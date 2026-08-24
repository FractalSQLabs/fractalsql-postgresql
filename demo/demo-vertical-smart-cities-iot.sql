-- demo/demo-vertical-smart-cities-iot.sql
--
-- Industry vertical: Smart Cities & IoT Sensor Grids.
--
-- A 400-sensor city grid (traffic/air-quality/noise, jittered 20x20
-- placement) for spatial coverage-complexity analysis, one sensor's
-- reading series carrying a deliberate regime shift (an air-quality
-- event) for DFA/drift detection, and diverse representative-zone
-- sampling across the grid.
--
-- Prerequisites: extension installed (sections 0-3 need nothing else).
-- Section 4 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-smart-cities-iot.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-smart-cities-iot.sql
--
-- Safe to re-run: vsc_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.74);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 400 sensors: a jittered 20x20 grid placement (lat/lon-style x,y
-- position) plus a 3-dim reading vector [traffic, air_quality, noise].
-- A grid-like layout, not sparse random scatter, is what the box-
-- counting-based functions below need to find enough occupied-cell
-- structure across eps scales (same requirement
-- demo/demo-vertical-sovereign-edge-ai.sql's facility-grid section documents).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 400 sensors: jittered 20x20 city grid + readings ==='

DROP TABLE IF EXISTS vsc_sensors;
CREATE TABLE vsc_sensors (
    id       serial PRIMARY KEY,
    sensor_id text,
    -- pos stays float8[] deliberately -- it's unnest()'d below into
    -- flat point-cloud input for fractal_dimension_boxcount/
    -- fractal_morphological_complexity, not read as a vector_col search
    -- corpus. unnest() requires a real Postgres array type;
    -- fractal_vector is a scalar varlena type without array semantics,
    -- so this specific usage genuinely isn't a fractal_vector fit.
    pos      float8[],   -- [x, y] placement
    -- reading IS fractal_vector(3) -- it's read as a vector_col search
    -- corpus by fractal_search_explore below (spi_scan_corpus dispatch
    -- already handles either type transparently), a fixed-width
    -- [traffic, air_quality, noise] vector where dimension safety
    -- matters, same argument as the other updated verticals.
    reading  fractal_vector(3)
);

INSERT INTO vsc_sensors (sensor_id, pos, reading)
SELECT 'SENSOR-' || (r * 20 + c + 1),
       ARRAY[r + (random()-0.5)*0.3, c + (random()-0.5)*0.3]::float8[],
       ARRAY[random()*2-1, random()*2-1, random()*2-1]::float8[]
FROM generate_series(0, 19) r
CROSS JOIN generate_series(0, 19) c;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount / fractal_morphological_complexity over
-- the sensor grid's spatial layout -- coverage-density diagnostics
-- (dimension near 2.0 + moderate lacunarity means even, gap-free
-- coverage; a lower dimension or high lacunarity would flag sparse or
-- clustered deployment).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Sensor grid spatial coverage: dimension + morphological complexity ==='

SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
    2
) AS coverage_dimension;

-- Blueprint (raw primitive): the sensor grid's morphological complexity
-- (box-counting dimension + lacunarity). Generalized below by the shipped
-- fractal_agent_network_coverage_alert preset, which folds this together
-- with the telemetry drift series and a reasoning step.
-- SELECT fractal_morphological_complexity(
--     (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
--     2
-- ) AS coverage_complexity;

-- Productized preset: the shipped engine returns the real morphological
-- dimension + lacunarity (fractal_morphological_complexity over the grid's
-- pos point-cloud, the 400-pt 20x20 grid this function needs) and the real
-- drift_detected flag (fractal_dimension_drift over the air-quality event
-- series -- |drift| > 0.5), plus a real rationale. The coverage boxcount
-- above stays raw (no engine home -- boxcount-only, no drift/reason step).
\echo '--- Preset: fractal_agent_network_coverage_alert (raw morphological form preserved above) ---'
SELECT morph_dimension, lacunarity, drift_detected, rationale
FROM fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       CASE WHEN t <= 150 THEN (random()-0.5)*0.02
                            ELSE (random()-0.5)*0.16 END AS step
                  FROM generate_series(1, 240) t) s
    ) c),
    2, 48, 0.5);

-- ------------------------------------------------------------------
-- 3. fractal_dimension_dfa / fractal_dimension_drift: sensor 112's
-- air-quality reading series carries a deliberate regime shift (an
-- event) at t=150 of 240 samples.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_dimension_dfa/_drift: air-quality event detection ==='

-- Blueprint (raw primitives): the air-quality series' long-range-
-- correlation exponent (DFA) and its regime-change drift report.
-- Generalized below by the shipped fractal_agent_regime_triage preset,
-- which runs both over the same series and reasons.
-- SELECT fractal_dimension_dfa(
--     (SELECT array_agg(cum ORDER BY t) FROM (
--         SELECT t, sum(step) OVER (ORDER BY t) AS cum
--           FROM (SELECT t,
--                        CASE WHEN t <= 150 THEN (random()-0.5)*0.02
--                             ELSE (random()-0.5)*0.16 END AS step
--                   FROM generate_series(1, 240) t) s
--     ) c)
-- ) AS whole_series_alpha;
--
-- SELECT fractal_dimension_drift(
--     (SELECT array_agg(cum ORDER BY t) FROM (
--         SELECT t, sum(step) OVER (ORDER BY t) AS cum
--           FROM (SELECT t,
--                        CASE WHEN t <= 150 THEN (random()-0.5)*0.02
--                             ELSE (random()-0.5)*0.16 END AS step
--                   FROM generate_series(1, 240) t) s
--     ) c),
--     48
-- ) AS drift_report;

-- Productized preset: the shipped engine returns the real DFA exponent,
-- the real drift_detected flag (|drift| > 0.5), and the real
-- recent_alpha/baseline_alpha, plus a real rationale.
\echo '--- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---'
SELECT dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale
FROM fractal_agent_regime_triage(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       CASE WHEN t <= 150 THEN (random()-0.5)*0.02
                            ELSE (random()-0.5)*0.16 END AS step
                  FROM generate_series(1, 240) t) s
    ) c),
    64, 0.5);

-- ------------------------------------------------------------------
-- 4. Scout Discovery: diverse representative sample of reading
-- profiles across the grid -- "what KINDS of zones do we actually
-- have" (quiet-residential vs. high-traffic-commercial vs. ...) rather
-- than scanning all 400 sensors by hand.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_search_explore: diverse zone reading-profiles ==='
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse representative set of
-- reading-profile embeddings -- "what KINDS of zones do we have".
-- SELECT p FROM fractal_search_explore(
--     'vsc_sensors', 'reading', ARRAY[0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real sensor ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session (the engine leaves diversify on -- the caller owns
-- that policy) so later sections see the same diversify-off state as before.
-- The blueprint's zero query is query-agnostic (explore samples the space);
-- recommend_diverse is query-anchored (nearest-neighbor top-k), so anchor on
-- the first sensor's own reading -- the nearest result is itself (score 1)
-- and the rest are a repulsion-diverse spread.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vsc_sensors', 'reading',
    (SELECT reading::float8[] FROM vsc_sensors ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. Reasoning: the city-ops narrative over coverage + drift is now
-- produced by the fractal_agent_network_coverage_alert preset's
-- rationale column in Section 2 (the same coverage morphological
-- complexity + air-quality drift, folded into one reasoning step).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: absorbed into the Section 2 network_coverage_alert rationale ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vsc_sensors;'
