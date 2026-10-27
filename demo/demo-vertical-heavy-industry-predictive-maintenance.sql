-- demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- Industry vertical: heavy machinery and fleet predictive maintenance --
-- commercial marine vessels, construction / mining equipment, industrial
-- powertrains, hull and structural sensor networks.  AGENTIC kit: two
-- installed agents are chained, shown hand-composed first and then as the
-- shipped one-call agents.
--
--   1. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      asset's vibration series, flagging a shift into a new (pre-
--      failure) regime.
--   2. fractal_agent_patient_deterioration_triage -- baseline-vs-current
--      trajectory drift against the asset's intake baseline, with a
--      same-class cohort search (an asset plays the patient).
--   3. A closing fractal_reason() produces a maintenance-window
--      recommendation.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed sections need no model; the
-- shipped agents and the closing recommendation are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- Safe to re-run: hpm_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * State vectors are [vib_rms_z, kurtosis_z, bearing_temp_z, order1_amp_z]
--     as float8[].
--   * The drift window is 32 points, so each asset needs >= 48 readings.
--     The failure signature is an ACCELERATING vibration ramp (a growing
--     bearing defect), not a level shift: DFA removes a constant offset,
--     so only a change in the series' dynamics moves the exponent.
--   * fractal_search_trajectory returns the 0-based scan position as
--     doc_id; the patient_deterioration_triage agent takes its cohort as
--     an array of ctid strings.
--   * This is the WEAR / LIFECYCLE half of heavy-industry monitoring.  A
--     CAD / structural-defect (3D mesh) kit is a separate topic.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Four pumps / drives x 96 readings.  PUMP-07 develops a bearing
-- defect at reading 65 (accelerating vibration, rising temperature);
-- the others age gently.  'class' groups comparable assets.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Asset telemetry: 4 assets x 96 readings ==='

DROP TABLE IF EXISTS hpm_readings;
CREATE TABLE hpm_readings (
    id     int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset  text,
    class  text,
    seq    int,
    vib    float8,              -- vibration RMS, mm/s
    temp_c float8,              -- bearing temperature
    state  float8[] NOT NULL CHECK (array_length(state, 1) = 4)
);

INSERT INTO hpm_readings (asset, class, seq, vib, temp_c, state)
WITH a(ai, asset, class) AS (VALUES
         (1, 'PUMP-03', 'centrifugal'), (2, 'PUMP-05', 'centrifugal'),
         (3, 'PUMP-07', 'centrifugal'), (4, 'DRIVE-12', 'gearbox')),
     r AS (
       SELECT ai, asset, class, g,
              2.1 + (g % 8) * 0.05
                + CASE WHEN asset = 'PUMP-07' AND g > 64
                       THEN 0.004 * (g - 64) * (g - 64) ELSE 0 END AS vib,
              58.0 + (g % 6) * 0.4
                + CASE WHEN asset = 'PUMP-07' AND g > 64 THEN 0.35 * (g - 64) ELSE 0 END AS temp_c
         FROM a, generate_series(1, 96) AS g)
SELECT asset, class, g, vib, temp_c,
       ARRAY[round(((vib - 2.3) / 1.0)::numeric, 4)::float8,
             round((((g % 8) * 0.05 + CASE WHEN asset = 'PUMP-07' AND g > 64
                                           THEN 0.08 * (g - 64) ELSE 0 END) - 0.2)::numeric, 4)::float8,
             round(((temp_c - 60.0) / 10.0)::numeric, 4)::float8,
             round(((vib - 2.1) * 0.5)::numeric, 4)::float8]
  FROM r ORDER BY ai, g;

SELECT asset, class, count(*) AS readings, round(max(vib)::numeric, 2) AS max_vib_mm_s,
       round(max(temp_c)::numeric, 1) AS max_bearing_temp_c
  FROM hpm_readings GROUP BY asset, class ORDER BY asset;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: vibration-regime drift per asset.  The
-- healthy assets sit near zero; PUMP-07's accelerating ramp pushes its
-- recent-window exponent far above its baseline.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Step 1 (hand-composed): vibration drift per asset ==='

SELECT asset,
       round((d->>'drift')::numeric, 4)          AS drift,
       round((d->>'recent_alpha')::numeric, 4)   AS recent_alpha,
       round((d->>'baseline_alpha')::numeric, 4) AS baseline_alpha
FROM (SELECT asset, fractal_dimension_drift(array_agg(vib ORDER BY seq), 32) AS d
        FROM hpm_readings GROUP BY asset) x
ORDER BY asset;

\echo '--- the shipped agent: same composition, one call (reasoning plugin) ---'
SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('hpm_readings', 'vib', 'seq', 'asset', 'PUMP-07', 32);

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: PUMP-07's intake baseline vs its latest
-- state.  The nearest fleet readings show where in the fleet's history
-- the pump now sits.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Step 2 (hand-composed): PUMP-07 baseline -> current trajectory ==='

WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, asset, seq FROM hpm_readings)
SELECT p.asset, p.seq, round(tr.distance::numeric, 4) AS distance
FROM fractal_search_trajectory(
         'hpm_readings', 'state',
         (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
         (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
         5) tr
JOIN pos p ON p.doc_id = tr.doc_id
ORDER BY tr.distance;

\echo '--- the shipped agent: cohort = same-class (centrifugal) assets (reasoning plugin) ---'
SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale
FROM fractal_agent_patient_deterioration_triage(
    'hpm_readings', 'state',
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT array_agg(ctid::text ORDER BY ctid) FROM hpm_readings WHERE class = 'centrifugal'),
    5, 'id');

-- ------------------------------------------------------------------
-- 4. Reasoning: the maintenance-window recommendation (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Reasoning: maintenance-window recommendation for PUMP-07 ==='

SELECT fractal_reason(
    'one-line maintenance-window recommendation for a pump showing an accelerating '
    'vibration regime shift and drift from its intake baseline',
    json_build_object(
      'vibration_drift', (SELECT fractal_dimension_drift(array_agg(vib ORDER BY seq), 32)
                            FROM hpm_readings WHERE asset = 'PUMP-07'))::text) AS recommendation;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE hpm_readings;'
