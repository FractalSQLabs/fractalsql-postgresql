-- demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- Industry vertical: Periodicity and selection: cycle-strength detection
-- and risk-aware portfolio choice. DOMAIN kit: Six items x 96 days of sales
-- velocity with a weekly demand cycle of differing strength.
-- `fractal_periodogram` quantifies which items are genuinely periodic;
-- `fractal_optimize_portfolio` picks the 3 items that get the scheduled
-- action (a Sharpe-style trade of margin recovered against demand
-- volatility); `fractal_agent_recommend_diverse` proposes a diverse set of
-- substitute items. On the Enterprise edition
-- `fractal_agent_diverse_portfolios` (multimodal optimization) also returns
-- structurally different schedules; on the Community edition that step
-- reports "enterprise tier not loaded".
--
--   1. fractal_periodogram: the dominant period of each item's sales
--      velocity.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 selection for the scheduled
--      action.
--   3. fractal_agent_recommend_diverse: a diverse substitute-item set.
--   4. fractal_agent_diverse_portfolios (Enterprise): structurally
--      different schedules.
--   5. A closing fractal_reason() writes the decision note.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- Safe to re-run: pps_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The multimodal step is the one expected error on the Community edition
--     (the "enterprise tier not loaded" refusal); everything else runs on
--     Community.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Six items x 96 days of sales velocity ==='
DROP TABLE IF EXISTS pps_sales;
CREATE TABLE pps_sales (
    ent text,
    seq int,
    val float8
);
INSERT INTO pps_sales (ent, seq, val)
SELECT ent, g, base * (1.0 + p1 * sin(2 * pi() * g / 7.0) + 0.004 * (g % 5))
FROM (VALUES ('item-a', 90, 0.35, 0),
             ('item-b', 110, 0.3, 0),
             ('item-c', 140, 0.02, 0),
             ('item-d', 120, 0.04, 0),
             ('item-e', 100, 0.28, 0),
             ('item-f', 160, 0.02, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 96) AS g;

\echo ''
\echo '=== 2. Periodicity per item (fractal_periodogram) + volatility ==='
DROP TABLE IF EXISTS pps_prof;
CREATE TABLE pps_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, (SELECT freq FROM fractal_periodogram(a.arr, 1) LIMIT 1) AS freq
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM pps_sales GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM pps_sales GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((dfa_alpha)::numeric, 3) AS dfa_alpha, round((freq)::numeric, 4) AS top_freq, round((1.0 / freq)::numeric, 1) AS samples_per_cycle
  FROM pps_prof ORDER BY ent;

\echo ''
\echo '=== 3. fractal_optimize_portfolio: pick 3 items for the scheduled action ==='
DROP TABLE IF EXISTS pps_result;
CREATE TABLE pps_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(round((p.mean_v / 100.0)::numeric, 4)::float8 ORDER BY p.pid) FROM pps_prof p),
    (SELECT array_agg(CASE WHEN a.pid = b.pid THEN round((a.var_v * a.dfa_alpha / 100.0)::numeric, 4)::float8 ELSE 0::float8 END
                      ORDER BY a.pid, b.pid)
       FROM pps_prof a CROSS JOIN pps_prof b),
    3, 42) AS rj;

SELECT round((rj->>'sharpe')::numeric, 4) AS sharpe FROM pps_result;

\echo '--- the chosen entries (weight > 0; weights are in ent order) ---'
SELECT p.ent, round(w.weight_text::numeric, 4) AS weight
FROM pps_result r
CROSS JOIN LATERAL jsonb_array_elements_text(r.rj->'weights') WITH ORDINALITY AS w(weight_text, ord)
JOIN pps_prof p ON p.pid = w.ord
WHERE w.weight_text::float8 > 0
ORDER BY w.weight_text::float8 DESC;

\echo ''
\echo '=== 4. Diverse substitute-item set ==='
DROP TABLE IF EXISTS pps_catalog;
CREATE TABLE pps_catalog (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 3)
);
INSERT INTO pps_catalog (id, label, vec) VALUES
    (1, 'alt-b 1', ARRAY[0.1513, 0.8487, 0.2763]),
    (2, 'alt-c 2', ARRAY[0.3026, 0.1474, 0.8776]),
    (3, 'alt-d 3', ARRAY[0.5789, 0.5461, 0.6539]),
    (4, 'alt-e 4', ARRAY[0.9302, 0.1448, 0.1552]),
    (5, 'alt-f 5', ARRAY[0.1065, 0.8435, 0.2065]),
    (6, 'alt-a 6', ARRAY[0.2578, 0.1422, 0.9328]),
    (7, 'alt-b 7', ARRAY[0.6591, 0.5409, 0.5841]),
    (8, 'alt-c 8', ARRAY[0.8854, 0.1396, 0.2104]),
    (9, 'alt-d 9', ARRAY[0.1867, 0.8383, 0.2617]),
    (10, 'alt-e 10', ARRAY[0.213, 0.137, 0.863]),
    (11, 'alt-f 11', ARRAY[0.6143, 0.5357, 0.6393]),
    (12, 'alt-a 12', ARRAY[0.9656, 0.1344, 0.1406]),
    (13, 'alt-b 13', ARRAY[0.1419, 0.8331, 0.3169]),
    (14, 'alt-c 14', ARRAY[0.2932, 0.1318, 0.9182]),
    (15, 'alt-d 15', ARRAY[0.5695, 0.5305, 0.5695]),
    (16, 'alt-e 16', ARRAY[0.9208, 0.1292, 0.1958]),
    (17, 'alt-f 17', ARRAY[0.2221, 0.8279, 0.2471]),
    (18, 'alt-a 18', ARRAY[0.2484, 0.1266, 0.9734]),
    (19, 'alt-b 19', ARRAY[0.6497, 0.5253, 0.6247]),
    (20, 'alt-c 20', ARRAY[0.876, 0.124, 0.126]),
    (21, 'alt-d 21', ARRAY[0.1773, 0.8227, 0.3023]),
    (22, 'alt-e 22', ARRAY[0.3286, 0.1214, 0.9036]),
    (23, 'alt-f 23', ARRAY[0.6049, 0.5201, 0.6799]),
    (24, 'alt-a 24', ARRAY[0.9562, 0.1188, 0.1812]),
    (25, 'alt-b 25', ARRAY[0.1325, 0.8175, 0.2325]),
    (26, 'alt-c 26', ARRAY[0.2838, 0.1162, 0.9588]),
    (27, 'alt-d 27', ARRAY[0.6851, 0.5149, 0.6101]),
    (28, 'alt-e 28', ARRAY[0.9114, 0.1136, 0.2364]),
    (29, 'alt-f 29', ARRAY[0.2127, 0.8123, 0.2877]),
    (30, 'alt-a 30', ARRAY[0.239, 0.111, 0.889]);
DROP TABLE IF EXISTS pps_rec;
CREATE TABLE pps_rec AS
SELECT row_number() OVER (ORDER BY r.score DESC, r.item_id) AS rk, r.item_id::int AS item_id, c.label AS label,
       round(r.score::numeric, 4)::float8 AS score
FROM fractal_agent_recommend_diverse('pps_catalog', 'vec', ARRAY[0.85, 0.2, 0.15]::float8[], 4, 'id') r
JOIN pps_catalog c ON c.id = r.item_id::int
ORDER BY 1;

SELECT rk, item_id, label, score FROM pps_rec ORDER BY rk;
SELECT fractal_diversify_disable();

\echo ''
\echo '=== 5. Enterprise edition: structurally different schedules ==='
\echo '--- Enterprise edition: structurally distinct candidates (errors with "enterprise tier not loaded" on the Community edition) ---'
SELECT candidate_id, sharpe, rationale
FROM fractal_agent_diverse_portfolios(
    (SELECT array_agg(round((p.mean_v / 100.0)::numeric, 4)::float8 ORDER BY p.pid) FROM pps_prof p),
    (SELECT array_agg(CASE WHEN a.pid = b.pid THEN round((a.var_v * a.dfa_alpha / 100.0)::numeric, 4)::float8 ELSE 0::float8 END
                      ORDER BY a.pid, b.pid)
       FROM pps_prof a CROSS JOIN pps_prof b),
    3, 4);

\echo ''
\echo '=== 6. Reasoning: decision note ==='
SELECT fractal_reason(
    'one-line decision note: which items to act on, why they are periodic, and what to promote instead',
    json_build_object('most_periodic_item', (SELECT ent FROM pps_prof ORDER BY dfa_alpha DESC LIMIT 1), 'promoted_substitute', (SELECT label FROM pps_rec WHERE rk = 1))::text) AS narrative;

\echo ''
\echo '=== 7. Headline check ==='
SELECT 'HEADLINE kit=periodicity-portfolio-selection ' || CASE WHEN (SELECT freq FROM pps_prof WHERE ent = 'item-a') > 0.13 AND (SELECT freq FROM pps_prof WHERE ent = 'item-a') < 0.16 AND (SELECT count(*) FROM pps_rec) = 4 THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE pps_sales, pps_prof, pps_result, pps_catalog, pps_rec;'
