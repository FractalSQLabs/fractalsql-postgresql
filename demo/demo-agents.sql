-- =============================================================================
-- FractalSQL Agents validation demo
-- =============================================================================
-- End-to-end validation of the sixteen installable agents shipped in the
-- optional `fractalsql_agents` dependent extension (requires='fractalsql').
-- Unlike the demo-agentic-*.sql demos -- which ship reference blueprint
-- functions inline at the top of the script -- this demo exercises the
-- agents via the real `CREATE EXTENSION fractalsql_agents` product path:
-- they are already installed as callable SQL functions in the database.
--
-- Agents exercised (13 cognition -> call fractal_reason;
-- 3 pure retrieval/analytics -> no LLM):
--   * fractal_agent_anomaly_triage            -- fractal_dimension_drift + fractal_reason
--   * fractal_agent_allocate                  -- fractal_optimize_portfolio + fractal_reason
--   * fractal_agent_route_task                -- fractal_search_telemetry + fractal_reason
--   * fractal_agent_outlier_intercept         -- fractal_search_telemetry + fractal_reason
--   * fractal_agent_recall_hybrid             -- fractal_hybrid_clinical_search (no LLM)
--   * fractal_agent_recommend_diverse         -- fractal_diversify_enable + telemetry (no LLM)
--   * fractal_agent_data_analyst              -- fractal_sql_agent + fractal_reason
--   * fractal_agent_patient_deterioration_triage -- hybrid_clinical_search + search_trajectory + reason
--   * fractal_agent_feedback_audit            -- diversify + isolate_background + detect_collapse (no LLM)
--   * fractal_agent_schedule_workload         -- fractal_search + telemetry + reason
--   * fractal_agent_rebalance_sibling         -- optimize_portfolio + search_trajectory + reason
--   * fractal_agent_detour_classify           -- search_trajectory + dimension_boxcount + reason
--   * fractal_agent_track_anomaly             -- search_trajectory + dimension_dfa + reason
--   * fractal_agent_network_coverage_alert    -- morphological_complexity + dimension_drift + reason
--   * fractal_agent_regime_triage             -- dimension_dfa + dimension_drift + reason
--   * fractal_agent_diverse_portfolios        -- optimize_portfolio_multimodal + reason (enterprise tier)
-- Every output column is a REAL primitive result, not a literal: threat_score
-- is the computed drift exponent; allocation/sharpe are the optimizer's own
-- output (no hardcoded 0.042); routed_to is the real nearest capability name and
-- confidence is 1/(1+distance); intercepted is a real distance-vs-threshold
-- comparison; mem_id/content are the real recalled row; item_id/score are the
-- real catalog id and 1-cosine_distance (no canned 0.95-i*0.01). The other
-- agents likewise: data_analyst's generated_sql/result_json are the real
-- sql_agent outputs; patient_deterioration_triage's nearest_cohort_id is the
-- real hybrid-search nearest resolved via ctid; feedback_audit's
-- diversity_quotient is the real detect_collapse (not NaN once the window is
-- warmed); schedule_workload's assigned_node/confidence, rebalance_sibling's
-- sharpe/weights/nearest_alloc_id, detour_classify's trace_complexity,
-- track_anomaly's dfa_exponent, and network_coverage_alert/regime_triage's
-- drift_detected (|drift|>threshold, the drift field is a signed numeric) are
-- all real primitive results. The 13 cognition agents'
-- triage_summary/rationale/reason/analysis columns are real fractal_reason
-- output. A closing fractal_reason() call synthesizes over the computed
-- results -- same closing pattern as demo.sql and every vertical demo.
--
-- fractal_agent_diverse_portfolios is enterprise tier (companion to
-- fractal_agent_allocate, Engine B): exception-guarded like
-- demo/enterprise-qtl-audit.sql so this script still completes cleanly on
-- the community image, where it is dormant by default.
--
-- Prerequisites:
--   1. CREATE EXTENSION fractalsql;          (the base extension)
--   2. CREATE EXTENSION fractalsql_agents;   (the dependent extension -- refuses
--      if fractalsql isn't present)
--   3. Reasoning configured -- the 13 cognition agents call
--      fractal_reason; the 3 retrieval/analytics agents need no
--      endpoint. See docs/reasoning-setup.md. Confirm before running:
--        SELECT fractal_reason('reply with a short confirmation');
-- Re-runnable: agents_demo_logs and the fixture tables are dropped and
-- recreated at the top of their sections.
-- =============================================================================

\timing on

-- 0. Prerequisite check -- both extensions must be installed.
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('fractalsql', 'fractalsql_agents')
ORDER BY extname;
-- Expect two rows. If fractalsql_agents is missing:
--   CREATE EXTENSION fractalsql_agents;
-- If fractalsql is missing, install the base extension first.

-- 1. Setup: a drifting metric time series for one host.
-- Same step-up shape as demo-vertical-agentic-ops-devops.sql: a baseline ~50 for
-- the first 48 rows then a +30 step-up, 96 points, so
-- fractal_dimension_drift's 32-point recent window has a real regime change
-- to detect (DFA needs the recent window large enough; window=16 is too
-- small and returns rc=-1). A second host makes the host filter meaningful.
DROP TABLE IF EXISTS agents_demo_logs;
CREATE TABLE agents_demo_logs (metric float8, ts timestamptz, host text);
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - gs) * interval '1 second', 'host-1'
FROM generate_series(1, 96) AS gs;
INSERT INTO agents_demo_logs VALUES
    (10, now(), 'host-2'),
    (11, now() + interval '1 min', 'host-2');

-- 2. fractal_agent_anomaly_triage (happy path).
-- threat_score is the REAL drift exponent (fractal_dimension_drift ran over
-- host-1's 96-point series); anomaly_type is the literal 'vector_drift' label
-- (a real label for what drift detects, not a stub); triage_summary is the
-- REAL fractal_reason output over the drift result.
\echo '=== fractal_agent_anomaly_triage (host-1, 32-pt recent window) ==='
SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32);

-- 2b. anomaly_triage empty-series guard (interactive only -- not in the re-runnable
-- path because it raises an ERROR). Uncomment to confirm it rejects cleanly:
-- SELECT * FROM fractal_agent_anomaly_triage(
--     'agents_demo_logs', 'metric', 'ts', 'host', 'no-such-host', 32);
-- Expect: ERROR: fractal_agent_anomaly_triage: no rows in agents_demo_logs.metric ...

-- 3. fractal_agent_allocate (happy path).
-- allocation is the REAL optimizer jsonb {sharpe, weights}; sharpe is the REAL
-- risk-adjusted return extracted from it (this is the column the demo
-- blueprint's hardcoded 0.042 "drift_score" literal used to fake); rationale is
-- the REAL fractal_reason output. cov is the 2x2 identity flattened to a 1-D
-- row-major 4-element array (fractal_optimize_portfolio reads it flattened,
-- not as a 2-D matrix).
\echo '=== fractal_agent_allocate (2 assets, cardinality=1) ==='
SELECT allocation, sharpe, rationale
FROM fractal_agent_allocate(
    ARRAY[0.05, 0.1]::float8[],
    ARRAY[1.0, 0.0, 0.0, 1.0]::float8[],
    1,
    '{"portfolio": "agents-demo"}'::text);

-- 4. fractal_agent_route_task (happy path).
-- task_emb is the incoming task embedding; the agent finds the nearest
-- capability row in agents_demo_caps via fractal_search_telemetry, resolves the
-- 0-indexed scan position back to the named capability id via the ctid
-- row_number() mapping, and routes. routed_to is the REAL capability name;
-- confidence is 1/(1+distance) (real, from the nearest-distance); rationale is
-- the REAL fractal_reason output.
DROP TABLE IF EXISTS agents_demo_caps;
CREATE TABLE agents_demo_caps (capability_name text, emb float8[]);
INSERT INTO agents_demo_caps VALUES
    ('root-cause-analyzer', ARRAY[0.1, 0.2, 0.3]),
    ('capacity-autoscaler', ARRAY[0.9, 0.8, 0.7]),
    ('incident-pager',      ARRAY[0.3, 0.3, 0.9]);

\echo '=== fractal_agent_route_task (task near root-cause-analyzer) ==='
SELECT routed_to, confidence, remaining_budget, rationale
FROM fractal_agent_route_task(
    ARRAY[0.11, 0.21, 0.31]::float8[],
    'agents_demo_caps', 'emb', 'capability_name', 1000);

-- 4b. route_task empty-table guard (interactive only -- raises an ERROR).
-- Uncomment to confirm it rejects cleanly:
-- SELECT * FROM fractal_agent_route_task(
--     ARRAY[0.1,0.2,0.3]::float8[], 'agents_demo_caps', 'emb',
--     'capability_name', 1000)
-- WHERE NOT EXISTS (SELECT 1 FROM agents_demo_caps);
-- (Empty the table first: TRUNCATE agents_demo_caps;)
-- Expect: ERROR: fractal_agent_route_task: no capability rows in agents_demo_caps

-- 5. fractal_agent_outlier_intercept.
-- Screens a proposed action's state vector against known-bad states. Uses
-- ORTHOGONAL vectors for the "far" case, because cosine distance ignores
-- magnitude: [0.1,0.1,0.1] vs [0.9,0.9,0.9] are parallel (distance 0), not far.
-- A far probe must point a different direction -- here [0,1,0] vs bad [1,0,0]
-- -> distance 1 > 0.5 -> intercepted=false.
DROP TABLE IF EXISTS agents_demo_badstates;
CREATE TABLE agents_demo_badstates (emb float8[]);
INSERT INTO agents_demo_badstates VALUES
    (ARRAY[1.0, 0.0, 0.0]),
    (ARRAY[0.9, 0.1, 0.0]);

\echo '=== fractal_agent_outlier_intercept (near a bad state) ==='
SELECT intercepted, reason
FROM fractal_agent_outlier_intercept(
    ARRAY[0.95, 0.05, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

\echo '=== fractal_agent_outlier_intercept (orthogonal/far) ==='
SELECT intercepted, reason
FROM fractal_agent_outlier_intercept(
    ARRAY[0.0, 1.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

-- 6. fractal_agent_recall_hybrid (happy path).
-- Pure retrieval: no LLM step. The "hybrid" is the cohort -- a strict SQL
-- filter (customer_id) mapped to 0-indexed scan positions, then
-- fractal_hybrid_clinical_search restricts the vector recall to that cohort.
-- mem_id is the REAL session_id from the matching row (not a canned 1..5);
-- content is the REAL row text (not 'recalled memory snippet N').
DROP TABLE IF EXISTS agents_demo_mem;
CREATE TABLE agents_demo_mem (
    session_id    bigint,
    customer_id   text,
    state_vector  float8[],
    content       text
);
INSERT INTO agents_demo_mem VALUES
    (1001, 'cust-a', ARRAY[0.2, 0.2, 0.2], 'resolved churn via loyalty upgrade'),
    (1002, 'cust-a', ARRAY[0.8, 0.8, 0.8], 'escalated billing dispute to agent'),
    (1003, 'cust-b', ARRAY[0.5, 0.5, 0.5], 'refunded a duplicate charge');

\echo '=== fractal_agent_recall_hybrid (cust-a cohort, k=2) ==='
SELECT mem_id, content
FROM fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', ARRAY[0.18, 0.22, 0.2]::float8[],
    'customer_id', 'cust-a', 2, 'session_id', 'content');

-- 6b. recall_hybrid no-rows guard (interactive only -- raises an ERROR).
-- Uncomment to confirm it rejects cleanly:
-- SELECT * FROM fractal_agent_recall_hybrid(
--     'agents_demo_mem', 'state_vector', ARRAY[0.1,0.1,0.1]::float8[],
--     'customer_id', 'no-such-customer', 5, 'session_id', 'content');
-- Expect: ERROR: fractal_agent_recall_hybrid: filter matched no rows in agents_demo_mem

-- 7. fractal_agent_recommend_diverse (happy path).
-- Pure retrieval: no LLM step. Enables session-global repulsion
-- (fractal_diversify_enable) so the search avoids recently-rejected items, then
-- fractal_search_telemetry returns a repulsion-diverse top-k. item_id is the
-- REAL catalog id (resolved via the ctid mapping); score is 1-cosine_distance
-- (real, from the primitive -- not the canned 0.95-i*0.01). The diversify-enable
-- is a session side effect: reset with SELECT fractal_diversify_disable(); when
-- your session is done (done below in the cleanup).
DROP TABLE IF EXISTS agents_demo_catalog;
CREATE TABLE agents_demo_catalog (id bigint, emb float8[]);
INSERT INTO agents_demo_catalog VALUES
    (10, ARRAY[0.1, 0.0, 0.0]),
    (20, ARRAY[0.0, 1.0, 0.0]),
    (30, ARRAY[0.0, 0.0, 1.0]);

\echo '=== fractal_agent_recommend_diverse (query near item 10, k=3) ==='
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'agents_demo_catalog', 'emb', ARRAY[0.12, 0.01, 0.0]::float8[], 3, 'id');

-- =============================================================================
-- Sections 9-17. Same real-output contract as the first six.
-- =============================================================================

-- 9. fractal_agent_data_analyst (horizontal NL->SQL->reason).
-- Composes fractal_sql_agent (auto_execute=true: NL->SQL->run via SPI, with a
-- subtransaction that captures execution failures into result_json) then
-- fractal_reason over the result. generated_sql is the agent's real generated
-- statement; result_json is the real executed row count (or a captured
-- execution-failure reason); analysis is the real fractal_reason read. The
-- horizontal catch-all -- no vertical demo is wired to it.
DROP TABLE IF EXISTS agents_demo_data;
CREATE TABLE agents_demo_data (id int PRIMARY KEY, category text, amount float8);
INSERT INTO agents_demo_data VALUES
    (1, 'hardware', 1200.00),
    (2, 'software',  800.50),
    (3, 'hardware',  450.25);

\echo '=== fractal_agent_data_analyst (NL: total spend per category) ==='
SELECT analysis, generated_sql, result_json
FROM fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data',
    ARRAY['agents_demo_data'], 2);

-- 10. fractal_agent_patient_deterioration_triage (medtech).
-- Composes a cohort-restricted hybrid search (fractal_hybrid_clinical_search)
-- with a baseline->current drift search (fractal_search_trajectory), then
-- reasons. cohort_doc_ids is caller-built from age>65 AND condition='sepsis'
-- -- the two-predicate cohort fractal_agent_recall_hybrid's single
-- (filter_col, filter_val) cannot express. nearest_cohort_id is the real
-- nearest patient (resolved via ctid); cohort_distance/drift_distance are
-- real; rationale is the real fractal_reason output.
DROP TABLE IF EXISTS agents_demo_patients;
CREATE TABLE agents_demo_patients (
    id int PRIMARY KEY, age int, condition text, vitals float8[]);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    ARRAY[0.90, -0.80, 0.70, 0.60]),
    (2, 64, 'sepsis',    ARRAY[0.10,  0.10, 0.10, 0.10]),
    (3, 78, 'pneumonia', ARRAY[0.20,  0.20, 0.20, 0.20]),
    (4, 81, 'sepsis',    ARRAY[0.85, -0.75, 0.65, 0.55]);

\echo '=== fractal_agent_patient_deterioration_triage (age>65 sepsis cohort) ==='
SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale
FROM fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals',
    ARRAY[0.9, -0.8, 0.7, 0.6]::float8[],
    ARRAY[0.1, 0.1, 0.1, 0.1]::float8[],
    ARRAY[0.95, -0.85, 0.75, 0.65]::float8[],
    (SELECT array_agg(doc_id ORDER BY doc_id) FROM
       (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id
          FROM agents_demo_patients
         WHERE age > 65 AND condition = 'sepsis') x),
    5, 'id');

-- 11. fractal_agent_feedback_audit (pure analytics, NO LLM).
-- A self-contained audit cycle: enables session-global repulsion, warms the
-- D_q rolling window with varied queries from a warmup table, reports
-- negative feedback on the audit target (fractal_isolate_background on the
-- k=1 telemetry doc_id -- the doc_id IS the handle), then reads back the real
-- diversity_quotient (fractal_detect_collapse, NOT NaN once the window is
-- warm) and session diagnostics (fractal_explain_result). Self-disables
-- diversify (unlike recommend_diverse, which leaves it on).
DROP TABLE IF EXISTS agents_demo_fcatalog, agents_demo_fwarmup;
CREATE TABLE agents_demo_fcatalog (id bigint PRIMARY KEY, emb float8[]);
INSERT INTO agents_demo_fcatalog
SELECT gs, ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 20) AS gs;
CREATE TABLE agents_demo_fwarmup (center float8[]);
INSERT INTO agents_demo_fwarmup
SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 8);

\echo '=== fractal_agent_feedback_audit (warmup -> isolate -> D_q) ==='
SELECT diversity_quotient, explanation
FROM fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', ARRAY[0.5, 0.5, 0.5]::float8[],
    'agents_demo_fwarmup', 'center', 8, 3);

-- 12. fractal_agent_schedule_workload (sovereign-edge).
-- Refines the task vector with fractal_search (the "sniper search" in the
-- abstract [-1,1]^dim space), finds the nearest node via
-- fractal_search_telemetry, resolves the scan position to the named node id
-- via ctid, and reasons. assigned_node is the real node id; confidence is
-- 1/(1+distance) (real); rationale is the real fractal_reason output. Like
-- route_task but with the fractal_search refinement step route_task lacks.
DROP TABLE IF EXISTS agents_demo_nodes;
CREATE TABLE agents_demo_nodes (id int PRIMARY KEY, capability float8[]);
INSERT INTO agents_demo_nodes VALUES
    (1, ARRAY[0.9, 0.1, 0.0, 0.0, 0.0]),
    (2, ARRAY[0.0, 0.0, 0.9, 0.1, 0.0]),
    (3, ARRAY[0.1, 0.0, 0.0, 0.0, 0.9]);

\echo '=== fractal_agent_schedule_workload (inference task -> nearest node) ==='
SELECT assigned_node, confidence, rationale
FROM fractal_agent_schedule_workload(
    ARRAY[0.8, 0.1, 0.0, 0.0, 0.1]::float8[],
    'agents_demo_nodes', 'capability', 'id', 30, 50, 5);

-- 13. fractal_agent_rebalance_sibling (quant-finance).
-- Runs the SFS cardinality-constrained Sharpe maximizer
-- (fractal_optimize_portfolio), extracts the weights as a float8[] vector,
-- finds the nearest historical allocation pattern via
-- fractal_search_trajectory, resolves its doc_id to the named allocation id
-- via ctid, and reasons. sharpe is the real optimizer output; weights is the
-- real jsonb; nearest_alloc_id is the real trajectory nearest; rationale is
-- the real fractal_reason output. cov is a flattened 1-D row-major 4x4.
DROP TABLE IF EXISTS agents_demo_alloc;
CREATE TABLE agents_demo_alloc (id bigint PRIMARY KEY, alloc float8[]);
INSERT INTO agents_demo_alloc VALUES
    (1, ARRAY[0.25, 0.25, 0.25, 0.25]),
    (2, ARRAY[0.40, 0.30, 0.20, 0.10]),
    (3, ARRAY[0.10, 0.20, 0.30, 0.40]);

\echo '=== fractal_agent_rebalance_sibling (4 assets, cardinality=4) ==='
SELECT sharpe, weights, nearest_alloc_id, nearest_distance, rationale
FROM fractal_agent_rebalance_sibling(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    4, 'agents_demo_alloc', 'alloc',
    ARRAY[0.25, 0.25, 0.25, 0.25]::float8[], NULL, 5, 'id');

-- 13b. fractal_agent_diverse_portfolios (enterprise tier). Companion to
-- fractal_agent_allocate (Engine B, above): same 4-asset mu/cov, but returns
-- several structurally distinct good portfolios via
-- fractal_optimize_portfolio_multimodal instead of one, plus one rationale
-- covering the tradeoffs across all of them. candidate_id/sharpe/weights are
-- real per-candidate optimizer output; rationale is the real fractal_reason
-- output. Exception-guarded (see the header note above): prints a NOTICE and
-- completes cleanly if the enterprise tier isn't loaded.
\echo '=== fractal_agent_diverse_portfolios (4 assets, cardinality=2, enterprise tier) ==='
DO $$
DECLARE
    r record;
    n int := 0;
BEGIN
    FOR r IN
        SELECT * FROM fractal_agent_diverse_portfolios(
            ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
            ARRAY[0.04, 0.0,  0.0,  0.0,
                  0.0,  0.09, 0.0,  0.0,
                  0.0,  0.0,  0.16, 0.0,
                  0.0,  0.0,  0.0,  0.25]::float8[],
            2, 6)
    LOOP
        n := n + 1;
        RAISE NOTICE 'candidate %: sharpe=%  weights=%', r.candidate_id, r.sharpe, r.weights;
        IF n = 1 THEN
            RAISE NOTICE 'rationale: %', r.rationale;
        END IF;
    END LOOP;
    IF n = 0 THEN
        RAISE NOTICE 'fractal_agent_diverse_portfolios returned no rows.';
    END IF;
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        RAISE NOTICE 'fractal_agent_diverse_portfolios: enterprise tier not loaded (dormant). To activate: stage libfractalsql-enterprise-sovereign-c.so into the container, run "ALTER SYSTEM SET fractalsql.enterprise_lib = ''<path>''; SELECT pg_reload_conf();", then re-run this demo. See demo/enterprise-qtl-audit.sql.';
END $$;

-- 14. fractal_agent_detour_classify (fleet-logistics).
-- Combines the route-deviation search (fractal_search_trajectory: current vs
-- baseline across the fleet) with the GPS trace's fractal complexity
-- (fractal_dimension_boxcount), then reasons. nearest_fleet_id is the real
-- trajectory nearest (resolved via ctid); trajectory_distance is real;
-- trace_complexity is the real box-counting dimension of the GPS trace;
-- rationale is the real fractal_reason output. Vehicle 1 has a deliberate
-- detour (its UPDATE relocates its tuple, exercising the ctid mapping).
DROP TABLE IF EXISTS agents_demo_vehicles;
CREATE TABLE agents_demo_vehicles (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_vehicles
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.05, b2+0.05, b3+0.05, b4+0.05]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
UPDATE agents_demo_vehicles
   SET current = ARRAY[(baseline::float8[])[1]-0.7, (baseline::float8[])[2]+0.6,
                       (baseline::float8[])[3]+0.5, (baseline::float8[])[4]-0.4]
 WHERE id = 1;

\echo '=== fractal_agent_detour_classify (vehicle 1 detour + GPS trace) ==='
SELECT nearest_fleet_id, trajectory_distance, trace_complexity, rationale
FROM fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current',
    (SELECT baseline::float8[] FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_vehicles WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
           FROM generate_series(1, 100) AS t
          CROSS JOIN LATERAL (VALUES (1, (random()-0.5)*0.3),
                              (2, (random()-0.5)*0.3)) AS s(ord, step)
     ) c),
    5, 'id', 2);

-- 15. fractal_agent_track_anomaly (maritime/cybersecurity).
-- Combines the track-deviation search (fractal_search_trajectory) with the
-- heading-change series' DFA exponent (fractal_dimension_dfa), then reasons.
-- nearest_fleet_id is the real trajectory nearest (resolved via ctid);
-- trajectory_distance is real; dfa_exponent is the real DFA exponent (may be
-- -1 for an insufficient window -- passed through); rationale is the real
-- fractal_reason output. Vessel 1 has a deliberate track deviation.
DROP TABLE IF EXISTS agents_demo_tracks;
CREATE TABLE agents_demo_tracks (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_tracks
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.04, b2+0.04, b3+0.04, b4+0.04]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
UPDATE agents_demo_tracks
   SET current = ARRAY[(baseline::float8[])[1]+0.6, (baseline::float8[])[2]-0.5,
                       (baseline::float8[])[3]-0.9, (baseline::float8[])[4]+0.8]
 WHERE id = 1;

\echo '=== fractal_agent_track_anomaly (vessel 1 deviation + heading DFA) ==='
SELECT nearest_fleet_id, trajectory_distance, dfa_exponent, rationale
FROM fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current',
    (SELECT baseline::float8[] FROM agents_demo_tracks WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_tracks WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t) FROM (
         SELECT t, sum(step) OVER (ORDER BY t) AS cum
           FROM (SELECT t,
                        (random()-0.5) * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35
                                               ELSE 0.03 END) AS step
                   FROM generate_series(1, 120) AS t) s
     ) c),
    5, 'id');

-- 16. fractal_agent_network_coverage_alert (smart-cities).
-- Combines the sensor grid's spatial morphology
-- (fractal_morphological_complexity -> dimension + lacunarity; needs >= ~256
-- points, so a 20x20 grid matching the smart-cities demo) with the telemetry
-- series' regime-change drift (fractal_dimension_drift), then reasons. The
-- drift field is recent_alpha - baseline_alpha (a SIGNED numeric, not a
-- boolean); drift_detected is |drift| > drift_threshold (default 0.5).
-- morph_dimension/lacunarity are real; drift_detected is a real boolean;
-- rationale is the real fractal_reason output.
\echo '=== fractal_agent_network_coverage_alert (20x20 grid + step-up drift) ==='
SELECT morph_dimension, lacunarity, drift_detected, rationale
FROM fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM (
         SELECT r*20 + c AS id, ord, v
           FROM generate_series(0, 19) AS r
          CROSS JOIN generate_series(0, 19) AS c
          CROSS JOIN LATERAL unnest(ARRAY[r + (random()-0.5)*0.3,
                                          c + (random()-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)
     ) g),
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    2, 48, 0.5);

-- 17. fractal_agent_regime_triage (general-purpose).
-- Runs fractal_dimension_dfa (long-range-correlation exponent) and
-- fractal_dimension_drift (regime-change drift + recent/baseline alphas) over
-- a single series, then reasons. The array-in shape fits any one series (no
-- per-row time/metric table, unlike anomaly_triage). drift_detected is
-- |drift| > drift_threshold (default 0.5); dfa_exponent may be -1.
-- dfa_exponent/drift_detected/recent_alpha/baseline_alpha are real; rationale
-- is the real fractal_reason output.
\echo '=== fractal_agent_regime_triage (96-pt step-up series) ==='
SELECT dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale
FROM fractal_agent_regime_triage(
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    64, 0.5);

-- 18. Closing narrative -- fractal_reason over the real computed results.
-- Same closing pattern as demo.sql and every vertical demo: one final
-- reasoning call that synthesizes a human-readable read over the real
-- analytics the cognition agents just produced.
\echo '=== Closing narrative: fractal_reason over the agent results ==='
SELECT fractal_reason(
    'Synthesize a one-paragraph ops brief across the sixteen agents: the '
    'anomaly-triage threat_score, the allocation sharpe, the route_task '
    'routed_to/confidence, the outlier_intercept decision, the patient-'
    'deterioration cohort/drift distances, the schedule_workload assignment, the '
    'rebalance sharpe/weights, the diverse-portfolios candidate sharpes, the '
    'detour/track distances and trace/DFA complexity, and the coverage/regime '
    'drift_detected flags above, and what each implies for the on-call engineer.',
    jsonb_build_object(
        'source', 'demo-agents.sql',
        'engines', ARRAY['fractal_agent_anomaly_triage',
                         'fractal_agent_allocate',
                         'fractal_agent_route_task',
                         'fractal_agent_outlier_intercept',
                         'fractal_agent_recall_hybrid',
                         'fractal_agent_recommend_diverse',
                         'fractal_agent_data_analyst',
                         'fractal_agent_patient_deterioration_triage',
                         'fractal_agent_feedback_audit',
                         'fractal_agent_schedule_workload',
                         'fractal_agent_rebalance_sibling',
                         'fractal_agent_diverse_portfolios',
                         'fractal_agent_detour_classify',
                         'fractal_agent_track_anomaly',
                         'fractal_agent_network_coverage_alert',
                         'fractal_agent_regime_triage']
    )::text
);

-- Reset the session-global diversify flag the recommend_diverse and
-- feedback_audit agents enabled (feedback_audit self-disables, but
-- belt-and-suspenders).
SELECT fractal_diversify_disable();

-- Cleanup: drop the demo tables. The agent functions are extension-owned and
-- are dropped only by `DROP EXTENSION fractalsql_agents` (see demo/README.md
-- Cleanup). Leave the tables in place to inspect the results; drop them to
-- re-run.
-- DROP TABLE agents_demo_logs, agents_demo_caps, agents_demo_badstates,
--            agents_demo_mem, agents_demo_catalog,
--            agents_demo_data, agents_demo_patients,
--            agents_demo_fcatalog, agents_demo_fwarmup,
--            agents_demo_nodes, agents_demo_alloc,
--            agents_demo_vehicles, agents_demo_tracks;