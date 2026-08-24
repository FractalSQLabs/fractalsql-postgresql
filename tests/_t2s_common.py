"""tests/_t2s_common.py — shared helpers for the fractal_text_to_sql()
test suite (test_text_to_sql_*.py).

Changing fractalsql.reasoning_plugin (or any GUC ensure_ctx() forwards
into the backend's environment) only takes effect for a BACKEND that
hasn't called it yet -- ensure_ctx() is lazy-per-backend and short-circuits
on every call after the first. ALTER SYSTEM + pg_reload_conf() alone is
not enough; the caller must also reconnect to get a fresh backend. See
reconnect() below and the demo/text-to-sql-spike-*.sql files, which hit
this the same way.
"""
import os
import sys

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed")
    sys.exit(0)


def get_dsn():
    return os.environ.get("FRACTALSQL_DSN", "postgresql:///fractalsql_bench")


def get_reasoning_plugin_path():
    return os.environ.get(
        "FRACTALSQL_REASONING_PLUGIN",
        "/usr/lib/postgresql/16/lib/fractalsql-reasoning-http.so")


def connect_or_skip(dsn=None):
    dsn = dsn or get_dsn()
    try:
        return psycopg.connect(dsn, autocommit=True)
    except Exception as e:
        print(f"SKIP: no DB reachable at {dsn}: {e}")
        return None


def _sql_literal(value):
    """Quote `value` as a SQL string literal. ALTER SYSTEM SET's grammar
    is not the general expression parser -- some builds reject a bind
    parameter in the value position -- so build the literal directly,
    matching demo/text-to-sql-spike-*.sql's own proven-working approach.
    Test-fixture-controlled values only (file paths, localhost URLs), not
    arbitrary user input."""
    return "'" + str(value).replace("'", "''") + "'"


def configure_reasoning(cur, plugin_path, http_url, model=None,
                        use_review=None, max_attempts=None,
                        allowed_statements=None,
                        embed_url=None, embed_model=None):
    """ALTER SYSTEM + reload the reasoning GUCs. Caller must reconnect
    afterward (see reconnect()) for a fresh backend to pick them up."""
    # Force the fractalsql module to load in THIS backend before setting
    # its GUCs. ALTER SYSTEM SET refuses a custom GUC it has never seen
    # unless the owning module is loaded (registering the GUC) or a
    # placeholder already exists in a config file. A fresh backend that
    # hasn't yet called a fractalsql function has neither, so the
    # text_to_sql_* GUCs would be rejected as "unrecognized". Calling any
    # fractalsql function runs _PG_init, which DefineCustom*Variable-
    # registers all of them. fractal_version() is the cheapest (no
    # reasoning plugin required).
    cur.execute("SELECT fractal_version()")
    cur.execute(f"ALTER SYSTEM SET fractalsql.reasoning_plugin = {_sql_literal(plugin_path)}")
    cur.execute(f"ALTER SYSTEM SET fractalsql.http_url = {_sql_literal(http_url)}")
    cur.execute("ALTER SYSTEM SET fractalsql.http_allow_plaintext = on")
    if model is not None:
        cur.execute(f"ALTER SYSTEM SET fractalsql.http_model = {_sql_literal(model)}")
    if use_review is not None:
        cur.execute(f"ALTER SYSTEM SET fractalsql.text_to_sql_use_review = "
                    f"{'on' if use_review else 'off'}")
    if max_attempts is not None:
        cur.execute(f"ALTER SYSTEM SET fractalsql.text_to_sql_max_attempts = {int(max_attempts)}")
    if allowed_statements is not None:
        cur.execute("ALTER SYSTEM SET fractalsql.text_to_sql_allowed_statements = "
                    f"{_sql_literal(allowed_statements)}")
    if embed_url is not None:
        cur.execute(f"ALTER SYSTEM SET fractalsql.http_embed_url = {_sql_literal(embed_url)}")
    if embed_model is not None:
        cur.execute(f"ALTER SYSTEM SET fractalsql.http_embed_model = {_sql_literal(embed_model)}")
    cur.execute("SELECT pg_reload_conf()")


def reconnect(conn, dsn=None):
    """Close `conn` and open a fresh connection/backend -- required after
    configure_reasoning() for the new GUC values to actually take effect
    (see module docstring)."""
    conn.close()
    return psycopg.connect(dsn or get_dsn(), autocommit=True)
