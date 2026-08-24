-- demo/demo-vertical-fleet-logistics.sql
--
-- Industry vertical: Autonomous Fleet Management & Last-Mile Delivery.
--
-- A 40-vehicle delivery fleet with route-embedding vectors, one vehicle
-- running a deliberately-detouring route. Diverse depot-coverage
-- clustering, a cohort-restricted search (today's route-3 vehicles
-- only), current-vs-baseline detour detection, and GPS-trace
-- complexity via box-counting.
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Section 5 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-fleet-logistics.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-fleet-logistics.sql
--
-- Safe to re-run: vfl_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.61);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 40 delivery vehicles across 4 routes, each with a BASELINE route
-- vector (planned stop sequence, embedded) and a CURRENT route vector
-- (today's actual telemetry). Vehicle 5 gets a deliberate large
-- detour; everyone else's current stays close to baseline (normal
-- traffic/timing noise).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 40 delivery vehicles: baseline vs. current route vectors ==='

DROP TABLE IF EXISTS vfl_vehicles;
CREATE TABLE vfl_vehicles (
    id       serial PRIMARY KEY,
    van_id   text,
    route_no int,
    -- fractal_vector(4), not float8[] -- same fixed-width,
    -- dimension-safety-matters argument as demo-vertical-medtech-clinical.sql's
    -- vitals and demo-vertical-maritime-defense.sql's baseline/current.
    baseline fractal_vector(4),
    current  fractal_vector(4)
);

-- INSERT is UNCHANGED (still literal ::float8[] values) -- the
-- assignment cast handles coercion into the fractal_vector(4) columns
-- automatically, same as the other two updated verticals.
INSERT INTO vfl_vehicles (van_id, route_no, baseline, current)
SELECT 'VAN-' || gs, ((gs - 1) % 4) + 1,
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (random()-0.5)*0.06, b2 + (random()-0.5)*0.06,
             b3 + (random()-0.5)*0.06, b4 + (random()-0.5)*0.06]::float8[]
FROM generate_series(1, 40) gs,
     LATERAL (SELECT random()*2-1, random()*2-1, random()*2-1, random()*2-1) AS bl(b1, b2, b3, b4);

-- Vehicle 5's deliberate detour: current route vector far from its
-- plan. fractal_vector has no [n] subscript operator -- cast to
-- float8[] for the per-element arithmetic (same pattern as
-- demo-vertical-maritime-defense.sql's vessel-7 UPDATE), then let the
-- assignment cast coerce the result back on write.
UPDATE vfl_vehicles
   SET current = ARRAY[(baseline::float8[])[1] - 0.7, (baseline::float8[])[2] + 0.6,
                        (baseline::float8[])[3] + 0.5, (baseline::float8[])[4] - 0.4]::float8[]
 WHERE id = 5;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse route/zone clustering across the fleet --
-- depot coverage planning ("what KINDS of routes are actually running
-- today") without scanning all 40 by hand.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_search_explore: diverse route/zone clustering ==='
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse representative set of
-- route/zone-cluster embeddings across the fleet.
-- SELECT p FROM fractal_search_explore(
--     'vfl_vehicles', 'current', ARRAY[0,0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real vehicle ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 cohort search below sees the same
-- diversify-off state as before (the engine leaves diversify on -- the
-- caller owns that policy). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so
-- anchor on the first vehicle's own current vector.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vfl_vehicles', 'current',
    (SELECT current::float8[] FROM vfl_vehicles ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Cohort-restricted search: "today's route-3 vehicles only" --
-- fractal_search_telemetry's table_name argument is a plain text table
-- name, so a cohort filter composes by searching a filtered temp table
-- instead (the same cohort-then-search shape
-- fractal_hybrid_clinical_search uses internally for its doc_ids
-- allowlist, without needing that clinically-named function here).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Cohort-restricted search: route-3 vehicles only ==='

-- v.id = t.doc_id + 1 holds here only because vehicle 5 (route_no = 1,
-- the sole UPDATEd row -- see section 1) is never in the route-3
-- filter: the UPDATE relocates ITS tuple, but leaves every route-3
-- vehicle's relative scan order untouched. Don't copy this shortcut
-- into a query whose cohort could include the updated row -- see
-- section 4 below and demo-vertical-maritime-defense.sql/
-- demo-vertical-cybersecurity-threat-detection.sql for the ctid-mapped
-- version this needs once that's no longer true.
DROP TABLE IF EXISTS vfl_route3_cohort;
CREATE TEMP TABLE vfl_route3_cohort AS
SELECT * FROM vfl_vehicles WHERE route_no = 3;

SELECT v.van_id, t.distance
FROM fractal_search_telemetry('vfl_route3_cohort', 'current',
                              ARRAY[0.3, -0.3, 0.2, 0.1]::float8[], 5) t
JOIN vfl_route3_cohort v ON v.id = t.doc_id + 1
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for vehicle
-- 5 -- detour detection, "what changed" not "what's closest".
-- flagged.baseline/flagged.current are fractal_vector(4) column
-- values, so this resolves to the fractal_vector overload directly.
--
-- Unlike section 3, this scans the FULL vfl_vehicles table -- which
-- includes vehicle 5's own relocated tuple (its detour UPDATE in
-- section 1 moved it to scan last). doc_id + 1 = id would mislabel
-- whichever row now happens to have that id; map via ctid (physical
-- scan) order instead.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_search_trajectory: vehicle 5''s detour vs. the fleet ==='

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- vehicle 5's detour. Generalized by the shipped
-- fractal_agent_detour_classify preset in Section 5, which folds this
-- trajectory search together with the GPS-trace box-counting complexity
-- and a reasoning step (and resolves the nearest vehicle via ctid, the
-- same mapping this raw form uses).
-- SELECT v.van_id, t.distance
-- FROM vfl_vehicles flagged, fractal_search_trajectory(
--     'vfl_vehicles', 'current', flagged.baseline, flagged.current, 5
-- ) t
-- JOIN (SELECT *, row_number() OVER (ORDER BY ctid) - 1 AS doc_id
--         FROM vfl_vehicles) v ON v.doc_id = t.doc_id
-- WHERE flagged.id = 5
-- ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 5. fractal_dimension_boxcount: GPS-trace complexity for vehicle 5's
-- detoured route (a 2D wandering path, 200 samples) -- a smooth planned
-- route would trace a near-straight path (dimension close to 1); a
-- detour with backtracking/wandering pushes it higher.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. fractal_dimension_boxcount: vehicle 5''s GPS trace complexity ==='

-- Blueprint (raw primitive): the GPS trace's box-counting complexity.
-- Generalized below by the fractal_agent_detour_classify preset, which
-- folds this together with the Section 4 trajectory search and a
-- reasoning step.
-- SELECT fractal_dimension_boxcount(
--     (SELECT array_agg(cum ORDER BY t, ord) FROM (
--         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
--         FROM generate_series(1, 200) t
--         CROSS JOIN LATERAL (VALUES (1, (random()-0.5)*0.3), (2, (random()-0.5)*0.3)) AS s(ord, step)
--     ) c),
--     2
-- ) AS gps_trace_dimension;

-- Productized preset: the shipped engine returns the real nearest fleet
-- vehicle (fractal_search_trajectory over vehicle 5's baseline->current,
-- resolved via ctid), the real trajectory_distance, the real GPS-trace
-- box-counting complexity, plus a real rationale.
\echo '--- Preset: fractal_agent_detour_classify (raw trajectory+boxcount form preserved above) ---'
SELECT nearest_fleet_id, trajectory_distance, trace_complexity, rationale
FROM fractal_agent_detour_classify(
    'vfl_vehicles', 'current',
    (SELECT baseline::float8[] FROM vfl_vehicles WHERE id = 5),
    (SELECT current::float8[]  FROM vfl_vehicles WHERE id = 5),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
        SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
        FROM generate_series(1, 200) t
        CROSS JOIN LATERAL (VALUES (1, (random()-0.5)*0.3), (2, (random()-0.5)*0.3)) AS s(ord, step)
    ) c),
    5, 'id', 2);

-- ------------------------------------------------------------------
-- 6. Reasoning: the dispatch narrative for vehicle 5 is now produced by
-- the fractal_agent_detour_classify preset's rationale column in
-- Section 5 (the same trajectory deviation + GPS-trace complexity,
-- folded into one reasoning step).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. Reasoning: absorbed into the Section 5 detour_classify rationale ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vfl_vehicles;'
