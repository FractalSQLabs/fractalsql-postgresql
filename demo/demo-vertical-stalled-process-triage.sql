-- demo/demo-vertical-stalled-process-triage.sql
--
-- Industry vertical: Staged pipeline: velocity bottlenecks and stalled-item
-- triage. DOMAIN kit: 36 open items across segments and stages; three
-- tier-1 items in the review stage show the same stall signature
-- (time-in-stage far above the healthy velocity, falling engagement, a
-- silent owner, deepening concessions).
-- `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort
-- search plus baseline-vs-current drift, with item-health columns in place
-- of clinical vitals): an item's stage-entry telemetry plays the patient's
-- admission baseline.
--
--   1. Cohort-restricted search: tier-1 items in the review stage only
--      (plain SQL picks the cohort).
--   2. fractal_search_trajectory: which items moved from the healthy-
--      velocity baseline the way the stalled one did.
--   3. fractal_agent_patient_deterioration_triage: both searches plus a
--      reasoned rationale in one call.
--   4. A closing fractal_reason() writes the recovery-plan recommendation.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-stalled-process-triage.sql
--
-- Safe to re-run: spt_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Item-health vector = [days-in-stage drift, engagement drop, owner
--     silence, concession pressure]; healthy items sit near zero.
--   * The three stalled items (ids 7, 15, 31) share one vector, so they tie
--     at the top of the trajectory search.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. 36 items: segment, stage and item-health vector ==='
DROP TABLE IF EXISTS spt_items;
CREATE TABLE spt_items (
    id int PRIMARY KEY,
    label text,
    segment text,
    stage text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 4)
);
INSERT INTO spt_items (id, label, segment, stage, vec) VALUES
    (1, 'ITEM-001', 'tier-2', 'intake', ARRAY[0.05, -0.06, 0.03, -0.04]),
    (2, 'ITEM-002', 'tier-3', 'review', ARRAY[0.1, -0.02, 0.06, 0.02]),
    (3, 'ITEM-003', 'tier-1', 'intake', ARRAY[0.15, 0.02, 0.09, 0.08]),
    (4, 'ITEM-004', 'tier-2', 'review', ARRAY[0.2, 0.06, 0, 0.14]),
    (5, 'ITEM-005', 'tier-3', 'intake', ARRAY[0, 0.1, 0.03, 0.2]),
    (6, 'ITEM-006', 'tier-1', 'review', ARRAY[0.05, 0.14, 0.06, -0.1]),
    (7, 'ITEM-007', 'tier-1', 'review', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (8, 'ITEM-008', 'tier-3', 'review', ARRAY[0.15, -0.06, 0, 0.02]),
    (9, 'ITEM-009', 'tier-1', 'intake', ARRAY[0.2, -0.02, 0.03, 0.08]),
    (10, 'ITEM-010', 'tier-2', 'review', ARRAY[0, 0.02, 0.06, 0.14]),
    (11, 'ITEM-011', 'tier-3', 'intake', ARRAY[0.05, 0.06, 0.09, 0.2]),
    (12, 'ITEM-012', 'tier-1', 'review', ARRAY[0.1, 0.1, 0, -0.1]),
    (13, 'ITEM-013', 'tier-2', 'intake', ARRAY[0.15, 0.14, 0.03, -0.04]),
    (14, 'ITEM-014', 'tier-3', 'review', ARRAY[0.2, -0.1, 0.06, 0.02]),
    (15, 'ITEM-015', 'tier-1', 'review', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (16, 'ITEM-016', 'tier-2', 'review', ARRAY[0.05, -0.02, 0, 0.14]),
    (17, 'ITEM-017', 'tier-3', 'intake', ARRAY[0.1, 0.02, 0.03, 0.2]),
    (18, 'ITEM-018', 'tier-1', 'review', ARRAY[0.15, 0.06, 0.06, -0.1]),
    (19, 'ITEM-019', 'tier-2', 'intake', ARRAY[0.2, 0.1, 0.09, -0.04]),
    (20, 'ITEM-020', 'tier-3', 'review', ARRAY[0, 0.14, 0, 0.02]),
    (21, 'ITEM-021', 'tier-1', 'intake', ARRAY[0.05, -0.1, 0.03, 0.08]),
    (22, 'ITEM-022', 'tier-2', 'review', ARRAY[0.1, -0.06, 0.06, 0.14]),
    (23, 'ITEM-023', 'tier-3', 'intake', ARRAY[0.15, -0.02, 0.09, 0.2]),
    (24, 'ITEM-024', 'tier-1', 'review', ARRAY[0.2, 0.02, 0, -0.1]),
    (25, 'ITEM-025', 'tier-2', 'intake', ARRAY[0, 0.06, 0.03, -0.04]),
    (26, 'ITEM-026', 'tier-3', 'review', ARRAY[0.05, 0.1, 0.06, 0.02]),
    (27, 'ITEM-027', 'tier-1', 'intake', ARRAY[0.1, 0.14, 0.09, 0.08]),
    (28, 'ITEM-028', 'tier-2', 'review', ARRAY[0.15, -0.1, 0, 0.14]),
    (29, 'ITEM-029', 'tier-3', 'intake', ARRAY[0.2, -0.06, 0.03, 0.2]),
    (30, 'ITEM-030', 'tier-1', 'review', ARRAY[0, -0.02, 0.06, -0.1]),
    (31, 'ITEM-031', 'tier-1', 'review', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (32, 'ITEM-032', 'tier-3', 'review', ARRAY[0.1, 0.06, 0, 0.02]),
    (33, 'ITEM-033', 'tier-1', 'intake', ARRAY[0.15, 0.1, 0.03, 0.08]),
    (34, 'ITEM-034', 'tier-2', 'review', ARRAY[0.2, 0.14, 0.06, 0.14]),
    (35, 'ITEM-035', 'tier-3', 'intake', ARRAY[0, -0.1, 0.09, 0.2]),
    (36, 'ITEM-036', 'tier-1', 'review', ARRAY[0.05, -0.06, 0, -0.1]);
SELECT segment, stage, count(*) AS n FROM spt_items
 GROUP BY segment, stage ORDER BY segment, stage;

\echo ''
\echo '=== 2. Cohort-restricted search: tier-1 items in review ==='
SELECT w.id, w.label AS label, round(h.distance::numeric, 4) AS distance
FROM fractal_hybrid_clinical_search(
         'spt_items', 'vec', ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],
         (SELECT array_agg(ctid::text ORDER BY ctid) FROM spt_items WHERE segment = 'tier-1' AND stage = 'review'),
         5) h
JOIN spt_items w ON w.ctid::text = h.doc_id
ORDER BY h.distance, w.id;

\echo ''
\echo '=== 3. Baseline -> current item-health trajectory ==='
DROP TABLE IF EXISTS spt_traj;
CREATE TABLE spt_traj AS
WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, id, label FROM spt_items)
SELECT row_number() OVER (ORDER BY tr.distance, pos.id) AS rk, pos.id, pos.label AS label,
       round(tr.distance::numeric, 4)::float8 AS distance
FROM fractal_search_trajectory(
         'spt_items', 'vec',
         ARRAY[0.05, 0, 0.03, 0]::float8[],    -- baseline
         ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],    -- current
         5) tr
JOIN pos ON pos.doc_id = tr.doc_id;

SELECT rk, id, label, distance FROM spt_traj ORDER BY rk;

\echo ''
\echo '=== 4. fractal_agent_patient_deterioration_triage (stalled-item triage) ==='
DROP TABLE IF EXISTS spt_triage;
CREATE TABLE spt_triage AS
SELECT nearest_cohort_id::text AS nearest_cohort_id, cohort_distance, drift_distance, rationale
FROM fractal_agent_patient_deterioration_triage(
    'spt_items', 'vec', ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],
    ARRAY[0.05, 0, 0.03, 0]::float8[], ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],
    (SELECT array_agg(ctid::text ORDER BY ctid) FROM spt_items WHERE segment = 'tier-1' AND stage = 'review'),
    5, 'id');

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale FROM spt_triage;

\echo ''
\echo '=== 5. Reasoning: recovery-plan recommendation ==='
SELECT fractal_reason(
    'one-line recovery-plan recommendation for these stalled tier-1 items',
    json_build_object('stalled_items_found', (SELECT count(*) FROM spt_traj WHERE distance < 0.001), 'nearest_cohort_item', (SELECT nearest_cohort_id FROM spt_triage))::text) AS narrative;

\echo ''
\echo '=== 6. Headline check ==='
SELECT 'HEADLINE kit=stalled-process-triage ' || CASE WHEN (SELECT count(*) FROM spt_traj WHERE distance < 0.001) >= 3 AND (SELECT nearest_cohort_id FROM spt_triage) IN ('7', '15', '31') THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE spt_items, spt_traj, spt_triage;'
