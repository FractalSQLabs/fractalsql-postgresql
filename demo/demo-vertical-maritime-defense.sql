-- demo/demo-vertical-maritime-defense.sql
--
-- Industry vertical: Maritime, Aviation & Defense (AIS & Radar Tracking).
--
-- A synthetic AIS-style vessel fleet (30 vessels, lat/lon/speed/heading
-- track vectors) with one vessel given a deliberate course deviation --
-- fractal_search_trajectory's "current vs. baseline" delta search is a
-- direct fit for track-deviation detection ("what changed"), and DFA's
-- scaling exponent on a heading-change series is a real fit for
-- maneuvering-pattern irregularity (smooth transit vs. erratic track).
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Section 5 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-maritime-defense.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-maritime-defense.sql
--
-- Safe to re-run: vmd_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.29);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 30 vessels, each with a BASELINE track vector (their filed/typical
-- route: [lat_norm, lon_norm, speed_norm, heading_norm]) and a CURRENT
-- track vector. Vessel 7 gets a deliberate large deviation (course
-- change + speed drop -- a classic "gone dark then reappeared off
-- track" pattern); everyone else's current stays close to baseline
-- (normal transit noise).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 30 vessels: baseline vs. current AIS track vectors ==='

DROP TABLE IF EXISTS vmd_vessels;
CREATE TABLE vmd_vessels (
    id       serial PRIMARY KEY,
    mmsi     text,
    -- fractal_vector(4), not float8[] -- a fixed-width AIS track state
    -- ([lat_norm, lon_norm, speed_norm, heading_norm]), the same
    -- dimension-safety argument as vitals in demo-vertical-medtech-clinical.sql.
    baseline fractal_vector(4),
    current  fractal_vector(4)
);

-- Neither float8[] nor fractal_vector has a built-in elementwise +/-
-- operator, so baseline and current are built from the same
-- per-dimension base values directly rather than via array
-- arithmetic -- the INSERT below is otherwise UNCHANGED from the
-- float8[] version of this demo (still literal ::float8[] values),
-- relying on the same assignment-cast coercion
-- demo-vertical-medtech-clinical.sql's INSERT does.
INSERT INTO vmd_vessels (mmsi, baseline, current)
SELECT 'MMSI-' || (100000000 + gs),
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (random()-0.5)*0.05, b2 + (random()-0.5)*0.05,
             b3 + (random()-0.5)*0.1,  b4 + (random()-0.5)*0.1]::float8[]
FROM generate_series(1, 30) gs,
     LATERAL (SELECT random()*2-1, random()*2-1, random()*2-1, random()*2-1) AS bl(b1, b2, b3, b4);

-- Vessel 7's deliberate deviation: large heading/speed change from
-- baseline. fractal_vector has no [n] subscript operator (unlike
-- float8[]) -- cast to float8[] for the per-element arithmetic, then
-- let the assignment cast coerce the result back into the
-- fractal_vector(4) column on write.
UPDATE vmd_vessels
   SET current = ARRAY[(baseline::float8[])[1] + 0.6, (baseline::float8[])[2] - 0.5,
                        (baseline::float8[])[3] - 0.9, (baseline::float8[])[4] + 0.8]::float8[]
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. fractal_search_trajectory: current vs. baseline DELTA for the
-- flagged vessel -- which stored tracks does this deviation most
-- resemble? "What changed", not "what's closest" -- see that
-- function's own doc comment. flagged.baseline/flagged.current are
-- fractal_vector(4) column values, so this call resolves to the
-- fractal_vector overload directly -- no cast needed at the call site.
-- ------------------------------------------------------------------
-- doc_id is the row's 0-based position in the search's own internal
-- table scan, NOT id - 1 -- those only coincide for a table that has
-- never been UPDATEd. Vessel 7's deviation UPDATE in section 1
-- relocated its tuple to the end of the heap, so vmd_vessels' scan
-- order no longer matches id order. Map doc_id back to id via the
-- same ctid (physical scan) order the search actually used.
\echo ''
\echo '=== 2. fractal_search_trajectory: vessel 7''s deviation vs. the fleet ==='

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- vessel 7's deviation. Generalized by the shipped
-- fractal_agent_track_anomaly preset in Section 4, which folds this
-- trajectory search together with the heading-change DFA exponent and
-- a reasoning step (and resolves the nearest vessel via ctid, the same
-- mapping this raw form uses).
-- SELECT v.mmsi, t.distance
-- FROM vmd_vessels flagged, fractal_search_trajectory(
--     'vmd_vessels', 'current', flagged.baseline, flagged.current, 5
-- ) t
-- JOIN (SELECT *, row_number() OVER (ORDER BY ctid) - 1 AS doc_id
--         FROM vmd_vessels) v ON v.doc_id = t.doc_id
-- WHERE flagged.id = 7
-- ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry / fractal_search_explore: nearest-track
-- lookup (who's near a contact-of-interest position) and diverse-track
-- clustering (representative traffic patterns across the whole fleet).
--
-- Same doc_id-vs-id caveat as section 2 -- vessel 7's relocated tuple
-- means the plain table (not a cohort filter that excludes it) still
-- needs the ctid mapping.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Nearest vessels to a contact position, and diverse fleet traffic patterns ==='

\echo 'Nearest vessels to a contact-of-interest position:'
SELECT v.mmsi, t.distance
FROM fractal_search_telemetry('vmd_vessels', 'current',
                              ARRAY[0.2, 0.2, 0.5, 0.0]::float8[], 5) t
JOIN (SELECT *, row_number() OVER (ORDER BY ctid) - 1 AS doc_id
        FROM vmd_vessels) v ON v.doc_id = t.doc_id
ORDER BY t.distance;

\echo ''
\echo 'Diverse representative traffic patterns across the fleet:'
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's traffic-pattern embeddings.
-- SELECT p FROM fractal_search_explore(
--     'vmd_vessels', 'current', ARRAY[0,0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real vessel ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session (the engine leaves diversify on -- the caller owns
-- that policy) so later sections see the same diversify-off state as before.
-- The blueprint's zero query is query-agnostic (explore samples the space);
-- recommend_diverse is query-anchored, so anchor on the first vessel's own
-- current vector.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vmd_vessels', 'current',
    (SELECT current::float8[] FROM vmd_vessels ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 4. fractal_dimension_dfa: maneuvering-pattern irregularity. A smooth
-- transit heading series (vessel on a steady course) vs. vessel 7's
-- erratic heading series (evasive/anomalous maneuvering) -- DFA's
-- alpha separates the two: near-random-walk (smooth, ~1.3-1.5) vs.
-- much rougher/anti-persistent behavior for erratic maneuvering.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_dimension_dfa: heading-change series, normal vs. flagged vessel ==='

\echo 'Normal vessel (smooth heading drift over 120 samples):'
SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t, (random() - 0.5) * 0.03 AS step FROM generate_series(1, 120) t) s
    ) c)
) AS normal_vessel_alpha;

\echo ''
\echo 'Vessel 7 (erratic heading swings over the same window):'
-- Blueprint (raw primitive): the flagged vessel's heading-change DFA
-- exponent. Generalized below by the fractal_agent_track_anomaly preset,
-- which folds this together with the Section 2 trajectory search and a
-- reasoning step. (The normal-vessel DFA above stays raw -- a comparison
-- baseline the engine, which takes a single heading series, has no home
-- for.)
-- SELECT fractal_dimension_dfa(
--     (SELECT array_agg(cum ORDER BY t) FROM (
--         SELECT t, sum(step) OVER (ORDER BY t) AS cum
--           FROM (SELECT t,
--                        (random() - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step
--                   FROM generate_series(1, 120) t) s
--     ) c)
-- ) AS flagged_vessel_alpha;

-- Productized preset: the shipped engine returns the real nearest fleet
-- vessel (fractal_search_trajectory over vessel 7's baseline->current,
-- resolved via ctid), the real trajectory_distance, the real heading-
-- series DFA exponent, plus a real rationale.
\echo '--- Preset: fractal_agent_track_anomaly (raw trajectory+dfa form preserved above) ---'
SELECT nearest_fleet_id, trajectory_distance, dfa_exponent, rationale
FROM fractal_agent_track_anomaly(
    'vmd_vessels', 'current',
    (SELECT baseline::float8[] FROM vmd_vessels WHERE id = 7),
    (SELECT current::float8[]  FROM vmd_vessels WHERE id = 7),
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       (random() - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1, 120) t) s
    ) c),
    5, 'id');

-- ------------------------------------------------------------------
-- 5. Reasoning: the "does vessel 7's track need attention?" narrative is
-- now produced by the fractal_agent_track_anomaly preset's rationale
-- column in Section 4 (the same trajectory deviation + heading DFA,
-- folded into one reasoning step).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: absorbed into the Section 4 track_anomaly rationale ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vmd_vessels;'
