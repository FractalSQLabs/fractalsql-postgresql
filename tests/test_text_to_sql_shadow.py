#!/usr/bin/env python3
"""tests/test_text_to_sql_shadow.py — shadow test for
fractal_text_to_sql(), and the script for validating the feature
against real local models (phi4:14b, gemma4:12b, gpt-oss:20b by default).

"Shadow" here means: run the real pipeline (with REVIEW turned on) and
then independently EXECUTE the SQL it returns, comparing the actual
result against a ground truth computed directly in SQL -- shadowing the
pipeline's own implicit verdict (it returned successfully = GENERATE +
REVIEW + ALLOWLIST + EXPLAIN all approved it) against ground truth,
without the ground-truth check gating anything inside the pipeline
itself. This formalizes demo/text-to-sql-spike-4-negative-control.sql's
manual methodology (does review's PASS/FAIL actually track correctness,
not just plausibility?) into a repeatable, scriptable check against the
real built feature instead of a hand-rolled spike.

The question below is the same hard multi-constraint case validated
earlier by hand against all three models (grouping + a HAVING-shaped
exclusion an LLM can plausibly miss) -- see the spike files for the
manual run this automates.

Per-model outcomes:
    PASS           -- pipeline returned SQL, and it matches ground truth
    WRONG-ANSWER    -- pipeline returned SQL, but it does NOT match ground
                       truth -- review/EXPLAIN approved something wrong.
                       This is the real thing this test exists to catch.
    GENERATION-FAILED -- pipeline exhausted its retry budget and errored;
                       disappointing but not a safety failure (it refused
                       to return something it couldn't validate).
    UNREACHABLE     -- couldn't reach the model endpoint at all; skipped,
                       doesn't count for or against the run.

Exits 1 only if at least one reachable model produced a WRONG-ANSWER.
Exits 0 (with a SKIP note) if no configured model was reachable at all.

Usage:
    python3 tests/test_text_to_sql_shadow.py [DSN]
    FRACTALSQL_DSN=...  FRACTALSQL_REASONING_PLUGIN=...  \\
        FRACTALSQL_HTTP_URL=http://localhost:11434/v1/chat/completions \\
        FRACTALSQL_MODELS=phi4:14b,gemma4:12b,gpt-oss:20b \\
        python3 tests/test_text_to_sql_shadow.py
"""
import os
import sys

from _t2s_common import (connect_or_skip, get_dsn, get_reasoning_plugin_path,
                         configure_reasoning, reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
PLUGIN = get_reasoning_plugin_path()
HTTP_URL = os.environ.get("FRACTALSQL_HTTP_URL",
                          "http://localhost:11434/v1/chat/completions")
MODELS = [m.strip() for m in
          os.environ.get("FRACTALSQL_MODELS",
                         "phi4:14b,gemma4:12b,gpt-oss:20b").split(",") if m.strip()]

QUESTION = ("For each service, show the count of alerts broken down by "
           "severity level, but only include services that have logged "
           "at least one critical-severity alert.")

GROUND_TRUTH_SQL = """
    SELECT service, severity, COUNT(*)
    FROM _t2s_shadow_alerts a
    WHERE EXISTS (
        SELECT 1 FROM _t2s_shadow_alerts c
        WHERE c.service = a.service AND c.severity = 'critical'
    )
    GROUP BY service, severity
    ORDER BY service, severity
"""

SEED_ROWS = [
    ("payments",     "info"),
    ("payments",     "warning"),
    ("checkout",     "info"),
    ("checkout",     "warning"),
    ("checkout",     "critical"),
    ("checkout",     "critical"),
    ("auth-service", "warning"),
    ("search",       "info"),
    ("search",       "critical"),
    ("search",       "warning"),
]


def setup_fixture(cur):
    cur.execute("DROP TABLE IF EXISTS _t2s_shadow_alerts")
    cur.execute("""
        CREATE TABLE _t2s_shadow_alerts (
            id       serial PRIMARY KEY,
            service  text NOT NULL,
            severity text NOT NULL CHECK (severity IN ('info','warning','critical')),
            message  text
        )
    """)
    cur.executemany(
        "INSERT INTO _t2s_shadow_alerts (service, severity) VALUES (%s, %s)",
        SEED_ROWS)


def main():
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0

    if not os.path.isfile(PLUGIN):
        print(f"SKIP: reasoning plugin not found at {PLUGIN} "
              "(set FRACTALSQL_REASONING_PLUGIN)")
        return 0

    with conn:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS fractalsql")
        setup_fixture(cur)
        cur.execute(GROUND_TRUTH_SQL)
        ground_truth = sorted(cur.fetchall())

    print(f"Question: {QUESTION}")
    print(f"Ground truth ({len(ground_truth)} rows): {ground_truth}\n")

    results = {}
    for model in MODELS:
        print(f"=== {model} ===")
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, HTTP_URL, model=model,
                                use_review=True, max_attempts=2,
                                allowed_statements="select")
        c = reconnect(c, DSN)
        try:
            with c:
                cur = c.cursor()
                try:
                    cur.execute(
                        "SELECT fractal_text_to_sql(%s, ARRAY['_t2s_shadow_alerts'])",
                        (QUESTION,))
                    sql = cur.fetchone()[0]
                except Exception as e:
                    msg = str(e).lower()
                    if ("could not connect" in msg or "connection refused" in msg
                            or "timed out" in msg or "timeout" in msg):
                        print(f"UNREACHABLE: {e}\n")
                        results[model] = "UNREACHABLE"
                        continue
                    print(f"GENERATION-FAILED: {e}\n")
                    results[model] = "GENERATION-FAILED"
                    continue

                print(f"Generated SQL:\n{sql}\n")
                cur.execute(sql)
                actual = sorted(cur.fetchall())
                if actual == ground_truth:
                    print(f"PASS: matches ground truth ({len(actual)} rows)\n")
                    results[model] = "PASS"
                else:
                    print(f"WRONG-ANSWER: got {actual}, expected {ground_truth}\n")
                    results[model] = "WRONG-ANSWER"
        except Exception as e:
            print(f"UNREACHABLE: connection-level failure: {e}\n")
            results[model] = "UNREACHABLE"

    conn2 = connect_or_skip(DSN)
    with conn2:
        conn2.cursor().execute("DROP TABLE IF EXISTS _t2s_shadow_alerts")

    print("=== Summary ===")
    for model, outcome in results.items():
        print(f"  {model}: {outcome}")

    reachable = {m: o for m, o in results.items() if o != "UNREACHABLE"}
    if not reachable:
        print("\nSKIP: no configured model was reachable -- is Ollama running "
              "and are these models pulled?")
        return 0

    wrong = [m for m, o in reachable.items() if o == "WRONG-ANSWER"]
    if wrong:
        print(f"\nFAIL: {wrong} produced an approved-but-incorrect answer "
              "-- review/EXPLAIN rubber-stamped a wrong result", file=sys.stderr)
        return 1

    print("\nOK: no model produced an approved-but-incorrect answer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
