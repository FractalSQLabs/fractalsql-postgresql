-- demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Industry vertical: telecom -- anomalous account-change screening (SIM
-- swap, port-out, plan change, unusual device or location changes).  A
-- general-purpose pre-commit safety check, not a fraud-specific product.
-- DOMAIN kit built on one installed agent,
-- fractal_agent_outlier_intercept, reused verbatim: it screens a
-- PROPOSED event against a history of known-anomalous change patterns,
-- exactly its designed contract (the same shape as the ADAS kit's
-- known-bad-state history, applied to account activity).
--
-- Prerequisites: CREATE EXTENSION fractalsql; CREATE EXTENSION
-- fractalsql_agents;.  The hand-composed screen needs no model; the
-- shipped agent returns a reasoned `reason` (docs/reasoning-setup.md).
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Safe to re-run: taa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Event vectors are [sim_change, port_out, new_device, geo_jump,
--     off_hours] intensities in 0..1 as float8[] guarded by a CHECK on
--     their length.
--   * Cosine distance (the default) compares the SHAPE of an event, not
--     its overall intensity: a faint version of a known pattern is
--     flagged too.  Use 'l2' when intensity should count (Section 4).
--   * fractal_search_telemetry returns the row's ctid as doc_id.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. History of known-anomalous change patterns, and four proposed
-- account events awaiting commit.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Known-anomalous patterns + proposed account events ==='

DROP TABLE IF EXISTS taa_known_anomalous;
CREATE TABLE taa_known_anomalous (
    id      int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pattern text,
    event   float8[] NOT NULL CHECK (array_length(event, 1) = 5)
);
INSERT INTO taa_known_anomalous (pattern, event) VALUES
    ('SIM swap + port-out + new device',      ARRAY[0.95, 0.90, 0.85, 0.10, 0.20]),
    ('SIM swap from a distant location',      ARRAY[0.90, 0.05, 0.30, 0.95, 0.40]),
    ('rapid plan changes off-hours',          ARRAY[0.05, 0.05, 0.10, 0.10, 0.95]),
    ('new device + location jump + port-out', ARRAY[0.10, 0.80, 0.90, 0.85, 0.30]);

DROP TABLE IF EXISTS taa_proposed;
CREATE TABLE taa_proposed (
    id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label text,
    event float8[] NOT NULL CHECK (array_length(event, 1) = 5)
);
INSERT INTO taa_proposed (label, event) VALUES
    ('E1 swap + port-out + new handset', ARRAY[0.92, 0.88, 0.80, 0.12, 0.18]),
    ('E2 routine plan upgrade',          ARRAY[0.02, 0.00, 0.05, 0.00, 0.05]),
    ('E3 new handset, same city',        ARRAY[0.00, 0.02, 0.70, 0.04, 0.05]),
    ('E4 faint SIM swap, far away',      ARRAY[0.40, 0.02, 0.12, 0.42, 0.16]);

SELECT count(*) AS known_patterns FROM taa_known_anomalous;

-- ------------------------------------------------------------------
-- 2. Hand-composed screen: nearest known-anomalous pattern per event,
-- threshold 0.10 (cosine).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Hand-composed screen (cosine, threshold 0.10) ==='

SELECT p.label, k.pattern AS nearest_pattern,
       round(t.distance::numeric, 4) AS distance,
       (t.distance < 0.10) AS intercepted
FROM taa_proposed p
CROSS JOIN LATERAL fractal_search_telemetry('taa_known_anomalous', 'event', p.event, 1) t
JOIN taa_known_anomalous k ON k.ctid::text = t.doc_id
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent (reasoning plugin for the `reason` field).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_agent_outlier_intercept (cosine) ==='

SELECT p.label, o.intercepted, o.metric, o.reason
FROM taa_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(
         p.event, 'taa_known_anomalous', 'event', 0.10) o
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. When intensity should count: exact Euclidean distance.  E4 is a
-- faint SIM swap with a location jump -- the same shape as a known
-- pattern but at under half the intensity -- so cosine flags it while
-- l2 lets it through to a lower-severity review queue.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Same screen under exact Euclidean distance (threshold 0.30) ==='

SELECT p.label, o.intercepted AS intercepted_l2
FROM taa_proposed p
CROSS JOIN LATERAL fractal_agent_outlier_intercept(
         p.event, 'taa_known_anomalous', 'event', 0.30, 'l2') o
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the justification an analyst sees next to the held
-- event (needs the reasoning plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: justification for holding E1 ==='

SELECT fractal_reason(
    'one-line justification for holding this account change for review',
    json_build_object(
      'event', (SELECT label FROM taa_proposed WHERE id = 1),
      'screen', (SELECT json_agg(t) FROM fractal_search_telemetry(
                   'taa_known_anomalous', 'event',
                   (SELECT event FROM taa_proposed WHERE id = 1), 2) t))::text) AS justification;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE taa_known_anomalous, taa_proposed;'
