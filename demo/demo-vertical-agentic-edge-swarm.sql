-- demo/demo-vertical-agentic-edge-swarm.sql
--
-- Industry vertical: Agentic Edge / Robotics Swarm Coordination.
--
-- Three independent showcases against a battery- and bandwidth-
-- constrained edge swarm:
--
--   1. Vector quantization (int8 + binary) for compressed swarm memory
--      -- each edge node has tight RAM/radio-bandwidth budgets, so
--      storing/transmitting full float8 state embeddings for every
--      peer isn't free; binary quantization + Hamming pre-filtering is
--      the standard cheap-candidate-then-rerank pattern.
--   2. fractal_agent_detect_loop ("cognitive wobble" detection) -- one
--      agent stuck oscillating between two headings (a real, common
--      edge-robotics failure mode: a local-minimum trap in a reactive
--      controller) vs. one genuinely exploring; the SAME preset Phase 2
--      of this session rewired onto SimHash state-fingerprinting +
--      Brent's cycle detection, exercised here on its actual use case.
--   3. fractal_optimize_subset's value-weighted allocation for
--      battery-constrained task routing -- pick the best k tasks by
--      priority value, each bounded by its own battery-budget share.
--
-- Prerequisites: extension installed. No reasoning step in this file.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-agentic-edge-swarm.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-agentic-edge-swarm.sql
--
-- Safe to re-run: vae_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.37);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 20 edge-swarm nodes, each with a 16-dim compressed state-summary
-- embedding (heading, battery, sensor-cluster activations, etc.,
-- normalized). int8 quantization (4x) for on-device storage of peer
-- state; binary quantization (32x) + Hamming distance for a cheap
-- first-pass candidate filter ahead of a full-precision re-rank --
-- exactly the pairing documented on fractal_vector_hamming_distance
-- itself. No published-algorithm citation for quantization: general
-- "compress, then Hamming/popcount filter" pattern, per this repo's
-- own THIRD-PARTY-NOTICES.md.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Vector quantization: compressed swarm-node memory ==='

DROP TABLE IF EXISTS vae_nodes;
CREATE TABLE vae_nodes (
    id    serial PRIMARY KEY,
    -- fractal_vector(16), not float8[] -- fixed-width state summary,
    -- same dimension-safety argument as this repo's other
    -- fractal_vector verticals.
    state fractal_vector(16)
);

-- Flat CROSS JOIN, not ARRAY(uncorrelated subquery) -- an uncorrelated
-- subquery body (one that never references the outer generate_series(1,20)
-- row) gets hoisted into a one-shot InitPlan and evaluated ONCE for the
-- whole INSERT, silently making every node's state identical despite
-- random() being volatile. Same trap demo-vertical-quant-finance.sql's
-- own comment documents; a flat cross join has no nested subquery to
-- hoist, so every (node, dim) pair gets its own random() call, provably.
INSERT INTO vae_nodes (id, state)
SELECT gs, array_agg(random() * 2 - 1 ORDER BY dim)::float8[]
FROM generate_series(1, 20) gs
CROSS JOIN generate_series(1, 16) dim
GROUP BY gs;

\echo '(raw primitives -- no preset wraps these functions yet)'
DROP TABLE IF EXISTS vae_quantized;
CREATE TEMP TABLE vae_quantized AS
SELECT id,
       (fractal_vector_quantize_int8(state)).codes    AS int8_codes,
       (fractal_vector_quantize_int8(state)).scale     AS int8_scale,
       fractal_vector_quantize_binary(state)           AS binary_code
FROM vae_nodes;

SELECT id, octet_length(int8_codes) AS int8_bytes, round(int8_scale::numeric, 4) AS scale,
       octet_length(binary_code) AS binary_bytes
FROM vae_quantized
ORDER BY id
LIMIT 5;

\echo '(cheap Hamming pre-filter: nearest peers to node 1 by quantized-binary distance)'
SELECT b.id, fractal_vector_hamming_distance(a.binary_code, b.binary_code) AS hamming_dist
FROM vae_quantized a, vae_quantized b
WHERE a.id = 1 AND b.id != 1
ORDER BY hamming_dist ASC
LIMIT 5;

-- ------------------------------------------------------------------
-- 2. fractal_agent_detect_loop: two agents' recent state trajectories.
-- state-fingerprint is cosine/direction-based, so magnitude alone
-- carries no signal, and this kernel has real, non-obvious
-- false-positive modes confirmed empirically while building this demo
-- -- worth documenting plainly rather than papering over with a
-- cherry-picked seed:
--   * A fixed angular step (even with noise) revisits similar
--     directions every ~2*pi/step_size samples -- a real periodicity,
--     correctly flagged.
--   * A genuine, non-periodic UNBOUNDED random walk still gets flagged
--     spuriously: its per-step L2 norm trends steadily upward (a
--     random walk's magnitude grows roughly like sqrt(t)), and the
--     kernel's secondary DFA signal reads that steady growth as high
--     persistence (alpha > 0.9) regardless of the cycle-detect result.
--   * A low state dimension (3, matching the "compressed swarm memory"
--     framing elsewhere in this file) also has a real, separate
--     collision mode: with few true directional degrees of freedom,
--     the SimHash fingerprint's random hyperplane arrangement can
--     alias two genuinely different directions to the identical
--     64-bit fingerprint over as few as 24 samples, which Brent's
--     cycle detection (correctly, per its own contract) reports as a
--     repeat -- confirmed directly against this fixture by printing
--     the raw fingerprints and finding an exact collision between two
--     non-adjacent, non-similar samples.
-- The explorer trajectory below sidesteps all three: bounded per-
-- dimension (no magnitude drift -> no false DFA persistence), a wider
-- 8-dim state (more directional resolution -> far lower incidental
-- collision odds), and deterministic multi-frequency sinusoids with
-- pairwise-incommensurate (irrational-ratio) frequencies rather than
-- random() -- guarantees no exact periodicity within any finite window
-- and, unlike a random walk, is reproducible independent of where in
-- this script's random() call sequence it happens to run. Agent
-- bot-stuck below, by contrast, oscillates between two fixed headings
-- -- an exact period-2 cycle, the textbook "cognitive wobble" trap
-- this preset is built to catch.
--
-- Citations: SimHash state-fingerprint -- Charikar, M. S. (2002),
-- "Similarity estimation techniques from rounding algorithms," STOC.
-- Brent's cycle detection -- Brent, R. P. (1980), "An improved Monte
-- Carlo factorization algorithm," BIT Numerical Mathematics.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_agent_detect_loop: cognitive-wobble detection ==='
\echo '--- Preset: fractal_agent_detect_loop ---'

WITH explorer_walk(t, d1, d2, d3, d4, d5, d6, d7, d8) AS (
    SELECT t,
           sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
           sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
           sin(t * 3.87298335), sin(t * 4.12310563)
    FROM generate_series(1, 24) t
)
SELECT agent_id, is_loop_detected, dfa_exponent
FROM fractal_agent_detect_loop(
    'bot-explorer',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM explorer_walk
       CROSS JOIN LATERAL unnest(ARRAY[d1, d2, d3, d4, d5, d6, d7, d8]) WITH ORDINALITY AS u(v, ord)),
    8
);

SELECT agent_id, is_loop_detected, dfa_exponent
FROM fractal_agent_detect_loop(
    'bot-stuck',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM generate_series(1, 24) t
       CROSS JOIN LATERAL unnest(
           CASE WHEN t % 2 = 0 THEN ARRAY[1.0, 0.0, 0.0]
                ELSE                 ARRAY[0.0, 1.0, 0.0] END
       ) WITH ORDINALITY AS u(v, ord)),
    3
);

-- ------------------------------------------------------------------
-- 3. fractal_optimize_subset: 15 candidate tasks queued at an edge
-- coordinator, each with a priority VALUE and an upper-bound share of
-- the swarm's remaining shared battery budget it may consume if
-- selected. Pick the best k=5 tasks maximizing total value under that
-- per-task cap and the cardinality constraint -- the "which k tasks
-- are worth routing to the swarm right now" decision. Original work
-- (this SQL entry point's hardcoded objective, per Phase 3's own
-- THIRD-PARTY-NOTICES.md note) -- no citation.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_optimize_subset: battery-constrained task routing (best 5 of 15) ==='

DROP TABLE IF EXISTS vae_tasks;
CREATE TABLE vae_tasks (
    id            serial PRIMARY KEY,
    task_name     text,
    priority      float8,
    battery_share float8
);

-- battery_share range chosen so the top-5 upper bounds comfortably sum
-- past 1.0 -- fractal_optimize_subset requires the k largest
-- upper_bounds to sum to >= 1.0 or no feasible k-subset exists (see
-- its own COMMENT ON FUNCTION).
INSERT INTO vae_tasks (task_name, priority, battery_share)
SELECT 'task-' || gs, round((random() * 9 + 1)::numeric, 2)::float8, round((0.15 + random() * 0.2)::numeric, 3)::float8
FROM generate_series(1, 15) gs;

\echo '(raw primitive -- no preset wraps this function yet)'
DROP TABLE IF EXISTS vae_route_result;
CREATE TEMP TABLE vae_route_result AS
SELECT fractal_optimize_subset(
    (SELECT array_agg(priority ORDER BY id) FROM vae_tasks),
    (SELECT array_agg(battery_share ORDER BY id) FROM vae_tasks),
    5, NULL, 0.0, 99
) AS result;

SELECT result -> 'score' AS total_value_captured FROM vae_route_result;
SELECT t.task_name, t.priority, t.battery_share, w.weight
FROM vae_route_result r
CROSS JOIN LATERAL jsonb_array_elements_text(r.result -> 'weights') WITH ORDINALITY AS w(weight, ord)
JOIN vae_tasks t ON t.id = w.ord
WHERE w.weight::float8 > 1e-9
ORDER BY w.weight::float8 DESC;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vae_nodes, vae_tasks;'
