-- demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Industry vertical: occupational exposure monitoring -- hazardous-
-- materials response, chemical and nuclear plant crews, wearable-sensor
-- workforce safety.  DOMAIN kit built on one installed agent,
-- fractal_agent_patient_deterioration_triage, reused verbatim: its
-- contract (cohort vector search + baseline-vs-current trajectory drift)
-- is domain-neutral, so the kit only supplies exposure columns in place
-- of clinical vitals and a worker's pre-shift baseline in place of an
-- admission baseline.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Sections 1-3 need no model; the shipped agent and
-- the closing recommendation are reasoning-bearing (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Safe to re-run: hot_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Exposure vectors are [dose_rate_z, body_temp_z, air_quality_z,
--     heart_rate_z] as float8[] guarded by a CHECK on their length: a
--     wrong-width write from a wearable integration fails loudly at write
--     time, not silently inside a worker record.
--   * Row locators: fractal_hybrid_clinical_search returns the row's ctid
--     as doc_id, fractal_search_trajectory the 0-based scan position, and
--     the agent takes its cohort as an array of ctid strings.
--   * The cohort is caller-built with ordinary SQL (same work zone AND
--     same shift) -- the two-predicate cohort a single filter pair cannot
--     express.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 36 synthetic workers across three work zones and two shifts.
-- Zone 'reactor-bay' on the night shift is the contaminated cohort:
-- workers 7, 15 and 31 show elevated dose rate, temperature and heart
-- rate.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 36 workers: zone, shift and current exposure vector ==='

DROP TABLE IF EXISTS hot_workers;
CREATE TABLE hot_workers (
    id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone     text,
    shift    text,
    exposure float8[] NOT NULL CHECK (array_length(exposure, 1) = 4)
);

INSERT INTO hot_workers (zone, shift, exposure)
SELECT CASE g % 3 WHEN 0 THEN 'reactor-bay' WHEN 1 THEN 'fuel-handling' ELSE 'control-room' END,
       CASE WHEN g % 2 = 0 THEN 'night' ELSE 'day' END,
       ARRAY[0.05 * (g % 5),            -- dose rate
             0.04 * (g % 7) - 0.10,     -- body temperature
             0.03 * (g % 4),            -- air quality
             0.06 * (g % 6) - 0.10]     -- heart rate
FROM generate_series(1, 36) AS g
ORDER BY g;

-- Force a deterministic contaminated cohort.
UPDATE hot_workers SET zone = 'reactor-bay', shift = 'night',
       exposure = ARRAY[1.40, 0.90, 1.10, 1.20] WHERE id IN (7, 15, 31);

SELECT zone, shift, count(*) AS workers FROM hot_workers
 GROUP BY zone, shift ORDER BY zone, shift;

-- ------------------------------------------------------------------
-- 2. Hand-composed: cohort-restricted search.  Nearest reactor-bay
-- night-shift workers to the exposure profile of the worker under
-- review.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Cohort-restricted search: reactor-bay, night shift ==='

SELECT w.id AS worker_id, w.zone, w.shift, round(h.distance::numeric, 4) AS distance
FROM fractal_hybrid_clinical_search(
         'hot_workers', 'exposure', ARRAY[1.40, 0.90, 1.10, 1.20]::float8[],
         (SELECT array_agg(ctid::text ORDER BY ctid) FROM hot_workers
           WHERE zone = 'reactor-bay' AND shift = 'night'),
         5) h
JOIN hot_workers w ON w.ctid::text = h.doc_id
ORDER BY h.distance, w.id;

-- ------------------------------------------------------------------
-- 3. Hand-composed: pre-shift baseline vs current exposure.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Baseline -> current exposure trajectory ==='

WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, id, zone, shift FROM hot_workers)
SELECT p.id AS worker_id, p.zone, p.shift, round(tr.distance::numeric, 4) AS distance
FROM fractal_search_trajectory(
         'hot_workers', 'exposure',
         ARRAY[0.05, 0.00, 0.03, 0.00]::float8[],    -- pre-shift baseline
         ARRAY[1.40, 0.90, 1.10, 1.20]::float8[],    -- current (escalating)
         5) tr
JOIN pos p ON p.doc_id = tr.doc_id
ORDER BY tr.distance, p.id;

-- ------------------------------------------------------------------
-- 4. The shipped agent: both searches plus a reasoned rationale in one
-- call (reasoning plugin).  The rationale is the countermeasure-
-- dispatch recommendation.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_agent_patient_deterioration_triage (exposure triage) ==='

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale, cohort_matches
FROM fractal_agent_patient_deterioration_triage(
    'hot_workers', 'exposure', ARRAY[1.40, 0.90, 1.10, 1.20]::float8[],
    ARRAY[0.05, 0.00, 0.03, 0.00]::float8[], ARRAY[1.40, 0.90, 1.10, 1.20]::float8[],
    (SELECT array_agg(ctid::text ORDER BY ctid) FROM hot_workers
      WHERE zone = 'reactor-bay' AND shift = 'night'),
    5, 'id');

-- ------------------------------------------------------------------
-- 5. Reasoning: the medical-countermeasure dispatch recommendation
-- (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: countermeasure dispatch recommendation ==='

SELECT fractal_reason(
    'one-line medical-countermeasure dispatch recommendation for this exposed work crew',
    (SELECT json_agg(h) FROM fractal_hybrid_clinical_search(
         'hot_workers', 'exposure', ARRAY[1.40, 0.90, 1.10, 1.20]::float8[],
         (SELECT array_agg(ctid::text ORDER BY ctid) FROM hot_workers
           WHERE zone = 'reactor-bay' AND shift = 'night'), 3) h)::text) AS recommendation;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE hot_workers;'
