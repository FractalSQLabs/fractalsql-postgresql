-- demo/demo-vectorizer.sql
-- Runnable walkthrough of fractal_vectorizer_create() /
-- fractal_vectorizer_process_queue() / fractal_vectorizer_status.
-- See ../docs/vectorizer-setup.md for the full API reference, the
-- BYO-scheduler options, and open questions (chunking, cost controls).
--
-- Prerequisites: extension installed, reasoning AND embedding
-- configured. Local Ollama example pairing a chat model with a real
-- embedding model from the same host (never reuse the chat model for
-- embeddings -- a purpose-trained model matters):
--
--   ollama pull gpt-oss:20b
--   ollama pull nomic-embed-text
--
--   fractalsql.reasoning_plugin = '/usr/local/lib/fractalsql/fractalsql-reasoning-http.so'
--   fractalsql.http_url         = 'http://127.0.0.1:11434/v1/chat/completions'
--   fractalsql.http_model       = 'gpt-oss:20b'
--   fractalsql.http_embed_url   = 'http://127.0.0.1:11434/v1/embeddings'
--   fractalsql.http_embed_model = 'nomic-embed-text'
--   fractalsql.http_allow_plaintext = on
--
-- Confirm before running this script:
--   SELECT fractal_embed('reply with a short confirmation that this connection works');
--
-- Safe to re-run: the schema is dropped and recreated at the top.

\timing on
\pset pager off
\encoding UTF8

DROP TABLE IF EXISTS docs;

CREATE TABLE docs (
    id        serial PRIMARY KEY,
    body      text NOT NULL,
    embedding float8[]
);
COMMENT ON TABLE docs IS 'Toy document store -- one row per short passage';

\echo '=== Section 1: some rows BEFORE the vectorizer exists ==='
\echo 'fractal_vectorizer_create() backfills existing rows automatically --'
\echo 'these three will be queued the moment it runs, no separate step needed.'
INSERT INTO docs (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside PostgreSQL.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.'),
    ('fractal_text_to_sql never executes what it generates -- that is always separate.');

SELECT id, body FROM docs ORDER BY id;

\echo ''
\echo '=== Section 2: create the vectorizer ==='
SELECT fractal_vectorizer_create('docs', 'body', 'embedding');

\echo ''
\echo 'Backfilled queue (all 3 rows above -- none had an embedding yet):'
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

\echo ''
\echo '=== Section 3: a NEW row after the vectorizer exists ==='
\echo 'The trigger queues it automatically -- no manual step.'
INSERT INTO docs (body) VALUES
    ('Sniper Search refines a query point; Scout Mode returns a diverse population instead.');

SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

\echo ''
\echo '=== Section 4: process the queue ==='
\echo 'This is the one function you put on a schedule (pg_cron, OS cron,'
\echo 'Windows Task Scheduler, your own app -- see docs/vectorizer-setup.md).'
\echo 'Running it manually here for the demo:'
SELECT fractal_vectorizer_process_queue();

\echo ''
\echo '=== Section 5: check the results ==='
SELECT id, body, embedding IS NOT NULL AS has_embedding,
       CASE WHEN embedding IS NOT NULL THEN array_length(embedding, 1) END AS dim
FROM docs
ORDER BY id;

\echo ''
\echo 'Status view -- what fractal_vectorizer_process_queue() actually did:'
SELECT vectorizer_id, source_table, status, n, last_error
FROM fractal_vectorizer_status
ORDER BY status;

\echo ''
\echo '=== Section 6: edit a row, watch it get re-queued ==='
UPDATE docs SET body = body || ' (edited)' WHERE id = 1;
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;
SELECT fractal_vectorizer_process_queue();
SELECT vectorizer_id, status, n FROM fractal_vectorizer_status ORDER BY status;

\echo ''
\echo '================================================================'
\echo 'Next: docs/vectorizer-setup.md for the BYO-scheduler examples --'
\echo 'nothing here ran fractal_vectorizer_process_queue() on a schedule,'
\echo 'this demo called it manually once per section.'
\echo ''
\echo 'Clean up (fractal_vectorizers has no FK back to docs, so this'
\echo 'order matters -- delete the vectorizer row first, its queue rows'
\echo 'cascade automatically, then drop the table):'
\echo '  DELETE FROM fractal_vectorizers WHERE source_table = ''docs'';'
\echo '  DROP TABLE docs;'
\echo '================================================================'
