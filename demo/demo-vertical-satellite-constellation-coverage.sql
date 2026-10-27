-- demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Industry vertical: space and satellite communications -- constellation
-- coverage monitoring.  DOMAIN kit built on two installed agents:
--
--   * fractal_agent_network_coverage_alert -- spatial morphology of the
--     constellation's footprint grid (box-counting dimension + lacunarity)
--     plus drift of a link-quality telemetry series, flagging coverage
--     gaps and dead zones.  This is the COVERAGE-GAP angle only; orbital
--     drift and collision detection are a different problem and are not
--     covered here.
--   * fractal_agent_schedule_workload -- a secondary branch that models
--     launch-manifest / payload-slot scheduling as a resource-allocation
--     problem (vector-refine + nearest-slot match).
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Section 2 and the hand-composed nearest-slot
-- match need no model; the shipped agents and the closing narrative are
-- reasoning-bearing (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Safe to re-run: scc_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in recursive CTEs, not random().
--   * The footprint grid is a 20 x 20 lattice of footprint centers (400
--     points, flat interleaved x,y).  The morphology estimator needs a
--     few hundred points for a stable answer, which is why the grid is
--     this size.  The degraded constellation loses an 8 x 8 block of
--     footprints (a dead zone), which raises lacunarity (gappiness).
--   * The link-quality series is 96 samples with a regime change at 49:
--     a stable carrier followed by a fast oscillation as a relay degrades.
--   * fractal_search_telemetry returns the row's ctid as doc_id.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Footprint grids: a healthy 20 x 20 lattice and a degraded copy
-- missing an 8 x 8 block (rows 6-13, columns 6-13).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Footprint lattices: healthy (400) vs degraded (336) ==='

DROP TABLE IF EXISTS scc_footprints;
CREATE TABLE scc_footprints (
    r int, c int, x float8, y float8
);
INSERT INTO scc_footprints (r, c, x, y)
SELECT r, c, c + 0.06 * (((r * 7 + c * 13) % 10) - 5) / 5.0,
             r + 0.06 * (((r * 11 + c * 3) % 10) - 5) / 5.0
FROM generate_series(0, 19) AS r, generate_series(0, 19) AS c
ORDER BY r, c;

SELECT count(*) AS healthy_footprints,
       count(*) FILTER (WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)) AS degraded_footprints
  FROM scc_footprints;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of each lattice.  The dead zone shows up
-- as higher lacunarity in the degraded constellation.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Morphology: healthy vs degraded constellation ==='

SELECT 'healthy' AS constellation,
       round((m->>'dimension')::numeric, 3)  AS dimension,
       round((m->>'lacunarity')::numeric, 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        (SELECT array_agg(v ORDER BY r, c, ord)
           FROM scc_footprints f, LATERAL unnest(ARRAY[round(f.x::numeric, 4)::float8,
                                                       round(f.y::numeric, 4)::float8]) WITH ORDINALITY AS u(v, ord)),
        2) AS m) h
UNION ALL
SELECT 'degraded',
       round((m->>'dimension')::numeric, 3),
       round((m->>'lacunarity')::numeric, 3)
FROM (SELECT fractal_morphological_complexity(
        (SELECT array_agg(v ORDER BY r, c, ord)
           FROM scc_footprints f, LATERAL unnest(ARRAY[round(f.x::numeric, 4)::float8,
                                                       round(f.y::numeric, 4)::float8]) WITH ORDINALITY AS u(v, ord)
          WHERE NOT (f.r BETWEEN 6 AND 13 AND f.c BETWEEN 6 AND 13)),
        2) AS m) d;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the degraded constellation: morphology plus
-- link-quality drift plus a reasoned coverage alert (reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_agent_network_coverage_alert (degraded constellation) ==='

SELECT morph_dimension, lacunarity, drift_detected, rationale
FROM fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM scc_footprints f, LATERAL unnest(ARRAY[round(f.x::numeric, 4)::float8,
                                                   round(f.y::numeric, 4)::float8]) WITH ORDINALITY AS u(v, ord)
      WHERE NOT (f.r BETWEEN 6 AND 13 AND f.c BETWEEN 6 AND 13)),
    (WITH RECURSIVE n(t, x) AS (
            SELECT 1, 4242::bigint UNION ALL
            SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 96)
     SELECT array_agg(round(v::numeric, 4)::float8 ORDER BY t)
       FROM (SELECT t,
                    CASE WHEN t < 49
                         THEN 4.0 + 1.5 * sin(t * 0.31) + ((((x / 65536) % 1000) - 500) / 1250.0)
                         ELSE 4.0 + 3.0 * sin(t * 1.4)  + ((((x / 65536) % 1000) - 500) / 2500.0)
                    END AS v FROM n) s),
    2, 48, 0.5);

-- ------------------------------------------------------------------
-- 4. Secondary branch: launch-manifest scheduling.  Each launch slot
-- has a capability vector [mass_margin, plane_A, plane_B, plane_C,
-- rideshare]; a replacement-satellite payload is placed on the nearest
-- slot.  Vector-refine + nearest-node match, one call.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Launch-slot scheduling: fractal_agent_schedule_workload ==='

DROP TABLE IF EXISTS scc_slots;
CREATE TABLE scc_slots (id int PRIMARY KEY, capability float8[]);
INSERT INTO scc_slots VALUES
    (1, ARRAY[0.9, 0.8, 0.0, 0.0, 0.1]),    -- heavy lift, plane A
    (2, ARRAY[0.5, 0.0, 0.9, 0.1, 0.4]),    -- medium lift, plane B
    (3, ARRAY[0.3, 0.0, 0.1, 0.9, 0.9]),    -- rideshare, plane C
    (4, ARRAY[0.6, 0.1, 0.8, 0.1, 0.2]);    -- medium lift, plane B

\echo '--- hand-composed: nearest slot to the replacement payload ---'
SELECT s.id AS assigned_slot, round((1.0 / (1.0 + t.distance))::numeric, 4) AS confidence
FROM fractal_search_telemetry('scc_slots', 'capability', ARRAY[0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 1) t
JOIN scc_slots s ON s.ctid::text = t.doc_id;

\echo '--- the shipped agent: same composition plus refinement, one call (reasoning plugin) ---'
SELECT assigned_node AS assigned_slot, confidence, rationale
FROM fractal_agent_schedule_workload(
    ARRAY[0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 'scc_slots', 'capability', 'id', 30, 50);

-- ------------------------------------------------------------------
-- 5. Reasoning: the combined narrative (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: coverage gap and replacement-launch narrative ==='

SELECT fractal_reason(
    'one-line summary of this constellation coverage gap and the launch slot chosen to fill it',
    json_build_object(
      'nearest_slot', (SELECT json_agg(t) FROM fractal_search_telemetry(
            'scc_slots', 'capability', ARRAY[0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 1) t))::text) AS narrative;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE scc_footprints, scc_slots;'
