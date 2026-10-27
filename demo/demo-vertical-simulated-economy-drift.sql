-- demo/demo-vertical-simulated-economy-drift.sql
--
-- Industry vertical: Simulated-economy balancing: market inflation loops
-- and automated-actor detection. AGENTIC kit: Six markets x 96 days of
-- price index; every market carries a weekly demand cycle, and one (mkt-d)
-- enters an accelerating inflation spiral. `fractal_periodogram` confirms
-- the weekly cycle, `fractal_dimension_dfa` flags the market that is
-- inflating non-linearly, and `fractal_optimize_portfolio` picks the 3
-- markets for the scheduled sink program (the inflating market goes to an
-- emergency price-cap instead). `fractal_agent_detect_loop` then watches
-- trade-state logs: an automated actor that flips between the same two item
-- states is detected while a varied actor is not.
--
--   1. fractal_periodogram: the dominant period of each market (a 7-day
--      weekly cycle is expected).
--   2. fractal_dimension_dfa: the market whose price index is accelerating.
--   3. fractal_optimize_portfolio (SFS): 3-of-6 sink program, risk =
--      variance x DFA exponent.
--   4. fractal_agent_detect_loop: SimHash + Brent cycle detection on trade-
--      state logs, automated vs varied actor.
--   5. A closing fractal_reason() writes the balance note.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-simulated-economy-drift.sql
--
-- Safe to re-run: sed_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The trade-state logs follow the edge-swarm kit's fixtures: a
--     3-component state flipping between two directions (the automated
--     actor) against an 8-component varied walk.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Six markets x 96 days of price index ==='
DROP TABLE IF EXISTS sed_price;
CREATE TABLE sed_price (
    ent text,
    seq int,
    val float8
);
INSERT INTO sed_price (ent, seq, val)
SELECT ent, g, base * (1.0 + p1 * sin(2 * pi() * g / 7.0) + 0.004 * (g % 5)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM (VALUES ('mkt-a', 100, 0.12, 0),
             ('mkt-b', 80, 0.15, 0),
             ('mkt-c', 140, 0.1, 0),
             ('mkt-d', 120, 0.14, 0.0024),
             ('mkt-e', 90, 0.12, 0),
             ('mkt-f', 200, 0.08, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 96) AS g;

\echo ''
\echo '=== 2. Weekly cycle and non-linearity per market ==='
DROP TABLE IF EXISTS sed_prof;
CREATE TABLE sed_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, (SELECT freq FROM fractal_periodogram(a.arr, 1) LIMIT 1) AS freq
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM sed_price GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM sed_price GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((dfa_alpha)::numeric, 3) AS dfa_alpha, round((freq)::numeric, 4) AS top_freq, round((1.0 / freq)::numeric, 1) AS samples_per_cycle
  FROM sed_prof ORDER BY ent;

\echo ''
\echo '=== 3. fractal_optimize_portfolio: pick 3 markets for the sink program ==='
DROP TABLE IF EXISTS sed_result;
CREATE TABLE sed_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(round((p.mean_v / 100.0)::numeric, 4)::float8 ORDER BY p.pid) FROM sed_prof p),
    (SELECT array_agg(CASE WHEN a.pid = b.pid THEN round((a.var_v * a.dfa_alpha / 100.0)::numeric, 4)::float8 ELSE 0::float8 END
                      ORDER BY a.pid, b.pid)
       FROM sed_prof a CROSS JOIN sed_prof b),
    3, 42) AS rj;

SELECT round((rj->>'sharpe')::numeric, 4) AS sharpe FROM sed_result;

\echo '--- the chosen entries (weight > 0; weights are in ent order) ---'
SELECT p.ent, round(w.weight_text::numeric, 4) AS weight
FROM sed_result r
CROSS JOIN LATERAL jsonb_array_elements_text(r.rj->'weights') WITH ORDINALITY AS w(weight_text, ord)
JOIN sed_prof p ON p.pid = w.ord
WHERE w.weight_text::float8 > 0
ORDER BY w.weight_text::float8 DESC;
\echo '--- markets flagged for an emergency price cap (DFA exponent > 1.2) ---'
SELECT ent, round((dfa_alpha)::numeric, 3) AS dfa_alpha
  FROM sed_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;

\echo ''
\echo '=== 4. fractal_agent_detect_loop: automated actor vs varied actor ==='
DROP TABLE IF EXISTS sed_loop;
CREATE TABLE sed_loop AS
WITH walk(t, d1, d2, d3, d4, d5, d6, d7, d8) AS (
    SELECT t,
           sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
           sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
           sin(t * 3.87298335), sin(t * 4.12310563)
    FROM generate_series(1, 24) t
)
SELECT agent_id, is_loop_detected::int AS is_loop, dfa_exponent
FROM fractal_agent_detect_loop(
    'varied-actor',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM walk
       CROSS JOIN LATERAL unnest(ARRAY[d1, d2, d3, d4, d5, d6, d7, d8]) WITH ORDINALITY AS u(v, ord)),
    8)
UNION ALL
SELECT agent_id, is_loop_detected::int, dfa_exponent
FROM fractal_agent_detect_loop(
    'auto-actor',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM generate_series(1, 24) t
       CROSS JOIN LATERAL unnest(
           CASE WHEN t % 2 = 0 THEN ARRAY[1.0, 0.0, 0.0]
                ELSE                 ARRAY[0.0, 1.0, 0.0] END
       ) WITH ORDINALITY AS u(v, ord)),
    3);

SELECT agent_id, is_loop, dfa_exponent FROM sed_loop ORDER BY agent_id;

\echo ''
\echo '=== 5. Reasoning: balance note ==='
SELECT fractal_reason(
    'one-line balance note: the inflating market, the sink program, and the actor to block',
    json_build_object('inflating_market', (SELECT ent FROM sed_prof ORDER BY dfa_alpha DESC LIMIT 1), 'bot_loops', (SELECT count(*) FROM sed_loop WHERE is_loop = 1))::text) AS narrative;

\echo ''
\echo '=== 6. Headline check ==='
SELECT 'HEADLINE kit=simulated-economy-drift ' || CASE WHEN (SELECT dfa_alpha FROM sed_prof WHERE ent = 'mkt-d') > 1.2 AND (SELECT count(*) FROM sed_prof WHERE dfa_alpha > 1.2) = 1 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') > 0.13 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') < 0.16 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'auto-actor') = 1 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'varied-actor') = 0 THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE sed_price, sed_prof, sed_result, sed_loop;'
