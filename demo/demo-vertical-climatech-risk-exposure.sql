-- demo/demo-vertical-climatech-risk-exposure.sql
--
-- Industry vertical: Climate Tech -- physical climate-risk exposure
-- monitoring for insurers and asset managers (wildfire, flood, drought
-- hazard sensor grids).  DOMAIN kit built on one installed agent,
-- fractal_agent_network_coverage_alert, reused verbatim: spatial
-- morphology (box-counting dimension + lacunarity) of the hazard grid
-- plus drift of a telemetry series, closing with a risk-exposure
-- narrative.  The kit is shaped like the smart-cities kit's sensor grid,
-- over climate-hazard readings instead of urban IoT sensors.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed morphology needs no model; the
-- shipped agent and the closing narrative are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-climatech-risk-exposure.sql
--
-- Safe to re-run: cre_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in a recursive CTE, not random().
--   * A 20 x 20 sensor grid (400 cells).  A cell is "high hazard" when its
--     fuel-moisture deficit index exceeds 0.40 in the dry season (0.25 in
--     the wet season, where the index runs about half as high).  In the
--     dry season the high-hazard region is large and clumped toward the
--     south-west; in the wet season it is smaller.  The point cloud handed
--     to the morphology estimator is the set of high-hazard cell centers
--     (flat interleaved x,y); it needs a couple of hundred points for a
--     stable estimate, which is why the dry-season cloud is the one the
--     shipped agent is run on.
--   * The drift series is the regional fuel-moisture telemetry: stable
--     for 48 days, then a rapid oscillation as a heat wave begins.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Hazard grid: a fuel-moisture deficit index per cell for the dry
-- and wet seasons.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 20 x 20 hazard grid, dry vs wet season ==='

DROP TABLE IF EXISTS cre_grid;
CREATE TABLE cre_grid (
    r int, c int,
    dry_index float8,
    wet_index float8
);
INSERT INTO cre_grid (r, c, dry_index, wet_index)
SELECT r, c,
       (19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + ((r * 5 + c * 3) % 7) / 70.0 + 0.05,
       ((19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + ((r * 5 + c * 3) % 7) / 70.0) * 0.55
FROM generate_series(0, 19) AS r, generate_series(0, 19) AS c
ORDER BY r, c;

SELECT count(*) FILTER (WHERE dry_index > 0.40) AS high_hazard_cells_dry,
       count(*) FILTER (WHERE wet_index > 0.25) AS elevated_cells_wet
  FROM cre_grid;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of the elevated-hazard region in each
-- season (dry: index > 0.40; wet: index > 0.25, since the wet-season
-- index runs about half as high).  The dry-season region is large and
-- compact; the wet-season region is smaller and gappier.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Morphology of the high-hazard region ==='

SELECT 'dry season' AS season,
       round((m->>'dimension')::numeric, 3)  AS dimension,
       round((m->>'lacunarity')::numeric, 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        (SELECT array_agg(v ORDER BY r, c, ord)
           FROM cre_grid g, LATERAL unnest(ARRAY[g.c::float8, g.r::float8]) WITH ORDINALITY AS u(v, ord)
          WHERE g.dry_index > 0.40), 2) AS m) d
UNION ALL
SELECT 'wet season',
       round((m->>'dimension')::numeric, 3),
       round((m->>'lacunarity')::numeric, 3)
FROM (SELECT fractal_morphological_complexity(
        (SELECT array_agg(v ORDER BY r, c, ord)
           FROM cre_grid g, LATERAL unnest(ARRAY[g.c::float8, g.r::float8]) WITH ORDINALITY AS u(v, ord)
          WHERE g.wet_index > 0.25), 2) AS m) w;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the dry season: morphology + fuel-moisture
-- drift + a reasoned exposure alert (reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_agent_network_coverage_alert (dry-season exposure) ==='

SELECT morph_dimension, lacunarity, drift_detected, rationale
FROM fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM cre_grid g, LATERAL unnest(ARRAY[g.c::float8, g.r::float8]) WITH ORDINALITY AS u(v, ord)
      WHERE g.dry_index > 0.40),
    (WITH RECURSIVE n(t, x) AS (
            SELECT 1, 2718::bigint UNION ALL
            SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 96)
     SELECT array_agg(round(v::numeric, 4)::float8 ORDER BY t)
       FROM (SELECT t,
                    CASE WHEN t < 49
                         THEN 4.0 + 1.5 * sin(t * 0.31) + ((((x / 65536) % 1000) - 500) / 1250.0)
                         ELSE 4.0 + 3.0 * sin(t * 1.4)  + ((((x / 65536) % 1000) - 500) / 2500.0)
                    END AS v FROM n) s),
    2, 48, 0.5);

-- ------------------------------------------------------------------
-- 4. Reasoning: the risk-exposure narrative (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Reasoning: risk-exposure narrative ==='

SELECT fractal_reason(
    'one-line physical-climate-risk exposure narrative for an insured portfolio in this region',
    (SELECT fractal_morphological_complexity(
        (SELECT array_agg(v ORDER BY r, c, ord)
           FROM cre_grid g, LATERAL unnest(ARRAY[g.c::float8, g.r::float8]) WITH ORDINALITY AS u(v, ord)
          WHERE g.dry_index > 0.40), 2))::text) AS narrative;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE cre_grid;'
