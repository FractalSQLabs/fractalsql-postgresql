-- demo/demo-fractal-index.sql
-- Walkthrough of the IVF index: fractal_index_create / _info (status and advice) / _list / _refresh / _rebuild / _drop, the indexed fractal_search and its ids option.
-- Self-contained: 2,000 synthetic 16-dimensional vectors in 20 clusters, no endpoint or plugin needed.
--
-- fractal_search(table, column, query, k [, options]) probes a few IVF cells instead of scanning every row, then VERIFIES
-- every candidate against the stored vectors, so the distances it returns are exact cosine distances, never approximations.
-- fractal_search with {"use_index":false} (or without an index) is the exact brute-force scan. Rows are named by an integer
-- key column (id by default), not a ctid, because a ctid moves on UPDATE and VACUUM.
-- (The scalar fractal_search(float8[], ...) of version 1.0 is now fractal_sfs_converge.)
--
-- Re-runnable: the table and the index are dropped and recreated at the top.

\echo === 1. A table of vectors (2,000 rows, 20 clusters) ===
DROP TABLE IF EXISTS idx_demo CASCADE;
CREATE TABLE idx_demo(id int PRIMARY KEY, label text, embedding float8[]);
INSERT INTO idx_demo
SELECT i, 'row ' || i,
       array(SELECT round(((i % 20) * (0.07 * (j % 5 - 2)) + ((j * 7 + i * 13) % 97) / 400.0)::numeric, 4)::float8
               FROM generate_series(1, 16) j)
  FROM generate_series(1, 2000) i;
SELECT count(*) AS rows, array_length(embedding, 1) AS dim FROM idx_demo GROUP BY 2;

\echo
\echo === 2. Build an index (FP32 here so the demo recall is exact; INT8 is the default and 4x-8x smaller) ===
\echo The build samples rows as queries, compares the index with exact search at nprobe 1, 2, 4 ... and stores the
\echo smallest nprobe whose 95% lower bound reaches target_recall as this index's default.
SELECT fractal_index_create('idx_demo', 'embedding',
       '{"vector_format":"FP32","name":"idx_demo_ix","target_recall":0.95,"calibration_samples":100}');

\echo
\echo === 3. fractal_index_info: format, size, staleness, calibration, last search ===
SELECT i->>'format' AS format, i->>'nlist' AS cells, i->>'rows_indexed' AS rows_indexed, i->>'stale' AS stale,
       i->>'nprobe_default' AS default_nprobe, i->'calibration'->>'reaches_target' AS reaches_target
  FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;

\echo The verdict: status is ready / stale / degraded / empty / orphaned, and advice says what to do about it (nothing yet):
SELECT i->>'status' AS status, i->'advice' AS advice FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;
\echo The catalog, one row per index:
SELECT name, table_name, vector_col, format, rows, status, generation FROM fractal_index_list();

\echo
\echo === 4. Search: the index versus the exact scan ===
\echo Same query, same distances (the index verifies every candidate), far fewer rows scanned:
SELECT * FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 5);
SELECT * FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 5, '{"use_index":false}');
SELECT i->'last_search' AS last_search FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;

\echo
\echo === 5. Rows added after the build are still found (the delta is scanned exactly) ===
INSERT INTO idx_demo VALUES (9001, 'new row', (SELECT embedding FROM idx_demo WHERE id = 42));
INSERT INTO idx_demo SELECT 9100 + id, 'late copy ' || id, embedding FROM idx_demo WHERE id BETWEEN 100 AND 199;
SELECT doc_id, distance FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 3);
SELECT i->>'has_delta' AS has_delta, i->>'stale' AS stale FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;
\echo The verdict now says what changed and what to do (the added rows are scanned exactly on every search until you refresh):
SELECT i->>'status' AS status, i->>'rows_added_since_build' AS added, i->'advice' AS advice FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;

\echo
\echo === 6. Refresh: fold the added rows into the cells, with no retraining ===
SELECT r->>'added' AS added, r->>'rows' AS rows, r->>'generation' AS generation FROM (SELECT fractal_index_refresh('idx_demo_ix') AS r) s;
SELECT i->>'status' AS status, i->>'has_delta' AS has_delta, i->>'rows_indexed' AS rows_indexed, i->'advice' AS advice FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;
\echo The late arrival is now served from the cells, not by the exact delta scan:
SELECT doc_id, distance FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 3);

\echo
\echo === 6b. One call that keeps an index fit to use: fractal_index_ensure ===
\echo It looks at the index on a table and column and does only what is needed (created, refreshed, rebuilt or unchanged), so it suits a setup script or a scheduled job:
SELECT fractal_index_ensure('idx_demo', 'embedding') AS ensured;

\echo
\echo === 7. Index plus filter in one call: the ids option ===
\echo Pick the rows with ordinary SQL (here: every tenth row), pass their keys, and search only those:
SELECT doc_id, round(distance::numeric, 6) AS distance
  FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 4,
       (SELECT jsonb_build_object('ids', jsonb_agg(id)) FROM idx_demo WHERE id % 10 = 2));
\echo Every row returned ends in 2, so the filter held; row 42 is in the set and is its own nearest neighbour.

\echo
\echo === 8. A deleted row is never returned ===
DELETE FROM idx_demo WHERE id = 42;
SELECT doc_id, distance FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 9001), 3);

\echo
\echo === 9. Rebuild folds the changes in as a new generation (readers never see a partial index) ===
SELECT fractal_index_rebuild('idx_demo_ix')->>'generation' AS generation;
SELECT i->>'rows_indexed' AS rows_indexed, i->>'stale' AS stale, i->>'has_delta' AS has_delta FROM (SELECT fractal_index_info('idx_demo_ix') AS i) s;

\echo
\echo === 10. Drop the index: fractal_search falls back to the exact scan ===
SELECT fractal_index_drop('idx_demo_ix');
SELECT count(*) AS rows_returned FROM fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 9001), 5);
DROP TABLE idx_demo;
