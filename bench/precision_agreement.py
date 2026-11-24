#!/usr/bin/env python3
"""bench/precision_agreement.py -- precision-contract agreement metric for the SQL vector functions.

For each dimension it draws unit vectors, computes cosine distance through fractal_vector_cosine_distance and compares it with a float64
reference (numpy) and with the sequential-double reference the contract specifies. Reports top-10 agreement, the maximum absolute and relative
error against the float64 reference, and the share of results BIT-identical to the sequential double reference (1.0000 expected). The ANN
index is a separate benchmark track: see index_head_to_head.py.

  bench/precision_agreement.py [--dsn DSN] [--dims 128,768,1536] [--n 400] [--queries 20] [--embeddings FILE.npy]
"""
import argparse, math, os, sys
import numpy as np
import psycopg


def vec(v):
    return "[" + ",".join(repr(float(x)) for x in v) + "]"


def seq_cos(a, b):
    d = x = y = 0.0
    for p, q in zip(a.tolist(), b.tolist()):
        d += p * q; x += p * p; y += q * q
    return 1.0 if x == 0 or y == 0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))


def run(cur, name, X, Q):
    agree = exact = tot = 0; max_abs = max_rel = 0.0
    X64 = X.astype(np.float64)
    xs = [vec(x) for x in X]
    for q in Q:
        qs = vec(q)
        cur.execute("select fractal_vector_cosine_distance(%s::fractal_vector, x::fractal_vector) from unnest(%s::text[]) with ordinality t(x, n) order by n", (qs, xs))
        sql = np.array([r[0] for r in cur.fetchall()])
        q64 = q.astype(np.float64); ref64 = 1.0 - (X64 @ q64) / (np.linalg.norm(X64, axis=1) * np.linalg.norm(q64))
        seq = np.array([seq_cos(q, x) for x in X])
        agree += int(list(np.lexsort((np.arange(len(X)), sql))[:10]) == list(np.lexsort((np.arange(len(X)), ref64))[:10]))
        err = np.abs(sql - ref64)
        max_abs = max(max_abs, err.max()); max_rel = max(max_rel, (err / np.maximum(np.abs(ref64), 1e-30)).max())
        exact += int((sql == seq).sum()); tot += len(sql)
    print("%-12s top-10 agreement %.3f  max abs err %.2e  max rel err %.2e  bit-identical to the sequential double reference %.4f" % (
        name, agree / len(Q), max_abs, max_rel, exact / tot))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.environ.get("FRACTALSQL_DSN", "postgresql:///fractalsql_bench"))
    ap.add_argument("--dims", default="128,768,1536"); ap.add_argument("--n", type=int, default=400); ap.add_argument("--queries", type=int, default=20)
    ap.add_argument("--embeddings"); ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args(); rng = np.random.default_rng(a.seed)
    with psycopg.connect(a.dsn, autocommit=True) as con:
        cur = con.cursor(); cur.execute("create extension if not exists fractalsql")
        if a.embeddings:
            E = np.load(a.embeddings).astype(np.float32); run(cur, "embeddings", E[:a.n], E[a.n:a.n + a.queries]); return 0
        for d in [int(x) for x in a.dims.split(",")]:
            X = rng.standard_normal((a.n + a.queries, d)).astype(np.float32); X /= np.linalg.norm(X, axis=1, keepdims=True)
            run(cur, "dim %d" % d, X[:a.n], X[a.n:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
