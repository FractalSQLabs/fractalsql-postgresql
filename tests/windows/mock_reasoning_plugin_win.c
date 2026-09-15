/* tests/windows/mock_reasoning_plugin_win.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Windows port of tests/mock_reasoning_plugin.c -- same file-driven
 * design (returns whatever SQL the harness wrote to a fixed path,
 * wrapped in a ```sql fence, falling back to "SELECT 1" if absent),
 * but the fixed path is a Windows one. The original's hardcoded
 * "/tmp/fractalsql_bt_sql.txt" does not resolve to anything real on
 * Windows (no /tmp), so fopen() always failed there and every gate 04
 * scenario silently got the "SELECT 1" fallback regardless of what
 * build_test.ps1 actually wrote -- confirmed on the first real
 * Windows run (every injected-SQL scenario reported 'SELECT 1' back).
 *
 * Must match build_test.ps1's $SqlFile constant exactly.
 *
 * Build (via build_test.ps1 -- do not invoke directly):
 *   cl /nologo /MT /LD /DFSQL_STATIC /I<repo>\include ^
 *      tests\windows\mock_reasoning_plugin_win.c ^
 *      /Fe<out>\mock.dll ^
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
/* MSVC's CRT-deprecation warnings (fopen/strcpy below) are expected in
 * these fixtures -- silenced at the source, not chased file-by-file. */
#define _CRT_SECURE_NO_WARNINGS

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

/* Bare relative filename, not an absolute C:\Windows\Temp\... path --
 * that absolute path was the previous attempt, and it silently never
 * worked (fopen always returned NULL despite the file demonstrably
 * existing there with the right content, confirmed via diagnostics on
 * a real Windows run -- likely some access restriction specific to
 * that system directory from within the backend process, still not
 * fully root-caused). A relative path resolves against the backend's
 * CWD, which PostgreSQL sets to its own data directory at startup
 * (true cross-platform, not Windows-specific) -- a location the
 * backend unquestionably has full read/write access to, since it's
 * postgres's own. build_test.ps1 writes this file at
 * $DataDir\fractalsql_bt_sql.txt to match. */
#define MOCK_SQL_FILE "fractalsql_bt_sql.txt"

/* Dumped fresh on every generate() call (GENERATE, REVIEW, or a bare
 * fractal_reason()) so Gate28ReviewIsolation can tell which tier's
 * dispatch last ran without needing a distinct plugin: since REVIEW
 * always runs after GENERATE within one fractal_text_to_sql() call,
 * the file's content after the whole call reflects REVIEW's own env,
 * not GENERATE's. Same bare-relative-filename/CWD mechanism as
 * MOCK_SQL_FILE above. */
#define MOCK_RESPONSE_MODE_DUMP_FILE "fractalsql_bt_review_env_dump.txt"

static int
mock_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
            const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

/* This DLL and fractalsql.dll are separately /MT-linked (see the build
 * comment above), so each has its own private static-CRT copy of
 * _environ -- a documented MSVC gotcha (Microsoft Learn: "Potential
 * Errors Passing CRT Objects Across DLL Boundaries"; also reported
 * against curl and MIT krb5). plain getenv() here can silently miss
 * changes fractalsql.c makes via setenv()/unsetenv(), which on Win32
 * resolve to PostgreSQL's pgwin32_putenv()/pgwin32_unsetenv() (see PG's
 * src/port/win32env.c) -- those update the real, single, process-wide
 * environment block via SetEnvironmentVariable specifically so other
 * modules can observe the change, but only a reader that also goes
 * through the Win32 API, not a separate CRT's getenv(), is guaranteed
 * to see it. Confirmed as the actual cause of gate 28 (review_isolation)
 * failing only on Windows despite passing on Linux with the identical
 * source-level fix in t2s_run_review(): the fix's unsetenv() call was
 * genuinely running, but this plugin's own getenv() wasn't seeing it. */
static const char *
mock_getenv_win32(const char *name, char *buf, DWORD buf_len)
{
    DWORD n = GetEnvironmentVariableA(name, buf, buf_len);
    if (n == 0 || n >= buf_len)
        return NULL;
    return buf;
}

static void
mock_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
mock_generate(void *u, const char *p, size_t pl,
              char **response_out, size_t *response_len_out,
              void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    char  sql[8192] = "SELECT 1";
    FILE *f = fopen(MOCK_SQL_FILE, "r");
    if (f != NULL)
    {
        size_t n = fread(sql, 1, sizeof(sql) - 1, f);
        sql[n] = '\0';
        while (n > 0 && (sql[n - 1] == '\n' || sql[n - 1] == '\r'))
            sql[--n] = '\0';
        fclose(f);
    }

    /* fractal_text_to_sql()'s GENERATE step loads its own reasoning
     * context with FSQL_REASONING_HTTP_RESPONSE_MODE=code (see
     * ensure_text_to_sql_ctx() in src/fractalsql.c) -- under that mode
     * a real fractalsql-reasoning-http plugin already strips the
     * fence itself before generate() returns, so fractalsql-postgresql
     * no longer does any fence-stripping of its own (that used to be
     * find_sql_span()/extract_sql_from_response(), removed when this
     * mode switch landed -- see tests/mock_reasoning_plugin.c's
     * matching Linux-side comment for the full story). This mock must
     * model that same contract or every gate driving it through
     * fractal_text_to_sql() sees literal ```sql fences as part of the
     * "SQL" and fails to parse. fractal_reason()'s own bare calls
     * (gate 05/07) never set RESPONSE_MODE, so they still get the
     * fenced form here, same as a real chat-mode response would look
     * before any extraction. */
    char        response_mode_buf[256];
    const char *response_mode = mock_getenv_win32("FSQL_REASONING_HTTP_RESPONSE_MODE",
                                                    response_mode_buf, sizeof(response_mode_buf));
    int         code_mode = response_mode != NULL && strcmp(response_mode, "code") == 0;

    FILE *dump = fopen(MOCK_RESPONSE_MODE_DUMP_FILE, "w");
    if (dump != NULL)
    {
        fprintf(dump, "RESPONSE_MODE=%s\n", response_mode != NULL ? response_mode : "(unset)");
        fclose(dump);
    }

    char *resp = malloc(strlen(sql) + 16);
    if (resp == NULL)
        return -1;
    if (code_mode)
        strcpy(resp, sql);
    else
        snprintf(resp, strlen(sql) + 16, "```sql\n%s\n```", sql);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = mock_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = mock_format;
    vfs->generate      = mock_generate;
    return 0;
}
