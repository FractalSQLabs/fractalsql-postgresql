#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Starts the MCP server in every way its command line, environment and
database connection allow, and checks that it always ends in an orderly way.

Four groups:

  one-shot   --version, --help, the lock and manifest writers and --list-tools
             with odd arguments and environment settings (no database needed)
  stdio      the stdio server with each tuning knob at normal, edge and
             invalid values
  http       --http with odd ports, binds, tokens, token files, paths and TLS
             settings; it is started, asked one question where it listens, and
             stopped with SIGTERM
  database   a wrong port, user, password and database, a listener that is not a
             database (silent, hangs up, sends garbage), and a connection that is
             killed under a running server

What must hold for every run: it ends within its time limit (a server that does not
stop on SIGTERM or end of input is killed and counted), it is not killed by a
signal it did not receive, and where the case states an exit status it has it.
What a particular misconfiguration is refused with is not asserted.

  MCP_SERVER_EXE      the server binary (required)
  PG*                 the engine to connect to (inherited) for the stdio, http
                      and kill cases (PGHOST may be a socket directory)
  MCP_PSQL_BIN        psql, for the killed-connection cases

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

EXE = os.environ.get("MCP_SERVER_EXE", "")
_FAILURES = 0
_COUNT = 0
_OFFENDERS: list = []
_IGNORED_TERM: list = []   # http servers still running 20 s after SIGTERM

_NO_DB = {"PGHOST": "", "PGPORT": "", "PGDATABASE": "", "PGUSER": "", "PGPASSWORD": "", "FSQL_MCP_PG_CONN_URI": ""}
_INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cli", "version": "0"}}})
_LIST = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
_CALL = json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": {"name": "fractal_version", "arguments": {}}})


def _check(label, cond):
    global _FAILURES
    print(("PASS " if cond else "FAIL ") + label, flush=True)
    if not cond:
        _FAILURES += 1
    return bool(cond)


def _env(extra):
    env = dict(os.environ)
    env.pop("LD_PRELOAD", None)
    for k in ("FSQL_MCP_AUTH_TOKEN", "FSQL_MCP_AUTH_TOKEN_FILE", "FSQL_MCP_HTTPS", "FSQL_MCP_TLS_CERT_FILE",
              "FSQL_MCP_TLS_KEY_FILE", "FSQL_MCP_HTTP_PATH", "FSQL_MCP_READ_ONLY", "FSQL_MCP_LOG_LEVEL",
              "FSQL_MCP_TOOL_WHITELIST", "FSQL_MCP_ENABLED_CATEGORIES", "FSQL_MCP_STRICT_SCHEMA_HASH",
              "FSQL_MCP_SCHEMA_LOCK", "FSQL_MCP_SAFETY_LOCK", "FSQL_MCP_MANIFEST_PATH", "FSQL_MCP_PG_CONN_URI"):
        env.pop(k, None)
    env.update(extra or {})
    return env


def _record(ok, what):
    global _COUNT
    _COUNT += 1
    if not ok:
        _OFFENDERS.append(what)


def _ended_well(rc, termed=False):
    """An exit status, not a death by a signal nobody sent (negative) and not 'still
    running'. A server that was sent SIGTERM may end by it."""
    return rc is not None and (rc >= 0 or (termed and rc == -signal.SIGTERM))


def one_shot(cwd):
    """(args, env, expected) where expected is 'zero', 'nonzero' or 'any'."""
    tmp = tempfile.mkdtemp(prefix="fsqlmcp_cli_")
    lock = os.path.join(tmp, "lock")
    cases = [
        (["--version"], {}, "zero"), (["--help"], {}, "zero"), (["-h"], {}, "zero"),
        (["--no-such-flag"], {}, "nonzero"), (["--tool"], {}, "nonzero"), (["--category"], {}, "nonzero"),
        (["--schema-lock-path"], {}, "nonzero"), (["--host"], {}, "nonzero"), (["x"], {}, "nonzero"),
        (["--list-tools"], {}, "zero"),
        (["--list-tools", "--tool", "fractal_version"], {}, "zero"),
        (["--list-tools", "--tool", "fractal_version,fractal_search,"], {}, "zero"),
        (["--list-tools", "--tool", ","], {}, "zero"), (["--list-tools", "--tool", "no_such_tool"], {}, "zero"),
        (["--list-tools", "--tool", ""], {}, "zero"),
        (["--list-tools", "--category", "admin"], {}, "zero"),
        (["--list-tools", "--category", "admin,discovery,agency,analytics,cognition,enterprise,vectorizer"], {}, "zero"),
        (["--list-tools", "--category", "no_such_category"], {}, "zero"),
        (["--list-tools", "--category", "admin", "--tool", "fractal_search"], {}, "zero"),
        (["--list-tools"], {"FSQL_MCP_TOOL_WHITELIST": "fractal_search,fractal_embed"}, "zero"),
        (["--list-tools"], {"FSQL_MCP_ENABLED_CATEGORIES": "admin"}, "zero"),
        (["--list-tools"], {"FSQL_MCP_ENABLED_CATEGORIES": "", "FSQL_MCP_TOOL_WHITELIST": ""}, "zero"),
        (["--list-tools"], {"FSQL_MCP_STRICT_SCHEMA_HASH": "1"}, "any"),
        (["--list-tools"], {"FSQL_MCP_STRICT_SCHEMA_HASH": "1", "FSQL_MCP_SCHEMA_LOCK": os.path.join(tmp, "absent")}, "any"),
        (["--write-schema-lock", "--schema-lock-path", lock], {}, "zero"),
        (["--write-schema-lock", "--schema-lock-path", os.path.join(tmp, "no", "such", "dir", "lock")], {}, "any"),
        (["--write-schema-lock", "--schema-lock-path", tmp], {}, "any"),
        (["--write-schema-lock", "--schema-lock-path", ""], {}, "any"),
        (["--write-schema-lock"], {"FSQL_MCP_SCHEMA_LOCK": os.path.join(tmp, "env-lock")}, "any"),
        (["--write-safety-annotations-lock"], {"FSQL_MCP_SAFETY_LOCK": os.path.join(tmp, "safety")}, "zero"),
        (["--write-safety-annotations-lock"], {"FSQL_MCP_SAFETY_LOCK": os.path.join(tmp, "no", "dir", "safety")}, "any"),
        (["--write-safety-annotations-lock"], {"FSQL_MCP_SAFETY_LOCK": tmp}, "any"),
        (["--write-manifest"], {"FSQL_MCP_MANIFEST_PATH": os.path.join(tmp, "manifest")}, "zero"),
        (["--write-manifest"], {"FSQL_MCP_MANIFEST_PATH": os.path.join(tmp, "no", "dir", "manifest")}, "any"),
        (["--write-schema-lock", "--write-manifest", "--schema-lock-path", lock], {"FSQL_MCP_MANIFEST_PATH": os.path.join(tmp, "m2")}, "any"),
        (["--write-safety-annotations-lock", "--list-tools"], {"FSQL_MCP_SAFETY_LOCK": os.path.join(tmp, "s2")}, "any"),
        (["--list-tools", "--version"], {}, "zero"), (["--version", "--no-such-flag"], {}, "zero"),
        (["--no-such-flag", "--version"], {}, "nonzero"),
    ]
    for args, env, want in cases:
        e = _env({**_NO_DB, **env})
        try:
            r = subprocess.run([EXE, *args], env=e, cwd=cwd, capture_output=True, text=True, timeout=30,
                               stdin=subprocess.DEVNULL)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = None
        ok = _ended_well(rc) and (want == "any" or (want == "zero") == (rc == 0))
        _record(ok, "one-shot %s %s -> rc %s (wanted %s)" % (args, sorted(env), rc, want))
    _check("cli: %d one-shot command lines and environments ended as expected" % len(cases),
           not [o for o in _OFFENDERS if o.startswith("one-shot")])


def _session(args, env, send, cwd, grace=0.0, timeout=30):
    """Runs the server, writes the lines in `send`, closes stdin and returns
    (rc, stdout). rc is None for a server that had to be killed."""
    p = subprocess.Popen([EXE, *args], env=_env(env), cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    try:
        for line in send:
            p.stdin.write(line + "\n")
            p.stdin.flush()
            time.sleep(grace)
        p.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    p.stdin = None       # already closed; communicate() would try to flush it
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        return None, ""


def stdio(cwd):
    knobs = [{}]
    for name, vals in (
            ("FSQL_MCP_LOG_LEVEL", ("normal", "verbose", "bogus", "")),
            ("FSQL_MCP_READ_ONLY", ("true", "false", "1", "yes", "")),
            ("FSQL_MCP_MAX_ROWS_CEILING", ("0", "1", "-1", "abc", "99999999999999999999", "")),
            ("FSQL_MCP_MAX_CONCURRENT_CHEAP", ("0", "1", "-1", "abc", "100000")),
            ("FSQL_MCP_MAX_CONCURRENT_EXPENSIVE", ("0", "1", "-1", "abc", "100000")),
            ("FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT", ("0", "1", "-1", "abc")),
            ("FSQL_MCP_MAX_QUEUE_WAIT_MS", ("0", "1", "-1", "abc", "99999999")),
            ("FSQL_MCP_SHUTDOWN_DRAIN_MS", ("0", "1", "-1", "abc", "50")),
            ("FSQL_MCP_AGENT_PARTIAL", ("on", "off", "true", "1", "0", "garbage")),
            ("FSQL_MCP_TOOL_WHITELIST", ("fractal_search", "no_such_tool", ",", "")),
            ("FSQL_MCP_ENABLED_CATEGORIES", ("admin", "no_such_category", "admin,agency")),
            ("FSQL_MCP_STRICT_SCHEMA_HASH", ("1", "0", "true"))):
        for v in vals:
            knobs.append({name: v})
    knobs.append({"FSQL_MCP_MAX_CONCURRENT_CHEAP": "1", "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE": "1",
                  "FSQL_MCP_MAX_QUEUE_WAIT_MS": "1", "FSQL_MCP_LOG_LEVEL": "verbose"})
    n0 = len(_OFFENDERS)
    for env in knobs:
        rc, out = _session([], env, [_INIT, _LIST, _CALL], cwd)
        ok = _ended_well(rc) and (rc != 0 or '"id":1' in out.replace(" ", ""))
        _record(ok, "stdio %s -> rc %s" % (env, rc))
    for args in (["--tool", "fractal_version"], ["--category", "admin"], ["--category", "no_such"],
                 ["--tool", ","], ["--host", "127.0.0.1"]):
        rc, out = _session(args, {}, [_INIT, _LIST, _CALL], cwd)
        _record(_ended_well(rc), "stdio %s -> rc %s" % (args, rc))
    _check("cli: %d stdio server starts with tuning knobs at normal, edge and invalid values ended in order"
           % (len(knobs) + 5), len(_OFFENDERS) == n0)


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _http_run(args, env, cwd, ask=True):
    """Starts the HTTP server, probes it once, stops it with SIGTERM. Returns the
    exit status (None if it had to be killed) and whether it answered."""
    p = subprocess.Popen([EXE, *args], env=_env(env), cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    answered = False
    port = None
    for i, a in enumerate(args):
        if a == "--http" and i + 1 < len(args) and args[i + 1].isdigit():
            port = int(args[i + 1])
    deadline = time.monotonic() + 3.0
    while ask and port and time.monotonic() < deadline and p.poll() is None:
        try:
            c = socket.create_connection(("127.0.0.1", port), timeout=1)
            c.settimeout(2)
            c.sendall(b"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            answered = bool(c.recv(64))
            c.close()
            break
        except OSError:
            time.sleep(0.1)
    if not (ask and port):
        # Nothing to ask: give a start-up that refuses its arguments time to say so
        # before the stop signal arrives.
        try:
            p.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            pass
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=20)
        return p.returncode, answered
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        _IGNORED_TERM.append(" ".join(args))
        return -signal.SIGTERM, answered


def http(cwd):
    tmp = tempfile.mkdtemp(prefix="fsqlmcp_http_")
    empty = os.path.join(tmp, "empty")
    open(empty, "w").close()
    tok = os.path.join(tmp, "tok")
    open(tok, "w").write("a-long-enough-token-value-0123456789\n")
    unreadable = os.path.join(tmp, "dir")
    os.mkdir(unreadable)
    cases = []
    for port in (None, "0", "70000", "-1", "abc"):
        p = str(_free_port()) if port is None else port
        cases.append((["--http", p], {}))
        cases.append((["--http", p, "--host", "127.0.0.1"], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}))
    port = str(_free_port())
    for env in ({"FSQL_MCP_AUTH_TOKEN": "short"}, {"FSQL_MCP_AUTH_TOKEN": ""}, {"FSQL_MCP_AUTH_TOKEN": "x" * 4096},
                {"FSQL_MCP_AUTH_TOKEN_FILE": tok}, {"FSQL_MCP_AUTH_TOKEN_FILE": empty},
                {"FSQL_MCP_AUTH_TOKEN_FILE": os.path.join(tmp, "absent")}, {"FSQL_MCP_AUTH_TOKEN_FILE": unreadable},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_AUTH_TOKEN_FILE": tok},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTP_PATH": "/x"},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTP_PATH": ""},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTP_PATH": "no-slash"},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTP_PATH": "/" + "a" * 2000},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTPS": "1"},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTPS": "1", "FSQL_MCP_TLS_CERT_FILE": os.path.join(tmp, "c"),
                 "FSQL_MCP_TLS_KEY_FILE": os.path.join(tmp, "k")},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTPS": "1", "FSQL_MCP_TLS_CERT_FILE": empty,
                 "FSQL_MCP_TLS_KEY_FILE": empty},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_HTTPS": "0"},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_READ_ONLY": "true", "FSQL_MCP_LOG_LEVEL": "verbose"},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_MAX_CONCURRENT_CHEAP": "1",
                 "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE": "1", "FSQL_MCP_MAX_QUEUE_WAIT_MS": "1"}):
        cases.append((["--http", port], env))
    for bind in ("0.0.0.0", "::1", "not-an-address", "", "999.1.1.1", "localhost"):
        cases.append((["--http", port, "--host", bind], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}))
    cases.append((["--http"], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}))
    cases.append((["--http", "--host", "127.0.0.1"], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}))
    cases.append((["--http", port, "--tool", "fractal_version"], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}))
    n0 = len(_OFFENDERS)
    for args, env in cases:
        rc, _ = _http_run(args, env, cwd)
        _record(_ended_well(rc, True), "http %s %s -> rc %s" % (args, sorted(env), rc))
    # A second server on a port that is already taken.
    holder = socket.socket()
    holder.bind(("127.0.0.1", 0))
    holder.listen(1)
    taken = holder.getsockname()[1]
    rc, _ = _http_run(["--http", str(taken), "--host", "127.0.0.1"], {"FSQL_MCP_AUTH_TOKEN": "t" * 32}, cwd, ask=False)
    holder.close()
    _record(_ended_well(rc, True), "http on a taken port -> rc %s" % rc)
    _check("cli: %d http server starts with odd ports, binds, tokens, paths and TLS settings ended in order"
           % (len(cases) + 1), len(_OFFENDERS) == n0)


class _FakeDb(threading.Thread):
    """A TCP listener that is not a database. mode: silent (accepts and says
    nothing), hangup (closes at once), garbage (sends bytes that are not a
    handshake), partial (a few bytes of a plausible greeting, then closes)."""

    def __init__(self, mode):
        super().__init__(daemon=True)
        self.mode = mode
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.5)
        self.port = self.sock.getsockname()[1]
        self.stop = False
        self.start()

    def run(self):
        held = []
        while not self.stop:
            try:
                c, _ = self.sock.accept()
            except OSError:
                continue
            try:
                if self.mode == "hangup":
                    c.close()
                    continue
                if self.mode == "garbage":
                    c.sendall(b"\xff" * 64 + b"\x00\x01\x02garbage\r\n")
                    c.close()
                    continue
                if self.mode == "partial":
                    c.sendall(b"\x4a\x00\x00\x00\x0a" + b"5.5.5-fake\x00")
                    c.close()
                    continue
                held.append(c)       # silent
            except OSError:
                pass
        for c in held:
            c.close()
        self.sock.close()


def database(cwd):
    base = {k: os.environ.get(k, "") for k in ("PGHOST", "PGPORT", "PGUSER", "PGPASSWORD",
                                                "PGDATABASE")}
    base["PGCONNECT_TIMEOUT"] = "3"    # the silent listener must be given up on, not waited out
    cases = [
        {"PGPORT": str(_free_port())},                                   # nothing listening
        {"PGHOST": "127.0.0.1", "PGPORT": "1"},
        {"PGHOST": "no-such-host.invalid"},
        {"PGPASSWORD": "wrong-password"},
        {"PGUSER": "no_such_user", "PGPASSWORD": "x"},
        {"PGDATABASE": "no_such_database"},
        {"PGDATABASE": ""},
        {"PGPORT": "abc"}, {"PGPORT": "-5"}, {"PGPORT": "99999"}, {"PGHOST": ""},
        {"PGUSER": "u" * 5000}, {"PGDATABASE": "d" * 5000},
    ]
    fakes = []
    for mode in ("hangup", "garbage", "partial", "silent"):
        f = _FakeDb(mode)
        fakes.append(f)
        cases.append({"PGHOST": "127.0.0.1", "PGPORT": str(f.port)})
    n0 = len(_OFFENDERS)
    for env in cases:
        rc, _ = _session([], {**base, **env}, [_INIT, _LIST, _CALL], cwd, timeout=40)
        _record(_ended_well(rc), "database %s -> rc %s" % ({k: v[:20] for k, v in env.items()}, rc))
    # The http server with the same unusable databases.
    for env in cases[:4] + cases[-5:-1]:
        rc, _ = _http_run(["--http", str(_free_port()), "--host", "127.0.0.1"],
                          {**base, **env, "FSQL_MCP_AUTH_TOKEN": "t" * 32}, cwd)
        _record(_ended_well(rc, True), "database (http) %s -> rc %s" % ({k: v[:20] for k, v in env.items()}, rc))
    for f in fakes:
        f.stop = True
    _check("cli: %d unusable database settings and listeners that are not a database ended in order"
           % (len(cases) + 8), len(_OFFENDERS) == n0)


def killed_connection(cwd):
    """The server's connection to the database is killed under it; the next calls
    must come back (reconnected or as clean errors), never take the server down."""
    exe = os.environ.get("MCP_PSQL_BIN")
    port = os.environ.get("PGPORT", "")
    if not exe or not port.isdigit():
        print("SKIP cli: killed-connection cases (needs psql and PGPORT)")
        return
    # The server's own stderr is kept: if it dies here, its last words are
    # the only way to tell a crash from a clean exit.
    errpath = os.path.join(tempfile.mkdtemp(prefix="fsqlkill_"), "server.err")
    errf = open(errpath, "wb")
    p = subprocess.Popen([EXE], env=_env({}), cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=errf, text=True)
    out_q: list = []
    threading.Thread(target=lambda: [out_q.append(l) for l in p.stdout], daemon=True).start()

    def send(msg):
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()

    def wait_id(i, t=20):
        end = time.monotonic() + t
        while time.monotonic() < end:
            for l in list(out_q):
                try:
                    if json.loads(l).get("id") == i:
                        return json.loads(l)
                except ValueError:
                    pass
            time.sleep(0.05)
        return None

    ok = True
    answers = 0
    gone = ""
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        ok &= wait_id(1) is not None
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": "fractal_version", "arguments": {}}})
        ok &= wait_id(2) is not None
        for rnd in range(4):
            # Terminate every other backend of this database: the server's own connection among them.
            subprocess.run([exe, "-X", "-tA", "-c",
                            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' "
                            "AND pid <> pg_backend_pid() AND datname = current_database()"],
                           capture_output=True, text=True)
            time.sleep(0.3)
            for k in range(3):
                rid = 100 + rnd * 10 + k
                send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                      "params": {"name": ("fractal_version", "fractal_embed", "fractal_schema_context")[k],
                                 "arguments": {} if k != 1 else {"text": "x"}}})
                if wait_id(rid, 30) is not None:
                    answers += 1
    except OSError as e:
        # The pipe to the server broke, which means the server is gone. Say so
        # -- with its exit code -- instead of reporting a bare pipe error.
        gone = "the server stopped reading its input (%s), exit code %s" % (e, p.poll())
        ok = False
    ok &= p.poll() is None
    try:
        p.stdin.close()
        p.wait(timeout=20)
    except Exception:  # noqa: BLE001
        p.kill()
        p.wait()
        ok = False
    errf.close()
    passed = ok and answers == 12 and p.returncode == 0
    if not passed:
        try:
            with open(errpath, "r", errors="replace") as fh:
                tail = fh.read()[-3000:].strip()
        except OSError:
            tail = ""
        if gone:
            print("      " + gone, flush=True)
        print("      server stderr: " + (tail if tail else "(nothing)"), flush=True)
    _check("cli: the server answered %d of 12 calls made after its database connection was killed, and exited "
           "in order" % answers, passed)


def run():
    if not EXE or not os.path.isfile(EXE):
        print("FAIL MCP_SERVER_EXE is not set to a server binary")
        return 1
    cwd = os.environ.get("MCP_SERVER_CWD") or tempfile.mkdtemp(prefix="fsqlmcp_cwd_")
    if not os.path.isdir(cwd):
        os.makedirs(cwd, exist_ok=True)
    shown = 0
    for fn in (one_shot, stdio, http, database, killed_connection):
        try:
            fn(cwd)
        except Exception as e:  # noqa: BLE001
            _check("cli: %s raised %r" % (fn.__name__, e), False)
        for o in _OFFENDERS[shown:shown + 8]:
            print("      offender: " + o, flush=True)
        shown = len(_OFFENDERS)
    _check("cli: every idle http server stopped on SIGTERM%s"
           % ("" if not _IGNORED_TERM else " (still running after 20 s: %d, first: %s)"
              % (len(_IGNORED_TERM), _IGNORED_TERM[0])), not _IGNORED_TERM)
    return 1 if _FAILURES else 0


if __name__ == "__main__":
    rc = run()
    print("mcp-cli: %s; %d failure(s), %d runs" % ("ALL GREEN" if not rc else "FAILED", _FAILURES, _COUNT))
    sys.exit(rc)
