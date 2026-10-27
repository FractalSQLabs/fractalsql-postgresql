#!/usr/bin/env bash
# demo/run_demo.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Runs every demo/*.sql content demo against the Docker demo
# container's own Postgres database, in one pass -- the "docker compose
# up -d; pull a model; run_demo.sh" button for a from-scratch look at
# everything in demo/, instead of one
# `psql -U postgres -d fractalsql_demo -f /demo/<file>` per file.
#
# Usage (either shape works):
#   ./demo/run_demo.sh            from the host, next to docker-compose.yml
#                                 (drives the compose "postgres" service --
#                                 same shape demo-workload.sh runs in)
#   docker compose exec postgres /demo/run_demo.sh
#                                 inside the demo container itself, matching
#                                 docs/docker-demo.md's own invocation style
# Flags:
#   ./demo/run_demo.sh --quiet
#   ./demo/run_demo.sh --only demo-vertical-fleet-logistics.sql
#   ./demo/run_demo.sh --skip demo-agents.sql,enterprise-stress.sql
#   ./demo/run_demo.sh --include-response-modes
#
# Scope: this is specifically the Docker demo image's workflow. It
# assumes the compose "postgres" service (DB fractalsql_demo, user
# postgres -- docker-compose.yml's own POSTGRES_* env) with both
# extensions enabled by the image's initdb scripts, and /demo/*.sql
# (COPYd by docker/Dockerfile's demo stage). A bare host install has a
# different connection posture and a differently-named database -- run
# demos there manually per each file's own header, or docs/docker-
# demo.md's non-Docker notes.
#
# Env overrides:
#   FSQL_DEMO_CONTAINER     compose service (or container) to exec into
#                           (default: postgres -- docker-compose.yml's own
#                           service; the same target
#                           demo-workload.sh's WORKLOAD_CONTAINER names)
#   FSQL_DEMO_DB            database name (default: fractalsql_demo,
#                           the compose demo service's POSTGRES_DB)
#   FSQL_DEMO_DBUSER        psql login user (default: postgres)
#   FSQL_DEMO_RUN_LOG_DIR   per-file log directory
#                           (default: /tmp/fractalsql_demo_run)
#   FSQL_DEMO_RUN_TIMEOUT   per-file timeout in seconds (default: 300)
#
# Reasoning-dependent sections need a model pulled first (docs/docker-
# demo.md step 2); without one, those calls fail with a clean Ollama
# model-not-found error and this script counts that file as a
# non-zero-exit result, same as any other failure -- it does not
# special-case or hide that (same stance demo-workload.sh's own header
# takes).
#
# A non-zero exit from one file is a "go read its log" signal, not
# proof of a bug -- read the per-file log before assuming one. (What it
# is NOT, on this PostgreSQL column: an "error by design" exit. The
# demos' deliberate CHECK/dimension/metric failures are all caught in
# DO ... EXCEPTION blocks -- psql under ON_ERROR_STOP=1 keeps running
# after a caught error -- and the enterprise-tier demos exit
# successfully with the documented dormant-path NOTICE. So a nonzero
# exit here means a real condition to read: most commonly the
# no-model-yet error above, or response-modes.sql's ::jsonb proof
# failing when the server is not actually in json mode -- which is the
# next paragraph.)
#
# demo/response-modes.sql is SKIPPED BY DEFAULT: unlike every other
# file here, it is explicitly NOT meant to run in one `psql -f` pass --
# FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-only setting read
# once at reasoning-plugin init, so switching modes needs a server
# restart with a new environment, not just a new SQL statement (see the
# file's own header). Pass --include-response-modes to exercise it
# anyway: each of its three mode sections then runs as a SEPARATE psql
# connection with the matching env set for that one process, mirroring
# what the file's header instructs a human to do by hand (run demo.sql
# first so demo_alerts exists, then run each section's query under its
# mode). That logic duplicates response-modes.sql's three SELECT
# statements inline below (same SQL, not -f against the file) -- keep
# both in sync if that file's SQL changes. An honest PostgreSQL-side
# note: the plugin reads that env on the SERVER side, and the running
# postmaster's environment is whatever the container was started with
# -- the env set here reaches the psql/client side, never the backend
# that executes it. In the stock compose container the server stays in
# its started-with mode (text, the default) for all three passes: use
# the flag for the process-per-mode SQL shape, and to actually engage a
# non-default mode, restart the postgres service with the env set (see
# demo/response-modes.sql's header and docs/reasoning-setup.md).
#
# demo/demo-workload.sh is NOT part of this: that is a separate
# concurrent load/stress tool (p50/p95/p99 latency under sustained
# load), not a content demo -- see its own header.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRSQL="${FSQL_DEMO_CONTAINER:-postgres}"
DB="${FSQL_DEMO_DB:-fractalsql_demo}"
DBUSER="${FSQL_DEMO_DBUSER:-postgres}"
LOG_DIR="${FSQL_DEMO_RUN_LOG_DIR:-/tmp/fractalsql_demo_run}"
TIMEOUT_SECS="${FSQL_DEMO_RUN_TIMEOUT:-300}"

QUIET=0
ONLY=""
SKIP=""
INCLUDE_RESPONSE_MODES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)                  QUIET=1 ;;
    --only)                   ONLY="$2"; shift ;;
    --skip)                   SKIP="$2"; shift ;;
    --include-response-modes) INCLUDE_RESPONSE_MODES=1 ;;
    -h|--help)
      sed -n '2,89p' "$0"; exit 0 ;;
    *) echo "run_demo.sh: unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# Two invocation shapes, chosen at runtime:
#  * host side (docker + docker-compose.yml present): every file runs
#    via `docker compose exec -T` into the compose service -- /demo/
#    is baked into the image, so the exec'd psql needs no mount.
#  * inside the demo container (this script was itself exec'd, so there
#    is no docker CLI): psql talks straight to the container's own
#    postmaster over its local socket, same credentials compose sets.
COMPOSE=()
if command -v docker >/dev/null 2>&1 && [[ -f "$HERE/../docker-compose.yml" ]]; then
  # MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL: on a Git-Bash/MSYS host the
  # path-conversion layer rewrites POSIX-looking arguments (/demo/…,
  # /work/…) to Windows paths before the container ever sees them --
  # every demo file then "does not exist" INSIDE the container. The env
  # vars are ignored by real POSIX hosts, so this is the portable form.
  # BUT the -f compose-file argument itself is consumed by docker.exe on
  # the WINDOWS side and must stay a Windows-form path there (with
  # conversion off, /c/Users/... means nothing to it) -- cygpath when
  # present (msys/git-bash), the plain path otherwise.
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  compose_file="$HERE/../docker-compose.yml"
  command -v cygpath >/dev/null 2>&1 && compose_file="$(cygpath -w "$compose_file")"
  COMPOSE=(docker compose -f "$compose_file" exec -T)
elif ! command -v psql >/dev/null 2>&1; then
  echo "run_demo.sh: neither docker compose nor psql is available." >&2
  echo "Run it from the repo root next to docker-compose.yml" >&2
  echo "(./demo/run_demo.sh), or inside the demo container" >&2
  echo "(docker compose exec ${FSQL_DEMO_CONTAINER:-postgres} /demo/run_demo.sh)." >&2
  exit 2
fi

# Sanity before the loop: is the demo database actually accepting?
if [[ ${#COMPOSE[@]} -gt 0 ]]; then
  if ! "${COMPOSE[@]}" "$FRSQL" pg_isready -U "$DBUSER" >/dev/null 2>&1; then
    echo "run_demo.sh: no Postgres answering in compose service '$FRSQL'." >&2
    echo "docker compose up -d first (see docs/docker-demo.md)." >&2
    exit 2
  fi
else
  if ! pg_isready -U "$DBUSER" >/dev/null 2>&1; then
    echo "run_demo.sh: no Postgres answering here -- is this the demo" >&2
    echo "container (docker compose exec ${FSQL_DEMO_CONTAINER:-postgres}" >&2
    echo "/demo/run_demo.sh)? See this script's own header." >&2
    exit 2
  fi
fi

PSQL_BASE=(psql -U "$DBUSER" -d "$DB" -v ON_ERROR_STOP=1)

# Every single psql run goes through here: mode="" for the main loop,
# a mode name for the --include-response-modes block below (see the
# header for what that env does and does not reach on PostgreSQL).
run_psql() {
  local modeenv="$1" sqlpath="$2"
  if [[ ${#COMPOSE[@]} -gt 0 ]]; then
    if [[ -n "$modeenv" ]]; then
      timeout "$TIMEOUT_SECS" "${COMPOSE[@]}" \
        -e "FSQL_REASONING_HTTP_RESPONSE_MODE=$modeenv" \
        "$FRSQL" "${PSQL_BASE[@]}" -f "$sqlpath"
    else
      timeout "$TIMEOUT_SECS" "${COMPOSE[@]}" \
        "$FRSQL" "${PSQL_BASE[@]}" -f "$sqlpath"
    fi
  else
    if [[ -n "$modeenv" ]]; then
      FSQL_REASONING_HTTP_RESPONSE_MODE="$modeenv" \
        timeout "$TIMEOUT_SECS" "${PSQL_BASE[@]}" -f "$sqlpath"
    else
      timeout "$TIMEOUT_SECS" "${PSQL_BASE[@]}" -f "$sqlpath"
    fi
  fi
}

mkdir -p "$LOG_DIR"

# response-modes.sql is handled separately below, never through the
# main loop (see this script's own header for why).
ALWAYS_SKIP="response-modes.sql"

IFS=',' read -r -a only_list <<< "$ONLY"
IFS=',' read -r -a skip_list <<< "$SKIP"

should_run() {
  local base="$1"
  [[ "$base" == "$ALWAYS_SKIP" ]] && return 1
  if [[ -n "$ONLY" ]]; then
    for o in "${only_list[@]}"; do [[ "$base" == "$o" ]] && return 0; done
    return 1
  fi
  for s in "${skip_list[@]}"; do [[ -n "$s" && "$base" == "$s" ]] && return 1; done
  return 0
}

pass=0
fail=0
declare -a failed_files=()

for sqlfile in "$HERE"/*.sql; do
  base="$(basename "$sqlfile")"
  should_run "$base" || continue
  [[ "$QUIET" -eq 1 ]] || echo "=== $base ==="
  log="$LOG_DIR/$base.log"
  if run_psql "" "/demo/$base" > "$log" 2>&1; then
    pass=$((pass + 1))
    [[ "$QUIET" -eq 1 ]] || echo "  ok ($log)"
  else
    fail=$((fail + 1))
    failed_files+=("$base")
    [[ "$QUIET" -eq 1 ]] || echo "  exit != 0 -- see $log (read the log before assuming a bug)"
  fi
done

if [[ "$INCLUDE_RESPONSE_MODES" -eq 1 ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "=== response-modes.sql (text/code/json, each its own connection + env) ==="
  for mode in text code json; do
    log="$LOG_DIR/response-modes.$mode.log"
    case "$mode" in
      text)
        # Keep these three inline in sync with demo/response-modes.sql.
        sql="SELECT fractal_reason('summarize what happened in demo_alerts in one sentence', (SELECT jsonb_agg(row_to_json(t))::text FROM (SELECT service, message, severity, created_at FROM demo_alerts) t));"
        ;;
      code)
        sql="SELECT fractal_reason('write a SQL query that selects all rows from demo_alerts where severity is critical');"
        ;;
      json)
        sql="SELECT fractal_reason('return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present', (SELECT jsonb_agg(row_to_json(t))::text FROM (SELECT severity FROM demo_alerts) t))::jsonb;"
        ;;
    esac
    logline="$log"
    if [[ ${#COMPOSE[@]} -gt 0 ]]; then
      # Same Windows-host posture as the main loop: the -f argument must be
      # the cygpath-converted form ($compose_file, hoisted in the COMPOSE
      # block above) -- a raw POSIX path means nothing to docker.exe once
      # MSYS_NO_PATHCONV=1 is exported (the main-loop fix applied here too).
      runargs=(docker compose -f "$compose_file" exec -T
               -e "FSQL_REASONING_HTTP_RESPONSE_MODE=$mode"
               "$FRSQL" "${PSQL_BASE[@]}" -c "$sql")
    else
      runargs=(env "FSQL_REASONING_HTTP_RESPONSE_MODE=$mode"
               "${PSQL_BASE[@]}" -c "$sql")
    fi
    if timeout "$TIMEOUT_SECS" "${runargs[@]}" > "$log" 2>&1; then
      pass=$((pass + 1))
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: ok ($logline)"
    else
      fail=$((fail + 1))
      failed_files+=("response-modes.sql:$mode")
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: exit != 0 -- see $logline (for json mode the ::jsonb cast errors if the server is not actually in json mode)"
    fi
  done
elif [[ "$QUIET" -eq 1 ]]; then
  :
else
  echo "(skipped response-modes.sql -- needs demo_alerts from demo.sql plus a"
  echo " per-mode env + server restart; pass --include-response-modes to run"
  echo " its three sections as separate connections, or see the file's own"
  echo " header to run it by hand)"
fi

echo
echo "=== $pass ok, $fail non-zero exit, logs in $LOG_DIR ==="
if [[ "$fail" -gt 0 ]]; then
  echo "Non-zero-exit files (read each log before assuming a bug):"
  printf '  %s\n' "${failed_files[@]}"
fi

exit 0