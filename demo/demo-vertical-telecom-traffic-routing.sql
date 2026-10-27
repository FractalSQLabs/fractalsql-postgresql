-- demo/demo-vertical-telecom-traffic-routing.sql
--
-- Industry vertical: telecom -- dynamic traffic and bandwidth dispatch to
-- the best-capable network node under a capacity budget.  DOMAIN kit
-- built on one installed agent, fractal_agent_route_task, reused
-- verbatim: it matches each incoming request to the best-capable node
-- under a token budget, exactly its designed contract.
--
-- Scope note: this is nearest-capable-node dispatch, not multi-hop
-- rerouting around a failed node (graph routing is a different problem).
-- Load awareness comes from routing over a table of only the nodes that
-- still have headroom.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed routing needs no model; the
-- shipped agent returns a reasoned rationale (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-telecom-traffic-routing.sql
--
-- Safe to re-run: ttr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Vectors are [bandwidth, latency_sensitivity, loss_tolerance,
--     region_affinity] as float8[].  A request vector says what the
--     session needs; a node vector says what the node is good at.
--   * The agent reads a table by name, so the available-nodes set is
--     materialized into a TEMP table each time it changes.
--   * fractal_search_telemetry returns the row's ctid as doc_id.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Network nodes (capability vector + current load) and five
-- incoming session requests.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Nodes and incoming requests ==='

DROP TABLE IF EXISTS ttr_nodes;
CREATE TABLE ttr_nodes (
    id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    node      text,
    capacity  int,        -- sessions
    node_load int,        -- sessions now
    caps      float8[] NOT NULL CHECK (array_length(caps, 1) = 4)
);
INSERT INTO ttr_nodes (node, capacity, node_load, caps) VALUES
    ('edge-core-east',   400, 120, ARRAY[0.95, 0.20, 0.10, 0.90]),   -- bulk bandwidth, east region
    ('edge-lowlat-west', 150,  60, ARRAY[0.30, 0.95, 0.15, 0.10]),   -- low latency, west region
    ('edge-mobile-hub',  250, 200, ARRAY[0.50, 0.50, 0.85, 0.50]),   -- loss-tolerant mobile traffic
    ('edge-backup-west', 200,  20, ARRAY[0.55, 0.55, 0.40, 0.15]);   -- general purpose, west

DROP TABLE IF EXISTS ttr_requests;
CREATE TABLE ttr_requests (
    id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label text,
    need  float8[] NOT NULL CHECK (array_length(need, 1) = 4)
);
INSERT INTO ttr_requests (label, need) VALUES
    ('R1 bulk video backhaul, east',     ARRAY[0.90, 0.15, 0.10, 0.85]),
    ('R2 cloud-gaming session, west',    ARRAY[0.35, 0.92, 0.12, 0.12]),
    ('R3 mobile handover burst',         ARRAY[0.45, 0.50, 0.88, 0.45]),
    ('R4 enterprise VPN, west',          ARRAY[0.50, 0.60, 0.30, 0.12]),
    ('R5 software update fan-out, east', ARRAY[0.92, 0.10, 0.20, 0.88]);

SELECT node, capacity, node_load, round(100.0 * node_load / capacity) AS pct_loaded FROM ttr_nodes;

-- ------------------------------------------------------------------
-- 2. Hand-composed dispatch: nearest node by capability, per request.
-- confidence = 1/(1+distance).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Hand-composed dispatch: nearest capable node per request ==='

SELECT r.label, n.node AS routed_to,
       round((1.0 / (1.0 + t.distance))::numeric, 4) AS confidence
FROM ttr_requests r
CROSS JOIN LATERAL fractal_search_telemetry('ttr_nodes', 'caps', r.need, 1) t
JOIN ttr_nodes n ON n.ctid::text = t.doc_id
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent, one call per request, under a 1000-token budget
-- (reasoning plugin for the rationale).  remaining_budget shows each
-- routing decision's cost.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_agent_route_task (budget 1000) ==='

SELECT r.label, a.routed_to, a.confidence, a.remaining_budget, a.rationale
FROM ttr_requests r
CROSS JOIN LATERAL fractal_agent_route_task(r.need, 'ttr_nodes', 'caps', 'node', 1000) a
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 4. Load awareness: edge-mobile-hub is at 80% load.  Route over only
-- the nodes with headroom (below 75% loaded) and R3 is re-homed.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Route over nodes with headroom (< 75% loaded) ==='

DROP TABLE IF EXISTS ttr_available;
CREATE TEMP TABLE ttr_available AS
SELECT node, caps FROM ttr_nodes WHERE 100.0 * node_load / capacity < 75 ORDER BY id;

SELECT r.label, a.routed_to
FROM ttr_requests r
CROSS JOIN LATERAL fractal_agent_route_task(r.need, 'ttr_available', 'caps', 'node', 1000) a
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch summary (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: dispatch summary ==='

SELECT fractal_reason(
    'one-line summary of how these session requests were dispatched and why one was re-homed',
    (SELECT string_agg(r.label || ' -> ' || a.routed_to, '; ' ORDER BY r.id)
       FROM ttr_requests r
       CROSS JOIN LATERAL fractal_agent_route_task(r.need, 'ttr_available', 'caps', 'node', 1000) a)) AS summary;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE ttr_nodes, ttr_requests;'
\echo '(the ttr_available TEMP table evaporates with the session.)'
