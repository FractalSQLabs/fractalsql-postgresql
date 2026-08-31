-- =============================================================================
-- FractalSQL Industry Vertical Demo: Stateful Session & Churn Drift
-- =============================================================================
-- End-to-end regression test for the trajectory-forecast agent. Exercises:
--   * fractal_agent_trajectory_predict  -- de-stubbed (C fix A3): now reads the
--     baseline vector (by PK = baseline_id) and the latest vector (max PK) from
--     the table, derives dim from the data, computes a real delta, and searches
--     the corpus for the nearest predicted state. No more hardcoded 1536 /
--     uninitialized-buffer placeholder -- it runs unwrapped on the 3-dim
--     state_vector column here.
--   * fractal_search_explore            -- pure-C Scout search on a literal vector
--   * fractal_agent_recall_hybrid       -- the REAL shipped fractalsql_agents
--     engine (hybrid_clinical_search + ctid id resolution), not a local stub
--   * fractal_agent_recommend_diverse   -- the REAL shipped fractalsql_agents
--     engine (repulsion-diverse top-k), not a local stub
--   * fractal_diversify_enable
-- Re-runnable (DROP at the top).
--
-- This demo previously shadowed fractal_agent_recall_hybrid/
-- recommend_diverse with local CREATE OR REPLACE FUNCTION stubs that
-- returned canned generate_series output ("recalled memory snippet N",
-- a fake 0.95-i*0.01 score) instead of calling the real engines shipped
-- in fractalsql_agents/. Those stubs predate that extension; this
-- version calls the real, fully-implemented agents against real demo
-- data instead.
-- =============================================================================

DROP TABLE IF EXISTS customer_sessions, customer_playbook, product_catalog CASCADE;

-- 1. Setup customer session telemetry -- a single customer (cust-abc) drifting
-- from onboarding toward churn across five sessions. session_id is the PK the
-- trajectory_predict agent resolves via pg_catalog; the latest row (max PK,
-- session_id = 103) is "current", and baseline_id (100) is "baseline".
CREATE TABLE customer_sessions (
    session_id        bigint PRIMARY KEY,
    customer_id       text,
    state_vector      float8[],
    sentiment_score    float8,
    last_interaction  timestamp
);

INSERT INTO customer_sessions (session_id, customer_id, state_vector, sentiment_score, last_interaction)
VALUES
(100, 'cust-abc', ARRAY[0.1, 0.1, 0.1], 0.8, now() - interval '30 days'),
(101, 'cust-abc', ARRAY[0.3, 0.15, 0.1], 0.6, now() - interval '20 days'),
(102, 'cust-abc', ARRAY[0.6, 0.2, 0.1], 0.4, now() - interval '10 days'),
(103, 'cust-abc', ARRAY[0.8, 0.2, 0.1], 0.2, now());

-- 2. A playbook of past churn-recovery cases: what worked (or didn't) for
-- other customers whose state vector, at the point of intervention, looked
-- like this. fractal_agent_recall_hybrid searches this by real vector
-- similarity against session 103's current state.
CREATE TABLE customer_playbook (
    case_id       bigint PRIMARY KEY,
    customer_id   text,
    state_vector  float8[],
    resolution    text
);

INSERT INTO customer_playbook (case_id, customer_id, state_vector, resolution) VALUES
(1, 'cust-def', ARRAY[0.75, 0.22, 0.12], 'Escalated to a retention specialist with a loyalty discount; saved'),
(2, 'cust-ghi', ARRAY[0.30, 0.10, 0.05], 'Proactive check-in call resolved early-stage frustration'),
(3, 'cust-jkl', ARRAY[0.82, 0.18, 0.09], 'Offered a downgrade path instead of cancellation; saved'),
(4, 'cust-mno', ARRAY[0.05, 0.05, 0.05], 'No intervention needed, healthy customer');

-- 3. A retention-offer catalog for recommend_diverse to pick a diverse,
-- non-redundant set of interventions from.
CREATE TABLE product_catalog (
    item_id  bigint PRIMARY KEY,
    name     text,
    emb      float8[]
);

INSERT INTO product_catalog (item_id, name, emb) VALUES
(1, 'Loyalty Discount 20%',      ARRAY[0.80, 0.20, 0.10]),
(2, 'Free Premium Upgrade',      ARRAY[0.75, 0.25, 0.15]),
(3, 'Dedicated Support Line',    ARRAY[0.60, 0.30, 0.20]),
(4, 'Downgrade to Basic Plan',   ARRAY[0.40, 0.10, 0.05]),
(5, 'Early Renewal Bonus',       ARRAY[0.20, 0.10, 0.10]);

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Enable stateful diversification to avoid repeating failed scripts
SELECT fractal_diversify_enable();

-- 5. Forecast trajectory drift toward churn
-- Searches the corpus for the nearest predicted state to the delta between
-- the baseline session (100) and the latest session (103). Returns a real
-- predicted_state_vector (length 3, derived from the data) and a
-- projected_drift_delta, not the old 1536-dim placeholder. Runs unwrapped.
SELECT * FROM fractal_agent_trajectory_predict(
    'customer_sessions', 'state_vector',
    100,  -- baseline_id (onboarding)
    5     -- forecast steps
);

-- 6. Hybrid Memory Recall (the real fractal_agent_recall_hybrid engine)
-- Recall past playbook cases whose state vector, at intervention time, was
-- close to this customer's current drifting state (session 103).
SELECT mem_id, content
FROM fractal_agent_recall_hybrid(
    'customer_playbook', 'state_vector',
    ARRAY[0.8, 0.2, 0.1]::float8[],
    NULL, NULL,   -- no cohort filter: search the whole playbook
    5, 'case_id', 'resolution'
);

-- 7. Repulsion-guided intervention
-- Use fractal_search to find the most diverse (non-redundant) recovery strategies
SELECT * FROM fractal_search_explore(
    'customer_sessions', 'state_vector',
    ARRAY[0.8, 0.2, 0.1],
    '{"population_size": 5}'
);

-- 8. Diverse Recommendations (the real fractal_agent_recommend_diverse engine)
-- Repulsion-diverse top-k retention offers for this customer's current state.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'product_catalog', 'emb',
    ARRAY[0.8, 0.2, 0.1]::float8[],
    5, 'item_id'
);
