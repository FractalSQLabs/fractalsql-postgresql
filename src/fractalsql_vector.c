/* src/fractalsql_vector.c — fractal_vector type I/O, typmod, casts,
 * operators.
 *
 * See fractalsql_vector.h for the storage layout. Distance operators
 * call directly into the vendored core's fsql_vector_* module (float32,
 * DB-agnostic) -- no float8 widening happens here; that only happens
 * at the spi_scan_corpus boundary in fractalsql.c, right before the
 * double-precision fsql_search_ptr/HNSW path.
 */

#include "postgres.h"
#include "fmgr.h"

/*
 * Same PG14/15-on-Windows PG_FUNCTION_INFO_V1 gap as fractalsql.c (see
 * that file's copy of this shim for the full rationale) -- a separate
 * translation unit needs its own redefinition.
 */
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

#include "libpq/pqformat.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "catalog/pg_type.h"

#include <ctype.h>
#include <math.h>
#include <string.h>

#include "fractalsql_vector.h"
#include "fractalsql_sql.h"   /* fsql_vector_* (vendored core API) */

PG_FUNCTION_INFO_V1(fractal_vector_in);
PG_FUNCTION_INFO_V1(fractal_vector_out);
PG_FUNCTION_INFO_V1(fractal_vector_recv);
PG_FUNCTION_INFO_V1(fractal_vector_send);
PG_FUNCTION_INFO_V1(fractal_vector_typmod_in);
PG_FUNCTION_INFO_V1(fractal_vector_typmod_out);
PG_FUNCTION_INFO_V1(fractal_vector_enforce_typmod);
PG_FUNCTION_INFO_V1(fractal_vector_dims);
PG_FUNCTION_INFO_V1(fractal_vector_from_float8_array);
PG_FUNCTION_INFO_V1(fractal_vector_to_float8_array);
PG_FUNCTION_INFO_V1(fractal_vector_l2_distance);
PG_FUNCTION_INFO_V1(fractal_vector_cosine_distance);
PG_FUNCTION_INFO_V1(fractal_vector_negative_inner_product);
PG_FUNCTION_INFO_V1(fractal_vector_l2_squared);
PG_FUNCTION_INFO_V1(fractal_vector_cosine_similarity);
PG_FUNCTION_INFO_V1(fractal_vector_norm);
PG_FUNCTION_INFO_V1(fractal_vector_normalize);
PG_FUNCTION_INFO_V1(fractal_vector_add);
PG_FUNCTION_INFO_V1(fractal_vector_sub);
PG_FUNCTION_INFO_V1(fractal_vector_scale);

/* Postgres typmod max for a 2-byte dim field; also fsql_vector_*'s
 * practical ceiling (embedding dimensions in practice are a few
 * thousand, so 32767 is a generous ceiling). */
#define FRACTALVEC_MAX_DIM  32767

FractalVector *
fractalvec_new(int16 dim)
{
    FractalVector *v = (FractalVector *) palloc(FRACTALVEC_SIZE(dim));
    SET_VARSIZE(v, FRACTALVEC_SIZE(dim));
    v->dim = dim;
    v->_reserved = 0;
    return v;
}

static void
check_dim_range(int64 dim)
{
    if (dim < 1 || dim > FRACTALVEC_MAX_DIM)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("fractal_vector dimension must be between 1 and %d, got %ld",
                        FRACTALVEC_MAX_DIM, (long) dim)));
}

/* Raises ERRCODE_STRING_DATA_LENGTH_MISMATCH, matching Postgres's own
 * convention for varchar(n)/numeric(p,s) length violations -- this is
 * the actual runtime enforcement mechanism (TYPMOD_IN/TYPMOD_OUT only
 * parse/print the "(n)" in DDL, they check nothing at runtime; the
 * self-cast in sql/fractalsql--1.0.sql that calls this function is
 * what Postgres invokes on every assignment into a typmod'd column). */
static void
check_dim_matches_typmod(int16 dim, int32 typmod)
{
    if (typmod < 0) return;   /* fractal_vector with no declared dimension */
    if (dim != typmod)
        ereport(ERROR,
                (errcode(ERRCODE_STRING_DATA_LENGTH_MISMATCH),
                 errmsg("fractal_vector dimension mismatch: column is "
                        "fractal_vector(%d), value has dimension %d",
                        typmod, dim)));
}

/* ------------------------------------------------------------------ */
/* Text I/O -- "[0.1,0.2,0.3]", matching pgvector's own format so      */
/* users don't have to learn a bespoke one.                           */
/* ------------------------------------------------------------------ */

Datum
fractal_vector_in(PG_FUNCTION_ARGS)
{
    char   *str    = PG_GETARG_CSTRING(0);
    int32   typmod = PG_GETARG_INT32(2);
    char   *p      = str;

    while (isspace((unsigned char) *p)) p++;
    if (*p != '[')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("fractal_vector: expected '[' at start of \"%s\"", str)));
    p++;

    float4  stackbuf[64];
    float4 *vals = stackbuf;
    int     cap  = 64;
    int     n    = 0;

    while (isspace((unsigned char) *p)) p++;
    if (*p != ']') {
        for (;;) {
            /* Bound the allocation before parsing the next element. Without
             * this, a TOASTed input of millions of numbers grows `vals` to
             * ~4x the input size before check_dim_range() fires at the end;
             * checking here caps the buffer at ~2*FRACTALVEC_MAX_DIM floats
             * (the repalloc doubling overshoots by at most 2x) regardless
             * of input length, and errors immediately on oversized input. */
            if (n >= FRACTALVEC_MAX_DIM)
                ereport(ERROR,
                        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                         errmsg("fractal_vector: dimension exceeds maximum %d",
                                FRACTALVEC_MAX_DIM)));
            char   *endptr;
            double  d = strtod(p, &endptr);
            if (endptr == p)
                ereport(ERROR,
                        (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                         errmsg("fractal_vector: invalid number in \"%s\"", str)));
            if (n == cap) {
                int newcap = cap * 2;
                float4 *newvals = (vals == stackbuf)
                    ? (float4 *) palloc(sizeof(float4) * newcap)
                    : (float4 *) repalloc(vals, sizeof(float4) * newcap);
                if (vals == stackbuf) memcpy(newvals, stackbuf, sizeof(float4) * cap);
                vals = newvals;
                cap  = newcap;
            }
            vals[n++] = (float4) d;
            p = endptr;
            while (isspace((unsigned char) *p)) p++;
            if (*p == ',') { p++; while (isspace((unsigned char) *p)) p++; continue; }
            break;
        }
    }
    if (*p != ']')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("fractal_vector: expected ']' in \"%s\"", str)));
    p++;
    while (isspace((unsigned char) *p)) p++;
    if (*p != '\0')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("fractal_vector: unexpected trailing data in \"%s\"", str)));

    check_dim_range(n);
    FractalVector *v = fractalvec_new((int16) n);
    memcpy(v->x, vals, sizeof(float4) * n);
    check_dim_matches_typmod(v->dim, typmod);

    PG_RETURN_FRACTALVEC_P(v);
}

Datum
fractal_vector_out(PG_FUNCTION_ARGS)
{
    FractalVector *v = PG_GETARG_FRACTALVEC_P(0);
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfoChar(&buf, '[');
    for (int i = 0; i < v->dim; i++) {
        if (i > 0) appendStringInfoChar(&buf, ',');
        appendStringInfo(&buf, "%.9g", (double) v->x[i]);
    }
    appendStringInfoChar(&buf, ']');
    PG_RETURN_CSTRING(buf.data);
}

/* ------------------------------------------------------------------ */
/* Binary I/O                                                         */
/* ------------------------------------------------------------------ */

Datum
fractal_vector_recv(PG_FUNCTION_ARGS)
{
    StringInfo buf    = (StringInfo) PG_GETARG_POINTER(0);
    int32      typmod = PG_GETARG_INT32(2);

    int16 dim = (int16) pq_getmsgint(buf, sizeof(int16));
    check_dim_range(dim);

    FractalVector *v = fractalvec_new(dim);
    for (int i = 0; i < dim; i++)
        v->x[i] = pq_getmsgfloat4(buf);
    check_dim_matches_typmod(v->dim, typmod);

    PG_RETURN_FRACTALVEC_P(v);
}

Datum
fractal_vector_send(PG_FUNCTION_ARGS)
{
    FractalVector *v = PG_GETARG_FRACTALVEC_P(0);
    StringInfoData buf;
    pq_begintypsend(&buf);
    pq_sendint16(&buf, v->dim);
    for (int i = 0; i < v->dim; i++)
        pq_sendfloat4(&buf, v->x[i]);
    PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* ------------------------------------------------------------------ */
/* Typmod -- parses/prints "(n)"; runtime enforcement is a separate   */
/* self-cast (fractal_vector_enforce_typmod below), not this pair.    */
/* ------------------------------------------------------------------ */

Datum
fractal_vector_typmod_in(PG_FUNCTION_ARGS)
{
    ArrayType *arr = PG_GETARG_ARRAYTYPE_P(0);
    int        n;
    Datum     *elems;
    bool      *nulls;
    deconstruct_array(arr, CSTRINGOID, -2, false, 'c', &elems, &nulls, &n);
    if (n != 1 || nulls[0])
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("fractal_vector typmod takes exactly one non-NULL parameter")));

    char *str = DatumGetCString(elems[0]);
    char *endptr;
    long  dim = strtol(str, &endptr, 10);
    if (endptr == str || *endptr != '\0')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("fractal_vector: invalid dimension \"%s\"", str)));
    check_dim_range(dim);

    PG_RETURN_INT32((int32) dim);
}

Datum
fractal_vector_typmod_out(PG_FUNCTION_ARGS)
{
    int32 typmod = PG_GETARG_INT32(0);
    char  buf[32];
    snprintf(buf, sizeof buf, "(%d)", typmod);
    PG_RETURN_CSTRING(pstrdup(buf));
}

Datum
fractal_vector_enforce_typmod(PG_FUNCTION_ARGS)
{
    FractalVector *v      = PG_GETARG_FRACTALVEC_P(0);
    int32          typmod = PG_GETARG_INT32(1);
    /* arg 2 (explicit-cast flag) is irrelevant here -- a dimension
     * mismatch is a data error, not a precision-loss warning a caller
     * can choose to silence with an explicit cast, unlike numeric(p,s)
     * truncation. */
    check_dim_matches_typmod(v->dim, typmod);
    PG_RETURN_FRACTALVEC_P(v);
}

Datum
fractal_vector_dims(PG_FUNCTION_ARGS)
{
    FractalVector *v = PG_GETARG_FRACTALVEC_P(0);
    PG_RETURN_INT32(v->dim);
}

/* ------------------------------------------------------------------ */
/* Casts to/from float8[] -- additive interop, nothing about float8[] */
/* is deprecated or broken.                                           */
/* ------------------------------------------------------------------ */

Datum
fractal_vector_from_float8_array(PG_FUNCTION_ARGS)
{
    ArrayType *arr = PG_GETARG_ARRAYTYPE_P(0);
    if (ARR_NDIM(arr) != 1 || ARR_HASNULL(arr))
        ereport(ERROR,
                (errcode(ERRCODE_DATA_EXCEPTION),
                 errmsg("fractal_vector: source float8[] must be 1-D non-null")));
    int     n = ARR_DIMS(arr)[0];
    check_dim_range(n);

    Datum  *ds;
    bool   *nulls;
    int     n2;
    deconstruct_array(arr, FLOAT8OID, sizeof(float8), FLOAT8PASSBYVAL, 'd',
                      &ds, &nulls, &n2);

    FractalVector *v = fractalvec_new((int16) n2);
    for (int i = 0; i < n2; i++) v->x[i] = (float4) DatumGetFloat8(ds[i]);
    PG_RETURN_FRACTALVEC_P(v);
}

Datum
fractal_vector_to_float8_array(PG_FUNCTION_ARGS)
{
    FractalVector *v  = PG_GETARG_FRACTALVEC_P(0);
    Datum         *ds = (Datum *) palloc(sizeof(Datum) * v->dim);
    for (int i = 0; i < v->dim; i++) ds[i] = Float8GetDatum((double) v->x[i]);
    PG_RETURN_ARRAYTYPE_P(
        construct_array(ds, v->dim, FLOAT8OID, sizeof(float8), FLOAT8PASSBYVAL, 'd'));
}

/* ------------------------------------------------------------------ */
/* Distance operators -- read the two varlenas' x[]/dim directly (no  */
/* array-unpack step), call into core's float32 module.               */
/* ------------------------------------------------------------------ */

static void
check_same_dim(int16 a_dim, int16 b_dim)
{
    if (a_dim != b_dim)
        ereport(ERROR,
                (errcode(ERRCODE_DATA_EXCEPTION),
                 errmsg("fractal_vector: dimension mismatch (%d vs %d)",
                        a_dim, b_dim)));
}

Datum
fractal_vector_l2_distance(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    float4 dist;
    fsql_vector_l2(a->x, b->x, (size_t) a->dim, &dist);
    PG_RETURN_FLOAT8((double) dist);
}

Datum
fractal_vector_cosine_distance(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    float4 dist;
    fsql_vector_cosine_distance(a->x, b->x, (size_t) a->dim, &dist);
    PG_RETURN_FLOAT8((double) dist);
}

Datum
fractal_vector_negative_inner_product(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    float4 dot;
    fsql_vector_dot(a->x, b->x, (size_t) a->dim, &dot);
    PG_RETURN_FLOAT8((double) -dot);
}

/* ------------------------------------------------------------------ */
/* General-purpose vector arithmetic the core already implements,      */
/* now exposed as SQL-callable functions. fractal_vector_sub is       */
/* included alongside add for symmetry.                               */
/* ------------------------------------------------------------------ */

Datum
fractal_vector_l2_squared(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    float4 sq;
    fsql_vector_l2_sq(a->x, b->x, (size_t) a->dim, &sq);
    PG_RETURN_FLOAT8((double) sq);
}

Datum
fractal_vector_cosine_similarity(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    float4 sim;
    fsql_vector_cosine_similarity(a->x, b->x, (size_t) a->dim, &sim);
    PG_RETURN_FLOAT8((double) sim);
}

Datum
fractal_vector_norm(PG_FUNCTION_ARGS)
{
    FractalVector *v = PG_GETARG_FRACTALVEC_P(0);
    float4 n;
    fsql_vector_norm(v->x, (size_t) v->dim, &n);
    PG_RETURN_FLOAT8((double) n);
}

Datum
fractal_vector_normalize(PG_FUNCTION_ARGS)
{
    FractalVector *v   = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *out = fractalvec_new(v->dim);
    fsql_vector_normalize(v->x, (size_t) v->dim, out->x);
    PG_RETURN_FRACTALVEC_P(out);
}

Datum
fractal_vector_add(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    FractalVector *out = fractalvec_new(a->dim);
    fsql_vector_add(a->x, b->x, (size_t) a->dim, out->x);
    PG_RETURN_FRACTALVEC_P(out);
}

Datum
fractal_vector_sub(PG_FUNCTION_ARGS)
{
    FractalVector *a = PG_GETARG_FRACTALVEC_P(0);
    FractalVector *b = PG_GETARG_FRACTALVEC_P(1);
    check_same_dim(a->dim, b->dim);
    FractalVector *out = fractalvec_new(a->dim);
    fsql_vector_sub(a->x, b->x, (size_t) a->dim, out->x);
    PG_RETURN_FRACTALVEC_P(out);
}

Datum
fractal_vector_scale(PG_FUNCTION_ARGS)
{
    FractalVector *v      = PG_GETARG_FRACTALVEC_P(0);
    float4         scalar = (float4) PG_GETARG_FLOAT8(1);
    FractalVector *out    = fractalvec_new(v->dim);
    fsql_vector_scale(v->x, (size_t) v->dim, scalar, out->x);
    PG_RETURN_FRACTALVEC_P(out);
}
