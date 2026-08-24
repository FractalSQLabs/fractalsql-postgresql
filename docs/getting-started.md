<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Getting Started: From Zero to Your First Agent

This guide takes you from a fresh checkout to a running agentic database in
about five minutes — no Postgres install, no compiler, no model download
required to start. By the end you will have:

- a Postgres 18 server with the `fractalsql` **and** `fractalsql_agents`
  extensions loaded,
- a diverse vector search that runs with **no model** connected,
- a live reasoning call against a real LLM, and
- all 15 agents demoable on demand.

The fastest path is Docker. If you are putting this into a real Postgres
cluster instead, jump to [Install without Docker](#5-install-without-docker)
and come back to the "first search" / "first agent" sections.

> **The 5-minute path:** [1. Running in 60 seconds](#1-running-in-60-seconds-docker)
> → [2. Your first search](#2-your-first-search-no-model-needed)
> → [3. Turn on reasoning](#3-turn-on-reasoning) → [4. Your first agent](#4-your-first-agent)
> → [where next](#where-next).

---

## 1. Running in 60 seconds (Docker)

From the repo root:

```bash
docker compose up -d
```

That starts a Postgres 18 container with both extensions **enabled by init**
plus an Ollama container with **no model pulled** (you add a model when you
want reasoning — see [step 3](#3-turn-on-reasoning)). All the demo SQL ships
inside the image at `/demo/`, ready to run on demand.

Verify FractalSQL is alive and both extensions are loaded:

```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo \
  -c "\dx" \
  -c "SELECT fractal_edition(), fractal_version();"
```

You should see `fractalsql` and `fractalsql_agents` in the extension list, and:

```
  edition  | version
-----------+---------
 Community | 2.0.0
```

> **No `psql` on your host?** Every command below uses
> `docker compose exec postgres psql ...` so you never need a local client.
> If you do have `psql`, the server is also exposed on host port `15432`
> (`psql -h localhost -p 15432 -U postgres -d fractalsql_demo`, password
> `fractalsql`).

---

## 2. Your first search (no model needed)

FractalSQL's core is a **Stochastic Fractal Search** optimizer. It comes in
two flavours that solve different problems:

- **Sniper** (`fractal_search`) — converge to the single best point in a
  continuous space.
- **Scout** (`fractal_search_explore`) — discover the *diverse* structure of
  your own data, finding distinct "islands" instead of collapsing to one
  nearest neighbour.

Scout is what makes FractalSQL different from a plain vector DB, and it runs
with **no model connected**. Try it on a tiny toy corpus:

```sql
docker compose exec postgres psql -U postgres -d fractalsql_demo <<'sql'
CREATE TABLE demo_vecs (id int, emb float8[]);
INSERT INTO demo_vecs VALUES
  (1, ARRAY[0.1, 0.1, 0.1]),
  (2, ARRAY[0.9, 0.9, 0.9]),
  (3, ARRAY[0.2, 0.8, 0.2]);

-- Scout: discover the distinct basins in the data (not just the closest row)
SELECT p FROM fractal_search_explore(
    'demo_vecs', 'emb',
    ARRAY[0.5, 0.5, 0.5]::float8[],
    '{"population_size": 20, "iterations": 10, "walk": 0}'::jsonb
) AS p;
sql
```

You'll get back a spread of vectors drawn from the distinct clusters in your
table — the opposite of a `top-K` query that would return three rows all from
the same neighbourhood. Re-running it is safe and gives similar diverse
coverage.

→ For the HNSW-vs-Scout benchmark that makes the difference concrete, see
**[docs/docker-demo.md](docker-demo.md)** (the optional `--profile pgvector`
section).

---

## 3. Turn on reasoning

Search finds data; **reasoning** turns it into insight. Reasoning is opt-in —
it calls an LLM through a high-performance HTTP bridge, so you point it at a
provider (Ollama locally, or AWS Bedrock / Azure OpenAI / GCP Vertex in the
cloud).

**With the bundled Ollama** — pull a model once, then reason:

```bash
# one-time model pull (~13.8 GB for gpt-oss:20b; a few hundred MB for the embedder)
docker compose --profile pull-model run --rm pull-model
```

```sql
docker compose exec postgres psql -U postgres -d fractalsql_demo \
  -c "SELECT fractal_reason('Reply with exactly: FSQL_LIVE_OK') AS reply;"
```

```
    reply
--------------
 FSQL_LIVE_OK
```

The embedder works the same way (it powers the vectorizer and any
RAG-style agent):

```sql
SELECT array_length(fractal_embed('hello world'), 1) AS embed_dim;
--  768
```

→ To point at a cloud endpoint instead of local Ollama, see
**[docs/reasoning-setup.md](reasoning-setup.md)** (provider config, GUCs,
the slow-hardware timeout notes).

---

## 4. Your first agent

The **Agent Tier** composes Discovery + Cognition into self-correcting
routines. The image ships a single script that exercises all **15 agents**
end-to-end — anomaly triage, portfolio allocation, hybrid recall,
route planning, deterioration triage, regime detection, and the rest:

```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo \
  -f /demo/demo-agents.sql
```

Each section sets up its own fixture tables (with `DROP TABLE IF EXISTS`
first, so it's re-runnable) and calls one agent. With a model pulled you get
real reasoned output for every section; without one, the retrieval/optimization
parts still run and only the closing narrative is missing.

Prefer a specific industry? The vertical demos are one command each — e.g.
cybersecurity threat detection:

```bash
docker compose exec postgres psql -U postgres -d fractalsql_demo \
  -f /demo/demo-vertical-cybersecurity-threat-detection.sql
```

→ To pick the right agent for your problem, see the decision table in
**[docs/api-agency.md](api-agency.md#which-agent-should-i-use)**. To pick the
right *industry* starting point, see
**[docs/starter-kits.md](starter-kits.md)**.

---

## 5. Install without Docker

For a real Postgres cluster, grab the package matching your PostgreSQL major
and CPU architecture from [GitHub Releases](https://github.com/FractalSQLabs/fractalsql-postgresql/releases).

```bash
# Debian / Ubuntu
sudo apt install ./postgresql-17-fractalsql-amd64.deb

# RHEL / Rocky / Fedora
sudo dnf install ./postgresql-17-fractalsql-*.rpm
```

```bash
# Windows: run the matching .msi (e.g. FractalSQL-PostgreSQL-17-2.0.0-x64.msi)
# It installs into the EDB default C:\Program Files\PostgreSQL\<major>\ tree.
```

Then load **both** extensions, once per database:

```bash
sudo -u postgres psql -d mydb -c "CREATE EXTENSION fractalsql;"
sudo -u postgres psql -d mydb -c "CREATE EXTENSION fractalsql_agents;"
```

`fractalsql_agents` is pure PL/pgSQL and `requires='fractalsql'`, so it loads
the instant the base extension is present — no extra library, no compile.

On **macOS** there is no `.deb`/`.rpm` equivalent, so releases ship a
per-(major, arch) tarball with an `install.sh`:

```bash
tar xzf fractalsql-postgresql-2.0.0-pg17-darwin-arm64.tar.gz
cd fractalsql-postgresql-2.0.0-pg17-darwin-arm64
./install.sh        # uses pg_config on PATH; or: PG_CONFIG=/opt/homebrew/opt/postgresql@17/bin/pg_config ./install.sh
```

`install.sh` drops the base extension, the reasoning plugin, **and** the
agents files into the target server's own extension dir, then you run the two
`CREATE EXTENSION` lines above.

→ Package paths, version matrices, and the reasoning-plugin GUCs are in
**[docs/features.md](features.md)** and
**[docs/reasoning-setup.md](reasoning-setup.md)**.

---

## Where next

The documentation is a linear path. You just finished step 2.

| Step | Question | Go to |
|------|----------|-------|
| 3 | *"How do I apply this to **my** industry?"* | **[docs/starter-kits.md](starter-kits.md)** |
| 4 | *"How does a specific agent work, and what are its inputs?"* | **[docs/api-agency.md](api-agency.md)** |
| 5 | *"How do I build a proprietary agent that isn't in the box?"* | **[docs/composition-guide.md](composition-guide.md)** |

If you want the full Docker walkthrough (profiles, the optional pgvector
benchmark, cleanup), it's in **[docs/docker-demo.md](docker-demo.md)**.