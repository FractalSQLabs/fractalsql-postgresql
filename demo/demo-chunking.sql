-- demo/demo-chunking.sql
-- Long text, chunked: split documents into passages, embed the passages, and answer a question from the right passages.
--
--   1. fractal_chunk_text on its own: how a text is cut (no model needed).
--   2. A vectorizer with chunk_size: the chunks go into a table and are embedded.
--   3. A question answered from one document only (meta_filter on parent_id), with the passages it was drawn from.
--   4. The same table through an index: fractal_index_ensure, then fractalsql.agent_use_index.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured (see demo/demo-vectorizer.sql for the local-Ollama example).
-- Confirm before running:   SELECT array_length(fractal_embed('hello world'), 1);
-- Safe to re-run: the demo tables are dropped and recreated.

\echo === 1. How fractal_chunk_text cuts a text ===
\echo --- paragraphs are packed into a chunk while it stays within the size ---
SELECT e->>'no' AS no, e->>'start' AS start, e->>'end' AS "end", e->>'text' AS chunk
  FROM jsonb_array_elements(fractal_chunk_text(E'First paragraph here.\n\nSecond one is short.\n\nThird paragraph is a bit longer than the others are.', 40, 0)) e;
\echo --- sentences, with a long sentence cut into overlapping pieces ---
SELECT e->>'no' AS no, e->>'text' AS chunk
  FROM jsonb_array_elements(fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence')) e;

\echo
\echo === 2. A vectorizer that chunks ===
DROP TABLE IF EXISTS chunk_demo_docs_chunks;
DROP TABLE IF EXISTS chunk_demo_docs CASCADE;
CREATE TABLE chunk_demo_docs (id int PRIMARY KEY, title text, body text);
INSERT INTO chunk_demo_docs VALUES
 (1, 'Heartbeat runbook',
  E'A node that stops heartbeating is first marked suspect. The coordinator waits for three missed beats before it acts.\n\nIf the node is still silent, drain its work to the other nodes and open an incident. Do not restart it until the drain has finished, or its in-flight work is lost.\n\nAfter the restart, watch the node for ten minutes. If it misses another beat, replace the hardware.'),
 (2, 'Backup runbook',
  E'Backups run nightly at two in the morning. Each backup is verified by restoring it into a scratch database and comparing row counts.\n\nA failed verification pages the on-call engineer. Never delete the previous good backup until the next one has verified.'),
 (3, 'Billing runbook',
  'Invoices are generated on the first of the month. A customer who disputes an invoice gets it frozen until the dispute is closed.');
SELECT fractal_vectorizer_create('chunk_demo_docs', 'body', 'embedding',
         '{"chunk_size": 220, "chunk_overlap": 20, "chunk_mode": "paragraph"}') AS vectorizer_id;
SELECT count(*) AS chunks_created FROM chunk_demo_docs_chunks;
SELECT fractal_vectorizer_process_queue(50) AS chunks_embedded;
SELECT parent_id, chunk_no, length(chunk_text) AS chars, array_length(embedding, 1) AS dims
  FROM chunk_demo_docs_chunks ORDER BY parent_id, chunk_no;

\echo
\echo === 3. A question answered from one document, with the passages it used ===
\echo --- the whole corpus ---
SELECT a.answer, a.source_row_ids, a.used_index
  FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding') a;
\echo --- only the passages of document 1 (meta_filter) ---
SELECT a.answer, a.source_row_ids
  FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}') a;
\echo The passages those row ids name:
SELECT c.id AS row_id, c.parent_id, c.chunk_no, substr(c.chunk_text, 1, 70) || '...' AS passage
  FROM chunk_demo_docs_chunks c
 WHERE c.id::text IN (SELECT unnest(a.source_row_ids) FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}') a);

\echo
\echo === 4. The same table through an index ===
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding', '{"vector_format": "FP32"}') AS ensured;
\echo Calling it again changes nothing:
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding') AS ensured_again;
SET fractalsql.agent_use_index = on;
SELECT a.used_index, a.source_row_ids
  FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding') a;
SET fractalsql.agent_use_index = off;

\echo
\echo Tables left in place for inspection. Clean up with:
\echo '  SELECT fractal_index_drop(''chunk_demo_docs_chunks_embedding''); DROP TABLE chunk_demo_docs_chunks; DROP TABLE chunk_demo_docs CASCADE;'
