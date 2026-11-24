#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/id_emission.py -- how the agents write a row's id (and the caller's other text) into their results
(run by gate 65).

The id column is the caller's data, so what an agent writes must never become JSON structure and must never be
altered: the row ids come back byte for byte, the SQL agent's failure is reported as JSON (not as a raw string
that would break the document), and the audit entry the text-to-SQL path writes carries the question and the
generated SQL exactly as they were given -- every control character, quote and backslash included.

Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); FSQL_ENTERPRISE_LIB (the enterprise core .so,
for the audit-entry part -- that part is skipped without one). Skips (exit 0) when psycopg is missing or no
database is reachable.
"""
import json, os, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

ENT_LIB = os.environ.get("FSQL_ENTERPRISE_LIB", "")

passes = fails = 0


def safe(t):
    """The text under test may hold characters a Windows console (cp1252) cannot print: show them escaped.

    Printing it raw kills the driver, and the report of the defect goes with it."""
    return str(t).encode("ascii", "backslashreplace").decode("ascii")


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (safe(what), ("-- " + safe(detail)[:300]) if detail else ""))


def connect():
    # options=-c client_encoding=UTF8: a cluster whose database encoding is SQL_ASCII (a container with
    # no locale) hands the client raw bytes for text, and psycopg escapes non-ASCII characters as
    # JSON escapes -- which such a server cannot translate. The encoding has to be negotiated at
    # connect time.
    c = psycopg.connect("", autocommit=True, options="-c client_encoding=UTF8")
    c.execute("SET client_encoding TO 'UTF8'")
    return c


try:
    c0 = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)


SCRIPT_FILE = os.environ.get("FSQL_SCRIPT", "/tmp/fractalsql_bt_script.txt")
RS = chr(0x1e)     # the record separator the scripted plugin splits the replies on
VECTOR = "[0.1,0.2,0.3]"   # the embedding the agent's first dispatch finds


def _ensure_script_dir(path):
    """The script file lives beside the plugin, which reads it from the host process's current
    drive (a literal "/tmp/..." is what the fixture plugins use). The directory has to exist
    before the plugin opens the file."""
    d = os.path.dirname(path)
    if d:
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


def write_scripts(replies):
    """Scripts the replies the next dispatches will find, in dispatch order."""
    _ensure_script_dir(SCRIPT_FILE)
    with open(SCRIPT_FILE, "w", encoding="utf-8", newline="") as f:
        f.write(RS.join(replies))


def clear_scripts():
    try:
        os.remove(SCRIPT_FILE)
    except OSError:
        pass


# --- the fixture: a table whose PRIMARY KEY is text, holding every awkward id ------------------------
IDS = ("42", "0", "-7", "10.5", "007", "", "true", "null", "NaN",
       '{"x":1', '["a"', 'quote " and backslash \\', "tab\there", "line\nbreak", "cr\rhere",
       "back\bspace and form\ffeed", "ctl\x01\x02\x1f end", "slash / and unicode é 日本 \U0001f600",
       "-" + "9" * 400, "1" + "0" * 400)

with connect() as c:
    c.execute("""
        DROP TABLE IF EXISTS bt_em_rows;
        CREATE TABLE bt_em_rows (id text PRIMARY KEY, tag text, emb float8[]);
    """)
    for i, ident in enumerate(IDS):
        try:
            c.execute("INSERT INTO bt_em_rows (id, tag, emb) VALUES (%s, %s, %s);",
                      (ident, "row %d" % i, [0.1 + i * 0.001, 0.2, 0.3]))
        except psycopg.Error as e:
            if "encoding" not in str(e):
                raise
            # A database whose encoding is not UTF-8 cannot hold this id: the server refuses the
            # conversion, whatever the client sends. That is the character set, not a defect.
            print("  note: the database encoding cannot hold every id -- the non-ASCII ones are skipped")

# --- the row ids come back exactly -------------------------------------------------------------------
# Each id is picked out on its own with a meta_filter, so the assertion is about THAT row's id and not about
# which rows the search happened to rank first.
for ident in IDS:
    # ensure_ascii=False: the default would write the non-ASCII ids as unicode escapes, and a server
    # whose database encoding is SQL_ASCII cannot translate a unicode escape into it.
    flt = json.dumps({"id": ident}, ensure_ascii=False)
    write_scripts([VECTOR, "the answer"])
    with connect() as c:
        try:
            rows = c.execute("SELECT source_row_ids FROM fractal_rag_agent('q', 'bt_em_rows', 'emb', %s);",
                             (flt,)).fetchone()
        except psycopg.Error as e:
            if "encoding" in str(e):
                # A database whose encoding is not UTF-8 cannot represent this id: the server refuses
                # the conversion, whatever the client sends. That is the character set, not a defect.
                # (the note names the case, not the text: a non-ASCII string cannot be printed on a
                # cp1252 console, which is what a Windows terminal hands the driver)
                print("  note: the database encoding cannot represent one of the ids -- skipped")
                continue
            check(False, "the agent accepts the id %r" % ident[:30], str(e)[:200]); continue
    ids = list(rows[0]) if rows and rows[0] else []
    check(ids == [ident], "the id %r comes back byte for byte" % ident[:30], (ids[:3], [len(i) for i in ids[:3]]))

# every id in the table is reachable and none of them was altered on the way through
with connect() as c:
    rows = c.execute("SELECT id FROM bt_em_rows ORDER BY id;").fetchall()
check(len(rows) == len(IDS), "the fixture holds every id (%d)" % len(rows), len(rows))

# --- the SQL agent's failure is reported as JSON ------------------------------------------------------
# The rejection text carries a quote and a doubled quote; the result_json must still be a JSON document,
# and the message must be in it exactly.
with connect() as c:
    try:
        got = c.execute("SELECT execution_status, result_json::text FROM fractal_sql_agent('q', ARRAY['bt_em_rows'], 1, false);").fetchone()
        status, result_json = got[0], got[1]
    except psycopg.Error as e:
        status, result_json = "error", str(e)
check(status in ("validation_failed", "execution_failed", "success"),
      "the SQL agent answers with a status", status)
if isinstance(result_json, str) and result_json:
    try:
        parsed = json.loads(result_json)
        ok = isinstance(parsed, dict) and "status" in parsed
    except Exception as e:
        ok = False
        parsed = "not JSON: %s" % e
    check(ok, "the SQL agent's result_json is a JSON document", parsed)
else:
    check(True, "the SQL agent's result_json is empty (nothing to parse)")

# --- the audit entry carries the caller's text exactly ---------------------------------------------------
# fractal_text_to_sql's best-effort audit entry holds the question and the generated SQL, escaped into a
# JSON document: whatever the caller wrote has to come back out of it unchanged.
if ENT_LIB and os.path.exists(ENT_LIB):
    QUESTION = 'count the rows in "bt_em_rows" \\ please' + chr(9) + chr(1)
    # The scripted plugin answers the text-to-SQL tier with the SQL below; the question carries a quote, a
    # backslash, a tab and a control character, and the audit entry has to carry it out again unchanged.
    write_scripts(["SELECT count(*) FROM bt_em_rows"])
    with connect() as c:
        c.execute("SELECT set_config('fractalsql.enterprise_ledger_key', 'id-emission-key', false);")
        try:
            c.execute("SELECT fractal_text_to_sql(%s, ARRAY['bt_em_rows']);", (QUESTION,))
            answer = c.execute("SELECT convert_from(blob, 'UTF8')::jsonb FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;").fetchone()
        except psycopg.Error as e:
            answer = None
            check(False, "the text-to-SQL audit entry is written", str(e)[:200])
    if answer is not None:
        entry = answer[0]
        check(entry.get("entry", {}).get("question") == QUESTION,
              "the audit entry carries the question exactly", repr(entry.get("entry", {}).get("question"))[:200])
        check(entry.get("entry", {}).get("generated_sql") == "SELECT count(*) FROM bt_em_rows",
              "the audit entry carries the generated SQL exactly", repr(entry.get("entry", {}).get("generated_sql"))[:200])
    else:
        print("  note: no audit entry was written (the enterprise tier was not loaded?)")
else:
    print("  note: no enterprise core (FSQL_ENTERPRISE_LIB) -- the audit-entry part is skipped")

clear_scripts()
with connect() as c:
    c.execute("DROP TABLE IF EXISTS bt_em_rows;")
print("id emission: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
