/* tests/mock_embed_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic mock reasoning plugin for build_test.sh's embed/
 * vectorizer gate. Implements the reasoning ABI directly (no HTTP at
 * all) and normally returns a fixed JSON array-of-floats string as the
 * "generate" response -- the exact shape fractal_embed()'s
 * parse_embedding_array() expects (matching what the real
 * fractalsql-reasoning-http plugin hands back after ITS OWN
 * data[0].embedding extraction; see that repo's own mock_http_test.sh
 * for the HTTP-level equivalent of this same contract).
 *
 * Deliberately ignores the QUERY -- this gate is testing
 * fractalsql-postgresql's OWN dispatch/parsing glue (ensure_embed_ctx,
 * fractal_embed, the vectorizer's write-back), not any provider's HTTP
 * behavior. That's already covered by fractalsql-reasoning-http's own
 * test suite and this repo's tests/test_vectorizer.py (which exercises
 * the real vendored .so against a mock HTTP server).
 *
 * ONE exception (agent_partial_reasoning_fail gate, gate 32): the
 * plugin watches the CONTEXT blob, which only the agent REASONING calls
 * ever carry real content in (embed calls always dispatch context "{}";
 * fractal_search_agent/fractal_rag_agent dispatch the retrieval context
 * built from the searched table's row content). If the context blob
 * contains FSQL_BT_FAIL_REASON (a text value the gate plants in the
 * searched table), generate() fails with rc=1 instead of returning the
 * vector -- a deterministic reasoning-step failure with the embed half
 * still healthy, which is exactly the precondition the
 * fractalsql.agent_partial_reasoning_flip/raise contract needs.
 *
 * Test-harness use only; never shipped.
 *
 * Cross-platform, no OS-specific code (no file I/O, no POSIX-only
 * calls) -- built directly on both build_test.sh (Linux) and
 * build_test.ps1 (Windows), same as tests/evil_lying_length_plugin.c,
 * no separate tests/windows/<plugin>_win.c copy needed.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/mock_embed_plugin.c -o <tmp>/mock_embed_plugin.so
 */
#include "fractalsql_sql.h"

#include <stdlib.h>
#include <string.h>

#define MOCK_EMBED_VECTOR "[0.1,0.2,0.3]"
#define MOCK_FAIL_SENTINEL "FSQL_BT_FAIL_REASON"

/* Cross-platform needle-in-haystack over a length-delimited blob (the
 * ABI passes context as ptr+len, not a NUL-terminated string, and
 * memmem() is POSIX-only -- MSVC's CRT has no equivalent on the C99
 * path this file is built with). */
static const char *
find_blob(const char *hay, size_t hay_len, const char *needle, size_t needle_len)
{
    if (hay_len < needle_len)
        return NULL;
    for (size_t i = 0; i + needle_len <= hay_len; i++)
    {
        if (memcmp(hay + i, needle, needle_len) == 0)
            return hay + i;
    }
    return NULL;
}

static int
mock_embed_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
                  const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql;

    /* The prompt is the only channel generate() sees: "x" = business as
     * usual, the fail sentinel = the gate wants THIS dispatch (and only
     * this one -- embed dispatches context "{}") to fail. */
    static char b[2] = { 'x', '\0' };
    if (c != NULL && cl > 0 &&
        find_blob(c, cl, MOCK_FAIL_SENTINEL, sizeof(MOCK_FAIL_SENTINEL) - 1) != NULL)
    {
        *prompt_out     = MOCK_FAIL_SENTINEL;
        *prompt_len_out = sizeof(MOCK_FAIL_SENTINEL) - 1;
        return 0;
    }
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
mock_embed_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
mock_embed_generate(void *u, const char *p, size_t pl,
                    char **response_out, size_t *response_len_out,
                    void (**response_free_fn_out)(void *))
{
    (void) u;

    *response_out         = NULL;
    *response_len_out     = 0;
    *response_free_fn_out = mock_embed_free;

    /* Fail sentinel = requested reasoning-step failure (gate 32's
     * agent_partial_reasoning_fail pair): a nonzero rc with no response
     * body, the same shape a real provider outage surfaces through. */
    if (p != NULL && pl == sizeof(MOCK_FAIL_SENTINEL) - 1 &&
        memcmp(p, MOCK_FAIL_SENTINEL, pl) == 0)
        return 1;

    /* Not strdup() -- POSIX-only, and MSVC's CRT treats it as
     * deprecated (C4996). A plain malloc+memcpy has no such baggage on
     * either toolchain. */
    size_t len = strlen(MOCK_EMBED_VECTOR);
    char  *resp = malloc(len + 1);
    if (resp == NULL)
        return -1;
    memcpy(resp, MOCK_EMBED_VECTOR, len + 1);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = mock_embed_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = mock_embed_format;
    vfs->generate      = mock_embed_generate;
    return 0;
}