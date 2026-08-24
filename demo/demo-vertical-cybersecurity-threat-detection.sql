-- demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Industry vertical: Cybersecurity & Threat Detection (network behavior
-- analytics / SOC log analysis).
--
-- A 35-host fleet across three network zones, each with a BASELINE
-- traffic-behavior vector and a CURRENT (recent window) vector. One
-- host goes quiet-then-beacons: a compromise pattern (outbound
-- connection volume, unique destination ports, and DNS query rate all
-- spike; failed-auth rate barely moves -- this isn't a brute-force
-- attempt, it's a stealthier C2 beaconing profile). Diverse
-- traffic-profile clustering for threat hunting, a zone-restricted
-- search, current-vs-baseline drift detection, and connection-rate
-- regime-change detection via DFA.
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Section 6 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-cybersecurity-threat-detection.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Safe to re-run: vcy_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.73);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 35 hosts across 3 zones (dmz, internal, guest), each with a
-- BASELINE behavior vector (normal traffic profile) and a CURRENT
-- vector (this window's telemetry). Fields, in order:
-- [outbound_conn_rate, unique_dest_ports, dns_query_rate,
-- failed_auth_rate], each normalized to roughly [-1, 1]. Host 7 gets
-- a deliberate compromise pattern -- everyone else's current stays
-- close to baseline (ordinary traffic noise).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 35 hosts: baseline vs. current network-behavior vectors ==='

DROP TABLE IF EXISTS vcy_hosts;
CREATE TABLE vcy_hosts (
    id       serial PRIMARY KEY,
    hostname text,
    zone     text,
    -- fractal_vector(4), not float8[] -- same fixed-width,
    -- dimension-safety-matters argument as demo-vertical-medtech-clinical.sql's
    -- vitals and demo-vertical-maritime-defense.sql's baseline/current: a
    -- feature-extraction bug that silently changed the vector's width
    -- should be a hard write-time error, not a corrupted search corpus.
    baseline fractal_vector(4),
    current  fractal_vector(4)
);

-- INSERT is UNCHANGED (still literal ::float8[] values) -- the
-- assignment cast handles coercion into the fractal_vector(4) columns
-- automatically, same as the other three fractal_vector verticals.
INSERT INTO vcy_hosts (hostname, zone, baseline, current)
SELECT 'HOST-' || gs,
       (ARRAY['dmz', 'internal', 'guest'])[((gs - 1) % 3) + 1],
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (random()-0.5)*0.06, b2 + (random()-0.5)*0.06,
             b3 + (random()-0.5)*0.06, b4 + (random()-0.5)*0.06]::float8[]
FROM generate_series(1, 35) gs,
     LATERAL (SELECT random()*2-1, random()*2-1, random()*2-1, random()*2-1) AS bl(b1, b2, b3, b4);

-- Host 7's deliberate compromise: outbound connections, destination
-- ports, and DNS query volume all spike; failed-auth barely moves.
-- fractal_vector has no [n] subscript operator -- cast to float8[]
-- for the per-element arithmetic (same pattern as
-- demo-vertical-maritime-defense.sql's vessel-7 UPDATE), then let the
-- assignment cast coerce the result back on write.
UPDATE vcy_hosts
   SET current = ARRAY[(baseline::float8[])[1] + 0.8, (baseline::float8[])[2] + 0.7,
                        (baseline::float8[])[3] + 0.6, (baseline::float8[])[4] + 0.05]::float8[]
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse traffic-profile clustering across the
-- fleet -- threat hunting ("what KINDS of behavior profiles are
-- actually running right now") instead of cosine top-K, which would
-- just return 50 near-duplicates of whichever profile is most common
-- and miss the one host that looks different.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_search_explore: diverse traffic-profile clustering ==='
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's traffic-profile embeddings -- surfaces the one host that looks
-- different instead of K near-duplicates of the most common profile.
-- SELECT p FROM fractal_search_explore(
--     'vcy_hosts', 'current', ARRAY[0,0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real host ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 zone search below sees the same
-- diversify-off state as before (the engine leaves diversify on -- the
-- caller owns that policy). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so
-- anchor on the first host's own current vector.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vcy_hosts', 'current',
    (SELECT current::float8[] FROM vcy_hosts ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Zone-restricted search: "DMZ hosts only" -- fractal_search_
-- telemetry's table_name argument is a plain text table name, so a
-- zone filter composes by searching a filtered temp table instead
-- (the same cohort-then-search shape fractal_hybrid_clinical_search
-- uses internally for its doc_ids allowlist, without needing that
-- clinically-named function here -- same composition
-- demo-vertical-fleet-logistics.sql uses for its route-3 cohort).
--
-- doc_id is the row's 0-based position in the search's own internal
-- table scan, NOT id - 1 -- those only coincide for a table that has
-- never been UPDATEd (a plain heap scan then visits rows in insertion
-- order). vcy_dmz_cohort was built by filtering the ALREADY-UPDATEd
-- vcy_hosts (host 7's compromise UPDATE relocated its tuple to the
-- end of the heap, and host 7 is itself in the dmz zone), so its scan
-- order no longer matches id order. Map doc_id back to id via the
-- same ctid (physical scan) order the search actually used, rather
-- than assuming doc_id + 1 = id.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Zone-restricted search: DMZ hosts only ==='

DROP TABLE IF EXISTS vcy_dmz_cohort;
CREATE TEMP TABLE vcy_dmz_cohort AS
SELECT * FROM vcy_hosts WHERE zone = 'dmz';

SELECT h.hostname, t.distance
FROM fractal_search_telemetry('vcy_dmz_cohort', 'current',
                              ARRAY[0.3, 0.3, 0.3, 0.0]::float8[], 5) t
JOIN (SELECT *, row_number() OVER (ORDER BY ctid) - 1 AS doc_id
        FROM vcy_dmz_cohort) h ON h.doc_id = t.doc_id
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for host 7
-- -- "what changed" rather than "what's closest", the direct fit for
-- compromise/beaconing detection. host7.baseline/host7.current are
-- fractal_vector(4) column values, so this resolves to the
-- fractal_vector overload directly.
--
-- Same doc_id-vs-id caveat as section 3 above -- host 7's own UPDATE
-- relocated its tuple, so vcy_hosts' scan order diverges from id
-- order (host 7 now scans last). Map via ctid order, not id - 1.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_search_trajectory: host 7''s drift vs. the fleet ==='

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- host 7's compromise drift. Generalized by the shipped
-- fractal_agent_track_anomaly preset in Section 5, which folds this
-- trajectory search together with the connection-rate heading DFA and a
-- reasoning step (and resolves the nearest host via ctid, the same
-- mapping this raw form uses).
-- SELECT h.hostname, h.zone, t.distance
-- FROM vcy_hosts flagged, fractal_search_trajectory(
--     'vcy_hosts', 'current', flagged.baseline, flagged.current, 5
-- ) t
-- JOIN (SELECT *, row_number() OVER (ORDER BY ctid) - 1 AS doc_id
--         FROM vcy_hosts) h ON h.doc_id = t.doc_id
-- WHERE flagged.id = 7
-- ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 5. fractal_dimension_dfa / fractal_dimension_drift: host 7's
-- connections-per-minute series over the last 300 minutes, with a
-- deliberate regime change at t=220 -- low-amplitude noisy baseline
-- traffic, then a shift to a regular, higher-frequency beaconing
-- interval. DFA's scaling exponent picks up the change in long-range
-- structure; fractal_dimension_drift makes the same point directly by
-- comparing the tail window against everything before it.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. fractal_dimension_dfa / drift: host 7 connection-rate regime change ==='

DROP TABLE IF EXISTS vcy_conn_series;
CREATE TEMP TABLE vcy_conn_series AS
SELECT t,
       CASE WHEN t < 220
            THEN 4.0 + 1.5 * sin(t * 0.31) + (random()-0.5) * 0.8
            ELSE 4.0 + 3.0 * sin(t * 1.4)  + (random()-0.5) * 0.4
       END AS conn_rate
FROM generate_series(1, 300) t;

-- Blueprint (raw primitives): the connection-rate series' DFA exponent
-- and its drift report. Generalized below by TWO shipped presets:
-- fractal_agent_regime_triage (the dfa+drift over this series) and
-- fractal_agent_track_anomaly (this series' DFA folded with the Section 4
-- trajectory search over host 7's baseline->current).
-- SELECT fractal_dimension_dfa(
--     (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series)
-- ) AS full_series_dfa_exponent;
--
-- SELECT fractal_dimension_drift(
--     (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
--     60
-- ) AS recent_60min_vs_history;

-- Productized preset (1): the regime-change engine over the connection-
-- rate series -- real DFA exponent, real drift_detected, real alphas,
-- real rationale.
\echo '--- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---'
SELECT dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale
FROM fractal_agent_regime_triage(
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
    64, 0.5);

-- Productized preset (2): the track-anomaly engine -- real nearest fleet
-- host (fractal_search_trajectory over host 7's baseline->current,
-- resolved via ctid), real trajectory_distance, real connection-rate DFA
-- exponent, real rationale.
\echo '--- Preset: fractal_agent_track_anomaly (raw trajectory+dfa form preserved in Section 4 + above) ---'
SELECT nearest_fleet_id, trajectory_distance, dfa_exponent, rationale
FROM fractal_agent_track_anomaly(
    'vcy_hosts', 'current',
    (SELECT baseline::float8[] FROM vcy_hosts WHERE id = 7),
    (SELECT current::float8[]  FROM vcy_hosts WHERE id = 7),
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
    5, 'id');

-- ------------------------------------------------------------------
-- 6. Reasoning: the SOC triage narrative for host 7 is now split across
-- the two Section 5 preset rationales -- fractal_agent_track_anomaly
-- (the baseline->current drift + connection-rate DFA) and
-- fractal_agent_regime_triage (the regime change itself).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. Reasoning: absorbed into the Section 5 track_anomaly + regime_triage rationales ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vcy_hosts;'
