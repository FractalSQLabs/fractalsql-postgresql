#!/usr/bin/env bash
# tests/valgrind_run.sh -- build_test.sh --profile: valgrind memcheck over the extension and the MCP server's code (Linux only).
#
# What it adds to the sanitizer cells: invalid and uninitialised accesses and leaks in the C code the extension runs (the core
# engine it links statically, the glue), on the unmodified build. What it cannot see: PostgreSQL allocates from memory contexts
# (palloc), and a server built without USE_VALGRIND does not tell valgrind about palloc chunks, so an uninitialised read of
# palloc'd memory, or a palloc leak, is invisible here; memory from malloc (the core) is fully tracked.
#
# Targets:
#   units    tests/extract_parse_probe.c and the three pure-C fuzz corpora (parse_embedding_array, extract_best_point,
#            extract_population) replayed with mutations; -O0 -g
#   engine   a throwaway cluster (initdb) whose postmaster runs under valgrind (--trace-children=yes: every backend gets its
#            own log), fractalsql.so preloaded, the extension's SQL installed, and every demo/demo-vertical-*.sql kit run
#            through psql with the mock reasoning plugin
#   mcp      the MCP server's own code (mcp/src, C++): vectors_probe, concurrency_probe, db_probe (DB-less)
#   server   the running MCP server under valgrind (a wrapper script starts it), driven by mcp/test/smoke.py against the
#            valgrind'd cluster
#
# Verdict (tests/valgrind_check.py): FAIL on any memcheck error or definite/indirect leak whose stack has a frame in our code (the
# extension, a probe, the MCP server binary); the PostgreSQL server's own reports and possible leaks are counted, not failed.
# SKIP (exit 0) when not on Linux or valgrind / the PostgreSQL binaries are missing.
#
# Env: PG_MAJOR (default 16; PG_BINDIR overrides /usr/lib/postgresql/$PG_MAJOR/bin), PROFILE_KEEP=1 keeps the logs directory,
# PROFILE_ONLY=units|engine|mcp|server runs one target.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
say() { printf '\n== profile: %s\n' "$*"; }
[ "$(uname -s)" = Linux ] || { echo "  SKIP profile: valgrind runs on Linux only"; exit 0; }
command -v valgrind >/dev/null 2>&1 || { echo "  SKIP profile: valgrind is not installed"; exit 0; }
PGV="${PG_MAJOR:-16}"
BIN="${PG_BINDIR:-/usr/lib/postgresql/$PGV/bin}"
[ -x "$BIN/postgres" ] && [ -x "$BIN/initdb" ] && [ -x "$BIN/psql" ] || { echo "  SKIP profile: no PostgreSQL $PGV binaries in $BIN (set PG_MAJOR or PG_BINDIR)"; exit 0; }
PY="$(command -v python3)"
ONLY="${PROFILE_ONLY:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/fsql_profile_XXXXXX")"
PGSTARTED=0
cleanup() {
  if [ "$PGSTARTED" = 1 ]; then "$BIN/pg_ctl" -D "$W/data" -m immediate stop >/dev/null 2>&1; fi
  [ "${PROFILE_KEEP:-0}" = 1 ] || rm -rf "$W"
}
trap cleanup EXIT
FAILS=0
VG=(valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes
    --num-callers=40 --fair-sched=yes --xml=yes)
cc_clean() { env -u LD_PRELOAD "$@"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; }
free_port() { "$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
export FSQL_REASONING_REQUIRE_SIGNATURE=0

SO=""
need_module() {
  [ -n "$SO" ] && return 0
  # the module is built per PostgreSQL major: clean, then build against this one
  { nice make clean PG_CONFIG="$BIN/pg_config" && nice make PG_CONFIG="$BIN/pg_config"; } >"$W/make.log" 2>&1 \
    || { fail "the extension did not build (see $W/make.log)"; return 1; }
  SO="$ROOT/fractalsql.so"
  [ -f "$SO" ] || { fail "no extension at $SO"; return 1; }
}

verdict() {   # verdict LABEL ours... -- xml...
  local label="$1"; shift
  local args=() xmls=() seen=0 a
  for a in "$@"; do
    if [ "$a" = -- ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then args+=(--ours "$a"); else xmls+=("$a"); fi
  done
  local x ok=1; for x in "${xmls[@]}"; do [ -s "$x" ] || { echo "  FAIL $label: no valgrind report at $x"; ok=0; }; done
  [ "$ok" = 1 ] || { FAILS=$((FAILS + 1)); PROFILE_KEEP=1; return; }
  if "$PY" -I "$HERE/valgrind_check.py" verdict "${args[@]}" "${xmls[@]}"; then echo "  PASS $label"
  else echo "  FAIL $label (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
}

# a cluster whose postmaster (and every backend it forks) runs under valgrind; sets PGPORT, SOCK, PSQL; logs in $W/slogs
start_pg_vg() {
  need_module || return 1
  PGPORT="$(free_port)"; SOCK="$W/sock"; mkdir -p "$SOCK" "$W/slogs"
  local MOCK="$W/mock_reasoning_plugin.so"
  cc_clean cc -shared -fPIC -std=c99 -Iinclude tests/mock_reasoning_plugin.c -o "$MOCK" 2>"$W/plugin.log" || { fail "the mock plugin did not build"; return 1; }
  "$BIN/initdb" -D "$W/data" -U postgres --auth=trust >"$W/initdb.log" 2>&1 || { fail "initdb failed (see $W/initdb.log)"; return 1; }
  { echo "fractalsql.reasoning_plugin = '$MOCK'"; echo "fractalsql.text_to_sql_max_attempts = 1"; } >> "$W/data/postgresql.conf"
  ( cd "$W" && exec nice "${VG[@]}" --trace-children=yes --xml-file="$W/slogs/pg.%p.xml" "$BIN/postgres" -D "$W/data" -p "$PGPORT" -k "$SOCK" \
      -c listen_addresses='' -c shared_preload_libraries="$SO" ) >"$W/pg.log" 2>&1 &
  PGSTARTED=1
  local i
  for i in $(seq 1 240); do "$BIN/pg_isready" -h "$SOCK" -p "$PGPORT" >/dev/null 2>&1 && break; sleep 0.5; done
  "$BIN/pg_isready" -h "$SOCK" -p "$PGPORT" >/dev/null 2>&1 || { echo "  the cluster did not come up:"; tail -5 "$W/pg.log"; return 1; }
  PSQL=("$BIN/psql" -h "$SOCK" -p "$PGPORT" -U postgres -X -tA)
  sed -e "s#MODULE_PATHNAME#$SO#g" -e '/^\\echo/d' sql/fractalsql--1.0.sql > "$W/ext.sql"
  "${PSQL[@]}" -f "$W/ext.sql" >"$W/ext.out" 2>&1
  if grep -q 'ERROR' "$W/ext.out"; then echo "  the extension's SQL did not install cleanly:"; grep -m3 ERROR "$W/ext.out"; return 1; fi
  # the dependent fractalsql_agents extension (the PL/pgSQL agent engines the kits call), with its \echo ... \quit guard dropped
  grep -v '\\quit' fractalsql_agents/sql/fractalsql_agents--1.0.sql | "${PSQL[@]}" >"$W/agents.out" 2>&1
  if grep -q 'ERROR' "$W/agents.out"; then echo "  the agents SQL did not install cleanly:"; grep -m3 ERROR "$W/agents.out"; return 1; fi
  return 0
}
stop_pg_vg() {   # a fast shutdown: the backends exit normally, which is what makes valgrind write their reports
  "$BIN/pg_ctl" -D "$W/data" -m fast -w -t 600 stop >"$W/stop.log" 2>&1 || { fail "the cluster did not stop (see $W/stop.log)"; }
  PGSTARTED=0
  local i; for i in $(seq 1 240); do pgrep -f "$W/data" >/dev/null 2>&1 || break; sleep 0.5; done
}

if [ -z "$ONLY" ] || [ "$ONLY" = units ]; then
  say "units"
  mkdir -p "$W/u"
  build() { cc_clean cc -std=c11 -O0 -g -Wno-unused-function -Iinclude -Isrc "$@" -lm 2>"$W/u/cc.log" \
              || { fail "a unit binary did not build"; tail -3 "$W/u/cc.log"; return 1; }; }
  run_u() {   # run_u NAME args...
    local n="$1"; shift
    timeout 600 nice "${VG[@]}" --xml-file="$W/u/$n.xml" "$W/u/$n" "$@" >"$W/u/$n.log" 2>&1
    verdict "$n" "$W/u/" -- "$W/u/$n.xml"
  }
  build tests/extract_parse_probe.c src/fractalsql_parse.c -o "$W/u/extract_parse_probe" && run_u extract_parse_probe
  for t in parse_embedding_array extract_best_point extract_population; do
    build "$HERE/fuzz_replay.c" "tests/fuzz/fuzz_$t.c" src/fractalsql_parse.c -o "$W/u/fuzz_$t"
    [ -x "$W/u/fuzz_$t" ] && run_u "fuzz_$t" "tests/fuzz/corpus_$t" 3
  done
fi

if [ -z "$ONLY" ] || [ "$ONLY" = engine ]; then
  say "engine (PostgreSQL $PGV postmaster under valgrind, the demo kits through psql)"
  if start_pg_vg; then
    n=0; bad=0
    for kit in "$ROOT"/demo/demo-vertical-*.sql; do
      [ -f "$kit" ] || continue
      n=$((n + 1))
      "${PSQL[@]}" -F'|' -f "$kit" >"$W/kit_$n.out" 2>&1 || true
      grep -q 'server closed the connection\|terminated abnormally\|connection to server was lost' "$W/kit_$n.out" && { bad=$((bad + 1)); echo "  the server died during $(basename "$kit")"; }
    done
    echo "  $n kits"
    [ "$bad" -eq 0 ] || { FAILS=$((FAILS + 1)); PROFILE_KEEP=1; }
    stop_pg_vg
    # shellcheck disable=SC2206
    logs=("$W"/slogs/pg.*.xml)
    verdict engine "$SO" -- "${logs[@]}"
  else fail "engine: could not start the cluster under valgrind"; stop_pg_vg; fi
fi

mcp_ready() {
  [ -n "${MCP_READY:-}" ] && return 0
  CXX="$(command -v g++ || command -v c++ || command -v clang++ || true)"
  if [ -z "$CXX" ] || ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists libpq 2>/dev/null; then
    echo "  SKIP mcp: no C++ compiler or no libpq (pkg-config libpq)"; return 1
  fi
  mkdir -p "$W/mcp"; MCP_READY=1
}

if [ -z "$ONLY" ] || [ "$ONLY" = mcp ]; then
  say "mcp (the MCP server's probes, C++)"
  if mcp_ready; then
    M="$ROOT/mcp"; CXXF=(-std=c++17 -O1 -g -pthread -I"$M/vendor" -I"$M/src" $(pkg-config --cflags libpq))
    bm() { cc_clean "$CXX" "${CXXF[@]}" "$@" 2>>"$W/mcp/cc.log" || { fail "an MCP probe did not build (see $W/mcp/cc.log)"; return 1; }; }
    run_m() { local n="$1"; shift; timeout 1500 nice "${VG[@]}" --xml-file="$W/mcp/$n.xml" "$W/mcp/$n" "$@" >"$W/mcp/$n.log" 2>&1; verdict "mcp_$n" "$W/mcp/" -- "$W/mcp/$n.xml"; }
    bm "$M/tests/vectors_probe.cpp" "$M/src/vectors.cpp" "$M/src/errors.cpp" -o "$W/mcp/vectors_probe" && run_m vectors_probe
    bm "$M/tests/concurrency_probe.cpp" -o "$W/mcp/concurrency_probe" && run_m concurrency_probe
    bm "$M/tests/db_probe.cpp" "$M/src/errors.cpp" "$M/src/logging.cpp" -o "$W/mcp/db_probe" $(pkg-config --libs libpq) -lssl -lcrypto -lpthread \
      && { unset PGHOST PGPORT PGUSER PGDATABASE PGCONN; run_m db_probe; }
  fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = server ]; then
  say "server (the running MCP server under valgrind, driven by mcp/test/smoke.py)"
  if mcp_ready; then
    if ! cc_clean nice make -C "$ROOT/mcp" CXX="$CXX" CXXFLAGS="-O1 -g $(pkg-config --cflags libpq)" OUT="$W/mcp/fractalsql-postgresql-mcp" >"$W/mcp/smake.log" 2>&1; then
      fail "the MCP server did not build (see $W/mcp/smake.log)"; tail -5 "$W/mcp/smake.log"
    else
      rm -rf "$W/data" "$W/sock" "$W/slogs"
      if start_pg_vg; then
        # the server refuses to start without its drift locks, looked up next to the executable
        cp "$ROOT/mcp/.mcp-schema-lock" "$ROOT/mcp/.mcp-safety-annotations-lock" "$W/mcp/" 2>/dev/null
        mkdir -p "$W/mcp/slogs" "$W/mcp/cwd"
        cat > "$W/mcp/srv-valgrind.sh" <<EOF
#!/bin/bash
# (bash, not dash: only bash keeps the client's stdin on a backgrounded command)
# valgrind runs as a child that keeps the client's pipes, so a client that gives up waiting for the (slow, leak-checking) exit and
# kills this wrapper does not cut the report short
nice valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes --num-callers=40 --fair-sched=yes --xml=yes --xml-file='$W/mcp/slogs/server.%p.xml' '$W/mcp/fractalsql-postgresql-mcp' "\$@" <&0 &
VP=\$!
# a client that terminates the wrapper (HTTP servers are stopped that way) must stop the server, not orphan it
trap 'kill -TERM \$VP 2>/dev/null' TERM INT
while kill -0 \$VP 2>/dev/null; do wait \$VP; rc=\$?; done
exit \${rc:-0}
EOF
        chmod +x "$W/mcp/srv-valgrind.sh"
        # the fixtures the smoke driver expects (as the harness's gate 33 creates them), and the canned reply the mock plugin returns
        "${PSQL[@]}" -c "
           CREATE TABLE mcpsmoke_items (id serial PRIMARY KEY, name text, label text, emb float8[], emb_auto float8[]);
           INSERT INTO mcpsmoke_items (name, label, emb) SELECT 'i' || g, 'l' || g, ARRAY[0.1*g, 0.2, 0.0]::float8[] FROM generate_series(1, 5) g;
           CREATE TABLE mcpsw_logs (metric float8, ts timestamptz, host text);
           INSERT INTO mcpsw_logs SELECT 50.0 + (g % 8) * 1.3 + CASE WHEN g > 48 THEN 30.0 ELSE 0.0 END,
                  now() - (96 - g) * interval '1 second', 'h1' FROM generate_series(1, 96) g;" >"$W/fixtures.out" 2>&1
        printf "SELECT 'mcp-cognition-ok'::text;\n" > /tmp/fractalsql_bt_sql.txt
        out="$(cd "$W/mcp/cwd" && env PGHOST="$SOCK" PGPORT="$PGPORT" PGUSER=postgres PGDATABASE=postgres FSQL_MCP_LOG_LEVEL=normal \
               FSQL_MCP_EXE="$W/mcp/srv-valgrind.sh" FSQL_MCP_MOCK_SQL_FILE=/tmp/fractalsql_bt_sql.txt timeout 3000 "$PY" -u "$ROOT/mcp/test/smoke.py" 2>&1)"
        rc=$?
        printf '%s\n' "$out" > "$W/mcp/smoke.log"
        echo "  smoke driver: $(grep -c '^ *PASS\|^PASS' <<< "$out") checks passed, $(grep -c '^ *FAIL\|^FAIL' <<< "$out") failed (exit $rc)"
        # the driver waits 15 s for each server to exit and then kills it; valgrind's leak check takes longer, so "graceful shutdown"
        # checks are a timing artifact here, not a finding: they are reported but not counted
        real_fails="$(grep -E '^ *FAIL' <<< "$out" | grep -vc 'graceful shutdown')"
        if [ "$rc" -ne 0 ] && { [ "$real_fails" -ne 0 ] || ! grep -q 'graceful shutdown' <<< "$out"; }; then
          echo "  (a failure here may be a client timeout under valgrind's slowdown, see $W/mcp/smoke.log)"
          grep -E 'FAIL|Traceback|Error' <<< "$out" | head -5 | cut -c1-200
          FAILS=$((FAILS + 1)); PROFILE_KEEP=1
        elif [ "$rc" -ne 0 ]; then echo "  note: only the shutdown-timing checks failed (the driver kills a server that is still writing its valgrind report)"; fi
        # let every valgrind'd server finish writing its report
        for i in $(seq 1 120); do pgrep -f "$W/mcp/slogs/" >/dev/null 2>&1 || break; sleep 1; done
        pkill -TERM -f "$W/mcp/slogs/" 2>/dev/null   # a server the client left running: stop it so it writes its report
        for i in $(seq 1 600); do pgrep -f "$W/mcp/slogs/" >/dev/null 2>&1 || break; sleep 1; done
        stop_pg_vg
        # shellcheck disable=SC2206
        logs=("$W"/mcp/slogs/server.*.xml "$W"/slogs/pg.*.xml)
        verdict server "$W/mcp/fractalsql-postgresql-mcp" "$SO" -- "${logs[@]}"
      else fail "server: could not start the cluster under valgrind"; stop_pg_vg; fi
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "profile: all targets clean"; else echo "profile: $FAILS target(s) failed"; fi
[ "${PROFILE_KEEP:-0}" = 1 ] && echo "  logs kept in $W"
exit "$FAILS"
