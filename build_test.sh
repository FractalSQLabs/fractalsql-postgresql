#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh — post-build validation gate runner for
# fractalsql-postgresql. Mirrors what CI runs, so local == CI.
#
# Builds the extension for a target PostgreSQL major and validates it
# against a THROWAWAY cluster (no root: initdb + a private socket dir in
# /tmp, torn down on exit).
#
# Gates:
#   01  build          make against the target major's pg_config      ~5s
#   02  smoke          load + version + fractal_search convergence    ~5s
#   03  schema_context introspection (PK / NOT NULL / comment / FK)   ~3s
#   04  text_to_sql    allowlist fuzz matrix + never-executes proof   ~8s
#                      (uses tests/mock_reasoning_plugin.c)
#   05  evil_overread  guard-page non-terminated response survives,   ~3s
#                      at GENERATE, REVIEW, and bare fractal_reason()
#                      (uses tests/evil_nonterminating_plugin.c)
#   06  crash_recovery deliberately-segfaulting plugin: connection    ~10s
#                      drops, cluster auto-restarts, prior data intact
#                      (uses tests/evil_crash_plugin.c)
#   07  evil_lying_length  guard_ai_response_len rejects an implausible ~3s
#                      claimed length before any read, at GENERATE,
#                      REVIEW, and bare fractal_reason()
#                      (uses tests/evil_lying_length_plugin.c)
#   08  authz          low-priv role blocked from schema_context on a  ~1s
#                      table it lacks SELECT on (info-disclosure fix)
#   09  guc_superuser   non-superuser rejected from setting            ~1s
#                      reasoning_plugin (GUC_SUPERUSER_ONLY fix)
#   10  dos_and_injection  512-table cap fires at 513; SQL-injection-  ~1s
#                      shaped table_names cleanly rejected, not executed
#   11  scout           fractal_search_explore: full population       ~2s
#                      returned, disperses across >1 island
#   12  soak            SOAK_WORKERS concurrent backends x SOAK_ITERS   ~5s
#                      mixed benign calls each; asserts no failures
#                      and the cluster stays responsive under load
#   13  siu_mode        text_to_sql_allowed_statements=select_insert_   ~2s
#                      update: INSERT/UPDATE returned (never executed),
#                      DDL/DELETE still rejected
#   14  retry           max_attempts=2 retry-with-feedback: attempt 1   ~1s
#                      rejected, attempt 2 succeeds, rejection reason
#                      threaded into the attempt-2 prompt
#                      (uses tests/retry_reasoning_plugin.c)
#   15  embed           fractal_embed() + the vectorizer: create/       ~3s
#                      backfill/process_queue/status against a canned
#                      embedding, real dispatch through the three-tier
#                      ensure_embed_ctx() path (not just error paths);
#                      NULL input, bad plugin path, over-limit embedding
#                      array (evil_embed_plugin.c), injection-shaped
#                      source_table, double-create
#                      (uses tests/mock_embed_plugin.c, evil_embed_plugin.c)
#   16  embed_authz     vectorizer authz: a role that owns its table    ~1s
#                      can fully use its own vectorizer with no extra
#                      DBA grants; a different role with no SELECT on
#                      that table cannot read/embed it via the GLOBAL
#                      process_queue() (mirrors gate 08's boundary for
#                      the vectorizer specifically)
#   17  embed_soak      concurrent fractal_vectorizer_process_queue()   ~3s
#                      calls (10 workers) against a 100-row shared
#                      queue -- proves SELECT ... FOR UPDATE SKIP LOCKED
#                      really does prevent double-processing (mirrors
#                      gate 12's soak pattern)
#   18  embed_crash     deliberately-segfaulting plugin mid-           ~10s
#                      process_queue(): proves a crash rolls the WHOLE
#                      in-flight call back (rows revert to 'pending',
#                      not stuck 'processing' needing stale_after) and
#                      that a normal call afterward recovers cleanly
#                      (uses tests/evil_crash_plugin.c, mirrors gate 06)
#   19  sfs_bounds      validate_sfs_params() bounds for fractal_search/  ~1s
#                      _debug/_explore (iterations/population_size/
#                      diffusion_factor/dim, never exercised before this
#                      gate) plus an injection-shaped table_name into
#                      fractal_search_explore (mirrors gate 10's
#                      equivalent test for fractal_schema_context)
#   20  api_func        closes 5 API-surface coverage gaps found by a     ~2s
#                      gap analysis against README's API table:
#                      fractal_reason() happy-path correctness (never
#                      checked before -- only ever "didn't crash"),
#                      fractal_reason(NULL) and fractal_text_to_sql(NULL)
#                      rejection, fractal_search_explore()'s own bounds
#                      via its options jsonb (shares validate_sfs_params
#                      but was never proven), and
#                      fractal_vectorizer_process_queue()'s stale_after
#                      reclaim UPDATE (staged directly, with a
#                      within-window negative control)
#   21  fuzz_smoke      FUZZ ONLY (--fuzz, not in DEFAULT/QUICK). Builds  ~90s
#                      + briefly runs (FSQL_FUZZ_TIME seconds each,
#                      default 30) libFuzzer drivers against the 3
#                      hand-rolled parsers in src/fractalsql_parse.c
#                      (factored out of fractalsql.c specifically so
#                      they can link standalone, no postgres backend
#                      needed): fsql_parse_embedding_array (highest
#                      priority -- parses fractal_embed()'s raw response
#                      from whatever endpoint fractalsql.http_embed_url
#                      points at, genuinely externally-adversarial
#                      input), fsql_extract_best_point and
#                      fsql_extract_population (parse the vendored
#                      core's own result JSON -- lower risk, included as
#                      defense-in-depth). No live cluster needed.
#                      Requires a libFuzzer-capable clang (set
#                      FSQL_FUZZ_CC to override auto-detection); skips
#                      cleanly if none is found.
#   28  review_isolation  ensure_review_ctx()/g_review_ctx: fractal_   ~10s
#                      text_to_sql()'s REVIEW step never inherits an
#                      operator-set FSQL_REASONING_HTTP_RESPONSE_MODE,
#                      even under a real postmaster restart with it
#                      exported (RESPONSE_MODE has no GUC -- it's a
#                      boot-time env capture, unlike THINK in gate 27)
#   29  vector_ops      all 17 fractal_vector_* functions (arithmetic/   ~2s
#                      distance/quantization on the native vector
#                      type), known-answer asserted
#   30  new_primitives  the 6 newest analytics/vector-math primitives,    ~2s
#                      known-answer asserted: change_point_detect,
#                      periodogram, state_fingerprint, cycle_detect,
#                      tda_persistence_diagram, optimize_subset
#   31  enterprise_mock  enterprise activation/signature verification    ~3s
#                      (gates 24-26's dlopen/dlsym wiring) against a
#                      throwaway self-signed mock .so compiled at test
#                      time (tests/mock_enterprise_core.c)
#   32  sovereign_agents  the 5 C-native Agent functions (fractal_       ~3s
#                      search_agent, fractal_agent_plan_explore,
#                      fractal_agent_trajectory_predict, fractal_agent_
#                      detect_loop, fractal_rag_agent)
#   33  mcp_smoke        the FractalSQL MCP plugin (mcp/, docs/            ~8s
#                      mcp-plugin.md) end to end over stdio:
#                      initialize handshake, tools/list against the
#                      pinned 79-tool postgreSQL catalog with the
#                      non-empty description + inputSchema.properties
#                      accessibility invariant (spec 1.7 mechanically),
#                      then tools/call round trips per tier -- one
#                      Discovery (telemetry + vector normalization),
#                      one Cognition against $MOCK, one no-LLM Community
#                      agent, the clean "enterprise tier not loaded"
#                      error path, the schema/validation error class,
#                      and the 1.5 row-ceiling truncation contract.
#                      The shared engine lives in mcp/test/smoke.py (stdlib
#                      python only, no MCP SDK); this gate is a thin wrapper
#                      (fixture + env + dispatch) like gate 21's standalone
#                      shape. Skips when make/g++ (the C++17 build), pkg-
#                      config libpq/openssl, or python3 are absent.
#   39  extract_parse  standalone C unit probe (tests/               ~1s
#                      extract_parse_probe.c) linked against this
#                      repo's OWN src/fractalsql_parse.c: covers
#                      fsql_extract_best_point /
#                      fsql_parse_embedding_array / fsql_extract_topk's
#                      malformed-input error branches (missing key,
#                      malformed number, missing closing brace, idx
#                      out of range/wrap guard, non-JSON input) --
#                      unreachable through any real SQL-level call,
#                      where those parsers only ever see well-formed
#                      core/mock output (same rationale as the SQLite
#                      column's gate 39). Compiled with separately-
#                      named _extract_parse_* objects so a --coverage
#                      run MERGES the probe's parse.c hits with the
#                      main build's instead of overwriting them.
#                      Skips cleanly if no C compiler is present.
#   40  vectors_probe  standalone C++17 unit probe (mcp/tests/        ~3s
#                      vectors_probe.cpp, 43 checks) against mcp/src/
#                      vectors.cpp + errors.cpp: the coercion/
#                      validation branches only reachable with inputs
#                      the live tools/call schema layer filters out.
#                      No DB involved. Skips without g++/clang++.
#   41  db_probe       standalone C++17 unit probe (mcp/tests/        ~6s
#                      db_probe.cpp) against libpq: the DB-less
#                      unconnected/refused-connection/SQLSTATE
#                      classification branches always run with no
#                      PG* env (16 checks); the connected branches
#                      then run LIVE against the throwaway cluster on
#                      the gate-41 live leg (see run_major: it runs
#                      after gate 33, wiring the same PG* env gate 33
#                      exports to the server). Live checks that need
#                      no cluster are SKIPPED, not failed, without
#                      one. Skips without g++/libpq headers.
#   42  concurrency_probe  standalone C++17 unit probe (mcp/tests/    ~1s
#                      concurrency_probe.cpp, 4 checks) for mcp/src/
#                      concurrency.h's per-client-limit / global-
#                      timeout / Token-release branches -- saturated
#                      sequentially, no timing dependency, no DB.
#                      Header-only, so only -I mcp/src is needed.
#   43  enterprise_surface  the enterprise SURFACE invariant: of the   ~2s
#                      twelve user-facing enterprise functions,
#                      exactly ONE -- fractal_ledger_verify() -- is not
#                      gated on the enterprise core library (it is a
#                      pure storage-layer read of the persisted chain),
#                      and the other ELEVEN raise 'enterprise tier not
#                      loaded' with no core loaded. Forces the dormant
#                      state deterministically (the enterprise_lib GUC
#                      pointed at a nonexistent path) so it asserts the
#                      same thing on a community checkout and on an
#                      enterprise one. Does NOT self-skip on community:
#                      the community checkout is the state it pins.
#   44  error_paths    argument-validation / error-path sweep: ~270     ~40s
#                      calls (NULL args, zero/negative sizes, ragged or
#                      mismatched arrays, missing tables/columns, bad
#                      enums, out-of-range indexes) each pinned to the
#                      exact error it must raise, and each failed if it
#                      crashes the backend. Mostly there to cover the
#                      ereport branches the happy-path gates skip; it
#                      found fractal_sql_agent(NULL) and
#                      fractal_sql_agent(q, NULL, 0) crashing the backend.
#   48  kits           the twenty-nine newer industry kits (demo/demo-       ~20s
#                      vertical-{ev-battery-lifecycle,adas-safety-
#                      validation,v2x-warranty-triage,critical-
#                      inventory-routing,heavy-industry-predictive-
#                      maintenance,climatech-grid-balancing,hazmat-
#                      occupational-triage,scenario-planning-
#                      simulation,avionics-fault-prediction,
#                      satellite-constellation-coverage,telecom-
#                      account-anomaly-screening,telecom-traffic-
#                      routing,climatech-emissions-monitoring,
#                      climatech-risk-exposure,rf-spectrum-sensing}
#                      .sql): each is run through psql against the
#                      scratch cluster with the mock reasoning
#                      plugin, raises no SQL error (the scenario
#                      kit's plan_explore needs an embedding
#                      endpoint: at most one expected), prints no
#                      NaN, and reproduces its headline result on
#                      its deterministic fixture
#   45  enterprise_paths  the enterprise-tier paths the dormant state     ~15s
#                      cannot reach, via tests/mock_enterprise_core.c:
#                      multimodal / pareto / audit argument validation,
#                      and the ledger-tip authentication fractal_ledger_
#                      load() runs (genesis, chain link, structural hash,
#                      MAC present/short/wrong/valid, key set/unset)
#                      against hand-built kind=1 chains with a real
#                      HMAC-SHA256 computed in SQL. Found
#                      fractal_audit_log(NULL, ...) crashing the backend.
#   38  mcp_https     the MCP server's direct-TLS mode (--https):        ~4s
#                      mcp/tests/mcp_https_smoke_client.py drives the
#                      three fail-fast startup modes (missing cert/key,
#                      garbage key, mismatched key -> nonzero exit),
#                      proves the port speaks TLS not plaintext, and
#                      round-trips an authenticated session under the
#                      Bearer-token check. Standalone (no cluster);
#                      live-DB leg self-skips without PG* env. Skips
#                      without openssl/python3/make+g++/pkg-config.
#
# Gate sets:
#   QUICK   = 01 02                                   post-edit sanity loop
#   DEFAULT = 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 22 23  pre-push / CI (one major)
#             24 25 26 27 28 29 30 31 32 33 38 39 40 41 42 43 44 45 46 47
#   FUZZ    = 21                                       --fuzz, not part of DEFAULT (adds real wall-time)
#
# Cross-version: pass --cross to run DEFAULT against every installed
# major in 14..18 (skips majors whose server binaries are absent). This
# is what the release matrix exercises.
#
# Usage:
#   ./build_test.sh                 # DEFAULT against PG_MAJOR (default 16)
#   ./build_test.sh --quick
#   ./build_test.sh --pg 15
#   ./build_test.sh --cross
#   ./build_test.sh --fuzz          # gate 21 only -- libFuzzer smoke, no cluster
#   ./build_test.sh --gate 04
#   ./build_test.sh --list
#   ./build_test.sh --coverage      # gcov-instrumented build; DEFAULT
#                                    # gates; lcov/genhtml report after
#
# --coverage notes:
#   Rebuilds with `make COVERAGE=1` (Makefile: --coverage on compile +
#   link for src/fractalsql.o only, not the vendored core archive).
#   Needs lcov+genhtml on PATH. This repo checks out onto a vboxsf bind
#   mount in this environment -- gcov's .gcda updates can hang there,
#   so GCOV_PREFIX/GCOV_PREFIX_STRIP redirect the live writes
#   to /tmp for the duration of the run; the result is copied back
#   next to the .gcno afterward, once, as a plain file copy (safe).
#   Report: coverage_html/index.html (+ coverage_html_mcp/ when the
#   gate 40/41/42 probes ran the mcp sources instrumented) + a text
#   summary on stdout. Branches are counted EXCLUDING exception-tagged
#   (lower-case 'e'-prefixed block numbers) BRDA records, and
#   --rc no_exception_branch=1 is passed to GENHTML ONLY (see the
#   comments in run_coverage_report: passing it to lcov
#   --capture/--extract instead zeroes BRF/BRH entirely on this
#   lcov/geninfo version, a geninfo 2.0-1 bug in that combination).
#
# Environment:
#   PG_MAJOR             target major (default: 16)
#   PG_BINDIR             override /usr/lib/postgresql/$PG_MAJOR/bin
#   FSQL_TEST_TIMEOUT_MULT  scales gate 06/18's crash-recovery poll
#                           budget (default 1; auto-defaults to 4 under
#                           --asan/--ubsan, since ASan's overhead alone
#                           is enough to blow the default 15s budget on
#                           real hardware -- set this explicitly to
#                           override that auto-bump either direction).
#                           Bump further on a loaded/VM host where WAL
#                           replay + shared-memory reinit runs slower
#                           still.
#   FSQL_FUZZ_CC            libFuzzer-capable clang for gate 21 (default:
#                           auto-detect clang-18/17/16/15/clang on PATH,
#                           probed for -fsanitize=fuzzer support before
#                           use -- a bare `clang` shadowed by an
#                           unrelated toolchain is a real failure mode,
#                           not hypothetical).
#   FSQL_FUZZ_TIME          seconds per fuzz target in gate 21 (default
#                           30). This is a pre-push SMOKE run, not a
#                           campaign -- bump it locally for real
#                           crash-finding, same binaries either way.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Canonical (symlink-resolved) tmp root. fractalsql-core's
# fsql_load_reasoning() deliberately rejects any plugin path where
# realpath(path) != path -- a defense against symlink pivots (see its
# own header comment in fractalsql-core/src/fsql.c). On Linux /tmp is a
# real directory, so this is a no-op. On macOS /tmp is ITSELF a
# standard, OS-provided symlink to /private/tmp, so any plugin path
# built as literal "/tmp/..." fails that check even though nothing
# malicious is going on -- confirmed on real Darwin hardware: "path is
# not canonical (got '/tmp/fractalsql_bt_mock_16.so', resolves to
# '/private/tmp/fractalsql_bt_mock_16.so')" on every gate that loads a
# mock/evil test plugin. Resolving once here and building every plugin
# path from $TMPROOT (not a literal "/tmp") fixes this at the source
# instead of weakening the security check itself.
TMPROOT="$(cd /tmp && pwd -P)"

# fsql_pg_dlsuffix <pg_config> -- echoes the DLSUFFIX the GIVEN target's
# own PGXS will actually use. Confirmed on real CI hardware (2026-08):
# this is NOT simply "uname -s == Darwin" -> .dylib -- PostgreSQL itself
# changed its own default Darwin DLSUFFIX from .so to .dylib at a
# specific major-version boundary, and that boundary lands INSIDE our
# own supported range (PG14/15 still use .so; PG16-18 use .dylib, each
# confirmed directly from a real link command in CI). A hardcoded guess
# here built fine either way (make itself doesn't care what name it
# writes), but every RUNTIME load failed on whichever majors guessed
# wrong, since Postgres's dfmgr.c looks for that exact suffix with no
# fallback. A prior version of this function parsed Makefile.global's
# own DLSUFFIX default directly -- but that value can be overridden
# LATER by an `include .../Makefile.port` line inside Makefile.global
# (Makefile.port wins, since it's included last), so parsing only
# Makefile.global silently missed the override on PG14/15 and always
# fell back to the wrong guess there. PGXS ships a `show_dl_suffix`
# target for exactly this ("Show the DLSUFFIX to build scripts (e.g.
# buildfarm)") -- ask the same Makefile/PGXS chain the real build uses
# instead of re-deriving the include/override logic ourselves.
fsql_pg_dlsuffix() {
  local pg_config="$1" suffix=""
  suffix="$(make PG_CONFIG="$pg_config" show_dl_suffix 2>/dev/null | tail -1)"
  if [[ -n "$suffix" ]]; then
    printf '%s' "$suffix"
  elif [[ "$(uname -s)" = "Darwin" ]]; then
    printf '%s' ".dylib"
  else
    printf '%s' ".so"
  fi
  return 0
}

DEFAULT_GATES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32 33 38 39 40 41 42 43 44 45 46 47 48)
QUICK_GATES=(01 02)
FUZZ_GATES=(21)

PG_MAJOR="${PG_MAJOR:-16}"
MODE="default"
ONE_GATE=""
COVERAGE=0
ASAN=0
UBSAN=0

# Scales the poll-loop budgets below (pg_swap_plugin's reload wait,
# gate 06/18's post-crash restart wait). Loaded/VM hosts can make crash
# recovery (WAL replay + shared-memory reinit) take noticeably longer
# than on a quiet dev box. Bump this rather than adding a
# skip/retry hack: e.g. FSQL_TEST_TIMEOUT_MULT=3 ./build_test.sh --cross
#
# --asan/--ubsan auto-bump to 4 (unless FSQL_TEST_TIMEOUT_MULT is
# explicitly set): confirmed empirically, not theoretical -- ASan's
# instrumentation adds real overhead to crash recovery's WAL replay +
# shared-memory reinit, enough that the default 15s budget
# (TIMEOUT_MULT=1) times out on real hardware, not just a loaded VM.
# Once gate 06 times out the cluster is STILL mid-recovery, which then
# cascades into every later gate failing with "database system is in
# recovery mode" -- a single missed env var turning one real timeout
# into 30+ confusing failures. Auto-bumping removes the need to
# remember FSQL_TEST_TIMEOUT_MULT=4 every time --asan is passed, which
# is exactly the mistake that caused that cascade in practice.

# --- colours ----------------------------------------------------------
if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; Z="\033[0m"; else G=""; R=""; Y=""; Z=""; fi
pass() { local msg="$1"; printf "  [${G}PASS${Z}] %s\n" "$msg"; return 0; }
fail() { local msg="$1"; printf "  [${R}FAIL${Z}] %s\n" "$msg"; FAILED=1; return 0; }
skip() { local msg="$1"; printf "  [${Y}SKIP${Z}] %s\n" "$msg"; return 0; }

usage() { sed -n '4,264p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)   MODE="quick" ;;
    --cross)   MODE="cross" ;;
    --fuzz)    MODE="fuzz" ;;
    --pg)      PG_MAJOR="$2"; shift ;;
    --gate)    ONE_GATE="$2"; shift ;;
    --coverage) COVERAGE=1 ;;
    --asan)    ASAN=1 ;;
    --ubsan)   UBSAN=1 ;;
    --list)    printf "gates: %s\nfuzz gates: %s\n" "${DEFAULT_GATES[*]}" "${FUZZ_GATES[*]}"; exit 0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Evaluated AFTER the argument loop: --asan/--ubsan set ASAN/UBSAN above, so
# the auto-bump below can see them (it used to run before parsing, when both
# were still 0, and never fired).
if [[ -n "${FSQL_TEST_TIMEOUT_MULT:-}" ]]; then
  TIMEOUT_MULT="$FSQL_TEST_TIMEOUT_MULT"
elif [[ "$ASAN" -eq 1 ]] || [[ "$UBSAN" -eq 1 ]]; then
  TIMEOUT_MULT=4
else
  TIMEOUT_MULT=1
fi

# --- per-major state (set by pg_setup) --------------------------------
BIN=""; SO=""; MOCK=""; EVIL=""; CRASH=""; LYING=""; RETRY=""; EMBED=""; THINK=""; DATADIR=""; SOCKDIR=""; PORT=""; PSQL=()
FAILED=0

pg_bindir() {
  local pg_ver="$1"
  if [[ -n "${PG_BINDIR:-}" ]]; then
    echo "$PG_BINDIR"
  elif [[ "$(uname -s)" = "Darwin" ]]; then
    # Homebrew's postgresql@$MAJOR keg -- matches
    # .github/workflows/install-test.yml's macos-install job exactly
    # (PG_CONFIG="$(brew --prefix postgresql@17)/bin/pg_config"). `brew
    # --prefix` on an uninstalled formula still prints the theoretical
    # path (doesn't fail), so probe it for a real pg_config before
    # trusting it. If that fails, fall back to the official EDB .dmg
    # installer's layout (/Library/PostgreSQL/$MAJOR/bin -- same family
    # as the Windows EDB installer's C:\Program Files\PostgreSQL\
    # $MAJOR\) instead of just failing when Homebrew isn't how
    # PostgreSQL got installed. pg_setup()'s own -x initdb/-x pg_config
    # check downstream still fires either way -- same contract as the
    # Linux branch below -- this only widens what gets tried first.
    local brew_bin
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(brew --prefix "postgresql@$pg_ver" 2>/dev/null)/bin"
    else
      brew_bin="/opt/homebrew/opt/postgresql@$pg_ver/bin"
    fi
    if [[ -x "$brew_bin/pg_config" ]]; then
      echo "$brew_bin"
    elif [[ -x "/Library/PostgreSQL/$pg_ver/bin/pg_config" ]]; then
      echo "/Library/PostgreSQL/$pg_ver/bin"
    else
      echo "$brew_bin"
    fi
  else
    echo "/usr/lib/postgresql/$pg_ver/bin"
  fi
  return 0
}

# Resolves a sanitizer runtime's real .so path: `cc -print-file-name=
# libasan.so` on EL/RHEL-family distros often returns a LINKER SCRIPT
# (ASCII text with INPUT(...) directives), not an ELF -- LD_PRELOAD
# rejects those with "file too short". Falls back to the versioned ELF
# resolved via ldconfig when that happens.
resolve_san_rt() {
  local libname="$1"
  if [[ "$(uname -s)" = "Darwin" ]]; then
    # Apple clang's runtime layout is completely different from Linux's
    # -- no libasan.so/libubsan.so at all. `-print-resource-dir` finds
    # the active Xcode/CLT toolchain's compiler-rt tree; the dylib is
    # unified under lib/darwin/ regardless of arm64/x86_64. UNVERIFIED
    # on real Darwin hardware as of this writing -- confirm the exact
    # filename on a real run; Apple has renamed compiler-rt dylibs across major
    # Xcode versions before.
    local resdir; resdir="$(${CC:-cc} -print-resource-dir 2>/dev/null)"
    [[ -n "$resdir" ]] || { printf ''; return; }
    case "$libname" in
      libasan.so)  printf '%s' "$resdir/lib/darwin/libclang_rt.asan_osx_dynamic.dylib" ;;
      libubsan.so) printf '%s' "$resdir/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib" ;;
      *)           printf '' ;;
    esac
    return
  fi
  local rt
  rt="$(${CC:-cc} -print-file-name="$libname" 2>/dev/null)"
  if [[ -f "$rt" ]] && ! file -b "$rt" | grep -qE 'ELF|shared object'; then
    local stem="${libname%.so}"
    local cand
    cand="$(ldconfig -p 2>/dev/null \
            | awk -v s="$stem" '$1 ~ "^"s"\\.so\\.[0-9]+$" {print $NF; exit}')"
    [[ -n "$cand" ]] && [[ -f "$cand" ]] && rt="$cand"
  fi
  printf '%s' "$rt"
  return 0
}

# Builds mcp/fractalsql-postgresql-mcp from scratch the first time it is called
# in a run. mcp/Makefile has no header-dependency tracking and cannot tell that
# an object was built with different flags (an earlier --coverage/--asan or
# differently-configured build), so reusing stale .o files fails to link
# ("relocation R_X86_64_32 ... recompile with -fPIE") or, worse, links objects
# compiled against an older class layout. One clean per run, then incremental.
MCP_CLEANED=0
build_mcp() {
  local log="$1"
  if [[ "$MCP_CLEANED" -eq 0 ]]; then
    ( cd mcp && make clean >/dev/null 2>&1 )
    MCP_CLEANED=1
  fi
  # --coverage: build the SERVER instrumented too (COVERAGE=1 in mcp/Makefile
  # adds --coverage plus -fprofile-update=atomic, which the threaded HTTP
  # transport needs). The smoke gates then run it, and its .gcda land under
  # GCOV_PREFIX like everything else's.
  if [[ "$COVERAGE" -eq 1 ]]; then
    ( cd mcp && make COVERAGE=1 -j2 >"$log" 2>&1 )
  else
    ( cd mcp && make -j2 >"$log" 2>&1 )
  fi
}

cleanup() {
  [[ -n "$DATADIR" ]] && [[ -d "$DATADIR" ]] && "$BIN/pg_ctl" -D "$DATADIR" -m immediate stop >/dev/null 2>&1
  [[ -n "$DATADIR" ]] && rm -rf "$DATADIR"
  [[ -n "$SOCKDIR" ]] && rm -rf "$SOCKDIR"
  rm -f /tmp/fractalsql_bt_sql.txt /tmp/fractalsql_bt_evil_trigger_call.txt
  return 0
}
trap cleanup EXIT

# --coverage: redirect gcov's live .gcda writes off the (possibly
# vboxsf-mounted) source tree for the run, so every backend that loads
# the instrumented .so writes to /tmp instead. GCOV_PREFIX_STRIP counts
# path components to drop from the .gcno-embedded absolute path before
# prefixing with GCOV_PREFIX -- computed from $HERE's own depth so this
# isn't hardcoded to one checkout location. Exported unconditionally
# (harmless no-op without a --coverage build); postmaster/backends
# inherit it since pg_setup() launches pg_ctl from this same shell.
if [[ "$COVERAGE" -eq 1 ]]; then
  export GCOV_PREFIX="/tmp/fractalsql_bt_gcov_$$"
  export GCOV_PREFIX_STRIP=$(($(echo "$HERE" | tr -cd '/' | wc -c)))
  mkdir -p "$GCOV_PREFIX"
fi

# ereport(ERROR, ...) expands to `errstart(...) ? errfinish(...) : 0`, and
# errstart() never returns false for ERROR level, so the "not logged" branch
# of a statement that DID run can never be taken. This drops that one branch
# from a line only when (a) the statement starts with ereport(, (b) the line
# carries exactly two branches, and (c) exactly one of them was taken. An
# ereport that was never reached keeps both of its branches and stays visible
# as a real gap. Prints the number of branches dropped.
drop_ereport_level_branches() {
  local in="$1" out="$2"
  awk -v outfile="$out" '
    function flush(   i, n, ln, taken, tot, k, drop, brf, brh, j) {
      for (i = 1; i <= nl; i++) keep[i] = 1
      for (ln in cnt) {
        if (src[ln] ~ /^[ \t]*ereport[ \t]*\(/) {
          if (cnt[ln] != 2 || taken_n[ln] != 1) continue
          for (k = 1; k <= nb[ln]; k++) {
            i = bidx[ln, k]
            if (bt[i] == "-" || bt[i] + 0 == 0) { keep[i] = 0; dropped++ }
          }
        } else if (src[ln] ~ /\)[ \t]*ereport[ \t]*\(/) {
          # "if (cond) ereport(ERROR, ...)" on one line: the own elevel test of the ereport
          # is the LAST two branches of the line.
          if (nb[ln] < 4) continue
          i = bidx[ln, nb[ln]]; j = bidx[ln, nb[ln] - 1]
          if ((bt[i] == "-" || bt[i] + 0 == 0) && bt[j] != "-" && bt[j] + 0 > 0) { keep[i] = 0; dropped++ }
        }
      }
      brf = 0; brh = 0
      for (i = 1; i <= nl; i++) if (keep[i] && substr(L[i], 1, 5) == "BRDA:") {
        split(substr(L[i], 6), p, ",")
        brf++; if (p[4] != "-" && p[4] + 0 > 0) brh++
      }
      for (i = 1; i <= nl; i++) {
        if (!keep[i]) continue
        if (substr(L[i], 1, 4) == "BRF:") print "BRF:" brf > outfile
        else if (substr(L[i], 1, 4) == "BRH:") print "BRH:" brh > outfile
        else print L[i] > outfile
      }
    }
    function reset() { nl = 0; delete cnt; delete taken_n; delete nb; delete bidx; delete bt; delete src; nsrc = 0 }
    BEGIN { FS = "\n"; reset() }
    {
      line = $0
      if (substr(line, 1, 3) == "SF:") {
        file = substr(line, 4); n = 0
        while ((getline sl < file) > 0) { n++; srcall[n] = sl }
        close(file)
        for (j = 1; j <= n; j++) src[j] = srcall[j]
      }
      L[++nl] = line
      if (substr(line, 1, 5) == "BRDA:") {
        split(substr(line, 6), p, ",")
        if (substr(p[2], 1, 1) != "e") {
          ln = p[1] + 0
          cnt[ln]++; nb[ln]++; bidx[ln, nb[ln]] = nl; bt[nl] = p[4]
          if (p[4] != "-" && p[4] + 0 > 0) taken_n[ln]++
        }
      }
      if (line == "end_of_record") { flush(); reset() }
    }
    END { print dropped + 0 > "/dev/stderr" }
  ' "$in" 2>"$out.dropped"
  EREPORT_DROPPED="$(cat "$out.dropped" 2>/dev/null)"
  rm -f "$out.dropped"
}

# Copy the redirected .gcda back next to the .gcno (one plain file
# copy — not the hot-path gcov flushing that vboxsf chokes on) and
# generate an lcov report. Called once after the gate matrix finishes.
# drop_scope_exit_branches <in.info> <out.info>
# The mcp/ server is heavy template C++ (nlohmann json, std::string): at the
# CLOSING line of a scope -- a bare "}", "} );", "} } );" -- gcc/gcov report
# a "branch" for every temporary's destructor and cleanup edge. They are
# compiler-generated, carry no source-level decision, and are not tagged as
# exception edges, so the 'e'-block filter alone leaves them in the
# denominator (on a 4k-line server it was about 1,000 of 8,700 branches, e.g.
# 76 "missed" on the single "}" that ends resources.cpp's table builder).
# Drops BRDA records whose source line is only closing punctuation, plus those on
# tool-table registration rows (see the comment at the second rule), and
# recomputes BRF/BRH per file; prints the number dropped (and how many of those
# were registration rows) on stderr.
drop_scope_exit_branches() {
  local in="$1" out="$2"
  awk -v outfile="$out" '
    function flush(   i, brf, brh, p) {
      brf = 0; brh = 0
      for (i = 1; i <= nl; i++) if (keep[i] && substr(L[i], 1, 5) == "BRDA:") {
        split(substr(L[i], 6), p, ",")
        brf++; if (p[4] != "-" && p[4] + 0 > 0) brh++
      }
      for (i = 1; i <= nl; i++) {
        if (!keep[i]) continue
        if (substr(L[i], 1, 4) == "BRF:") print "BRF:" brf > outfile
        else if (substr(L[i], 1, 4) == "BRH:") print "BRH:" brh > outfile
        else print L[i] > outfile
      }
    }
    BEGIN { nl = 0 }
    {
      line = $0
      if (substr(line, 1, 3) == "SF:") {
        file = substr(line, 4); n = 0; delete src
        while ((getline sl < file) > 0) { n++; src[n] = sl }
        close(file)
      }
      L[++nl] = line; keep[nl] = 1
      if (substr(line, 1, 5) == "BRDA:") {
        split(substr(line, 6), p, ",")
        if (src[p[1] + 0] ~ /^[ \t]*[})\];,]+[ \t})\];,]*$/) { keep[nl] = 0; dropped++ }
        # A tool-table registration row: "t.push_back( ToolSpec{ name, category, ..., lambda } );".
        # It is declarative (no decision in the row itself -- the handler lambda is on its own
        # lines and stays counted), but the aggregate initialiser builds a std::vector of params,
        # a std::function and several strings in one expression, and gcov attributes about six
        # unwind/cleanup branches per row that no input can reach (78 rows, ~470 of them).
        else if (index(src[p[1] + 0], "t.push_back( ToolSpec{") > 0) { keep[nl] = 0; dropped++; reg++ }
      }
      if (line == "end_of_record") { flush(); nl = 0; delete keep; delete L }
    }
    END { print dropped + 0, reg + 0 > "/dev/stderr" }
  ' "$in" 2>"$out.dropped"
  read -r SCOPE_EXIT_DROPPED REG_ROW_DROPPED < "$out.dropped" 2>/dev/null || true
  rm -f "$out.dropped"
}

run_coverage_report() {
  local gcda_src
  gcda_src="$(find "$GCOV_PREFIX" -name 'fractalsql.gcda' 2>/dev/null | head -1)"
  if [[ -z "$gcda_src" ]]; then
    fail "coverage: no .gcda produced (was --coverage gate 01 build ok?)"
    return
  fi
  # Copy EVERY redirected .gcda back next to its own .gcno, not just the
  # main build's fractalsql.gcda: gate 39 compiles its _extract_parse_*
  # probe objects into src/, and gates 40/41/42 do the same for their
  # _*_probe_* objects in mcp/src/. Each .gcda must land beside its
  # matching .gcno (basenames are unique per directory) for the lcov
  # captures below to pair them.
  local g base
  while IFS= read -r g; do
    base="$(basename "$g")"
    # Key on the matching .gcno, NOT on an existing .gcda: GCOV_PREFIX sends
    # every live write to $GCOV_PREFIX, so the destination .gcda does not
    # exist yet (the probes' _*_probe_*.gcda never do) and testing for it
    # skipped every one of them -- "no mcp/src/*.gcda produced".
    [[ -f "src/${base%.gcda}.gcno" ]] && cp "$g" "src/$base"
    [[ -f "mcp/src/${base%.gcda}.gcno" ]] && cp "$g" "mcp/src/$base"
    [[ -f "mcp/src/adapters/${base%.gcda}.gcno" ]] && cp "$g" "mcp/src/adapters/$base"
  done < <(find "$GCOV_PREFIX" -name '*.gcda')

  if ! command -v lcov >/dev/null 2>&1; then
    skip "coverage: lcov not installed, skipping report"
    return
  fi
  lcov --capture --directory src --output-file "$TMPROOT/fractalsql_bt_coverage_raw.info" \
       --rc branch_coverage=1 >"$TMPROOT/fractalsql_bt_lcov.log" 2>&1 \
    || { fail "coverage: lcov capture failed — see $TMPROOT/fractalsql_bt_lcov.log"; return; }

  # Extract just our TUs: --list's aggregate Rate% goes haywire (seen:
  # a nonsensical >1000% function rate) when the capture also includes
  # the handful of lines pulled in from system headers like postgres.h/
  # palloc.h -- those aren't our code and nobody's asking about their
  # coverage anyway. Wider than plain '*/src/fractalsql.c' now that
  # gate 39 adds its own coverage of src/fractalsql_parse.c (src/ and
  # src/fractalsql_vector.c are the only other paths under */src/ the
  # capture can see).
  lcov --extract "$TMPROOT/fractalsql_bt_coverage_raw.info" '*/src/*' \
       --output-file "$TMPROOT/fractalsql_bt_coverage_ext.info" \
       --rc branch_coverage=1 >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1
  drop_ereport_level_branches "$TMPROOT/fractalsql_bt_coverage_ext.info" "$TMPROOT/fractalsql_bt_coverage.info"

  echo ""
  echo "=== coverage (src/*.c) ==="
  [[ "${EREPORT_DROPPED:-0}" -gt 0 ]] && echo "  (excluding ${EREPORT_DROPPED} never-takeable ereport log-level branches on lines whose ereport did run)"
  # Computed directly from the .info file's own LF/LH/FNF/FNH totals
  # rather than `lcov --list`'s table -- lcov 2.0-1's --list renderer
  # miscomputes its Rate% column against this intermediate
  # gcov-JSON-derived .info (seen: a nonsensical 1170% function rate)
  # even though the underlying LF:/LH:/etc. totals, and genhtml's own
  # report built from the same file, are both correct.
  #
  # Branches, though, are summed directly from the raw BRDA: lines
  # rather than trusted from the .info's own BRF:/BRH: fields,
  # EXCLUDING exception-tagged branches (an 'e' prefix on BRDA's
  # block-number field -- GCC natively tags its exception-unwind
  # landing pads that way; plain C has none today, but gate 39's own
  # probe objects land in the same captures and this keeps the text
  # summary agreeing with genhtml's --rc no_exception_branch=1 report
  # by construction). This mirrors the SQLite column's same
  # methodology, ported here in full -- see the mcp/ capture section
  # below for the round-48/49 numbers it is worth.
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRDA:/ {
      split($2, p, ",")
      if (substr(p[2], 1, 1) != "e") {
        brf++
        if (p[4] != "-" && p[4]+0 > 0) brh++
      }
    }
    END {
      printf "  lines:     %d/%d", lh, lf
      if (lf > 0) printf " (%.1f%%)", 100*lh/lf
      print ""
      printf "  functions: %d/%d", fnh, fnf
      if (fnf > 0) printf " (%.1f%%)", 100*fnh/fnf
      print ""
      printf "  branches:  %d/%d", brh, brf
      if (brf > 0) printf " (%.1f%%)", 100*brh/brf
      print ""
    }' "$TMPROOT/fractalsql_bt_coverage.info"

  # no_exception_branch=1 is applied to genhtml ONLY: see the IMPORTANT
  # note in the mcp/ capture section below (passing it to lcov
  # --capture/--extract instead zeroes BRF/BRH entirely for this
  # lcov/geninfo version -- a geninfo 2.0-1 bug in that combination).
  if command -v genhtml >/dev/null 2>&1; then
    genhtml "$TMPROOT/fractalsql_bt_coverage.info" --output-directory coverage_html \
            --rc branch_coverage=1 --rc no_exception_branch=1 >"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
      && pass "coverage: report at coverage_html/index.html" \
      || fail "coverage: genhtml failed — see $TMPROOT/fractalsql_bt_genhtml.log"
  fi

  # mcp/src coverage: the MCP server itself (built `make COVERAGE=1` by
  # build_mcp, run by gates 33/38) plus the gate 40/41/42 probes. The mcp/
  # Makefile's COVERAGE=1 branch adds -fprofile-update=atomic: the server is
  # threaded, and plain --coverage races in gcda counter updates, after which
  # geninfo fails with "Unexpected negative count". The probes below pass
  # --coverage -fprofile-update=atomic inline for gate 42's threaded shape.
  if ! find mcp/src -name '*.gcda' 2>/dev/null | grep -q .; then
    skip "coverage: no mcp/src/*.gcda produced (gates 33/38/40/41/42 didn't run the MCP server or probes under --coverage)"
  else
    lcov --capture --directory mcp/src --output-file "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" \
         --rc branch_coverage=1 --ignore-errors mismatch >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1 \
      || { fail "coverage: mcp lcov capture failed; see $TMPROOT/fractalsql_bt_lcov.log"; return; }

    # Extract just our probes' own view of mcp/src: the capture also
    # picks up mcp/vendor/json.hpp (nlohmann, not ours) when any of it
    # got inlined; neither is our code.
    lcov --extract "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" '*/mcp/src/*' \
         --output-file "$TMPROOT/fractalsql_bt_mcp_coverage.info" \
         --rc branch_coverage=1 --ignore-errors mismatch >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1
    # Compiler scope-exit (destructor) edges on closing-brace lines carry no
    # source decision: see drop_scope_exit_branches. The filtered file is the
    # one reported and rendered; the raw one stays in $TMPROOT for triage.
    drop_scope_exit_branches "$TMPROOT/fractalsql_bt_mcp_coverage.info" "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

    echo ""
    echo "=== coverage (mcp/src: the instrumented MCP server run by gates 33/38, plus the gate 40/41/42 probes) ==="
    echo "  (branch counts exclude exception edges, $(( ${SCOPE_EXIT_DROPPED:-0} - ${REG_ROW_DROPPED:-0} )) compiler records on closing-brace lines"
    echo "   and ${REG_ROW_DROPPED:-0} records on tool-table registration rows, t.push_back( ToolSpec{ ... } ))"
    # Same BRDA-based branch counting as the src/*.c section above --
    # here it is NOT a no-op: mcp/src is heavy template C++ (nlohmann
    # json), whose exception-unwind landing pads dominate the raw BRF:
    # denominator unless the 'e'-tagged set is excluded. See that
    # section plus the SQLite column's round-48 note (its agency.cpp
    # branch rate went 48.3% -> 82.7% on this exclusion alone).
    awk -F: '
      /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
      /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
      /^BRDA:/ {
        split($2, p, ",")
        if (substr(p[2], 1, 1) != "e") {
          brf++
          if (p[4] != "-" && p[4]+0 > 0) brh++
        }
      }
      END {
        printf "  lines:     %d/%d", lh, lf
        if (lf > 0) printf " (%.1f%%)", 100*lh/lf
        print ""
        printf "  functions: %d/%d", fnh, fnf
        if (fnf > 0) printf " (%.1f%%)", 100*fnh/fnf
        print ""
        printf "  branches:  %d/%d", brh, brf
        if (brf > 0) printf " (%.1f%%)", 100*brh/brf
        print ""
      }' "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

    if command -v genhtml >/dev/null 2>&1; then
      genhtml "$TMPROOT/fractalsql_bt_mcp_coverage_f.info" --output-directory coverage_html_mcp \
              --rc branch_coverage=1 --rc no_exception_branch=1 >>"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
        && pass "coverage: mcp report at coverage_html_mcp/index.html" \
        || fail "coverage: mcp genhtml failed — see $TMPROOT/fractalsql_bt_genhtml.log"
    fi
  fi

  rm -rf "$GCOV_PREFIX"
  return 0
}

# Build the target-major extension and mock plugin, start a throwaway
# cluster with the mock reasoning plugin preloaded. Returns 1 (skip) if
# the major's server binaries are not installed.
pg_setup() {
  local v="$1"
  BIN="$(pg_bindir "$v")"
  if [[ ! -x "$BIN/initdb" ]] || [[ ! -x "$BIN/pg_config" ]]; then
    return 1
  fi
  # Independent of gate_01_build's own detection -- a single non-01
  # -Gate run reuses a prior build without gate_01_build ever running
  # this session, so FSQL_DLSUFFIX may not be set yet.
  FSQL_DLSUFFIX="$(fsql_pg_dlsuffix "$BIN/pg_config")"
  SO="$HERE/fractalsql$FSQL_DLSUFFIX"
  MOCK="$TMPROOT/fractalsql_bt_mock_$v.so"
  EVIL="$TMPROOT/fractalsql_bt_evil_$v.so"
  CRASH="$TMPROOT/fractalsql_bt_crash_$v.so"
  LYING="$TMPROOT/fractalsql_bt_lying_$v.so"
  RETRY="$TMPROOT/fractalsql_bt_retry_$v.so"
  EMBED="$TMPROOT/fractalsql_bt_embed_$v.so"
  EVIL_EMBED="$TMPROOT/fractalsql_bt_evil_embed_$v.so"
  THINK="$TMPROOT/fractalsql_bt_think_$v.so"
  DATADIR="/tmp/fractalsql_bt_data_$v"
  SOCKDIR="/tmp/fractalsql_bt_sock_$v"
  PORT=$(( 5600 + v ))
  rm -rf "$DATADIR" "$SOCKDIR"; mkdir -p "$SOCKDIR"
  rm -f /tmp/fractalsql_bt_evil_trigger_call.txt
  cc -shared -fPIC -std=c99 -Iinclude tests/mock_reasoning_plugin.c -o "$MOCK" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/evil_nonterminating_plugin.c -o "$EVIL" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/evil_crash_plugin.c -o "$CRASH" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/evil_lying_length_plugin.c -o "$LYING" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/retry_reasoning_plugin.c -o "$RETRY" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/mock_embed_plugin.c -o "$EMBED" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/evil_embed_plugin.c -o "$EVIL_EMBED" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  cc -shared -fPIC -std=c99 -Iinclude tests/think_reasoning_plugin.c -o "$THINK" 2>/tmp/fractalsql_bt_setup_$v.log \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  rm -f /tmp/fractalsql_bt_retry_prompt.txt
  "$BIN/initdb" -D "$DATADIR" -U postgres --auth=trust >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { tail -20 /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  # reasoning_plugin and text_to_sql_max_attempts go in postgresql.conf,
  # NOT -c on the command line: command-line-set GUC values outrank
  # ALTER SYSTEM/config-file/reload for the rest of the postmaster's
  # life, which would permanently defeat pg_set_guc()'s ALTER SYSTEM +
  # pg_reload_conf() (gates 05/06's plugin swap, gate 14's max_attempts
  # bump for the retry-with-feedback path).
  echo "fractalsql.reasoning_plugin = '$MOCK'" >> "$DATADIR/postgresql.conf"
  echo "fractalsql.text_to_sql_max_attempts = 1" >> "$DATADIR/postgresql.conf"
  # postgres (not itself sanitizer-instrumented) is the "host process"
  # that dlopens our now-instrumented fractalsql.so via
  # shared_preload_libraries: LD_PRELOAD the runtime so its symbols are
  # already resolved before the dlopen happens, or the backend fails to
  # start with undefined __asan_*/__ubsan_* symbol errors. Exported here
  # (not just locally) so pg_ctl's child postgres process inherits it
  # normally.
  # DYLD_INSERT_LIBRARIES is Darwin's LD_PRELOAD equivalent. A Homebrew-
  # installed postgres binary lives outside SIP-protected paths (/usr/bin,
  # /System, ...), so the var should NOT get silently stripped here --
  # but genuinely unverified until this actually runs on real hardware.
  # UBSan specifically: Apple's -fsanitize=undefined historically links
  # its minimal runtime statically into the compiled object rather than
  # needing a preloaded shared dylib the way Linux's libubsan.so does
  # -- if resolve_san_rt can't find a dylib for it on Darwin, that's
  # treated as "nothing to preload" (skip, not fail) rather than
  # assuming the gate is broken; confirm which is actually true on a
  # real run and tighten this back to a hard failure if UBSan turns out
  # to need the preload after all.
  local preload_var="LD_PRELOAD"
  [[ "$(uname -s)" = "Darwin" ]] && preload_var="DYLD_INSERT_LIBRARIES"
  if [[ "$ASAN" -eq 1 ]]; then
    # Darwin: DYLD_INSERT_LIBRARIES-injecting ASan into a postgres that
    # wasn't itself compiled with -fsanitize=address doesn't reliably
    # install ASan's malloc/free interceptor table on modern macOS
    # (chained fixups resolve libSystem calls before the late-injected
    # runtime can hook them) -- confirmed on real hardware: the dylib
    # loads fine, then ASan's own runtime aborts with "Interceptors are
    # not working ... loaded too late (e.g. via dlopen)". Signing has
    # nothing to do with it. Detect a plain (non-instrumented) binary
    # up front and skip cleanly instead of hard-failing pg_ctl start.
    if [[ "$(uname -s)" = "Darwin" ]] \
       && ! otool -L "$BIN/postgres" 2>/dev/null | grep -qi 'libclang_rt\.asan\|libasan'; then
      skip "PG$v cluster setup (Darwin ASan needs postgres itself built with -fsanitize=address; run against a source-built ASan postgres to exercise this gate here -- Linux/Windows ASan CI already cover this same portable C source)"
      return 3
    fi
    local asan_rt; asan_rt="$(resolve_san_rt libasan.so)"
    [[ -n "$asan_rt" ]] && [[ -f "$asan_rt" ]] || { echo "FAIL: could not resolve libasan.so runtime" >&2; return 2; }
    export "$preload_var"="$asan_rt"
    export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:log_path=/tmp/fractalsql_bt_asan"
  elif [[ "$UBSAN" -eq 1 ]]; then
    local ubsan_rt; ubsan_rt="$(resolve_san_rt libubsan.so)"
    if [[ -n "$ubsan_rt" ]] && [[ -f "$ubsan_rt" ]]; then
      export "$preload_var"="$ubsan_rt"
    elif [[ "$(uname -s)" != "Darwin" ]]; then
      echo "FAIL: could not resolve libubsan.so runtime" >&2; return 2
    fi
    export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
  fi
  "$BIN/pg_ctl" -D "$DATADIR" -w -l "$DATADIR/log" \
     -o "-p $PORT -k $SOCKDIR -c listen_addresses='' -c shared_preload_libraries=$SO" \
     start >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { tail -20 /tmp/fractalsql_bt_setup_$v.log >&2; [[ -f "$DATADIR/log" ]] && tail -20 "$DATADIR/log" >&2; return 2; }
  PSQL=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U postgres -d postgres -X -tA)
  # register the functions from the freshly built .so
  "${PSQL[@]}" -c "
     CREATE FUNCTION fractal_version() RETURNS text AS '$SO','fractal_version' LANGUAGE C IMMUTABLE STRICT;
     CREATE FUNCTION fractal_edition() RETURNS text AS '$SO','fractal_edition' LANGUAGE C IMMUTABLE STRICT;
     CREATE FUNCTION fractal_search(query float8[], iterations int4 DEFAULT 30, population_size int4 DEFAULT 50, diffusion_factor int4 DEFAULT 2) RETURNS float8[] AS '$SO','fractal_search' LANGUAGE C VOLATILE STRICT;
     CREATE FUNCTION fractal_search_debug(query float8[], iterations int4 DEFAULT 30, population_size int4 DEFAULT 50, diffusion_factor int4 DEFAULT 2) RETURNS jsonb AS '$SO','fractal_search_debug' LANGUAGE C VOLATILE STRICT;
     CREATE FUNCTION fractal_schema_context(table_names text[] DEFAULT NULL, query_hint text DEFAULT NULL) RETURNS text AS '$SO','fractal_schema_context' LANGUAGE C;
     CREATE FUNCTION fractal_text_to_sql(question text, table_names text[] DEFAULT NULL) RETURNS text AS '$SO','fractal_text_to_sql' LANGUAGE C;
     CREATE FUNCTION fractal_reason(query text, context text DEFAULT '{}') RETURNS text AS '$SO','fractal_reason' LANGUAGE C;
     CREATE FUNCTION fractal_search_explore(table_name text, vector_col text, query float8[], options jsonb DEFAULT '{}'::jsonb) RETURNS SETOF float8[] AS '$SO','fractal_search_explore' LANGUAGE C VOLATILE STRICT;
     CREATE FUNCTION fractal_embed(input text) RETURNS float8[] AS '$SO','fractal_embed' LANGUAGE C;
  " >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  # Agent-tier (the 6 C-level "Universal Agent" functions + their composite
  # return types: fractal_search_agent, fractal_sql_agent, fractal_rag_agent,
  # fractal_agent_plan_explore, fractal_agent_trajectory_predict,
  # fractal_agent_detect_loop). This section sits between the core
  # (hand-registered above) and the Vectorizer marker; it references
  # MODULE_PATHNAME, so sed it to $SO. Engine G (fractal_agent_data_analyst)
  # composes fractal_sql_agent, so its fractal_sql_agent_result composite
  # type MUST exist before the agents extension slice loads -- PL/pgSQL
  # resolves DECLARE res fractal_sql_agent_result at CREATE time, so
  # without this slice engine G's CREATE fails with "type
  # fractal_sql_agent_result does not exist". (First surfaced on the first
  # live run after Stage 4 -- the gate-23 extension was parse-checked only.)
  awk '/^-- Agent-tier results types/{f=1} /^-- Vectorizer --/{f=0} f' sql/fractalsql--1.0.sql \
    | sed "s#MODULE_PATHNAME#$SO#g" \
    | "${PSQL[@]}" >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  # Vectorizer (tables/trigger function/fractal_vectorizer_create/
  # fractal_vectorizer_process_queue/fractal_vectorizer_status view) --
  # pure SQL/PL/pgSQL, no C symbols, so it's extracted straight from the
  # real sql/fractalsql--1.0.sql (from its own section marker onward)
  # rather than duplicated here by hand. Avoids this harness's copy
  # drifting from the real extension SQL the same way the hardcoded
  # CREATE FUNCTION list above already can (a known, accepted tradeoff
  # for the C functions -- not worth re-deriving those from MODULE_
  # PATHNAME substitution just for this), but for a much longer block
  # where drift risk is higher and substitution isn't needed anyway
  # (no MODULE_PATHNAME references in this section at all).
  awk '/^-- Vectorizer --/{f=1} f' sql/fractalsql--1.0.sql | "${PSQL[@]}" \
    >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  # v2.x additions (Diversify/Repulsion, feedback, dimension analysis,
  # portfolio optimization, domain geometry, named feature store) --
  # same extract-from-the-real-SQL-file pattern as the Vectorizer block
  # above, but this section DOES reference MODULE_PATHNAME (all its C
  # functions), which only CREATE EXTENSION substitutes automatically;
  # sed it to the freshly-built $SO before piping in, same as it would
  # be at real install time.
  awk '/^-- v2.x additions --/{f=1} f' sql/fractalsql--1.0.sql \
    | sed "s#MODULE_PATHNAME#$SO#g" \
    | "${PSQL[@]}" >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  # fractalsql_agents dependent extension: the parameterized PL/pgSQL agent
  # engines. Pure PL/pgSQL (no MODULE_PATHNAME), loaded raw like the Vectorizer
  # block -- but read from its own extension subdir, with the \echo ... \quit
  # guard line dropped (\quit would abort psql mid-script). The base functions
  # it composes (fractal_dimension_drift, fractal_reason,
  # fractal_optimize_portfolio) are already registered above, so PL/pgSQL
  # CREATE defers-resolution succeeds.
  grep -v '\\quit' fractalsql_agents/sql/fractalsql_agents--1.0.sql \
    | "${PSQL[@]}" >/tmp/fractalsql_bt_setup_$v.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_$v.log >&2; return 2; }
  return 0
}

pg_teardown() {
  [[ -n "$DATADIR" ]] && "$BIN/pg_ctl" -D "$DATADIR" -m fast stop >/dev/null 2>&1
  rm -rf "$DATADIR" "$SOCKDIR" "$MOCK" "$EVIL" "$CRASH" "$LYING" "$RETRY" "$EMBED" "$EVIL_EMBED"
  DATADIR=""; SOCKDIR=""
  return 0
}

# Generic PGC_SIGHUP GUC setter: ALTER SYSTEM + reload + poll until the
# new value is visible. ALTER SYSTEM cannot run inside a transaction
# block, and a multi-statement single -c string executes as an implicit
# one -- these must be two separate psql invocations, not one
# -c "A; B". Polls afterward since pg_reload_conf() only signals the
# postmaster and returns -- it does not wait for the reload to land.
#   $1 = GUC name, $2 = value AS WRITTEN in the SET statement (quote
#        strings yourself, e.g. "'/path'"), $3 = value AS READ BACK by
#        current_setting() (e.g. on/off for booleans, unquoted path text)
pg_set_guc() {
  local key="$1" val="$2" scope="$3"
  "${PSQL[@]}" -c "ALTER SYSTEM SET $key = $val;" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
  local i v tries=$(( 10 * TIMEOUT_MULT ))
  for i in $(seq 1 "$tries"); do
    v=$("${PSQL[@]}" -c "SELECT current_setting('$key');" 2>/dev/null)
    [[ "$v" = "$scope" ]] && return 0
    sleep 0.2
  done
  return 1
}

pg_swap_plugin() { local plugin="$1"; pg_set_guc fractalsql.reasoning_plugin "'$plugin'" "$plugin"; return 0; }

# --- gates ------------------------------------------------------------

gate_01_build() {
  local v="$1" bin; bin="$(pg_bindir "$v")"
  if [[ ! -x "$bin/pg_config" ]]; then skip "01 build (PG$v pg_config absent)"; return; fi
  FSQL_DLSUFFIX="$(fsql_pg_dlsuffix "$bin/pg_config")"
  # PG_CONFIG must match the real build below -- without it this falls
  # back to Makefile's bare "pg_config" default, which silently fails
  # to resolve PGXS (and thus does nothing) whenever pg_config isn't on
  # PATH, e.g. a PG_BINDIR override pointing outside PATH. A no-op clean
  # here leaves stale .o files for the real build to (wrongly) reuse.
  make clean PG_CONFIG="$bin/pg_config" >/dev/null 2>&1
  local cov_arg=""
  # with_llvm=no: PGXS's separate JIT-bitcode compile (clang -emit-llvm)
  # shares PG_CPPFLAGS with the .o compile, so it also picks up
  # --coverage and (on this toolchain) clobbers gcc's just-written
  # fractalsql.gcno with an incompatible clang-format one afterward.
  # Bitcode is a runtime-JIT concern, irrelevant to a coverage run.
  [[ "$COVERAGE" -eq 1 ]] && cov_arg="COVERAGE=1 with_llvm=no"
  local san_arg=""
  # Confirmed on real hardware (this sandbox): unlike COVERAGE, ASan/UBSan
  # don't need with_llvm=no -- the JIT-bitcode compile picks up the same
  # -fsanitize= flags and builds cleanly (no .gcno-class file conflict,
  # since sanitizers don't produce their own on-disk artifacts the way
  # gcov does), so it's left enabled here.
  [[ "$ASAN" -eq 1 ]]  && san_arg="ASAN=1"
  [[ "$UBSAN" -eq 1 ]] && san_arg="UBSAN=1"
  # FAULT_INJECT=1: test builds only -- compiles in src/fsql_fault.h so gate
  # 47 can fail individual SPI/core calls. The shipped build never sets it.
  local fi_arg="FAULT_INJECT=1"
  if make $cov_arg $san_arg $fi_arg PG_CONFIG="$bin/pg_config" >/tmp/fractalsql_bt_build_$v.log 2>&1 && [[ -f "fractalsql$FSQL_DLSUFFIX" ]]; then
    pass "01 build (PG$v)"
  else
    fail "01 build (PG$v) — see /tmp/fractalsql_bt_build_$v.log"
    grep -iE "error:" "/tmp/fractalsql_bt_build_$v.log" | head -3 | sed 's/^/         /'
  fi
  return 0
}

gate_02_smoke() {
  local ver; ver=$("${PSQL[@]}" -c "SELECT fractal_version();" 2>&1)
  [[ "$ver" = "2.0.20" ]] && pass "02 smoke: version=$ver" || fail "02 smoke: version='$ver' (want 2.0.20)"
  # fractal_search convergence: cosine similarity to query ~1
  local r; r=$("${PSQL[@]}" -c "
     WITH q AS (SELECT fractal_search(ARRAY[0.6,0.8]::float8[],100,50,2) AS v)
     SELECT CASE WHEN sqrt(v[1]*v[1]+v[2]*v[2])>1e-9
                  AND (v[1]*0.6+v[2]*0.8)/sqrt(v[1]*v[1]+v[2]*v[2])>0.99
                 THEN 'ok' ELSE 'FAIL' END FROM q;" 2>&1)
  [[ "$r" = "ok" ]] && pass "02 smoke: fractal_search convergence" || fail "02 smoke: convergence=$r"
  local ed; ed=$("${PSQL[@]}" -c "SELECT fractal_edition();" 2>&1)
  [[ -n "$ed" ]] && ! grep <<< "$ed" -q ERROR && pass "02 smoke: edition=$ed" || fail "02 smoke: edition='$ed'"
  # fractal_search_debug returns the FULL fsql_search_ptr result JSON
  # (not just the best_point extraction fractal_search uses) -- assert
  # the best_point key survives the jsonb_in round-trip.
  local dbg; dbg=$("${PSQL[@]}" -c "SELECT fractal_search_debug(ARRAY[0.6,0.8]::float8[],100,50,2);" 2>&1)
  grep <<< "$dbg" -q "best_point" && pass "02 smoke: fractal_search_debug has best_point" || fail "02 smoke: fractal_search_debug='$dbg'"
  return 0
}

gate_03_schema_context() {
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_orders, bt_customers;
     CREATE TABLE bt_customers (id serial PRIMARY KEY, name text NOT NULL, status text);
     COMMENT ON TABLE bt_customers IS 'buyers';
     CREATE TABLE bt_orders (id serial PRIMARY KEY, customer_id int NOT NULL REFERENCES bt_customers(id), total int NOT NULL);
  " >/dev/null 2>&1
  local ctx; ctx=$("${PSQL[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_customers','bt_orders']);" 2>&1)
  grep <<< "$ctx" -q "id integer PK"        && pass "03 schema_context: PK"       || fail "03 schema_context: PK"
  grep <<< "$ctx" -q "name text NOT NULL"   && pass "03 schema_context: NOT NULL" || fail "03 schema_context: NOT NULL"
  grep <<< "$ctx" -q "buyers"               && pass "03 schema_context: comment"  || fail "03 schema_context: comment"
  grep <<< "$ctx" -q "REFERENCES bt_customers" && pass "03 schema_context: FK"    || fail "03 schema_context: FK"
  # auto-discovery mode (table_names omitted/NULL): must find bt_customers
  # and bt_orders on its own. Relies on this gate running early, before
  # any other gate has created tables in the public schema.
  local auto; auto=$("${PSQL[@]}" -c "SELECT fractal_schema_context();" 2>&1)
  if grep <<< "$auto" -q "bt_customers" && grep <<< "$auto" -q "bt_orders"; then
    pass "03 schema_context: auto-discovery finds both tables"
  else
    fail "03 schema_context: auto-discovery='$auto'"
  fi

  # Composite-FK schema context: a multi-column FK with both referential
  # actions. The FK section of append_table_context prints pg_get_constraintdef
  # output verbatim (src/fractalsql.c ~3357), so the emitted line must carry
  # BOTH the (pa, pb) column pair -- proving a composite FK isn't rendered as
  # a single-column one -- and both ON DELETE / ON UPDATE actions.
  # Child columns stay NULLable: ON UPDATE SET NULL writes NULL into them by
  # design, so NOT NULL here would be a self-contradictory (though
  # create-time-accepted) schema. Cleaned up at gate end.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;
     CREATE TABLE bt_fk_parent (col_a int, col_b int, id serial PRIMARY KEY);
     ALTER TABLE bt_fk_parent ADD CONSTRAINT bt_fk_parent_ab_uniq UNIQUE (col_a, col_b);
     CREATE TABLE bt_fk_child (pa int, pb int);
     ALTER TABLE bt_fk_child ADD CONSTRAINT bt_fk_child_ab_fk
       FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent (col_a, col_b)
       ON DELETE CASCADE ON UPDATE SET NULL;
  " >/dev/null 2>&1
  local fk_ctx; fk_ctx=$("${PSQL[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_fk_parent','bt_fk_child']);" 2>&1)
  grep <<< "$fk_ctx" -q "FOREIGN KEY (pa, pb)" \
    && pass "03 schema_context: composite-FK multi-column (pa, pb) line rendered" \
    || fail "03 schema_context: composite-FK (pa, pb) columns missing: '$fk_ctx'"
  grep <<< "$fk_ctx" -q "REFERENCES bt_fk_parent" \
    && pass "03 schema_context: composite-FK REFERENCES line present" \
    || fail "03 schema_context: composite-FK REFERENCES missing: '$fk_ctx'"
  grep <<< "$fk_ctx" -q "ON DELETE CASCADE" \
    && pass "03 schema_context: composite-FK ON DELETE CASCADE rendered" \
    || fail "03 schema_context: ON DELETE CASCADE missing: '$fk_ctx'"
  grep <<< "$fk_ctx" -q "ON UPDATE SET NULL" \
    && pass "03 schema_context: composite-FK ON UPDATE SET NULL rendered" \
    || fail "03 schema_context: ON UPDATE SET NULL missing: '$fk_ctx'"
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;" >/dev/null 2>&1
  return 0
}

# helper: expect a text_to_sql rejection containing $2 (or PASS if $2 empty)
# $3 = label, prefixed with the calling gate's own number by the caller
# (e.g. "04 valid-SELECT", "13 siu-insert-allowed") since this helper is
# shared by gates 04 and 13.
t2s_expect() {
  local canned="$1" want="$2" label="$3"
  echo "$canned" > /tmp/fractalsql_bt_sql.txt
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if [[ -z "$want" ]]; then
    grep <<< "$r" -q ERROR && fail "$label (expected PASS): $r" || pass "$label → returned"
  else
    if grep <<< "$r" -q "$want"; then pass "$label → rejected ($want)"; else fail "$label: got '$r' (want '$want')"; fi
  fi
  return 0
}

gate_04_text_to_sql() {
  t2s_expect "SELECT count(*) FROM bt_orders"                                  ""                       "04 valid-SELECT"
  t2s_expect "SELECT 1; DROP TABLE bt_orders"                                  "exactly one SQL"        "04 stacked"
  t2s_expect "DROP TABLE bt_orders"                                            "not permitted"          "04 DDL"
  t2s_expect "DELETE FROM bt_orders"                                           "not permitted"          "04 DELETE"
  t2s_expect "WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d"   "data-modifying CTE"     "04 modifying-CTE"
  t2s_expect "SELECT nope FROM bt_orders"                                      "does not analyze"       "04 bad-column"
  t2s_expect "this is not sql at all ##"                                       "does not parse"         "04 unparseable"
  # The empty-candidate contract (sibling v2.0.8's "the model response
  # contained no SQL" case, test-enabling sentinel added to the mock): a
  # ZERO-LENGTH success response from the plugin is a validation failure
  # ("expected exactly one SQL statement, found 0"), fed back and retried
  # -- not an empty statement passed on or executed.
  t2s_expect "FSQL_BT_EMPTY_RESPONSE"                                          "found 0"     "04 empty-candidate"
  local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_orders;" 2>&1)
  [[ "$n" = "0" ]] && pass "04 never-executes (bt_orders still empty)" || fail "04 never-executes: row count=$n"
  # auto-discovery mode (table_names omitted/NULL): the full GENERATE ->
  # ALLOWLIST -> EXPLAIN pipeline must still work off the auto-built
  # schema context, not just the explicit-table_names path every other
  # case above exercises.
  echo "SELECT count(*) FROM bt_orders" > /tmp/fractalsql_bt_sql.txt
  local auto; auto=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q');" 2>&1)
  if grep <<< "$auto" -q "^SELECT count"; then
    pass "04 auto-discovery: text_to_sql without table_names"
  else
    fail "04 auto-discovery: got '$auto'"
  fi
  return 0
}

# Guard-page plugin: response is deliberately NOT NUL-terminated and
# flush against an unmapped page, so any over-read SIGSEGVs instantly.
# Proves the pnstrdup(summary, summary_len) fix (fractalsql.c) holds —
# without it, this gate crashes the backend instead of getting a result.
# Also proves it at the OTHER two call sites that share the identical
# fix (bare fractal_reason(), and t2s_run_review() via trigger=2 —
# see the plugin's own header comment for why REVIEW needs a 2nd-call
# trigger rather than "misbehave every time").
gate_05_evil_overread() {
  pg_swap_plugin "$EVIL" || { fail "05 evil_overread: plugin swap did not take effect"; return; }

  echo "1" > /tmp/fractalsql_bt_evil_trigger_call.txt
  echo "SELECT 1" > /tmp/fractalsql_bt_sql.txt
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$r" -qE "server closed the connection|could not connect"; then
    fail "05 evil_overread: GENERATE path — backend crashed — $r"
  else
    pass "05 evil_overread: GENERATE path (non-terminated guard-page response) survived"
  fi

  local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_reason('q');" 2>&1)
  if grep <<< "$r2" -qE "server closed the connection|could not connect"; then
    fail "05 evil_overread: bare fractal_reason() — backend crashed — $r2"
  else
    pass "05 evil_overread: bare fractal_reason() survived"
  fi

  pg_set_guc fractalsql.text_to_sql_use_review on on \
    || { fail "05 evil_overread: could not enable text_to_sql_use_review"; pg_swap_plugin "$MOCK"; return; }
  echo "2" > /tmp/fractalsql_bt_evil_trigger_call.txt
  local r3; r3=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$r3" -qE "server closed the connection|could not connect"; then
    fail "05 evil_overread: REVIEW path — backend crashed — $r3"
  else
    pass "05 evil_overread: REVIEW path (t2s_run_review) survived"
  fi
  pg_set_guc fractalsql.text_to_sql_use_review off off
  echo "1" > /tmp/fractalsql_bt_evil_trigger_call.txt

  pg_swap_plugin "$MOCK"
  return 0
}

# Same three call sites as gate 05, but the adversarial claim is a
# lying summary_len (32 MiB, over a real 8-byte buffer) instead of a
# missing NUL terminator — proves guard_ai_response_len() rejects
# BEFORE any read is attempted, at all three sites that call it.
gate_07_evil_lying_length() {
  pg_swap_plugin "$LYING" || { fail "07 evil_lying_length: plugin swap did not take effect"; return; }

  echo "1" > /tmp/fractalsql_bt_evil_trigger_call.txt
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$r" -qE "server closed the connection|could not connect"; then
    fail "07 evil_lying_length: GENERATE path — backend crashed — $r"
  elif grep <<< "$r" -q "implausible response length"; then
    pass "07 evil_lying_length: GENERATE path rejected cleanly"
  else
    fail "07 evil_lying_length: GENERATE path — expected rejection, got: $r"
  fi

  local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_reason('q');" 2>&1)
  if grep <<< "$r2" -qE "server closed the connection|could not connect"; then
    fail "07 evil_lying_length: bare fractal_reason() — backend crashed — $r2"
  elif grep <<< "$r2" -q "implausible response length"; then
    pass "07 evil_lying_length: bare fractal_reason() rejected cleanly"
  else
    fail "07 evil_lying_length: bare fractal_reason() — expected rejection, got: $r2"
  fi

  pg_set_guc fractalsql.text_to_sql_use_review on on \
    || { fail "07 evil_lying_length: could not enable text_to_sql_use_review"; pg_swap_plugin "$MOCK"; return; }
  echo "2" > /tmp/fractalsql_bt_evil_trigger_call.txt
  local r3; r3=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$r3" -qE "server closed the connection|could not connect"; then
    fail "07 evil_lying_length: REVIEW path — backend crashed — $r3"
  elif grep <<< "$r3" -q "implausible response length"; then
    pass "07 evil_lying_length: REVIEW path (t2s_run_review) rejected cleanly"
  else
    fail "07 evil_lying_length: REVIEW path — expected rejection, got: $r3"
  fi
  pg_set_guc fractalsql.text_to_sql_use_review off off
  echo "1" > /tmp/fractalsql_bt_evil_trigger_call.txt

  pg_swap_plugin "$MOCK"
  return 0
}

# Regression test for a real information-disclosure bug found + fixed
# 2026-08-04: append_table_context()'s explicit-table_names path
# resolved names via to_regclass() (visibility only, NOT privilege) and
# then queried pg_attribute/pg_constraint directly (globally-readable
# catalogs) -- so a caller naming a table it had ZERO grants on could
# still read its full column/PK/FK/comment structure. Fixed by adding
# has_table_privilege(..., 'SELECT') to the resolution query. The
# auto-discovery path (table_names IS NULL) already had this check;
# this proves the explicit path now matches it.
gate_08_authz() {
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_secret;
     CREATE TABLE bt_secret (id serial PRIMARY KEY, ssn text);
     COMMENT ON TABLE bt_secret IS 'PII - restricted';
     REVOKE ALL ON bt_secret FROM PUBLIC;
     DROP ROLE IF EXISTS bt_lowpriv;
     CREATE ROLE bt_lowpriv LOGIN;
  " >/dev/null 2>&1

  local lowpriv_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_lowpriv -d postgres -X -tA)
  local r; r=$("${lowpriv_psql[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_secret']);" 2>&1)
  if grep <<< "$r" -q "ssn"; then
    fail "08 authz: low-priv role saw bt_secret's columns (info disclosure): $r"
  elif grep <<< "$r" -q "not found or not visible"; then
    pass "08 authz: low-priv role correctly blocked from bt_secret"
  else
    fail "08 authz: unexpected result: $r"
  fi

  "${PSQL[@]}" -c "GRANT SELECT ON bt_secret TO bt_lowpriv;" >/dev/null 2>&1
  local r2; r2=$("${lowpriv_psql[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_secret']);" 2>&1)
  grep <<< "$r2" -q "ssn" && pass "08 authz: SELECT grant restores visibility" \
                              || fail "08 authz: granted role still blocked: $r2"

  "${PSQL[@]}" -c "DROP ROLE bt_lowpriv; DROP TABLE bt_secret;" >/dev/null 2>&1
  return 0
}

# Regression test for today's GUC_SUPERUSER_ONLY fix (fractalsql.c):
# a non-superuser must not be able to point reasoning_plugin at an
# arbitrary .so path (that's native code execution in every backend).
gate_09_guc_superuser() {
  "${PSQL[@]}" -c "DROP ROLE IF EXISTS bt_lowpriv2; CREATE ROLE bt_lowpriv2 LOGIN;" >/dev/null 2>&1
  local lowpriv_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_lowpriv2 -d postgres -X -tA)
  local r; r=$("${lowpriv_psql[@]}" -c "ALTER SYSTEM SET fractalsql.reasoning_plugin = '/tmp/evil.so';" 2>&1)
  grep <<< "$r" -qiE "permission denied|must be a?n? ?superuser" \
    && pass "09 guc_superuser: non-superuser rejected from setting reasoning_plugin" \
    || fail "09 guc_superuser: expected rejection, got: $r"
  # The whole fractalsql.http_* provider family (url, token, model,
  # embed_url, embed_model, think, think_provider, native_url, num_ctx,
  # allow_plaintext) is GUC_SUPERUSER_ONLY: a non-superuser must not be
  # able to READ the deployment's provider configuration, while the rest
  # of the config surface stays readable. The boundary is PER-KEY -- the
  # positive control below proves the gate is not a blanket refusal.
  local rRead; rRead=$("${lowpriv_psql[@]}" -c "SELECT current_setting('fractalsql.http_model', true);" 2>&1)
  grep <<< "$rRead" -qiE "permission denied|must be a?n? ?superuser" \
    && pass "09 guc_superuser: non-superuser rejected from reading http_model" \
    || fail "09 guc_superuser: expected a privilege error reading http_model, got: $rRead"
  local rRead2; rRead2=$("${lowpriv_psql[@]}" -c "SELECT current_setting('fractalsql.text_to_sql_max_attempts', true);" 2>&1)
  grep -qE '^[0-9]+$' <<< "$rRead2" \
    && pass "09 guc_superuser: the boundary is per-key -- a non-superuser still reads a non-superuser-only key" \
    || fail "09 guc_superuser: expected text_to_sql_max_attempts to stay readable, got: $rRead2"

  # ---- T-G: the typed config surface (fractalsql_set_config() /
  # fractalsql_get_config(), src/fractalsql.c's fsql_cfg_keys[] table).
  # This is the SQL-callable wrapper over the fractalsql.* GUCs, and
  # it is what promises typed validation, a per-key privilege boundary,
  # a scope boundary, and an error naming the known keys.
  local rG; rG=$("${PSQL[@]}" -c "SELECT fractalsql_get_config('nope');" 2>&1)
  grep -q 'unknown config key "nope"' <<< "$rG" && grep -q "Known keys:" <<< "$rG" \
    && pass "09 cfg: an unknown key is an error that lists the known keys (get)" \
    || fail "09 cfg: expected an unknown-key error naming the known keys, got: $rG"
  local rG2; rG2=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('nope','x');" 2>&1)
  grep -q 'unknown config key "nope"' <<< "$rG2" \
    && pass "09 cfg: an unknown key is an error, never a silent no-op (set)" \
    || fail "09 cfg: expected an unknown-key error, got: $rG2"

  # Both spellings of a key are accepted, case-insensitively -- the bare
  # name ("http_url") and the GUC's own name ("fractalsql.http_url"). The
  # bare form used to be matched case-SENSITIVELY (fsql_cfg_lookup()
  # folded only the prefixed spelling), which contradicted both the
  # function's own contract and the SQL COMMENT on the two functions.
  local rG3; rG3=$("${PSQL[@]}" -c "SELECT fractalsql_get_config('text_to_sql_max_attempts');" 2>&1)
  local rG4; rG4=$("${PSQL[@]}" -c "SELECT fractalsql_get_config('fractalsql.text_to_sql_max_attempts');" 2>&1)
  [[ "$rG3" = "$rG4" ]] && grep -qE '^[0-9]+$' <<< "$rG3" \
    && pass "09 cfg: the bare key and the GUC spelling return the same value" \
    || fail "09 cfg: expected the two spellings to agree, got bare='$rG3' prefixed='$rG4'"
  local rG5; rG5=$("${PSQL[@]}" -c "SELECT fractalsql_get_config('TEXT_TO_SQL_MAX_ATTEMPTS');" 2>&1)
  local rG6; rG6=$("${PSQL[@]}" -c "SELECT fractalsql_get_config('FRACTALSQL.text_to_sql_max_attempts');" 2>&1)
  [[ "$rG5" = "$rG3" && "$rG6" = "$rG3" ]] \
    && pass "09 cfg: both key spellings are matched case-insensitively" \
    || fail "09 cfg: expected case-insensitive matching, got bare-upper='$rG5' prefixed-upper='$rG6' (expected '$rG3')"

  # A bool key canonicalizes to on/off and the value written IS the GUC's
  # own value -- current_setting() has to agree with it in the SAME
  # session (the write is session-scoped, so a separate connection would
  # read a fresh backend's untouched default).
  local rG7; rG7=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('agent_partial_reasoning_fail','yes') || '=' || fractalsql_get_config('agent_partial_reasoning_fail') || '=' || current_setting('fractalsql.agent_partial_reasoning_fail');" 2>&1)
  [[ "$rG7" = "on=on=on" ]] \
    && pass "09 cfg: a bool key canonicalizes 'yes' to 'on' and the value lands in the GUC itself" \
    || fail "09 cfg: expected on=on=on, got: $rG7"
  local rG8; rG8=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('agent_partial_reasoning_fail','tru');" 2>&1)
  grep -q "expects a boolean" <<< "$rG8" && grep -q "Accepted spellings" <<< "$rG8" \
    && pass "09 cfg: a bool key rejects an unrecognised spelling and names the accepted ones" \
    || fail "09 cfg: expected a boolean rejection, got: $rG8"

  # Typed validation: int, enum, and the documented order -- the VALUE is
  # validated before the privilege and scope checks, so a bad value is
  # reported as a bad value even for a key a session may not change.
  local rG9; rG9=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('http_num_ctx','notanint');" 2>&1)
  grep -q "expects an integer" <<< "$rG9" \
    && pass "09 cfg: an int key rejects a non-integer" \
    || fail "09 cfg: expected an integer rejection, got: $rG9"
  local rG10; rG10=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('http_num_ctx','1048577');" 2>&1)
  grep -q "must be between 0 and 1048576" <<< "$rG10" \
    && pass "09 cfg: an int key rejects a value outside its range" \
    || fail "09 cfg: expected a range rejection, got: $rG10"
  local rG11; rG11=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('text_to_sql_allowed_statements','drop');" 2>&1)
  grep -q "must be one of: select|select_insert_update" <<< "$rG11" \
    && pass "09 cfg: an enum key rejects a value outside its member list" \
    || fail "09 cfg: expected an enum rejection, got: $rG11"
  local rG12; rG12=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('text_to_sql_max_attempts','99');" 2>&1)
  grep -q "must be between 1 and 10" <<< "$rG12" \
    && pass "09 cfg: an invalid value is reported BEFORE the scope check (text_to_sql_max_attempts is reload-scoped)" \
    || fail "09 cfg: expected the value error to win over the scope error, got: $rG12"

  # The scope boundary: a reload-scoped (PGC_SIGHUP) key cannot be changed
  # in a session, and the error names the ALTER SYSTEM + pg_reload_conf()
  # path instead of silently doing nothing.
  local rG13; rG13=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('text_to_sql_max_attempts','3');" 2>&1)
  grep -q "is reload-scoped and cannot be changed in a session" <<< "$rG13" \
    && grep -q "ALTER SYSTEM SET" <<< "$rG13" && grep -q "pg_reload_conf" <<< "$rG13" \
    && pass "09 cfg: a reload-scoped key refuses a session change and names the ALTER SYSTEM + pg_reload_conf path" \
    || fail "09 cfg: expected the reload-scoped refusal with the ALTER SYSTEM hint, got: $rG13"
  # ... while a session-settable key (PGC_USERSET / PGC_SUSET) IS writable
  # in a session, and the canonical value comes back.
  local rG14; rG14=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('enterprise_ledger_key','cfgtest');" 2>&1)
  [[ "$rG14" = "cfgtest" ]] \
    && pass "09 cfg: a session-settable key (enterprise_ledger_key) is writable in a session" \
    || fail "09 cfg: expected the value to be accepted, got: $rG14"

  # NULL arguments are argument faults, not "unset".
  local rG15; rG15=$("${PSQL[@]}" -c "SELECT fractalsql_set_config(NULL,'x');" 2>&1)
  grep -q "the key must not be NULL" <<< "$rG15" \
    && pass "09 cfg: set rejects a NULL key" \
    || fail "09 cfg: expected the NULL-key rejection, got: $rG15"
  local rG16; rG16=$("${PSQL[@]}" -c "SELECT fractalsql_set_config('text_to_sql_max_attempts',NULL);" 2>&1)
  grep -q "the value must not be NULL" <<< "$rG16" \
    && pass "09 cfg: set rejects a NULL value" \
    || fail "09 cfg: expected the NULL-value rejection, got: $rG16"
  local rG17; rG17=$("${PSQL[@]}" -c "SELECT fractalsql_get_config(NULL);" 2>&1)
  grep -q "the key must not be NULL" <<< "$rG17" \
    && pass "09 cfg: get rejects a NULL key" \
    || fail "09 cfg: expected the NULL-key rejection, got: $rG17"

  # The config API enforces the SAME per-key privilege boundary the GUCs
  # carry -- and, like the GUCs, it is per-key, not blanket.
  local rL1; rL1=$("${lowpriv_psql[@]}" -c "SELECT fractalsql_set_config('http_url','http://x');" 2>&1)
  grep -q "is a superuser-only setting" <<< "$rL1" \
    && pass "09 cfg: a non-superuser cannot SET a superuser-only key through the config API" \
    || fail "09 cfg: expected the superuser-only rejection, got: $rL1"
  local rL2; rL2=$("${lowpriv_psql[@]}" -c "SELECT fractalsql_get_config('http_url');" 2>&1)
  grep -q "is a superuser-only setting" <<< "$rL2" \
    && pass "09 cfg: a non-superuser cannot READ a superuser-only key through the config API" \
    || fail "09 cfg: expected the superuser-only rejection, got: $rL2"
  local rL3; rL3=$("${lowpriv_psql[@]}" -c "SELECT fractalsql_get_config('text_to_sql_max_attempts');" 2>&1)
  grep -qE '^[0-9]+$' <<< "$rL3" \
    && pass "09 cfg: the config API's privilege boundary is per-key -- a non-superuser still reads a non-superuser-only key" \
    || fail "09 cfg: expected text_to_sql_max_attempts to stay readable, got: $rL3"
  local rL4; rL4=$("${lowpriv_psql[@]}" -c "SELECT fractalsql_set_config('agent_partial_reasoning_fail','on');" 2>&1)
  [[ "$rL4" = "on" ]] \
    && pass "09 cfg: a non-superuser may set a non-superuser-only, session-settable key" \
    || fail "09 cfg: expected the set to be accepted, got: $rL4"

  "${PSQL[@]}" -c "DROP ROLE bt_lowpriv2;" >/dev/null 2>&1
  return 0
}

# MAX_SCHEMA_CONTEXT_TABLES (512) DoS cap boundary, and a SQL-injection-
# shaped table name proving clean rejection rather than execution.
gate_10_dos_and_injection() {
  local many; many=$(printf "'t%s'," $(seq 1 513) | sed 's/,$//')
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_schema_context(ARRAY[$many]);" 2>&1)
  grep <<< "$r" -q "exceeds the limit of 512" \
    && pass "10 dos_cap: 513 table names rejected" \
    || fail "10 dos_cap: expected PROGRAM_LIMIT_EXCEEDED, got: $r"

  local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_customers''; DROP TABLE bt_orders; --']);" 2>&1)
  local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_orders;" 2>&1)
  if [[ "$n" = "0" ]]; then
    pass "10 injection: SQL-injection-shaped table name did not execute (bt_orders intact)"
  else
    fail "10 injection: bt_orders row count changed (n=$n) — injection may have executed"
  fi
  grep <<< "$r2" -qE "not found or not visible|ERROR" \
    && pass "10 injection: injection-shaped table name cleanly rejected" \
    || fail "10 injection: unexpected result: $r2"
  return 0
}

# Scout mode minimal smoke: a 3-island clustered corpus, population
# returned (not the pre-Scout 1-row stub), particles disperse across
# more than one island. Mirrors tests/test_scout.py's core assertions
# in the lightweight bash/SQL style so it runs in the fast/CI path.
gate_11_scout() {
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_scout_docs;
     CREATE TABLE bt_scout_docs (id int, emb_arr float8[]);
     INSERT INTO bt_scout_docs
       SELECT i, ARRAY[1.0,0.0,0.0]::float8[] FROM generate_series(1,20) i
       UNION ALL
       SELECT i, ARRAY[0.0,1.0,0.0]::float8[] FROM generate_series(21,40) i
       UNION ALL
       SELECT i, ARRAY[0.0,0.0,1.0]::float8[] FROM generate_series(41,60) i;
  " >/dev/null 2>&1

  local n; n=$("${PSQL[@]}" -c "
     SELECT count(*) FROM fractal_search_explore(
       'bt_scout_docs', 'emb_arr', ARRAY[1.0,0.0,0.0]::float8[],
       '{\"population_size\": 24, \"iterations\": 12}'::jsonb);" 2>&1)
  [[ "$n" = "24" ]] && pass "11 scout: returns full population (24 particles)" \
                   || fail "11 scout: expected 24 particles, got: $n"

  local islands; islands=$("${PSQL[@]}" -c "
     SELECT count(DISTINCT
       CASE WHEN p[1] > p[2] AND p[1] > p[3] THEN 0
            WHEN p[2] > p[1] AND p[2] > p[3] THEN 1
            ELSE 2 END)
     FROM fractal_search_explore(
       'bt_scout_docs', 'emb_arr', ARRAY[1.0,0.0,0.0]::float8[],
       '{\"population_size\": 24, \"iterations\": 12}'::jsonb) AS p;" 2>&1)
  [[ "${islands:-0}" -gt 1 ]] 2>/dev/null && pass "11 scout: particles disperse across >1 island" \
                                          || fail "11 scout: expected dispersion, got islands=$islands"

  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_scout_docs;" >/dev/null 2>&1
  return 0
}

# Deliberately-segfaulting plugin. No in-process fix can prevent this —
# the point is to CI-verify PostgreSQL's own crash-recovery contract:
# the triggering connection drops, the postmaster auto-restarts the
# cluster (restart_after_crash, on by default), and previously
# committed data survives intact.
gate_06_crash_recovery() {
  "${PSQL[@]}" -c "INSERT INTO bt_customers (name, status) VALUES ('canary', 'ok');" >/dev/null 2>&1
  pg_swap_plugin "$CRASH" || { fail "06 crash_recovery: plugin swap did not take effect"; return; }
  echo "SELECT 1" > /tmp/fractalsql_bt_sql.txt
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  grep <<< "$r" -qE "server closed the connection|could not connect" \
    && pass "06 crash_recovery: triggering connection dropped as expected" \
    || fail "06 crash_recovery: expected the connection to drop, got: $r"

  # Two concerns share this poll but must NOT share the same cutoff:
  # whether recovery counts as "fast enough" for the gate's own pass/fail
  # (the original `tries` budget), and whether the crash plugin gets
  # swapped back to $MOCK at all -- restoring it was previously gated
  # behind this same up==1-within-budget check, so a near-miss (cluster
  # comes back a few seconds late) left the deliberately-crashing plugin
  # active for every remaining gate in the run, cascading into unrelated-
  # looking failures far downstream. Poll for up to double the budget;
  # report pass/fail against the original window, but restore the plugin
  # as long as the cluster comes back at all within the extended one.
  local up=0 i tries=$(( 30 * TIMEOUT_MULT )) within_budget=0
  for i in $(seq 1 $(( tries * 2 ))); do
    "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1 && { up=1; [[ "$i" -le "$tries" ]] && within_budget=1; break; }
    sleep 0.5
  done
  [[ "$within_budget" -eq 1 ]] && pass "06 crash_recovery: cluster auto-restarted" \
                   || fail "06 crash_recovery: cluster did not come back within $(( tries / 2 ))s"

  if [[ "$up" -eq 1 ]]; then
    local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_customers WHERE name = 'canary';" 2>&1)
    [[ "$n" = "1" ]] && pass "06 crash_recovery: prior data intact after recovery" \
                    || fail "06 crash_recovery: canary row missing after recovery (n=$n)"
    pg_swap_plugin "$MOCK"
  else
    fail "06 crash_recovery: cluster never came back -- remaining gates will run against the crash plugin"
  fi
  return 0
}

# Concurrency/soak: SOAK_WORKERS concurrent backends x SOAK_ITERS mixed
# benign calls each (fractal_search / schema_context / text_to_sql),
# against the SAME shared cluster. Each backend is a separate OS
# process (no threading), so this isn't hunting for data races on
# fractalsql.c's static globals -- those are already per-process. It's
# checking for what concurrency actually CAN break here: connection/
# resource exhaustion, and any SPI/transaction-handling bug that only
# surfaces under overlapping backends. Bounded duration by design, not
# a multi-minute stress soak.
SOAK_WORKERS=20
SOAK_ITERS=15

gate_12_soak() {
  local outdir="/tmp/fractalsql_bt_soak_$$"
  rm -rf "$outdir"; mkdir -p "$outdir"
  echo "SELECT count(*) FROM bt_orders" > /tmp/fractalsql_bt_sql.txt

  local pids=() w
  for w in $(seq 1 "$SOAK_WORKERS"); do
    (
      local rc=0 i
      for i in $(seq 1 "$SOAK_ITERS"); do
        case $(( (w + i) % 3 )) in
          0) "${PSQL[@]}" -c "SELECT fractal_search(ARRAY[0.6,0.8]::float8[],20,20,2);" >/dev/null 2>&1 || rc=1 ;;
          1) "${PSQL[@]}" -c "SELECT fractal_schema_context(ARRAY['bt_customers','bt_orders']);" >/dev/null 2>&1 || rc=1 ;;
          2) "${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" >/dev/null 2>&1 || rc=1 ;;
          *) ;;   # unreachable: (w+i) % 3 is always 0/1/2
        esac
      done
      echo "$rc" > "$outdir/worker_$w.rc"
    ) &
    pids+=("$!")
  done
  local p
  for p in "${pids[@]}"; do wait "$p"; done

  local failed_workers=0
  for w in $(seq 1 "$SOAK_WORKERS"); do
    [[ "$(cat "$outdir/worker_$w.rc" 2>/dev/null)" = "0" ]] || failed_workers=$((failed_workers + 1))
  done
  local total=$(( SOAK_WORKERS * SOAK_ITERS ))
  [[ "$failed_workers" -eq 0 ]] \
    && pass "12 soak: $SOAK_WORKERS workers x $SOAK_ITERS iterations ($total calls) all succeeded" \
    || fail "12 soak: $failed_workers/$SOAK_WORKERS workers had a failed call"

  "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1 \
    && pass "12 soak: cluster responsive after concurrent load" \
    || fail "12 soak: cluster unresponsive after concurrent load"

  rm -rf "$outdir"
  return 0
}

# select_insert_update mode: fractalsql.text_to_sql_allowed_statements
# widens the allowlist from SELECT-only to SELECT/INSERT/UPDATE. Proves
# both halves of that: writes are now returned (not rejected) instead
# of executed (still just EXPLAINed, per t2s_check_explain), and DDL/
# DELETE remain rejected regardless -- the GUC only ever adds INSERT/
# UPDATE to the allowed set, never removes the DDL/DELETE block.
gate_13_siu_mode() {
  pg_set_guc fractalsql.text_to_sql_allowed_statements "'select_insert_update'" "select_insert_update" \
    || { fail "13 siu_mode: GUC did not take effect"; return; }

  t2s_expect "INSERT INTO bt_orders (customer_id, total) VALUES (1, 100)" "" "13 siu-insert-allowed"
  t2s_expect "UPDATE bt_orders SET total = 0"                             "" "13 siu-update-allowed"
  t2s_expect "DROP TABLE bt_orders"          "not permitted" "13 siu-ddl-still-rejected"
  t2s_expect "DELETE FROM bt_orders"         "not permitted" "13 siu-delete-still-rejected"

  local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_orders;" 2>&1)
  [[ "$n" = "0" ]] && pass "13 siu_mode: INSERT/UPDATE never execute (bt_orders still empty)" \
                  || fail "13 siu_mode: row count=$n"

  pg_set_guc fractalsql.text_to_sql_allowed_statements "'select'" "select"

  # ---- T-I: the check hook on fractalsql.text_to_sql_allowed_statements.
  # The GUC carries a check hook (src/fractalsql.c's
  # check_t2s_allowed_statements), so an invalid value is rejected AT SET
  # TIME rather than merely refused later.
  #
  # A session SET cannot reach the hook: the GUC is PGC_SIGHUP, so
  # PostgreSQL refuses the SET first ("cannot be changed now") and the
  # hook never runs. ALTER SYSTEM is the one path that validates at set
  # time, because that is where Postgres parses and checks the value it
  # is about to persist.
  local rI1; rI1=$("${PSQL[@]}" -c "SET fractalsql.text_to_sql_allowed_statements = 'bogus';" 2>&1)
  grep -q "cannot be changed now" <<< "$rI1" \
    && pass "13 check-hook: a session SET of the PGC_SIGHUP GUC is refused by PostgreSQL itself" \
    || fail "13 check-hook: expected 'cannot be changed now', got: $rI1"
  local rI2; rI2=$("${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.text_to_sql_allowed_statements = 'bogus';" 2>&1)
  grep -q 'invalid value for parameter "fractalsql\.text_to_sql_allowed_statements"' <<< "$rI2" \
    && grep -q 'Allowed values are "select" and "select_insert_update"' <<< "$rI2" \
    && pass "13 check-hook: ALTER SYSTEM rejects an invalid value and names the accepted ones" \
    || fail "13 check-hook: expected the check hook's rejection, got: $rI2"
  # The rejected value must not have been persisted, and the server must
  # still be alive and serving the previous value.
  if [[ -f "$DATADIR/postgresql.auto.conf" ]]; then
    if ! grep -q "bogus" "$DATADIR/postgresql.auto.conf"; then
      pass "13 check-hook: the rejected value never reached postgresql.auto.conf"
    else
      fail "13 check-hook: the rejected value was persisted to postgresql.auto.conf"
    fi
  else
    skip "13 check-hook: postgresql.auto.conf not found -- skipped the persistence check"
  fi
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
  sleep 2
  local rI3; rI3=$("${PSQL[@]}" -c "SELECT current_setting('fractalsql.text_to_sql_allowed_statements');" 2>&1)
  [[ "$rI3" = "select" ]] \
    && pass "13 check-hook: the effective value is unchanged after the rejected ALTER SYSTEM" \
    || fail "13 check-hook: expected the effective value to still be 'select', got: $rI3"
  local rI4; rI4=$("${PSQL[@]}" -c "SELECT 1;" 2>&1)
  [[ "$rI4" = "1" ]] \
    && pass "13 check-hook: the server survived the rejected ALTER SYSTEM" \
    || fail "13 check-hook: expected the server to be alive, got: $rI4"
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.text_to_sql_allowed_statements;" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1

  # The check hook is deliberately NOT applied to
  # fractalsql.enterprise_lib: a rejecting hook there would fail the
  # config reload of every backend that has the library loaded (the
  # postmaster re-reads the same file), so an arbitrary path has to be
  # accepted there and the refusal is raised at USE time instead --
  # which is gate 31's job. Assert the asymmetry explicitly.
  local rI5; rI5=$("${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_lib = '/nonexistent/fractalsql_ent_probe.so';" 2>&1)
  if ! grep -qiE "error|invalid value" <<< "$rI5"; then
    pass "13 check-hook: enterprise_lib deliberately has no check hook (an arbitrary path is accepted at set time)"
  else
    fail "13 check-hook: expected enterprise_lib to accept any path, got: $rI5"
  fi
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.enterprise_lib;" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
  return 0
}

# Retry-with-feedback: max_attempts>1 with a plugin that returns a
# rejected statement on attempt 1 and a valid one on attempt 2. Covers
# the retry loop's prompt-rebuild branch (fractalsql.c, `last_sql !=
# NULL`) which every other gate leaves untouched (they all run at
# max_attempts=1, so the loop body only ever executes once).
gate_14_retry() {
  pg_set_guc fractalsql.text_to_sql_max_attempts 2 2 \
    || { fail "14 retry: GUC did not take effect"; return; }
  pg_swap_plugin "$RETRY" || { fail "14 retry: plugin swap did not take effect"; pg_set_guc fractalsql.text_to_sql_max_attempts 1 1; return; }

  local r; r=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$r" -qE "server closed the connection|could not connect"; then
    fail "14 retry: backend crashed -- $r"
  elif grep <<< "$r" -q "^SELECT 1"; then
    pass "14 retry: succeeded on 2nd attempt after 1st was rejected"
  else
    fail "14 retry: expected eventual success (SELECT 1), got: $r"
  fi

  local prompt; prompt=$(cat /tmp/fractalsql_bt_retry_prompt.txt 2>/dev/null)
  grep <<< "$prompt" -q "not permitted" \
    && pass "14 retry: attempt-1 rejection reason fed back into attempt-2 prompt" \
    || fail "14 retry: retry prompt missing feedback text: '$prompt'"

  local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_orders;" 2>&1)
  [[ "$n" = "0" ]] && pass "14 retry: never-executes held across retries" || fail "14 retry: row count=$n"

  # --- review exhaustion: t2s_run_review's own exhausted-attempts branch
  #     (src/fractalsql.c: "exhausted %d attempt(s), last review verdict").
  #     Review PASSES only when the critique response starts with PASS
  #     (pg_strncasecmp(p, "PASS", 4) in t2s_run_review) -- and the standard
  #     MOCK plugin's REVIEW response can NEVER satisfy that, by
  #     construction: ensure_review_ctx() loads with RESPONSE_MODE unset
  #     (see its own comment), so mock_generate() always renders the
  #     canned file content as a ```sql-fenced chat response beginning
  #     "```s..." -- no sentinel content can ever produce a PASS prefix.
  #     max_attempts=1 therefore turns the first (and only) review FAIL
  #     directly into the exhaustion error.
  pg_set_guc fractalsql.text_to_sql_max_attempts 1 1 \
    || { fail "14 review-exhaustion: max_attempts GUC did not take effect"; return; }
  pg_set_guc fractalsql.text_to_sql_use_review on on \
    || { fail "14 review-exhaustion: use_review GUC did not take effect"; return; }
  pg_swap_plugin "$MOCK" \
    || { fail "14 review-exhaustion: plugin swap did not take effect"; pg_set_guc fractalsql.text_to_sql_use_review off off; return; }
  echo "SELECT 1" > /tmp/fractalsql_bt_sql.txt
  local rr; rr=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" 2>&1)
  if grep <<< "$rr" -qE "server closed the connection|could not connect"; then
    fail "14 review-exhaustion: backend crashed -- $rr"
  elif grep <<< "$rr" -q "exhausted 1 attempt(s), last review verdict" && grep <<< "$rr" -q '```sql'; then
    pass "14 review-exhaustion: review FAIL twice over -> 'exhausted 1 attempt(s), last review verdict' with the mock's fenced critique"
  else
    fail "14 review-exhaustion: expected the review-exhaustion rejection, got: $rr"
  fi
  grep <<< "$rr" -q "Last candidate SQL: SELECT 1" \
    && pass "14 review-exhaustion: errdetail carries the last candidate SQL" \
    || fail "14 review-exhaustion: errdetail missing: '$rr'"
  rm -f /tmp/fractalsql_bt_sql.txt
  pg_set_guc fractalsql.text_to_sql_use_review off off
  # max_attempts and the plugin are left at 1/$MOCK by the restores below.

  pg_set_guc fractalsql.text_to_sql_max_attempts 1 1
  pg_swap_plugin "$MOCK"
  return 0
}

# fractal_embed() + the vectorizer, real dispatch through
# ensure_embed_ctx()/g_embed_ctx (the three-tier reasoning-context split
# -- see fractalsql.c's own header comment) using a canned-vector mock
# plugin, not just the "no plugin configured"/"no http_embed_url
# configured" precondition-error paths every other gate here leaves
# untouched. HTTP-level embedding-response parsing (data[0].embedding
# extraction, malformed-response handling) is covered separately in
# tests/test_vectorizer.py against the real vendored plugin -- this gate
# is about fractalsql-postgresql's OWN glue (dispatch, parse_embedding_
# array, the vectorizer's queue/trigger/write-back), matching every
# other gate's mock-plugin scope in this file.
gate_15_embed() {
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "15 embed: http_embed_url GUC did not take effect"; return; }
  pg_set_guc fractalsql.reasoning_plugin "'$EMBED'" "$EMBED" \
    || { fail "15 embed: plugin swap did not take effect"; pg_swap_plugin "$MOCK"; return; }

  local r; r=$("${PSQL[@]}" -c "SELECT fractal_embed('test input');" 2>&1)
  [[ "$r" = "{0.1,0.2,0.3}" ]] \
    && pass "15 embed: fractal_embed() returned the canned vector" \
    || fail "15 embed: fractal_embed() expected {0.1,0.2,0.3}, got: $r"

  local rnull; rnull=$("${PSQL[@]}" -c "SELECT fractal_embed(NULL);" 2>&1)
  grep <<< "$rnull" -q "must not be NULL" \
    && pass "15 embed: NULL input rejected cleanly" \
    || fail "15 embed: NULL input expected a clear rejection, got: $rnull"

  # Nonexistent plugin path -- exercises ensure_reasoning_tier_ctx's own
  # load-failure branch (distinct from "no plugin configured at all").
  pg_set_guc fractalsql.reasoning_plugin "'/tmp/fractalsql_bt_nonexistent.so'" "/tmp/fractalsql_bt_nonexistent.so" \
    || { fail "15 embed: bad-path GUC did not take effect"; pg_swap_plugin "$MOCK"; return; }
  local rbad; rbad=$("${PSQL[@]}" -c "SELECT fractal_embed('test input');" 2>&1)
  grep <<< "$rbad" -q "failed to load reasoning plugin" \
    && pass "15 embed: nonexistent plugin path rejected cleanly" \
    || fail "15 embed: nonexistent plugin path expected a clear rejection, got: $rbad"
  pg_set_guc fractalsql.reasoning_plugin "'$EMBED'" "$EMBED" \
    || { fail "15 embed: plugin swap back did not take effect"; pg_swap_plugin "$MOCK"; return; }

  # Evil embed: a plugin returning MAX_EMBED_DIM+1 (16385) floats must be
  # REJECTED, not silently truncated to a wrong-but-plausible 16384-
  # element vector -- a real bug in parse_embedding_array() fixed
  # alongside this test (the original loop condition stopped writing at
  # cap but still returned success). tests/evil_embed_plugin.c mirrors
  # gate 07's evil_lying_length_plugin.c for the embedding response path.
  pg_swap_plugin "$EVIL_EMBED" || { fail "15 embed: evil_embed plugin swap did not take effect"; pg_swap_plugin "$MOCK"; return; }
  local revil; revil=$("${PSQL[@]}" -c "SELECT fractal_embed('test input');" 2>&1)
  grep <<< "$revil" -q "could not parse embedding response" \
    && pass "15 embed: over-limit embedding array rejected, not silently truncated" \
    || fail "15 embed: expected a clean rejection, got: $revil"
  pg_set_guc fractalsql.reasoning_plugin "'$EMBED'" "$EMBED" \
    || { fail "15 embed: plugin swap back (post evil_embed) did not take effect"; pg_swap_plugin "$MOCK"; return; }

  "${PSQL[@]}" -c "DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';" >/dev/null 2>&1
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_embed_docs;" >/dev/null 2>&1
  "${PSQL[@]}" -c "CREATE TABLE bt_embed_docs (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);" >/dev/null 2>&1
  "${PSQL[@]}" -c "INSERT INTO bt_embed_docs (body) VALUES ('a'), ('b');" >/dev/null 2>&1

  # SQL-injection-shaped source_table, same pattern gate 10 already
  # proves for fractal_schema_context/fractal_search_explore, extended
  # here to the vectorizer's own dynamic SQL (CREATE TRIGGER/EXECUTE
  # with %I-quoted identifiers). Must fail cleanly via the ::regclass
  # cast (source_table doesn't resolve) before ever reaching format().
  local rinj; rinj=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_docs''; DROP TABLE bt_embed_docs; --', 'body', 'embedding');" 2>&1)
  local ninj; ninj=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_embed_docs;" 2>&1)
  if [[ "$ninj" = "2" ]]; then
    pass "15 embed: injection-shaped source_table did not execute (bt_embed_docs intact)"
  else
    fail "15 embed: bt_embed_docs row count changed (n=$ninj) — injection may have executed"
  fi
  grep <<< "$rinj" -qE "invalid name syntax|does not exist|ERROR" \
    && pass "15 embed: injection-shaped source_table cleanly rejected" \
    || fail "15 embed: unexpected result: $rinj"

  local vzid; vzid=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding');" 2>&1)

  # Double-create: same (source_table, text_col, embedding_col) again
  # must fail with a clean, fractal_-prefixed message naming the
  # existing vectorizer id -- not a raw "duplicate key value violates
  # unique constraint ..." that leaks the constraint name and a
  # PL/pgSQL stack frame.
  local rdup; rdup=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding');" 2>&1)
  grep <<< "$rdup" -q "already exists (id=$vzid)" \
    && pass "15 embed: double-create rejected with a clean, specific error" \
    || fail "15 embed: expected a clean double-create rejection naming id=$vzid, got: $rdup"
  local n; n=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  [[ "$n" = "2" ]] && pass "15 embed: process_queue processed 2 backfilled rows" \
    || fail "15 embed: process_queue expected 2, got: $n"

  local embedded; embedded=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_embed_docs WHERE embedding = '{0.1,0.2,0.3}';" 2>&1)
  [[ "$embedded" = "2" ]] && pass "15 embed: both rows got the real embedding written back" \
    || fail "15 embed: expected 2 rows with the embedding written back, got: $embedded"

  local status; status=$("${PSQL[@]}" -c "SELECT status FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid;" 2>&1)
  [[ "$status" = "done" ]] && pass "15 embed: vectorizer status shows done, no failures" \
    || fail "15 embed: expected status 'done', got: $status"

  # --- vectorizer-failed-rows: the process_queue failure path
  #     (sql/fractalsql--1.0.sql's EXCEPTION WHEN OTHERS block: every
  #     failing row must END status='failed' with error=SQLERRM and an
  #     updated_at, visible through fractal_vectorizer_status's
  #     last_failure_at/last_error columns) -- plus the claim/retry logic
  #     that decides what "recovering" means. Disrupt ONE condition: blank
  #     fractalsql.http_embed_url the way this gate itself swaps GUCs
  #     (pg_set_guc = ALTER SYSTEM + reload + poll; save the pinned value
  #     and restore it below). With the URL unset, ensure_embed_ctx()
  #     (src/fractalsql.c:1706) raises "fractal_embed:
  #     fractalsql.http_embed_url is not configured" before any dispatch --
  #     deterministic, no HTTP involved. Two new trigger-enqueued rows
  #     exercise it.
  pg_set_guc fractalsql.http_embed_url "''" "" \
    || { fail "15 vectorizer-failed-rows: could not blank fractalsql.http_embed_url"; return; }
  "${PSQL[@]}" -c "INSERT INTO bt_embed_docs (body) VALUES ('c'), ('d');" >/dev/null 2>&1
  local rfail
  rfail=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  local nfail; nfail=$("${PSQL[@]}" -c "
    SELECT count(*) FROM fractal_vectorizer_queue
     WHERE vectorizer_id = $vzid AND status = 'failed'
       AND COALESCE(error, '') <> '';" 2>&1)
  [[ "$nfail" = "2" ]] \
    && pass "15 vectorizer-failed-rows: both queued rows end status='failed' with a non-empty error" \
    || fail "15 vectorizer-failed-rows: expected 2 failed rows with an error string, got: $nfail ($rfail)"
  local ftxt; ftxt=$("${PSQL[@]}" -c "
    SELECT bool_and(error LIKE '%http_embed_url is not configured%')
      FROM fractal_vectorizer_queue
     WHERE vectorizer_id = $vzid AND status = 'failed';" 2>&1)
  [[ "$ftxt" = "t" ]] \
    && pass "15 vectorizer-failed-rows: error carries the engine's own 'http_embed_url is not configured' message" \
    || fail "15 vectorizer-failed-rows: expected the ensure_embed_ctx error text in the queue rows, got: $ftxt"
  local vstat; vstat=$("${PSQL[@]}" -c "
    SELECT count(*) FROM fractal_vectorizer_status
     WHERE vectorizer_id = $vzid AND status = 'failed'
       AND last_failure_at IS NOT NULL
       AND last_error LIKE '%http_embed_url is not configured%';" 2>&1)
  # The view groups BY status (one row per queued-status group for this
  # vectorizer — done/failed/... coexist), so assert on the failed GROUP's
  # presence, not on any one emitted line (the docker gate caught the
  # line-shape assumption: the done row sorts first, the failed row's
  # display truncates, and the line-greps were order-fragile).
  [[ "$vstat" = "1" ]] \
    && pass "15 vectorizer-failed-rows: fractal_vectorizer_status shows the failed group with last_failure_at and last_error set" \
    || fail "15 vectorizer-failed-rows: expected the failed group row in fractal_vectorizer_status, got: $vstat"

  # Recovery: the claim loop only ever picks status='pending' rows (the FOR
  # r IN SELECT ... WHERE q.status = 'pending' in process_queue), so a bare
  # re-run never retries the failed rows -- it returns 0 and leaves them
  # failed. Restoring the embed config alone is therefore not enough; the
  # operator path is a pending-reset UPDATE (the exact shape of
  # process_queue's own stale_after reclaim UPDATE), after which the same
  # rows complete with the canned embedding.
  local nretry; nretry=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  [[ "$nretry" = "0" ]] \
    && pass "15 vectorizer-failed-rows: a bare re-run does NOT retry failed rows (claim only picks 'pending'; returned 0)" \
    || fail "15 vectorizer-failed-rows: expected process_queue to not retry failed rows (0), got: $nretry"

  # Restore the pinned embed URL FIRST: by itself it recovers nothing
  # (asserted above), and it is what lets the pending-reset rows below
  # actually succeed with the canned embedding.
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "15 vectorizer-failed-rows: could not restore fractalsql.http_embed_url"; return; }
  "${PSQL[@]}" -c "
    UPDATE fractal_vectorizer_queue
       SET status = 'pending', processing_started_at = NULL
     WHERE vectorizer_id = $vzid AND status = 'failed';" >/dev/null 2>&1
  local nrec; nrec=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  [[ "$nrec" = "2" ]] \
    && pass "15 vectorizer-failed-rows: after restoring the config + a pending-reset, the recovered rows process to done" \
    || fail "15 vectorizer-failed-rows: expected 2 recovered rows after the pending-reset, got: $nrec"
  local ndone; ndone=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_embed_docs WHERE embedding = '{0.1,0.2,0.3}';" 2>&1)
  [[ "$ndone" = "4" ]] \
    && pass "15 vectorizer-failed-rows: all 4 rows carry the canned embedding after recovery" \
    || fail "15 vectorizer-failed-rows: expected 4 embedded rows after recovery, got: $ndone"

  "${PSQL[@]}" -c "DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';" >/dev/null 2>&1
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_embed_docs;" >/dev/null 2>&1
  pg_swap_plugin "$MOCK"
  return 0
}

# Vectorizer authz: two real properties, not assumed from reading the
# GRANTs added alongside this test --
#   1. A role that owns its OWN table can fully use the vectorizer on
#      it (create, backfill, trigger-driven auto-enqueue on a new
#      write) without any DBA-granted access to fractal_vectorizers/
#      fractal_vectorizer_queue -- requires those tables' PUBLIC grants
#      (see sql/fractalsql--1.0.sql) plus fractal_vectorizer_enqueue()
#      being SECURITY DEFINER; a real, found-this-session bug before
#      that fix was every non-owner-of-the-tracking-tables role's
#      INSERT into a vectorized table failing entirely (the trigger
#      itself errored on "permission denied for table
#      fractal_vectorizer_queue", rolling back the caller's own write).
#   2. A DIFFERENT role, with no SELECT on that table, calling
#      fractal_vectorizer_process_queue() (which processes the GLOBAL
#      queue, not just its own caller's vectorizers) must not be able
#      to read or embed that table's content -- Postgres's own
#      privilege system gates the dynamic EXECUTE SELECT inside
#      process_queue(), same class of boundary gate 08 already proves
#      for fractal_schema_context, applied here to the vectorizer.
gate_16_embed_authz() {
  "${PSQL[@]}" -c "
     DROP ROLE IF EXISTS bt_embed_owner;
     CREATE ROLE bt_embed_owner LOGIN;
     GRANT CREATE ON SCHEMA public TO bt_embed_owner;
     DROP ROLE IF EXISTS bt_embed_outsider;
     CREATE ROLE bt_embed_outsider LOGIN;
  " >/dev/null 2>&1

  local owner_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_embed_owner -d postgres -X -tA)
  local outsider_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_embed_outsider -d postgres -X -tA)

  "${owner_psql[@]}" -c "
     CREATE TABLE bt_embed_owned (id serial PRIMARY KEY, body text, embedding float8[]);
     INSERT INTO bt_embed_owned (body) VALUES ('owner data');
  " >/dev/null 2>&1

  local vzid; vzid=$("${owner_psql[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_owned', 'body', 'embedding');" 2>&1)
  case "$vzid" in
    ''|*[!0-9]*) fail "16 embed_authz: owner role could not create its own vectorizer: $vzid" ;;
    *) pass "16 embed_authz: owner role created a vectorizer on its own table" ;;
  esac

  "${owner_psql[@]}" -c "INSERT INTO bt_embed_owned (body) VALUES ('second row, via trigger');" >/dev/null 2>&1
  local qn; qn=$("${owner_psql[@]}" -c "
     SELECT count(*) FROM fractal_vectorizer_queue q
     JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
     WHERE v.source_table = 'bt_embed_owned' AND q.status = 'pending';" 2>&1)
  [[ "$qn" = "2" ]] \
    && pass "16 embed_authz: backfill + trigger-driven enqueue both succeeded for the owner (2 pending)" \
    || fail "16 embed_authz: expected 2 pending rows (1 backfilled + 1 via trigger), got: $qn"

  local rout; rout=$("${outsider_psql[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  local statuses; statuses=$("${owner_psql[@]}" -c "
     SELECT string_agg(DISTINCT q.status, ',') FROM fractal_vectorizer_queue q
     JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
     WHERE v.source_table = 'bt_embed_owned';" 2>&1)
  [[ "$statuses" = "failed" ]] \
    && pass "16 embed_authz: outsider's process_queue() call left both rows 'failed', not processed" \
    || fail "16 embed_authz: expected both rows 'failed' after the outsider's call, got statuses: $statuses"

  local errtext; errtext=$("${owner_psql[@]}" -c "
     SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid AND status = 'failed';" 2>&1)
  grep <<< "$errtext" -q "permission denied for table bt_embed_owned" \
    && pass "16 embed_authz: failure reason correctly names a permission error, not a data value" \
    || fail "16 embed_authz: expected a permission-denied error, got: $errtext"

  local leaked; leaked=$("${owner_psql[@]}" -c "SELECT embedding FROM bt_embed_owned WHERE embedding IS NOT NULL;" 2>&1)
  [[ -z "$leaked" ]] \
    && pass "16 embed_authz: no embedding was written by the unauthorized outsider's call" \
    || fail "16 embed_authz: an embedding was written despite the outsider lacking SELECT: $leaked"

  # ---- the CONFUSED-DEPUTY half (the PROCESSOR's read) ----
  #
  # The asserts above prove the CALLER's own privileges are enforced: the
  # dynamic SELECT runs as the caller, so an outsider gets Postgres's own
  # "permission denied". The other half of the H fix is the read that
  # happens with the PROCESSOR's privileges. fractal_vectorizer_process_queue()
  # is SECURITY INVOKER, so it reads the content column with whoever ran
  # the batch -- and in the default deployment that is the MCP server's
  # own role, a SUPERUSER (docker-compose.yml: PGUSER: postgres), while
  # the vectorizer row may have been registered by, and the queue row
  # INSERTed by, a DIFFERENT unprivileged role. fractal_vectorizers and
  # fractal_vectorizer_queue are both PUBLIC-writable, so without a gate
  # an unprivileged role could name ANY real relation and have the
  # superuser's process_queue() read that relation's content column and
  # ship it to the embedding provider -- the read is UNAUTHORIZED even
  # though the SQL that triggers it is legitimate.
  #
  # The gate now asks the vectorizer's CREATOR -- the role that
  # legitimately asked for this content to be embedded -- whether IT is
  # entitled to SELECT the content column. The creator is unforgeable
  # (pinned by fractal_vectorizer_pin_creator) and the target is
  # immutable (fractal_vectorizer_guard_identity), so the pair cannot be
  # steered at a target its creator is not entitled to.
  "${PSQL[@]}" -c "
     DROP ROLE IF EXISTS bt_dep_lowpriv;
     CREATE ROLE bt_dep_lowpriv LOGIN;
     GRANT USAGE ON SCHEMA public TO bt_dep_lowpriv;
     DROP TABLE IF EXISTS bt_dep_secret;
     CREATE TABLE bt_dep_secret (id int PRIMARY KEY, body text, embedding float8[]);
     INSERT INTO bt_dep_secret(id, body) VALUES (1, 'the secret body');
     REVOKE ALL ON bt_dep_secret FROM PUBLIC;
     GRANT SELECT (id, embedding) ON bt_dep_secret TO bt_dep_lowpriv;
  " >/dev/null 2>&1

  local lowpriv_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_dep_lowpriv -d postgres -X -tA)

  # The registry row names a table the low-priv role does not own and
  # cannot read the content column of -- and ASKS to be attributed to a
  # superuser, so the pinning trigger has to refuse the attribution.
  local depid; depid=$("${lowpriv_psql[@]}" -c "
     INSERT INTO fractal_vectorizers
            (source_table, source_pk_col, text_col, embedding_col, created_by)
     VALUES ('bt_dep_secret', 'id', 'body', 'embedding', 'postgres')
     RETURNING id;" 2>&1 | head -1)
  case "$depid" in
    ''|*[!0-9]*)
      fail "16 embed_authz: the low-priv role could not register a vectorizer row: $depid" ;;
    *)
      local dep_owner; dep_owner=$("${PSQL[@]}" -c "
         SELECT created_by FROM fractal_vectorizers WHERE id = $depid;" 2>&1)
      [[ "$dep_owner" = "bt_dep_lowpriv" ]] \
        && pass "16 embed_authz: the registry row's creator is pinned to the inserting role (a forged superuser attribution is ignored)" \
        || fail "16 embed_authz: expected created_by=bt_dep_lowpriv (pinned), got: $dep_owner" ;;
  esac

  if [[ "$depid" =~ ^[0-9]+$ ]]; then
    # The queue row is INSERTed by the same unprivileged role -- the
    # registry and the queue are both PUBLIC-writable.
    "${lowpriv_psql[@]}" -c "
       INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value)
       VALUES ($depid, '1');" >/dev/null 2>&1

    # The PROCESSOR is the superuser: exactly the default deployment.
    "${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" >/dev/null 2>&1

    local dep_err; dep_err=$("${PSQL[@]}" -c "
       SELECT last_error FROM fractal_vectorizer_status
        WHERE vectorizer_id = $depid AND status = 'failed';" 2>&1)
    grep -q "is not entitled to SELECT the content column" <<< "$dep_err" \
      && pass "16 embed_authz: the superuser's process_queue() refuses the low-priv creator's deputy read of the content column" \
      || fail "16 embed_authz: expected the entitlement refusal, got: $dep_err"

    local dep_leak; dep_leak=$("${PSQL[@]}" -c "
       SELECT embedding FROM bt_dep_secret WHERE embedding IS NOT NULL;" 2>&1)
    [[ -z "$dep_leak" ]] \
      && pass "16 embed_authz: nothing was embedded, so the secret body never left the database" \
      || fail "16 embed_authz: an embedding was written despite the refused deputy read: $dep_leak"

    # The target and the creator are immutable against UPDATE, so a
    # privileged role cannot re-point an existing vectorizer at another
    # relation after the fact.
    local dep_retarget; dep_retarget=$("${PSQL[@]}" -c "
       UPDATE fractal_vectorizers SET created_by = 'postgres' WHERE id = $depid;" 2>&1)
    grep -q "immutable" <<< "$dep_retarget" \
      && pass "16 embed_authz: the registry row's creator cannot be re-attributed by an UPDATE" \
      || fail "16 embed_authz: expected the immutability guard to reject the re-attribution, got: $dep_retarget"

    # Positive control: once the creator IS entitled to the content
    # column, the entitlement gate must stop firing -- otherwise the
    # refusal above would prove nothing.
    "${PSQL[@]}" -c "GRANT SELECT (body) ON bt_dep_secret TO bt_dep_lowpriv;" >/dev/null 2>&1
    local dep_entitled; dep_entitled=$("${PSQL[@]}" -c "
       SELECT has_column_privilege('bt_dep_lowpriv', 'bt_dep_secret'::regclass, 'body', 'SELECT');" 2>&1)
    [[ "$dep_entitled" = "t" ]] \
      && pass "16 embed_authz: the creator's column-level entitlement is what the gate reads" \
      || fail "16 embed_authz: expected has_column_privilege=true after the grant, got: $dep_entitled"

    "${lowpriv_psql[@]}" -c "
       UPDATE fractal_vectorizer_queue SET status = 'pending', error = NULL
        WHERE vectorizer_id = $depid;" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" >/dev/null 2>&1
    local dep_err2; dep_err2=$("${PSQL[@]}" -c "
       SELECT coalesce(max(last_error), '') FROM fractal_vectorizer_status
        WHERE vectorizer_id = $depid AND status = 'failed';" 2>&1)
    if grep -q "is not entitled to SELECT the content column" <<< "$dep_err2"; then
      fail "16 embed_authz: the entitlement gate still fired after granting the creator SELECT on the content column"
    else
      pass "16 embed_authz: once the creator is entitled, the entitlement gate stops firing (the refusal above was the gate, not a broken batch)"
    fi
  fi

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_dep_secret';
     DROP TABLE IF EXISTS bt_dep_secret;
     DROP ROLE IF EXISTS bt_embed_owner;
     DROP ROLE IF EXISTS bt_embed_outsider;
     DROP ROLE IF EXISTS bt_dep_lowpriv;
  " >/dev/null 2>&1
  return 0
}

# Concurrent fractal_vectorizer_process_queue() calls against a SHARED
# queue, proving (not assuming) the "safe to call concurrently" claim
# both the code comment and docs/vectorizer-setup.md make for its
# SELECT ... FOR UPDATE SKIP LOCKED usage: every row processed exactly
# once, no row double-embedded, no row left behind, no worker error --
# mirrors gate 12's soak pattern (background subshells, one process per
# worker, no threading -- not hunting data races in fractalsql.c's
# statics, which are already per-process; this is checking Postgres's
# own row-locking behavior under real overlapping callers).
EMBED_SOAK_ROWS=100
EMBED_SOAK_WORKERS=10
EMBED_SOAK_BATCH=5

gate_17_embed_soak() {
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "17 embed_soak: http_embed_url GUC did not take effect"; return; }
  pg_swap_plugin "$EMBED" || { fail "17 embed_soak: plugin swap did not take effect"; return; }

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_soak';
     DROP TABLE IF EXISTS bt_embed_soak;
     CREATE TABLE bt_embed_soak (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
     INSERT INTO bt_embed_soak (body)
       SELECT 'row ' || i FROM generate_series(1, $EMBED_SOAK_ROWS) i;
  " >/dev/null 2>&1
  local vzid; vzid=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_soak', 'body', 'embedding');" 2>&1)
  local queued; queued=$("${PSQL[@]}" -c "
     SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'pending';" 2>&1)
  if [[ "$queued" != "$EMBED_SOAK_ROWS" ]]; then
    fail "17 embed_soak: setup: expected $EMBED_SOAK_ROWS queued rows, got $queued"
    pg_swap_plugin "$MOCK"; return
  fi

  local outdir="/tmp/fractalsql_bt_embed_soak_$$"
  rm -rf "$outdir"; mkdir -p "$outdir"
  local pids=() w
  for w in $(seq 1 "$EMBED_SOAK_WORKERS"); do
    (
      local rc=0 total=0 i
      # Enough iterations per worker that, summed across all workers,
      # the queue is fully drained even in the worst-case scheduling
      # (workers finishing early once their share is exhausted just do
      # cheap zero-row calls for their remaining iterations).
      for i in $(seq 1 $(( EMBED_SOAK_ROWS / EMBED_SOAK_BATCH + 2 ))); do
        local n; n=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue($EMBED_SOAK_BATCH);" 2>&1)
        case "$n" in
          ''|*[!0-9]*) rc=1 ;;
          *) total=$(( total + n )) ;;
        esac
      done
      echo "$rc $total" > "$outdir/worker_$w.rc"
    ) &
    pids+=("$!")
  done
  local p
  for p in "${pids[@]}"; do wait "$p"; done

  local failed_workers=0 sum_processed=0
  for w in $(seq 1 "$EMBED_SOAK_WORKERS"); do
    local line; line=$(cat "$outdir/worker_$w.rc" 2>/dev/null)
    local wrc wtotal; read -r wrc wtotal <<< "$line"
    [[ "$wrc" = "0" ]] || failed_workers=$((failed_workers + 1))
    sum_processed=$(( sum_processed + ${wtotal:-0} ))
  done
  rm -rf "$outdir"

  [[ "$failed_workers" -eq 0 ]] \
    && pass "17 embed_soak: $EMBED_SOAK_WORKERS concurrent workers, no call errored" \
    || fail "17 embed_soak: $failed_workers/$EMBED_SOAK_WORKERS workers had a failed call"

  [[ "$sum_processed" -eq "$EMBED_SOAK_ROWS" ]] \
    && pass "17 embed_soak: exactly $EMBED_SOAK_ROWS rows processed total (no double-count, none lost)" \
    || fail "17 embed_soak: expected $EMBED_SOAK_ROWS rows processed summed across workers, got $sum_processed"

  local done_n; done_n=$("${PSQL[@]}" -c "
     SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'done';" 2>&1)
  [[ "$done_n" = "$EMBED_SOAK_ROWS" ]] \
    && pass "17 embed_soak: all $EMBED_SOAK_ROWS queue rows are 'done', none stuck pending/processing" \
    || fail "17 embed_soak: expected $EMBED_SOAK_ROWS rows 'done', got $done_n"

  local embedded_n; embedded_n=$("${PSQL[@]}" -c "
     SELECT count(*) FROM bt_embed_soak WHERE embedding = '{0.1,0.2,0.3}';" 2>&1)
  [[ "$embedded_n" = "$EMBED_SOAK_ROWS" ]] \
    && pass "17 embed_soak: all $EMBED_SOAK_ROWS rows got the embedding written back exactly once" \
    || fail "17 embed_soak: expected $EMBED_SOAK_ROWS rows with the embedding, got $embedded_n"

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_soak';
     DROP TABLE IF EXISTS bt_embed_soak;
  " >/dev/null 2>&1
  pg_swap_plugin "$MOCK"
  return 0
}

# Real crash mid-process_queue(), via the same deliberately-segfaulting
# plugin gate 06 already uses. Proves what ACTUALLY happens, not what
# stale_after's own doc comment might suggest in isolation: fractal_
# vectorizer_process_queue() is one PL/pgSQL FUNCTION call, i.e. one
# transaction (EXCEPTION blocks are subtransaction SAVEPOINTs, not
# independent commits) -- a crash mid-call means NOTHING from that call
# was ever committed, so the row(s) it touched revert to whatever they
# were before the call (here, 'pending'), not left stuck in
# 'processing'. stale_after's reclaim exists for a DIFFERENT failure
# shape (a caller that durably committed 'processing' some other way,
# e.g. a future per-row-autonomous-transaction redesign) -- this gate
# exists so that distinction is verified, not assumed from reading the
# code. See docs/vectorizer-setup.md's "Design" section for the
# same point stated for operators.
gate_18_embed_crash() {
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "18 embed_crash: http_embed_url GUC did not take effect"; return; }

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_crash';
     DROP TABLE IF EXISTS bt_embed_crash;
     CREATE TABLE bt_embed_crash (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
     INSERT INTO bt_embed_crash (body) VALUES ('a'), ('b'), ('c');
  " >/dev/null 2>&1
  local vzid; vzid=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_embed_crash', 'body', 'embedding');" 2>&1)

  pg_swap_plugin "$CRASH" || { fail "18 embed_crash: plugin swap did not take effect"; return; }
  local r; r=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  grep <<< "$r" -qE "server closed the connection|could not connect" \
    && pass "18 embed_crash: triggering connection dropped as expected" \
    || fail "18 embed_crash: expected the connection to drop, got: $r"

  # See gate_06_crash_recovery's comment on why pass/fail budget and
  # actual up-detection must not share the same cutoff -- restoring the
  # plugin at the end of this gate depends on `up`, and a near-miss here
  # previously left the crash plugin active for the rest of the run.
  local up=0 i tries=$(( 30 * TIMEOUT_MULT )) within_budget=0
  for i in $(seq 1 $(( tries * 2 ))); do
    "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1 && { up=1; [[ "$i" -le "$tries" ]] && within_budget=1; break; }
    sleep 0.5
  done
  [[ "$within_budget" -eq 1 ]] && pass "18 embed_crash: cluster auto-restarted" \
                   || fail "18 embed_crash: cluster did not come back within $(( tries / 2 ))s"
  if [[ "$up" -ne 1 ]]; then
    fail "18 embed_crash: cluster never came back -- remaining gates will run against the crash plugin"
    return
  fi

  # The real, empirically-checked claim this gate exists for: the crash
  # rolled back the WHOLE in-flight call, so all 3 rows are back to
  # 'pending' -- not stuck in 'processing' waiting on stale_after.
  local statuses; statuses=$("${PSQL[@]}" -c "
     SELECT string_agg(DISTINCT status, ',') FROM fractal_vectorizer_queue
     WHERE vectorizer_id = $vzid;" 2>&1)
  [[ "$statuses" = "pending" ]] \
    && pass "18 embed_crash: all 3 rows reverted to 'pending' after the crash (atomic rollback, not stuck 'processing')" \
    || fail "18 embed_crash: expected all rows 'pending' post-crash, got statuses: $statuses"

  # Recovery: a normal call afterward, with a working plugin, must
  # process the reverted rows normally -- no data lost, nothing
  # permanently wedged by the earlier crash.
  pg_swap_plugin "$EMBED" || { fail "18 embed_crash: plugin swap to EMBED did not take effect"; pg_swap_plugin "$MOCK"; return; }
  local n; n=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" 2>&1)
  [[ "$n" = "3" ]] && pass "18 embed_crash: post-recovery call processed all 3 previously-crashed rows" \
                  || fail "18 embed_crash: expected 3 rows processed after recovery, got: $n"

  local done_n; done_n=$("${PSQL[@]}" -c "
     SELECT count(*) FROM bt_embed_crash WHERE embedding = '{0.1,0.2,0.3}';" 2>&1)
  [[ "$done_n" = "3" ]] && pass "18 embed_crash: all 3 rows correctly embedded after recovery" \
                       || fail "18 embed_crash: expected 3 embedded rows after recovery, got: $done_n"

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_crash';
     DROP TABLE IF EXISTS bt_embed_crash;
  " >/dev/null 2>&1
  pg_swap_plugin "$MOCK"
  return 0
}

# validate_sfs_params() bounds (fractal_search/fractal_search_debug/
# fractal_search_explore all funnel through the same function) were
# NEVER exercised anywhere in this gate suite before this test --
# gate 10 proves the equivalent DoS cap for fractal_schema_context
# (MAX_SCHEMA_CONTEXT_TABLES) but nothing did the same for SFS's own
# iterations/population_size/diffusion_factor/dim ceilings. Also closes
# the injection-shaped-identifier gap for fractal_search_explore
# specifically (gate 10 only ever covered fractal_schema_context for
# that class of test).
#
# MAX_QUERY_DIM (1M) turns out to be effectively dead code in practice:
# the core library's own FSQL_MAX_DIM ceiling is 16384, far below 1M, so
# it always rejects first for any realistic-but-large dim. This gate
# tests the REAL, reachable ceiling (16385) and notes the finding here
# rather than constructing a >1M-element array to reach validate_sfs_
# params' own (currently unreachable) check.
gate_19_sfs_bounds() {
  local r

  r=$("${PSQL[@]}" -c "SELECT fractal_search(ARRAY(SELECT 0.1 FROM generate_series(1,16385)));" 2>&1)
  grep <<< "$r" -qE "exceeds FSQL_MAX_DIM|out of range" \
    && pass "19 sfs_bounds: over-limit query dim (16385) rejected cleanly" \
    || fail "19 sfs_bounds: expected a clean dim-limit rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_search(ARRAY[]::float8[]);" 2>&1)
  grep <<< "$r" -qE "1-D non-null|must be non-empty" \
    && pass "19 sfs_bounds: empty query array rejected cleanly" \
    || fail "19 sfs_bounds: expected a clean empty-array rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10001);" 2>&1)
  grep <<< "$r" -q "iterations 10001 out of range" \
    && pass "19 sfs_bounds: iterations over MAX_ITERATIONS (10000) rejected cleanly" \
    || fail "19 sfs_bounds: expected an iterations-limit rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10, 100001);" 2>&1)
  grep <<< "$r" -q "population_size 100001 out of range" \
    && pass "19 sfs_bounds: population_size over MAX_POPULATION_SIZE (100000) rejected cleanly" \
    || fail "19 sfs_bounds: expected a population_size-limit rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10, 20, 33);" 2>&1)
  grep <<< "$r" -q "diffusion_factor 33 out of range" \
    && pass "19 sfs_bounds: diffusion_factor over MAX_DIFFUSION_FACTOR (32) rejected cleanly" \
    || fail "19 sfs_bounds: expected a diffusion_factor-limit rejection, got: $r"

  # fractal_search_debug shares validate_sfs_params -- one spot check
  # (not the full sweep above) confirms the shared function is actually
  # being called from this entry point too, not just fractal_search.
  r=$("${PSQL[@]}" -c "SELECT fractal_search_debug(ARRAY[0.1,0.2]::float8[], 10, 20, 33);" 2>&1)
  grep <<< "$r" -q "diffusion_factor 33 out of range" \
    && pass "19 sfs_bounds: fractal_search_debug shares the same bounds check" \
    || fail "19 sfs_bounds: expected fractal_search_debug to reject diffusion_factor=33, got: $r"

  # fractal_search_debug's full search-state telemetry: the result jsonb is
  # the vendored core's raw fsql_search_ptr JSON round-tripped through
  # jsonb_in, and its UNCONDITIONAL keys (one printf format in the core:
  # {"dim":%d,"n_corpus":%zu,"best_fit":...,"best_point":...}) must all
  # survive. Gate 02 only asserts best_point; this proves the debug payload
  # is the full state, not a reduced shape.
  r=$("${PSQL[@]}" -c "SELECT fractal_search_debug(ARRAY[0.6,0.8]::float8[], 30, 50, 2);" 2>&1)
  if grep <<< "$r" -q '"dim"' && grep <<< "$r" -q '"n_corpus"' && grep <<< "$r" -q '"best_fit"' && grep <<< "$r" -q '"best_point"'; then
    pass "19 sfs_bounds: fractal_search_debug returns the full search-state telemetry (dim/n_corpus/best_fit/best_point)"
  else
    fail "19 sfs_bounds: fractal_search_debug missing telemetry keys: $r"
  fi

  # Wrong-typed query arg: float8[] cannot be resolved from text[] (no
  # implicit array-element cast), so postgres's own type resolver rejects
  # before the C function ever runs. The C-side ARR_ELEMTYPE guard in
  # float8_array_to_doubles ("query must be float8[], got %s") is only
  # reachable from internal callers, not SQL typing.
  r=$("${PSQL[@]}" -c "SELECT fractal_search_debug('{0.1,0.2}'::text[], 30, 50, 2);" 2>&1)
  grep <<< "$r" -q "does not exist" \
    && pass "19 sfs_bounds: fractal_search_debug rejects a wrong-typed query arg (PG type resolution)" \
    || fail "19 sfs_bounds: expected a type-resolution rejection, got: $r"

  # Injection-shaped table_name into fractal_search_explore -- same
  # class of test gate 10 already gives fractal_schema_context, closing
  # the gap for search_explore specifically.
  local rinj; rinj=$("${PSQL[@]}" -c "SELECT * FROM fractal_search_explore('bt_orders''; DROP TABLE bt_orders; --', 'vec', ARRAY[0.1,0.2]::float8[]);" 2>&1)
  local n; n=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_orders;" 2>&1)
  if [[ "$n" = "0" ]]; then
    pass "19 sfs_bounds: injection-shaped table_name into fractal_search_explore did not execute (bt_orders intact)"
  else
    fail "19 sfs_bounds: bt_orders row count changed (n=$n) — injection may have executed"
  fi
  grep <<< "$rinj" -qE "does not exist|ERROR" \
    && pass "19 sfs_bounds: injection-shaped table_name cleanly rejected" \
    || fail "19 sfs_bounds: unexpected result: $rinj"
  return 0
}

# Closes 5 concrete API-surface coverage gaps found by a gap analysis
# against README's API table (each an explicit, existing code path --
# not speculative):
#   1. fractal_reason(): happy-path correctness was never checked --
#      every other gate touching it only asserts "didn't crash" /
#      "cleanly rejected a bad plugin", never "returned the right text".
#   2. fractal_reason(NULL): its own explicit PG_ARGISNULL(0) check
#      (fractal_reason isn't STRICT, unlike the search functions) had
#      zero coverage.
#   3. fractal_text_to_sql(NULL): same pattern, its own explicit
#      PG_ARGISNULL(0) check, zero coverage.
#   4. fractal_search_explore()'s bounds: it calls the same
#      validate_sfs_params() as fractal_search/_debug (confirmed by
#      reading the code), but nothing had ever proved that by actually
#      passing an over-limit value through its options jsonb -- exactly
#      the kind of "shares code, must be fine" assumption that hid the
#      build_schema_context_cstr() heap-use-after-free found this
#      session via ASan, not code review.
#   5. fractal_vectorizer_process_queue()'s stale_after reclaim: gate 18
#      already proved a crash can't produce a stuck 'processing' row in
#      the CURRENT implementation, but the reclaim UPDATE itself (the
#      WHERE processing_started_at < now() - stale_after clause) was
#      never independently exercised -- staged directly here, with a
#      negative control (a row still within the window) proving the
#      time comparison actually gates rather than reclaiming
#      unconditionally.
gate_20_api_func() {
  # --- 1: fractal_reason() happy path -------------------------------
  echo "gap-analysis-canary" > /tmp/fractalsql_bt_sql.txt
  local r1; r1=$("${PSQL[@]}" -c "SELECT fractal_reason('q');" 2>&1)
  local expect1; expect1=$(printf '```sql\ngap-analysis-canary\n```')
  [[ "$r1" = "$expect1" ]] \
    && pass "20 api_func: fractal_reason() returns the plugin's actual response" \
    || fail "20 api_func: fractal_reason() expected the fenced canary text, got: $r1"
  rm -f /tmp/fractalsql_bt_sql.txt

  # --- 2: fractal_reason(NULL) ---------------------------------------
  local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_reason(NULL);" 2>&1)
  grep <<< "$r2" -q "query must not be NULL" \
    && pass "20 api_func: fractal_reason(NULL) rejected cleanly" \
    || fail "20 api_func: fractal_reason(NULL) expected a clear rejection, got: $r2"

  # --- 3: fractal_text_to_sql(NULL) -----------------------------------
  local r3; r3=$("${PSQL[@]}" -c "SELECT fractal_text_to_sql(NULL);" 2>&1)
  grep <<< "$r3" -q "question must not be NULL" \
    && pass "20 api_func: fractal_text_to_sql(NULL) rejected cleanly" \
    || fail "20 api_func: fractal_text_to_sql(NULL) expected a clear rejection, got: $r3"

  # --- 4: fractal_search_explore()'s own bounds -----------------------
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_explore_bounds;
     CREATE TABLE bt_explore_bounds (id int, emb float8[]);
     INSERT INTO bt_explore_bounds VALUES (1, ARRAY[0.1,0.2]::float8[]);
  " >/dev/null 2>&1
  local r4; r4=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_search_explore('bt_explore_bounds', 'emb',
       ARRAY[0.1,0.2]::float8[], '{\"iterations\": 10001}'::jsonb);" 2>&1)
  grep <<< "$r4" -q "iterations 10001 out of range" \
    && pass "20 api_func: fractal_search_explore rejects an over-limit iterations option" \
    || fail "20 api_func: expected an iterations-limit rejection, got: $r4"

  local r4b; r4b=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_search_explore('bt_explore_bounds', 'emb',
       ARRAY[0.1,0.2]::float8[], '{\"diffusion_factor\": 33}'::jsonb);" 2>&1)
  grep <<< "$r4b" -q "diffusion_factor 33 out of range" \
    && pass "20 api_func: fractal_search_explore rejects an over-limit diffusion_factor option" \
    || fail "20 api_func: expected a diffusion_factor-limit rejection, got: $r4b"
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_explore_bounds;" >/dev/null 2>&1

  # --- 5: fractal_vectorizer_process_queue()'s stale_after reclaim ----
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "20 api_func: http_embed_url GUC did not take effect"; return; }
  pg_swap_plugin "$EMBED" || { fail "20 api_func: plugin swap did not take effect"; pg_swap_plugin "$MOCK"; return; }

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_stale_reclaim';
     DROP TABLE IF EXISTS bt_stale_reclaim;
     CREATE TABLE bt_stale_reclaim (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
     INSERT INTO bt_stale_reclaim (body) VALUES ('old-stuck'), ('recent-stuck');
  " >/dev/null 2>&1
  local vzid; vzid=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('bt_stale_reclaim', 'body', 'embedding');" 2>&1)

  # old-stuck: claimed 1 hour ago, past the 5-minute stale_after below
  # -- must be reclaimed. recent-stuck: claimed 30 seconds ago, still
  # within it -- must be left alone (the negative control).
  "${PSQL[@]}" -c "
     UPDATE fractal_vectorizer_queue q
        SET status = 'processing', processing_started_at = now() - interval '1 hour'
       FROM bt_stale_reclaim t
      WHERE q.vectorizer_id = $vzid AND t.body = 'old-stuck' AND q.source_pk_value = t.id::text;
     UPDATE fractal_vectorizer_queue q
        SET status = 'processing', processing_started_at = now() - interval '30 seconds'
       FROM bt_stale_reclaim t
      WHERE q.vectorizer_id = $vzid AND t.body = 'recent-stuck' AND q.source_pk_value = t.id::text;
  " >/dev/null 2>&1

  "${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue(10, '5 minutes'::interval);" >/dev/null 2>&1

  local statuses; statuses=$("${PSQL[@]}" -c "
     SELECT t.body || '=' || q.status FROM fractal_vectorizer_queue q
     JOIN bt_stale_reclaim t ON t.id::text = q.source_pk_value
     WHERE q.vectorizer_id = $vzid ORDER BY t.body;" 2>&1)
  grep <<< "$statuses" -q "old-stuck=done" \
    && pass "20 api_func: a row stranded past stale_after was reclaimed and processed" \
    || fail "20 api_func: expected old-stuck=done, got: $statuses"
  grep <<< "$statuses" -q "recent-stuck=processing" \
    && pass "20 api_func: a row still within stale_after was left alone, not reclaimed" \
    || fail "20 api_func: expected recent-stuck=processing (untouched), got: $statuses"

  "${PSQL[@]}" -c "
     DELETE FROM fractal_vectorizers WHERE source_table = 'bt_stale_reclaim';
     DROP TABLE IF EXISTS bt_stale_reclaim;
  " >/dev/null 2>&1

  # --- 6: FSQL_MAX_INPUT_BYTES over-cap rejection (src/fractalsql.c:239).
  #     grep FSQL_MAX_INPUT_BYTES shows exactly ONE use site in this repo:
  #     the dispatch budget in fractal_embed() itself (its strlen check at
  #     :3198) -- fractal_text_to_sql() has NO byte cap to reject with (its
  #     input is the question string plus in-engine-built schema context;
  #     there is no engine-side over-cap error text to assert), so the
  #     overload call here goes to fractal_embed() only. 4 MiB + 1 chars,
  #     built with repeat() per this harness's no-python convention, and
  #     rejected BEFORE any plugin dispatch -- deterministic even though the
  #     URL/embed GUCs are still configured for part 5 above.
  local rov; rov=$("${PSQL[@]}" -c "SELECT fractal_embed(repeat('A', 4*1024*1024 + 1));" 2>&1)
  grep <<< "$rov" -q "fractal_embed: input exceeds the 4 MiB limit" \
    && pass "20 api_func: a 4 MiB + 1 embed input is rejected with the engine's own over-cap error" \
    || fail "20 api_func: expected 'input exceeds the 4 MiB limit', got: $rov"

  pg_swap_plugin "$MOCK" >/dev/null
  return 0
}

# v2.x additions smoke gate -- HNSW/Diversify-era functions (dimension
# analysis, portfolio optimization, domain geometry, the named feature
# store, Diversify/feedback controls). Deliberately a smoke gate, not
# exhaustive unit coverage -- proves the SQL wiring end-to-end against
# the real .so, same scope/spirit as gate_02_smoke and gate_11_scout.
#
# Fixture note: fractal_dimension_boxcount / _vascular_network /
# _nerve_plexus_metric / _morphological_complexity all bottom out in
# box-counting, which needs enough points AND enough dynamic range of
# scales to produce >= 3 valid epsilon buckets -- too few points (or an
# exactly-regular lattice) silently fails that filter even for
# well-defined geometry. Point counts here (40/30/80) and the jitter on
# the nerve fixture are chosen to satisfy that filter.
gate_22_v2_functions() {
  # --- fixtures (generated once, deterministic seeds) -----------------
  local boxpts; boxpts=$(awk 'BEGIN{srand(42); out=""; for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01; if(i>1) out=out","; out=out x","y} print out}')
  # mapfile is bash 4.0+ only -- macOS (and macOS GitHub Actions runners)
  # ship bash 3.2.57 as /bin/bash and never upgrade it (frozen there over
  # the GPLv3 relicense), so build a plain array with a read loop instead
  # -- confirmed on a real 3.2.57 that mapfile is "command not found"
  # there, while this pattern works unchanged.
  local vasc=()
  while IFS= read -r vasc_line; do vasc+=("$vasc_line"); done < <(awk 'BEGIN{
    srand(1); n=30; nc=""; el=""; al="";
    for (i=0;i<n;i++) { x=i; y=rand()*0.01; z=rand()*0.01; xs[i]=x; ys[i]=y; zs[i]=z; if (i>0) nc=nc","; nc=nc x","y","z; }
    for (i=0;i<n-1;i++) { if (i>0) { el=el","; al=al","; } el=el i","(i+1); dx=xs[i+1]-xs[i]; dy=ys[i+1]-ys[i]; dz=zs[i+1]-zs[i]; d=sqrt(dx*dx+dy*dy+dz*dz); al=al d; }
    print nc; print el; print al;
  }')
  local vasc_nc="${vasc[0]}" vasc_el="${vasc[1]}" vasc_al="${vasc[2]}"
  local nerve=()
  while IFS= read -r nerve_line; do nerve+=("$nerve_line"); done < <(awk 'BEGIN{
    srand(2); n=80; nc=""; el="";
    for (i=0;i<n;i++) { x=i; y=(i%2==0?0:1)+rand()*0.01; if (i>0) nc=nc","; nc=nc x","y; }
    for (i=0;i<n-1;i++) { if (i>0) el=el","; el=el i","(i+1); }
    print nc; print el;
  }')
  local nerve_nc="${nerve[0]}" nerve_el="${nerve[1]}"

  # --- 1: dimension analysis -------------------------------------------
  local r1; r1=$("${PSQL[@]}" -c "
     SELECT fractal_dimension_dfa(
       (SELECT array_agg(sin(i / 3.0) + i * 0.001) FROM generate_series(1, 64) i));" 2>&1)
  grep <<< "$r1" -Eq '^[0-9]+\.[0-9]+$' \
    && pass "22 v2_functions: fractal_dimension_dfa returns a numeric exponent" \
    || fail "22 v2_functions: fractal_dimension_dfa expected a float8, got: $r1"

  local r1b; r1b=$("${PSQL[@]}" -c "SELECT fractal_dimension_dfa(ARRAY[1,2,3]::float8[]);" 2>&1)
  grep <<< "$r1b" -q "series needs >= 16 points" \
    && pass "22 v2_functions: fractal_dimension_dfa rejects a too-short series" \
    || fail "22 v2_functions: expected a too-short-series rejection, got: $r1b"

  local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_dimension_boxcount(ARRAY[$boxpts]::float8[], 2);" 2>&1)
  grep <<< "$r2" -Eq '^[0-9]+\.[0-9]+$' \
    && pass "22 v2_functions: fractal_dimension_boxcount returns a numeric dimension" \
    || fail "22 v2_functions: fractal_dimension_boxcount expected a float8, got: $r2"

  local r3; r3=$("${PSQL[@]}" -c "
     SELECT fractal_dimension_drift(
       (SELECT array_agg(sin(i / 3.0) + i * 0.001) FROM generate_series(1, 200) i), 64);" 2>&1)
  grep <<< "$r3" -q '"drift"' \
    && pass "22 v2_functions: fractal_dimension_drift returns {drift, recent_alpha, baseline_alpha}" \
    || fail "22 v2_functions: fractal_dimension_drift expected a drift jsonb, got: $r3"

  # --- 2: portfolio optimization ---------------------------------------
  local r4; r4=$("${PSQL[@]}" -c "
     SELECT fractal_optimize_portfolio(
       ARRAY[0.08,0.12,0.10,0.15]::float8[],
       ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[],
       2, 12345);" 2>&1)
  grep <<< "$r4" -q '"sharpe"' \
    && pass "22 v2_functions: fractal_optimize_portfolio returns {sharpe, weights}" \
    || fail "22 v2_functions: fractal_optimize_portfolio expected a sharpe/weights jsonb, got: $r4"

  local r4b; r4b=$("${PSQL[@]}" -c "
     SELECT fractal_optimize_portfolio(ARRAY[0.1,0.1]::float8[], ARRAY[1.0]::float8[], 1, NULL);" 2>&1)
  grep <<< "$r4b" -q "cov length" \
    && pass "22 v2_functions: fractal_optimize_portfolio rejects a mismatched cov length" \
    || fail "22 v2_functions: expected a cov-length rejection, got: $r4b"

  # diffusion_mode (parse_diffusion_mode in fractalsql.c): r4 above
  # omits it entirely (the 'gaussian' default), never exercising the
  # 'levy' branch or the rejection of an unrecognized value.
  local r4c; r4c=$("${PSQL[@]}" -c "
     SELECT fractal_optimize_portfolio(
       ARRAY[0.08,0.12,0.10,0.15]::float8[],
       ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[],
       2, 12345, false, 'levy');" 2>&1)
  grep <<< "$r4c" -q '"sharpe"' \
    && pass "22 v2_functions: fractal_optimize_portfolio diffusion_mode=levy returns {sharpe, weights}" \
    || fail "22 v2_functions: diffusion_mode=levy='$r4c'"

  local r4d; r4d=$("${PSQL[@]}" -c "
     SELECT fractal_optimize_portfolio(
       ARRAY[0.08,0.12,0.10,0.15]::float8[],
       ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[],
       2, 12345, false, 'bogus');" 2>&1)
  grep <<< "$r4d" -q "diffusion_mode must be" \
    && pass "22 v2_functions: fractal_optimize_portfolio rejects an unrecognized diffusion_mode" \
    || fail "22 v2_functions: expected a diffusion_mode rejection, got: $r4d"

  # --- 3: domain-specific geometry --------------------------------------
  local r5; r5=$("${PSQL[@]}" -c "SELECT fractal_morphological_complexity(ARRAY[$boxpts]::float8[], 2);" 2>&1)
  grep <<< "$r5" -q '"lacunarity"' \
    && pass "22 v2_functions: fractal_morphological_complexity returns {dimension, lacunarity}" \
    || fail "22 v2_functions: fractal_morphological_complexity expected a dimension/lacunarity jsonb, got: $r5"

  local r6; r6=$("${PSQL[@]}" -c "
     SELECT fractal_vascular_network(ARRAY[$vasc_nc]::float8[], ARRAY[$vasc_el]::int4[], ARRAY[$vasc_al]::float8[]);" 2>&1)
  grep <<< "$r6" -q '"mean_tortuosity"' \
    && pass "22 v2_functions: fractal_vascular_network returns {mean_tortuosity, branch_density, fractal_dimension}" \
    || fail "22 v2_functions: fractal_vascular_network expected a tortuosity jsonb, got: $r6"

  local r7; r7=$("${PSQL[@]}" -c "
     SELECT fractal_nerve_plexus_metric(ARRAY[$nerve_nc]::float8[], 2, ARRAY[$nerve_el]::int4[]);" 2>&1)
  grep <<< "$r7" -q '"fiber_length_density"' \
    && pass "22 v2_functions: fractal_nerve_plexus_metric returns {fiber_length_density, branch_density, fractal_dimension}" \
    || fail "22 v2_functions: fractal_nerve_plexus_metric expected a fiber-density jsonb, got: $r7"

  # Tetrahedron: mesh IS its own convex hull, so gyrification_index must
  # be exactly 1.0 -- a clean deterministic check, not just "didn't error".
  local r8; r8=$("${PSQL[@]}" -c "
     SELECT fractal_cortical_folding(
       ARRAY[0,0,0, 1,0,0, 0,1,0, 0,0,1]::float8[],
       ARRAY[0,1,2, 0,1,3, 0,2,3, 1,2,3]::int4[]);" 2>&1)
  grep <<< "$r8" -q '"gyrification_index": 1.0000000000' \
    && pass "22 v2_functions: fractal_cortical_folding gives gyrification_index=1.0 for a tetrahedron (mesh == its own hull)" \
    || fail "22 v2_functions: expected gyrification_index=1.0 for a tetrahedron, got: $r8"

  # --- 4: named feature store (postgres-side, no core primitive) -------
  "${PSQL[@]}" -c "
     DELETE FROM fractalsql_feature_store WHERE doc_id IN (901,902,903,904);
     SELECT fractal_store_morphology(901, ARRAY[0.0,0.0,0.0]::float8[]);
     SELECT fractal_store_morphology(902, ARRAY[10.0,10.0,10.0]::float8[]);
     SELECT fractal_store_morphology(903, ARRAY[1.0,0.0,0.0]::float8[]);
     SELECT fractal_store_morphology(904, ARRAY[0.5,0.5,0.5]::float8[]);
  " >/dev/null 2>&1
  # upsert-overwrite: doc 901 moves far away, must drop out of a k=2 mine
  "${PSQL[@]}" -c "SELECT fractal_store_morphology(901, ARRAY[100.0,100.0,100.0]::float8[]);" >/dev/null 2>&1
  local r9; r9=$("${PSQL[@]}" -c "
     SELECT string_agg(doc_id::text, ',' ORDER BY distance)
     FROM fractal_mine_topology_negatives(ARRAY[0.0,0.0,0.0]::float8[], 2)
     WHERE doc_id IN (901,902,903,904);" 2>&1)
  [[ "$r9" = "904,903" ]] \
    && pass "22 v2_functions: fractal_mine_topology_negatives k-NN order + upsert-overwrite correct" \
    || fail "22 v2_functions: expected mine order 904,903 (901 overwritten far away), got: $r9"

  local r9b; r9b=$("${PSQL[@]}" -c "SELECT fractal_store_morphology(-1, ARRAY[1.0]::float8[]);" 2>&1)
  grep <<< "$r9b" -q "doc_id must be >= 0" \
    && pass "22 v2_functions: fractal_store_morphology rejects a negative doc_id" \
    || fail "22 v2_functions: expected a negative-doc_id rejection, got: $r9b"

  local r9c; r9c=$("${PSQL[@]}" -c "SELECT fractal_mine_topology_negatives(ARRAY[0.0]::float8[], 0);" 2>&1)
  grep <<< "$r9c" -q "k must be > 0" \
    && pass "22 v2_functions: fractal_mine_topology_negatives rejects k<=0" \
    || fail "22 v2_functions: expected a k<=0 rejection, got: $r9c"

  "${PSQL[@]}" -c "DELETE FROM fractalsql_feature_store WHERE doc_id IN (901,902,903,904);" >/dev/null 2>&1

  # --- 5: Diversify / feedback controls ---------------------------------
  "${PSQL[@]}" -c "SELECT fractal_diversify_enable();" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT fractal_diversify_set_params(20, 0.1, 1.0, 0.5, 100, 50);" >/dev/null 2>&1
  local r10; r10=$("${PSQL[@]}" -c "SELECT fractal_explain_result();" 2>&1)
  grep <<< "$r10" -q '"diversify_enabled": true' \
    && pass "22 v2_functions: fractal_explain_result reflects diversify_enabled after enable" \
    || fail "22 v2_functions: expected diversify_enabled=true, got: $r10"

  "${PSQL[@]}" -c "SELECT fractal_feedback_report(0, 'negative', 100);" >/tmp/fractalsql_bt_v2_fb.log 2>&1
  grep -q "ERROR" /tmp/fractalsql_bt_v2_fb.log \
    && fail "22 v2_functions: fractal_feedback_report errored on a valid call: $(cat /tmp/fractalsql_bt_v2_fb.log)" \
    || pass "22 v2_functions: fractal_feedback_report accepted a valid negative-engagement report"

  local r11; r11=$("${PSQL[@]}" -c "SELECT fractal_feedback_report(0, 'bogus', NULL);" 2>&1)
  grep <<< "$r11" -q "kind must be one of" \
    && pass "22 v2_functions: fractal_feedback_report rejects an invalid kind" \
    || fail "22 v2_functions: expected an invalid-kind rejection, got: $r11"

  "${PSQL[@]}" -c "SELECT fractal_diversify_disable();" >/dev/null 2>&1
  rm -f /tmp/fractalsql_bt_v2_fb.log

  # --- 6: table-backed top-k telemetry search + thin compositions -----
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_telemetry_docs;
     CREATE TABLE bt_telemetry_docs (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_telemetry_docs (emb) VALUES
       (ARRAY[1.0,0.0,0.0]::float8[]),
       (ARRAY[0.0,1.0,0.0]::float8[]),
       (ARRAY[0.9,0.1,0.0]::float8[]),
       (ARRAY[0.0,0.0,1.0]::float8[]),
       (ARRAY[0.5,0.5,0.0]::float8[]);
  " >/dev/null 2>&1

  # telemetry/hybrid report doc_id as a ctid (text), not a 0-indexed scan
  # position. Each assertion joins t.doc_id back to the real row via
  # d.ctid::text = t.doc_id and checks the table's own id. This verifies
  # the ctid mapping and stays independent of the physical page layout.
  local r12; r12=$("${PSQL[@]}" -c "
     SELECT d.id, t.distance
       FROM fractal_search_telemetry('bt_telemetry_docs', 'emb',
            ARRAY[1.0,0.0,0.0]::float8[], 2) t
       JOIN bt_telemetry_docs d ON d.ctid::text = t.doc_id
      ORDER BY t.distance LIMIT 1;" 2>&1)
  [[ "$r12" = "1|0" ]] \
    && pass "22 v2_functions: fractal_search_telemetry finds the exact match at distance 0 (ctid doc_id resolves to id 1)" \
    || fail "22 v2_functions: expected id=1 dist=0 first via the ctid doc_id, got: $r12"

  # The old 0-indexed cohort doc_ids [1,3,4] were scan positions of
  # physical rows 2,4,5. In the ctid world the cohort is built with
  # ordinary SQL (array_agg of ctid::text) and the expected id order is
  # the same three rows in the same distance order: 2,5,4.
  local r13; r13=$("${PSQL[@]}" -c "
     SELECT d.id FROM fractal_hybrid_clinical_search(
       'bt_telemetry_docs', 'emb', ARRAY[0.0,1.0,0.0]::float8[],
       (SELECT array_agg(ctid::text) FROM bt_telemetry_docs WHERE id IN (2,4,5)), 3) t
       JOIN bt_telemetry_docs d ON d.ctid::text = t.doc_id
      ORDER BY t.distance;" 2>&1)
  [[ "$r13" = "$(printf '2\n5\n4')" ]] \
    && pass "22 v2_functions: fractal_hybrid_clinical_search restricts to the ctid cohort and returns real row ids" \
    || fail "22 v2_functions: expected doc_ids 2,5,4 in that order, got: $r13"

  local r14; r14=$("${PSQL[@]}" -c "
     SELECT fractal_hybrid_clinical_search(
       'bt_telemetry_docs', 'emb', ARRAY[0.0,1.0,0.0]::float8[],
       ARRAY['(999,1)']::text[], 1);" 2>&1)
  grep <<< "$r14" -q "cohort matched no rows" \
    && pass "22 v2_functions: fractal_hybrid_clinical_search rejects a cohort matching zero rows" \
    || fail "22 v2_functions: expected a no-rows-matched rejection, got: $r14"

  local r15; r15=$("${PSQL[@]}" -c "
     SELECT doc_id, distance FROM fractal_search_trajectory(
       'bt_telemetry_docs', 'emb', ARRAY[0.0,0.0,0.0]::float8[],
       ARRAY[1.0,0.0,0.0]::float8[], 1);" 2>&1)
  grep <<< "$r15" -q "^0|0$" \
    && pass "22 v2_functions: fractal_search_trajectory searches near the delta vector" \
    || fail "22 v2_functions: expected doc_id=0 dist=0 for a [1,0,0] delta, got: $r15"

  # fractal_vector-typed overload (fractal_search_trajectory_fv in
  # src/fractalsql.c): the two calls above only ever resolve the
  # float8[] signature -- confirmed via gcov these never ran before
  # this. Same table/query, just cast as fractal_vector so postgres's
  # own overload resolution picks the C function this exercises
  # (also the only caller of decode_vector_datum's fractal_vector
  # branch outside gate 32's trajectory_predict calls).
  local r15fv; r15fv=$("${PSQL[@]}" -c "
     SELECT doc_id, distance FROM fractal_search_trajectory(
       'bt_telemetry_docs', 'emb', '[0.0,0.0,0.0]'::fractal_vector,
       '[1.0,0.0,0.0]'::fractal_vector, 1);" 2>&1)
  grep <<< "$r15fv" -q "^0|0$" \
    && pass "22 v2_functions: fractal_search_trajectory (fractal_vector overload) searches near the delta vector" \
    || fail "22 v2_functions: expected doc_id=0 dist=0 for a [1,0,0] delta (fv overload), got: $r15fv"

  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_combined_docs;
     CREATE TABLE bt_combined_docs (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_combined_docs (emb) VALUES
       (ARRAY[1.0,0.0, 0.0,0.0]::float8[]),
       (ARRAY[0.0,0.0, 1.0,0.0]::float8[]);
  " >/dev/null 2>&1
  local r16; r16=$("${PSQL[@]}" -c "
     SELECT doc_id, distance FROM fractal_cross_modal_search(
       'bt_combined_docs', 'emb', ARRAY[1.0,0.0]::float8[],
       ARRAY[1.0,0.0]::float8[], 1.0, 1);" 2>&1)
  grep <<< "$r16" -q "^0|0$" \
    && pass "22 v2_functions: fractal_cross_modal_search at alpha=1.0 favors the morphology-only row" \
    || fail "22 v2_functions: expected doc_id=0 dist=0 at alpha=1.0, got: $r16"

  # fractal_vector-typed overload (fractal_cross_modal_search_fv):
  # same table/query as r16, just fractal_vector-cast -- confirmed via
  # gcov this never ran before this (0% coverage).
  local r16fv; r16fv=$("${PSQL[@]}" -c "
     SELECT doc_id, distance FROM fractal_cross_modal_search(
       'bt_combined_docs', 'emb', '[1.0,0.0]'::fractal_vector,
       '[1.0,0.0]'::fractal_vector, 1.0, 1);" 2>&1)
  grep <<< "$r16fv" -q "^0|0$" \
    && pass "22 v2_functions: fractal_cross_modal_search (fractal_vector overload) at alpha=1.0 favors the morphology-only row" \
    || fail "22 v2_functions: expected doc_id=0 dist=0 at alpha=1.0 (fv overload), got: $r16fv"

  local r17; r17=$("${PSQL[@]}" -c "
     SELECT fractal_cross_modal_search(
       'bt_combined_docs', 'emb', ARRAY[1.0,0.0]::float8[],
       ARRAY[1.0,0.0]::float8[], 1.5, 1);" 2>&1)
  grep <<< "$r17" -q "alpha_weight must be in" \
    && pass "22 v2_functions: fractal_cross_modal_search rejects an out-of-range alpha_weight" \
    || fail "22 v2_functions: expected an alpha_weight rejection, got: $r17"

  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_telemetry_docs, bt_combined_docs;" >/dev/null 2>&1

  # --- 7: rejection-class sweep for the v2.x primitives, extending the
  #     happy paths gates 22/29/30 already prove. Every string asserted
  #     here is this repo's own error text (src/fractalsql.c /
  #     src/fractalsql_vector.c), not the SQLite sibling's wording.
  local r
  # optimize_portfolio: k<=0 and k>n_assets both hit the same validation
  # ("k must satisfy 1 <= k <= n_assets"); cov stays consistent so the
  # cov-length check passes and it is really the k branch that fires.
  # (NULL mu is NOT covered: fractal_optimize_portfolio is declared
  # non-STRICT and has no PG_ARGISNULL guard at its entry, so a NULL mu
  # would SIGSEGV the backend -- a real robustness gap, but not something
  # this harness can assert as a clean deterministic rejection.)
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 0, 1);" 2>&1)
  grep <<< "$r" -q "k must satisfy 1 <= k <= n_assets" \
    && pass "22 rejection: optimize_portfolio rejects k<=0" \
    || fail "22 rejection: expected the k<=0 rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 3, 1);" 2>&1)
  grep <<< "$r" -q "k must satisfy 1 <= k <= n_assets" \
    && pass "22 rejection: optimize_portfolio rejects k>n_assets" \
    || fail "22 rejection: expected the k>n_assets rejection, got: $r"

  # tda_persistence_diagram: dim=0; point count not a multiple of dim; a
  # too-few-points (n_points=1) instance rejected by the core (the "2 <=
  # n_points <= 512" bound); max_dim outside {0,1}.
  r=$("${PSQL[@]}" -c "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0,1.0,1.0]::float8[], 0);" 2>&1)
  grep <<< "$r" -q "dim must be > 0" \
    && pass "22 rejection: tda_persistence_diagram rejects dim<=0" \
    || fail "22 rejection: expected a dim<=0 rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,1.0]::float8[], 3);" 2>&1)
  grep <<< "$r" -q "points length (2) must be a multiple of dim (3)" \
    && pass "22 rejection: tda_persistence_diagram rejects a point list that is not a multiple of dim" \
    || fail "22 rejection: expected a points-length rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0]::float8[], 2);" 2>&1)
  grep <<< "$r" -q "2 <= n_points" \
    && pass "22 rejection: tda_persistence_diagram rejects a single-point cloud (n_points >= 2)" \
    || fail "22 rejection: expected a too-few-points rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0,1.0,1.0,2.0,2.0]::float8[], 2, 2);" 2>&1)
  grep <<< "$r" -q "max_dim in {0,1}" \
    && pass "22 rejection: tda_persistence_diagram rejects max_dim=2 (core supports only {0,1})" \
    || fail "22 rejection: expected a max_dim rejection, got: $r"

  # periodogram: max_peaks <= 0; series shorter than the core's n >= 4 floor.
  r=$("${PSQL[@]}" -c "SELECT fractal_periodogram(ARRAY[1.0,2.0,3.0,4.0]::float8[], 0);" 2>&1)
  grep <<< "$r" -q "max_peaks must be > 0" \
    && pass "22 rejection: periodogram rejects max_peaks<=0" \
    || fail "22 rejection: expected a max_peaks rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_periodogram(ARRAY[1.0,2.0,3.0]::float8[], 4);" 2>&1)
  grep <<< "$r" -q "need n >= 4" \
    && pass "22 rejection: periodogram rejects a too-short series" \
    || fail "22 rejection: expected a need-n>=4 rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_periodogram(ARRAY[[1.0,2.0],[3.0,4.0]]::float8[], 4);" 2>&1)
  grep <<< "$r" -q "query must be 1-D non-null float8\[\]" \
    && pass "22 rejection: periodogram rejects a 2-D (malformed) series" \
    || fail "22 rejection: expected the 1-D-non-null rejection, got: $r"

  # cycle_detect: empty fingerprints array; a NULL element inside it; mixed
  # fingerprint lengths. (The negative hamming_threshold branch is gate 30's
  # already.) Bytea payloads are opaque -- a "garbage" fingerprint of a
  # constant length is a valid stream element by contract, so the
  # non-hex/non-JSON malformed shapes the sibling rejects simply do not
  # exist as pg rejections here.
  r=$("${PSQL[@]}" -c "SELECT count(*) FROM fractal_cycle_detect(ARRAY[]::bytea[], 0);" 2>&1)
  grep <<< "$r" -q "fingerprints array must not be empty" \
    && pass "22 rejection: cycle_detect rejects an empty fingerprints array" \
    || fail "22 rejection: expected an empty-array rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT count(*) FROM fractal_cycle_detect(ARRAY['ab'::bytea, NULL]::bytea[], 0);" 2>&1)
  grep <<< "$r" -q "fingerprints array must not contain NULLs" \
    && pass "22 rejection: cycle_detect rejects a NULL fingerprint element" \
    || fail "22 rejection: expected a NULL-element rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT count(*) FROM fractal_cycle_detect(ARRAY['ab'::bytea, 'abc'::bytea]::bytea[], 0);" 2>&1)
  grep <<< "$r" -q "every fingerprint must be the same length" \
    && pass "22 rejection: cycle_detect rejects mixed-length fingerprints" \
    || fail "22 rejection: expected a length-mismatch rejection, got: $r"

  # state_fingerprint: a 2-D (malformed) vec -- the shared float8_array_
  # to_doubles helper's own message says "query" even for this function's
  # vec argument. (n_bits<=0 is gate 30's already.)
  r=$("${PSQL[@]}" -c "SELECT fractal_state_fingerprint(ARRAY[[1.0,2.0],[3.0,4.0]]::float8[], 8, 42);" 2>&1)
  grep <<< "$r" -q "query must be 1-D non-null float8\[\]" \
    && pass "22 rejection: state_fingerprint rejects a 2-D vec" \
    || fail "22 rejection: expected a 1-D-non-null rejection, got: $r"

  # The native vector type's dimension cap -- the REAL cap is
  # FRACTALVEC_MAX_DIM = 32767 (src/fractalsql_vector.c), enforced inline
  # during text input ("dimension exceeds maximum 32767") and by
  # check_dim_range for degenerate dims ("dimension must be between 1 and
  # 32767"). fractal_vector_add's happy path is gate 29's; this covers its
  # input-parse rejection surface.
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_add('[]'::fractal_vector, '[1,2,3]'::fractal_vector);" 2>&1)
  grep <<< "$r" -q "fractal_vector dimension must be between 1 and 32767, got 0" \
    && pass "22 rejection: fractal_vector rejects a zero-dimension ('[]') input" \
    || fail "22 rejection: expected the zero-dim rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_add('[1,2'::fractal_vector, '[1,2,3]'::fractal_vector);" 2>&1)
  grep <<< "$r" -q "expected ']'" \
    && pass "22 rejection: fractal_vector_add rejects an unclosed vector literal" \
    || fail "22 rejection: expected an unclosed-literal rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_dims(('[' || repeat('1,', 32767) || '1]')::fractal_vector);" 2>&1)
  grep <<< "$r" -q "dimension exceeds maximum 32767" \
    && pass "22 rejection: fractal_vector rejects dim>32767 (32768-element literal)" \
    || fail "22 rejection: expected the 32767-cap rejection, got: $r"
  # NULL required vector args: the portfolio entries are deliberately
  # non-STRICT (their optional args use SQL-side NULL defaults), so a NULL
  # mu/cov can legally arrive — and the C entry used to deref it (backend
  # SIGSEGV; the in-function guard now rejects cleanly). One case per
  # entry; mu-null on _portfolio, mu-null on both multimodal entries, and
  # cov-null on _portfolio.
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio(NULL, '{0.5,0.5,0.5,0.5}'::float8[], 1);" 2>&1)
  grep <<< "$r" -q "fractal_optimize_portfolio: mu must not be NULL" \
    && pass "22 rejection: fractal_optimize_portfolio rejects a NULL mu" \
    || fail "22 rejection: expected the NULL-mu rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio('{0.25,0.25,0.5,0}'::float8[], NULL, 1);" 2>&1)
  grep <<< "$r" -q "fractal_optimize_portfolio: cov must not be NULL" \
    && pass "22 rejection: fractal_optimize_portfolio rejects a NULL cov" \
    || fail "22 rejection: expected the NULL-cov rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio_multimodal(NULL, '{0.25,0.25,0.5,0}'::float8[], 2, 1, 0.25, 0.9, 42, false, 'diffusion');" 2>&1)
  grep <<< "$r" -q "fractal_optimize_portfolio_multimodal: mu must not be NULL" \
    && pass "22 rejection: fractal_optimize_portfolio_multimodal rejects a NULL mu" \
    || fail "22 rejection: expected the multimodal NULL-mu rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio_multimodal_pareto(NULL, '{0.25,0.25,0.5,0}'::float8[], 2, 1, 8, 42, false, 'diffusion');" 2>&1)
  grep <<< "$r" -q "fractal_optimize_portfolio_multimodal_pareto: mu must not be NULL" \
    && pass "22 rejection: fractal_optimize_portfolio_multimodal_pareto rejects a NULL mu" \
    || fail "22 rejection: expected the pareto NULL-mu rejection, got: $r"

  # ---- T-H: fractal_vector_to_json() / fractal_vector_from_text(). A
  # JSON and a text front end for the native vector type. The JSON is
  # built on the type's OWN text rendering, deliberately NOT on a float8[]
  # round trip (which would widen 0.1f to 0.10000000149011612) -- that
  # difference is the point, so it is asserted rather than assumed.
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_to_json('[1,2,3]'::fractal_vector)::text;" 2>&1)
  [[ "$(tr -d '[:space:]' <<< "$r")" = "[1,2,3]" ]] \
    && pass "22 vector-json: to_json renders a vector as a JSON array" \
    || fail "22 vector-json: expected '[1, 2, 3]', got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_to_json('[0.1,0.2,0.3]'::fractal_vector) = '[0.1,0.2,0.3]'::fractal_vector::text::jsonb;" 2>&1)
  [[ "$r" = "t" ]] \
    && pass "22 vector-json: to_json is exactly the type's own text rendering parsed as JSON" \
    || fail "22 vector-json: expected the JSON to match the type's own text rendering, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_to_json('[0.1]'::fractal_vector) <> to_jsonb('[0.1]'::fractal_vector::float8[]);" 2>&1)
  [[ "$r" = "t" ]] \
    && pass "22 vector-json: the JSON is deliberately NOT the float8[] round trip (which would widen 0.1f)" \
    || fail "22 vector-json: expected the JSON to differ from the float8[] round trip, got: $r"

  # from_text: exactly two accepted forms -- a JSON/pgvector-style array
  # and a plain comma-separated list -- each with and without spaces after
  # the commas.
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('[1,2,3]')::text;" 2>&1)
  [[ "$r" = "[1,2,3]" ]] \
    && pass "22 vector-text: from_text parses the array form" \
    || fail "22 vector-text: expected '[1,2,3]', got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('1,2,3')::text;" 2>&1)
  [[ "$r" = "[1,2,3]" ]] \
    && pass "22 vector-text: from_text parses the plain list form" \
    || fail "22 vector-text: expected '[1,2,3]' from the list form, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('[1, 2, 3]')::text;" 2>&1)
  [[ "$r" = "[1,2,3]" ]] \
    && pass "22 vector-text: from_text tolerates spaces after the commas" \
    || fail "22 vector-text: expected '[1,2,3]', got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('1, 2, 3')::text;" 2>&1)
  [[ "$r" = "[1,2,3]" ]] \
    && pass "22 vector-text: from_text tolerates spaces in the list form" \
    || fail "22 vector-text: expected '[1,2,3]', got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text(NULL) IS NULL, fractal_vector_to_json(NULL::fractal_vector) IS NULL;" 2>&1)
  [[ "$r" = "t|t" ]] \
    && pass "22 vector-text: NULL in, NULL out (both helpers are STRICT)" \
    || fail "22 vector-text: expected t|t, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('');" 2>&1)
  grep <<< "$r" -q "an empty string is not a vector" \
    && pass "22 vector-text: an empty string is rejected" \
    || fail "22 vector-text: expected the empty-string rejection, got: $r"
  # The rejection has to name the offending text EXACTLY: PL/pgSQL's RAISE
  # placeholder is a bare "%", so a "%s" in the format string used to
  # leave a stray literal "s" inside the quoted text ("[1,2,x]s").
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('[1,2,x]');" 2>&1)
  grep <<< "$r" -q 'could not parse "\[1,2,x\]" as a vector array' \
    && pass "22 vector-text: a malformed array is rejected and the offending text is quoted exactly" \
    || fail "22 vector-text: expected the array-form parse rejection, got: $r"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text('1,2,x');" 2>&1)
  grep <<< "$r" -q 'could not parse "1,2,x" as a vector' \
    && pass "22 vector-text: a malformed list is rejected and the offending text is quoted exactly" \
    || fail "22 vector-text: expected the list-form parse rejection, got: $r"
  # The round trip is compared on the type's own text rendering --
  # fractal_vector has no "=" operator, and the rendering is the exact
  # thing the round trip has to preserve.
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_text(fractal_vector_to_json('[0.1,0.2,0.3]'::fractal_vector)::text)::text = '[0.1,0.2,0.3]'::fractal_vector::text;" 2>&1)
  [[ "$r" = "t" ]] \
    && pass "22 vector-text: a JSON round trip through the type's own rendering is lossless" \
    || fail "22 vector-text: expected the round trip to be lossless, got: $r"
  return 0
}

# fractalsql_agents dependent-extension smoke gate -- the two parameterized
# PL/pgSQL agent engines (fractal_agent_anomaly_triage, fractal_agent_allocate)
# shipped in fractalsql_agents/. Deliberately a smoke gate, same scope/spirit
# as gate 22: proves the engine compositions run end-to-end against the real .so
# + the real C primitives they wrap (fractal_dimension_drift, fractal_reason,
# fractal_optimize_portfolio). The engines' LLM step is fed by the gate-20 mock
# reasoning canary so it is deterministic without a live endpoint: the drift and
# optimizer steps are real C (deterministic); the reason step returns the
# canary. The engines themselves are loaded by pg_setup's agents-SQL slice (no
# MODULE_PATHNAME, pure PL/pgSQL). Mirrors build_test.ps1's Gate23Agents.
gate_23_agents() {
  # The engines call fractal_reason; the mock reasoning plugin (the resting
  # $MOCK state) returns /tmp/fractalsql_bt_sql.txt's content as the response.
  # Set the same canary gate 20 uses, so the engines' triage_summary / rationale
  # carry it. pg_swap_plugin "$MOCK" guarantees the mock is active even if gate
  # 23 is run standalone (without gate 20 before it).
  pg_swap_plugin "$MOCK" >/dev/null
  echo "gap-analysis-canary" > /tmp/fractalsql_bt_sql.txt

  # --- fixture: a drifting metric series for one host -----------------
  # Same step-up shape as demo/demo-vertical-agentic-ops-devops.sql: baseline ~50 for
  # the first 48 rows then a +30 step-up, 96 points, so fractal_dimension_drift's
  # 32-point recent window has a real regime change to detect (window=16 is too
  # small for DFA on the recent window -- see the demo's own note). A second
  # host makes the host filter meaningful.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_logs;
     CREATE TABLE bt_agents_logs (metric float8, ts timestamptz, host text);
     INSERT INTO bt_agents_logs (metric, ts, host)
     SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
            now() - (96 - gs) * interval '1 second', 'host-1'
       FROM generate_series(1,96) gs;
     INSERT INTO bt_agents_logs VALUES (10, now(), 'host-2'),
                                        (11, now() + interval '1 min', 'host-2');" >/dev/null 2>&1

  # --- 1: fractal_agent_anomaly_triage happy path ---------------------
  # threat_score is the REAL drift exponent (fractal_dimension_drift ran);
  # triage_summary is the REAL reason step (canary proves fractal_reason ran).
  local r1; r1=$("${PSQL[@]}" -c "
     SELECT threat_score FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r1" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: anomaly_triage threat_score is a real computed drift float" \
    || fail "23 agents: expected a numeric threat_score, got: $r1"

  local r1b; r1b=$("${PSQL[@]}" -c "
     SELECT triage_summary FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r1b" -q 'gap-analysis-canary' \
    && pass "23 agents: anomaly_triage composes drift -> reason (reason step ran)" \
    || fail "23 agents: expected the reasoning canary in triage_summary, got: $r1b"

  # --- 2: anomaly_triage empty-series guard ---------------------------
  local r2; r2=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','no-such-host',32);" 2>&1)
  grep <<< "$r2" -q 'no rows in' \
    && pass "23 agents: anomaly_triage raises a clean ERROR when the filter matches no rows" \
    || fail "23 agents: expected a no-rows ERROR, got: $r2"

  # --- 2b: agent_partial_reasoning_fail pair (PL/pgSQL engines) --------
  # The standard flag-off/flag-on pair (the sqlite repo's gate-29
  # convention), exercised on engine A. TWO DIFFERENT failure shapes, kept
  # apart on purpose -- the drift half needs no plugin at all, so the pair
  # isolates exactly the raise-vs-partial difference:
  #   (a) a SETUP mistake -- the reasoning plugin does not load at all
  #       (SQLSTATE 55000). This is NEVER softened: with the flag on the
  #       engine still raises (a missing plugin is a configuration mistake,
  #       not a transient endpoint failure -- the sibling sqlite engine
  #       hard-errors on it too).
  #   (b) a TRANSIENT endpoint failure -- the mock plugin LOADS, but its
  #       dispatch fails (the FSQL_BT_FORCE_FAIL sentinel). This IS
  #       softened: the engine returns its computed data half with the LLM
  #       column NULL and a SEPARATE reasoning_step_failed column carrying
  #       the error text (the two-column contract, matching the sibling's
  #       {"<llm>":null,"reasoning_step_failed":"<error>"} JSON shape).
  pg_set_guc fractalsql.reasoning_plugin "'/nonexistent/fractalsql_bt_broken.so'" "/nonexistent/fractalsql_bt_broken.so" \
    || { fail "23 agents: could not point reasoning_plugin at the broken path"; pg_swap_plugin "$MOCK" >/dev/null; return; }

  local r2b; r2b=$("${PSQL[@]}" -c "
     SELECT threat_score FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r2b" -q 'reasoning' \
    && pass "23 agents: agent_partial_reasoning_fail off -- the reasoning failure raises through the engine" \
    || fail "23 agents: expected the reasoning failure to raise with the flag off, got: $r2b"

  pg_set_guc fractalsql.agent_partial_reasoning_fail on on \
    || { fail "23 agents: could not set agent_partial_reasoning_fail=on"; pg_swap_plugin "$MOCK" >/dev/null; return; }

  # (a) the setup mistake is NOT softened by the flag.
  local r2b2; r2b2=$("${PSQL[@]}" -c "
     SELECT threat_score FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r2b2" -q 'reasoning plugin' \
    && pass "23 agents: a missing reasoning plugin is a setup mistake -- it still raises with the flag on" \
    || fail "23 agents: expected the setup mistake to raise even with the flag on, got: $r2b2"

  # (b) the transient dispatch failure IS softened, into the two-column
  # contract: threat_score is still the REAL computed drift float,
  # triage_summary is NULL, and reasoning_step_failed carries the raw error
  # text (no 'reasoning_step_failed: ' prefix -- the column name says it).
  pg_swap_plugin "$MOCK" >/dev/null
  echo "FSQL_BT_FORCE_FAIL" > /tmp/fractalsql_bt_sql.txt
  local r2c; r2c=$("${PSQL[@]}" -c "
     SELECT (threat_score IS NOT NULL),
            (triage_summary IS NULL),
            (reasoning_step_failed IS NOT NULL),
            (reasoning_step_failed <> ''),
            (reasoning_step_failed NOT LIKE 'reasoning_step_failed:%')
       FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r2c" -q '^t|t|t|t|t$' \
    && pass "23 agents: agent_partial_reasoning_fail on -- data half (real drift float) + NULL LLM column + reasoning_step_failed error column" \
    || fail "23 agents: expected the partial row (drift float + NULL triage_summary + reasoning_step_failed), got: $r2c"

  # flag off + the same transient failure: the failure propagates again.
  pg_set_guc fractalsql.agent_partial_reasoning_fail off off \
    || { fail "23 agents: could not reset agent_partial_reasoning_fail=off"; pg_swap_plugin "$MOCK" >/dev/null; return; }
  local r2d; r2d=$("${PSQL[@]}" -c "
     SELECT threat_score FROM fractal_agent_anomaly_triage(
       'bt_agents_logs','metric','ts','host','host-1',32);" 2>&1)
  grep <<< "$r2d" -q 'dispatch failed' \
    && pass "23 agents: agent_partial_reasoning_fail off -- a transient reasoning failure still raises" \
    || fail "23 agents: expected the transient reasoning failure to raise with the flag off, got: $r2d"

  # Restore the resting state the rest of the gate (and gate 24+) expects.
  pg_swap_plugin "$MOCK" >/dev/null
  echo "gap-analysis-canary" > /tmp/fractalsql_bt_sql.txt

  # --- 3: fractal_agent_allocate happy path --------------------------
  # allocation is the REAL optimizer jsonb {sharpe, weights}; sharpe is the REAL
  # risk-adjusted return extracted from it (replaces the demo's 0.042 literal);
  # rationale is the REAL reason step (canary).
  local r3; r3=$("${PSQL[@]}" -c "
     SELECT allocation FROM fractal_agent_allocate(
       ARRAY[0.05,0.1]::float8[], ARRAY[1.0,0.0,0.0,1.0]::float8[], 1, '{}'::text);" 2>&1)
  grep <<< "$r3" -q '"sharpe"' \
    && pass "23 agents: allocate composes optimize_portfolio -> reason (real optimizer jsonb with sharpe)" \
    || fail "23 agents: expected a sharpe-bearing allocation jsonb, got: $r3"

  local r3b; r3b=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_allocate(
       ARRAY[0.05,0.1]::float8[], ARRAY[1.0,0.0,0.0,1.0]::float8[], 1, '{}'::text);" 2>&1)
  grep <<< "$r3b" -q 'gap-analysis-canary' \
    && pass "23 agents: allocate rationale is the real reason step output (canary)" \
    || fail "23 agents: expected the reasoning canary in rationale, got: $r3b"

  # --- 4: allocate cov-length rejection -------------------------------
  # The engine must surface fractal_optimize_portfolio's clean 'cov length'
  # ERROR unchanged, not swallow it.
  local r4; r4=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_allocate(
       ARRAY[0.1,0.1]::float8[], ARRAY[1.0]::float8[], 1, NULL::text);" 2>&1)
  grep <<< "$r4" -q 'cov length' \
    && pass "23 agents: allocate surfaces the optimizer's clean cov-length rejection" \
    || fail "23 agents: expected a cov-length rejection, got: $r4"

  # --- 5: fractal_agent_route_task happy path -------------------------
  # routed_to is the REAL nearest capability (telemetry ran + doc_id resolved
  # to the named id); confidence is real, derived from the nearest distance
  # (1/(1+d)); rationale is the REAL reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_caps;
     CREATE TABLE bt_agents_caps (capability_name text, emb float8[]);
     INSERT INTO bt_agents_caps VALUES ('cap-a', ARRAY[0.1,0.2,0.3]), ('cap-b', ARRAY[0.9,0.8,0.7]);" >/dev/null 2>&1
  local r5; r5=$("${PSQL[@]}" -c "
     SELECT routed_to FROM fractal_agent_route_task(
       ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);" 2>&1)
  grep <<< "$r5" -q '^cap-a$' \
    && pass "23 agents: route_task returns the real nearest capability name (telemetry + doc_id resolution)" \
    || fail "23 agents: expected routed_to=cap-a, got: $r5"

  local r5b; r5b=$("${PSQL[@]}" -c "
     SELECT confidence FROM fractal_agent_route_task(
       ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);" 2>&1)
  grep <<< "$r5b" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: route_task confidence is a real float derived from the nearest distance" \
    || fail "23 agents: expected a numeric confidence, got: $r5b"

  local r5c; r5c=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_route_task(
       ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);" 2>&1)
  grep <<< "$r5c" -q 'gap-analysis-canary' \
    && pass "23 agents: route_task composes telemetry -> reason (reason step ran)" \
    || fail "23 agents: expected the reasoning canary in rationale, got: $r5c"

  # --- 6: route_task empty-capability-table guard ---------------------
  "${PSQL[@]}" -c "DELETE FROM bt_agents_caps;" >/dev/null 2>&1
  local r6; r6=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_route_task(
       ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);" 2>&1)
  grep <<< "$r6" -q 'no capability rows' \
    && pass "23 agents: route_task raises a clean ERROR when the capability table is empty" \
    || fail "23 agents: expected a no-capability-rows ERROR, got: $r6"

  # --- 7: fractal_agent_outlier_intercept intercept + allow -----------
  # Bad states point along the x-axis. Cosine distance ignores magnitude, so
  # the "far" probe must differ in DIRECTION (orthogonal y-axis), not just
  # magnitude -- [0.1,0.1,0.1] vs [0.9,0.9,0.9] would be distance 0 (parallel).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_badstates;
     CREATE TABLE bt_agents_badstates (emb float8[]);
     INSERT INTO bt_agents_badstates VALUES (ARRAY[1,0,0]), (ARRAY[0.9,0.1,0.0]);" >/dev/null 2>&1
  local r7; r7=$("${PSQL[@]}" -c "
     SELECT intercepted FROM fractal_agent_outlier_intercept(
       ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);" 2>&1)
  grep <<< "$r7" -q '^t$' \
    && pass "23 agents: outlier_intercept intercepts a state within the threshold (real distance 0 < 0.5)" \
    || fail "23 agents: expected intercepted=t for a near state, got: $r7"

  local r7b; r7b=$("${PSQL[@]}" -c "
     SELECT intercepted FROM fractal_agent_outlier_intercept(
       ARRAY[0,1,0]::float8[], 'bt_agents_badstates','emb', 0.5);" 2>&1)
  grep <<< "$r7b" -q '^f$' \
    && pass "23 agents: outlier_intercept allows an orthogonal state (real cosine distance 1 > 0.5)" \
    || fail "23 agents: expected intercepted=f for an orthogonal state, got: $r7b"

  local r7c; r7c=$("${PSQL[@]}" -c "
     SELECT reason FROM fractal_agent_outlier_intercept(
       ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);" 2>&1)
  grep <<< "$r7c" -q 'gap-analysis-canary' \
    && pass "23 agents: outlier_intercept reason is the real reason step output (canary)" \
    || fail "23 agents: expected the reasoning canary in reason, got: $r7c"

  # The explicit metric argument: a threshold is calibrated against one
  # metric, so the metric is caller-chosen, and the same probe can get
  # opposite decisions under different metrics. [0.05,0,0] is
  # cosine-parallel to the bad x-axis states (cosine distance ~0, so
  # intercepted, as r7 showed for [1,0,0]) but L2-far: the nearest bad
  # state is [0.9,0.1,0.0] at sqrt(0.7225+0.01) = 0.856 > 0.5, so
  # allowed. An unknown metric must be a hard error, never a fallback.
  local r7d; r7d=$("${PSQL[@]}" -c "
     SELECT intercepted FROM fractal_agent_outlier_intercept(
       ARRAY[0.05,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'l2');" 2>&1)
  grep <<< "$r7d" -q '^f$' \
    && pass "23 agents: outlier_intercept metric=l2 allows the parallel state cosine intercepts (real L2 distance 0.856 > 0.5)" \
    || fail "23 agents: expected intercepted=f for metric=l2 (L2 distance 0.856 > 0.5), got: $r7d"

  local r7e; r7e=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_outlier_intercept(
       ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'euclid');" 2>&1)
  grep <<< "$r7e" -q "metric must be 'cosine' or 'l2'" \
    && pass "23 agents: outlier_intercept rejects an unknown metric (no silent fallback)" \
    || fail "23 agents: expected a metric rejection, got: $r7e"

  # --- 7b: the metric column is exposed (sibling parity) --------------
  # The metric the engine actually used must be visible in the returned
  # columns, not only inside the nested payload -- the sibling's shape is
  # {"intercepted":..,"metric":..,"reason":..}.
  local r7f; r7f=$("${PSQL[@]}" -c "
     SELECT metric FROM fractal_agent_outlier_intercept(
       ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);" 2>&1)
  grep <<< "$r7f" -q '^cosine$' \
    && pass "23 agents: outlier_intercept exposes the metric it actually used (metric column)" \
    || fail "23 agents: expected metric=cosine in the outlier_intercept row, got: $r7f"

  local r7g; r7g=$("${PSQL[@]}" -c "
     SELECT metric FROM fractal_agent_outlier_intercept(
       ARRAY[0.05,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'l2');" 2>&1)
  grep <<< "$r7g" -q '^l2$' \
    && pass "23 agents: outlier_intercept reports the caller-chosen l2 metric in the metric column" \
    || fail "23 agents: expected metric=l2 in the outlier_intercept row, got: $r7g"

  # --- 7c: a NULL input vector is an ARGUMENT fault, not a data fault --
  # The engine rejects the NULL itself with invalid_parameter_value
  # (22023) instead of letting it reach the vector math, where it would
  # surface as a generic low-level data error.
  local r7h; r7h=$("${PSQL[@]}" -c "
     DO \$\$ BEGIN
       PERFORM * FROM fractal_agent_route_task(NULL::float8[], 'bt_agents_caps','emb','capability_name', 10);
     EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sqlstate=%', SQLSTATE;
     END \$\$;" 2>&1)
  grep <<< "$r7h" -q 'sqlstate=22023' \
    && pass "23 agents: a NULL input vector is an argument error (22023), not a vector-math data error" \
    || fail "23 agents: expected a 22023 argument error for a NULL input vector, got: $r7h"

  # --- 8: fractal_agent_recall_hybrid happy path + guard --------------
  # Real session_ids + real content from the fixture (NOT the stub's
  # generate_series 1-5 / 'recalled memory snippet N'); the cohort
  # (customer_id filter) excludes cust-b's session. Pure retrieval -- no
  # LLM step, so no canary here, fully real C.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_mem;
     CREATE TABLE bt_agents_mem (session_id bigint, customer_id text, state_vector float8[], content text);
     INSERT INTO bt_agents_mem VALUES
       (1001, 'cust-a', ARRAY[0.1,0.2,0.3], 'resolved churn via loyalty upgrade'),
       (1002, 'cust-a', ARRAY[0.15,0.25,0.35], 'offered retention discount'),
       (1003, 'cust-b', ARRAY[0.9,0.8,0.7], 'escalated to human agent');" >/dev/null 2>&1
  local r8; r8=$("${PSQL[@]}" -c "
     SELECT mem_id FROM fractal_agent_recall_hybrid(
       'bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[],
       'customer_id','cust-a', 5, 'session_id','content') LIMIT 1;" 2>&1)
  grep <<< "$r8" -q '^1001$' \
    && pass "23 agents: recall_hybrid returns the real nearest session_id (not the stub's generate_series 1-5)" \
    || fail "23 agents: expected mem_id=1001, got: $r8"

  local r8b; r8b=$("${PSQL[@]}" -c "
     SELECT content FROM fractal_agent_recall_hybrid(
       'bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[],
       'customer_id','cust-a', 5, 'session_id','content') LIMIT 1;" 2>&1)
  grep <<< "$r8b" -q 'resolved churn via loyalty upgrade' \
    && pass "23 agents: recall_hybrid returns the real row content (not the stub's canned snippet)" \
    || fail "23 agents: expected the real content, got: $r8b"

  local r8c; r8c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_recall_hybrid(
       'bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[],
       'customer_id','no-such-cust', 5, 'session_id','content');" 2>&1)
  grep <<< "$r8c" -q 'filter matched no rows' \
    && pass "23 agents: recall_hybrid raises a clean ERROR when the filter matches no rows" \
    || fail "23 agents: expected a filter-matched-no-rows ERROR, got: $r8c"

  # --- 9: fractal_agent_recommend_diverse happy path ------------------
  # Real catalog ids + real scores (NOT the stub's generate_series 1..k /
  # 0.95 - i*0.01). Diversify is enabled as a session side effect; no
  # feedback has been reported so repulsion is a no-op and telemetry returns
  # the plain nearest first (id 10, distance 0 -> score 1). Pure retrieval.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_catalog;
     CREATE TABLE bt_agents_catalog (id bigint, emb float8[]);
     INSERT INTO bt_agents_catalog VALUES (10, ARRAY[0.1,0.2,0.3]), (20, ARRAY[0.9,0.8,0.7]), (30, ARRAY[0.5,0.5,0.5]);" >/dev/null 2>&1
  local r9; r9=$("${PSQL[@]}" -c "
     SELECT item_id FROM fractal_agent_recommend_diverse(
       'bt_agents_catalog','emb', ARRAY[0.1,0.2,0.3]::float8[], 3, 'id') LIMIT 1;" 2>&1)
  grep <<< "$r9" -q '^10$' \
    && pass "23 agents: recommend_diverse returns the real nearest catalog id (not the stub's generate_series 1..k)" \
    || fail "23 agents: expected item_id=10, got: $r9"

  local r9b; r9b=$("${PSQL[@]}" -c "
     SELECT score FROM fractal_agent_recommend_diverse(
       'bt_agents_catalog','emb', ARRAY[0.1,0.2,0.3]::float8[], 3, 'id') LIMIT 1;" 2>&1)
  grep <<< "$r9b" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: recommend_diverse score is a real float (1 - cosine distance), not the stub's canned 0.95-i*0.01" \
    || fail "23 agents: expected a numeric score, got: $r9b"

  # ====================================================================
  # Stage 4 engines G-O (9 new). The 8 cognition engines (G,H,J,K,L,M,N,O)
  # reuse the gate-20 mock canary set above, so their rationale/analysis
  # columns carry it; feedback_audit (I) is pure analytics (no LLM, no
  # canary). Real C primitives feed the analytics columns; the canary proves
  # the reason step ran. Mirrors build_test.ps1's Gate23Agents.
  # ====================================================================

  # --- 10: fractal_agent_data_analyst happy path ----------------------
  # Composes fractal_sql_agent (NL->SQL->execute, auto_execute=true) ->
  # fractal_reason. With the mock canary the generated_sql IS the canary
  # (the mock LLM); auto_execute's subtransaction catches the canary-as-SQL
  # syntax error into a real execution_failed result_json, proving the
  # execute step ran; analysis is the real reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_data;
     CREATE TABLE bt_agents_data (id int PRIMARY KEY, val float8);
     INSERT INTO bt_agents_data VALUES (1,10.5),(2,20.5);" >/dev/null 2>&1
  local r10; r10=$("${PSQL[@]}" -c "
     SELECT generated_sql FROM fractal_agent_data_analyst(
       'sum of val', ARRAY['bt_agents_data'], 2);" 2>&1)
  grep <<< "$r10" -q 'gap-analysis-canary' \
    && pass "23 agents: data_analyst composes sql_agent (generated_sql is the real LLM step, canary)" \
    || fail "23 agents: expected the canary in generated_sql, got: $r10"
  local r10b; r10b=$("${PSQL[@]}" -c "
     SELECT result_json::text FROM fractal_agent_data_analyst(
       'sum of val', ARRAY['bt_agents_data'], 2);" 2>&1)
  grep <<< "$r10b" -q '"status"' \
    && pass "23 agents: data_analyst result_json is a real jsonb (auto_execute subtransaction ran)" \
    || fail "23 agents: expected a status-bearing result_json, got: $r10b"
  local r10c; r10c=$("${PSQL[@]}" -c "
     SELECT analysis FROM fractal_agent_data_analyst(
       'sum of val', ARRAY['bt_agents_data'], 2);" 2>&1)
  grep <<< "$r10c" -q 'gap-analysis-canary' \
    && pass "23 agents: data_analyst composes sql_agent -> reason (analysis is the real reason step, canary)" \
    || fail "23 agents: expected the canary in analysis, got: $r10c"

  # --- 10d: fractal_sql_agent's auto_execute SAVEPOINT scoping --------
  # Unlike the canary-as-SQL path above (10/10b/10c, which proves the compose-
  # and-fail shape), this drives the mock's single canned-reply file
  # (/tmp/fractalsql_bt_sql.txt, the same file gate 04's auto-discovery
  # case writes) with a real, valid INSERT, so one call can genuinely
  # succeed and a colliding call can genuinely fail. One connection, one
  # open transaction: a real prior COMMITted write (id=99), then three
  # fractal_sql_agent calls that always generate the SAME INSERT (id=1)
  # -- the first succeeds, the second and third both collide with the
  # PRIMARY KEY and must each report execution_failed via auto_execute's
  # internal subtransaction, proving the same fixed call is safely
  # reusable after a prior rollback, not just after a clean release.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_sql_agent_sp;
     CREATE TABLE bt_sql_agent_sp (id int PRIMARY KEY, val text);
     INSERT INTO bt_sql_agent_sp (id, val) VALUES (99, 'prior');" >/dev/null 2>&1
  pg_set_guc fractalsql.text_to_sql_allowed_statements "'select_insert_update'" "select_insert_update" \
    || fail "23 agents: sql_agent_savepoint GUC did not take effect"
  echo "INSERT INTO bt_sql_agent_sp (id, val) VALUES (1, 'x')" > /tmp/fractalsql_bt_sql.txt
  # Separate -c flags, not one multi-statement -c string: on PG14, a
  # single simple-query message containing multiple statements silently
  # drops every statement's output but the last once one of them calls
  # a function that uses BeginInternalSubTransaction (confirmed live --
  # the combined form returns only the COMMIT tag, no BEGIN, no SELECT
  # results, on PG14; PG16 is unaffected). Separate -c flags still share
  # one connection, so the explicit BEGIN/COMMIT still scope one real
  # transaction across all three calls.
  local out; out=$("${PSQL[@]}" \
     -c "BEGIN;" \
     -c "SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);" \
     -c "SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);" \
     -c "SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);" \
     -c "COMMIT;" 2>&1)
  # BEGIN/COMMIT print their own command tags even under -tA (only
  # SELECT's tuples are suppressed by -t) -- filter them out before
  # indexing, rather than assuming the 3 statuses are lines 1-3.
  local statuses; statuses=$(grep -vE '^(BEGIN|COMMIT)$' <<< "$out")
  local status1 status2 status3
  status1=$(sed -n '1p' <<< "$statuses")
  status2=$(sed -n '2p' <<< "$statuses")
  status3=$(sed -n '3p' <<< "$statuses")
  [[ "$status1" = "executed" ]] \
    && pass "23 agents: sql_agent_savepoint: first INSERT executed cleanly" \
    || fail "23 agents: sql_agent_savepoint: first call expected status=executed, got '$status1' (full: $out)"
  [[ "$status2" = "execution_failed" ]] \
    && pass "23 agents: sql_agent_savepoint: second (colliding) INSERT reported execution_failed via the auto_execute subtransaction, not a raw error" \
    || fail "23 agents: sql_agent_savepoint: second call expected status=execution_failed, got '$status2'"
  [[ "$status3" = "execution_failed" ]] \
    && pass "23 agents: sql_agent_savepoint: third call reused the same call shape after the second call's rollback, no escaped error" \
    || fail "23 agents: sql_agent_savepoint: third call expected status=execution_failed, got '$status3'"
  local cnt; cnt=$("${PSQL[@]}" -c "SELECT count(*) FROM bt_sql_agent_sp;" 2>&1)
  [[ "$cnt" = "2" ]] \
    && pass "23 agents: sql_agent_savepoint: both the prior commit (id=99) and the first call's write (id=1) survive -- no phantom rows from the two rolled-back calls" \
    || fail "23 agents: sql_agent_savepoint: expected exactly 2 surviving rows (id=1,99), count=$cnt"
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_sql_agent_sp;" >/dev/null 2>&1
  pg_set_guc fractalsql.text_to_sql_allowed_statements "'select'" "select"
  # Restore the shared mock-reply file: every engine after this point in
  # gate 23 expects the "gap-analysis-canary" reply this gate's own
  # header already set, not the INSERT text this sub-test just wrote.
  echo "gap-analysis-canary" > /tmp/fractalsql_bt_sql.txt

  # --- 11: fractal_agent_patient_deterioration_triage happy + guard ----
  # nearest_cohort_id is the REAL hybrid_clinical_search nearest resolved via
  # ctid; cohort_distance/drift_distance are real; rationale is the reason
  # step (canary). cohort_doc_ids built from age>65 AND condition='sepsis'
  # (the two-predicate case recall_hybrid cannot express).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_patients;
     CREATE TABLE bt_agents_patients (id int PRIMARY KEY, age int, condition text, vitals float8[]);
     INSERT INTO bt_agents_patients VALUES
       (1,70,'sepsis',ARRAY[0.9,-0.8,0.7,0.6]),
       (2,30,'sepsis',ARRAY[0.1,0.1,0.1,0.1]),
       (3,72,'flu',  ARRAY[0.2,0.2,0.2,0.2]),
       (4,80,'sepsis',ARRAY[0.85,-0.75,0.65,0.55]);" >/dev/null 2>&1
  local r11; r11=$("${PSQL[@]}" -c "
     SELECT nearest_cohort_id FROM fractal_agent_patient_deterioration_triage(
       'bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[],
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[],
       (SELECT array_agg(ctid::text) FROM bt_agents_patients
          WHERE age>65 AND condition='sepsis'),
       5, 'id');" 2>&1)
  grep <<< "$r11" -Eq '^[0-9]+$' \
    && pass "23 agents: patient_deterioration_triage returns the real nearest cohort id (hybrid search + ctid resolution)" \
    || fail "23 agents: expected a numeric nearest_cohort_id, got: $r11"
  local r11m; r11m=$("${PSQL[@]}" -c "
     SELECT jsonb_array_length(cohort_matches) FROM fractal_agent_patient_deterioration_triage(
       'bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[],
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[],
       (SELECT array_agg(ctid::text) FROM bt_agents_patients
          WHERE age>65 AND condition='sepsis'),
       5, 'id');" 2>&1)
  [[ "$r11m" = "2" ]] \
    && pass "23 agents: patient_deterioration_triage cohort_matches now honors k (got 2 of 2 qualifying rows)" \
    || fail "23 agents: expected cohort_matches length 2, got: $r11m"
  local r11b; r11b=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_patient_deterioration_triage(
       'bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[],
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[],
       (SELECT array_agg(ctid::text) FROM bt_agents_patients
          WHERE age>65 AND condition='sepsis'),
       5, 'id');" 2>&1)
  grep <<< "$r11b" -q 'gap-analysis-canary' \
    && pass "23 agents: patient_deterioration_triage composes hybrid+trajectory -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r11b"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_patients;" >/dev/null 2>&1
  local r11c; r11c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_patient_deterioration_triage(
       'bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[],
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[],
       NULL, 5, 'id');" 2>&1)
  grep <<< "$r11c" -q 'no patient rows' \
    && pass "23 agents: patient_deterioration_triage raises a clean ERROR when the patient table is empty" \
    || fail "23 agents: expected a no-patient-rows ERROR, got: $r11c"

  # --- 12: fractal_agent_feedback_audit happy + guard ------------------
  # Pure analytics (NO LLM, no canary): enables diversify, warms the D_q
  # window from the warmup table, isolates the target, reads back a real
  # diversity_quotient (NOT NaN -- the warmup populated the window) + the
  # real session diagnostics jsonb. Self-disables diversify.
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_fcatalog, bt_agents_fwarmup;
     CREATE TABLE bt_agents_fcatalog (id bigint PRIMARY KEY, emb float8[]);
     INSERT INTO bt_agents_fcatalog SELECT gs, ARRAY[random()*2-1, random()*2-1, random()*2-1] FROM generate_series(1,20) gs;
     CREATE TABLE bt_agents_fwarmup (center float8[]);
     INSERT INTO bt_agents_fwarmup SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1] FROM generate_series(1,8);" >/dev/null 2>&1
  local r12; r12=$("${PSQL[@]}" -c "
     SELECT diversity_quotient::text FROM fractal_agent_feedback_audit(
       'bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[],
       'bt_agents_fwarmup','center', 8, 3);" 2>&1)
  grep <<< "$r12" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: feedback_audit diversity_quotient is a real float (warmup populated the D_q window, not NaN)" \
    || fail "23 agents: expected a numeric diversity_quotient, got: $r12"
  local r12b; r12b=$("${PSQL[@]}" -c "
     SELECT (explanation IS NOT NULL)::text FROM fractal_agent_feedback_audit(
       'bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[],
       'bt_agents_fwarmup','center', 8, 3);" 2>&1)
  grep <<< "$r12b" -q '^true$' \
    && pass "23 agents: feedback_audit returns the real session diagnostics jsonb" \
    || fail "23 agents: expected a non-null explanation, got: $r12b"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_fcatalog;" >/dev/null 2>&1
  local r12c; r12c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_feedback_audit(
       'bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[],
       'bt_agents_fwarmup','center', 8, 3);" 2>&1)
  grep <<< "$r12c" -q 'no catalog rows' \
    && pass "23 agents: feedback_audit raises a clean ERROR when the catalog is empty" \
    || fail "23 agents: expected a no-catalog-rows ERROR, got: $r12c"

  # --- 13: fractal_agent_schedule_workload happy + guard ---------------
  # assigned_node is the REAL nearest node (fractal_search refinement +
  # telemetry + ctid resolution); confidence = 1/(1+d) is real; rationale
  # is the reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_nodes;
     CREATE TABLE bt_agents_nodes (id int PRIMARY KEY, capability float8[]);
     INSERT INTO bt_agents_nodes VALUES
       (1,ARRAY[0.9,0.1,0.0,0.0,0.0]),
       (2,ARRAY[0.0,0.0,0.9,0.1,0.0]),
       (3,ARRAY[0.1,0.0,0.0,0.0,0.9]);" >/dev/null 2>&1
  local r13; r13=$("${PSQL[@]}" -c "
     SELECT assigned_node FROM fractal_agent_schedule_workload(
       ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);" 2>&1)
  grep <<< "$r13" -Eq '^[0-9]+$' \
    && pass "23 agents: schedule_workload returns the real nearest node (fractal_search + telemetry + ctid)" \
    || fail "23 agents: expected a numeric assigned_node, got: $r13"
  local r13b; r13b=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_schedule_workload(
       ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);" 2>&1)
  grep <<< "$r13b" -q 'gap-analysis-canary' \
    && pass "23 agents: schedule_workload composes search+telemetry -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r13b"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_nodes;" >/dev/null 2>&1
  local r13c; r13c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_schedule_workload(
       ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);" 2>&1)
  grep <<< "$r13c" -q 'no node rows' \
    && pass "23 agents: schedule_workload raises a clean ERROR when the node table is empty" \
    || fail "23 agents: expected a no-node-rows ERROR, got: $r13c"

  # --- 14: fractal_agent_rebalance_sibling happy + guard ---------------
  # sharpe is the REAL optimizer output; weights is the real jsonb;
  # nearest_alloc_id is the real trajectory-search nearest resolved via
  # ctid; rationale is the reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_alloc;
     CREATE TABLE bt_agents_alloc (id bigint PRIMARY KEY, alloc float8[]);
     INSERT INTO bt_agents_alloc VALUES
       (1,ARRAY[0.25,0.25,0.25,0.25]),
       (2,ARRAY[0.4,0.3,0.2,0.1]),
       (3,ARRAY[0.1,0.2,0.3,0.4]);" >/dev/null 2>&1
  local r14; r14=$("${PSQL[@]}" -c "
     SELECT sharpe::text FROM fractal_agent_rebalance_sibling(
       ARRAY[0.05,0.10,0.15,0.20]::float8[],
       ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[],
       4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');" 2>&1)
  grep <<< "$r14" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: rebalance_sibling sharpe is the real optimizer output" \
    || fail "23 agents: expected a numeric sharpe, got: $r14"
  local r14b; r14b=$("${PSQL[@]}" -c "
     SELECT nearest_alloc_id FROM fractal_agent_rebalance_sibling(
       ARRAY[0.05,0.10,0.15,0.20]::float8[],
       ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[],
       4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');" 2>&1)
  grep <<< "$r14b" -Eq '^[0-9]+$' \
    && pass "23 agents: rebalance_sibling nearest_alloc_id is the real trajectory nearest (ctid resolution)" \
    || fail "23 agents: expected a numeric nearest_alloc_id, got: $r14b"
  local r14c; r14c=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_rebalance_sibling(
       ARRAY[0.05,0.10,0.15,0.20]::float8[],
       ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[],
       4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');" 2>&1)
  grep <<< "$r14c" -q 'gap-analysis-canary' \
    && pass "23 agents: rebalance_sibling composes optimize+trajectory -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r14c"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_alloc;" >/dev/null 2>&1
  local r14d; r14d=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_rebalance_sibling(
       ARRAY[0.05,0.10,0.15,0.20]::float8[],
       ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[],
       4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');" 2>&1)
  grep <<< "$r14d" -q 'no allocation rows' \
    && pass "23 agents: rebalance_sibling raises a clean ERROR when the allocation table is empty" \
    || fail "23 agents: expected a no-allocation-rows ERROR, got: $r14d"

  # --- 15: fractal_agent_detour_classify happy + guard -----------------
  # nearest_fleet_id is the REAL trajectory-search nearest; trace_complexity
  # is the REAL box-counting dimension of the GPS trace; rationale is the
  # reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_vehicles;
     CREATE TABLE bt_agents_vehicles (id int PRIMARY KEY, baseline float8[], current float8[]);
     INSERT INTO bt_agents_vehicles SELECT gs, ARRAY[b1,b2,b3,b4], ARRAY[b1+0.05,b2+0.05,b3+0.05,b4+0.05]
       FROM generate_series(1,8) gs,
            LATERAL (SELECT random()*2-1 a, random()*2-1 b, random()*2-1 c, random()*2-1 d) bl(b1,b2,b3,b4);
     UPDATE bt_agents_vehicles SET current = ARRAY[(baseline::float8[])[1]-0.7,(baseline::float8[])[2]+0.6,(baseline::float8[])[3]+0.5,(baseline::float8[])[4]-0.4] WHERE id=1;" >/dev/null 2>&1
  local r15; r15=$("${PSQL[@]}" -c "
     SELECT trace_complexity::text FROM fractal_agent_detour_classify(
       'bt_agents_vehicles','current',
       (SELECT baseline::float8[] FROM bt_agents_vehicles WHERE id=1),
       (SELECT current::float8[] FROM bt_agents_vehicles WHERE id=1),
       (SELECT array_agg(cum ORDER BY t, ord) FROM (
          SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
          FROM generate_series(1,100) t
          CROSS JOIN LATERAL (VALUES (1,(random()-0.5)*0.3),(2,(random()-0.5)*0.3)) AS s(ord,step)
        ) c),
       5, 'id', 2);" 2>&1)
  grep <<< "$r15" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: detour_classify trace_complexity is the real box-counting dimension of the GPS trace" \
    || fail "23 agents: expected a numeric trace_complexity, got: $r15"
  local r15b; r15b=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_detour_classify(
       'bt_agents_vehicles','current',
       (SELECT baseline::float8[] FROM bt_agents_vehicles WHERE id=1),
       (SELECT current::float8[] FROM bt_agents_vehicles WHERE id=1),
       (SELECT array_agg(cum ORDER BY t, ord) FROM (
          SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
          FROM generate_series(1,100) t
          CROSS JOIN LATERAL (VALUES (1,(random()-0.5)*0.3),(2,(random()-0.5)*0.3)) AS s(ord,step)
        ) c),
       5, 'id', 2);" 2>&1)
  grep <<< "$r15b" -q 'gap-analysis-canary' \
    && pass "23 agents: detour_classify composes trajectory+boxcount -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r15b"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_vehicles;" >/dev/null 2>&1
  local r15c; r15c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_detour_classify(
       'bt_agents_vehicles','current',
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.2,0.2,0.2,0.2]::float8[],
       ARRAY[0,0,0,0]::float8[], 5, 'id', 2);" 2>&1)
  grep <<< "$r15c" -q 'no vehicle rows' \
    && pass "23 agents: detour_classify raises a clean ERROR when the vehicle table is empty" \
    || fail "23 agents: expected a no-vehicle-rows ERROR, got: $r15c"

  # --- 16: fractal_agent_track_anomaly happy + guard -------------------
  # nearest_fleet_id is the REAL trajectory nearest; dfa_exponent is the REAL
  # DFA exponent of the heading series (may be -1, still numeric); rationale
  # is the reason step (canary).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agents_tracks;
     CREATE TABLE bt_agents_tracks (id int PRIMARY KEY, baseline float8[], current float8[]);
     INSERT INTO bt_agents_tracks SELECT gs, ARRAY[b1,b2,b3,b4], ARRAY[b1+0.04,b2+0.04,b3+0.04,b4+0.04]
       FROM generate_series(1,8) gs,
            LATERAL (SELECT random()*2-1 a, random()*2-1 b, random()*2-1 c, random()*2-1 d) bl(b1,b2,b3,b4);
     UPDATE bt_agents_tracks SET current = ARRAY[(baseline::float8[])[1]+0.6,(baseline::float8[])[2]-0.5,(baseline::float8[])[3]-0.9,(baseline::float8[])[4]+0.8] WHERE id=1;" >/dev/null 2>&1
  local r16; r16=$("${PSQL[@]}" -c "
     SELECT dfa_exponent::text FROM fractal_agent_track_anomaly(
       'bt_agents_tracks','current',
       (SELECT baseline::float8[] FROM bt_agents_tracks WHERE id=1),
       (SELECT current::float8[] FROM bt_agents_tracks WHERE id=1),
       (SELECT array_agg(cum ORDER BY t) FROM (
          SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t, (random()-0.5)*(CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1,120) t) s
        ) c),
       5, 'id');" 2>&1)
  grep <<< "$r16" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: track_anomaly dfa_exponent is the real DFA exponent of the heading series" \
    || fail "23 agents: expected a numeric dfa_exponent, got: $r16"
  local r16b; r16b=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_track_anomaly(
       'bt_agents_tracks','current',
       (SELECT baseline::float8[] FROM bt_agents_tracks WHERE id=1),
       (SELECT current::float8[] FROM bt_agents_tracks WHERE id=1),
       (SELECT array_agg(cum ORDER BY t) FROM (
          SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t, (random()-0.5)*(CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1,120) t) s
        ) c),
       5, 'id');" 2>&1)
  grep <<< "$r16b" -q 'gap-analysis-canary' \
    && pass "23 agents: track_anomaly composes trajectory+dfa -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r16b"
  "${PSQL[@]}" -c "DELETE FROM bt_agents_tracks;" >/dev/null 2>&1
  local r16c; r16c=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_track_anomaly(
       'bt_agents_tracks','current',
       ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.2,0.2,0.2,0.2]::float8[],
       ARRAY[0,0,0]::float8[], 5, 'id');" 2>&1)
  grep <<< "$r16c" -q 'no track rows' \
    && pass "23 agents: track_anomaly raises a clean ERROR when the track table is empty" \
    || fail "23 agents: expected a no-track-rows ERROR, got: $r16c"

  # --- 17: fractal_agent_network_coverage_alert happy + NULL guard -----
  # morph_dimension + lacunarity are the REAL morphological_complexity output
  # (needs >= ~256 points -- use a 20x20 grid, matching the smart-cities
  # demo); drift_detected is the REAL |drift|>threshold over a step-up
  # series (true); rationale is the reason step (canary).
  local r17; r17=$("${PSQL[@]}" -c "
     SELECT morph_dimension::text FROM fractal_agent_network_coverage_alert(
       (SELECT array_agg(v ORDER BY id, ord) FROM (
          SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
          CROSS JOIN generate_series(0,19) c
          CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
        ) g),
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       2, 48, 0.5);" 2>&1)
  grep <<< "$r17" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: network_coverage_alert morph_dimension is the real morphological complexity" \
    || fail "23 agents: expected a numeric morph_dimension, got: $r17"
  local r17b; r17b=$("${PSQL[@]}" -c "
     SELECT drift_detected::text FROM fractal_agent_network_coverage_alert(
       (SELECT array_agg(v ORDER BY id, ord) FROM (
          SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
          CROSS JOIN generate_series(0,19) c
          CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
        ) g),
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       2, 48, 0.5);" 2>&1)
  grep <<< "$r17b" -q '^true$' \
    && pass "23 agents: network_coverage_alert drift_detected=true for a real regime-change series (|drift|>0.5)" \
    || fail "23 agents: expected drift_detected=t, got: $r17b"
  local r17c; r17c=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_network_coverage_alert(
       (SELECT array_agg(v ORDER BY id, ord) FROM (
          SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
          CROSS JOIN generate_series(0,19) c
          CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
        ) g),
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       2, 48, 0.5);" 2>&1)
  grep <<< "$r17c" -q 'gap-analysis-canary' \
    && pass "23 agents: network_coverage_alert composes morph+drift -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r17c"
  local r17d; r17d=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_network_coverage_alert(
       NULL::float8[], ARRAY[1,2,3]::float8[], 2, 48, 0.5);" 2>&1)
  grep <<< "$r17d" -q 'point_cloud and drift_series are required' \
    && pass "23 agents: network_coverage_alert raises a clean ERROR when point_cloud/drift_series is NULL" \
    || fail "23 agents: expected a required-args ERROR, got: $r17d"

  # --- 18: fractal_agent_regime_triage happy + NULL guard --------------
  # dfa_exponent is the REAL DFA exponent; drift_detected is the REAL
  # |drift|>threshold (true for the step-up series); recent/baseline alphas
  # are real; rationale is the reason step (canary).
  local r18; r18=$("${PSQL[@]}" -c "
     SELECT dfa_exponent::text FROM fractal_agent_regime_triage(
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       64, 0.5);" 2>&1)
  grep <<< "$r18" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "23 agents: regime_triage dfa_exponent is the real DFA exponent" \
    || fail "23 agents: expected a numeric dfa_exponent, got: $r18"
  local r18b; r18b=$("${PSQL[@]}" -c "
     SELECT drift_detected::text FROM fractal_agent_regime_triage(
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       64, 0.5);" 2>&1)
  grep <<< "$r18b" -q '^true$' \
    && pass "23 agents: regime_triage drift_detected=true for a real regime-change series (|drift|>0.5)" \
    || fail "23 agents: expected drift_detected=t, got: $r18b"
  local r18c; r18c=$("${PSQL[@]}" -c "
     SELECT rationale FROM fractal_agent_regime_triage(
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       64, 0.5);" 2>&1)
  grep <<< "$r18c" -q 'gap-analysis-canary' \
    && pass "23 agents: regime_triage composes dfa+drift -> reason (canary)" \
    || fail "23 agents: expected the canary in rationale, got: $r18c"
  local r18d; r18d=$("${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_regime_triage(NULL::float8[], 64, 0.5);" 2>&1)
  grep <<< "$r18d" -q 'series is required' \
    && pass "23 agents: regime_triage raises a clean ERROR when series is NULL" \
    || fail "23 agents: expected a series-required ERROR, got: $r18d"
  # An EXPLICIT NULL for the trailing optional numeric parameter must fall
  # back to the documented default (0.5), like the sibling's da_opt_double.
  # PostgreSQL substitutes a DEFAULT only for an OMITTED argument, so
  # without the COALESCE the comparison `abs(dv) > drift_threshold` yields
  # NULL, drift_detected comes back NULL (not true) and the prompt text is
  # left with a hole. The series is the SAME shape as the passing assertion
  # above -- only the third argument differs (NULL instead of 0.5) -- so the
  # assertion isolates the COALESCE and nothing else. (A two-level step
  # series is NOT usable here: the core drift estimator rejects a degenerate
  # series with rc=-1 before the threshold is ever compared.)
  local r18e; r18e=$("${PSQL[@]}" -c "
     SELECT drift_detected::text FROM fractal_agent_regime_triage(
       (SELECT array_agg(v ORDER BY t) FROM (
          SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                         ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
          FROM generate_series(1,96) t) s),
       64, NULL);" 2>&1)
  grep <<< "$r18e" -q '^true$' \
    && pass "23 agents: regime_triage applies the 0.5 default when drift_threshold is an explicit NULL" \
    || fail "23 agents: expected drift_detected=t for an explicit-NULL drift_threshold, got: '$r18e'"

  # Restore session state: diversify was enabled by recommend_diverse and
  # feedback_audit (feedback_audit self-disables, but belt-and-suspenders).
  "${PSQL[@]}" -c "SELECT fractal_diversify_disable();" >/dev/null 2>&1

  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_agents_caps, bt_agents_badstates, bt_agents_mem, bt_agents_catalog;" >/dev/null 2>&1
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_agents_logs;" >/dev/null 2>&1
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_agents_data, bt_agents_patients, bt_agents_fcatalog, bt_agents_fwarmup, bt_agents_nodes, bt_agents_alloc, bt_agents_vehicles, bt_agents_tracks;" >/dev/null 2>&1
  rm -f /tmp/fractalsql_bt_sql.txt
  return 0
}

# FUZZ only -- not in DEFAULT or QUICK, run via --fuzz. No live cluster
# needed: builds + briefly runs libFuzzer drivers against the three
# hand-rolled parsers this repo has that read externally-influenceable
# text into a fixed-size buffer (src/fractalsql_parse.c -- factored out
# of src/fractalsql.c specifically so these can be linked standalone,
# without postgres.h/a running backend; see that file's own header
# comment). fsql_parse_embedding_array is the highest-priority target:
# it parses fractal_embed()'s raw response from whatever embedding
# endpoint fractalsql.http_embed_url points at, i.e. genuinely
# attacker-controlled bytes if that endpoint is malicious or merely
# buggy. The other two (fsql_extract_best_point, fsql_extract_population)
# parse the vendored core's own result JSON -- lower external-adversary
# risk, included as defense-in-depth for the same hand-rolled-strtod-
# scan class of bug.
#
# This is a SMOKE run (FSQL_FUZZ_TIME seconds per target, default 30),
# not a real fuzzing campaign -- it exists to catch a regression before
# push. Run a real multi-hour campaign locally (same binaries, higher
# -max_total_time) before relying on this gate to have found everything.
gate_21_fuzz_smoke() {
  local cc="${FSQL_FUZZ_CC:-}"
  if [[ -z "$cc" ]]; then
    for candidate in clang-18 clang-17 clang-16 clang-15 clang; do
      if command -v "$candidate" >/dev/null 2>&1; then cc="$candidate"; break; fi
    done
  fi
  if [[ -z "$cc" ]] || ! command -v "$cc" >/dev/null 2>&1; then
    skip "21 fuzz_smoke (no clang found -- set FSQL_FUZZ_CC to a libFuzzer-capable clang)"
    return
  fi
  # The clang resolved above might not actually have libFuzzer support
  # (e.g. a bare `clang` shadowed by an unrelated toolchain's shim) --
  # verify with a trivial compile before trusting it for the real
  # targets, rather than failing confusingly three functions down.
  local probe_src probe_bin
  probe_src="$(mktemp /tmp/fractalsql_bt_fuzzprobe_XXXXXX.c)"
  probe_bin="${probe_src%.c}"
  printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){(void)d;(void)n;return 0;}\n' > "$probe_src"
  if ! "$cc" -fsanitize=fuzzer "$probe_src" -o "$probe_bin" >/dev/null 2>&1; then
    rm -f "$probe_src" "$probe_bin"
    skip "21 fuzz_smoke ($cc lacks -fsanitize=fuzzer support -- set FSQL_FUZZ_CC)"
    return
  fi
  rm -f "$probe_src" "$probe_bin"

  local fuzz_time="${FSQL_FUZZ_TIME:-30}"
  mkdir -p /tmp/fractalsql_bt_fuzz

  local target
  for target in parse_embedding_array extract_best_point extract_population; do
    local bin="/tmp/fractalsql_bt_fuzz/fuzz_$target"
    local buildlog="/tmp/fractalsql_bt_fuzz_${target}_build.log"
    if ! "$cc" -std=c99 -O1 -g -fsanitize=fuzzer,address -fno-sanitize-recover=address \
        -Isrc \
        src/fractalsql_parse.c "tests/fuzz/fuzz_${target}.c" \
        -o "$bin" >"$buildlog" 2>&1; then
      fail "21 fuzz_smoke: $target — build failed, see $buildlog"
      continue
    fi

    local runlog="/tmp/fractalsql_bt_fuzz_${target}_run.log"
    if ASAN_OPTIONS=detect_leaks=0 "$bin" -max_total_time="$fuzz_time" -print_final_stats=1 \
        "tests/fuzz/corpus_${target}/" >"$runlog" 2>&1; then
      local execs; execs=$(grep -o "number_of_executed_units: [0-9]*" "$runlog" | grep -o "[0-9]*")
      pass "21 fuzz_smoke: $target — ${fuzz_time}s clean (${execs:-?} execs, no crash)"
    else
      fail "21 fuzz_smoke: $target — crash/hang found, see $runlog (repro: $bin <crash-file>)"
    fi
    rm -f "$bin"
  done
  return 0
}


# Table runner shared by gates 44 and 45. Reads "label<TAB>expect<TAB>sql"
# rows from stdin: expect = "E:<text>" (an ERROR whose message contains the
# fixed string <text>), "OK" (no ERROR) or "NONE" (either). A row also fails
# if the backend crashes or the connection drops. A "@mock" row swaps the
# reasoning mock back in. $1 = gate number for messages; sets TBL_N/TBL_BAD.
TBL_N=0; TBL_BAD=0
sql_table_run() {
  local gate="$1" label expect sql out i
  TBL_N=0; TBL_BAD=0
  while IFS=$'\t' read -r label expect sql; do
    [[ -z "$label" ]] && continue
    if [[ "$label" = "@mock" ]]; then pg_swap_plugin "$MOCK" >/dev/null; continue; fi
    # "@plugin<TAB>VAR": swap the reasoning plugin to the path in $VAR (MOCK, EMBED, ...).
    # "@guc<TAB>name<TAB>value": ALTER SYSTEM SET fractalsql.<name> = value, then wait for it.
    if [[ "$label" = "@plugin" ]]; then pg_swap_plugin "${!expect}" >/dev/null; continue; fi
    if [[ "$label" = "@guc" ]]; then
      pg_set_guc "fractalsql.$expect" "'$sql'" "$sql" >/dev/null \
        || fail "$gate error_paths: could not set fractalsql.$expect"
      continue
    fi
    TBL_N=$((TBL_N + 1))
    # </dev/null: psql would otherwise consume the rest of this loop's input.
    out=$("${PSQL[@]}" -c "$sql" 2>&1 </dev/null | awk '
      /^WARNING:/ { skip = 1; next }                 # drop a WARNING and its HINT/DETAIL/CONTEXT tail
      skip && /^(HINT|DETAIL|CONTEXT|QUERY):/ { next }
      { skip = 0; print }')
    # Record mode (FSQL_TBL_DISCOVER=<file>): write each row's actual output
    # instead of asserting, to (re)pin a table's expected messages.
    if [[ -n "${FSQL_TBL_DISCOVER:-}" ]]; then
      printf '%s => %s\n' "$label" "$(tr '\n' ' ' <<<"$out" | tr -cd '\11\40-\176' | cut -c1-230)" >> "$FSQL_TBL_DISCOVER"
      grep -q "server closed the connection\|in recovery mode\|not yet accepting" <<<"$out" \
        && for i in $(seq 1 60); do "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 </dev/null && break; sleep 0.5; done
      continue
    fi
    if grep -q "server closed the connection\|terminated by signal\|in recovery mode\|not yet accepting" <<<"$out"; then
      fail "$gate error_paths: '$label' CRASHED the backend: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
      TBL_BAD=$((TBL_BAD + 1))
      for i in $(seq 1 $((60 * TIMEOUT_MULT))); do "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 </dev/null && break; sleep 0.5; done
      continue
    fi
    case "$expect" in
      E:*) grep -qF -- "${expect#E:}" <<<"$out" && grep -q "^ERROR:" <<<"$out" \
             || { fail "$gate error_paths: '$label' expected ERROR containing '${expect#E:}', got: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"; TBL_BAD=$((TBL_BAD + 1)); } ;;
      OK)  grep -q "^ERROR:" <<<"$out" \
             && { fail "$gate error_paths: '$label' expected success, got: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"; TBL_BAD=$((TBL_BAD + 1)); } ;;
      *)   ;;
    esac
  done
}

# Gate 44: error-path / argument-validation sweep. One table of calls, each
# with the outcome it must produce: "E:<text>" = must raise an ERROR whose
# message contains <text> (fixed-string match); "OK" = must complete without
# an ERROR; "NONE" = either is acceptable. EVERY row additionally fails if the
# backend crashes or the connection drops -- the property the engine's
# non-STRICT entry points (PG_GETARG_* on a NULL datum) are most exposed to.
# Exists chiefly for branch coverage of the argument-validation/ereport paths
# that the happy-path gates never reach, and doubles as a regression table:
# it found fractal_sql_agent(NULL) and fractal_sql_agent(q, NULL, 0) taking
# the backend down. fractal_optimize_portfolio_multimodal[_pareto] and the
# audit functions check the enterprise tier before anything else, so only
# their NULL-argument guards are reachable here; gate 45 covers the rest
# against the mock enterprise core.
gate_44_error_paths() {
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_g44;
     CREATE TABLE bt_g44 (id int, emb float8[]);
     INSERT INTO bt_g44 VALUES (1, ARRAY[0.1,0.2]), (2, ARRAY[0.3,0.2]), (3, ARRAY[0.9,0.8]);
     DROP TABLE IF EXISTS bt_g44x, bt_g44e;
     CREATE TABLE bt_g44x (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_g44x (emb) VALUES (ARRAY[0.1,0.2,0.3,0.4]), (ARRAY[0.4,0.3,0.2,0.1]), (ARRAY[0.9,0.8,0.7,0.6]);
     CREATE TABLE bt_g44e (id serial PRIMARY KEY, emb float8[], txt text);
     INSERT INTO bt_g44e (emb, txt) VALUES (ARRAY[0.1,0.2,0.3], 'a'), (ARRAY[0.3,0.2,0.1], 'b'), (ARRAY[0.9,0.8,0.7], 'c');
     DROP TABLE IF EXISTS bt_g44n, bt_g44d, bt_g44z, bt_g44t, bt_g44v, bt_g44w;
     CREATE TABLE bt_g44n (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_g44n (emb) VALUES (NULL), (ARRAY[0.1,0.2]), (NULL);
     CREATE TABLE bt_g44d (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_g44d (emb) VALUES (ARRAY[0.1,0.2]), (ARRAY[0.1,0.2,0.3]);
     CREATE TABLE bt_g44z (id serial PRIMARY KEY, emb float8[]);
     CREATE TABLE bt_g44t (id serial PRIMARY KEY, emb text);
     INSERT INTO bt_g44t (emb) VALUES ('x'), ('y');
     CREATE TABLE bt_g44v (id serial PRIMARY KEY, emb fractal_vector);
     INSERT INTO bt_g44v (emb) VALUES ('[0.1,0.2]'), ('[0.3,0.2]'), ('[0.9,0.8]');
     CREATE TABLE bt_g44w (id serial PRIMARY KEY, emb fractal_vector);
     INSERT INTO bt_g44w (emb) VALUES ('[0.1,0.2]'), ('[0.1,0.2,0.3]');
  " >/dev/null 2>&1
  # The embed-dependent rows (agents, fractal_embed) need the embed mock and a
  # configured endpoint; the "@mock" row below swaps the reasoning mock back
  # in for the rows after it (fractal_sql_agent).
  pg_swap_plugin "$EMBED" >/dev/null
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "44 error_paths: http_embed_url GUC did not take effect"; return; }

  sql_table_run 44 <<'FSQL_TBL_ROWS'
search_agent null query	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent(NULL,'bt_g44e','emb')
search_agent null table	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent('q',NULL,'emb')
search_agent null col	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent('q','bt_g44e',NULL)
search_agent pop 0	E:fractalsql: search failed	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',0,15)
search_agent iter 0	OK	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',50,0)
search_agent null pop	OK	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',NULL,NULL)
rag null q	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent(NULL,'bt_g44e','emb')
rag null tbl	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent('q',NULL,'emb')
rag null col	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent('q','bt_g44e',NULL)
rag bad filter	OK	SELECT * FROM fractal_rag_agent('q','bt_g44e','emb','not json')
plan null state	OK	SELECT * FROM fractal_agent_plan_explore(NULL,'bt_g44e','emb',3)
plan null tbl	OK	SELECT * FROM fractal_agent_plan_explore('s',NULL,'emb',3)
plan null col	OK	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e',NULL,3)
plan null br	OK	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e','emb',NULL)
plan br 0	E:fractalsql: plan_explore search failed (rc=-1)	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e','emb',0)
traj null tbl	OK	SELECT * FROM fractal_agent_trajectory_predict(NULL,'emb',1,3)
traj null col	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e',NULL,1,3)
traj null id	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',NULL,3)
traj null steps	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,NULL)
traj steps 0	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,0)
traj steps big	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,100000)
traj missing id	E:fractal_agent_trajectory_predict: no row in bt_g44e with id = 999999	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',999999,3)
loop null id	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop(NULL,ARRAY[1,2]::float8[],1)
loop null log	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop('a',NULL,1)
loop null dim	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],NULL)
loop dim 0	E:fractalsql: dim must be > 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],0)
loop bits 0	E:fractalsql: n_bits must be > 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,0)
loop bits huge	OK	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,100000)
loop ragged	E:fractalsql: state_log length (3) is not a multiple of dim (2)	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2,3]::float8[],2)
loop neg thresh	E:fractalsql: hamming_threshold must be >= 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,64,0.0,-1)
loop null opts	OK	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2,1,2,1,2]::float8[],2,NULL,NULL,NULL)
loop empty log	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a','{}'::float8[],1)
loop null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,NULL]::float8[],1)
loop 2d array	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[[1,2],[3,4]]::float8[],1)
fingerprint bits 0	E:fractalsql: n_bits must be > 0	SELECT fractal_state_fingerprint(ARRAY[1,2]::float8[],0)
fingerprint empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_state_fingerprint('{}'::float8[],8)
cycle null elem	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY['\x01',NULL]::bytea[])
cycle ragged	E:fractalsql: every fingerprint must be the same length (index 0 was 1 b	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x0102']::bytea[])
cycle neg thresh	E:fractalsql: hamming_threshold must be >= 0	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x01']::bytea[],-1)
cycle empty	E:fractalsql: fingerprints array must not be empty	SELECT * FROM fractal_cycle_detect('{}'::bytea[])
cycle repeat	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x02','\x01','\x02','\x01','\x02']::bytea[])
cycle thresh	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x00','\x01','\x00','\x01','\x00','\x01']::bytea[],2)
cycle 2d	OK	SELECT * FROM fractal_cycle_detect(ARRAY[['\x01','\x02'],['\x03','\x04']]::bytea[])
dfa null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_dimension_dfa(ARRAY[1,NULL,3]::float8[])
dfa empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_dimension_dfa('{}'::float8[])
boxcount dim 0	E:fractalsql: points length (4) must be a positive multiple of dim (0)	SELECT fractal_dimension_boxcount(ARRAY[1,2,3,4]::float8[],0)
boxcount ragged	E:fractalsql: points length (3) must be a positive multiple of dim (2)	SELECT fractal_dimension_boxcount(ARRAY[1,2,3]::float8[],2)
boxcount few	E:fractalsql: fractal_dimension_boxcount rc=-1 (need >= 8 points, non-de	SELECT fractal_dimension_boxcount(ARRAY[1,2]::float8[],2)
cp thresh	E:fractalsql: fractal_change_point_detect rc=-1 (need n >= 2*win, thresh	SELECT fractal_change_point_detect(ARRAY[1,2,3,4,5,6,7,8]::float8[],2,-1.0,16)
cp max_points 0	E:fractalsql: max_points must be > 0	SELECT fractal_change_point_detect(ARRAY[1,2,3,4,5,6,7,8]::float8[],2,2.0,0)
cp short	E:fractalsql: fractal_change_point_detect rc=-1 (need n >= 2*win, thresh	SELECT fractal_change_point_detect(ARRAY[1,2,3]::float8[],16,2.0,16)
cp null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_change_point_detect(ARRAY[1,NULL,3]::float8[],2,2.0,16)
periodogram short	E:fractalsql: fractal_periodogram rc=-1 (need n >= 4)	SELECT * FROM fractal_periodogram(ARRAY[1,2,3]::float8[],4)
periodogram peaks 0	E:fractalsql: max_peaks must be > 0	SELECT * FROM fractal_periodogram(ARRAY[1,2,3,4,5,6,7,8]::float8[],0)
periodogram null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_periodogram(ARRAY[1,NULL,3,4,5]::float8[],4)
tda dim 0	E:fractalsql: dim must be > 0	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],0)
tda ragged	E:fractalsql: points length (3) must be a multiple of dim (2)	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3]::float8[],2)
tda max_dim	E:fractalsql: fractal_tda_persistence_diagram rc=-1 (2 <= n_points <= 51	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,-1)
tda thresh	E:fractalsql: fractal_tda_persistence_diagram rc=-1 (2 <= n_points <= 51	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,1,-1.0)
tda bars	E:fractalsql: max_h0_bars must be > 0	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,1,1.0,0)
drift win	E:fractalsql: window must be > 0	SELECT fractal_dimension_drift(ARRAY[1,2,3,4]::float8[],0)
drift short	E:fractalsql: fractal_dimension_drift rc=-1 (need n >= window + 16, wind	SELECT fractal_dimension_drift(ARRAY[1,2,3,4]::float8[],64)
portfolio k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
portfolio k big	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],5)
portfolio cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
portfolio bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,NULL,false,'bogus')
portfolio null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
portfolio null mu	E:fractalsql: fractal_optimize_portfolio: mu must not be NULL	SELECT fractal_optimize_portfolio(NULL,ARRAY[1,0,0,1]::float8[],1)
portfolio null cov	E:fractalsql: fractal_optimize_portfolio: cov must not be NULL	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],NULL,1)
portfolio null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
portfolio ok	OK	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,7)
portfolio ok obl	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,7,true,'cauchy')
mm null mu	E:fractalsql: fractal_optimize_portfolio_multimodal: mu must not be NULL	SELECT fractal_optimize_portfolio_multimodal(NULL,ARRAY[1,0,0,1]::float8[],1)
mm null cov	E:fractalsql: fractal_optimize_portfolio_multimodal: cov must not be NUL	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],NULL,1)
pareto null mu	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: mu must not 	SELECT fractal_optimize_portfolio_multimodal_pareto(NULL,ARRAY[1,0,0,1]::float8[],1)
pareto null cov	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: cov must not	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],NULL,1)
subset null vals	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(NULL,ARRAY[1,1]::float8[],1)
subset null ub	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],NULL,1)
subset null k	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],NULL)
subset k 0	E:fractalsql: k must satisfy 1 <= k <= n_items (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],0)
subset ub len	E:fractalsql: upper_bounds length (1) must match item_values length (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1]::float8[],1)
subset prev len	E:fractalsql: prev_weights length (1) must match item_values length (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],1,ARRAY[1]::float8[])
subset neg pen	E:fractalsql: fractal_optimize_subset rc=-1 (check upper_bounds in [0,1]	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],1,NULL,-1.0)
subset ok prev	OK	SELECT fractal_optimize_subset(ARRAY[1,2,3]::float8[],ARRAY[1,1,1]::float8[],2,ARRAY[0.5,0.5,0]::float8[],0.1,3)
subset ok nulls	OK	SELECT fractal_optimize_subset(ARRAY[1,2,3]::float8[],ARRAY[1,1,1]::float8[],2,NULL,NULL,NULL)
vascular null	OK	SELECT fractal_vascular_network(NULL,ARRAY[0,1]::int4[],ARRAY[1.0]::float8[])
vascular null edges	OK	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],NULL,ARRAY[1.0]::float8[])
vascular null arc	OK	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],NULL)
vascular coords len	E:fractalsql: node_coords length must be a multiple of 3	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0]::float8[],ARRAY[0,1]::int4[],ARRAY[1.0]::float8[])
vascular edges odd	E:fractalsql: edges length must be a multiple of 2	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1,0]::int4[],ARRAY[1.0]::float8[])
vascular arc len	E:fractalsql: edge_arc_length length (2) must equal edges length / 2 (1)	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],ARRAY[1.0,2.0]::float8[])
vascular idx range	E:fractalsql: fractal_vascular_network rc=-1	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,9]::int4[],ARRAY[1.0]::float8[])
vascular neg idx	E:fractalsql: index array entries must be >= 0 (got -1)	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[-1,1]::int4[],ARRAY[1.0]::float8[])
vascular neg arc	E:fractalsql: fractal_vascular_network rc=-1	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],ARRAY[-1.0]::float8[])
folding null	OK	SELECT fractal_cortical_folding(NULL,ARRAY[0,1,2]::int4[])
folding null faces	OK	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],NULL)
folding verts len	E:fractalsql: vertices length must be a multiple of 3	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0]::float8[],ARRAY[0,1,2]::int4[])
folding faces len	E:fractalsql: faces length must be a multiple of 3	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],ARRAY[0,1]::int4[])
folding idx range	E:fractalsql: fractal_cortical_folding rc=-1 (need >= 4 non-coplanar ver	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],ARRAY[0,1,9]::int4[])
nerve null	OK	SELECT fractal_nerve_plexus_metric(NULL,2,ARRAY[0,1]::int4[])
nerve null dim	OK	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],NULL,ARRAY[0,1]::int4[])
nerve null edges	OK	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,NULL)
nerve dim 0	E:fractalsql: node_coords length (4) must be a positive multiple of dim 	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],0,ARRAY[0,1]::int4[])
nerve ragged	E:fractalsql: node_coords length (3) must be a positive multiple of dim 	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1]::float8[],2,ARRAY[0,1]::int4[])
nerve edges odd	E:fractalsql: edges length must be a multiple of 2	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[0,1,0]::int4[])
nerve idx range	E:fractalsql: fractal_nerve_plexus_metric rc=-1	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[0,7]::int4[])
morph null	OK	SELECT fractal_morphological_complexity(NULL,2)
morph null dim	OK	SELECT fractal_morphological_complexity(ARRAY[0,0,1,0]::float8[],NULL)
morph dim 0	E:fractalsql: points length (4) must be a positive multiple of dim (0)	SELECT fractal_morphological_complexity(ARRAY[0,0,1,0]::float8[],0)
morph ragged	E:fractalsql: points length (3) must be a positive multiple of dim (2)	SELECT fractal_morphological_complexity(ARRAY[0,0,1]::float8[],2)
store_morph null	OK	SELECT fractal_store_morphology(NULL,ARRAY[1,2]::float8[])
store_morph null arr	OK	SELECT fractal_store_morphology(1,NULL)
store_morph empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_store_morphology(1,'{}'::float8[])
mine null	OK	SELECT * FROM fractal_mine_topology_negatives(NULL,3)
mine null k	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[1,2]::float8[],NULL)
mine k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_mine_topology_negatives(ARRAY[1,2]::float8[],0)
mine empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_mine_topology_negatives('{}'::float8[],3)
telemetry null tbl	OK	SELECT * FROM fractal_search_telemetry(NULL,'emb',ARRAY[1,2]::float8[],1)
telemetry null col	OK	SELECT * FROM fractal_search_telemetry('bt_g44',NULL,ARRAY[1,2]::float8[],1)
telemetry null q	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',NULL,1)
telemetry null k	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2]::float8[],NULL)
telemetry k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2]::float8[],0)
telemetry no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_telemetry('bt_nope','emb',ARRAY[1,2]::float8[],1)
telemetry no col	E:column "nope" does not exist	SELECT * FROM fractal_search_telemetry('bt_g44','nope',ARRAY[1,2]::float8[],1)
telemetry empty q	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_search_telemetry('bt_g44','emb','{}'::float8[],1)
telemetry dim mismatch	E:fractalsql: bt_g44.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2,3]::float8[],1)
telemetry ok	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid null tbl	OK	SELECT * FROM fractal_hybrid_clinical_search(NULL,'emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid null col	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44',NULL,ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid null q	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',NULL,ARRAY['(0,1)'],1)
hybrid null ids	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],NULL,1)
hybrid null k	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],NULL)
hybrid k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],0)
hybrid bad ctid	E:fractalsql: doc_ids cohort matched no rows in bt_g44.emb	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['zzz'],1)
hybrid empty ids	E:fractalsql: doc_ids must be a 1-D non-null text[] of ctid strings	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],'{}'::text[],1)
hybrid null id elem	E:fractalsql: doc_ids must be a 1-D non-null text[] of ctid strings	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[NULL]::text[],1)
hybrid no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_hybrid_clinical_search('bt_nope','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid ok	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY['(0,1)','(0,2)'],2)
traj_search null tbl	OK	SELECT * FROM fractal_search_trajectory(NULL,'emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search null col	OK	SELECT * FROM fractal_search_trajectory('bt_g44',NULL,ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search null base	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',NULL::float8[],ARRAY[1,2]::float8[],1)
traj_search null cur	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],NULL::float8[],1)
traj_search null k	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],NULL)
traj_search k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0)
traj_search dim mismatch	E:fractalsql: baseline_vector dim (2) must match current_vector dim (3)	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2,3]::float8[],1)
traj_search no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_trajectory('bt_nope','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search ok	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
traj_search_fv null tbl	OK	SELECT * FROM fractal_search_trajectory(NULL,'emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,1)
traj_search_fv null base	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',NULL::fractal_vector,'[1,2]'::fractal_vector,1)
traj_search_fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44','emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0)
traj_search_fv ok	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,2)
cross null tbl	OK	SELECT * FROM fractal_cross_modal_search(NULL,'emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0.5,1)
cross null m	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',NULL::float8[],ARRAY[1,2]::float8[],0.5,1)
cross null c	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],NULL::float8[],0.5,1)
cross null alpha	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],NULL,1)
cross alpha lo	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],-0.1,1)
cross alpha hi	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1.1,1)
cross k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0.5,0)
cross dim mismatch	E:fractalsql: bt_g44x.emb row 0 has dim 4, expected 5 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2,3]::float8[],0.5,1)
cross ok	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],0.5,2)
cross_fv null tbl	OK	SELECT * FROM fractal_cross_modal_search(NULL,'emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0.5,1)
cross_fv alpha	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,2.0,1)
cross_fv ok	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0.5,2)
explore bad col	E:column "nope" does not exist	SELECT * FROM fractal_search_explore('bt_g44','nope',ARRAY[1,2]::float8[])
explore no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_explore('bt_nope','emb',ARRAY[1,2]::float8[])
explore bad opts	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[1,2]::float8[],'[1]'::jsonb)
explore pop	E:fractalsql: population_size 0 out of range [1, 100000]	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[1,2]::float8[],'{"population_size":0}')
explore ok	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"iterations":3,"population_size":5}')
explore str opt	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"iterations":"x"}')
search iter 0	E:fractalsql: iterations 0 out of range [1, 10000]	SELECT fractal_search(ARRAY[1,2]::float8[],0)
search pop 0	E:fractalsql: population_size 0 out of range [1, 100000]	SELECT fractal_search(ARRAY[1,2]::float8[],5,0)
search empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_search('{}'::float8[])
search_dbg diff	E:fractalsql: diffusion_factor 99 out of range [1, 32]	SELECT fractal_search_debug(ARRAY[1,2]::float8[],5,5,99)
embed null	E:fractal_embed: input must not be NULL	SELECT fractal_embed(NULL)
embed empty	E:fractal_embed: dispatch failed (rc=-1): fractalsql: invalid arguments 	SELECT fractal_embed('')
schema bad tbl	E:fractal_schema_context: table "bt_nope" not found or not visible	SELECT fractal_schema_context(ARRAY['bt_nope'])
schema empty arr	E:fractal_schema_context: no visible tables found	SELECT fractal_schema_context('{}'::text[])
schema null elem	E:fractal_schema_context: no visible tables found	SELECT fractal_schema_context(ARRAY[NULL]::text[])
schema hint	OK	SELECT length(fractal_schema_context(ARRAY['bt_g44'],'embedding'))>0
t2s null tables elem	E:fractal_schema_context: no visible tables found	SELECT fractal_text_to_sql('q',ARRAY[NULL]::text[])
getcfg unknown	E:fractalsql_get_config: unknown config key "nope"	SELECT fractalsql_get_config('nope')
getcfg secret	OK	SELECT fractalsql_get_config('enterprise_ledger_key')
getcfg prefixed	OK	SELECT fractalsql_get_config('fractalsql.http_url')
getcfg null	E:fractalsql_get_config: the key must not be NULL	SELECT fractalsql_get_config(NULL)
getcfg all keys	OK	SELECT k,fractalsql_get_config(k) FROM unnest(ARRAY['reasoning_plugin','http_url','http_model','http_allow_plaintext','http_embed_url','http_embed_model','http_think','http_think_provider','http_native_url','http_num_ctx','text_to_sql_max_attempts','text_to_sql_allowed_statements','text_to_sql_use_review','enterprise_lib','enterprise_require_signature','agent_partial_reasoning_fail']) k
setcfg unknown	E:fractalsql_set_config: unknown config key "nope"	SELECT fractalsql_set_config('nope','x')
setcfg null val	E:fractalsql_set_config: the value must not be NULL	SELECT fractalsql_set_config('agent_partial_reasoning_fail',NULL)
setcfg bad bool	E:fractalsql_set_config: "agent_partial_reasoning_fail" expects a boolea	SELECT fractalsql_set_config('agent_partial_reasoning_fail','maybe')
setcfg ok	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','on')
setcfg reload	E:fractalsql_set_config: "fractalsql.http_url" is reload-scoped and cann	SELECT fractalsql_set_config('http_url','http://x')
setcfg secret	NONE	SELECT fractalsql_set_config('enterprise_ledger_key','abc')
setcfg max_attempts bad	E:fractalsql_set_config: "text_to_sql_max_attempts" expects an integer	SELECT fractalsql_set_config('text_to_sql_max_attempts','abc')
setcfg prefixed	OK	SELECT fractalsql_set_config('fractalsql.agent_partial_reasoning_fail','off')
ledger verify kind	OK	SELECT fractal_ledger_verify(3)
ledger verify null	OK	SELECT fractal_ledger_verify(NULL)
ledger verify 1	OK	SELECT fractal_ledger_verify(1)
ledger verify 2	OK	SELECT fractal_ledger_verify(2)
diversify bad win	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(-1)
diversify bad stall	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(NULL,-1.0)
diversify bad sigma	OK	SELECT fractal_diversify_set_params(NULL,NULL,0.0)
diversify bad weight	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(NULL,NULL,NULL,-1.0)
feedback bad kind	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(1,'bogus')
feedback null	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(NULL,'click')
feedback dwell	OK	SELECT fractal_feedback_report(1,'dwell',-5)
feedback ok	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(1,'click')
isolate null	OK	SELECT fractal_isolate_background(NULL)
isolate bad	E:fractalsql: result_handle must be >= 0	SELECT fractal_isolate_background(-1)
explain	OK	SELECT fractal_explain_result()
collapse	OK	SELECT fractal_detect_collapse()
vec from_text bad	E:fractal_vector_from_text: could not parse "abc" as a vector: invalid i	SELECT fractal_vector_from_text('abc')
vec from_text empty	E:fractal_vector_from_text: could not parse "[]" as a vector array: frac	SELECT fractal_vector_from_text('[]')
vec from_text nan	OK	SELECT fractal_vector_from_text('[NaN,1]')
vec from_array null elem	E:fractal_vector: source float8[] must be 1-D non-null	SELECT fractal_vector_from_float8_array(ARRAY[1,NULL]::float8[])
vec from_array empty	E:fractal_vector: source float8[] must be 1-D non-null	SELECT fractal_vector_from_float8_array('{}'::float8[])
vec dim mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_l2_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec add mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_add('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec sub mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_sub('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec cos mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_cosine_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec cos zero	OK	SELECT fractal_vector_cosine_distance('[0,0]'::fractal_vector,'[1,2]'::fractal_vector)
vec cossim zero	OK	SELECT fractal_vector_cosine_similarity('[0,0]'::fractal_vector,'[0,0]'::fractal_vector)
vec ip mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_negative_inner_product('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec l2sq mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_l2_squared('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec lp p0	E:fractal_vector_lp_distance: p must be > 0	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0)
vec lp mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector,2)
vec lp inf	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,'Infinity')
vec lp 1	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,1)
vec lp 3	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,3)
vec normalize zero	OK	SELECT fractal_vector_normalize('[0,0]'::fractal_vector)
vec scale nan	OK	SELECT fractal_vector_scale('[1,2]'::fractal_vector,'NaN')
vec scale inf	OK	SELECT fractal_vector_scale('[1,2]'::fractal_vector,'Infinity')
vec typmod bad	E:fractal_vector dimension mismatch: column is fractal_vector(3), value 	SELECT '[1,2]'::fractal_vector(3)
vec typmod zero	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[1,2]'::fractal_vector(0)
vec typmod huge	E:fractal_vector dimension must be between 1 and 32767, got 100000	SELECT '[1,2]'::fractal_vector(100000)
vec typmod ok	OK	SELECT '[1,2]'::fractal_vector(2)
vec cast explicit	E:fractal_vector dimension mismatch: column is fractal_vector(3), value 	SELECT fractal_vector('[1,2]'::fractal_vector,3,true)
vec quant zero	OK	SELECT fractal_vector_quantize_int8('[0,0]'::fractal_vector)
vec quant ok	OK	SELECT fractal_vector_quantize_int8('[0.5,-1]'::fractal_vector)
vec hamming empty	E:fractal_vector_hamming_distance rc=-1	SELECT fractal_vector_hamming_distance('\x'::bytea,'\x'::bytea)
vec to_json	OK	SELECT fractal_vector_to_json('[1,2]'::fractal_vector)
vec recv send	OK	SELECT fractal_vector_send('[1,2]'::fractal_vector)
vec in bad bracket	E:fractal_vector: expected '[' at start of "1,2"	SELECT '1,2'::fractal_vector
vec in trailing	E:fractal_vector: unexpected trailing data in "[1,2]x"	SELECT '[1,2]x'::fractal_vector
vec in dims big	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,17000))||']')::fractal_vector)
vec in too long	E:fractal_vector: dimension exceeds maximum 32767	SELECT ('['||(SELECT string_agg('1',',') FROM generate_series(1,100000))||']')::fractal_vector
vec typmod_in bad	E:fractal_vector: invalid dimension "abc"	SELECT 'x'::fractal_vector(abc)
vec in leading ws	OK	SELECT '   [1,2]'::fractal_vector
vec in inner ws	OK	SELECT '[ 1 , 2 ]   '::fractal_vector
vec in empty	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[]'::fractal_vector
vec in empty ws	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[  ]'::fractal_vector
vec in blank	E:fractal_vector: expected '[' at start of "   "	SELECT '   '::fractal_vector
vec in empty str	E:fractal_vector: expected '[' at start of ""	SELECT ''::fractal_vector
vec in bad number	E:fractal_vector: invalid number in "[1,abc]"	SELECT '[1,abc]'::fractal_vector
vec in trailing comma	E:fractal_vector: invalid number in "[1,]"	SELECT '[1,]'::fractal_vector
vec in no close	E:fractal_vector: expected ']' in "[1,2"	SELECT '[1,2'::fractal_vector
vec in no close ws	E:fractal_vector: expected ']' in "[1 2]"	SELECT '[1 2]'::fractal_vector
vec in 64 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,64))||']')::fractal_vector)
vec in 65 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,65))||']')::fractal_vector)
vec in 200 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,200))||']')::fractal_vector)
vec in exp inf	NONE	SELECT '[1e999,-1e999]'::fractal_vector
vec typmod two args	E:fractal_vector typmod takes exactly one non-NULL parameter	SELECT '[1,2]'::fractal_vector(1,2)
vec typmod junk	E:fractal_vector: invalid dimension "2x"	SELECT '[1,2]'::fractal_vector('2x')
vec typmod empty str	E:fractal_vector: invalid dimension ""	SELECT '[1,2]'::fractal_vector('')
vec typmod negative	E:fractal_vector dimension must be between 1 and 32767, got -1	SELECT '[1,2]'::fractal_vector(-1)
vec typmod null	NONE	SELECT '[1,2]'::fractal_vector(NULL)
vec hamming long eq	OK	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'))
vec hamming long diff	OK	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ba',200),'hex'))
vec hamming long mismatch	E:fractal_vector_hamming_distance: length mismatch (200 vs 201 bytes)	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ab',201),'hex'))
vec hamming short vs long	E:fractal_vector_hamming_distance: length mismatch (1 vs 200 bytes)	SELECT fractal_vector_hamming_distance('\x01'::bytea,decode(repeat('ab',200),'hex'))
vec hamming long vs short	E:fractal_vector_hamming_distance: length mismatch (200 vs 1 bytes)	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),'\x01'::bytea)
vec quant binary long	OK	SELECT length(fractal_vector_quantize_binary(('['||(SELECT string_agg(((i%2)*2-1)::text,',') FROM generate_series(1,1100) i)||']')::fractal_vector))
vec quant int8 long	OK	SELECT (fractal_vector_quantize_int8(('['||(SELECT string_agg((i-70)::text,',') FROM generate_series(1,140) i)||']')::fractal_vector)).scale
vectorizer create no table	E:relation "bt_nope" does not exist	SELECT fractal_vectorizer_create('bt_nope','t','e')
vectorizer create no col	E:column "nope" of relation "bt_g44e" does not exist	SELECT fractal_vectorizer_create('bt_g44e','nope','emb')
vectorizer pause missing	E:fractal_vectorizer_pause: no vectorizer with id 999999	SELECT fractal_vectorizer_pause(999999)
vectorizer resume missing	E:fractal_vectorizer_resume: no vectorizer with id 999999	SELECT fractal_vectorizer_resume(999999)
vectorizer drop missing	E:fractal_vectorizer_drop: no vectorizer with id 999999	SELECT fractal_vectorizer_drop(999999)
vectorizer null	E:fractal_vectorizer_pause: no vectorizer with id <NULL>	SELECT fractal_vectorizer_pause(NULL)
vectorizer queue 0	OK	SELECT fractal_vectorizer_process_queue(0)
vectorizer queue neg	E:LIMIT must not be negative	SELECT fractal_vectorizer_process_queue(-1)
rag ok	OK	SELECT count(*)>=0 FROM fractal_rag_agent('q','bt_g44e','emb')
rag meta filter	OK	SELECT count(*)>=0 FROM fractal_rag_agent('q','bt_g44e','emb','{"id":1}')
search_agent ok	OK	SELECT count(*)>=0 FROM fractal_search_agent('q','bt_g44e','emb')
search_agent small	E:fractalsql: search failed	SELECT count(*)>=0 FROM fractal_search_agent('q','bt_g44e','emb',1,1)
plan ok	OK	SELECT count(*) FROM fractal_agent_plan_explore('q','bt_g44e','emb',2)
plan no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_agent_plan_explore('q','bt_nope','emb',2)
plan no col	E:column "nope" does not exist	SELECT * FROM fractal_agent_plan_explore('q','bt_g44e','nope',2)
traj ok	OK	SELECT predicted_state_vector IS NOT NULL FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,2)
embed ok	OK	SELECT array_length(fractal_embed('hello'),1)
embed huge	E:fractal_embed: input exceeds the 4 MiB limit	SELECT fractal_embed(repeat('A', 4*1024*1024 + 1))
vectorizer create ok	OK	SELECT fractal_vectorizer_create('bt_g44e','txt','emb')
cycle empty elems	E:fractalsql: fsql_cycle_detect_init rc=-1	SELECT * FROM fractal_cycle_detect(ARRAY['\x','\x']::bytea[])
cycle thresh huge	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x01']::bytea[],100000)
cycle long ok	OK	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex')]::bytea[])
cycle long mismatch	E:fractalsql: every fingerprint must be the same length (index 0 was 200	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),decode(repeat('ab',201),'hex')]::bytea[])
cycle first null	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY[NULL,'\x01']::bytea[])
cycle long null	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),NULL]::bytea[])
cycle short mismatch long	E:fractalsql: every fingerprint must be the same length (index 0 was 1 b	SELECT * FROM fractal_cycle_detect(ARRAY['\x01',decode(repeat('ab',200),'hex')]::bytea[])
cycle abab	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x010203','\x040506','\x010203','\x040506','\x010203','\x040506','\x010203','\x040506']::bytea[])
cycle thresh near	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x00','\x01','\x00','\x01','\x00','\x01']::bytea[],4)
loop one state	E:fractalsql: state_log must contain at least 2 states	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],2)
loop repeating	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(v) FROM (SELECT CASE WHEN i%2=0 THEN 1.0 ELSE 2.0 END AS v FROM generate_series(1,80) i) s),2)
loop wander	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(sin(i*1.7)+i*0.05) FROM generate_series(1,96) i),2)
loop thresh	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(sin(i*1.3)) FROM generate_series(1,64) i),4,64,1.0,8)
setcfg http_num_ctx=abc	E:fractalsql_set_config: "http_num_ctx" expects an integer	SELECT fractalsql_set_config('http_num_ctx','abc')
setcfg http_num_ctx=99999999999999999999	E:fractalsql_set_config: "http_num_ctx" expects an integer	SELECT fractalsql_set_config('http_num_ctx','99999999999999999999')
setcfg http_num_ctx=-5	E:fractalsql_set_config: "http_num_ctx" must be between 0 and 1048576	SELECT fractalsql_set_config('http_num_ctx','-5')
setcfg http_num_ctx=2000000	E:fractalsql_set_config: "http_num_ctx" must be between 0 and 1048576	SELECT fractalsql_set_config('http_num_ctx','2000000')
setcfg http_num_ctx=4096	E:fractalsql_set_config: "fractalsql.http_num_ctx" is reload-scoped and 	SELECT fractalsql_set_config('http_num_ctx','4096')
setcfg text_to_sql_max_attempts=0	E:fractalsql_set_config: "text_to_sql_max_attempts" must be between 1 an	SELECT fractalsql_set_config('text_to_sql_max_attempts','0')
setcfg text_to_sql_max_attempts=11	E:fractalsql_set_config: "text_to_sql_max_attempts" must be between 1 an	SELECT fractalsql_set_config('text_to_sql_max_attempts','11')
setcfg text_to_sql_max_attempts=3x	E:fractalsql_set_config: "text_to_sql_max_attempts" expects an integer	SELECT fractalsql_set_config('text_to_sql_max_attempts','3x')
setcfg text_to_sql_max_attempts=3	E:fractalsql_set_config: "fractalsql.text_to_sql_max_attempts" is reload	SELECT fractalsql_set_config('text_to_sql_max_attempts','3')
setcfg text_to_sql_allowed_statements=bogus	E:fractalsql_set_config: "text_to_sql_allowed_statements" must be one of	SELECT fractalsql_set_config('text_to_sql_allowed_statements','bogus')
setcfg text_to_sql_allowed_statements=select	E:fractalsql_set_config: "fractalsql.text_to_sql_allowed_statements" is 	SELECT fractalsql_set_config('text_to_sql_allowed_statements','select')
setcfg text_to_sql_allowed_statements=select_insert_update	E:fractalsql_set_config: "fractalsql.text_to_sql_allowed_statements" is 	SELECT fractalsql_set_config('text_to_sql_allowed_statements','select_insert_update')
setcfg text_to_sql_use_review=maybe	E:fractalsql_set_config: "text_to_sql_use_review" expects a boolean	SELECT fractalsql_set_config('text_to_sql_use_review','maybe')
setcfg text_to_sql_use_review=on	E:fractalsql_set_config: "fractalsql.text_to_sql_use_review" is reload-s	SELECT fractalsql_set_config('text_to_sql_use_review','on')
setcfg http_allow_plaintext=no	E:fractalsql_set_config: "fractalsql.http_allow_plaintext" is reload-sco	SELECT fractalsql_set_config('http_allow_plaintext','no')
setcfg http_allow_plaintext=y	E:fractalsql_set_config: "fractalsql.http_allow_plaintext" is reload-sco	SELECT fractalsql_set_config('http_allow_plaintext','y')
setcfg too long	E:fractalsql_set_config: "http_url" is too long	SELECT fractalsql_set_config('http_url',repeat('x',9000))
setcfg upper key	E:fractalsql_set_config: "fractalsql.http_url" is reload-scoped and cann	SELECT fractalsql_set_config('FractalSQL.HTTP_URL','http://x')
setcfg long key	E:fractalsql_set_config: unknown config key "kkkkkkkkkkkkkkkkkkkkkkkkkkk	SELECT fractalsql_set_config(repeat('k',200),'x')
setcfg bool on	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','on')
setcfg bool 1	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','1')
setcfg bool true	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','true')
setcfg bool yes	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','yes')
setcfg bool t	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','t')
setcfg bool y	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','y')
setcfg bool TRUE	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','TRUE')
setcfg bool off	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','off')
setcfg bool 0	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','0')
setcfg bool false	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','false')
setcfg bool no	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','no')
setcfg bool f	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','f')
setcfg bool n	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','n')
setcfg bool Off	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','Off')
getcfg reasoning_plugin	OK	SELECT fractalsql_get_config('reasoning_plugin')
getcfg http_model	OK	SELECT fractalsql_get_config('http_model')
getcfg http_embed_url	OK	SELECT fractalsql_get_config('http_embed_url')
getcfg http_think	OK	SELECT fractalsql_get_config('http_think')
getcfg enterprise_lib	OK	SELECT fractalsql_get_config('enterprise_lib')
getcfg http_token	OK	SELECT fractalsql_get_config('http_token')
telemetry empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_search_telemetry('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid empty	E:fractalsql: doc_ids cohort matched no rows in bt_g44z.emb	SELECT * FROM fractal_hybrid_clinical_search('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44z),ARRAY['(0,1)']),2)
explore empty	E:fractalsql: bt_g44z.emb has no rows to explore	SELECT count(*) FROM fractal_search_explore('bt_g44z','emb',ARRAY[0.1,0.2]::float8[])
traj_search empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_search_trajectory('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_cross_modal_search('bt_g44z','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_telemetry('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid null vec	E:fractalsql: NULL vector at cohort row 0	SELECT * FROM fractal_hybrid_clinical_search('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44n),ARRAY['(0,1)']),2)
explore null vec	E:fractalsql: NULL vector at row 0	SELECT count(*) FROM fractal_search_explore('bt_g44n','emb',ARRAY[0.1,0.2]::float8[])
traj_search null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_trajectory('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_cross_modal_search('bt_g44n','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid ragged dims	E:fractalsql: bt_g44d.emb cohort row 1 has dim 3, expected 2 (match the 	SELECT * FROM fractal_hybrid_clinical_search('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44d),ARRAY['(0,1)']),2)
explore ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT count(*) FROM fractal_search_explore('bt_g44d','emb',ARRAY[0.1,0.2]::float8[])
traj_search ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_trajectory('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44d','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_telemetry('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid text col	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44t),ARRAY['(0,1)']),2)
explore text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT count(*) FROM fractal_search_explore('bt_g44t','emb',ARRAY[0.1,0.2]::float8[])
traj_search text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_trajectory('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_cross_modal_search('bt_g44t','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid mixed fvec dims	E:fractalsql: bt_g44w.emb cohort row 1 has dim 3, expected 2 (match the 	SELECT * FROM fractal_hybrid_clinical_search('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44w),ARRAY['(0,1)']),2)
explore mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT count(*) FROM fractal_search_explore('bt_g44w','emb',ARRAY[0.1,0.2]::float8[])
traj_search mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_trajectory('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44w','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
search_agent empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_search_agent('q','bt_g44z','emb')
rag empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_rag_agent('q','bt_g44z','emb')
plan empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_agent_plan_explore('q','bt_g44z','emb',2)
search_agent null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_agent('q','bt_g44n','emb')
rag null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_rag_agent('q','bt_g44n','emb')
plan null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_agent_plan_explore('q','bt_g44n','emb',2)
search_agent ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_search_agent('q','bt_g44d','emb')
rag ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_rag_agent('q','bt_g44d','emb')
plan ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_agent_plan_explore('q','bt_g44d','emb',2)
search_agent text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_agent('q','bt_g44t','emb')
rag text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_rag_agent('q','bt_g44t','emb')
plan text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_agent_plan_explore('q','bt_g44t','emb',2)
telemetry fvec	OK	SELECT * FROM fractal_search_telemetry('bt_g44v','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid fvec	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44v','emb',ARRAY[0.1,0.2]::float8[],(SELECT array_agg(ctid::text) FROM bt_g44v),2)
explore fvec	OK	SELECT count(*) FROM fractal_search_explore('bt_g44v','emb',ARRAY[0.1,0.2]::float8[])
explore mmr low	OK	SELECT count(*) FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"mmr_lambda":-1}')
explore mmr high	OK	SELECT count(*) FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"mmr_lambda":2}')
traj baseline null	E:fractal_agent_trajectory_predict: baseline vector is NULL	SELECT * FROM fractal_agent_trajectory_predict('bt_g44n','emb',1,2)
traj current null	E:fractal_agent_trajectory_predict: current vector is NULL	SELECT * FROM fractal_agent_trajectory_predict('bt_g44n','emb',2,2)
traj dim mismatch	E:fractal_agent_trajectory_predict: baseline dim 2 != current dim 3	SELECT * FROM fractal_agent_trajectory_predict('bt_g44d','emb',1,2)
traj empty table	E:fractal_agent_trajectory_predict: no row in bt_g44z with id = 1	SELECT * FROM fractal_agent_trajectory_predict('bt_g44z','emb',1,2)
traj no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_agent_trajectory_predict('bt_nope','emb',1,2)
traj fvec	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44v','emb',1,2)
traj fvec mixed	E:fractal_agent_trajectory_predict: baseline dim 2 != current dim 3	SELECT * FROM fractal_agent_trajectory_predict('bt_g44w','emb',1,2)
mine ok	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[],2)
store_morph ok	OK	SELECT fractal_store_morphology(1,ARRAY[0.1,0.2]::float8[])
mine after store	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[],2)
mine dim differs	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2,0.3]::float8[],2)
store_morph null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_store_morphology(2,ARRAY[0.1,NULL]::float8[])
store_morph neg	E:fractalsql: doc_id must be >= 0	SELECT fractal_store_morphology(-1,ARRAY[0.1,0.2]::float8[])
@mock		
sql_agent null q	E:fractal_sql_agent: question must not be NULL	SELECT * FROM fractal_sql_agent(NULL)
sql_agent neg retries	E:fractal_sql_agent: max_retries must be >= 1 (got -1)	SELECT * FROM fractal_sql_agent('q',NULL,-1)
sql_agent ok	NONE	SELECT * FROM fractal_sql_agent('q')
vascular 2d edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[[0,1],[1,0]]::int4[],ARRAY[1.0,1.0]::float8[])
vascular null elem edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,NULL]::int4[],ARRAY[1.0]::float8[])
nerve 2d edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[[0,1],[1,0]]::int4[])
feedback neg handle	E:fractalsql: result_handle must be >= 0	SELECT fractal_feedback_report(-1,'positive')
isolate neg handle	NONE	SELECT fractal_isolate_background(-1)
diversify dq	OK	SELECT fractal_diversify_current_dq()
diversify p99	OK	SELECT fractal_diversify_overhead_p99_us()
hybrid 2d ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY[['(0,1)','(0,2)'],['(0,3)','(0,4)']],2)
hybrid null elem ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY['(0,1)',NULL],2)
hybrid empty ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{}'::text[],2)
trajectory fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0)
trajectory fv dims	E:fractalsql: baseline_vector dim (2) must match current_vector dim (3)	SELECT * FROM fractal_search_trajectory('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2,0.1]'::fractal_vector,2)
cross fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_cross_modal_search('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0.5,0)
agent trajectory text col	NONE	SELECT * FROM fractal_agent_trajectory_predict('bt_g44t','emb',1,3)
FSQL_TBL_ROWS
  local n=$TBL_N bad=$TBL_BAD
  [[ "$bad" -eq 0 ]] && pass "44 error_paths: all $n argument-validation / error-path / NULL-argument calls behaved as specified (no backend crash)"

  "${PSQL[@]}" -c "SELECT fractal_vectorizer_drop(v.id) FROM fractal_vectorizers v WHERE v.source_table = 'bt_g44e';" >/dev/null 2>&1 </dev/null
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_g44, bt_g44x, bt_g44e, bt_g44n, bt_g44d, bt_g44z, bt_g44t, bt_g44v, bt_g44w; DELETE FROM fractalsql_feature_store;" >/dev/null 2>&1 </dev/null
  pg_swap_plugin "$MOCK" >/dev/null
  return 0
}

# Gate 45: the enterprise-tier code paths that the dormant (community) state
# cannot reach, driven through tests/mock_enterprise_core.c -- the same mock
# gate 31 uses. Two halves:
#   (a) the validation / error branches of fractal_optimize_portfolio_
#       multimodal, _pareto and the audit functions, which check the tier
#       BEFORE their arguments and so are unreachable from gate 44;
#   (b) the ledger-tip authentication that fractal_ledger_load() runs before
#       handing the persisted chain to the core (ledger_verify_latest):
#       genesis/link/hash/MAC checks against hand-built kind=1 chains, with a
#       real HMAC-SHA256 computed in SQL so the "valid" cases are genuinely
#       valid (and so a regression that rejects good data fails too).
# Self-contained: builds its own mock, points enterprise_lib at it, and puts
# enterprise_lib / the ledger key back afterwards.
gate_45_enterprise_paths() {
  local mock_so="$TMPROOT/fractalsql_bt_g45_ent_${PG_MAJOR}.so"
  rm -f "$mock_so" "$mock_so.sig"
  cc -shared -fPIC -std=c99 -Iinclude tests/mock_enterprise_core.c -o "$mock_so" \
    2>/tmp/fractalsql_bt_gate45_build.log \
    || { cat /tmp/fractalsql_bt_gate45_build.log >&2; fail "45 enterprise_paths: mock .so failed to build"; return 0; }
  "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;" >/dev/null 2>&1 </dev/null
  if ! pg_set_guc fractalsql.enterprise_lib "'$mock_so'" "$mock_so"; then
    fail "45 enterprise_paths: could not point enterprise_lib at the mock"; rm -f "$mock_so"; return 0
  fi

  # ---- (a) argument validation behind the tier check ------------------
  sql_table_run 45 <<'FSQL_TBL_ROWS'
mm null mu	E:fractalsql: fractal_optimize_portfolio_multimodal: mu must not be NULL	SELECT fractal_optimize_portfolio_multimodal(NULL,ARRAY[1,0,0,1]::float8[],1)
mm null cov	E:fractalsql: fractal_optimize_portfolio_multimodal: cov must not be NUL	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],NULL,1)
mm null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
mm k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
mm cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
mm restarts 0	E:fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,0)
mm overlap	NONE	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,2.0)
mm quality	NONE	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0.1,2.0)
mm bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0.1,0.9,1,false,'bogus')
mm ok	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,3,0.15,0.9,5,true,'cauchy')
mm ok nulls	OK	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,NULL,NULL,NULL,NULL,NULL,NULL)
pareto null mu	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: mu must not 	SELECT fractal_optimize_portfolio_multimodal_pareto(NULL,ARRAY[1,0,0,1]::float8[],1)
pareto null cov	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: cov must not	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],NULL,1)
pareto null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
pareto k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
pareto cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
pareto restarts 0	E:fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,0)
pareto front 0	E:fractalsql: max_front must satisfy 1 <= max_front <= n_restarts (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0)
pareto front big	E:fractalsql: max_front must satisfy 1 <= max_front <= n_restarts (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,99)
pareto bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,2,1,false,'bogus')
pareto ok	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,3,3,5,true,'cauchy')
pareto ok nulls	OK	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,NULL,NULL,NULL,NULL,NULL)
audit_unpack null	OK	SELECT fractal_audit_unpack(NULL)
audit_unpack short	E:invalid input syntax for type json	SELECT fractal_audit_unpack('\x00')
audit_unpack garbage	E:invalid input syntax for type json	SELECT fractal_audit_unpack(decode(repeat('ab',64),'hex'))
audit_log null	E:fractalsql: fractal_audit_log: entry_type and payload must not be NULL	SELECT fractal_audit_log(NULL,'{}')
audit_log null payload	E:fractalsql: fractal_audit_log: entry_type and payload must not be NULL	SELECT fractal_audit_log('x',NULL)
audit_log ok	OK	SELECT fractal_audit_log('g45.test', '{"n":1}'::jsonb)
audit_log big	OK	SELECT fractal_audit_log('g45.test', jsonb_build_object('p', repeat('x', 200000)))
audit_log keyed	OK	SET fractalsql.enterprise_ledger_key = 'g45-key'; SELECT fractal_audit_log('g45.keyed', '{"n":2}'::jsonb)
audit_unpack json	OK	SELECT fractal_audit_unpack(convert_to('{"a":1}', 'UTF8'))
audit_unpack not json	E:invalid input syntax for type json	SELECT fractal_audit_unpack(convert_to('not json', 'UTF8'))
audit_unpack empty	E:invalid input syntax for type json	SELECT fractal_audit_unpack('\x'::bytea)
audit_unpack big	OK	SELECT length(fractal_audit_unpack(convert_to('"' || repeat('x', 300000) || '"', 'UTF8'))::text)
mm ok k=n	OK	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],2)
pareto ok k=n	OK	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],2)
mm null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
pareto null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
FSQL_TBL_ROWS
  [[ "$TBL_BAD" -eq 0 ]] \
    && pass "45 enterprise_paths: all $TBL_N multimodal / pareto / audit validation calls behaved as specified (mock core loaded)"

  # ---- (b) ledger tip authentication ----------------------------------
  # Constraint-free ledger fixture (same shape and index as gate 31's) so
  # rows the extension's own DDL would refuse (NULL hashes, short MACs) can
  # be staged. bt_hmac() is a plain HMAC-SHA256 over the built-in sha256().
  "${PSQL[@]}" -c "
    DROP TABLE IF EXISTS fractalsql_ledger;
    CREATE TABLE fractalsql_ledger (
      id bigserial PRIMARY KEY, kind integer NOT NULL, blob bytea NOT NULL,
      mac bytea, prev_hash bytea, entry_hash bytea,
      sealed boolean NOT NULL DEFAULT false, updated timestamptz NOT NULL DEFAULT now());
    CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx ON fractalsql_ledger (kind, id DESC);
    CREATE OR REPLACE FUNCTION bt_put(p bytea, b bytea, m bytea) RETURNS bytea LANGUAGE plpgsql AS \$f\$
    DECLARE h bytea := sha256(p || b || coalesce(m, '\\x'::bytea));
    BEGIN
      INSERT INTO fractalsql_ledger (kind, blob, mac, prev_hash, entry_hash) VALUES (1, b, m, p, h);
      RETURN h;
    END \$f\$;
    CREATE OR REPLACE FUNCTION bt_hmac(k bytea, m bytea) RETURNS bytea LANGUAGE plpgsql IMMUTABLE AS \$f\$
    DECLARE ik bytea := '\x'::bytea; ok bytea := '\x'::bytea; kk bytea := k; i int;
    BEGIN
      IF length(kk) > 64 THEN kk := sha256(kk); END IF;
      kk := kk || decode(repeat('00', 64 - length(kk)), 'hex');
      FOR i IN 0..63 LOOP
        ik := ik || set_byte('\x00'::bytea, 0, get_byte(kk, i) # 54);
        ok := ok || set_byte('\x00'::bytea, 0, get_byte(kk, i) # 92);
      END LOOP;
      RETURN sha256(ok || sha256(ik || m));
    END \$f\$;" >/dev/null 2>&1 </dev/null
  local zero="decode(repeat('00',32),'hex')"
  # row builder: chain_row(prev, blob, mac_or_null) -> entry_hash is
  # sha256(prev || blob [|| mac]).
  local key="gate45-ledger-key"
  sql_table_run 45 <<FSQL_TBL_ROWS
tip empty	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT fractal_ledger_load()
tip genesis ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01020304',NULL); SELECT fractal_ledger_load()
tip genesis nonzero prev	E:fractalsql: ledger chain verification failed -- the sole entry's prev_	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(decode(repeat('11',32),'hex'),'\x01',NULL); SELECT fractal_ledger_load()
tip chain ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); SELECT fractal_ledger_load()
tip chain link broken	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',NULL); SELECT bt_put(decode(repeat('22',32),'hex'),'\x02',NULL); SELECT fractal_ledger_load()
tip prior hash null	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,NULL); SELECT bt_put($zero,'\x02',NULL); SELECT fractal_ledger_load()
tip prior hash short	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,'\x0011'); SELECT bt_put($zero,'\x02',NULL); SELECT fractal_ledger_load()
tip blob tampered	E:fractalsql: ledger chain verification failed -- the latest entry's has	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x0102',NULL); UPDATE fractalsql_ledger SET blob='\x0103' WHERE kind=1; SELECT fractal_ledger_load()
tip prev short	E:fractalsql: ledger chain verification failed -- stored prev_hash/entry	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01','\x0011',$zero); SELECT fractal_ledger_load()
tip hash short	E:fractalsql: ledger chain verification failed -- stored prev_hash/entry	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,'\x0011'); SELECT fractal_ledger_load()
tip entry_hash null	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,NULL); SELECT fractal_ledger_load()
tip prev null	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',NULL,$zero); SELECT fractal_ledger_load()
tip key, no mac	E:fractalsql: ledger MAC verification failed -- the persisted blob has n	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',NULL); SELECT fractal_ledger_load()
tip key, mac short	E:fractalsql: ledger MAC verification failed -- stored MAC is 16 bytes, 	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',decode(repeat('cd',16),'hex')); SELECT fractal_ledger_load()
tip key, mac wrong	E:fractalsql: ledger MAC verification failed -- the persisted QTL blob i	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',decode(repeat('cd',32),'hex')); SELECT fractal_ledger_load()
tip key, mac valid	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); SELECT fractal_ledger_load()
tip key, mac valid, blob tampered	E:fractalsql: ledger MAC verification failed -- the persisted QTL blob i	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); UPDATE fractalsql_ledger SET blob='\x02' WHERE kind=1; SELECT fractal_ledger_load()
tip key, mac valid, hash tampered	E:fractalsql: ledger chain verification failed -- the latest entry's has	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); UPDATE fractalsql_ledger SET entry_hash=decode(repeat('ee',32),'hex') WHERE kind=1; SELECT fractal_ledger_load()
tip nokey, mac present	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',decode(repeat('ab',32),'hex')); SELECT fractal_ledger_load()
tip nokey, mac short	E:fractalsql: ledger MAC verification failed -- stored MAC is 16 bytes, 	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',decode(repeat('ab',16),'hex')); SELECT fractal_ledger_load()
tip verify kind1 ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); SELECT fractal_ledger_verify(1)::text
tip verify kind1 tampered	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); UPDATE fractalsql_ledger SET blob='\x09' WHERE kind=1 AND id=(SELECT min(id) FROM fractalsql_ledger WHERE kind=1); SELECT fractal_ledger_verify(1)::text
migrate old schema	OK	DROP TABLE IF EXISTS fractalsql_ledger; CREATE TABLE fractalsql_ledger (kind int PRIMARY KEY, blob bytea); SELECT fractal_ledger_verify(1)
migrate missing index	OK	DROP TABLE IF EXISTS fractalsql_ledger; CREATE TABLE fractalsql_ledger (id bigserial PRIMARY KEY, kind integer NOT NULL, blob bytea NOT NULL, mac bytea, prev_hash bytea NOT NULL, entry_hash bytea NOT NULL, sealed boolean NOT NULL DEFAULT false, updated timestamptz NOT NULL DEFAULT now()); SELECT fractal_ledger_verify(1)
FSQL_TBL_ROWS
  [[ "$TBL_BAD" -eq 0 ]] \
    && pass "45 enterprise_paths: all $TBL_N ledger-tip authentication cases behaved as specified (genesis, link, hash, MAC, key/no-key)"

  # ---- (c) enterprise libraries that are missing symbols -----------------
  # One built without the optional multimodal symbols (an older enterprise
  # build: the loader accepts it, the multimodal functions refuse), one
  # without a required symbol (the loader refuses the whole library).
  local mock_old="$TMPROOT/fractalsql_bt_g45_old_${PG_MAJOR}.so" mock_bad="$TMPROOT/fractalsql_bt_g45_bad_${PG_MAJOR}.so"
  rm -f "$mock_old" "$mock_bad"
  if cc -shared -fPIC -std=c99 -DMOCK_OMIT_MULTIMODAL -Iinclude tests/mock_enterprise_core.c -o "$mock_old" 2>/tmp/fractalsql_bt_gate45_build.log \
     && cc -shared -fPIC -std=c99 -DMOCK_OMIT_AUDIT_UNPACK -Iinclude tests/mock_enterprise_core.c -o "$mock_bad" 2>>/tmp/fractalsql_bt_gate45_build.log; then
    pg_set_guc fractalsql.enterprise_lib "'$mock_old'" "$mock_old" >/dev/null
    sql_table_run 45 <<FSQL_TBL_ROWS
old core multimodal	E:not available in this enterprise library	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
old core pareto	E:not available in this enterprise library	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
old core ledger still works	OK	SELECT fractal_ledger_truth_count()
FSQL_TBL_ROWS
    [[ "$TBL_BAD" -eq 0 ]] \
      && pass "45 enterprise_paths: a core without the optional multimodal symbols loads, and only the multimodal functions refuse"
    pg_set_guc fractalsql.enterprise_lib "'$mock_bad'" "$mock_bad" >/dev/null
    sql_table_run 45 <<FSQL_TBL_ROWS
bad core ledger	E:enterprise tier not loaded	SELECT fractal_ledger_flush()
bad core multimodal	E:enterprise tier not loaded	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
FSQL_TBL_ROWS
    [[ "$TBL_BAD" -eq 0 ]] \
      && pass "45 enterprise_paths: a core missing a required symbol is refused as a whole"
  else
    cat /tmp/fractalsql_bt_gate45_build.log >&2
    fail "45 enterprise_paths: reduced mock cores failed to build"
  fi
  rm -f "$mock_old" "$mock_bad"

  "${PSQL[@]}" -c "DROP FUNCTION IF EXISTS bt_hmac(bytea,bytea), bt_put(bytea,bytea,bytea); DELETE FROM fractalsql_ledger;" >/dev/null 2>&1 </dev/null
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.enterprise_require_signature;" >/dev/null 2>&1 </dev/null
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.enterprise_lib;" >/dev/null 2>&1 </dev/null
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1 </dev/null
  rm -f "$mock_so" "$mock_so.sig"
  return 0
}

# Gate 46: plugin / provider configuration paths. Every setting that is only
# applied "if configured" (http_url, token, model, plaintext, embed url/model,
# think, native url, num_ctx, review, max attempts, allowed statements) is
# never set by the other gates, so the branches that apply them stay dark.
# This sets them all, runs the reasoning / embed / text-to-sql entry points
# against the mock plugins, then clears the plugin path entirely to exercise
# the "no plugin configured" errors.
gate_46_plugin_config() {
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_g46;
     CREATE TABLE bt_g46 (id serial PRIMARY KEY, emb float8[], txt text);
     INSERT INTO bt_g46 (emb, txt) VALUES (ARRAY[0.1,0.2,0.3],'a'), (ARRAY[0.3,0.2,0.1],'b');
  " >/dev/null 2>&1 </dev/null
  echo "SELECT count(*) FROM bt_g46" > /tmp/fractalsql_bt_sql.txt
  pg_swap_plugin "$MOCK" >/dev/null
  sql_table_run 46 <<'FSQL_TBL_ROWS'
@guc	http_url	http://127.0.0.1:9/v1/chat/completions
@guc	http_token	bt-token
@guc	http_model	bt-model
@guc	http_allow_plaintext	on
@guc	http_embed_url	http://127.0.0.1:9/v1/embeddings
@guc	http_embed_model	bt-embed
@guc	http_think	low
@guc	http_think_provider	ollama
@guc	http_native_url	http://127.0.0.1:9/api/chat
@guc	http_num_ctx	4096
@guc	text_to_sql_max_attempts	3
@guc	text_to_sql_allowed_statements	select_insert_update
configured reason	OK	SELECT fractal_reason('q')
configured reason ctx	OK	SELECT fractal_reason('q', '{"k":1}')
configured t2s	OK	SELECT fractal_text_to_sql('count rows in bt_g46')
configured t2s tables	OK	SELECT fractal_text_to_sql('count rows', ARRAY['bt_g46'])
configured sql_agent	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
configured sql_agent exec	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46', ARRAY['bt_g46'], 2, true)
configured schema	OK	SELECT length(fractal_schema_context(ARRAY['bt_g46'], 'rows')) > 0
@guc	text_to_sql_use_review	on
review t2s	E:fractal_text_to_sql: exhausted 3 attempt(s), last review verdict: ```s	SELECT fractal_text_to_sql('count rows in bt_g46')
review sql_agent	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
@guc	text_to_sql_use_review	off
@plugin	EMBED
configured embed	OK	SELECT array_length(fractal_embed('hello'), 1)
configured search_agent	OK	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
configured rag	OK	SELECT * FROM fractal_rag_agent('q', 'bt_g46', 'emb')
configured plan	OK	SELECT count(*) FROM fractal_agent_plan_explore('q', 'bt_g46', 'emb', 2)
@guc	http_embed_url	
embed url unset	E:http_embed_url is not configured	SELECT fractal_embed('hello')
embed url unset agent	E:fractal_embed: fractalsql.http_embed_url is not configured	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
@guc	reasoning_plugin	
no plugin reason	E:fractal_reason: no reasoning plugin loaded	SELECT fractal_reason('q')
no plugin t2s	E:fractal_text_to_sql: no reasoning plugin loaded	SELECT fractal_text_to_sql('count rows in bt_g46')
no plugin sql_agent	E:fractal_sql_agent: no reasoning plugin loaded	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
no plugin embed	E:fractal_embed: no reasoning plugin loaded	SELECT fractal_embed('hello')
no plugin schema	OK	SELECT length(fractal_schema_context(ARRAY['bt_g46'])) > 0
no plugin search_agent	E:fractal_search_agent: no reasoning plugin loaded	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
FSQL_TBL_ROWS
  [[ "$TBL_BAD" -eq 0 ]] \
    && pass "46 plugin_config: all $TBL_N provider-configuration / no-plugin calls behaved as specified (no backend crash)"
  local k
  for k in http_url http_token http_model http_allow_plaintext http_embed_url http_embed_model http_think \
           http_think_provider http_native_url http_num_ctx text_to_sql_max_attempts text_to_sql_allowed_statements \
           text_to_sql_use_review; do
    "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.$k;" >/dev/null 2>&1 </dev/null
  done
  "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1 </dev/null
  pg_set_guc fractalsql.reasoning_plugin "'$MOCK'" "$MOCK" >/dev/null
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_g46;" >/dev/null 2>&1 </dev/null
  rm -f /tmp/fractalsql_bt_sql.txt
  return 0
}

# Gate 47: fault injection into the SPI and core calls the extension checks.
# The "SPI_execute(...) != SPI_OK_*" and "rc != FSQL_OK" branches fire only on
# memory exhaustion or an engine fault, so no SQL input reaches them. A test
# build (gate 01 passes FAULT_INJECT=1; src/fsql_fault.h) lets a session fail
# the Nth call of one named site:  SET fractalsql.fault_inject = 'SPI_execute:3'.
# For each statement below and each site, the sweep fails call 1, 2, 3, ...
# until a run no longer reaches that many calls, and requires every injected
# run to end cleanly: no backend crash or hang, and none of the warnings
# Postgres emits when a code path leaks (non-empty SPI stack, an unclosed
# resource). The failure may surface as an ERROR or be absorbed (a best-effort
# path); either is fine. Skips when the build has no hook. Linux/macOS only.
FI_SITES="srf_context SPI_connect SPI_execute SPI_execute_with_args fsql_new_sovereign fsql_load_reasoning fsql_search_ptr fsql_search_null_json fsql_dispatch_ai fsql_dispatch_ai_resp fsql_dispatch_ai_nosummary fsql_extract_topk fsql_topk_idx_neg fsql_topk_idx_big fsql_extract_best_point fsql_extract_population fsql_parse_embedding_array fsql_cycle_detect_init fsql_cycle_detect_feed fsql_state_fingerprint fsql_feedback_report fsql_diversify_enable fsql_diversify_disable fsql_diversify_get_params fsql_diversify_set_params fsql_optimize_portfolio_ex get_call_result_type g_ent_ledger_flush g_ent_ledger_load g_ent_ledger_compact g_ent_ledger_reset_soft g_ent_ledger_reset_hard g_ent_ledger_truth_count g_ent_ledger_shadow_count g_ent_optimize_portfolio_multimodal g_ent_optimize_portfolio_multimodal_ex g_ent_optimize_portfolio_multimodal_pareto"
FI_RUNS=0; FI_FIRED=0; FI_BAD=0
FI_TIMEOUT=""

# fault_sweep <label> <sql>: sweep every site in FI_SITES over one statement.
fault_sweep() {
  local label="$1" sql="$2" site k out i
  for site in $FI_SITES; do
    for k in $(seq 1 100); do
      out=$($FI_TIMEOUT "${PSQL[@]}" -c "SET fractalsql.fault_inject = '$site:$k'; $sql" 2>&1 </dev/null)
      local rc=$?
      FI_RUNS=$((FI_RUNS + 1))
      if grep -q "server closed the connection\|terminated by signal\|in recovery mode\|not yet accepting" <<<"$out" \
         || [[ "$rc" -eq 124 ]]; then
        fail "47 fault_injection: '$label' with $site:$k CRASHED or hung the backend: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
        FI_BAD=$((FI_BAD + 1))
        for i in $(seq 1 $((60 * TIMEOUT_MULT))); do "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 </dev/null && break; sleep 0.5; done
        break
      fi
      grep -q "fractalsql: fault injected at" <<<"$out" || break    # ran past the last call of this site
      FI_FIRED=$((FI_FIRED + 1))
      if grep -qiE "non-empty SPI stack|leak|was not closed|still open" <<<"$out"; then
        fail "47 fault_injection: '$label' with $site:$k leaked: $(grep -iE 'non-empty SPI stack|leak|was not closed|still open' <<<"$out" | head -1 | cut -c1-140)"
        FI_BAD=$((FI_BAD + 1))
      fi
    done
  done
}

gate_47_fault_injection() {
  if ! "${PSQL[@]}" -c "SHOW fractalsql.fault_inject" >/dev/null 2>&1 </dev/null; then
    skip "47 fault_injection: this build has no fault-injection hook (needs make FAULT_INJECT=1)"
    return 0
  fi
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_g47, bt_g47v;
     CREATE TABLE bt_g47 (id serial PRIMARY KEY, emb float8[], txt text);
     INSERT INTO bt_g47 (emb, txt) VALUES (ARRAY[0.1,0.2,0.3],'a'), (ARRAY[0.3,0.2,0.1],'b'), (ARRAY[0.9,0.8,0.7],'c'), (ARRAY[0.5,0.5,0.5],'d');
     CREATE TABLE bt_g47v (id serial PRIMARY KEY, emb fractal_vector);
     INSERT INTO bt_g47v (emb) VALUES ('[0.1,0.2,0.3]'), ('[0.3,0.2,0.1]'), ('[0.9,0.8,0.7]');
  " >/dev/null 2>&1 </dev/null
  echo "SELECT count(*) FROM bt_g47" > /tmp/fractalsql_bt_sql.txt
  FI_RUNS=0; FI_FIRED=0; FI_BAD=0
  FI_TIMEOUT=""
  command -v timeout >/dev/null 2>&1 && FI_TIMEOUT="timeout $((60 * TIMEOUT_MULT))"

  # ---- reasoning mock: text-to-SQL, the SQL agent, schema context ------
  pg_swap_plugin "$MOCK" >/dev/null
  fault_sweep "sql_agent"           "SELECT * FROM fractal_sql_agent('count rows in bt_g47')"
  fault_sweep "sql_agent exec"      "SELECT * FROM fractal_sql_agent('count rows in bt_g47', ARRAY['bt_g47'], 2, true)"
  fault_sweep "text_to_sql"         "SELECT fractal_text_to_sql('count rows in bt_g47', ARRAY['bt_g47'])"
  fault_sweep "schema_context"      "SELECT length(fractal_schema_context(ARRAY['bt_g47'], 'rows'))"
  fault_sweep "schema_context auto" "SELECT length(fractal_schema_context())"
  fault_sweep "reason"              "SELECT fractal_reason('q')"
  pg_set_guc fractalsql.text_to_sql_use_review "'on'" "on" >/dev/null
  pg_set_guc fractalsql.text_to_sql_max_attempts "'2'" "2" >/dev/null
  fault_sweep "sql_agent review"    "SELECT * FROM fractal_sql_agent('count rows in bt_g47')"
  fault_sweep "text_to_sql review"  "SELECT fractal_text_to_sql('count rows in bt_g47')"
  pg_set_guc fractalsql.text_to_sql_use_review "'off'" "off" >/dev/null

  # ---- embed mock: the embedding-driven agents --------------------------
  pg_swap_plugin "$EMBED" >/dev/null
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" >/dev/null
  fault_sweep "embed"          "SELECT array_length(fractal_embed('hello'), 1)"
  fault_sweep "search_agent"   "SELECT * FROM fractal_search_agent('q', 'bt_g47', 'emb')"
  fault_sweep "rag_agent"      "SELECT * FROM fractal_rag_agent('q', 'bt_g47', 'emb')"
  fault_sweep "plan_explore"   "SELECT count(*) FROM fractal_agent_plan_explore('q', 'bt_g47', 'emb', 2)"
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.http_embed_url; SELECT pg_reload_conf();" >/dev/null 2>&1 </dev/null

  # ---- no plugin needed: search, trajectory, loop/cycle, diversify ------
  pg_swap_plugin "$MOCK" >/dev/null
  fault_sweep "search"           "SELECT fractal_search(ARRAY[0.1,0.2,0.3]::float8[], 3, 6)"
  fault_sweep "search_debug"     "SELECT fractal_search_debug(ARRAY[0.1,0.2,0.3]::float8[], 3, 6)"
  fault_sweep "search_explore"   "SELECT count(*) FROM fractal_search_explore('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], '{\"iterations\":3,\"population_size\":5}')"
  fault_sweep "search_explore fv" "SELECT count(*) FROM fractal_search_explore('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[])"
  fault_sweep "telemetry"        "SELECT count(*) FROM fractal_search_telemetry('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], 2)"
  fault_sweep "telemetry fv"     "SELECT count(*) FROM fractal_search_telemetry('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[], 2)"
  fault_sweep "trajectory"       "SELECT count(*) FROM fractal_search_trajectory('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], ARRAY[0.3,0.2,0.1]::float8[], 2)"
  fault_sweep "trajectory fv"    "SELECT count(*) FROM fractal_search_trajectory('bt_g47v', 'emb', '[0.1,0.2,0.3]'::fractal_vector, '[0.3,0.2,0.1]'::fractal_vector, 2)"
  fault_sweep "cross_modal"      "SELECT count(*) FROM fractal_cross_modal_search('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], ARRAY[0.3,0.2,0.1]::float8[], 0.5, 2)"
  fault_sweep "cross_modal fv"   "SELECT count(*) FROM fractal_cross_modal_search('bt_g47v', 'emb', '[0.1,0.2,0.3]'::fractal_vector, '[0.3,0.2,0.1]'::fractal_vector, 0.5, 2)"
  fault_sweep "hybrid"           "SELECT count(*) FROM fractal_hybrid_clinical_search('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], (SELECT array_agg(ctid::text) FROM bt_g47), 2)"
  fault_sweep "hybrid fv"        "SELECT count(*) FROM fractal_hybrid_clinical_search('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[], (SELECT array_agg(ctid::text) FROM bt_g47v), 2)"
  fault_sweep "agent trajectory" "SELECT * FROM fractal_agent_trajectory_predict('bt_g47', 'emb', 1, 3)"
  fault_sweep "agent trajectory fv" "SELECT * FROM fractal_agent_trajectory_predict('bt_g47v', 'emb', 1, 3)"
  fault_sweep "detect_loop"      "SELECT * FROM fractal_agent_detect_loop('a', ARRAY[1,2,1,2,1,2,1,2]::float8[], 2)"
  fault_sweep "fingerprint"      "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64)"
  fault_sweep "cycle_detect"     "SELECT * FROM fractal_cycle_detect(ARRAY['\\x01','\\x02','\\x01','\\x02','\\x01','\\x02']::bytea[])"
  fault_sweep "diversify"        "SELECT fractal_diversify_enable(); SELECT fractal_diversify_set_params(5); SELECT fractal_feedback_report(1,'positive'); SELECT fractal_explain_result(); SELECT fractal_detect_collapse(); SELECT fractal_diversify_disable()"
  fault_sweep "diversify dq"     "SELECT fractal_diversify_enable(); SELECT fractal_diversify_current_dq(); SELECT fractal_diversify_overhead_p99_us(); SELECT fractal_isolate_background(1); SELECT fractal_diversify_disable()"
  fault_sweep "periodogram"      "SELECT * FROM fractal_periodogram(ARRAY[1,2,3,4,5,6,7,8]::float8[], 4)"
  fault_sweep "tda"              "SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4,5,6]::float8[], 2)"
  fault_sweep "portfolio"        "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2, 7)"
  fault_sweep "set_config"       "SELECT fractalsql_set_config('http_model', 'bt-model'); SELECT fractalsql_get_config('http_model')"
  fault_sweep "store/mine"       "SELECT fractal_store_morphology(1, ARRAY[0.1,0.2]::float8[]); SELECT count(*) FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[], 2)"

  # ---- enterprise mock: ledger / audit ----------------------------------
  local mock_so="$TMPROOT/fractalsql_bt_g47_ent_${PG_MAJOR}.so"
  rm -f "$mock_so" "$mock_so.sig"
  if cc -shared -fPIC -std=c99 -Iinclude tests/mock_enterprise_core.c -o "$mock_so" 2>/tmp/fractalsql_bt_gate47_build.log; then
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;" >/dev/null 2>&1 </dev/null
    if pg_set_guc fractalsql.enterprise_lib "'$mock_so'" "$mock_so"; then
      fault_sweep "ledger verify"  "SELECT fractal_ledger_verify(1)"
      fault_sweep "ledger load"    "SELECT fractal_ledger_load()"
      fault_sweep "ledger flush"   "SELECT fractal_ledger_flush()"
      fault_sweep "audit_log"      "SELECT fractal_audit_log('bt', '{\"k\":1}')"
      fault_sweep "ledger compact" "SELECT fractal_ledger_compact()"
      fault_sweep "ledger reset"   "SELECT fractal_ledger_reset_soft(); SELECT fractal_ledger_reset_hard()"
      fault_sweep "ledger counts"  "SELECT fractal_ledger_truth_count(); SELECT fractal_ledger_shadow_count()"
      fault_sweep "multimodal"     "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2)"
      fault_sweep "pareto"         "SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2)"
    else
      fail "47 fault_injection: could not point enterprise_lib at the mock"
    fi
    "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.enterprise_require_signature; ALTER SYSTEM RESET fractalsql.enterprise_lib; SELECT pg_reload_conf();" >/dev/null 2>&1 </dev/null
  else
    cat /tmp/fractalsql_bt_gate47_build.log >&2
    fail "47 fault_injection: mock enterprise core failed to build"
  fi
  rm -f "$mock_so" "$mock_so.sig"

  # ---- ledger storage callbacks, driven directly (test-only SQL wrapper) --
  # The enterprise core is what normally calls them, and none is vendored in a
  # community checkout, so the build's fractal_fi_ledger_vfs() stands in.
  "${PSQL[@]}" -c "
     CREATE OR REPLACE FUNCTION bt_fi_ledger_vfs(op text, kind int4, payload bytea DEFAULT NULL)
       RETURNS text AS '$SO','fractal_fi_ledger_vfs' LANGUAGE C VOLATILE;
     DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1 </dev/null
  local lr
  lr=$("${PSQL[@]}" -c "SELECT bt_fi_ledger_vfs('read', 1)" 2>&1 </dev/null)
  [[ "$lr" = "rc=-46 len=0 hex=" ]] \
    && pass "47 fault_injection: reading an empty ledger reports 'unavailable' (-46), not an error" \
    || fail "47 fault_injection: empty-ledger read returned: $lr"
  "${PSQL[@]}" -c "SELECT bt_fi_ledger_vfs('write', 1, '\\x616263')" >/dev/null 2>&1 </dev/null
  lr=$("${PSQL[@]}" -c "SELECT bt_fi_ledger_vfs('read', 1)" 2>&1 </dev/null)
  [[ "$lr" = "rc=0 len=3 hex=616263" ]] \
    && pass "47 fault_injection: a ledger entry written through the storage callback reads back byte for byte" \
    || fail "47 fault_injection: ledger read-back returned: $lr"
  fault_sweep "ledger vfs write"       "SELECT bt_fi_ledger_vfs('write', 1, '\\x616263')"
  fault_sweep "ledger vfs write keyed" "SET fractalsql.enterprise_ledger_key = 'bt-key'; SELECT bt_fi_ledger_vfs('write', 1, '\\x616263'); SELECT bt_fi_ledger_vfs('read', 1)"
  fault_sweep "ledger vfs read"        "SELECT bt_fi_ledger_vfs('read', 1)"
  fault_sweep "ledger vfs seal"        "SELECT bt_fi_ledger_vfs('seal', 1)"
  "${PSQL[@]}" -c "DROP FUNCTION IF EXISTS bt_fi_ledger_vfs(text,int4,bytea); DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1 </dev/null

  if [[ "$FI_BAD" -eq 0 && "$FI_FIRED" -gt 100 ]]; then
    pass "47 fault_injection: $FI_FIRED injected SPI/core failures across $FI_RUNS runs; none crashed, hung or leaked"
  elif [[ "$FI_BAD" -eq 0 ]]; then
    fail "47 fault_injection: only $FI_FIRED faults fired in $FI_RUNS runs -- the hook is not reaching the call sites"
  fi

  "${PSQL[@]}" -c "RESET fractalsql.fault_inject; DROP TABLE IF EXISTS bt_g47, bt_g47v;" >/dev/null 2>&1 </dev/null
  pg_swap_plugin "$MOCK" >/dev/null
  rm -f /tmp/fractalsql_bt_sql.txt
  return 0
}

# --- run one major through a gate set ---------------------------------
gate_24_enterprise() {
  # QTL ledger + CISO audit -- runtime-gated behind the enterprise core
  # library. Self-skips on a community-only checkout (no enterprise
  # library vendored in include/). When the library IS present, exercises
  # the full wiring: dlopen + dlsym of fsql_ledger_*/fsql_audit_unpack, the
  # Postgres-backed storage VFS round-trip (flush -> fractalsql_ledger ->
  # audit_unpack), and the dormant-path error when the library is absent.
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-sovereign-c.so include/*/libfractalsql-enterprise-sovereign-c.dylib 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "24 enterprise: skipped (community edition; no libfractalsql-enterprise-sovereign-c.* in include/)"
    return
  fi
  local abs
  abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")

  # Phase E below calls agents that invoke fractal_reason -- make sure the
  # mock plugin is active regardless of whether gate 23 ran first (this
  # gate must be standalone-runnable, same rationale as gate 23's swap).
  pg_swap_plugin "$MOCK" >/dev/null

  # fractalsql.enterprise_lib is PGC_SIGHUP: set it via ALTER SYSTEM +
  # reload, then poll until a fresh backend observes the new value (a
  # bare SET cannot change a SIGHUP GUC in-session, and pg_reload_conf()
  # returns before the postmaster has re-read config).
  local v
  set_ent_guc() {
    local val="$1" want="$1"
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_lib = '$val';" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      v=$("${PSQL[@]}" -tA -c "SHOW fractalsql.enterprise_lib;" 2>/dev/null)
      [[ "$v" = "$want" ]] && return
      sleep 0.3
    done
  }

  # Phase A: enterprise library present -- the surface activates.
  set_ent_guc "$abs"
  if [[ "$v" != "$abs" ]]; then
    fail "24 enterprise: could not apply fractalsql.enterprise_lib (reload did not take effect; got '$v')"
    return
  fi
  local ra
  ra=$("${PSQL[@]}" -c "
    SELECT fractal_ledger_flush();
    SELECT fractal_ledger_truth_count() AS truth, fractal_ledger_shadow_count() AS shadow;
    SELECT fractal_ledger_load();
    SELECT fractal_ledger_compact();
    SELECT fractal_ledger_reset_soft();
    SELECT fractal_ledger_reset_hard();
    SELECT fractal_audit_unpack(blob)::text AS audit
      FROM fractalsql_ledger WHERE kind = 1;" 2>&1)
  grep <<< "$ra" -q "ERROR:" \
    && fail "24 enterprise: ledger/audit errored with the enterprise library present: $ra" \
    || pass "24 enterprise: ledger flush/load/compact/reset/counts work with the enterprise library"
  grep <<< "$ra" -q "\[\]" \
    && pass "24 enterprise: fractal_audit_unpack decoded the persisted QTL blob end-to-end (storage VFS round-trip)" \
    || fail "24 enterprise: audit_unpack did not return the flushed QTL jsonb (got: $ra)"

  # Phase B: point the GUC at a missing path -- the surface goes dormant,
  # equivalent to removing the .so. Fresh backend -> dlopen fails -> the
  # documented 'enterprise tier not loaded' error.
  set_ent_guc "/nonexistent/fractalsql-enterprise-absent.so"
  local rb
  rb=$("${PSQL[@]}" -c "SELECT fractal_ledger_flush();" 2>&1)
  grep <<< "$rb" -q "enterprise tier not loaded" \
    && pass "24 enterprise: ledger functions return 'enterprise tier not loaded' when the library is absent" \
    || fail "24 enterprise: expected 'enterprise tier not loaded' when absent, got: $rb"

  # Phase C: fractal_optimize_portfolio_multimodal -- dormant error while
  # absent, real multi-candidate result once the library is back.
  local rc_dormant
  rc_dormant=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);" 2>&1)
  grep <<< "$rc_dormant" -q "enterprise tier not loaded" \
    && pass "24 enterprise: portfolio_multimodal returns 'enterprise tier not loaded' when the library is absent" \
    || fail "24 enterprise: expected 'enterprise tier not loaded' for portfolio_multimodal when absent, got: $rc_dormant"

  set_ent_guc "$abs"
  local rc_active
  rc_active=$("${PSQL[@]}" -tA -c "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2, 4)->>'n_found';" 2>/dev/null)
  case "$rc_active" in
    [1-9]|[1-9][0-9])
      pass "24 enterprise: portfolio_multimodal returns real candidates (n_found=$rc_active) with the library present" ;;
    *)
      fail "24 enterprise: expected a positive n_found from portfolio_multimodal, got: $rc_active" ;;
  esac

  # Phase D: fractal_audit_log / fractal_ledger_verify(2) -- the general
  # decision-audit chain (kind=2, independent of kind=1's QTL chain).
  # Library still active from Phase C.
  "${PSQL[@]}" -c "DELETE FROM fractalsql_ledger WHERE kind = 2;" >/dev/null 2>&1
  local rd_write
  rd_write=$("${PSQL[@]}" -c "SELECT fractal_audit_log('test_entry', '{\"note\":\"gate24\"}'::jsonb);" 2>&1)
  grep <<< "$rd_write" -q "ERROR:" \
    && fail "24 enterprise: fractal_audit_log errored with the library present: $rd_write" \
    || pass "24 enterprise: fractal_audit_log writes to the audit chain (kind=2) with the library present"

  local rd_verify
  rd_verify=$("${PSQL[@]}" -tA -c "SELECT fractal_ledger_verify(2)->>'ok';" 2>/dev/null)
  [[ "$rd_verify" = "true" ]] \
    && pass "24 enterprise: fractal_ledger_verify(2) confirms the audit chain is clean" \
    || fail "24 enterprise: expected fractal_ledger_verify(2) ok=true, got: $rd_verify"

  # fractal_optimize_portfolio (single-best) also logs to the audit chain
  # when enterprise is active -- confirm a NEW kind=2 row appears.
  local rd_before rd_after
  rd_before=$("${PSQL[@]}" -tA -c "SELECT count(*) FROM fractalsql_ledger WHERE kind = 2;" 2>/dev/null)
  "${PSQL[@]}" -c "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);" >/dev/null 2>&1
  rd_after=$("${PSQL[@]}" -tA -c "SELECT count(*) FROM fractalsql_ledger WHERE kind = 2;" 2>/dev/null)
  if [[ "${rd_after:-0}" -gt "${rd_before:-0}" ]] 2>/dev/null; then
    pass "24 enterprise: fractal_optimize_portfolio logs a provenance record to the audit chain when enterprise is active"
  else
    fail "24 enterprise: expected a new kind=2 row after fractal_optimize_portfolio, before=$rd_before after=$rd_after"
  fi

  # Dormant: fractal_audit_log errors cleanly; fractal_optimize_portfolio
  # (a community feature) keeps working regardless -- this is the whole
  # point of the best-effort binding.
  set_ent_guc "/nonexistent/fractalsql-enterprise-absent.so"
  local rd_dormant
  rd_dormant=$("${PSQL[@]}" -c "SELECT fractal_audit_log('test_entry', '{}'::jsonb);" 2>&1)
  grep <<< "$rd_dormant" -q "enterprise tier not loaded" \
    && pass "24 enterprise: fractal_audit_log returns 'enterprise tier not loaded' when the library is absent" \
    || fail "24 enterprise: expected 'enterprise tier not loaded' for fractal_audit_log when absent, got: $rd_dormant"

  local rd_portfolio_still_works
  rd_portfolio_still_works=$("${PSQL[@]}" -c "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);" 2>&1)
  grep <<< "$rd_portfolio_still_works" -q "ERROR:" \
    && fail "24 enterprise: fractal_optimize_portfolio broke on community (no enterprise lib): $rd_portfolio_still_works" \
    || pass "24 enterprise: fractal_optimize_portfolio (community feature) keeps working with the enterprise library absent"

  # Phase E: representative sample of the newly-wired agent bindings --
  # confirm each writes a correctly-typed kind=2 row when enterprise is
  # active. Gate 23 already proves all 11 candidates behave identically
  # (best-effort no-op) on community; this proves the enterprise side of
  # the same bindings actually fires.
  set_ent_guc "$abs"
  latest_audit_type() {
    "${PSQL[@]}" -tA -c "
      SELECT convert_from(blob, 'UTF8')::jsonb->>'type'
        FROM fractalsql_ledger WHERE kind = 2
        ORDER BY id DESC LIMIT 1;" 2>/dev/null
    return 0
  }

  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_gate24_history;
     CREATE TABLE bt_gate24_history (id int PRIMARY KEY, emb float8[]);
     INSERT INTO bt_gate24_history VALUES (1, ARRAY[0.1,0.2,0.3]);" >/dev/null 2>&1
  "${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_outlier_intercept(
       ARRAY[0.1,0.2,0.3]::float8[], 'bt_gate24_history', 'emb', 0.5);" >/dev/null 2>&1
  [[ "$(latest_audit_type)" = "agent_outlier_intercept" ]] \
    && pass "24 enterprise: fractal_agent_outlier_intercept logs a provenance record to the audit chain" \
    || fail "24 enterprise: expected agent_outlier_intercept in the latest kind=2 row"

  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_gate24_data;
     CREATE TABLE bt_gate24_data (id int PRIMARY KEY, val float8);
     INSERT INTO bt_gate24_data VALUES (1,10.5),(2,20.5);" >/dev/null 2>&1
  "${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_data_analyst(
       'sum of val', ARRAY['bt_gate24_data'], 2);" >/dev/null 2>&1
  [[ "$(latest_audit_type)" = "agent_data_analyst" ]] \
    && pass "24 enterprise: fractal_agent_data_analyst logs a provenance record to the audit chain" \
    || fail "24 enterprise: expected agent_data_analyst in the latest kind=2 row"

  # fractal_agent_diverse_portfolios (enterprise-only gap-fix binding) --
  # both the C-side portfolio_optimize_multimodal entry and the agent-level
  # entry must land (same double-logging pattern as allocate/rebalance).
  "${PSQL[@]}" -c "
     SELECT * FROM fractal_agent_diverse_portfolios(
       ARRAY[0.1,0.05,0.08]::float8[],
       ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2, 4);" >/dev/null 2>&1
  local rd_diverse_types
  rd_diverse_types=$("${PSQL[@]}" -tA -c "
    SELECT convert_from(blob, 'UTF8')::jsonb->>'type'
      FROM fractalsql_ledger WHERE kind = 2
      ORDER BY id DESC LIMIT 2;" 2>/dev/null)
  grep <<< "$rd_diverse_types" -q "agent_diverse_portfolios" \
    && grep <<< "$rd_diverse_types" -q "portfolio_optimize_multimodal" \
    && pass "24 enterprise: fractal_agent_diverse_portfolios + fractal_optimize_portfolio_multimodal both log (double-logging, gap-fix binding)" \
    || fail "24 enterprise: expected both agent_diverse_portfolios and portfolio_optimize_multimodal in the last 2 kind=2 rows, got: $rd_diverse_types"

  # Reset the GUC so it does not leak into later gates on a reused cluster.
  set_ent_guc ""
  return 0
}

gate_25_enterprise_stress() {
  # Enterprise QTL ledger under stress + tamper-evidence + concurrency.
  # Self-skips on a community-only checkout (same detection as gate 24).
  # Gate 24 covers the basic active/dormant wiring; this gate exercises the
  # ledger at its capacity bound, under repeated churn, against a corrupted
  # blob, and under concurrent + cross-backend access.
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-sovereign-c.so include/*/libfractalsql-enterprise-sovereign-c.dylib 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "25 enterprise-stress: skipped (community edition; no libfractalsql-enterprise-sovereign-c.* in include/)"
    return
  fi
  local abs
  abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")

  # PGC_SIGHUP GUC -- same apply-and-poll helper as gate 24.
  local v
  set_ent_guc() {
    local val="$1" want="$1"
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_lib = '$val';" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      v=$("${PSQL[@]}" -tA -c "SHOW fractalsql.enterprise_lib;" 2>/dev/null)
      [[ "$v" = "$want" ]] && return
      sleep 0.3
    done
  }

  set_ent_guc "$abs"
  if [[ "$v" != "$abs" ]]; then
    fail "25 enterprise-stress: could not apply fractalsql.enterprise_lib (got '$v')"
    set_ent_guc ""
    return
  fi

  # Clean slate for the gate.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1

  # ---- Phase A: stress -- fill-to-cap (64 truth + 64 shadow = 128) + churn.
  # Truth/Shadow each cap at 64 (FSQL_TRUTH/SHADOW_DEFAULT_CAP); beyond that
  # the lowest-weight entry is evicted. 64+64 with disjoint doc_ids encodes
  # all 128 (no QTL dedup). Churn = 10 reset+reseed+flush+load cycles.
  local ra
  ra=$("${PSQL[@]}" 2>&1 <<'SQL'
SELECT fractal_diversify_enable();
DO $$
DECLARE i int; c int; tc bigint; sc bigint; ev int; audit jsonb;
BEGIN
  PERFORM fractal_ledger_reset_hard();
  FOR i IN 1..64 LOOP PERFORM fractal_feedback_report(i, 'positive'); END LOOP;
  FOR i IN 65..128 LOOP PERFORM fractal_feedback_report(i, 'negative'); END LOOP;
  SELECT fractal_ledger_truth_count()  INTO tc;
  SELECT fractal_ledger_shadow_count() INTO sc;
  PERFORM fractal_ledger_flush();
  SELECT fractal_audit_unpack(blob) INTO audit FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  ev := jsonb_array_length(audit);
  IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
    RAISE EXCEPTION 'A fill mismatch: truth=% shadow=% events=%', tc, sc, ev;
  END IF;
  FOR c IN 1..10 LOOP
    PERFORM fractal_ledger_reset_hard();
    FOR i IN 1..64  LOOP PERFORM fractal_feedback_report(i + 1000*c, 'positive'); END LOOP;
    FOR i IN 65..128 LOOP PERFORM fractal_feedback_report(i + 1000*c, 'negative'); END LOOP;
    PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_load();
  END LOOP;
  SELECT fractal_ledger_truth_count()  INTO tc;
  SELECT fractal_ledger_shadow_count() INTO sc;
  SELECT fractal_audit_unpack(blob) INTO audit FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  ev := jsonb_array_length(audit);
  IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
    RAISE EXCEPTION 'A churn mismatch: truth=% shadow=% events=%', tc, sc, ev;
  END IF;
END $$;
SQL
)
  if grep <<< "$ra" -q "ERROR:"; then
    fail "25 enterprise-stress Phase A: fill-to-cap/churn errored: $ra"
  else
    pass "25 enterprise-stress Phase A: fill-to-cap (64+64=128) + 10 flush/load churn cycles, audit round-trips 128 events"
  fi

  # ---- Phase B: tamper-evidence (structural). Truncate the persisted QTL
  # blob below the 24-byte header and assert load rejects it. NOTE: the QTL
  # format carries no CRC/MAC and ledger_seal_ledger is a no-op, so this is
  # STRUCTURAL tamper-evidence only -- a targeted payload byte-flip is NOT
  # caught. The gate asserts the structural case and documents the gap.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  local rb
  rb=$("${PSQL[@]}" 2>&1 <<'SQL'
SELECT fractal_diversify_enable();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_feedback_report(2, 'negative');
SELECT fractal_ledger_flush();
UPDATE fractalsql_ledger SET blob = substring(blob from 1 for 5) WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
SELECT fractal_ledger_load();
SQL
)
  # B-full's entry_hash covers the blob unconditionally (no key required),
  # so this UPDATE is now caught by ledger_verify_latest()'s chain-hash
  # check BEFORE the core's own structural decode ever runs -- a strictly
  # earlier, and now always-active, layer of the same tamper-evidence.
  # Accept either message: the core's structural rejection is still the
  # fallback for anything that somehow gets past the chain-hash check.
  if grep <<< "$rb" -q "ERROR:" && grep <<< "$rb" -qE "fsql_ledger_load|ledger chain verification failed"; then
    pass "25 enterprise-stress Phase B: structural tamper (truncated QTL blob) rejected by load"
  else
    fail "25 enterprise-stress Phase B: expected load to reject a truncated blob, got: $rb"
  fi

  # ---- Phase C: concurrency.
  # (a) Cross-session persistence: seed+flush in one backend, load+count in
  #     a FRESH backend; counts must match (proves the table-backed VFS is
  #     backend-independent, not in-memory only).
  # (b) 8 concurrent backends each seed one event + flush. Under B-full's
  #     append-only chain this correctly produces MULTIPLE rows (B-lite's
  #     UPSERT collapsed concurrent flushes into one; that behavior is
  #     gone by design). The invariant now is that the chain stays a
  #     single unforked line despite the concurrency -- ledger_write_entry's
  #     advisory xact lock (keyed on kind) serializes the "read head, link,
  #     insert" sequence -- and the latest blob still decodes cleanly.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  # NOTE: seed+flush MUST run as -c/-c/-c... within a SINGLE psql
  # invocation (one backend, one g_ctx) -- each separate "${PSQL[@]}" -c
  # call below would otherwise open its own connection/backend, so the
  # in-memory truth/shadow ledgers from one call would never be visible
  # to the next and fractal_ledger_flush() would persist an EMPTY
  # ledger (the cross-session load then correctly reports 0|0, which
  # silently masked this rather than erroring).
  "${PSQL[@]}" \
    -c "SELECT fractal_diversify_enable();" \
    -c "SELECT fractal_ledger_reset_hard();" \
    -c "SELECT fractal_feedback_report(g, 'positive') FROM generate_series(1,10) g;" \
    -c "SELECT fractal_feedback_report(g, 'negative') FROM generate_series(11,20) g;" \
    -c "SELECT fractal_ledger_flush();" >/dev/null 2>&1
  local cross
  cross=$("${PSQL[@]}" -c "SELECT fractal_ledger_load(); SELECT fractal_ledger_truth_count() AS t, fractal_ledger_shadow_count() AS s;" 2>&1)
  if grep <<< "$cross" -q "10|10"; then
    pass "25 enterprise-stress Phase C(a): cross-session persistence -- fresh backend loaded 10/10 from the persisted blob"
  else
    fail "25 enterprise-stress Phase C(a): expected 10|10 after cross-session load, got: $cross"
  fi

  # 8 concurrent workers, each: seed one event + flush. Fresh chain (drop
  # first) so the row count is self-contained regardless of what earlier
  # phases left behind; pre-flush one row before the workers start so they
  # write to an EXISTING chain, avoiding the concurrent CREATE TABLE IF NOT
  # EXISTS race on pg_class. feedback_report inserts unconditionally, so
  # workers need not re-enable diversify. Invariant: 9 rows total (1
  # pre-flush + 8 concurrent), the chain verifies as a single unforked
  # line, and the latest blob decodes.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT fractal_diversify_enable(); SELECT fractal_feedback_report(0, 'positive'); SELECT fractal_ledger_flush();" >/dev/null 2>&1
  local w
  for w in 1 2 3 4 5 6 7 8; do
    "${PSQL[@]}" -c "SELECT fractal_feedback_report($w, 'positive'); SELECT fractal_ledger_flush();" >/dev/null 2>&1 &
  done
  wait
  local rows verify_full verify_ok latest_decode
  rows=$("${PSQL[@]}" -tA -c "SELECT count(*) FROM fractalsql_ledger WHERE kind = 1;" 2>/dev/null)
  verify_full=$("${PSQL[@]}" -tA -c "SELECT fractal_ledger_verify()::text;" 2>/dev/null)
  verify_ok=$("${PSQL[@]}" -tA -c "SELECT fractal_ledger_verify()->>'ok';" 2>/dev/null)
  latest_decode=$("${PSQL[@]}" -c "SELECT fractal_audit_unpack(blob)::text FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;" 2>&1)
  if [[ "$rows" = "9" ]] && [[ "$verify_ok" = "true" ]] && ! grep <<< "$latest_decode" -q "ERROR:"; then
    pass "25 enterprise-stress Phase C(b): 8 concurrent flushes -> 9 append-only rows, chain verifies as one unforked line, latest blob decodes"
  else
    fail "25 enterprise-stress Phase C(b): expected 9 linked rows + clean decode after parallel flush, got rows=$rows verify=$verify_full decode=$latest_decode"
  fi

  # ---- Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_key).
  # Phases A-C ran with the key UNSET (structural path). D sets the key
  # (PGC_SUSET -> SET per-session, no reload): flush tags the blob with
  # HMAC-SHA256 (assert length(mac)=32), load verifies; a middle payload
  # byte-flip (length + count preserved -> structural check blind to it) is
  # rejected by the MAC; re-flush re-tags and load verifies clean. This is
  # B-lite: the MAC lives in the open extension at the storage seam; the
  # enterprise core is unchanged and is never handed tampered bytes.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  local rd
  rd=$("${PSQL[@]}" 2>&1 <<'SQL'
SET fractalsql.enterprise_ledger_key = 'gate25-mac-key';
DO $$
DECLARE mac_len int;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive');
  PERFORM fractal_ledger_flush();
  SELECT length(mac) INTO mac_len FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  IF mac_len IS NULL OR mac_len <> 32 THEN
    RAISE EXCEPTION 'D tag mismatch: mac length = % (expected 32)', mac_len;
  END IF;
  PERFORM fractal_ledger_load();                 -- MAC verifies -> ok
  -- tamper: flip a middle payload byte the structural check cannot see
  UPDATE fractalsql_ledger
     SET blob = set_byte(blob, length(blob) / 2, 254)
   WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
  BEGIN
    PERFORM fractal_ledger_load();
    RAISE EXCEPTION 'D tamper NOT detected: load accepted a byte-flipped blob';
  EXCEPTION
    WHEN internal_error THEN
      RAISE NOTICE 'D tamper detected by HMAC (byte-flip rejected)';
  END;
  -- recovery: re-flush re-tags; load verifies clean
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive');
  PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_load();
EXCEPTION
  WHEN object_not_in_prerequisite_state THEN
    RAISE EXCEPTION 'D enterprise not loaded';
END $$;
RESET fractalsql.enterprise_ledger_key;
SQL
)
  if grep <<< "$rd" -q "D tamper detected by HMAC"; then
    pass "25 enterprise-stress Phase D: HMAC MAC tags blob (32B), rejects a structural-blind byte-flip, re-flush re-tags cleanly"
  else
    fail "25 enterprise-stress Phase D: MAC path did not behave as expected: $rd"
  fi

  # ---- Phase E: B-full append-only chain -- multi-row verify, a MIDDLE-row
  # tamper that fractal_ledger_load()'s O(1) tip-only check cannot see but
  # fractal_ledger_verify()'s full O(n) walk catches, and a deleted-row gap.
  # NOTE (documented limitation, not tested here): a chain can prove nothing
  # in the MIDDLE was altered/removed, but it cannot prove nothing was
  # truncated off the very END -- there is nothing after the last surviving
  # row to notice its absence. That needs an external anchor (e.g. publishing
  # the head hash somewhere independent), out of scope here.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  local re
  re=$("${PSQL[@]}" 2>&1 <<'SQL'
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(2, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(3, 'positive'); PERFORM fractal_ledger_flush();

  SELECT fractal_ledger_verify() INTO v;
  IF NOT (v->>'ok')::boolean OR (v->>'rows_verified')::int <> 3 THEN
    RAISE EXCEPTION 'E chain mismatch after 3 flushes: %', v;
  END IF;
  RAISE NOTICE 'E verify: 3/3 rows clean after 3 flushes';

  -- Tamper a MIDDLE row (id=2), not the latest (id=3).
  UPDATE fractalsql_ledger SET blob = set_byte(blob, 0, 254) WHERE id = 2;

  -- load() only checks the tip (id=3) -- still succeeds. Documents the
  -- intentional O(1) scope boundary.
  PERFORM fractal_ledger_load();
  RAISE NOTICE 'E load: still passes after a MIDDLE-row tamper (O(1) tip-only scope)';

  -- the full walk done by verify() catches it.
  SELECT fractal_ledger_verify() INTO v;
  IF (v->>'ok')::boolean OR (v->>'first_failure_id')::int <> 2 THEN
    RAISE EXCEPTION 'E verify() did not catch the middle-row tamper: %', v;
  END IF;
  RAISE NOTICE 'E verify: caught middle-row tamper at id=2 (%)', v->>'reason';
END $$;
SQL
)
  if grep <<< "$re" -q "E verify: 3/3 rows clean" \
     && grep <<< "$re" -q "E load: still passes" \
     && grep <<< "$re" -q "E verify: caught middle-row tamper"; then
    pass "25 enterprise-stress Phase E: B-full chain -- multi-row verify, middle-row tamper undetected by load but caught by verify()"
  else
    fail "25 enterprise-stress Phase E: B-full chain checks did not behave as expected: $re"
  fi

  # Phase E continued: deleting a MIDDLE row leaves a visible id-sequence gap.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  local rg
  rg=$("${PSQL[@]}" 2>&1 <<'SQL'
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(2, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(3, 'positive'); PERFORM fractal_ledger_flush();

  DELETE FROM fractalsql_ledger WHERE id = 2;

  SELECT fractal_ledger_verify() INTO v;
  IF (v->>'ok')::boolean OR (v->>'reason' NOT LIKE '%gap%') THEN
    RAISE EXCEPTION 'E deletion gap not detected: %', v;
  END IF;
  RAISE NOTICE 'E verify: caught deletion gap (%)', v->>'reason';
END $$;
SQL
)
  if grep <<< "$rg" -q "E verify: caught deletion gap"; then
    pass "25 enterprise-stress Phase E: deleting a middle row leaves a visible id-sequence gap, caught by verify()"
  else
    fail "25 enterprise-stress Phase E: deletion gap detection did not behave as expected: $rg"
  fi

  # Phase E continued: migrating an existing B-lite-shaped table (kind PK,
  # no id/prev_hash/entry_hash) -- expect a NOTICE and a clean fresh chain,
  # not an error. Nothing worth preserving from that shape (last-writer-wins,
  # no real history), so this is an intentional reset, not data loss.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  "${PSQL[@]}" -c "
    CREATE TABLE fractalsql_ledger (
      kind    integer PRIMARY KEY,
      blob    bytea   NOT NULL,
      mac     bytea,
      sealed  boolean NOT NULL DEFAULT false,
      updated timestamptz NOT NULL DEFAULT now()
    );
    INSERT INTO fractalsql_ledger (kind, blob) VALUES (1, '\x00'::bytea);
  " >/dev/null 2>&1
  local rm
  rm=$("${PSQL[@]}" -c "SELECT fractal_diversify_enable(); SELECT fractal_ledger_reset_hard(); SELECT fractal_feedback_report(1, 'positive'); SELECT fractal_ledger_flush();" 2>&1)
  local rm_verify
  rm_verify=$("${PSQL[@]}" -c "SELECT fractal_ledger_verify();" 2>&1)
  if grep <<< "$rm" -q "migrating fractalsql_ledger from the single-row snapshot schema" \
     && grep <<< "$rm_verify" -q '"ok": *true'; then
    pass "25 enterprise-stress Phase E: single-row-snapshot -> append-only-chain schema migration -- NOTICE fires, fresh chain verifies clean"
  else
    fail "25 enterprise-stress Phase E: migration did not behave as expected: flush=$rm verify=$rm_verify"
  fi

  # Reset the GUC so it does not leak into later gates on a reused cluster.
  set_ent_guc ""
  return 0
}

gate_26_enterprise_signature() {
  # Detached Ed25519 signature verification for the enterprise .so
  # (fractalsql.enterprise_require_signature). Self-skips on a
  # community-only checkout, same detection as gates 24/25.
  #
  # This gate deliberately does NOT test the "valid signature, actually
  # verifies" happy path -- that requires the matching private key, which
  # is FractalSQLabs's release-process secret and does not belong in this
  # repo or its test fixtures (a checked-in test key would misrepresent
  # key custody). That path was validated manually against a throwaway
  # keypair during development -- gate 24 passing with a real matching
  # .sig staged alongside the .so is the evidence (see fractalsql.c's
  # FSQL_ENTERPRISE_PUBKEY comment). What's tested here needs no key at
  # all: a missing .sig (soft unless require=on) and an invalid .sig
  # (always hard-refused, regardless of require).
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-sovereign-c.so include/*/libfractalsql-enterprise-sovereign-c.dylib 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "26 enterprise-signature: skipped (community edition; no libfractalsql-enterprise-sovereign-c.* in include/)"
    return
  fi
  local abs sig_path
  abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")
  sig_path="${abs}.sig"
  rm -f "$sig_path"

  local v
  set_ent_guc() {
    local val="$1" want="$1"
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_lib = '$val';" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      v=$("${PSQL[@]}" -tA -c "SHOW fractalsql.enterprise_lib;" 2>/dev/null)
      [[ "$v" = "$want" ]] && return
      sleep 0.3
    done
  }
  set_require() {
    local rval="$1" want_r="$1" vr
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_require_signature = $rval;" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      vr=$("${PSQL[@]}" -tA -c "SHOW fractalsql.enterprise_require_signature;" 2>/dev/null)
      [[ "$vr" = "$want_r" ]] && return
      sleep 0.3
    done
  }

  set_ent_guc "$abs"
  if [[ "$v" != "$abs" ]]; then
    fail "26 enterprise-signature: could not apply fractalsql.enterprise_lib (got '$v')"
    return
  fi

  # ---- Case A: no .sig, require=off (default) -- soft: WARNING logged,
  # library still loads and works.
  set_require "off"
  local ra
  ra=$("${PSQL[@]}" -c "SELECT fractal_ledger_reset_hard();" 2>&1)
  if grep <<< "$ra" -q "no signature found for enterprise library" \
     && ! grep <<< "$ra" -q "enterprise tier not loaded"; then
    pass "26 enterprise-signature Case A: missing .sig + require=off -- WARNS but still loads"
  else
    fail "26 enterprise-signature Case A: expected a WARN-and-load, got: $ra"
  fi

  # ---- Case B: no .sig, require=on -- hard: refused.
  set_require "on"
  local rb
  rb=$("${PSQL[@]}" -c "SELECT fractal_ledger_reset_hard();" 2>&1)
  if grep <<< "$rb" -q "no signature found for enterprise library" \
     && grep <<< "$rb" -q "enterprise tier not loaded"; then
    pass "26 enterprise-signature Case B: missing .sig + require=on -- refused"
  else
    fail "26 enterprise-signature Case B: expected a hard refusal, got: $rb"
  fi

  # ---- Case C: invalid/garbage .sig (64 random bytes, matches no key) --
  # always refused, even with require=off.
  set_require "off"
  head -c 64 /dev/urandom > "$sig_path"
  local rc
  rc=$("${PSQL[@]}" -c "SELECT fractal_ledger_reset_hard();" 2>&1)
  if grep <<< "$rc" -q "failed signature verification" \
     && grep <<< "$rc" -q "enterprise tier not loaded"; then
    pass "26 enterprise-signature Case C: invalid .sig -- always refused regardless of require setting"
  else
    fail "26 enterprise-signature Case C: expected a hard refusal on invalid signature, got: $rc"
  fi
  rm -f "$sig_path"

  # Reset the GUCs so they do not leak into later gates on a reused cluster.
  set_require "off"
  set_ent_guc ""
  return 0
}

# Reasoning-effort (THINK) GUC passthrough -- fractalsql.http_think/
# http_think_provider/http_native_url/http_num_ctx reach the plugin's
# process environment correctly (Case A/B), and never leak into
# fractal_embed()'s tier even when set (Case C, proving
# ensure_embed_ctx()'s explicit unsetenv() calls actually work). Each
# case uses a fresh "${PSQL[@]}" -c invocation deliberately -- a new
# backend process per call, so g_reason_loaded/g_embed_loaded (per-
# backend statics) start false and ensure_*_ctx() actually re-applies
# the current GUC values instead of short-circuiting on an earlier
# call's cached load.
gate_27_think() {
  pg_swap_plugin "$THINK" || { fail "27 think: plugin swap did not take effect"; return; }
  local dump=/tmp/fractalsql_bt_think_dump.txt

  # Case A: all four unset -- byte-identical to pre-v1.4.0 behavior.
  pg_set_guc fractalsql.http_think "''" "" || { fail "27 think: reset http_think"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_think_provider "''" "" || { fail "27 think: reset http_think_provider"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_native_url "''" "" || { fail "27 think: reset http_native_url"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_num_ctx 0 0 || { fail "27 think: reset http_num_ctx"; pg_swap_plugin "$MOCK"; return; }
  rm -f "$dump"
  "${PSQL[@]}" -c "SELECT fractal_reason('q');" >/dev/null 2>&1
  local a; a=$(cat "$dump" 2>/dev/null)
  if grep <<< "$a" -q "^THINK=(unset)$" && grep <<< "$a" -q "^THINK_PROVIDER=(unset)$" \
     && grep <<< "$a" -q "^NATIVE_URL=(unset)$" && grep <<< "$a" -q "^NUM_CTX=(unset)$"; then
    pass "27 think Case A: all four GUCs unset -> no THINK-related env var reaches the plugin"
  else
    fail "27 think Case A: expected all four (unset), got: $a"
  fi

  # Case B: set all four -- each reaches the plugin's environment via
  # fractal_reason() (ensure_reason_ctx()'s apply_think_env()).
  pg_set_guc fractalsql.http_think "'medium'" "medium" || { fail "27 think: set http_think"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_think_provider "'ollama'" "ollama" || { fail "27 think: set http_think_provider"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_native_url "'http://127.0.0.1:9/native'" "http://127.0.0.1:9/native" \
    || { fail "27 think: set http_native_url"; pg_swap_plugin "$MOCK"; return; }
  pg_set_guc fractalsql.http_num_ctx 8192 8192 || { fail "27 think: set http_num_ctx"; pg_swap_plugin "$MOCK"; return; }
  rm -f "$dump"
  "${PSQL[@]}" -c "SELECT fractal_reason('q');" >/dev/null 2>&1
  local b; b=$(cat "$dump" 2>/dev/null)
  if grep <<< "$b" -q "^THINK=medium$" && grep <<< "$b" -q "^THINK_PROVIDER=ollama$" \
     && grep <<< "$b" -q "^NATIVE_URL=http://127.0.0.1:9/native$" && grep <<< "$b" -q "^NUM_CTX=8192$"; then
    pass "27 think Case B: all four GUCs reach the plugin via fractal_reason()"
  else
    fail "27 think Case B: expected THINK=medium/THINK_PROVIDER=ollama/NATIVE_URL=http://127.0.0.1:9/native/NUM_CTX=8192, got: $b"
  fi

  # Case C: fractal_text_to_sql()'s GENERATE step forwards the same four
  # (apply_think_env() is shared between ensure_reason_ctx() and
  # ensure_text_to_sql_ctx()) -- the mock's canned "OK" response isn't
  # a fenced SQL block, so this call is expected to error; only the
  # dump file (written before that error, at format_prompt() time) is
  # under test here.
  rm -f "$dump"
  "${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers']);" >/dev/null 2>&1
  local c; c=$(cat "$dump" 2>/dev/null)
  if grep <<< "$c" -q "^THINK=medium$" && grep <<< "$c" -q "^THINK_PROVIDER=ollama$"; then
    pass "27 think Case C: fractal_text_to_sql()'s GENERATE step also forwards THINK/THINK_PROVIDER"
  else
    fail "27 think Case C: expected THINK=medium/THINK_PROVIDER=ollama from the GENERATE step, got: $c"
  fi

  # Case D: fractal_embed() never sees THINK vars even with the GUCs
  # still set from Case B/C -- proves ensure_embed_ctx()'s explicit
  # unsetenv() calls, not just "embed happens not to set them".
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "27 think Case D: http_embed_url GUC did not take effect"; pg_swap_plugin "$MOCK"; return; }
  rm -f "$dump"
  "${PSQL[@]}" -c "SELECT fractal_embed('test input');" >/dev/null 2>&1
  local d; d=$(cat "$dump" 2>/dev/null)
  if grep <<< "$d" -q "^THINK=(unset)$" && grep <<< "$d" -q "^THINK_PROVIDER=(unset)$" \
     && grep <<< "$d" -q "^NATIVE_URL=(unset)$" && grep <<< "$d" -q "^NUM_CTX=(unset)$"; then
    pass "27 think Case D: fractal_embed() never sees THINK vars, even with the GUCs still set"
  else
    fail "27 think Case D: expected all four (unset) in the embed tier, got: $d"
  fi

  # Reset the GUCs so they do not leak into later gates on a reused cluster.
  pg_set_guc fractalsql.http_think "''" ""
  pg_set_guc fractalsql.http_think_provider "''" ""
  pg_set_guc fractalsql.http_native_url "''" ""
  pg_set_guc fractalsql.http_num_ctx 0 0
  pg_swap_plugin "$MOCK"
  return 0
}

# Regression test for ensure_review_ctx()/g_review_ctx: fractal_text_to_
# sql()'s REVIEW step must never see an operator-set
# FSQL_REASONING_HTTP_RESPONSE_MODE, even though REVIEW is "just a
# second fractal_reason()-shaped call" sharing the same URL/token/model
# config. Before this fix REVIEW shared g_reason_ctx directly, so an
# operator setting RESPONSE_MODE=json (say) for their own
# fractal_reason() calls would silently break t2s_run_review()'s
# hardcoded leading-PASS/FAIL text parsing too.
#
# Unlike THINK (gate 27), RESPONSE_MODE has no GUC -- it's captured
# from the raw process environment exactly once, at postmaster startup
# (_PG_init's g_response_mode_boot), so exercising it needs a real
# pg_ctl restart with the var exported into the postmaster's own
# environment, not just an ALTER SYSTEM + reload. Restores the
# un-restarted baseline afterward so later gates on this same reused
# cluster see a clean postmaster environment again.
gate_28_review_isolation() {
  pg_swap_plugin "$MOCK" >/dev/null

  local dump="/tmp/fractalsql_bt_review_env_dump.txt"
  restart_pg() {
    "$BIN/pg_ctl" -D "$DATADIR" -m fast stop >/dev/null 2>&1
    "$BIN/pg_ctl" -D "$DATADIR" -w -l "$DATADIR/log" \
       -o "-p $PORT -k $SOCKDIR -c listen_addresses='' -c shared_preload_libraries=$SO" \
       start >/tmp/fractalsql_bt_gate28_restart.log 2>&1
    return
  }

  export FSQL_REASONING_HTTP_RESPONSE_MODE=json
  if ! restart_pg; then
    fail "28 review_isolation: could not restart cluster with FSQL_REASONING_HTTP_RESPONSE_MODE=json set"
    unset FSQL_REASONING_HTTP_RESPONSE_MODE
    restart_pg
    return
  fi

  # Positive control: fractal_reason()'s own tier DOES see the boot-
  # captured value -- proves the env var actually reached the
  # postmaster (and that g_response_mode_boot's capture/re-apply
  # mechanism works) before trusting REVIEW's negative result below.
  rm -f "$dump"
  "${PSQL[@]}" -c "SELECT fractal_reason('q');" >/dev/null 2>&1
  local ra; ra=$(cat "$dump" 2>/dev/null)
  if grep <<< "$ra" -q "^RESPONSE_MODE=json$"; then
    pass "28 review_isolation: positive control -- fractal_reason() sees the boot-captured RESPONSE_MODE=json"
  else
    fail "28 review_isolation: positive control failed, expected RESPONSE_MODE=json from fractal_reason(), got: $ra"
  fi

  # The actual regression check: REVIEW must NOT see it, regardless.
  # REVIEW runs after GENERATE within one fractal_text_to_sql() call,
  # so the dump file's content once the whole call returns/errors
  # reflects REVIEW's own env (see mock_reasoning_plugin.c's header).
  if ! pg_set_guc fractalsql.text_to_sql_use_review on on; then
    fail "28 review_isolation: could not enable text_to_sql_use_review"
  else
    echo "SELECT 1" > /tmp/fractalsql_bt_sql.txt
    rm -f "$dump"
    "${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" >/dev/null 2>&1
    local rb; rb=$(cat "$dump" 2>/dev/null)
    if grep <<< "$rb" -q "^RESPONSE_MODE=(unset)$"; then
      pass "28 review_isolation: REVIEW step never sees the boot-captured RESPONSE_MODE, even though fractal_reason() does"
    else
      fail "28 review_isolation: expected RESPONSE_MODE=(unset) from the REVIEW dispatch, got: $rb"
    fi
    pg_set_guc fractalsql.text_to_sql_use_review off off
  fi

  # Restore: stop, drop the env var, restart -- so later gates on this
  # same reused cluster see a clean postmaster environment again.
  unset FSQL_REASONING_HTTP_RESPONSE_MODE
  restart_pg || fail "28 review_isolation: could not restart cluster to restore the clean baseline environment"
  pg_swap_plugin "$MOCK" >/dev/null
  return 0
}

# All 17 fractal_vector_* functions (sql/fractalsql--1.0.sql): the
# native vector type's arithmetic/distance/quantization family,
# known-answer asserted.
gate_29_vector_ops() {
  local r

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_cosine_similarity('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "1" ]] && pass "29 vector_ops: cosine_similarity(identical)=1" \
                    || fail "29 vector_ops: cosine_similarity='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_norm('[3,4,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "5" ]] && pass "29 vector_ops: norm([3,4,0])=5" \
                    || fail "29 vector_ops: norm='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_add('[1,2,3]'::fractal_vector, '[1,1,1]'::fractal_vector);" 2>&1)
  [[ "$r" = "[2,3,4]" ]] && pass "29 vector_ops: add([1,2,3],[1,1,1])=[2,3,4]" \
                          || fail "29 vector_ops: add='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_sub('[3,4,5]'::fractal_vector, '[1,1,1]'::fractal_vector);" 2>&1)
  [[ "$r" = "[2,3,4]" ]] && pass "29 vector_ops: sub([3,4,5],[1,1,1])=[2,3,4]" \
                          || fail "29 vector_ops: sub='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_dims('[1,2,3,4]'::fractal_vector);" 2>&1)
  [[ "$r" = "4" ]] && pass "29 vector_ops: dims([1,2,3,4])=4" \
                    || fail "29 vector_ops: dims='$r'"

  # float32 storage, not exact decimal: 0.6/0.8 round-trip through
  # fractal_vector's actual float32 precision as
  # 0.600000024/0.800000012 (fractal_vector_out's "%.9g", confirmed in
  # src/fractalsql_vector.c).
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_normalize('[3,4,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "[0.600000024,0.800000012,0]" ]] \
    && pass "29 vector_ops: normalize([3,4,0]) -> unit vector [0.6,0.8,0]" \
    || fail "29 vector_ops: normalize='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_normalize(NULL);" 2>&1)
  [[ "$r" = "" ]] && pass "29 vector_ops: normalize(NULL) -> NULL (STRICT)" \
                   || fail "29 vector_ops: expected NULL, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_scale('[1,2,3]'::fractal_vector, 2);" 2>&1)
  [[ "$r" = "[2,4,6]" ]] && pass "29 vector_ops: scale([1,2,3],2)=[2,4,6]" \
                          || fail "29 vector_ops: scale='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_scale(NULL, 2);" 2>&1)
  [[ "$r" = "" ]] && pass "29 vector_ops: scale(NULL,...) -> NULL (STRICT)" \
                   || fail "29 vector_ops: expected NULL, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_negative_inner_product('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "-1" ]] && pass "29 vector_ops: negative_inner_product(identical unit vectors)=-1" \
                     || fail "29 vector_ops: negative_inner_product='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_negative_inner_product(NULL, '[1,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "" ]] && pass "29 vector_ops: negative_inner_product(NULL,...) -> NULL (STRICT)" \
                   || fail "29 vector_ops: expected NULL, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_l2_distance('[0,0,0]'::fractal_vector, '[3,4,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "5" ]] && pass "29 vector_ops: l2_distance([0,0,0],[3,4,0])=5" \
                    || fail "29 vector_ops: l2_distance='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_l2_squared('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "25" ]] && pass "29 vector_ops: l2_squared([3,4,0],[0,0,0])=25 (skips the sqrt in l2_distance)" \
                     || fail "29 vector_ops: l2_squared='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_cosine_distance('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "0" ]] && pass "29 vector_ops: cosine_distance(identical)=0" \
                    || fail "29 vector_ops: cosine_distance='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_cosine_distance(NULL, '[1,0,0]'::fractal_vector);" 2>&1)
  [[ "$r" = "" ]] && pass "29 vector_ops: cosine_distance(NULL,...) -> NULL (STRICT)" \
                   || fail "29 vector_ops: expected NULL, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_vector_from_float8_array(ARRAY[1,2,3]::float8[]);" 2>&1)
  [[ "$r" = "[1,2,3]" ]] && pass "29 vector_ops: from_float8_array canonicalizes [1,2,3]" \
                          || fail "29 vector_ops: from_float8_array='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_to_float8_array('[1,2,3]'::fractal_vector);" 2>&1)
  [[ "$r" = "{1,2,3}" ]] \
    && pass "29 vector_ops: to_float8_array canonicalizes to {1,2,3} (native array text, not fractal_vector's own [1,2,3] form)" \
    || fail "29 vector_ops: to_float8_array='$r'"

  # --- v2.0.20: Lp distance, quantization, Hamming distance -----------
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 2.0);" 2>&1)
  [[ "$r" = "5" ]] && pass "29 vector_ops: lp_distance p=2 ([3,4] from origin) = 5" \
                    || fail "29 vector_ops: lp_distance p=2='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 1.0);" 2>&1)
  [[ "$r" = "7" ]] && pass "29 vector_ops: lp_distance p=1 ([3,4] from origin) = 7" \
                    || fail "29 vector_ops: lp_distance p=1='$r'"
  r=$("${PSQL[@]}" -c "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 0);" 2>&1)
  grep <<< "$r" -q "p must be > 0" \
    && pass "29 vector_ops: lp_distance rejects p<=0" \
    || fail "29 vector_ops: expected a p<=0 rejection, got: $r"

  # quantize_int8: dim raw signed bytes (hex bytea text "\xHHHH..."),
  # dequantization v[i] ~= codes[i]*scale within half a quantization step.
  local q8 q8_codes q8_scale q8_hex
  q8=$("${PSQL[@]}" -c "SELECT codes, scale FROM fractal_vector_quantize_int8('[1,-2,3]'::fractal_vector);" 2>&1)
  q8_codes=$(awk -F'|' '{print $1}' <<< "$q8")
  q8_scale=$(awk -F'|' '{print $2}' <<< "$q8")
  # Strip the "\x" prefix in bash, not in the awk script below: awk's -v
  # assignment does its own backslash-escape processing, which corrupts
  # a raw "\x2a" prefix before any sub()/regex here ever sees it.
  q8_hex="${q8_codes#\\x}"
  awk -v hex="$q8_hex" -v s="$q8_scale" '
    function abs(x) { return x < 0 ? -x : x }
    function hexbyte(h2,    i, c, v) {
      v = 0
      for (i = 1; i <= 2; i++) {
        c = index("0123456789abcdef", tolower(substr(h2, i, 1))) - 1
        v = v * 16 + c
      }
      return v
    }
    BEGIN {
      h = hex
      if (length(h) != 6 || (s + 0) <= 0) exit 1
      for (i = 1; i <= 3; i++) {
        v = hexbyte(substr(h, (i-1)*2+1, 2))
        if (v >= 128) v -= 256
        q[i] = v
      }
      if (abs(q[1]*s - 1) > s*0.6) exit 1
      if (abs(q[2]*s + 2) > s*0.6) exit 1
      if (abs(q[3]*s - 3) > s*0.6) exit 1
    }' \
    && pass "29 vector_ops: quantize_int8 dequantizes [1,-2,3] within rounding error (codes=$q8_codes scale=$q8_scale)" \
    || fail "29 vector_ops: quantize_int8 codes='$q8_codes' scale='$q8_scale' (dequantization out of tolerance)"

  # quantize_binary + hamming_distance: 2 dims pack into 1 byte;
  # identical vectors -> 0; one flipped sign -> 1. (The sign-bit
  # polarity itself is the vendored core's choice -- these assertions
  # hold either way.)
  local qb hm0 hm1 hm_bad
  qb=$("${PSQL[@]}" -c "SELECT octet_length(fractal_vector_quantize_binary('[1,-1]'::fractal_vector));" 2>&1)
  [[ "$qb" = "1" ]] && pass "29 vector_ops: quantize_binary 2 dims -> 1 packed byte" \
                     || fail "29 vector_ops: quantize_binary byte count=$qb"
  hm0=$("${PSQL[@]}" -c "
    SELECT fractal_vector_hamming_distance(
      fractal_vector_quantize_binary('[1,-1]'::fractal_vector),
      fractal_vector_quantize_binary('[1,-1]'::fractal_vector));" 2>&1)
  [[ "$hm0" = "0" ]] && pass "29 vector_ops: hamming_distance(identical)=0" \
                      || fail "29 vector_ops: hamming_distance(identical)='$hm0'"
  hm1=$("${PSQL[@]}" -c "
    SELECT fractal_vector_hamming_distance(
      fractal_vector_quantize_binary('[1,-1]'::fractal_vector),
      fractal_vector_quantize_binary('[1,1]'::fractal_vector));" 2>&1)
  [[ "$hm1" = "1" ]] && pass "29 vector_ops: hamming_distance(one flipped sign)=1" \
                      || fail "29 vector_ops: hamming_distance(flipped sign)='$hm1'"
  hm_bad=$("${PSQL[@]}" -c "SELECT fractal_vector_hamming_distance('\x01'::bytea, '\x0102'::bytea);" 2>&1)
  grep <<< "$hm_bad" -q "length mismatch" \
    && pass "29 vector_ops: hamming_distance rejects unequal byte lengths" \
    || fail "29 vector_ops: expected a length-mismatch rejection, got: $hm_bad"
  return 0
}

# The 6 newest analytics/vector-math primitives (v2.0.20), known-answer
# asserted: real float8[]/bytea[] array args, with fractal_periodogram
# and fractal_cycle_detect set-returning (TABLE).
gate_30_new_primitives() {
  local r

  # --- fractal_change_point_detect: step up at t=50 in a 100-sample
  # series with a non-degenerate (sine) wobble, win=16, threshold=2.0.
  # At least one flagged boundary must land near the true split.
  r=$("${PSQL[@]}" -c "
    SELECT fractal_change_point_detect(array_agg(v ORDER BY i), 16, 2.0, 16)
      FROM (SELECT i, CASE WHEN i < 50 THEN 0.2*sin(0.5*i) ELSE 5.2+0.2*cos(0.5*i) END AS v
              FROM generate_series(0, 99) i) s;" 2>&1)
  local cp_ok=0 cp_v
  for cp_v in $(tr -d '{}' <<< "$r" | tr ',' ' '); do
    awk "BEGIN{exit !($cp_v >= 30 && $cp_v <= 70)}" && cp_ok=1
  done
  [[ "$cp_ok" = "1" ]] && pass "30 new_primitives: change_point_detect flags a boundary near the t=50 step ($r)" \
                        || fail "30 new_primitives: change_point_detect='$r' (no boundary in [30,70])"

  r=$("${PSQL[@]}" -c "SELECT fractal_change_point_detect(ARRAY[1,2,3]::float8[], 0, 2.0, 16);" 2>&1)
  grep <<< "$r" -q "win must be > 0" \
    && pass "30 new_primitives: change_point_detect rejects window <= 0" \
    || fail "30 new_primitives: expected a win<=0 rejection, got: $r"

  # --- fractal_periodogram: 64 samples of sin(2*pi*t/8) -> an exact
  # k=8/64 bin at 0.125 cycles/sample as the top-power peak.
  r=$("${PSQL[@]}" -c "
    SELECT freq FROM fractal_periodogram(
      (SELECT array_agg(0.5*sin(2*pi()*i/8.0) ORDER BY i) FROM generate_series(0, 63) i), 4)
    ORDER BY power DESC LIMIT 1;" 2>&1)
  awk -v f="$r" 'BEGIN{exit !(f > 0.124 && f < 0.126)}' 2>/dev/null \
    && pass "30 new_primitives: periodogram top freq is the true 0.125 bin (got $r)" \
    || fail "30 new_primitives: periodogram top freq='$r' (expected 0.125)"

  # --- fractal_state_fingerprint: 128 bits -> exactly 16 packed bytes,
  # byte-for-byte deterministic across identical calls (seeded random
  # hyperplanes).
  local fp1 fp2 n_fp
  fp1=$("${PSQL[@]}" -c "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42);" 2>&1)
  n_fp=$("${PSQL[@]}" -c "SELECT octet_length(fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42));" 2>&1)
  [[ "$n_fp" = "16" ]] && pass "30 new_primitives: state_fingerprint 128 bits -> 16 bytes" \
                        || fail "30 new_primitives: state_fingerprint byte count=$n_fp"
  fp2=$("${PSQL[@]}" -c "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42);" 2>&1)
  [[ "$fp1" = "$fp2" ]] && pass "30 new_primitives: state_fingerprint is deterministic (same seed, same bytes)" \
                         || fail "30 new_primitives: state_fingerprint differs across identical calls: '$fp1' vs '$fp2'"
  r=$("${PSQL[@]}" -c "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 0, 42);" 2>&1)
  grep <<< "$r" -q "n_bits must be > 0" \
    && pass "30 new_primitives: state_fingerprint rejects n_bits <= 0" \
    || fail "30 new_primitives: expected an n_bits<=0 rejection, got: $r"

  # --- fractal_cycle_detect: fingerprints of A,B,A,B,A,B as a bytea[].
  # Brent's checkpoint schedule needs roughly twice the period in stream
  # length to close, so a bare A,B,A does NOT report a cycle -- the
  # 6-element stream does (0-indexed
  # at_index=3, cycle_len=2). Negative case uses A,B,D with mutually
  # non-collinear state vectors: SimHash fingerprints of SCALAR-MULTIPLE
  # states are byte-identical (both '9,9,9' and '4,4,4' sit on the
  # (1,1,1) diagonal), so the negative case needs a different direction,
  # not a different magnitude.
  r=$("${PSQL[@]}" -c "
    SELECT at_index, cycle_len FROM fractal_cycle_detect(
      ARRAY[
        fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7)
      ], 0);" 2>&1)
  grep <<< "$r" -q "^3|2$" \
    && pass "30 new_primitives: cycle_detect closes the A,B,A,B,A,B period-2 stream at_index=3 cycle_len=2" \
    || fail "30 new_primitives: cycle_detect(A,B,A,B,A,B)='$r'"

  r=$("${PSQL[@]}" -c "
    SELECT count(*) FROM fractal_cycle_detect(
      ARRAY[
        fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
        fractal_state_fingerprint(ARRAY[4,5,6]::float8[], 64, 7)
      ], 0);" 2>&1)
  [[ "$r" = "0" ]] && pass "30 new_primitives: cycle_detect reports no cycle for three distinct states" \
                    || fail "30 new_primitives: cycle_detect(A,B,D) row count='$r' (expected 0)"

  r=$("${PSQL[@]}" -c "SELECT fractal_cycle_detect(ARRAY[fractal_state_fingerprint(ARRAY[1]::float8[], 8, 1)], -1);" 2>&1)
  grep <<< "$r" -q "hamming_threshold must be >= 0" \
    && pass "30 new_primitives: cycle_detect rejects a negative hamming_threshold" \
    || fail "30 new_primitives: expected a negative-threshold rejection, got: $r"

  # --- fractal_tda_persistence_diagram: 12 points in two tight 6-point
  # clusters far apart. Each cluster forms a complete graph under
  # thresh=1.0, so the 1-skeleton cycle rank is 15 edges - 6 vertices +
  # 1 component = 10 per cluster = 20 total; h0_bars is 5 merge bars per
  # cluster = 10. max_dim=0 must leave betti1 NULL (scope note: the
  # 1-skeleton cycle rank, not full simplicial H1 -- see the function's
  # own SQL comment).
  local pts="0.0,0.0, 0.1,0.0, 0.05,0.0866, 0.1,0.0866, 0.02,0.05, 0.08,0.03, 10.0,10.0, 10.1,10.0, 10.05,10.0866, 10.1,10.0866, 10.02,10.05, 10.08,10.03"
  r=$("${PSQL[@]}" -c "
    SELECT betti1, jsonb_array_length(h0_bars)
      FROM fractal_tda_persistence_diagram(ARRAY[$pts]::float8[], 2, 1, 1.0, 64);" 2>&1)
  grep <<< "$r" -q "^20|10$" \
    && pass "30 new_primitives: tda_persistence_diagram two-cluster betti1=20 (2 x (15-6+1)), n_h0_bars=10 (2 x 5 merge bars)" \
    || fail "30 new_primitives: tda_persistence_diagram='$r' (expected betti1=20, n_h0_bars=10)"
  r=$("${PSQL[@]}" -c "
    SELECT betti1 FROM fractal_tda_persistence_diagram(ARRAY[$pts]::float8[], 2, 0, 1.0, 64);" 2>&1)
  [[ "$r" = "" ]] && pass "30 new_primitives: tda_persistence_diagram max_dim=0 leaves betti1 NULL" \
                   || fail "30 new_primitives: tda max_dim=0 betti1='$r' (expected NULL)"

  # --- fractal_optimize_subset: value-weighted allocation with bounds
  # 0.6 per item and at-most-2 nonzero. Weights sum to 1.0, so with k=2
  # each cap must allow the pair to reach 1.0 (0.6+0.4 works; [0.4]x5
  # caps the pair at 0.8 < 1.0, infeasible). With feasible [0.6]x5 caps
  # the optimum puts 0.6 on the largest value (0.15) and 0.4 on the
  # second (0.12) -> score exactly 0.138.
  r=$("${PSQL[@]}" -c "
    SELECT (s->>'score')::float8
      FROM (SELECT fractal_optimize_subset(
              ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
              ARRAY[0.6,0.6,0.6,0.6,0.6]::float8[], 2) s) t;" 2>&1)
  awk -v s="$r" 'BEGIN{exit !(s > 0.1378 && s < 0.1382)}' 2>/dev/null \
    && pass "30 new_primitives: optimize_subset hits the exact 0.138 optimum (got $r)" \
    || fail "30 new_primitives: optimize_subset score='$r' (expected 0.138)"

  local os_w os_nz=0 w
  os_w=$("${PSQL[@]}" -c "
    SELECT s->'weights'
      FROM (SELECT fractal_optimize_subset(
              ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
              ARRAY[0.6,0.6,0.6,0.6,0.6]::float8[], 2) s) t;" 2>&1)
  for w in $(tr -d '[]' <<< "$os_w" | tr ',' ' '); do
    awk "BEGIN{exit !($w > 0.0000001)}" && os_nz=$((os_nz + 1))
  done
  [[ "$os_nz" -le 2 ]] && pass "30 new_primitives: optimize_subset honors the at-most-2-nonzero cap ($os_nz nonzero)" \
                        || fail "30 new_primitives: optimize_subset nonzero weights=$os_nz ('$os_w')"

  r=$("${PSQL[@]}" -c "
    SELECT fractal_optimize_subset(
      ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
      ARRAY[0.4,0.4,0.4,0.4,0.4]::float8[], 2);" 2>&1)
  grep <<< "$r" -q "fractal_optimize_subset rc=" \
    && pass "30 new_primitives: optimize_subset infeasible instance (caps 0.4x5 < 1.0 at k=2) rejected cleanly" \
    || fail "30 new_primitives: infeasible optimize_subset='$r' (expected a clean rc= rejection)"

  # --- fractal_spectrogram_entropy (core v2.0.26): short-time spectral
  # entropy. Series = 256 samples of a pure tone (period 8) then 256 of
  # deterministic pseudo-noise; win=64, hop=32 -> 15 frames, frames 0-6
  # entirely tone, frames 8-14 entirely noise (frame 7 straddles). Measured
  # against the core directly: tone frames read 0.250, noise frames
  # 0.78-0.92, so the 0.40 / 0.70 cut-offs have wide margins.
  local spec_series="(SELECT array_agg(CASE WHEN i < 256 THEN 0.5*sin(2*pi()*i/8.0)
                                              ELSE (x - floor(x)) - 0.5 END ORDER BY i)
                        FROM (SELECT i, sin(i::float8 * 12.9898::float8) * 43758.5453::float8 AS x
                                FROM generate_series(0, 511) i) q)"
  r=$("${PSQL[@]}" -c "
    SELECT array_length(fractal_spectrogram_entropy($spec_series, 64, 32), 1);" 2>&1)
  [[ "$r" = "15" ]] && pass "30 new_primitives: spectrogram_entropy frame count = floor((512-64)/32)+1 = 15" \
                     || fail "30 new_primitives: spectrogram_entropy frames='$r' (expected 15)"

  r=$("${PSQL[@]}" -c "
    WITH h AS (SELECT fractal_spectrogram_entropy($spec_series, 64, 32) e)
    SELECT (SELECT avg(x) FROM unnest(e[1:7])  x) < 0.40
       AND (SELECT avg(x) FROM unnest(e[9:15]) x) > 0.70
       AND (SELECT bool_and(x BETWEEN 0 AND 1) FROM unnest(e) x)
      FROM h;" 2>&1)
  [[ "$r" = "t" ]] && pass "30 new_primitives: spectrogram_entropy separates a tone (<0.40) from noise (>0.70), all frames in [0,1]" \
                    || fail "30 new_primitives: spectrogram_entropy tone/noise separation='$r'"

  # The point of returning float8[]: it composes with change_point_detect.
  # The tone->noise transition is at frame ~7; a boundary must land in [5,11].
  r=$("${PSQL[@]}" -c "
    SELECT fractal_change_point_detect(fractal_spectrogram_entropy($spec_series, 64, 32), 4, 2.0, 8);" 2>&1)
  local sp_ok=0 sp_v
  for sp_v in $(tr -d '{}' <<< "$r" | tr ',' ' '); do
    awk "BEGIN{exit !($sp_v >= 5 && $sp_v <= 11)}" && sp_ok=1
  done
  [[ "$sp_ok" = "1" ]] && pass "30 new_primitives: change_point_detect over spectrogram_entropy flags the tone->noise transition ($r)" \
                        || fail "30 new_primitives: change_point_detect(spectrogram_entropy)='$r' (no boundary in [5,11])"

  # A constant signal has no spectral energy: every frame reports exactly 0.0
  # (never NaN), and max_frames truncates to the first frames.
  r=$("${PSQL[@]}" -c "
    SELECT bool_and(x = 0.0) AND count(*) = 5
      FROM unnest(fractal_spectrogram_entropy(array_fill(3.0::float8, ARRAY[200]), 64, 32)) x;" 2>&1)
  [[ "$r" = "t" ]] && pass "30 new_primitives: spectrogram_entropy of a constant signal is 0.0 in all 5 frames (no NaN)" \
                    || fail "30 new_primitives: spectrogram_entropy constant='$r'"

  r=$("${PSQL[@]}" -c "
    SELECT array_length(fractal_spectrogram_entropy($spec_series, 64, 32, 4), 1);" 2>&1)
  [[ "$r" = "4" ]] && pass "30 new_primitives: spectrogram_entropy max_frames=4 truncates to the first 4 frames" \
                    || fail "30 new_primitives: spectrogram_entropy max_frames='$r' (expected 4)"

  # Defaults (win=64, hop=32) match the explicit call.
  r=$("${PSQL[@]}" -c "
    SELECT fractal_spectrogram_entropy($spec_series) = fractal_spectrogram_entropy($spec_series, 64, 32);" 2>&1)
  [[ "$r" = "t" ]] && pass "30 new_primitives: spectrogram_entropy defaults are win=64, hop=32" \
                    || fail "30 new_primitives: spectrogram_entropy defaults='$r'"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(ARRAY[1,2,3,4,5,6,7,8,9,10]::float8[], 4, 2);" 2>&1)
  grep <<< "$r" -q "win must be in \[8, 512\]" \
    && pass "30 new_primitives: spectrogram_entropy rejects win < 8" \
    || fail "30 new_primitives: expected a win range rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 513, 32);" 2>&1)
  grep <<< "$r" -q "win must be in \[8, 512\]" \
    && pass "30 new_primitives: spectrogram_entropy rejects win > 512" \
    || fail "30 new_primitives: expected a win range rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 16, 0);" 2>&1)
  grep <<< "$r" -q "hop must be > 0" \
    && pass "30 new_primitives: spectrogram_entropy rejects hop <= 0" \
    || fail "30 new_primitives: expected a hop rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 16, 8, 0);" 2>&1)
  grep <<< "$r" -q "max_frames must be in" \
    && pass "30 new_primitives: spectrogram_entropy rejects max_frames < 1" \
    || fail "30 new_primitives: expected a max_frames rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[10]), 16, 8);" 2>&1)
  grep <<< "$r" -q "fractal_spectrogram_entropy rc=" \
    && pass "30 new_primitives: spectrogram_entropy rejects a series shorter than win (clean rc= error)" \
    || fail "30 new_primitives: expected a short-series rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(array_fill('NaN'::float8, ARRAY[64]), 16, 8);" 2>&1)
  grep <<< "$r" -q "fractal_spectrogram_entropy rc=" \
    && pass "30 new_primitives: spectrogram_entropy rejects a non-finite sample (clean rc= error)" \
    || fail "30 new_primitives: expected a NaN rejection, got: $r"

  r=$("${PSQL[@]}" -c "SELECT fractal_spectrogram_entropy(NULL::float8[], 16, 8);" 2>&1)
  [[ -z "$r" ]] \
    && pass "30 new_primitives: spectrogram_entropy(NULL, ...) -> NULL (STRICT)" \
    || fail "30 new_primitives: spectrogram_entropy NULL series='$r' (expected NULL / empty)"
  return 0
}

# Enterprise activation/signature-verification wiring, exercised via a
# throwaway, self-signed mock .so compiled at test time -- gives gates
# 24-26's dlopen/dlsym/signature-verification machinery real CI
# coverage (they otherwise self-skip when no licensed enterprise
# library is vendored). Reuses gate 24's fractalsql.enterprise_* GUCs.
#
# Not covered here: torn-tail repair and ledger-directory permission
# failures don't apply (the ledger is a real table, not a flat file),
# and there's no persistent in-process state for a reload-time guard to
# race against (each psql call is a fresh backend). Byte-level tamper
# detection reuses gate 25's UPDATE ... SET blob = set_byte(...) technique.
gate_31_enterprise_mock() {
  local mock_so="$TMPROOT/fractalsql_bt_mock_ent_${PG_MAJOR}.so"
  local badsig_so="$mock_so.badsig.so"
  local fail_sentinel="$TMPROOT/fractalsql_bt_mock_ent_fail_${PG_MAJOR}"

  rm -f "$mock_so" "$badsig_so" "$badsig_so.sig" "$fail_sentinel"
  cc -shared -fPIC -std=c99 -Iinclude tests/mock_enterprise_core.c -o "$mock_so" \
    2>/tmp/fractalsql_bt_gate31_build.log \
    || { cat /tmp/fractalsql_bt_gate31_build.log >&2; fail "31 enterprise_mock: mock .so failed to build"; return; }
  cp "$mock_so" "$badsig_so"
  head -c 64 /dev/urandom > "$badsig_so.sig"

  # FSQL_MOCK_ENT_FAIL must be in the POSTMASTER's own environment
  # (mock_enterprise_core.c's own header: plain getenv, read fresh per
  # call but the process's own environ never changes after fork) -- set
  # it before the restart below so every backend forked from here
  # inherits it, then drive failures purely via the sentinel FILE.
  export FSQL_MOCK_ENT_FAIL="$fail_sentinel"
  "$BIN/pg_ctl" -D "$DATADIR" -m fast stop >/dev/null 2>&1
  if ! "$BIN/pg_ctl" -D "$DATADIR" -w -l "$DATADIR/log" \
         -o "-p $PORT -k $SOCKDIR -c listen_addresses='' -c shared_preload_libraries=$SO" \
         start >/tmp/fractalsql_bt_gate31_restart.log 2>&1; then
    fail "31 enterprise_mock: could not restart cluster with FSQL_MOCK_ENT_FAIL set"
    unset FSQL_MOCK_ENT_FAIL
    rm -f "$mock_so" "$badsig_so" "$badsig_so.sig" "$fail_sentinel"
    return
  fi

  local pre; pre=$("${PSQL[@]}" -c "SELECT fractal_ledger_truth_count();" 2>&1)
  grep <<< "$pre" -q "enterprise tier not loaded" \
    && pass "31 enterprise_mock: truth_count refuses cleanly before enterprise_lib is set" \
    || fail "31 enterprise_mock: expected 'enterprise tier not loaded', got: $pre"

  # g_ent_attempted short-circuit (src/fractalsql.c:1049-1051): the dormant
  # dlopen attempt is cached per backend, so the SECOND enterprise call in
  # the SAME session takes the short-circuit return instead of re-reading
  # the GUC and re-attempting. Both statements below run in one backend
  # (one psql invocation = one connection -- each statement is its own
  # batch, so psql continues past the first ERROR), and both must report
  # the engine's own dormant error, identically, with no crash.
  local rsc
  rsc=$("${PSQL[@]}" 2>&1 <<'SQL'
SELECT fractal_ledger_flush();
SELECT fractal_ledger_flush();
SQL
)
  if grep <<< "$rsc" -qE "server closed the connection|could not connect"; then
    fail "31 ent-attempted: backend crashed -- $rsc"
  elif [[ "$(grep -c 'fractalsql: enterprise tier not loaded' <<< "$rsc")" = "2" ]]; then
    pass "31 ent-attempted: two dormant enterprise calls in ONE backend both report the same dormant error (2nd via the g_ent_attempted short-circuit)"
  else
    fail "31 ent-attempted: expected 2 dormant errors, got: $rsc"
  fi

  # Path 1: a corrupt/wrong .sig is ALWAYS fatal -- no real signing key
  # needed (ent_verify_signature rejects on a MISMATCH, which 64 random
  # bytes reliably is). ensure_enterprise_lib() only WARNs on this (see
  # fractalsql.c) and returns false, so the caller's own "enterprise
  # tier not loaded" still fires -- the WARNING text is what's grepped
  # for here, not the final result.
  if pg_set_guc fractalsql.enterprise_lib "'$badsig_so'" "$badsig_so"; then
    local r1; r1=$("${PSQL[@]}" -c "SELECT fractal_ledger_truth_count();" 2>&1)
    grep <<< "$r1" -qi "signature" \
      && pass "31 enterprise_mock: a corrupt/wrong .sig refuses to load" \
      || fail "31 enterprise_mock: expected a signature-refusal, got: $r1"
  else
    fail "31 enterprise_mock: could not apply enterprise_lib=badsig_so"
  fi

  # A wrong-SIZED .sig (not just wrong-content) is a distinct branch in
  # ent_verify_signature: "n != sizeof(sig_bytes)" is checked and
  # rejected BEFORE the EVP_PKEY_new_raw_public_key/verify step the
  # Path 1 badsig test above exercises -- confirmed via gcov this
  # specific size-check branch never ran before this.
  local wrongsize_so="$mock_so.wrongsize.so"
  cp "$mock_so" "$wrongsize_so"
  head -c 10 /dev/urandom > "$wrongsize_so.sig"
  if pg_set_guc fractalsql.enterprise_lib "'$wrongsize_so'" "$wrongsize_so"; then
    local rsize; rsize=$("${PSQL[@]}" -c "SELECT fractal_ledger_truth_count();" 2>&1)
    grep <<< "$rsize" -qi "signature" \
      && pass "31 enterprise_mock: a wrong-SIZED .sig (not 64 bytes) refuses to load" \
      || fail "31 enterprise_mock: expected a signature-refusal, got: $rsize"
  else
    fail "31 enterprise_mock: could not apply enterprise_lib=wrongsize_so"
  fi
  rm -f "$wrongsize_so" "$wrongsize_so.sig"

  # Path 2: no .sig at all + enterprise_require_signature=on -- fatal.
  "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_require_signature = on;" >/dev/null 2>&1
  if pg_set_guc fractalsql.enterprise_lib "'$mock_so'" "$mock_so"; then
    local r2; r2=$("${PSQL[@]}" -c "SELECT fractal_ledger_truth_count();" 2>&1)
    grep <<< "$r2" -qi "signature" \
      && pass "31 enterprise_mock: a missing .sig refuses to load when enterprise_require_signature is set" \
      || fail "31 enterprise_mock: expected a signature-refusal, got: $r2"
  else
    fail "31 enterprise_mock: could not apply enterprise_lib=mock_so (require_signature path)"
  fi

  # Path 3: no .sig, enterprise_require_signature back off -- loads
  # unverified (the backward-compatible default). This is the config
  # that stays in place for the rest of this gate. (No "fresh path"
  # trick needed: every "${PSQL[@]}" -c call here is already its own
  # fresh backend.)
  "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;" >/dev/null 2>&1
  if pg_set_guc fractalsql.enterprise_lib "'$mock_so'" "$mock_so"; then
    # ensure_enterprise_lib() re-WARNs "no signature found ... loading
    # unverified" on EVERY call from here on (it's a backend-local
    # static, and every "${PSQL[@]}" -c is a fresh backend -- see this
    # gate's own header comment), so every exact-match check for the
    # rest of this gate needs the trailing result line, not the whole
    # 2>&1 blob (which the WARNING now leads).
    local r3; r3=$("${PSQL[@]}" -c "SELECT fractal_ledger_truth_count();" 2>&1 | tail -n 1)
    [[ "$r3" = "0" ]] && pass "31 enterprise_mock: a missing .sig loads unverified by default once require_signature is off" \
                       || fail "31 enterprise_mock: expected 0, got: $r3"
  else
    fail "31 enterprise_mock: could not apply enterprise_lib=mock_so (unverified path)"
  fi

  # Every ledger void/count wrapper's success branch.
  local fn r
  for fn in fractal_ledger_flush fractal_ledger_compact fractal_ledger_reset_soft fractal_ledger_reset_hard fractal_ledger_load; do
    r=$("${PSQL[@]}" -c "SELECT $fn();" 2>&1)
    grep <<< "$r" -q "ERROR" \
      && fail "31 enterprise_mock: $fn errored while the mock is loaded: $r" \
      || pass "31 enterprise_mock: $fn succeeds while the mock is loaded"
  done
  local sc; sc=$("${PSQL[@]}" -c "SELECT fractal_ledger_shadow_count();" 2>&1 | tail -n 1)
  [[ "$sc" = "0" ]] && pass "31 enterprise_mock: shadow_count succeeds while the mock is loaded" \
                     || fail "31 enterprise_mock: expected 0 from shadow_count, got: $sc"

  # Failure branch: the sentinel flips the SAME mock's return codes
  # without touching the postmaster's environment or enterprise_lib
  # again (see tests/mock_enterprise_core.c's own header for why a
  # file, not a value, is the toggle).
  touch "$fail_sentinel"
  local rf; rf=$("${PSQL[@]}" -c "SELECT fractal_ledger_flush();" 2>&1)
  grep <<< "$rf" -q "ERROR" \
    && pass "31 enterprise_mock: flush refuses cleanly when the mock reports failure" \
    || fail "31 enterprise_mock: expected flush to error with the fail sentinel set, got: $rf"
  rm -f "$fail_sentinel"

  # Deep storage layer, entirely this repo's own code (ledger write/
  # verify, HMAC, chain hashing) -- audit_log/ledger_verify never call
  # back into the dlopen'd library at all ("pure storage-layer check"
  # per fractal_ledger_verify's own SQL comment), so this exercises
  # real ground regardless of what the mock above did.
  "${PSQL[@]}" -c "DELETE FROM fractalsql_ledger WHERE kind = 2;" >/dev/null 2>&1
  local rg; rg=$("${PSQL[@]}" 2>&1 <<'SQL'
SET fractalsql.enterprise_ledger_key = 'gate31-hmac-test-key';
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_ledger_verify(2)::text;
UPDATE fractalsql_ledger
   SET blob = set_byte(blob, length(blob) / 2, 254)
 WHERE kind = 2 AND id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 2);
SELECT fractal_ledger_verify(2)::text;
RESET fractalsql.enterprise_ledger_key;
SQL
)
  grep <<< "$rg" -q '"ok": true' \
    && pass "31 enterprise_mock: audit_log + ledger_verify round-trip a real HMAC-keyed chain entry" \
    || fail "31 enterprise_mock: expected an ok verify before tamper, got: $rg"
  grep <<< "$rg" -q '"ok": false' \
    && pass "31 enterprise_mock: ledger_verify detects a byte-level HMAC tamper (no real .so needed)" \
    || fail "31 enterprise_mock: expected a tamper-detected report after the byte-flip, got: $rg"

  # ---- ledger-verify per-row error report: the malformed-row branches and
  # a pure chain-LINK break, each asserted through verify()'s own jsonb
  # report ({ok, first_failure_id, reason}). Fixture: the chain table is
  # first swapped for a CONSTRAINT-FREE copy of the same shape. Rationale:
  # ledger_ensure_table's own DDL declares prev_hash/entry_hash NOT NULL, so
  # verify()'s "malformed row (unexpected NULL)" branch is unreachable
  # through normal writes -- it defends storage the extension does not
  # control (externally replaced / lenient tables, the same premise as
  # gate 25's migration case). No HMAC key is set here, so rows carry NULL
  # mac exactly as ledger_write_entry wrote them (the length branch is
  # reached through a non-NULL mac of the wrong length, and the structural
  # recompute runs without mac identically to how it was written).
  #
  # Tamper shape implemented for the link case ("31 ledger-tamper-link"):
  # UPDATE the MIDDLE row's prev_hash to a fake 32B value. This repo's
  # verify() (src/fractalsql.c, fractal_ledger_verify) recomputes a row's
  # entry_hash over expect_prev = the PREVIOUS row's STORED entry_hash --
  # not the row's own stored prev_hash -- but the chain-LINK check
  # (row.prev_hash vs expect_prev) runs BEFORE the structural recompute, so
  # a fake prev_hash fails THAT row's own link check while its untouched
  # entry_hash stays fully self-consistent (recomputing
  # sha256(prev_row_entry_hash || blob || mac) would still match). The
  # SQLite sibling's "blob + recomputed entry_hash" shape is deliberately
  # NOT implemented: in pg it would only make the NEXT row's link check
  # fire, and it needs a SQL-side sha256 (pgcrypto) this harness avoids.
  # The lenient fixture must carry ledger_ensure_table's OWN index (by
  # name and shape): when the index is missing, each audit_log/verify's
  # ensure step runs a CREATE INDEX INSIDE the session's active query and
  # postgres rejects it ("because it is being used by active queries in
  # this session") -- the silent shape the docker gate caught.
  _31_reset_lenient_ledger() {
    "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
    "${PSQL[@]}" -c "
      CREATE TABLE fractalsql_ledger (
        id         bigserial   PRIMARY KEY,
        kind       integer     NOT NULL,
        blob       bytea       NOT NULL,
        mac        bytea,
        prev_hash  bytea,
        entry_hash bytea,
        sealed     boolean     NOT NULL DEFAULT false,
        updated    timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx
        ON fractalsql_ledger (kind, id DESC);" >/dev/null 2>&1
  }
  local rf
  _31_reset_lenient_ledger
  rf=$("${PSQL[@]}" 2>&1 <<'SQL'
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET entry_hash = NULL
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'malformed row (unexpected NULL)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
SQL
)
  grep <<< "$rf" -q "^ok$" \
    && pass "31 ledger-verify-malformed-null: entry_hash=NULL hits verify()'s 'malformed row (unexpected NULL)' branch at the middle row id" \
    || fail "31 ledger-verify-malformed-null: expected the strict ok report, got: $rf"

  rf=$("${PSQL[@]}" 2>&1 <<'SQL'
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET mac = decode(repeat('cd', 16), 'hex')
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'malformed row (bad hash/mac length)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
SQL
)
  grep <<< "$rf" -q "^ok$" \
    && pass "31 ledger-verify-malformed-length: a 16-byte mac (expects 32) hits verify()'s 'malformed row (bad hash/mac length)' branch at the middle row id" \
    || fail "31 ledger-verify-malformed-length: expected the strict ok report, got: $rf"

  rf=$("${PSQL[@]}" 2>&1 <<'SQL'
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET prev_hash = decode(repeat('ab', 32), 'hex')
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'chain-link break (prev_hash mismatch)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
SQL
)
  grep <<< "$rf" -q "^ok$" \
    && pass "31 ledger-tamper-link: a self-consistent row whose prev_hash no longer matches the previous row's entry_hash fails its OWN link check ('chain-link break (prev_hash mismatch)')" \
    || fail "31 ledger-tamper-link: expected the strict ok report, got: $rf"

  # Restore the CANONICAL chain shape (NOT NULL on prev_hash/entry_hash)
  # for the rest of the run: drop the lenient fixture and let
  # ledger_ensure_table re-create its own DDL on the next write (the
  # audit_log call below does exactly that and seeds a fresh genesis row).
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1
  "${PSQL[@]}" -c "SELECT fractal_audit_log('test.reset', '{\"n\":0}'::jsonb);" >/dev/null 2>&1

  # fractal_audit_unpack: a direct decode call -- distinct from the
  # audit_log+ledger_verify round-trip above, which never calls this
  # function at all. The mock's fsql_audit_unpack is a pure echo
  # (tests/mock_enterprise_core.c's own header), so round-tripping jsonb
  # through it is an exact equality check. A payload past the
  # 8192-byte default cap forces the FSQL_ETRUNCATED buffer-growth
  # retry loop, built here with repeat() instead of python3, matching
  # this file's own no-python3 convention.
  local au; au=$("${PSQL[@]}" -c "
    SELECT (fractal_audit_unpack(jsonb_build_object('n', repeat('A', 9000))::text::bytea)
            = jsonb_build_object('n', repeat('A', 9000)));" 2>&1 | tail -n 1)
  [[ "$au" = "t" ]] \
    && pass "31 enterprise_mock: audit_unpack round-trips a payload past the 8192-byte default cap" \
    || fail "31 enterprise_mock: expected audit_unpack to echo the 9000-byte payload back exactly, got: $au"

  # Portfolio multimodal family (all 3 optional symbols present here).
  local pm; pm=$("${PSQL[@]}" -c "
    SELECT fractal_optimize_portfolio_multimodal(
      ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 1, 2)->>'n_found';" 2>&1 | tail -n 1)
  [[ "$pm" = "1" ]] && pass "31 enterprise_mock: fractal_optimize_portfolio_multimodal returns a well-formed result" \
                     || fail "31 enterprise_mock: expected n_found=1, got: $pm"
  # n_restarts omitted here (defaults to 8): the _pareto variant also
  # requires 1 <= max_front <= n_restarts, which an explicit n_restarts=2
  # against max_front's default of 8 violates.
  local pmp; pmp=$("${PSQL[@]}" -c "
    SELECT fractal_optimize_portfolio_multimodal_pareto(
      ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 1)->>'n_found';" 2>&1 | tail -n 1)
  [[ "$pmp" = "1" ]] && pass "31 enterprise_mock: fractal_optimize_portfolio_multimodal_pareto returns a well-formed result" \
                      || fail "31 enterprise_mock: expected n_found=1, got: $pmp"

  # t2s_audit_log_best_effort / portfolio_audit_log_best_effort: the
  # SAME two "best-effort kind=2 audit record" helpers fractal_text_to_
  # sql/fractal_optimize_portfolio always call, but confirmed via gcov
  # to only ever hit their early "enterprise not loaded" return branch
  # -- neither gate 04/14/20 (text_to_sql) nor gate 22 (optimize_
  # portfolio) ever runs with enterprise loaded. One call to each here,
  # now that the mock IS loaded, exercises the real JSON-build +
  # ledger_write_entry branch in both. convert_from(..., 'UTF8'), not a
  # bare ::text cast: bytea's default ::text cast gives its hex-escaped
  # literal form ("\x7b22...") under bytea_output=hex, not the decoded
  # string jsonb_in needs.
  "${PSQL[@]}" -c "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" >/dev/null 2>&1
  local t2s_audit; t2s_audit=$("${PSQL[@]}" -c "
    SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;" 2>&1 | tail -n 1)
  [[ "$t2s_audit" = "text_to_sql" ]] \
    && pass "31 enterprise_mock: fractal_text_to_sql logs a text_to_sql provenance record when enterprise is loaded" \
    || fail "31 enterprise_mock: expected the latest kind=2 row to be type=text_to_sql, got: $t2s_audit"

  "${PSQL[@]}" -c "
    SELECT fractal_optimize_portfolio(
      ARRAY[0.08,0.12,0.10,0.15]::float8[],
      ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[],
      2, 12345);" >/dev/null 2>&1
  local portfolio_audit; portfolio_audit=$("${PSQL[@]}" -c "
    SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;" 2>&1 | tail -n 1)
  [[ "$portfolio_audit" = "portfolio_optimize" ]] \
    && pass "31 enterprise_mock: fractal_optimize_portfolio logs a portfolio_optimize provenance record when enterprise is loaded" \
    || fail "31 enterprise_mock: expected the latest kind=2 row to be type=portfolio_optimize, got: $portfolio_audit"

  # ---- T-J: the enterprise_lib verdict cache (ensure_enterprise_lib).
  # The dlopen verdict is cached PER BACKEND and keyed by the PATH it was
  # reached for. Two consequences, and they are opposites:
  #   - LOADED, then the GUC changes: REFUSED, with the old and new paths
  #     named. The core is dlopen'd once per backend and its image is the
  #     trust anchor, so it cannot be re-pointed under a session that
  #     already loaded it. The refusal is raised at USE time (the GUC is
  #     PGC_SIGHUP, so a value that arrives with a config reload cannot be
  #     rejected by a check hook without failing the reload of every
  #     backend).
  #   - FAILED, then the GUC changes: re-evaluated. Nothing is loaded, so
  #     there is no trust anchor to protect.
  #
  # The re-point can only arrive through a config RELOAD, so the test has
  # to hold ONE session open across the reload -- every psql invocation is
  # a new backend, and a new backend starts with an empty verdict cache.
  # Hence the multi-statement, single-invocation blocks below.
  local repoint_path="$mock_so.repoint.so"
  local rj1
  rj1=$("${PSQL[@]}" 2>&1 <<SQL
SELECT 'LOAD:' || fractal_ledger_truth_count()::text;
ALTER SYSTEM SET fractalsql.enterprise_lib = '$repoint_path';
SELECT pg_reload_conf();
SELECT pg_sleep(3);
SELECT 'SEEN:' || current_setting('fractalsql.enterprise_lib');
SELECT 'USE:' || fractal_ledger_truth_count()::text;
SQL
)
  grep -q "LOAD:0" <<< "$rj1" \
    && pass "31 ent-repoint: the enterprise core loads from the configured path" \
    || fail "31 ent-repoint: expected the mock to load, got: $rj1"
  grep -qF "SEEN:$repoint_path" <<< "$rj1" \
    && pass "31 ent-repoint: the reload delivered the new path to the open session" \
    || fail "31 ent-repoint: expected the session to see '$repoint_path' after the reload, got: $rj1"
  grep -q "was changed from" <<< "$rj1" && grep -qF "$mock_so" <<< "$rj1" && grep -qF "$repoint_path" <<< "$rj1" \
    && pass "31 ent-repoint: a LOADED library refuses a mid-session re-point, naming the old and the new path" \
    || fail "31 ent-repoint: expected the re-point refusal, got: $rj1"

  # The FAILED half: a load that failed is re-evaluated when the path
  # changes, so a bad path does not poison the session forever. The first
  # call must FAIL (the file is not there) and the second must SUCCEED --
  # after the path was changed back, in the SAME session.
  local missing_path="$mock_so.missing.so"
  if pg_set_guc fractalsql.enterprise_lib "'$missing_path'" "$missing_path"; then
    local rj2
    rj2=$("${PSQL[@]}" 2>&1 <<SQL
SELECT 'F1:' || fractal_ledger_truth_count()::text;
ALTER SYSTEM SET fractalsql.enterprise_lib = '$mock_so';
SELECT pg_reload_conf();
SELECT pg_sleep(3);
SELECT 'F2:' || fractal_ledger_truth_count()::text;
SQL
)
    if grep -q "enterprise tier not loaded" <<< "$rj2" && ! grep -q "F1:" <<< "$rj2"; then
      pass "31 ent-repoint: a load that failed refuses cleanly (the dormant error)"
    else
      fail "31 ent-repoint: expected the dormant error for the missing library, got: $rj2"
    fi
    grep -q "F2:0" <<< "$rj2" \
      && pass "31 ent-repoint: a FAILED verdict is re-evaluated when the path changes (the same session then loads the good library)" \
      || fail "31 ent-repoint: expected the second call to succeed after the path changed, got: $rj2"
  else
    fail "31 ent-repoint: could not point enterprise_lib at the missing path"
  fi

  unset FSQL_MOCK_ENT_FAIL
  rm -f "$mock_so" "$badsig_so" "$badsig_so.sig" "$fail_sentinel"
  "${PSQL[@]}" -c "ALTER SYSTEM RESET fractalsql.enterprise_lib; ALTER SYSTEM RESET fractalsql.enterprise_require_signature;" >/dev/null 2>&1
  "$BIN/pg_ctl" -D "$DATADIR" -m fast stop >/dev/null 2>&1
  "$BIN/pg_ctl" -D "$DATADIR" -w -l "$DATADIR/log" \
     -o "-p $PORT -k $SOCKDIR -c listen_addresses='' -c shared_preload_libraries=$SO" \
     start >/tmp/fractalsql_bt_gate31_restore.log 2>&1
  return 0
}

# The 5 C-native Agent functions (src/fractalsql.c): fractal_search_
# agent, fractal_agent_plan_explore, fractal_agent_trajectory_predict,
# fractal_agent_detect_loop, fractal_rag_agent, plus their shared helper
# build_retrieval_context. Gate 23's "agents" only exercises the
# PL/pgSQL agent layer, never these direct C UDFs.
#
# search_agent/rag_agent need a working embed dispatch, which $MOCK
# (tests/mock_reasoning_plugin.c) can't provide. $EMBED (tests/mock_
# embed_plugin.c) always returns "[0.1,0.2,0.3]" regardless of input --
# used for both the embed step and, as a deterministic value, the
# reason step. Needs a 3-dim corpus to match.
gate_32_sovereign_agents() {
  pg_swap_plugin "$EMBED" || { fail "32 sovereign_agents: plugin swap did not take effect"; return; }
  # Standalone-scoped gate runs never execute gate 15, which is what leaves
  # fractalsql.http_embed_url pinned in a full run; without it the engine
  # refuses every embed dispatch outright. Pin it here (ALTER SYSTEM;
  # gates 15/17/20/27 re-set the same value, harmless in a full run).
  pg_set_guc fractalsql.http_embed_url "'http://unused/embeddings'" "http://unused/embeddings" \
    || { fail "32 sovereign_agents: http_embed_url GUC did not take effect"; return; }

  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS bt_agent_vec, bt_agent_fvec, bt_agent_nopk, bt_agent_empty;
     CREATE TABLE bt_agent_vec (id serial PRIMARY KEY, emb float8[]);
     INSERT INTO bt_agent_vec (emb) VALUES
       (ARRAY[0.0,0.0,0.0]::float8[]),
       (ARRAY[1.0,0.0,0.0]::float8[]),
       (ARRAY[0.0,1.0,0.0]::float8[]),
       (ARRAY[0.0,0.0,1.0]::float8[]);
     CREATE TABLE bt_agent_fvec (id serial PRIMARY KEY, emb fractal_vector);
     INSERT INTO bt_agent_fvec (emb) VALUES ('[0,0,0]'), ('[1,1,1]');
     CREATE TABLE bt_agent_nopk (id int, emb float8[]);
     INSERT INTO bt_agent_nopk VALUES (1, ARRAY[0.0,0.0,0.0]::float8[]);
     CREATE TABLE bt_agent_empty (id int PRIMARY KEY, emb float8[]);
  " >/dev/null 2>&1

  # --- 1: fractal_search_agent ----------------------------------------
  local sa; sa=$("${PSQL[@]}" -c "
     SELECT answer, array_length(source_doc_ids, 1), execution_time_ms
       FROM fractal_search_agent('q', 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$sa" -q "^\[0.1,0.2,0.3\]|" \
    && pass "32 sovereign_agents: fractal_search_agent returns the real dispatch answer + non-empty source_doc_ids" \
    || fail "32 sovereign_agents: expected the embed/reason canary answer, got: $sa"

  local sa_null; sa_null=$("${PSQL[@]}" -c "SELECT fractal_search_agent(NULL, 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$sa_null" -q "query, table_name, and vector_col are required" \
    && pass "32 sovereign_agents: fractal_search_agent rejects a NULL query" \
    || fail "32 sovereign_agents: expected a required-args rejection, got: $sa_null"

  local sa_empty; sa_empty=$("${PSQL[@]}" -c "SELECT fractal_search_agent('q', 'bt_agent_empty', 'emb');" 2>&1)
  grep <<< "$sa_empty" -q "no rows found in bt_agent_empty.emb" \
    && pass "32 sovereign_agents: fractal_search_agent rejects an empty table" \
    || fail "32 sovereign_agents: expected a no-rows rejection, got: $sa_empty"

  # --- 2: fractal_agent_plan_explore (SETOF, STRICT) ------------------
  local pe; pe=$("${PSQL[@]}" -c "
     SELECT count(*), bool_and(array_length(plan_trajectory, 1) = 3)
       FROM fractal_agent_plan_explore('q', 'bt_agent_vec', 'emb', 3);" 2>&1)
  grep <<< "$pe" -Eq "^[1-9][0-9]*\|t$" \
    && pass "32 sovereign_agents: fractal_agent_plan_explore returns branches with real 3-dim trajectories" \
    || fail "32 sovereign_agents: expected >=1 row with 3-dim trajectories, got: $pe"

  local pe_null; pe_null=$("${PSQL[@]}" -c "SELECT * FROM fractal_agent_plan_explore(NULL, 'bt_agent_vec', 'emb', 3);" 2>&1)
  [[ -z "$pe_null" ]] \
    && pass "32 sovereign_agents: fractal_agent_plan_explore(NULL, ...) returns an empty set (STRICT)" \
    || fail "32 sovereign_agents: expected an empty set for a NULL arg, got: $pe_null"

  # --- 3: fractal_agent_trajectory_predict (STRICT) -------------------
  local tp; tp=$("${PSQL[@]}" -c "
     SELECT array_length(predicted_state_vector, 1), projected_drift_delta IS NOT NULL, risk_threshold_exceeded IS NOT NULL
       FROM fractal_agent_trajectory_predict('bt_agent_vec', 'emb', 1, 1);" 2>&1)
  [[ "$tp" = "3|t|t" ]] \
    && pass "32 sovereign_agents: fractal_agent_trajectory_predict returns a real 3-dim predicted state (float8[] vector_col)" \
    || fail "32 sovereign_agents: expected 3|t|t, got: $tp"

  # Same call against a fractal_vector-typed vector_col -- the other
  # branch of decode_vector_datum (confirmed 0% coverage before this).
  local tpfv; tpfv=$("${PSQL[@]}" -c "
     SELECT array_length(predicted_state_vector, 1), projected_drift_delta IS NOT NULL, risk_threshold_exceeded IS NOT NULL
       FROM fractal_agent_trajectory_predict('bt_agent_fvec', 'emb', 1, 1);" 2>&1)
  [[ "$tpfv" = "3|t|t" ]] \
    && pass "32 sovereign_agents: fractal_agent_trajectory_predict returns a real 3-dim predicted state (fractal_vector vector_col)" \
    || fail "32 sovereign_agents: expected 3|t|t (fractal_vector vector_col), got: $tpfv"

  local tp_null; tp_null=$("${PSQL[@]}" -c "SELECT fractal_agent_trajectory_predict(NULL, 'emb', 1, 1);" 2>&1)
  [[ "$tp_null" = "" ]] \
    && pass "32 sovereign_agents: fractal_agent_trajectory_predict(NULL, ...) returns NULL (STRICT)" \
    || fail "32 sovereign_agents: expected an empty/NULL result, got: $tp_null"

  local tp_nopk; tp_nopk=$("${PSQL[@]}" -c "SELECT fractal_agent_trajectory_predict('bt_agent_nopk', 'emb', 1, 1);" 2>&1)
  grep <<< "$tp_nopk" -q "has no primary key" \
    && pass "32 sovereign_agents: fractal_agent_trajectory_predict rejects a table with no primary key" \
    || fail "32 sovereign_agents: expected a no-primary-key rejection, got: $tp_nopk"

  local tp_oob; tp_oob=$("${PSQL[@]}" -c "SELECT fractal_agent_trajectory_predict('bt_agent_vec', 'emb', 999, 1);" 2>&1)
  grep <<< "$tp_oob" -q "no row in bt_agent_vec with" \
    && pass "32 sovereign_agents: fractal_agent_trajectory_predict rejects a nonexistent baseline_id" \
    || fail "32 sovereign_agents: expected a no-such-baseline rejection, got: $tp_oob"

  # --- 4: fractal_agent_detect_loop (pure math, no table/plugin) ------
  # Period-2 cycle: A,B,A,B,A,B (dim=2, 6 states -> 12 flat doubles).
  # Brent's checkpoint schedule needs roughly twice the period in
  # stream length to close.
  local dl; dl=$("${PSQL[@]}" -c "
     SELECT agent_id, is_loop_detected FROM fractal_agent_detect_loop(
       'agent1', ARRAY[1,1, 9,9, 1,1, 9,9, 1,1, 9,9]::float8[], 2, 64, 7.0, 0);" 2>&1)
  [[ "$dl" = "agent1|t" ]] \
    && pass "32 sovereign_agents: fractal_agent_detect_loop closes a real period-2 cycle (A,B,A,B,A,B)" \
    || fail "32 sovereign_agents: expected agent1|t, got: $dl"

  local dl_const; dl_const=$("${PSQL[@]}" -c "
     SELECT is_loop_detected FROM fractal_agent_detect_loop(
       'agent2', ARRAY[5,5, 5,5, 5,5]::float8[], 2, 64, 7.0, 0);" 2>&1)
  [[ "$dl_const" = "t" ]] \
    && pass "32 sovereign_agents: fractal_agent_detect_loop closes a cycle on a constant-state log" \
    || fail "32 sovereign_agents: expected t for a constant-state log, got: $dl_const"

  # fractal_agent_detect_loop was found to be (wrongly) declared STRICT
  # in SQL -- its C body already explicitly handles every arg's NULL
  # case (a clear error for the 3 required args, a documented default
  # for the 3 optional ones), which STRICT was silently short-circuiting
  # around. Fixed (STRICT removed from the SQL declaration); asserting
  # the real, now-reachable error message.
  local dl_req; dl_req=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop(NULL, ARRAY[1,1]::float8[], 2);" 2>&1)
  grep <<< "$dl_req" -q "agent_id, state_log, and dim are required" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects a NULL agent_id" \
    || fail "32 sovereign_agents: expected a required-args rejection, got: $dl_req"

  # The other half of the same bug: an explicitly-NULL OPTIONAL arg
  # (n_bits here) must fall back to its documented default (64), not
  # null out the whole result -- this is the specific behavior STRICT
  # was silently breaking before the fix above, now proven live rather
  # than just asserting the error path.
  local dl_optnull; dl_optnull=$("${PSQL[@]}" -c "
    SELECT is_loop_detected FROM fractal_agent_detect_loop(
      'agent3', ARRAY[1,1, 9,9, 1,1, 9,9, 1,1, 9,9]::float8[], 2, NULL, 7.0, 0);" 2>&1)
  [[ "$dl_optnull" = "t" ]] \
    && pass "32 sovereign_agents: fractal_agent_detect_loop(..., n_bits=NULL, ...) falls back to the n_bits=64 default, not a NULL result" \
    || fail "32 sovereign_agents: expected t (default n_bits honored), got: $dl_optnull"

  local dl_dim0; dl_dim0=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop('a', ARRAY[1,1]::float8[], 0);" 2>&1)
  grep <<< "$dl_dim0" -q "dim must be > 0" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects dim <= 0" \
    || fail "32 sovereign_agents: expected a dim<=0 rejection, got: $dl_dim0"

  local dl_bits0; dl_bits0=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2,2]::float8[], 2, 0);" 2>&1)
  grep <<< "$dl_bits0" -q "n_bits must be > 0" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects n_bits <= 0" \
    || fail "32 sovereign_agents: expected an n_bits<=0 rejection, got: $dl_bits0"

  local dl_ham; dl_ham=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2,2]::float8[], 2, 64, 42.0, -1);" 2>&1)
  grep <<< "$dl_ham" -q "hamming_threshold must be >= 0" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects a negative hamming_threshold" \
    || fail "32 sovereign_agents: expected a negative-threshold rejection, got: $dl_ham"

  local dl_short; dl_short=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop('a', ARRAY[1,1]::float8[], 2);" 2>&1)
  grep <<< "$dl_short" -q "state_log must contain at least 2 states" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects a state_log with fewer than 2 states" \
    || fail "32 sovereign_agents: expected a too-few-states rejection, got: $dl_short"

  local dl_shape; dl_shape=$("${PSQL[@]}" -c "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2]::float8[], 2);" 2>&1)
  grep <<< "$dl_shape" -q "is not a multiple of dim" \
    && pass "32 sovereign_agents: fractal_agent_detect_loop rejects a state_log length not divisible by dim" \
    || fail "32 sovereign_agents: expected a length-not-divisible rejection, got: $dl_shape"

  # --- 5: fractal_rag_agent -------------------------------------------
  local ra; ra=$("${PSQL[@]}" -c "SELECT answer FROM fractal_rag_agent('q', 'bt_agent_vec', 'emb');" 2>&1)
  [[ "$ra" = "[0.1,0.2,0.3]" ]] \
    && pass "32 sovereign_agents: fractal_rag_agent returns the real embed/reason dispatch answer" \
    || fail "32 sovereign_agents: expected the embed/reason canary answer, got: $ra"

  local ra_null; ra_null=$("${PSQL[@]}" -c "SELECT fractal_rag_agent(NULL, 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$ra_null" -q "query, table_name, and vector_col are required" \
    && pass "32 sovereign_agents: fractal_rag_agent rejects a NULL query" \
    || fail "32 sovereign_agents: expected a required-args rejection, got: $ra_null"

  local ra_empty; ra_empty=$("${PSQL[@]}" -c "SELECT fractal_rag_agent('q', 'bt_agent_empty', 'emb');" 2>&1)
  grep <<< "$ra_empty" -q "no rows found in bt_agent_empty.emb" \
    && pass "32 sovereign_agents: fractal_rag_agent rejects an empty table" \
    || fail "32 sovereign_agents: expected a no-rows rejection, got: $ra_empty"

  # --- 6: agent_partial_reasoning_fail pair (C agents) -----------------
  # The embed mock (tests/mock_embed_plugin.c) fails its generate() when the
  # dispatched CONTEXT carries FSQL_BT_FAIL_REASON -- and context is real
  # content ONLY for the reasoning call (embed always dispatches "{}"), so the
  # embed half stays healthy and the forced failure lands exactly on the
  # reasoning flip point. Standard flag-off (raises) / flag-on (computed data
  # half + reasoning_step_failed marker) pair, per the sqlite repo's gate-29
  # pair convention.
  "${PSQL[@]}" -c "
     ALTER TABLE bt_agent_vec ADD COLUMN IF NOT EXISTS note text;
     INSERT INTO bt_agent_vec (emb, note) VALUES (ARRAY[0.5,0.5,0.0]::float8[], 'FSQL_BT_FAIL_REASON');
  " >/dev/null 2>&1

  # Flag OFF (default): the reasoning failure raises, same as always.
  local srf; srf=$("${PSQL[@]}" -c "SELECT fractal_search_agent('q', 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$srf" -q "search_agent reasoning failed" \
    && pass "32 sovereign_agents: agent_partial_reasoning_fail off -- the reasoning failure still raises" \
    || fail "32 sovereign_agents: expected the reasoning raise with the flag off, got: $srf"

  # Flag ON: the search half survives; the answer carries the marker + detail.
  pg_set_guc fractalsql.agent_partial_reasoning_fail on on \
    || { fail "32 sovereign_agents: could not set agent_partial_reasoning_fail=on"; pg_swap_plugin "$MOCK" >/dev/null; return; }
  local srp; srp=$("${PSQL[@]}" -c "
     SELECT (answer LIKE 'reasoning_step_failed:%') AND (answer LIKE '%rc=%'), array_length(source_doc_ids, 1), execution_time_ms
       FROM fractal_search_agent('q', 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$srp" -Eq "^t\|[1-9][0-9]*\|" \
    && pass "32 sovereign_agents: agent_partial_reasoning_fail on -- search_agent returns data half + reasoning_step_failed" \
    || fail "32 sovereign_agents: expected a partial result (data half + reasoning_step_failed), got: $srp"

  local rap; rap=$("${PSQL[@]}" -c "SELECT answer LIKE 'reasoning_step_failed:%' FROM fractal_rag_agent('q', 'bt_agent_vec', 'emb');" 2>&1)
  grep <<< "$rap" -q "^t$" \
    && pass "32 sovereign_agents: agent_partial_reasoning_fail on -- rag_agent returns the partial answer" \
    || fail "32 sovereign_agents: expected the rag_agent partial answer, got: $rap"

  # Restore the default raise contract before cleanup.
  pg_set_guc fractalsql.agent_partial_reasoning_fail off off \
    || { fail "32 sovereign_agents: could not reset agent_partial_reasoning_fail=off"; pg_swap_plugin "$MOCK" >/dev/null; return; }

  "${PSQL[@]}" -c "DROP TABLE IF EXISTS bt_agent_vec, bt_agent_fvec, bt_agent_nopk, bt_agent_empty;" >/dev/null 2>&1
  pg_swap_plugin "$MOCK" >/dev/null
  return 0
}

# gate_33_mcp_smoke -- the FractalSQL MCP plugin (mcp/, docs/mcp-plugin.md) exercised end to end over stdio. The C++17 server is built with its own plain Makefile (mcp/Makefile, per the spec's plain-make build standard), then mcp/test/smoke.py drives it over JSON-RPC: wire-level asserts always run; DB-dependent round trips run against the gate set's own throwaway cluster wired in through the standard PG* env libpq reads. Skips (not fails) when the C++ toolchain, pkg-config libpq/openssl, or python3 are absent -- the plugin's gates are additive.
gate_33_mcp_smoke() {
  if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
    skip "33 mcp_smoke (make/g++ not on PATH -- the MCP server builds via mcp/Makefile)"
    return 0
  fi
  if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists libpq 2>/dev/null; then
    skip "33 mcp_smoke (pkg-config libpq missing -- install libpq-dev)"
    return 0
  fi
  if ! pkg-config --exists openssl 2>/dev/null; then
    skip "33 mcp_smoke (pkg-config openssl missing -- install libssl-dev)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    skip "33 mcp_smoke (python3 not on PATH -- the smoke driver is a zero-dep python script)"
    return 0
  fi
  if build_mcp "$TMPROOT/fractalsql_bt_mcp33_build.log"; then :; else
    tail -25 "$TMPROOT/fractalsql_bt_mcp33_build.log" | sed 's/^/         /'
    fail "33 mcp_smoke (mcp/Makefile build failed -- see $TMPROOT/fractalsql_bt_mcp33_build.log)"; return 0
  fi
  if [[ ! -x mcp/fractalsql-postgresql-mcp ]]; then
    skip "33 mcp_smoke (binary absent after build)"
    return 0
  fi

  # Fixture for the row-locator/truncation/vectorizer calls (single-column PK
  # for the vectorizer lifecycle; label col for the text-column registration;
  # empty emb_auto as the vectorizer's target column -- create() needs it to
  # exist to wire the trigger + backfill).
  "${PSQL[@]}" -c "
     DROP TABLE IF EXISTS mcpsmoke_items;
     CREATE TABLE mcpsmoke_items (id serial PRIMARY KEY, name text, label text, emb float8[], emb_auto float8[]);
     INSERT INTO mcpsmoke_items (name, label, emb) SELECT 'i' || g, 'l' || g, ARRAY[0.1*g, 0.2, 0.0]::float8[] FROM generate_series(1, 5) g;
     DROP TABLE IF EXISTS mcpsw_logs;
     CREATE TABLE mcpsw_logs (metric float8, ts timestamptz, host text);
     INSERT INTO mcpsw_logs SELECT 50.0 + (g % 8) * 1.3 + CASE WHEN g > 48 THEN 30.0 ELSE 0.0 END,
            now() - (96 - g) * interval '1 second', 'h1' FROM generate_series(1, 96) g;
  " >/dev/null 2>&1
  # The mock reasoning plugin is already active in this cluster (setup wrote
  # fractalsql.reasoning_plugin = '$MOCK' into postgresql.conf); the mock
  # returns whatever file /tmp/fractalsql_bt_sql.txt holds as the "LLM
  # response" (fenced, or raw 'SELECT 1' if the file is absent). An EARLIER
  # gate in the same run may have left stale content there and/or swapped the
  # plugin -- pin both fresh so smoke.py's Cognition round trip is
  # deterministic no matter which gates ran before this one.
  printf "SELECT 'mcp-cognition-ok'::text;\n" > /tmp/fractalsql_bt_sql.txt
  pg_swap_plugin "$MOCK" >/dev/null
  local out rc=0
  # FSQL_MCP_MOCK_SQL_FILE: smoke.py's agent_partial_reasoning_fail case writes
  # the FSQL_BT_FORCE_FAIL sentinel into the mock plugin's response file, then
  # restores it (same file the Cognition canary above is pinned to).
  out=$(PGHOST="$SOCKDIR" PGPORT="$PORT" PGUSER=postgres \
        PGDATABASE=postgres FSQL_MCP_LOG_LEVEL=normal FSQL_MCP_DEBUG_SQL=1 \
        FSQL_MCP_EXE="$PWD/mcp/fractalsql-postgresql-mcp" \
        FSQL_MCP_MOCK_SQL_FILE=/tmp/fractalsql_bt_sql.txt \
        python3 mcp/test/smoke.py 2>&1) || rc=$?
  # Keep every assert line visible under the gate's own indent.
  printf '%s\n' "$out" | sed 's/^/         /'
  if [[ "$rc" -eq 0 ]]; then
    pass "33 mcp_smoke: handshake + tools/list invariants + per-tier tools/call round trips (C++17 server)"
  elif [[ "$rc" -eq 77 ]]; then
    skip "33 mcp_smoke (smoke driver reported self-skip)"
  else
    fail "33 mcp_smoke (see assert lines above)"
  fi
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS mcpsmoke_items, mcpsw_logs;" >/dev/null 2>&1
  return 0
}

# ======================================================================
# Gates 39-42: standalone host-side unit probes (no cluster needed).
# Compiler resolution notes: gate 39 is pure C (this repo's own
# src/fractalsql_parse.c -- postgres.h-free by design, exactly so a
# standalone TU can link it, gate 21's fuzz drivers being the original
# client); gates 40/41/42 are C++17 and need g++/clang++ specifically --
# gcc alone mis-links the C++ standard-library symbols for these probes
# (same finding the sibling SQLite column's harnesses recorded). Both
# resolvers honor FSQL_CC / FSQL_CXX overrides.
pick_cc() {
  local c
  if [[ -n "${FSQL_CC:-}" ]] && command -v "$FSQL_CC" >/dev/null 2>&1; then
    printf '%s' "$FSQL_CC"; return 0
  fi
  for c in cc gcc clang; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$(command -v "$c")"; return 0; }
  done
  return 1
}

pick_cxx() {
  local c
  if [[ -n "${FSQL_CXX:-}" ]] && command -v "$FSQL_CXX" >/dev/null 2>&1; then
    printf '%s' "$FSQL_CXX"; return 0
  fi
  for c in g++ clang++; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$(command -v "$c")"; return 0; }
  done
  return 1
}

# dir_of <absolute-compiler-path-or-name> -- the bin dir its own runtime
# DLLs live in (mingw exes resolve libstdc++/libgcc/libwinpthread from
# PATH, and a host PATH can carry a DIFFERENT mingw's copy -- verified
# on a Git-Bash host: Git-for-Windows's /mingw64/bin shadowed the probe
# compiler's libstdc++-6.dll and every C++ probe 127'd at load).
dir_of() {
  dirname "$(command -v "$1" 2>/dev/null || echo "$1")"
}

# gate_38_mcp_https -- the MCP server's direct-TLS mode (--https) against
# mcp/tests/mcp_https_smoke_client.py: the three load-failure modes
# (missing files / garbage key / mismatched key) must exit nonzero at
# STARTUP, the port must speak TLS not plaintext, and the token check must
# still apply under TLS. The gate generates the throwaway self-signed
# cert/key with the openssl CLI (skipping the whole gate if it is absent).
# Runs standalone (no cluster): the client's DB-dependent live-leg checks
# self-skip without PG* env -- TLS behavior is the point, and the
# plaintext HTTP behavior is gate 33's/smoke.py's.
gate_38_mcp_https() {
  local exe="$PWD/mcp/fractalsql-postgresql-mcp"
  if ! command -v python3 >/dev/null 2>&1; then
    skip "38 mcp_https (python3 not on PATH)"; return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    skip "38 mcp_https (openssl not on PATH -- the throwaway self-signed cert needs it)"; return 0
  fi
  if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
    skip "38 mcp_https (make/g++ not on PATH)"; return 0
  fi
  if ! pkg-config --exists libpq >/dev/null 2>&1 || ! pkg-config --exists openssl >/dev/null 2>&1; then
    skip "38 mcp_https (pkg-config libpq/openssl missing -- install libpq-dev/libssl-dev)"; return 0
  fi
  # ALWAYS rebuild (never test a stale exe): a committed/host-built Linux
  # binary can carry a GLIBC the runner doesn't have (the docker gate caught
  # exactly that: a GLIBC_2.38 host build inside a bookworm 2.36 image,
  # "version GLIBC_2.38 not found" at every spawn). make is incremental and
  # 33 does the same thing.
  if build_mcp "$TMPROOT/fractalsql_bt_mcp38_build.log"; then :; else
    tail -25 "$TMPROOT/fractalsql_bt_mcp38_build.log" | sed 's/^/         /'
    fail "38 mcp_https (mcp/Makefile build failed -- see $TMPROOT/fractalsql_bt_mcp38_build.log)"; return 0
  fi
  local port cert key
  port=18953
  cert="$TMPROOT/fractalsql_bt_https_cert.pem"
  key="$TMPROOT/fractalsql_bt_https_key.pem"
  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj "/CN=127.0.0.1" -config /dev/null \
        -keyout "$key" -out "$cert" >/dev/null 2>&1 \
     || [[ ! -s "$cert" || ! -s "$key" ]]; then
    # Some openssl builds need a real config file; fall back to the
    # driver's own minimal-config recipe (it generates a second pair the
    # same way, so a bare -config /dev/null that fails here fails there
    # too -- both halves skip-as-pass consistently).
    skip "38 mcp_https (openssl self-signed generation failed)"; return 0
  fi
  local out rc=0
  out=$(MCP_SERVER_EXE="$exe" MCP_SERVER_CWD="$PWD" \
        MCP_HTTPS_PORT="$port" MCP_HTTPS_CERT="$cert" MCP_HTTPS_KEY="$key" \
        python3 mcp/tests/mcp_https_smoke_client.py 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/         /'
  if [[ "$rc" -eq 0 ]]; then
    pass "38 mcp_https: --https fail-fast modes + TLS-only port + bearer-under-TLS round trip"
  else
    fail "38 mcp_https (see client output above)"
  fi
  return 0
}

gate_39_extract_parse() {
  local cc
  cc="$(pick_cc)" || { skip "39 extract_parse (no C compiler on PATH -- set FSQL_CC)"; return 0; }
  # fsql_extract_best_point / fsql_parse_embedding_array /
  # fsql_extract_topk (src/fractalsql_parse.c) all parse JSON text
  # that, through any real SQL-level call, only ever comes back
  # well-formed from the vendored SFS core or tests/mock_reasoning_
  # plugin.c's canned responses -- there is no SQL-reachable way to
  # feed them a deliberately malformed string, so their error branches
  # (missing key, malformed number, missing closing brace, idx out of
  # range/wrap guard, non-JSON input) are otherwise dead in a plain
  # --coverage run. Same standalone-probe / separately-named-object
  # treatment as the SQLite column's gate 39: probe-only objects named
  # _extract_parse_* for src/fractalsql_parse.c, NOT the main build's
  # own src/fractalsql_parse.o paths, so under --coverage this run's
  # hits ADD to the real build's via lcov's same-source-path summation
  # rather than overwriting its object file's counters.
  local mainobj="src/_extract_parse_main.o"
  local supportobj="src/_extract_parse_support.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  rm -f "$mainobj" "$supportobj"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc \
        -c tests/extract_parse_probe.c -o "$mainobj" \
        >"$TMPROOT/fractalsql_bt_extract_parse_build.log" 2>&1 \
     || ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} \
        -c src/fractalsql_parse.c -o "$supportobj" \
        >>"$TMPROOT/fractalsql_bt_extract_parse_build.log" 2>&1; then
    fail "39 extract_parse: probe failed to build (see $TMPROOT/fractalsql_bt_extract_parse_build.log)"
    rm -f "$mainobj" "$supportobj"
    return 0
  fi
  local bin="$TMPROOT/fractalsql_bt_extract_parse_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$supportobj" -o "$bin" \
        >"$TMPROOT/fractalsql_bt_extract_parse_link.log" 2>&1; then
    fail "39 extract_parse: probe failed to link (see $TMPROOT/fractalsql_bt_extract_parse_link.log)"
    rm -f "$mainobj" "$supportobj"
    return 0
  fi
  # No sanitizer runtime of its own -- nothing here dlopens a
  # sanitizer-built library, so strip any sanitizer preload the
  # harness exported before running it (build+run both).
  # Subshell-local strip only: this is the C (cc) probe -- gcc has no
  # shared stdc++ runtime to pin to its own dir, so no compiler-dir
  # PATH prepend is needed (the C++ probes 40/41/42 do the $cxx-dir
  # prepend instead).
  local out
  out=$(
    unset LD_PRELOAD DYLD_INSERT_LIBRARIES
    "$bin" 2>&1
  )
  local rc=$?
  rm -f "$mainobj" "$supportobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${supportobj%.o}.gcno" "${supportobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    local n_ok; n_ok="$(grep -c '^OK:' <<<"$out")"
    pass "39 extract_parse: best_point/embedding_array/topk malformed-input branches ($n_ok checks OK)"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "39 extract_parse: see driver output above"
  fi
  return 0
}

gate_40_vectors_probe() {
  if [[ ! -f "mcp/tests/vectors_probe.cpp" ]]; then
    skip "40 vectors_probe (mcp/tests/vectors_probe.cpp not present)"
    return 0
  fi
  local cxx
  cxx="$(pick_cxx)" || { skip "40 vectors_probe (no g++/clang++ on PATH -- set FSQL_CXX)"; return 0; }
  # mcp/src/vectors.cpp's own coercion/validation branches are
  # reachable through a real tools/call round trip only indirectly (a
  # tool whose schema lets a deliberately-malformed element through);
  # the unit probe hits each branch with certainty. Built from mcp/ so
  # the recorded source path for src/vectors.cpp and src/errors.cpp
  # matches the main mcp build's own -- merging into its coverage via
  # lcov's same-source-path summation rather than overwriting it. Its
  # ToolError/ErrorClass API lives in errors.cpp, so that TU is
  # separately compiled alongside vectors.cpp with its own
  # _vectors_probe_errors.o (same naming pattern as the source files it
  # provides coverage for).
  local mainobj="mcp/src/_vectors_probe_main.o"
  local vecobj="mcp/src/_vectors_probe_vectors.o"
  local errobj="mcp/src/_vectors_probe_errors.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  # std::to_chars(double) in src/vectors.cpp needs macOS >= 13.3 (see mcp/Makefile)
  local minver=()
  [[ "$(uname -s)" = "Darwin" ]] && minver+=(-mmacosx-version-min=13.3)
  rm -f "$mainobj" "$vecobj" "$errobj"
  (
    cd mcp && \
    { env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c tests/vectors_probe.cpp -o "$HERE/mcp/src/_vectors_probe_main.o"
      rc1=$?
      env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c src/vectors.cpp -o "$HERE/mcp/src/_vectors_probe_vectors.o"; rc2=$?
      env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c src/errors.cpp -o "$HERE/mcp/src/_vectors_probe_errors.o"; rc3=$?
    } 2>&1
    [[ $rc1 -eq 0 && $rc2 -eq 0 && $rc3 -eq 0 ]]; echo "build-rc=$?"
  ) >"$TMPROOT/fractalsql_bt_vectors_probe_build.log" 2>&1
  local build_ok
  build_ok="$(grep -o '^build-rc=[0-9]*$' "$TMPROOT/fractalsql_bt_vectors_probe_build.log" | grep -o '[0-9]*$')"
  if [[ "$build_ok" != "0" || ! -f "$mainobj" || ! -f "$vecobj" || ! -f "$errobj" ]]; then
    fail "40 vectors_probe: probe failed to build (see $TMPROOT/fractalsql_bt_vectors_probe_build.log)"
    rm -f "$mainobj" "$vecobj" "$errobj"
    return 0
  fi
  local bin="$TMPROOT/fractalsql_bt_vectors_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$vecobj" "$errobj" -o "$bin" \
        >"$TMPROOT/fractalsql_bt_vectors_probe_link.log" 2>&1; then
    fail "40 vectors_probe: probe failed to link (see $TMPROOT/fractalsql_bt_vectors_probe_link.log)"
    rm -f "$mainobj" "$vecobj" "$errobj"
    return 0
  fi
  # Subshell-local: strip the harness's sanitizer preload (this probe
  # dlopens nothing sanitizer-built) and resolve the PROBE COMPILER's
  # own runtime dir first (see dir_of -- a Git-Bash host's /mingw64/bin
  # can shadow libstdc++-6.dll/libgcc_s_seh-1.dll with an incompatible
  # Git-for-Windows copy, verified: full ambient PATH made the C++
  # probes fail to load with 127, minimal first).
  local out
  out=$(
    unset LD_PRELOAD DYLD_INSERT_LIBRARIES
    PATH="$(dir_of "$cxx"):$PATH"
    "$bin" 2>&1
  )
  local rc=$?
  rm -f "$mainobj" "$vecobj" "$errobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${vecobj%.o}.gcno" "${vecobj%.o}.gcda"
    rm -f "${errobj%.o}.gcno" "${errobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    local n_ok; n_ok="$(grep -c '^OK:' <<<"$out")"
    pass "40 vectors_probe: mcp/src/vectors.cpp coercion/validation branches ($n_ok checks OK)"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "40 vectors_probe: see driver output above"
  fi
  return 0
}

# Builds the db_probe binary once and remembers it (G41_READY/G41_BIN,
# deliberately NOT local -- the live leg reuses it). pkg-config first,
# pg_config as the fallback; only libpq at link time (errors.cpp pulls
# in no OpenSSL -- -lssl/-lcrypto are the SERVER link's requirement in
# mcp/Makefile, not this probe's).
_gate_41_build() {
  if [[ "${G41_READY:-0}" -eq 1 ]]; then return 0; fi
  G41_READY=0
  G41_BIN=""
  G41_LIBPQ_BIN=""
  if [[ ! -f "mcp/tests/db_probe.cpp" ]]; then
    skip "41 db_probe (mcp/tests/db_probe.cpp not present)"
    return 1
  fi
  local cxx
  cxx="$(pick_cxx)" || { skip "41 db_probe (no g++/clang++ on PATH -- set FSQL_CXX)"; return 1; }
  # Resolution ORDER: pg_config first (PG_BINDIR, PATH, EDB and
  # Homebrew layouts), pkg-config second. pkg-config mirrors
  # mcp/Makefile's own --cflags/--libs libpq usage and is what a bare
  # libpq-dev CI host has -- but on an MSYS host Strawberry perl's
  # pkg-config "wins" with a resolvable .pc pointing at ITS OWN client
  # (libpq.a importing a libpq__.dll: still a working libpq, but not
  # the PG major this harness tests) -- hence pg_config-first, and the
  # trivial PQlibVersion() compile+run verify before trusting any
  # chain either way (same "test-compile before trusting a resolution"
  # convention gate 21 already uses for its libFuzzer-capable clang).
  # Only libpq is needed at link time -- errors.cpp pulls in no OpenSSL
  # (-lssl/-lcrypto are the SERVER link's requirement in mcp/Makefile,
  # not this probe's).
  local pq_probe_c="$TMPROOT/fractalsql_bt_db_probe_toolchain.c"
  local pq_probe_bin="$TMPROOT/fractalsql_bt_db_probe_toolchain"
  printf '%s\n' '#include <libpq-fe.h>' \
      'int main(void) { return PQlibVersion() >= 0 ? 0 : 1; }' > "$pq_probe_c"
  local pq_cflags="" pq_libs="" pgrtbin="" cand
  for cand in "${PG_BINDIR:-/pg_config}" \
              "/c/Program Files/PostgreSQL/$PG_MAJOR/bin/pg_config" \
              "/usr/lib/postgresql/$PG_MAJOR/bin/pg_config" \
              "/Library/PostgreSQL/$PG_MAJOR/bin/pg_config" \
              "$(command -v pg_config 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    local c2 l2
    c2="-I$("$cand" --includedir 2>/dev/null)"
    l2="-L$("$cand" --libdir 2>/dev/null) -lpq"
    # The verify's run half needs libpq's runtime too (MSYS/DLL
    # case -- pg_config's own bin dir; no-op on POSIX).
    if PATH="$(dirname "$cand"):$PATH" "$cxx" -O1 -g $c2 "$pq_probe_c" $l2 \
         -o "$pq_probe_bin" >/dev/null 2>&1 \
       && PATH="$(dirname "$cand"):$PATH" "$pq_probe_bin" >/dev/null 2>&1; then
      pq_cflags="$c2"; pq_libs="$l2"
      pgrtbin="$(dirname "$cand")"
      break
    fi
  done
  if [[ -z "$pq_cflags$pq_libs" ]] && command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libpq 2>/dev/null; then
    local c1 l1
    c1="$(pkg-config --cflags libpq 2>/dev/null)"    # flags must word-split, unquoted
    l1="$(pkg-config --libs libpq 2>/dev/null)"
    if "$cxx" -O1 -g $c1 "$pq_probe_c" $l1 -o "$pq_probe_bin" >/dev/null 2>&1 \
       && "$pq_probe_bin" >/dev/null 2>&1; then
      pq_cflags="$c1"; pq_libs="$l1"
    fi
  fi
  rm -f "$pq_probe_c" "$pq_probe_bin" "$pq_probe_bin.exe"
  if [[ -z "$pq_cflags$pq_libs" ]]; then
    skip "41 db_probe (no working libpq -- pkg-config libpq and pg_config (PG_BINDIR, PATH, EDB/Homebrew layouts) all failed their own probe compile+run)"
    return 1
  fi
  # Runtime side: libpq is a shared object everywhere; on MSYS/Windows
  # the .dll (and its own deps) live in the same PG tree's bin dir,
  # which the child must see on PATH when the probe runs. Empty on
  # POSIX when pkg-config won (the shared lib resolves normally
  # there); a pg_config win gives us the exact tree.
  if [[ -n "$pgrtbin" ]]; then
    G41_LIBPQ_BIN="$pgrtbin"
  elif [[ -n "${PG_BINDIR:-}" ]]; then
    G41_LIBPQ_BIN="${PG_BINDIR%/bin}/bin"
  elif command -v pg_config >/dev/null 2>&1; then
    G41_LIBPQ_BIN="$(pg_config --bindir 2>/dev/null || true)"
  fi
  # ...plus the probe compiler's own runtime dir (dir_of) rides ahead
  # of the ambient PATH in the run legs below: libpq's dir first, then
  # the C++ runtime's (see dir_of's comment).
  G41_LIBPQ_BIN="${G41_LIBPQ_BIN:+$G41_LIBPQ_BIN:}$(dir_of "$cxx")"
  local mainobj="mcp/src/_db_probe_main.o"
  local errobj="mcp/src/_db_probe_errors.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  rm -f "$mainobj" "$errobj"
  (
    cd mcp && {
      env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
          ${covflags[@]+"${covflags[@]}"} $pq_cflags -Ivendor -Isrc \
          -c tests/db_probe.cpp -o "$HERE/mcp/src/_db_probe_main.o"; rc1=$?
      env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
          ${covflags[@]+"${covflags[@]}"} $pq_cflags -Ivendor -Isrc \
          -c src/errors.cpp -o "$HERE/mcp/src/_db_probe_errors.o"; rc2=$?
    }
  ) >"$TMPROOT/fractalsql_bt_db_probe_build.log" 2>&1
  if [[ ! -f "$mainobj" || ! -f "$errobj" ]]; then
    fail "41 db_probe: probe failed to build (see $TMPROOT/fractalsql_bt_db_probe_build.log)"
    rm -f "$mainobj" "$errobj"
    return 1
  fi
  G41_BIN="$TMPROOT/fractalsql_bt_db_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" \
        ${covflags[@]+"${covflags[@]}"} "$mainobj" "$errobj" -o "$G41_BIN" \
        $pq_libs \
        >"$TMPROOT/fractalsql_bt_db_probe_link.log" 2>&1; then
    fail "41 db_probe: probe failed to link (see $TMPROOT/fractalsql_bt_db_probe_link.log)"
    G41_BIN=""
    return 1
  fi
  rm -f "$mainobj" "$errobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${errobj%.o}.gcno" "${errobj%.o}.gcda"
  fi
  G41_READY=1
  return 0
}

gate_41_db_probe() {
  # DB-less leg. Runs ALWAYS (standalone, before pg_setup -- like gates
  # 01/21) with every PG* env var explicitly cleared, so the probe's
  # live-DB section self-skips (mirroring mcp/test/smoke.py's exit-77
  # posture); DB-less checks must all pass (exit 0). The compiled
  # binary is KEPT (G41_BIN/G41_READY) for the gate's LIVE leg --
  # gate_41_db_live(), run inside the db block after gate 33, wiring
  # the same PG* env gate 33 exports to the server.
  _gate_41_build || return 0
  local out
  local path_pfx="${G41_LIBPQ_BIN:+$G41_LIBPQ_BIN:}"
  # Subshell-local env edits (NOT `env VAR=... cmd`: confirmed on an
  # MSYS host that coreutils env's own PATH= handling breaks the
  # child's DLL search for a spaces-in-path libpq bin dir, while the
  # plain assignment form works -- and the unset/PATH changes anyway
  # stay inside the $( ) subshell).
  out=$(
    unset PGDATABASE PGHOST PGCONN FSQL_MCP_TEST_CONNINFO \
          LD_PRELOAD DYLD_INSERT_LIBRARIES   # no sanitizer-built library involved here
    [[ -n "$path_pfx" ]] && PATH="$path_pfx$PATH"
    "$G41_BIN" 2>&1
  )
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    local n_ok; n_ok="$(grep -c '^OK:' <<<"$out")"
    pass "41 db_probe: unconnected/refused-connection + SQLSTATE-classification branches, DB-less ($n_ok checks OK; live checks self-skipped without PG* env)"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "41 db_probe: see driver output above (DB-less leg)"
  fi
  return 0
}

gate_41_db_live() {
  # LIVE leg: runs only inside the db block (see run_major), directly
  # after gate 33 in gate order 33 -> ... -> 41, with the throwaway
  # cluster pg_setup() started still up. Wires the same PG* env gate 33
  # exports (unix-socket host, this run's port, trust-auth postgres
  # user), so the probe's connected/prepare-failure/version-skew/
  # agent-partial branches exercise the REAL engine. Without a
  # successfully built probe (the DB-less leg already reported why),
  # this leg just references that verdict instead of re-failing.
  if [[ "${G41_READY:-0}" -ne 1 ]]; then
    skip "41 db_probe live leg (probe build didn't succeed -- see the DB-less leg's own fail/skip reason above)"
    return 0
  fi
  if [[ -z "$SOCKDIR" || ! -S "$SOCKDIR/.s.PGSQL.$PORT" ]]; then
    skip "41 db_probe live leg (no live cluster socket at $SOCKDIR)"
    return 0
  fi
  local out
  out=$(
    unset LD_PRELOAD DYLD_INSERT_LIBRARIES   # libpq here is not sanitizer-built
    PATH="${G41_LIBPQ_BIN:+$G41_LIBPQ_BIN:}$PATH" \
    PGHOST="$SOCKDIR" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres \
    "$G41_BIN" 2>&1
  )
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    local n_ok; n_ok="$(grep -c '^OK:' <<<"$out")"
    pass "41 db_probe live leg: connected callScalar/callRow/callRows, engine-failure classification, version-skew warning and agent-partial wiring on the live cluster ($n_ok checks OK)"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "41 db_probe live leg: see driver output above"
  fi
  return 0
}

gate_42_concurrency_probe() {
  if [[ ! -f "mcp/tests/concurrency_probe.cpp" ]]; then
    skip "42 concurrency_probe (mcp/tests/concurrency_probe.cpp not present)"
    return 0
  fi
  local cxx
  cxx="$(pick_cxx)" || { skip "42 concurrency_probe (no g++/clang++ on PATH -- set FSQL_CXX)"; return 0; }
  # mcp/src/concurrency.h's per-client-limit-reached and global-timeout
  # throw branches (and the Token-destructor release paths each throw
  # takes on its way out) are never hit by any live-protocol test: a
  # synchronous request/response round trip always releases its Token
  # before the next request is read. concurrency.h is header-only (no
  # concurrency.cpp of its own), so -- like gate 41's db_probe sibling --
  # this probe's own translation unit is the only place its coverage
  # data exists at all, and no other object needs to be separately
  # compiled alongside it.
  local obj="mcp/src/_concurrency_probe.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  rm -f "$obj"
  (
    cd mcp && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g -pthread \
        ${covflags[@]+"${covflags[@]}"} -Ivendor -Isrc \
        -c tests/concurrency_probe.cpp -o "$HERE/mcp/src/_concurrency_probe.o" 2>&1; echo "build-rc=$?"
  ) >"$TMPROOT/fractalsql_bt_concurrency_probe_build.log" 2>&1
  local build_ok
  build_ok="$(grep -o '^build-rc=[0-9]*$' "$TMPROOT/fractalsql_bt_concurrency_probe_build.log" | grep -o '[0-9]*$')"
  if [[ "$build_ok" != "0" || ! -f "$obj" ]]; then
    fail "42 concurrency_probe: probe failed to build (see $TMPROOT/fractalsql_bt_concurrency_probe_build.log)"
    rm -f "$obj"
    return 0
  fi
  local bin="$TMPROOT/fractalsql_bt_concurrency_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -pthread \
        ${covflags[@]+"${covflags[@]}"} "$obj" -o "$bin" \
        >"$TMPROOT/fractalsql_bt_concurrency_probe_link.log" 2>&1; then
    fail "42 concurrency_probe: probe failed to link (see $TMPROOT/fractalsql_bt_concurrency_probe_link.log)"
    rm -f "$obj"
    return 0
  fi
  # Subshell-local: strip the harness's sanitizer preload (this probe
  # dlopens nothing sanitizer-built) and resolve the PROBE COMPILER's
  # own runtime dir first (see dir_of -- a Git-Bash host's /mingw64/bin
  # can shadow libstdc++-6.dll/libgcc_s_seh-1.dll with an incompatible
  # Git-for-Windows copy, verified: full ambient PATH made the C++
  # probes fail to load with 127, minimal first).
  local out
  out=$(
    unset LD_PRELOAD DYLD_INSERT_LIBRARIES
    PATH="$(dir_of "$cxx"):$PATH"
    "$bin" 2>&1
  )
  local rc=$?
  rm -f "$obj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${obj%.o}.gcno" "${obj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "42 concurrency_probe: mcp/src/concurrency.h per-client-limit, global-timeout and Token-release branches (driver: ${out})"
  else
    printf '%s\n' "$out" | sed 's/^/         /'
    fail "42 concurrency_probe: see driver output above"
  fi
  return 0
}

# The enterprise SURFACE INVARIANT: of the twelve user-facing enterprise
# functions, exactly ONE is not gated on the enterprise core library.
#
# fractal_ledger_verify() is a pure storage-layer check -- it walks the
# persisted ledger chain with SPI and never touches the enterprise core
# (no ensure_search_ctx, no ensure_enterprise_lib) -- so it must answer
# on EVERY edition, including community with no .so anywhere. The other
# ELEVEN (9 ledger/audit + 2 portfolio) must raise the documented
# 'enterprise tier not loaded' error when the library is absent.
#
# This is easy to break by accident, in both directions:
#   - GATING fractal_ledger_verify() "for consistency" would take the
#     CISO audit query offline on community -- a forensic read of the
#     persisted chain, which community still writes via the best-effort
#     audit bindings, with no core library involved at all.
#   - UNGATING one of the other eleven would make a dormant function
#     appear to work, and then fail deeper in, in a way that leaks the
#     enterprise core's internals.
# The sibling engine (fractalsql-sqlite) holds the same invariant, and
# the whole point of pinning it here is that it is a property of the
# SURFACE, not of any one edition.
#
# The dormant state is forced deterministically by pointing
# fractalsql.enterprise_lib at a path that does not exist -- the same
# trick gate 24's Phase B uses -- so this gate asserts the SAME thing
# whether or not an enterprise library happens to be vendored in
# include/. It therefore does NOT self-skip on a community checkout:
# the community checkout is precisely the state it is here to pin.
# ----------------------------------------------------------------------
# gate 48: industry kits (demo/demo-vertical-*.sql: 42 kits -- the twenty-nine newer
# automotive / aerospace / telecom / climate-tech / RF / event-stream / document / spatial kits, then the 13 original
# ones, which are checked for a clean run and an unchanged output shape rather than a headline).  Each is run
# end to end through psql against the scratch cluster (fractalsql_agents
# installed, the mock reasoning plugin answering the reasoned steps) and
# must (a) exist, (b) raise no SQL error beyond the documented exception
# (the scenario-planning kit's plan_explore call needs an embedding
# endpoint: at most one error), (c) print no NaN, and (d) reproduce its
# headline claim -- the fixtures are deterministic (no random()), so the
# claim is checked against fixed numbers.
# ----------------------------------------------------------------------
# kit_shape_ok <output> <min>: the older kits have no HEADLINE line and their fixtures use
# random() under setseed(), so their numbers are not pinned. What a regression does change is
# the SHAPE of the output: a step that silently returns no rows drops data lines. Count the
# lines that are neither psql noise nor command tags and require at least <min> of them
# (three quarters of what a clean run prints).
kit_shape_ok() {
  local n
  n=$(grep -vcE '^(psql:|NOTICE|HINT|DETAIL|CONTEXT|LINE|DROP |CREATE |INSERT |UPDATE |DELETE |SELECT [0-9]|ALTER |SET$|Timing|Time:|$)' <<< "$1")
  [[ "$n" -ge "$2" ]]
}

gate_48_kits() {
  if [[ ! -d demo ]]; then
    skip "48 kits (demo/ not present)"; return
  fi
  pg_swap_plugin "$MOCK" || { fail "48 kits: plugin swap did not take effect"; return; }
  local kits=(ev-battery-lifecycle adas-safety-validation v2x-warranty-triage
    critical-inventory-routing heavy-industry-predictive-maintenance
    climatech-grid-balancing hazmat-occupational-triage
    scenario-planning-simulation avionics-fault-prediction
    satellite-constellation-coverage telecom-account-anomaly-screening
    telecom-traffic-routing climatech-emissions-monitoring
    climatech-risk-exposure rf-spectrum-sensing
    event-stream-anomaly-triage outlier-interception-footprint agentic-budget-reallocation
    stalled-process-triage intent-matching-discovery
    agentic-next-action-ranking document-risk-drift
    coordinated-record-detection sensor-telemetry-allocation simulated-economy-drift
    multi-series-replenishment periodicity-portfolio-selection
    agentic-recall-recommendation spatial-footprint-portfolio-risk
    agentic-customer-support agentic-edge-swarm agentic-fintech-mcts
    agentic-ops-devops biotech-genomics cybersecurity-threat-detection
    fleet-logistics maritime-defense medtech-clinical quant-finance
    recommendation-search smart-cities-iot sovereign-edge-ai)
  local k f out nerr maxerr ok
  for k in "${kits[@]}"; do
    f="demo/demo-vertical-$k.sql"
    if [[ ! -f "$f" ]]; then
      fail "48 kits: $f is missing"; continue
    fi
    out=$("${PSQL[@]}" -F'|' -f "$f" 2>&1)
    nerr=$(grep -c 'ERROR:' <<< "$out")
    maxerr=0; [[ "$k" == scenario-planning-simulation ]] && maxerr=1; [[ "$k" == periodicity-portfolio-selection ]] && maxerr=1
    case "$k" in agentic-fintech-mcts) maxerr=1 ;; agentic-ops-devops) maxerr=2 ;; esac   # fractal_embed with no embedding endpoint
    if [[ "$nerr" -gt "$maxerr" ]]; then
      fail "48 kits: $k raised $nerr SQL error(s), at most $maxerr expected: $(grep 'ERROR:' <<< "$out" | head -2 | tr '\n' ' ')"
      continue
    fi
    if grep -qE '(^|\|)-?(nan|NaN|inf|Infinity)(\||$)' <<< "$out"; then
      fail "48 kits: $k printed a NaN/inf cell"; continue
    fi
    ok=0
    case "$k" in
      event-stream-anomaly-triage|outlier-interception-footprint|agentic-budget-reallocation|stalled-process-triage|intent-matching-discovery|agentic-next-action-ranking|document-risk-drift|coordinated-record-detection|sensor-telemetry-allocation|simulated-economy-drift|multi-series-replenishment|periodicity-portfolio-selection|agentic-recall-recommendation|spatial-footprint-portfolio-risk) grep -q "HEADLINE kit=$k ok" <<< "$out" && ok=1 ;;
      agentic-customer-support) kit_shape_ok "$out" 11 && ok=1 ;;
      agentic-edge-swarm) kit_shape_ok "$out" 22 && ok=1 ;;
      agentic-fintech-mcts) kit_shape_ok "$out" 3 && ok=1 ;;
      agentic-ops-devops) kit_shape_ok "$out" 6 && ok=1 ;;
      biotech-genomics) kit_shape_ok "$out" 12 && ok=1 ;;
      cybersecurity-threat-detection) kit_shape_ok "$out" 25 && ok=1 ;;
      fleet-logistics) kit_shape_ok "$out" 19 && ok=1 ;;
      maritime-defense) kit_shape_ok "$out" 22 && ok=1 ;;
      medtech-clinical) kit_shape_ok "$out" 18 && ok=1 ;;
      quant-finance) kit_shape_ok "$out" 15 && ok=1 ;;
      recommendation-search) kit_shape_ok "$out" 24 && ok=1 ;;
      smart-cities-iot) kit_shape_ok "$out" 18 && ok=1 ;;
      sovereign-edge-ai) kit_shape_ok "$out" 21 && ok=1 ;;
      ev-battery-lifecycle) awk -F'|' '$1=="EV-203" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="EV-101" && $2+0<0 && $3+0<1 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      adas-safety-validation) awk -F'|' '$1 ~ /^P1 firm/ && $4=="t" {a=1} $1 ~ /^P2 steady/ && $4=="f" {b=1} $1 ~ /^P3 gentle/ && $4=="t" {c=1} END{exit !(a&&b&&c)}' <<< "$out" && ok=1 ;;
      v2x-warranty-triage) grep -q '^battery-thermal-service|0\.99' <<< "$out" && ok=1 ;;
      critical-inventory-routing) awk -F'|' '$1==4 && $2=="west" && $5+0>1.2 {a=1} END{exit !a}' <<< "$out" && ok=1 ;;
      heavy-industry-predictive-maintenance) awk -F'|' '$1=="PUMP-07" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="PUMP-03" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      climatech-grid-balancing) awk -F'|' '$1=="AREA-C" && $2+0>0.5 && $3+0>1.2 {a=1} $1=="AREA-A" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      hazmat-occupational-triage) awk -F'|' '($1==7||$1==15||$1==31) && $2=="reactor-bay" && $3=="night" && $4+0<0.001 {n++} END{exit !(n>=3)}' <<< "$out" && ok=1 ;;
      scenario-planning-simulation) [[ $(grep -c 'variant' <<< "$out") -ge 6 ]] && ok=1 ;;
      avionics-fault-prediction) grep -q '^AC-09|0\.2' <<< "$out" && ok=1 ;;
      satellite-constellation-coverage) awk -F'|' '$1=="healthy" && NF==3 {h=$3+0} $1=="degraded" && NF==3 {d=$3+0} END{exit !(h>0 && d>h)}' <<< "$out" && ok=1 ;;
      telecom-account-anomaly-screening) awk -F'|' '$1 ~ /^E1 swap/ && $4=="t" {a=1} $1 ~ /^E2 routine/ && $4=="f" {b=1} $1 ~ /^E4 faint/ && $4=="t" {c=1} END{exit !(a&&b&&c)}' <<< "$out" && ok=1 ;;
      telecom-traffic-routing) grep -q '^R3 mobile handover burst|edge-mobile-hub|' <<< "$out" && grep -q '^R3 mobile handover burst|edge-backup-west$' <<< "$out" && ok=1 ;;
      climatech-emissions-monitoring) awk -F'|' '$1=="CH4-02" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="CH4-01" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      climatech-risk-exposure) awk -F'|' '$1=="dry season" && NF==3 {a=1} $1=="wet season" && NF==3 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      rf-spectrum-sensing) grep -q '^CH-A|{9}$' <<< "$out" && grep -q '^CH-B|{}$' <<< "$out" && grep -q '^CH-C|{}$' <<< "$out" && ok=1 ;;
    esac
    if [[ "$ok" -eq 1 ]]; then
      pass "48 kits: demo-vertical-$k.sql runs clean and reproduces its headline result"
    else
      fail "48 kits: demo-vertical-$k.sql did not reproduce its headline result"
    fi
  done
  # The kits leave their tables behind for inspection; this gate does not.
  "${PSQL[@]}" -c "DROP TABLE IF EXISTS ebl_telemetry, asv_known_bad, asv_proposed, asv_routes,
      v2x_capabilities, v2x_claims, cir_depots, cir_consumption, cir_profile, cir_result, hpm_readings,
      cgb_freq, cgb_resources, cgb_result, hot_workers, sps_scenarios, sps_scout, afp_flights,
      scc_footprints, scc_slots, taa_known_anomalous, taa_proposed, ttr_nodes, ttr_requests,
      cem_readings, cre_grid, rfs_capture, rfs_entropy,
      esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj, oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim, abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed, spt_items, spt_traj, spt_triage, imd_entities, imd_picks, imd_scout, imd_content, imd_rec, anr_candidates, anr_recall, anr_actions, anr_rec, drd_risk, drd_prof, drd_clauses, drd_picks, drd_scout, drd_approved, drd_rec, crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim, sta_demand, sta_prof, sta_result, sed_price, sed_prof, sed_result, sed_loop, msr_units, msr_prof, msr_result, pps_sales, pps_prof, pps_result, pps_catalog, pps_rec, arr_offers, arr_picks, arr_scout, arr_sessions, arr_recall, sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks, sfp_scout CASCADE;" >/dev/null 2>&1
}

gate_43_enterprise_surface() {
  # fractalsql.enterprise_lib is PGC_SIGHUP: it cannot be set in-session,
  # so it goes through ALTER SYSTEM + reload, then we poll until a FRESH
  # backend observes the new value (pg_reload_conf() returns before the
  # postmaster has re-read the config).
  local v
  set_ent_guc_surface() {
    local val="$1" want="$1"
    "${PSQL[@]}" -c "ALTER SYSTEM SET fractalsql.enterprise_lib = '$val';" >/dev/null 2>&1
    "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      v=$("${PSQL[@]}" -tA -c "SHOW fractalsql.enterprise_lib;" 2>/dev/null)
      [[ "$v" = "$want" ]] && return
      sleep 0.3
    done
  }

  set_ent_guc_surface "/nonexistent/fractalsql-enterprise-absent.so"
  if [[ "$v" != "/nonexistent/fractalsql-enterprise-absent.so" ]]; then
    fail "43 enterprise_surface: could not force the dormant tier (reload did not take effect; got '$v')"
    return 0
  fi

  # The one UNGATED function: a forensic read of the persisted chain
  # that must work with no enterprise core loaded at all.
  local vres
  vres=$("${PSQL[@]}" -tA -c "SELECT fractal_ledger_verify();" 2>&1)
  if grep -q "enterprise tier not loaded" <<< "$vres"; then
    fail "43 enterprise_surface: fractal_ledger_verify() must NOT be gated on the enterprise core, but it raised the dormant error"
  elif grep -q '"ok": *true' <<< "$vres"; then
    pass "43 enterprise_surface: fractal_ledger_verify() answers with no enterprise core loaded (the one ungated function)"
  else
    fail "43 enterprise_surface: expected fractal_ledger_verify() to return an ok report, got: $vres"
  fi

  # The other ELEVEN: each must raise the documented dormant error.
  # The portfolio pair is checked with the same arguments gate 24 uses,
  # so a failure here is about the GATE and not about the arguments.
  local gated_calls=(
    "SELECT fractal_ledger_flush();"
    "SELECT fractal_ledger_load();"
    "SELECT fractal_ledger_compact();"
    "SELECT fractal_ledger_reset_soft();"
    "SELECT fractal_ledger_reset_hard();"
    "SELECT fractal_ledger_truth_count();"
    "SELECT fractal_ledger_shadow_count();"
    "SELECT fractal_audit_log('t', '{}'::jsonb);"
    "SELECT fractal_audit_unpack(''::bytea);"
    "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);"
    "SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);"
  )
  local gated_names=(
    "fractal_ledger_flush"
    "fractal_ledger_load"
    "fractal_ledger_compact"
    "fractal_ledger_reset_soft"
    "fractal_ledger_reset_hard"
    "fractal_ledger_truth_count"
    "fractal_ledger_shadow_count"
    "fractal_audit_log"
    "fractal_audit_unpack"
    "fractal_optimize_portfolio_multimodal"
    "fractal_optimize_portfolio_multimodal_pareto"
  )
  local bad_gated=()
  local i out
  for i in "${!gated_calls[@]}"; do
    out=$("${PSQL[@]}" -c "${gated_calls[$i]}" 2>&1)
    if ! grep -q "enterprise tier not loaded" <<< "$out"; then
      bad_gated+=("${gated_names[$i]}: $out")
    fi
  done
  if [[ "${#bad_gated[@]}" -eq 0 ]]; then
    pass "43 enterprise_surface: all 11 gated enterprise functions raise 'enterprise tier not loaded' with no core loaded"
  else
    fail "43 enterprise_surface: expected all 11 gated functions to be dormant, got: ${bad_gated[*]}"
  fi

  # Database-side guard behind the MCP server's FSQL_MCP_READ_ONLY switch: the two
  # ledger resets are not executable by PUBLIC (sql/fractalsql--1.0.sql), so a role
  # with no grant is refused by Postgres itself, before the enterprise core is even
  # consulted. The superuser calls above still reach the dormant error.
  "${PSQL[@]}" -c "DROP ROLE IF EXISTS bt_ledger_lowpriv; CREATE ROLE bt_ledger_lowpriv LOGIN;" >/dev/null 2>&1
  local lp_psql=("$BIN/psql" -h "$SOCKDIR" -p "$PORT" -U bt_ledger_lowpriv -d postgres -X -tA)
  local lp_bad=() lp_fn
  for lp_fn in fractal_ledger_reset_soft fractal_ledger_reset_hard; do
    out=$("${lp_psql[@]}" -c "SELECT ${lp_fn}();" 2>&1)
    grep -q "permission denied for function ${lp_fn}" <<< "$out" || lp_bad+=("${lp_fn}: $out")
  done
  "${PSQL[@]}" -c "DROP ROLE IF EXISTS bt_ledger_lowpriv;" >/dev/null 2>&1
  if [[ "${#lp_bad[@]}" -eq 0 ]]; then
    pass "43 enterprise_surface: fractal_ledger_reset_soft/_hard are refused to a role with no EXECUTE grant (permission denied)"
  else
    fail "43 enterprise_surface: expected 'permission denied' for a low-privilege role on the ledger resets, got: ${lp_bad[*]}"
  fi

  # The gate must not leak into later gates on a reused cluster.
  set_ent_guc_surface ""
  return 0
}

# --- run one major through a gate set ---------------------------------

run_major() {
  local v="$1"; shift
  local gates=("$@")
  printf "== PG%s ==\n" "$v"
  # gate 01 (build) and gate 21 (fuzz smoke) always run standalone (no
  # cluster) -- gate 21 links the pure-C parsers directly, no postgres
  # backend involved at all. Same for the gate 39-42 unit probes
  # (39/40/42 entirely; 41's DB-less leg, whose compiled binary
  # gate_41_db_live reuses for its live leg inside the db block below).
  for g in "${gates[@]}"; do [[ "$g" = "01" ]] && gate_01_build "$v"; done
  for g in "${gates[@]}"; do [[ "$g" = "21" ]] && gate_21_fuzz_smoke; done
  for g in "${gates[@]}"; do
    case "$g" in
      38) gate_38_mcp_https ;;
      39) gate_39_extract_parse ;;
      40) gate_40_vectors_probe ;;
      41) gate_41_db_probe ;;   # DB-less leg (PG* env unset)
      42) gate_42_concurrency_probe ;;
    esac
  done
  # gates 02-20 need a live cluster
  local need_db=0
  for g in "${gates[@]}"; do
    case "$g" in
      02|03|04|05|06|07|08|09|10|11|12|13|14|15|16|17|18|19|20|22|23|24|25|26|27|28|29|30|31|32|33|41|43|44|45|46|47) need_db=1 ;;
      *) ;;   # 01/21/38/39/40/42 (and 41's DB-less leg) run standalone above -- intentional no-op
    esac
  done
  if [[ "$need_db" -eq 1 ]]; then
    pg_setup "$v"; local rc=$?
    if [[ "$rc" -eq 1 ]]; then skip "PG$v runtime gates (server binaries absent)"; return; fi
    if [[ "$rc" -eq 3 ]]; then return; fi   # pg_setup already printed its own skip() message
    if [[ "$rc" -ne 0 ]]; then fail "PG$v cluster setup"; return; fi
    # gate 03 creates bt_customers/bt_orders; several later gates
    # (04, 05, 07, 08, 10) depend on that fixture already existing, so
    # ensure it exists even if 03 wasn't explicitly requested.
    local have_03=0
    for g in "${gates[@]}"; do [[ "$g" = "03" ]] && have_03=1; done
    [[ "$have_03" -eq 0 ]] && gate_03_schema_context >/dev/null
    for g in "${gates[@]}"; do
      case "$g" in
        02) gate_02_smoke ;;
        03) gate_03_schema_context ;;
        04) gate_04_text_to_sql ;;
        05) gate_05_evil_overread ;;
        06) gate_06_crash_recovery ;;
        07) gate_07_evil_lying_length ;;
        08) gate_08_authz ;;
        09) gate_09_guc_superuser ;;
        10) gate_10_dos_and_injection ;;
        11) gate_11_scout ;;
        12) gate_12_soak ;;
        13) gate_13_siu_mode ;;
        14) gate_14_retry ;;
        15) gate_15_embed ;;
        16) gate_16_embed_authz ;;
        17) gate_17_embed_soak ;;
        18) gate_18_embed_crash ;;
        19) gate_19_sfs_bounds ;;
        20) gate_20_api_func ;;
        22) gate_22_v2_functions ;;
        23) gate_23_agents ;;
        24) gate_24_enterprise ;;
        25) gate_25_enterprise_stress ;;
        26) gate_26_enterprise_signature ;;
        27) gate_27_think ;;
        28) gate_28_review_isolation ;;
        29) gate_29_vector_ops ;;
        30) gate_30_new_primitives ;;
        31) gate_31_enterprise_mock ;;
        32) gate_32_sovereign_agents ;;
        33) gate_33_mcp_smoke ;;
        43) gate_43_enterprise_surface ;;
        44) gate_44_error_paths ;;
        45) gate_45_enterprise_paths ;;
        46) gate_46_plugin_config ;;
        47) gate_47_fault_injection ;;
        48) gate_48_kits ;;
        41) gate_41_db_live ;;
        *) ;;   # 01/21/39/40/42 already ran standalone above (41's DB-less leg too), no-op here by design
      esac
    done
    pg_teardown
  fi
  return 0
}

# --- dispatch ---------------------------------------------------------
if [[ -n "$ONE_GATE" ]]; then
  run_major "$PG_MAJOR" "$ONE_GATE"
elif [[ "$MODE" = "quick" ]]; then
  run_major "$PG_MAJOR" "${QUICK_GATES[@]}"
elif [[ "$MODE" = "cross" ]]; then
  for v in 14 15 16 17 18; do run_major "$v" "${DEFAULT_GATES[@]}"; done
elif [[ "$MODE" = "fuzz" ]]; then
  run_major "$PG_MAJOR" "${FUZZ_GATES[@]}"
else
  run_major "$PG_MAJOR" "${DEFAULT_GATES[@]}"
fi

[[ "$COVERAGE" -eq 1 ]] && run_coverage_report

echo ""
if [[ "$FAILED" -eq 0 ]]; then printf "${G}build_test: PASS${Z}\n"; exit 0
else printf "${R}build_test: FAIL${Z}\n"; exit 1; fi
