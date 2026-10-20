-- demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Industry vertical: Climate Tech -- industrial emissions and utility-
-- leak detection (methane / CO2 sensor networks, water-distribution
-- pressure and flow monitoring).  DOMAIN kit built on one installed
-- agent, fractal_agent_anomaly_triage, reused verbatim: the drift
-- exponent of a single sensor's series flags a shift into a new
-- (leak / over-emission) regime, closing with a reasoned narrative.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed drift needs no model; the
-- shipped agent and the closing narrative are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Safe to re-run: cem_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Each sensor has a baseline reading; the drift window is 32 points,
--     so each sensor needs >= 48 readings.  A leak is an ACCELERATING
--     concentration ramp downstream of the source, not a level shift:
--     DFA removes a constant offset, so only a change in the series'
--     dynamics moves the exponent.
--   * The network mixes gases and a pipeline-pressure sensor (PRS-07): the
--     agent is indifferent to the physical quantity, so the same call
--     screens a water-distribution pressure series for leaks.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Four sensors x 96 readings.  CH4-02 (methane, downstream of a
-- compressor) starts leaking at reading 65: concentration ramps up
-- quadratically.  CH4-01 and CO2-01 are steady; PRS-07 is a pipeline
-- pressure sensor, steady here.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Sensor network: 4 sensors x 96 readings ==='

DROP TABLE IF EXISTS cem_readings;
CREATE TABLE cem_readings (
    sensor   text,
    quantity text,
    seq      int,
    value    float8,
    baseline float8
);
INSERT INTO cem_readings (sensor, quantity, seq, value, baseline)
SELECT sensor, quantity, g,
       base * (1.0 + 0.004 * (g % 8))
         + CASE WHEN sensor = 'CH4-02' AND g > 64
                THEN 0.0045 * (g - 64) * (g - 64) ELSE 0 END,
       base
FROM (VALUES ('CH4-01', 'methane_ppm', 1.9), ('CH4-02', 'methane_ppm', 1.9),
             ('CO2-01', 'co2_ppm', 412.0), ('PRS-07', 'pressure_kpa', 620.0)) AS s(sensor, quantity, base),
     generate_series(1, 96) AS g;

SELECT sensor, quantity, round(max(value)::numeric, 3) AS peak, max(baseline) AS baseline
  FROM cem_readings GROUP BY sensor, quantity ORDER BY sensor;

-- ------------------------------------------------------------------
-- 2. Hand-composed: emissions-regime drift per sensor.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Hand-composed: regime drift per sensor ==='

SELECT sensor,
       round((d->>'drift')::numeric, 4)          AS drift,
       round((d->>'recent_alpha')::numeric, 4)   AS recent_alpha,
       round((d->>'baseline_alpha')::numeric, 4) AS baseline_alpha
FROM (SELECT sensor, fractal_dimension_drift(array_agg(round(value::numeric, 5)::float8 ORDER BY seq), 32) AS d
        FROM cem_readings GROUP BY sensor) x
ORDER BY sensor;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the leaking sensor, and on a steady one for
-- contrast (reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_agent_anomaly_triage: leaking vs steady sensor ==='

SELECT 'CH4-02 (leaking)' AS sensor, threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-02', 32)
UNION ALL
SELECT 'CH4-01 (steady)', threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-01', 32);

-- ------------------------------------------------------------------
-- 4. Reasoning: the leak narrative (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Reasoning: leak / over-emission narrative ==='

SELECT fractal_reason(
    'one-line leak-detection narrative and recommended field response for this sensor',
    (SELECT fractal_dimension_drift(array_agg(round(value::numeric, 5)::float8 ORDER BY seq), 32)::text
       FROM cem_readings WHERE sensor = 'CH4-02')) AS narrative;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE cem_readings;'
