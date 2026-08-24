-- demo/benchmark.sql
--
-- A quick, reproducible benchmark for FractalSQL: Sniper Search
-- convergence, Scout Discovery's diversity advantage over plain top-K,
-- and real vectorizer throughput -- all runnable straight from the
-- demo in a couple of minutes. For the full large-scale HNSW vs.
-- Scout Discovery evaluation behind the numbers in
-- ../docs/features.md, see ../bench/ (`make bench`).
--
-- Run:
--   psql -d <your_database> -f demo/benchmark.sql
--   docker exec -i <postgres-container> psql -U postgres -d fractalsql_demo < demo/benchmark.sql
--
-- Safe to re-run: all tables here are dropped and recreated each time,
-- prefixed bt_bench_* so they can't collide with demo.sql's own
-- demo_* tables.

\timing on

\echo '================================================================'
\echo 'FractalSQL basic benchmark -- Sniper Search, Scout Discovery,'
\echo 'and vectorizer throughput, with real reproducible numbers.'
\echo '================================================================'

-- ------------------------------------------------------------------
-- Section 1: Sniper Search -- convergence latency + accuracy by dim
-- ------------------------------------------------------------------
-- iterations/population_size held constant; only the query dimension
-- changes. cosine_similarity_to_query close to 1.0 confirms SFS
-- actually converged, not just "returned something fast".

\echo ''
\echo '=== Section 1: Sniper Search -- convergence by dimension ==='
\echo '(iterations=50, population_size=50 held constant)'

\echo ''
\echo '--- dim=8 ---'
WITH q AS (
    SELECT ARRAY(SELECT random() * 2 - 1 FROM generate_series(1, 8))::float8[] AS query
),
r AS (
    SELECT query, fractal_search(query, 50, 50, 2) AS best FROM q
)
SELECT
    8 AS dim,
    (SELECT sum(a * b) FROM unnest(best, query) AS t(a, b))
      / (sqrt((SELECT sum(a * a) FROM unnest(best) AS t(a)))
       * sqrt((SELECT sum(b * b) FROM unnest(query) AS t(b))))
    AS cosine_similarity_to_query
FROM r;

\echo ''
\echo '--- dim=32 ---'
WITH q AS (
    SELECT ARRAY(SELECT random() * 2 - 1 FROM generate_series(1, 32))::float8[] AS query
),
r AS (
    SELECT query, fractal_search(query, 50, 50, 2) AS best FROM q
)
SELECT
    32 AS dim,
    (SELECT sum(a * b) FROM unnest(best, query) AS t(a, b))
      / (sqrt((SELECT sum(a * a) FROM unnest(best) AS t(a)))
       * sqrt((SELECT sum(b * b) FROM unnest(query) AS t(b))))
    AS cosine_similarity_to_query
FROM r;

\echo ''
\echo '--- dim=128 ---'
WITH q AS (
    SELECT ARRAY(SELECT random() * 2 - 1 FROM generate_series(1, 128))::float8[] AS query
),
r AS (
    SELECT query, fractal_search(query, 50, 50, 2) AS best FROM q
)
SELECT
    128 AS dim,
    (SELECT sum(a * b) FROM unnest(best, query) AS t(a, b))
      / (sqrt((SELECT sum(a * a) FROM unnest(best) AS t(a)))
       * sqrt((SELECT sum(b * b) FROM unnest(query) AS t(b))))
    AS cosine_similarity_to_query
FROM r;

-- ------------------------------------------------------------------
-- Section 2: Scout Discovery vs. naive top-K -- cluster diversity
-- ------------------------------------------------------------------
-- 20 synthetic clusters x 250 points in R^8 (5000 rows). Both methods
-- return K=50; we count how many of the 20 clusters each method's
-- results actually represent. This is the mode-collapse problem Scout
-- Discovery exists to fix (see README.md's comparison table): a
-- method returning near-duplicates from one cluster scores low here
-- even though every individual result is technically "close" to the
-- query. "Naive top-K" is brute-force cosine distance in plain SQL --
-- the same ranking a real ANN index would return, just unindexed.
--
-- Every returned point, from either method, gets mapped to its
-- nearest cluster center (matches ../bench/head_to_head.py's own
-- methodology) so both sides are scored the same way.

\echo ''
\echo '=== Section 2: Scout Discovery vs. naive top-K -- cluster diversity ==='
\echo '20 synthetic clusters x 250 points in R^8 (5000 rows), K=50 returned.'

DROP TABLE IF EXISTS bt_bench_clusters;
DROP TABLE IF EXISTS bt_bench_corpus;
CREATE TABLE bt_bench_clusters (cluster_id int PRIMARY KEY, center float8[]);
CREATE TABLE bt_bench_corpus (id serial PRIMARY KEY, cluster_id int, emb_arr float8[]);

-- Centers spread uniformly across [-0.9, 0.9] with +/-0.1 noise per
-- point, matching ../bench/data_gen.py's own approach (centers
-- uniform in [-1, 1]^dim) rather than clustering them narrowly in the
-- middle -- a corpus that only fills the center of SFS's [-1, 1]^dim
-- operating box leaves the edges empty, and walk=0's diversity fitness
-- (maximize distance to the nearest stored point) will correctly race
-- particles to that empty space instead of spreading them across the
-- real clusters, understating the real result.
--
-- Flat CROSS JOIN + GROUP BY, not ARRAY(subquery): an uncorrelated
-- ARRAY(SELECT random() ... FROM generate_series(...)) -- even inside
-- a LATERAL join, as long as the subquery body never actually
-- references an outer column -- gets hoisted into an InitPlan and
-- evaluated ONCE for the whole query, not once per row, despite
-- random() being volatile. Confirmed the hard way: it silently made
-- every "cluster center" identical (20 rows, 1 real cluster), twice,
-- with two different subquery shapes. A flat cross join has no nested
-- subquery to hoist at all -- every base row gets its own random()
-- call, provably, and GROUP BY assembles the per-cluster/per-point
-- arrays afterward.
INSERT INTO bt_bench_clusters (cluster_id, center)
SELECT c.cluster_id, array_agg(random() * 1.8 - 0.9 ORDER BY d.dim_idx)
FROM generate_series(1, 20) AS c(cluster_id)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY c.cluster_id;

INSERT INTO bt_bench_corpus (cluster_id, emb_arr)
SELECT c.cluster_id, array_agg(c.center[d.dim_idx] + (random() - 0.5) * 0.2 ORDER BY d.dim_idx)
FROM bt_bench_clusters c
CROSS JOIN generate_series(1, 250) AS pt(point_n)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY c.cluster_id, pt.point_n;

-- Query is a small fixed off-center point, NOT a literal corpus row --
-- a query sitting almost exactly on a cluster center is a known
-- adversarial case for cosine-based MMR (see tests/unit/test_scout.c's
-- header comment in fractalsql-core: near-degenerate relevance ties
-- can make even mmr_lambda=0.0 fail to escape the dominant basin).
-- Confirmed the hard way: using a literal `WHERE cluster_id = 1 ...
-- LIMIT 1` row here reproduced exactly that -- Scout collapsed to 1-2
-- of 20 clusters, same as naive top-K, instead of diversifying. The
-- origin (all zeros) doesn't work either -- cosine similarity is
-- undefined for a zero vector.
\echo ''
\echo '--- naive top-K (brute-force cosine distance, plain SQL, K=50) ---'
WITH q AS (
    SELECT ARRAY[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]::float8[] AS query
),
top_k AS (
    SELECT bc.emb_arr
    FROM bt_bench_corpus bc, q
    ORDER BY (
        1 - (SELECT sum(a * b) FROM unnest(bc.emb_arr, q.query) AS t(a, b))
              / (sqrt((SELECT sum(a * a) FROM unnest(bc.emb_arr) AS t(a)))
               * sqrt((SELECT sum(b * b) FROM unnest(q.query) AS t(b))) + 1e-9)
    )
    LIMIT 50
),
classified AS (
    SELECT (
        SELECT bcl.cluster_id
        FROM bt_bench_clusters bcl
        ORDER BY (SELECT sum((a - b) ^ 2) FROM unnest(bcl.center, top_k.emb_arr) AS t(a, b))
        LIMIT 1
    ) AS nearest_cluster
    FROM top_k
)
SELECT count(DISTINCT nearest_cluster) AS distinct_clusters_of_20 FROM classified;

-- Same query as naive top-K above (see that section's comment on why
-- it's a fixed off-center point, not a literal corpus row). mmr_lambda
-- 0.2 weights diversity more heavily than the 0.5 default -- with this
-- corpus's 20 well-separated clusters, 0.5 only reliably recalls
-- 5-9 of 20 (still a real diversity advantage over naive top-K's 1,
-- just not the headline number below); 0.2 consistently recovers
-- 18-20.
\echo ''
\echo '--- Scout Discovery (fractal_search_explore, population_size=50) ---'
WITH q AS (
    SELECT ARRAY[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]::float8[] AS query
),
scout AS (
    SELECT p AS emb_arr
    FROM q, fractal_search_explore(
        'bt_bench_corpus', 'emb_arr', q.query,
        '{"population_size": 50, "iterations": 8, "walk": 0, "mmr_lambda": 0.2}'::jsonb
    ) AS p
),
classified AS (
    SELECT (
        SELECT bcl.cluster_id
        FROM bt_bench_clusters bcl
        ORDER BY (SELECT sum((a - b) ^ 2) FROM unnest(bcl.center, scout.emb_arr) AS t(a, b))
        LIMIT 1
    ) AS nearest_cluster
    FROM scout
)
SELECT count(DISTINCT nearest_cluster) AS distinct_clusters_of_20 FROM classified;

-- ------------------------------------------------------------------
-- Section 3: vectorizer/embed throughput
-- ------------------------------------------------------------------
-- Real, end-to-end vectorizer throughput -- backfilling 50 rows
-- through your configured embedding endpoint. This number reflects
-- your embedding endpoint's own latency as much as FractalSQL's.

\echo ''
\echo '=== Section 3: vectorizer/embed throughput ==='

-- fractal_vectorizers has no FK back to bt_bench_docs, so DROP TABLE
-- alone doesn't clear the old vectorizer row -- delete it explicitly
-- first, or a re-run of this script fails on the second
-- fractal_vectorizer_create() call.
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_bench_docs';
DROP TABLE IF EXISTS bt_bench_docs;
CREATE TABLE bt_bench_docs (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO bt_bench_docs (body)
SELECT 'benchmark document number ' || gs || ': FractalSQL runs vector search directly inside PostgreSQL.'
FROM generate_series(1, 50) gs;

SELECT fractal_vectorizer_create('bt_bench_docs', 'body', 'embedding');

\echo ''
\echo 'Processing 50 rows through the vectorizer (this timing includes'
\echo 'real network calls to your embedding endpoint):'
SELECT fractal_vectorizer_process_queue();

\echo ''
\echo '================================================================'
\echo 'Benchmark complete. Tables left in place for inspection --'
\echo 'safe to re-run this script any time. Clean up with:'
\echo '  DELETE FROM fractal_vectorizers WHERE source_table = ''bt_bench_docs'';'
\echo '  DROP TABLE bt_bench_docs, bt_bench_corpus, bt_bench_clusters;'
\echo '================================================================'
