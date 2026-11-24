#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/kit_mutation.py -- every kit statement re-run with one literal swapped for an awkward value (run by gate 67).

The kits in demo/ are the extension's own end-to-end exercises: each one creates a fixture, calls the fractal_*
functions over it and prints a headline result. Every statement in them that CALLS a fractal_ function is
re-run here with one of its literal arguments swapped for an awkward value (NULL, an empty string, a huge
number, a malformed JSON fragment, ...) and with its argument list changed (an argument dropped, an extra NULL
added, one argument NULLed). The mutated statement must answer or fail cleanly: the backend may not crash and
may not hang.

The mutated statements only read (SELECT / WITH), so what they do changes nothing the next statement sees.

Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); MUT_MAX (literal mutants per statement, default
8), MUT_FILTER (a regex over the kit file name), MUT_MAX_KITS (a cap, for debugging). Skips (exit 0) when
psycopg is missing or no database is reachable.
"""
import os, re, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MUT_MAX = int(os.environ.get("MUT_MAX", "16") or 16)
MUT_MAX_KITS = int(os.environ.get("MUT_MAX_KITS", "0") or 0)
FILTER = re.compile(os.environ.get("MUT_FILTER", ""))
STATEMENT_TIMEOUT = os.environ.get("MUT_TIMEOUT", "20s")

passes = fails = 0
crashed = 0
mutated = 0


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))


def connect():
    c = psycopg.connect("", autocommit=True)
    c.execute("SET client_encoding TO 'UTF8'")
    c.execute("SELECT set_config('statement_timeout', %s, false);", (STATEMENT_TIMEOUT,))
    return c


try:
    c = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)


# --- the kits ---------------------------------------------------------------------------------------
EXTRA = ("demo-chunking.sql", "demo-fractal-index.sql")
demo = os.path.join(ROOT, "demo")
kits = []
if os.path.isdir(demo):
    for f in sorted(os.listdir(demo)):
        if not f.endswith(".sql"):
            continue
        if not (f.startswith("demo-vertical-") or f in EXTRA):
            continue
        if not FILTER.search(f):
            continue
        kits.append(os.path.join(demo, f))
if MUT_MAX_KITS:
    kits = kits[:MUT_MAX_KITS]

if not kits:
    print("SKIP: no kit files found under demo/"); sys.exit(0)

# --- the SQL splitter -------------------------------------------------------------------------------
def strip_meta(text):
    """Drops the psql meta-commands and the comment lines: the mutants are plain SQL."""
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("\\"):
            continue
        out.append(line)
    return "\n".join(out)


def split_statements(text):
    """Splits a script into statements on a top-level semicolon.

    Handles single quotes (with '' escapes), dollar quoting and -- / /* */ comments. The kits use none of
    the exotic forms, but a splitter that gets them wrong would produce mutants that are not the statement
    under test."""
    stmts, buf = [], []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(text[i:min(j + 1, n)])
            i = j + 1
            continue
        if ch == '"':
            j = text.find('"', i + 1)
            j = n if j < 0 else j + 1
            buf.append(text[i:j])
            i = j
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                buf.append(text[i:j])
                i = j
                continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(" ")
            i = j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            buf.append(" ")
            i = j
            continue
        if ch == ";":
            stmts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if "".join(buf).strip():
        stmts.append("".join(buf))
    return [s.strip() for s in stmts if s.strip()]


# --- the mutation rules -----------------------------------------------------------------------------
# A literal: a single-quoted string (with '' for an embedded quote) or a number that is not glued to a word
# character or a dot.
LIT = re.compile(r"'(?:[^']|'')*'|(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w.])")
STR_POOL = ["NULL", "''", "'{}'", "'[]'", "'{\"a\":'", "'x'", "'0'", "-1", "0", "1e308",
            "repeat('x', 4000)", "'[1,2'", "'\\x00'"]
NUM_POOL = ["NULL", "0", "-1", "1", "2147483647", "1e308", "-1e308", "'x'", "''", "0.0",
            "9223372036854775807", "'[]'", "1e-300"]


def literal_mutants(st, limit):
    """One literal swapped for an awkward value of its own kind.

    The mutants are spread over the statement's literals (round robin, with
    the next awkward value each time), so a statement with several literals
    has each of them tried rather than only the first."""
    lits = list(LIT.finditer(st))
    out = []
    pool_i = 0
    round_no = 0
    while len(out) < limit and lits:
        added = 0
        for m in lits:
            if len(out) >= limit:
                break
            pool = STR_POOL if m.group(0).startswith("'") else NUM_POOL
            v = pool[(pool_i + round_no) % len(pool)]
            pool_i += 1
            if v == m.group(0):
                continue
            out.append(st[:m.start()] + v + st[m.end():])
            added += 1
        round_no += 1
        if added == 0:
            break
    return out


def call_spans(st):
    """The (name, open_paren, close_paren) of every fractal_* call in the statement, with the offsets of its
    top-level arguments."""
    spans = []
    for m in re.finditer(r"\bfractal_[a-z_0-9]*\s*\(", st):
        open_at = st.index("(", m.start())
        depth, i, args = 0, open_at, []
        arg_start, in_str, in_id = None, False, False
        while i < len(st):
            ch = st[i]
            if in_str:
                if ch == "'":
                    if i + 1 < len(st) and st[i + 1] == "'":
                        i += 2
                        continue
                    in_str = False
            elif in_id:
                if ch == '"':
                    in_id = False
            elif ch == "'":
                in_str = True
            elif ch == '"':
                in_id = True
            elif ch == "(":
                depth += 1
                if depth == 1:
                    arg_start = i + 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    args.append((arg_start, i))
                    spans.append((m.group(0).strip(), open_at, i, args))
                    break
            elif ch == "," and depth == 1:
                args.append((arg_start, i))
                arg_start = i + 1
            i += 1
    return spans


def arity_mutants(st, max_calls=3):
    """The argument list changed: the trailing arguments dropped (so the defaults are exercised), an extra
    NULL added, one argument NULLed."""
    out = []
    for _name, open_at, close_at, args in call_spans(st)[:max_calls]:
        texts = [st[a:b] for a, b in args]
        if len(texts) >= 1:
            # drop the trailing argument
            kept = st[:open_at + 1] + ",".join(texts[:-1]) + st[close_at:]
            out.append(kept)
            if len(texts) >= 2:
                # drop two trailing arguments
                out.append(st[:open_at + 1] + ",".join(texts[:-2]) + st[close_at:])
        # one extra argument
        out.append(st[:close_at] + ", NULL" + st[close_at:])
        # one argument NULLed
        for a, b in args:
            out.append(st[:a] + " NULL " + st[b:])
    return out


TARGET = re.compile(r"(?is)^\s*(select|with)\b")
CALL = re.compile(r"\bfractal_[a-z_0-9]*\s*\(")
CREATED = re.compile(r"(?is)^\s*create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z_0-9]*)")


def is_target(st):
    return bool(TARGET.match(st)) and bool(CALL.search(st))


TRACE = os.environ.get("MUT_TRACE") == "1"      # echo every statement (debugging a crash)


last_stmt = ""

def run(st):
    """Runs one statement. Returns "ok", "err" or "crash"."""
    global crashed, last_stmt
    if TRACE:
        print("   RUN: %s" % st[:140].replace(chr(10), " "), flush=True)
    try:
        c.execute(st)
        try:
            c.fetchall()
        except Exception:
            pass
        last_stmt = st
        return "ok"
    except psycopg.Error as e:
        # A server-side ERROR always carries a SQLSTATE; a connection failure carries none. psycopg maps
        # most of the extension's own refusals to OperationalError (SQLSTATE classes 38, 57, ...), so the
        # SQLSTATE -- not the exception class -- is what tells a refusal from a dead backend.
        if getattr(e, "sqlstate", None) is None or c.closed:
            crashed += 1
            print("  FAIL the backend died on: %s -- %s" % (st[:160].replace("\n", " "), str(e)[:160]))
            if last_stmt:
                print("       (the statement before it was: %s)" % last_stmt[:160].replace(chr(10), " "))
            try:
                c.close()
            except Exception:
                pass
            try:
                globals()["c"] = connect()
            except Exception:
                pass
            return "crash"
        return "err"          # an ordinary SQL error is the expected outcome for most mutants


created = []
for kit in kits:
    name = os.path.basename(kit)
    with open(kit, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    stmts = split_statements(strip_meta(text))
    setup = [s for s in stmts if not is_target(s)]
    targets = [s for s in stmts if is_target(s)]
    for s in setup:
        m = CREATED.match(s)
        if m:
            created.append(m.group(1))
    # The setup runs first, so the mutated statements see the fixture the kit built.
    for s in setup:
        run(s)
    for st in targets:
        for mu in literal_mutants(st, MUT_MAX) + arity_mutants(st):
            mutated += 1
            run(mu)

# The kits leave their tables behind; this gate does not.
for t in sorted(set(created)):
    run("DROP TABLE IF EXISTS %s CASCADE;" % t)

# --- the index tier, under the same mutation rules ------------------------------------------------
# The kits barely touch the index tier, and the index functions are mostly option parsing and refusal
# paths -- exactly what a literal swapped for an awkward value reaches. The calls below are the whole
# index surface over a fixture of its own.
INDEX_FIXTURE = [
    "DROP TABLE IF EXISTS bt_mut_ix CASCADE",
    "CREATE TABLE bt_mut_ix (id serial PRIMARY KEY, v float8[])",
    "INSERT INTO bt_mut_ix (v) SELECT ARRAY[0.1 + i * 0.001, 0.2, 0.3] FROM generate_series(1, 20) i",
]
INDEX_CALLS = (
    "SELECT fractal_index_create('bt_mut_ix', 'v', '{\"name\": \"bt_mut_ix\", \"nlist\": 4}')",
    "SELECT fractal_index_info('bt_mut_ix')",
    "SELECT fractal_index_list()",
    "SELECT fractal_index_refresh('bt_mut_ix')",
    "SELECT fractal_index_rebuild('bt_mut_ix')",
    "SELECT fractal_index_ensure('bt_mut_ix', 'v', '{\"name\": \"bt_mut_ix\", \"nlist\": 4}')",
    "SELECT fractal_index_candidates('bt_mut_ix', 'v', ARRAY[0.1, 0.2, 0.3]::float8[])",
    "SELECT fractal_index_drop('bt_mut_ix')",
    "SELECT count(*) FROM fractal_search('bt_mut_ix', 'v', ARRAY[0.1, 0.2, 0.3]::float8[], 5)",
    "SELECT count(*) FROM fractal_search('bt_mut_ix', 'v', ARRAY[0.1, 0.2, 0.3]::float8[], 5, '{\"nprobe\": 2}')",
)
for s in INDEX_FIXTURE:
    run(s + ";")
for st in INDEX_CALLS:
    for mu in literal_mutants(st, MUT_MAX) + arity_mutants(st):
        mutated += 1
        run(mu)
run("DROP TABLE IF EXISTS bt_mut_ix CASCADE;")

check(crashed == 0, "no mutated statement crashed the backend (%d statements mutated over %d kits)"
      % (mutated, len(kits)), crashed)
print("kit mutation: %d kits, %d mutated statements, %d crashed" % (len(kits), mutated, crashed))
sys.exit(1 if crashed else 0)
