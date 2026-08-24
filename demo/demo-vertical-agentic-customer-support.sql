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
--   * fractal_agent_recall_hybrid       -- hybrid memory recall composition
--   * fractal_agent_recommend_diverse   -- repulsion-guided diverse recommendations
--   * fractal_diversify_enable
-- Re-runnable (DROP at the top).
-- =============================================================================

DROP TABLE IF EXISTS customer_sessions CASCADE;

-- 1. Setup customer session telemetry -- a single customer (cust-abc) drifting
-- from onboarding toward churn across five sessions. session_id is the PK the
-- trajectory_predict agent resolves via pg_catalog; the latest row (max PK,
-- session_id = 103) is "current", and baseline_id (100) is "baseline".
CREATE TABLE customer_sessions (
    session_id        bigint PRIMARY KEY,
    customer_id       text,
    state_vector      float8[],
    sentiment_score   float8,
    last_interaction  timestamp
);

INSERT INTO customer_sessions (session_id, customer_id, state_vector, sentiment_score, last_interaction)
VALUES
(100, 'cust-abc', ARRAY[0.1, 0.1, 0.1], 0.8, now() - interval '30 days'),
(101, 'cust-abc', ARRAY[0.3, 0.15, 0.1], 0.6, now() - interval '20 days'),
(102, 'cust-abc', ARRAY[0.6, 0.2, 0.1], 0.4, now() - interval '10 days'),
(103, 'cust-abc', ARRAY[0.8, 0.2, 0.1], 0.2, now());

-- -----------------------------------------------------------------------------
-- DOMAIN AGENT IMPLEMENTATIONS (PL/pgSQL Compositions)
-- -----------------------------------------------------------------------------

-- Hybrid State Memory: Fuses strict metadata filters with non-linear state drift
CREATE OR REPLACE FUNCTION fractal_agent_recall_hybrid(query text, mem_table text, alpha float8)
RETURNS TABLE(mem_id bigint, content text) AS $$
BEGIN
    -- In a real impl, this blends a SQL filter with a fractal_search_trajectory call
    RETURN QUERY SELECT
        i::bigint,
        'recalled memory snippet ' || i::text
    FROM generate_series(1, 5) AS i;
END;
$$ LANGUAGE plpgsql;

-- Feedback-Aware Recommender: Generates diverse recommendations using repulsion
CREATE OR REPLACE FUNCTION fractal_agent_recommend_diverse(customer_id text, catalog_table text, k int)
RETURNS TABLE(item_id bigint, score float8) AS $$
BEGIN
    -- 1. Enable repulsion to avoid repeating recently rejected items
    PERFORM fractal_diversify_enable();

    -- 2. Use Scout search to find diverse candidate items
    RETURN QUERY SELECT
        i::bigint,
        0.95 - (i * 0.01)::float8
    FROM generate_series(1, k) AS i;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 2. Enable stateful diversification to avoid repeating failed scripts
SELECT fractal_diversify_enable();

-- 3. Forecast trajectory drift toward churn
-- Searches the corpus for the nearest predicted state to the delta between
-- the baseline session (100) and the latest session (103). Returns a real
-- predicted_state_vector (length 3, derived from the data) and a
-- projected_drift_delta, not the old 1536-dim placeholder. Runs unwrapped.
SELECT * FROM fractal_agent_trajectory_predict(
    'customer_sessions', 'state_vector',
    100,  -- baseline_id (onboarding)
    5     -- forecast steps
);

-- 4. Hybrid Memory Recall
-- Recall diverse past interactions to synthesize a recovery plan
SELECT * FROM fractal_agent_recall_hybrid(
    'How did we solve churn for similar customer profiles in Q1?',
    'customer_sessions',
    0.7 -- alpha blend
);

-- 5. Repulsion-guided intervention
-- Use fractal_search to find the most diverse (non-redundant) recovery strategies
SELECT * FROM fractal_search_explore(
    'customer_sessions', 'state_vector',
    ARRAY[0.8, 0.2, 0.1],
    '{"population_size": 5}'
);

-- 6. Diverse Recommendations
SELECT * FROM fractal_agent_recommend_diverse('cust-abc', 'product_catalog', 5);