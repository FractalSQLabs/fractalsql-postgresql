#!/usr/bin/env python3
"""tests/test_text_to_sql_evil_nonterminating.py — memory-safety evil test.

Locks in the fix for a real over-read: the reasoning ABI supplies
summary_len but does NOT promise the response `summary` is
NUL-terminated, and the sovereign tier loads out-of-tree plugins. If
fractal_text_to_sql() ever treats `summary` as a C string again
(strstr/strchr/strlen/pstrdup without the length), it will read past the
buffer.

This test builds a hostile plugin (tests/evil_nonterminating_plugin.c)
that returns a non-NUL-terminated `summary` positioned flush against a
PROT_NONE guard page, so ANY read of summary[summary_len] SIGSEGVs the
backend deterministically -- not "maybe, off heap slack". It then drives
both the GENERATE path (extract_sql_from_response) and, with review on,
the review path (t2s_run_review), asserting the backend does NOT crash
(the connection stays alive). With the length-bounded pnstrdup handling
in place, the pipeline runs; without it, the backend dies here.

POSIX-only (mmap/mprotect). Skip-safe: exits 0 with a SKIP message if
not on a POSIX platform, cc is missing, psycopg is missing, no DB is
reachable, or the feature isn't deployed.

Usage:
    FRACTALSQL_DSN=... python3 tests/test_text_to_sql_evil_nonterminating.py
"""
import os
import subprocess
import sys
import tempfile

from _t2s_common import (connect_or_skip, get_dsn, configure_reasoning,
                         reconnect)

DSN = sys.argv[1] if len(sys.argv) > 1 else get_dsn()
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def skip(msg):
    print(f"SKIP: {msg}")
    sys.exit(0)


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def connection_alive(conn):
    """True if the backend is still usable (no crash), else False."""
    try:
        cur = conn.cursor()
        cur.execute("SELECT 1")
        return cur.fetchone()[0] == 1
    except Exception:
        return False


def build_evil_plugin(outdir):
    src = os.path.join(HERE, "evil_nonterminating_plugin.c")
    inc = os.path.join(REPO, "include")
    if not os.path.isfile(os.path.join(inc, "fractalsql_sql.h")):
        skip(f"ABI header not found under {inc} (run from a source checkout)")
    so = os.path.join(outdir, "evil_nonterminating_plugin.so")
    cc = os.environ.get("CC", "cc")
    try:
        subprocess.run(
            [cc, "-shared", "-fPIC", "-std=c99", f"-I{inc}", src, "-o", so],
            check=True, capture_output=True)
    except FileNotFoundError:
        skip(f"compiler {cc!r} not found")
    except subprocess.CalledProcessError as e:
        skip(f"could not build evil plugin: {e.stderr.decode(errors='replace')}")
    return so


def main():
    if os.name != "posix":
        skip("guard-page technique is POSIX-only")

    conn = connect_or_skip(DSN)
    if conn is None:
        return 0

    # feature present?
    try:
        conn.cursor().execute("SELECT 1 FROM pg_proc WHERE proname = 'fractal_text_to_sql'")
    except Exception as e:
        skip(f"cannot query catalog: {e}")

    # A table must exist so schema_context succeeds and the pipeline
    # actually reaches the plugin's response (the code path under test).
    with conn:
        cur = conn.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS _t2s_evil_target (id int)")
    conn = reconnect(conn, DSN)

    tmp = tempfile.mkdtemp(prefix="fsql_evil_")
    plugin = build_evil_plugin(tmp)

    # The plugin returns its built-in default of bare "SELECT 1" (no
    # fence, no trailing NUL, guard page immediately after the 8 bytes).
    # Bare SQL means the GENERATE extraction has to walk the buffer with
    # no delimiter to stop it early -- an unbounded walk crosses into the
    # guard page. We can't override the default from here: the plugin
    # reads FSQL_EVIL_SQL_FILE from the *backend's* environment (forked
    # from the postmaster), not this script's, so setting it here would
    # not reach the backend. The default is exactly what we assert on.
    passed = 0

    # ---- GENERATE path (review off): extract_sql_from_response ----
    with conn:
        cur = conn.cursor()
        configure_reasoning(cur, plugin, "http://127.0.0.1:1/unused",
                            use_review=False, max_attempts=1,
                            allowed_statements="select")
    conn = reconnect(conn, DSN)
    with conn:
        cur = conn.cursor()
        try:
            cur.execute("SELECT fractal_text_to_sql('q', ARRAY['_t2s_evil_target'])")
            result = cur.fetchone()[0]
        except Exception as e:
            if not connection_alive(conn):
                fail("backend CRASHED handling a non-NUL-terminated response "
                     "in the GENERATE path (over-read past summary_len)")
            fail(f"unexpected error (backend alive, so not the over-read): {e}")
        if not connection_alive(conn):
            fail("backend CRASHED in the GENERATE path (over-read)")
        if "SELECT 1" not in (result or ""):
            fail(f"GENERATE returned unexpected SQL {result!r} (expected to "
                 "contain 'SELECT 1')")
        print("OK: GENERATE path handled a guard-paged non-terminated "
              f"response without over-read (returned {result!r})")
        passed += 1
    conn = reconnect(conn, DSN)

    # ---- REVIEW path (review on): t2s_run_review ----
    with conn:
        cur = conn.cursor()
        configure_reasoning(cur, plugin, "http://127.0.0.1:1/unused",
                            use_review=True, max_attempts=1,
                            allowed_statements="select")
    conn = reconnect(conn, DSN)
    with conn:
        cur = conn.cursor()
        # With review on, the review dispatch returns the same guard-paged
        # buffer; t2s_run_review must copy it length-bounded before
        # inspecting it. The verdict will be FAIL ("SELECT 1" isn't
        # "PASS..."), so this call is EXPECTED to error -- we only assert
        # the backend did not CRASH.
        try:
            cur.execute("SELECT fractal_text_to_sql('q', ARRAY['_t2s_evil_target'])")
            cur.fetchone()
        except Exception:
            pass
        if not connection_alive(conn):
            fail("backend CRASHED in the REVIEW path (t2s_run_review over-read "
                 "of a non-NUL-terminated response)")
        print("OK: REVIEW path handled a guard-paged non-terminated response "
              "without over-read (backend alive)")
        passed += 1

    print(f"OK: {passed}/2 evil non-terminating-response scenarios passed "
          "(no over-read, backend never crashed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
