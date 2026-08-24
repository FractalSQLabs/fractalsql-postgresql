<p align="center">
  <img src="FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# FractalSQL: Sovereign Data Intelligence
### The Agentic Database Engine for PostgreSQL

**Vector Search. In-Database Reasoning. Production-Safe Agency. All beside your data.**

FractalSQL transforms PostgreSQL from a passive data store into an active agentic
database. While traditional RAG (Retrieval-Augmented Generation) focuses on *finding*
the right data, FractalSQL focuses on **closing the loop**: moving from discovery
to cognition, and finally to autonomous agency.

By bringing reasoning and agency directly into the PostgreSQL kernel, FractalSQL
enables **Sovereign Data Intelligence**: the ability to reason, plan, and act upon
your data without it ever leaving your control.

| Traditional RAG Stack | The Sovereign Way (FractalSQL) |
| --- | --- |
| **Mode Collapse** — top-K search returns near-duplicates, starving the LLM of diverse context. | **Scout Discovery** — quantified, diverse semantic search that discovers the data's real structure. |
| **Fragmented Logic** — app pulls rows, calls LLM, handles retries, and glues answers in middleware. | **In-Database Reasoning** — reasoning and embedding happen inside the backend via a high-performance VFS. |
| **Passive Retrieval** — you ask a question, the DB returns rows, and you hope the LLM is correct. | **Autonomous Agency** — self-correcting SQL, loop detection, and trajectory forecasting. |

---

## From zero to your first agent

FractalSQL's docs follow a single linear path — each step answers one question
and hands off to the next. You don't need to read everything; follow the path.

1. **What is this and why do I care?** — you are here. Sovereign Data Intelligence, in one page.
2. **How do I get the extension running in 60 seconds?** → [Getting Started](docs/getting-started.md) (Docker `compose up` or the Windows `.msi`, then your first Scout search).
3. **How do I apply this to my industry?** → [Starter Kits](docs/starter-kits.md) — runnable, industry-specific SQL scripts (SOC, FinTech, MedTech, Fleet, Smart-Cities, …).
4. **How does a specific agent work and what are its inputs?** → [Agent Recipes](docs/api-agency.md) — the sixteen installable agents, each as a recipe.
5. **How do I build a proprietary agent that isn't in the box?** → [Composition Guide](docs/composition-guide.md) — the design patterns behind the recipes.

> New here? Step 2 is a one-command demo. Step 3 drops you into a vertical that
> looks like your problem. Step 4 is the reference you'll keep coming back to.

---

## 🎯 Who are you?

Depending on your role, you'll want to start in different places:

- **AI Engineer**: You want to improve RAG quality and reasoning.
  → Start with **[docs/features.md](docs/features.md)** and **[docs/reasoning-setup.md](docs/reasoning-setup.md)**.
- **DBA / Security Architect**: You care about stability, safety, and grants.
  → See the **[Safety & Governance guide](docs/text-to-sql-setup.md#secure-it-authorization-vs-correctness)**.
- **Product Developer**: You want to build agentic features quickly.
  → Run the **[Docker Demo](docs/docker-demo.md)**, then pick a **[Starter Kit](docs/starter-kits.md)**.

---

## 🧩 What's in the box

Four tiers of SQL-callable primitives, composable into agents with plain PL/pgSQL.

- **Discovery** — diverse, mode-collapse-free retrieval: `fractal_search` (Sniper), `fractal_search_explore` (Scout), `fractal_search_telemetry` (table-backed top-K).
- **Cognition** — in-database LLM integration: `fractal_reason` (Bedrock, Azure OpenAI, Vertex, Ollama), `fractal_embed`, `fractal_text_to_sql`.
- **Agency** — self-correcting routines: `fractal_search_agent`, `fractal_sql_agent`, `fractal_agent_plan_explore`, `fractal_agent_detect_loop`, plus **sixteen installable agents** — see the [Agent Recipes](docs/api-agency.md).
- **Analytics** — fractal/dimension primitives: `fractal_dimension_dfa`, `fractal_dimension_boxcount`, `fractal_optimize_portfolio`, and more.

Every primitive is an ordinary SQL function, so a domain agent is just a
`CREATE FUNCTION ... LANGUAGE plpgsql` that calls them in sequence. When you're
ready to build your own, the [Composition Guide](docs/composition-guide.md)
walks through the patterns the shipped agents use. See the
**[Agent Blueprint Gallery](demo/README.md#industry-vertical-demos)** for full
SOC, FinTech, and MedTech reference implementations.

---

## 🚀 Get it running

The fastest path is one command — see **[Getting Started](docs/getting-started.md)**
for the 60-second Docker run and the native installers:

```bash
docker compose up -d   # then connect and run your first Scout search
```

Native installers (PostgreSQL 14–18, Linux amd64/arm64 and Windows x64): `.deb`
/ `.rpm` and a signed Windows `.msi`.

---

## 🏛️ Enterprise Tier — CISO Decision Audit & Quantized Ternary Ledger (QTL)

For regulated environments — finance, healthcare, defense — that need to
**prove, not just claim**, what an autonomous agent decided and why: every
optimizer call and every one of FractalSQL's agent decisions can write a
tamper-evident record you hand to a CISO or auditor, not a log line you hope
nobody disputes. This is delivered as a drop-in core library — **no rebuild,
no extension reload**. The same community extension binary ships the SQL
signatures; whether they do real work depends entirely on a runtime GUC.

**Community edition (default):** all nine functions are present but
**dormant**. Calling one returns a clear, actionable error:

```
ERROR: fractalsql: enterprise tier not loaded
HINT: set fractalsql.enterprise_lib to the path of the enterprise core
shared library (libfractalsql-enterprise-sovereign-c.so / .dylib / .dll)
and reload configuration, or contact your vendor for the enterprise tier.
```

**Enterprise edition:** drop the enterprise core shared library into
`include/` (or anywhere readable by the server) and point the GUC at it:

```sql
ALTER SYSTEM SET fractalsql.enterprise_lib =
  '/path/to/libfractalsql-enterprise-sovereign-c.so';
SELECT pg_reload_conf();
```

`pg_reload_conf()` is asynchronous — a fresh backend started a moment later
picks up the new value (the GUC is `SIGHUP`-scoped, so it cannot be set with a
per-session `SET`). The nine functions then activate and operate on the same
in-memory context the community search engine already built — eight ledger-
management functions plus `fractal_audit_unpack` for CISO decode — and the
ledger persists through a Postgres-backed storage VFS into the
`fractalsql_ledger` table:

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush()` | Encode truth + shadow ledgers into a QTL blob and append it to the chain. |
| `fractal_ledger_load()` | Hydrate the in-memory ledgers from the chain's latest entry (verifies only the tip — O(1)). |
| `fractal_ledger_verify()` | Walk the ENTIRE chain (O(n), on demand) and return a `jsonb` audit report. |
| `fractal_ledger_compact()` | Defragment / re-pack the in-memory QTL representation. |
| `fractal_ledger_reset_soft()` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard()` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count()` | Truth-side entry count (`bigint`). |
| `fractal_ledger_shadow_count()` | Shadow-side entry count (`bigint`). |
| `fractal_audit_unpack(bytea)` | Decode a persisted QTL blob into its audit JSON (`jsonb`). |

**Removing the library re-dormants the surface**: point the GUC back at a
missing path (or unset it) and reload — the functions return to the
*enterprise tier not loaded* error with no recompile. The search engine and
every community primitive keep working unchanged; only the ledger/audit
surface is gated.

**`fractal_audit_log(entry_type, payload)`** — the general decision-audit
chain: a second, independent append-only chain in `fractalsql_ledger`
(`kind=2`, same hash-chain guarantees as the QTL chain, verify with
`fractal_ledger_verify(2)`) for provenance records rather than QTL blobs.
`fractal_text_to_sql`, `fractal_optimize_portfolio`,
`fractal_optimize_portfolio_multimodal`, and
`fractal_optimize_portfolio_multimodal_pareto` log to it automatically
when enterprise is active — silently skipped on community, so none of
them ever depend on a license to keep working. Query it directly: `SELECT id,
updated, convert_from(blob, 'UTF8')::jsonb FROM fractalsql_ledger WHERE
kind = 2 ORDER BY id`.

Every decision-making agent in `fractalsql_agents` logs its own decision
to the same chain with the same best-effort, community-safe pattern (each
wraps its `fractal_audit_log` call in `BEGIN ... EXCEPTION WHEN
object_not_in_prerequisite_state THEN NULL; END;`, so a missing enterprise
tier never breaks the agent): `fractal_agent_anomaly_triage`,
`fractal_agent_allocate`, `fractal_agent_route_task`,
`fractal_agent_outlier_intercept`, `fractal_agent_data_analyst`,
`fractal_agent_patient_deterioration_triage`,
`fractal_agent_schedule_workload`, `fractal_agent_rebalance_sibling`,
`fractal_agent_detour_classify`, `fractal_agent_track_anomaly`,
`fractal_agent_network_coverage_alert`, `fractal_agent_regime_triage`,
and `fractal_agent_diverse_portfolios`. The pure-retrieval/pure-analytics
engines (`fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`,
`fractal_agent_feedback_audit`) don't make a decision worth auditing, so
they're intentionally not wired up.

**`fractal_optimize_portfolio_multimodal()`** (enterprise tier): like
`fractal_optimize_portfolio` but runs several independent restarts and
returns up to `n_restarts` structurally distinct portfolios instead of
one — candidates within `quality_frac` of the best Sharpe found, no two
sharing more than `overlap_threshold` of their assets. Same entropy
engine as the single-best version; the gate gives access to the
multi-restart + diverse-selection capability, not a different algorithm.
Paired agent: `fractal_agent_diverse_portfolios` in `fractalsql_agents`.
It logs to the decision-audit chain above the same way.

**`fractal_optimize_portfolio_multimodal_pareto()`** (enterprise tier):
Pareto-front sibling of the function above — same `n_restarts`
independent searches, but scores each by decomposed **return/risk**
instead of scalar Sharpe and reduces them to a genuine non-dominated
Pareto front (NSGA-II crowding-distance truncation past `max_front`)
rather than sharpe-threshold + asset-overlap selection. Purely
additive, doesn't change the sibling function's semantics. All three
`fractal_optimize_portfolio*` functions also accept `use_obl`
(Opposition-Based Learning — evaluate each SFS trial candidate's
bound-reflected opposite, keep whichever fits better) and
`diffusion_mode` (`'gaussian'` default or `'levy'`, a heavy-tailed
Mantegna-algorithm step that can help escape local optima on highly
multimodal problems). Same `fractal_agent_diverse_portfolios` agent
exposes both via its `objective_mode := 'sharpe' | 'pareto'` parameter.

**Append-only chain, not a snapshot.** The ledger is a genuine history: every
row links to its predecessor via `entry_hash = SHA256(prev_hash || blob ||
mac)`, and writes are plain `INSERT`s, never `UPDATE`/`UPSERT`. A rewritten
row breaks the chain; a deleted row leaves a visible gap in the `id`
sequence. This holds **even without a MAC key** — `entry_hash` covers the
blob unconditionally, so a byte-flip anywhere in history is structurally
detectable, not just cryptographically. Set the `fractalsql.enterprise_ledger_key`
GUC (superuser-only, `PGC_SUSET` — settable per-session) to additionally
**HMAC-SHA256-tag** each blob, authenticating it against forgery by anyone
who doesn't hold the key. `fractal_ledger_load()` checks only the chain's
tip on every call (cheap, O(1));
`fractal_ledger_verify()` walks the full chain for a periodic or on-demand
CISO audit (O(n) — not run automatically). One honest limit: the chain can
prove nothing in the *middle* was altered or removed, but it can't prove
nothing was truncated off the very *end* — there's nothing after the last
row to notice its absence. That needs an external anchor (e.g. publishing
the head hash somewhere independent), which this does not do. (See
`demo/enterprise-stress.sql` Phase E and `build_test` gate 25 Phase E.)

**Detached signature verification (optional hardening).** The 8-symbol
`dlsym` check in `ensure_enterprise_lib()` only proves a file has the right
function *names* — a tampered file with the same names sails through it
untouched. Set `fractalsql.enterprise_require_signature = on` (superuser-only,
`PGC_SIGHUP`) to additionally require a valid detached Ed25519 signature (a
sibling `<path>.sig` file, 64 raw bytes) against a fixed FractalSQLabs public
key before the library is `dlopen`'d. Off by default — a missing `.sig` only
logs a `WARNING` and the library still loads, so this is backward compatible
with unsigned releases. An **invalid** signature (present but wrong) is
always refused regardless of the setting — unambiguous tamper evidence,
unlike a merely absent file. New enterprise releases only need a fresh
signature from the same long-lived key; this extension never needs
rebuilding, preserving the drop-in-`.so` design a hash pin would have broken.
(See `build_test` gate 26.)

---

## 📊 Compatibility & License

| PostgreSQL | Linux | Windows x64 | macOS |
| --- | :---: | :---: | :---: |
| 14 | ✓ | ✓ | ✓ |
| 15 | ✓ | ✓ | ✓ |
| 16 | ✓ | ✓ | ✓ |
| 17 | ✓ | ✓ | ✓ |
| 18 | ✓ | ✓ | ✓ |

**License**: Apache-2.0 AND BSD-2-Clause. See `LICENSE`.

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.

---

## 📚 Documentation

*Follow the path above; the links below are the same steps, expanded.*

- **[Getting Started](docs/getting-started.md)** — 60-second Docker / native install.
- **[Starter Kits](docs/starter-kits.md)** — industry-specific runnable SQL scripts.
- **[Agent Recipes](docs/api-agency.md)** — the sixteen installable agents, each as a recipe.
- **[Composition Guide](docs/composition-guide.md)** — build your own agent.
- **[Features](docs/features.md)** — the full Capability Map and API reference.
- **[Reasoning Setup](docs/reasoning-setup.md)** — LLM provider configuration (Ollama, OpenAI, Bedrock, Azure, Vertex).
- **[Text-to-SQL Setup](docs/text-to-sql-setup.md)** — pipeline details and the security model.
- **[Vectorizer Setup](docs/vectorizer-setup.md)** — automatic embedding pipelines.
- **[Docker Demo](docs/docker-demo.md)** — a one-command end-to-end demo.
- **[Agent Blueprint Gallery](demo/README.md)** — the vertical demos and reference agents.