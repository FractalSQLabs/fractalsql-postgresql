-- demo/demo-vertical-sovereign-edge-ai.sql
--
-- Industry vertical: Sovereign, Edge & Autonomous Systems AI.
--
-- FractalSQL's whole story fits this vertical natively: search,
-- reasoning, and optimization all run as pure C inside the same
-- Postgres process -- no external vector-DB service, no cloud API call
-- required for search/optimization, and even fractal_reason() can point
-- at a fully local model (see ../docs/reasoning-setup.md's air-gapped
-- guidance) for environments where a network call out is unacceptable.
-- This script: a fleet of 50 edge-compute nodes, finding the best node
-- for a workload (Sniper), a diverse representative sample of the fleet
-- (Scout), and fractal_optimize_portfolio repurposed as a general
-- on-device black-box resource allocator (its own doc comment already
-- frames it as a generic cardinality-constrained optimizer, not
-- finance-specific).
--
-- Prerequisites: extension installed (sections 0-5 need nothing else).
-- Section 6 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-sovereign-edge-ai.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-sovereign-edge-ai.sql
--
-- Safe to re-run: vse_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.55);

\echo '=== 0. Sanity check: extension + edition loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 50 edge-compute nodes with a 5-dim resource-capability vector:
-- [cpu_free, mem_free, gpu_avail, net_headroom, battery] each roughly
-- normalized to [-1,1] (1 = plenty of headroom).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 50 edge-compute nodes: resource-capability vectors ==='

DROP TABLE IF EXISTS vse_nodes;
-- fractal_vector(5), not float8[] -- no fractal_search_trajectory/
-- fractal_cross_modal_search calls in this vertical to exercise a new
-- overload, but a malformed capability report from an edge node is a
-- real operational failure mode this type catches at write time;
-- fractal_search_telemetry/fractal_search_explore below already read
-- either column type transparently (spi_scan_corpus dispatch).
CREATE TABLE vse_nodes (id serial PRIMARY KEY, node_name text, capability fractal_vector(5));
INSERT INTO vse_nodes (node_name, capability)
SELECT 'edge-node-' || gs,
       ARRAY[random()*2-1, random()*2-1, random()*2-1, random()*2-1, random()*2-1]::float8[]
FROM generate_series(1, 50) gs;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount over the physical facility layout: a
-- 20x20 grid of candidate rack positions with small placement jitter --
-- a spatial-complexity signal for constrained-compute monitoring, the
-- spatial sibling of DFA's own time-series complexity signal. Needs
-- enough SPACE-FILLING points for the internal box-counting estimator
-- to find >= 3 valid eps-octaves (same validity filter as
-- demo/demo-vertical-medtech-clinical.sql's vessel/nerve fixtures) -- a
-- sparse or purely random scatter (like the 50-node capability table
-- above) is too sparse for this filter, a physical grid isn't.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_dimension_boxcount: facility deployment-grid density ==='
\echo '(dimension near 2.0 means the deployment fills the available floor'
\echo 'space; a lower number would flag a sparse or corner-clustered rollout)'

SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r
       CROSS JOIN generate_series(0, 19) c
       CROSS JOIN LATERAL unnest(
           ARRAY[r + (random() - 0.5) * 0.3, c + (random() - 0.5) * 0.3]
       ) WITH ORDINALITY AS u(v, ord)),
    2
) AS deployment_grid_dimension;

-- ------------------------------------------------------------------
-- 3. Sniper Search: converge toward the ideal node profile for a
-- GPU-heavy inference workload (high GPU, high mem, moderate CPU).
-- fractal_search_telemetry then maps that ideal profile to a REAL node
-- to actually schedule onto.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Sniper Search: ideal node profile for a GPU-inference workload ==='

-- Blueprint (raw primitives): converge toward the ideal node profile with
-- fractal_search (the "sniper search" in the abstract [-1,1]^5 space), then
-- map that profile to a REAL node with fractal_search_telemetry. Generalized
-- below by the shipped fractal_agent_schedule_workload preset, which folds
-- both steps together and reasons (and resolves the nearest node via ctid,
-- avoiding the raw form's doc_id+1 shortcut that only holds for an
-- never-UPDATEd table).
-- SELECT fractal_search(ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], iterations => 50) AS ideal_profile;
--
-- SELECT n.node_name, t.distance
-- FROM fractal_search_telemetry('vse_nodes', 'capability',
--                               ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], 3) t
-- JOIN vse_nodes n ON n.id = t.doc_id + 1
-- ORDER BY t.distance;

-- Productized preset: the shipped engine refines the task vector
-- (fractal_search), finds the nearest node (fractal_search_telemetry),
-- resolves its scan position to the real node id via ctid, and reasons.
-- assigned_node is the real node id; confidence is 1/(1+distance).
\echo '--- Preset: fractal_agent_schedule_workload (raw search+telemetry form preserved above) ---'
SELECT assigned_node, confidence, rationale
FROM fractal_agent_schedule_workload(
    ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[],
    'vse_nodes', 'capability', 'id', 50, 50, 5, '{}'::text);

-- ------------------------------------------------------------------
-- 4. Scout Discovery: a diverse representative sample of the fleet's
-- distinct capability profiles -- useful for capacity planning ("what
-- KINDS of nodes do we actually have") without scanning all 50 by hand.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Scout Discovery: diverse fleet capability profiles ==='
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's distinct capability-profile embeddings.
-- SELECT p FROM fractal_search_explore(
--     'vse_nodes', 'capability', ARRAY[0,0,0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real node ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session (the engine leaves diversify on -- the caller owns
-- that policy) so the section-5 allocator below is unaffected. The blueprint's
-- zero query is query-agnostic (explore samples the space); recommend_diverse
-- is query-anchored, so anchor on the first node's own capability vector.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vse_nodes', 'capability',
    (SELECT capability::float8[] FROM vse_nodes ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. fractal_optimize_portfolio as a general on-device black-box
-- resource allocator: which 6 of these 50 nodes should a distributed
-- job land on, maximizing an "efficiency Sharpe" over expected
-- throughput (mu) vs. contention risk (cov, higher between nodes on
-- the same rack/subnet)? Cardinality-constrained, NP-hard in general --
-- exactly the ruggedness class this SFS-backed optimizer targets (see
-- that function's own doc comment).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. fractal_optimize_portfolio: pick 6-of-50 nodes for a distributed job ==='

DROP TABLE IF EXISTS vse_throughput;
CREATE TABLE vse_throughput (node_id int PRIMARY KEY, expected_throughput float8, rack int);
INSERT INTO vse_throughput (node_id, expected_throughput, rack)
SELECT id, 0.4 + random() * 0.6, ((id - 1) / 10) FROM vse_nodes;

DROP TABLE IF EXISTS vse_contention_flat;
CREATE TEMP TABLE vse_contention_flat AS
SELECT a.node_id AS i, b.node_id AS j,
       CASE WHEN a.node_id = b.node_id THEN 0.05
            WHEN a.rack = b.rack THEN 0.06
            ELSE 0.005 END AS c_ij
FROM vse_throughput a
CROSS JOIN vse_throughput b;

-- Blueprint (raw primitive): the SFS cardinality-constrained Sharpe
-- maximizer over expected-throughput (mu) vs. contention risk (cov).
-- SELECT fractal_optimize_portfolio(
--     (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
--     (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
--     6, 7
-- ) AS allocation;

-- Productized preset: the shipped engine runs the optimizer and reasons a
-- placement rationale over its {sharpe, weights} output. (The engine does
-- not expose the raw primitive's seed arg -- the allocation is still real,
-- just not seeded to 7.)
\echo '--- Preset: fractal_agent_allocate (raw optimizer form preserved above) ---'
SELECT allocation, sharpe, rationale
FROM fractal_agent_allocate(
    (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
    (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
    6,
    '{"job": "distributed-inference", "vertical": "sovereign-edge"}'::text
);

-- ------------------------------------------------------------------
-- 5. Reasoning: narrate the placement decision. Runs against whatever
-- endpoint fractalsql.http_url points at -- a fully local model on a
-- LAN-only host demonstrates the air-gapped-capable story this
-- vertical cares about (see ../docs/reasoning-setup.md).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. Reasoning over the placement decision ==='

-- The section-5 preset (fractal_agent_allocate) already produces this
-- placement rationale as its `rationale` output column -- it runs the same
-- fractal_reason call over the same optimizer output this standalone
-- section used to. The raw form is preserved below as the blueprint it
-- generalizes:
-- SELECT fractal_reason(
--     'given this cardinality-constrained node allocation (sharpe + weights per node), explain the placement decision and any risk from rack co-location',
--     jsonb_build_object(
--         'allocation', (SELECT fractal_optimize_portfolio(
--             (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
--             (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
--             6, 7
--         ))
--     )::text
-- );
\echo '(rationale now produced by fractal_agent_allocate above -- see its rationale column)'

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vse_nodes, vse_throughput;'
