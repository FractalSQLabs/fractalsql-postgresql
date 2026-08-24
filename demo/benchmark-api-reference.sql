-- demo/benchmark-api-reference.sql
--
-- A `\timing on` pass over EVERY callable function in
-- sql/fractalsql--1.0.sql (34 functions: 9 core v1.0 + the 4-function
-- vectorizer group (create, process_queue, pause, resume) + 21 v2.x
-- additions), grouped the same way that file groups them. Distinct
-- from demo/benchmark.sql, which stays scoped to
-- its own narrower Sniper/Scout/vectorizer comparison (see that file's
-- own header comment) -- this one's job is coverage, not a head-to-head
-- comparison.
--
-- Fixtures are deliberately small and reused across sections -- this is
-- a correctness-plus-latency smoke pass over the whole API surface, not
-- a scale benchmark (see ../bench/ for the real HNSW-vs-Scout scale
-- evaluation behind docs/features.md's numbers). Reasoning-dependent
-- calls (fractal_reason, fractal_text_to_sql, fractal_embed) are
-- wrapped the same way demo/demo-business-intelligence.sql's
-- bi_safe_t2s() guards fractal_text_to_sql, so a missing/misconfigured
-- reasoning endpoint degrades that one row instead of aborting the rest
-- of the benchmark.
--
-- Run:
--   psql -d <your_database> -f demo/benchmark-api-reference.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/benchmark-api-reference.sql
--
-- Safe to re-run: bmk_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.11);

-- Takes the risky call as a TEXT SQL expression and EXECUTEs it inside
-- this function's own body, not as a pre-evaluated argument -- an
-- ordinary `bmk_safe(label, fractal_reason(...))` call would evaluate
-- fractal_reason() in the OUTER query before bmk_safe ever runs, so
-- its exception handler would never see the error. Same reasoning as
-- demo/demo-business-intelligence.sql's bi_safe_t2s(), which calls
-- fractal_text_to_sql() INSIDE its own function body for exactly this
-- reason -- this is the generic form of that same pattern.
CREATE OR REPLACE FUNCTION bmk_safe_call(label text, sql_expr text) RETURNS text AS $$
DECLARE
    result text;
BEGIN
    EXECUTE format('SELECT (%s)::text', sql_expr) INTO result;
    RETURN result;
EXCEPTION WHEN OTHERS THEN
    RETURN '-- ' || label || ' failed: ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

\echo '================================================================'
\echo 'FractalSQL full-API-reference benchmark -- one pass over all 34'
\echo 'callable functions, grouped by category.'
\echo '================================================================'

-- ------------------------------------------------------------------
-- 0. Meta (2 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Meta: fractal_edition, fractal_version ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Search (3 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Search: fractal_search, fractal_search_debug ==='

DROP TABLE IF EXISTS bmk_corpus;
CREATE TABLE bmk_corpus (id serial PRIMARY KEY, emb_arr float8[]);
INSERT INTO bmk_corpus (emb_arr)
SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1, random()*2-1,
             random()*2-1, random()*2-1, random()*2-1, random()*2-1]::float8[]
FROM generate_series(1, 100);

SELECT fractal_search(ARRAY[0.6,0.8,0,0,0,0,0,0]::float8[], iterations => 30);
SELECT fractal_search_debug(ARRAY[0.6,0.8,0,0,0,0,0,0]::float8[], iterations => 10) -> 'best_fit';

\echo ''
\echo '=== Search: fractal_search_explore ==='
SELECT count(*) AS scout_population FROM fractal_search_explore(
    'bmk_corpus', 'emb_arr', ARRAY[0,0,0,0,0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 6, "walk": 0}'::jsonb
) AS p;

-- ------------------------------------------------------------------
-- 2. Reasoning / text-to-SQL / embedding (4 functions, guarded)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Reasoning: fractal_reason, fractal_schema_context, fractal_text_to_sql, fractal_embed ==='

SELECT bmk_safe_call('fractal_reason',
    $$fractal_reason('reply with a one-word confirmation', '{}')$$) AS reason_result;
SELECT bmk_safe_call('fractal_schema_context',
    $$left(fractal_schema_context(ARRAY['bmk_corpus'], NULL), 80)$$) AS schema_context_result;
SELECT bmk_safe_call('fractal_text_to_sql',
    $$fractal_text_to_sql('how many rows are in bmk_corpus?', ARRAY['bmk_corpus'])$$) AS text_to_sql_result;
SELECT bmk_safe_call('fractal_embed',
    $$array_length(fractal_embed('a short benchmark sentence'), 1)$$) AS embed_dim;

-- ------------------------------------------------------------------
-- 3. Vectorizer (4 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Vectorizer: fractal_vectorizer_create, fractal_vectorizer_process_queue,'
\echo 'fractal_vectorizer_pause, fractal_vectorizer_resume ==='

DELETE FROM fractal_vectorizers WHERE source_table = 'bmk_docs';
DROP TABLE IF EXISTS bmk_docs;
CREATE TABLE bmk_docs (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO bmk_docs (body) SELECT 'benchmark document ' || gs FROM generate_series(1, 5) gs;
SELECT fractal_vectorizer_create('bmk_docs', 'body', 'embedding') AS bmk_vzid \gset
SELECT fractal_vectorizer_process_queue();
-- pause: further writes to bmk_docs stop queueing, process_queue() skips
-- this vectorizer's remaining pending rows -- resume immediately after so
-- the rest of this script (and a re-run) sees normal behavior again.
SELECT fractal_vectorizer_pause(:bmk_vzid);
SELECT fractal_vectorizer_resume(:bmk_vzid);

-- ------------------------------------------------------------------
-- 4. Diversify / Repulsion + Feedback (7 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Diversify/Repulsion + Feedback: enable, set_params, detect_collapse,'
\echo 'explain_result, feedback_report, isolate_background, disable ==='

SELECT fractal_diversify_enable();
SELECT fractal_diversify_set_params(window_n => 5, repulsion_sigma => 0.3, repulsion_weight => 0.5);
SELECT t.doc_id FROM generate_series(1, 6) g
CROSS JOIN LATERAL fractal_search_telemetry('bmk_corpus', 'emb_arr', ARRAY[0,0,0,0,0,0,0,0]::float8[], 3) t;
SELECT fractal_detect_collapse() AS dq;
SELECT fractal_explain_result() AS diagnostics;
SELECT fractal_feedback_report(1, 'positive', 4000);
SELECT fractal_isolate_background(2);
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. Fractal dimension analysis (3 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Dimension analysis: fractal_dimension_dfa, _boxcount, _drift ==='

SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum((random()-0.5)*0.05) OVER (ORDER BY t) AS cum FROM generate_series(1, 200) t
    ) c)
) AS dfa_alpha;

-- 20x20 jittered grid -- see demo/demo-vertical-sovereign-edge-ai.sql's own
-- comment on why box-counting needs a space-filling, not scattered,
-- fixture to find >= 3 valid eps-octaves.
SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r
       CROSS JOIN generate_series(0, 19) c
       CROSS JOIN LATERAL unnest(ARRAY[r + (random()-0.5)*0.3, c + (random()-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)),
    2
) AS boxcount_dimension;

SELECT fractal_dimension_drift(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum((random()-0.5)*0.05) OVER (ORDER BY t) AS cum FROM generate_series(1, 100) t
    ) c),
    32
) AS drift_report;

-- ------------------------------------------------------------------
-- 6. Portfolio optimization (1 function)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Portfolio: fractal_optimize_portfolio ==='

SELECT fractal_optimize_portfolio(
    ARRAY[0.05,0.08,0.03,0.12,0.07,0.01]::float8[],
    ARRAY[0.02,0,0,0,0,0, 0,0.03,0,0,0,0, 0,0,0.04,0,0,0,
          0,0,0,0.05,0,0, 0,0,0,0,0.06,0, 0,0,0,0,0,0.07]::float8[],
    2, 42
) AS allocation;

-- ------------------------------------------------------------------
-- 7. Domain-specific geometry (4 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Domain geometry: fractal_vascular_network, _cortical_folding,'
\echo '_nerve_plexus_metric, fractal_morphological_complexity ==='

-- 28-node chain + 2 branch leaves -- see demo/demo-vertical-medtech-clinical.sql
-- for why this scale (not a handful of nodes) is needed for the
-- internal box-counting step to succeed.
SELECT fractal_vascular_network(
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 27) i
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.0, 0.0]) WITH ORDINALITY AS u(v, ord))
    || ARRAY[10, 1, 0, 10, 0, 1]::float8[],
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 26) i
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
    || ARRAY[10, 28, 10, 29]::int4[],
    (SELECT array_agg(1.02) FROM generate_series(0, 28))
) AS vascular;

-- Unit cube surface mesh (8 vertices, 12 faces) -- known-answer
-- reference (GI ~1.0), same fixture demo/demo-vertical-medtech-clinical.sql uses.
SELECT fractal_cortical_folding(
    ARRAY[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]::float8[],
    ARRAY[0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
          3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5]::int4[]
) AS cortical;

SELECT fractal_nerve_plexus_metric(
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 79) i
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.05 * sin(i::float8)]) WITH ORDINALITY AS u(v, ord)),
    2,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 78) i
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
) AS nerve;

SELECT fractal_morphological_complexity(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r
       CROSS JOIN generate_series(0, 19) c
       CROSS JOIN LATERAL unnest(ARRAY[r + (random()-0.5)*0.3, c + (random()-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)),
    2
) AS morphology;

-- ------------------------------------------------------------------
-- 8. Named feature store (2 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Feature store: fractal_store_morphology, fractal_mine_topology_negatives ==='

SELECT fractal_store_morphology(gs, ARRAY[random(), random(), random()]::float8[])
FROM generate_series(1, 10) gs;
SELECT doc_id, distance FROM fractal_mine_topology_negatives(ARRAY[0.5,0.5,0.5]::float8[], 3);

-- ------------------------------------------------------------------
-- 9. Table-backed telemetry search family (4 functions)
-- ------------------------------------------------------------------
\echo ''
\echo '=== Telemetry search: fractal_search_telemetry, _hybrid_clinical_search,'
\echo '_search_trajectory, fractal_cross_modal_search ==='

SELECT doc_id, distance FROM fractal_search_telemetry(
    'bmk_corpus', 'emb_arr', ARRAY[0,0,0,0,0,0,0,0]::float8[], 3
);

SELECT doc_id, distance FROM fractal_hybrid_clinical_search(
    'bmk_corpus', 'emb_arr', ARRAY[0,0,0,0,0,0,0,0]::float8[],
    (SELECT array_agg(id - 1) FROM bmk_corpus WHERE id <= 20), 3
);

SELECT doc_id, distance FROM fractal_search_trajectory(
    'bmk_corpus', 'emb_arr',
    ARRAY[0,0,0,0,0,0,0,0]::float8[], ARRAY[0.5,0.5,0,0,0,0,0,0]::float8[], 3
);

DROP TABLE IF EXISTS bmk_modal;
CREATE TABLE bmk_modal (id serial PRIMARY KEY, combined_vec float8[]);
INSERT INTO bmk_modal (combined_vec)
SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1, random()*2-1]::float8[]
FROM generate_series(1, 20);
SELECT doc_id, distance FROM fractal_cross_modal_search(
    'bmk_modal', 'combined_vec',
    ARRAY[0.5,0.5]::float8[], ARRAY[-0.5,-0.5]::float8[], 0.5, 3
);

\echo ''
\echo '================================================================'
\echo 'Benchmark complete -- 34/34 functions exercised. Tables left in'
\echo 'place for inspection. Clean up with:'
\echo '  DELETE FROM fractal_vectorizers WHERE source_table = ''bmk_docs'';'
\echo '  DROP TABLE bmk_corpus, bmk_docs, bmk_modal;'
\echo '  DELETE FROM fractalsql_feature_store WHERE doc_id BETWEEN 1 AND 10;'
\echo '  DROP FUNCTION bmk_safe_call(text, text);'
\echo '================================================================'
