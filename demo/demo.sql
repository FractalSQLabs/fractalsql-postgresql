-- demo/demo.sql
--
-- FractalSQL basic demo: Sniper/Scout search feeding LLM reasoning.
--
-- Prerequisites (see demo/README.md for the full walkthrough):
--   1. fractalsql-postgresql installed and `CREATE EXTENSION fractalsql;`
--      already run in the target database.
--   2. Reasoning configured per ../docs/reasoning-setup.md -- this script
--      assumes fractalsql.reasoning_plugin / http_url / http_model are
--      already set and `SELECT pg_reload_conf();` has been run. Any
--      OpenAI-compatible endpoint works (Ollama, Bedrock, Azure, GCP
--      Vertex, ...) -- this script doesn't care which.
--
-- Run:
--   psql -d <your_database> -f demo/demo.sql
--
-- Safe to re-run: the demo tables are dropped and recreated each time.
-- Nothing here is destructive to anything outside the two demo_* tables.

\timing on

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

\echo ''
\echo '=== 1. Set up a small alerts table with something worth noticing ==='
DROP TABLE IF EXISTS demo_alerts;
CREATE TABLE demo_alerts (
    id          serial PRIMARY KEY,
    service     text,
    message     text,
    severity    text,
    created_at  timestamptz DEFAULT now()
);

INSERT INTO demo_alerts (service, message, severity, created_at) VALUES
    ('api-gateway',  'request latency p99 245ms',              'info',     now() - interval '55 minutes'),
    ('api-gateway',  'request latency p99 260ms',              'info',     now() - interval '50 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '45 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '40 minutes'),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  now() - interval '30 minutes'),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  now() - interval '29 minutes'),
    ('auth-service', '17 failed login attempts, user_id=8821', 'warning',  now() - interval '28 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '20 minutes'),
    ('api-gateway',  'request latency p99 4200ms',              'critical', now() - interval '10 minutes'),
    ('api-gateway',  'request latency p99 3900ms',              'critical', now() - interval  '9 minutes');

\echo ''
\echo '=== 2. Sniper Search: converge to a single best point ==='
SELECT fractal_search(ARRAY[0.6, 0.8, 0.0]::float8[], iterations => 50);

\echo ''
\echo '=== 3. Ask the LLM to analyze the alerts table (real context, not a bare ping) ==='
SELECT fractal_reason(
    'summarize what happened in the last hour and flag anything that needs attention',
    (SELECT jsonb_agg(row_to_json(t))::text
       FROM (SELECT service, message, severity, created_at
               FROM demo_alerts
              WHERE created_at > now() - interval '1 hour'
              ORDER BY created_at) t)
);

\echo ''
\echo '=== 4. Scout Discovery feeding reasoning: search + reason in one pipeline ==='
DROP TABLE IF EXISTS demo_embeddings;
CREATE TABLE demo_embeddings (id serial PRIMARY KEY, emb_arr float8[]);
INSERT INTO demo_embeddings (emb_arr)
SELECT ARRAY[random(), random(), random()]::float8[] FROM generate_series(1, 500);

SELECT fractal_reason(
    'these are points from a 3D embedding space sampled by Scout Discovery -- describe the spread',
    (SELECT jsonb_agg(p)::text FROM (
        SELECT p FROM fractal_search_explore(
            'demo_embeddings', 'emb_arr', ARRAY[0,0,0]::float8[],
            '{"population_size": 10, "iterations": 8, "walk": 0}'::jsonb
        ) AS p
    ) t)
);

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables demo_alerts and demo_embeddings were left in place for you to'
\echo 'inspect further. Clean up with:'
\echo '  DROP TABLE demo_alerts, demo_embeddings;'
