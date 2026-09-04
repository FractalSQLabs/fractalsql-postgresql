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
#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    const char *response_mode = getenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
    int         code_mode = response_mode != NULL && strcmp(response_mode, "code") == 0;

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
