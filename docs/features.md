<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is not a single tool, but a tiered capability framework for **Sovereign Data Intelligence**. It provides a progression from basic vector discovery to autonomous agentic reasoning, all executed natively within the PostgreSQL backend to ensure data sovereignty and eliminate the "data shuffle" between database and LLM.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in three editions, each unlocking more of the four capability tiers described below (Discovery → Cognition → Agency → Analytics). The editions are a *build/licensing* axis; the capability tiers are a *functional* axis — a single install belongs to one edition and exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **Community** | Discovery | SFS Core, Sniper Search, Scout Discovery | Base extension (`libfractalsql-community`) |
| **Sovereign** | Cognition & Agency | In-DB Reasoning, Embeddings, Agent Tier | Sovereign build + Reasoning Plugin (`.so`) |
| **Enterprise** | Governance | QTL (Quantized Ternary Ledger), Audit Logs, SLAs | Enterprise build + License Key |

---

## 🔍 Tier 1: Discovery

The foundation of FractalSQL is the **Stochastic Fractal Search (SFS)** engine. Unlike standard HNSW or IVFFlat indexes, SFS treats vector search as a continuous optimization problem.

### Sniper Search (`fractal_search`)
Converges to the single best point minimizing cosine distance to a query over a unit box. It is a "precision" tool for finding the absolute global minimum.

### Scout Discovery (`fractal_search_explore`)
Scans a stored corpus and returns a diverse population of results. It uses a brute-force relevance scan followed by **Maximal Marginal Relevance (MMR)** to ensure the results cover the data's distinct basins of attraction, preventing the "mode collapse" common in top-K search.

### Table-Backed Telemetry (`fractal_search_telemetry`)
A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the ground-truth layer used by all higher-order agentic functions.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a Virtual File System (VFS) surface to the SFS core, allowing it to communicate with LLMs and embedding models via a high-performance C-bridge. This enables intelligence to happen *beside* the data.

### In-Database Reasoning (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider. Because it runs inside the backend, you can feed it the results of a Scout search or a SQL query in one statement. 

**Universal Connectivity**: The reasoning VFS provides a provider-agnostic bridge to the world's leading models, including **AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, and **local Ollama** for air-gapped sovereignty. You can switch providers via config without changing a single line of SQL.

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
In a benchmark of 100k vectors across 50 clusters:
- **HNSW** (top-50) typically discovered **1-2 clusters**.
- **Scout** (pop=50) typically discovered **6-8 clusters**.

While Scout is $O(N \times d)$ (linear scan), it is the only way to guarantee that your LLM receives a diverse set of perspectives rather than a single, collapsed cluster.

### Storage: `float8[]` vs `fractal_vector`
Using the native `fractal_vector` type provides a $\sim 1.3x$ to $1.7x$ speedup over `float8[]` by skipping the array-unpack step during the linear scan.

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
