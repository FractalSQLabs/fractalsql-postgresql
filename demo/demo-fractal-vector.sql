-- demo/demo-fractal-vector.sql
-- Runnable walkthrough of the fractal_vector(n) native type: typmod
-- dimension enforcement, the vectorizer writing into a typed column,
-- fractal_search_trajectory's fractal_vector overload, and a storage
-- comparison against an equivalent float8[] table.
-- See ../docs/vectorizer-setup.md's "Storage: float8[] vs
-- fractal_vector(n)" section for the full writeup this demo walks
-- through interactively.
--
-- Prerequisites: extension installed, reasoning AND embedding
-- configured -- same setup as demo/demo-vectorizer.sql (see that
-- file's header for the local-Ollama example). Confirm before running:
--   SELECT fractal_embed('reply with a short confirmation that this connection works');
--
-- Safe to re-run: the schema is dropped and recreated at the top.

\timing on
\pset pager off
\encoding UTF8

-- Re-runnable: tear down a prior run's vectorizer config + queue (the config
-- outlives the table in v1 -- there is no fractal_vectorizer_drop), then drop
-- the demo tables. The unconditional DELETEs are no-ops on a first run.
DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'docs_fv');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'docs_fv');
DELETE FROM fractal_vectorizers WHERE source_table = 'docs_fv';
DROP TABLE IF EXISTS docs_fv;
DROP TABLE IF EXISTS docs_fv_float8;

-- Create docs_fv with the typmod set to the configured embedding model's
-- actual output dimension, so the demo runs end-to-end on whatever model is
-- configured (768 for nomic-embed-text, 1536 for OpenAI text-embedding-3-small,
-- ...). The typmod is what makes a dimension mismatch a hard error (Section 3).
DO $$
DECLARE d int;
BEGIN
    d := array_length(fractal_embed('fractalsql dimension probe'), 1);
    IF d IS NULL THEN
        RAISE EXCEPTION 'fractal-vector-demo: fractal_embed() returned no dimension -- is the embedding endpoint configured?';
    END IF;
    EXECUTE format('CREATE TABLE docs_fv (id serial PRIMARY KEY, body text NOT NULL, embedding fractal_vector(%s))', d);
END $$;
COMMENT ON TABLE docs_fv IS 'Same shape as demo/demo-vectorizer.sql''s docs table, '
    'but embedding is fractal_vector(<model dim>) instead of float8[]';

\echo '=== Section 1: dimension enforcement is automatic ==='
\echo 'fractal_vectorizer_create() and process_queue() below need ZERO changes'
\echo 'from the float8[] version in demo-vectorizer.sql -- the column type alone'
\echo 'is what makes a dimension mismatch a hard error instead of silent corruption.'
INSERT INTO docs_fv (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside PostgreSQL.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.');

SELECT id, body FROM docs_fv ORDER BY id;

\echo ''
\echo '=== Section 2: create the vectorizer -- exactly like the float8[] demo ==='
SELECT fractal_vectorizer_create('docs_fv', 'body', 'embedding');
SELECT fractal_vectorizer_process_queue();

SELECT id, body, embedding IS NOT NULL AS has_embedding,
       fractal_vector_dims(embedding) AS dim
FROM docs_fv
ORDER BY id;

\echo ''
\echo '=== Section 3: the hard-fail, live ==='
\echo 'A dimension mismatch on this column raises immediately -- no separate'
\echo 'validation step, no silent truncation. Wrapped in a DO block so this'
\echo 'demo keeps running after the intentional error.'
DO $$
BEGIN
    INSERT INTO docs_fv (body, embedding) VALUES ('deliberately wrong dimension', '[0.1,0.2]');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught as expected: %', SQLERRM;
END $$;

\echo ''
\echo '=== Section 4: fractal_search_trajectory over a fractal_vector column ==='
\echo 'Same function as the float8[] demo, direct varlena reads instead of'
\echo 'array unpacking -- see bench/vector_type_head_to_head.py for the'
\echo 'latency comparison at real scale.'
SELECT * FROM fractal_search_trajectory(
    'docs_fv', 'embedding',
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1),
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1),
    2
);

\echo ''
\echo '=== Section 5: fractal_vector operators and functions ==='
\echo 'Exercise the public vector-type surface the other demos do not reach:'
\echo 'distance operators (<->, <=>, <#>), arithmetic (+, -, *), l2_squared,'
\echo 'cosine_similarity, norm, normalize, and the float8[] cast.'
SELECT
    a.embedding <-> b.embedding AS l2_distance_op,
    a.embedding <=> b.embedding AS cosine_distance_op,
    a.embedding <#> b.embedding AS neg_inner_product_op,
    fractal_vector_l2_squared(a.embedding, b.embedding)        AS l2_squared,
    fractal_vector_cosine_similarity(a.embedding, b.embedding) AS cosine_similarity,
    fractal_vector_norm(a.embedding)                           AS norm_a,
    fractal_vector_norm(b.embedding)                           AS norm_b
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- Arithmetic operators (+, -, scalar *) and normalize return fractal_vector;
-- fractal_vector_dims confirms the element count is preserved.
SELECT
    fractal_vector_dims(a.embedding + b.embedding)              AS add_dims,
    fractal_vector_dims(a.embedding - b.embedding)              AS sub_dims,
    fractal_vector_dims(a.embedding * 2.0)                     AS scale_dims,
    fractal_vector_dims(fractal_vector_normalize(a.embedding)) AS normalize_dims
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- The float8[] cast (implicit, via fractal_vector_to_float8_array) and back
-- via fractal_vector_from_float8_array. pg_typeof confirms both directions.
SELECT
    pg_typeof(a.embedding::float8[])                                AS cast_to_float8_type,
    pg_typeof(fractal_vector_from_float8_array(a.embedding::float8[])) AS cast_back_type
FROM docs_fv a
WHERE a.id = 1 AND a.embedding IS NOT NULL;

\echo ''
\echo '=== Section 6: storage comparison ==='
\echo 'Same values, both column types, at the configured model''s embedding width.'
CREATE TABLE docs_fv_float8 (id serial PRIMARY KEY, embedding float8[]);
INSERT INTO docs_fv_float8 (embedding)
    SELECT embedding::float8[] FROM docs_fv WHERE embedding IS NOT NULL;

SELECT
    (SELECT pg_column_size(embedding) FROM docs_fv WHERE embedding IS NOT NULL LIMIT 1)
        AS fractal_vector_bytes,
    (SELECT pg_column_size(embedding) FROM docs_fv_float8 LIMIT 1)
        AS float8_array_bytes;
\echo 'Expect fractal_vector (uncompressed float4, ~dim*4 bytes + overhead) to'
\echo 'be roughly half the float8[] size (raw float8, ~dim*8 bytes + array'
\echo 'overhead), or less if TOAST compression kicks in on the float8[] side'
\echo '-- see docs/vectorizer-setup.md for why the realized ratio varies.'

\echo ''
\echo '================================================================'
\echo 'Next: docs/vectorizer-setup.md''s "Storage: float8[] vs'
\echo 'fractal_vector(n)" section, and bench/vector_type_head_to_head.py'
\echo 'for the same comparison at 100k-row scale.'
\echo ''
\echo 'This demo is re-runnable: the vectorizer config + queue + tables are torn'
\echo 'down at the top of the file, so it can be re-run without manual cleanup.'
\echo '================================================================'
\echo '================================================================'
