/* tests/windows/scripted_reasoning_plugin_win.c
 *
 * Windows variant of tests/scripted_reasoning_plugin.c. Same ABI, script
 * format and behavior; only the two things that cannot cross a Windows
 * backend change:
 *
 *   - The script file and the dispatch log open by BARE RELATIVE FILENAME,
 *     resolved against the backend's CWD, which PostgreSQL sets to its own
 *     data directory at startup -- a location the backend unquestionably
 *     has full access to, since it's postgres's own. The POSIX plugin's
 *     "/tmp/..." literals resolve against every process's own drive: the
 *     driver (python, from the checkout) and the backend (postgres.exe)
 *     can land on different drives, and the plugin then reads a script
 *     that was never written where it looks ("fopen always returned NULL
 *     despite the file demonstrably existing" -- the same class of
 *     failure the mock plugin's Windows variant was built for;
 *     build_test.ps1 passes the driver FSQL_SCRIPT naming
 *     $DataDir\fractalsql_bt_script.txt so driver and backend agree).
 *
 *   - The tier env vars (FSQL_REASONING_HTTP_MODE / _RESPONSE_MODE) are
 *     read through the Win32 API, not getenv(): the extension updates the
 *     real single process-wide environment block via SetEnvironmentVariable
 *     (postgresql's own port), which a separate CRT's getenv() is not
 *     guaranteed to see -- confirmed as the actual cause of gate 28
 *     (review_isolation) failing only on Windows with the identical
 *     source-level fix in place (see mock_reasoning_plugin_win.c).
 *
 * Everything else (script picking, the record separator, the fenced-block
 * extraction, the per-tier context) is the POSIX plugin's own logic.
 *
 * Test-harness use only; never shipped.
 *
 * Build (build_test.ps1 BuildTestPlugins compiles this):
 *   cl /nologo /MT /LD /DFSQL_STATIC /I<repo>\include ^
 *      tests\windows\scripted_reasoning_plugin_win.c /Fo<tmp>\scripted.obj ^
 *      /Fe<out>\scripted.dll ^
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
#define _CRT_SECURE_NO_WARNINGS

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

#include <process.h>
#define getpid _getpid

#define SCRIPT_FILE       "fractalsql_bt_script.txt"
#define RS                 '\x1e'
#define MAX_SCRIPT_BYTES   (256 * 1024)
#define SCRIPT_CALL_LOG    "fractalsql_bt_script_calls.log"

/* The extension updates the real single process-wide environment block via
 * SetEnvironmentVariable (see win32env.c); a CRT getenv() may return a
 * stale value or NULL for such a change, so read through the Win32 API --
 * same root cause the mock plugin's Windows variant already covered. */
static const char *
scripted_getenv_win32(const char *name, char *buf, DWORD buf_len)
{
    DWORD n = GetEnvironmentVariableA(name, buf, buf_len);
    if (n == 0 || n >= buf_len)
        return NULL;
    return buf;
}

/* The per-tier state. The extension loads the plugin ONCE PER TIER (the
 * chat tier, the text-to-SQL tier, the review tier and the embedding tier
 * each get their own VFS), so the tier is captured at init time -- the
 * environment says which tier is being loaded (the extension sets
 * FSQL_REASONING_HTTP_MODE=embedding for the embedding tier and
 * FSQL_REASONING_HTTP_RESPONSE_MODE=code for the text-to-SQL one, and
 * clears both for the chat tiers), and reading it at dispatch time would
 * be wrong: the embedding tier's MODE is still set when the chat tier
 * dispatches later in the same backend. */
typedef struct
{
    int  is_embed;   /* the embedding tier: the embedding script, no fence extraction */
    int  code;       /* RESPONSE_MODE=code: extract the single fenced block */
} scripted_ctx_t;

/* ONE script for every tier, and the replies are consumed in the order
 * the dispatches happen: a text-to-SQL call dispatches to the model
 * twice (the candidate, then the review verdict), a retrieval agent
 * dispatches to the embedding endpoint first and to the model second.
 * One file and one counter keep that ordering the only thing the harness
 * has to get right -- and it keeps the plugin independent of which tier
 * it is serving, which matters because a host may hand the same plugin
 * instance to more than one of them. */
static long g_calls = 0;

/* Reads a whole file into a malloc'd NUL-terminated buffer. Returns NULL
 * when the file is absent or unreadable (the harness removes it between
 * scenarios, so an absent file is a normal state, not an error). */
static char *
read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL)
        return NULL;
    size_t cap = 4096, len = 0;
    char  *buf = malloc(cap);
    if (buf == NULL)
    {
        fclose(f);
        return NULL;
    }
    for (;;)
    {
        if (len + 1 >= cap)
        {
            if (cap >= MAX_SCRIPT_BYTES)
                break;
            size_t ncap = cap * 2;
            if (ncap > MAX_SCRIPT_BYTES)
                ncap = MAX_SCRIPT_BYTES;
            char *nbuf = realloc(buf, ncap);
            if (nbuf == NULL)
            {
                free(buf);
                fclose(f);
                return NULL;
            }
            buf = nbuf;
            cap = ncap;
        }
        size_t n = fread(buf + len, 1, cap - len - 1, f);
        if (n == 0)
            break;
        len += n;
    }
    fclose(f);
    buf[len] = '\0';
    return buf;
}

/* Picks the idx-th (0-based) reply out of a script buffer. Returns 1 and
 * points *out/*out_len at the reply (NUL-terminated for convenience), 0
 * when the script has no such reply (exhausted or absent). */
static int
script_pick(const char *script, long idx, const char **out, size_t *out_len)
{
    if (script == NULL)
        return 0;
    const char *p = script;
    for (long i = 0;; i++)
    {
        const char *e = strchr(p, RS);
        size_t      len = e ? (size_t) (e - p) : strlen(p);
        if (i == idx)
        {
            *out     = p;
            *out_len = len;
            return 1;
        }
        if (e == NULL)
            return 0;
        p = e + 1;
    }
}

/* --- RESPONSE_MODE=code: the fenced-block extraction ------------------- */

/* Finds the next "```" at or after p. Returns NULL when there is none. */
static const char *
find_fence(const char *p, const char *end)
{
    while (end - p >= 3)
    {
        if (p[0] == '`' && p[1] == '`' && p[2] == '`')
            return p;
        p++;
    }
    return NULL;
}

/* Applies the real plugin's code-mode rules to a reply.
 *   0 = hand back the reply unchanged (no fenced block)
 *   1 = hand back the single block's interior
 *  -1 = two or more blocks: a dispatch failure
 * The result is malloc'd; *out_len excludes the NUL. */
static int
apply_code_mode(const char *reply, size_t reply_len, char **out, size_t *out_len)
{
    const char *end     = reply + reply_len;
    const char *p       = reply;
    const char *start   = NULL;
    size_t      len     = 0;
    int         blocks  = 0;

    while (p < end)
    {
        const char *fence = find_fence(p, end);
        const char *inner = NULL;
        const char *close = NULL;
        if (fence != NULL)
        {
            inner = fence + 3;
            while (inner < end && *inner != '\n')
                inner++;              /* skip the language tag */
            if (inner < end)
                inner++;              /* skip the newline after it */
            close = find_fence(inner, end);
        }
        if (fence == NULL || close == NULL)
            break;                    /* no fence left, or an unclosed one */

        blocks++;
        if (blocks == 1)
        {
            start = inner;
            len   = (size_t) (close - inner);
            while (len > 0 && (start[len - 1] == '\n' || start[len - 1] == '\r'))
                len--;
        }
        p = close + 3;
    }

    if (blocks > 1)
        return -1;

    if (blocks == 0)
    {
        char *copy = malloc(reply_len + 1);
        if (copy == NULL)
            return -1;
        memcpy(copy, reply, reply_len);
        copy[reply_len] = '\0';
        *out     = copy;
        *out_len = reply_len;
        return 0;
    }

    char *copy = malloc(len + 1);
    if (copy == NULL)
        return -1;
    memcpy(copy, start, len);
    copy[len] = '\0';
    *out     = copy;
    *out_len = len;
    return 0;
}

/* --- the ABI ----------------------------------------------------------- */

static int
scripted_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
                const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out     = b;
    *prompt_len_out = 1;
    return 0;
}

static void
scripted_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
scripted_generate(void *u, const char *p, size_t pl,
                  char **response_out, size_t *response_len_out,
                  void (**response_free_fn_out)(void *))
{
    (void) p; (void) pl;

    *response_out         = NULL;
    *response_len_out     = 0;
    *response_free_fn_out = scripted_free;

    scripted_ctx_t *sc = (scripted_ctx_t *) u;
    if (sc == NULL)
        return 1;

    const char *path = SCRIPT_FILE;
    long        idx  = g_calls++;

    char *script = read_file(path);
    if (script == NULL)
    {
        fprintf(stderr,
                "scripted_reasoning_plugin: no script at %s -- the dispatch fails\n",
                path);
        return 1;
    }

    const char *reply     = NULL;
    size_t      reply_len = 0;
    if (!script_pick(script, idx, &reply, &reply_len))
    {
        fprintf(stderr,
                "scripted_reasoning_plugin: the script at %s ran out (call %ld) -- "
                "the dispatch fails\n", path, idx + 1);
        free(script);
        return 1;
    }

    /* A dispatch log: which backend (pid) consumed which reply of which
     * script. The counters live in the plugin's own image, so this is how
     * a gate proves they are per backend and not shared. */
    {
        FILE *log = fopen(SCRIPT_CALL_LOG, "a");
        if (log != NULL)
        {
            fprintf(log, "pid=%ld script=%s call=%ld embed=%d code=%d reply=[%.60s]\n",
                    (long) getpid(), sc->is_embed ? "embed" : "reason", idx + 1, sc->is_embed, sc->code,
                    reply_len < 60 ? reply : reply + 60);
            fclose(log);
        }
    }

    /* The reasoning tiers run with RESPONSE_MODE=code for text-to-SQL's
     * GENERATE step; the real plugin does the fenced-block extraction
     * itself, so this one does too. */
    char  *body     = NULL;
    size_t body_len = 0;
    if (sc->code)
    {
        int rc = apply_code_mode(reply, reply_len, &body, &body_len);
        if (rc < 0)
        {
            fprintf(stderr,
                    "scripted_reasoning_plugin: the reply holds more than one fenced "
                    "block -- the dispatch fails\n");
            free(script);
            return 1;
        }
    }
    else
    {
        body = malloc(reply_len + 1);
        if (body == NULL)
        {
            free(script);
            return -1;
        }
        memcpy(body, reply, reply_len);
        body[reply_len] = '\0';
        body_len = reply_len;
    }
    free(script);

    *response_out         = body;
    *response_len_out     = body_len;
    *response_free_fn_out = scripted_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    /* The per-tier state lives as long as the backend does: this plugin exports no
     * fsql_reasoning_fini, so the few dozen bytes are released when the backend exits. */
    scripted_ctx_t *sc = (scripted_ctx_t *) calloc(1, sizeof(scripted_ctx_t));
    if (sc == NULL)
        return -1;

    char mode[64], rmode[64];
    const char *m = scripted_getenv_win32("FSQL_REASONING_HTTP_MODE", mode, sizeof mode);
    sc->is_embed = (m != NULL && strcmp(m, "embedding") == 0);

    const char *rm = scripted_getenv_win32("FSQL_REASONING_HTTP_RESPONSE_MODE", rmode, sizeof rmode);
    sc->code = !sc->is_embed && rm != NULL && strcmp(rm, "code") == 0;

    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = sc;
    vfs->format_prompt = scripted_format;
    vfs->generate      = scripted_generate;
    return 0;
}
