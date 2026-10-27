-- demo/demo-vertical-document-risk-drift.sql
--
-- Industry vertical: Document risk drift: clause-level drift detection and
-- compliance review. DOMAIN kit: Four agreements x 96 weekly clause-risk
-- reviews; one agreement's amended terms drift into a new regime (an
-- accelerating risk creep). `fractal_dimension_drift` (the regime-detection
-- recipe from the quant-finance kit, applied to document risk) finds it;
-- Scout (`fractal_search_explore`) pulls six deliberately different clause
-- variants out of the 24-clause corpus so the reviewer sees the spread
-- rather than six near-copies; and `fractal_agent_recommend_diverse`
-- proposes diverse approved replacement language.
--
--   1. fractal_dimension_drift per agreement: whose clause risk changed
--      regime.
--   2. fractal_agent_anomaly_triage: the shipped one-call triage for the
--      drifting agreement.
--   3. Scout: six different clause variants across the four clause
--      families.
--   4. fractal_agent_recommend_diverse: diverse approved replacement
--      clauses.
--   5. A closing fractal_reason() writes the reviewer-ready note.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-document-risk-drift.sql
--
-- Safe to re-run: drd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Clause vector = [liability exposure, data-transfer scope, termination
--     rigidity, regulatory novelty].
--   * The drift exponent compares the recent window against the baseline
--     window of the same series.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Clause-risk telemetry: 4 agreements x 96 weekly reviews ==='
DROP TABLE IF EXISTS drd_risk;
CREATE TABLE drd_risk (
    ent text,
    seq int,
    val float8
);
INSERT INTO drd_risk (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM (VALUES ('DOC-A', 38, 0),
             ('DOC-B', 52, 0),
             ('DOC-C', 45, 0.0024),
             ('DOC-D', 61, 0)) AS s(ent, base, p2),
     generate_series(1, 96) AS g;

\echo ''
\echo '=== 2. Hand-composed: clause-risk regime drift per agreement ==='
DROP TABLE IF EXISTS drd_prof;
CREATE TABLE drd_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, (x.dj->>'drift')::float8 AS drift, (x.dj->>'recent_alpha')::float8 AS recent_alpha, (x.dj->>'baseline_alpha')::float8 AS baseline_alpha
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM drd_risk GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM drd_risk GROUP BY ent) m ON m.ent = a.ent
CROSS JOIN LATERAL (SELECT fractal_dimension_drift(a.arr, 32) AS dj) x
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((dfa_alpha)::numeric, 3) AS dfa_alpha, round((drift)::numeric, 4) AS drift, round((recent_alpha)::numeric, 4) AS recent_alpha, round((baseline_alpha)::numeric, 4) AS baseline_alpha
  FROM drd_prof ORDER BY ent;

\echo ''
\echo '=== 3. fractal_agent_anomaly_triage: drifting vs stable agreement ==='
SELECT 'DOC-C (drifting)' AS entity, threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('drd_risk', 'val', 'seq', 'ent', 'DOC-C', 32)
UNION ALL
SELECT 'DOC-A (stable)' AS entity, threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('drd_risk', 'val', 'seq', 'ent', 'DOC-A', 32);

\echo ''
\echo '=== 4. Scout: six different clause variants ==='
DROP TABLE IF EXISTS drd_clauses;
CREATE TABLE drd_clauses (
    id int PRIMARY KEY,
    label text,
    family text,
    c1 float8,
    c2 float8,
    c3 float8,
    c4 float8,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 4)
);
INSERT INTO drd_clauses (id, label, family, c1, c2, c3, c4, vec) VALUES
    (1, 'CL-01 data handling', 'data handling', 0.2013, 0.8387, 0.3313, 0.3687, ARRAY[0.2013, 0.8387, 0.3313, 0.3687]),
    (2, 'CL-02 termination', 'termination', 0.3626, 0.2374, 0.8726, 0.5974, ARRAY[0.3626, 0.2374, 0.8726, 0.5974]),
    (3, 'CL-03 scope limits', 'scope limits', 0.5739, 0.6361, 0.2639, 0.2261, ARRAY[0.5739, 0.6361, 0.2639, 0.2261]),
    (4, 'CL-04 liability', 'liability', 0.9352, 0.1348, 0.2052, 0.8548, ARRAY[0.9352, 0.1348, 0.2052, 0.8548]),
    (5, 'CL-05 data handling', 'data handling', 0.1465, 0.8335, 0.2465, 0.3335, ARRAY[0.1465, 0.8335, 0.2465, 0.3335]),
    (6, 'CL-06 termination', 'termination', 0.3078, 0.2322, 0.9378, 0.5622, ARRAY[0.3078, 0.2322, 0.9378, 0.5622]),
    (7, 'CL-07 scope limits', 'scope limits', 0.6691, 0.6309, 0.1791, 0.1909, ARRAY[0.6691, 0.6309, 0.1791, 0.1909]),
    (8, 'CL-08 liability', 'liability', 0.8804, 0.1296, 0.2704, 0.8196, ARRAY[0.8804, 0.1296, 0.2704, 0.8196]),
    (9, 'CL-09 data handling', 'data handling', 0.2417, 0.8283, 0.3117, 0.4483, ARRAY[0.2417, 0.8283, 0.3117, 0.4483]),
    (10, 'CL-10 termination', 'termination', 0.253, 0.227, 0.853, 0.527, ARRAY[0.253, 0.227, 0.853, 0.527]),
    (11, 'CL-11 scope limits', 'scope limits', 0.6143, 0.6257, 0.2443, 0.1557, ARRAY[0.6143, 0.6257, 0.2443, 0.1557]),
    (12, 'CL-12 liability', 'liability', 0.9756, 0.1244, 0.1856, 0.7844, ARRAY[0.9756, 0.1244, 0.1856, 0.7844]),
    (13, 'CL-13 data handling', 'data handling', 0.1869, 0.8231, 0.3769, 0.4131, ARRAY[0.1869, 0.8231, 0.3769, 0.4131]),
    (14, 'CL-14 termination', 'termination', 0.3482, 0.2218, 0.9182, 0.6418, ARRAY[0.3482, 0.2218, 0.9182, 0.6418]),
    (15, 'CL-15 scope limits', 'scope limits', 0.5595, 0.6205, 0.1595, 0.1205, ARRAY[0.5595, 0.6205, 0.1595, 0.1205]),
    (16, 'CL-16 liability', 'liability', 0.9208, 0.1192, 0.2508, 0.7492, ARRAY[0.9208, 0.1192, 0.2508, 0.7492]),
    (17, 'CL-17 data handling', 'data handling', 0.2821, 0.8179, 0.2921, 0.3779, ARRAY[0.2821, 0.8179, 0.2921, 0.3779]),
    (18, 'CL-18 termination', 'termination', 0.2934, 0.2166, 0.9834, 0.6066, ARRAY[0.2934, 0.2166, 0.9834, 0.6066]),
    (19, 'CL-19 scope limits', 'scope limits', 0.6547, 0.6153, 0.2247, 0.2353, ARRAY[0.6547, 0.6153, 0.2247, 0.2353]),
    (20, 'CL-20 liability', 'liability', 0.866, 0.114, 0.166, 0.714, ARRAY[0.866, 0.114, 0.166, 0.714]),
    (21, 'CL-21 data handling', 'data handling', 0.2273, 0.8127, 0.3573, 0.3427, ARRAY[0.2273, 0.8127, 0.3573, 0.3427]),
    (22, 'CL-22 termination', 'termination', 0.3886, 0.2114, 0.8986, 0.5714, ARRAY[0.3886, 0.2114, 0.8986, 0.5714]),
    (23, 'CL-23 scope limits', 'scope limits', 0.5999, 0.6101, 0.2899, 0.2001, ARRAY[0.5999, 0.6101, 0.2899, 0.2001]),
    (24, 'CL-24 liability', 'liability', 0.9612, 0.1088, 0.2312, 0.8288, ARRAY[0.9612, 0.1088, 0.2312, 0.8288]);
DROP TABLE IF EXISTS drd_scout;
CREATE TABLE drd_scout AS
SELECT pt.ord, pt.p
FROM fractal_search_explore(
         'drd_clauses', 'vec', ARRAY[0.5, 0.6, 0.4, 0.5]::float8[],
         '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}'::jsonb)
     WITH ORDINALITY AS pt(p, ord);

DROP TABLE IF EXISTS drd_picks;
CREATE TABLE drd_picks AS
SELECT t.ord, s.id, s.label, s.family
FROM drd_scout t
JOIN drd_clauses s ON abs(s.c1 - t.p[1]) < 1e-6 AND abs(s.c2 - t.p[2]) < 1e-6 AND abs(s.c3 - t.p[3]) < 1e-6 AND abs(s.c4 - t.p[4]) < 1e-6
ORDER BY t.ord;

SELECT ord, id, label, family FROM drd_picks ORDER BY ord;
\echo '--- coverage: clause families represented in the six picks ---'
SELECT count(DISTINCT family) AS families_covered_of_4 FROM drd_picks;

\echo ''
\echo '=== 5. Diverse approved replacement clauses ==='
DROP TABLE IF EXISTS drd_approved;
CREATE TABLE drd_approved (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 3)
);
INSERT INTO drd_approved (id, label, vec) VALUES
    (1, 'APPROVED-01 data handling', ARRAY[0.1513, 0.8487, 0.2763]),
    (2, 'APPROVED-02 termination', ARRAY[0.3026, 0.1474, 0.8776]),
    (3, 'APPROVED-03 scope limits', ARRAY[0.5789, 0.5461, 0.6539]),
    (4, 'APPROVED-04 liability', ARRAY[0.9302, 0.1448, 0.1552]),
    (5, 'APPROVED-05 data handling', ARRAY[0.1065, 0.8435, 0.2065]),
    (6, 'APPROVED-06 termination', ARRAY[0.2578, 0.1422, 0.9328]),
    (7, 'APPROVED-07 scope limits', ARRAY[0.6591, 0.5409, 0.5841]),
    (8, 'APPROVED-08 liability', ARRAY[0.8854, 0.1396, 0.2104]),
    (9, 'APPROVED-09 data handling', ARRAY[0.1867, 0.8383, 0.2617]),
    (10, 'APPROVED-10 termination', ARRAY[0.213, 0.137, 0.863]),
    (11, 'APPROVED-11 scope limits', ARRAY[0.6143, 0.5357, 0.6393]),
    (12, 'APPROVED-12 liability', ARRAY[0.9656, 0.1344, 0.1406]),
    (13, 'APPROVED-13 data handling', ARRAY[0.1419, 0.8331, 0.3169]),
    (14, 'APPROVED-14 termination', ARRAY[0.2932, 0.1318, 0.9182]),
    (15, 'APPROVED-15 scope limits', ARRAY[0.5695, 0.5305, 0.5695]),
    (16, 'APPROVED-16 liability', ARRAY[0.9208, 0.1292, 0.1958]),
    (17, 'APPROVED-17 data handling', ARRAY[0.2221, 0.8279, 0.2471]),
    (18, 'APPROVED-18 termination', ARRAY[0.2484, 0.1266, 0.9734]),
    (19, 'APPROVED-19 scope limits', ARRAY[0.6497, 0.5253, 0.6247]),
    (20, 'APPROVED-20 liability', ARRAY[0.876, 0.124, 0.126]);
DROP TABLE IF EXISTS drd_rec;
CREATE TABLE drd_rec AS
SELECT row_number() OVER (ORDER BY r.score DESC, r.item_id) AS rk, r.item_id::int AS item_id, c.label AS label,
       round(r.score::numeric, 4)::float8 AS score
FROM fractal_agent_recommend_diverse('drd_approved', 'vec', ARRAY[0.85, 0.2, 0.15]::float8[], 4, 'id') r
JOIN drd_approved c ON c.id = r.item_id::int
ORDER BY 1;

SELECT rk, item_id, label, score FROM drd_rec ORDER BY rk;
SELECT fractal_diversify_disable();

\echo ''
\echo '=== 6. Reasoning: reviewer-ready note ==='
SELECT fractal_reason(
    'one-line reviewer-ready note: which agreement drifted, the exposure, and the replacement language to propose',
    json_build_object('drifting_agreement', (SELECT ent FROM drd_prof ORDER BY drift DESC LIMIT 1), 'replacement', (SELECT label FROM drd_rec WHERE rk = 1))::text) AS narrative;

\echo ''
\echo '=== 7. Headline check ==='
SELECT 'HEADLINE kit=document-risk-drift ' || CASE WHEN (SELECT drift FROM drd_prof WHERE ent = 'DOC-C') > 0.5 AND (SELECT drift FROM drd_prof WHERE ent = 'DOC-A') < 0 AND (SELECT count(*) FROM drd_picks) = 6 AND (SELECT count(DISTINCT family) FROM drd_picks) >= 3 AND (SELECT count(*) FROM drd_rec) = 4 THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE drd_risk, drd_prof, drd_clauses, drd_picks, drd_scout, drd_approved, drd_rec;'
