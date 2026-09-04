/* tests/mock_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic, file-driven mock reasoning plugin for build_test.sh's
 * text-to-sql gate. Implements the reasoning ABI (fsql_reasoning_init)
 * and returns, as the "LLM response", whatever SQL the harness has
 * written to /tmp/fractalsql_bt_sql.txt (wrapped in a ```sql fence).
 * Falls back to "SELECT 1" if the file is absent.
 *
 * A fixed path is used on purpose: the backend is forked from the
 * postmaster and does NOT inherit the harness's environment, so we
 * cannot pass the path via an env var -- the harness writes the file,
 * the plugin reads it. Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/mock_reasoning_plugin.c -o <tmp>/mock_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MOCK_SQL_FILE "/tmp/fractalsql_bt_sql.txt"

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
     * fence itself before generate() returns (its own tested
     * extract-and-fail-on-2+-blocks logic), so fractalsql-postgresql
     * no longer does any fence-stripping of its own (that used to be
     * find_sql_span()/extract_sql_from_response(), removed when this
     * mode switch landed). This mock must model that same contract or
     * every gate driving it through fractal_text_to_sql() would see
     * literal ```sql fences as part of the "SQL" and fail to parse --
     * matching real reasoning-http's behavior, not the pre-refactor
     * shape. fractal_reason()'s own bare calls (gate 05/07) never set
     * RESPONSE_MODE, so they still get the fenced form here, same as
     * a real chat-mode response would look before any extraction. */
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
