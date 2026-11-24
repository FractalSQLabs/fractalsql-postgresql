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
#include <stdio.h>
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


/* ------------------------------------------------------------------ chunking */

/* the whole JSON result is capped: a 20 KB text with a large overlap would otherwise expand to gigabytes (size x chunks) */
#define FSQL_CHUNK_MAX_OUT ((size_t) 64 * 1024 * 1024)
typedef struct { char *b; size_t n, cap; int oom; int big; } ChunkBuf;

static void cb_put(ChunkBuf *o, const char *s, size_t len)
{
    if (o->oom || o->big) return;
    if (len > FSQL_CHUNK_MAX_OUT || o->n > FSQL_CHUNK_MAX_OUT - len) { o->big = 1; return; }
    if (o->n + len + 1 > o->cap) {
        size_t nc = o->cap ? o->cap : 256;
        char *nb;
        while (nc < o->n + len + 1) nc *= 2;
        nb = (char *) realloc(o->b, nc);
        if (!nb) { o->oom = 1; return; }
        o->b = nb; o->cap = nc;
    }
    memcpy(o->b + o->n, s, len); o->n += len; o->b[o->n] = '\0';
}

typedef struct { size_t *cp; size_t n; const unsigned char *t; size_t blen; } ChunkCps;

static int cps_build(ChunkCps *c, const unsigned char *t, size_t blen)
{
    size_t i = 0;
    c->t = t; c->blen = blen; c->n = 0;
    c->cp = (size_t *) malloc((blen + 1) * sizeof(size_t));
    if (!c->cp) return -1;
    while (i < blen) {
        unsigned char b = t[i];
        size_t len = b < 0x80 ? 1 : (b >= 0xF0 && b <= 0xF4) ? 4 : (b >= 0xE0) ? 3 : (b >= 0xC2) ? 2 : 1, k = 1;
        c->cp[c->n++] = i;
        if (b >= 0xF5) len = 1;
        while (k < len && i + k < blen && (t[i + k] & 0xC0) == 0x80) k++;
        i += (k == len) ? len : 1;       /* a truncated or invalid sequence is one character per byte */
    }
    c->cp[c->n] = blen;
    return 0;
}

static int chunk_is_ws(unsigned char b) { return b == ' ' || b == '\t' || b == '\r' || b == '\n'; }

/* the character at index i as a single byte when it is ASCII, else 0xFF */
static unsigned char cps_ascii(const ChunkCps *c, size_t i)
{
    size_t b = c->cp[i];
    return c->t[b] < 0x80 ? c->t[b] : 0xFF;
}

static void chunk_emit(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b)
{
    char tmp[96];
    int l = snprintf(tmp, sizeof tmp, "%s{\"no\":%lld,\"start\":%lld,\"end\":%lld,\"text\":\"", no ? "," : "", (long long) no, (long long) a, (long long) b);
    cb_put(o, tmp, (size_t) l);
    for (size_t i = c->cp[a]; i < c->cp[b]; i++) {
        unsigned char ch = c->t[i];
        if (ch >= 0x80) {
            /* a byte that does not belong to a well-formed UTF-8 character is written as U+FFFD, so the JSON stays valid UTF-8 */
            size_t need = ch >= 0xF0 ? 4 : ch >= 0xE0 ? 3 : 2, ln = 1;
            while (i + ln < c->cp[b] && (c->t[i + ln] & 0xC0) == 0x80 && ln < need) ln++;
            int okc = 0;
            if (ch >= 0xC2 && ch <= 0xDF) okc = ln == 2;
            else if (ch >= 0xE0 && ch <= 0xEF) okc = ln == 3 && !(ch == 0xE0 && c->t[i + 1] < 0xA0) && !(ch == 0xED && c->t[i + 1] >= 0xA0);
            else if (ch >= 0xF0 && ch <= 0xF4) okc = ln == 4 && !(ch == 0xF0 && c->t[i + 1] < 0x90) && !(ch == 0xF4 && c->t[i + 1] >= 0x90);
            if (!okc) { cb_put(o, "\\ufffd", 6); continue; }
            cb_put(o, (const char *) &c->t[i], ln);
            i += ln - 1;
            continue;
        }
        if (ch == '"') cb_put(o, "\\\"", 2);
        else if (ch == '\\') cb_put(o, "\\\\", 2);
        else if (ch == '\n') cb_put(o, "\\n", 2);
        else if (ch == '\r') cb_put(o, "\\r", 2);
        else if (ch == '\t') cb_put(o, "\\t", 2);
        else if (ch < 0x20) { l = snprintf(tmp, sizeof tmp, "\\u%04x", ch); cb_put(o, tmp, (size_t) l); }
        else cb_put(o, (const char *) &c->t[i], 1);   /* a raw byte: UTF-8 passes through unchanged */
    }
    cb_put(o, "\"}", 2);
}

/* the span [a,b) split into pieces of at most size characters, overlap shared; the new chunk count, or (size_t)-1 over the cap */
static size_t chunk_split(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b, size_t size, size_t overlap)
{
    size_t pos = a;
    for (;;) {
        size_t e = pos + size < b ? pos + size : b;
        if (no >= FSQL_CHUNK_MAX_CHUNKS || o->big) return (size_t) -1;
        chunk_emit(o, c, no++, pos, e);
        if (e >= b) break;
        pos = e - overlap;
    }
    return no;
}

int fsql_chunk_text(const unsigned char *t, size_t blen, long size, long overlap, int mode, char **out)
{
    ChunkCps c;
    ChunkBuf o = { NULL, 0, 0, 0, 0 };
    size_t no = 0, S = (size_t) size, V = (size_t) overlap, n;
    int over = 0;
    *out = NULL;
    if (cps_build(&c, t, blen) != 0) return -1;
    n = c.n;
    cb_put(&o, "[", 1);
    if (mode == 0) {
        if (n > 0) { no = chunk_split(&o, &c, 0, 0, n, S, V); over = no == (size_t) -1; }
    } else {
        size_t cur_a = 0, cur_b = 0, i = 0;
        int have = 0;
        while (i < n && !over) {
            size_t ua, ub;
            while (i < n && chunk_is_ws(cps_ascii(&c, i))) i++;
            if (i >= n) break;
            ua = i;
            for (;;) {                       /* extend to the end of the unit */
                unsigned char ch;
                if (i >= n) { ub = n; break; }
                ch = cps_ascii(&c, i);
                if (chunk_is_ws(ch)) {       /* whitespace: a paragraph break, or (sentence mode) just a separator? */
                    size_t j = i; int lf = 0;
                    while (j < n && chunk_is_ws(cps_ascii(&c, j))) { if (cps_ascii(&c, j) == '\n') lf++; j++; }
                    if (lf >= 2) { ub = i; i = j; break; }
                    i = j;
                    continue;
                }
                i++;
                if (mode == 2 && (ch == '.' || ch == '!' || ch == '?')) {
                    while (i < n && (cps_ascii(&c, i) == '.' || cps_ascii(&c, i) == '!' || cps_ascii(&c, i) == '?')) i++;
                    if (i >= n || chunk_is_ws(cps_ascii(&c, i))) { ub = i; break; }
                }
            }
            while (ub > ua && chunk_is_ws(cps_ascii(&c, ub - 1))) ub--;
            if (ub == ua) continue;
            if (ub - ua > S) {               /* longer than a chunk: flush, then split it */
                if (have) { chunk_emit(&o, &c, no++, cur_a, cur_b); have = 0; }
                no = chunk_split(&o, &c, no, ua, ub, S, V);
                if (no == (size_t) -1) over = 1;
            } else if (!have) { cur_a = ua; cur_b = ub; have = 1; }
            else if (ub - cur_a <= S) { cur_b = ub; }
            else { chunk_emit(&o, &c, no++, cur_a, cur_b); cur_a = ua; cur_b = ub; }
            if (!over && (no >= FSQL_CHUNK_MAX_CHUNKS || o.big)) over = 1;
        }
        if (have && !over) chunk_emit(&o, &c, no++, cur_a, cur_b);
    }
    free(c.cp);
    cb_put(&o, "]", 1);
    if (o.oom) { free(o.b); return -1; }
    if (over || o.big) { free(o.b); return 1; }
    *out = o.b;
    return 0;
}
