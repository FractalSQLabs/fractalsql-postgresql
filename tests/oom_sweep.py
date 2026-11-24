#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/oom_sweep.py -- every kit statement re-run with a failure injected inside the extension (run by gate 66).

An extension that runs INSIDE a postgres backend cannot be swept by interposing the allocator: the backend's
own allocations are the ones a malloc interposer would break first, and there is no separate process to
fail in.

What the extension does have is a fault hook compiled into itself: fractalsql.fault_inject (src/fsql_fault.h,
built with `make FAULT_INJECT=1`, which build_test.sh always does). It fails the Nth call of one named site --
an SPI call, a core call, a dispatch to the reasoning plugin -- which is the same shape of failure an
allocation failure produces at the extension's own boundary: the extension gets a non-zero return where it
expected success, and everything downstream of it has to cope.

So: every kit statement is re-run with each fault site armed, and the statement must still answer or fail
cleanly. The backend may not crash, may not hang, and may not leak an SPI connection.

Env: the libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE); FSQL_FAULT_SITES (the sites to sweep, space
separated), OOM_MAX_K (the call ordinals per site, default 2), OOM_MAX_KITS (a cap, for debugging),
OOM_FILTER (a regex over the kit file name). Skips (exit 0) when psycopg is missing, no database is reachable,
or the build has no fault hook.
"""
import os, re, sys, time

try:
    import psycopg
except ImportError:
    print("SKIP: psycopg not installed"); sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAX_K = int(os.environ.get("OOM_MAX_K", "2") or 2)
MAX_KITS = int(os.environ.get("OOM_MAX_KITS", "0") or 0)
FILTER = re.compile(os.environ.get("OOM_FILTER", ""))
STATEMENT_TIMEOUT = os.environ.get("OOM_TIMEOUT", "20s")

DEFAULT_SITES = ("SPI_connect SPI_execute SPI_execute_with_args fsql_dispatch_ai fsql_search_ptr "
                 "fsql_extract_topk fsql_parse_embedding_array fsql_load_reasoning get_call_result_type "
                 "srf_context").split()
SITES = os.environ.get("FSQL_FAULT_SITES", "").split() or DEFAULT_SITES

crashed = 0
leaked = 0
runs = 0
fired = 0


NOTICES = []


def _notice(diag):
    """The extension announces an injected fault with a NOTICE; the driver counts them."""
    NOTICES.append(getattr(diag, "message_primary", "") or "")


def connect():
    c = psycopg.connect("", autocommit=True)
    c.execute("SET client_encoding TO 'UTF8'")
    c.execute("SELECT set_config('statement_timeout', %s, false);", (STATEMENT_TIMEOUT,))
    try:
        c.add_notice_handler(_notice)
    except AttributeError:
        pass
    return c


try:
    c = connect()
except Exception as e:
    print("SKIP: no database reachable: %s" % e); sys.exit(0)

try:
    c.execute("SHOW fractalsql.fault_inject;").fetchone()
except Exception:
    print("SKIP: this build has no fault-injection hook (needs make FAULT_INJECT=1)")
    sys.exit(0)

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
if MAX_KITS:
    kits = kits[:MAX_KITS]
if not kits:
    print("SKIP: no kit files found under demo/"); sys.exit(0)


def strip_meta(text):
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith("\\"))


def split_statements(text):
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


TARGET = re.compile(r"(?is)^\s*(select|with)\b")
CALL = re.compile(r"\bfractal_[a-z_0-9]*\s*\(")
CREATED = re.compile(r"(?is)^\s*create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z_0-9]*)")


def is_target(st):
    return bool(TARGET.match(st)) and bool(CALL.search(st))


def run(st):
    """Runs one statement. Returns "ok" / "err" / "crash" / "leak"."""
    global crashed, leaked
    try:
        c.execute(st)
        try:
            c.fetchall()
        except Exception:
            pass
        return "ok"
    except psycopg.Error as e:
        # A server-side ERROR always carries a SQLSTATE; a connection failure carries none. psycopg maps
        # most of the extension's own refusals to OperationalError (SQLSTATE classes 38, 57, ...), so the
        # SQLSTATE -- not the exception class -- is what tells a refusal from a dead backend.
        if getattr(e, "sqlstate", None) is None or c.closed:
            crashed += 1
            print("  FAIL the backend died on: %s -- %s" % (st[:160].replace("\n", " "), str(e)[:160]))
            try:
                c.close()
            except Exception:
                pass
            try:
                globals()["c"] = connect()
            except Exception:
                pass
            return "crash"
        msg = str(e).lower()
        if "non-empty spi stack" in msg or "was not closed" in msg or "still open" in msg:
            leaked += 1
            print("  FAIL the statement leaked: %s -- %s" % (st[:120].replace("\n", " "), str(e)[:160]))
        return "err"


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
        run(s)
    for st in targets:
        for site in SITES:
            for k in range(1, MAX_K + 1):
                runs += 1
                before = len(NOTICES)
                outcome = run("SET fractalsql.fault_inject = '%s:%d'; %s" % (site, k, st))
                if outcome == "crash":
                    break
                if any("fault injected at" in n for n in NOTICES[before:]):
                    fired += 1
                else:
                    break    # this statement does not reach that site any more

# The kits leave their tables behind; this gate does not.
for t in sorted(set(created)):
    run("DROP TABLE IF EXISTS %s CASCADE;" % t)

if crashed:
    print("oom sweep: %d kits, %d runs, %d injected failures, %d problem(s)" % (len(kits), runs, fired, crashed + leaked))
    sys.exit(1)
print("oom sweep: %d kits, %d runs, %d injected failures, %d problem(s)" % (len(kits), runs, fired, leaked))
sys.exit(1 if leaked else 0)
