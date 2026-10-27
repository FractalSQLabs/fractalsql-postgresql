#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Engine-agnostic robustness probes for the fractalsql-*-mcp C++ servers.

Run from the end of mcp_smoke_client.py (it imports this module and calls
run(check)), so it rides the existing MCP gate on POSIX and on Windows with
the same environment contract and no new gate to register:

  MCP_SERVER_EXE   the server binary just built        (required)
  MCP_SERVER_CWD   the server process's working dir    (default: the exe's dir)
  MCP_HERE         the mcp/ directory                  (for the C++ probe)
  ...plus whatever the engine needs to connect (inherited from os.environ).

The probes use only the wire protocol and the server's own tools/list, so the
same file serves every engine repo. They pin defects that were found in the
PostgreSQL server and that the sibling servers share by construction:

  1. A line of valid JSON that is not an object ([] / 42 / null / "s"), a
     non-string "method", or a non-object "params" must never take the
     process down: value() on the wrong JSON type throws, and a throw out of
     the dispatcher on the stdio worker thread is std::terminate.
  2. The same bodies inside an HTTP batch (a connection thread) likewise.
  3. An explicit JSON null for an OPTIONAL parameter reached handlers that read
     it with Json::value(key, default), which throws on a present null ->
     "internal server error". Validation treats null as "absent"; the
     handler must see it absent.
  4. sanitizeSecrets ran std::regex over engine error text; std::regex recurses
     per character, so a long message threw regex_error(error_complexity)
     (MSVC) or could exhaust the stack. A very long string must come back as an
     ordinary error, and the C++ probe (sanitize_probe.cpp) differential-tests
     the linear replacement against the old regexes.

What must hold for EVERY probe call: a well-formed JSON-RPC response (no hang,
no dead server) and never an adapter-layer "server" error class.

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import http.client as httpc
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

_ODD_LINES = [
    "[]", "[1, 2, 3]", '"a string"', "42", "null", "true", "{}", '{"jsonrpc": "2.0"}',
    '{"method": "ping"}', '{"jsonrpc": "2.0", "id": 1}',
    '{"jsonrpc": "2.0", "id": 1, "method": 5}',
    '{"jsonrpc": "2.0", "id": 1, "method": null}',
    '{"jsonrpc": "2.0", "id": 1, "method": {"a": 1}}',
    '{"jsonrpc": "2.0", "id": 1, "method": ["ping"]}',
    '{"jsonrpc": "2.0", "method": "tools/call"}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": "x"}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": null}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": []}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": 5}}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "x", "arguments": []}}',
    '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "x", "arguments": "y"}}',
    '{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": []}',
    '{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": 5}}',
    '{"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": {"name": 5}}',
    '{"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": "x"}',
    '{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": []}',
    '{"jsonrpc": "2.0", "method": "notifications/cancelled"}',
    '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}',
    '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": null}}',
    '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": {"a": [1]}}}',
    "{not json", "", "   ", "\t",
]


class _Session:
    """One stdio server process. Responses are matched by id on a reader
    thread so requests and answers interleave and a wedged server times out
    instead of hanging the gate."""

    def __init__(self, exe, cwd, env_extra=None, args=()):
        env = dict(os.environ)
        env.update(env_extra or {})
        self.p = subprocess.Popen(
            [exe, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd=cwd, env=env, text=True,
            encoding="utf-8", bufsize=1)
        self.q = queue.Queue()
        self._n = 0
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.q.put(line)
        self.q.put(None)

    def raw(self, text):
        self.p.stdin.write(text + "\n")
        self.p.stdin.flush()

    def send(self, method, params=None, notify=False, rid=None):
        self._n += 1
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self._n if rid is None else rid
        self.raw(json.dumps(msg))
        return msg.get("id")

    def recv(self, want, timeout=60):
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("timed out waiting for id=%r" % (want,))
            try:
                line = self.q.get(timeout=left)
            except queue.Empty:
                raise RuntimeError("timed out waiting for id=%r" % (want,))
            if line is None:
                self.q.put(None)
                raise RuntimeError("server closed stdout (process died?)")
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                raise RuntimeError("non-JSON line on stdout: " + line[:200])
            if isinstance(obj, dict) and obj.get("id") == want:
                return obj

    def call(self, method, params=None, timeout=60):
        return self.recv(self.send(method, params), timeout)

    def alive(self):
        return self.p.poll() is None

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.p.wait(timeout=20)
        except Exception:  # noqa: BLE001
            self.p.kill()
            self.p.wait(timeout=10)
        return self.p.returncode


def _init(s):
    s.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "robustness", "version": "0"}})
    s.send("notifications/initialized", {}, notify=True)


def _is_server_error(resp):
    """The adapter-layer bug class: an uncaught exception reported as the
    "server" taxonomy class, or the dispatcher's generic internal error."""
    if not isinstance(resp, dict):
        return True
    if "error" in resp and "internal" in str((resp["error"] or {}).get("message", "")).lower():
        return True
    sc = (resp.get("result") or {}).get("structuredContent")
    return isinstance(sc, dict) and sc.get("error_class") == "server"


# ---- schema-driven argument fixtures (engine-agnostic) ---------------------

def _val(schema):
    t = schema.get("type")
    if isinstance(t, list):
        t = [x for x in t if x != "null"][0]
    if "enum" in schema and schema["enum"]:
        return schema["enum"][0]
    if t == "array":
        it = schema.get("items", {}).get("type")
        return ["ff00"] if it == "string" else ([1, 2, 3] if it == "integer" else [0.1, 0.2, 0.3])
    if t == "string":
        return "smoke"
    if t == "integer":
        return 3
    if t == "number":
        return 0.5
    if t == "boolean":
        return False
    if t == "object":
        return {}
    return "smoke"


_BAD = {"string": 12345, "integer": "not-a-number", "number": "not-a-number",
        "boolean": "maybe", "array": "not-an-array", "object": [1, 2]}


def _scalar_type(schema):
    t = schema.get("type")
    if isinstance(t, list):
        t = [x for x in t if x != "null"][0]
    return t


def _tool_calls(s, tools, check):
    """Mutate each tool's argument set one thing at a time. Destructive tools
    only get mutations that are rejected before the handler runs (so a real
    reset / drop / ALTER SYSTEM can never execute from this sweep)."""
    bad, n = [], 0
    for tool in tools:
        name = tool["name"]
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        destructive = bool((tool.get("annotations") or {}).get("destructiveHint"))
        full = {k: _val(v) for k, v in props.items()}
        pre_handler, executing = [], []
        for k, v in props.items():
            if k in required:
                pre_handler.append(("drop required %s" % k, {a: b for a, b in full.items() if a != k}, True))
            t = _scalar_type(v)
            if t in _BAD:
                pre_handler.append(("wrong type %s" % k, {**full, k: _BAD[t]}, False))
        pre_handler.append(("unknown property", {**full, "zz_unknown": 1}, False))
        if not destructive:
            executing.append(("required only", {k: full[k] for k in required}, False))
            executing.append(("fully filled", full, False))
            for k, v in props.items():
                if k not in required:
                    # the null-optional crash: validation skips the null, the
                    # handler used to throw on it
                    executing.append(("null optional %s" % k, {**full, k: None}, False))
                    executing.append(("only optional %s" % k, {**{r: full[r] for r in required}, k: full[k]}, False))
        for label, args, must_schema in pre_handler + executing:
            n += 1
            try:
                resp = s.call("tools/call", {"name": name, "arguments": args}, timeout=120)
            except Exception as e:  # noqa: BLE001
                bad.append("%s [%s]: %r" % (name, label, e))
                if not s.alive():
                    break
                continue
            if _is_server_error(resp):
                bad.append("%s [%s]: %s" % (name, label, json.dumps(resp)[:200]))
            elif must_schema:
                res = resp.get("result") or {}
                if not (res.get("isError") or "error" in resp):
                    bad.append("%s [%s]: a dropped required argument was accepted" % (name, label))
        if not s.alive():
            bad.append("SERVER DIED during " + name)
            break
    check("robustness: %d mutated / null-optional tool calls over %d tools all answered, none a server error"
          % (n, len(tools)), not bad)
    for b in bad[:8]:
        print("      offender: " + b)
    return tools


def _long_strings(s, tools, check):
    """A very long string reaches the engine and comes back inside its error
    text, which passes through sanitizeSecrets (the old regex pair threw on it)."""
    bad, n = [], 0
    for tool in tools:
        if (tool.get("annotations") or {}).get("destructiveHint"):
            continue
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        strs = [k for k, v in props.items() if _scalar_type(v) == "string" and "enum" not in v]
        if not strs:
            continue
        full = {k: _val(v) for k, v in props.items() if k in required}
        for k in strs[:2]:
            args = dict(full)
            args[k] = "x" * 300000
            n += 1
            try:
                resp = s.call("tools/call", {"name": tool["name"], "arguments": args}, timeout=120)
            except Exception as e:  # noqa: BLE001
                bad.append("%s.%s: %r" % (tool["name"], k, e))
                break
            if _is_server_error(resp):
                bad.append("%s.%s: %s" % (tool["name"], k, json.dumps(resp)[:200]))
        if n >= 12 or not s.alive():
            break
    check("robustness: %d calls with a 300000-character string argument answered, none a server error" % n,
          not bad and n > 0)
    for b in bad[:5]:
        print("      offender: " + b)


# Values that pass the schema's top-level type check but are wrong, degenerate
# or hostile once they reach the handler: bad array elements, numbers at the
# edge of every conversion, empty / over-long / quote-laden strings, nested
# objects. (_tool_calls only swaps a whole parameter for the wrong JSON type.)
_VALUE_ARRAYS = [
    [], [1, "x", 3], [[1, 2], [3]], [None, 1.0], [True, False], ["1", "2"], [{"a": 1}],
    [1e308, -1e308], [2 ** 70, 1], [0.0], [5.0] * 64, [0.0] * 40,
    [round(((i * 7919) % 211) / 17.0 - 6.0, 3) for i in range(300)],
    [round(i / 4.0, 3) for i in range(256)],
]
_VALUE_INTS = [-1, 0, 2 ** 63, True]
_VALUE_NUMS = [-1.0, 0, 1e308, -0.0, 1e-320]
_VALUE_STRS = ["", "   ", 'a"b', "it's", "x" * 70, "\u00e9\u4e2d", "'; select 1; --",
               # secret-shaped text: engines echo identifiers in their errors, and the
               # echo passes through sanitizeSecrets (URI credentials, KEY=value)
               "postgres://user:hunter2@db.example/x", "x://user@host", "x://:pw@h", "x://u:pw",
               "x://u:@h", "://u:p@h", " ://u:p@h", "a://u:b://c:d@h",
               "DB_PASSWORD=abc", "my_api_key = abc", "AUTH_TOKEN=tok", "PASSWORD=", "password =",
               "=x", "x=y", "SECRET_KEY=   ", "api_key=a b"]
_VALUE_BOOLS = [0, 1, "true"]
_VALUE_OBJS = [{}, {"a": {"b": [1, {"c": None}]}}, {"k": "v", "n": 1}]


def _value_sweep(s, tools, check, budget_s=240):
    """One parameter at a time takes each hostile value while the others keep
    their fixture values. Only non-destructive tools run it (a hostile value
    must never reach a real drop / reset), and the integer set stays clear of
    large positives so no search is asked for 2^31 iterations."""
    pool = {"array": _VALUE_ARRAYS, "integer": _VALUE_INTS, "number": _VALUE_NUMS,
            "string": _VALUE_STRS, "boolean": _VALUE_BOOLS, "object": _VALUE_OBJS}
    bad, n = [], 0
    stop = time.monotonic() + budget_s
    for tool in tools:
        if (tool.get("annotations") or {}).get("destructiveHint"):
            continue
        props = (tool.get("inputSchema") or {}).get("properties", {})
        full = {k: _val(v) for k, v in props.items()}
        for k, v in props.items():
            t = _scalar_type(v)
            vals = [] if "enum" in v else pool.get(t, [])
            for val in vals:
                if time.monotonic() > stop or not s.alive():
                    break
                n += 1
                try:
                    resp = s.call("tools/call", {"name": tool["name"], "arguments": {**full, k: val}}, timeout=120)
                except Exception as e:  # noqa: BLE001
                    bad.append("%s.%s=%s: %r" % (tool["name"], k, json.dumps(val)[:40], e))
                    break
                if _is_server_error(resp):
                    bad.append("%s.%s=%s: %s" % (tool["name"], k, json.dumps(val)[:40], json.dumps(resp)[:160]))
    check("robustness: %d hostile-value tool calls (bad array elements, edge numbers, odd strings) answered, none a server error" % n,
          not bad and n > 0 and s.alive())
    for b in bad[:8]:
        print("      offender: " + b)


def _protocol_sweep(s, check):
    """resources/* and prompts/* driven from their own listings: every listed
    uri / prompt is read with good, missing, empty and oddly-typed arguments.
    Each answer must be well formed and none may be a server error."""
    bad, n = [], 0

    def probe(method, params):
        nonlocal n
        n += 1
        try:
            resp = s.call(method, params, timeout=60)
        except Exception as e:  # noqa: BLE001
            bad.append("%s %s: %r" % (method, json.dumps(params)[:80], e))
            return {}
        if _is_server_error(resp):
            bad.append("%s %s: %s" % (method, json.dumps(params)[:80], json.dumps(resp)[:160]))
        return resp

    rl = probe("resources/list", {})
    probe("resources/templates/list", {})
    uris = [r.get("uri") for r in ((rl.get("result") or {}).get("resources") or []) if isinstance(r, dict)]
    for uri in uris:
        if not isinstance(uri, str):
            continue
        for u in ([uri] if "{" not in uri else
                  [uri.replace("{kind}", k) for k in ("0", "1", "2", "3", "-1", "x", "", "99999999999")]):
            probe("resources/read", {"uri": u})
    for u in ("", "fractalsql://", "fractalsql://nope", "http://example.invalid/x", "x" * 5000):
        probe("resources/read", {"uri": u})
    probe("resources/read", {})
    pl = probe("prompts/list", {})
    for pr in ((pl.get("result") or {}).get("prompts") or []):
        if not isinstance(pr, dict) or not isinstance(pr.get("name"), str):
            continue
        names = [a.get("name") for a in (pr.get("arguments") or []) if isinstance(a, dict)]
        variants = [{}, {k: "" for k in names}, {k: "   " for k in names}, {k: None for k in names},
                    {k: "a, b ,,c" for k in names}, {k: " a , b " for k in names}, {k: [1, 2, 3] for k in names},
                    {k: 7 for k in names}, {k: {"a": 1} for k in names}, {k: "1,2,3" for k in names},
                    {k: "x" * 400 for k in names}]
        for v in variants:
            probe("prompts/get", {"name": pr["name"], "arguments": v})
        for k in names:
            probe("prompts/get", {"name": pr["name"], "arguments": {k: "smoke"}})
    probe("prompts/get", {"name": "no-such-prompt"})
    probe("prompts/get", {"name": ""})
    probe("prompts/get", {})
    probe("completion/complete", {"ref": {"type": "ref/prompt", "name": "x"}, "argument": {"name": "a", "value": ""}})
    probe("logging/setLevel", {"level": "debug"})
    probe("no/such/method", {})
    check("robustness: %d resources/* and prompts/* calls (every listed uri and prompt, odd arguments) answered, none a server error" % n,
          not bad and n > 0 and s.alive())
    for b in bad[:6]:
        print("      offender: " + b)


def _stdio_phase(exe, cwd, check):
    s = _Session(exe, cwd)
    try:
        _init(s)
        # request ids of every JSON type come back verbatim
        id_bad = []
        for rid in ("str-id", 4.5, {"a": 1}, [1, 2], 0, "", True):
            s.raw(json.dumps({"jsonrpc": "2.0", "id": rid, "method": "ping"}))
            try:
                if "result" not in s.recv(rid, 15):
                    id_bad.append(rid)
            except Exception:  # noqa: BLE001
                id_bad.append(rid)
        check("robustness: ping with string / float / object / array / zero / empty / bool ids is echoed", not id_bad)

        bad = []
        for line in _ODD_LINES:
            s.raw(line)
            try:
                if "result" not in s.call("ping", {}, timeout=20):
                    bad.append(line)
            except Exception as e:  # noqa: BLE001
                bad.append("%s -> %r" % (line, e))
                break
        check("robustness: %d odd / malformed request lines leave the server alive and in sync" % len(_ODD_LINES),
              not bad and s.alive())
        for b in bad[:3]:
            print("      offender: " + b)

        s.raw("x" * (8 * 1024 * 1024 + 64))
        try:
            ok = "result" in s.call("ping", {}, timeout=40)
        except Exception:  # noqa: BLE001
            ok = False
        check("robustness: a line past the 8 MiB bound does not wedge or kill the stream", ok and s.alive())

        r = s.call("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}})
        pv = (r.get("result") or {}).get("protocolVersion")
        check("robustness: an unsupported protocolVersion is answered with a supported one",
              isinstance(pv, str) and pv != "1999-01-01")
        check("robustness: a non-string protocolVersion still initializes",
              "result" in s.call("initialize", {"protocolVersion": 5}))

        listed = s.call("tools/list", {})
        tools = (listed.get("result") or {}).get("tools") or []
        check("robustness: tools/list returned a catalog to sweep", len(tools) > 5)
        _tool_calls(s, tools, check)
        _long_strings(s, tools, check)
        _value_sweep(s, tools, check)
        _protocol_sweep(s, check)
        check("robustness: the server is still answering after the sweep",
              "result" in s.call("ping", {}, timeout=30) and s.alive())
    finally:
        rc = s.close()
    check("robustness: stdio server exits cleanly (rc 0) after the full robustness run", rc == 0)


def _surface_phase(exe, cwd, check):
    """The command-line / environment surface: one-shot flags, bad flags,
    log levels, tool filters, and the HTTP / HTTPS configuration errors. Each
    run must exit or answer promptly; nothing here needs a healthy database."""
    def run1(args, env_extra=None, timeout=30):
        env = dict(os.environ)
        env.update(env_extra or {})
        try:
            r = subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout,
                               cwd=cwd, env=env, input="")
            return r.returncode, (r.stdout or "") + (r.stderr or "")
        except Exception as e:  # noqa: BLE001
            return None, repr(e)

    bad = []
    for args, want_zero in ((["--version"], True), (["--help"], True), (["-h"], True),
                            (["--list-tools"], True), (["--list-tools", "--category", "analytics"], True),
                            (["--bogus-flag"], False), (["--tool"], False), (["--category"], False),
                            (["--host"], False), (["--path"], False), (["--tls-cert"], False),
                            (["--schema-lock-path"], False)):
        rc, out = run1(args)
        if rc is None or (rc == 0) != want_zero:
            bad.append("%s -> rc=%r %s" % (" ".join(args), rc, out[:80]))
    # HTTP / HTTPS configuration errors exit non-zero immediately
    for args, env in ((["--http", "0"], {"FSQL_MCP_AUTH_TOKEN": "", "FSQL_MCP_AUTH_TOKEN_FILE": ""}),
                      (["--https", "0"], {"FSQL_MCP_AUTH_TOKEN": "t"}),
                      (["--https", "0", "--tls-cert", "/nonexistent.pem"], {"FSQL_MCP_AUTH_TOKEN": "t"}),
                      (["--https", "0", "--tls-cert", "/nonexistent.pem", "--tls-key", "/nonexistent.key"],
                       {"FSQL_MCP_AUTH_TOKEN": "t"}),
                      ([], {"FSQL_MCP_TRANSPORT": "http", "FSQL_MCP_AUTH_TOKEN": "", "FSQL_MCP_AUTH_TOKEN_FILE": ""}),
                      ([], {"FSQL_MCP_HTTPS": "1", "FSQL_MCP_TRANSPORT": "http", "FSQL_MCP_AUTH_TOKEN": "t",
                            "FSQL_MCP_TLS_CERT_FILE": "/nonexistent.pem"})):
        rc, out = run1(args, env)
        if rc is None or rc == 0:
            bad.append("%s %s -> rc=%r" % (" ".join(args), sorted(env), rc))
    check("robustness: one-shot flags, bad flags and HTTP/HTTPS config errors exit as documented", not bad)
    for b in bad[:6]:
        print("      offender: " + b)

    # stdio with each log level and tool filter still answers tools/list + ping
    bad = []
    for label, args, env in (("log verbose", [], {"FSQL_MCP_LOG_LEVEL": "verbose"}),
                             ("log error", [], {"FSQL_MCP_LOG_LEVEL": "error"}),
                             ("log other", [], {"FSQL_MCP_LOG_LEVEL": "bogus"}),
                             ("env categories", [], {"FSQL_MCP_ENABLED_CATEGORIES": "analytics, discovery"}),
                             ("env whitelist", [], {"FSQL_MCP_TOOL_WHITELIST": "fractal_search,fractal_dimension_dfa,nope"}),
                             ("flag category", ["--category", "analytics"], {}),
                             ("flag tool", ["--tool", "fractal_dimension_dfa"], {})):
        s = _Session(exe, cwd, env, args)
        try:
            _init(s)
            lst = (s.call("tools/list", {}).get("result") or {}).get("tools") or []
            r = s.call("tools/call", {"name": "fractal_dimension_dfa", "arguments": {"series": [0.1, 0.5, 0.2, 0.9]}}, timeout=60)
            if _is_server_error(r) or "result" not in s.call("ping", {}):
                bad.append("%s: %s" % (label, json.dumps(r)[:120]))
            if label.startswith(("env categories", "flag category", "env whitelist", "flag tool")) and not 0 < len(lst) < 82:
                bad.append("%s: filter left %d tools" % (label, len(lst)))
        except Exception as e:  # noqa: BLE001
            bad.append("%s: %r" % (label, e))
        finally:
            s.close()
    check("robustness: log levels and --tool / --category / env tool filters serve a narrowed catalog", not bad)
    for b in bad[:6]:
        print("      offender: " + b)

    # HTTP configured by flags (--http-transport, --host, --path) and by env
    bad = []
    for label, build in (
            ("flags", lambda port: (["--http-transport", str(port), "--host", "127.0.0.1", "--path", "/rb"], {}, "/rb")),
            ("env", lambda port: (["--http", str(port)], {"FSQL_MCP_HTTP_HOST": "127.0.0.1", "FSQL_MCP_HTTP_PATH": "/envp"}, "/envp")),
            ("transport env", lambda port: ([], {"FSQL_MCP_TRANSPORT": "http", "FSQL_MCP_HTTP_PORT": str(port)}, "/mcp"))):
        port = _free_port()
        args, env, path = build(port)
        e = dict(os.environ, FSQL_MCP_AUTH_TOKEN="surface-token", **env)
        p = subprocess.Popen([exe, *args], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, cwd=cwd, env=e)
        try:
            up = False
            for _ in range(60):
                if p.poll() is not None:
                    break
                try:
                    c = httpc.HTTPConnection("127.0.0.1", port, timeout=2)
                    c.request("GET", "/healthz")
                    rr = c.getresponse()
                    rr.read()
                    c.close()
                    up = rr.status == 200
                    if up:
                        break
                except Exception:  # noqa: BLE001
                    time.sleep(0.15)
            if not up:
                bad.append("%s: did not come up on %d" % (label, port))
                continue
            hdr = {"Authorization": "Bearer surface-token", "Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
            for method, target, h, body, ok_status in (
                    ("POST", path, hdr, json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                   "params": {"protocolVersion": "2025-06-18"}}), (200,)),
                    ("POST", "/elsewhere", hdr, "{}", (404,)),
                    ("GET", path, hdr, None, (405, 404)),
                    ("POST", path, {k: v for k, v in hdr.items() if k != "Authorization"}, "{}", (401,)),
                    ("POST", path, {**hdr, "Authorization": "Bearer wrong"}, "{}", (401,)),
                    ("DELETE", path, hdr, None, (200, 202, 204, 400, 404, 405)),
                    ("PUT", path, hdr, "{}", (404, 405)),
                    ("GET", "/readyz", hdr, None, (200, 404, 503)),
                    ("GET", "/healthz", {}, None, (200,))):
                try:
                    c = httpc.HTTPConnection("127.0.0.1", port, timeout=20)
                    c.request(method, target, body=body, headers=h)
                    rr = c.getresponse()
                    rr.read()
                    c.close()
                    if rr.status not in ok_status:
                        bad.append("%s %s %s -> %d" % (label, method, target, rr.status))
                except Exception as ex:  # noqa: BLE001
                    bad.append("%s %s %s: %r" % (label, method, target, ex))
        finally:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=15)
                except Exception:  # noqa: BLE001
                    p.kill()
    check("robustness: HTTP configured by flags, by env and by FSQL_MCP_TRANSPORT serves the right path and refuses the rest", not bad)
    for b in bad[:6]:
        print("      offender: " + b)


def _read_only_phase(exe, cwd, check):
    try:
        helptxt = subprocess.run([exe, "--help"], capture_output=True, text=True,
                                 timeout=30, cwd=cwd).stdout
    except Exception:  # noqa: BLE001
        helptxt = ""
    if "FSQL_MCP_READ_ONLY" not in helptxt:
        print("SKIP robustness: this server does not advertise FSQL_MCP_READ_ONLY")
        return
    s = _Session(exe, cwd, {"FSQL_MCP_READ_ONLY": "true"})
    try:
        _init(s)
        tools = (s.call("tools/list", {}).get("result") or {}).get("tools") or []
        destructive = [t for t in tools if (t.get("annotations") or {}).get("destructiveHint")]
        if not destructive:
            print("SKIP robustness: no destructive tool to refuse in read-only mode")
            return
        t = destructive[0]
        args = {k: _val(v) for k, v in t.get("inputSchema", {}).get("properties", {}).items()
                if k in set(t.get("inputSchema", {}).get("required", []))}
        r = s.call("tools/call", {"name": t["name"], "arguments": args}, timeout=60)
        txt = json.dumps(r).lower()
        check("robustness: read-only mode refuses a destructive tool (%s) before the engine" % t["name"],
              ((r.get("result") or {}).get("isError") is True or "error" in r) and "read-only" in txt)
        non_destructive = [x for x in tools if not (x.get("annotations") or {}).get("destructiveHint")]
        check("robustness: read-only mode still lists and serves the non-destructive tools",
              len(non_destructive) > 0 and "result" in s.call("ping", {}))
    finally:
        s.close()


def _free_port():
    with socket.socket() as sk:
        sk.bind(("127.0.0.1", 0))
        return sk.getsockname()[1]


def _http_phase(exe, cwd, check):
    """HTTP edge: non-object bodies and batch members must not abort the
    server from a connection thread."""
    port = _free_port()
    token = "robustness-token"
    env = dict(os.environ, FSQL_MCP_AUTH_TOKEN=token, FSQL_MCP_HTTP_PORT=str(port))
    p = subprocess.Popen([exe, "--http", str(port)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, cwd=cwd, env=env)

    def post(body, session=None):
        c = httpc.HTTPConnection("127.0.0.1", port, timeout=20)
        hdr = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
        if session:
            hdr["Mcp-Session-Id"] = session
        c.request("POST", "/mcp", body=body if isinstance(body, (bytes, str)) else json.dumps(body), headers=hdr)
        r = c.getresponse()
        data = r.read().decode("utf-8", "replace")
        sid = r.getheader("Mcp-Session-Id")
        c.close()
        return r.status, data, sid

    try:
        up = False
        for _ in range(80):
            if p.poll() is not None:
                break
            try:
                c = httpc.HTTPConnection("127.0.0.1", port, timeout=2)
                c.request("GET", "/healthz")
                rr = c.getresponse()
                rr.read()
                c.close()
                if rr.status == 200:
                    up = True
                    break
            except Exception:  # noqa: BLE001
                time.sleep(0.15)
        if not check("robustness: the HTTP server came up for the edge probes", up):
            return
        st, _, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                           "params": {"protocolVersion": "2025-06-18"}})
        bodies = ['[1, "x", null, [], {}]', "42", '"s"', "null", "true", "[]",
                  '{"jsonrpc": "2.0", "id": 1, "method": 5}',
                  '[{"jsonrpc": "2.0", "id": 1, "method": 5}, 7]']
        bad = []
        for b in bodies:
            try:
                st, data, _ = post(b, sid)
                if st not in (200, 202, 400):
                    bad.append("%s -> HTTP %s" % (b, st))
            except Exception as e:  # noqa: BLE001
                bad.append("%s -> %r" % (b, e))
        for b in bad[:4]:
            print("      offender: " + b)
        alive = p.poll() is None
        answers = False
        if alive:
            try:
                st, data, _ = post({"jsonrpc": "2.0", "id": 2, "method": "ping"}, sid)
                answers = st == 200 and "result" in data
            except Exception:  # noqa: BLE001
                answers = False
        check("robustness: non-object bodies and batch members over HTTP leave the server alive and answering",
              not bad and alive and answers)
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=15)
            except Exception:  # noqa: BLE001
                p.kill()


def _sanitize_probe(here, check):
    """Compile and run the C++ differential probe (old regexes vs the linear
    scanners) when a compiler is on PATH. The long-string tool calls above are
    what covers Windows/MSVC, where no g++ is present."""
    src = os.path.join(here, "tests", "sanitize_probe.cpp")
    errors = os.path.join(here, "src", "errors.cpp")
    cxx = os.environ.get("CXX") or shutil.which("g++") or shutil.which("clang++")
    if not (os.path.isfile(src) and os.path.isfile(errors) and cxx):
        print("SKIP robustness: sanitize_probe (no compiler or probe source present)")
        return
    with tempfile.TemporaryDirectory() as td:
        exe = os.path.join(td, "sanitize_probe")
        b = subprocess.run([cxx, "-std=c++17", "-O1", "-I", os.path.join(here, "src"), src, errors, "-o", exe],
                           capture_output=True, text=True)
        if b.returncode != 0:
            check("robustness: sanitize_probe builds", False)
            print(b.stderr[-600:])
            return
        r = subprocess.run([exe], capture_output=True, text=True, timeout=300)
        print(r.stdout.strip())
        check("robustness: sanitizeSecrets matches the old regex behaviour and survives huge inputs",
              r.returncode == 0)


def run(check):
    """Entry point used by mcp_smoke_client.py. `check(label, cond)` prints
    PASS/FAIL and counts failures."""
    exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ.get("MCP_SERVER_CWD") or os.path.dirname(os.path.abspath(exe)) or "."
    here = os.environ.get("MCP_HERE", "")
    for name, fn in (("stdio", lambda: _stdio_phase(exe, cwd, check)),
                     ("surface", lambda: _surface_phase(exe, cwd, check)),
                     ("read-only", lambda: _read_only_phase(exe, cwd, check)),
                     ("http", lambda: _http_phase(exe, cwd, check)),
                     ("sanitize", lambda: _sanitize_probe(here, check) if here else None)):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            check("robustness: %s phase raised %r" % (name, e), False)


if __name__ == "__main__":
    fails = 0

    def _check(label, cond):
        global fails
        print(("PASS " if cond else "FAIL ") + label)
        if not cond:
            fails += 1
        return bool(cond)

    run(_check)
    print("mcp-robustness: %s; %d failure(s)" % ("ALL GREEN" if not fails else "FAILED", fails))
    sys.exit(1 if fails else 0)
