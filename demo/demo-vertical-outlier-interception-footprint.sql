-- demo/demo-vertical-outlier-interception-footprint.sql
--
-- Industry vertical: Automated-traffic interception: bot-farm and
-- invalid-traffic screening. DOMAIN kit: Screens proposed traffic sessions
-- against a history of known-abuse signatures with
-- `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean
-- when magnitude should count), then uses `fractal_dimension_boxcount` on
-- click-coordinate clouds: organic traffic fills the page (a high
-- box-counting dimension) while an automated farm hammering a handful of
-- targets collapses onto a line (a dimension near 1).
--
--   1. fractal_agent_outlier_intercept: hold sessions that sit near a known
--      bot-farm signature.
--   2. The same screen under exact Euclidean distance (threshold 0.30),
--      where magnitude matters.
--   3. fractal_dimension_boxcount: the topological footprint of each
--      traffic source's click map.
--   4. A closing fractal_reason() writes the hold / release justification.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-outlier-interception-footprint.sql
--
-- Safe to re-run: oif_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Session signature = [click velocity, IP-pool concentration, device
--     reuse, headless-UA ratio, geo mismatch].
--   * Click maps are 200 points each in the unit square: an organic spread
--     vs a collinear farm pattern.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Known abuse signatures + proposed traffic sessions ==='
DROP TABLE IF EXISTS oif_known;
CREATE TABLE oif_known (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 5)
);
INSERT INTO oif_known (id, label, vec) VALUES
    (1, 'automated farm: one device pool, burst requests', ARRAY[0.95, 0.9, 0.85, 0.1, 0.2]),
    (2, 'datacenter bot traffic, headless browsers', ARRAY[0.9, 0.05, 0.3, 0.95, 0.4]),
    (3, 'residential-proxy request spoofing', ARRAY[0.05, 0.05, 0.1, 0.1, 0.95]),
    (4, 'request-stacking ring', ARRAY[0.1, 0.8, 0.9, 0.85, 0.3]);
DROP TABLE IF EXISTS oif_proposed;
CREATE TABLE oif_proposed (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 5)
);
INSERT INTO oif_proposed (id, label, vec) VALUES
    (1, 'T1 burst requests from a shared device pool', ARRAY[0.92, 0.88, 0.8, 0.12, 0.18]),
    (2, 'T2 organic referral session', ARRAY[0.02, 0, 0.05, 0, 0.05]),
    (3, 'T3 returning user on a new device', ARRAY[0, 0.02, 0.7, 0.04, 0.05]),
    (4, 'T4 faint headless traffic, far geo', ARRAY[0.4, 0.02, 0.12, 0.42, 0.16]);

\echo ''
\echo '=== 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ==='
DROP TABLE IF EXISTS oif_screen;
CREATE TABLE oif_screen AS
SELECT p.id, p.label, o.intercepted::int AS intercepted, o.metric
FROM oif_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(p.vec, 'oif_known', 'vec', 0.1) o
ORDER BY p.id;

SELECT id, label, intercepted, metric FROM oif_screen ORDER BY id;

\echo ''
\echo '=== 3. Same screen under exact Euclidean distance (threshold 0.30) ==='
DROP TABLE IF EXISTS oif_screen_l2;
CREATE TABLE oif_screen_l2 AS
SELECT p.id, p.label, o.intercepted::int AS intercepted, o.metric
FROM oif_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(p.vec, 'oif_known', 'vec', 0.3, 'l2') o
ORDER BY p.id;

SELECT id, label, intercepted, metric FROM oif_screen_l2 ORDER BY id;

\echo ''
\echo '=== 4. Click-map topology: organic traffic vs an automated farm ==='
DROP TABLE IF EXISTS oif_clicks;
CREATE TABLE oif_clicks (
    ent text,
    pt  int,
    x   float8,
    y   float8
);
INSERT INTO oif_clicks (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
FROM (VALUES ('organic-source', 1),
             ('farm-ring', 0)) AS s(ent, p1),
     generate_series(1, 200) AS g;
DROP TABLE IF EXISTS oif_dim;
CREATE TABLE oif_dim AS
SELECT ent, round(fractal_dimension_boxcount(array_agg(v ORDER BY pt, ord), 2)::numeric, 3)::float8 AS dim
FROM (SELECT ent, pt, ord, v
        FROM oif_clicks CROSS JOIN LATERAL unnest(ARRAY[x, y]) WITH ORDINALITY AS u(v, ord)) q
GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM oif_dim ORDER BY ent;

\echo ''
\echo '=== 5. Reasoning: hold / release justification ==='
SELECT fractal_reason(
    'one-line justification for holding the flagged traffic and the topology evidence for an automated farm',
    json_build_object('held_session', (SELECT label FROM oif_screen WHERE id = 1), 'farm_dimension', (SELECT dim FROM oif_dim WHERE ent = 'farm-ring'), 'organic_dimension', (SELECT dim FROM oif_dim WHERE ent = 'organic-source'))::text) AS narrative;

\echo ''
\echo '=== 6. Headline check ==='
SELECT 'HEADLINE kit=outlier-interception-footprint ' || CASE WHEN (SELECT intercepted FROM oif_screen WHERE id = 1) = 1 AND (SELECT intercepted FROM oif_screen WHERE id = 2) = 0 AND (SELECT intercepted FROM oif_screen WHERE id = 4) = 1 AND (SELECT dim FROM oif_dim WHERE ent = 'farm-ring') + 0.3 < (SELECT dim FROM oif_dim WHERE ent = 'organic-source') THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim;'
