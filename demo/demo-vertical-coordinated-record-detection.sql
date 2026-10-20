-- demo/demo-vertical-coordinated-record-detection.sql
--
-- Industry vertical: Coordinated-record detection: ring signatures and
-- severity-trajectory analysis. DOMAIN kit: A review desk screens new
-- submissions against known ring signatures with
-- `fractal_agent_outlier_intercept`, finds the records that moved from the
-- normal severity baseline the way a staged ring does with
-- `fractal_search_trajectory`, and measures the geographic footprint of
-- event locations with `fractal_dimension_boxcount` (organic events scatter
-- across the city; a staged ring repeats along one road).
--
--   1. fractal_agent_outlier_intercept: hold new records that match a known
--      ring signature.
--   2. fractal_search_trajectory: which open records moved the way the
--      ring's records did.
--   3. fractal_dimension_boxcount: the footprint of event locations,
--      organic vs ring.
--   4. A closing fractal_reason() writes the referral line.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-coordinated-record-detection.sql
--
-- Safe to re-run: crd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ring signature = [record velocity, shared provider, shared
--     representative, soft-tissue ratio, address clustering].
--   * Severity vector = [severity jump, treatment gap, bill inflation,
--     representative speed]; the three ring records (ids 5, 13, 22) share
--     one vector.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Known ring signatures + proposed new records ==='
DROP TABLE IF EXISTS crd_known;
CREATE TABLE crd_known (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 5)
);
INSERT INTO crd_known (id, label, vec) VALUES
    (1, 'staged-event ring: same provider and representative', ARRAY[0.95, 0.9, 0.85, 0.1, 0.2]),
    (2, 'synthetic-severity ring: repeated minor-severity pile-up', ARRAY[0.9, 0.05, 0.3, 0.95, 0.4]),
    (3, 'phantom-participant records, one address cluster', ARRAY[0.05, 0.05, 0.1, 0.1, 0.95]),
    (4, 'provider-collusion ring: repeat billing', ARRAY[0.1, 0.8, 0.9, 0.85, 0.3]);
DROP TABLE IF EXISTS crd_proposed;
CREATE TABLE crd_proposed (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 5)
);
INSERT INTO crd_proposed (id, label, vec) VALUES
    (1, 'P1 staged-pattern record, usual provider and representative', ARRAY[0.92, 0.88, 0.8, 0.12, 0.18]),
    (2, 'P2 isolated single-party record', ARRAY[0.02, 0, 0.05, 0, 0.05]),
    (3, 'P3 new provider, same city', ARRAY[0, 0.02, 0.7, 0.04, 0.05]),
    (4, 'P4 faint minor-severity pattern, far away', ARRAY[0.4, 0.02, 0.12, 0.42, 0.16]);

\echo ''
\echo '=== 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ==='
DROP TABLE IF EXISTS crd_screen;
CREATE TABLE crd_screen AS
SELECT p.id, p.label, o.intercepted::int AS intercepted, o.metric
FROM crd_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(p.vec, 'crd_known', 'vec', 0.1) o
ORDER BY p.id;

SELECT id, label, intercepted, metric FROM crd_screen ORDER BY id;

\echo ''
\echo '=== 3. Open-record severity trajectory: who moved like the ring ==='
DROP TABLE IF EXISTS crd_records;
CREATE TABLE crd_records (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 4)
);
INSERT INTO crd_records (id, label, vec) VALUES
    (1, 'REC-001', ARRAY[0.05, -0.06, 0.03, -0.04]),
    (2, 'REC-002', ARRAY[0.1, -0.02, 0.06, 0.02]),
    (3, 'REC-003', ARRAY[0.15, 0.02, 0.09, 0.08]),
    (4, 'REC-004', ARRAY[0.2, 0.06, 0, 0.14]),
    (5, 'REC-005 (ring)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (6, 'REC-006', ARRAY[0.05, 0.14, 0.06, -0.1]),
    (7, 'REC-007', ARRAY[0.1, -0.1, 0.09, -0.04]),
    (8, 'REC-008', ARRAY[0.15, -0.06, 0, 0.02]),
    (9, 'REC-009', ARRAY[0.2, -0.02, 0.03, 0.08]),
    (10, 'REC-010', ARRAY[0, 0.02, 0.06, 0.14]),
    (11, 'REC-011', ARRAY[0.05, 0.06, 0.09, 0.2]),
    (12, 'REC-012', ARRAY[0.1, 0.1, 0, -0.1]),
    (13, 'REC-013 (ring)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (14, 'REC-014', ARRAY[0.2, -0.1, 0.06, 0.02]),
    (15, 'REC-015', ARRAY[0, -0.06, 0.09, 0.08]),
    (16, 'REC-016', ARRAY[0.05, -0.02, 0, 0.14]),
    (17, 'REC-017', ARRAY[0.1, 0.02, 0.03, 0.2]),
    (18, 'REC-018', ARRAY[0.15, 0.06, 0.06, -0.1]),
    (19, 'REC-019', ARRAY[0.2, 0.1, 0.09, -0.04]),
    (20, 'REC-020', ARRAY[0, 0.14, 0, 0.02]),
    (21, 'REC-021', ARRAY[0.05, -0.1, 0.03, 0.08]),
    (22, 'REC-022 (ring)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (23, 'REC-023', ARRAY[0.15, -0.02, 0.09, 0.2]),
    (24, 'REC-024', ARRAY[0.2, 0.02, 0, -0.1]),
    (25, 'REC-025', ARRAY[0, 0.06, 0.03, -0.04]),
    (26, 'REC-026', ARRAY[0.05, 0.1, 0.06, 0.02]),
    (27, 'REC-027', ARRAY[0.1, 0.14, 0.09, 0.08]),
    (28, 'REC-028', ARRAY[0.15, -0.1, 0, 0.14]),
    (29, 'REC-029', ARRAY[0.2, -0.06, 0.03, 0.2]),
    (30, 'REC-030', ARRAY[0, -0.02, 0.06, -0.1]);
DROP TABLE IF EXISTS crd_traj;
CREATE TABLE crd_traj AS
WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, id, label FROM crd_records)
SELECT row_number() OVER (ORDER BY tr.distance, pos.id) AS rk, pos.id, pos.label AS label,
       round(tr.distance::numeric, 4)::float8 AS distance
FROM fractal_search_trajectory(
         'crd_records', 'vec',
         ARRAY[0.05, 0, 0.03, 0]::float8[],    -- baseline
         ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],    -- current
         5) tr
JOIN pos ON pos.doc_id = tr.doc_id;

SELECT rk, id, label, distance FROM crd_traj ORDER BY rk;

\echo ''
\echo '=== 4. Event-location topology: organic vs staged ring ==='
DROP TABLE IF EXISTS crd_locations;
CREATE TABLE crd_locations (
    ent text,
    pt  int,
    x   float8,
    y   float8
);
INSERT INTO crd_locations (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
FROM (VALUES ('organic-records', 1),
             ('staged-ring', 0)) AS s(ent, p1),
     generate_series(1, 200) AS g;
DROP TABLE IF EXISTS crd_dim;
CREATE TABLE crd_dim AS
SELECT ent, round(fractal_dimension_boxcount(array_agg(v ORDER BY pt, ord), 2)::numeric, 3)::float8 AS dim
FROM (SELECT ent, pt, ord, v
        FROM crd_locations CROSS JOIN LATERAL unnest(ARRAY[x, y]) WITH ORDINALITY AS u(v, ord)) q
GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM crd_dim ORDER BY ent;

\echo ''
\echo '=== 5. Reasoning: referral ==='
SELECT fractal_reason(
    'one-line referral for the suspected staged-event ring',
    json_build_object('held_record', (SELECT label FROM crd_screen WHERE id = 1), 'ring_records_found', (SELECT count(*) FROM crd_traj WHERE distance < 0.001), 'ring_dimension', (SELECT dim FROM crd_dim WHERE ent = 'staged-ring'))::text) AS narrative;

\echo ''
\echo '=== 6. Headline check ==='
SELECT 'HEADLINE kit=coordinated-record-detection ' || CASE WHEN (SELECT intercepted FROM crd_screen WHERE id = 1) = 1 AND (SELECT intercepted FROM crd_screen WHERE id = 2) = 0 AND (SELECT intercepted FROM crd_screen WHERE id = 4) = 1 AND (SELECT count(*) FROM crd_traj WHERE distance < 0.001) >= 3 AND (SELECT dim FROM crd_dim WHERE ent = 'staged-ring') + 0.3 < (SELECT dim FROM crd_dim WHERE ent = 'organic-records') THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim;'
