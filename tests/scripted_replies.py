#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/scripted_replies.py -- the extension against a model that answers exactly what the test scripts (run by gate 63).

tests/scripted_reasoning_plugin.c answers each dispatch with the next reply of the script the harness wrote
(one reply per dispatch, per script), so a test chooses what the extension has to parse. Every scenario runs
in its own connection, because the plugin's reply counter is per backend process. The gate runs with the
review step on, so a text-to-SQL call dispatches twice -- the candidate, then the verdict -- and the driver
scripts the two replies in that order.

  * text-to-SQL replies: the SQL in a fenced block in every shape (case, no language tag, unterminated, a second
    block, prose around it), bare SQL, and the statements the allowlist refuses (EXPLAIN in each form, DML, two
    statements, an empty reply);
  * the review verdict: the word PASS at the front of the reply, and the replies that merely start with it
    ("PASS2", "Password ..."), which are critiques;
  * the SQL agent: the reply the model gave, the status it earned (success / validation_failed /
    execution_failed) and the JSON it reported the failure in;
  * the chat tier: the reply is handed back exactly as the model wrote it (fences and all);
  * embedding replies: a vector in every shape the parser takes or refuses;
  * the retrieval agent's meta_filter: what the parser accepts, which rows each filter keeps, and what it refuses
    before any embedding is asked for.

Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); FSQL_SCRIPTED_PLUGIN (the plugin .so);
FSQL_SCRIPT_REASON / FSQL_SCRIPT_EMBED (the script files). Skips (exit 0) when psycopg is missing or no database
is reachable.
"""
import json, os, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

SCRIPT_FILE = os.environ.get("FSQL_SCRIPT", "/tmp/fractalsql_bt_script.txt")
PLUGIN      = os.environ.get("FSQL_SCRIPTED_PLUGIN", "")
RS          = "\x1e"

passes = fails = 0


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))


def connect():
    # options=-c client_encoding=UTF8: a cluster whose database encoding is SQL_ASCII (a container
    # with no locale) hands the client raw bytes for text, and psycopg escapes non-ASCII characters
    # as JSON escapes -- which such a server cannot translate. The encoding has to be negotiated at
    # connect time, not with a later SET, or psycopg keeps the server's original one.
    c = psycopg.connect("", autocommit=True, options="-c client_encoding=UTF8")
    c.execute("SET client_encoding TO 'UTF8'")
    return c


try:
    c0 = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)


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


def write_script(replies):
    """Scripts the replies the next dispatches will find, in dispatch order."""
    _ensure_script_dir(SCRIPT_FILE)
    with open(SCRIPT_FILE, "w", encoding="utf-8", newline="") as f:
        f.write(RS.join(replies))


def clear_scripts():
    try:
        os.remove(SCRIPT_FILE)
    except OSError:
        pass


def run(sql, params=None, replies=None):
    """Runs one statement in a FRESH backend with the scripted replies in place.

    Returns (kind, payload): kind is "ok" (payload = the rows) or "err" (payload = the message)."""
    write_script(replies or [])
    try:
        with connect() as c:
            try:
                cur = c.execute(sql, params)
                try:
                    rows = cur.fetchall()
                except Exception:
                    rows = []
                return ("ok", rows)
            except psycopg.Error as e:
                return ("err", str(e))
    finally:
        clear_scripts()


def one(sql, params=None, replies=None):
    """The single-value form of run()."""
    kind, payload = run(sql, params, replies)
    if kind == "ok":
        if not payload:
            return ("ok", None)
        return ("ok", payload[0][0])
    return ("err", payload)


# --- the fixture -------------------------------------------------------------------------------
with connect() as c:
    c.execute("""
        DROP TABLE IF EXISTS bt_sr_rows;
        CREATE TABLE bt_sr_rows (id serial PRIMARY KEY, tag text, n numeric, txt text, emb float8[]);
        INSERT INTO bt_sr_rows (tag, n, txt, emb) VALUES
            ('a', 1.5,  'abc',  ARRAY[0.1,0.2,0.3]),
            ('b', -3,   '12',   ARRAY[0.9,0.1,0.0]),
            ('a', 100,  'abc',  ARRAY[0.0,0.8,0.5]),
            (NULL, NULL, NULL,  ARRAY[0.2,0.2,0.2]);
    """)

# --- the plugin ----------------------------------------------------------------------------------
# The gate points fractalsql.reasoning_plugin at the scripted plugin and sets the embedding endpoint
# (both are reload-scoped GUCs, so the gate owns them: a backend only picks them up when it starts).
if not PLUGIN or not os.path.exists(PLUGIN):
    print("  FAIL the scripted plugin is missing (FSQL_SCRIPTED_PLUGIN)"); sys.exit(1)

T2S = "SELECT fractal_text_to_sql('q', ARRAY['bt_sr_rows']);"
VECTOR = "[0.1,0.2,0.3]"   # the embedding the retrieval agent's first dispatch finds

# --- text-to-SQL replies -----------------------------------------------------------------------
# (reply, expected outcome, needle). "ok" means the statement came back; "err" means it was refused and the
# message carries the needle. The needles are the extension's own words.
T2S_CASES = (
    ("```sql\nSELECT 1\n```",                       "ok",  "SELECT 1"),
    ("```SQL\nSELECT 1```",                         "ok",  "SELECT 1"),
    ("```sqlx\nSELECT 1\n```",                      "ok",  "SELECT 1"),
    ("```\nSELECT 1\n```",                          "ok",  "SELECT 1"),
    ("```text\nSELECT 1\n```",                      "ok",  "SELECT 1"),
    ("SELECT 1",                                   "ok",  "SELECT 1"),
    ("  -- c\n SELECT 1",                           "ok",  "SELECT 1"),
    ("/* c */ SELECT 1",                            "ok",  "SELECT 1"),
    ("here: ```sql\nSELECT count(*) FROM bt_sr_rows\n``` done", "ok", "count(*)"),
    ("```sql\nSELECT 1",                            "err", "does not parse"),      # unterminated fence
    ("```sql",                                     "err", "does not parse"),
    ("```sql\n```",                                "err", "found 0"),             # an empty block
    ("```sql\nSELECT 1```\n```sql\nSELECT 2```",    "err", "dispatch failed"),    # two blocks: not guessable
    ("EXPLAIN SELECT 1",                           "err", "not permitted"),
    ("explain select 1",                           "err", "not permitted"),
    ("EXPLAIN QUERY PLAN SELECT 1",                "err", "does not parse"),
    ("EXPLAIN",                                    "err", "does not parse"),
    ("EXPLAIN QUERY SELECT 1",                     "err", "does not parse"),
    ("",                                           "err", "found 0"),
    ("   ",                                        "err", "found 0"),
    ("DELETE FROM bt_sr_rows",                     "err", "not permitted"),
    ("INSERT INTO bt_sr_rows (tag) VALUES ('x')",  "err", "not permitted"),
    ("SELECT 1; SELECT 2",                         "err", "exactly one SQL statement"),
)
for reply, kind, needle in T2S_CASES:
    # the reply, then the review verdict (the gate runs with the review step on)
    k, v = one(T2S, replies=[reply, "PASS"])
    if kind == "ok":
        check(k == "ok" and needle in str(v), "text-to-SQL reply %r returns the statement" % reply[:40], (k, str(v)[:160]))
    else:
        check(k == "err" and needle in v, "text-to-SQL reply %r is refused (%s)" % (reply[:40], needle), (k, str(v)[:200]))

# --- the SQL agent: the reply, the status and the JSON the failure is reported in --------------------
AGENT = "SELECT execution_status, result_json::text, retry_count FROM fractal_sql_agent('q', ARRAY['bt_sr_rows'], %d, %s);"
AGENT_CASES = (
    ("SELECT count(*) FROM bt_sr_rows",        1, "false", "success",          None),
    ("SELECT * FROM bt_sr_rows WHERE id = 1",  1, "false", "success",          None),
    ("DELETE FROM bt_sr_rows",                 1, "false", "validation_failed", "not permitted"),
    ("SELECT * FROM bt_sr_no_such_table",      1, "false", "validation_failed", "does not analyze"),
    ("SELECT 1; SELECT 2",                     1, "false", "validation_failed", "exactly one SQL statement"),
    ("SELECT 1/0",                             1, "true",  "validation_failed", "division by zero"),
    ("SELECT txt::int FROM bt_sr_rows",        1, "true",  "execution_failed",  "invalid input syntax for type integer"),
)
for reply, retries, execu, want_status, want_err in AGENT_CASES:
    kind, payload = run(AGENT % (retries, execu), replies=[reply, "PASS"])
    if kind != "ok" or not payload:
        check(False, "sql_agent reply %r answers" % reply[:40], str(payload)[:200]); continue
    status, result_json, retries_used = payload[0][0], payload[0][1], payload[0][2]
    ok = status == want_status
    detail = (status, str(result_json)[:160], retries_used)
    if want_err is not None:
        ok = ok and (result_json is not None) and (want_err in result_json)
        # the failure is reported as JSON, not as a raw string
        try:
            parsed = json.loads(result_json) if result_json else {}
            ok = ok and parsed.get("status") is not None
        except Exception as e:
            ok = False
            detail = (detail, "result_json is not JSON: %s" % e)
    check(ok, "sql_agent reply %r is %s" % (reply[:40], want_status), detail)

# --- the review verdict: the word PASS at the front of the reply, and nothing that merely starts with it ----
# The verdict is the reply's first word: PASS in any case, and the end of the reply (or a non-identifier
# character) right after it. A critique that begins with the same four letters is not a pass.
REVIEW_CASES = (
    ("PASS",                       True),
    ("pass",                       True),
    ("PASS and then some prose",   True),
    ("PASS.",                      True),
    ("PASS2",                      False),
    ("PASS_1",                     False),
    ("Password column is missing", False),
    ("FAIL: the column is wrong",  False),
    ("",                           False),
)
for verdict, is_pass in REVIEW_CASES:
    k, v = one(T2S, replies=["SELECT 1", verdict])
    if is_pass:
        check(k == "ok" and "SELECT 1" in str(v), "the review verdict %r passes the candidate" % verdict[:30], (k, str(v)[:160]))
    else:
        check(k == "err" and "last review verdict" in v, "the review verdict %r is a critique" % verdict[:30], (k, str(v)[:200]))

# --- the chat tier: the reply is handed back exactly as the model wrote it --------------------------------
for reply in ("the routing is sound", "```sql\nSELECT 1\n```", "line one\nline two", "  padded  "):
    k, v = one("SELECT fractal_reason('q');", replies=[reply])
    check(k == "ok" and v == reply, "fractal_reason returns the reply verbatim (%r)" % reply[:30], (k, str(v)[:120]))

# --- embedding replies -------------------------------------------------------------------------------
EMB = (("[0.1,0.2,0.3]", "03000000"), ("[1]", "01000000"), ("[ 0.1 , 0.2 ]", "02000000"),
       ("[0.1,0.2,0.3] trailing", None),
       ("[0.1,0.2,0.3", "03000000"),          # an unterminated array: the values before it are kept
       ("[", "ERR"), ("[ ]", "ERR"),
       ("no vector", "ERR"), ("[]", "ERR"), ("", "ERR"), ("[0.1,abc]", "ERR"), ("0.1,0.2]", "ERR"),
       ("[[1,2],[3,4]]", "ERR"),
       ("[" + ",".join(["0.1"] * 16385) + "]", "ERR"))   # past the dimension cap (MAX_EMBED_DIM)
for reply, want in EMB:
    k, v = one("SELECT fractal_embed('x');", replies=[reply])
    if want is None:
        check(k in ("ok", "err"), "embedding reply %r is handled" % reply[:30], (k, str(v)[:120]))
    elif want == "ERR":
        check(k == "err", "embedding reply %r is refused with a clean error" % reply[:30], (k, str(v)[:160]))
    else:
        check(k == "ok" and len(v) == int(want[:2], 16), "embedding reply %r is a %d-dim vector" % (reply[:30], int(want[:2], 16)),
              (k, str(v)[:160]))

# --- the retrieval agent's meta_filter: what the parser accepts, and which rows each filter keeps -----------
# rows: id 1 tag a n 1.5 | id 2 tag b n -3 | id 3 tag a n 100 | id 4 tag NULL n NULL
RAG = "SELECT source_row_ids FROM fractal_rag_agent('q', 'bt_sr_rows', 'emb', %s);"
FILTERS = (
    ("{}",          {1, 2, 3, 4}),
    ("{ }",         {1, 2, 3, 4}),
    ("{}",          {1, 2, 3, 4}),
    ('{"tag":"a"}', {1, 3}),
    ('{"id":1}',    {1}),
    ('{"n":1.5}',   {1}),
    ('{"n":-3}',    {2}),
    ('{"n":1e2}',   {3}),
    ('{"n":null}',  {4}),
    ('{"tag":null}',{4}),
    ('{"id":1,"tag":"a"}', {1}),
)
for flt, want in FILTERS:
    k, v = one(RAG % ("'" + flt.replace("'", "''") + "'"), replies=[VECTOR, "the answer"])
    if k != "ok":
        check(False, "meta_filter %r is accepted" % flt, str(v)[:200]); continue
    got = set(v[0]) if v[0] else set()
    allowed = set(str(x) for x in want)
    check(bool(got) and got <= allowed, "meta_filter %r keeps rows %s (it returned %s)"
          % (flt, sorted(allowed), sorted(got)), (sorted(got),))

# a filter that is not a flat object of column: value pairs is refused before any embedding is asked for
for flt, needle in (("[1]", "must be a JSON object"),
                    ('"a"',  "must be a JSON object"),
                    ('{"tag":["a"]}', "must be a string, number, boolean or null"),
                    ('{"tag":{"a":1}}', "must be a string, number, boolean or null"),
                    ('{"tag":', "invalid input syntax"),
                    ('{"nosuch":1}', "does not exist"),
                    ('{"tag":"zzz"}', "no rows found")):
    k, v = one(RAG % ("'" + flt.replace("'", "''") + "'"), replies=[VECTOR, "the answer"])
    check(k == "err" and needle in v, "meta_filter %r is refused (%s)" % (flt, needle), (k, str(v)[:200]))

clear_scripts()
with connect() as c:
    c.execute("DROP TABLE IF EXISTS bt_sr_rows;")
print("scripted replies: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
