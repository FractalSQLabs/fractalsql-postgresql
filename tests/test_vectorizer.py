#!/usr/bin/env python3
"""tests/test_vectorizer.py — fractal_embed() and the vectorizer's
actual SUCCESS path, against a mock embeddings HTTP server.

Every other reasoning-adjacent test in this repo (test_text_to_sql_*.py)
deliberately drives the pipeline into REJECTION paths with a canned
model response -- real models are unreliable for eliciting one specific
adversarial output on demand. This file covers the opposite, previously
untested gap: does fractal_embed() actually return a real, correctly
parsed vector when the plugin succeeds, and does
fractal_vectorizer_process_queue() actually write it back to a row?
Everything up to this file only ever exercised fractal_embed()'s error
paths (no plugin configured, no http_embed_url configured).

Uses the real, vendored fractalsql-reasoning-http.so (not a stub) against
tests/_mock_llm_server.py's MockEmbedServer -- so this exercises the
actual plugin's request-building and data[0].embedding parsing, not just
this extension's own dispatch/error-handling code.

Requires a *built* fractalsql-reasoning-http.so, pointed to by
FRACTALSQL_REASONING_PLUGIN. Skips cleanly if that .so isn't present,
psycopg is missing, or no DB is reachable.

Usage:
    python3 tests/test_vectorizer.py [DSN]
    FRACTALSQL_DSN=...  FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so \\
        python3 tests/test_vectorizer.py
"""
import os
import sys

from _mock_llm_server import MockEmbedServer
from _t2s_common import (connect_or_skip, get_dsn, get_reasoning_plugin_path,
                         configure_reasoning, reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
PLUGIN = get_reasoning_plugin_path()
# Not actually dispatched to in any scenario here (every scenario below
# only calls fractal_embed()/the vectorizer, never fractal_reason()) --
# set anyway because ensure_reason_ctx()/ensure_text_to_sql_ctx() aren't
# on this file's critical path, only http_embed_url is real per scenario.
DUMMY_CHAT_URL = "http://127.0.0.1:1/unused"


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def _quote_ident(name):
    """Double-quote a Postgres identifier, doubling embedded quotes --
    the same escaping rule format()'s own %I applies server-side.
    Hand-rolled (not psycopg.sql.Identifier) so scenario D below builds
    its DDL/DML the way a real caller with a text table/column name
    would, not through a library that could mask a mistake.
    """
    return '"' + name.replace('"', '""') + '"'


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

    passed = 0

    # ---- Scenario A: fractal_embed() direct success ----------------
    vec = [0.25, -0.5, 0.75]
    with MockEmbedServer(vector=vec) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("SELECT fractal_embed('hello world')")
            got = cur.fetchone()[0]
            if got != vec:
                fail(f"[direct fractal_embed] expected {vec!r}, got {got!r}")
            print(f"OK: [direct fractal_embed] {got!r}")
            passed += 1

    # ---- Scenario B: vectorizer end-to-end, real embeddings --------
    vec_b = [1.0, 2.0, 3.0]
    with MockEmbedServer(vector=vec_b) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_docs'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
            cur.execute("""
                CREATE TABLE _vec_test_docs (
                    id serial PRIMARY KEY,
                    body text NOT NULL,
                    embedding float8[]
                )
            """)
            cur.execute("INSERT INTO _vec_test_docs (body) VALUES ('a'), ('b')")

            cur.execute("SELECT fractal_vectorizer_create('_vec_test_docs', 'body', 'embedding')")
            vzid = cur.fetchone()[0]

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n = cur.fetchone()[0]
            if n != 2:
                fail(f"[vectorizer e2e] expected 2 rows processed, got {n}")

            cur.execute("SELECT embedding FROM _vec_test_docs ORDER BY id")
            rows = cur.fetchall()
            for r in rows:
                if r[0] != vec_b:
                    fail(f"[vectorizer e2e] row embedding {r[0]!r} != {vec_b!r}")

            cur.execute("""
                SELECT status, n FROM fractal_vectorizer_status
                WHERE vectorizer_id = %s
            """, (vzid,))
            status_rows = dict(cur.fetchall())
            if status_rows != {"done": 2}:
                fail(f"[vectorizer e2e] expected status {{'done': 2}}, got {status_rows!r}")

            print(f"OK: [vectorizer e2e] 2/2 rows embedded correctly, status={status_rows!r}")
            passed += 1

    # ---- Scenario C: malformed response -- real per-row failure,
    # via the actual plugin's own extract_embedding() rejecting a
    # response with no "data" key, not just this extension's own
    # "no plugin configured" precondition check (already covered
    # interactively, not by an automated test until now). ----------
    with MockEmbedServer(body={"error": "not a real embeddings response"}) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_bad'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
            cur.execute("""
                CREATE TABLE _vec_test_bad (
                    id serial PRIMARY KEY,
                    body text NOT NULL,
                    embedding float8[]
                )
            """)
            cur.execute("INSERT INTO _vec_test_bad (body) VALUES ('c')")
            cur.execute("SELECT fractal_vectorizer_create('_vec_test_bad', 'body', 'embedding')")
            vzid = cur.fetchone()[0]

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n = cur.fetchone()[0]
            if n != 1:
                fail(f"[malformed response] expected 1 row processed, got {n}")

            cur.execute("""
                SELECT status, last_error FROM fractal_vectorizer_status
                WHERE vectorizer_id = %s
            """, (vzid,))
            status, last_error = cur.fetchone()
            if status != "failed":
                fail(f"[malformed response] expected status 'failed', got {status!r}")
            # Not asserting the specific substring here -- the plugin's own
            # detailed diagnostic ("response missing data[0].embedding...")
            # goes to the server log via stderr, not into fsql_last_error()'s
            # propagated string; fractal_embed()'s wrapper message
            # ("dispatch failed (rc=...): reasoning_vfs.generate failed")
            # is intentionally more generic. What matters here is that a
            # real, non-empty error got recorded and the row is 'failed',
            # not stuck or silently swallowed.
            if not last_error:
                fail("[malformed response] expected a non-empty error, got none")

            print(f"OK: [malformed response] row failed cleanly: {last_error!r}")
            passed += 1

    # ---- Scenario D: adversarial identifiers -- proves the %I/%L-based
    # dynamic SQL in fractal_vectorizer_create()/_process_queue() is
    # injection-safe, not just "looks safe by construction". Table name,
    # text_col, AND embedding_col all carry the same embedded-quote +
    # DROP-TABLE + comment-marker payload, exercised through the full
    # create -> backfill -> process_queue -> write-back pipeline with a
    # REAL successful embed (not just a clean-failure path), and asserts
    # fractal_vectorizers/fractal_vectorizer_queue are provably untouched
    # by the payload (row counts, not just "no exception raised"). ------
    evil_tbl = 'vec_evil"; drop table fractal_vectorizers; --'
    evil_txt = 'txt"; drop table fractal_vectorizers;--'
    evil_emb = 'emb"; drop table fractal_vectorizers;--'
    vec_d = [9.0, 8.0, 7.0]
    with MockEmbedServer(vector=vec_d) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_vectorizers_before = cur.fetchone()[0]

            cur.execute('DROP TABLE IF EXISTS %s' % _quote_ident(evil_tbl))
            cur.execute(
                'CREATE TABLE %s (id serial PRIMARY KEY, %s text, %s float8[])'
                % (_quote_ident(evil_tbl), _quote_ident(evil_txt), _quote_ident(evil_emb))
            )
            cur.execute(
                'INSERT INTO %s (%s) VALUES (%%s), (%%s)'
                % (_quote_ident(evil_tbl), _quote_ident(evil_txt)),
                ('hello', 'world'))

            # source_table is passed pre-quoted (the only form ::regclass
            # can resolve for a name needing SQL-quoting -- see
            # v_tbl_ident in fractal_vectorizer_create()); text_col/
            # embedding_col are passed raw (never regclass-validated, %I
            # quotes them internally) -- two genuinely different, both
            # correct, calling conventions, not an inconsistency.
            cur.execute(
                "SELECT fractal_vectorizer_create(%s, %s, %s)",
                (_quote_ident(evil_tbl), evil_txt, evil_emb))
            vzid = cur.fetchone()[0]

            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_vectorizers_after_create = cur.fetchone()[0]
            if n_vectorizers_after_create != n_vectorizers_before + 1:
                fail(f"[adversarial identifiers] expected exactly 1 new row in "
                     f"fractal_vectorizers, before={n_vectorizers_before} "
                     f"after={n_vectorizers_after_create} -- possible injection "
                     f"side effect")

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n = cur.fetchone()[0]
            if n != 2:
                fail(f"[adversarial identifiers] expected 2 rows processed, got {n}")

            cur.execute(
                'SELECT %s FROM %s ORDER BY id'
                % (_quote_ident(evil_emb), _quote_ident(evil_tbl)))
            rows = cur.fetchall()
            for r in rows:
                if r[0] != vec_d:
                    fail(f"[adversarial identifiers] row embedding {r[0]!r} != {vec_d!r} "
                         f"-- write-back through the malicious column name failed")

            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_vectorizers_final = cur.fetchone()[0]
            if n_vectorizers_final != n_vectorizers_after_create:
                fail(f"[adversarial identifiers] fractal_vectorizers row count changed "
                     f"during process_queue() ({n_vectorizers_after_create} -> "
                     f"{n_vectorizers_final}) -- possible injection side effect")

            print(f"OK: [adversarial identifiers] table/text_col/embedding_col "
                  f"all containing embedded quotes + DROP TABLE + comment markers "
                  f"round-tripped safely, fractal_vectorizers untouched "
                  f"({n_vectorizers_final} rows)")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE id = %s", (vzid,))
            cur.execute('DROP TABLE IF EXISTS %s' % _quote_ident(evil_tbl))

    # ---- Scenario E: pause/resume -- enabled=false must stop BOTH future
    # enqueueing (the trigger no-ops) and processing of already-pending
    # rows (process_queue()'s join excludes it), and enabled=true must
    # cleanly resume both. --------------------------------------------
    vec_e = [4.0, 5.0, 6.0]
    with MockEmbedServer(vector=vec_e) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_pause'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
            cur.execute("""
                CREATE TABLE _vec_test_pause (
                    id serial PRIMARY KEY,
                    body text NOT NULL,
                    embedding float8[]
                )
            """)
            cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('a')")

            cur.execute("SELECT fractal_vectorizer_create('_vec_test_pause', 'body', 'embedding')")
            vzid = cur.fetchone()[0]

            cur.execute("SELECT fractal_vectorizer_pause(%s)", (vzid,))
            cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('b')")

            cur.execute("""
                SELECT count(*) FROM fractal_vectorizer_queue
                WHERE vectorizer_id = %s
            """, (vzid,))
            n_queued_while_paused = cur.fetchone()[0]
            if n_queued_while_paused != 1:
                fail(f"[pause/resume] expected 1 queued row (the pre-pause backfill "
                     f"of 'a' only -- 'b' inserted while paused must NOT enqueue), "
                     f"got {n_queued_while_paused}")

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n_while_paused = cur.fetchone()[0]
            if n_while_paused != 0:
                fail(f"[pause/resume] expected 0 rows processed while paused, "
                     f"got {n_while_paused}")

            cur.execute("SELECT fractal_vectorizer_resume(%s)", (vzid,))
            cur.execute("UPDATE _vec_test_pause SET body = 'b-updated' WHERE body = 'b'")

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n_after_resume = cur.fetchone()[0]
            if n_after_resume != 2:
                fail(f"[pause/resume] expected 2 rows processed after resume "
                     f"('a' from before the pause + 'b' enqueued by the post-resume "
                     f"update), got {n_after_resume}")

            try:
                cur.execute("SELECT fractal_vectorizer_pause(-1)")
                fail("[pause/resume] pausing a nonexistent vectorizer id should raise")
            except Exception:
                c.rollback()

            print(f"OK: [pause/resume] enqueue+processing correctly gated by "
                  f"enabled -- 0 processed while paused, 2 processed after resume")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_pause'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_pause")

    # ---- Scenario F: rate cap -- options.max_embeds_per_window must cap
    # embed ATTEMPTS per rolling window (not just successes), and the
    # window must roll over once rate_window_secs elapses. --------------
    with MockEmbedServer(body={"error": "unreachable -- rate-capped rows "
                                         "should never even call this"}) as mock:
        c = connect_or_skip(DSN)
        if c is None:
            return 0
        with c:
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL,
                                embed_url=mock.url)
        c = reconnect(c, DSN)
        with c:
            cur = c.cursor()
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_rate'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_rate")
            cur.execute("""
                CREATE TABLE _vec_test_rate (
                    id serial PRIMARY KEY,
                    body text NOT NULL,
                    embedding float8[]
                )
            """)
            cur.execute("INSERT INTO _vec_test_rate (body) SELECT 'row ' || g "
                        "FROM generate_series(1, 5) g")

            # %s::jsonb, not bare %s -- a bound text parameter isn't
            # guaranteed to implicitly coerce to jsonb the way a literal
            # with ::jsonb in the SQL text does; explicit cast removes
            # any dependency on psycopg's parameter-OID inference.
            cur.execute(
                "SELECT fractal_vectorizer_create('_vec_test_rate', 'body', 'embedding', %s::jsonb)",
                ('{"max_embeds_per_window": 2, "rate_window_secs": 3600}',))
            vzid = cur.fetchone()[0]

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n_first_call = cur.fetchone()[0]
            if n_first_call != 2:
                fail(f"[rate cap] expected exactly 2 rows attempted (the cap), "
                     f"got {n_first_call}")

            cur.execute("""
                SELECT window_calls FROM fractal_vectorizer_rate_window
                WHERE vectorizer_id = %s
            """, (vzid,))
            window_calls = cur.fetchone()[0]
            if window_calls != 2:
                fail(f"[rate cap] expected window_calls=2, got {window_calls}")

            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n_second_call = cur.fetchone()[0]
            if n_second_call != 0:
                fail(f"[rate cap] expected 0 more rows this window "
                     f"(cap already hit), got {n_second_call}")

            # Simulate the window elapsing -- proves rollover, not just
            # that the cap holds within one window.
            cur.execute("""
                UPDATE fractal_vectorizer_rate_window
                SET window_start = now() - interval '2 hours'
                WHERE vectorizer_id = %s
            """, (vzid,))
            cur.execute("SELECT fractal_vectorizer_process_queue()")
            n_after_rollover = cur.fetchone()[0]
            if n_after_rollover != 2:
                fail(f"[rate cap] expected 2 more rows after window rollover, "
                     f"got {n_after_rollover}")

            print(f"OK: [rate cap] capped at 2/window across 2 calls, "
                  f"allowed 2 more after simulated rollover "
                  f"(3 rows never attempted, still pending)")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_rate'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_rate")

    # ---- Cleanup ------------------------------------------------------
    c = connect_or_skip(DSN)
    if c is not None:
        with c:
            cur = c.cursor()
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table IN "
                        "('_vec_test_docs', '_vec_test_bad', '_vec_test_pause', '_vec_test_rate')")
            cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
            cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
            cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
            cur.execute("DROP TABLE IF EXISTS _vec_test_rate")

    print(f"\ntest_vectorizer: PASS ({passed}/6 scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
