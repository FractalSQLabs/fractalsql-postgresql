<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# FractalSQL benchmark: HNSW vs Scout Mode

Head-to-head comparison of pgvector's HNSW index against FractalSQL's
`fractal_search_explore` (Scout Mode, `walk=0`). Measures search latency
and island recall on a synthetic Gaussian-cluster dataset.

## Prerequisites

- PostgreSQL 16 with `pgvector` and `fractalsql` installed
- Python 3.9+
- A database you can create/drop tables in (default DSN expects
  a database named `fractalsql_bench`)

## Setup

```bash
pip install -r bench/requirements.txt
createdb fractalsql_bench                # one-time, as a PG superuser
```

Verify both extensions are available:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION fractalsql;
\dx
```

## Run the benchmark

```bash
make bench                               # data_gen + head_to_head
```

Or manually:

```bash
python3 bench/data_gen.py                # ~30–60s to populate 100k rows
python3 bench/head_to_head.py            # ~1–3 min for 5 queries
```

## What you should see

The output is a per-query table followed by an average:

```
qi  anchor      |       HNSW ms   HNSW recall    |       SFS ms   SFS recall
-------------------------------------------------------------------------
 0  cluster  12 |        3.2      1 / 50         |    18400.1    28 / 50
 1  cluster   7 |        2.8      1 / 50         |    18100.4    31 / 50
...

Averages over 5 queries:
  HNSW:      3.0 ms   recall  1.0 / 50
  SFS :  18200.0 ms   recall 29.4 / 50
  SFS is 6000x slower and discovers 29x more distinct clusters
```

The shape of the result will vary run to run, but the pattern is robust:
HNSW finds ~1–2 clusters at millisecond latency; Scout Mode finds 20–35
clusters at multi-second latency. This is the intended comparison —
different algorithms solving different problems.

## Scaling notes

The SFS fitness is `min over stored_set of ||candidate - v||²`, evaluated
brute-force. Per-fitness cost is O(N × D), and SFS makes ~2500 evaluations
in a population=50, iterations=8 run. That scales linearly with the
stored-set size:

| N (stored vectors) | Approx per-query SFS time at d=768 |
| ------------------ | ---------------------------------- |
| 10 000             |   2–5 seconds                      |
| 100 000 (default)  |  20–60 seconds                     |
| 1 000 000          |   3–10 minutes                     |

HNSW is approximately N-independent in comparison. For production use
beyond ~100k vectors, a future version of `fractal_search_explore`
could use an approximate-NN index internally for fitness lookups. For
now, Scout Mode is best applied to curated sub-corpora where diversity
matters more than scan throughput.

## Tuning

`head_to_head.py` exposes a few knobs:

```
--n-queries        number of queries to average (default 5)
--top-k            #results per method, also SFS population_size (50)
--sfs-iter         SFS generations (default 8)
--sfs-mdn          diffusion factor (default 2)
--hnsw-ef-search   pgvector search quality (default 40)
--seed             query-selection RNG seed
```

`data_gen.py` exposes the dataset shape:

```
--n        total points (default 100000)
--dim      vector dimension (default 768)
--clusters number of Gaussian islands (default 50)
--sigma    intra-cluster std (default 0.05)
```

## fractal_vector vs float8[] at scale

A second, unrelated benchmark: `fractal_vector(n)` vs `float8[]` storage
size, bulk-load throughput, and search latency, at `data_gen.py`'s real
scale rather than a hand-picked single row. Distinct from the
HNSW-vs-Scout comparison above.

```bash
make bench-vector
```

Or manually:

```bash
python3 bench/data_gen.py --with-fractal-vector   # adds bench_vectors.emb_fv
python3 bench/vector_type_head_to_head.py
```

Reports four numbers: `pg_column_size` per row (float8[] vs
fractal_vector), bulk `COPY` throughput for both column types,
`fractal_search_trajectory` latency old (float8[]) vs new
(fractal_vector) overload, and peak backend RSS during a full-corpus
`fractal_vector` scan (a regression tripwire for `spi_scan_corpus`'s
per-row detoast-then-`pfree()` loop actually keeping memory bounded —
meaningful only when the benchmark client and the Postgres server share
a host, since it reads `/proc/<backend_pid>/status`; self-skips
otherwise).

The storage-size ratio depends on how compressible your actual
embedding values are: Postgres TOASTs `float8[]` with compression by
default, while `fractal_vector` uses `STORAGE = external` and skips
compression deliberately (float mantissas compress poorly). Small
vectors that never trigger TOAST see close to the full ~2x
(uncompressed `float4` vs uncompressed `float8`); larger vectors where
`float8[]`'s TOAST compression kicks in see a smaller realized gap.
Measure on your own data before treating either number as a promise.

**On sub-benchmark (c)'s absolute numbers**: `fractal_search_trajectory`
(like every `fractal_search_telemetry`-family function) runs a full SFS
population search internally (`telemetry_topk_srf`'s hardcoded
`population_size=50, max_generation=15`), the same cost class as
`fractal_search_explore`/Scout mode above — it is not a cheap distance-
sort top-k. The "Scaling notes" table above (20-60s at N=100k, d=768,
Scout Mode) is the right intuition for sub-benchmark (c) too, and the
absolute latency you see is dominated by that SFS cost, not by the
`float8[]`-vs-`fractal_vector` unpack difference this arm is actually
trying to isolate. Judge fractal_vector's contribution from the relative
gap between the two rows, not either row's absolute value — and expect
both to be considerably slower still on a CPU-constrained host (e.g. a
2-vCPU container) than the table above implies, since that table was
measured on a real multi-core host.

`vector_type_head_to_head.py`'s own knobs:

```
--copy-n           row count for the COPY throughput sub-benchmark
                   (default 20000 -- smaller than the full corpus,
                   this arm is O(n) by design so a subset is
                   representative)
--search-queries   queries to average for the latency sub-benchmark
                   (default 10)
```
