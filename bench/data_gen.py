#!/usr/bin/env python3
"""
bench/data_gen.py — Generate the synthetic "Island" dataset for the
head-to-head benchmark.

Creates N points in d dimensions, organized into K Gaussian clusters.
Cluster centers are placed uniformly in [-1, 1]^d; each point is sampled
from a Gaussian around its assigned center with per-component std=sigma.
Values are clipped to [-1, 1] so they fall within FractalSQL's default
search bounds.

Writes two tables:
    bench_vectors (id int, cluster_id int, emb vector(d), emb_arr float8[]
                   [, emb_fv fractal_vector(d) if --with-fractal-vector])
    bench_centers (cluster_id int, center_arr float8[])

--with-fractal-vector adds an emb_fv fractal_vector(d) column, populated
from the SAME underlying values as emb_arr (modulo the deliberate
float8->float4 narrowing) -- one corpus backing a fair storage/latency
comparison in bench/vector_type_head_to_head.py. Default off so the
existing head_to_head.py (HNSW-vs-Scout) run is unaffected.

Builds an HNSW index on bench_vectors.emb for the pgvector comparison
arm of the benchmark.

Usage:
    python3 bench/data_gen.py --dsn postgresql:///fractalsql_bench \\
        --n 100000 --dim 768 --clusters 50

Defaults: 100k points, dim=128, 50 clusters.
"""

import argparse
import sys
import time

import numpy as np
import psycopg
from pgvector.psycopg import register_vector


def validate_dsn(raw: str) -> str:
    """Portability hardening (sibling v2.0.8's bench-arg guard class, PG half):
    the --dsn CLI value is connection INPUT, not trusted config. Reject
    control characters (a newline inside a conninfo keyword/value line
    smuggles a second keyword past operators reading logs), and reject
    keywords that make the connection a side channel rather than a bench
    target (options= -c injection, passfile=, service=, hostfile=). The
    containment the sqlite column gives its --db file path is impossible
    here (a DSN has no filesystem path); this is the equivalent input pin.
    Returns the validated string unchanged."""
    if any(ord(c) < 0x20 or ord(c) == 0x7f for c in raw):
        raise SystemExit("bench: --dsn contains control characters; refusing")
    try:
        from psycopg import conninfo as _ci
        kv = _ci.conninfo_to_dict(raw)
    except Exception as exc:              # unparseable conninfo
        raise SystemExit(f"bench: --dsn is not a valid conninfo: {exc}")
    bad = {"options", "passfile", "service", "hostfile"}
    found = bad & ({k.lower() for k in kv} if kv else set())
    if found:
        raise SystemExit("bench: --dsn refuses control-surface keyword(s) "
                         + ",".join(sorted(found)))
    return raw

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default="postgresql:///fractalsql_bench",
                    help="PG connection string (default: %(default)s)")
    ap.add_argument("--n", type=int, default=100_000,
                    help="number of points (default: %(default)s)")
    ap.add_argument("--dim", type=int, default=128,
                    help="vector dimension (default: %(default)s). Use --dim 768 "
                         "for realistic-embedding scale; note that HNSW index "
                         "build time and SFS fitness cost both scale linearly "
                         "with dim.")
    ap.add_argument("--clusters", type=int, default=50,
                    help="number of Gaussian clusters (default: %(default)s)")
    ap.add_argument("--sigma", type=float, default=0.05,
                    help="per-component std of intra-cluster noise "
                         "(default: %(default)s)")
    ap.add_argument("--with-fractal-vector", action="store_true",
                    help="also add an emb_fv fractal_vector(dim) column, "
                         "for bench/vector_type_head_to_head.py "
                         "(default: off, keeps the existing HNSW-vs-Scout "
                         "head_to_head.py run unaffected)")
    ap.add_argument("--seed", type=int, default=42,
                    help="RNG seed (default: %(default)s)")
    args = ap.parse_args()

    # int() re-cast at the point of use: --dim is CLI-supplied text that
    # feeds the f-string CREATE TABLE below, and an explicit numeric cast
    # at the use site is what guarantees the interpolated piece is a
    # number, not an identifier. (argparse's type=int already enforces
    # this; this use-site cast is the guard -- and the pinned variable --
    # the SQL string actually relies on.)
    dim = int(args.dim)

    rng = np.random.default_rng(args.seed)

    print(f"Generating {args.n} points in R^{args.dim}, "
          f"{args.clusters} clusters, sigma={args.sigma}")
    t0 = time.perf_counter()

    # Cluster centers in [-1, 1]^dim.
    centers = rng.uniform(-1.0, 1.0, (args.clusters, args.dim))

    # Assign each point to a cluster, generate coords around the center,
    # and clip to the search box.
    labels  = rng.integers(0, args.clusters, size=args.n)
    noise   = rng.normal(0.0, args.sigma, (args.n, args.dim))
    vectors = np.clip(centers[labels] + noise, -1.0, 1.0)

    print(f"  generated in {time.perf_counter() - t0:.1f}s "
          f"({vectors.nbytes / 1e6:.1f} MB)")

    # ---- load into Postgres --------------------------------------------
    print(f"Connecting to {args.dsn} ...")
    with psycopg.connect(validate_dsn(args.dsn), autocommit=True) as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        conn.execute("CREATE EXTENSION IF NOT EXISTS fractalsql;")
        register_vector(conn)

        fv_col = ",\n                emb_fv     fractal_vector(%d) NOT NULL" % dim \
            if args.with_fractal_vector else ""

        conn.execute("DROP TABLE IF EXISTS bench_vectors;")
        conn.execute("DROP TABLE IF EXISTS bench_centers;")
        conn.execute(f"""
            CREATE TABLE bench_vectors (
                id         int       PRIMARY KEY,
                cluster_id int       NOT NULL,
                emb        vector({dim}) NOT NULL,
                emb_arr    float8[]  NOT NULL{fv_col}
            );
        """)
        conn.execute("""
            CREATE TABLE bench_centers (
                cluster_id int       PRIMARY KEY,
                center_arr float8[]  NOT NULL
            );
        """)

        print(f"  inserting {args.clusters} cluster centers ...")
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO bench_centers VALUES (%s, %s)",
                [(i, centers[i].tolist()) for i in range(args.clusters)])

        print(f"  bulk-loading {args.n} vectors via COPY ...")
        t0 = time.perf_counter()
        # Text COPY — float format is simple and fast enough for this scale.
        # Using list representation for both vector and float8[] columns;
        # pgvector registers a text-out adapter that produces "[1,2,...]".
        # fractal_vector's text format is "[1.23,...]" too (matches
        # pgvector's own convention deliberately -- see fractal_vector's
        # own type comment), same coords as emb/emb_arr modulo the
        # deliberate float8->float4 narrowing on the way in -- one corpus
        # backs a fair three-way comparison in
        # vector_type_head_to_head.py.
        fv_cols = ", emb_fv" if args.with_fractal_vector else ""
        with conn.cursor() as cur:
            with cur.copy(f"COPY bench_vectors (id, cluster_id, emb, emb_arr{fv_cols}) "
                          "FROM STDIN WITH (FORMAT TEXT)") as copy:
                for i in range(args.n):
                    v = vectors[i]
                    # vector type's text input:        [1.23,4.56,...]
                    # float8[] type's text input:       {1.23,4.56,...}
                    # fractal_vector's text input:      [1.23,4.56,...]
                    coords = ",".join(f"{x:.6f}" for x in v)
                    vec_lit = f"[{coords}]"
                    arr_lit = "{" + coords + "}"
                    if args.with_fractal_vector:
                        copy.write_row((i, int(labels[i]), vec_lit, arr_lit, vec_lit))
                    else:
                        copy.write_row((i, int(labels[i]), vec_lit, arr_lit))
        print(f"    COPY done in {time.perf_counter() - t0:.1f}s")

        print("  building HNSW index on emb ...")
        t0 = time.perf_counter()
        # Tuned down from defaults (m=16, ef_construction=64) to keep demo
        # build time reasonable at 100k rows. Production deployments should
        # tune up for better recall quality.
        conn.execute("CREATE INDEX bench_emb_hnsw ON bench_vectors "
                     "USING hnsw (emb vector_l2_ops) "
                     "WITH (m = 8, ef_construction = 32);")
        conn.execute("ANALYZE bench_vectors;")
        print(f"    index built in {time.perf_counter() - t0:.1f}s")

        n = conn.execute("SELECT count(*) FROM bench_vectors").fetchone()[0]
        k = conn.execute("SELECT count(*) FROM bench_centers").fetchone()[0]
        print(f"\nDone. bench_vectors={n} rows, bench_centers={k} rows")

    return 0


if __name__ == "__main__":
    sys.exit(main())
