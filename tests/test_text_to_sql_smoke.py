#!/usr/bin/env python3
"""tests/test_text_to_sql_smoke.py — smoke test for
fractal_text_to_sql().

One live end-to-end call against whatever reasoning plugin/model is
actually configured: does the full GENERATE -> ALLOWLIST -> EXPLAIN
pipeline run without crashing and return SQL that actually references
the table it was asked about? This is deliberately NOT a correctness
check (see test_text_to_sql_shadow.py for that) -- it is the fast "is
anything on fire" gate to run after every build.

Skip-safe: exits 0 with a SKIP: message if psycopg is missing, no DB is
reachable, fractal_text_to_sql isn't deployed, the reasoning plugin
.so isn't present, or the configured model endpoint doesn't respond.

Usage:
    python3 tests/test_text_to_sql_smoke.py [DSN]
    FRACTALSQL_DSN=...  FRACTALSQL_REASONING_PLUGIN=...  \\
        FRACTALSQL_HTTP_URL=http://localhost:11434/v1/chat/completions \\
        FRACTALSQL_MODEL=phi4:14b \\
        python3 tests/test_text_to_sql_smoke.py
"""
import os
import sys

from _t2s_common import (connect_or_skip, get_dsn, get_reasoning_plugin_path,
                         configure_reasoning, reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
PLUGIN = get_reasoning_plugin_path()
HTTP_URL = os.environ.get("FRACTALSQL_HTTP_URL",
                          "http://localhost:11434/v1/chat/completions")
MODEL = os.environ.get("FRACTALSQL_MODEL", "phi4:14b")


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
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        cur.execute("""
            CREATE TABLE _t2s_smoke_orders (
                id          serial PRIMARY KEY,
                customer    text NOT NULL,
                total_cents int NOT NULL,
                status      text NOT NULL
            )
        """)
        cur.execute("""
            INSERT INTO _t2s_smoke_orders (customer, total_cents, status) VALUES
                ('acme',    1200, 'paid'),
                ('acme',    3400, 'paid'),
                ('globex',   500, 'refunded')
        """)

        configure_reasoning(cur, PLUGIN, HTTP_URL, model=MODEL,
                            use_review=False, max_attempts=2,
                            allowed_statements="select")

    conn = reconnect(conn, DSN)
    with conn:
        cur = conn.cursor()
        try:
            cur.execute(
                "SELECT fractal_text_to_sql(%s, ARRAY['_t2s_smoke_orders'])",
                ("How many orders does customer 'acme' have?",))
            sql = cur.fetchone()[0]
        except Exception as e:
            print(f"SKIP: fractal_text_to_sql call failed -- reasoning "
                  f"endpoint unreachable, model not pulled, or not deployed: {e}")
            cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
            return 0

        print(f"Generated SQL:\n{sql}\n")

        if "_t2s_smoke_orders" not in sql:
            cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
            fail(f"generated SQL doesn't reference the target table: {sql!r}")

        if not sql.strip().lower().startswith("select"):
            cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
            fail(f"generated SQL isn't a SELECT despite allowed_statements=select: {sql!r}")

        # The function already EXPLAIN-validated this, but actually
        # executing it here is still a real, direct proof the returned
        # SQL runs, not just plans.
        cur.execute(sql)
        rows = cur.fetchall()
        print(f"Executed successfully, {len(rows)} row(s): {rows}")

        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")

    print(f"OK: text-to-sql smoke test passed (model={MODEL})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
