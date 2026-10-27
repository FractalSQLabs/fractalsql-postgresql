-- demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Industry vertical: High-frequency event-stream latency and rate anomaly
-- triage. DOMAIN kit: Four endpoints x 96 one-minute intervals of request
-- latency; one endpoint (EP-C) develops an accelerating latency ramp (a
-- timeout cascade) and a second (EP-B) has a retry-storm oscillation in its
-- request rate. `fractal_agent_anomaly_triage` flags the latency regime
-- shift, `fractal_periodogram` finds the retry-storm period, and
-- `fractal_search_trajectory` finds which endpoints' success-rate / latency
-- / timeout / fill health has moved the same way EP-C's did.
--
--   1. fractal_dimension_drift / fractal_agent_anomaly_triage: which
--      endpoint's latency changed regime.
--   2. fractal_periodogram: the dominant period of each endpoint's request
--      rate (a retry loop shows as a sharp line).
--   3. fractal_search_trajectory: endpoints whose health moved like the
--      degraded one (baseline -> current).
--   4. A closing fractal_reason() writes the triage line.
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents; The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Safe to re-run: esa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Latency is a steady base with a small cycle; EP-C ramps quadratically
--     from interval 65.
--   * Request rate: EP-B carries a 12-interval oscillation; the others are
--     flat with a faint 7-interval ripple.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Event-stream telemetry: 4 endpoints x 96 intervals ==='
DROP TABLE IF EXISTS esa_latency;
CREATE TABLE esa_latency (
    ent text,
    seq int,
    val float8
);
INSERT INTO esa_latency (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM (VALUES ('EP-A', 42, 0),
             ('EP-B', 55, 0),
             ('EP-C', 48, 0.0024),
             ('EP-D', 61, 0)) AS s(ent, base, p2),
     generate_series(1, 96) AS g;
DROP TABLE IF EXISTS esa_rate;
CREATE TABLE esa_rate (
    ent text,
    seq int,
    val float8
);
INSERT INTO esa_rate (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.02 * sin(2 * pi() * g / 7.0) + p1 * sin(2 * pi() * g / 12.0))
FROM (VALUES ('EP-A', 900, 0, 0),
             ('EP-B', 800, 0.3, 0),
             ('EP-C', 950, 0, 0),
             ('EP-D', 700, 0, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 96) AS g;
SELECT ent, count(*) AS intervals FROM esa_latency GROUP BY ent ORDER BY ent;

\echo ''
\echo '=== 2. Hand-composed: latency regime drift per endpoint ==='
DROP TABLE IF EXISTS esa_lprof;
CREATE TABLE esa_lprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, (x.dj->>'drift')::float8 AS drift, (x.dj->>'recent_alpha')::float8 AS recent_alpha, (x.dj->>'baseline_alpha')::float8 AS baseline_alpha
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM esa_latency GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_latency GROUP BY ent) m ON m.ent = a.ent
CROSS JOIN LATERAL (SELECT fractal_dimension_drift(a.arr, 32) AS dj) x
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((dfa_alpha)::numeric, 3) AS dfa_alpha, round((drift)::numeric, 4) AS drift, round((recent_alpha)::numeric, 4) AS recent_alpha, round((baseline_alpha)::numeric, 4) AS baseline_alpha
  FROM esa_lprof ORDER BY ent;

\echo ''
\echo '=== 3. fractal_agent_anomaly_triage: degraded vs healthy endpoint ==='
SELECT 'EP-C (degraded)' AS entity, threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-C', 32)
UNION ALL
SELECT 'EP-A (healthy)' AS entity, threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-A', 32);

\echo ''
\echo '=== 4. Retry-storm period: fractal_periodogram on the request rate ==='
DROP TABLE IF EXISTS esa_rprof;
CREATE TABLE esa_rprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v::numeric, 4)::float8 AS mean_v, round(m.var_v::numeric, 4)::float8 AS var_v, (SELECT freq FROM fractal_periodogram(a.arr, 1) LIMIT 1) AS freq
FROM (SELECT ent, array_agg(round(val::numeric, 5)::float8 ORDER BY seq) AS arr FROM esa_rate GROUP BY ent) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_rate GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round((freq)::numeric, 4) AS top_freq, round((1.0 / freq)::numeric, 1) AS samples_per_cycle
  FROM esa_rprof ORDER BY ent;

\echo ''
\echo '=== 5. Endpoint health trajectory: who moved like EP-C ==='
DROP TABLE IF EXISTS esa_health;
CREATE TABLE esa_health (
    id int PRIMARY KEY,
    label text,
    vec float8[] NOT NULL CHECK (array_length(vec, 1) = 4)
);
INSERT INTO esa_health (id, label, vec) VALUES
    (1, 'EP-01', ARRAY[0.05, -0.06, 0.03, -0.04]),
    (2, 'EP-02', ARRAY[0.1, -0.02, 0.06, 0.02]),
    (3, 'EP-03 (degraded)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (4, 'EP-04', ARRAY[0.2, 0.06, 0, 0.14]),
    (5, 'EP-05', ARRAY[0, 0.1, 0.03, 0.2]),
    (6, 'EP-06', ARRAY[0.05, 0.14, 0.06, -0.1]),
    (7, 'EP-07 (degraded)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (8, 'EP-08', ARRAY[0.15, -0.06, 0, 0.02]),
    (9, 'EP-09', ARRAY[0.2, -0.02, 0.03, 0.08]),
    (10, 'EP-10', ARRAY[0, 0.02, 0.06, 0.14]),
    (11, 'EP-11 (degraded)', ARRAY[1.4, 0.9, 1.1, 1.2]),
    (12, 'EP-12', ARRAY[0.1, 0.1, 0, -0.1]),
    (13, 'EP-13', ARRAY[0.15, 0.14, 0.03, -0.04]),
    (14, 'EP-14', ARRAY[0.2, -0.1, 0.06, 0.02]),
    (15, 'EP-15', ARRAY[0, -0.06, 0.09, 0.08]),
    (16, 'EP-16', ARRAY[0.05, -0.02, 0, 0.14]);
DROP TABLE IF EXISTS esa_traj;
CREATE TABLE esa_traj AS
WITH pos AS (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id, id, label FROM esa_health)
SELECT row_number() OVER (ORDER BY tr.distance, pos.id) AS rk, pos.id, pos.label AS label,
       round(tr.distance::numeric, 4)::float8 AS distance
FROM fractal_search_trajectory(
         'esa_health', 'vec',
         ARRAY[0.05, 0, 0.03, 0]::float8[],    -- baseline
         ARRAY[1.4, 0.9, 1.1, 1.2]::float8[],    -- current
         5) tr
JOIN pos ON pos.doc_id = tr.doc_id;

SELECT rk, id, label, distance FROM esa_traj ORDER BY rk;

\echo ''
\echo '=== 6. Reasoning: triage line ==='
SELECT fractal_reason(
    'one-line event-stream triage: which endpoint is degrading, since when, and the likely cause',
    json_build_object('worst_endpoint', (SELECT ent FROM esa_lprof ORDER BY drift DESC LIMIT 1), 'retry_storm_endpoint', (SELECT ent FROM esa_rprof ORDER BY freq DESC LIMIT 1), 'nearest_degraded_health', (SELECT label FROM esa_traj WHERE rk = 1))::text) AS narrative;

\echo ''
\echo '=== 7. Headline check ==='
SELECT 'HEADLINE kit=event-stream-anomaly-triage ' || CASE WHEN (SELECT drift FROM esa_lprof WHERE ent = 'EP-C') > 0.5 AND (SELECT drift FROM esa_lprof WHERE ent = 'EP-A') < 0 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') > 0.07 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') < 0.10 AND (SELECT count(*) FROM esa_traj WHERE distance < 0.001) >= 3 THEN 'ok' ELSE 'MISS' END AS headline;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj;'
