<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Composition Guide: Build Your Own Agent

You have run the [industry starter kits](starter-kits.md) and read the
[sixteen agent recipes](api-agency.md#the-sixteen-recipes). Now the question
is: **how do I build a proprietary agent that isn't in the box?**

The good news: there is no framework to learn. Every FractalSQL primitive
(the search functions, the reasoning bridge, the six Universal Agents) is an
**ordinary SQL function**. A custom agent is just a `CREATE FUNCTION ...
LANGUAGE plpgsql` that calls them in sequence, feeds one's output into the
next's input, and returns a shaped result row. The shipped agents and
the [Domain Agent blueprints](api-agency.md#reference-blueprints-domain-agents)
are exactly this: PL/pgSQL compositions, productized. You write the same
kind of function, for your tables and your workflow.

---

## The six building blocks

These are the C-level **Universal Agents**, callable as soon as
`CREATE EXTENSION fractalsql` runs (they need a reasoning plugin + an
OpenAI-compatible endpoint configured; see
[reasoning-setup.md](reasoning-setup.md)). Full signatures and behaviour are
in [api-agency.md → Building blocks](api-agency.md#building-blocks-the-six-universal-agents);
here is the pick-list.

| Block | Role | Use it when… |
|---|---|---|
| `fractal_search_agent` | Embed → Scout-search → synthesize an answer over retrieved rows | You want a single reasoned answer grounded in a vector corpus |
| `fractal_rag_agent` | Single-turn RAG (embed → Scout → reason) | Same as above, focused one-shot; the lighter RAG pattern |
| `fractal_sql_agent` | NL → SQL with self-correction on `EXPLAIN`/exec failure | You need structured answers from tables, not vector prose |
| `fractal_agent_plan_explore` | MCTS-style diverse strategy trajectories | You need *multiple* non-overlapping plans, not one answer |
| `fractal_agent_trajectory_predict` | Forecast state by matching a drift delta-vector in history | You need "where is this heading, based on past drift?" |
| `fractal_agent_detect_loop` | DFA-based infinite-loop / repetition detector | You need a safety monitor on an autonomous agent's state log |

Underneath these, the **Discovery primitives** (`fractal_search`,
`fractal_search_explore`, `fractal_search_trajectory`, `fractal_search_telemetry`,
`fractal_optimize_portfolio`, the `fractal_dimension_*` family) are also
ordinary functions you can chain directly when a Universal Agent is more than
you need.

---

## The composition principle

A composition is a pipeline with up to four stages:

1. **Retrieve**: find the relevant rows (Scout for diversity, or a trajectory
   search for "what changed"). Either call a Discovery primitive directly or
   let `fractal_search_agent` / `fractal_rag_agent` do embed→search for you.
2. **Reason**: `fractal_reason(query, context)` over the retrieved rows'
   *content* (not their raw vectors; the Universal Agents fetch the matched
   rows' non-vector columns by `ctid` and pass that compact JSON to the LLM).
3. **Act** (optional): `fractal_sql_agent` with `auto_execute => true` when
   the agent must run a query, under a guardrailed role (below).
4. **Guard** (optional): `fractal_agent_detect_loop` on the agent's state-hash
   log, and/or `fractal_agent_outlier_intercept`-style screening of a proposed
   action against known-bad states.

Stages 1–2 are the common case (most "answer my data" agents). Add 3 when the
agent must *do* something. Add 4 any time the agent is autonomous.

---

## Worked patterns

### Pattern A — "Answer my corpus" (single-turn RAG)

The simplest useful agent, and you usually don't even need to compose it:
call the block directly:

```sql
SELECT answer FROM fractal_rag_agent(
    'What does our runbook say about a node that stops heartbeating?',
    'runbook_chunks', 'emb'
);
```

Compose it yourself only when you want to shape the output or pre-filter the
corpus with SQL the block doesn't expose yet:

```sql
CREATE OR REPLACE FUNCTION tier1_answer(q text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE ctx text; ans text;
BEGIN
  -- narrow the corpus with ordinary SQL first, then reason over it
  SELECT string_agg(row_to_json(t)::text, ', ')
    INTO ctx
    FROM (SELECT title, body FROM runbook_chunks
           WHERE team = 'sre' AND updated_at > now() - interval '90 days'
           ORDER BY updated_at DESC LIMIT 25) t;
  SELECT fractal_reason(q, ctx) INTO ans;
  RETURN ans;
END $$;
```

### Pattern B — Self-correcting read-only analyst

`fractal_sql_agent` generates SQL and (with `auto_execute => true`) runs it,
retrying on `EXPLAIN` or execution failure. Compose it when the user's
question is about *tables*, not vector prose. **Always** behind the guardrails
in [Safe Agency](#safe-agency--guardrails):

```sql
-- run as a least-privilege role; restrict the statement classes the agent may emit
ALTER ROLE fractal_analyst SET text_to_sql_allowed_statements = 'SELECT';

SELECT generated_sql, execution_status, result_json
  FROM fractal_sql_agent(
    'total spend per category last quarter',
    ARRAY['invoices'], max_retries => 2, auto_execute => true);
```

The `data_analyst` agent is the productized version of this:
NL→SQL inside its own composition, with the retry loop and a reasoned summary
of the result row.

### Pattern C — Multi-step agent with a safety barrier

This is the pattern the [DevOps starter kit](starter-kits.md#agentic-kits-model-on-composed-agents)
productizes: retrieve → act → guard. A minimal skeleton:

```sql
CREATE OR REPLACE FUNCTION tier1_resolve(
    incident_id bigint, question text
) RETURNS table(step text, detail text) LANGUAGE plpgsql AS $$
DECLARE
    retrieved jsonb;  sql_res record;  state_hashes bigint[];
BEGIN
  -- 1. RETRIEVE: Scout-search the incident corpus for relevant context
  SELECT jsonb_agg(row_to_json(t))
    INTO retrieved
    FROM (SELECT title, body FROM incident_notes
           WHERE incident_id = tier1_resolve.incident_id
           ORDER BY updated_at DESC LIMIT 20) t;

  -- 2. ACT: if retrieval is thin, fall back to NL->SQL over the metrics tables
  IF jsonb_array_length(COALESCE(retrieved, '[]'::jsonb)) < 3 THEN
    SELECT generated_sql, execution_status INTO sql_res
      FROM fractal_sql_agent(question, ARRAY['metrics'], auto_execute => true);
    RETURN QUERY SELECT 'sql_fallback', sql_res.generated_sql;
  END IF;

  -- 3. REASON over the retrieved context
  RETURN QUERY SELECT 'answer',
    fractal_reason(question, retrieved::text);

  -- 4. GUARD: log this agent step's state hash and check for a loop
  state_hashes := array_agg(hashtextextended(question || retrieved::text, 0));  -- your state hash
  -- on a real loop: array_agg(state_hash ORDER BY event_ts) from an event log
  RETURN QUERY SELECT 'loop_check',
    (SELECT ('loop=' || is_loop_detected || ' alpha=' || dfa_exponent::text)
       FROM fractal_agent_detect_loop(state_hashes));
END $$;
```

> The skeleton is illustrative. `hashtextextended` is a stand-in; your state-hash scheme is yours
> to define. The wiring (retrieve, fall back to `fractal_sql_agent`, reason,
> then `fractal_agent_detect_loop` on the state log) is the part to copy. The
> shipped `route_task` + `outlier_intercept` +
> `detect_loop` composition in
> `demo/demo-vertical-agentic-ops-devops.sql` is the full, runnable form.

---

## Safe Agency & Guardrails

`fractal_sql_agent` (and any composition that calls it with
`auto_execute => true`) generates and executes arbitrary SQL. Treat it the way
you'd treat any NL→SQL surface:

- **Run it under a least-privilege role.** Grant the connecting role only the
  schema/table privileges you want the agent to be able to read or write.
  Pattern B's `fractal_analyst` role is the model.
- **Restrict the allowed statements.** The `text_to_sql_allowed_statements`
  GUC gates which statement classes the agent may emit; tighten it to the set
  your workload needs (e.g. `SELECT` only for a read-only analyst).
- **Prefer `auto_execute => false` for exploratory use.** Let the caller
  review `generated_sql` and run it themselves. The cognition agents (e.g.
  `data_analyst`) pass `true` deliberately, *inside* their own composition with
  the role and allowlist already locked down.

For autonomous agents (Pattern C), add the **safety barriers** the DevOps
blueprint uses: `fractal_agent_detect_loop` on the state-hash log to catch
infinite loops, and an `outlier_intercept`-style screen that checks a proposed
action's state vector against known-bad state clusters before the action runs.

---

## Two gotchas to carry over

These bit the shipped agents; they'll bite yours too.

- **`id_col` must be bigint-castable.** The table-searching agents
  (`recall_hybrid`, `recommend_diverse`, `patient_deterioration_triage`,
  `schedule_workload`, `rebalance_sibling`, `detour_classify`,
  `track_anomaly`) resolve the C code's 0-indexed row position to your named
  id column via `row_number() OVER (ORDER BY ctid) - 1`. A text label column
  won't do; pass the numeric PK. See
  [api-agency.md → A note on id resolution](api-agency.md#a-note-on-id-resolution).
- **Diversify is session-global.** `recommend_diverse` calls
  `fractal_diversify_enable()` as a session side effect so re-searches avoid
  recently-rejected items. Reset it with `fractal_diversify_disable()` when
  your session is done, or call `feedback_audit`, which runs the
  whole audit cycle and self-disables.

---

## Where next

- **Full signatures and per-agent behaviour** →
  [api-agency.md](api-agency.md) (the six Universal Agents block and the
  sixteen recipes).
- **Runnable compositions to copy** → the three agentic starter kits
  ([starter-kits.md](starter-kits.md#agentic-kits-model-on-composed-agents));
  each one's `CREATE OR REPLACE FUNCTION` blocks are the wiring.
- **Configure the reasoning endpoint** the Universal Agents call →
  [reasoning-setup.md](reasoning-setup.md).
- **Validate your composition** against the same demo path the shipped agents
  use → `psql -f /demo/demo-agents.sql`.