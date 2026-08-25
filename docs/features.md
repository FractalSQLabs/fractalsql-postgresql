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

The Agent Tier composes the Discovery and Cognition primitives into autonomous routines. These are "Universal Agents" that provide the high-level logic for complex workflows, which can then be composed into "Domain Agents" using PL/pgSQL.

### Agent Dependency Matrix

| Agent Function | Dependencies | Capability Provided |
| --- | --- | --- |
| `fractal_search_agent` | Embed $\rightarrow$ Scout $\rightarrow$ Reason | End-to-end synthesis of diverse context into a final answer. |
| `fractal_sql_agent` | T2S $\rightarrow$ Parser $\rightarrow$ EXPLAIN $\rightarrow$ LLM | Robust SQL generation with automatic self-correction via retries. |
| `fractal_agent_plan_explore` | SFS Core $\rightarrow$ Diversify/Repulsion | MCTS-style exploration of non-overlapping strategy trajectories. |
| `fractal_agent_trajectory_predict` | Telemetry $\rightarrow$ Delta-Vector Logic | Preemptive forecast of state drift by searching the delta vector. |
| `fractal_agent_detect_loop` | DFA $\rightarrow$ Dimension Analysis | Safety monitor that flags repetitive behavior via scaling exponents. |

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

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and technical geometry:
- **Vascular Networks**: Tortuosity and branch-density for vessel graphs.
- **Cortical Folding**: Gyrification Index for brain-surface meshes.
- **Nerve Plexus**: Density and dimension for fiber skeletons.
- **Morphological Complexity**: Combined box-counting and lacunarity for segmented masks.

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve cardinality-constrained Sharpe-ratio maximization. It finds the best $K$ assets in a large universe without the exponential cost of a brute-force search.

---

## 📈 Benchmarks & Scaling

### HNSW vs. Scout Discovery
In a benchmark of 100k vectors across 50 Gaussian clusters (see `bench/README.md` for the full methodology and how to reproduce it):
- **HNSW** (top-50) typically discovered **1-2 clusters**, at millisecond latency.
- **Scout** (pop=50) typically discovered **20-35 clusters**, at multi-second latency, roughly **6000x slower** than HNSW at this scale.

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
- `fractal_search_agent(...)`: End-to-end synthesis. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_sql_agent(...)`: Self-correcting SQL execution. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_plan_explore(...)`: Strategy exploration. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_trajectory_predict(...)`: Drift projection. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_detect_loop(...)`: Loop safety monitoring. $\rightarrow$ **[api-agency.md](api-agency.md)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
