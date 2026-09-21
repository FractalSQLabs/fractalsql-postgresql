<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is a tiered capability framework that runs discovery, reasoning, and agentic workflows inside the PostgreSQL backend: no external RAG middleware shuffling data between the database and the LLM. It provides a progression from basic vector discovery to autonomous agentic reasoning.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in two editions, each unlocking more of the four capability tiers described below (Discovery → Cognition → Agency → Analytics). The editions are a *build/licensing* axis; the capability tiers are a *functional* axis. A single install belongs to one edition and exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **Community** | Discovery, Cognition, Agency | SFS Core, Sniper Search, Scout Discovery, In-DB Reasoning, Embeddings, 15 of the 16 Agents | Base extension (`libfractalsql-community`), everything most installs need |
| **Enterprise** | Governance | Tamper-evident decision ledger (hash chain), audit trail, detached-signature verification | Community extension + drop-in enterprise library, gated by a runtime GUC. See [Enterprise Tier](enterprise.md) |

---

## 🔍 Tier 1: Discovery

The foundation of FractalSQL is the **Stochastic Fractal Search (SFS)** engine, which treats vector search as a continuous optimization problem rather than an index lookup like standard HNSW or IVFFlat.

### Sniper Search (`fractal_search`)
Pure SFS convergence to the single best point minimizing cosine distance to a query over a unit box. It is a "precision" tool for finding the absolute global minimum.

### Scout Discovery (`fractal_search_explore`)
Scans a stored corpus and returns a diverse population of results: an SFS population search blended with **Maximal Marginal Relevance (MMR)** re-ranking, so the results cover the data's distinct basins of attraction instead of the "mode collapse" common in top-K search.

### Table-Backed Telemetry (`fractal_search_telemetry`)
A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the ground-truth layer used by all higher-order agentic functions.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a reasoning bridge to the SFS core, allowing it to call LLMs and embedding models via a pluggable C provider interface. This enables reasoning to happen *beside* the data.

### In-Database Reasoning (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider. Because it runs inside the backend, you can feed it the results of a Scout search or a SQL query in one statement. 

**Provider-agnostic**: the same `fractal_reason()` call works against **AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, or **local Ollama**. Switch providers via config without changing a single line of SQL. Local providers keep data on your own infrastructure; cloud providers send it to that provider under your own account and agreement (BAA-covered where your compliance posture requires it).

### Semantic Embeddings (`fractal_embed`)
Generates vectors from text using a purpose-trained embedding model. This removes the need for an external embedding pipeline for many RAG use cases.

### Safe Text-to-SQL (`fractal_text_to_sql`)
Generates SQL from natural language. It uses a three-stage safety pipeline:
1. **Parse-Check**: Validates statement shape (e.g., no DDL).
2. **Allowlist**: Ensures the statement type is permitted (e.g., `SELECT` only).
3. **EXPLAIN-Check**: Runs the statement through the Postgres planner inside a subtransaction to catch column/type mismatches before returning the SQL.

---

## 🤖 Tier 3: Agency

The Agency tier composes the Discovery and Cognition primitives into autonomous routines: 16 installable agents, each a productized recipe for a recurring pattern, built on 6 reusable Universal Agent primitives you can also call directly. See [`docs/api-agency.md`](api-agency.md) for the full argument reference, examples, and notes.

### Agents

| Agent | Recipe | Reasoning |
| --- | --- | --- |
| `fractal_agent_anomaly_triage` | drift exponent on one entity's series → reasoning triage | ✓ |
| `fractal_agent_regime_triage` | DFA + drift over one series → reasoning triage | ✓ |
| `fractal_agent_track_anomaly` | trajectory deviation + heading DFA → reasoning triage | ✓ |
| `fractal_agent_detour_classify` | trajectory deviation + box-counting → reasoning classify | ✓ |
| `fractal_agent_network_coverage_alert` | spatial morphology + telemetry drift → reasoning alert | ✓ |
| `fractal_agent_allocate` | SFS Sharpe optimizer → reasoning rationale | ✓ |
| `fractal_agent_rebalance_sibling` | optimizer + trajectory search → reasoning rationale | ✓ |
| `fractal_agent_diverse_portfolios` (enterprise) | multimodal optimizer → reasoning tradeoff summary | ✓ |
| `fractal_agent_route_task` | nearest-capability search + budget accounting → reasoning rationale | ✓ |
| `fractal_agent_schedule_workload` | `fractal_search` refine + nearest node → reasoning rationale | ✓ |
| `fractal_agent_outlier_intercept` | distance-to-bad-state safety barrier → reasoning justification | ✓ |
| `fractal_agent_patient_deterioration_triage` | cohort search + trajectory drift → reasoning triage | ✓ |
| `fractal_agent_data_analyst` | NL → SQL → execute → reasoning analysis | ✓ |
| `fractal_agent_recall_hybrid` | cohort-restricted vector recall | — |
| `fractal_agent_recommend_diverse` | repulsion-diverse top-k | — |
| `fractal_agent_feedback_audit` | diversify loop + collapse detection | — |

### Universal Agents

The six building blocks the agents above compose. Call them directly to build your own recipe.

| Function | What it does |
| --- | --- |
| `fractal_search_agent` | Embed a query, Scout-search a table, and reason over the matched rows. |
| `fractal_rag_agent` | Focused single-turn RAG: embed, Scout-search, and reason over the result. |
| `fractal_sql_agent` | Self-correcting NL-to-SQL, retrying on `EXPLAIN`/execution failure. |
| `fractal_agent_plan_explore` | MCTS-style exploration of multiple non-overlapping strategy trajectories. |
| `fractal_agent_trajectory_predict` | Forecasts future state from a delta against historical telemetry. |
| `fractal_agent_detect_loop` | Flags infinite/repetitive agent loops via SimHash state fingerprints and Brent's cycle detector, with a DFA drift check. |

### Safe Agency & Guardrails

To prevent "hallucination-driven" database corruption, the Agent Tier implements two primary guardrails:

1. **The Subtransactional Barrier**: Functions like `fractal_sql_agent` with `auto_execute => true` run generated SQL inside an internal subtransaction. If a constraint is violated or an error occurs, the subtransaction is rolled back, the error is fed back to the LLM for a retry, and the main session remains intact.
2. **The Deterministic Allowlist**: The `fractalsql.text_to_sql_allowed_statements` GUC strictly limits the types of SQL the agent can generate (e.g., preventing `DROP TABLE` even if the LLM suggests it).

---

## 📐 Tier 4: Analytics

The final tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into actionable structural insights.

### Fractal Dimension Analysis
- **DFA (`fractal_dimension_dfa`)**: Analyzes the scaling exponent of a time series to distinguish between noise, random walks, and structured signals.
- **Box-Counting (`fractal_dimension_boxcount`)**: Measures the Minkowski-Bouligand dimension of a point cloud to evaluate spatial complexity.
- **Drift (`fractal_dimension_drift`)**: Detects regime changes by comparing the DFA exponent of a recent window against a baseline.
- **Change-Point Localization (`fractal_change_point_detect`)**: Localizes where a series' mean or variance shifted, complementing DFA's overall characterization.
- **Periodogram (`fractal_periodogram`)**: Exact power spectrum (direct DFT) for cadence detection such as beaconing or retry loops.

### Topology and State Fingerprints
- **Persistence (`fractal_tda_persistence_diagram`)**: Exact 0-dimensional persistence over a point cloud's Vietoris-Rips filtration, plus the graph cycle rank as an informational Betti-number estimate.
- **SimHash (`fractal_state_fingerprint`)**: Folds a state vector into a Hamming-comparable fingerprint where nearly-identical states collide.
- **Cycle Detection (`fractal_cycle_detect`)**: Streaming Brent's algorithm over a fingerprint stream, one output per cycle closure.

### Vector Math
- **$L_p$ Distance (`fractal_vector_lp_distance`)**: Generalized distance over `fractal_vector` for any $p > 0$.
- **Quantization (`fractal_vector_quantize_int8` / `_binary`)**: 4x/32x per-vector compression with optional Hamming pre-filtering ahead of a full-precision re-rank.

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and technical geometry:
- **Vascular Networks**: Tortuosity and branch-density for vessel graphs.
- **Cortical Folding**: Gyrification Index for brain-surface meshes.
- **Nerve Plexus**: Density and dimension for fiber skeletons.
- **Morphological Complexity**: Combined box-counting and lacunarity for segmented masks.

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve cardinality-constrained Sharpe-ratio maximization. It finds the best $K$ assets in a large universe without the exponential cost of a brute-force search.
`fractal_optimize_subset` generalizes the same search to value-weighted allocation over any scored item list with per-item bounds.

---

## 📈 Benchmarks & Scaling

### HNSW vs. Scout Discovery
In a benchmark of 100k vectors across 50 Gaussian clusters, measured directly against current Scout (see `bench/README.md` for the full methodology and how to reproduce it):
- **HNSW** (top-50) typically discovered **1 cluster**, in single-digit milliseconds.
- **Scout** (pop=50) typically discovered **6-9 clusters**, in roughly 1.5-1.7 seconds, on the order of **100x+ slower** than HNSW at this scale (measured 130-270x across repeated runs).

That tradeoff is the whole point of Scout Mode, not a hidden cost: it's $O(N \times d)$ (linear scan) by design, and it's the only way here to guarantee your LLM receives a genuinely diverse set of perspectives rather than a single collapsed cluster. It is not a drop-in replacement for HNSW. Use it where diversity matters more than latency (e.g. curated sub-corpora, not full-corpus top-k at scale).

### Storage: `float8[]` vs `fractal_vector`
Using the native `fractal_vector` type gives close to a **~2x** speedup over `float8[]` for small vectors that never trigger Postgres's automatic TOAST compression (uncompressed `float4` vs uncompressed `float8`). Larger vectors where `float8[]`'s TOAST compression kicks in see a smaller realized gap. The ratio depends on how compressible your actual embedding values are; measure on your own data before treating either number as a promise (see `bench/README.md`'s `fractal_vector vs float8[]` section).

---

## 📚 API Reference

(Detailed argument tables, defaults, and ranges are available in the **[Detailed API Reference](api-discovery.md)**.)

**Discovery**
- `fractal_search(query, ...)`: Sniper Mode convergence. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_explore(table, col, query, ...)`: Scout Mode diverse exploration. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_telemetry(table, col, query, k)`: Ground-truth row retrieval. $\rightarrow$ **[api-discovery.md](api-discovery.md)**

**Cognition**
- `fractal_reason(query, context)`: LLM dispatch. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_embed(input)`: Semantic vector generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_text_to_sql(question, table_names?)`: Safe SQL generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**

**Agency**
- `fractal_agent_data_analyst(...)`: NL question over tables + reasoned summary. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_route_task(...)`: Sub-agent dispatch. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_regime_triage(...)` / `_anomaly_triage(...)`: Drift/regime detection. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_recommend_diverse(...)` / `_recall_hybrid(...)`: Diverse/cohort-restricted retrieval. $\rightarrow$ **[api-agency.md](api-agency.md)**
- 10 more, full list $\rightarrow$ **[api-agency.md](api-agency.md#which-agent-should-i-use)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_change_point_detect(series, win, ...)`: Change-point localization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_periodogram(series, max_peaks?)`: Exact power spectrum. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_tda_persistence_diagram(points, dim, ...)`: Point-cloud persistence. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_state_fingerprint(v, ...)` / `fractal_cycle_detect(fingerprints, ...)`: SimHash + Brent cycle detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vector_lp_distance(a, b, p)` / `fractal_vector_quantize_int8(v)` / `_binary(v)`: Vector math and quantization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
