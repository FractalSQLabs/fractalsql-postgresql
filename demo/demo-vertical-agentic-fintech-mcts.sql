-- =============================================================================
-- FractalSQL Industry Vertical Demo: Scenario Exploration & Safe Execution
-- =============================================================================
-- End-to-end regression test for the planning + text-to-sql agents. Exercises:
--   * fractal_agent_plan_explore     -- embeds the seed state, Scout-searches
--                                       a real 768-dim embedding column (the
--                                       embed-coupling now satisfied by the
--                                       vectorizer, so this runs unwrapped)
--   * fractal_sql_agent              -- auto-executes model-generated SQL inside
--                                       a subtransaction (C fix A2: a thrown
--                                       ERROR is caught and surfaced as
--                                       execution_status='execution_failed',
--                                       not propagated to abort the call)
--   * fractal_optimize_portfolio     -- SFS-based cardinality-constrained allocation
--   * fractal_reason                 -- rationale synthesis
--   * fractal_vectorizer_*           -- vectorizes strategy descriptions
-- Re-runnable (see the teardown block at the top).
-- =============================================================================

DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'trade_strategies');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'trade_strategies');
DELETE FROM fractal_vectorizers WHERE source_table = 'trade_strategies';
DROP TABLE IF EXISTS trade_strategies, portfolios, assets, restrictions CASCADE;

-- 1. Setup financial strategy space
CREATE TABLE trade_strategies (
    strategy_id     bigint PRIMARY KEY,
    description     text,                 -- vectorized below
    embedding       fractal_vector(768),  -- populated by the vectorizer (nomic-embed-text)
    trajectory      float8[],
    constraints     jsonb,
    expected_return float8
);

INSERT INTO trade_strategies (strategy_id, description, trajectory, constraints, expected_return)
VALUES
(1, 'low-volatility mean-reversion strategy targeting ESG-compliant equities with tight risk bounds',
        ARRAY[0.1, 0.2], '{"max_risk": 0.05}', 0.08),
(2, 'momentum strategy riding medium-term trends with moderate risk tolerance and diversified sector exposure',
        ARRAY[0.5, 0.1], '{"max_risk": 0.10}', 0.12),
(3, 'high-conviction concentrated strategy with strict risk budget and low expected turnover',
        ARRAY[0.9, 0.8], '{"max_risk": 0.02}', 0.04);

-- 2. Vectorize the strategy descriptions into 768-dim embeddings. This is the
-- embedding-width column fractal_agent_plan_explore needs (it embeds the
-- initial_state text and Scout-searches this column).
SELECT fractal_vectorizer_create('trade_strategies', 'description', 'embedding');
SELECT fractal_vectorizer_process_queue();

-- 3. Portfolio/asset/restriction tables referenced by the fractal_sql_agent
-- regulatory-audit step. Minimal seed so the agent's schema context
-- (fractal_schema_context) can resolve the table_names it is given.
CREATE TABLE portfolios (
    portfolio_id int PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE assets (
    asset_id int PRIMARY KEY,
    portfolio_id int NOT NULL,
    value numeric NOT NULL,
    esg_restricted boolean NOT NULL DEFAULT false
);
CREATE TABLE restrictions (
    restriction_id int PRIMARY KEY,
    asset_id int NOT NULL,
    restriction_type text NOT NULL
);
INSERT INTO portfolios (portfolio_id, name) VALUES
    (1, 'Global Growth'), (2, 'ESG Core'), (3, 'High Yield');
INSERT INTO assets (asset_id, portfolio_id, value, esg_restricted) VALUES
    (101, 1, 250000, false),
    (102, 1, 120000, true),
    (103, 2,  80000, true),
    (104, 3, 310000, false);
INSERT INTO restrictions (restriction_id, asset_id, restriction_type) VALUES
    (1, 102, 'ESG-fossil-fuel'),
    (2, 103, 'ESG-weapons');

-- -----------------------------------------------------------------------------
-- DOMAIN AGENT IMPLEMENTATIONS (PL/pgSQL Compositions)
-- -----------------------------------------------------------------------------

-- Cardinality-Constrained Allocator: Executes Sharpe optimization + drift analysis
CREATE OR REPLACE FUNCTION fractal_agent_portfolio_rebalance(portfolio_id text, target_cardinality int)
RETURNS TABLE(new_weights jsonb, drift_score float8, rationale text) AS $$
DECLARE
    opt_res jsonb;
    reason_res text;
BEGIN
    -- 1. Run the Core Optimizer (SFS-based). cov must be a FLATTENED 1-D
    -- array of length n_assets^2 (fractal_optimize_portfolio reads it via
    -- float8_array_to_doubles, which rejects 2-D matrices); the 2x2 identity
    -- here is [1,0,0,1] row-major. See demo-vertical-quant-finance.sql for the
    -- array_agg pattern at real scale.
    opt_res := fractal_optimize_portfolio(ARRAY[0.05, 0.1], ARRAY[1.0, 0.0, 0.0, 1.0], target_cardinality);

    -- 2. Synthesize the rationale for the shift
    reason_res := fractal_reason(
        'Explain why this portfolio rebalance is necessary based on the new weights: ' || opt_res::text,
        '{"portfolio": "' || portfolio_id || '"}'
    );

    RETURN QUERY SELECT
        opt_res,
        0.042::float8,
        reason_res;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. MCTS-style strategy exploration
-- Explore N non-overlapping execution paths starting from a seed market state.
-- fractal_agent_plan_explore embeds the initial_state text (->768) and
-- Scout-searches the trade_strategies.embedding column for diverse branches.
SELECT * FROM fractal_agent_plan_explore(
    'momentum strategy with moderate risk',
    'trade_strategies', 'embedding',
    max_branches => 3
);
-- Result: 3 diverse branch_ids with confidence scores

-- 5. Self-correcting Text-to-SQL for regulatory audit
-- Ask for a complex regulatory report, with auto-execution and retries. The
-- generated SQL runs inside a subtransaction (C fix A2): a thrown ERROR is
-- caught and returned as execution_status='execution_failed' + the error in
-- result_json, rather than aborting the whole agent call. On a working model
-- it returns execution_status='executed' and the row count in result_json.
SELECT * FROM fractal_sql_agent(
    'Calculate the total exposure to ESG-restricted assets across all portfolios',
    ARRAY['portfolios', 'assets', 'restrictions'],
    max_retries => 3,
    auto_execute => true
);

-- 6. Portfolio Rebalance
SELECT * FROM fractal_agent_portfolio_rebalance('port-global-01', 2);

-- 7. Safe Execution in Subtransactions
-- The auto_execute above runs the generated SQL inside a subtransaction to
-- ensure that any late-stage constraint violation doesn't abort the whole
-- session.