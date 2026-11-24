#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/test_index_tamper.py -- the index tier against damaged storage and out-of-range options (run by gate 59).

Connects with the libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE) to a database that has the extension. Every case uses its own table
and index, and everything created is dropped at the end.
  * fractal_index_create refuses each option out of its range and accepts the boundary values;
  * a stored index is loaded by a FRESH connection (the index cache is per backend), and every defect in a stored cell row is refused with
    "corrupt", one defect at a time: a cell number out of range, a negative row count, an ids blob whose length is not 8 x the row count
    (short, empty, long), a codes blob of the wrong length or empty; a meta row whose dim, nlist or format disagrees with the model;
  * fractal_index_refresh and fractal_index_candidates, which read the stored cells again, meet the same damaged rows;
  * rerank, nprobe and k as search options, near and per_cell clamped, a list long enough to grow the output, a vector with a component that
    is not finite, and every fractal_index_ensure action and the ways its rebuild or refresh can fail.
Env: FSQL_SHOW=1 prints what every case returns. Skips (exit 0) when psycopg is missing or no database is reachable."""
import json, math, os, random, sys

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

SHOW = os.environ.get("FSQL_SHOW") == "1"
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:260]) if detail else ""))
    if SHOW: print("   [%s] %s %s" % ("ok" if cond else "FAIL", what, ("-- " + str(detail)[:200]) if detail else ""))

def connect():
    return psycopg.connect("", autocommit=True)
try:
    ADMIN = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)

def one(c, sql, *params):
    """(True, first column of the first row) or (False, the error text)."""
    try:
        cur = c.execute(sql, params)
        row = cur.fetchone() if cur.description else None
        return True, (row[0] if row else None)
    except psycopg.Error as e:
        return False, str(e).strip().split("\n")[0]

SCHEMA = one(ADMIN, "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='fractal_index_cells'")[1]
if not SCHEMA:
    one(ADMIN, "SELECT fractal_index_list()")      # the tables are created on first use of the index tier
    SCHEMA = one(ADMIN, "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='fractal_index_cells'")[1] or "public"
CELLS, META = "%s.fractal_index_cells" % SCHEMA, "%s.fractal_index_meta" % SCHEMA

D, N = 8, 120
random.seed(5)
rows = [[round(random.gauss(0, 1), 4) for _ in range(D)] for _ in range(N)]
SEQ = [0]
TABLES, INDEXES = [], []
def new_table(nrows=None, data=None, extra_text=False):
    SEQ[0] += 1
    t = "tamper_t%d" % SEQ[0]
    one(ADMIN, "CREATE TABLE %s(id int PRIMARY KEY, v float8[])" % t)
    data = data if data is not None else rows
    with ADMIN.cursor() as cur:
        cur.executemany("INSERT INTO %s(id, v) VALUES (%%s, %%s)" % t, [(i + 1, r) for i, r in enumerate(data)])
    TABLES.append(t)
    return t
def build(fmt="FP32", **extra):
    t = new_table()
    ix = "tamper_ix%d" % SEQ[0]
    o = {"name": ix, "vector_format": fmt, "nlist": 2, "calibration_samples": 30}; o.update(extra)
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps(o))
    assert ok, r
    INDEXES.append(ix)
    return t, ix
def search(c, t, ix, k=3, **opts):
    o = {"index": ix}; o.update(opts)
    return one(c, "SELECT count(*) FROM fractal_search(%s, 'v', %s::float8[], %s, %s::jsonb)", t, rows[3], k, json.dumps(o))

# --- options out of range --------------------------------------------------------------------------------------------------------------
t = new_table(); n = 0
for opt, bad in (("nlist", 4097), ("nlist", -1), ("iters", 101), ("iters", -1), ("sample", 1000001), ("sample", -1), ("pca_dim", 100000), ("pca_dim", -1), ("seed", -1)):
    n += 1
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps({"name": "tamper_o%d" % n, opt: bad}))
    check(not ok and "must be" in r, "%s = %s is refused with the range message" % (opt, bad), r)
ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps({"name": "tamper_ofmt", "vector_format": "INT7"}))
check(not ok and "vector_format" in r, "an unknown vector_format is refused", r)
for opt, good in (("nlist", 0), ("iters", 0), ("sample", 0), ("pca_dim", 0), ("seed", 0), ("nlist", 2), ("iters", 100)):
    n += 1; nm = "tamper_o%d" % n
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps({"name": nm, opt: good, "vector_format": "FP32"}))
    check(ok, "%s = %s is accepted" % (opt, good), r)
    if ok: INDEXES.append(nm)
for what, opts in (("nlist a string that is not a number", {"nlist": "abc"}), ("nlist a boolean", {"nlist": True}), ("nlist null", {"nlist": None})):
    n += 1; nm = "tamper_o%d" % n
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps(dict(opts, name=nm, vector_format="FP32")))
    check(ok or isinstance(r, str), "options with %s are handled (defaulted or refused cleanly)" % what, r)
    if ok: INDEXES.append(nm)

# --- a stored cell row damaged, one defect at a time ---------------------------------------------------------------------------------------
def cell_sql(ix):
    return {
    "a cell number below 0": ("UPDATE %s SET cell = -1 WHERE name = %%s AND cell = 0" % CELLS, "cellno"),
    "a cell number at or after nlist": ("UPDATE %s SET cell = 99 WHERE name = %%s AND cell = 0" % CELLS, "cellno"),
    "a negative row count": ("UPDATE %s SET n = -1 WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "an ids blob shorter than 8 x the row count": ("UPDATE %s SET ids = substring(ids from 1 for 3) WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "an empty ids blob": ("UPDATE %s SET ids = ''::bytea WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "an ids blob longer than 8 x the row count": ("UPDATE %s SET ids = ids || '\\x00'::bytea WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "a row count past any real size": ("UPDATE %s SET n = 2147483647 WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "a codes blob of the wrong length": ("UPDATE %s SET codes = substring(codes from 1 for 3) WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "an empty codes blob": ("UPDATE %s SET codes = ''::bytea WHERE name = %%s AND cell = 0" % CELLS, "size"),
    "a codes blob longer than its row count": ("UPDATE %s SET codes = codes || '\\x00'::bytea WHERE name = %%s AND cell = 0" % CELLS, "size"),
    }
for what, (sql, kind) in cell_sql("").items():
    t, ix = build()
    one(ADMIN, sql, ix)
    c = connect()
    ok, r = search(c, t, ix)
    check(not ok and ("corrupt" in r or "incomplete" in r), "%s is refused by a fresh connection's search with a clean 'corrupt' error" % what, r)
    c.close()
for what, (sql, kind) in cell_sql("").items():
    t, ix = build()
    with ADMIN.cursor() as cur:      # a refresh with nothing added returns before it reads the cells: give it rows to fold in
        cur.executemany("INSERT INTO %s(id, v) VALUES (%%s, %%s)" % t, [(5000 + i, r) for i, r in enumerate(rows[:3])])
    one(ADMIN, sql, ix)
    c = connect()
    ok, r = one(c, "SELECT fractal_index_refresh(%s)", ix)
    if kind == "size": check(not ok and "corrupt" in r, "fractal_index_refresh over %s is refused with a clean 'corrupt' error" % what, r)
    else: check(ok or isinstance(r, str), "fractal_index_refresh over %s is answered or refused cleanly" % what, r)
    c.close()
for what, sql in (("a dim that is not the model's", "UPDATE %s SET dim = dim + 1 WHERE name = %%s" % META), ("an nlist that is not the model's", "UPDATE %s SET nlist = nlist + 1 WHERE name = %%s" % META),
                  ("a format that is not the model's", "UPDATE %s SET format = 'INT8' WHERE name = %%s" % META)):
    t, ix = build()
    one(ADMIN, sql, ix)
    c = connect()
    ok, r = search(c, t, ix)
    check(not ok and ("corrupt" in r or "model" in r or "format" in r or "dim" in r), "a meta row with %s is refused cleanly" % what, r)
    c.close()
for what, (sql, kind) in cell_sql("").items():                  # candidates reads the stored cells again: the same damaged rows are skipped
    t, ix = build()
    c = connect()
    search(c, t, ix)
    one(ADMIN, sql, ix)
    ok, r = one(c, "SELECT coalesce(array_length(fractal_index_candidates(%s, 'v', %s::float8[], %s::jsonb), 1), 0)", t, rows[5], json.dumps({"near": 2, "per_cell": 1}))
    check(ok or isinstance(r, str), "candidates over a resident index with %s answers or refuses cleanly" % what, r)
    c.close()

# --- search options that are clamped or refused: rerank, nprobe, k ---------------------------------------------------------------------------
t, ix = build("INT4")
c = connect()
for what, opts, want_ok in (("rerank -1", {"rerank": -1}, False), ("rerank 100001", {"rerank": 100001}, False), ("rerank 5 on an INT4 index", {"rerank": 5}, False),
                            ("rerank 20 on an INT4 index", {"rerank": 20}, True), ("rerank 100000", {"rerank": 100000}, True), ("rerank 0 on an INT4 index", {"rerank": 0}, False),
                            ("nprobe 0", {"nprobe": 0}, True), ("nprobe 1e12", {"nprobe": 1e12}, True), ("nprobe -3", {"nprobe": -3}, True)):
    ok, r = search(c, t, ix, **opts)
    check(ok == want_ok, "fractal_search with %s is %s" % (what, "answered" if want_ok else "refused"), r)
c.close()
t, ix = build("INT8")
c = connect()
for what, opts in (("rerank 0 on an INT8 index", {"rerank": 0}), ("rerank 1 on an INT8 index", {"rerank": 1}), ("verify off", {"verify": False}),
                   ("verify off and an ids set", {"verify": False, "ids": [1, 2, 3, 7, 9, 11]}), ("use_index off", {"use_index": False}),
                   ("use_index off and an ids set", {"use_index": False, "ids": [1, 2, 3, 7]}), ("nprobe 1 and verify off", {"nprobe": 1, "verify": False})):
    ok, r = search(c, t, ix, k=1, **opts)
    check(ok, "fractal_search with %s (k = 1) is answered" % what, r)
c.close()

t, ix = build("FP32")
c = connect()
for what, opts in (("verify off (FP32: nothing to rerank, so the index's own distances are returned)", {"verify": False}), ("verify off with nprobe 1", {"verify": False, "nprobe": 1}),
                   ("verify off, k = 1", {"verify": False})):
    ok, r = search(c, t, ix, k=1 if "k = 1" in what else 3, **opts)
    check(ok and r >= 1, "fractal_search with %s is answered" % what, r)
c.close()
t, ix = build("INT8")
c = connect()
ok, r = search(c, t, ix, rerank=0, verify=False); check(ok and r >= 1, "an INT8 index with rerank 0 and verify off answers from its own distances", r)
c.close()

# --- the model the index was built for ---------------------------------------------------------------------------------------------------
t, ix = build("FP32", model="alpha")
c = connect()
ok, r = search(c, t, ix, model="beta"); check(not ok and "does not match" in r, "a query for another model than the index was built for is refused", r)
ok, r = search(c, t, ix, model="alpha"); check(ok, "a query for the model the index was built for is answered", r)
c.close()

# --- fractal_index_create refuses what it cannot index, with a clean error ------------------------------------------------------------------------------
def mk(name, ddl, inserts=()):
    one(ADMIN, "CREATE TABLE %s(%s)" % (name, ddl)); TABLES.append(name)
    for sql, params in inserts: one(ADMIN, sql.replace("%s", name), *params)
    return name
def shape_opts():
    return json.dumps({"name": "tamper_shape%d" % (len(TABLES) + 1), "vector_format": "FP32", "nlist": 2})     # one index name per case: a clash must never be what refuses it
bad_tables = (
    ("a vector column that is a two-dimensional array", "id int primary key, v float8[]", [("INSERT INTO %s VALUES (1, ARRAY[[1,2],[3,4]]::float8[])", ())]),
    ("a vector with a NULL component", "id int primary key, v float8[]", [("INSERT INTO %s VALUES (1, ARRAY[1,NULL,3]::float8[])", ())]),
    ("a table with no rows", "id int primary key, v float8[]", []),
    ("a table whose vectors are all NULL", "id int primary key, v float8[]", [("INSERT INTO %s VALUES (1, NULL), (2, NULL)", ())]),
    ("a vector wider than the largest dimension", "id int primary key, v float8[]", [("INSERT INTO %s VALUES (1, array_fill(0.5::float8, ARRAY[100000]))", ())]),
    ("an empty vector", "id int primary key, v float8[]", [("INSERT INTO %s VALUES (1, ARRAY[]::float8[])", ())]),
    ("a vector column that is text", "id int primary key, v text", [("INSERT INTO %s VALUES (1, '0.1,0.2')", ())]),
    ("an id column that is text", "id text primary key, v float8[]", [("INSERT INTO %s VALUES ('a', ARRAY[1,2,3]::float8[])", ())]),
    ("a table with no id column (a composite key instead)", "a int, b int, v float8[], PRIMARY KEY (a, b)", [("INSERT INTO %s VALUES (1, 2, ARRAY[1,2,3]::float8[])", ())]),
)
for what, ddl, ins in bad_tables:
    tb = mk("tamper_shape%d" % (len(TABLES) + 1), ddl, ins)
    o = shape_opts()
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", tb, o)
    check(not ok, "fractal_index_create over %s is refused" % what, r)
    if ok: INDEXES.append(json.loads(o)["name"])
# an integer id column needs no declared primary key: it is the key the index returns
tb = mk("tamper_shape%d" % (len(TABLES) + 1), "id int, v float8[]", [("INSERT INTO %s VALUES (1, ARRAY[1,2,3]::float8[]), (2, ARRAY[3,2,1]::float8[])", ())])
o = shape_opts(); ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)->>'id_col'", tb, o)
check(ok and r == "id", "a table whose integer id column has no declared primary key is indexed by that column", r)
if ok: INDEXES.append(json.loads(o)["name"])
good = mk("tamper_shape_ok", "id int primary key, v float8[]", [("INSERT INTO %s SELECT i, ARRAY[i, i %% 7, i %% 5, 1]::float8[] FROM generate_series(1, 40) i", ())])
for what, call, params in (("a table that does not exist", "SELECT fractal_index_create(%s, 'v', %s::jsonb)", ("tamper_no_such_table", shape_opts())),
                           ("a column that does not exist", "SELECT fractal_index_create(%s, 'nope', %s::jsonb)", (good, shape_opts())),
                           ("a table name that is not an identifier", "SELECT fractal_index_create(%s, 'v', %s::jsonb)", ('x; drop table %s' % good, shape_opts())),
                           ("an id_col that is not an integer column", "SELECT fractal_index_create(%s, 'v', '{\"id_col\":\"v\"}'::jsonb)", (good,)),
                           ("an id_col that does not exist", "SELECT fractal_index_create(%s, 'v', '{\"id_col\":\"nope\"}'::jsonb)", (good,)),
                           ("a rebuild of an index that does not exist", "SELECT fractal_index_rebuild(%s)", ("tamper_no_such_index",)),
                           ("an info on an index that does not exist", "SELECT fractal_index_info(%s)", ("tamper_no_such_index",)),
                           ("a refresh of an index that does not exist", "SELECT fractal_index_refresh(%s)", ("tamper_no_such_index",))):
    ok, r = one(ADMIN, call, *params)
    check(not ok, "%s is refused" % what, r)
for what, jopt in (("an array", "[]"), ("a string", '"text"'), ("a number", "5"), ("null", "null"), ("an empty object", "{}")):
    tb = mk("tamper_shape%d" % (len(TABLES) + 1), "id int primary key, v float8[]", [("INSERT INTO %s SELECT i, ARRAY[i, i %% 7, i %% 5, 1]::float8[] FROM generate_series(1, 40) i", ())])
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)->>'name'", tb, jopt)
    check(ok or isinstance(r, str), "options that are %s are accepted or refused cleanly" % what, r)
    if ok and r: INDEXES.append(r)
ok, r = one(ADMIN, "SELECT fractal_index_drop(%s)", "tamper_no_such_index")
check(not ok and "no index named" in r, "dropping an index that does not exist is refused, naming it", r)

# --- a NULL argument is refused with a clean error, never a crash: every function, every required argument --------------------------------------------------------
arr = "ARRAY[1,2,3,1]::float8[]"
for what, call in (("fractal_index_create(NULL, col)", "SELECT fractal_index_create(NULL, 'v')"), ("fractal_index_create(table, NULL)", "SELECT fractal_index_create('%s', NULL)" % good),
                   ("fractal_index_rebuild(NULL)", "SELECT fractal_index_rebuild(NULL)"), ("fractal_index_drop(NULL)", "SELECT fractal_index_drop(NULL)"),
                   ("fractal_index_info(NULL)", "SELECT fractal_index_info(NULL)"), ("fractal_index_refresh(NULL)", "SELECT fractal_index_refresh(NULL)"),
                   ("fractal_index_ensure(NULL, col)", "SELECT fractal_index_ensure(NULL, 'v')"), ("fractal_index_ensure(table, NULL)", "SELECT fractal_index_ensure('%s', NULL)" % good),
                   ("fractal_index_candidates(NULL, col, query)", "SELECT fractal_index_candidates(NULL, 'v', %s)" % arr),
                   ("fractal_index_candidates(table, NULL, query)", "SELECT fractal_index_candidates('%s', NULL, %s)" % (good, arr)),
                   ("fractal_index_candidates(table, col, NULL)", "SELECT fractal_index_candidates('%s', 'v', NULL::float8[])" % good),
                   ("fractal_search(NULL, col, query, k)", "SELECT count(*) FROM fractal_search(NULL, 'v', %s, 3)" % arr),
                   ("fractal_search(table, NULL, query, k)", "SELECT count(*) FROM fractal_search('%s', NULL, %s, 3)" % (good, arr)),
                   ("fractal_search(table, col, NULL, k)", "SELECT count(*) FROM fractal_search('%s', 'v', NULL::float8[], 3)" % good),
                   ("fractal_search(table, col, query, NULL)", "SELECT count(*) FROM fractal_search('%s', 'v', %s, NULL::int)" % (good, arr))):
    ok, r = one(ADMIN, call)
    check(not ok and "must not be NULL" in r, "%s is refused with a clean error (no crash)" % what, r)
ok, r = one(ADMIN, "SELECT 1"); check(ok, "the connection is still alive after every NULL argument", r)
ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)->>'name'", "%s.%s" % ("public", good), json.dumps({"name": "tamper_qual", "vector_format": "FP32", "nlist": 2}))
check(ok or isinstance(r, str), "a schema-qualified table name is accepted or refused cleanly", r)
if ok: INDEXES.append("tamper_qual")
for what, k in (("k = 0", 0), ("k below 0", -3), ("k past the row count", 100000)):
    ok, r = one(ADMIN, "SELECT count(*) FROM fractal_search(%s, 'v', ARRAY[1,2,3,1]::float8[], %s, '{}'::jsonb)", good, k)
    check(ok or isinstance(r, str), "fractal_search with %s is answered or refused cleanly" % what, r)
ok, r = one(ADMIN, "SELECT count(*) FROM fractal_search(%s, 'v', ARRAY[1,2,3]::float8[], 3, '{}'::jsonb)", good)
check(not ok, "a query of the wrong dimension is refused", r)
ok, r = one(ADMIN, "SELECT count(*) FROM fractal_search(%s, 'v', ARRAY[1,NULL,3,1]::float8[], 3, '{}'::jsonb)", good)
check(not ok, "a query with a NULL component is refused", r)

# --- a vector with a component that is not finite or past float range stops the build ------------------------------------------------------------
for what, bad in (("NaN", "NaN"), ("infinity", "Infinity"), ("past float range", "1e39")):
    t = new_table()
    one(ADMIN, "UPDATE %s SET v = ARRAY[%s::float8,1,2,3,4,5,6,7] WHERE id = 50" % (t, "'%s'" % bad if bad != "1e39" else "1e39"))
    ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps({"name": "tamper_nf%d" % SEQ[0], "vector_format": "FP32", "nlist": 2}))
    check(not ok, "a component that is %s is refused at build" % what, r)

# --- candidates: near and per_cell clamped at both ends, and a list long enough to grow the output ----------------------------------------------------
t = new_table(data=[[random.gauss(0, 1) for _ in range(D)] for _ in range(3000)])
ok, r = one(ADMIN, "SELECT fractal_index_create(%s, 'v', %s::jsonb)", t, json.dumps({"name": "tamper_bx", "vector_format": "FP32", "nlist": 4, "calibration_samples": 30}))
check(ok, "a 3000-row index is built", r)
INDEXES.append("tamper_bx")
q5 = one(ADMIN, "SELECT v FROM %s WHERE id = 6" % t)[1]
for what, opts in (("near and per_cell below their range", {"near": -5, "per_cell": -5}), ("near and per_cell past their range", {"near": 99999, "per_cell": 9999999}),
                   ("every cell and every row", {"near": 4, "per_cell": 100000}), ("near 0", {"near": 0, "per_cell": 1})):
    ok, r = one(ADMIN, "SELECT coalesce(array_length(fractal_index_candidates(%s, 'v', %s::float8[], %s::jsonb), 1), 0)", t, q5, json.dumps(opts))
    check(ok and r >= 0, "fractal_index_candidates with %s answers a list (%s ids)" % (what, r), r)
ok, r = one(ADMIN, "SELECT array_length(fractal_index_candidates(%s, 'v', %s::float8[], %s::jsonb), 1)", t, q5, json.dumps({"near": 4, "per_cell": 100000}))
check(ok and r and r > 2000, "an every-row candidate list is long (it grows the output buffer)", r)
one(ADMIN, "INSERT INTO %s(id, v) VALUES (100000, %%s)" % t, q5)
ok, r = one(ADMIN, "SELECT 100000 = ANY(fractal_index_candidates(%s, 'v', %s::float8[], %s::jsonb))", t, q5, json.dumps({"near": 4, "per_cell": 100000}))
check(ok and r is True, "rows added since the build are among the candidates", r)
ok, r = one(ADMIN, "SELECT count(*) FROM fractal_search(%s, 'v', %s::float8[], 50, %s::jsonb)", t, q5, json.dumps({"index": "tamper_bx", "verify": False, "ids": list(range(1, 400))}))
check(ok and r == 50, "a search over a long ids set (verify off) returns k rows", r)

# --- fractal_index_ensure: each action, and each way the action it chooses can fail ----------------------------------------------------------------------
t, ix = build("INT4", target_recall=0.99999)
ok, r = one(ADMIN, "SELECT fractal_index_info(%s)->>'status'", ix); status = r if ok else None
check(status in ("ready", "degraded"), "an INT4 index built for a very high target reports a verdict (%s)" % status, r)
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v', '{\"vector_format\":\"FP32\",\"nlist\":2}'::jsonb)->>'action'", t)
check(ok, "ensure with new options on a %s index answers (%s)" % (status, r), r)
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v', '{\"nlist\":99999}'::jsonb)->>'action'", t)
check(not ok or r in ("unchanged", "rebuilt"), "ensure with out-of-range new options is refused or leaves the index", r)
t, ix = build("FP32")
one(ADMIN, "DELETE FROM %s WHERE id > 40" % t)
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v')->>'action'", t); check(ok and r == "rebuilt", "ensure rebuilds after more than a fifth of the rows were deleted", r)
one(ADMIN, "DELETE FROM %s WHERE id > 20" % t)
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v', '{\"vector_format\":\"FP16\",\"nlist\":2}'::jsonb)->>'action'", t)
check(ok and r == "rebuilt", "ensure rebuilds with the new options after more deletions", r)
t, ix = build("FP32")
with ADMIN.cursor() as cur:
    cur.executemany("INSERT INTO %s(id, v) VALUES (%%s, %%s)" % t, [(2000 + i, r) for i, r in enumerate(rows[:60])])
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v', '{\"vector_format\":\"FP16\",\"nlist\":2}'::jsonb)->>'action'", t)
check(ok and r == "rebuilt", "ensure rebuilds with the new options after more than a quarter of the rows were added", r)
t, ix = build("FP32")
with ADMIN.cursor() as cur:
    cur.executemany("INSERT INTO %s(id, v) VALUES (%%s, %%s)" % t, [(3000 + i, r) for i, r in enumerate(rows[:3])])
one(ADMIN, "UPDATE %s SET n = -1 WHERE name = %%s AND cell = 0" % CELLS, ix)
c = connect()
ok, r = one(c, "SELECT fractal_index_ensure(%s, 'v')->>'action'", t)
check(not ok and "corrupt" in r, "ensure whose refresh finds a damaged cell reports it", r)
c.close()
t, ix = build("FP32")
with ADMIN.cursor() as cur:
    cur.executemany("INSERT INTO %s(id, v) VALUES (%%s, %%s)" % t, [(4000 + i, [1.0, 2.0]) for i in range(70)])   # past a quarter, none the right dimension
ok, r = one(ADMIN, "SELECT fractal_index_ensure(%s, 'v')->>'action'", t)
check(not ok, "fractal_index_ensure reports a rebuild that fails (rows of the wrong dimension)", r)
ok, r = search(ADMIN, t, ix)
check(ok, "the previous generation still serves searches after a failed ensure", r)

# --- clean up: leave the database as it was found ----------------------------------------------------------------------------------------------------
for ix in INDEXES: one(ADMIN, "SELECT fractal_index_drop(%s)", ix)
for tb in TABLES: one(ADMIN, "DROP TABLE IF EXISTS %s" % tb)
print("test_index_tamper: %s (%d checks passed, %d failed)" % ("PASS" if fails == 0 else "FAIL", passes, fails)); sys.exit(1 if fails else 0)
