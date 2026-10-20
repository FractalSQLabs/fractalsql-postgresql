-- demo/demo-vertical-climatech-grid-balancing.sql
--
-- Industry vertical: Climate Tech -- renewable and storage generation
-- balancing on a distribution grid.  AGENTIC kit: a hand-composed chain,
-- then the shipped agents doing each step in one call.
--
--   1. fractal_dimension_dfa / _drift over grid-frequency telemetry --
--      detects a stability regime change (the same recipe the quant-
--      finance kit uses for volatility regimes, applied to a grid).
--   2. fractal_optimize_portfolio (SFS) -- reallocates generation and
--      storage dispatch across nodes under a cardinality constraint,
--      using a ramp-risk matrix in which correlated renewables carry
--      shared weather risk.
--   3. A closing fractal_reason() gives the dispatch-plan rationale.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Sections 1-3's hand-composed steps need no model;
-- the shipped agents and the closing rationale are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-climatech-grid-balancing.sql
--
-- Safe to re-run: cgb_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * The drift window is 32 points, so each area needs >= 48 readings.
--     The instability is an ACCELERATING oscillation envelope, not a
--     level shift: DFA removes a constant offset, so only a change in the
--     series' dynamics moves the exponent.
--   * The optimizer maximizes a Sharpe-style ratio: mu is dispatch value
--     per unit of capacity moved, the matrix is ramp risk.  Two variable
--     renewables (solar, wind) share weather risk (correlation 0.6);
--     batteries and hydro are nearly independent.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Grid-frequency telemetry for three balancing areas, 96 samples
-- each (deviation from nominal, mHz).  AREA-C loses damping from sample
-- 65: its oscillation envelope grows quadratically.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Grid-frequency deviation: 3 areas x 96 samples ==='

DROP TABLE IF EXISTS cgb_freq;
CREATE TABLE cgb_freq (
    area    text,
    sample  int,
    dev_mhz float8
);
INSERT INTO cgb_freq (area, sample, dev_mhz)
SELECT area, g,
       4.0 + (g % 8) * 0.8
         + CASE WHEN area = 'AREA-C' AND g > 64
                THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END
FROM (VALUES ('AREA-A'), ('AREA-B'), ('AREA-C')) AS a(area),
     generate_series(1, 96) AS g;

SELECT area, count(*) AS samples, round(max(dev_mhz)::numeric, 2) AS peak_dev_mhz
  FROM cgb_freq GROUP BY area ORDER BY area;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: stability-regime drift per area.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Step 1 (hand-composed): frequency-stability drift per area ==='

SELECT area,
       round((d->>'drift')::numeric, 4)          AS drift,
       round((d->>'recent_alpha')::numeric, 4)   AS recent_alpha,
       round((d->>'baseline_alpha')::numeric, 4) AS baseline_alpha
FROM (SELECT area, fractal_dimension_drift(array_agg(dev_mhz ORDER BY sample), 32) AS d
        FROM cgb_freq GROUP BY area) x
ORDER BY area;

\echo '--- the shipped agent: same composition, one call (reasoning plugin) ---'
SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('cgb_freq', 'dev_mhz', 'sample', 'area', 'AREA-C', 32);

-- ------------------------------------------------------------------
-- 3. Step 2: the dispatch set.  Six resources; pick the 4 that carry
-- the AREA-C instability response with the best risk-adjusted value.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Step 2: fractal_optimize_portfolio -- pick 4 of 6 resources ==='

DROP TABLE IF EXISTS cgb_resources;
CREATE TABLE cgb_resources (
    id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text,
    class     text,
    value_mu  float8,      -- dispatch value per unit of capacity moved
    ramp_risk float8       -- ramp-rate risk, MW/min scaled
);
INSERT INTO cgb_resources (name, class, value_mu, ramp_risk) VALUES
    ('solar-farm-north',  'variable', 0.090, 0.30),
    ('wind-park-ridge',   'variable', 0.100, 0.35),
    ('battery-4h-east',   'storage',  0.070, 0.08),
    ('battery-2h-west',   'storage',  0.060, 0.07),
    ('pumped-hydro',      'dispatch', 0.080, 0.10),
    ('gas-peaker',        'dispatch', 0.110, 0.20);

-- Flat row-major risk matrix: ramp_i * ramp_j * rho, with rho = 1 on the
-- diagonal, 0.6 between two variable renewables, 0.1 otherwise.
DROP TABLE IF EXISTS cgb_result;
CREATE TABLE cgb_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(value_mu ORDER BY id) FROM cgb_resources),
    (SELECT array_agg(round((a.ramp_risk * b.ramp_risk *
                CASE WHEN a.id = b.id THEN 1.0
                     WHEN a.class = 'variable' AND b.class = 'variable' THEN 0.6
                     ELSE 0.1 END)::numeric, 6)::float8 ORDER BY a.id, b.id)
       FROM cgb_resources a CROSS JOIN cgb_resources b),
    4, 42) AS rj;

SELECT round((rj->>'sharpe')::numeric, 4) AS sharpe FROM cgb_result;

\echo '--- the dispatch set (weight > 0; weights are in resource id order) ---'
SELECT r.name, r.class, round(w.weight_text::numeric, 4) AS dispatch_weight
FROM cgb_result c
CROSS JOIN LATERAL jsonb_array_elements_text(c.rj->'weights') WITH ORDINALITY AS w(weight_text, ord)
JOIN cgb_resources r ON r.id = w.ord
WHERE w.weight_text::float8 > 0
ORDER BY w.weight_text::float8 DESC;

\echo '--- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---'
SELECT allocation AS dispatch_plan, sharpe, rationale
FROM fractal_agent_allocate(
    (SELECT array_agg(value_mu ORDER BY id) FROM cgb_resources),
    (SELECT array_agg(round((a.ramp_risk * b.ramp_risk *
                CASE WHEN a.id = b.id THEN 1.0
                     WHEN a.class = 'variable' AND b.class = 'variable' THEN 0.6
                     ELSE 0.1 END)::numeric, 6)::float8 ORDER BY a.id, b.id)
       FROM cgb_resources a CROSS JOIN cgb_resources b),
    4, '{"portfolio": "grid-dispatch"}');

-- ------------------------------------------------------------------
-- 4. Reasoning: the dispatch-plan rationale (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Reasoning: dispatch-plan rationale ==='

SELECT fractal_reason(
    'one-line rationale for this grid dispatch plan given the frequency-stability drift in AREA-C',
    json_build_object(
      'area_c_drift', (SELECT fractal_dimension_drift(array_agg(dev_mhz ORDER BY sample), 32)
                         FROM cgb_freq WHERE area = 'AREA-C'),
      'dispatch', (SELECT rj FROM cgb_result))::text) AS rationale;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE cgb_freq, cgb_resources, cgb_result;'
