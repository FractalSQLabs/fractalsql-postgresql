<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Docker Demo: The Learning Path

Try FractalSQL without installing anything. `docker-compose.yml` at the repo root
builds a Postgres 18 image with the extension pre-installed and stands up a
turnkey demo environment.

## 🛠️ Prerequisites

Docker and Docker Compose. The demo builds the extension from source inside the
container, so no local PostgreSQL installation or compiler is required.

---

## 🚀 Setup Guide

### 1. The turnkey default — `docker compose up -d`

One command, no flags, gives you the bare minimum:

- **Postgres 18** running, DB `fractalsql_demo`, with **both** `fractalsql` and
  `fractalsql_agents` enabled (the base extension + the sixteen agents).
- **Ollama** running with **no model pulled** (model download is opt-in, step 2).
- Every demo + the `bench/` head-to-head benchmarks inside the container (`/demo/`,
  `/bench/`). Demos are **demoable on demand**: they are not run at init, because
  reasoning is inert until a model is pulled and the demos are re-runnable.

```bash
docker compose up -d
```

**Quick test** (works with no model; base Sniper search needs no LLM):
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -c \
  "SELECT fractal_search(ARRAY[0.6, 0.8, 0.0]::float8[], iterations => 100);"
```

Confirm both extensions loaded:
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -c "\dx"
# expect: fractalsql, fractalsql_agents
```

Run any demo (re-runnable; each recreates its own fixture tables):
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/<demo>.sql
```

### 2. Cognition — pull a model (opt-in)

Reasoning (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) needs a model.
Ollama is already up from step 1; pull one with the `pull-model` one-shot:
```bash
docker compose --profile pull-model run --rm pull-model
```
…or, equivalently, `docker compose exec ollama ollama pull gpt-oss:20b` (and
`nomic-embed-text`). This pulls ~13.8GB (gpt-oss:20b) + a few hundred MB
(nomic-embed-text). CPU-only inference may take several minutes per query on
modest hardware. See [docs/reasoning-setup.md](reasoning-setup.md)'s hardware
section. (Or point `fractalsql.http_url` at a cloud endpoint instead; see
[Reasoning Setup](reasoning-setup.md).)

**Quick test** (now that a model is present):
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -c \
  "SELECT fractal_reason('summarize this', '{\"note\": \"hello from the demo\"}');"
```

Re-run any cognition demo now for full reasoning output: e.g. the sixteen-agent
validation:
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-agents.sql
```

### 3. Vectorizer automation

No extra containers: reuse the model from step 2. Enables automatic embedding
pipelines:
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vectorizer.sql
```

---

## 🎓 The Learning Path

Run the demos in this order to see the progression from a vector search tool to a
sovereign agentic database. (Cognition/Agency demos need a model from step 2;
Discovery demos do not.)

### Level 1: Geometric Discovery
*Focus: Using the fractal core and domain-specific geometry to find structure in noise.*
- **Goal**: Learn to use SFS for high-precision convergence and domain-specific metrics (vascular, cortical, nerve).
- **Demos**:
  ```bash
  # MedTech: Clinical Telemetry & Patient Monitoring
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-medtech-clinical.sql
  # Maritime: AIS & Radar Tracking
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-maritime-defense.sql
  # Fleet: Last-Mile Delivery
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-fleet-logistics.sql
  # Smart Cities: IoT Sensor Grids
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-smart-cities-iot.sql
  ```

### Level 2: Cognitive Synthesis
*Focus: Composing search with LLM reasoning to generate human-readable insights.*
- **Goal**: Learn to feed Scout Discovery results into `fractal_reason` and use `fractal_text_to_sql` for safe data exploration.
- **Demos**:
  ```bash
  # Recommendations: Advanced Discovery Engines
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-recommendation-search.sql
  # Sovereign: Edge & Autonomous Systems AI
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-sovereign-edge-ai.sql
  # BI: The Full Reasoning Loop (Question -> SQL -> Result -> Reason)
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-business-intelligence.sql
  ```

### Level 3: Autonomous Agency
*Focus: Building self-correcting, safe, and predictive agentic workflows.*
- **Goal**: Learn to use loop detection (DFA), trajectory prediction, and self-correcting SQL agents. The reference blueprint agents ship inline in each vertical demo; the sixteen installable agents are exercised by `demo-agents.sql` (which uses the real `CREATE EXTENSION fractalsql_agents` product path).
- **Demos**:
  ```bash
  # DevOps: Autonomous Incident Triage & Self-Healing
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-agentic-ops-devops.sql
  # Support: Stateful Session & Churn Drift
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-agentic-customer-support.sql
  # FinTech: MCTS Scenario Exploration & Safe Execution
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-agentic-fintech-mcts.sql
  # Cyber: Threat Detection & Triage
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-cybersecurity-threat-detection.sql
  # The sixteen installable agents (requires fractalsql_agents, already enabled)
  docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-agents.sql
  ```

See [Agent Recipes](api-agency.md#which-agent-should-i-use) for what each agent
does and when to use it.

### Other demos in the image

`/demo/` also contains `demo.sql` (the base walkthrough), `response-modes.sql`,
`demo-text-to-sql.sql`, the `text-to-sql-spike-*.sql` series, `demo-fractal-vector.sql`,
`benchmark.sql`, and `benchmark-api-reference.sql`. Run any the same way.

---

## 📊 Validation & Benchmarks

### Scout vs. HNSW (in-database demo)
See how Scout Discovery captures more distinct clusters than standard top-K search.
This uses FractalSQL's own `fractal_vector` type. No pgvector needed:
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/benchmark.sql
```

### Full API surface
Exercise all 40+ functions (Search, Reason, Agents, Analytics) in one pass:
```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/benchmark-api-reference.sql
```

### Head-to-head benchmark vs. pgvector (optional)
`bench/` runs the real HNSW-vs-Scout head-to-head from `bench/README.md`. pgvector is
**optional** because only this benchmark needs it; the demos don't. Its Python deps
are pre-installed in `/bench/.venv`. Enable pgvector and stand up the benchmark DB
with the `pgvector` profile (creates `fractalsql_bench` with both `vector` and
`fractalsql` extensions):
```bash
docker compose --profile pgvector up -d pgvector-init
```
Then run the bench in-container:
```bash
docker compose exec postgres /bench/.venv/bin/python3 /bench/data_gen.py --dsn 'dbname=fractalsql_bench user=postgres'
docker compose exec postgres /bench/.venv/bin/python3 /bench/head_to_head.py --dsn 'dbname=fractalsql_bench user=postgres'
```
…or run it from the host against `localhost:15432` with your own Python env
(`pip install -r bench/requirements.txt`). See `bench/README.md` for the output
shape and tuning knobs.

---

## 🧹 Cleanup

```bash
docker compose down -v                       # default services + volumes
docker compose --profile pull-model down -v  # also remove the pulled-model volume
docker compose --profile pgvector down -v    # also remove the bench DB volume
```

The `-v` flag removes the named volumes (Postgres data, the Ollama model cache).
Drop it if you want to keep them for next time.