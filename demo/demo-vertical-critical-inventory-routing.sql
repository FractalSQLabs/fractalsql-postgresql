-- demo/demo-vertical-critical-inventory-routing.sql
--
-- Industry vertical: critical-consumables inventory and replenishment
-- across a distributed depot network (medical / cold-chain stock, retail
-- high-turnover SKUs, industrial spare-parts consumables).  AGENTIC kit:
-- a hand-composed chain, then the shipped agent doing the allocation
-- step in one call.
--
--   1. fractal_dimension_dfa over each depot's daily-consumption series
--      -- identifies depots whose demand is NON-LINEAR (bursty, runaway)
--      rather than merely high.
--   2. fractal_optimize_portfolio (SFS) -- chooses which depots get the
--      scheduled replenishment run under a cardinality constraint, with
--      the risk matrix inflated for the bursty depots.  Bursty depots
--      fall out of the risk-adjusted run and are flagged from Step 1 for
--      expedited restock instead.
--   3. A closing fractal_reason() gives the rebalancing rationale.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  Sections 1-3's hand-composed steps need no model;
-- the shipped fractal_agent_allocate call and the closing rationale are
-- reasoning-bearing (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-critical-inventory-routing.sql
--
-- Safe to re-run: cir_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the expected
--     need served per unit of stock moved, the matrix is the demand risk.
--     Here risk_i = demand variance x DFA exponent, so a depot whose
--     demand is accelerating costs more risk than a steady one of the
--     same volume.
--   * fractal_agent_allocate is the shipped composition of the optimizer
--     plus a reasoned rationale; a purpose-built productized form of this
--     whole recipe is a separate roadmap item, so this kit composes the
--     steps by hand exactly as the other agentic kits do before their
--     agent function lands.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Six regional depots, 64 days of consumption each.  D1-D3 and D5-D6
-- are steady (a weekly cycle on a base level).  D4 starts accelerating
-- on day 41 -- the non-linear spike a plain average would hide.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Six depots x 64 days of consumption ==='

DROP TABLE IF EXISTS cir_depots CASCADE;
CREATE TABLE cir_depots (
    id     int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region text,
    base   float8
);
INSERT INTO cir_depots (region, base) VALUES
    ('north', 120), ('south', 95), ('east', 140),
    ('west', 110), ('central', 160), ('coastal', 85);

DROP TABLE IF EXISTS cir_consumption;
CREATE TABLE cir_consumption (
    depot_id int,
    day      int,
    units    float8
);
INSERT INTO cir_consumption (depot_id, day, units)
SELECT p.id, d,
       p.base * (1.0 + 0.06 * ((d + p.id) % 7) / 7.0)
         + CASE WHEN p.id = 4 AND d > 40 THEN 0.45 * (d - 40) * (d - 40) ELSE 0 END
FROM cir_depots p, generate_series(1, 64) AS d;

-- ------------------------------------------------------------------
-- 2. Step 1: DFA exponent, mean and variance per depot.  D4's exponent
-- stands well above the steady depots even though its average moves
-- less than D5's raw volume.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Step 1: DFA exponent of each depot''s consumption ==='

DROP TABLE IF EXISTS cir_profile;
CREATE TABLE cir_profile AS
SELECT d.id AS depot_id, d.region,
       round(avg(c.units)::numeric, 2)::float8 AS mean_units,
       round((avg(c.units * c.units) - avg(c.units) * avg(c.units))::numeric, 2)::float8 AS var_units,
       fractal_dimension_dfa(array_agg(round(c.units::numeric, 3)::float8 ORDER BY c.day)) AS dfa_alpha
  FROM cir_depots d JOIN cir_consumption c ON c.depot_id = d.id
 GROUP BY d.id, d.region
 ORDER BY d.id;

SELECT depot_id, region, mean_units, var_units, round(dfa_alpha::numeric, 3) AS dfa_alpha
  FROM cir_profile ORDER BY depot_id;

-- ------------------------------------------------------------------
-- 3. Step 2: scheduled replenishment for 3 of the 6 depots.
-- mu_i  = mean daily consumption (need served per unit moved);
-- cov   = diagonal risk matrix, var_i x alpha_i (demand variance
--         inflated by how non-linear the depot's demand is), flat
--         row-major as the optimizer expects.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Step 2: fractal_optimize_portfolio -- pick 3 depots ==='

DROP TABLE IF EXISTS cir_result;
CREATE TABLE cir_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(round((mean_units / 100.0)::numeric, 4)::float8 ORDER BY depot_id) FROM cir_profile),
    (SELECT array_agg(CASE WHEN a.depot_id = b.depot_id
                           THEN round((a.var_units * a.dfa_alpha / 100.0)::numeric, 4)::float8
                           ELSE 0::float8 END
                      ORDER BY a.depot_id, b.depot_id)
       FROM cir_profile a CROSS JOIN cir_profile b),
    3, 42) AS rj;

SELECT round((rj->>'sharpe')::numeric, 4) AS sharpe FROM cir_result;

\echo '--- the chosen depots (weight > 0; weights are in depot_id order) ---'
SELECT p.depot_id, p.region, round(w.weight_text::numeric, 4) AS weight
FROM cir_result r
CROSS JOIN LATERAL jsonb_array_elements_text(r.rj->'weights') WITH ORDINALITY AS w(weight_text, ord)
JOIN cir_profile p ON p.depot_id = w.ord
WHERE w.weight_text::float8 > 0
ORDER BY w.weight_text::float8 DESC;

\echo '--- depots flagged from Step 1 for expedited restock (DFA exponent > 1.2) ---'
SELECT depot_id, region, round(dfa_alpha::numeric, 3) AS dfa_alpha
  FROM cir_profile WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;

\echo '--- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---'
SELECT allocation, sharpe, rationale
FROM fractal_agent_allocate(
    (SELECT array_agg(round((mean_units / 100.0)::numeric, 4)::float8 ORDER BY depot_id) FROM cir_profile),
    (SELECT array_agg(CASE WHEN a.depot_id = b.depot_id
                           THEN round((a.var_units * a.dfa_alpha / 100.0)::numeric, 4)::float8
                           ELSE 0::float8 END
                      ORDER BY a.depot_id, b.depot_id)
       FROM cir_profile a CROSS JOIN cir_profile b),
    3, '{"portfolio": "critical-inventory-routing"}');

-- ------------------------------------------------------------------
-- 4. Reasoning: the rebalancing rationale (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Reasoning: rebalancing rationale ==='

SELECT fractal_reason(
    'one-line rationale for this critical-inventory replenishment plan',
    json_build_object(
      'dfa_by_depot', (SELECT json_object_agg(region, round(dfa_alpha::numeric, 3)) FROM cir_profile),
      'allocation',   (SELECT rj FROM cir_result))::text) AS rationale;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE cir_depots, cir_consumption, cir_profile, cir_result;'
