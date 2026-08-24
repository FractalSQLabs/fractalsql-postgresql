<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# FractalSQL demo

`demo.sql` is a runnable, five-minute walkthrough of search and
reasoning in one script: Sniper Search, Scout Discovery, and LLM
reasoning — including Scout's output feeding straight into a reasoning
call, which is the pattern the rest of the docs point at but don't show
running end to end in one place. Text-to-SQL has its own walkthrough —
see [Text-to-SQL](#text-to-sql) below.

`response-modes.sql` is a companion script for `text` / `code` / `json`
response modes — see [Response modes](#response-modes) below for why
it's a separate file from `demo.sql`.

## Prerequisites

1. **The extension is installed and enabled.** If you haven't done this
   yet, start with [../docs/getting-started.md](../docs/getting-started.md).

   ```sql
   CREATE EXTENSION fractalsql;
   ```

2. **Reasoning is configured.** Sections 0–2 of `demo.sql` only need the
   extension itself, but sections 3–4 call `fractal_reason()`, which
   needs a working LLM endpoint. Follow
   [../docs/reasoning-setup.md](../docs/reasoning-setup.md) first —
   Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, and any OpenAI-compatible
   endpoint are all documented there. Confirm it works before running this
   demo:

   ```sql
   SELECT fractal_reason('reply with a short confirmation that this connection works');
   ```

   If that errors, `demo.sql` will hit the same error at section 3 — fix
   it there first rather than debugging through the demo script.

## Running it

```sh
psql -d <your_database> -f demo/demo.sql
```

`\timing on` is set at the top, so you'll see how long each step takes —
worth watching, since the reasoning calls (sections 3–4) are the slow
part. A cloud endpoint typically responds in a few seconds; a local
Ollama model can take much longer on a cold load (see "Slow or
constrained hardware" in `reasoning-setup.md` if a call times out).

The script is safe to re-run: `demo_alerts` and `demo_embeddings` are
dropped and recreated at the start of their sections every time, so
there's no stale-state cleanup to do between runs.

## What each section shows

- **0 — Sanity check.** `fractal_edition()` / `fractal_version()`
  confirm the extension is actually loaded before anything else runs.
- **1 — Setup.** A small `demo_alerts` table with a deliberate story in
  it: a login-attempt count that escalates (3 → 3 → 17) and a latency
  spike in the last ~10 minutes. Nothing here calls the LLM yet.
- **2 — Sniper Search.** `fractal_search()` converges to a single best
  point for a query vector — the fast, precise mode. No table needed;
  it operates on the query vector alone.
- **3 — Reasoning over real data.** `fractal_reason()` gets a real
  `context` argument this time — the alerts from the last hour,
  serialized to JSON via a subquery — rather than an empty ping. Expect
  the model to notice the login-attempt escalation and the latency
  spike; exact wording varies by model and provider.
- **4 — Scout Discovery feeding reasoning.** `fractal_search_explore()`
  samples a diversity-spread population from `demo_embeddings`, and
  that population is handed to `fractal_reason()` as context in the
  same statement. This is the differentiator pattern: diversity-sampled
  context instead of a plain `WHERE` filter, in one pipeline.

## Response modes

`response-modes.sql` demonstrates `FSQL_REASONING_HTTP_RESPONSE_MODE`
(`text` / `code` / `json`) — see
[docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes-v121)
for the full explanation.

It's a **separate file from `demo.sql`**, not another section in it,
because the response mode is env-var-only and read once when the
plugin initializes — changing it needs an OS-level environment change
plus a full PostgreSQL restart, which a single `psql -f` script can't
do to itself mid-run. Run it as three manual passes instead:

1. Run `demo.sql` first if you haven't — `response-modes.sql` reuses
   its `demo_alerts` table.
2. For each mode (`text` needs no setup — it's the default):
   1. Set `FSQL_REASONING_HTTP_RESPONSE_MODE` and restart PostgreSQL.
      See "Switching modes on an already-running install" in
      [docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes-v121)
      for the exact commands on your platform.
   2. Run only that section's query from `response-modes.sql` (copy it
      into `psql`, or `psql -f` just that section) — not the whole file.

What to expect: `code` mode returns a bare SQL statement with no
prose wrapper (no "Here's a query that does that:" preamble, no
visible fence markers). `json` mode returns text that survives a
`::jsonb` cast — the script's own query includes that cast, so a
successful result is proof the plugin's extraction and validation
actually worked, not just "looks like JSON."

## Enterprise Tier — QTL & CISO Audit

`enterprise-qtl-audit.sql` exercises the enterprise-tier **Quantized Ternary
Ledger** (append-only, tamper-evident Truth/Shadow record of search/feedback
events) and **CISO audit unpack** surface. Unlike every other demo here, it
runs cleanly in **two** states and tells you which one it found:

- **Dormant (default on the Docker image):** the enterprise core library is
  not shipped with the community image, so the nine functions (eight
  `fractal_ledger_*` functions plus `fractal_audit_unpack`) are present but
  inactive. The demo seeds
  real engagement events with the community `fractal_feedback_report()`
  primitive, then the first enterprise call is caught and the demo prints a
  single `Enterprise tier not loaded` NOTICE explaining how to activate it.
  It exits successfully — safe to run on a community-only checkout or in CI.
- **Active:** with the enterprise core shared library staged in and
  `fractalsql.enterprise_lib` pointed at it (reload), the demo flushes the
  seeded ledgers to the `fractalsql_ledger` table via the Postgres storage
  VFS, decodes the persisted QTL blob back into a CISO event log, then
  exercises `load` / `compact` / `reset_soft` / `reset_hard` end to end.

```sh
psql -d <your_database> -f demo/enterprise-qtl-audit.sql
```

See the [Enterprise Tier](../README.md#-enterprise-tier--ciso-decision-audit--quantized-ternary-ledger-qtl)
section of the root README for the activation commands and the function
table. The script header has the exact Docker `compose cp` + `ALTER SYSTEM`
incantation to stage an enterprise library in and back out again.

### Enterprise Tier — Stress & Tamper-Evidence

`enterprise-stress.sql` is the companion to the audit demo above: it
hammers the same enterprise ledger surface under load. It fills the
in-memory Truth/Shadow ledgers to their **capacity bound** (64 each,
`FSQL_TRUTH/SHADOW_DEFAULT_CAP` — 128 events total with disjoint doc_ids),
round-trips them through the QTL encode → `fractalsql_ledger` table →
decode path, churns 5 flush/load cycles at capacity, and probes
**tamper-evidence** in two layers: structurally (Phase B/C — truncating the
persisted QTL blob below its 24-byte header, rejected as
`FSQL_ELEDGER_INTEGRITY`) and cryptographically (Phase D — setting
`fractalsql.enterprise_ledger_key` to HMAC-SHA256-tag the blob and flipping a
middle payload byte the structural check cannot see, rejected by the MAC on
load). Same dual-state, safe-on-community shape as the audit demo (dormant →
single NOTICE; active → all phases run clean).

> **Scope note:** by default (`fractalsql.enterprise_ledger_key` unset) the QTL
> format carries no MAC and the seal VFS op is a no-op, so the tamper-evidence
> demonstrated in Phases A–C is **structural only** (truncation / count-length
> mismatch). A targeted payload byte-flip (e.g. changing a stored `doc_id`) is
> **not** detected by the structural check. **Phase D** sets
> `fractalsql.enterprise_ledger_key` (a superuser-only `PGC_SUSET` GUC, settable
> per-session) to add an **HMAC-SHA256 envelope**: every flush tags the persisted
> blob and every load verifies the tag before the core decodes, so that same
> byte-flip **is** detected. The MAC lives in the open extension at the storage
> seam — the enterprise core is unchanged and is never handed tampered bytes.
>
> **Concurrency / cross-session** coverage (parallel last-writer-wins
> flush across 8 backends, and load-in-a-fresh-backend) is exercised by
> `build_test` **gate 25** (`gate_25_enterprise_stress` /
> `Gate25EnterpriseStress`), which can fork parallel psql backends — not
> something a single `psql -f` can do.

```sh
psql -d <your_database> -f demo/enterprise-stress.sql
```

## Text-to-SQL

`demo-text-to-sql.sql` walks through `fractal_text_to_sql()` against
a richer three-table schema with real foreign keys (`customers` ->
`orders` -> `order_items`) — single-table questions, a question
requiring a join, and a question requiring all three tables, plus
capturing and running a generated statement yourself. Same
prerequisites as `demo.sql` (extension installed, reasoning
configured). Full pipeline explanation, the GUC reference, and the
execution-role grant pattern are in
[docs/text-to-sql-setup.md](../docs/text-to-sql-setup.md).

```sh
psql -d <your_database> -f demo/demo-text-to-sql.sql
```

`demo/text-to-sql-spike-*.sql` are earlier, throwaway hand-rolled
scripts from before this function existed (single-table, no FKs,
driving `fractal_reason()` directly to validate the approach) — kept
for history, not the recommended starting point.

## Industry vertical demos

Eleven runnable walkthroughs — eight **industry verticals** and three
**agentic verticals** — each with its own synthetic dataset and its own
subset of the function surface chosen for genuine domain fit, not forced
coverage. Every one ends with a `fractal_reason()` narrative call over
real computed results, same closing pattern as `demo.sql`. Same
prerequisites as `demo.sql` (extension installed; the final reasoning
section in each needs [reasoning configured](../docs/reasoning-setup.md)
— every earlier section runs without it). All eleven are also wired
into the Docker demo — see [the Learning Path](../docs/docker-demo.md#the-learning-path).
Four (MedTech, Maritime, Fleet, Cybersecurity) store their vector
columns as the native **`fractal_vector(n)`** type instead of
`float8[]` — see
[demo-fractal-vector.sql](demo-fractal-vector.sql) and
[docs/vectorizer-setup.md](../docs/vectorizer-setup.md#storage-float8-vs-fractal_vectorn)
for the type itself.

```sh
psql -d <your_database> -f demo/demo-vertical-quant-finance.sql
```

- **[demo-vertical-quant-finance.sql](demo-vertical-quant-finance.sql)** —
  Quantitative Finance & Algorithmic Trading. A 25-asset factor-model
  portfolio (`fractal_optimize_portfolio` picks the best 8) and a
  300-point price series with a deliberate volatility regime change at
  t=150 (`fractal_dimension_dfa`/`fractal_dimension_drift`).
  `fractal_search_trajectory` finds which of 10 historical quarterly
  rebalances the new allocation most resembles.
- **[demo-vertical-medtech-clinical.sql](demo-vertical-medtech-clinical.sql)** —
  MedTech, Clinical Telemetry & Patient Monitoring. 40 synthetic
  patients, `vitals` stored as **`fractal_vector(5)`** (not `float8[]`)
  — a fixed five-field clinical vector where dimension-drift protection
  actually matters: `fractal_hybrid_clinical_search` over an
  age/condition cohort computed with ordinary SQL, `fractal_search_
  trajectory` for a patient's current vitals vs. their own admission
  baseline (the exact example in that function's own doc comment, using
  the `fractal_vector` overload directly), plus all four domain-
  geometry functions (`fractal_vascular_network`,
  `fractal_cortical_folding`, `fractal_nerve_plexus_metric`) on small,
  pre-extracted geometric fixtures — a vessel graph, a reference unit-
  cube mesh, a nerve fiber skeleton.
- **[demo-vertical-recommendation-search.sql](demo-vertical-recommendation-search.sql)** —
  Advanced Recommendation, Search & Discovery Engines. A 300-item, 6-genre
  catalog for diverse "you might also like" discovery
  (`fractal_search_explore`), table-backed top-k
  (`fractal_search_telemetry`), and the **full stateful-diversity
  loop**: enable Diversify, search, report negative feedback on the
  top result, re-search the same query, confirm it's now avoided — the
  real differentiator over plain top-K or MMR, neither of which is
  stateful across searches. Also covers `fractal_cross_modal_search`
  (content + behavior vectors, weighted).
- **[demo-vertical-sovereign-edge-ai.sql](demo-vertical-sovereign-edge-ai.sql)** —
  Sovereign, Edge & Autonomous Systems AI. FractalSQL's whole story fits
  this vertical natively — search, reasoning, and optimization all run
  as pure C inside the same Postgres process, no external vector-DB
  service required. A 50-node edge-compute fleet: Sniper Search for an
  ideal node profile, Scout Discovery for diverse fleet profiles,
  `fractal_dimension_boxcount` over a facility deployment grid, and
  `fractal_optimize_portfolio` repurposed as a general on-device
  black-box resource allocator (picking 6-of-50 nodes for a
  distributed job under contention risk).
- **[demo-vertical-maritime-defense.sql](demo-vertical-maritime-defense.sql)** —
  Maritime, Aviation & Defense (AIS & Radar Tracking). 30 synthetic AIS
  vessel tracks (`baseline`/`current` stored as **`fractal_vector(4)`**,
  a fixed track-state vector), one given a deliberate course deviation.
  `fractal_search_trajectory` on the current-vs-baseline track delta
  (a direct fit for "what changed" deviation detection, via the
  `fractal_vector` overload), nearest-track/diverse-track clustering
  across the fleet, and `fractal_dimension_dfa` on heading-change
  series to separate smooth transit from erratic maneuvering.
- **[demo-vertical-fleet-logistics.sql](demo-vertical-fleet-logistics.sql)** —
  Autonomous Fleet Management & Last-Mile Delivery. A 40-vehicle
  delivery fleet (`baseline`/`current` stored as **`fractal_vector(4)`**),
  one running a deliberate detour. Diverse route/zone clustering for
  depot coverage, a cohort-restricted search ("today's route-3 vehicles
  only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses, built here with an ordinary
  filtered temp table instead of that clinically-named function),
  detour detection via `fractal_search_trajectory` (`fractal_vector`
  overload), and GPS-trace complexity via `fractal_dimension_boxcount`.
- **[demo-vertical-smart-cities-iot.sql](demo-vertical-smart-cities-iot.sql)** —
  Smart Cities & IoT Sensor Grids. A 400-sensor city grid
  (traffic/air-quality/noise): spatial coverage diagnostics
  (`fractal_dimension_boxcount`/`fractal_morphological_complexity`),
  an air-quality event detected via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a sensor series with a deliberate
  regime shift, and diverse representative-zone sampling via Scout
  Discovery.
- **[demo-vertical-cybersecurity-threat-detection.sql](demo-vertical-cybersecurity-threat-detection.sql)** —
  Cybersecurity & Threat Detection (network behavior analytics). A
  35-host fleet across three zones (`baseline`/`current` stored as
  **`fractal_vector(4)`**), one host showing a stealthy compromise
  pattern — outbound connections, destination ports, and DNS query
  volume all spike while failed-auth stays flat, not a brute-force
  signature. Diverse traffic-profile clustering for threat hunting
  (`fractal_search_explore`), a zone-restricted search ("DMZ hosts
  only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses), compromise detection via
  `fractal_search_trajectory` (`fractal_vector` overload), and
  connection-rate regime-change detection via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a beaconing-onset series.

### Agentic verticals (Universal Agent composition)

The three agentic verticals exercise the six C-level **Universal Agents**
composed with PL/pgSQL into **Domain Agents** — see
[docs/api-agency.md](../docs/api-agency.md) for the composition pattern.
Unlike the domain verticals above, every section here needs reasoning
configured (the agents call `fractal_reason`/`fractal_embed`), and each
is a clean, re-runnable regression test of a recently-fixed agent code
path — nothing commented out, no `DO/EXCEPTION` skip-wrappers.

- **[demo-vertical-agentic-ops-devops.sql](demo-vertical-agentic-ops-devops.sql)** —
  DevOps/SRE: Autonomous Incident Triage & Self-Healing. The
  embed-coupled agents on a real 768-dim vectorized `incident_logs`
  corpus: `fractal_search_agent` (a zero-exerciser that crashed on a
  wrong column type before the `spi_scan_corpus` type guard) and
  `fractal_rag_agent` (a zero-exerciser that returned garbage before the
  raw-vector context fix), `fractal_agent_detect_loop` on a period-2
  state-hash array (the short-period check the DFA-only threshold missed),
  `fractal_dimension_drift` over a non-degenerate latency series, plus
  `fractal_agent_route_task` and `fractal_agent_outlier_intercept` Domain
  Agent compositions.
- **[demo-vertical-agentic-fintech-mcts.sql](demo-vertical-agentic-fintech-mcts.sql)** —
  FinTech: Scenario Exploration & Safe Execution. `fractal_agent_plan_explore`
  over a 768-dim vectorized `trade_strategies` corpus (the embed-coupling
  satisfied by the vectorizer, so the SRF runs unwrapped after its
  memory-context fix), `fractal_sql_agent` with `auto_execute => true`
  (after the subtransaction fix, a thrown error is caught and surfaced as
  `execution_status='execution_failed'` rather than aborting the call),
  and `fractal_optimize_portfolio` rebalancing.
- **[demo-vertical-agentic-customer-support.sql](demo-vertical-agentic-customer-support.sql)** —
  Customer Support: Stateful Session & Churn Drift.
  `fractal_agent_trajectory_predict` on a 3-dim `state_vector` column (now
  de-stubbed: reads baseline + latest by PK, derives dim from the data,
  computes a real delta — no more 1536 placeholder), plus
  `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, and
  the `fractal_diversify_enable` stateful-diversity loop.

**A note on `fractal_dimension_boxcount`/`fractal_morphological_complexity`
fixture design**, visible across several of the scripts above: both
functions need enough *space-filling* points (a grid, a path, a real
geometric structure) for their internal box-counting estimator to find
>= 3 valid eps-octaves — its own documented validity filter. A sparse
or purely random scatter of points, even well past the 8-point
minimum, typically fails this and returns an error rather than a wrong
number. Every fixture above was chosen and verified against a live
instance with that requirement in mind.

## The sixteen agents

`demo-agents.sql` validates the sixteen installable agents
shipped in the optional `fractalsql_agents` dependent extension — the
productized, callable form of the six Domain Agent reference blueprints
plus ten generalized agents that cover the
vertical demo sections the first six don't cover (see
[docs/api-agency.md](../docs/api-agency.md#which-agent-should-i-use)). It
exercises all sixteen agents end-to-end via the real `CREATE EXTENSION` path:

- **`fractal_agent_anomaly_triage`** — over a drifting latency series (real
  `fractal_dimension_drift` → real `fractal_reason`).
- **`fractal_agent_allocate`** — on a real `mu`/`cov` (real
  `fractal_optimize_portfolio` → real `fractal_reason`).
- **`fractal_agent_route_task`** — matches a task embedding to the nearest
  capability row (real `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_outlier_intercept`** — screens a state vector against known
  bad states and compares the real nearest-distance to a threshold (real
  `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_recall_hybrid`** — vector recall restricted by a metadata
  cohort (real `fractal_hybrid_clinical_search`); pure retrieval, no LLM step.
- **`fractal_agent_recommend_diverse`** — repulsion-diverse top-k over a catalog
  (real `fractal_diversify_enable` + real `fractal_search_telemetry`); pure
  retrieval, no LLM step.
- **`fractal_agent_data_analyst`** — a natural-language question over your
  tables (real `fractal_sql_agent` with `auto_execute => true` → real
  `fractal_reason`); the horizontal catch-all with no vertical preset.
- **`fractal_agent_patient_deterioration_triage`** — cohort-restricted
  nearest patient + baseline→current drift (real
  `fractal_hybrid_clinical_search` + real `fractal_search_trajectory` → real
  `fractal_reason`); the cohort is caller-built so `age>65 AND
  condition='sepsis'` composes in ordinary SQL.
- **`fractal_agent_feedback_audit`** — a self-contained diversify/repulsion
  audit cycle (real `fractal_detect_collapse` + real `fractal_explain_result`);
  pure analytics, **no LLM**, self-disables diversify.
- **`fractal_agent_schedule_workload`** — refines a task vector then finds
  the nearest node (real `fractal_search` + real `fractal_search_telemetry` →
  real `fractal_reason`).
- **`fractal_agent_rebalance_sibling`** — optimized book vs nearest
  historical allocation (real `fractal_optimize_portfolio` + real
  `fractal_search_trajectory` → real `fractal_reason`).
- **`fractal_agent_diverse_portfolios`** — enterprise tier; companion to
  `fractal_agent_allocate` returning several structurally distinct good
  portfolios instead of one (real `fractal_optimize_portfolio_multimodal` →
  real `fractal_reason`); dormant on community, exception-guarded so the
  demo still completes cleanly.
- **`fractal_agent_detour_classify`** — route deviation + GPS-trace
  complexity (real `fractal_search_trajectory` + real
  `fractal_dimension_boxcount` → real `fractal_reason`).
- **`fractal_agent_track_anomaly`** — track deviation + heading DFA (real
  `fractal_search_trajectory` + real `fractal_dimension_dfa` → real
  `fractal_reason`).
- **`fractal_agent_network_coverage_alert`** — sensor-grid morphology +
  telemetry drift (real `fractal_morphological_complexity` + real
  `fractal_dimension_drift` → real `fractal_reason`); 20×20 grid (400 pts).
- **`fractal_agent_regime_triage`** — single-series regime change (real
  `fractal_dimension_dfa` + real `fractal_dimension_drift` → real
  `fractal_reason`).

Thirteen agents are cognition (end in `fractal_reason`); three are pure
retrieval/analytics with no endpoint needed (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`). The script closes with
a `fractal_reason()` narrative over the computed results — same closing
pattern as every other demo.

**Prerequisites:** in addition to the base extension and reasoning (same as
`demo.sql`), install the agents extension:

```sql
CREATE EXTENSION fractalsql;          -- prerequisite (already in demo.sql)
CREATE EXTENSION fractalsql_agents;   -- the dependent extension
```

```sh
psql -d <your_database> -f demo/demo-agents.sql
```

The script is safe to re-run: `agents_demo_logs` and the agent fixture
tables (`agents_demo_caps`, `agents_demo_badstates`, `agents_demo_mem`,
`agents_demo_catalog`, `agents_demo_data`, `agents_demo_patients`,
`agents_demo_fcatalog`/`agents_demo_fwarmup`, `agents_demo_nodes`,
`agents_demo_alloc`, `agents_demo_vehicles`, `agents_demo_tracks`) are
dropped and recreated at the top of their sections. The eight
non-agentic vertical demos (`demo-vertical-quant-finance.sql`,
`demo-vertical-medtech-clinical.sql`, `demo-vertical-recommendation-search.sql`,
`demo-vertical-sovereign-edge-ai.sql`, `demo-vertical-maritime-defense.sql`,
`demo-vertical-fleet-logistics.sql`, `demo-vertical-smart-cities-iot.sql`,
`demo-vertical-cybersecurity-threat-detection.sql`) are likewise now **presets** —
each rewired section keeps its raw-primitive call as a commented blueprint
above the shipped agent call that generalizes it (the 3 agentic vertical
reference blueprints — `demo-vertical-agentic-ops-devops.sql`,
`demo-vertical-agentic-fintech-mcts.sql`, `demo-vertical-agentic-customer-support.sql` —
stay untouched).
The agents themselves are extension-owned functions, dropped only if you
`DROP EXTENSION fractalsql_agents` (see [Cleanup](#cleanup)).

## Full API benchmark

`benchmark-api-reference.sql` is a `\timing on` pass exercising the
callable functions in `sql/fractalsql--1.0.sql`, grouped by
category, against small generated fixtures — a correctness-plus-latency
smoke pass over the whole API surface, distinct from
[`benchmark.sql`](benchmark.sql)'s narrower Sniper-Search/Scout-
Discovery/vectorizer-throughput comparison (which stays scoped to that,
see its own header comment). Reasoning-dependent calls (`fractal_reason`,
`fractal_text_to_sql`, `fractal_embed`) are wrapped in a generic
`bmk_safe_call()` helper — the same pattern `business-intelligence-
demo.sql`'s `bi_safe_t2s()` uses, generalized to any function call — so
a missing or misconfigured reasoning/embedding endpoint degrades that
one row instead of aborting the rest of the benchmark.

```sh
psql -d <your_database> -f demo/benchmark-api-reference.sql
```

## Cleanup

The demo tables are left in place after running so you can poke at the
results. Drop them when you're done:

```sql
DROP TABLE demo_alerts, demo_embeddings;
DROP TABLE order_items, orders, customers;  -- demo-text-to-sql.sql
DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;         -- demo-vertical-quant-finance.sql
DROP TABLE vmc_patients;                                               -- demo-vertical-medtech-clinical.sql
DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;                   -- demo-vertical-recommendation-search.sql
DROP TABLE vse_nodes, vse_throughput;                                  -- demo-vertical-sovereign-edge-ai.sql
DROP TABLE vmd_vessels;                                                -- demo-vertical-maritime-defense.sql
DROP TABLE vfl_vehicles;                                               -- demo-vertical-fleet-logistics.sql
DROP TABLE vsc_sensors;                                                -- demo-vertical-smart-cities-iot.sql
DROP TABLE vcy_hosts;                                                  -- demo-vertical-cybersecurity-threat-detection.sql
DROP TABLE incident_logs, agent_capabilities;                          -- demo-vertical-agentic-ops-devops.sql
DROP TABLE trade_strategies, portfolios, assets, restrictions;        -- demo-vertical-agentic-fintech-mcts.sql
DROP TABLE customer_sessions;                                         -- demo-vertical-agentic-customer-support.sql
DROP TABLE bmk_corpus, bmk_docs, bmk_modal;                            -- benchmark-api-reference.sql
DROP TABLE agents_demo_logs, agents_demo_caps, agents_demo_badstates, agents_demo_mem, agents_demo_catalog;  -- demo-agents.sql
DELETE FROM fractal_vectorizers WHERE source_table IN ('bt_bench_docs', 'bmk_docs', 'incident_logs', 'trade_strategies');
DROP FUNCTION IF EXISTS bmk_safe_call(text, text);
-- Drop the optional agents extension (also drops its agent functions):
-- DROP EXTENSION IF EXISTS fractalsql_agents;
```

## Troubleshooting

- **Section 0 fails** — the extension isn't installed/enabled in this
  database. See [../docs/getting-started.md](../docs/getting-started.md).
- **Section 3 or 4 fails** — reasoning isn't configured, or the endpoint
  is unreachable/misconfigured. See the Troubleshooting section in
  [../docs/reasoning-setup.md](../docs/reasoning-setup.md) — it covers
  the specific error strings you'll see (plugin not loaded, HTTP 401,
  timeout, non-2xx response) and what each one means.
- **The reasoning response reads oddly** (e.g. the model asks for data
  instead of describing it) — check that the `context` subquery in that
  section actually returned rows. An empty or NULL context still gets
  sent as `'{}'`, and the model's default system prompt explicitly
  expects "database search results" to analyze; with nothing there, it
  will say so rather than hallucinate an answer.
