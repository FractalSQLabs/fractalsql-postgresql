-- demo/demo-vertical-multi-series-replenishment.sql
--
-- Industry vertical: Multi-location replenishment: stockout prevention and
-- non-linear demand forecasting. AGENTIC kit: Six locations x 64 days of
-- unit demand. `fractal_dimension_dfa` finds the location whose demand is
-- accelerating (a viral item or a local event) rather than merely high;
-- `fractal_optimize_portfolio` picks which 3 locations get the scheduled
-- replenishment from the central hub with the risk matrix inflated by the
-- DFA exponent; the surging location is flagged for an expedited pick
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step.
--
--   1. fractal_dimension_dfa over each location's daily units: non-linear
--      vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled replenishment,
--      risk = variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the redistribution rationale.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-multi-series-replenishment.sql
--
-- Safe to re-run: msr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily units per unit of stock moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Six locations x 64 days of unit demand ==='
DROP TABLE IF EXISTS msr_units;
CREATE TABLE msr_units (
    ent text,
    seq int,
    val float8
);
INSERT INTO msr_units (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.10 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM (VALUES ('loc-a', 130, 1, 0),
             ('loc-b', 105, 2, 0),
             ('loc-c', 150, 3, 0),
             ('loc-d', 115, 4, 0.4),
             ('loc-e', 170, 5, 0),
             ('loc-f', 90, 6, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 64) AS g;

\echo ''
\echo '=== 2. DFA exponent of each location ==='
DROP TABLE IF EXISTS msr_prof;
CREATE TABLE msr_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM msr_units GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM msr_units GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((dfa_alpha)::numeric, 3) AS dfa_alpha
  FROM msr_prof ORDER BY ent;

\echo ''
\echo '=== 3. fractal_optimize_portfolio: pick 3 locations ==='
DROP TABLE IF EXISTS msr_result;
CREATE TABLE msr_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(round((p.mean_v / 100.0)::numeric, 4)::float8 ORDER BY p.pid) FROM msr_prof p),
    (SELECT array_agg(CASE WHEN a.pid = b.pid THEN round((a.var_v * a.dfa_alpha / 100.0)::numeric, 4)::float8 ELSE 0::float8 END
                      ORDER BY a.pid, b.pid)
       FROM msr_prof a CROSS JOIN msr_prof b),
    3, 42) AS rj;

SELECT round((rj->>'sharpe')::numeric, 4) AS sharpe FROM msr_result;

\echo '--- the chosen entries (weight > 0; weights are in ent order) ---'
SELECT p.ent, round(w.weight_text::numeric, 4) AS weight
FROM msr_result r
CROSS JOIN LATERAL jsonb_array_elements_text(r.rj->'weights') WITH ORDINALITY AS w(weight_text, ord)
JOIN msr_prof p ON p.pid = w.ord
WHERE w.weight_text::float8 > 0
ORDER BY w.weight_text::float8 DESC;
\echo '--- locations flagged for an expedited pick (DFA exponent > 1.2) ---'
SELECT ent, round((dfa_alpha)::numeric, 3) AS dfa_alpha
  FROM msr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
\echo '--- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---'
SELECT allocation, sharpe, rationale
FROM fractal_agent_allocate(
    (SELECT array_agg(round((p.mean_v / 100.0)::numeric, 4)::float8 ORDER BY p.pid) FROM msr_prof p),
    (SELECT array_agg(CASE WHEN a.pid = b.pid THEN round((a.var_v * a.dfa_alpha / 100.0)::numeric, 4)::float8 ELSE 0::float8 END
                      ORDER BY a.pid, b.pid)
       FROM msr_prof a CROSS JOIN msr_prof b),
    3, '{"portfolio": "multi-location-replenishment"}');

\echo ''
\echo '=== 4. Reasoning: redistribution rationale ==='
SELECT fractal_reason(
    'one-line redistribution rationale: which locations get scheduled stock and which needs an expedited pick',
    json_build_object('surging_location', (SELECT ent FROM msr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM msr_prof))::text) AS narrative;

\echo ''
\echo '=== 5. Headline check ==='
SELECT 'HEADLINE kit=multi-series-replenishment ' || CASE WHEN (SELECT dfa_alpha FROM msr_prof WHERE ent = 'loc-d') > 1.2 AND (SELECT count(*) FROM msr_prof WHERE dfa_alpha > 1.2) = 1 THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE msr_units, msr_prof, msr_result;'
