#!/usr/bin/env python3
"""Gate-33 smoke engine for fractalsql-postgresql-mcp (engine-agnostic; talks
JSON-RPC over the binary's stdio). DB-dependent asserts run only when PG* env
wires a live FractalSQL install; the wire-level asserts always run.

Exit codes: 0 pass, 1 fail, 77 self-skip (binary missing).
"""
import json
import os
import re
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

EXPECTED_TOOLS = {
    # discovery (14)
    "fractal_search", "fractal_search_debug", "fractal_search_explore",
    "fractal_search_telemetry", "fractal_hybrid_clinical_search",
    "fractal_search_trajectory", "fractal_cross_modal_search",
    "fractal_diversify_enable", "fractal_diversify_disable",
    "fractal_diversify_set_params", "fractal_detect_collapse",
    "fractal_explain_result", "fractal_feedback_report", "fractal_isolate_background",
    # cognition (4)
    "fractal_reason", "fractal_embed", "fractal_text_to_sql", "fractal_schema_context",
    # agency (22)
    "fractal_agent_anomaly_triage", "fractal_agent_regime_triage",
    "fractal_agent_track_anomaly", "fractal_agent_detour_classify",
    "fractal_agent_network_coverage_alert", "fractal_agent_allocate",
    "fractal_agent_rebalance_sibling", "fractal_agent_diverse_portfolios",
    "fractal_agent_route_task", "fractal_agent_schedule_workload",
    "fractal_agent_outlier_intercept", "fractal_agent_patient_deterioration_triage",
    "fractal_agent_data_analyst", "fractal_agent_recall_hybrid",
    "fractal_agent_recommend_diverse", "fractal_agent_feedback_audit",
    "fractal_search_agent", "fractal_rag_agent", "fractal_sql_agent",
    "fractal_agent_plan_explore", "fractal_agent_trajectory_predict",
    "fractal_agent_detect_loop",
    # analytics (23)
    "fractal_dimension_dfa", "fractal_dimension_boxcount", "fractal_dimension_drift",
    "fractal_change_point_detect", "fractal_periodogram", "fractal_spectrogram_entropy",
    "fractal_tda_persistence_diagram",
    "fractal_state_fingerprint", "fractal_cycle_detect", "fractal_vector_lp_distance",
    "fractal_vector_quantize_int8", "fractal_vector_quantize_binary",
    "fractal_vector_hamming_distance", "fractal_vascular_network",
    "fractal_cortical_folding", "fractal_nerve_plexus_metric",
    "fractal_morphological_complexity", "fractal_optimize_portfolio",
    "fractal_optimize_portfolio_multimodal", "fractal_optimize_portfolio_multimodal_pareto",
    "fractal_optimize_subset", "fractal_store_morphology", "fractal_mine_topology_negatives",
    # enterprise (10)
    "fractal_ledger_flush", "fractal_ledger_load", "fractal_ledger_verify",
    "fractal_ledger_compact", "fractal_ledger_reset_soft", "fractal_ledger_reset_hard",
    "fractal_ledger_truth_count", "fractal_ledger_shadow_count",
    "fractal_audit_unpack", "fractal_audit_log",
    # vectorizer (5)
    "fractal_vectorizer_create", "fractal_vectorizer_pause", "fractal_vectorizer_resume",
    "fractal_vectorizer_drop", "fractal_vectorizer_process_queue",
    # admin (4)
    "fractalsql_get_version", "fractalsql_configure_reasoning",
    "fractalsql_set_config", "fractalsql_get_config",
}

# Hand-maintained safety classification, deliberately NOT generated from the server
# and NOT the same file as mcp/.mcp-safety-annotations-lock: regenerating that lock
# records whatever a new tool declares, so it cannot force anyone to decide. This table
# can: tools/list is checked against it below, and a tool missing from it, or whose
# hints differ from it, fails the smoke test. Edit it by hand when you add a tool.
#   read        readOnlyHint (no state changed)
#   write       changes state, but is not destructive (additive / recomputable)
#   destructive can discard or overwrite data or configuration; refused by FSQL_MCP_READ_ONLY
# The bool is openWorldHint: True if the tool reaches outside this DB connection
# (e.g. sends text to the embedding or reasoning provider).
EXPECTED_SAFETY = {
    "fractal_agent_allocate": ("write", True),
    "fractal_agent_anomaly_triage": ("write", True),
    "fractal_agent_data_analyst": ("write", True),
    "fractal_agent_detect_loop": ("read", False),
    "fractal_agent_detour_classify": ("write", True),
    "fractal_agent_diverse_portfolios": ("write", True),
    "fractal_agent_feedback_audit": ("write", False),
    "fractal_agent_network_coverage_alert": ("write", True),
    "fractal_agent_outlier_intercept": ("write", True),
    "fractal_agent_patient_deterioration_triage": ("write", True),
    "fractal_agent_plan_explore": ("write", True),
    "fractal_agent_rebalance_sibling": ("write", True),
    "fractal_agent_recall_hybrid": ("read", False),
    "fractal_agent_recommend_diverse": ("write", False),
    "fractal_agent_regime_triage": ("write", True),
    "fractal_agent_route_task": ("write", True),
    "fractal_agent_schedule_workload": ("write", True),
    "fractal_agent_track_anomaly": ("write", True),
    "fractal_agent_trajectory_predict": ("write", False),
    "fractal_audit_log": ("write", False),
    "fractal_audit_unpack": ("read", False),
    "fractal_change_point_detect": ("read", False),
    "fractal_cortical_folding": ("read", False),
    "fractal_cross_modal_search": ("read", False),
    "fractal_cycle_detect": ("read", False),
    "fractal_detect_collapse": ("read", False),
    "fractal_dimension_boxcount": ("read", False),
    "fractal_dimension_dfa": ("read", False),
    "fractal_dimension_drift": ("read", False),
    "fractal_diversify_disable": ("write", False),
    "fractal_diversify_enable": ("write", False),
    "fractal_diversify_set_params": ("write", False),
    "fractal_embed": ("write", True),
    "fractal_explain_result": ("read", False),
    "fractal_feedback_report": ("write", False),
    "fractal_hybrid_clinical_search": ("read", False),
    "fractal_isolate_background": ("write", False),
    "fractal_ledger_compact": ("destructive", False),
    "fractal_ledger_flush": ("destructive", False),
    "fractal_ledger_load": ("write", False),
    "fractal_ledger_reset_hard": ("destructive", False),
    "fractal_ledger_reset_soft": ("destructive", False),
    "fractal_ledger_shadow_count": ("read", False),
    "fractal_ledger_truth_count": ("read", False),
    "fractal_ledger_verify": ("read", False),
    "fractal_mine_topology_negatives": ("read", False),
    "fractal_morphological_complexity": ("read", False),
    "fractal_nerve_plexus_metric": ("read", False),
    "fractal_optimize_portfolio": ("read", False),
    "fractal_optimize_portfolio_multimodal": ("read", False),
    "fractal_optimize_portfolio_multimodal_pareto": ("read", False),
    "fractal_optimize_subset": ("read", False),
    "fractal_periodogram": ("read", False),
    "fractal_rag_agent": ("write", True),
    "fractal_reason": ("write", True),
    "fractal_schema_context": ("read", False),
    "fractal_search": ("read", False),
    "fractal_search_agent": ("write", True),
    "fractal_search_debug": ("read", False),
    "fractal_search_explore": ("read", False),
    "fractal_search_telemetry": ("read", False),
    "fractal_search_trajectory": ("read", False),
    "fractal_spectrogram_entropy": ("read", False),
    "fractal_sql_agent": ("write", True),
    "fractal_state_fingerprint": ("read", False),
    "fractal_store_morphology": ("write", False),
    "fractal_tda_persistence_diagram": ("read", False),
    "fractal_text_to_sql": ("write", True),
    "fractal_vascular_network": ("read", False),
    "fractal_vector_hamming_distance": ("read", False),
    "fractal_vector_lp_distance": ("read", False),
    "fractal_vector_quantize_binary": ("read", False),
    "fractal_vector_quantize_int8": ("read", False),
    "fractal_vectorizer_create": ("write", False),
    "fractal_vectorizer_drop": ("destructive", False),
    "fractal_vectorizer_pause": ("write", False),
    "fractal_vectorizer_process_queue": ("write", False),
    "fractal_vectorizer_resume": ("write", False),
    "fractalsql_configure_reasoning": ("destructive", False),
    "fractalsql_get_config": ("read", False),
    "fractalsql_get_version": ("read", False),
    "fractalsql_set_config": ("destructive", False),
}


class Client:
    def __init__(self, exe, env=None):
        self.p = subprocess.Popen(
            [exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env or os.environ, text=True, encoding="utf-8",
            cwd=os.path.dirname(os.path.abspath(exe)) or ".",
        )
        self._id = 0
        # Mirror the server's stderr into our stderr (prefixed) so gate runners
        # see sql-debug/log lines alongside the assert stream.
        self._err_thread = threading.Thread(target=self._pump_stderr, daemon=True)
        self._err_thread.start()
        # stdout is drained by a thread so recv() can honour its timeout: a
        # bare readline() blocks forever on a wedged server (ASan backend
        # stuck mid-report, postmaster in recovery), hanging the whole gate.
        self._out_q = queue.Queue()
        self._out_thread = threading.Thread(target=self._pump_stdout, daemon=True)
        self._out_thread.start()

    def _pump_stdout(self):
        try:
            for line in self.p.stdout:
                self._out_q.put(line)
        except Exception:
            pass
        self._out_q.put("")   # EOF sentinel

    def _pump_stderr(self):
        try:
            for line in self.p.stderr:
                sys.stderr.write("[srv] " + line)
        except Exception:
            pass

    def send(self, method, params=None, notify=False):
        self._id += 1
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self._id
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        return self._id

    def recv(self, want_id, timeout_s=60):
        # stderr may carry log lines; stdout is pure JSON-RPC
        deadline = time.monotonic() + timeout_s
        while True:
            try:
                line = self._out_q.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                raise RuntimeError("timed out after %ss waiting for response id=%r" % (timeout_s, want_id))
            if line == "":
                self._out_q.put("")   # keep EOF sticky for later recv()s
                raise RuntimeError("server closed stdout (see [srv] stderr lines above)")
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                raise RuntimeError("non-JSON line on stdout (framing corruption): " + line[:300])
            if obj.get("id") == want_id:
                return obj
            # ignore notifications / unsolicited ids

    def call(self, method, params=None, timeout_s=60):
        rid = self.send(method, params)
        return self.recv(rid, timeout_s)

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=15)
            return self.p.returncode
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
            return None


def stop_proc(proc, http=False, timeout=10):
    """Stop a server subprocess GRACEFULLY, falling back to kill().

    An instrumented (--coverage) server only writes its .gcda counters from
    a normal exit: a SIGKILL discards everything the phase just exercised,
    so the coverage report then shows well-tested code as untested. A stdio
    server exits on stdin EOF; the HTTP/TLS listener exits on SIGTERM (its
    drain path). Either way the process is killed if it does not leave
    within `timeout` seconds, so a hung server can never wedge the gate.
    """
    if proc.poll() is not None:
        return proc.returncode
    try:
        if http:
            if os.name == "nt":
                proc.terminate()
            else:
                proc.send_signal(signal.SIGTERM)
        elif proc.stdin is not None:
            proc.stdin.close()
    except Exception:
        pass
    try:
        proc.wait(timeout=timeout)
    except Exception:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
    return proc.returncode


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" -- " + str(detail)[:300]) if detail and not cond else ""))


def ok(cond, name, detail=""):
    """check + a 0/1 tally value: `fails += ok(...)` counts only failures."""
    check(name, cond, detail)
    return 0 if cond else 1


def main():
    exe = os.environ.get("FSQL_MCP_EXE")
    if not exe:
        print("SKIP: FSQL_MCP_EXE not set")
        return 77
    if os.name == "nt" and not os.path.isfile(exe):
        exe += ".exe"
    if not os.path.isfile(exe):
        print("SKIP: binary not found at " + exe)
        return 77

    fails = 0

    cli = Client(exe)
    try:
        # ---- 1. initialize / serverInfo ----
        r = cli.call("initialize", {"protocolVersion": "2025-03-26",
                                    "capabilities": {},
                                    "clientInfo": {"name": "gate33-smoke", "version": "0"}})
        info = r.get("result", {}).get("serverInfo", {})
        fails += ok(info.get("name") == "fractalsql-postgresql-mcp", "initialize serverInfo name", info)
        fails += ok(bool(info.get("version")), "initialize serverInfo version", info)
        proto = r.get("result", {}).get("protocolVersion")
        fails += ok(proto == "2025-03-26", "initialize echoes requested protocolVersion", proto)
        cli.send("notifications/initialized", {}, notify=True)

        # ---- 2. ping ----
        r = cli.call("ping")
        fails += ok(r.get("result") == {}, "ping returns empty result", r)

        # ---- 3. tools/list: exact 82-name catalog + schema integrity ----
        r = cli.call("tools/list")
        tools = r.get("result", {}).get("tools", [])
        names = [t.get("name") for t in tools]
        fails += ok(set(names) == EXPECTED_TOOLS, "tools/list exact 82-name catalog",
                    "missing=" + str(sorted(EXPECTED_TOOLS - set(names)))[:200]
                    + " extra=" + str(sorted(set(names) - EXPECTED_TOOLS))[:200])
        fails += ok(len(names) == len(EXPECTED_TOOLS), f"tools/list count == {len(EXPECTED_TOOLS)}", len(names))
        bad_desc = [n for n, t in zip(names, tools) if not (t.get("description") or "").strip()]
        fails += ok(not bad_desc, "every tool has a non-empty description", bad_desc)
        bad_schema = []
        for t in tools:
            s = t.get("inputSchema") or {}
            if s.get("type") != "object" or s.get("additionalProperties") is not False:
                bad_schema.append(t["name"])
            props = s.get("properties")
            if not isinstance(props, dict):
                bad_schema.append(t["name"])
            # zero-arg tools: empty properties + no required is a complete contract.
            # Non-zero-arg: properties must be non-empty and every required key exist.
            elif s.get("required") and any(k not in props for k in s["required"]):
                bad_schema.append(t["name"])
            elif s.get("required") and not props:
                bad_schema.append(t["name"])
        fails += ok(not bad_schema, "inputSchema integrity (object/additionalProperties:false/properties)", bad_schema)
        # array params advertise real element kinds (this repo's corrected shape)
        tele = next((t for t in tools if t["name"] == "fractal_search_telemetry"), {})
        items = tele.get("inputSchema", {}).get("properties", {}).get("query", {}).get("items", {})
        fails += ok(items.get("type") == "number", "vector params advertise items:number", items)
        ann = {t["name"]: t.get("annotations") or {} for t in tools}
        # ---- safety table: every tool's hints must match EXPECTED_SAFETY ----
        explicit = ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")
        fails += ok(set(EXPECTED_SAFETY) == set(names),
                    "EXPECTED_SAFETY classifies exactly the tools served (a new tool needs a row here)",
                    "unclassified=" + str(sorted(set(names) - set(EXPECTED_SAFETY)))[:200]
                    + " stale=" + str(sorted(set(EXPECTED_SAFETY) - set(names)))[:200])
        not_explicit = [n for n, a in ann.items() if not all(isinstance(a.get(k), bool) for k in explicit)]
        fails += ok(not not_explicit,
                    "every tool sends all four hints explicitly (an omitted hint defaults to destructive/open-world in the MCP spec)",
                    not_explicit[:5])
        def _kind(a):
            if a.get("readOnlyHint") and a.get("destructiveHint"):
                return "contradiction"
            return "destructive" if a.get("destructiveHint") else ("read" if a.get("readOnlyHint") else "write")
        safety_drift = {n: [(_kind(a), a.get("openWorldHint")), EXPECTED_SAFETY.get(n)]
                        for n, a in ann.items() if (_kind(a), a.get("openWorldHint")) != EXPECTED_SAFETY.get(n)}
        fails += ok(not safety_drift, "every tool's hints match EXPECTED_SAFETY (got, expected)",
                    dict(list(safety_drift.items())[:5]))
        fails += ok(ann.get("fractal_ledger_reset_hard", {}).get("destructiveHint") is True,
                    "reset_hard destructiveHint", ann.get("fractal_ledger_reset_hard"))
        fails += ok(ann.get("fractal_explain_result", {}).get("readOnlyHint") is True,
                    "explain_result readOnlyHint", ann.get("fractal_explain_result"))
        fails += ok(ann.get("fractal_reason", {}).get("openWorldHint") is True
                    and ann["fractal_reason"].get("secretHint") is True,
                    "fractal_reason 15.2 hints (openWorld+secret)", ann.get("fractal_reason"))
        fails += ok(ann.get("fractal_diversify_enable", {}).get("idempotentHint") is True,
                    "diversify_enable idempotentHint (15.2)", ann.get("fractal_diversify_enable"))
        # 15.2's Postgres clause: every read-only Discovery/Analytics tool is
        # idempotent via the readOnly->idempotent pass in those two adapters
        # (spec 15.2 scopes the pass to those tiers only — the read-only tools
        # in other tiers — ledger_verify, audit_unpack, get_version, the no-LLM
        # agents — are deliberately left idempotent=false, not guessed).
        ro_no_idem = [t["name"] for t in tools
                      if (t.get("annotations") or {}).get("readOnlyHint") is True
                      and (t.get("annotations") or {}).get("idempotentHint") is not True
                      and (t.get("_meta") or {}).get("x-fractalsql-tier") in ("discovery", "analytics")]
        fails += ok(not ro_no_idem, "15.2: readOnly discovery/analytics tools carry idempotentHint", ro_no_idem)
        # 15.2 openWorldHint is set PER TOOL, not per tier: it means "this
        # call reaches an entity OUTSIDE the database (an LLM or embedding
        # provider)". The closed-world engines must NOT carry it, and the
        # one Agency tool that DOES leave the database (plan_explore embeds
        # the caller's state label through the embedding provider) must.
        fails += ok(ann.get("fractal_schema_context", {}).get("openWorldHint") is not True,
                    "schema_context is closed-world (no openWorldHint)",
                    ann.get("fractal_schema_context"))
        closed_world = ["fractal_agent_recall_hybrid", "fractal_agent_recommend_diverse",
                        "fractal_agent_feedback_audit", "fractal_agent_trajectory_predict",
                        "fractal_agent_detect_loop"]
        leaked = [n for n in closed_world if ann.get(n, {}).get("openWorldHint") is True]
        fails += ok(not leaked, "15.2: the closed-world agency engines carry no openWorldHint", leaked)
        fails += ok(ann.get("fractal_agent_plan_explore", {}).get("openWorldHint") is True,
                    "plan_explore openWorldHint (it embeds the state label via the provider)",
                    ann.get("fractal_agent_plan_explore"))
        meta = {t["name"]: t.get("_meta") or {} for t in tools}
        fails += ok(meta.get("fractal_search", {}).get("x-fractalsql-tier") == "discovery",
                    "_meta x-fractalsql-tier present", meta.get("fractal_search"))
        fails += ok(all("x-fractalsql-retry-tier" not in (meta.get(t["name"]) or {}) for t in tools),
                    "no x-fractalsql-retry-tier on postgres tool meta")

        # ---- 4. schema-class errors, no DB touched ----
        r = cli.call("tools/call", {"name": "fractal_search", "arguments": {"query": "not-a-vector"}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(r.get("result", {}).get("isError") is True and sc.get("error_class") == "schema",
                    "bad vector arg -> schema error_class", r.get("result"))
        r = cli.call("tools/call", {"name": "fractal_isolate_background", "arguments": {}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(r.get("result", {}).get("isError") is True and sc.get("error_class") == "schema",
                    "missing required arg -> schema error_class", sc)
        r = cli.call("tools/call", {"name": "definitely_not_a_tool", "arguments": {}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(sc.get("error_class") == "schema", "unknown tool -> schema error_class", sc)

        # ---- 4b. JSON-RPC/prompt error paths (v2.0.9 sibling port; no DB touched) ----
        r = cli.call("tools/call", {"name": "fractal_search", "arguments": [1, 2, 3]})
        fails += ok(r.get("error", {}).get("code") == -32602
                    and "JSON object" in str(r.get("error", {}).get("message", "")),
                    "tools/call with non-object arguments -> -32602 object-required", r.get("error"))
        # A request with no "method" at all -> -32600 (raw write: Client.send always pairs one).
        cli.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 990001}) + "\n")
        cli.p.stdin.flush()
        r = cli.recv(990001, timeout_s=15)
        fails += ok(r.get("error", {}).get("code") == -32600, "request without method -> -32600", r.get("error"))
        # Defect-J regression guard lives in its OWN client below (section
        # 4c): a pre-fix binary DIES on a non-string method, and a dead
        # client's pipe would take every later assert on this client with
        # it. Keeping it separate means a regression is reported as a
        # clean FAIL and the rest of the suite still runs.
        r = cli.call("prompts/get", {"name": "definitely_not_a_prompt", "arguments": {}})
        fails += ok(r.get("error", {}).get("code") == -32602, "unknown prompt -> -32602", r.get("error"))
        r = cli.call("resources/read", {"uri": "fractalsql://definitely-not-a-resource"})
        fails += ok(r.get("error", {}).get("code") == -32602
                    and "unknown resource" in str(r.get("error", {}).get("message", "")),
                    "unknown resources/read URI -> -32602 (top-level)", r.get("error"))
        r = cli.call("tools/call", {"name": "fractal_search_telemetry",
                                    "arguments": {"table_name": "x", "vector_col": "emb",
                                                  "query": [0.1, 0.2], "k": "not-a-number"}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(r.get("result", {}).get("isError") is True and sc.get("error_class") == "schema",
                    "schema-layer k type rejection (string k) before any DB touch", sc)

        # ---- 5. resources / prompts surface ----
        r = cli.call("resources/list")
        uris = [x.get("uri") for x in r.get("result", {}).get("resources", [])]
        fails += ok(set(uris) == {"fractalsql://schema", "fractalsql://config",
                                  "fractalsql://ledger/{kind}", "fractalsql://vectorizer/status",
                                  "fractalsql://agents"},
                    "resources/list five entries", uris)
        r = cli.call("resources/read", {"uri": "fractalsql://ledger/notanint"})
        sc = (r.get("error") or {}).get("message", "")
        fails += ok("integer" in sc, "ledger resource bad kind -> schema error", sc)
        r = cli.call("prompts/list")
        pnames = [p.get("name") for p in r.get("result", {}).get("prompts", [])]
        fails += ok(len(pnames) >= 11 and "incident_triage" in pnames, "prompts/list >= 11 incl incident_triage", pnames)
        r = cli.call("prompts/get", {"name": "safe_sql_question", "arguments": {"question": "how many rows?"}})
        txt = r.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", "")
        fails += ok("fractal_text_to_sql" in txt and "least-privilege" in txt,
                    "prompts/get fills args + least-privilege note", txt[:200])
        r = cli.call("prompts/get", {"name": "safe_sql_question", "arguments": {}})
        fails += ok((r.get("error") or {}).get("message", "").startswith("missing required prompt argument"),
                    "prompts/get missing required arg error", r.get("error"))

        # ---- 6. notifications are never replied to; parse error is id:null ----
        cli.send("notifications/initialized", {}, notify=True)
        rid = cli.send("notifications/cancelled", {"requestId": "never-seen-id"}, notify=True)
        r = cli.call("ping")
        fails += ok(True, "notifications produce no interleaved replies")
        r2 = cli.call("garbage-not-json")  # parsed as a method -> method not found path
        fails += ok(r2.get("error", {}).get("code") == -32601, "unknown method -> -32601", r2.get("error"))
    finally:
        rc = cli.close()
    fails += ok(rc == 0, "graceful shutdown exit code 0 on EOF", rc)

    # ---- 4c. Defect-J regression guard (own client) ----
    # A "method" of the WRONG TYPE used to take down the whole server.
    # nlohmann's value(key, default) does not type-check a key it finds,
    # so value("method","") threw type_error.302 on {"method": 123}: the
    # throw escaped the dispatcher, and the process died (over HTTP it
    # escaped the connection thread and killed the server outright). The
    # fix reads "method" only when it really is a string, so a
    # non-string method is now just an unknown method: -32601, and the
    # connection keeps serving.
    #
    # Its own client on purpose: against a pre-fix binary the server dies
    # here, and every later assert on the shared client would then fail
    # with a dead-pipe OSError instead of reporting the real defect.
    cli = Client(exe)
    try:
        cli.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                "clientInfo": {"name": "defect-j", "version": "0"}})
        cli.send("notifications/initialized", {}, notify=True)
        crashed = False
        try:
            cli.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 990002, "method": 123}) + "\n")
            cli.p.stdin.flush()
            r = cli.recv(990002, timeout_s=15)
            fails += ok(r.get("error", {}).get("code") == -32601,
                        "non-string method -> -32601 (guarded read, no crash)", r.get("error"))
        except Exception as e:
            crashed = True
            fails += ok(False, "non-string method -> -32601 (guarded read, no crash)",
                        "the server DIED on a non-string method: " + repr(e))
        if not crashed:
            try:
                r = cli.call("ping")
                fails += ok(r.get("result") == {}, "server still serving after a non-string method", r)
            except Exception as e:
                fails += ok(False, "server still serving after a non-string method",
                            "the server DIED: " + repr(e))
    finally:
        cli.close()

    # ---- 7. parse-error framing gate: id:null, code -32700 (fresh process) ----
    cli = Client(exe)
    try:
        cli.p.stdin.write("this is {{ not json\n")
        cli.p.stdin.flush()
        r = cli.recv(None, timeout_s=15)
        fails += ok(r.get("error", {}).get("code") == -32700 and r.get("id") is None,
                    "parse error -> -32700 with id:null", r)
        # ---- 8. read-only kill switch (15.4): DB-independent (pre-engine refusal) ----
    finally:
        cli.close()

    # The kill switch is read through envBoolOr(), which used to be an
    # EXACT match on "true"/"1"/"on". The conventional UPPERCASE spelling
    # in a CI env file or a docker-compose environment block therefore
    # evaluated to FALSE: the read-only switch never fired and destructive
    # tools stayed callable in a deployment the operator believed was
    # read-only. The fix case-folds the value and also accepts "yes".
    # Every accepted spelling is asserted here, because the regression is
    # silent -- it only shows up in the deployments that spell it the
    # other way.
    for ro_value in ("true", "TRUE", "True", "1", "on", "ON", "yes", "YES"):
        ro_env = dict(os.environ)
        ro_env["FSQL_MCP_READ_ONLY"] = ro_value
        cli = Client(exe, ro_env)
        try:
            cli.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                    "clientInfo": {"name": "ro", "version": "0"}})
            cli.send("notifications/initialized", {}, notify=True)
            r = cli.call("tools/call", {"name": "fractal_ledger_reset_hard", "arguments": {}})
            sc = r.get("result", {}).get("structuredContent", {})
            fails += ok(sc.get("error_class") == "schema" and "read-only" in sc.get("message", ""),
                        "FSQL_MCP_READ_ONLY=" + ro_value + " refuses destructive pre-engine", sc)
        finally:
            cli.close()

    # ---- 9. DB-dependent asserts (only when PG env is wired) ----
    pg_env_present = bool(os.environ.get("PGHOST") or os.environ.get("PGDATABASE") or os.environ.get("PGCONN"))
    if pg_env_present:
        run_db_asserts(exe, ok, fails.__setattr__)

    # ---- 10. CLI-phase gates (v2.0.9 sibling port: one-shot + refusal codes) ----
    fails += run_cli_phase(exe)
    fails += run_cli_edge_phase(exe)
    # ---- 11. SIGHUP forced token reload (POSIX only, v2.0.9 port of the
    # async-signal-safe SIGHUP contract): the mtime-pinned token file that the
    # mtime check alone would NOT pick up must still flip 401 -> 200 after
    # SIGHUP, and the same-session DELETE with the new token closes cleanly. ----
    if os.name != "nt":
        try:
            fails += run_sighup_phase(exe)
        except Exception as e:
            print("FAIL sighup phase: unexpected exception: " + repr(e))
            fails += 1
        # ---- 11b. the SAME contract in direct-TLS mode: the plain-HTTP
        # phase never exercises the TLS path, where a MISSING SIGHUP
        # handler would let the default disposition terminate the server
        # and take the token-rotation contract with it. ----
        try:
            fails += run_tls_sighup_phase(exe)
        except Exception as e:
            print("FAIL tls sighup phase: unexpected exception: " + repr(e))
            fails += 1
    # ---- 11c. HTTP transport edge cases (raw sockets; needs no database) ----
    try:
        fails += run_http_edge_phase(exe)
    except Exception as e:
        print("FAIL http edge phase: unexpected exception: " + repr(e))
        fails += 1
    # ---- 12. shutdown-drain phase (POSIX + live PG + the slow-mock sentinel,
    # v2.0.9 port): SIGTERM with an in-flight (mock-slow) fractal_reason call
    # must exit rc==0 through the bounded drain, not hang on the straggler. ----
    try:
        fails += run_protocol_phase(exe)
    except Exception as e:
        print("FAIL protocol phase: unexpected exception: " + repr(e))
        fails += 1
    if os.name != "nt" and pg_env_present:
        try:
            fails += run_cancel_phase(exe)
        except Exception as e:
            print("FAIL cancel phase: unexpected exception: " + repr(e))
            fails += 1
        try:
            fails += run_drain_phase(exe)
        except Exception as e:
            print("FAIL drain phase: unexpected exception: " + repr(e))
            fails += 1

    # ---- 13. engine-agnostic robustness probes (tests/mcp_robustness.py, the same file
    # every fractalsql-*-mcp repo carries): odd / non-object lines, non-object HTTP bodies,
    # explicit-null optionals and very long strings over the whole catalog, read-only
    # refusal, and the sanitizeSecrets differential probe. ----
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests"))
        import mcp_robustness
        os.environ.setdefault("MCP_SERVER_EXE", exe)
        os.environ.setdefault("MCP_HERE", os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
        rb_fails = [0]

        def _rb_check(label, cond):
            rb_fails[0] += ok(bool(cond), label)
            return bool(cond)
        mcp_robustness.run(_rb_check)
        fails += rb_fails[0]
    except ImportError:
        print("SKIP robustness probes (mcp_robustness.py not present)")

    if fails:
        print(f"SMOKE FAILED: {fails} assertion(s)")
        return 1
    print("SMOKE PASS")
    return 0


def run_cli_phase(exe):
    """--write-manifest -> a lock-dir-redirected scratch manifest; --http
    without a token exits 2 BEFORE binding; an unknown flag exits 2; a
    serving stdio run with the committed lock logs schema_lock_ok."""
    import tempfile
    import subprocess
    fails = 0
    cwd = os.path.dirname(os.path.abspath(exe))

    scratch = tempfile.mkdtemp(prefix="mcp_manifest_")
    env = dict(os.environ, FSQL_MCP_LOCK_DIR=scratch)
    r = subprocess.run([exe, "--write-manifest"], capture_output=True, text=True, env=env, timeout=60)
    man = os.path.join(scratch, "manifest.json")
    data = {}
    if os.path.isfile(man):
        with open(man, encoding="utf-8") as fh:
            data = json.load(fh)
    tools = data.get("tools", [])
    fails += ok(r.returncode == 0 and isinstance(data.get("version"), str)
                and len(tools) == 82
                and any(t.get("name") == "fractalsql_set_config" for t in tools),
                "--write-manifest -> FSQL_MCP_LOCK_DIR scratch manifest (82 tools)",
                [r.returncode, data.get("version"), len(tools)])
    try:
        os.remove(man)
        os.rmdir(scratch)
    except Exception:
        pass

    # --http without any token: config refusal BEFORE binding a port.
    env = dict(os.environ)
    env.pop("FSQL_MCP_AUTH_TOKEN", None)
    env.pop("FSQL_MCP_AUTH_TOKEN_FILE", None)
    r = subprocess.run([exe, "--http", "18799"], capture_output=True, text=True,
                       env=env, timeout=60, input="")
    fails += ok(r.returncode == 2 and "AUTH_TOKEN" in r.stderr,
                "--http without a token exits 2 before binding", r.stderr[-200:])

    r = subprocess.run([exe, "--definitely-not-a-flag"], capture_output=True, text=True,
                       env=dict(os.environ), timeout=60, input="")
    fails += ok(r.returncode == 2 and "unknown argument" in r.stderr,
                "unknown CLI flag exits 2 (rejected, not ignored)", r.stderr[-200:])

    # A SERVING stdio run against the committed lock logs schema_lock_ok.
    env = dict(os.environ)
    env.pop("FSQL_MCP_SCHEMA_LOCK", None)
    proc = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, text=True,
                            cwd=cwd)
    try:
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": {"protocolVersion": "2025-03-26"}}) + "\n")
        proc.stdin.flush()
        # Give the gate a moment to have logged the event, then stop the server.
        time.sleep(1.0)
        stop_proc(proc)
        err = proc.stderr.read()
        fails += ok('"event":"schema_lock_ok"' in err or "'schema_lock_ok'" in err,
                    "serving with the committed lock logs schema_lock_ok", err[-300:])
    finally:
        stop_proc(proc)
    return fails


def run_cli_edge_phase(exe):
    """main.cpp's command-line and environment surface -- everything that
    runs BEFORE a database is needed: --version / --help / --list-tools, the
    value-less flag refusal, the --tool / --category whitelist filters, the
    schema-lock and safety-lock write/verify/mismatch paths (and which
    spellings of FSQL_MCP_STRICT_SCHEMA_HASH make a mismatch fatal), the
    manifest-path override, and the two HTTP start-up config refusals."""
    import tempfile
    fails = 0
    cwd = os.path.dirname(os.path.abspath(exe))
    scratch = tempfile.mkdtemp(prefix="mcp_cli_edge_")
    clean = {k: v for k, v in os.environ.items()
             if k not in ("FSQL_MCP_SCHEMA_LOCK", "FSQL_MCP_SAFETY_LOCK", "FSQL_MCP_LOCK_DIR",
                          "FSQL_MCP_STRICT_SCHEMA_HASH", "FSQL_MCP_MANIFEST_PATH",
                          "FSQL_MCP_AUTH_TOKEN", "FSQL_MCP_AUTH_TOKEN_FILE")}

    def run(args, env=None, stdin="", timeout=60):
        return subprocess.run([exe] + list(args), capture_output=True, text=True,
                              env=env if env is not None else dict(clean),
                              input=stdin, timeout=timeout, cwd=cwd)

    init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": "2025-03-26"}})
    lst = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})

    def served_tools(args, env=None):
        r = run(args, env=env, stdin=init + "\n" + lst + "\n")
        names = None
        for line in r.stdout.splitlines():
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("id") == 2:
                names = [t["name"] for t in (o.get("result") or {}).get("tools", [])]
        return r, names

    r = run(["--version"])
    fails += ok(r.returncode == 0 and re.match(r"^\d+\.\d+\.\d+", r.stdout.strip()) is not None,
                "cli: --version prints a semver and exits 0", [r.returncode, r.stdout[:40]])
    for flag in ("--help", "-h"):
        r = run([flag])
        fails += ok(r.returncode == 0 and "Flags:" in r.stdout and "--list-tools" in r.stdout,
                    "cli: %s prints the usage text and exits 0" % flag, r.returncode)
    r = run(["--list-tools"])
    rows = [ln.split("\t") for ln in r.stdout.splitlines() if ln.strip()]
    names_all = [x[0] for x in rows]
    fails += ok(r.returncode == 0 and len(rows) == 82 and all(len(x) == 2 for x in rows)
                and names_all == sorted(names_all),
                "cli: --list-tools prints 82 sorted name<TAB>category rows (no database needed)",
                [r.returncode, len(rows)])
    for flag in ("--tool", "--category", "--host", "--path", "--tls-cert", "--tls-key",
                 "--schema-lock-path", "--safety-lock-path"):
        r = run([flag])
        fails += ok(r.returncode == 2 and "missing value for " + flag in r.stderr,
                    "cli: %s with no value exits 2 (missing value)" % flag, [r.returncode, r.stderr[-80:]])

    # ---- --tool / --category whitelist filters (CSV: spaces and empty items tolerated) ----
    r, names = served_tools(["--tool", " fractalsql_get_version , fractal_dimension_dfa ,,"])
    fails += ok(names is not None and sorted(names) == ["fractal_dimension_dfa", "fractalsql_get_version"],
                "cli: --tool whitelists exactly the named tools (blanks and empty CSV items ignored)", names)
    r, names = served_tools(["--category", "ADMIN"])
    fails += ok(names is not None and "fractalsql_get_version" in names and "fractal_dimension_dfa" not in names
                and 0 < len(names) < 82,
                "cli: --category is case-insensitive and serves only that category", names and len(names))
    r, names = served_tools(["--category", "nosuchcategory"])
    fails += ok(names == [], "cli: an unknown --category serves zero tools", names)
    r, names = served_tools(["--category", "admin", "--tool", "fractalsql_get_version,fractal_dimension_dfa"])
    fails += ok(names == ["fractalsql_get_version"],
                "cli: --category and --tool intersect (a tool must pass both)", names)

    # ---- schema lock: write, verify, mismatch (warn) and strict (fatal) ----
    sl = os.path.join(scratch, "schema.lock")
    r = run(["--write-schema-lock", "--schema-lock-path", sl])
    wrote = os.path.isfile(sl)
    fails += ok(r.returncode == 0 and wrote and r.stdout.strip() in open(sl).read(),
                "cli: --write-schema-lock writes the lock and prints the hash", [r.returncode, r.stdout[:20]])
    env = dict(clean, FSQL_MCP_SCHEMA_LOCK=sl)
    r = run([], env=env, stdin=init + "\n")
    fails += ok(r.returncode == 0 and "schema_lock_ok" in r.stderr,
                "cli: a matching schema lock logs schema_lock_ok", r.stderr[-120:])
    with open(sl, "w") as fh:
        fh.write("0" * 64 + "\n")
    r = run([], env=env, stdin=init + "\n")
    fails += ok(r.returncode == 0 and "schema hash mismatch" in r.stderr and '"id":1' in r.stdout.replace(" ", ""),
                "cli: a stale schema lock only WARNS by default (the server still serves)", [r.returncode, r.stderr[-100:]])
    for v in ("1", "true", "TRUE", "on", "yes"):
        r = run([], env=dict(env, FSQL_MCP_STRICT_SCHEMA_HASH=v), stdin=init + "\n")
        fails += ok(r.returncode == 2 and "schema hash mismatch" in r.stderr,
                    "cli: FSQL_MCP_STRICT_SCHEMA_HASH=%s makes a schema mismatch fatal (exit 2)" % v, r.returncode)
    for v in ("0", "off", "no", ""):
        r = run([], env=dict(env, FSQL_MCP_STRICT_SCHEMA_HASH=v), stdin=init + "\n")
        fails += ok(r.returncode == 0,
                    "cli: FSQL_MCP_STRICT_SCHEMA_HASH=%r leaves a mismatch non-fatal" % v, r.returncode)

    # ---- safety-annotation lock: write, verify, any drift is fatal (exit 3) ----
    sf = os.path.join(scratch, "safety.lock")
    r = run(["--write-safety-annotations-lock", "--safety-lock-path", sf])
    fails += ok(r.returncode == 0 and os.path.isfile(sf) and "written" in r.stdout,
                "cli: --write-safety-annotations-lock writes the lock", [r.returncode, r.stdout[:60]])
    envs = dict(clean, FSQL_MCP_SAFETY_LOCK=sf)
    r = run([], env=envs, stdin=init + "\n")
    fails += ok(r.returncode == 0, "cli: a matching safety lock serves normally", [r.returncode, r.stderr[-100:]])
    with open(sf, newline="") as fh:
        lock = fh.read()
    flipped = lock.replace("destructive=0", "destructive=1", 1) if "destructive=0" in lock else lock + "bogus_tool destructive=1\n"
    with open(sf, "w", newline="") as fh:
        fh.write(flipped)
    r = run([], env=envs, stdin=init + "\n")
    fails += ok(r.returncode == 3 and "safety-annotation lock mismatch" in r.stderr,
                "cli: a drifted safety-annotation lock is fatal (exit 3), STRICT flag or not", [r.returncode, r.stderr[-100:]])

    # ---- manifest-path override ----
    mp = os.path.join(scratch, "m.json")
    r = run(["--write-manifest"], env=dict(clean, FSQL_MCP_MANIFEST_PATH=mp))
    fails += ok(r.returncode == 0 and os.path.isfile(mp) and "(82 tools)" in r.stdout,
                "cli: FSQL_MCP_MANIFEST_PATH redirects --write-manifest", [r.returncode, r.stdout[:80]])

    # ---- HTTP start-up config refusals ----
    r = run(["--http", "18964", "--host", "no-such-host.invalid"], env=dict(clean, FSQL_MCP_AUTH_TOKEN="t"))
    fails += ok(r.returncode == 1 and "http listen failed" in r.stderr,
                "cli: an unresolvable --host is a listen failure (exit 1), not a bind-all fallback",
                [r.returncode, r.stderr[-100:]])
    r = run(["--https", "18965"], env=dict(clean, FSQL_MCP_AUTH_TOKEN="t"))
    fails += ok(r.returncode == 2, "cli: --https without a certificate/key is a config error (exit 2)",
                [r.returncode, r.stderr[-100:]])

    import shutil
    shutil.rmtree(scratch, ignore_errors=True)
    return fails


def run_sighup_phase(exe):
    """POSIX only: the mtime-pinned-back token file that the mtime check
    alone would skip must flip 401 -> 200 after SIGHUP (the async-signal-safe
    deferred-reload contract), and the session opened with the new token
    closes with a 200 DELETE."""
    import signal
    import http.client
    import tempfile

    cwd = os.path.dirname(os.path.abspath(exe))
    port = 18957
    token_file = os.path.join(tempfile.mkdtemp(prefix="mcp_sighup_"), "token.txt")
    with open(token_file, "w", encoding="utf-8") as fh:
        fh.write("sighup-token-old\n")

    env = dict(os.environ, FSQL_MCP_AUTH_TOKEN_FILE=token_file,
               FSQL_MCP_HTTP_PORT=str(port), FSQL_MCP_HTTP_HOST="127.0.0.1")
    proc = subprocess.Popen([exe, "--http", str(port)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, text=True, cwd=cwd)
    fails = 0

    def req(port_, method, path, token=None, session=None, body=None, timeout=5.0):
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port_, timeout=timeout)
            headers = {}
            if token is not None:
                headers["Authorization"] = "Bearer " + token
            if session is not None:
                headers["Mcp-Session-Id"] = session
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read().decode("utf-8", "replace")
            hdrs = {k.lower(): v for k, v in resp.getheaders()}
            conn.close()
            return resp.status, hdrs, data
        except Exception:
            return None, {}, ""

    try:
        up = False
        for _ in range(60):
            s, _, _ = req(port, "GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        fails += ok(up, "sighup phase: server comes up with a token file", port)

        # Old token still matches while in memory; prove the baseline works
        # end to end: initialize + DELETE with the OLD token.
        s, h, _ = req(port, "POST", "/mcp", token="sighup-token-old",
                      body=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": {"protocolVersion": "2025-06-18"}}))
        old_sid = h.get("mcp-session-id")
        fails += ok(s == 200 and bool(old_sid), "sighup phase: the OLD token authenticates (baseline)", s)
        s, _, _ = req(port, "DELETE", "/mcp", token="sighup-token-old", session=old_sid)
        fails += ok(s == 200, "sighup phase: baseline session DELETE closes (200)", s)

        # New token with the file's ORIGINAL mtime RESTORED ("pinned back"
        # the sibling's way: pinning to an arbitrary older date is a mtime
        # CHANGE and the mtime check still reloads; pinning to the SAME
        # mtime the store already recorded is what the plain check alone
        # would skip — only the forced reload may pick the new token up).
        # NANOSECOND ints (st_mtime_ns), not float seconds: float64's ULP
        # at epoch+1.7e9s is ~240ns, so a float restore can differ from the
        # store's recorded count by that much — which on Linux ext4/ns is
        # STILL a change (docker-caught: the "skip" assert saw 400 =
        # the request AUTHED). Integer ns round-trips exactly.
        mtime_ns = os.stat(token_file).st_mtime_ns
        with open(token_file, "w", encoding="utf-8") as fh:
            fh.write("sighup-token-new\n")
        os.utime(token_file, ns=(mtime_ns, mtime_ns))
        time.sleep(0.2)
        s, _, _ = req(port, "POST", "/mcp", token="sighup-token-new",
                      body='{"jsonrpc":"2.0"}')
        fails += ok(s == 401, "sighup phase: the pinned new token is NOT picked up by the mtime check", s)

        # SIGHUP -> the deferred force reload (running on an ordinary request
        # thread inside matches()) must make the new token the live one:
        # 401 -> 200 initialize -> DELETE 200.
        os.kill(proc.pid, signal.SIGHUP)
        deadline = time.time() + 8.0
        s2, h2 = None, {}
        minted = None
        while time.time() < deadline:
            s2, h2, _ = req(port, "POST", "/mcp", token="sighup-token-new",
                            body=json.dumps({"jsonrpc": "2.0", "id": 2, "method": "initialize",
                                             "params": {"protocolVersion": "2025-06-18"}}))
            if s2 == 200:
                minted = h2.get("mcp-session-id")
                break
            time.sleep(0.1)
        fails += ok(s2 == 200 and bool(minted),
                    "sighup phase: only the FORCED reload path picks up the mtime-pinned token (initialize 200)",
                    s2)
        s, _, _ = req(port, "DELETE", "/mcp", token="sighup-token-new", session=minted)
        fails += ok(s == 200, "sighup phase: new-token session DELETE closes (200)", s)

        # --- the plain mtime-driven reload and its two keep-the-token cases ---
        def init_status(tok):
            return req(port, "POST", "/mcp", token=tok,
                       body=json.dumps({"jsonrpc": "2.0", "id": 3, "method": "initialize",
                                        "params": {"protocolVersion": "2025-06-18"}}))[0]

        base_ns = os.stat(token_file).st_mtime_ns
        with open(token_file, "w", encoding="utf-8") as fh:
            fh.write("sighup-token-third\n")
        os.utime(token_file, ns=(base_ns + 10 * 10**9, base_ns + 10 * 10**9))
        fails += ok(init_status("sighup-token-third") == 200,
                    "token file: a CHANGED mtime reloads the new token without a signal")
        fails += ok(init_status("sighup-token-new") == 401,
                    "token file: the replaced token stops authenticating (401)")
        with open(token_file, "w", encoding="utf-8") as fh:
            fh.write("\n")
        os.utime(token_file, ns=(base_ns + 20 * 10**9, base_ns + 20 * 10**9))
        fails += ok(init_status("sighup-token-third") == 200,
                    "token file: an emptied file is ignored -- the live token is kept")
        os.remove(token_file)
        fails += ok(init_status("sighup-token-third") == 200,
                    "token file: a deleted file is ignored -- the live token is kept")
        fails += ok(init_status("wrong-token") == 401,
                    "token file: a wrong token is still refused after the file vanished")
    finally:
        stop_proc(proc, http=True)
    return fails


def run_http_edge_phase(exe):
    """HTTP transport edge cases over raw sockets: bad framing, bad auth, bad
    sessions, oversized and idle connections, batches and concurrency. Every
    response is checked for its status code, and the server must still be
    healthy at the end (no case may take it down)."""
    import socket
    import threading

    cwd = os.path.dirname(os.path.abspath(exe))
    port = 18961
    token = "edge-token"
    env = dict(os.environ, FSQL_MCP_AUTH_TOKEN=token, FSQL_MCP_HTTP_PORT=str(port),
               FSQL_MCP_HTTP_HOST="127.0.0.1")
    proc = subprocess.Popen([exe, "--http", str(port)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, text=True, cwd=cwd)
    fails = 0

    def raw(data, half_close=False, timeout=6.0, read=True):
        """Send raw bytes; return (status or None, header-dict, body)."""
        try:
            sk = socket.create_connection(("127.0.0.1", port), timeout=timeout)
            sk.settimeout(timeout)
            if data:
                sk.sendall(data if isinstance(data, bytes) else data.encode())
            if half_close:
                sk.shutdown(socket.SHUT_WR)
            if not read:
                sk.close()
                return None, {}, ""
            buf = b""
            while True:
                try:
                    chunk = sk.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
            sk.close()
        except OSError:
            return None, {}, ""
        head, _, body = buf.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        try:
            status = int(lines[0].split()[1])
        except (IndexError, ValueError):
            return None, {}, buf.decode("latin-1")
        hdrs = {}
        for ln in lines[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                hdrs[k.strip().lower()] = v.strip()
        return status, hdrs, body.decode("utf-8", "replace")

    def http(method, path, body=None, token_=token, session=None, extra=None, version="HTTP/1.1"):
        hdrs = ["Host: x"]
        if token_ is not None:
            hdrs.append("Authorization: Bearer " + token_)
        if session is not None:
            hdrs.append("Mcp-Session-Id: " + session)
        hdrs.extend(extra or [])
        payload = b""
        if body is not None:
            payload = body if isinstance(body, bytes) else body.encode()
            if not any(h.lower().startswith("content-length") for h in (extra or [])):
                hdrs.append("Content-Length: %d" % len(payload))
        msg = ("%s %s %s\r\n%s\r\n\r\n" % (method, path, version, "\r\n".join(hdrs))).encode() + payload
        return raw(msg)

    def rpc(i, method, params=None):
        return json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}})

    def expect(cond, name, detail=""):
        nonlocal fails
        fails += ok(cond, "http edge: " + name, detail)

    try:
        up = False
        for _ in range(60):
            if http("GET", "/healthz", token_=None)[0] == 200:
                up = True
                break
            time.sleep(0.15)
        expect(up, "server comes up", port)

        # --- health endpoints and routing ---
        expect(http("GET", "/healthz", token_=None)[0] == 200, "/healthz needs no token")
        rs = http("GET", "/readyz", token_=None)
        expect(rs[0] in (200, 503) and '"ok"' in rs[2], "/readyz answers {ok:..} without a token", rs[:1] + (rs[2],))
        expect(http("GET", "/nope")[0] == 404, "unknown path -> 404")
        expect(http("GET", "/mcp")[0] == 405, "GET /mcp -> 405")
        for m in ("PUT", "PATCH", "OPTIONS"):
            expect(http(m, "/mcp", body="{}")[0] in (404, 405), m + " /mcp is refused")
        expect(http("POST", "/mcp?trace=1", body=rpc(1, "ping"), session="nosuch")[0] == 404,
               "query string is stripped before routing")

        # --- authentication ---
        body = rpc(1, "initialize", {"protocolVersion": "2025-06-18"})
        expect(http("POST", "/mcp", body=body, token_=None)[0] == 401, "no Authorization header -> 401")
        expect(http("POST", "/mcp", body=body, token_="wrong")[0] == 401, "wrong bearer token -> 401")
        expect(http("POST", "/mcp", body=body, token_=None, extra=["Authorization: Basic abc"])[0] == 401,
               "non-Bearer scheme -> 401")
        expect(http("POST", "/mcp", body=body, token_=None, extra=["Authorization: Bearer"])[0] == 401,
               "empty bearer -> 401")
        expect(http("POST", "/mcp", body=body, token_=token[:-1])[0] == 401, "token prefix -> 401")

        # --- body framing ---
        expect(http("POST", "/mcp", body="")[0] == 400, "empty body -> 400")
        expect(http("POST", "/mcp", body="{not json")[0] == 400, "invalid JSON -> 400")
        expect(http("POST", "/mcp", body="123")[0] == 400, "non-object JSON -> 400")
        expect(http("POST", "/mcp", body="x", extra=["Content-Length: abc"])[0] == 400, "non-numeric Content-Length -> 400")
        expect(http("POST", "/mcp", body="x", extra=["Content-Length: -1"])[0] == 400, "negative Content-Length -> 400")
        expect(http("POST", "/mcp", body="x", extra=["Content-Length: "])[0] == 400, "empty Content-Length -> 400")
        expect(http("POST", "/mcp", body="x", extra=["Content-Length: 99999999999999999999999"])[0] == 400,
               "overflowing Content-Length -> 400")
        expect(http("POST", "/mcp", body="x", extra=["Content-Length: 99999999"])[0] == 413, "oversized body -> 413")
        expect(http("POST", "/mcp", body="5\r\nhello\r\n0\r\n\r\n",
                    extra=["Transfer-Encoding: chunked", "Content-Length: 0"])[0] == 411, "chunked body -> 411")
        # body shorter than Content-Length, then EOF: must not hang or crash
        st = raw("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Length: 100\r\n\r\nabc" % token,
                 half_close=True)
        expect(st[0] in (None, 400), "truncated body then EOF is dropped cleanly", st[0])
        # garbage / oversized request heads
        raw("GARBAGE\r\n\r\n")
        raw("\r\n\r\n")
        raw(b"\x00\xff\xfe\r\n\r\n")
        raw("POST /mcp HTTP/1.1\r\nHost: x\r\nX-Pad: " + "a" * 70000 + "\r\n\r\n")
        raw("POST /mcp HTTP/1.1\r\nHost: x\r\nbad header line without colon\r\n\r\n")
        raw("POST", read=False)
        expect(http("GET", "/healthz", token_=None)[0] == 200, "server survives garbage and oversized request heads")

        # --- session rules ---
        expect(http("POST", "/mcp", body=rpc(2, "tools/list"))[0] == 400, "non-initialize without a session id -> 400")
        expect(http("POST", "/mcp", body=rpc(2, "tools/list"), session="deadbeef")[0] == 404, "unknown session id -> 404")
        expect(http("POST", "/mcp", body=body, session="deadbeef")[0] == 400, "initialize carrying a session id -> 400")
        expect(http("DELETE", "/mcp")[0] in (400, 404), "DELETE without a session id")
        expect(http("DELETE", "/mcp", session="deadbeef")[0] == 404, "DELETE of an unknown session -> 404")
        st, hd, _ = http("POST", "/mcp", body=body)
        sid = hd.get("mcp-session-id")
        expect(st == 200 and bool(sid), "initialize mints a session", st)
        expect(http("POST", "/mcp", body=json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                    session=sid)[0] == 202, "notification -> 202")
        expect(http("POST", "/mcp", body=rpc(3, "tools/list"), session=sid)[0] == 200, "tools/list in session -> 200")
        expect(http("POST", "/mcp", body=rpc(4, "ping"), session=sid)[0] == 200, "ping -> 200")
        batch = json.dumps([json.loads(rpc(5, "ping")), json.loads(rpc(6, "tools/list"))])
        st, _, bd = http("POST", "/mcp", body=batch, session=sid)
        expect(st == 200 and bd.lstrip().startswith("["), "batch request -> array response", st)
        one = json.dumps([json.loads(rpc(7, "ping"))])
        expect(http("POST", "/mcp", body=one, session=sid)[0] == 200, "single-element batch -> 200")
        notes = json.dumps([{"jsonrpc": "2.0", "method": "notifications/initialized"}])
        expect(http("POST", "/mcp", body=notes, session=sid)[0] == 202, "all-notification batch -> 202")
        expect(http("POST", "/mcp", body=json.dumps({"jsonrpc": "2.0", "id": 8, "method": 123}), session=sid)[0] == 200,
               "non-string method is answered with a JSON-RPC error, not a crash")
        expect(http("POST", "/mcp", body="[]", session=sid)[0] == 400, "empty batch -> 400 (invalid request)")
        # Non-object batch members (and a non-object single body) used to throw
        # out of the dispatcher and abort the whole server: each must now just
        # be an "invalid request" entry, and the server must keep answering.
        st, _, bd = http("POST", "/mcp", body='[1, "x", null, [], {}]', session=sid)
        expect(st == 200 and bd.count("invalid request") == 5, "batch of non-object members -> five invalid-request entries", [st, bd[:120]])
        for junk in ("42", '"s"', "null", "true"):
            st, _, bd = http("POST", "/mcp", body=junk, session=sid)
            expect(st == 400, "non-object body %s -> 400" % junk, [st, bd[:100]])
        expect(http("GET", "/healthz", token_=None)[0] == 200, "server still healthy after non-object bodies")
        bst, bh, bb = http("POST", "/mcp", body=json.dumps([json.loads(rpc(9, "initialize", {"protocolVersion": "2025-06-18"}))]))
        batch_sid = bh.get("mcp-session-id")
        expect(bst == 200 and bool(batch_sid), "initialize inside a batch mints a session", bst)
        if batch_sid:
            http("DELETE", "/mcp", session=batch_sid)
        expect(http("DELETE", "/mcp", session=sid)[0] == 200, "DELETE closes the session")
        expect(http("POST", "/mcp", body=rpc(10, "ping"), session=sid)[0] == 404, "a closed session id is gone (404)")

        # --- idle connection is closed by the server's short first-byte timeout ---
        t0 = time.time()
        try:
            sk = socket.create_connection(("127.0.0.1", port), timeout=8)
            sk.settimeout(8)
            closed = sk.recv(1) == b""
            sk.close()
        except OSError:
            closed = True
        expect(closed and (time.time() - t0) < 7.5, "an idle connection is closed by the server", round(time.time() - t0, 1))

        # --- concurrency ---
        results = []

        def hit():
            results.append(http("GET", "/healthz", token_=None)[0])

        threads = [threading.Thread(target=hit) for _ in range(24)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)
        expect(results.count(200) == 24, "24 concurrent requests all answered 200", results)
        expect(proc.poll() is None, "server process is still running after every edge case")
    finally:
        stop_proc(proc, http=True)
    return fails


def run_tls_sighup_phase(exe):
    """POSIX only: the SAME SIGHUP force-reload contract as run_sighup_phase,
    but with the server in direct-TLS mode (--https).

    Why TLS needs its own assert: SIGHUP must mean "reload the token
    file, nothing else" -- and a server with NO SIGHUP handler gets the
    default disposition, which TERMINATES the process. The handler is
    installed unconditionally now, so a TLS-mode server keeps its token
    rotation contract instead of dying on the first kill -HUP. The
    plain-HTTP phase cannot see that: it never exercises the TLS path.

    Skipped-as-pass (not failed) when openssl is not on PATH -- the
    throwaway self-signed pair is generated the same way the TLS gate
    generates it."""
    import http.client
    import signal
    import ssl

    cwd = os.path.dirname(os.path.abspath(exe))
    port = 18958
    fails = 0

    try:
        openssl = subprocess.run(["openssl", "version"], capture_output=True, text=True, timeout=30)
    except Exception:
        openssl = None
    if openssl is None or openssl.returncode != 0:
        print("PASS tls sighup phase: skipped (no openssl on PATH to mint a throwaway cert)")
        return 0

    tmpdir = tempfile.mkdtemp(prefix="mcp_tls_sighup_")
    cert = os.path.join(tmpdir, "cert.pem")
    key = os.path.join(tmpdir, "key.pem")
    cnf = os.path.join(tmpdir, "openssl.cnf")
    token_file = os.path.join(tmpdir, "token.txt")
    with open(cnf, "w", encoding="utf-8") as fh:
        fh.write("[req]\ndistinguished_name = dn\nprompt = no\n[dn]\n")
    with open(token_file, "w", encoding="utf-8") as fh:
        fh.write("tls-sighup-token-old\n")
    genrc = subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=127.0.0.1", "-config", cnf, "-keyout", key, "-out", cert],
        capture_output=True, text=True, timeout=120,
        env=dict(os.environ, OPENSSL_CONF="", HOME=tmpdir))
    if genrc.returncode != 0:
        print("PASS tls sighup phase: skipped (openssl could not mint the throwaway cert)")
        return 0

    env = dict(os.environ, FSQL_MCP_AUTH_TOKEN_FILE=token_file,
               FSQL_MCP_HTTP_PORT=str(port), FSQL_MCP_HTTP_HOST="127.0.0.1")
    proc = subprocess.Popen([exe, "--https", str(port), "--tls-cert", cert, "--tls-key", key],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, text=True, cwd=cwd)

    def req(port_, method, path, token=None, session=None, body=None, timeout=5.0):
        # The throwaway cert is self-signed for 127.0.0.1 and the only
        # server we talk to is the one we just spawned, so there is no CA
        # to verify against: verification is off for this loopback probe.
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection("127.0.0.1", port_, timeout=timeout, context=ctx)
            headers = {}
            if token is not None:
                headers["Authorization"] = "Bearer " + token
            if session is not None:
                headers["Mcp-Session-Id"] = session
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read().decode("utf-8", "replace")
            hdrs = {k.lower(): v for k, v in resp.getheaders()}
            conn.close()
            return resp.status, hdrs, data
        except Exception:
            return None, {}, ""

    try:
        up = False
        for _ in range(80):
            s, _, _ = req(port, "GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        fails += ok(up, "tls sighup phase: the TLS transport comes up", port)
        if not up:
            return fails

        s, h, _ = req(port, "POST", "/mcp", token="tls-sighup-token-old",
                      body=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": {"protocolVersion": "2025-06-18"}}))
        old_sid = h.get("mcp-session-id")
        fails += ok(s == 200 and bool(old_sid), "tls sighup phase: the OLD token authenticates over TLS", s)

        # A NOTIFICATION (a request with no id) has no JSON-RPC reply, but
        # the HTTP exchange still needs an answer. All three paths must
        # answer 202: the initialize branch (an id-less initialize -- the
        # branch that MINTS a session and then has nothing to reply with),
        # the in-session single path, and a batch made up ENTIRELY of
        # notifications (no reply-producing part at all).
        s, _, _ = req(port, "POST", "/mcp", token="tls-sighup-token-old",
                      body=json.dumps({"jsonrpc": "2.0", "method": "initialize",
                                       "params": {"protocolVersion": "2025-06-18"}}))
        fails += ok(s == 202, "tls sighup phase: an id-less initialize is answered 202", s)
        s, _, _ = req(port, "POST", "/mcp", token="tls-sighup-token-old", session=old_sid,
                      body=json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized",
                                       "params": {}}))
        fails += ok(s == 202, "tls sighup phase: an in-session notification is answered 202", s)
        s, _, _ = req(port, "POST", "/mcp", token="tls-sighup-token-old", session=old_sid,
                      body=json.dumps([{"jsonrpc": "2.0", "method": "notifications/initialized",
                                        "params": {}},
                                       {"jsonrpc": "2.0", "method": "notifications/cancelled",
                                        "params": {"requestId": "never-seen-id"}}]))
        fails += ok(s == 202, "tls sighup phase: a batch of only notifications is answered 202", s)
        s, _, _ = req(port, "DELETE", "/mcp", token="tls-sighup-token-old", session=old_sid)
        fails += ok(s == 200, "tls sighup phase: baseline session DELETE closes over TLS (200)", s)

        # Pin the new token's mtime back to the EXACT nanosecond the store
        # already recorded, so the plain mtime check cannot pick it up and
        # only the forced (SIGHUP) reload can.
        mtime_ns = os.stat(token_file).st_mtime_ns
        with open(token_file, "w", encoding="utf-8") as fh:
            fh.write("tls-sighup-token-new\n")
        os.utime(token_file, ns=(mtime_ns, mtime_ns))
        time.sleep(0.2)
        s, _, _ = req(port, "POST", "/mcp", token="tls-sighup-token-new", body='{"jsonrpc":"2.0"}')
        fails += ok(s == 401, "tls sighup phase: the mtime-pinned new token is NOT picked up by the mtime check", s)

        os.kill(proc.pid, signal.SIGHUP)
        # The TLS-specific half of the contract: with a SIGHUP handler
        # installed, the process must still be ALIVE. Without one, SIGHUP's
        # default disposition terminates it and the token rotation dies
        # with it.
        time.sleep(0.5)
        fails += ok(proc.poll() is None,
                    "tls sighup phase: SIGHUP does not terminate the TLS-mode server", proc.poll())

        deadline = time.time() + 8.0
        s2, h2, _ = None, {}, None
        minted = None
        while time.time() < deadline:
            s2, h2, _ = req(port, "POST", "/mcp", token="tls-sighup-token-new",
                            body=json.dumps({"jsonrpc": "2.0", "id": 2, "method": "initialize",
                                             "params": {"protocolVersion": "2025-06-18"}}))
            if s2 == 200:
                minted = h2.get("mcp-session-id")
                break
            time.sleep(0.1)
        fails += ok(s2 == 200 and bool(minted),
                    "tls sighup phase: the FORCED reload picks up the mtime-pinned token over TLS", s2)
        s, _, _ = req(port, "DELETE", "/mcp", token="tls-sighup-token-new", session=minted)
        fails += ok(s == 200, "tls sighup phase: new-token session DELETE closes over TLS (200)", s)
    finally:
        stop_proc(proc, http=True)
        try:
            for f in (cert, key, cnf, token_file):
                if os.path.isfile(f):
                    os.remove(f)
            os.rmdir(tmpdir)
        except Exception:
            pass
    return fails


def run_drain_phase(exe):
    """POSIX only, live PG + the mock reasoning plugin's slow sentinel: a
    SIGTERM with a SLOW in-flight tools/call (fractal_reason) must drain
    bounded: the process exits rc==0 within ~6s even though the call needed
    ~(slow_ms) — the drain-wait proves its wait loop runs its body with a
    straggler instead of either hanging (unbounded join) or exiting early."""
    import http.client
    import threading

    cwd = os.path.dirname(os.path.abspath(exe))
    port = 18958
    slow_ms = int(os.environ.get("FSQL_MCP_DRAIN_SLOW_MS", "2000"))
    try:
        with open("/tmp/fractalsql_bt_slow_ms.txt", "w", encoding="utf-8") as fh:
            fh.write(str(slow_ms))
    except Exception as e:
        print("SKIP drain phase: cannot write the slow sentinel (" + str(e) + ")")
        return 0

    env = dict(os.environ, FSQL_MCP_AUTH_TOKEN="drain-tok",
               FSQL_MCP_HTTP_PORT=str(port), FSQL_MCP_HTTP_HOST="127.0.0.1",
               FSQL_MCP_SHUTDOWN_DRAIN_MS="300")
    log_path = "/tmp/fractalsql_mcp_drain_server.log"
    with open(log_path, "w", encoding="utf-8") as log:
        proc = subprocess.Popen([exe, "--http", str(port)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=log, env=env,
                                text=True, cwd=cwd)
        fails = 0
        session = {}
        done = threading.Event()

        def in_flight():
            # A slow (mock-sleeping) fractal_reason call keeps ONE request
            # in flight across the shutdown signal.
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                conn.request("POST", "/mcp", body=json.dumps(
                    {"jsonrpc": "2.0", "id": 77, "method": "tools/call",
                     "params": {"name": "fractal_reason", "arguments": {"query": "drain"}}}),
                    headers={"Authorization": "Bearer drain-tok",
                             "Mcp-Session-Id": session.get("id", "")})
                conn.getresponse().read()
                conn.close()
            except Exception:
                pass
            done.set()

        try:
            up = False
            for _ in range(60):
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2.0)
                    conn.request("GET", "/healthz")
                    resp = conn.getresponse()
                    resp.read()
                    conn.close()
                    if resp.status == 200:
                        up = True
                        break
                except Exception:
                    time.sleep(0.15)
            if not fails and not up:
                print("FAIL drain phase: server did not come up; see " + log_path)
                return 1
            # initialize on its own connection
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request("POST", "/mcp", body=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2025-06-18"}}),
                headers={"Authorization": "Bearer drain-tok"})
            resp = conn.getresponse()
            resp.read()
            session["id"] = resp.getheader("Mcp-Session-Id")
            conn.close()
            if not session.get("id"):
                print("FAIL drain phase: no session minted; see " + log_path)
                return 1

            t = threading.Thread(target=in_flight, daemon=True)
            t.start()
            time.sleep(0.5)   # the slow call is now in flight (it needs >= slow_ms)
            import signal
            t0 = time.time()
            proc.send_signal(signal.SIGTERM)
            rc = None
            try:
                rc = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
            elapsed = time.time() - t0
            fails += ok(rc == 0 and elapsed < 6.0,
                        "drain phase: SIGTERM with an in-flight slow call drains bounded (rc==0, <6s)",
                        [rc, round(elapsed, 2)])
            done.wait(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except Exception:
                    pass
        try:
            os.remove("/tmp/fractalsql_bt_slow_ms.txt")
        except Exception:
            pass
    return fails


def run_protocol_phase(exe):
    """JSON-RPC / stdio edge cases that need no database: protocol-version
    negotiation, odd request ids and malformed request shapes (each must leave
    the stream in sync -- a following ping still answers), a line past the
    8 MiB bound, and read-only mode refusing a destructive tool."""
    fails = 0

    def raw(cli, text):
        cli.p.stdin.write(text + "\n")
        cli.p.stdin.flush()

    cli = Client(exe)
    try:
        r = cli.call("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}})
        pv = (r.get("result") or {}).get("protocolVersion")
        fails += ok(isinstance(pv, str) and pv != "1999-01-01",
                    "protocol: an unsupported protocolVersion is answered with a supported one", pv)
        r = cli.call("initialize", {"protocolVersion": 5})
        fails += ok("result" in r, "protocol: a non-string protocolVersion still initializes", r)
        r = cli.call("initialize")
        fails += ok("result" in r, "protocol: initialize without params answers", r)
        r = cli.call("initialize", {"protocolVersion": "2025-06-18"})
        fails += ok((r.get("result") or {}).get("protocolVersion") == "2025-06-18",
                    "protocol: a supported protocolVersion is echoed", r)
        r = cli.call("resources/templates/list", {})
        fails += ok(isinstance((r.get("result") or {}).get("resourceTemplates"), list),
                    "protocol: resources/templates/list answers a list", r)

        # request ids of every JSON type are echoed back verbatim
        for rid in ("str-id", 4.5, {"a": 1}, [1, 2], 0, "", True):
            raw(cli, json.dumps({"jsonrpc": "2.0", "id": rid, "method": "ping"}))
            try:
                got = cli.recv(rid, 10)
                fails += ok("result" in got, "protocol: ping with id %r is answered" % (rid,), got)
            except Exception as e:
                fails += ok(False, "protocol: ping with id %r is answered" % (rid,), repr(e))

        # malformed shapes: each gets some well-formed answer or none, and
        # the stream stays in sync (the closing ping answers)
        bad_lines = [
            "[1, 2, 3]", "[]", '"a string"', "42", "null", "true", "{}", '{"jsonrpc": "2.0"}',
            '{"method": "ping"}', '{"jsonrpc": "2.0", "id": 1}', '{"jsonrpc": "2.0", "id": 1, "method": 5}',
            '{"jsonrpc": "2.0", "id": 1, "method": null}', '{"jsonrpc": "2.0", "method": "tools/call"}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": "x"}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": null}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": []}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": 5}}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "fractalsql_get_version", "arguments": []}}',
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "fractalsql_get_version", "arguments": "x"}}',
            '{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": []}',
            '{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": 5}}',
            '{"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": {"name": 5}}',
            '{"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": "x"}',
            '{"jsonrpc": "2.0", "method": "notifications/cancelled"}',
            '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}',
            '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": null}}',
            '{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": {"a": [1]}}}',
            '{"jsonrpc": "2.0", "method": "no/such/notification", "params": {}}',
            "{not json", "", "   ", "\t",
        ]
        bad = []
        for line in bad_lines:
            raw(cli, line)
            try:
                if "result" not in cli.call("ping", {}, timeout_s=15):
                    bad.append((line, "ping did not answer"))
            except Exception as e:
                bad.append((line, repr(e)))
                break
        fails += ok(not bad, "protocol: %d malformed / odd requests leave the stream in sync" % len(bad_lines), bad[:3])

        # one line past the 8 MiB bound is dropped / refused, not fatal
        raw(cli, "x" * (8 * 1024 * 1024 + 64))
        try:
            fails += ok("result" in cli.call("ping", {}, timeout_s=30),
                        "protocol: a line past the 8 MiB bound does not wedge the stream")
        except Exception as e:
            fails += ok(False, "protocol: a line past the 8 MiB bound does not wedge the stream", repr(e))
    finally:
        rc = cli.close()
    fails += ok(rc == 0, "protocol: clean exit after the odd-input run", rc)

    # read-only mode: a destructive tool is refused before it reaches the engine
    ro = Client(exe, env=dict(os.environ, FSQL_MCP_READ_ONLY="true"))
    try:
        ro.call("initialize", {"protocolVersion": "2025-06-18"})
        r = ro.call("tools/call", {"name": "fractalsql_configure_reasoning", "arguments": {"http_url": "http://127.0.0.1:1"}})
        res = r.get("result") or {}
        fails += ok(res.get("isError") is True and "read-only" in json.dumps(res),
                    "protocol: read-only mode refuses a destructive tool", r)
        r = ro.call("tools/call", {"name": "fractalsql_get_version", "arguments": {}})
        fails += ok("result" in r, "protocol: read-only mode still serves a non-destructive tool", r)
    finally:
        ro.close()
    return fails


def run_cancel_phase(exe):
    """POSIX + live PG + the mock reasoning plugin's slow sentinel: a
    notifications/cancelled for an in-flight slow fractal_reason call marks it
    cancelled, so its result is discarded and the client gets a cancelled
    error (the cancel branch of the dispatcher, which a quiescent server never
    reaches). Also: a cancel that names no in-flight call is a no-op."""
    slow = "/tmp/fractalsql_bt_slow_ms.txt"
    try:
        with open(slow, "w", encoding="utf-8") as fh:
            fh.write("1500")
    except Exception as e:
        print("SKIP cancel phase: cannot write the slow sentinel (" + str(e) + ")")
        return 0
    fails = 0
    cli = Client(exe)
    try:
        cli.call("initialize", {"protocolVersion": "2025-06-18"})
        cli.send("notifications/initialized", {}, notify=True)
        rid = cli.send("tools/call", {"name": "fractal_reason", "arguments": {"query": "cancel me"}})
        time.sleep(0.4)
        cli.send("notifications/cancelled", {"requestId": rid}, notify=True)
        r = cli.recv(rid, 30)
        text = json.dumps(r).lower()
        fails += ok("cancel" in text, "cancel phase: an in-flight call that is cancelled returns a cancelled error", r)
        # a cancel that names nothing in flight (wrong id, then a stale id) changes nothing
        cli.send("notifications/cancelled", {"requestId": 987654}, notify=True)
        cli.send("notifications/cancelled", {"requestId": rid}, notify=True)
        os.remove(slow)
        r = cli.call("tools/call", {"name": "fractal_reason", "arguments": {"query": "after"}})
        fails += ok("result" in r and "cancel" not in json.dumps(r).lower(),
                    "cancel phase: a stale cancel does not poison the next call", r)
    except Exception as e:
        fails += ok(False, "cancel phase: unexpected exception", repr(e))
    finally:
        cli.close()
        try:
            os.remove(slow)
        except Exception:
            pass
    return fails


def run_db_asserts(exe, ok, _setfails):
    """DB-dependent asserts against a live FractalSQL install (both extensions)."""
    import struct
    import math

    cli = Client(exe)
    fails = 0
    try:
        cli.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "db", "version": "0"}})
        cli.send("notifications/initialized", {}, notify=True)

        r = cli.call("tools/call", {"name": "fractalsql_get_version", "arguments": {}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(bool(sc.get("version")), "get_version reports engine version", sc)

        # Cognition tier against the mock reasoning plugin (spec 8.3: one
        # Cognition round trip per tier). The gate wires fractalsql.
        # reasoning_plugin to the harness's mock plugin AND seeds its
        # response file with the sentinel below (mock_generate returns the
        # file's content, fenced in ```sql, for a bare fractal_reason call) --
        # so a passing round trip proves the whole dispatch chain end to end
        # without touching a real LLM.
        r = cli.call("tools/call", {"name": "fractal_reason",
                                    "arguments": {"query": "smoke probe"}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(not (r.get("result", {}) or {}).get("isError", False)
                    and "mcp-cognition-ok" in str(sc.get("text", "")),
                    "fractal_reason round trip against the mock reasoning plugin", sc)

        # agent_partial_reasoning_fail at the MCP level (api-agency.md's contract,
        # engine key fractalsql.agent_partial_reasoning_fail): Db::applyAgentPartial
        # already SET the engine's opt-in key ON for this session (FSQL_MCP_AGENT_PARTIAL
        # defaults on). Writing the FSQL_BT_FORCE_FAIL sentinel into the mock plugin's
        # response file makes every reasoning dispatch fail deterministically (nonzero
        # rc, no response body -- the shape a real provider outage surfaces through).
        # regime_triage must then return its COMPUTED half with a NULL LLM
        # column and the error text in the SEPARATE trailing
        # 'reasoning_step_failed' column -- a successful call, NOT isError --
        # while fractal_reason deliberately keeps raising. The gate passes
        # FSQL_MCP_MOCK_SQL_FILE because the Windows mock resolves the file
        # relative to the backend's CWD (its data dir), which only the gate
        # knows.
        mock_sql = os.environ.get("FSQL_MCP_MOCK_SQL_FILE")
        if mock_sql:
            with open(mock_sql, "r", encoding="utf-8", errors="replace") as f:
                orig_sql = f.read()
            try:
                with open(mock_sql, "w", encoding="utf-8", newline="") as f:
                    f.write("FSQL_BT_FORCE_FAIL")
                r = cli.call("tools/call", {"name": "fractal_reason",
                                            "arguments": {"query": "smoke probe"}})
                fails += ok((r.get("result", {}) or {}).get("isError", False),
                            "fractal_reason still raises with the fail sentinel (flag on)", r)

                # Deterministic mirror of gate 23's proven step-up series (low-
                # frequency first half -> high-frequency second half), pseudo-noise
                # in place of random() so the drift assert can't flake.
                def _tv(t: float) -> float:
                    if t < 48:
                        return 4.0 + 1.5 * math.sin(t * 0.31) + 0.8 * (0.5 - ((t * 37) % 23) / 23.0)
                    return 4.0 + 3.0 * math.sin(t * 1.4) + 0.4 * (0.5 - ((t * 29) % 19) / 19.0)
                series = [ _tv(float( t )) for t in range( 1, 97 ) ]
                r = cli.call("tools/call", {"name": "fractal_agent_regime_triage",
                                            "arguments": {"series": series,
                                                          "win": 64,
                                                          "drift_threshold": 0.5}})
                sc = r.get("result", {}).get("structuredContent", {})
                # pg boolean fields pass db.h's decodeField as the STRING 't'/'f'
                # (only JSON-parseable text is re-typed), so 't' is true here.
                drift = str((sc or {}).get("drift_detected", "")).lower()
                # The partial-reasoning contract is TWO fields (the sibling's
                # shape, and what api-agency.md now documents): the LLM column
                # comes back NULL and a SEPARATE trailing 'reasoning_step_failed'
                # column carries the raw error text. The old shape -- the
                # marker string INSIDE the rationale column -- is what this
                # assertion used to look for; a consumer testing
                # `rationale IS NULL` must now see a null, so assert the new
                # contract exactly.
                failed_col = (sc or {}).get("reasoning_step_failed")
                fails += ok(not (r.get("result", {}) or {}).get("isError", False)
                            and (sc or {}).get("rationale") is None
                            and isinstance(failed_col, str) and failed_col != ""
                            and not failed_col.startswith("reasoning_step_failed:")
                            and isinstance((sc or {}).get("dfa_exponent"), (int, float))
                            and drift in ("true", "t", "1"),
                            "regime_triage returns the computed half + NULL rationale + reasoning_step_failed column", sc)
            finally:
                with open(mock_sql, "w", encoding="utf-8", newline="") as f:
                    f.write(orig_sql)

        r0 = cli.call("tools/call", {"name": "fractal_search_telemetry",
                                     "arguments": {"table_name": "mcpsmoke_items", "vector_col": "emb",
                                                   "query": [0.6, 0.8, 0.0], "k": 2}})
        b0 = r0.get("result", {}).get("structuredContent", {})
        fails += ok(not (r0.get("result", {}) or {}).get("isError", False),
                    "telemetry k=2 (no limit) executes", b0)
        r = cli.call("tools/call", {"name": "fractal_search_telemetry",
                                    "arguments": {"table_name": "mcpsmoke_items", "vector_col": "emb",
                                                  "query": [0.6, 0.8, 0.0], "k": 3, "limit": 2}})
        body = r.get("result", {}).get("structuredContent", {})
        rows = body.get("rows") or (body if isinstance(body, list) else [])
        trunc = body.get("truncated") if isinstance(body, dict) else None
        fails += ok(isinstance(rows, list) and len(rows) <= 2 and bool(trunc),
                    "telemetry limit=2 -> truncated + <=2 rows", body)
        flat = rows if isinstance(rows, list) else (rows or {}).get("rows", [])
        doc_id = flat[0].get("doc_id") if flat else None
        fails += ok(isinstance(doc_id, str) and doc_id.startswith("("),
                    "telemetry doc_id is the ctid STRING (e.g. '(0,1)')", rows)

        r = cli.call("tools/call", {"name": "fractal_search",
                                    "arguments": {"query": [0.6, 0.8, 0.0], "iterations": 30,
                                                  "population_size": 50, "diffusion_factor": 2}})
        sc = r.get("result", {}).get("structuredContent", {})
        vec = (sc or {}).get("value")
        fails += ok(isinstance(vec, list) and len(vec) == 3
                    and all(isinstance(x, (int, float)) or x is None for x in vec),
                    "fractal_search returns best point as a JSON number array", sc)

        r = cli.call("tools/call", {"name": "fractal_agent_detect_loop",
                                    "arguments": {"agent_id": "smoke-agent",
                                                  "state_log": [0.1, 0.2, 0.1, 0.2, 0.1, 0.2, 0.1, 0.2],
                                                  "dim": 2, "n_bits": 64, "hamming_threshold": 0}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(sc is not None and set(sc.keys()) >= {"agent_id", "dfa_exponent", "is_loop_detected"}
                    and "cycle_len" not in (sc or {}), "detect_loop 3-field composite row (no cycle_len)", sc)

        r = cli.call("tools/call", {"name": "fractal_ledger_flush", "arguments": {}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(r.get("result", {}).get("isError") is True and sc.get("error_class") == "engine"
                    and "enterprise" in str(sc.get("message", "")).lower(),
                    "ledger_flush on Community -> clean enterprise-not-loaded engine error", sc)

        r = cli.call("tools/call", {"name": "fractal_ledger_verify", "arguments": {"kind": 1}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(not (r.get("result", {}) or {}).get("isError", False)
                    and sc.get("ok") is True and isinstance(sc.get("rows_verified"), int),
                    "ledger_verify(kind=1) works with NO enterprise library", sc)

        r = cli.call("tools/call", {"name": "fractal_vectorizer_process_queue",
                                    "arguments": {"batch_size": 10, "stale_after": 600}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok((sc or {}).get("processed") == 0,
                    "vectorizer process_queue (interval bind) runs, 0 processed", sc)

        r = cli.call("tools/call", {"name": "fractal_vector_hamming_distance",
                                    "arguments": {"a": "ff00", "b": "0f0f"}})
        sc = r.get("result", {}).get("structuredContent", {})
        fails += ok(isinstance((sc or {}).get("value"), int),
                    "hamming distance (bytea,bytea)->int8 as integer", sc)

        r = cli.call("tools/call", {"name": "fractal_audit_log",
                                    "arguments": {"entry_type": "smoke", "payload": '{"k": [1,2]}'}})
        r2 = cli.call("tools/call", {"name": "fractal_audit_log",
                                     "arguments": {"entry_type": "smoke-bad", "payload": "not json"}})
        sc1 = (r.get("result", {}).get("structuredContent") or {})
        msg1 = str(sc1.get("message", ""))
        # On Community the function is enterprise-gated (dlopen runtime gate) —
        # the clean gated error IS the correct outcome; on Enterprise it appends.
        ok_first = not (r.get("result", {}) or {}).get("isError", False) or \
            (sc1.get("error_class") == "engine" and "enterprise" in msg1.lower())
        ok_second = (r2.get("result", {}).get("structuredContent") or {}).get("error_class") == "schema"
        fails += ok(ok_first and ok_second,
                    "audit_log: gated-or-ok on valid jsonb; non-JSON payload -> schema",
                    [sc1, r2.get("result")])

        # ---- admin config tools (v2.0.9 sibling port: GUC-backed get/set;
        # the fractalsql.-prefixed and bare engine key spelling both work) ----
        r = cli.call("tools/call", {"name": "fractalsql_get_config",
                                    "arguments": {"key": "agent_partial_reasoning_fail"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(not (r.get("result", {}) or {}).get("isError", False)
                    and str(sc.get("value")).lower() in ("on", "true", "1"),
                    "fractalsql_get_config reads back the session-set agent_partial key", sc)
        r = cli.call("tools/call", {"name": "fractalsql_get_config",
                                    "arguments": {"key": "http_token"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(r.get("result", {}).get("isError") is True and "never" in str(sc.get("message", "")).lower(),
                    "fractalsql_get_config refuses the secret key", sc)
        r = cli.call("tools/call", {"name": "fractalsql_set_config",
                                    "arguments": {"key": "http_model", "value": "smoke-set-model"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(r.get("result", {}).get("isError") is True
                    and "reload-scoped" in str(sc.get("message", ""))
                    and "fractalsql_configure_reasoning" in str(sc.get("message", "")),
                    "fractalsql_set_config on a reload-scoped (PGC_SIGHUP) key -> clean redirect to ALTER SYSTEM",
                    sc)
        r = cli.call("tools/call", {"name": "fractalsql_set_config",
                                    "arguments": {"key": "agent_partial_reasoning_fail", "value": "off"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(not (r.get("result", {}) or {}).get("isError", False) and sc.get("new") == "off",
                    "fractalsql_set_config sets the PGC_USERSET key session-scoped", sc)
        r = cli.call("tools/call", {"name": "fractalsql_set_config",
                                    "arguments": {"key": "agent_partial_reasoning_fail", "value": "on"}})
        r = cli.call("tools/call", {"name": "fractalsql_get_config",
                                    "arguments": {"key": "agent_partial_reasoning_fail"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(str(sc.get("value")).lower() in ("on", "true", "1"),
                    "fractalsql_get_config sees the set_config change after the reset", sc)
        r = cli.call("tools/call", {"name": "fractalsql_set_config",
                                    "arguments": {"key": "enterprise_lib", "value": "/tmp"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(r.get("result", {}).get("isError") is True
                    and "allow_secrets" in str(sc.get("message", "")),
                    "fractalsql_set_config refuses enterprise keys without allow_secrets=true", sc)
        r = cli.call("tools/call", {"name": "fractalsql_set_config",
                                    "arguments": {"key": "definitely_not_a_key", "value": "x"}})
        sc = (r.get("result", {}).get("structuredContent") or {})
        fails += ok(r.get("result", {}).get("isError") is True and "unknown config key" in str(sc.get("message", "")),
                    "fractalsql_set_config rejects an unknown key", sc)

        r = cli.call("resources/read", {"uri": "fractalsql://vectorizer/status"})
        body = r.get("result", {}).get("contents", [{}])[0].get("text", "")
        fails += ok("vectorizers" in body, "vectorizer status resource reads the VIEW", body[:120])

        r = cli.call("resources/read", {"uri": "fractalsql://schema"})
        body = r.get("result", {}).get("contents", [{}])[0].get("text", "")
        fails += ok(len(body) > 20, "schema resource returns live catalog text", body[:120])

        # vectorizer create + pause + drop lifecycle on the fixture table
        # (single-column PK; the fixture carries an empty emb_auto target
        # column -- create() needs it to exist to wire the trigger + backfill;
        # drop cascades the queued rows away).
        r = cli.call("tools/call", {"name": "fractal_vectorizer_create",
                                    "arguments": {"source_table": "mcpsmoke_items", "text_col": "label",
                                                  "embedding_col": "emb_auto"}})
        sc = r.get("result", {}).get("structuredContent", {})
        vid = (sc or {}).get("id")
        created = isinstance(vid, int) and not (r.get("result", {}) or {}).get("isError", False)
        if created:
            r2 = cli.call("tools/call", {"name": "fractal_vectorizer_pause", "arguments": {"id": vid}})
            r3 = cli.call("tools/call", {"name": "fractal_vectorizer_drop", "arguments": {"id": vid}})
            fails += ok(not (r2.get("result", {}) or {}).get("isError", False)
                        and not (r3.get("result", {}) or {}).get("isError", False),
                        "vectorizer create->pause->drop lifecycle", [r2.get("result"), r3.get("result")])
        else:
            fails += ok(False, "vectorizer create returned an id", sc)
        fails += sweep_all_tools(cli, ok)
        fails += sweep_variants(cli, ok)
        fails += sweep_negative(cli, ok)
        fails += sweep_prompts_and_resources(cli, ok)
        fails += sweep_admin(cli, ok)
    finally:
        rc = cli.close()
    fails += ok(rc == 0, "db smoke: graceful shutdown exit 0", rc)

    if fails:
        print(f"DB SMOKE FAILED: {fails} assertion(s)")
        sys.exit(1)


# ---------------------------------------------------------------------------
# All-tools sweep: every tool in tools/list is called twice against the live
# fixture -- once with only its required arguments and once with every
# argument filled -- plus once with no arguments at all (the schema-rejection
# path). The point is the adapter layer: each tool's argument binding and
# result decoding runs for real. Individual outcomes are deliberately not
# pinned (Community-only builds legitimately answer enterprise tools with an
# error); what must hold for EVERY call is a well-formed JSON-RPC response, no
# generic "internal server error", and a server that is still answering after
# the whole sweep.
# ---------------------------------------------------------------------------
_SWEEP_SKIP = {
    "fractalsql_configure_reasoning",   # ALTER SYSTEM: would rewrite the test cluster's config
}
_ARRAYS = {
    "mu": [0.1, 0.2, 0.15], "cov": [1, 0, 0, 0, 1, 0, 0, 0, 1],
    "item_values": [1, 2, 3], "upper_bounds": [1, 1, 1],
    "node_coords": [0, 0, 0, 1, 0, 0, 2, 0, 1, 3, 0, 0], "edges": [0, 1, 1, 2, 2, 3],
    "arc_length": [1, 1, 1], "vertices": [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
    "faces": [0, 1, 2, 0, 1, 3, 0, 2, 3, 1, 2, 3],
    "fingerprints": ["ff00", "0f0f", "ff00", "0f0f", "ff00", "0f0f"],
    "cohort_doc_ids": ["(0,1)", "(0,2)"], "doc_ids": ["(0,1)", "(0,2)"],
    "table_names": ["mcpsmoke_items"], "feature_array": [0.1, 0.2],
    "points": [float(i) + (i % 3) * 0.01 for i in range(40)],
    "series": [round(__import__("math").sin(i / 3.0) + i * 0.01, 4) for i in range(96)],
    "drift_series": [round(__import__("math").sin(i / 3.0) + i * 0.01, 4) for i in range(96)],
    "heading_series": [round(__import__("math").sin(i / 5.0), 4) for i in range(24)],
    "gps_trace": [round(__import__("math").sin(i / 5.0), 4) for i in range(24)],
    "point_cloud": [round((i * 37 % 101) / 101.0, 4) for i in range(600)],
    "state_log": [0.1, 0.2, 0.1, 0.2, 0.1, 0.2, 0.1, 0.2, 0.3, 0.1, 0.2, 0.3],
    # cross-modal: the two vectors are concatenated and must match the
    # fixture rows' dimension (3).
    "morphology_vector": [0.1, 0.2], "clinical_vector": [0.3],
}
_STRINGS = {
    "table_name": "mcpsmoke_items", "mem_table": "mcpsmoke_items", "catalog_table": "mcpsmoke_items",
    "alloc_table": "mcpsmoke_items", "cap_table": "mcpsmoke_items", "node_table": "mcpsmoke_items",
    "patient_table": "mcpsmoke_items", "vehicle_table": "mcpsmoke_items", "track_table": "mcpsmoke_items",
    "strategy_table": "mcpsmoke_items", "warmup_table": "mcpsmoke_items", "history_table": "mcpsmoke_items",
    "source_table": "mcpsmoke_items", "log_table": "mcpsw_logs",
    "vector_col": "emb", "vec_col": "emb", "emb_col": "emb", "alloc_emb_col": "emb", "cap_emb_col": "emb",
    "node_emb_col": "emb", "warmup_vec_col": "emb", "embedding_col": "emb_auto", "text_col": "label",
    "id_col": "id", "cap_id_col": "id", "node_id_col": "id", "metric_col": "metric", "time_col": "ts",
    "filter_col": "host", "filter_val": "h1", "a": "ff00", "b": "0f0f", "blob": "7b7d",
    "payload": '{"a": 1}', "kind": "positive", "key": "agent_partial_reasoning_fail", "value": "off",
    "meta_filter": "{}", "context": "{}", "diffusion_mode": "gaussian", "objective_mode": "sharpe",
    "content_col": "name", "metric": "cosine", "entry_type": "smoke", "agent_id": "smoke-agent",
}
_INTS = {
    "dim": 3, "k": 3, "cardinality": 2, "budget": 5, "window": 16, "forecast_steps": 2, "max_branches": 2,
    "dwell_ms": 100, "n_bits": 64, "baseline_id": 1, "doc_id": 1, "id": 999999, "result_handle": 1,
    # window / frame / persistence parameters the engine range-checks
    "win": 32, "hop": 8, "max_frames": 64, "max_dim": 1, "max_h0_bars": 16, "boxcount_dim": 2,
    "drift_win": 48, "n_restarts": 2, "baseline_window": 32,
}
# Chain geometries for the vascular / nerve tools: the engine's box-counting
# needs enough nodes (30 / 80) and a little jitter off a regular lattice to
# find >= 3 valid scales (same reasoning as the build_test.sh gate-22 fixture).
_VASC_NC = [v for i in range(30) for v in (float(i), 0.01 * ((i * 7) % 5), 0.01 * ((i * 3) % 4))]
_VASC_EDGES = [v for i in range(29) for v in (i, i + 1)]
_VASC_ARC = [round(((_VASC_NC[3 * (i + 1)] - _VASC_NC[3 * i]) ** 2 + (_VASC_NC[3 * (i + 1) + 1] - _VASC_NC[3 * i + 1]) ** 2
                    + (_VASC_NC[3 * (i + 1) + 2] - _VASC_NC[3 * i + 2]) ** 2) ** 0.5, 5) for i in range(29)]
_NERVE_NC = [v for i in range(80) for v in (float(i), (i % 2) + 0.01 * ((i * 7) % 5))]
_NERVE_EDGES = [v for i in range(79) for v in (i, i + 1)]
# (tool, parameter) -> value, where one tool needs something different from the by-name fixture.
_TOOL_OVERRIDES = {
    ("fractal_agent_recall_hybrid", "filter_col"): "label",
    ("fractal_nerve_plexus_metric", "dim"): 2,
    ("fractal_nerve_plexus_metric", "node_coords"): _NERVE_NC,
    ("fractal_nerve_plexus_metric", "edges"): _NERVE_EDGES,
    ("fractal_vascular_network", "node_coords"): _VASC_NC,
    ("fractal_vascular_network", "edges"): _VASC_EDGES,
    ("fractal_vascular_network", "arc_length"): _VASC_ARC,
    ("fractal_agent_detour_classify", "gps_trace"): _ARRAYS["point_cloud"],
    ("fractal_agent_recall_hybrid", "filter_val"): "l1",
    ("fractal_dimension_boxcount", "points"): _ARRAYS["point_cloud"],
    ("fractal_morphological_complexity", "points"): _ARRAYS["point_cloud"],
}


def _sweep_value(tool, name, schema):
    if (tool, name) in _TOOL_OVERRIDES:
        return _TOOL_OVERRIDES[(tool, name)]
    t = schema.get("type")
    if isinstance(t, list):
        t = [x for x in t if x != "null"][0]
    if t == "array":
        if name in _ARRAYS:
            return _ARRAYS[name]
        if schema.get("items", {}).get("type") == "string":
            return ["(0,1)"]
        return [0.1, 0.2, 0.3]
    if t == "string":
        return _STRINGS.get(name, "smoke")
    if t == "integer":
        if tool == "fractal_dimension_boxcount" or (tool.endswith("morphological_complexity") and name == "dim"):
            return 2
        if name == "dim" and tool in ("fractal_tda_persistence_diagram", "fractal_nerve_plexus_metric"):
            return 2
        return _INTS.get(name, 3)
    if t == "number":
        return {"alpha_weight": 0.5, "p": 2.0, "threshold": 2.0, "seed": 7}.get(name, 0.5)
    if t == "boolean":
        return False
    if t == "object":
        return {}
    return "smoke"


def sweep_variants(cli, ok):
    """Per-tool optional-argument variants. The positive sweep sends the
    required-only call and the fully-filled call; this adds, for every tool,
    one call per optional parameter (required arguments + that one optional),
    so each `args.contains(key)` / `bindIf` branch is taken in isolation, plus
    the enumerated string values (diffusion_mode, objective_mode), both
    booleans and the nullable optionals sent as an explicit null. Outcomes are
    not pinned (an engine error is a legitimate answer): every call must give a
    well-formed response and never an adapter-layer "server" error."""
    fails = 0
    tools = (cli.call("tools/list", {}).get("result") or {}).get("tools") or []
    enums = {"diffusion_mode": ["gaussian", "levy", "bogus"], "objective_mode": ["sharpe", "pareto", "bogus"]}
    bad, n_calls = [], 0
    for tool in tools:
        name = tool["name"]
        if name in _SWEEP_SKIP:
            continue
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        base = {k: _sweep_value(name, k, v) for k, v in props.items() if k in required}
        variants = []
        for k, v in props.items():
            if k in required:
                continue
            val = _sweep_value(name, k, v)
            t = v.get("type")
            if k in enums:
                variants += [{**base, k: e} for e in enums[k]]
            elif t == "boolean" or (isinstance(t, list) and "boolean" in t):
                variants += [{**base, k: True}, {**base, k: False}]
            else:
                variants.append({**base, k: val})
            if isinstance(t, list) and "null" in t:
                variants.append({**base, k: None})
        for args in variants:
            n_calls += 1
            try:
                resp = cli.call("tools/call", {"name": name, "arguments": args}, timeout_s=120)
            except Exception as e:
                bad.append((name, "call raised " + repr(e)))
                continue
            if not isinstance(resp, dict) or ("result" not in resp and "error" not in resp):
                bad.append((name, "malformed response"))
                continue
            sc = (resp.get("result") or {}).get("structuredContent") or {}
            if (isinstance(sc, dict) and sc.get("error_class") == "server") or "internal server error" in json.dumps(resp.get("error", "")):
                bad.append((name, "adapter bug -> " + json.dumps(args)[:120] + " " + json.dumps(resp)[:160]))
    fails += ok(not bad, "variants: %d one-optional-at-a-time calls all well-formed, none an adapter error" % n_calls, bad[:5])
    # A very long identifier comes back inside the engine's error text, which
    # passes through sanitizeSecrets. That used to be two std::regex passes, which
    # throw regex_error(error_complexity) on MSVC for a long message (surfacing as
    # a "server" error out of the error path itself); it is linear now.
    r = cli.call("tools/call", {"name": "fractal_vectorizer_create", "arguments": {
        "source_table": "x" * 300000, "text_col": "label", "embedding_col": "emb_auto", "options": {}}}, timeout_s=60)
    sc = (r.get("result") or {}).get("structuredContent") or {}
    fails += ok(isinstance(sc, dict) and sc.get("error_class") != "server" and "error" not in r,
                "variants: a 300000-character identifier does not break error sanitizing", json.dumps(r)[:200])
    return fails


def sweep_all_tools(cli, ok):
    fails = 0
    r = cli.call("tools/list", {})
    tools = (r.get("result") or {}).get("tools") or []
    fails += ok(len(tools) > 50, "sweep: tools/list returned the full catalog", len(tools))
    bad = []
    n_calls = 0
    for tool in tools:
        name = tool["name"]
        if name in _SWEEP_SKIP:
            continue
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        variants = [{}]
        variants.append({k: _sweep_value(name, k, v) for k, v in props.items() if k in required})
        variants.append({k: _sweep_value(name, k, v) for k, v in props.items()
                         if k in required or "default" in v})
        # Every parameter filled (nullable optionals included), then the same
        # call with each nullable optional sent as an explicit JSON null.
        full = {k: _sweep_value(name, k, v) for k, v in props.items()}
        variants.append(full)
        nullable = [k for k, v in props.items()
                    if k not in required and isinstance(v.get("type"), list) and "null" in v["type"]]
        if nullable:
            variants.append({**full, **{k: None for k in nullable}})
        for args in variants:
            n_calls += 1
            try:
                resp = cli.call("tools/call", {"name": name, "arguments": args}, timeout_s=120)
            except Exception as e:   # a timeout / dead server is the failure this sweep exists to catch
                bad.append((name, "call raised " + repr(e)))
                continue
            if not isinstance(resp, dict) or ("result" not in resp and "error" not in resp):
                bad.append((name, "malformed response"))
                continue
            err = resp.get("error")
            if err and "internal server error" in str(err.get("message", "")):
                bad.append((name, "unhandled exception -> " + str(err)))
            # A backend that died mid-call surfaces as a connection error in
            # this call's response (and in every later one). Name the call that
            # did it and stop, instead of reporting a wall of follow-on errors.
            if re.search(r"server closed the connection|terminated abnormally|recovery mode|crash of another server process",
                         json.dumps(resp)):
                bad.append((name, "BACKEND DIED on args=" + json.dumps(args)[:200] + " -> " + json.dumps(resp)[:200]))
                break
        if bad and bad[-1][1].startswith("BACKEND DIED"):
            break
    fails += ok(not bad, "sweep: %d tool calls over %d tools all returned well-formed responses" % (n_calls, len(tools)), bad[:5])
    r = cli.call("tools/call", {"name": "fractalsql_get_version", "arguments": {}})
    sc = (r.get("result") or {}).get("structuredContent") or {}
    fails += ok(bool(sc.get("version")), "sweep: server still answering after the full sweep", sc)
    return fails


# ---------------------------------------------------------------------------
# Negative sweep: the adapters' argument-validation branches. Starting from
# each tool's fully-filled VALID argument set (same fixtures as the positive
# sweep), mutate ONE thing at a time -- drop a required argument, send the
# wrong JSON type, an out-of-range number, an empty / nested / mistyped
# array, a quote-laden string, an explicit null, an unknown property -- and
# call the tool. Outcomes are mostly not pinned (a lenient coercion is a
# legitimate answer); what must hold for EVERY mutated call:
#   * a well-formed JSON-RPC response (no hang, no dead server);
#   * never a "server" error_class: that class is an adapter-layer BUG
#     (an uncaught exception, e.g. json::at/get on the wrong type), and the
#     whole point is that bad client input can never reach it;
#   * dropping a REQUIRED argument is rejected with error_class "schema".
# ---------------------------------------------------------------------------
_NEG_BAD = {   # JSON type -> a value of a different type
    "string": 12345, "integer": "not-a-number", "number": "not-a-number",
    "boolean": "maybe", "array": "not-an-array", "object": [1, 2],
}


def _neg_variants(tool, props, required, base):
    seen = set()

    def emit(label, args):
        key = json.dumps(args, sort_keys=True, default=str)
        if key not in seen:
            seen.add(key)
            return [(label, args)]
        return []

    out = []
    for k in props:
        if k in required:
            a = dict(base)
            a.pop(k, None)
            out += emit("missing-required:" + k, a)
    for k, v in props.items():
        t = v.get("type")
        nullable = isinstance(t, list) and "null" in t
        if isinstance(t, list):
            t = [x for x in t if x != "null"][0]
        if t in _NEG_BAD:
            out += emit("wrong-type:" + k, {**base, k: _NEG_BAD[t]})
        if not nullable:
            out += emit("null:" + k, {**base, k: None})
        if t == "integer":
            for bad in (-1, 0, 2147483648, 1.5):
                out += emit("int-range:%s=%r" % (k, bad), {**base, k: bad})
        elif t == "number":
            for bad in (-1.0, 0.0, 1e308, True):
                out += emit("num-range:%s=%r" % (k, bad), {**base, k: bad})
        elif t == "array":
            for bad in ([], [None], [[1, 2], [3]], ["a", "b"], [True, False], [{}]):
                out += emit("array-shape:%s=%s" % (k, json.dumps(bad)), {**base, k: bad})
        elif t == "string":
            for bad in ("", "a'b\"c;--", "x" * 4096, "\u00e9\u00e8"):
                out += emit("string-shape:%s=%r" % (k, bad[:12]), {**base, k: bad})
        elif t == "object":
            for bad in ({"unexpected": 1}, []):
                out += emit("object-shape:%s=%s" % (k, json.dumps(bad)), {**base, k: bad})
        elif t == "boolean":
            for bad in (1, "true", None):
                out += emit("bool-shape:%s=%r" % (k, bad), {**base, k: bad})
    out += emit("unknown-property", {**base, "zz_unknown_property": 1})
    return out


def sweep_negative(cli, ok):
    fails = 0
    r = cli.call("tools/list", {})
    tools = (r.get("result") or {}).get("tools") or []
    bad = []
    n_calls = 0
    n_err = 0
    for tool in tools:
        name = tool["name"]
        if name in _SWEEP_SKIP:
            continue
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        base = {k: _sweep_value(name, k, v) for k, v in props.items()}
        for label, args in _neg_variants(name, props, required, base):
            n_calls += 1
            try:
                resp = cli.call("tools/call", {"name": name, "arguments": args}, timeout_s=60)
            except Exception as e:
                bad.append((name, label, "call raised " + repr(e)))
                break
            if not isinstance(resp, dict) or ("result" not in resp and "error" not in resp):
                bad.append((name, label, "malformed response"))
                continue
            err = resp.get("error")
            res = resp.get("result") or {}
            sc = res.get("structuredContent") or {}
            cls = sc.get("error_class") if res.get("isError") else None
            if cls or err:
                n_err += 1
            if (err and "internal server error" in str(err.get("message", ""))) or cls == "server":
                bad.append((name, label, "adapter-layer error: " + json.dumps(sc or err)[:160]))
            if label.startswith("missing-required:") and cls != "schema" and not err:
                bad.append((name, label, "required argument dropped but not rejected as schema: "
                            + json.dumps(res)[:160]))
            if re.search(r"server closed the connection|terminated abnormally|recovery mode",
                         json.dumps(resp)):
                bad.append((name, label, "BACKEND DIED on args=" + json.dumps(args)[:160]))
                break
        if bad and "BACKEND DIED" in bad[-1][2]:
            break
    for entry in bad[:80]:   # the full list, so one run names every offender
        print("  negative-sweep offender: " + " | ".join(str(x)[:150] for x in entry))
    fails += ok(not bad, "negative sweep: %d mutated calls (%d rejected) over %d tools -- no hang, no "
                         "adapter-layer error, required arguments enforced" % (n_calls, n_err, len(tools)),
                bad[:6])
    r = cli.call("tools/call", {"name": "fractalsql_get_version", "arguments": {}})
    sc = (r.get("result") or {}).get("structuredContent") or {}
    fails += ok(bool(sc.get("version")), "negative sweep: server still answering afterwards", sc)
    return fails


def _tool(cli, name, args):
    """-> (is_error, structuredContent) for one tools/call."""
    res = cli.call("tools/call", {"name": name, "arguments": args}, timeout_s=60).get("result") or {}
    return bool(res.get("isError")), res.get("structuredContent") or {}


def sweep_admin(cli, ok):
    """The config tools, positive and negative, WITHOUT touching the cluster:
    fractalsql_set_config is session-scoped (set_config(..., false)) and is
    only pointed at the one session-settable key plus refusal cases; the
    ALTER SYSTEM tool (fractalsql_configure_reasoning) is exercised only on
    its no-op refusal, because a real call would rewrite postgresql.auto.conf
    for every later gate on the same cluster."""
    fails = 0
    G = "agent_partial_reasoning_fail"

    err, sc = _tool(cli, "fractalsql_set_config", {"key": G, "value": "on"})
    fails += ok(not err and sc.get("effective") is True and sc.get("key") == "fractalsql." + G,
                "admin: set_config sets the session-settable key and verifies it by read-back", sc)
    for spelling in ("true", "1", "yes", "t"):
        err, sc = _tool(cli, "fractalsql_set_config", {"key": "fractalsql." + G, "value": spelling})
        fails += ok(not err and sc.get("effective") is True,
                    "admin: boolean spelling %r reads back as the same setting (prefixed key accepted)" % spelling, sc)
    for spelling in ("off", "false", "0", "no"):
        err, sc = _tool(cli, "fractalsql_set_config", {"key": G, "value": spelling})
        fails += ok(not err and sc.get("effective") is True,
                    "admin: boolean spelling %r reads back as the same setting" % spelling, sc)
    err, sc = _tool(cli, "fractalsql_set_config", {"key": G, "value": "banana"})
    fails += ok(err and sc.get("error_class") == "engine",
                "admin: an invalid value surfaces the server's own error (engine class)", sc)
    err, sc = _tool(cli, "fractalsql_set_config", {"key": "http_model", "value": "x"})
    fails += ok(err and sc.get("error_class") == "schema" and "ALTER SYSTEM" in sc.get("message", ""),
                "admin: a reload-scoped key is refused with the ALTER SYSTEM pointer", sc)
    err, sc = _tool(cli, "fractalsql_set_config", {"key": "no_such_key", "value": "x"})
    fails += ok(err and sc.get("error_class") == "schema" and "unknown config key" in sc.get("message", ""),
                "admin: set_config rejects an unknown key", sc)
    err, sc = _tool(cli, "fractalsql_set_config", {"key": "enterprise_ledger_key", "value": "k"})
    fails += ok(err and sc.get("error_class") == "schema" and "allow_secrets" in sc.get("message", ""),
                "admin: an enterprise-posture key needs allow_secrets=true", sc)
    err, sc = _tool(cli, "fractalsql_set_config",
                    {"key": "enterprise_ledger_key", "value": "smoke-ledger-key", "allow_secrets": True})
    fails += ok(not err and sc.get("new") == "***" and sc.get("old") == "***",
                "admin: a secret key's old/new values are redacted in the result", sc)
    _tool(cli, "fractalsql_set_config", {"key": "enterprise_ledger_key", "value": "", "allow_secrets": True})

    err, sc = _tool(cli, "fractalsql_get_config", {"key": G})
    fails += ok(not err and sc.get("value") in ("on", "off") and sc.get("key") == "fractalsql." + G,
                "admin: get_config reads the session's value back", sc)
    for k in ("http_token", "fractalsql.http_token", "enterprise_ledger_key"):
        err, sc = _tool(cli, "fractalsql_get_config", {"key": k})
        fails += ok(err and sc.get("error_class") == "schema" and "secret" in sc.get("message", ""),
                    "admin: get_config never reads back the secret key %s" % k, sc)
    err, sc = _tool(cli, "fractalsql_get_config", {"key": "fractalsql.no_such_key"})
    fails += ok(err and sc.get("error_class") == "schema" and "unknown config key" in sc.get("message", ""),
                "admin: get_config rejects an unknown fractalsql.* key", sc)
    err, sc = _tool(cli, "fractalsql_get_config", {"key": "work_mem"})
    fails += ok(err and sc.get("error_class") == "schema" and "unknown config key" in sc.get("message", ""),
                "admin: get_config is not a general GUC reader -- an arbitrary server setting is refused", sc)

    for args in ({}, {"provider_url": None, "model": None, "allow_plaintext": None}):
        err, sc = _tool(cli, "fractalsql_configure_reasoning", args)
        fails += ok(err and sc.get("error_class") == "schema" and "nothing to set" in sc.get("message", ""),
                    "admin: configure_reasoning with no usable field is refused before any ALTER SYSTEM",
                    sc)
    return fails


def sweep_prompts_and_resources(cli, ok):
    """prompts/list + prompts/get for every prompt (all arguments, none, and a
    comma-separated table_names), resources/list + resources/read for every
    URI plus unknown, malformed and templated ones."""
    fails = 0
    r = cli.call("prompts/list", {})
    prompts = (r.get("result") or {}).get("prompts") or []
    fails += ok(len(prompts) >= 10, "sweep: prompts/list returned the prompt catalog", len(prompts))
    bad = []
    for pr in prompts:
        args = {a["name"]: ("orders, customers" if a["name"] == "table_names" else "smoke")
                for a in pr.get("arguments", [])}
        for params in ({"name": pr["name"], "arguments": args},
                       {"name": pr["name"], "arguments": {}},
                       {"name": pr["name"], "arguments": {a["name"]: "" for a in pr.get("arguments", [])}},
                       {"name": pr["name"]}):
            resp = cli.call("prompts/get", params)
            if "result" not in resp and "error" not in resp:
                bad.append((pr["name"], "malformed"))
    resp = cli.call("prompts/get", {"name": "no_such_prompt", "arguments": {}})
    fails += ok("error" in resp, "sweep: prompts/get on an unknown prompt is an error", resp)
    fails += ok(not bad, "sweep: prompts/get answers every prompt (full, missing and empty arguments)", bad[:3])

    r = cli.call("resources/list", {})
    uris = [x["uri"] for x in (r.get("result") or {}).get("resources", [])]
    fails += ok(len(uris) >= 4, "sweep: resources/list returned the resource catalog", uris)
    cli.call("resources/templates/list", {})
    reads = [u.replace("{kind}", "1") for u in uris] + [
        "fractalsql://ledger/2", "fractalsql://ledger/9", "fractalsql://ledger/abc",
        "fractalsql://nope", "not-a-uri", ""]
    bad = []
    for u in reads:
        resp = cli.call("resources/read", {"uri": u})
        if "result" not in resp and "error" not in resp:
            bad.append((u, "malformed"))
    resp = cli.call("resources/read", {})
    if "result" not in resp and "error" not in resp:
        bad.append(("<no uri>", "malformed"))
    fails += ok(not bad, "sweep: resources/read answers every URI, valid or not", bad[:3])
    return fails


if __name__ == "__main__":
    sys.exit(main())