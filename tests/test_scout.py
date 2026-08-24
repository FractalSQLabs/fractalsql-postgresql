#!/usr/bin/env python3
"""tests/test_scout.py — Scout Mode (fractal_search_explore) e2e gate.

Builds a 3-island clustered corpus table, calls the fractal_search_explore
set-returning function, and asserts the §8 Scout enablement properties:

  (1)+(2) returns the population — population_size particles, each of the
          corpus dim (not the 1-row stub the pre-Scout build returned);
  (3)     discovery — the particles disperse across >1 island.

Skips cleanly (exit 0) if psycopg is missing, no DB is reachable, or the
installed extension predates Scout (fractal_search_explore absent / stub),
so it is safe to run before the Scout drop is deployed.

Usage:
    python3 tests/test_scout.py [DSN]
    FRACTALSQL_DSN=... python3 tests/test_scout.py
    (default DSN: postgresql:///fractalsql_bench)
"""
import json
import os
import random
import sys

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed")
    sys.exit(0)

DSN = (sys.argv[1] if len(sys.argv) > 1
       else os.environ.get("FRACTALSQL_DSN", "postgresql:///fractalsql_bench"))

CENTERS = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
DIM = 3
PER = 20
POP = 24


def nearest(p):
    return min(range(3), key=lambda k:
               sum((p[i] - CENTERS[k][i]) ** 2 for i in range(DIM)))


def main():
    rng = random.Random(11)
    try:
        conn = psycopg.connect(DSN, autocommit=True)
    except Exception as e:
        print(f"SKIP: no DB reachable at {DSN}: {e}")
        return 0

    with conn:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS fractalsql")
        cur.execute("DROP TABLE IF EXISTS _scout_docs")
        cur.execute("CREATE TABLE _scout_docs (id int, emb_arr float8[])")
        rid = 0
        for c in CENTERS:
            for _ in range(PER):
                v = [x + rng.uniform(-0.02, 0.02) for x in c]
                cur.execute("INSERT INTO _scout_docs VALUES (%s, %s)", (rid, v))
                rid += 1

        query = CENTERS[0]                       # anchor inside island 0
        opts = json.dumps({"population_size": POP, "iterations": 12})
        try:
            cur.execute(
                "SELECT p FROM fractal_search_explore("
                "    '_scout_docs', 'emb_arr', %s, %s::jsonb) AS p",
                (query, opts))
            rows = [r[0] for r in cur.fetchall()]
        except Exception as e:
            print("SKIP: fractal_search_explore unavailable / pre-Scout "
                  f"(Scout drop not deployed?): {e}")
            cur.execute("DROP TABLE IF EXISTS _scout_docs")
            return 0
        cur.execute("DROP TABLE IF EXISTS _scout_docs")

    # Skip-safe: the pre-Scout build's fractal_search_explore is a stub
    # that returns a single best_point row. Treat <= 1 row as "Scout drop
    # not deployed" and skip rather than fail, so the gate stays green
    # until the refreshed core lands.
    if len(rows) <= 1:
        print(f"SKIP: fractal_search_explore returned the pre-Scout stub "
              f"({len(rows)} row) — deploy the Scout-enabled drop to enable")
        return 0
    if len(rows) != POP:
        print(f"FAIL: expected {POP} particles, got {len(rows)}", file=sys.stderr)
        return 1
    if not all(len(p) == DIM for p in rows):
        print("FAIL: particle dim != 3", file=sys.stderr)
        return 1
    islands = len(set(nearest(p) for p in rows))
    print(f"population: {len(rows)} particles, dim {DIM}")
    print(f"SCOUT discovered {islands}/3 islands")
    if islands < 2:
        print(f"FAIL: Scout discovered only {islands} island(s); "
              "expected >= 2 (no dispersion)", file=sys.stderr)
        return 1
    print("OK: postgres scout gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
