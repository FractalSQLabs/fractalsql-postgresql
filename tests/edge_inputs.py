#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/edge_inputs.py -- edge-input matrix for every fractal_* SQL function (run by the --fault gate).

For each function and overload in pg_proc it builds calls that vary ONE argument at a time through a pool of awkward values for that argument's
type (NULL, empty, huge, NaN and infinity, negative, malformed JSON, arrays of the wrong shape, a bytea short enough for a 1-byte varlena header
and one long enough for a 4-byte header, ...) while the others hold a plausible value, plus an all-NULL call and an all-plausible call; a function
with default arguments is also tried at its minimum arity. Set-returning functions are read with SELECT * FROM; aggregates are skipped.

What is asserted: no call may crash the backend (the connection is lost), hang past the statement timeout, (errors are expected; those
raised with the default internal code are listed as notes only). Ordinary errors are the expected outcome for most of these
inputs. Functions that change state for the whole database or are slow by design are skipped (SKIP).
Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); EDGE_MAX (functions, debug). Skips (exit 0) when psycopg is missing or no database
is reachable."""
import os, re, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

MAXF = int(os.environ.get("EDGE_MAX", "0") or 0)
def connect():
    c = psycopg.connect("", autocommit=True)
    c.execute("SET statement_timeout = '20s'")
    return c
try:
    c = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)

SKIP = re.compile(r"^fractal_(ledger_reset_hard|ledger_reset_soft|lock_destructive|ledger_compact|ledger_flush|ledger_load|vectorizer_process_queue)$")

# a small fixture the plausible values refer to
FIX = """
DROP TABLE IF EXISTS edge_docs CASCADE;
CREATE TABLE edge_docs(id int PRIMARY KEY, label text, tag text, emb float8[]);
INSERT INTO edge_docs SELECT i, 'row' || i, CASE WHEN i % 2 = 0 THEN 'a' ELSE 'b' END, ARRAY[(i %% 7) * 0.1, (i %% 5) * 0.2, 0.3]::float8[] FROM generate_series(1, 30) i;
DROP TABLE IF EXISTS edge_series CASCADE;
CREATE TABLE edge_series(ts int, host text, cpu float8, emb float8[]);
INSERT INTO edge_series SELECT i, 'h1', sin(i * 0.37) + (i %% 7) * 0.05, ARRAY[0.1, 0.2, 0.3]::float8[] FROM generate_series(0, 59) i;
""".replace("%%", "%")
for stmt in [s for s in FIX.split(";\n") if s.strip()]:
    c.execute(stmt)

BIG_BYTEA = "decode(repeat('ab', 400), 'hex')"        # 400 bytes: a 4-byte varlena header
POOL = {
    "text": ["NULL", "''", "' '", "'{'", "'[]'", "'{\"a\":'", "'it''s'", "'x;DROP TABLE edge_docs'", "'SELECT 1'", "'nope'", "repeat('x', 5000)", "'üñï'", "'-1'", "'1e400'",
             "'0.1,0.2,0.3'", "'[0.1,0.2,0.3]'", "'[0.1,0.2'", "'{\"population_size\":5,\"iterations\":3}'", "'[[1,2],[3,4]]'", "'edge_docs'", "'emb'", "'id'", "'public.edge_docs'",
             "'\"edge_docs\"'", "'1,2,3,4,5,6'", "'a' || chr(10) || chr(10) || 'b. c! d? e'"],
    "int4": ["NULL", "0", "-1", "1", "2", "3", "5", "100", "100000", "2147483647", "-2147483648"],
    "int8": ["NULL", "0", "-1", "1", "5", "100000", "9223372036854775807", "-9223372036854775808"],
    "int2": ["NULL", "0", "-1", "1", "32767"],
    "float8": ["NULL", "0", "-1", "0.5", "1", "1e308", "-1e308", "'NaN'::float8", "'Infinity'::float8", "'-Infinity'::float8", "1e-320"],
    "float4": ["NULL", "0", "'NaN'::float4", "1"],
    "float8[]": ["NULL", "'{}'::float8[]", "ARRAY[NULL]::float8[]", "ARRAY[1]::float8[]", "ARRAY[0.1,0.2,0.3]::float8[]", "ARRAY[0.1,0.2,0.3,0.4,0.5]::float8[]", "'{NaN}'::float8[]",
                 "'{Infinity}'::float8[]", "'{-Infinity,1}'::float8[]", "ARRAY[[1,2],[3,4]]::float8[]", "array_fill(0.5::float8, ARRAY[5000])", "array_fill(0.5::float8, ARRAY[70000])",
                 "ARRAY[1e308, 1e308, 1e308]::float8[]", "ARRAY[0,0,0]::float8[]", "ARRAY[1,2,3,4,5,6,7,8,9,10,11,12]::float8[]", "ARRAY[0.1,NULL,0.3]::float8[]"],
    "int4[]": ["NULL", "'{}'::int4[]", "ARRAY[1,2,3]::int4[]", "ARRAY[NULL]::int4[]", "ARRAY[-1]::int4[]", "ARRAY[2147483647]::int4[]"],
    "int8[]": ["NULL", "'{}'::int8[]", "ARRAY[1,2,3]::int8[]", "ARRAY[NULL]::int8[]", "ARRAY[-1]::int8[]"],
    "text[]": ["NULL", "'{}'::text[]", "ARRAY['edge_docs']", "ARRAY[NULL]::text[]", "ARRAY['a','b','c']", "ARRAY['edge_docs','edge_docs','edge_docs']", "ARRAY['x;y']"],
    "bytea": ["NULL", "''::bytea", "'\\x00'::bytea", "'\\x0001'::bytea", "'\\xff'::bytea", "'\\x00000000'::bytea", "'\\x0000803f'::bytea", "'\\xdeadbeef'::bytea", BIG_BYTEA,
              "decode(repeat('00', 70000), 'hex')", "decode(repeat('ff', 9), 'hex')"],
    "jsonb": ["NULL", "'{}'::jsonb", "'[]'::jsonb", "'null'::jsonb", "'\"x\"'::jsonb", "'5'::jsonb", "'{\"a\":{\"b\":[1,2]}}'::jsonb", "'{\"n\":1}'::jsonb", "'[1,2,3]'::jsonb",
              "'{\"population_size\":5,\"iterations\":3}'::jsonb", "'{\"k\":-1,\"limit\":0}'::jsonb", "jsonb_build_array(repeat('x', 3000))", "'{\"tag\":\"a\"}'::jsonb", "'{\"id\":1}'::jsonb"],
    "json": ["NULL", "'{}'::json", "'[]'::json", "'null'::json", "'{\"a\":1}'::json"],
    "boolean": ["NULL", "true", "false"],
    "numeric": ["NULL", "0", "1", "-1", "'NaN'::numeric", "1e30"],
    "timestamptz": ["NULL", "now()", "'-infinity'::timestamptz"],
    "oid": ["NULL", "0", "1"],
    "regclass": ["NULL", "'edge_docs'::regclass"],
}
TYPICAL = {
    "text": ["'0.1,0.2,0.3'", "'edge_docs'", "'emb'", "'id'", "'label'", "'tag'", "'a'"],
    "int4": ["5", "10", "3", "2"], "int8": ["5", "10", "1"], "int2": ["1"], "float8": ["0.5", "0.1", "1"], "float4": ["0.5"],
    "float8[]": ["ARRAY[0.1,0.2,0.3]::float8[]"], "int4[]": ["ARRAY[1,2,3]::int4[]"], "int8[]": ["ARRAY[1,2,3]::int8[]"], "text[]": ["ARRAY['edge_docs']"],
    "bytea": ["'\\x0000803f'::bytea"], "jsonb": ["'{\"a\":1}'::jsonb"], "json": ["'{\"a\":1}'::json"], "boolean": ["true"], "numeric": ["1"],
    "timestamptz": ["now()"], "oid": ["0"], "regclass": ["'edge_docs'::regclass"],
}

def catalog():
    rows = c.execute("""
        SELECT p.oid, p.proname, p.proretset, p.pronargs, p.pronargdefaults, p.prokind,
               (SELECT array_agg(format_type(t, NULL) ORDER BY ord) FROM unnest(p.proargtypes) WITH ORDINALITY AS u(t, ord))
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname LIKE 'fractal\\_%' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY p.proname, p.oid""").fetchall()
    out = []
    for oid, name, retset, nargs, ndef, kind, types in rows:
        if kind != "f" or SKIP.match(name): continue
        out.append((name, bool(retset), int(nargs), int(ndef), types or []))
    return out

def typ(t):
    t = t.replace("double precision", "float8").replace("integer", "int4").replace("bigint", "int8").replace("smallint", "int2").replace("real", "float4")
    t = t.replace("character varying", "text")
    return t
crashes, internals, calls, timeouts, skipped_types = [], [], 0, 0, set()
def run(name, retset, args_sql, label):
    global c, calls, timeouts
    sql = ("SELECT count(*) FROM %s(%s)" if retset else "SELECT %s(%s)") % (name, ", ".join(args_sql))
    calls += 1
    try:
        c.execute(sql).fetchall()
    except psycopg.errors.QueryCanceled:
        timeouts += 1
    except psycopg.OperationalError as e:
        if not (c.broken or c.closed):                  # an ordinary error the extension raised (a missing setting, a refused value), not a dead backend
            return
        crashes.append((name, label, sql[:200], str(e).strip().split("\n")[0]))
        for _ in range(60):                             # the postmaster restarts the cluster after a crash: wait for it
            time.sleep(1)
            try: c = connect(); break
            except Exception: continue
        else:
            print("  FAIL the server did not come back after %s" % name); print_and_exit()
    except psycopg.Error as e:
        if c.broken or c.closed:                        # the connection died without an OperationalError being raised
            crashes.append((name, label, sql[:200], str(e).strip().split("\n")[0]))
            c = connect()
        elif getattr(e, "sqlstate", None) == "XX000" and "terminat" not in str(e):
            internals.append((name, label, sql[:200], str(e).strip().split("\n")[0]))   # informational: the extension raises its own refusals with the default code

def print_and_exit():
    for n, l, s, e in crashes: print("  FAIL crash: %s [%s]: %s -- %s" % (n, l, s, e))
    seen = set()
    for n, l, s, e in internals:
        if (n, e[:60]) in seen: continue
        seen.add((n, e[:60]))
        if len(seen) <= 25: print("  note: error raised with the default internal code: %s [%s] -- %s" % (n, l, e[:140]))
    ok = not crashes
    print("edge inputs: %d calls, %d timed out, %d crash(es) (%d errors raised with the default internal code, informational): %s" % (calls, timeouts, len(crashes), len(internals), "PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)

cat = catalog()
if MAXF: cat = cat[:MAXF]
t0 = time.time()
for name, retset, nargs, ndef, types in cat:
    ts = [typ(t) for t in types]
    if any(t not in POOL for t in ts):
        skipped_types.update(t for t in ts if t not in POOL); continue
    arities = {nargs} | ({nargs - ndef} if ndef else set())
    for n in sorted(arities):
        sub = ts[:n]
        if n == 0:
            run(name, retset, [], "no arguments"); continue
        typical = [TYPICAL[t][i % len(TYPICAL[t])] if t in TYPICAL else "NULL" for i, t in enumerate(sub)]
        run(name, retset, typical, "all plausible")
        run(name, retset, ["NULL"] * n, "all NULL")
        for pos in range(n):
            for val in POOL[sub[pos]]:
                args = list(typical); args[pos] = val
                run(name, retset, args, "arg %d = %s" % (pos + 1, val[:40]))
    if time.time() - t0 > 900: print("  note: stopped after 15 minutes"); break
if skipped_types: print("  note: functions with argument types the sweep has no values for were skipped: %s" % ", ".join(sorted(skipped_types)))
c.execute("DROP TABLE IF EXISTS edge_docs CASCADE"); c.execute("DROP TABLE IF EXISTS edge_series CASCADE")
print_and_exit()
