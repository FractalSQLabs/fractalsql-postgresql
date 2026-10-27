-- demo/demo-vertical-adas-safety-validation.sql
--
-- Industry vertical: ADAS / autonomous-driving safety validation --
-- edge-case interception before a maneuver is committed.  AGENTIC kit:
-- two signals are composed, shown hand-composed first and then as the
-- shipped one-call agent.
--
--   1. fractal_agent_outlier_intercept -- a pre-commit safety barrier:
--      screens a PROPOSED vehicle state vector against a history of
--      known-bad states (prior disengagements and near-misses), exactly
--      its designed contract.
--   2. fractal_search_trajectory -- flags when the vehicle's current
--      routing vector has moved away from the fleet baseline.
--   3. A closing fractal_reason() turns both signals into one verdict.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed sections (2, 4) need no model;
-- the shipped outlier_intercept agent returns a reasoned `reason`, so
-- Sections 3 and 5 need the reasoning plugin (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-adas-safety-validation.sql
--
-- Safe to re-run: asv_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * State vectors are [speed_z, lateral_accel_z, brake_z, steer_rate_z]
--     as float8[].  The intercept distance is COSINE by default, which
--     ignores magnitude: a mild maneuver in the same direction as a known-
--     bad one is intercepted too.  Pass 'l2' as the fifth argument when
--     magnitude should count (Section 3).
--   * Row locators: fractal_search_telemetry returns the row's ctid as
--     doc_id; fractal_search_trajectory returns the 0-based scan position.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Known-bad state history and three proposed maneuvers.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Known-bad history + proposed maneuvers ==='

DROP TABLE IF EXISTS asv_known_bad;
CREATE TABLE asv_known_bad (
    id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario text,
    state    float8[] NOT NULL CHECK (array_length(state, 1) = 4)
);
INSERT INTO asv_known_bad (scenario, state) VALUES
    ('hard brake at highway speed',   ARRAY[0.90, 0.10, 0.95, 0.10]),
    ('evasive swerve',                ARRAY[0.50, 0.90, 0.20, 0.95]),
    ('late brake approaching a stop', ARRAY[0.40, 0.05, 0.90, 0.05]),
    ('lane drift under load',         ARRAY[0.70, 0.60, 0.05, 0.30]);

DROP TABLE IF EXISTS asv_proposed;
CREATE TABLE asv_proposed (
    id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label text,
    state float8[] NOT NULL CHECK (array_length(state, 1) = 4)
);
INSERT INTO asv_proposed (label, state) VALUES
    ('P1 firm brake, high speed',   ARRAY[0.88, 0.12, 0.90, 0.15]),
    ('P2 steady cruise',            ARRAY[0.55, 0.02, 0.02, 0.01]),
    ('P3 gentle lane change',       ARRAY[0.45, 0.35, 0.05, 0.30]);

SELECT count(*) AS known_bad_states FROM asv_known_bad;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: nearest known-bad state per proposal,
-- threshold 0.15 (cosine).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Step 1 (hand-composed): nearest known-bad state, threshold 0.15 ==='

SELECT p.label, k.scenario AS nearest_bad,
       round(t.distance::numeric, 4) AS distance,
       (t.distance < 0.15) AS intercepted
FROM asv_proposed p
CROSS JOIN LATERAL fractal_search_telemetry('asv_known_bad', 'state', p.state, 1) t
JOIN asv_known_bad k ON k.ctid::text = t.doc_id
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent (its `reason` field is
-- reasoning-bearing).  Note P3: the cosine check intercepts it (same
-- direction as the known-bad lane drift, just gentler); exact Euclidean
-- distance lets it through because magnitude counts.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Step 1 (shipped agent): fractal_agent_outlier_intercept ==='

SELECT p.label, o.intercepted, o.metric, o.reason
FROM asv_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(
         p.state, 'asv_known_bad', 'state', 0.15) o
ORDER BY p.id;

\echo '--- same check under exact Euclidean distance (magnitude counts) ---'
SELECT p.label, o.intercepted AS intercepted_l2
FROM asv_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(
         p.state, 'asv_known_bad', 'state', 0.30, 'l2') o
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. Step 2: routing deviation from the fleet baseline.  40 fleet
-- vehicles on three lane/speed bands; vehicle V-17's routing vector
-- (lateral offset, heading, speed) is compared against the fleet
-- baseline.  The nearest fleet members to the baseline and to the
-- current vector show how far this vehicle has strayed.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Step 2: routing deviation from the fleet baseline ==='

DROP TABLE IF EXISTS asv_routes;
CREATE TABLE asv_routes (
    id      int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle text,
    route   float8[] NOT NULL CHECK (array_length(route, 1) = 3)
);
INSERT INTO asv_routes (vehicle, route)
SELECT 'V-' || g,
       ARRAY[0.10 * (g % 3) + 0.01 * (g % 7),            -- lateral offset
             0.05 * (g % 4),                             -- heading error
             0.60 + 0.05 * (g % 3) + 0.004 * (g % 5)]    -- speed band
FROM generate_series(1, 40) AS g
ORDER BY g;

WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, vehicle FROM asv_routes)
SELECT p.vehicle, round(tr.distance::numeric, 4) AS distance
FROM fractal_search_trajectory(
         'asv_routes', 'route',
         ARRAY[0.100, 0.050, 0.650]::float8[],      -- fleet baseline routing vector
         ARRAY[0.900, 0.800, 0.200]::float8[],      -- V-17 now: far off its lane/speed band
         3) tr
JOIN pos p ON p.doc_id = tr.doc_id
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 5. Reasoning: one go / no-go verdict over both signals (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: go / no-go verdict for proposal P1 ==='

SELECT fractal_reason(
    'one-line go/no-go safety verdict for this proposed ADAS maneuver',
    json_build_object(
      'intercept', (SELECT row_to_json(o)
                      FROM asv_proposed p,
                           LATERAL fractal_agent_outlier_intercept(p.state, 'asv_known_bad', 'state', 0.15) o
                     WHERE p.id = 1),
      'routing_deviation', (SELECT json_agg(tr)
                              FROM fractal_search_trajectory('asv_routes', 'route',
                                     ARRAY[0.100, 0.050, 0.650]::float8[],
                                     ARRAY[0.900, 0.800, 0.200]::float8[], 2) tr))::text) AS verdict;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE asv_known_bad, asv_proposed, asv_routes;'
