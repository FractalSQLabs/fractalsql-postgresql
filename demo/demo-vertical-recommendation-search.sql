-- demo/demo-vertical-recommendation-search.sql
--
-- Industry vertical: Advanced Recommendation, Search & Discovery Engines.
--
-- A product/content catalog for diverse "you might also like" discovery,
-- a table-backed top-k telemetry search, the full stateful-diversity
-- loop (enable Diversify, search, report negative feedback on a result,
-- re-search, confirm it's avoided -- the real differentiator over plain
-- top-K or MMR: it's stateful and feedback-learning, not a one-shot
-- re-ranking heuristic), and cross-modal search (content + behavior
-- vectors, weighted).
--
-- Prerequisites: extension installed (sections 0-5 need nothing else).
-- Section 6 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-recommendation-search.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-recommendation-search.sql
--
-- Safe to re-run: vrs_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.83);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 300-item catalog, 6 genre clusters x 50 items in R^8. Centers
-- spread uniformly across [-0.9, 0.9] with per-item jitter -- matching
-- demo/benchmark.sql's own approach (narrow clustering in the box
-- center would silently understate Scout's real diversity result, per
-- that file's own load-bearing comment). Flat CROSS JOIN + GROUP BY,
-- not ARRAY(subquery) -- see demo/demo-vertical-quant-finance.sql's comment
-- on why an uncorrelated ARRAY(SELECT random() ...) silently produces
-- identical rows via InitPlan hoisting.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 300-item catalog: 6 genre clusters in R^8 ==='

DROP TABLE IF EXISTS vrs_genres;
DROP TABLE IF EXISTS vrs_catalog;
-- Both fractal_vector(8), not float8[] -- fixed-width genre-centroid
-- and catalog-item embeddings, same dimension-safety argument as the
-- other updated verticals. INSERTs below are otherwise unchanged
-- (still float8[]-typed expressions), relying on the assignment cast.
CREATE TABLE vrs_genres (genre_id int PRIMARY KEY, name text, center fractal_vector(8));
CREATE TABLE vrs_catalog (id serial PRIMARY KEY, genre_id int, title text, emb_arr fractal_vector(8));

INSERT INTO vrs_genres (genre_id, name, center)
SELECT g, name, array_agg(random() * 1.8 - 0.9 ORDER BY d.dim_idx)
FROM (VALUES (1,'sci-fi'),(2,'documentary'),(3,'true-crime'),
             (4,'comedy'),(5,'strategy-games'),(6,'cooking')) AS gv(g, name)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY g, name;

-- fractal_vector has no [n] subscript operator (unlike float8[]) --
-- cast to float8[] for the per-dimension jitter lookup, same pattern
-- as demo-vertical-maritime-defense.sql's vessel-7 UPDATE.
INSERT INTO vrs_catalog (genre_id, title, emb_arr)
SELECT gc.genre_id, gc.name || '-item-' || pt.item_n,
       array_agg((gc.center::float8[])[d.dim_idx] + (random() - 0.5) * 0.25 ORDER BY d.dim_idx)
FROM vrs_genres gc
CROSS JOIN generate_series(1, 50) AS pt(item_n)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY gc.genre_id, gc.name, pt.item_n;

SELECT count(*) AS items, count(DISTINCT genre_id) AS genres FROM vrs_catalog;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse "you might also like" -- a spread across
-- distinct genre basins, not K near-duplicates from one genre.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_search_explore: diverse recommendations ==='
\echo '--- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---'

-- Blueprint (raw primitive): returns a diverse spread of representative
-- catalog embeddings across distinct genre basins (not K near-duplicates
-- from one genre).
-- SELECT p FROM fractal_search_explore(
--     'vrs_catalog', 'emb_arr', ARRAY[0,0,0,0,0,0,0,0]::float8[],
--     '{"population_size": 6, "iterations": 8, "walk": 0}'::jsonb
-- ) AS p;

-- Productized preset: the shipped engine returns real catalog ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 top-k and section-4 diversify loop
-- below see the same diversify-off baseline as before (the engine leaves
-- diversify on -- the caller owns that policy; section 4 re-enables it
-- explicitly for its own audit). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so anchor
-- on the first catalog item's own embedding.
SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'vrs_catalog', 'emb_arr',
    (SELECT emb_arr::float8[] FROM vrs_catalog ORDER BY id LIMIT 1),
    6, 'id')
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry: real top-k rows (doc_id + distance) --
-- the primitive fractal_search_explore/fractal_search don't provide on
-- their own (see that function's own doc comment).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_search_telemetry: top-5 nearest catalog items ==='

SELECT c.title, t.distance
FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                              (SELECT center FROM vrs_genres WHERE genre_id = 1), 5) t
JOIN vrs_catalog c ON c.id = t.doc_id + 1
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. Diversify/Repulsion session state: enable it, report NEGATIVE
-- feedback on a result, and confirm the session picks it up.
--
-- fractal_diversify_enable()'s own doc comment scopes this to
-- "fractal_search results" specifically -- fractal_search_telemetry's
-- top_k (and hybrid_clinical_search/search_trajectory/cross_modal_
-- search, which all share it) is deliberately a literal, ground-truth
-- "k nearest REAL rows to this query" list, not repulsion-adjusted --
-- that's what makes it trustworthy for the doc_id/distance pairs the
-- rest of this demo joins back to real catalog rows. Repulsion state
-- from fractal_isolate_background is real (see the diagnostics below),
-- but today it only steers fractal_search()'s own single converged
-- point in the abstract [-1,1]^dim space, not this table-backed top-k
-- list -- so re-running the SAME fractal_search_telemetry query below
-- correctly returns the SAME top result, not a different one.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Diversify/Repulsion: session-level feedback state ==='

-- Blueprint (raw primitive): the stateful diversify/repulsion loop --
-- enable repulsion, set params, warm the D_q rolling window with varied
-- genre-center queries, report negative feedback on the genre-3 top
-- result (fractal_isolate_background on its doc_id -- the doc_id IS the
-- handle), read back the real diversity_quotient + session diagnostics,
-- and disable. Generalized below by the shipped
-- fractal_agent_feedback_audit preset, which runs this whole audit cycle
-- self-contained (and self-disables diversify, unlike recommend_diverse).
-- SELECT fractal_diversify_enable();
-- SELECT fractal_diversify_set_params(
--     window_n => 5, repulsion_sigma => 0.3, repulsion_weight => 0.5
-- );
-- SELECT t.doc_id
-- FROM generate_series(1, 8) g
-- CROSS JOIN LATERAL fractal_search_telemetry(
--     'vrs_catalog', 'emb_arr', (SELECT center FROM vrs_genres WHERE genre_id = ((g % 6) + 1)), 3
-- ) t;
-- SELECT c.title, t.doc_id, t.distance
-- FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
--                               (SELECT center FROM vrs_genres WHERE genre_id = 3), 1) t
-- JOIN vrs_catalog c ON c.id = t.doc_id + 1 \gset before_
-- SELECT fractal_isolate_background(:before_doc_id);
-- SELECT fractal_detect_collapse() AS dq, fractal_explain_result() AS diagnostics;
-- SELECT fractal_diversify_disable();

-- Productized preset: the shipped engine enables repulsion, warms the
-- D_q window from the genre centers, reports negative feedback on the
-- genre-3 audit target, reads back the real diversity_quotient (NOT NaN
-- once the window is warm) + session diagnostics, and self-disables.
-- Pure analytics, no LLM.
\echo '--- Preset: fractal_agent_feedback_audit (raw diversify loop preserved above) ---'
SELECT diversity_quotient, explanation
FROM fractal_agent_feedback_audit(
    'vrs_catalog', 'emb_arr',
    (SELECT center::float8[] FROM vrs_genres WHERE genre_id = 3),
    'vrs_genres', 'center', 8, 3);

-- ------------------------------------------------------------------
-- 5. Cross-modal search: content embedding + behavior embedding,
-- weighted (weighted CONCATENATION, not a blend -- each modality keeps
-- its own dimensions; vector_col must already be stored in this
-- combined shape).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. fractal_cross_modal_search: content + behavior, weighted ==='

DROP TABLE IF EXISTS vrs_modal_items;
-- fractal_vector(8) -- exercises fractal_cross_modal_search's
-- fractal_vector overload below.
CREATE TABLE vrs_modal_items (id serial PRIMARY KEY, title text, combined_vec fractal_vector(8));
INSERT INTO vrs_modal_items (title, combined_vec)
SELECT 'modal-item-' || gs,
       ARRAY[random()*2-1, random()*2-1, random()*2-1, random()*2-1,   -- content (4d)
             random()*2-1, random()*2-1, random()*2-1, random()*2-1]  -- behavior (4d)
FROM generate_series(1, 60) gs;

SELECT m.title, t.distance
FROM fractal_cross_modal_search(
    'vrs_modal_items', 'combined_vec',
    '[0.6,0.6,-0.6,0.0]'::fractal_vector,   -- content query
    '[0.2,-0.2,0.2,0.2]'::fractal_vector,   -- behavior query
    0.7, 5
) t
JOIN vrs_modal_items m ON m.id = t.doc_id + 1
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 6. Reasoning: explain the recommendation set in plain language.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. Reasoning over the recommendation set ==='

SELECT fractal_reason(
    'each item is a catalog title with a distance score from a diverse discovery search -- explain what kind of viewer/listener would want this mix and why the spread across genres matters',
    (SELECT jsonb_agg(row_to_json(t))::text FROM (
        SELECT c.title, c.genre_id, gt.distance
        FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                                      ARRAY[0,0,0,0,0,0,0,0]::float8[], 8) gt
        JOIN vrs_catalog c ON c.id = gt.doc_id + 1
    ) t)
);

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;'
