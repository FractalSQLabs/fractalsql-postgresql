-- =============================================================================
-- FractalSQL Industry Vertical Demo: Autonomous Incident Triage & Self-Healing
-- =============================================================================
-- End-to-end regression test for the embed-coupled agents. Exercises:
--   * fractal_agent_detect_loop   -- period-2 loop detection (C fix A4)
--   * fractal_search_agent        -- runs on a real 768-dim fractal_vector
--                                    column (was crashing / commented out;
--                                    C fix A1 makes a wrong column type a
--                                    clean ERROR instead of a backend crash)
--   * fractal_rag_agent           -- was a zero-exerciser before this demo
--   * fractal_dimension_drift     -- non-degenerate drifting latency series
--   * fractal_vectorizer_*        -- vectorizes the incident text
--   * fractal_agent_route_task, fractal_agent_outlier_intercept,
--     fractal_agent_anomaly_triage -- the REAL shipped fractalsql_agents
--     engines, not the local stubs this file used to define
-- Re-runnable: tear down a prior run's vectorizer config + queue (the config
-- outlives the table in v1 -- there is no fractal_vectorizer_drop), then drop
-- the demo tables. The unconditional DELETEs are no-ops on a first run.
--
-- This demo previously shadowed three real agents with local
-- CREATE OR REPLACE FUNCTION stubs: fractal_agent_route_task and
-- fractal_agent_outlier_intercept returned hardcoded values regardless
-- of input, and fractal_agent_threat_triage duplicated real drift+reason
-- logic under a name fractalsql_agents/'s own comments say was later
-- promoted into the real fractal_agent_anomaly_triage. This version
-- calls the three real, fully-implemented engines instead.
-- =============================================================================

DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'incident_logs');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'incident_logs');
DELETE FROM fractal_vectorizers WHERE source_table = 'incident_logs';
DROP TABLE IF EXISTS incident_logs, agent_capabilities, known_bad_states CASCADE;

-- 1. Setup synthetic incident telemetry
CREATE TABLE incident_logs (
    id          bigint PRIMARY KEY,
    agent_id    text,
    state_hash  bigint,        -- period-2 loop indicator (12345 / 67890)
    latency_ms  float8,        -- drifting metric -> fractal_dimension_drift
    body        text,           -- human-readable event line, vectorized below
    embedding   fractal_vector(768),  -- populated by the vectorizer (nomic-embed-text)
    event_ts    timestamp,
    payload     jsonb
);

-- Simulate a deployment bot stuck in an infinite retry loop: the state_hash
-- toggles 12345<->67890 every cycle (a clean period-2 sequence -- detect_loop
-- flags it via the short-period check, C fix A4, even though its DFA alpha is
-- ~0.1, well below the 0.9 threshold). The latency_ms series is a genuinely
-- drifting (non-degenerate) signal -- a baseline ~50ms for the first 64 cycles,
-- then a +30ms step-up over the most recent 32 cycles (the loop degrading
-- latency) -- so fractal_dimension_drift succeeds with a 32-point recent
-- window (DFA needs the recent window large enough; window=16 is too small).
-- The body text is what the vectorizer embeds for search_agent / rag_agent.
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
SELECT gs, 'bot-deploy-01',
       CASE WHEN gs % 2 = 1 THEN 12345 ELSE 67890 END,
       50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 64 THEN 30.0 ELSE 0.0 END,
       CASE WHEN gs % 2 = 1
            THEN 'bot-deploy-01 retrying authentication: identity service refused connection (attempt ' || gs || ')'
            ELSE 'bot-deploy-01 health check completed: all subsystems nominal (cycle ' || gs || ')'
       END,
       now() - (96 - gs) * interval '1 second',
       CASE WHEN gs % 2 = 1 THEN '{"event": "retry_auth"}'::jsonb
            ELSE '{"event": "check_health"}'::jsonb END
FROM generate_series(1, 96) AS gs;

-- A few healthy logs from a second bot (ids 97-99, outside bot-deploy-01's range).
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
VALUES
(97, 'bot-deploy-02', 11111, 42.0, 'bot-deploy-02 deployed configuration v2.3 successfully', now(), '{"event": "init"}'),
(98, 'bot-deploy-02', 22222, 45.0, 'bot-deploy-02 applied rolling update to worker pool',    now(), '{"event": "config"}'),
(99, 'bot-deploy-02', 33333, 48.0, 'bot-deploy-02 deployment finalized, rollout green',      now(), '{"event": "deploy"}');

-- 2. Vectorize the incident body text into 768-dim embeddings. The vectorizer
-- backfills the already-inserted rows into its queue, then process_queue embeds
-- them (nomic-embed-text -> 768 dims). This is the embedding-width column the
-- embed-coupled agents (search_agent, rag_agent) need.
SELECT fractal_vectorizer_create('incident_logs', 'body', 'embedding');
SELECT fractal_vectorizer_process_queue();   -- returns the number of rows embedded

-- 3. Setup capabilities map for routing
CREATE TABLE agent_capabilities (
    capability_name text PRIMARY KEY,
    embedding float8[]
);

INSERT INTO agent_capabilities (capability_name, embedding)
VALUES
('root-cause-analyzer', ARRAY[0.1, 0.2, 0.3]),
('rollback-executor', ARRAY[0.9, 0.8, 0.7]);

-- A small library of known-bad deployment states for
-- fractal_agent_outlier_intercept to screen proposed actions against.
CREATE TABLE known_bad_states (
    state_id     bigint PRIMARY KEY,
    description  text,
    state_vec    float8[]
);
INSERT INTO known_bad_states (state_id, description, state_vec) VALUES
(1, 'auth-service unreachable, retry storm',  ARRAY[0.5, 0.5, 0.5]),
(2, 'disk pressure cascading restarts',       ARRAY[0.9, 0.1, 0.2]);

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Loop Detection via DFA + short-period check
-- The state_hash sequence is a clean 12345<->67890 period-2 toggle. Its DFA
-- scaling exponent is ~0.1 (below the 0.9 threshold), so the DFA path alone
-- would NOT flag it -- but the short-period check (C fix A4) does. Result:
-- is_loop_detected = true.
SELECT * FROM fractal_agent_detect_loop(
    (SELECT array_agg(state_hash ORDER BY event_ts) FROM incident_logs WHERE agent_id = 'bot-deploy-01')
);

-- 5. Multi-Agent Routing (the real fractal_agent_route_task engine)
-- Real nearest-capability search over agent_capabilities.embedding, not a
-- hardcoded routed_to/confidence.
SELECT routed_to, confidence, remaining_budget, rationale
FROM fractal_agent_route_task(
    ARRAY[0.15, 0.25, 0.35]::float8[],
    'agent_capabilities', 'embedding', 'capability_name',
    1000
);

-- 6. Outlier Interception (the real fractal_agent_outlier_intercept engine)
-- Real cosine distance to the nearest known_bad_states row. This state_vec
-- matches state_id 1 exactly (distance 0), so intercepted = true.
SELECT intercepted, reason
FROM fractal_agent_outlier_intercept(
    ARRAY[0.5, 0.5, 0.5]::float8[],
    'known_bad_states', 'state_vec',
    0.8
);

-- 7. Threat Triage on the drifting latency metric (the real
-- fractal_agent_anomaly_triage engine, runs unwrapped: the latency_ms
-- series is a non-degenerate step-up signal with a 32-point recent window,
-- so fractal_dimension_drift succeeds -- window=16 would be too small for
-- DFA on the recent window and return rc=-1).
SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage('incident_logs', 'latency_ms', 'event_ts', 'agent_id', 'bot-deploy-01', 32);

-- 8. Localized Root-Cause Synthesis via Search Agent
-- Embeds the query (->768 for nomic-embed-text) and runs a diverse Scout
-- search over the incident_logs.embedding column, then reasons over the
-- retrieved context. This is the call that used to crash the backend when
-- pointed at the bigint state_hash column -- C fix A1 now makes that a clean
-- ERROR, and pointing at the real embedding column works end to end.
SELECT * FROM fractal_search_agent(
    'Why is bot-deploy-01 looping on auth?',
    'incident_logs', 'embedding',
    pop_size => 10, iterations => 5
);

-- 9. RAG Agent: retrieve-then-reason over the incident corpus.
SELECT * FROM fractal_rag_agent(
    'What events led to the auth retry loop on bot-deploy-01?',
    'incident_logs', 'embedding'
);