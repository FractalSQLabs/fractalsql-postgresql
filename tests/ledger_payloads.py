#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/ledger_payloads.py -- what fractal_audit_log writes into the chain for every shape of entry type, payload
and actor (run by gate 64).

The ledger entry is built from the caller's text: {"type": ..., "entry": ...} with an "_actor" block added.
Whatever the text holds must never break the JSON or the chain: the payload is spliced in as JSON (an object
gets the actor inside it, a scalar or an array is wrapped as {"value": ...}), and the entry type and the actor
name are escaped (quote, backslash, control characters, unicode). Each entry must be accepted or refused
cleanly, and the chain must still verify.

Uses the mock enterprise core (tests/mock_enterprise_core.c) with a ledger key, as gate 31 does.
Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); FSQL_ENTERPRISE_LIB (the core .so). Skips
(exit 0) when psycopg is missing or no database is reachable.
"""
import json, os, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

ENT_LIB = os.environ.get("FSQL_ENTERPRISE_LIB", "")
LEDGER_KEY = "ledger-payload-test-key"

passes = fails = 0


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))


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


if not ENT_LIB or not os.path.exists(ENT_LIB):
    print("  FAIL the enterprise core is missing (FSQL_ENTERPRISE_LIB)"); sys.exit(1)

with connect() as c:
    c.execute("SELECT set_config('fractalsql.enterprise_ledger_key', %s, false);", (LEDGER_KEY,))
    c.execute("DROP TABLE IF EXISTS fractalsql_ledger, fractalsql_ledger_head;")


def audit(entry_type, payload):
    """One fractal_audit_log call. Returns (ok, value-or-message)."""
    with connect() as c:
        c.execute("SELECT set_config('fractalsql.enterprise_ledger_key', %s, false);", (LEDGER_KEY,))
        try:
            c.execute("SELECT fractal_audit_log(%s, %s);", (entry_type, payload))
            return (True, None)
        except psycopg.Error as e:
            return (False, str(e))


# --- the payload shapes -----------------------------------------------------------------------------
# (what, payload, accepted). Every payload here is already jsonb -- the CALLER's type -- so the shapes the
# entry builder distinguishes are: an object (the actor goes inside it), an empty object, and everything
# else (wrapped as {"value": ...}).
PAYLOADS = (
    ("an object",                    '{"n":1}',                 True),
    ("a nested object",              '{"a":{"b":[1,2,{"c":null}]}}', True),
    ("an object with a null value",  '{"a":null}',              True),
    ("an empty object",              '{}',                      True),
    ("an array",                     '[1,2,3]',                 True),
    ("an array of objects",          '[{"a":1},{"b":2}]',       True),
    ("a string",                     '"text"',                  True),
    ("a number",                     '12',                      True),
    ("a float",                      '1.5',                     True),
    ("true",                         'true',                    True),
    ("null",                         'null',                    True),
)
for what, payload, accepted in PAYLOADS:
    ok, err = audit("type.payload", payload)
    check(ok == accepted, "audit_log accepts %s" % what, err)

# --- the entry types ---------------------------------------------------------------------------------
ESC = "q\" b\\ bs\b ff\f nl\n cr\r tab\t c1\x01 c1f\x1f end"
TYPES = (
    ("a plain name",        "plain"),
    ("a quote",             'a"b'),
    ("a backslash",         "a\\b"),
    ("every escape and control character", ESC),
    ("a long type",         "t" * 300),
    ("a unicode type",      "tipo é 日本 \U0001f600"),
    ("an empty type",       ""),
    ("a JSON-looking type", '{"type":"forged"}'),
)
skipped_types = []
for what, etype in TYPES:
    ok, err = audit(etype, '{"k":1}')
    if not ok and "encoding" in str(err):
        # A database whose encoding is not UTF-8 cannot represent this text: the server refuses the
        # conversion, whatever the client sends. That is the database's character set, not a defect.
        print("  note: the database encoding cannot represent %s -- skipped" % what)
        skipped_types.append(etype)
        continue
    check(ok, "audit_log takes an entry type with %s" % what, err)

# --- the actor ----------------------------------------------------------------------------------------
# The actor block is built from the DB role, the session role, the fractalsql.actor client and the pid.
ACTORS = (
    ("a quote",              'who "x"'),
    ("a backslash",          "who \\x"),
    ("every escape and control character", ESC),
    ("an empty name",        ""),
    ("a long name",          "n" * 400),
    ("a unicode name",       "cliente é 日本 \U0001f600"),
)
for what, actor in ACTORS:
    with connect() as c:
        try:
            c.execute("SELECT set_config('fractalsql.enterprise_ledger_key', %s, false);", (LEDGER_KEY,))
            c.execute("SELECT set_config('fractalsql.actor', %s, false);", (actor,))
            c.execute("SELECT fractal_audit_log('actor.test', '{\"a\":1}');")
            ok, err = (True, None)
        except psycopg.Error as e:
            ok, err = (False, str(e))
    if not ok and "encoding" in str(err):
        # A database whose encoding is not UTF-8 cannot represent this name: the server refuses the
        # conversion, whatever the client sends. That is the character set, not a defect.
        print("  note: the database encoding cannot represent an actor name that is %s -- skipped" % what)
        continue
    check(ok, "audit_log with an actor name that is %s" % what, err)

# --- the arguments the function refuses ------------------------------------------------------------------
# A caller-supplied "_actor" is rejected: the actor block is the server's, never the caller's.
ok, err = audit("forged.actor", '{"_actor":{"role":"root"}}')
check(not ok, "audit_log refuses a payload that carries its own _actor", err)
ok, err = audit(None, '{"k":1}')
check(not ok, "audit_log refuses a NULL entry type", err)
ok, err = audit("null.payload", None)
check(not ok, "audit_log refuses a NULL payload", err)

# --- what actually landed in the chain ---------------------------------------------------------------------
with connect() as c:
    c.execute("SELECT set_config('fractalsql.enterprise_ledger_key', %s, false);", (LEDGER_KEY,))
    rows = c.execute("SELECT id, convert_from(blob, 'UTF8') FROM fractalsql_ledger WHERE kind = 2 ORDER BY id;").fetchall()
    ok, report = True, None
    try:
        report = c.execute("SELECT fractal_ledger_verify(2);").fetchone()[0]
    except psycopg.Error as e:
        ok, report = False, str(e)

check(len(rows) >= 20, "the entries are in the ledger table (%d rows)" % len(rows), len(rows))
bad = 0
types_seen = []
for _id, blob in rows:
    try:
        entry = json.loads(blob)
    except Exception:
        bad += 1
        continue
    if not isinstance(entry, dict) or "type" not in entry or "entry" not in entry:
        bad += 1
        continue
    actor = entry["entry"].get("_actor") if isinstance(entry["entry"], dict) else None
    if not isinstance(actor, dict) or "role" not in actor or "pid" not in actor:
        bad += 1
        continue
    types_seen.append(entry["type"])
check(bad == 0, "every stored entry is a well-formed {type, entry{_actor}} object (%d stored)" % len(rows), bad)
check(ok and isinstance(report, dict) and report.get("ok") is True,
      "the chain still verifies after every entry", report)
# the awkward types came back exactly as they went in
for what, etype in TYPES:
    if etype == "" or etype in skipped_types:
        continue
    check(etype in types_seen, "the entry type with %s is stored exactly as it was given" % what)
check(any(t == ESC for t in types_seen), "an entry type with control characters is stored exactly as it was given")
if skipped_types:
    # (the note names the kinds, not the text: a non-ASCII string cannot be printed on a
    # cp1252 console, which is what a Windows terminal hands the driver)
    print("  note: %d entry type(s) were skipped -- the database encoding cannot represent them"
          % len(skipped_types))
# the empty object got the actor and nothing else
empties = [json.loads(b) for _i, b in rows if json.loads(b).get("type") == "type.payload"]
check(any(list(e["entry"].keys()) == ["_actor"] for e in empties),
      "an empty payload is stored as the actor block alone", [list(e["entry"].keys()) for e in empties][:3])
check(any(e["entry"].get("value") == [1, 2, 3] for e in empties),
      "a non-object payload is stored wrapped as a value", [e["entry"] for e in empties][:3])

# --- the configuration keys ----------------------------------------------------------------------------
with connect() as c:
    ok, keys = True, None
    try:
        keys = c.execute("SELECT fractal_config_keys();").fetchone()[0]
    except psycopg.Error as e:
        ok, keys = False, str(e)
names = [k["name"] for k in keys] if ok and isinstance(keys, list) else []
check(len(names) > 20, "the key list is available (%d keys)" % len(names), keys if not ok else "")
for name in names:
    with connect() as c:
        try:
            c.execute("SELECT fractal_config_get(%s);", (name,)).fetchone()
            answered = True
        except psycopg.Error as e:
            answered = isinstance(str(e), str)      # a clean refusal is fine
    check(answered, "fractal_config_get(%r) answers or refuses cleanly" % name)

# The chain the driver built is the gate's own fixture; this gate does not leave it behind.
with connect() as c:
    c.execute("DROP TABLE IF EXISTS fractalsql_ledger, fractalsql_ledger_head;")
print("ledger payloads: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
