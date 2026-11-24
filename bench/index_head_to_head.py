#!/usr/bin/env python3
"""bench/index_head_to_head.py -- the IVF index (fractal_index_create + the indexed fractal_search) against exact search and pgvector.

Contestants, all on the same table:
  exact     fractal_search with use_index=false: the brute-force scan (ground truth; also what fractal_search does without an index)
  index     fractal_search over a fractal_index, for each vector_format, at the build-time calibrated nprobe and at fixed nprobe values
  hnsw      pgvector's HNSW (cosine) when the vector extension is installed; skipped otherwise
For every contestant it reports recall@k against the exact top-k, median latency per query, bytes of index per row, build seconds and
rows scanned (the "index actually used" check: below the row count). Distances returned by the index are exact; only which rows
reach the verify step is approximate.

  bench/index_head_to_head.py [--dsn DSN] [--n 20000] [--dim 128] [--clusters 50] [--queries 60]
                              [--formats INT8,INT4,FP16,FP32] [--embeddings FILE.npy]
"""
import argparse, json, os, statistics, sys, time
import numpy as np
import psycopg


def lit(v):
    return "{" + ",".join(repr(float(x)) for x in v) + "}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.environ.get("FRACTALSQL_DSN", "postgresql:///fractalsql_bench"))
    ap.add_argument("--n", type=int, default=20000); ap.add_argument("--dim", type=int, default=128); ap.add_argument("--clusters", type=int, default=50)
    ap.add_argument("--queries", type=int, default=60); ap.add_argument("--formats", default="INT8,INT4,FP16,FP32")
    ap.add_argument("--embeddings"); ap.add_argument("--seed", type=int, default=7); ap.add_argument("--k", type=int, default=10)
    a = ap.parse_args(); rng = np.random.default_rng(a.seed)
    if a.embeddings:
        X = np.load(a.embeddings).astype(np.float32)
    else:
        cent = rng.standard_normal((a.clusters, a.dim))
        X = (cent[rng.integers(0, a.clusters, a.n)] + 0.25 * rng.standard_normal((a.n, a.dim))).astype(np.float32)
        X /= np.linalg.norm(X, axis=1, keepdims=True)
    n, d = X.shape
    with psycopg.connect(a.dsn, autocommit=True) as con:
        cur = con.cursor()
        cur.execute("create extension if not exists fractalsql")
        cur.execute("drop table if exists bench_ix cascade"); cur.execute("create table bench_ix(id int primary key, emb float8[])")
        with cur.copy("copy bench_ix(id, emb) from stdin") as cp:
            for i in range(n):
                cp.write_row((i + 1, lit(X[i])))
        cur.execute("analyze bench_ix")
        qi = rng.choice(n, size=min(a.queries, n), replace=False); Q = [lit(X[i]) for i in qi]
        print("rows %d dim %d queries %d, recall@%d against the exact top-%d" % (n, d, len(Q), a.k, a.k))

        def run(opts, label):
            lat = []; res = []
            for q in Q:
                t0 = time.perf_counter()
                cur.execute("select doc_id from fractal_search('bench_ix','emb',%s::float8[],%s,%s::jsonb)", (q, a.k + 1, json.dumps(opts)))
                lat.append((time.perf_counter() - t0) * 1000); res.append([int(r[0]) for r in cur.fetchall()])
            return res, statistics.median(lat)

        truth, lat_exact = run({"use_index": False}, "exact")
        truth = [[i for i in r if i != qi[j] + 1][:a.k] for j, r in enumerate(truth)]
        print("%-28s recall %.3f  median %7.2f ms  rows scanned %9d" % ("exact (scan)", 1.0, lat_exact, n))

        def recall(res):
            return sum(len(set([i for i in r if i != qi[j] + 1][:a.k]) & set(truth[j])) for j, r in enumerate(res)) / (a.k * len(res))

        try:
            cur.execute("create extension if not exists vector")
            cur.execute("alter table bench_ix add column pv vector(%d)" % d)
            cur.execute("update bench_ix set pv = emb::real[]::vector")
            t0 = time.time(); cur.execute("create index bench_ix_hnsw on bench_ix using hnsw (pv vector_cosine_ops)")
            tb = time.time() - t0
            lat = []; res = []
            for j in qi:
                t0 = time.perf_counter()
                cur.execute("select id from bench_ix order by pv <=> %s::vector limit %s", (lit(X[j]).replace("{", "[").replace("}", "]"), a.k + 1))
                lat.append((time.perf_counter() - t0) * 1000); res.append([r[0] for r in cur.fetchall()])
            print("%-28s recall %.3f  median %7.2f ms  build %.1fs" % ("pgvector hnsw", recall(res), statistics.median(lat), tb))
        except Exception as e:  # noqa
            print("%-28s skipped (%s)" % ("pgvector hnsw", str(e).splitlines()[0][:60]))
        for fmt in [f.strip().upper() for f in a.formats.split(",")]:
            t0 = time.time()
            cur.execute("select fractal_index_create('bench_ix','emb',%s::jsonb)", (json.dumps({"name": "ix_" + fmt, "vector_format": fmt}),))
            info = cur.fetchone()[0]
            print("%s: nlist %d pca_dim %d, %.1f bytes/row (%.1f MB), build %.1fs, calibrated nprobe %s" % (
                fmt, info["nlist"], info["pca_dim"], info["bytes"] / info["rows"], info["bytes"] / 1e6, time.time() - t0, info.get("calibrated_nprobe", "-")))
            for label, np_opt in (("calibrated", None), ("nprobe 4", 4), ("nprobe 16", 16), ("every cell", info["nlist"])):
                opts = {"index": "ix_" + fmt}
                if np_opt:
                    opts["nprobe"] = np_opt
                res, lat = run(opts, label)
                cur.execute("select fractal_index_info(%s)->'last_search'", ("ix_" + fmt,)); ls = cur.fetchone()[0]
                print("   %-24s recall %.3f  median %7.2f ms  rows scanned %9d (used_index=%s)" % (label, recall(res), lat, ls["rows_scanned"], ls["used_index"]))
            cur.execute("select fractal_index_drop(%s)", ("ix_" + fmt,))
        cur.execute("drop table bench_ix cascade")


if __name__ == "__main__":
    sys.exit(main())
