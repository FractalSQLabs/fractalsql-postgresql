-- demo/demo-vertical-avionics-fault-prediction.sql
--
-- Industry vertical: aerospace -- avionics and flight-path fault
-- prediction across a fleet.  DOMAIN kit built on one installed agent,
-- fractal_agent_track_anomaly, which generalizes directly from the
-- maritime-defense kit's 2D tracks to 3D flight paths: same agent, same
-- contract (trajectory deviation search + heading-change DFA exponent),
-- closing with a reasoned classification of the deviation.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Sections 1-3 need no model; the shipped agent and
-- the closing classification are reasoning-bearing (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-avionics-fault-prediction.sql
--
-- Safe to re-run: afp_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: heading noise comes from an integer
--     LCG in a recursive CTE, not random().
--   * Each flight carries a planned-path vector and its latest-state
--     vector, [x_km, y_km, altitude_km] as float8[] guarded by a CHECK on
--     their length.  Flight AC-09 has a stuck control surface: its path
--     has drifted off plan and its heading changes become erratic for a
--     stretch of the flight.
--   * fractal_search_trajectory returns the 0-based scan position as
--     doc_id; the agent resolves the nearest fleet member's id itself.
--   * DFA needs a reasonable series length (a few dozen points at
--     minimum); the heading series here is 120 samples.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. A 12-aircraft fleet: planned path vs current state in 3D.  Eleven
-- are on plan to within small offsets; AC-09 has drifted far off plan
-- (lateral and vertical).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Fleet: planned path vs current state (3D) ==='

DROP TABLE IF EXISTS afp_flights;
CREATE TABLE afp_flights (
    id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flight      text,
    baseline    float8[] NOT NULL CHECK (array_length(baseline, 1) = 3),
    current_pos float8[] NOT NULL CHECK (array_length(current_pos, 1) = 3)
);

INSERT INTO afp_flights (flight, baseline, current_pos)
SELECT format('AC-%s', lpad(g::text, 2, '0')),
       ARRAY[0.20 + 0.05 * g, 0.40 + 0.02 * (g % 4), 0.80],
       ARRAY[0.20 + 0.05 * g + 0.004 * (g % 3),
             0.40 + 0.02 * (g % 4) + 0.003 * (g % 2),
             0.80 - 0.002 * (g % 3)]
FROM generate_series(1, 12) AS g
ORDER BY g;

-- AC-09: far off plan.
UPDATE afp_flights SET current_pos = ARRAY[0.900, 1.400, 0.350] WHERE flight = 'AC-09';

SELECT flight, baseline, current_pos FROM afp_flights WHERE flight IN ('AC-01', 'AC-09');

-- ------------------------------------------------------------------
-- 2. Heading-change series: a steady transit (small noise) vs AC-09's
-- erratic stretch (large swings between samples 60 and 90).  The
-- running sum is the heading walk the DFA exponent is computed on.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. DFA of the heading walk: steady flight vs AC-09 ==='

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919::bigint UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, (((x / 65536) % 1000) - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * 0.03) OVER (ORDER BY t) AS s FROM steps)
SELECT 'steady flight' AS series,
       round(fractal_dimension_dfa(array_agg(round(s::numeric, 6)::float8 ORDER BY t))::numeric, 3) AS dfa_alpha
  FROM walk
UNION ALL
SELECT 'AC-09 erratic stretch', round(fractal_dimension_dfa(array_agg(round(s::numeric, 6)::float8 ORDER BY t))::numeric, 3)
  FROM (WITH RECURSIVE n(t, x) AS (
               SELECT 1, 7919::bigint UNION ALL
               SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
             steps AS (SELECT t, (((x / 65536) % 1000) - 500) / 1000.0 AS u FROM n)
        SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) OVER (ORDER BY t) AS s
          FROM steps) w;

-- ------------------------------------------------------------------
-- 3. Hand-composed: trajectory deviation of AC-09 -- the fleet members
-- nearest to its planned path and to where it is now.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. AC-09 baseline -> current trajectory search ==='

WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, flight FROM afp_flights)
SELECT p.flight, round(tr.distance::numeric, 4) AS distance
FROM fractal_search_trajectory(
         'afp_flights', 'current_pos',
         (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
         (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'),
         5) tr
JOIN pos p ON p.doc_id = tr.doc_id
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 4. The shipped agent: trajectory deviation + heading DFA + a reasoned
-- classification in one call (reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_agent_track_anomaly (3D flight path) ==='

SELECT nearest_fleet_id, trajectory_distance, dfa_exponent, rationale
FROM fractal_agent_track_anomaly(
    'afp_flights', 'current_pos',
    (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
    (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'),
    (WITH RECURSIVE n(t, x) AS (
            SELECT 1, 7919::bigint UNION ALL
            SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
          steps AS (SELECT t, (((x / 65536) % 1000) - 500) / 1000.0 AS u FROM n),
          walk AS (SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                                 OVER (ORDER BY t) AS s FROM steps)
     SELECT array_agg(round(s::numeric, 6)::float8 ORDER BY t) FROM walk),
    5, 'id');

-- ------------------------------------------------------------------
-- 5. Reasoning: classify the deviation (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: classify the deviation ==='

SELECT fractal_reason(
    'one-line classification of this flight-path deviation: sensor fault, control-surface fault, or weather',
    (SELECT json_agg(tr)
       FROM fractal_search_trajectory('afp_flights', 'current_pos',
              (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
              (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'), 3) tr)::text) AS classification;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE afp_flights;'
