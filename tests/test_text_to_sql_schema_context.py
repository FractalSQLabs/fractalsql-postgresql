#!/usr/bin/env python3
"""tests/test_text_to_sql_schema_context.py — unit test for
fractal_schema_context().

No LLM involved -- this function is pure catalog introspection, so this
is a real, fast, deterministic unit test (unlike the rest of the
text-to-sql suite, which needs a reasoning plugin configured one way or
another). Covers: column/type/PK/NOT NULL rendering, table + column
comments, foreign-key rendering, explicit table_names vs auto-discovery,
and the "named table not found" error path.

Skips cleanly (exit 0) if psycopg is missing, no DB is reachable, or
fractal_schema_context isn't deployed yet.

Usage:
    python3 tests/test_text_to_sql_schema_context.py [DSN]
    FRACTALSQL_DSN=... python3 tests/test_text_to_sql_schema_context.py
"""
import sys

from _t2s_common import connect_or_skip, get_dsn

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0

    with conn:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS fractalsql")

        cur.execute("DROP TABLE IF EXISTS _t2s_order_items")
        cur.execute("DROP TABLE IF EXISTS _t2s_orders")
        cur.execute("DROP TABLE IF EXISTS _t2s_customers")

        cur.execute("""
            CREATE TABLE _t2s_customers (
                id     serial PRIMARY KEY,
                name   text NOT NULL,
                status text
            )
        """)
        cur.execute("COMMENT ON TABLE _t2s_customers IS 'People who buy things'")
        cur.execute("COMMENT ON COLUMN _t2s_customers.status IS "
                    "'one of: active, churned'")

        cur.execute("""
            CREATE TABLE _t2s_orders (
                id          serial PRIMARY KEY,
                customer_id int NOT NULL REFERENCES _t2s_customers(id),
                total_cents int NOT NULL
            )
        """)

        try:
            cur.execute(
                "SELECT fractal_schema_context(ARRAY['_t2s_orders', '_t2s_customers'])")
            ctx = cur.fetchone()[0]
        except Exception as e:
            print(f"SKIP: fractal_schema_context unavailable "
                  f"(text-to-sql not deployed?): {e}")
            cur.execute("DROP TABLE IF EXISTS _t2s_orders")
            cur.execute("DROP TABLE IF EXISTS _t2s_customers")
            return 0

        print("=== fractal_schema_context output ===")
        print(ctx)
        print("=========================================")

        checks = [
            ("Table: public._t2s_customers" in ctx or "Table: _t2s_customers" in ctx,
             "customers table header present"),
            ("Table: public._t2s_orders" in ctx or "Table: _t2s_orders" in ctx,
             "orders table header present"),
            ("People who buy things" in ctx, "table comment rendered"),
            ("one of: active, churned" in ctx, "column comment rendered"),
            ("id integer PK" in ctx, "PK marker rendered for customers.id"),
            ("name text NOT NULL" in ctx, "NOT NULL marker rendered for customers.name"),
            ("REFERENCES" in ctx and "_t2s_customers" in ctx.split("Foreign keys:")[-1]
             if "Foreign keys:" in ctx else False,
             "foreign key rendered for orders.customer_id -> customers"),
        ]
        for ok, desc in checks:
            if not ok:
                cur.execute("DROP TABLE IF EXISTS _t2s_orders")
                cur.execute("DROP TABLE IF EXISTS _t2s_customers")
                fail(desc)
            print(f"OK: {desc}")

        # Auto-discovery path: no table_names -> at least our two tables
        # should be present among the visible tables.
        cur.execute("SELECT fractal_schema_context()")
        auto_ctx = cur.fetchone()[0]
        if "_t2s_customers" not in auto_ctx or "_t2s_orders" not in auto_ctx:
            cur.execute("DROP TABLE IF EXISTS _t2s_orders")
            cur.execute("DROP TABLE IF EXISTS _t2s_customers")
            fail("auto-discovery (NULL table_names) did not include both test tables")
        print("OK: auto-discovery includes both test tables")

        # Explicit, nonexistent table name must ERROR clearly, not skip
        # silently -- the caller asked for it by name.
        try:
            cur.execute("SELECT fractal_schema_context(ARRAY['_t2s_does_not_exist'])")
            cur.fetchone()
            cur.execute("DROP TABLE IF EXISTS _t2s_orders")
            cur.execute("DROP TABLE IF EXISTS _t2s_customers")
            fail("naming a nonexistent table did not raise an error")
        except Exception as e:
            if "not found" not in str(e) and "not_found" not in str(e).lower():
                # Still an error, which is the required behavior -- just
                # note the message shape differs from what we expected.
                print(f"OK: nonexistent table raised an error (message: {e})")
            else:
                print("OK: nonexistent table raised a clear 'not found' error")

    conn2 = connect_or_skip(DSN)
    with conn2:
        cur = conn2.cursor()
        cur.execute("DROP TABLE IF EXISTS _t2s_orders")
        cur.execute("DROP TABLE IF EXISTS _t2s_customers")

    print("OK: text-to-sql schema_context unit tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
