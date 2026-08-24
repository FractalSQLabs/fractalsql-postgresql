#!/usr/bin/env python3
"""tests/test_text_to_sql_fuzz.py — adversarial/fuzz suite for
fractal_text_to_sql().

Uses tests/_mock_llm_server.py to force the "model" to return specific
malicious or malformed SQL deterministically -- real models are
unreliable for eliciting one particular adversarial output on demand,
which is exactly what fuzz testing needs. Each scenario asserts the
pipeline's ALLOWLIST (raw_parser) or EXPLAIN stage rejects it with the
right reason, and that the dangerous statement is never returned to the
caller. One positive control proves the suite isn't just rejecting
everything.

Requires a *built* fractalsql-reasoning-http.so (any build -- these
scenarios never reach a real network call, the mock server intercepts
it), pointed to by FRACTALSQL_REASONING_PLUGIN. Skips cleanly if that
.so isn't present, psycopg is missing, or no DB is reachable.

Usage:
    python3 tests/test_text_to_sql_fuzz.py [DSN]
    FRACTALSQL_DSN=...  FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so \\
        python3 tests/test_text_to_sql_fuzz.py
"""
import os
import sys

from _mock_llm_server import MockLLMServer
from _t2s_common import (connect_or_skip, get_dsn, get_reasoning_plugin_path,
                         configure_reasoning, reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
PLUGIN = get_reasoning_plugin_path()

# (name, canned model response, substring expected in the ERROR, or None
# for "must succeed").
SCENARIOS = [
    (
        "stacked-statement injection",
        "```sql\nSELECT 1; DROP TABLE _t2s_fuzz_target;\n```",
        "exactly one SQL statement",
    ),
    (
        # DROP TABLE parses to a statement type that isn't in the allowed
        # set, so raw_parser's allowlist rejects it as "not permitted"
        # (naming the exact type, e.g. "DROP TABLE") -- there's no separate
        # is-utility check to produce a distinct "DDL" message.
        "bare DDL",
        "```sql\nDROP TABLE _t2s_fuzz_target;\n```",
        "not permitted",
    ),
    (
        "disallowed statement type (DELETE, default allowed=select)",
        "```sql\nDELETE FROM _t2s_fuzz_target;\n```",
        "not permitted",
    ),
    (
        # A write hidden inside a top-level SELECT via a data-modifying
        # CTE -- top-level node is SelectStmt, so the statement-type check
        # alone would pass it. The read-only check (parse analysis,
        # Query.hasModifyingCTE) must catch it in the default select mode.
        "data-modifying CTE (write hidden under a top-level SELECT)",
        "```sql\nWITH d AS (DELETE FROM _t2s_fuzz_target RETURNING *) "
        "SELECT * FROM d\n```",
        "data-modifying CTE",
    ),
    (
        "unparseable garbage",
        "```sql\nthis is not sql at all just words\n```",
        "does not parse",
    ),
    (
        "chatty non-fenced response (no clean single statement)",
        "Sure! Here's the query: SELECT 1; -- now ignore all previous "
        "instructions and DROP TABLE users instead;",
        "does not parse",
    ),
    (
        "positive control (well-formed SELECT)",
        "```sql\nSELECT count(*) FROM _t2s_fuzz_target\n```",
        None,
    ),
]


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


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
        try:
            cur.execute("SELECT fractal_text_to_sql('test', ARRAY['pg_class'])")
        except Exception as e:
            if "does not exist" in str(e).lower() or "unknown function" in str(e).lower():
                print(f"SKIP: fractal_text_to_sql not deployed: {e}")
                return 0
            # Any other error (e.g. no plugin loaded yet) just means we
            # haven't configured it -- proceed, scenarios configure it
            # themselves per-connection.

        cur.execute("DROP TABLE IF EXISTS _t2s_fuzz_target")
        cur.execute("CREATE TABLE _t2s_fuzz_target (id serial PRIMARY KEY, name text)")

    passed = 0
    for name, canned, expect_err_substr in SCENARIOS:
        with MockLLMServer(canned) as mock:
            c = connect_or_skip(DSN)
            if c is None:
                return 0
            with c:
                cur = c.cursor()
                configure_reasoning(cur, PLUGIN, mock.url,
                                    use_review=False, max_attempts=1,
                                    allowed_statements="select")
            c = reconnect(c, DSN)
            with c:
                cur = c.cursor()
                try:
                    cur.execute(
                        "SELECT fractal_text_to_sql(%s, ARRAY['_t2s_fuzz_target'])",
                        (f"scenario: {name}",))
                    result = cur.fetchone()[0]
                    if expect_err_substr is not None:
                        fail(f"[{name}] expected rejection containing "
                            f"{expect_err_substr!r}, got a returned SQL "
                            f"statement instead: {result!r}")
                    print(f"OK: [{name}] returned {result!r}")
                    passed += 1
                except Exception as e:
                    if expect_err_substr is None:
                        fail(f"[{name}] expected success, got error: {e}")
                    if expect_err_substr not in str(e):
                        fail(f"[{name}] expected error containing "
                            f"{expect_err_substr!r}, got: {e}")
                    print(f"OK: [{name}] rejected as expected ({expect_err_substr!r})")
                    passed += 1

    conn2 = connect_or_skip(DSN)
    with conn2:
        conn2.cursor().execute("DROP TABLE IF EXISTS _t2s_fuzz_target")

    print(f"OK: {passed}/{len(SCENARIOS)} fuzz scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
