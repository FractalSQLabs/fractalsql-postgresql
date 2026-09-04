#!/usr/bin/env bash
# demo/demo-workload.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# A production-shaped mixed workload against the docker-compose demo --
# concurrent simulated users, each issuing a realistic MIX of calls
# (mostly cheap search, occasionally expensive reasoning) sustained
# over real wall-clock time, with p50/p95/p99 latency per operation
# type at the end.
#
# This answers a different question than demo.sql/benchmark.sql do.
# Those prove the pipeline is CORRECT (right answer, one call at a
# time). This proves it HOLDS UP -- concurrent load, sustained
# duration, a realistic operation mix, not a single-shot demo. Neither
# one substitutes for the other.
#
# Baseline hardware assumption: a self-hosted, air-gapped deployment on
# modest 2016+-era hardware with an 8-16GB GPU running the reasoning
# model locally (not a cloud GPU) -- reasoning/text-to-sql latency
# numbers from this script are only meaningful in that context. Point
# --ollama-host at real hardware in that class to get a real baseline;
# the number this script cannot manufacture for you is "is my hardware
# in that class" -- that's on you to confirm separately.
#
# Usage:
#   ./demo/demo-workload.sh
#   ./demo/demo-workload.sh --duration 300 --concurrency 10
#   ./demo/demo-workload.sh --ollama-host 192.168.1.50:11434
#   ./demo/demo-workload.sh --ollama-host 192.168.1.50:11434 --model gemma4:12b
#
# --ollama-host: point reasoning/text-to-sql/embed at a real Ollama
# instance for real numbers (temporarily edits docker-compose.yml's
# fractalsql.http_url/http_embed_url and recreates the postgres
# container). ALWAYS reverted back to the docker-compose "ollama"
# service on exit, success or failure, via the trap below -- this
# script is meant to be run repeatedly by anyone, so it must never
# leave docker-compose.yml pointed at somebody's personal LAN box.
#
# Without --ollama-host, this runs against whatever's already
# configured (e.g. --profile reasoning already up with models pulled).
# If reasoning isn't configured, reason/text-to-sql/embed calls fail
# cleanly and get counted as failures in the summary, same as any
# other error under load would be -- this script does not hide that,
# it's a real signal about what's actually working right now.
#
# Env overrides:
#   WORKLOAD_DURATION      seconds per run (default 120)
#   WORKLOAD_CONCURRENCY   concurrent simulated users (default 5)
#   WORKLOAD_CONTAINER     postgres container name (default fractalsql-postgresql-postgres-1)
#   WORKLOAD_DB / WORKLOAD_DBUSER

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DURATION="${WORKLOAD_DURATION:-120}"
CONCURRENCY="${WORKLOAD_CONCURRENCY:-5}"
CONTAINER="${WORKLOAD_CONTAINER:-fractalsql-postgresql-postgres-1}"
DB="${WORKLOAD_DB:-fractalsql_demo}"
DBUSER="${WORKLOAD_DBUSER:-postgres}"
OLLAMA_HOST=""
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)     DURATION="$2"; shift ;;
    --concurrency)  CONCURRENCY="$2"; shift ;;
    --ollama-host)  OLLAMA_HOST="$2"; shift ;;
    --model)        MODEL="$2"; shift ;;
    -h|--help)
      sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

PSQL=(docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" -tA)
G="\033[32m"; Y="\033[33m"; Z="\033[0m"
log() { printf "%b\n" "$*"; }

# --------------------------------------------------------------------
# --ollama-host / --model: point the container's reasoning endpoint
# and/or chat model at something other than the docker-compose
# defaults, unconditionally reverted on exit (success, failure, or
# Ctrl-C) so this script can never leave docker-compose.yml pointed at
# a personal machine or a one-off model. Mirrors the exact revert this
# session already did by hand -- baked in here so nobody has to
# remember it. fractalsql.http_model covers both fractal_reason() and
# fractal_text_to_sql() (one shared chat-completions model, see
# docker-compose.yml's own command block) -- fractal_embed() always
# uses http_embed_model, untouched by --model.
# --------------------------------------------------------------------
COMPOSE_EDITED=0
revert_compose_overrides() {
  [[ "$COMPOSE_EDITED" -eq 1 ]] || return 0
  log "\n${Y}Reverting docker-compose.yml to its defaults...${Z}"
  sed -i \
    -e "s|http_url=http://${OLLAMA_HOST}|http_url=http://ollama:11434|" \
    -e "s|http_embed_url=http://${OLLAMA_HOST}|http_embed_url=http://ollama:11434|" \
    -e "s|http_model=${MODEL}|http_model=gpt-oss:20b|" \
    docker-compose.yml
  docker compose up -d --force-recreate postgres >/dev/null 2>&1
  COMPOSE_EDITED=0
}
trap revert_compose_overrides EXIT INT TERM

if [[ -n "$OLLAMA_HOST" ]] || [[ -n "$MODEL" ]]; then
  [[ -n "$OLLAMA_HOST" ]] && log "Pointing reasoning/text-to-sql/embed at $OLLAMA_HOST for this run..."
  [[ -n "$MODEL" ]] && log "Using chat model $MODEL for reason/text-to-sql this run..."
  sed_args=()
  if [[ -n "$OLLAMA_HOST" ]]; then
    sed_args+=(-e "s|http_url=http://ollama:11434|http_url=http://${OLLAMA_HOST}|")
    sed_args+=(-e "s|http_embed_url=http://ollama:11434|http_embed_url=http://${OLLAMA_HOST}|")
  fi
  if [[ -n "$MODEL" ]]; then
    sed_args+=(-e "s|http_model=gpt-oss:20b|http_model=${MODEL}|")
  fi
  sed -i "${sed_args[@]}" docker-compose.yml
  COMPOSE_EDITED=1
  if ! docker compose up -d --force-recreate postgres; then
    log "\n${Y}docker compose up failed -- see output above (a port conflict is the"
    log "usual cause, e.g. something else already bound to 5432). Aborting"
    log "before running the workload against a container that never started.${Z}"
    exit 1
  fi
  ready=0
  for _ in $(seq 1 30); do
    "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1 && { ready=1; break; }
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    log "\n${Y}postgres never became reachable within 30s of starting --"
    log "aborting before running the workload against a dead container."
    log "Check: docker logs $CONTAINER${Z}"
    exit 1
  fi
fi

# Fail fast if the target container isn't actually reachable, rather
# than let schema setup fail confusingly (or, worse, silently run the
# whole workload against nothing and report a wall of misleading
# failures -- confirmed the hard way, see docker-compose.yml revert
# above for the class of mistake this guards against).
if ! "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1; then
  log "${Y}$CONTAINER is not reachable -- is it running? (docker ps)${Z}"
  exit 1
fi

# --------------------------------------------------------------------
# Schema + seed data -- a small relational schema for text-to-sql, a
# document table for embed/vectorizer, and a vector corpus for
# Sniper/Scout. Realistic-shaped, not realistic content -- templated
# sentences/questions with real variety, not literal production text
# (that's not something this script can manufacture for you either).
# --------------------------------------------------------------------
log "Setting up workload schema (200 customers, ~1000 orders, 300 documents, 5000 vectors)..."
"${PSQL[@]}" -c "
DELETE FROM fractal_vectorizers WHERE source_table = 'wl_documents';
DROP TABLE IF EXISTS wl_orders, wl_customers, wl_documents, wl_vectors;

CREATE TABLE wl_customers (id serial PRIMARY KEY, name text NOT NULL, status text NOT NULL);
INSERT INTO wl_customers (name, status)
SELECT 'customer_' || gs, (ARRAY['active','active','active','churned'])[1 + (random()*3)::int]
FROM generate_series(1, 200) gs;

CREATE TABLE wl_orders (id serial PRIMARY KEY, customer_id int NOT NULL REFERENCES wl_customers(id),
                         total_cents int NOT NULL, status text NOT NULL, placed_at timestamptz NOT NULL);
INSERT INTO wl_orders (customer_id, total_cents, status, placed_at)
SELECT (random()*199 + 1)::int, (random()*20000 + 500)::int,
       (ARRAY['pending','paid','paid','paid','refunded'])[1 + (random()*4)::int],
       now() - (random() * interval '90 days')
FROM generate_series(1, 1000);

CREATE TABLE wl_documents (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO wl_documents (body)
SELECT (ARRAY[
    'Quarterly infrastructure review: database latency remained within SLA across all regions.',
    'Customer escalation notes: billing discrepancy resolved after reconciling the March invoice.',
    'Release notes: the search API now supports diverse retrieval alongside nearest-neighbor lookup.',
    'Incident postmortem: a connection pool exhaustion event was traced to a retry storm.',
    'Onboarding guide: new team members should start with the architecture overview document.',
    'Security review: rotated API credentials for all third-party integrations this cycle.',
    'Product feedback summary: users requested clearer error messages on failed imports.',
    'Capacity planning: projected storage growth suggests a review is needed within two quarters.'
])[1 + (random()*7)::int] || ' (doc ' || gs || ')'
FROM generate_series(1, 300) gs;

CREATE TABLE wl_vectors (id serial PRIMARY KEY, emb_arr float8[]);
INSERT INTO wl_vectors (emb_arr)
SELECT array_agg(random() * 2 - 1 ORDER BY d.dim_idx)
FROM generate_series(1, 5000) AS v(vec_id)
CROSS JOIN generate_series(1, 128) AS d(dim_idx)
GROUP BY v.vec_id;
" >/dev/null

VZID=$("${PSQL[@]}" -c "SELECT fractal_vectorizer_create('wl_documents', 'body', 'embedding');" 2>&1)
log "Vectorizer created (id=$VZID), backfilling ${G}300${Z} documents before the run starts..."
"${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue(500);" >/dev/null 2>&1

# --------------------------------------------------------------------
# Worker: sustained, weighted-random mix of operations for DURATION
# seconds. Mix approximates a real search-heavy app: cheap DB-native
# search dominates (sniper/scout/embed/insert, 90%), expensive
# LLM-backed calls are occasional (reason/text-to-sql, 10%) -- matching
# how a real app actually calls an LLM sparingly, not on every request.
# --------------------------------------------------------------------
RESULTS_DIR="/tmp/fractalsql_demo_workload_$$"
rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"

REASON_PROMPTS=(
    "summarize the current customer status distribution in one sentence"
    "what pattern, if any, is notable in recent order activity"
    "suggest one thing worth double-checking about billing data quality"
)
T2S_QUESTIONS=(
    "how many active customers are there?"
    "what is the total value of paid orders?"
    "which customers have refunded orders?"
    "how many orders were placed in the last 30 days?"
)
EMBED_TEXTS=(
    "a customer reported a billing discrepancy on their latest invoice"
    "quarterly infrastructure review shows stable database latency"
    "new release adds diverse retrieval to the search API"
)

worker() {
    local wid="$1" end_at op out lat
    end_at=$(( $(date +%s) + DURATION ))
    : > "$RESULTS_DIR/worker_$wid.log"
    while [[ "$(date +%s)" -lt "$end_at" ]]; do
        local r=$(( RANDOM % 100 ))
        if   [[ "$r" -lt 40 ]]; then op=sniper
        elif [[ "$r" -lt 55 ]]; then op=scout
        elif [[ "$r" -lt 70 ]]; then op=embed
        elif [[ "$r" -lt 80 ]]; then op=insert
        elif [[ "$r" -lt 90 ]]; then op=t2s
        else                       op=reason
        fi

        case "$op" in
            sniper)
                out=$("${PSQL[@]}" -c "\timing on" -c "
                    SELECT fractal_search(
                        ARRAY(SELECT random()*2-1 FROM generate_series(1,128))::float8[],
                        30, 30, 2);" 2>&1) ;;
            scout)
                out=$("${PSQL[@]}" -c "\timing on" -c "
                    SELECT p FROM fractal_search_explore(
                        'wl_vectors', 'emb_arr',
                        ARRAY(SELECT random()*2-1 FROM generate_series(1,128))::float8[],
                        '{\"population_size\": 20, \"iterations\": 8, \"walk\": 0}'::jsonb) AS p
                    LIMIT 20;" 2>&1) ;;
            embed)
                local txt="${EMBED_TEXTS[$((RANDOM % ${#EMBED_TEXTS[@]}))]}"
                out=$("${PSQL[@]}" -c "\timing on" -c "SELECT fractal_embed('$txt');" 2>&1) ;;
            insert)
                out=$("${PSQL[@]}" -c "\timing on" -c "
                    INSERT INTO wl_documents (body)
                    VALUES ('workload-generated note from worker $wid at ' || now());" 2>&1) ;;
            t2s)
                local q="${T2S_QUESTIONS[$((RANDOM % ${#T2S_QUESTIONS[@]}))]}"
                out=$("${PSQL[@]}" -c "\timing on" -c "
                    SELECT fractal_text_to_sql('$q', ARRAY['wl_customers','wl_orders']);" 2>&1) ;;
            reason)
                local p="${REASON_PROMPTS[$((RANDOM % ${#REASON_PROMPTS[@]}))]}"
                out=$("${PSQL[@]}" -c "\timing on" -c "SELECT fractal_reason('$p');" 2>&1) ;;
            *) ;;   # unreachable: op is set to one of the above by the if/elif chain above
        esac

        # psql prints a Time: line even when the query itself errored --
        # \timing measures statement execution wall-clock regardless of
        # outcome, it is not a success signal. Check for ERROR first, or
        # a fast dispatch failure (e.g. no chat model configured on the
        # target endpoint) silently counts as a fast "success" here,
        # which it did on a real run before this fix.
        lat=$(printf '%s' "$out" | grep -oE 'Time: [0-9.]+ ms' | grep -oE '[0-9.]+' | head -1)
        if printf '%s' "$out" | grep -q '^ERROR:'; then
            echo "$op fail 0" >> "$RESULTS_DIR/worker_$wid.log"
        elif [[ -n "$lat" ]]; then
            echo "$op ok $lat" >> "$RESULTS_DIR/worker_$wid.log"
        else
            echo "$op fail 0" >> "$RESULTS_DIR/worker_$wid.log"
        fi
    done
}

# Scheduler: drains the vectorizer queue on a fixed cadence, same as a
# real deployment's pg_cron/OS-cron job would -- not inline with user
# requests. See ../docs/vectorizer-setup.md for the real scheduling
# options this stands in for.
scheduler() {
    local end_at=$(( $(date +%s) + DURATION ))
    while [[ "$(date +%s)" -lt "$end_at" ]]; do
        sleep 5
        "${PSQL[@]}" -c "SELECT fractal_vectorizer_process_queue();" >/dev/null 2>&1
    done
}

log "\nRunning ${G}${CONCURRENCY}${Z} concurrent workers for ${G}${DURATION}s${Z}..."
log "Mix: 40% sniper / 15% scout / 15% embed / 10% insert / 10% text-to-sql / 10% reason\n"

pids=()
for w in $(seq 1 "$CONCURRENCY"); do
    worker "$w" &
    pids+=("$!")
done
scheduler &
pids+=("$!")
for p in "${pids[@]}"; do wait "$p"; done

# --------------------------------------------------------------------
# Aggregate: per-operation count, failures, and p50/p95/p99 latency
# (ms) across all workers. Percentile = sorted[ceil(p * n) - 1],
# nearest-rank method -- simple, standard, no external dependency.
# --------------------------------------------------------------------
percentile() {
    # args: sorted-values-file percentile(0-100)
    local file="$1" p="$2" n idx
    n=$(wc -l < "$file")
    [[ "$n" -eq 0 ]] && { echo "-"; return; }
    idx=$(( (p * n + 99) / 100 ))
    [[ "$idx" -lt 1 ]] && idx=1
    [[ "$idx" -gt "$n" ]] && idx="$n"
    sed -n "${idx}p" "$file"
}

log "================================================================"
log "Results (${CONCURRENCY} workers x ${DURATION}s)"
log "================================================================"
printf "%-8s %8s %8s %10s %10s %10s\n" "op" "calls" "failed" "p50 ms" "p95 ms" "p99 ms"

cat "$RESULTS_DIR"/worker_*.log > "$RESULTS_DIR/all.log" 2>/dev/null || : > "$RESULTS_DIR/all.log"
total_calls=0
total_failed=0
for op in sniper scout embed insert t2s reason; do
    n=$(awk -v o="$op" '$1==o' "$RESULTS_DIR/all.log" | wc -l)
    [[ "$n" -eq 0 ]] && continue
    nfail=$(awk -v o="$op" '$1==o && $2=="fail"' "$RESULTS_DIR/all.log" | wc -l)
    awk -v o="$op" '$1==o && $2=="ok" {print $3}' "$RESULTS_DIR/all.log" | sort -n > "$RESULTS_DIR/$op.sorted"
    p50=$(percentile "$RESULTS_DIR/$op.sorted" 50)
    p95=$(percentile "$RESULTS_DIR/$op.sorted" 95)
    p99=$(percentile "$RESULTS_DIR/$op.sorted" 99)
    printf "%-8s %8s %8s %10s %10s %10s\n" "$op" "$n" "$nfail" "$p50" "$p95" "$p99"
    total_calls=$((total_calls + n))
    total_failed=$((total_failed + nfail))
done

log ""
log "Total: $total_calls calls, $total_failed failed, $(( total_calls / DURATION )) calls/sec aggregate throughput"
if [[ "$total_failed" -eq 0 ]]; then
    log "${G}No failures under this load.${Z}"
else
    log "${Y}$total_failed calls failed -- if reasoning wasn't configured, that's expected"
    log "for reason/text-to-sql/embed; anything else is a real problem worth digging into.${Z}"
fi
log "================================================================"

rm -rf "$RESULTS_DIR"
