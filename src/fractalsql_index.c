/* src/fractalsql_index.c -- fractal_index_* and the indexed fractal_search for PostgreSQL.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The core does the maths (k-means cells, INT8 / INT4 / FP16 / FP32 codes, candidate search, recall estimation: the fsql_ivf_*
 * functions); this file owns the storage and the SQL surface:
 *
 *   fractal_index_create(table_name, vector_col, options jsonb DEFAULT '{}') -> jsonb    build and store an index
 *   fractal_index_rebuild(name)                                              -> jsonb    full rebuild, same options
 *   fractal_index_drop(name)                                                 -> boolean
 *   fractal_index_info(name)                                                 -> jsonb    format, size, staleness, calibration, last search, status + advice
 *   fractal_index_list()                                  -> TABLE(name, table_name, vector_col, format, dim, rows, rows_now, stale, status, generation)
 *   fractal_index_refresh(name)                                              -> jsonb    fold the rows added since the build into the cells
 *   fractal_search(table_name, vector_col, query float8[], k int4, options jsonb DEFAULT '{}')
 *                                                -> TABLE(doc_id text, distance float8, scan_pos int8)
 *   fractal_index_candidates(table_name, vector_col, query float8[], options jsonb DEFAULT '{}') -> int8[]
 *
 * The indexed row identity is a stable integer key column (option id_col, default "id"): a ctid moves on UPDATE and VACUUM, so it
 * cannot name a row inside an index that outlives the transaction. doc_id is that key as text and scan_pos is the key as well
 * (there is no scan order inside an index).
 *
 * Storage: two ordinary tables created on first use in the schema the extension lives in (so they are dumped by pg_dump):
 *   fractal_index_meta(name text PRIMARY KEY, tbl, col, id_col, dim, metric, format, nlist, pca_dim, rows, max_id, model, seed, generation,
 *                      format_version, options jsonb, built_at timestamptz, nprobe_default, calib jsonb, model_blob bytea)
 *   fractal_index_cells(name, generation, cell, n, ids bytea (int64 little-endian), codes bytea)
 * A build writes a NEW generation and switches the generation pointer inside the caller's transaction, so readers see either the old
 * or the new generation, never a partial one; an error aborts the whole build. Rows added after the build (key above max_id) are
 * scanned exactly (the delta); deleted rows are dropped by the verify step; a vector changed in place is only picked up by a
 * rebuild (fractal_index_info reports stale).
 *
 * Every candidate is verified: the shortlist rows are fetched, deleted rows dropped, exact double cosine distances computed with the
 * one shared implementation (fsql_precision.h) and ordered by distance then key. The index never returns an approximate distance.
 * Indexed fractal_search does not apply Diversify repulsion (fractal_search_telemetry does).
 */
#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "catalog/namespace.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/numeric.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include <errno.h>
#include <math.h>
#include <string.h>
#include <time.h>

#include "fractalsql_vector.h"
#include "fractalsql_sql.h"
#include "fsql_precision.h"

/* The IVF maths lives in fractalsql-core and the vendored core archive must carry it: the linker
 * extracts an archive member only to resolve an undefined STRONG reference, so a weak reference
 * would leave the symbol NULL -- the index would then be silently unavailable even with a fresh
 * archive. The declarations below therefore refer to the core's own header (a strong reference),
 * and a build against a core that predates the index is opted out of explicitly with
 * -DFSQL_NO_IVF: the functions stay registered and report that this core has no index. */

#if defined(FSQL_NO_IVF)
/* 0: this build was told the core has no IVF maths. */
static int fi_ivf_available(void) { return 0; }
#else
/* 1: the core's IVF maths is linked in. */
static int fi_ivf_available(void) { return 1; }
#endif

#define FI_NO_CORE_MSG "fractalsql: this build of fractalsql-core does not carry the IVF index (rebuild the core and refresh include/<platform>)"

#if defined(_WIN32) && PG_VERSION_NUM < 160000
#undef PG_FUNCTION_INFO_V1
#define PG_FUNCTION_INFO_V1(funcname) \
extern PGDLLEXPORT Datum funcname(PG_FUNCTION_ARGS); \
extern PGDLLEXPORT const Pg_finfo_record * CppConcat(pg_finfo_,funcname)(void); \
const Pg_finfo_record * \
CppConcat(pg_finfo_,funcname) (void) \
{ \
	static const Pg_finfo_record my_finfo = { 1 }; \
	return &my_finfo; \
} \
extern int no_such_variable
#endif

PG_FUNCTION_INFO_V1(fractal_index_create);
PG_FUNCTION_INFO_V1(fractal_index_rebuild);
PG_FUNCTION_INFO_V1(fractal_index_drop);
PG_FUNCTION_INFO_V1(fractal_index_info);
PG_FUNCTION_INFO_V1(fractal_index_list);
PG_FUNCTION_INFO_V1(fractal_index_refresh);
PG_FUNCTION_INFO_V1(fractal_index_ensure);
PG_FUNCTION_INFO_V1(fractal_index_search);
PG_FUNCTION_INFO_V1(fractal_index_candidates);

#define FI_MAXDIM         8192
#define FI_MAX_CACHED     8
#define FI_MAX_BYTES      ((size_t) 2 << 30)
#define FI_CALIB_FLOATS   ((size_t) 1 << 28)
#define FI_FORMAT_VERSION 1

static const char *const FI_FMT_NAME[4] = { "INT8", "INT4", "FP16", "FP32" };

static int
fi_parse_fmt(const char *s)
{
    for (int i = 0; i < 4; i++)
        if (strcmp(s, FI_FMT_NAME[i]) == 0) return i;
    return -1;
}

static size_t
fi_default_rerank(int fmt) { return fmt == FSQL_IVF_FMT_INT4 ? 40u : (fmt == FSQL_IVF_FMT_INT8 ? 30u : 0u); }

/* ------------------------------------------------------------------ options (jsonb) */

/* the text of a top-level key of the options jsonb, or NULL when absent/null (palloc'd) */
static char *
opt_text(Jsonb *opts, const char *key)
{
    JsonbValue buf, *v;
    if (opts == NULL || !JB_ROOT_IS_OBJECT(opts)) return NULL;
    v = getKeyJsonValueFromContainer(&opts->root, key, (int) strlen(key), &buf);
    if (v == NULL) return NULL;
    if (v->type == jbvString) {
        char *s = palloc((Size) v->val.string.len + 1);
        memcpy(s, v->val.string.val, (size_t) v->val.string.len);
        s[v->val.string.len] = '\0';
        return s;
    }
    if (v->type == jbvNumeric)
        return DatumGetCString(DirectFunctionCall1(numeric_out, NumericGetDatum(v->val.numeric)));
    if (v->type == jbvBool) return pstrdup(v->val.boolean ? "true" : "false");
    return NULL;
}

static double
opt_num(Jsonb *opts, const char *key, double dflt)
{
    char *t = opt_text(opts, key);
    char *e;
    double v;
    if (t == NULL) return dflt;
    v = strtod(t, &e);
    return (e == t || v != v) ? dflt : v;
}

static bool
opt_bool(Jsonb *opts, const char *key, bool dflt)
{
    char *t = opt_text(opts, key);
    if (t == NULL) return dflt;
    if (strcmp(t, "true") == 0) return true;
    if (strcmp(t, "false") == 0) return false;
    return dflt;
}

static Jsonb *
arg_options(FunctionCallInfo fcinfo, int n)
{
    return PG_NARGS() > n && !PG_ARGISNULL(n) ? PG_GETARG_JSONB_P(n) : NULL;
}

/* The required arguments of an index function are read with PG_GETARG_*, which does not look at the null flag: a NULL would be a null
 * pointer dereference in the backend. None of these functions is STRICT, so each one refuses a NULL in its first `nreq` arguments up front. */
static void
fi_require_args(FunctionCallInfo fcinfo, int nreq, const char *fname)
{
    for (int i = 0; i < nreq; i++)
        if (PG_ARGISNULL(i))
            ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED), errmsg("%s: argument %d must not be NULL", fname, i + 1)));
}

/* ------------------------------------------------------------------ little-endian ids */

static void put_le64(uint8_t *p, int64_t v) { uint64 u = (uint64) v; for (int i = 0; i < 8; i++) p[i] = (uint8_t) (u >> (8 * i)); }
static int64_t get_le64(const uint8_t *p) { uint64 u = 0; for (int i = 0; i < 8; i++) u |= (uint64) p[i] << (8 * i); return (int64_t) u; }

/* ------------------------------------------------------------------ resident cache (per backend, plain malloc: it outlives transactions) */

typedef struct FIdx {
    char            name[NAMEDATALEN];
    int             dim, fmt, nlist, pca_dim, generation, loaded, nprobe_default;
    int64           rows, max_id;
    fsql_ivf_model *m;
    fsql_ivf_index *x;
} FIdx;

static FIdx    g_cache[FI_MAX_CACHED];
static int     g_ncache = 0;
static int64   g_last_rows_scanned = 0;
static int     g_last_cells_probed = 0, g_last_used_index = 0, g_last_lookups = 0;

static void
fi_release(FIdx *x)
{
    if (x->x) fsql_ivf_index_free(x->x);
    if (x->m) fsql_ivf_model_free(x->m);
    memset(x, 0, sizeof *x);
}

static void
fi_forget(const char *name)
{
    for (int i = 0; i < g_ncache; i++)
        if (strcmp(g_cache[i].name, name) == 0) { fi_release(&g_cache[i]); g_cache[i].name[0] = '\0'; }
}

/* ------------------------------------------------------------------ SPI helpers */

static void
require_fits(const char *name, const char *what)
{
    if (name != NULL && strlen(name) >= NAMEDATALEN)
        ereport(ERROR, (errcode(ERRCODE_NAME_TOO_LONG), errmsg("fractalsql: %s \"%.20s...\" is longer than %d bytes", what, name, NAMEDATALEN - 1)));
}

/* the schema the extension's functions live in (the index tables are created there) */
static char *
fi_schema(FunctionCallInfo fcinfo)
{
    Oid nsp = get_func_namespace(fcinfo->flinfo->fn_oid);
    char *s = get_namespace_name(nsp);
    if (s == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_SCHEMA), errmsg("fractalsql: cannot resolve the extension schema")));
    return s;
}

static void
fi_ensure_tables(const char *schema)
{
    StringInfoData q;
    const char *qs = quote_identifier(schema);
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT to_regclass('%s.fractal_index_cells') IS NOT NULL AND to_regclass('%s.fractal_index_meta') IS NOT NULL", qs, qs);
    if (SPI_execute(q.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
        bool nul;
        if (DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul)) && !nul) { pfree(q.data); return; }
    }
    resetStringInfo(&q);
    appendStringInfo(&q,
        "CREATE TABLE IF NOT EXISTS %s.fractal_index_meta("
        " name text PRIMARY KEY, tbl text NOT NULL, col text NOT NULL, id_col text NOT NULL, dim int4 NOT NULL, metric text NOT NULL,"
        " format text NOT NULL, nlist int4 NOT NULL, pca_dim int4 NOT NULL, rows int8 NOT NULL, max_id int8 NOT NULL,"
        " model text NOT NULL, seed int8 NOT NULL, generation int4 NOT NULL, format_version int4 NOT NULL,"
        " options jsonb NOT NULL, built_at timestamptz NOT NULL, nprobe_default int4 NOT NULL DEFAULT 0, calib jsonb NOT NULL DEFAULT '{}',"
        " model_blob bytea NOT NULL);"
        "CREATE TABLE IF NOT EXISTS %s.fractal_index_cells("
        " name text NOT NULL, generation int4 NOT NULL, cell int4 NOT NULL, n int4 NOT NULL, ids bytea NOT NULL, codes bytea NOT NULL,"
        " PRIMARY KEY(name, generation, cell))", qs, qs);
    if (SPI_execute(q.data, false, 0) < 0)
        ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot create the index tables in schema %s", schema)));
    pfree(q.data);
}

/* one-row meta read; returns false when the index does not exist. All text fields are copied into the caller's context. */
typedef struct FiMeta {
    char    name[NAMEDATALEN], tbl[NAMEDATALEN], col[NAMEDATALEN], id_col[NAMEDATALEN], model[NAMEDATALEN];
    int     dim, fmt, nlist, pca_dim, generation, nprobe_default;
    int64   rows, max_id;
    char   *options;     /* jsonb as text, palloc'd */
} FiMeta;

/* SPI read-only queries use the snapshot the call started with and so do not see what this call wrote; after a build, refresh or rebuild
 * fractal_index_ensure reads with fi_ro = false (a fresh snapshot per query). */
static bool fi_ro = true;

static bool
fi_read_meta(const char *schema, const char *name, FiMeta *m)
{
    StringInfoData q;
    Datum   args[1];
    Oid     types[1] = { TEXTOID };
    int     rc;
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT tbl,col,id_col,dim,format,nlist,pca_dim,rows,max_id,model,generation,options::text,nprobe_default FROM %s.fractal_index_meta WHERE name = $1",
                     quote_identifier(schema));
    args[0] = CStringGetTextDatum(name);
    rc = SPI_execute_with_args(q.data, 1, types, args, NULL, fi_ro, 1);
    pfree(q.data);
    if (rc != SPI_OK_SELECT || SPI_processed != 1) return false;
    {
        HeapTuple t = SPI_tuptable->vals[0];
        TupleDesc d = SPI_tuptable->tupdesc;
        bool nul;
        memset(m, 0, sizeof *m);
        strlcpy(m->name, name, sizeof m->name);
        strlcpy(m->tbl, SPI_getvalue(t, d, 1), sizeof m->tbl);
        strlcpy(m->col, SPI_getvalue(t, d, 2), sizeof m->col);
        strlcpy(m->id_col, SPI_getvalue(t, d, 3), sizeof m->id_col);
        m->dim = DatumGetInt32(SPI_getbinval(t, d, 4, &nul));
        m->fmt = fi_parse_fmt(SPI_getvalue(t, d, 5));
        m->nlist = DatumGetInt32(SPI_getbinval(t, d, 6, &nul));
        m->pca_dim = DatumGetInt32(SPI_getbinval(t, d, 7, &nul));
        m->rows = DatumGetInt64(SPI_getbinval(t, d, 8, &nul));
        m->max_id = DatumGetInt64(SPI_getbinval(t, d, 9, &nul));
        strlcpy(m->model, SPI_getvalue(t, d, 10), sizeof m->model);
        m->generation = DatumGetInt32(SPI_getbinval(t, d, 11, &nul));
        m->options = pstrdup(SPI_getvalue(t, d, 12));
        m->nprobe_default = DatumGetInt32(SPI_getbinval(t, d, 13, &nul));
    }
    return m->fmt >= 0;
}

static bool
fi_find_name(const char *schema, const char *tbl, const char *col, char *out, size_t cap)
{
    StringInfoData q;
    Datum   args[2];
    Oid     types[2] = { TEXTOID, TEXTOID };
    int     rc;
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT name FROM %s.fractal_index_meta WHERE tbl = $1 AND col = $2 ORDER BY name LIMIT 1", quote_identifier(schema));
    args[0] = CStringGetTextDatum(tbl); args[1] = CStringGetTextDatum(col);
    rc = SPI_execute_with_args(q.data, 2, types, args, NULL, fi_ro, 1);
    pfree(q.data);
    if (rc != SPI_OK_SELECT || SPI_processed != 1) return false;
    strlcpy(out, SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1), cap);
    return true;
}

/* load the current generation into the resident cache (reloaded when the generation pointer moves) */
static FIdx *
fi_load(const char *schema, const char *name)
{
    FiMeta  m;
    FIdx   *slot = NULL;
    StringInfoData q;
    Datum   args[2];
    Oid     types[2] = { TEXTOID, INT4OID };
    int     rc, cells = 0;
    int64   total = 0;
    fsql_ivf_info_t info;
    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));

    if (!fi_read_meta(schema, name, &m))
        ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
    for (int i = 0; i < g_ncache; i++)
        if (strcmp(g_cache[i].name, name) == 0) {
            if (g_cache[i].loaded && g_cache[i].generation == m.generation) { g_cache[i].nprobe_default = m.nprobe_default; return &g_cache[i]; }
            fi_release(&g_cache[i]);
            slot = &g_cache[i];
            break;
        }
    if (slot == NULL) {
        for (int i = 0; i < g_ncache && slot == NULL; i++) if (g_cache[i].name[0] == '\0') slot = &g_cache[i];
        if (slot == NULL) {
            if (g_ncache >= FI_MAX_CACHED)
                ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("fractalsql: too many resident indexes (limit %d)", FI_MAX_CACHED)));
            slot = &g_cache[g_ncache++];
        }
    }
    memset(slot, 0, sizeof *slot);
    strlcpy(slot->name, name, sizeof slot->name);
    slot->dim = m.dim; slot->fmt = m.fmt; slot->nlist = m.nlist; slot->pca_dim = m.pca_dim; slot->generation = m.generation;
    slot->nprobe_default = m.nprobe_default; slot->rows = m.rows; slot->max_id = m.max_id;

    initStringInfo(&q);
    appendStringInfo(&q, "SELECT model_blob FROM %s.fractal_index_meta WHERE name = $1", quote_identifier(schema));
    args[0] = CStringGetTextDatum(name);
    rc = SPI_execute_with_args(q.data, 1, types, args, NULL, true, 1);
    if (rc == SPI_OK_SELECT && SPI_processed == 1) {
        bool nul;
        Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul);
        if (!nul) {
            bytea *b = DatumGetByteaPP(d);
            int mrc = 0;
            slot->m = fsql_ivf_model_load((const uint8_t *) VARDATA_ANY(b), (size_t) VARSIZE_ANY_EXHDR(b), &mrc);
        }
    }
    if (slot->m == NULL || fsql_ivf_model_info(slot->m, &info) != FSQL_OK || (int) info.dim != slot->dim || (int) info.nlist != slot->nlist ||
        (int) info.format != slot->fmt) {
        fi_release(slot);
        ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" has a missing or corrupt model; rebuild it", name)));
    }
    slot->x = fsql_ivf_index_new(slot->m);
    if (slot->x == NULL) { fi_release(slot); ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY), errmsg("fractalsql: out of memory loading index \"%s\"", name))); }

    resetStringInfo(&q);
    appendStringInfo(&q, "SELECT cell, n, ids, codes FROM %s.fractal_index_cells WHERE name = $1 AND generation = $2 ORDER BY cell", quote_identifier(schema));
    args[0] = CStringGetTextDatum(name); args[1] = Int32GetDatum(slot->generation);
    rc = SPI_execute_with_args(q.data, 2, types, args, NULL, true, 0);
    if (rc != SPI_OK_SELECT) { fi_release(slot); ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read the cells of index \"%s\"", name))); }
    for (uint64 r = 0; r < SPI_processed; r++) {
        HeapTuple t = SPI_tuptable->vals[r];
        TupleDesc d = SPI_tuptable->tupdesc;
        bool nul_c, nul_n, nul_ib, nul_cb;
        Datum d_c = SPI_getbinval(t, d, 1, &nul_c);
        Datum d_n = SPI_getbinval(t, d, 2, &nul_n);
        Datum d_ib = SPI_getbinval(t, d, 3, &nul_ib);
        Datum d_cb = SPI_getbinval(t, d, 4, &nul_cb);
        int32 c = nul_c ? -1 : DatumGetInt32(d_c);
        int32 n = nul_n ? -1 : DatumGetInt32(d_n);
        /* A NULL blob is a corrupt cell, not a zero-length one: detoasting a NULL datum would
         * dereference address 0, so the flag is checked before the pointer is built. */
        bytea *ib = nul_ib ? NULL : DatumGetByteaPP(d_ib);
        bytea *cb = nul_cb ? NULL : DatumGetByteaPP(d_cb);
        int64 *ids;
        if (c < 0 || c >= slot->nlist || n < 0 || ib == NULL || cb == NULL ||
            (int64) VARSIZE_ANY_EXHDR(ib) != (int64) n * 8 ||
            (int64) VARSIZE_ANY_EXHDR(cb) != (int64) n * (int64) info.code_bytes) {
            fi_release(slot);
            ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" is corrupt (cell %d)", name, c)));
        }
        ids = (int64 *) palloc((Size) (n > 0 ? n : 1) * sizeof(int64));
        for (int32 j = 0; j < n; j++) ids[j] = get_le64((const uint8_t *) VARDATA_ANY(ib) + (size_t) j * 8);
        if (fsql_ivf_index_set_cell(slot->x, (uint32_t) c, ids, (const uint8_t *) VARDATA_ANY(cb), (size_t) n) != FSQL_OK) {
            fi_release(slot);
            ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY), errmsg("fractalsql: out of memory loading index \"%s\"", name)));
        }
        pfree(ids);
        cells++; total += n;
    }
    if (cells != slot->nlist || total != slot->rows) {
        fi_release(slot);
        ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" is incomplete (%d of %d cells)", name, cells, m.nlist)));
    }
    slot->loaded = 1;
    return slot;
}

/* ------------------------------------------------------------------ reading the base table */

typedef struct FiRow {
    int64  id;
    float *vec;     /* palloc'd, dim floats */
} FiRow;

/* the vector column's type: float8[] or fractal_vector; returns the number of components of one datum into out (floats, palloc'd) */
static Oid
fi_fvec_oid(void)
{
    static Oid cached = InvalidOid;
    if (!OidIsValid(cached)) cached = TypenameGetTypid("fractal_vector");
    return cached;
}

static float *
fi_datum_to_floats(Datum d, Oid typ, int *dim_out)
{
    float *out;
    if (typ == fi_fvec_oid()) {
        FractalVector *fv = DatumGetFractalVectorP(d);
        out = (float *) palloc((Size) fv->dim * sizeof(float));
        memcpy(out, fv->x, (size_t) fv->dim * sizeof(float));
        *dim_out = fv->dim;
    } else {
        ArrayType *arr = DatumGetArrayTypeP(d);
        Datum *ds; bool *ns; int n;
        if (ARR_NDIM(arr) != 1) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: the vector column must hold one-dimensional arrays")));
        deconstruct_array(arr, FLOAT8OID, 8, FLOAT8PASSBYVAL, 'd', &ds, &ns, &n);
        out = (float *) palloc((Size) (n > 0 ? n : 1) * sizeof(float));
        for (int i = 0; i < n; i++) {
            double v;
            if (ns[i]) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: a NULL component in a vector")));
            v = DatumGetFloat8(ds[i]);
            if (!isfinite(v) || fabs(v) > 3.0e38) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: a non-finite or out-of-range vector component")));
            out[i] = (float) v;
        }
        *dim_out = n;
    }
    return out;
}

static void
fi_check_identifiers(const char *tbl, const char *col, const char *id_col)
{
    require_fits(tbl, "table name"); require_fits(col, "column name"); require_fits(id_col, "id column name");
}

/* ------------------------------------------------------------------ build */

typedef struct FiRowset { int64 *ids; float *vec; size_t n, cap; int dim; } FiRowset;

/* Reads every non-NULL (id, vector) row ordered by id into one rowset (floats; the core normalises). */
static void
fi_read_rows(const char *tbl, const char *col, const char *id_col, FiRowset *rs)
{
    StringInfoData q;
    int rc;
    Oid vt, it;
    memset(rs, 0, sizeof *rs);
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT %s, %s FROM %s WHERE %s IS NOT NULL ORDER BY %s", quote_identifier(id_col), quote_identifier(col), quote_identifier(tbl),
                     quote_identifier(col), quote_identifier(id_col));
    rc = SPI_execute(q.data, true, 0);
    if (rc != SPI_OK_SELECT) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read %s.%s", tbl, col)));
    vt = SPI_gettypeid(SPI_tuptable->tupdesc, 2); it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
    if (vt != FLOAT8ARRAYOID && vt != fi_fvec_oid())
        ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s vector_col must be float8[] or fractal_vector, got %s", tbl, col, format_type_be(vt))));
    if (it != INT2OID && it != INT4OID && it != INT8OID)
        ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s id_col must be smallint, integer or bigint, got %s", tbl, id_col, format_type_be(it))));
    rs->n = SPI_processed;
    if (rs->n == 0) ereport(ERROR, (errcode(ERRCODE_NO_DATA_FOUND), errmsg("fractalsql: %s.%s has no vectors to index", tbl, col)));
    rs->ids = (int64 *) MemoryContextAllocHuge(CurrentMemoryContext, rs->n * sizeof(int64));
    for (uint64 r = 0; r < rs->n; r++) {
        bool nul; int d;
        Datum idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul);
        Datum vd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul);
        float *f;
        if (nul) continue;
        rs->ids[r] = it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd));
        f = fi_datum_to_floats(vd, vt, &d);
        if (d < 1 || d > FI_MAXDIM) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: vector dimension %d at id %lld is outside 1..%d", d, (long long) rs->ids[r], FI_MAXDIM)));
        if (rs->dim == 0) {
            size_t bytes = rs->n * (size_t) d * sizeof(float);
            if (bytes > FI_MAX_BYTES) ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("fractalsql: the table is too large to index in one build (over %zu MiB of vectors)", FI_MAX_BYTES >> 20)));
            rs->dim = d;
            rs->vec = (float *) MemoryContextAllocHuge(CurrentMemoryContext, bytes);
        }
        if (d != rs->dim) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: vector dimension %d at id %lld differs from %d", d, (long long) rs->ids[r], rs->dim)));
        memcpy(rs->vec + (size_t) r * (size_t) d, f, (size_t) d * sizeof(float));
        pfree(f);
    }
}

static Jsonb *
fi_build(const char *schema, const char *name, const char *tbl, const char *col, const char *id_col, Jsonb *opts, const char *opts_text, bool is_rebuild)
{
    FiMeta prev;
    bool had;
    char *fmtname = opt_text(opts, "vector_format");
    int fmt = fi_parse_fmt(fmtname ? fmtname : "INT8");
    double nlist_d = opt_num(opts, "nlist", 0), iters_d = opt_num(opts, "iters", 0), sample_d = opt_num(opts, "sample", 0), pca_d = opt_num(opts, "pca_dim", 0), seed_d = opt_num(opts, "seed", 1);
    char *model = opt_text(opts, "model");
    uint64 seed;
    FiRowset rs;
    fsql_ivf_options_t o;
    fsql_ivf_trainer *t;
    uint8_t *blob = NULL;
    size_t blen = 0;
    int rc = 0, generation;
    fsql_ivf_model *m;
    fsql_ivf_info_t info;
    StringInfoData out;
    uint32_t *cell; uint8_t *codes; size_t *ccount;
    double calibrated_nprobe = 0; char *calib_json = NULL; bool calib_ok = false;
    Datum args[18];
    Oid types[18];
    int64 max_id = 0;

    if (fmt < 0) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: vector_format must be INT8, INT4, FP16 or FP32 (got '%s')", fmtname)));
    if (nlist_d < 0 || nlist_d > 4096 || iters_d < 0 || iters_d > 100 || sample_d < 0 || sample_d > 1000000 || pca_d < 0 || pca_d > FI_MAXDIM || seed_d < 0)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: nlist must be 0..4096, iters 0..100, sample 0..1000000, pca_dim 0..%d, seed >= 0", FI_MAXDIM)));
    seed = (uint64) seed_d; if (seed == 0) seed = 1;
    had = fi_read_meta(schema, name, &prev);
    if (had && !is_rebuild) ereport(ERROR, (errcode(ERRCODE_DUPLICATE_OBJECT), errmsg("fractalsql: index \"%s\" already exists (use fractal_index_rebuild or drop it first)", name)));
    if (!had && is_rebuild) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));

    fi_read_rows(tbl, col, id_col, &rs);
    memset(&o, 0, sizeof o);
    o.struct_size = sizeof o; o.dim = (uint32_t) rs.dim; o.format = (uint32_t) fmt; o.nlist = (uint32_t) nlist_d;
    o.pca_dim = (fmt <= FSQL_IVF_FMT_INT4) ? (uint32_t) pca_d : 0u; o.kmeans_iters = (uint32_t) iters_d; o.sample = (uint32_t) sample_d; o.seed = seed;
    t = fsql_ivf_trainer_new(&o, &rc);
    if (t == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: invalid index options for dimension %d (INT8/INT4 need dimension <= 4096 and pca_dim <= dimension)", rs.dim)));
    for (size_t r = 0; r < rs.n && rc == FSQL_OK; r += 4096) {
        size_t c = rs.n - r < 4096 ? rs.n - r : 4096;
        rc = fsql_ivf_trainer_add(t, rs.vec + r * (size_t) rs.dim, c);
    }
    if (rc == FSQL_OK) rc = fsql_ivf_trainer_finish(t, &blob, &blen);
    fsql_ivf_trainer_free(t);
    if (rc != FSQL_OK) ereport(ERROR, (errcode(rc == FSQL_ERR_OOM ? ERRCODE_OUT_OF_MEMORY : ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: training the index failed (rc=%d)", rc)));
    m = fsql_ivf_model_load(blob, blen, &rc);
    if (m == NULL) { fsql_ivf_free(blob); ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: internal error loading the trained model"))); }
    fsql_ivf_model_info(m, &info);

    cell = (uint32_t *) MemoryContextAllocHuge(CurrentMemoryContext, rs.n * sizeof(uint32_t));
    codes = (uint8_t *) MemoryContextAllocHuge(CurrentMemoryContext, rs.n * (size_t) info.code_bytes + 1);
    ccount = (size_t *) palloc0((Size) info.nlist * sizeof(size_t));
    for (size_t r = 0; r < rs.n; r++) {
        if (fsql_ivf_encode(m, rs.vec + r * (size_t) rs.dim, &cell[r], codes + r * (size_t) info.code_bytes) != FSQL_OK) {
            fsql_ivf_model_free(m); fsql_ivf_free(blob);
            ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: cannot encode the vector at id %lld", (long long) rs.ids[r])));
        }
        ccount[cell[r]]++;
        if (rs.ids[r] > max_id) max_id = rs.ids[r];
    }
    generation = had ? prev.generation + 1 : 1;

    /* write the new generation (one INSERT per cell) inside the caller's transaction */
    {
        StringInfoData q;
        Oid ct[6] = { TEXTOID, INT4OID, INT4OID, INT4OID, BYTEAOID, BYTEAOID };
        fsql_ivf_index *x = fsql_ivf_index_new(m);
        int64 *idbuf = (int64 *) palloc((Size) (rs.n > 0 ? rs.n : 1) * sizeof(int64));
        uint8_t *cellbuf = (uint8_t *) palloc((Size) rs.n * (size_t) info.code_bytes + 1);
        initStringInfo(&q);
        appendStringInfo(&q, "INSERT INTO %s.fractal_index_cells(name,generation,cell,n,ids,codes) VALUES($1,$2,$3,$4,$5,$6)", quote_identifier(schema));
        if (x == NULL) ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY), errmsg("fractalsql: out of memory")));
        for (uint32_t c = 0; c < info.nlist; c++) {
            size_t k = 0;
            bytea *ib, *cb;
            Datum a[6];
            for (size_t r = 0; r < rs.n; r++)
                if (cell[r] == c) { idbuf[k] = rs.ids[r]; memcpy(cellbuf + k * info.code_bytes, codes + r * (size_t) info.code_bytes, info.code_bytes); k++; }
            fsql_ivf_index_set_cell(x, c, idbuf, cellbuf, k);
            ib = (bytea *) palloc(VARHDRSZ + k * 8 + 1); SET_VARSIZE(ib, VARHDRSZ + k * 8);
            for (size_t j = 0; j < k; j++) put_le64((uint8_t *) VARDATA(ib) + j * 8, idbuf[j]);
            cb = (bytea *) palloc(VARHDRSZ + k * info.code_bytes + 1); SET_VARSIZE(cb, VARHDRSZ + k * info.code_bytes);
            memcpy(VARDATA(cb), cellbuf, k * info.code_bytes);
            a[0] = CStringGetTextDatum(name); a[1] = Int32GetDatum(generation); a[2] = Int32GetDatum((int32) c); a[3] = Int32GetDatum((int32) k);
            a[4] = PointerGetDatum(ib); a[5] = PointerGetDatum(cb);
            if (SPI_execute_with_args(q.data, 6, ct, a, NULL, false, 0) != SPI_OK_INSERT)
                ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: writing cell %u failed", c)));
            pfree(ib); pfree(cb);
        }
        /* calibration: sample rows as queries (each left out of its own ground truth), compare with exact search at nprobe 1,2,4..nlist */
        if (opt_num(opts, "calibration_samples", 200) > 0 && opt_num(opts, "target_recall", 0.95) > 0 && rs.n >= 12 && rs.n * (size_t) rs.dim <= FI_CALIB_FLOATS) {
            unsigned samples = (unsigned) opt_num(opts, "calibration_samples", 200);
            double target = opt_num(opts, "target_recall", 0.95);
            const unsigned K = 10;
            float *Xn; uint64 *pos; float *Q; int64 *self, *truth;
            uint32_t np[24]; size_t nnp = 0;
            double mean[24], se[24], lo[24], sc[24]; uint32_t rec = 0; int er = FSQL_ERR_INVALID;
            uint32_t shortlist = (uint32_t) fi_default_rerank(fmt);
            if (target > 1.0) target = 1.0;
            if (samples < 20u) samples = 20u;
            if (samples > 2000u) samples = 2000u;
            if ((size_t) samples > rs.n) samples = (unsigned) rs.n;
            if (shortlist < K + 5u) shortlist = K + 5u;
            Xn = (float *) palloc((Size) rs.n * (size_t) rs.dim * sizeof(float));
            for (size_t r = 0; r < rs.n; r++) fsql_ivf_normalize(rs.vec + r * (size_t) rs.dim, (size_t) rs.dim, Xn + r * (size_t) rs.dim);
            pos = (uint64 *) palloc((Size) samples * sizeof(uint64)); Q = (float *) palloc((Size) samples * (size_t) rs.dim * sizeof(float));
            self = (int64 *) palloc((Size) samples * sizeof(int64)); truth = (int64 *) palloc((Size) samples * K * sizeof(int64));
            rc = fsql_ivf_sample_rows(rs.n, samples, seed, pos);
            for (unsigned i = 0; rc == FSQL_OK && i < samples; i++) {
                size_t nt = 0;
                memcpy(Q + (size_t) i * (size_t) rs.dim, rs.vec + pos[i] * (size_t) rs.dim, (size_t) rs.dim * sizeof(float));
                self[i] = rs.ids[pos[i]];
                rc = fsql_ivf_exact_topk(Xn, rs.ids, rs.n, (size_t) rs.dim, Xn + pos[i] * (size_t) rs.dim, self[i], 1, K, truth + (size_t) i * K, &nt);
                if (rc == FSQL_OK && nt != K) rc = FSQL_ERR_INVALID;
            }
            for (uint32_t v = 1; v < info.nlist && nnp < 22; v *= 2u) np[nnp++] = v;
            np[nnp++] = info.nlist;
            if (rc == FSQL_OK) er = fsql_ivf_estimate_recall(x, Q, self, truth, samples, K, np, nnp, shortlist, target, mean, se, lo, sc, &rec);
            if (er == FSQL_OK || er == 1) {
                StringInfoData cj;
                initStringInfo(&cj);
                appendStringInfo(&cj, "{\"samples\":%u,\"k\":%u,\"target\":%g,\"shortlist\":%u,\"estimates\":[", samples, K, target, shortlist);
                for (size_t a2 = 0; a2 < nnp; a2++)
                    appendStringInfo(&cj, "%s{\"nprobe\":%u,\"recall\":%.4f,\"se\":%.4f,\"ci95_low\":%.4f,\"mean_rows_scanned\":%.0f}", a2 ? "," : "", np[a2], mean[a2], se[a2], lo[a2], sc[a2]);
                appendStringInfo(&cj, "],\"recommended_nprobe\":%u,\"reaches_target\":%s}", rec, er == FSQL_OK ? "true" : "false");
                calib_json = cj.data; calibrated_nprobe = (double) rec; calib_ok = true;
            }
            pfree(Xn); pfree(pos); pfree(Q); pfree(self); pfree(truth);
        }
        fsql_ivf_index_free(x);
        pfree(q.data);
    }

    /* the metadata row (insert or replace) and the removal of older generations */
    {
        StringInfoData q;
        bytea *mb = (bytea *) palloc(VARHDRSZ + blen); SET_VARSIZE(mb, VARHDRSZ + blen); memcpy(VARDATA(mb), blob, blen);
        types[0] = TEXTOID; types[1] = TEXTOID; types[2] = TEXTOID; types[3] = TEXTOID; types[4] = INT4OID; types[5] = TEXTOID; types[6] = INT4OID; types[7] = INT4OID;
        types[8] = INT8OID; types[9] = INT8OID; types[10] = TEXTOID; types[11] = INT8OID; types[12] = INT4OID; types[13] = INT4OID; types[14] = TEXTOID; types[15] = INT4OID;
        types[16] = TEXTOID; types[17] = BYTEAOID;
        args[0] = CStringGetTextDatum(name); args[1] = CStringGetTextDatum(tbl); args[2] = CStringGetTextDatum(col); args[3] = CStringGetTextDatum(id_col);
        args[4] = Int32GetDatum(rs.dim); args[5] = CStringGetTextDatum(FI_FMT_NAME[fmt]); args[6] = Int32GetDatum((int32) info.nlist); args[7] = Int32GetDatum((int32) info.pca_dim);
        args[8] = Int64GetDatum((int64) rs.n); args[9] = Int64GetDatum(max_id); args[10] = CStringGetTextDatum(model ? model : ""); args[11] = Int64GetDatum((int64) seed);
        args[12] = Int32GetDatum(generation); args[13] = Int32GetDatum(FI_FORMAT_VERSION); args[14] = CStringGetTextDatum(opts_text); args[15] = Int32GetDatum((int32) calibrated_nprobe);
        args[16] = CStringGetTextDatum(calib_ok ? calib_json : "{}"); args[17] = PointerGetDatum(mb);
        initStringInfo(&q);
        appendStringInfo(&q,
            "INSERT INTO %s.fractal_index_meta(name,tbl,col,id_col,dim,metric,format,nlist,pca_dim,rows,max_id,model,seed,generation,format_version,options,built_at,nprobe_default,calib,model_blob)"
            " VALUES($1,$2,$3,$4,$5,'cosine',$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb,now(),$16,$17::jsonb,$18)"
            " ON CONFLICT (name) DO UPDATE SET tbl=EXCLUDED.tbl,col=EXCLUDED.col,id_col=EXCLUDED.id_col,dim=EXCLUDED.dim,format=EXCLUDED.format,nlist=EXCLUDED.nlist,pca_dim=EXCLUDED.pca_dim,"
            "rows=EXCLUDED.rows,max_id=EXCLUDED.max_id,model=EXCLUDED.model,seed=EXCLUDED.seed,generation=EXCLUDED.generation,format_version=EXCLUDED.format_version,options=EXCLUDED.options,"
            "built_at=EXCLUDED.built_at,nprobe_default=EXCLUDED.nprobe_default,calib=EXCLUDED.calib,model_blob=EXCLUDED.model_blob", quote_identifier(schema));
        if (SPI_execute_with_args(q.data, 18, types, args, NULL, false, 0) != SPI_OK_INSERT)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: writing the index metadata failed")));
        resetStringInfo(&q);
        appendStringInfo(&q, "DELETE FROM %s.fractal_index_cells WHERE name = $1 AND generation < $2", quote_identifier(schema));
        {
            Oid dt[2] = { TEXTOID, INT4OID }; Datum da[2];
            da[0] = CStringGetTextDatum(name); da[1] = Int32GetDatum(generation);
            SPI_execute_with_args(q.data, 2, dt, da, NULL, false, 0);
        }
        pfree(q.data); pfree(mb);
    }
    fi_forget(name);

    initStringInfo(&out);
    appendStringInfo(&out, "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"id_col\":\"%s\",\"format\":\"%s\",\"dim\":%d,\"rows\":%zu,\"nlist\":%u,\"pca_dim\":%u,\"generation\":%d,\"bytes\":%zu",
                     name, tbl, col, id_col, FI_FMT_NAME[fmt], rs.dim, rs.n, info.nlist, info.pca_dim, generation, rs.n * info.code_bytes);
    if (calib_ok && calibrated_nprobe > 0) appendStringInfo(&out, ",\"calibrated_nprobe\":%d", (int) calibrated_nprobe);
    appendStringInfoChar(&out, '}');
    fsql_ivf_model_free(m); fsql_ivf_free(blob);
    pfree(cell); pfree(codes); pfree(ccount);
    return DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data)));
}

/* ------------------------------------------------------------------ health: what the index's state says about whether to trust it */

/* Thresholds behind the status and the advice in fractal_index_info. They are advice, never an error. */
#define FI_REFRESH_MAX_FRAC   0.25     /* more than this fraction of the rows added since the build: rebuild, do not just refresh */
#define FI_DELETED_MAX_FRAC   0.20     /* more than this fraction deleted: the cells hold many dead entries */

typedef struct FiHealth {
    int64  now, maxnow, added, deleted;
    bool   stale, has_delta, have_calib, reaches_target, missing;
    double target, recall;
} FiHealth;

/* The value of a key in the calibration JSON as jsonb printed it (`"key": value`): a pointer to the value, spaces skipped. */
static const char *
fi_json_key(const char *s, const char *key)
{
    char pat[64];
    const char *p;
    snprintf(pat, sizeof pat, "\"%s\":", key);
    p = strstr(s, pat);
    if (p == NULL) return NULL;
    p += strlen(pat);
    while (*p == ' ') p++;
    return p;
}

static void
fi_calib_facts(const char *calib, FiHealth *h)
{
    const char *r = calib ? fi_json_key(calib, "reaches_target") : NULL;
    const char *t, *rn;
    h->have_calib = r != NULL;
    if (r == NULL) return;
    h->reaches_target = strncmp(r, "true", 4) == 0;
    t = fi_json_key(calib, "target");
    h->target = t ? strtod(t, NULL) : 0.95;
    rn = fi_json_key(calib, "recommended_nprobe");
    if (rn != NULL) {
        long np = strtol(rn, NULL, 10);
        const char *p = calib;
        while ((p = strstr(p, "\"nprobe\":")) != NULL) {
            const char *v = p + 9, *rec;
            while (*v == ' ') v++;
            if (strtol(v, NULL, 10) == np && (rec = fi_json_key(p, "recall")) != NULL) { h->recall = strtod(rec, NULL); break; }
            p += 9;
        }
    }
}

static void
fi_health(const FiMeta *m, const char *calib, FiHealth *h)
{
    StringInfoData q;
    Oid pt[1] = { INT8OID }; Datum pa[1];
    memset(h, 0, sizeof *h);
    h->now = -1;
    initStringInfo(&q);
    /* The catalog outlives the table it indexes: when the table, the vector column or the key column is gone, say so (orphaned) instead of
     * failing the whole call on a query against a relation that does not exist. */
    {
        Oid xt[3] = { TEXTOID, TEXTOID, TEXTOID }; Datum xa[3];
        bool present = false;
        appendStringInfoString(&q, "SELECT count(*) = 2 FROM pg_catalog.pg_attribute a WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped AND a.attname::text IN ($2, $3)");
        xa[0] = CStringGetTextDatum(quote_identifier(m->tbl)); xa[1] = CStringGetTextDatum(m->col); xa[2] = CStringGetTextDatum(m->id_col);
        if (SPI_execute_with_args(q.data, 3, xt, xa, NULL, fi_ro, 1) == SPI_OK_SELECT && SPI_processed == 1) {
            bool nul;
            present = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul)) && !nul;
        }
        if (strcmp(m->col, m->id_col) == 0) present = false;
        if (!present) { h->missing = true; h->deleted = m->rows; fi_calib_facts(calib, h); pfree(q.data); return; }
        resetStringInfo(&q);
    }
    appendStringInfo(&q, "SELECT count(*), coalesce(max(%s),0) FROM %s WHERE %s IS NOT NULL", quote_identifier(m->id_col), quote_identifier(m->tbl), quote_identifier(m->col));
    if (SPI_execute(q.data, fi_ro, 0) == SPI_OK_SELECT && SPI_processed == 1) {
        bool nul;
        h->now = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul));
        h->maxnow = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &nul));
    }
    resetStringInfo(&q);
    appendStringInfo(&q, "SELECT count(*) FROM %s WHERE %s IS NOT NULL AND %s > $1", quote_identifier(m->tbl), quote_identifier(m->col), quote_identifier(m->id_col));
    pa[0] = Int64GetDatum(m->max_id);
    if (SPI_execute_with_args(q.data, 1, pt, pa, NULL, fi_ro, 1) == SPI_OK_SELECT && SPI_processed == 1) {
        bool nul;
        h->added = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul));
    }
    pfree(q.data);
    h->deleted = m->rows - (h->now - h->added);
    if (h->deleted < 0) h->deleted = 0;
    h->has_delta = h->added > 0;
    h->stale = h->now != m->rows || h->maxnow != m->max_id;
    fi_calib_facts(calib, h);
}

/* ready | stale | degraded | empty. "stale" here means there is something to do (rows were added, or many were deleted); the raw "stale"
 * flag in fractal_index_info is true for any change, including a few deleted rows the verify step already drops, which need no action. */
static const char *
fi_status(const FiMeta *m, const FiHealth *h)
{
    double rows = m->rows > 0 ? (double) m->rows : 1.0;
    if (h->missing) return "orphaned";
    if (h->now == 0) return "empty";
    if (h->have_calib && !h->reaches_target) return "degraded";
    if (h->added > 0 || (h->deleted > 0 && (double) h->deleted / rows > FI_DELETED_MAX_FRAC)) return "stale";
    return "ready";
}

/* The advice list as a JSON array body (no brackets): every applicable item, most useful first. */
static void
fi_advice(const FiMeta *m, const FiHealth *h, StringInfo b)
{
    int n = 0;
    double rows = m->rows > 0 ? (double) m->rows : 1.0;
    if (h->missing) { appendStringInfo(b, "\"the table %s or its columns %s and %s no longer exist; fractal_index_drop removes the index\"", m->tbl, m->col, m->id_col); return; }
    if (h->now == 0) { appendStringInfoString(b, "\"the table has no vectors; load rows and build the index again\""); n++; }
    if (h->have_calib && !h->reaches_target) {
        appendStringInfo(b, "%s\"the build's calibration reached recall %.2f against a target of %.2f; %s\"", n++ ? "," : "", h->recall, h->target,
                         (m->fmt == FSQL_IVF_FMT_INT8 || m->fmt == FSQL_IVF_FMT_INT4)
                             ? "rebuild with vector_format FP16 or FP32, or search with a larger rerank"
                             : "rebuild with a smaller nlist, or lower the target");
    }
    if (h->now > 0 && h->added > 0 && (double) h->added / rows > FI_REFRESH_MAX_FRAC)
        appendStringInfo(b, "%s\"rebuild: %.0f%% of the rows (%lld) were added since the build, more than the cells were trained for\"", n++ ? "," : "",
                         100.0 * (double) h->added / rows, (long long) h->added);
    else if (h->added > 0)
        appendStringInfo(b, "%s\"refresh: %lld rows (%.0f%% of the index) were added since the build; fractal_index_refresh folds them in\"", n++ ? "," : "",
                         (long long) h->added, 100.0 * (double) h->added / rows);
    if (h->deleted > 0 && (double) h->deleted / rows > FI_DELETED_MAX_FRAC)
        appendStringInfo(b, "%s\"rebuild: %lld rows (%.0f%%) were deleted since the build; they are dropped from results but still held in the cells\"", n++ ? "," : "",
                         (long long) h->deleted, 100.0 * (double) h->deleted / rows);
}

/* ------------------------------------------------------------------ refresh */

/* Folds the rows added since the build (key above the watermark) into the cells: each new row is encoded with the index's existing model
 * (no retraining) and appended to its cell, in a NEW generation written inside the caller's transaction, so a reader sees either the
 * old or the new generation, never a partial one. Deleted rows and rows whose vector changed in place are not touched: deleted rows are
 * already dropped by the verify step, and a changed vector needs fractal_index_rebuild (fractal_index_info says which it recommends). */
static Jsonb *
fi_refresh(const char *schema, const char *name)
{
    FiMeta m;
    FIdx *x;
    fsql_ivf_info_t info;
    StringInfoData q, out;
    Oid vt, it;
    int64 old_rows, max_id;
    int old_gen, new_gen, nlist, dim;
    size_t n = 0, cap = 0, *add;
    int64 *rowid = NULL;
    uint32_t *cellv = NULL;
    uint8_t *codes = NULL;
    Oid ct1[3] = { TEXTOID, INT4OID, INT4OID };

    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));
    if (!fi_read_meta(schema, name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
    x = fi_load(schema, name);
    if (fsql_ivf_model_info(x->m, &info) != FSQL_OK) ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" has a corrupt model; rebuild it", name)));
    old_rows = m.rows; max_id = m.max_id; old_gen = m.generation; nlist = m.nlist; dim = m.dim;

    initStringInfo(&q);
    appendStringInfo(&q, "SELECT %s, %s FROM %s WHERE %s > $1 AND %s IS NOT NULL ORDER BY %s", quote_identifier(m.id_col), quote_identifier(m.col), quote_identifier(m.tbl),
                     quote_identifier(m.id_col), quote_identifier(m.col), quote_identifier(m.id_col));
    {
        Oid pt[1] = { INT8OID }; Datum pa[1];
        pa[0] = Int64GetDatum(m.max_id);
        if (SPI_execute_with_args(q.data, 1, pt, pa, NULL, true, 0) != SPI_OK_SELECT)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read %s.%s", m.tbl, m.col)));
    }
    vt = SPI_gettypeid(SPI_tuptable->tupdesc, 2); it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
    if (SPI_processed == 0) {
        initStringInfo(&out);
        appendStringInfo(&out, "{\"name\":\"%s\",\"added\":0,\"rows\":%lld,\"generation\":%d,\"refreshed\":false}", name, (long long) old_rows, old_gen);
        return DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data)));
    }
    if (vt != FLOAT8ARRAYOID && vt != fi_fvec_oid())
        ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s vector_col must be float8[] or fractal_vector, got %s", m.tbl, m.col, format_type_be(vt))));
    cap = (size_t) SPI_processed;
    if (cap * (size_t) (8 + 4 + info.code_bytes) + 1 > FI_MAX_BYTES)
        ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("fractalsql: too many new rows to refresh in one call (over %zu MiB); rebuild the index instead", (size_t) (FI_MAX_BYTES >> 20))));
    rowid = (int64 *) MemoryContextAllocHuge(CurrentMemoryContext, cap * sizeof(int64));
    cellv = (uint32_t *) MemoryContextAllocHuge(CurrentMemoryContext, cap * sizeof(uint32_t));
    codes = (uint8_t *) MemoryContextAllocHuge(CurrentMemoryContext, cap * (size_t) info.code_bytes + 1);
    for (uint64 r = 0; r < SPI_processed; r++) {
        bool nul; int d; float *f;
        Datum idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul);
        Datum vd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul);
        int64 id = it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd));
        if (nul) continue;
        f = fi_datum_to_floats(vd, vt, &d);
        if (d != dim) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: vector dimension %d at id %lld differs from the index's %d", d, (long long) id, dim)));
        if (fsql_ivf_encode(x->m, f, &cellv[n], codes + n * (size_t) info.code_bytes) != FSQL_OK)
            ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: cannot encode the vector at id %lld", (long long) id)));
        rowid[n] = id;
        if (id > max_id) max_id = id;
        n++;
        pfree(f);
    }
    if (n == 0) {
        initStringInfo(&out);
        appendStringInfo(&out, "{\"name\":\"%s\",\"added\":0,\"rows\":%lld,\"generation\":%d,\"refreshed\":false}", name, (long long) old_rows, old_gen);
        return DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data)));
    }
    new_gen = old_gen + 1;
    add = (size_t *) palloc0((Size) nlist * sizeof(size_t));
    for (size_t r = 0; r < n; r++) add[cellv[r]]++;

    /* copy the cells to the new generation, then rewrite only the cells that received rows */
    resetStringInfo(&q);
    appendStringInfo(&q, "INSERT INTO %s.fractal_index_cells(name,generation,cell,n,ids,codes) SELECT name,$2,cell,n,ids,codes FROM %s.fractal_index_cells WHERE name = $1 AND generation = $3",
                     quote_identifier(schema), quote_identifier(schema));
    {
        Datum a[3];
        a[0] = CStringGetTextDatum(name); a[1] = Int32GetDatum(new_gen); a[2] = Int32GetDatum(old_gen);
        if (SPI_execute_with_args(q.data, 3, ct1, a, NULL, false, 0) != SPI_OK_INSERT)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: copying the cells of index \"%s\" failed", name)));
    }
    for (int c = 0; c < nlist; c++) {
        Oid rt[3] = { TEXTOID, INT4OID, INT4OID }, ut[6] = { TEXTOID, INT4OID, INT4OID, INT4OID, BYTEAOID, BYTEAOID };
        Datum ra[3], ua[6];
        int64 n0;
        bytea *ib, *cb, *nib, *ncb;
        bool nul_n, nul_i, nul_c;
        size_t nn, k, ibytes, cbytes;
        if (add[c] == 0) continue;
        resetStringInfo(&q);
        appendStringInfo(&q, "SELECT n, ids, codes FROM %s.fractal_index_cells WHERE name = $1 AND generation = $2 AND cell = $3", quote_identifier(schema));
        ra[0] = CStringGetTextDatum(name); ra[1] = Int32GetDatum(new_gen); ra[2] = Int32GetDatum(c);
        if (SPI_execute_with_args(q.data, 3, rt, ra, NULL, false, 1) != SPI_OK_SELECT || SPI_processed != 1)   /* read_only false: see the rows the copy just wrote */
            ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" is missing cell %d", name, c)));
        n0 = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul_n));
        {
            Datum di = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &nul_i), dc = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &nul_c);
            if (nul_n || nul_i || nul_c) ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" is corrupt (cell %d)", name, c)));
            ib = DatumGetByteaPP(di); cb = DatumGetByteaPP(dc);
        }
        if (n0 < 0 || (int64) VARSIZE_ANY_EXHDR(ib) != n0 * 8 || (int64) VARSIZE_ANY_EXHDR(cb) != n0 * (int64) info.code_bytes)
            ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("fractalsql: index \"%s\" is corrupt (cell %d)", name, c)));
        nn = (size_t) n0 + add[c];
        ibytes = nn * 8; cbytes = nn * (size_t) info.code_bytes;
        nib = (bytea *) palloc(VARHDRSZ + ibytes + 1); SET_VARSIZE(nib, VARHDRSZ + ibytes);
        ncb = (bytea *) palloc(VARHDRSZ + cbytes + 1); SET_VARSIZE(ncb, VARHDRSZ + cbytes);
        memcpy(VARDATA(nib), VARDATA_ANY(ib), (size_t) n0 * 8);
        memcpy(VARDATA(ncb), VARDATA_ANY(cb), (size_t) n0 * (size_t) info.code_bytes);
        k = (size_t) n0;
        for (size_t r = 0; r < n; r++)
            if (cellv[r] == (uint32_t) c) { put_le64((uint8_t *) VARDATA(nib) + k * 8, rowid[r]); memcpy((uint8_t *) VARDATA(ncb) + k * (size_t) info.code_bytes, codes + r * (size_t) info.code_bytes, info.code_bytes); k++; }
        resetStringInfo(&q);
        appendStringInfo(&q, "UPDATE %s.fractal_index_cells SET n = $4, ids = $5, codes = $6 WHERE name = $1 AND generation = $2 AND cell = $3", quote_identifier(schema));
        ua[0] = CStringGetTextDatum(name); ua[1] = Int32GetDatum(new_gen); ua[2] = Int32GetDatum(c); ua[3] = Int32GetDatum((int32) nn); ua[4] = PointerGetDatum(nib); ua[5] = PointerGetDatum(ncb);
        if (SPI_execute_with_args(q.data, 6, ut, ua, NULL, false, 0) != SPI_OK_UPDATE)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: writing cell %d failed", c)));
        pfree(nib); pfree(ncb);
    }
    {
        Oid mt[4] = { TEXTOID, INT8OID, INT8OID, INT4OID }; Datum ma[4];
        resetStringInfo(&q);
        appendStringInfo(&q, "UPDATE %s.fractal_index_meta SET rows = $2, max_id = $3, generation = $4 WHERE name = $1", quote_identifier(schema));
        ma[0] = CStringGetTextDatum(name); ma[1] = Int64GetDatum(old_rows + (int64) n); ma[2] = Int64GetDatum(max_id); ma[3] = Int32GetDatum(new_gen);
        if (SPI_execute_with_args(q.data, 4, mt, ma, NULL, false, 0) != SPI_OK_UPDATE)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: writing the index metadata failed")));
        resetStringInfo(&q);
        appendStringInfo(&q, "DELETE FROM %s.fractal_index_cells WHERE name = $1 AND generation < $2", quote_identifier(schema));
        {
            Oid dt[2] = { TEXTOID, INT4OID }; Datum da[2];
            da[0] = CStringGetTextDatum(name); da[1] = Int32GetDatum(new_gen);
            SPI_execute_with_args(q.data, 2, dt, da, NULL, false, 0);
        }
    }
    fi_forget(name);
    initStringInfo(&out);
    appendStringInfo(&out, "{\"name\":\"%s\",\"added\":%zu,\"rows\":%lld,\"generation\":%d,\"max_id\":%lld,\"refreshed\":true}",
                     name, n, (long long) (old_rows + (int64) n), new_gen, (long long) max_id);
    pfree(q.data); pfree(add);
    return DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data)));
}

/* ------------------------------------------------------------------ SQL functions */

static void
fi_spi_begin(void)
{
    if (SPI_connect() != SPI_OK_CONNECT) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: SPI_connect failed")));
}

/* copy a jsonb result out of the SPI memory context before SPI_finish */
static Jsonb *
fi_keep(Jsonb *j, MemoryContext to)
{
    MemoryContext old = MemoryContextSwitchTo(to);
    Jsonb *c = (Jsonb *) palloc(VARSIZE(j));
    memcpy(c, j, VARSIZE(j));
    MemoryContextSwitchTo(old);
    return c;
}

Datum
fractal_index_create(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 2, "fractal_index_create");
    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));
    char *tbl = text_to_cstring(PG_GETARG_TEXT_PP(0)), *col = text_to_cstring(PG_GETARG_TEXT_PP(1));
    Jsonb *opts = arg_options(fcinfo, 2);
    char *schema, *idc, *name, *opts_text;
    MemoryContext caller = CurrentMemoryContext;
    Jsonb *res;
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    idc = opts ? opt_text(opts, "id_col") : NULL;
    if (idc == NULL) idc = pstrdup("id");
    name = opts ? opt_text(opts, "name") : NULL;
    if (name == NULL) { StringInfoData n; initStringInfo(&n); appendStringInfo(&n, "%.28s_%.28s", tbl, col); name = n.data; }
    fi_check_identifiers(tbl, col, idc); require_fits(name, "index name");
    opts_text = opts ? JsonbToCString(NULL, &opts->root, VARSIZE(opts)) : pstrdup("{}");
    fi_ensure_tables(schema);
    res = fi_keep(fi_build(schema, name, tbl, col, idc, opts, opts_text, false), caller);
    SPI_finish();
    PG_RETURN_JSONB_P(res);
}

Datum
fractal_index_rebuild(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 1, "fractal_index_rebuild");
    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));
    char *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
    char *schema; FiMeta m;
    MemoryContext caller = CurrentMemoryContext;
    Jsonb *opts, *res;
    require_fits(name, "index name");
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    if (!fi_read_meta(schema, name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
    opts = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(m.options)));
    res = fi_keep(fi_build(schema, name, m.tbl, m.col, m.id_col, opts, m.options, true), caller);
    SPI_finish();
    PG_RETURN_JSONB_P(res);
}

Datum
fractal_index_drop(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 1, "fractal_index_drop");
    char *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
    char *schema; FiMeta m;
    StringInfoData q;
    Oid types[1] = { TEXTOID }; Datum args[1];
    require_fits(name, "index name");
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    if (!fi_read_meta(schema, name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
    args[0] = CStringGetTextDatum(name);
    initStringInfo(&q);
    appendStringInfo(&q, "DELETE FROM %s.fractal_index_cells WHERE name = $1", quote_identifier(schema));
    SPI_execute_with_args(q.data, 1, types, args, NULL, false, 0);
    resetStringInfo(&q);
    appendStringInfo(&q, "DELETE FROM %s.fractal_index_meta WHERE name = $1", quote_identifier(schema));
    SPI_execute_with_args(q.data, 1, types, args, NULL, false, 0);
    fi_forget(name);
    SPI_finish();
    PG_RETURN_BOOL(true);
}

Datum
fractal_index_refresh(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 1, "fractal_index_refresh");
    char *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
    char *schema;
    MemoryContext caller = CurrentMemoryContext;
    Jsonb *res;
    require_fits(name, "index name");
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    res = fi_keep(fi_refresh(schema, name), caller);
    SPI_finish();
    PG_RETURN_JSONB_P(res);
}

/* The calibration JSON of an index as text ("{}" when none). Call inside SPI. */
static char *
fi_calib_text(const char *schema, const char *name)
{
    StringInfoData q;
    Oid types[1] = { TEXTOID }; Datum args[1];
    char *out = pstrdup("{}");
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT calib::text FROM %s.fractal_index_meta WHERE name = $1", quote_identifier(schema));
    args[0] = CStringGetTextDatum(name);
    if (SPI_execute_with_args(q.data, 1, types, args, NULL, fi_ro, 1) == SPI_OK_SELECT && SPI_processed == 1) {
        char *v = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
        if (v) out = pstrdup(v);
    }
    pfree(q.data);
    return out;
}

/* fractal_index_ensure(table, column [, options]) -> {name, action, status, generation, rows}.
 * Leaves the index on that table and column fit to use: builds it when missing (created), folds in the added rows when that is all
 * that is needed (refreshed), rebuilds after a large change (rebuilt) and otherwise changes nothing (unchanged). */
Datum
fractal_index_ensure(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 2, "fractal_index_ensure");
    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));
    fi_ro = true;
    char *tbl = text_to_cstring(PG_GETARG_TEXT_PP(0)), *col = text_to_cstring(PG_GETARG_TEXT_PP(1));
    Jsonb *opts = arg_options(fcinfo, 2);
    char *schema, *idc, *opts_text, name[NAMEDATALEN] = "";
    const char *action = "unchanged";
    bool have_opts;
    FiMeta m; FiHealth h;
    MemoryContext caller = CurrentMemoryContext;
    StringInfoData out;
    Jsonb *res;
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    idc = opts ? opt_text(opts, "id_col") : NULL;
    if (idc == NULL) idc = pstrdup("id");
    fi_check_identifiers(tbl, col, idc);
    opts_text = opts ? JsonbToCString(NULL, &opts->root, VARSIZE(opts)) : pstrdup("{}");
    have_opts = opts != NULL && strcmp(opts_text, "{}") != 0;
    fi_ensure_tables(schema);
    if (!fi_find_name(schema, tbl, col, name, sizeof name)) {
        char *nm = opts ? opt_text(opts, "name") : NULL;
        if (nm == NULL) { StringInfoData n; initStringInfo(&n); appendStringInfo(&n, "%.28s_%.28s", tbl, col); nm = n.data; }
        require_fits(nm, "index name");
        (void) fi_build(schema, nm, tbl, col, idc, opts, opts_text, false);
        strlcpy(name, nm, sizeof name);
        action = "created";
    } else {
        const char *st;
        char *calib;
        if (!fi_read_meta(schema, name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
        calib = fi_calib_text(schema, name);
        fi_health(&m, calib, &h);
        st = fi_status(&m, &h);
        if (strcmp(st, "degraded") == 0) {
            if (have_opts) {
                (void) fi_build(schema, name, m.tbl, m.col, m.id_col, opts, opts_text, true);
                action = "rebuilt";
            }
        } else if (strcmp(st, "stale") == 0) {
            double rows = m.rows > 0 ? (double) m.rows : 1.0;
            if ((double) h.added / rows > FI_REFRESH_MAX_FRAC || (double) h.deleted / rows > FI_DELETED_MAX_FRAC) {
                Jsonb *o2 = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(m.options)));
                (void) fi_build(schema, name, m.tbl, m.col, m.id_col, o2, m.options, true);
                action = "rebuilt";
            } else if (h.added > 0) {
                (void) fi_refresh(schema, name);
                action = "refreshed";
            }
        }
    }
    fi_ro = false;   /* see what this call wrote */
    if (!fi_read_meta(schema, name, &m)) { fi_ro = true; ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name))); }
    fi_health(&m, fi_calib_text(schema, name), &h);
    fi_ro = true;
    initStringInfo(&out);
    appendStringInfo(&out, "{\"name\":\"%s\",\"action\":\"%s\",\"status\":\"%s\",\"generation\":%d,\"rows\":%lld}", m.name, action, fi_status(&m, &h), m.generation, (long long) m.rows);
    res = fi_keep(DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data))), caller);
    SPI_finish();
    PG_RETURN_JSONB_P(res);
}

extern bool fsql_index_agent_topk(FunctionCallInfo fcinfo, const char *tbl, const char *col, const double *q, int dim, int k, const char *where_sql,
                                  int mode, int64 min_rows, char ***ctids_out, int *n_out);

/* For the agents (called with no SPI connection open): the rows nearest the query through the index on tbl.col, as ctid strings
 * (best first), or false when the agents should scan instead. mode is 1 (on) or 2 (auto: only a ready index on a table of at least
 * min_rows rows). where_sql, when set, restricts the search to the rows it selects. The result is allocated in the caller's context. */
bool
fsql_index_agent_topk(FunctionCallInfo fcinfo, const char *tbl, const char *col, const double *q, int dim, int k, const char *where_sql,
                      int mode, int64 min_rows, char ***ctids_out, int *n_out)
{
    char *schema, name[NAMEDATALEN] = "";
    FiMeta m;
    MemoryContext caller = CurrentMemoryContext;
    StringInfoData sq;
    bool used = false;
    *ctids_out = NULL; *n_out = 0;
    if (!fi_ivf_available()) return false;
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    {
        StringInfoData t; bool ok = false;
        initStringInfo(&t);
        appendStringInfo(&t, "SELECT to_regclass('%s.fractal_index_meta') IS NOT NULL", quote_identifier(schema));
        if (SPI_execute(t.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
            bool nul;
            ok = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul)) && !nul;
        }
        if (!ok || !fi_find_name(schema, tbl, col, name, sizeof name) || !fi_read_meta(schema, name, &m)) { SPI_finish(); return false; }
    }
    if (mode == 2) {
        FiHealth h;
        fi_health(&m, fi_calib_text(schema, name), &h);
        if (strcmp(fi_status(&m, &h), "ready") != 0 || h.now < min_rows) { SPI_finish(); return false; }
    }
    initStringInfo(&sq);
    if (where_sql != NULL) {
        /* a restricted search passes the matching keys as the ids option; too many keys and a scan is the better path */
        StringInfoData c; int64 n = 0;
        initStringInfo(&c);
        appendStringInfo(&c, "SELECT count(*) FROM (SELECT 1 FROM %s t WHERE %s LIMIT 100001) x", quote_identifier(tbl), where_sql);
        if (SPI_execute(c.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
            bool nul;
            n = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul));
        }
        if (n == 0 || n > 100000) { SPI_finish(); return false; }
        appendStringInfo(&sq,
            "SELECT t.ctid::text FROM %s.fractal_search($1, $2, $3, $4, jsonb_build_object('ids', (SELECT jsonb_agg(w.%s) FROM %s w WHERE %s))) s "
            "JOIN %s t ON t.%s = s.doc_id::bigint ORDER BY s.distance",
            quote_identifier(schema), quote_identifier(m.id_col), quote_identifier(tbl), where_sql, quote_identifier(tbl), quote_identifier(m.id_col));
    } else {
        appendStringInfo(&sq,
            "SELECT t.ctid::text FROM %s.fractal_search($1, $2, $3, $4) s JOIN %s t ON t.%s = s.doc_id::bigint ORDER BY s.distance",
            quote_identifier(schema), quote_identifier(tbl), quote_identifier(m.id_col));
    }
    {
        Oid types[4] = { TEXTOID, TEXTOID, FLOAT8ARRAYOID, INT4OID }; Datum args[4];
        Datum *qd = (Datum *) palloc(sizeof(Datum) * (size_t) dim);
        int rc;
        for (int i = 0; i < dim; i++) qd[i] = Float8GetDatum(q[i]);
        args[0] = CStringGetTextDatum(tbl); args[1] = CStringGetTextDatum(col);
        args[2] = PointerGetDatum(construct_array(qd, dim, FLOAT8OID, sizeof(float8), FLOAT8PASSBYVAL, 'd'));
        args[3] = Int32GetDatum(k);
        rc = SPI_execute_with_args(sq.data, 4, types, args, NULL, true, 0);
        if (rc == SPI_OK_SELECT && SPI_processed > 0) {
            uint64 n = SPI_processed;
            MemoryContext old = MemoryContextSwitchTo(caller);
            char **out = (char **) palloc(sizeof(char *) * (size_t) n);
            for (uint64 i = 0; i < n; i++) out[i] = pstrdup(SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1));
            MemoryContextSwitchTo(old);
            *ctids_out = out; *n_out = (int) n; used = true;
        }
    }
    SPI_finish();
    return used;
}

/* fractal_index_list() -> one row per index. Reads the catalog without creating it: a database that never built an index lists nothing. */
Datum
fractal_index_list(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    MemoryContext per_query_ctx, oldcontext;
    TupleDesc tupdesc;
    Tuplestorestate *tupstore;
    char *schema;
    StringInfoData q;
    int ni = 0;
    char **names, **calibs;
    if (rsinfo == NULL || !(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("fractalsql: set-valued function called in context that cannot accept a set")));
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("fractalsql: function returning record called in context that cannot accept type record")));
    tupdesc = BlessTupleDesc(tupdesc);
    tupstore = tuplestore_begin_heap(false, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize; rsinfo->setResult = tupstore; rsinfo->setDesc = tupdesc;
    MemoryContextSwitchTo(oldcontext);

    fi_spi_begin();
    schema = fi_schema(fcinfo);
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT to_regclass('%s.fractal_index_meta') IS NOT NULL", quote_identifier(schema));
    {
        bool have = false;
        if (SPI_execute(q.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
            bool nul;
            have = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul)) && !nul;
        }
        if (!have) { SPI_finish(); return (Datum) 0; }
    }
    resetStringInfo(&q);
    appendStringInfo(&q, "SELECT name, calib::text FROM %s.fractal_index_meta ORDER BY name", quote_identifier(schema));
    if (SPI_execute(q.data, true, 0) != SPI_OK_SELECT) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read the index catalog")));
    ni = (int) SPI_processed;
    names = (char **) palloc((Size) (ni > 0 ? ni : 1) * sizeof(char *)); calibs = (char **) palloc((Size) (ni > 0 ? ni : 1) * sizeof(char *));
    for (int i = 0; i < ni; i++) {   /* the next SPI call replaces SPI_tuptable, so copy what the loop needs first */
        names[i] = pstrdup(SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1));
        calibs[i] = pstrdup(SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 2));
    }
    for (int i = 0; i < ni; i++) {
        FiMeta m; FiHealth h;
        Datum values[10]; bool nulls[10] = { false, false, false, false, false, false, false, false, false, false };
        MemoryContext old;
        if (!fi_read_meta(schema, names[i], &m)) continue;
        fi_health(&m, calibs[i], &h);
        old = MemoryContextSwitchTo(per_query_ctx);
        values[0] = CStringGetTextDatum(m.name); values[1] = CStringGetTextDatum(m.tbl); values[2] = CStringGetTextDatum(m.col);
        values[3] = CStringGetTextDatum(FI_FMT_NAME[m.fmt]); values[4] = Int32GetDatum(m.dim); values[5] = Int64GetDatum(m.rows); values[6] = Int64GetDatum(h.now);
        values[7] = BoolGetDatum(h.stale); values[8] = CStringGetTextDatum(fi_status(&m, &h)); values[9] = Int32GetDatum(m.generation);
        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
        MemoryContextSwitchTo(old);
    }
    SPI_finish();
    return (Datum) 0;
}

Datum
fractal_index_info(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 1, "fractal_index_info");
    char *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
    char *schema; FiMeta m;
    StringInfoData q, out, adv;
    char *built = pstrdup(""), *calib = pstrdup("{}");
    int fv = 0; int64 seed = 0;
    FiHealth h;
    MemoryContext caller = CurrentMemoryContext;
    Jsonb *res;
    Oid types[1] = { TEXTOID }; Datum args[1];
    require_fits(name, "index name");
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    if (!fi_read_meta(schema, name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", name)));
    initStringInfo(&q);
    appendStringInfo(&q, "SELECT built_at::text, format_version, seed, calib::text FROM %s.fractal_index_meta WHERE name = $1", quote_identifier(schema));
    args[0] = CStringGetTextDatum(name);
    if (SPI_execute_with_args(q.data, 1, types, args, NULL, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
        bool nul;
        built = pstrdup(SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1));
        fv = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &nul));
        seed = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &nul));
        calib = pstrdup(SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4));
    }
    fi_health(&m, calib, &h);
    initStringInfo(&adv);
    fi_advice(&m, &h, &adv);
    initStringInfo(&out);
    appendStringInfo(&out,
        "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"id_col\":\"%s\",\"metric\":\"cosine\",\"format\":\"%s\",\"dim\":%d,\"model\":\"%s\",\"nlist\":%d,\"pca_dim\":%d,\"generation\":%d,"
        "\"format_version\":%d,\"seed\":%lld,\"built_at\":\"%s\",\"rows_indexed\":%lld,\"rows_now\":%lld,\"max_id_indexed\":%lld,\"max_id_now\":%lld,"
        "\"has_delta\":%s,\"stale\":%s,\"rows_added_since_build\":%lld,\"rows_deleted_since_build\":%lld,\"status\":\"%s\",\"advice\":[%s],"
        "\"rerank_default\":%zu,\"nprobe_default\":%d,\"calibration\":%s,"
        "\"last_search\":{\"used_index\":%s,\"rows_scanned\":%lld,\"cells_probed\":%d,\"lookups\":%d}}",
        m.name, m.tbl, m.col, m.id_col, FI_FMT_NAME[m.fmt], m.dim, m.model, m.nlist, m.pca_dim, m.generation, fv, (long long) seed, built,
        (long long) m.rows, (long long) h.now, (long long) m.max_id, (long long) h.maxnow, h.has_delta ? "true" : "false",
        h.stale ? "true" : "false", (long long) h.added, (long long) h.deleted, fi_status(&m, &h), adv.data,
        fi_default_rerank(m.fmt), m.nprobe_default, calib,
        g_last_used_index ? "true" : "false", (long long) g_last_rows_scanned, g_last_cells_probed, g_last_lookups);
    res = fi_keep(DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data))), caller);
    SPI_finish();
    PG_RETURN_JSONB_P(res);
}

/* ------------------------------------------------------------------ search */

typedef struct FiCand { int64 id; double d; } FiCand;

static void
fi_ins(FiCand *a, int *n, int cap, FiCand c)
{
    int i;
    if (*n == cap) {
        FiCand *w = &a[cap - 1];
        if (!(c.d < w->d || (c.d == w->d && c.id < w->id))) return;
        i = cap - 1;
    } else i = (*n)++;
    while (i > 0 && (a[i - 1].d > c.d || (a[i - 1].d == c.d && a[i - 1].id > c.id))) { a[i] = a[i - 1]; i--; }
    a[i] = c;
}

/* exact cosine distance between a stored datum and the query (doubles) */
static double
fi_exact_dist(Datum d, Oid typ, const double *q, int dim, bool *ok)
{
    int dd;
    float *f = fi_datum_to_floats(d, typ, &dd);
    double *a, r;
    if (dd != dim) { pfree(f); *ok = false; return 0.0; }
    a = (double *) palloc((Size) dim * sizeof(double));
    for (int i = 0; i < dim; i++) a[i] = (double) f[i];
    r = fsqlp_cosine_distance_d(a, q, (size_t) dim);
    pfree(a); pfree(f);
    *ok = true;
    return r;
}

static double *
fi_query(ArrayType *qarr, int *dim_out)
{
    Datum *ds; bool *ns; int n; double *q;
    if (ARR_NDIM(qarr) != 1) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: the query must be a one-dimensional float8[]")));
    deconstruct_array(qarr, FLOAT8OID, 8, FLOAT8PASSBYVAL, 'd', &ds, &ns, &n);
    if (n < 1 || n > FI_MAXDIM) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: the query dimension %d is outside 1..%d", n, FI_MAXDIM)));
    q = (double *) palloc((Size) n * sizeof(double));
    for (int i = 0; i < n; i++) {
        if (ns[i]) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: a NULL component in the query")));
        q[i] = DatumGetFloat8(ds[i]);
        if (!isfinite(q[i]) || fabs(q[i]) > 3.0e38) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: the query contains a non-finite or out-of-range component")));
    }
    *dim_out = n;
    return q;
}

/* The ids option: restrict a search to a set of integer keys (a jsonb array, for example to_jsonb(array_agg(id)) over an ordinary WHERE).
 * A short list is scanned exactly; a long one goes through the index and is filtered, and when that leaves fewer than k rows the list is
 * scanned exactly, so the answer is never short just because the index's shortlist missed the set. */
#define FI_IDS_MAX         1000000
#define FI_IDS_EXACT_MAX   4096

typedef struct FiIds { int64 *v; size_t n; } FiIds;

static int
fi_ids_cmp(const void *a, const void *b)
{
    int64 x = *(const int64 *) a, y = *(const int64 *) b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static bool
fi_ids_has(const FiIds *s, int64 id)
{
    size_t lo = 0, hi = s->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->v[mid] == id) return true;
        if (s->v[mid] < id) lo = mid + 1; else hi = mid;
    }
    return false;
}

/* true when the options carry ids (parsed, sorted, de-duplicated); an error when they are malformed */
static bool
fi_ids_parse(Jsonb *opts, FiIds *out)
{
    JsonbValue buf, *v, e;
    JsonbIterator *it;
    JsonbIteratorToken tok;
    size_t cap = 64, n = 0, w = 0;
    int64 *arr;
    out->v = NULL; out->n = 0;
    if (opts == NULL || !JB_ROOT_IS_OBJECT(opts)) return false;
    v = getKeyJsonValueFromContainer(&opts->root, "ids", 3, &buf);
    if (v == NULL) return false;
    if (v->type != jbvBinary || !JsonContainerIsArray(v->val.binary.data))
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: ids must be a JSON array of integer keys")));
    arr = (int64 *) palloc(cap * sizeof(int64));
    it = JsonbIteratorInit(v->val.binary.data);
    tok = JsonbIteratorNext(&it, &e, true);      /* WJB_BEGIN_ARRAY */
    while ((tok = JsonbIteratorNext(&it, &e, true)) == WJB_ELEM) {
        char *t, *end;
        long long x;
        if (e.type != jbvNumeric) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: ids must be a JSON array of integer keys")));
        t = DatumGetCString(DirectFunctionCall1(numeric_out, NumericGetDatum(e.val.numeric)));
        errno = 0;
        x = strtoll(t, &end, 10);
        if (end == t || *end != '\0' || errno == ERANGE) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: ids must be a JSON array of integer keys")));
        if (n >= FI_IDS_MAX) ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("fractalsql: ids holds more than %d keys", FI_IDS_MAX)));
        if (n == cap) { cap *= 2; arr = (int64 *) repalloc(arr, cap * sizeof(int64)); }
        arr[n++] = (int64) x;
    }
    qsort(arr, n, sizeof(int64), fi_ids_cmp);
    for (size_t i = 0; i < n; i++) if (w == 0 || arr[i] != arr[w - 1]) arr[w++] = arr[i];
    out->v = arr; out->n = w;
    return true;
}

/* Scans exactly the rows the ids name (one query with = ANY). */
static void
fi_exact_over_ids(const char *tbl, const char *col, const char *id_col, const FiIds *ids, const double *q, int D, FiCand *res, int *nres, int k, int64 *scanned)
{
    StringInfoData sql;
    Datum *elems;
    ArrayType *arr;
    Oid pt[1] = { INT8ARRAYOID }; Datum pa[1];
    Oid vt, it;
    *nres = 0;
    if (ids->n == 0) return;
    elems = (Datum *) palloc(ids->n * sizeof(Datum));
    for (size_t i = 0; i < ids->n; i++) elems[i] = Int64GetDatum(ids->v[i]);
    arr = construct_array(elems, (int) ids->n, INT8OID, sizeof(int64), FLOAT8PASSBYVAL, 'd');
    initStringInfo(&sql);
    appendStringInfo(&sql, "SELECT %s, %s FROM %s WHERE %s = ANY($1) AND %s IS NOT NULL", quote_identifier(id_col), quote_identifier(col), quote_identifier(tbl),
                     quote_identifier(id_col), quote_identifier(col));
    pa[0] = PointerGetDatum(arr);
    if (SPI_execute_with_args(sql.data, 1, pt, pa, NULL, true, 0) != SPI_OK_SELECT) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read %s.%s", tbl, col)));
    vt = SPI_gettypeid(SPI_tuptable->tupdesc, 2); it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
    if (vt != FLOAT8ARRAYOID && vt != fi_fvec_oid()) ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s vector_col must be float8[] or fractal_vector", tbl, col)));
    for (uint64 r = 0; r < SPI_processed; r++) {
        bool nul, ok; Datum idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul), vd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul);
        int64 id; double dist;
        if (nul) continue;
        id = it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd));
        dist = fi_exact_dist(vd, vt, q, D, &ok);
        if (!ok) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: query dim mismatch with vector at id %lld", (long long) id)));
        { FiCand c = { id, dist }; fi_ins(res, nres, k, c); (*scanned)++; }
    }
}

Datum
fractal_index_search(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 4, "fractal_search");
    char *tbl = text_to_cstring(PG_GETARG_TEXT_PP(0)), *col = text_to_cstring(PG_GETARG_TEXT_PP(1));
    ArrayType *qarr = PG_GETARG_ARRAYTYPE_P(2);
    int32 k = PG_GETARG_INT32(3);
    Jsonb *opts = arg_options(fcinfo, 4);
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    MemoryContext per_query_ctx, oldcontext;
    TupleDesc tupdesc;
    Tuplestorestate *tupstore;
    FiCand *res;
    int nres = 0, D;
    double *q;
    char *schema, iname[NAMEDATALEN] = "", *idc, *uidx;
    bool use_index, verify;
    FIdx *x = NULL;
    StringInfoData sql;
    int64 scanned = 0; int cells_probed = 0, lookups = 0, used_index = 0;
    FiIds ids = { NULL, 0 };
    bool have_ids, exact_ids;

    if (rsinfo == NULL || !(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("fractalsql: set-valued function called in context that cannot accept a set")));
    if (k < 1 || k > 1000) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: k out of range [1, 1000]")));
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("fractalsql: function returning record called in context that cannot accept type record")));
    tupdesc = BlessTupleDesc(tupdesc);
    tupstore = tuplestore_begin_heap(false, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize; rsinfo->setResult = tupstore; rsinfo->setDesc = tupdesc;
    MemoryContextSwitchTo(oldcontext);

    q = fi_query(qarr, &D);
    use_index = opt_bool(opts, "use_index", true); verify = opt_bool(opts, "verify", true);
    have_ids = fi_ids_parse(opts, &ids);
    uidx = opts ? opt_text(opts, "index") : NULL;
    idc = opts ? opt_text(opts, "id_col") : NULL;
    require_fits(tbl, "table name"); require_fits(col, "column name");
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    if (use_index) {
        if (uidx != NULL) strlcpy(iname, uidx, sizeof iname);
        else if (!fi_find_name(schema, tbl, col, iname, sizeof iname)) iname[0] = '\0';
        if (iname[0]) x = fi_load(schema, iname);
    }
    res = (FiCand *) palloc(sizeof(FiCand) * (size_t) k);
    initStringInfo(&sql);

    exact_ids = have_ids && (x == NULL || ids.n <= FI_IDS_EXACT_MAX);
    if (exact_ids) {
        FiMeta m0;
        const char *etbl = tbl, *ecol = col, *eid;
        if (x != NULL) {
            if (!fi_read_meta(schema, x->name, &m0)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", x->name)));
            if (x->dim != D) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: query dimension %d does not match index \"%s\" dimension %d", D, x->name, x->dim)));
            etbl = m0.tbl; ecol = m0.col; eid = m0.id_col;
        } else {
            if (idc == NULL) idc = pstrdup("id");
            require_fits(idc, "id column name");
            eid = idc;
        }
        fi_exact_over_ids(etbl, ecol, eid, &ids, q, D, res, &nres, k, &scanned);
    } else if (x == NULL) {
        /* exact scan fallback: needs an id column (default id) to name the rows */
        Oid vt, it;
        if (idc == NULL) idc = pstrdup("id");
        require_fits(idc, "id column name");
        appendStringInfo(&sql, "SELECT %s, %s FROM %s WHERE %s IS NOT NULL", quote_identifier(idc), quote_identifier(col), quote_identifier(tbl), quote_identifier(col));
        if (SPI_execute(sql.data, true, 0) != SPI_OK_SELECT) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot read %s.%s", tbl, col)));
        vt = SPI_gettypeid(SPI_tuptable->tupdesc, 2); it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
        if (vt != FLOAT8ARRAYOID && vt != fi_fvec_oid()) ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s vector_col must be float8[] or fractal_vector", tbl, col)));
        if (it != INT2OID && it != INT4OID && it != INT8OID) ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("fractalsql: %s.%s id_col must be smallint, integer or bigint", tbl, idc)));
        for (uint64 r = 0; r < SPI_processed; r++) {
            bool nul, ok; Datum idd, vd; int64 id; double dist;
            idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul);
            vd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul);
            if (nul) continue;
            id = it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd));
            dist = fi_exact_dist(vd, vt, q, D, &ok);
            if (!ok) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: query dim mismatch with vector at id %lld", (long long) id)));
            { FiCand c = { id, dist }; fi_ins(res, &nres, k, c); scanned++; }
        }
    } else {
        double nprobe_d = opt_num(opts, "nprobe", 0);
        int nprobe = nprobe_d > 0 ? (int) (nprobe_d > 1e9 ? 1e9 : nprobe_d) : (x->nprobe_default > 0 ? x->nprobe_default : 16);
        size_t rr = fi_default_rerank(x->fmt), R, ncand = 0, nver;
        float *qf; int64_t *cid; double *cd; fsql_ivf_stats_t st;
        FiMeta m;
        char *mname = opts ? opt_text(opts, "model") : NULL;
        if (x->dim != D) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: query dimension %d does not match index \"%s\" dimension %d", D, x->name, x->dim)));
        if (!fi_read_meta(schema, x->name, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", x->name)));
        if (mname != NULL && m.model[0] && strcmp(mname, m.model) != 0)
            ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: model \"%s\" does not match index \"%s\" (built for \"%s\"); rebuild the index", mname, x->name, m.model)));
        if (nprobe < 1) nprobe = 1;
        if (nprobe > x->nlist) nprobe = x->nlist;
        if (opts && opt_text(opts, "rerank") != NULL) {
            double v = opt_num(opts, "rerank", (double) rr);
            if (v < 0 || v > 100000) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: rerank out of range")));
            if (x->fmt == FSQL_IVF_FMT_INT4 && v < 20) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("fractalsql: INT4 indexes always rerank; rerank must be at least 20")));
            rr = (size_t) v;
        }
        R = rr > (size_t) k ? rr : (size_t) k + 5u;
        if (R > (size_t) k + 400u) R = (size_t) k + 400u;
        if (have_ids) R = (size_t) k + 400u;                  /* a filtered search needs a deeper shortlist to still have k rows left */
        qf = (float *) palloc((Size) D * sizeof(float));
        for (int i = 0; i < D; i++) qf[i] = (float) q[i];
        cid = (int64_t *) palloc(R * sizeof(int64_t)); cd = (double *) palloc(R * sizeof(double));
        if (fsql_ivf_search(x->x, qf, (uint32_t) nprobe, (uint32_t) R, cid, cd, &ncand, &st) != FSQL_OK)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: index search failed")));
        scanned = (int64) st.rows_scanned; cells_probed = (int) st.cells_probed; used_index = 1;
        {   /* delta: rows added after the build (key above max_id), scanned exactly */
            Oid vt, it; Oid pt[1] = { INT8OID }; Datum pa[1];
            resetStringInfo(&sql);
            appendStringInfo(&sql, "SELECT %s, %s FROM %s WHERE %s > $1 AND %s IS NOT NULL", quote_identifier(m.id_col), quote_identifier(m.col), quote_identifier(m.tbl), quote_identifier(m.id_col), quote_identifier(m.col));
            pa[0] = Int64GetDatum(x->max_id);
            if (SPI_execute_with_args(sql.data, 1, pt, pa, NULL, true, 0) == SPI_OK_SELECT) {
                vt = SPI_gettypeid(SPI_tuptable->tupdesc, 2); it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
                for (uint64 r = 0; r < SPI_processed; r++) {
                    bool nul, ok; Datum idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul), vd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul);
                    int64 id; double dist;
                    if (nul) continue;
                    id = it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd));
                    if (have_ids && !fi_ids_has(&ids, id)) continue;
                    dist = fi_exact_dist(vd, vt, q, D, &ok);
                    if (!ok) continue;
                    { FiCand c = { id, dist }; fi_ins(res, &nres, k, c); scanned++; }
                }
            }
        }
        nver = (rr > 0 || have_ids) ? ncand : (verify ? (ncand < (size_t) k + 5u ? ncand : (size_t) k + 5u) : 0);
        if (nver > 0) {
            SPIPlanPtr plan; Oid pt[1] = { INT8OID }; Datum pa[1];
            resetStringInfo(&sql);
            appendStringInfo(&sql, "SELECT %s FROM %s WHERE %s = $1", quote_identifier(m.col), quote_identifier(m.tbl), quote_identifier(m.id_col));
            plan = SPI_prepare(sql.data, 1, pt);
            if (plan == NULL) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: cannot prepare the verify lookup")));
            for (size_t i = 0; i < nver; i++) {
                if (have_ids && !fi_ids_has(&ids, cid[i])) continue;
                pa[0] = Int64GetDatum(cid[i]);
                lookups++;
                if (SPI_execute_plan(plan, pa, NULL, true, 1) == SPI_OK_SELECT && SPI_processed == 1) {
                    bool nul, ok; Datum vd = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nul); double dist;
                    if (nul) continue;
                    dist = fi_exact_dist(vd, SPI_gettypeid(SPI_tuptable->tupdesc, 1), q, D, &ok);
                    if (ok) { FiCand c = { cid[i], dist }; fi_ins(res, &nres, k, c); }
                }
            }
        } else {
            for (size_t i = 0; i < ncand && (have_ids || (int) i < k); i++) { FiCand c; if (have_ids && !fi_ids_has(&ids, cid[i])) continue; c.id = cid[i]; c.d = cd[i]; fi_ins(res, &nres, k, c); }
        }
        /* the filter left fewer than k rows: the set is small enough that scanning it exactly is the honest answer */
        if (have_ids && nres < k && (size_t) nres < ids.n) {
            fi_exact_over_ids(m.tbl, m.col, m.id_col, &ids, q, D, res, &nres, k, &scanned);
            used_index = 0;
        }
    }
    g_last_rows_scanned = scanned; g_last_cells_probed = cells_probed; g_last_used_index = used_index; g_last_lookups = lookups;
    for (int i = 0; i < nres; i++) {
        Datum values[3]; bool nulls[3] = { false, false, false };
        MemoryContext old = MemoryContextSwitchTo(per_query_ctx);
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", (long long) res[i].id);
        values[0] = CStringGetTextDatum(buf); values[1] = Float8GetDatum(res[i].d); values[2] = Int64GetDatum(res[i].id);
        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
        MemoryContextSwitchTo(old);
    }
    SPI_finish();
    return (Datum) 0;
}

Datum
fractal_index_candidates(PG_FUNCTION_ARGS)
{
    fi_require_args(fcinfo, 3, "fractal_index_candidates");
    if (!fi_ivf_available()) ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED), errmsg("%s", FI_NO_CORE_MSG)));
    char *tbl = text_to_cstring(PG_GETARG_TEXT_PP(0)), *col = text_to_cstring(PG_GETARG_TEXT_PP(1));
    ArrayType *qarr = PG_GETARG_ARRAYTYPE_P(2);
    Jsonb *opts = arg_options(fcinfo, 3);
    int D, near, per;
    double *q; float *qf; uint32_t *cells, nc = 0;
    char *schema, iname[NAMEDATALEN] = "", *uidx;
    FIdx *x;
    StringInfoData sql;
    Datum *out; int nout = 0, cap = 1024;
    MemoryContext caller = CurrentMemoryContext;
    ArrayType *arr;
    double nd = opt_num(opts, "near", 6), pd = opt_num(opts, "per_cell", 1);
    near = (int) (nd < 0 ? 0 : (nd > 4096 ? 4096 : nd)); per = (int) (pd < 0 ? 0 : (pd > 100000 ? 100000 : pd));
    require_fits(tbl, "table name"); require_fits(col, "column name");
    q = fi_query(qarr, &D);
    fi_spi_begin();
    schema = fi_schema(fcinfo);
    fi_ensure_tables(schema);
    uidx = opts ? opt_text(opts, "index") : NULL;
    if (uidx != NULL) strlcpy(iname, uidx, sizeof iname);
    else if (!fi_find_name(schema, tbl, col, iname, sizeof iname)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index on this table and column")));
    x = fi_load(schema, iname);
    if (x->dim != D) ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("fractalsql: query dimension does not match the index")));
    qf = (float *) palloc((Size) D * sizeof(float));
    for (int i = 0; i < D; i++) qf[i] = (float) q[i];
    cells = (uint32_t *) palloc((Size) x->nlist * sizeof(uint32_t));
    if (fsql_ivf_probe_cells(x->m, qf, (uint32_t) (near > 0 ? near : 1), cells, &nc) != FSQL_OK) ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("fractalsql: probe failed")));
    if (near == 0) nc = 0;
    out = (Datum *) palloc((Size) cap * sizeof(Datum));
    {
        FiMeta m; Oid ct[2] = { TEXTOID, INT4OID }; Datum ca[2];
        char *isn = palloc0((Size) x->nlist);
        if (!fi_read_meta(schema, iname, &m)) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("fractalsql: no index named \"%s\"", iname)));
        for (uint32_t i = 0; i < nc; i++) if (cells[i] < (uint32_t) x->nlist) isn[cells[i]] = 1;
        initStringInfo(&sql);
        appendStringInfo(&sql, "SELECT cell, n, ids FROM %s.fractal_index_cells WHERE name = $1 AND generation = $2 ORDER BY cell", quote_identifier(schema));
        ca[0] = CStringGetTextDatum(iname); ca[1] = Int32GetDatum(x->generation);
        if (SPI_execute_with_args(sql.data, 2, ct, ca, NULL, true, 0) == SPI_OK_SELECT) {
            for (uint64 r = 0; r < SPI_processed; r++) {
                bool nul_c, nul_n, nul_ib;
                Datum d_c = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul_c);
                Datum d_n = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 2, &nul_n);
                Datum d_ib = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 3, &nul_ib);
                int32 c = nul_c ? -1 : DatumGetInt32(d_c);
                int32 n = nul_n ? -1 : DatumGetInt32(d_n);
                bytea *ib = nul_ib ? NULL : DatumGetByteaPP(d_ib);
                int64 take;
                if (c < 0 || c >= x->nlist || n < 0 || ib == NULL || (int64) VARSIZE_ANY_EXHDR(ib) != (int64) n * 8) continue;
                take = isn[c] ? n : (per < n ? per : n);
                for (int64 j = 0; j < take; j++) {
                    if (nout == cap) { cap *= 2; out = (Datum *) repalloc(out, (Size) cap * sizeof(Datum)); }
                    out[nout++] = Int64GetDatum(get_le64((const uint8_t *) VARDATA_ANY(ib) + (size_t) j * 8));
                }
            }
        }
        {   /* rows newer than the index */
            Oid pt[1] = { INT8OID }; Datum pa[1];
            resetStringInfo(&sql);
            appendStringInfo(&sql, "SELECT %s FROM %s WHERE %s > $1 AND %s IS NOT NULL", quote_identifier(m.id_col), quote_identifier(m.tbl), quote_identifier(m.id_col), quote_identifier(m.col));
            pa[0] = Int64GetDatum(x->max_id);
            if (SPI_execute_with_args(sql.data, 1, pt, pa, NULL, true, 0) == SPI_OK_SELECT)
                for (uint64 r = 0; r < SPI_processed; r++) {
                    bool nul; Datum idd = SPI_getbinval(SPI_tuptable->vals[r], SPI_tuptable->tupdesc, 1, &nul);
                    Oid it = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
                    if (nul) continue;
                    if (nout == cap) { cap *= 2; out = (Datum *) repalloc(out, (Size) cap * sizeof(Datum)); }
                    out[nout++] = Int64GetDatum(it == INT2OID ? (int64) DatumGetInt16(idd) : (it == INT4OID ? (int64) DatumGetInt32(idd) : DatumGetInt64(idd)));
                }
        }
    }
    {
        MemoryContext old = MemoryContextSwitchTo(caller);
        arr = construct_array(out, nout, INT8OID, 8, FLOAT8PASSBYVAL, 'd');
        MemoryContextSwitchTo(old);
    }
    SPI_finish();
    PG_RETURN_ARRAYTYPE_P(arr);
}
