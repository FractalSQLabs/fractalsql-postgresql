#!/usr/bin/env python3
"""tests/test_vector_type.py — the fractal_vector native type: typmod
enforcement, binary I/O, operator correctness, float8[] casts, and the
vectorizer dimension-enforcement ("Gap-1") proof.

Unlike test_vectorizer.py, most scenarios here don't need the reasoning
plugin at all -- fractal_vector is pure type/operator mechanics. Only
the last scenario (vectorizer dimension enforcement) touches
fractal_embed()/MockEmbedServer, mirroring test_vectorizer.py's own
pattern for that piece.

Each scenario reconnects fresh (`with conn:` closes the connection on
exit in psycopg3, unlike psycopg2 -- see Connection.__exit__), matching
test_vectorizer.py's own per-scenario connect_or_skip()/with c: shape.

Usage:
    python3 tests/test_vector_type.py [DSN]
    FRACTALSQL_DSN=... python3 tests/test_vector_type.py
"""
import math
import os
import struct
import sys

from _mock_llm_server import MockEmbedServer
from _t2s_common import (connect_or_skip, get_dsn, get_reasoning_plugin_path,
                         configure_reasoning, reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
PLUGIN = get_reasoning_plugin_path()
DUMMY_CHAT_URL = "http://127.0.0.1:1/unused"


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def f4(x):
    """Round a Python float through float32, the same narrowing every
    fractal_vector value goes through on the way in -- expected values
    in binary-round-trip assertions must be compared against THIS, not
    the original float8 literal, or a real, working test would flag
    ordinary float32 precision loss as a failure."""
    return struct.unpack('f', struct.pack('f', x))[0]


def main():
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0
    with conn:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS fractalsql")

    passed = 0

    # ---- Scenario 1: typmod dimension mismatch -- hard error, not
    # truncation or silent acceptance. -----------------------------
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0
    with conn:
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS _fv_test_typmod")
        cur.execute("CREATE TABLE _fv_test_typmod (id serial PRIMARY KEY, "
                    "embedding fractal_vector(3))")
        cur.execute("INSERT INTO _fv_test_typmod (embedding) VALUES ('[1,2,3]')")

        try:
            cur.execute("INSERT INTO _fv_test_typmod (embedding) VALUES ('[1,2]')")
            fail("[typmod mismatch] expected an error inserting a 2-element "
                 "value into fractal_vector(3), got none")
        except Exception as e:
            conn.rollback()
            if "dimension" not in str(e).lower():
                fail(f"[typmod mismatch] got an error, but not a dimension "
                     f"one: {e!r}")
            print(f"OK: [typmod mismatch] rejected cleanly: {e}")
            passed += 1

    # ---- Scenario 2: binary round-trip -- a custom psycopg3 binary
    # Dumper exercises fractal_vector_recv (the input parameter is sent
    # as wire-format bytes, not text); fractal_vector_send is exercised
    # by calling it explicitly and getting bytea back (a well-known
    # type psycopg parses natively, decoded here by hand) -- avoids
    # relying on psycopg's automatic binary-column-format negotiation
    # for a custom OID, which turned out to be unreliable across
    # multiple connections in one process (worked on the first
    # connection in a script, silently fell back to raw undecoded bytes
    # on the second+ -- a psycopg3 client-side quirk unrelated to this
    # extension's C code, which this approach sidesteps entirely rather
    # than depending on). Expected values are compared post-f4()
    # narrowing (every fractal_vector value is narrowed to float32 on
    # the way in). ------------------------------------------------
    from psycopg.adapt import Dumper
    from psycopg.pq import Format

    conn = connect_or_skip(DSN)
    if conn is None:
        return 0
    with conn:
        cur = conn.cursor()
        cur.execute("SELECT 'fractal_vector'::regtype::oid")
        fv_oid = cur.fetchone()[0]

        class _FV(list):
            """Marker subclass so this dumper doesn't shadow plain list
            (float8[]) parameter binding elsewhere in the test suite."""
            pass

        class FVBinaryDumper(Dumper):
            format = Format.BINARY
            oid = fv_oid

            def dump(self, obj):
                n = len(obj)
                return struct.pack(f'!h{n}f', n, *obj)

        conn.adapters.register_dumper(_FV, FVBinaryDumper)

        original = [0.1, -2.5, 3.333333, 100.0, -0.0001]
        cur.execute("SELECT fractal_vector_send(%s::fractal_vector)", (_FV(original),))
        raw = bytes(cur.fetchone()[0])
        (n,) = struct.unpack_from('!h', raw, 0)
        got = list(struct.unpack_from(f'!{n}f', raw, 2))
        expected = [f4(x) for x in original]
        if len(got) != len(expected) or any(
                not math.isclose(g, e, rel_tol=1e-6) for g, e in zip(got, expected)):
            fail(f"[binary round-trip] expected {expected!r} (float32-narrowed), "
                 f"got {got!r}")
        print(f"OK: [binary round-trip] {original!r} -> {got!r} "
              f"(binary recv via parameter dumper + explicit send() call)")
        passed += 1

    # ---- Scenario 3: operator correctness on fixed, hand-computed
    # vectors. -----------------------------------------------------
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0
    with conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT
                '[1,0]'::fractal_vector <-> '[0,1]'::fractal_vector,
                '[1,0]'::fractal_vector <=> '[0,1]'::fractal_vector,
                '[1,0]'::fractal_vector <#> '[0,1]'::fractal_vector,
                '[2,0]'::fractal_vector <=> '[4,0]'::fractal_vector
        """)
        l2, cosine, neg_ip, cosine_parallel = cur.fetchone()
        checks = [
            (math.isclose(l2, math.sqrt(2), rel_tol=1e-6), f"L2 distance {l2} != sqrt(2)"),
            (math.isclose(cosine, 1.0, abs_tol=1e-6), f"cosine distance {cosine} != 1.0 (orthogonal)"),
            (math.isclose(neg_ip, 0.0, abs_tol=1e-6), f"negative inner product {neg_ip} != 0.0 (orthogonal)"),
            (math.isclose(cosine_parallel, 0.0, abs_tol=1e-6), f"cosine distance {cosine_parallel} != 0.0 (parallel)"),
        ]
        for ok, msg in checks:
            if not ok:
                fail(f"[operator correctness] {msg}")
        print(f"OK: [operator correctness] L2={l2:.6f} cosine_orth={cosine:.6f} "
              f"neg_ip_orth={neg_ip:.6f} cosine_parallel={cosine_parallel:.6f}")
        passed += 1

    # ---- Scenario 4: casts to/from float8[], including a wrong-length
    # assignment into a typmod'd column. -----------------------------
    conn = connect_or_skip(DSN)
    if conn is None:
        return 0
    with conn:
        cur = conn.cursor()
        cur.execute("SELECT ('{1,2,3}'::float8[]::fractal_vector)::float8[]")
        round_tripped = cur.fetchone()[0]
        if round_tripped != [1.0, 2.0, 3.0]:
            fail(f"[casts] float8[] -> fractal_vector -> float8[] round-trip "
                 f"gave {round_tripped!r}, expected [1.0, 2.0, 3.0]")

        cur.execute("UPDATE _fv_test_typmod SET embedding = %s::float8[] "
                    "WHERE id = (SELECT id FROM _fv_test_typmod LIMIT 1)",
                    ([9.0, 9.0, 9.0],))

        try:
            cur.execute("UPDATE _fv_test_typmod SET embedding = %s::float8[] "
                        "WHERE id = (SELECT id FROM _fv_test_typmod LIMIT 1)",
                        ([1.0, 1.0],))
            fail("[casts] expected an error assigning a 2-element float8[] "
                 "into fractal_vector(3) via the assignment cast, got none")
        except Exception as e:
            conn.rollback()
            if "dimension" not in str(e).lower():
                fail(f"[casts] got an error, but not a dimension one: {e!r}")
            print(f"OK: [casts] float8[]<->fractal_vector round-trip correct "
                  f"({round_tripped!r}); assignment-cast dimension mismatch "
                  f"rejected cleanly: {e}")
            passed += 1

    # ---- Scenario 5: the actual Gap-1 proof -- fractal_vectorizer_
    # process_queue() must fail a row (not crash, not silently accept)
    # when the embed endpoint returns the wrong dimension for the
    # target fractal_vector(n) column, with ZERO changes to
    # fractal_vectorizer_create/process_queue's own PL/pgSQL. Other
    # rows in the same batch must be unaffected. ---------------------
    if not os.path.isfile(PLUGIN):
        print(f"SKIP: [Gap-1] reasoning plugin not found at {PLUGIN} "
              "(set FRACTALSQL_REASONING_PLUGIN)")
    else:
        wrong_dim_vec = [1.0, 2.0]   # column below is fractal_vector(3)
        with MockEmbedServer(vector=wrong_dim_vec) as mock:
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
                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_fv_gap1'")
                cur.execute("DROP TABLE IF EXISTS _vec_test_fv_gap1")
                cur.execute("""
                    CREATE TABLE _vec_test_fv_gap1 (
                        id serial PRIMARY KEY,
                        body text NOT NULL,
                        embedding fractal_vector(3)
                    )
                """)
                cur.execute("INSERT INTO _vec_test_fv_gap1 (body) VALUES ('a'), ('b')")

                cur.execute("SELECT fractal_vectorizer_create('_vec_test_fv_gap1', 'body', 'embedding')")
                vzid = cur.fetchone()[0]

                cur.execute("SELECT fractal_vectorizer_process_queue()")
                n = cur.fetchone()[0]
                if n != 2:
                    fail(f"[Gap-1] expected 2 rows attempted, got {n}")

                cur.execute("""
                    SELECT status, n, last_error FROM fractal_vectorizer_status
                    WHERE vectorizer_id = %s
                """, (vzid,))
                rows = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
                if "failed" not in rows or rows["failed"][0] != 2:
                    fail(f"[Gap-1] expected both rows 'failed' (embed endpoint "
                         f"returned dim 2, column is fractal_vector(3)), got "
                         f"{rows!r}")
                last_error = rows["failed"][1]
                if not last_error or "dimension" not in last_error.lower():
                    fail(f"[Gap-1] expected a dimension-related error message, "
                         f"got {last_error!r}")

                print(f"OK: [Gap-1] both rows failed cleanly on the real "
                      f"dimension-mismatch path (embed returned dim 2 into "
                      f"fractal_vector(3)): {last_error!r} -- zero changes to "
                      f"fractal_vectorizer_create/process_queue needed")
                passed += 1

                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_fv_gap1'")
                cur.execute("DROP TABLE IF EXISTS _vec_test_fv_gap1")

    # ---- Cleanup --------------------------------------------------
    conn = connect_or_skip(DSN)
    if conn is not None:
        with conn:
            cur = conn.cursor()
            cur.execute("DROP TABLE IF EXISTS _fv_test_typmod")

    n_scenarios = 5
    print(f"\ntest_vector_type: PASS ({passed}/{n_scenarios} scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
