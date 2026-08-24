<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Starter Kits: Apply FractalSQL to Your Industry

You have the extension running ([getting-started.md](getting-started.md)). Now:
**which end-to-end example do I run for *my* problem?**

FractalSQL ships eleven runnable industry walkthroughs — eight **domain
verticals** (a single `psql -f` each, mostly no-model) and three **agentic
verticals** (composed multi-step agents, model-on). Each kit is a
self-contained script: it builds its own synthetic dataset, runs the agents
that genuinely fit that domain, and closes with a reasoned narrative. They
are all re-runnable (`DROP TABLE IF EXISTS` at the top of every section) and
all ship inside the Docker image at `/demo/`.

> In Docker, run any kit with:
> ```bash
> docker compose exec postgres psql -U postgres -d fractalsql_demo \
>   -f /demo/<kit-file>.sql
> ```
> Without Docker: `psql -d <your_db> -f demo/<kit-file>.sql`.

## Which kit should I run?

| If your problem is… | Run this kit | Agents it exercises | Agent & recipe |
|---|---|---|---|
| Portfolio construction / regime detection | `demo-vertical-quant-finance.sql` | `regime_triage`, `rebalance_sibling`, `fractal_optimize_portfolio`, `fractal_dimension_dfa`/`_drift`, `fractal_search_trajectory` | [regime_triage](api-agency.md#regime-triage--fractal_agent_regime_triage), [rebalance_sibling](api-agency.md#rebalance-sibling--fractal_agent_rebalance_sibling) |
| Patient monitoring / clinical telemetry | `demo-vertical-medtech-clinical.sql` | `patient_deterioration_triage`, `fractal_hybrid_clinical_search`, `fractal_search_trajectory`, vascular/cortical/nerve geometry | [patient_deterioration_triage](api-agency.md#patient-deterioration-triage--fractal_agent_patient_deterioration_triage) |
| Recommendation / diverse search | `demo-vertical-recommendation-search.sql` | `recommend_diverse`, `feedback_audit`, `fractal_search_explore`, `fractal_search_telemetry`, `fractal_cross_modal_search` | [recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse), [feedback_audit](api-agency.md#feedback-audit--fractal_agent_feedback_audit) |
| Edge / autonomous fleet allocation | `demo-vertical-sovereign-edge-ai.sql` | `recommend_diverse`, `fractal_optimize_portfolio`, `fractal_dimension_boxcount`, Sniper (`fractal_search`) | [recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |
| Maritime / aviation track anomaly | `demo-vertical-maritime-defense.sql` | `track_anomaly`, `fractal_search_trajectory`, `fractal_dimension_dfa`, Scout | [track_anomaly](api-agency.md#track-anomaly--fractal_agent_track_anomaly) |
| Fleet logistics / detour detection | `demo-vertical-fleet-logistics.sql` | `detour_classify`, `recommend_diverse`, `fractal_search_trajectory`, `fractal_dimension_boxcount` | [detour_classify](api-agency.md#detour-classify--fractal_agent_detour_classify), [recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |
| Smart cities / IoT sensor grids | `demo-vertical-smart-cities-iot.sql` | `network_coverage_alert`, `fractal_dimension_dfa`/`_drift`/`_boxcount`, `fractal_morphological_complexity`, Scout | [network_coverage_alert](api-agency.md#network-coverage-alert--fractal_agent_network_coverage_alert) |
| Cybersecurity / network behavior analytics | `demo-vertical-cybersecurity-threat-detection.sql` | `track_anomaly`, `recommend_diverse`, `fractal_search_trajectory`, `fractal_dimension_dfa`/`_drift`, Scout | [track_anomaly](api-agency.md#track-anomaly--fractal_agent_track_anomaly) |
| **Agentic:** DevOps / SRE dispatch + safety | `demo-vertical-agentic-ops-devops.sql` | `route_task`, `outlier_intercept`, `anomaly_triage` + `detect_loop`, `threat_triage` blueprint (a composed-agent reference design — see Step 4) | [route_task](api-agency.md#route-task--fractal_agent_route_task), [outlier_intercept](api-agency.md#outlier-intercept--fractal_agent_outlier_intercept), [anomaly_triage](api-agency.md#anomaly-triage--fractal_agent_anomaly_triage) |
| **Agentic:** FinTech portfolio rebalance + MCTS | `demo-vertical-agentic-fintech-mcts.sql` | `rebalance_sibling`, `plan_explore`, `portfolio_rebalance` blueprint, `fractal_optimize_portfolio` | [rebalance_sibling](api-agency.md#rebalance-sibling--fractal_agent_rebalance_sibling), [plan_explore](api-agency.md#building-blocks-the-six-universal-agents) |
| **Agentic:** Customer support recall + recommend | `demo-vertical-agentic-customer-support.sql` | `recall_hybrid`, `recommend_diverse`, `trajectory_predict`, Scout | [recall_hybrid](api-agency.md#recall-hybrid--fractal_agent_recall_hybrid), [recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |

> Not sure which agent does what? The
> [decision table](api-agency.md#which-agent-should-i-use) maps every problem
> shape to its agent.

## Domain kits (run with no model)

These eight run almost entirely **without a reasoning endpoint** — only the
closing `fractal_reason()` narrative needs one, so you can see the
retrieval/optimization/geometry results immediately and pull a model later
just for the summary. Four (MedTech, Maritime, Fleet, Cybersecurity) store
vectors as the native `fractal_vector(n)` type — see
[vectorizer-setup.md](vectorizer-setup.md) for that type.

### Quantitative Finance — `demo-vertical-quant-finance.sql`
A 25-asset factor-model portfolio where `fractal_optimize_portfolio` picks the
best 8, and a 300-point price series with a deliberate volatility regime
change at t=150 that `fractal_dimension_dfa`/`_drift` detect automatically.
`fractal_search_trajectory` then finds which of 10 historical quarterly
rebalances the new allocation most resembles — the productized form is
`rebalance_sibling` and `regime_triage`.

### MedTech / Clinical — `demo-vertical-medtech-clinical.sql`
40 synthetic patients, vitals stored as `fractal_vector(5)`.
`fractal_hybrid_clinical_search` over an age/condition cohort computed with
ordinary SQL, `fractal_search_trajectory` for a patient's current vitals vs.
their admission baseline (the productized form is `patient_deterioration_triage`),
plus all four domain-geometry functions on small pre-extracted
fixtures (vessel graph, reference mesh, nerve skeleton).

### Recommendation / Search — `demo-vertical-recommendation-search.sql`
A 300-item, 6-genre catalog for diverse "you might also like" discovery, and
the **full stateful-diversity loop**: enable Diversify, search, report negative
feedback on the top result, re-search the same query, confirm it's now avoided
— the real differentiator over plain top-K or MMR. Productized form:
`recommend_diverse` and `feedback_audit`. Also covers
`fractal_cross_modal_search` (content + behavior vectors, weighted).

### Sovereign / Edge AI — `demo-vertical-sovereign-edge-ai.sql`
FractalSQL's whole story fits this vertical natively — search, reasoning, and
optimization all run as pure C inside the same Postgres process, no external
vector-DB service. A 50-node edge fleet: Sniper for an ideal node profile,
Scout for diverse fleet profiles, `fractal_dimension_boxcount` over a
deployment grid, and `fractal_optimize_portfolio` repurposed as a general
on-device resource allocator (picking 6-of-50 nodes for a distributed job).

### Maritime / Defense — `demo-vertical-maritime-defense.sql`
30 synthetic AIS vessel tracks (`fractal_vector(4)`), one with a deliberate
course deviation. `fractal_search_trajectory` on the current-vs-baseline track
delta for "what changed" deviation detection, nearest/diverse-track clustering
across the fleet, and `fractal_dimension_dfa` on heading-change series to
separate smooth transit from erratic maneuvering. Productized form:
`track_anomaly`.

### Fleet Logistics — `demo-vertical-fleet-logistics.sql`
A 40-vehicle delivery fleet (`fractal_vector(4)`), one running a deliberate
detour. Diverse route/zone clustering, a cohort-restricted search ("today's
route-3 vehicles only"), detour detection via `fractal_search_trajectory`, and
GPS-trace complexity via `fractal_dimension_boxcount`. Productized form:
`detour_classify`.

### Smart Cities / IoT — `demo-vertical-smart-cities-iot.sql`
A 400-sensor city grid (traffic / air-quality / noise): spatial coverage
diagnostics, an air-quality event detected via `fractal_dimension_dfa`/`_drift`
on a series with a deliberate regime shift, and diverse representative-zone
sampling via Scout. Productized form: `network_coverage_alert`.

### Cybersecurity — `demo-vertical-cybersecurity-threat-detection.sql`
A 35-host fleet across three zones (`fractal_vector(4)`), one host showing a
stealthy compromise — outbound connections, destination ports, and DNS query
volume all spike while failed-auth stays flat (not a brute-force signature).
Diverse traffic-profile clustering for threat hunting, a zone-restricted
("DMZ only") search, compromise detection via `fractal_search_trajectory`, and
beaconing-onset regime detection via `fractal_dimension_dfa`/`_drift`.
Productized form: `track_anomaly` and `recommend_diverse`.

## Agentic kits (model-on, composed agents)

These three compose the six C-level **Universal Agents** into multi-step
**Domain Agents** with PL/pgSQL — every section needs reasoning configured
([reasoning-setup.md](reasoning-setup.md)). The `CREATE OR REPLACE FUNCTION`
blocks at the top of each file are the composition wiring to copy; the
shipped agents are the productized, non-stubbed form of the same
blueprints. See [api-agency.md → Reference blueprints](api-agency.md#reference-blueprints-domain-agents)
for the per-blueprint composition table.

### DevOps / SRE — `demo-vertical-agentic-ops-devops.sql`
A sub-agent dispatcher (`route_task`), a pre-commit safety barrier
(`outlier_intercept`), SOC incident triage (`anomaly_triage`
+ the `threat_triage` blueprint), and a loop-safety monitor
(`detect_loop`). This is the kit to read if you want to see **guardrails
composed in** — the intercept + detect-loop pattern is the template for any
autonomous agent that acts on real systems.

### FinTech — `demo-vertical-agentic-fintech-mcts.sql`
Cardinality-constrained portfolio rebalance (`rebalance_sibling` +
the `portfolio_rebalance` blueprint) and MCTS-style strategy exploration
(`plan_explore`). Read this kit to see **optimization + reasoning composed**:
the SFS Sharpe optimizer runs, then `fractal_reason` writes the rationale for
the weight shift.

### Customer Support — `demo-vertical-agentic-customer-support.sql`
Hybrid memory recall (`recall_hybrid`), feedback-aware
recommendation (`recommend_diverse`), and state-drift forecasting
(`trajectory_predict`). Read this kit to see **retrieval composed with
stateful diversify** — the enable-diversify / search / feedback / re-search
loop wired into a real agent.

## Where next

- **"How does a specific agent work, and what are its inputs?"** → the
  per-agent recipes in [api-agency.md](api-agency.md#the-sixteen-recipes).
- **"How do I build a proprietary agent that isn't in the box?"** →
  [composition-guide.md](composition-guide.md) — the six Universal Agents as
  building blocks and worked composition patterns.
- **All sixteen agents end-to-end** → `psql -f /demo/demo-agents.sql`
  (the regression demo every recipe example is drawn from).