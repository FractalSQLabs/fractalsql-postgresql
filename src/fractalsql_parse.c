/* src/fractalsql_parse.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Implementations for fractalsql_parse.h -- see that header for why
 * this is a separate, postgres.h-free translation unit. Pure C99,
 * no PostgreSQL dependency: standard library only.
 */
#include "fractalsql_parse.h"

#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* Shared helper for the JSON-sniffing parsers' identical whitespace/comma
 * skip loops. NOTE:
 * fsql_extract_population keeps its own narrower (space/comma-only)
 * inline skips on purpose -- its input contract is the SFS
 * population block, emitted compactly without newlines. */
static const char *
skip_json_space(const char *p)
{
    while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' ||
           *p == '\t')
        p++;
    return p;
}

int
fsql_extract_best_point(const char *json, double *out, int cap)
{
    if (!json) return -1;
    const char *p = strstr(json, "\"best_point\"");
    if (!p) return -1;
    p = strchr(p, '[');
    if (!p) return -1;
    p++;
    int n = 0;
    while (*p && n < cap) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return -1;
        out[n++] = d;
        p = end;
    }
    return n;
}

int
fsql_parse_embedding_array(const char *json, double *out, int cap)
{
    if (!json) return -1;
    const char *p = strchr(json, '[');
    if (!p) return -1;
    p++;
    int n = 0;
    while (*p) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return -1;
        if (n >= cap) return -1;
        out[n++] = d;
        p = end;
    }
    return n;
}

int
fsql_extract_population(const char *json, int dim, int max_rows, double *out_flat)
{
    if (!json) return 0;
    const char *p = strstr(json, "\"population\":[");
    if (!p)
        return 0;
    p += strlen("\"population\":[");
    int np = 0;
    while (np < max_rows) {
        while (*p == ' ' || *p == ',') p++;
        if (*p != '[')                          /* end of outer array */
            break;
        p++;
        for (int d = 0; d < dim; d++) {
            char *end = NULL;
            out_flat[(size_t) np * dim + d] = strtod(p, &end);
            if (end == p)                       /* malformed — stop */
                return np;
            p = end;
            while (*p == ' ' || *p == ',') p++;
        }
        if (*p == ']') p++;
        np++;
    }
    return np;
}

/* One top_k element {"idx":N,"dist":D|null} -> (idx, dist). *pp is
 * positioned at the element's '{'; on success (returns 1) it ends past
 * the element's '}' and BOTH out params are FILLED — always, whatever
 * the values are (even idx < 0): the RANGE CHECK lives at the call
 * site, on the LOCAL scalars (writing only conditionally into
 * caller-owned slots would leave the call site reading an uninitialized
 * slot on the skip path). On a malformed entry
 * returns 0; the caller treats that as a whole-call failure, as before. */
static int
parse_topk_object(const char **pp, long *idx, double *dist)
{
    const char *p = *pp;
    p++;                                       /* past '{' */
    const char *idx_p = strstr(p, "\"idx\":");
    if (!idx_p) return 0;
    idx_p += strlen("\"idx\":");
    char *end = NULL;
    *idx = strtol(idx_p, &end, 10);
    if (end == idx_p) return 0;
    p = end;
    const char *dist_p = strstr(p, "\"dist\":");
    if (!dist_p) return 0;
    dist_p += strlen("\"dist\":");
    if (strncmp(dist_p, "null", 4) == 0) {
        *dist = 0.0;
        p = dist_p + 4;
    } else {
        end = NULL;
        *dist = strtod(dist_p, &end);
        if (end == dist_p) return 0;
        p = end;
    }
    p = strchr(p, '}');
    if (!p) return 0;
    *pp = p + 1;                               /* past '}' */
    return 1;
}

int
fsql_extract_topk(const char *json, int max_k, int *out_idx, double *out_dist)
{
    /* NULL-safe: a caller whose fsql_search_ptr call failed leaves json NULL,
     * and strstr(NULL, ...) is undefined (segfault). Return "no results"
     * rather than dereferencing. */
    if (!json)
        return -1;
    const char *p = strstr(json, "\"top_k\":[");
    if (!p)
        return -1;
    p += strlen("\"top_k\":[");
    int n = 0;
    while (n < max_k) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;             /* end of top_k array */
        if (*p != '{') return -1;
        long idx = 0;
        double dist = 0.0;
        if (!parse_topk_object(&p, &idx, &dist)) return -1;
        if (idx >= 0 && idx <= INT_MAX) {       /* skip unfilled (-1) slots;
                                                 * reject values that would
                                                 * wrap in the int cast */
            out_idx[n]  = (int) idx;
            out_dist[n] = dist;
            n++;
        }
    }
    return n;
}
