-- demo/demo-vertical-quant-finance.sql
--
-- Industry vertical: Quantitative Finance & Algorithmic Trading.
--
-- A cardinality-constrained portfolio problem (25 synthetic assets, a
-- 4-factor covariance model, optimize down to an 8-asset book) plus a
-- price series with a deliberate volatility regime change for DFA-based
-- regime detection -- a real, established DFA application (detecting
-- when a market series stops behaving like its own recent history).
--
-- Prerequisites: extension installed (sections 0-3 need nothing else).
-- Section 4 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-quant-finance.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-quant-finance.sql
--
-- Safe to re-run: vqf_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.42);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 25 synthetic assets, 4-factor covariance model (same construction
-- style as fractalsql-core's own portfolio-optimizer factor-model test
-- fixture): cov[i,j] = sum_f loadings[i,f]*loadings[j,f] + idio[i] on
-- the diagonal. mu is each asset's expected return.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 25 synthetic assets, 4-factor covariance model ==='

DROP TABLE IF EXISTS vqf_assets;
DROP TABLE IF EXISTS vqf_loadings;
CREATE TABLE vqf_assets (asset_id int PRIMARY KEY, symbol text, mu float8, idio float8);
CREATE TABLE vqf_loadings (asset_id int, factor_id int, loading float8, PRIMARY KEY (asset_id, factor_id));

INSERT INTO vqf_assets (asset_id, symbol, mu, idio)
SELECT a, 'TICK' || a, -0.02 + random() * 0.17, 0.02 + random() * 0.06
FROM generate_series(1, 25) a;

INSERT INTO vqf_loadings (asset_id, factor_id, loading)
SELECT a.asset_id, f, (random() - 0.5) * 0.6
FROM vqf_assets a
CROSS JOIN generate_series(1, 4) f;

-- Flat, row-major n*n covariance array -- exactly what
-- fractal_optimize_portfolio(mu, cov, k, seed) expects.
DROP TABLE IF EXISTS vqf_cov_flat;
CREATE TEMP TABLE vqf_cov_flat AS
SELECT ai.asset_id AS i, aj.asset_id AS j,
       (SELECT sum(li.loading * lj.loading)
          FROM vqf_loadings li, vqf_loadings lj
         WHERE li.asset_id = ai.asset_id AND lj.asset_id = aj.asset_id
           AND li.factor_id = lj.factor_id)
       + CASE WHEN ai.asset_id = aj.asset_id THEN ai.idio ELSE 0 END AS cov_ij
FROM vqf_assets ai
CROSS JOIN vqf_assets aj;

SELECT count(*) AS assets, (SELECT count(*) FROM vqf_cov_flat) AS cov_entries FROM vqf_assets;

-- ------------------------------------------------------------------
-- 2. Cardinality-constrained Sharpe-ratio optimization: pick the best
-- 8 of 25 assets. ~28x faster than scipy differential_evolution at
-- near-equal quality on this problem class (validated separately,
-- see fractalsql-core's optimizer work) -- the one place the SFS
-- engine has a proven edge.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_optimize_portfolio: best 8-of-25 asset book ==='

-- Blueprint (raw primitive): the SFS cardinality-constrained Sharpe
-- maximizer (pick the best 8 of 25 assets). Generalized by the shipped
-- fractal_agent_rebalance_sibling preset in Section 4, which runs this
-- optimizer, finds the nearest historical allocation pattern
-- (fractal_search_trajectory over the Section 4 snapshot fixture), and
-- reasons -- so the preset call sits after that fixture is built.
-- DROP TABLE IF EXISTS vqf_result;
-- CREATE TEMP TABLE vqf_result AS
-- SELECT fractal_optimize_portfolio(
--     (SELECT array_agg(mu ORDER BY asset_id) FROM vqf_assets),
--     (SELECT array_agg(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
--     8, 42
-- ) AS result;
--
-- SELECT result -> 'sharpe' AS sharpe FROM vqf_result;
-- SELECT a.symbol, w.weight
-- FROM vqf_result r
-- CROSS JOIN LATERAL jsonb_array_elements_text(r.result -> 'weights') WITH ORDINALITY AS w(weight, ord)
-- JOIN vqf_assets a ON a.asset_id = w.ord
-- WHERE w.weight::float8 > 1e-9
-- ORDER BY w.weight::float8 DESC;
\echo '(raw optimizer form preserved above; productized as fractal_agent_rebalance_sibling in Section 4)'

-- ------------------------------------------------------------------
-- 3. A 300-point price series with a deliberate volatility regime
-- change at t=150 (low-vol -> high-vol) -- fractal_dimension_dfa's
-- self-check pattern (white noise ~0.5, random walk ~1.5) applied to
-- something with an actual regime change baked in, and
-- fractal_dimension_drift(series, win) to detect it automatically
-- rather than eyeballing the exponent.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Price series with a volatility regime change at t=150 ==='

DROP TABLE IF EXISTS vqf_price_series;
CREATE TEMP TABLE vqf_price_series AS
SELECT array_agg(cum ORDER BY t) AS series
FROM (
    SELECT t,
           sum(CASE WHEN t <= 150 THEN (random() - 0.5) * 0.02
                    ELSE                (random() - 0.5) * 0.14 END)
             OVER (ORDER BY t ROWS UNBOUNDED PRECEDING) AS cum
    FROM generate_series(1, 300) t
) s;

-- Blueprint (raw primitives): the price series' DFA exponent (long-range
-- correlation) and its drift report (regime-change detection). Generalized
-- below by the shipped fractal_agent_regime_triage preset, which runs both
-- over the same series and reasons.
-- SELECT fractal_dimension_dfa(series) AS whole_series_alpha FROM vqf_price_series;
-- SELECT fractal_dimension_drift(series, 64) AS drift_report FROM vqf_price_series;

-- Productized preset: the shipped engine returns the real DFA exponent,
-- the real drift_detected flag (|drift| > 0.5), and the real
-- recent_alpha/baseline_alpha, plus a real rationale.
\echo '--- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---'
SELECT dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale
FROM fractal_agent_regime_triage(
    (SELECT series FROM vqf_price_series),
    64, 0.5);

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: which of 10 historical quarterly
-- rebalance snapshots does THIS rebalance (equal-weight baseline ->
-- the optimized book from Section 2) most resemble? "What changed",
-- not "what's closest" -- the natural query shape for drift.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_search_trajectory: nearest historical rebalance pattern ==='

DROP TABLE IF EXISTS vqf_allocation_snapshots;
-- fractal_vector(25), not float8[] -- fixed width (one weight per
-- asset), same dimension-safety argument as the other updated
-- verticals. INSERT below is unchanged (::float8[] via array_agg) --
-- the assignment cast coerces it on write.
CREATE TABLE vqf_allocation_snapshots (id serial PRIMARY KEY, quarter text, alloc fractal_vector(25));

-- Flat CROSS JOIN, not ARRAY(subquery) -- an uncorrelated subquery body
-- (one that never references the outer generate_series(1,10) row) gets
-- hoisted into a one-shot InitPlan and evaluated ONCE for the whole
-- INSERT, silently making every "quarter" identical despite random()
-- being volatile. See demo/benchmark.sql's own comment on this same
-- trap. A flat cross join has no nested subquery to hoist -- every
-- (snapshot, asset) pair gets its own random() call, provably.
CREATE TEMP TABLE vqf_snapshot_raw AS
SELECT gs AS snapshot_id, a.asset_id,
       CASE WHEN random() < 0.35 THEN random() ELSE 0 END AS raw_val
FROM generate_series(1, 10) gs
CROSS JOIN vqf_assets a;

CREATE TEMP TABLE vqf_snapshot_sums AS
SELECT snapshot_id, GREATEST(sum(raw_val), 1e-9) AS total
FROM vqf_snapshot_raw
GROUP BY snapshot_id;

INSERT INTO vqf_allocation_snapshots (quarter, alloc)
SELECT 'Q' || r.snapshot_id || '-hist',
       array_agg(r.raw_val / s.total ORDER BY r.asset_id)
FROM vqf_snapshot_raw r
JOIN vqf_snapshot_sums s ON s.snapshot_id = r.snapshot_id
GROUP BY r.snapshot_id, s.total
ORDER BY r.snapshot_id ASC;

-- Blueprint (raw primitive): the nearest historical rebalance pattern to
-- the optimized book (equal-weight baseline -> the Section 2 optimized
-- weights). Generalized below by the shipped fractal_agent_rebalance_sibling
-- preset, which runs the optimizer itself, finds this nearest pattern, and
-- reasons. (id_col is the snapshot's bigint id, not its text quarter label
-- -- the engine resolves the nearest id as a bigint.)
-- WITH baseline AS (
--     SELECT array_agg((1.0 / 25.0)::float8 ORDER BY asset_id)::fractal_vector AS v FROM vqf_assets
-- )
-- SELECT snap.quarter, snap_doc.distance
-- FROM baseline b, vqf_result r,
--      fractal_search_trajectory(
--          'vqf_allocation_snapshots', 'alloc',
--          b.v,
--          (SELECT array_agg((w.weight)::float8 ORDER BY w.ord)::fractal_vector
--             FROM jsonb_array_elements_text(r.result -> 'weights') WITH ORDINALITY AS w(weight, ord)),
--          3
--      ) AS snap_doc(doc_id, distance)
-- JOIN vqf_allocation_snapshots snap ON snap.id = snap_doc.doc_id + 1;

-- Productized preset: the shipped engine runs the SFS optimizer
-- (best 8-of-25), finds the nearest historical allocation pattern to the
-- equal-weight baseline -> optimized weights, resolves it to the real
-- snapshot id via ctid, and reasons. sharpe/weights/nearest_alloc_id/
-- nearest_distance are real; rationale is the real fractal_reason output.
\echo '--- Preset: fractal_agent_rebalance_sibling (raw optimizer+trajectory form preserved above) ---'
SELECT sharpe, weights, nearest_alloc_id, nearest_distance, rationale
FROM fractal_agent_rebalance_sibling(
    (SELECT array_agg(mu ORDER BY asset_id) FROM vqf_assets),
    (SELECT array_agg(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
    8, 'vqf_allocation_snapshots', 'alloc',
    (SELECT array_agg((1.0 / 25.0)::float8 ORDER BY asset_id) FROM vqf_assets),
    42, 5, 'id', '{}'::text);

-- ------------------------------------------------------------------
-- 5. Reasoning: the regime-shift + optimized-allocation narrative is now
-- split across two preset rationales -- fractal_agent_regime_triage
-- (Section 3, the market regime shift) and fractal_agent_rebalance_sibling
-- (Section 4, the optimized book + its nearest historical pattern).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: absorbed into the Section 3 + Section 4 preset rationales ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;'
