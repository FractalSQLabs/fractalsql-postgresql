/* src/fractalsql_vector.h — the fractal_vector Postgres type.
 *
 * A native varlena type for float4 vectors, typmod-enforced dimension
 * (`fractal_vector(n)`), storing the raw float32 payload contiguously
 * so distance/arithmetic operators read it directly (no float8[]
 * array-header/null-bitmap unpack step) and hand off to the vendored
 * core's DB-agnostic fsql_vector_* module (exposed via
 * include/fractalsql_sql.h) for the actual math.
 *
 * Storage layout (x[] must sit at a 4-byte-aligned offset, not 6-byte):
 *
 *   int32  vl_len_      varlena header
 *   int16  dim           1..32767
 *   int16  _reserved     alignment pad; reserved for a future
 *                        quantization-mode flag -- always 0 today.
 *   float  x[dim]        contiguous float32 payload
 *
 * float8[] remains fully supported everywhere -- this type is additive,
 * not a replacement. Casts between the two are registered in
 * sql/fractalsql--1.0.sql.
 */

#ifndef FRACTALSQL_VECTOR_H
#define FRACTALSQL_VECTOR_H

#include "postgres.h"
#include "fmgr.h"

typedef struct FractalVector
{
    int32   vl_len_;
    int16   dim;
    int16   _reserved;
    float4  x[FLEXIBLE_ARRAY_MEMBER];
} FractalVector;

#define FRACTALVEC_HDRSZ    offsetof(FractalVector, x)
#define FRACTALVEC_SIZE(n)  (FRACTALVEC_HDRSZ + sizeof(float4) * (Size) (n))

#define DatumGetFractalVectorP(d)  ((FractalVector *) PG_DETOAST_DATUM(d))
#define PG_GETARG_FRACTALVEC_P(n) DatumGetFractalVectorP(PG_GETARG_DATUM(n))
#define PG_RETURN_FRACTALVEC_P(v) PG_RETURN_POINTER(v)

/* Allocates a new FractalVector (palloc, VARSIZE set, dim/_reserved
 * set) with an uninitialized x[] payload of length `dim` -- caller
 * fills it in. */
extern FractalVector *fractalvec_new(int16 dim);

#endif  /* FRACTALSQL_VECTOR_H */
