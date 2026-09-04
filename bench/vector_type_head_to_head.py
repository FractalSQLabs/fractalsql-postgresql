#!/usr/bin/env python3
"""
bench/vector_type_head_to_head.py — fractal_vector(n) vs float8[] at
data_gen.py's actual scale (100k rows / dim 768 by default), not the
small demo's hand-picked single row.

Distinct from bench/head_to_head.py (HNSW-vs-Scout algorithm comparison,
unrelated to storage type). Requires bench_vectors.emb_fv, i.e. run
data_gen.py --with-fractal-vector first.

Measures:
  (a) pg_column_size per row, float8[] vs fractal_vector, at real scale.
  (b) Bulk COPY throughput for both column types.
  (c) fractal_search_trajectory / fractal_cross_modal_search query
      latency, old (float8[]) vs new (fractal_vector) overload --
      isolates the "no array-unpack step" claim at scale, the one
      number the small demo can't credibly produce on its own.
  (d) Peak backend RSS during a 100k-row scan (spi_scan_corpus's
      fractal_vector branch detoasts+widens one row at a time; this is
      the regression tripwire for that loop's per-row pfree() actually
      keeping memory bounded, not the correctness check -- that's
      tests/test_vector_type.py's job). Reads /proc/<backend_pid>/status
      client-side, so this assumes client and server share a host (the
      same assumption bench/README.md's local Postgres+pgvector setup
      already makes -- not meaningful against a remote/containerized
      server).

Usage:
    python3 bench/vector_type_head_to_head.py --dsn postgresql:///fractalsql_bench
"""

import argparse
import sys
import time

import psycopg


def read_rss_kb(conn) -> int | None:
    """VmRSS of the backend serving `conn`, via /proc -- None if
    unavailable (non-Linux, or client/server on different hosts)."""
    pid = conn.execute("SELECT pg_backend_pid()").fetchone()[0]
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])  # kB
    except OSError:
        return None
    return None


def bench_storage_size(conn) -> None:
    print("\n-- (a) storage size (pg_column_size, avg over 200 sampled rows) --")
    fv_avg, arr_avg = conn.execute("""
        SELECT avg(pg_column_size(emb_fv)), avg(pg_column_size(emb_arr))
        FROM (SELECT emb_fv, emb_arr FROM bench_vectors
              ORDER BY random() LIMIT 200) s
    """).fetchone()
    ratio = arr_avg / fv_avg if fv_avg else float("nan")
    print(f"  fractal_vector: {fv_avg:.0f} bytes")
    print(f"  float8[]      : {arr_avg:.0f} bytes  (TOAST-compressed by default; "
          f"fractal_vector uses STORAGE=external, no compression attempt)")
    print(f"  ratio         : {ratio:.2f}x")
    print("  Note: the realized ratio depends on how compressible your actual "
          "embedding values are -- measure on real data, not this synthetic "
          "Gaussian-cluster set, before treating this number as a promise.")


def bench_copy_throughput(conn, n: int, dim: int) -> None:
    print(f"\n-- (b) bulk COPY throughput ({n} rows, dim={dim}) --")
    import numpy as np
    rng = np.random.default_rng(7)
    vecs = np.clip(rng.normal(0.0, 0.3, (n, dim)), -1.0, 1.0)

    for label, table, col, typ in [
        ("float8[]", "_bt_copy_arr", "v", "float8[]"),
        ("fractal_vector", "_bt_copy_fv", "v", f"fractal_vector({dim})"),
    ]:
        conn.execute(f"DROP TABLE IF EXISTS {table}")
        conn.execute(f"CREATE TABLE {table} (id int, {col} {typ})")
        t0 = time.perf_counter()
        with conn.cursor() as cur:
            with cur.copy(f"COPY {table} (id, {col}) FROM STDIN WITH (FORMAT TEXT)") as copy:
                for i in range(n):
                    coords = ",".join(f"{x:.6f}" for x in vecs[i])
                    lit = ("{" + coords + "}") if typ == "float8[]" else f"[{coords}]"
                    copy.write_row((i, lit))
        elapsed = time.perf_counter() - t0
        print(f"  {label:16s}: {elapsed:.2f}s ({n / elapsed:.0f} rows/s)")
        conn.execute(f"DROP TABLE {table}")


def bench_search_latency(conn, n_queries: int) -> None:
    print("\n-- (c) fractal_search_trajectory latency: float8[] vs fractal_vector overload --")
    row = conn.execute("SELECT emb_arr, emb_fv FROM bench_vectors LIMIT 1").fetchone()
    if row is None or row[1] is None:
        print("  SKIP -- bench_vectors.emb_fv is empty (run data_gen.py "
              "--with-fractal-vector first)")
        return
    baseline_arr, _ = row

    for label, sql, params in [
        ("float8[]", """
            SELECT * FROM fractal_search_trajectory(
                'bench_vectors', 'emb_arr', %s::float8[], %s::float8[], 10)
        """, (baseline_arr, baseline_arr)),
        ("fractal_vector", """
            SELECT * FROM fractal_search_trajectory(
                'bench_vectors', 'emb_fv', %s::float8[]::fractal_vector,
                %s::float8[]::fractal_vector, 10)
        """, (baseline_arr, baseline_arr)),
    ]:
        times = []
        for _ in range(n_queries):
            t0 = time.perf_counter()
            conn.execute(sql, params).fetchall()
            times.append((time.perf_counter() - t0) * 1000.0)
        avg = sum(times) / len(times)
        print(f"  {label:16s}: {avg:.1f} ms avg over {n_queries} queries "
              f"(min {min(times):.1f}, max {max(times):.1f})")


def bench_peak_rss(conn, n: int) -> None:
    print(f"\n-- (d) peak backend RSS during a {n}-row fractal_vector scan --")
    row = conn.execute("SELECT emb_fv FROM bench_vectors LIMIT 1").fetchone()
    if row is None or row[0] is None:
        print("  SKIP -- bench_vectors.emb_fv is empty (run data_gen.py "
              "--with-fractal-vector first)")
        return
    baseline = conn.execute("SELECT emb_fv FROM bench_vectors LIMIT 1").fetchone()[0]

    rss_before = read_rss_kb(conn)
    if rss_before is None:
        print("  SKIP -- /proc/<pid>/status not readable (non-Linux, or client "
              "and server are on different hosts -- e.g. a remote/containerized "
              "server; this check only means something when they share a host)")
        return

    conn.execute("""
        SELECT * FROM fractal_search_trajectory(
            'bench_vectors', 'emb_fv', %s::fractal_vector, %s::fractal_vector, 10)
    """, (baseline, baseline)).fetchall()
    rss_after = read_rss_kb(conn)

    delta_mb = (rss_after - rss_before) / 1024.0
    print(f"  RSS before: {rss_before / 1024:.1f} MB, after: {rss_after / 1024:.1f} MB, "
          f"delta: {delta_mb:+.1f} MB (n={n} rows scanned)")
    if delta_mb > 50.0:
        print(f"  WARNING: >{50}MB growth from a single scan -- check spi_scan_corpus's "
              f"fractal_vector branch is actually pfree()-ing each detoasted row "
              f"(see its own comment on the pointer-identity check)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default="postgresql:///fractalsql_bench")
    ap.add_argument("--copy-n", type=int, default=20_000,
                    help="row count for the COPY throughput sub-benchmark "
                         "(default: %(default)s -- smaller than the full "
                         "corpus, this arm is O(n) by design so a subset "
                         "is representative)")
    ap.add_argument("--search-queries", type=int, default=10,
                    help="queries to average for the latency sub-benchmark "
                         "(default: %(default)s)")
    args = ap.parse_args()

    with psycopg.connect(args.dsn, autocommit=True) as conn:
        n_total, dim = conn.execute(
            "SELECT count(*), max(array_length(emb_arr, 1)) FROM bench_vectors"
        ).fetchone()
        if n_total == 0:
            print("bench_vectors is empty -- run data_gen.py --with-fractal-vector first",
                  file=sys.stderr)
            return 1
        print(f"vector_type_head_to_head: {n_total} rows, dim={dim}")

        bench_storage_size(conn)
        bench_copy_throughput(conn, args.copy_n, dim)
        bench_search_latency(conn, args.search_queries)
        bench_peak_rss(conn, n_total)

    return 0


if __name__ == "__main__":
    sys.exit(main())
