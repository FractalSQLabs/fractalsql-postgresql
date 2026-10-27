-- demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Industry vertical: Electric-vehicle fleet battery lifecycle -- state-of-
-- health (SoH) and thermal-regime monitoring.  AGENTIC kit: two installed
-- agents are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_patient_deterioration_triage -- cohort search plus
--      baseline-vs-current trajectory drift.  Its contract is domain-
--      neutral (a vehicle's intake baseline plays the patient's admission
--      baseline), so the kit only supplies different columns.
--   2. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      vehicle's temperature series, flagging a shift into a new regime
--      (pre-thermal-runaway) independently of the SoH comparison.
--   3. A closing fractal_reason() synthesizes both signals into one
--      maintenance / safety recommendation.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Sections 1-4's hand-composed steps need no model;
-- the shipped agents and Section 5 need the reasoning plugin
-- (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Safe to re-run: ebl_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: no random(), so every run returns the
--     same numbers.
--   * state is a float8[] of [soh, temp_z, volt_z, fade_rate].
--   * Row locators: fractal_search_telemetry / _hybrid_clinical_search
--     return the row's ctid as doc_id, fractal_search_trajectory returns
--     the 0-based scan position, and the patient_deterioration_triage
--     agent takes its cohort as an array of ctid strings and resolves the
--     id column itself.
--   * The temperature series needs >= 48 points per vehicle for the 32-
--     point drift window (DFA needs the recent window large enough).  The
--     fault is an accelerating ramp, not a level shift: DFA removes a
--     constant offset, so only a change in the series' dynamics registers.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Fleet telemetry: 3 vehicles x 96 readings.  EV-101 and EV-102 age
-- gently.  EV-203 develops a fault at reading 65: an accelerating
-- (quadratic) thermal ramp, a voltage sag and an accelerating SoH fade.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Fleet telemetry: 3 vehicles x 96 readings ==='

DROP TABLE IF EXISTS ebl_telemetry;
CREATE TABLE ebl_telemetry (
    id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vin        text,
    model_year int,
    seq        int,              -- reading order within the vehicle
    soh        float8,           -- state of health, fraction of nominal capacity
    temp_c     float8,           -- pack temperature
    volt       float8,           -- mean cell voltage under load
    state      float8[] NOT NULL CHECK (array_length(state, 1) = 4)
);

INSERT INTO ebl_telemetry (vin, model_year, seq, soh, temp_c, volt, state)
WITH v(vi, vin, my) AS (VALUES (1, 'EV-101', 2024), (2, 'EV-102', 2024), (3, 'EV-203', 2023)),
     r AS (
       SELECT vi, vin, my, g,
              0.99 - 0.0004 * g
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.004 * (g - 64) ELSE 0 END AS soh,
              31.0 + (g % 8) * 0.6
                + CASE WHEN vin = 'EV-203' AND g > 64
                       THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END AS temp_c,
              3.72 - (g % 5) * 0.004
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.09 ELSE 0 END AS volt
         FROM v, generate_series(1, 96) AS g)
SELECT vin, my, g, soh, temp_c, volt,
       ARRAY[round(soh::numeric, 4)::float8, round(((temp_c - 35.0) / 10.0)::numeric, 4)::float8,
             round(((volt - 3.70) / 0.10)::numeric, 4)::float8, round(((0.99 - soh) / g)::numeric, 6)::float8]
  FROM r
 ORDER BY vi, g;

SELECT vin, count(*) AS readings, round(min(soh)::numeric, 3) AS min_soh,
       round(max(temp_c)::numeric, 1) AS max_temp_c
  FROM ebl_telemetry GROUP BY vin ORDER BY vin;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: baseline-vs-current trajectory search.
-- EV-203's intake baseline vs its latest reading; the nearest fleet
-- readings show where in the fleet's history the pack now sits.
-- (trajectory doc_id is the 0-based scan position.)
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Step 1 (hand-composed): EV-203 baseline -> current trajectory ==='

WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, vin, seq FROM ebl_telemetry)
SELECT p.vin, p.seq, round(tr.distance::numeric, 4) AS distance
FROM fractal_search_trajectory(
         'ebl_telemetry', 'state',
         (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
         (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
         5) tr
JOIN pos p ON p.doc_id = tr.doc_id
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent.  The cohort is caller-
-- built with ordinary SQL (model year 2023, the cohort EV-203 belongs
-- to) as an array of ctid strings; nearest_cohort_id / cohort_distance /
-- drift_distance are real.  Reasoning-bearing: needs the plugin.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Step 1 (shipped agent): fractal_agent_patient_deterioration_triage ==='

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale
FROM fractal_agent_patient_deterioration_triage(
    'ebl_telemetry', 'state',
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT array_agg(ctid::text ORDER BY ctid) FROM ebl_telemetry WHERE model_year = 2023),
    5, 'id');

-- ------------------------------------------------------------------
-- 4. Step 2, hand-composed then productized: temperature-regime drift.
-- fractal_dimension_drift on each vehicle's temperature series; the
-- healthy pair sits near zero (slightly negative), EV-203's accelerating
-- ramp pushes the recent-window exponent far above its baseline.  (DFA
-- measures how the series' fluctuation scales, so the regime change is a
-- change in dynamics -- a pure level shift would not move it.)
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Step 2 (hand-composed): temperature-regime drift per vehicle ==='

SELECT vin,
       round((d->>'drift')::numeric, 4)          AS drift,
       round((d->>'recent_alpha')::numeric, 4)   AS recent_alpha,
       round((d->>'baseline_alpha')::numeric, 4) AS baseline_alpha
FROM (SELECT vin, fractal_dimension_drift(array_agg(temp_c ORDER BY seq), 32) AS d
        FROM ebl_telemetry GROUP BY vin) x
ORDER BY vin;

\echo '--- the shipped agent: same composition, one call (reasoning plugin) ---'
SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('ebl_telemetry', 'temp_c', 'seq', 'vin', 'EV-203', 32);

-- ------------------------------------------------------------------
-- 5. Reasoning: one maintenance / safety recommendation over BOTH
-- signals (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: maintenance / safety recommendation for EV-203 ==='

SELECT fractal_reason(
    'one-line maintenance and safety recommendation for an EV pack showing '
    'both an accelerating state-of-health fade and a thermal regime shift',
    json_build_object(
      'thermal_drift', (SELECT fractal_dimension_drift(array_agg(temp_c ORDER BY seq), 32)
                          FROM ebl_telemetry WHERE vin = 'EV-203'),
      'soh_at_intake_vs_now', (SELECT json_build_array(
              (SELECT soh FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
              (SELECT soh FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96))))::text) AS recommendation;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE ebl_telemetry;'
