-- demo/demo-vertical-biotech-genomics.sql
--
-- Industry vertical: Biotech, Structural Biology & Genomics.
--
-- Two independent showcases, both raw-primitive (no shipped preset wraps
-- either function yet -- unlike the other demo-vertical-*.sql files,
-- there is no fractal_agent_* engine to fall back to here):
--
--   1. fractal_tda_persistence_diagram over a synthetic cyclic-peptide
--      backbone point cloud (a closed-loop protein motif) -- 0-dim
--      persistence (cluster birth/death) plus the graph-cycle-rank
--      Betti-1 approximation, showing it correctly flags the loop.
--   2. fractal_vector_lp_distance over synthetic scRNA-seq-style
--      per-cell expression vectors, contrasting p=2 (Euclidean) against
--      a fractional p (sharper high-dimensionality contrast) between
--      two related cell states.
--
-- Prerequisites: extension installed. No reasoning step in this file.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-biotech-genomics.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-biotech-genomics.sql
--
-- Safe to re-run: vbg_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.91);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. fractal_tda_persistence_diagram: a synthetic 40-residue cyclic
-- peptide backbone -- Calpha coordinates traced around a closed ring in
-- 3D (a real, common structural motif: e.g. cyclic peptides, and loop
-- regions in larger folded proteins), plus a small amount of thermal
-- noise. A closed loop is EXACTLY the shape this function's graph-based
-- Betti-1 approximation is suited to detect cleanly (see the caveat
-- below on what it does NOT detect reliably).
--
-- max_dim=1 requests the Betti-1 approximation; max_thresh is chosen
-- past the ring's own inter-residue spacing so the filtration has fully
-- connected the ring into one cycle before the threshold cuts off.
--
-- IMPORTANT SCOPE CAVEAT (carried verbatim from this function's own
-- COMMENT ON FUNCTION in sql/fractalsql--1.0.sql): h0_bars (birth/death
-- pairs) is an EXACT 0-dimensional persistence computation. betti1 is
-- the underlying Vietoris-Rips graph's CYCLE RANK (edges minus vertices
-- plus connected components), NOT full simplicial H1 -- it over-counts
-- true H1 whenever a filled triangle exists in the data. A full
-- simplicial computation (what Ripser/GUDHI compute via boundary-matrix
-- reduction) is out of scope here. Do not report betti1 as an
-- equivalent-quality H1 count for structures with densely-packed local
-- neighborhoods (e.g. globular folds, not the sparse ring case below).
-- Size-capped at <= 512 points.
--
-- Citation: Edelsbrunner, H., Letscher, D., & Zomorodian, A. (2002).
-- "Topological persistence and simplification." Discrete &
-- Computational Geometry, 28(4), 511-533.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. fractal_tda_persistence_diagram: cyclic peptide backbone (40 residues) ==='

DROP TABLE IF EXISTS vbg_backbone;
CREATE TEMP TABLE vbg_backbone AS
SELECT (SELECT array_agg(v ORDER BY i, ord)
          FROM generate_series(0, 39) i
          CROSS JOIN LATERAL unnest(ARRAY[
              3.8 * cos(2 * pi() * i / 40.0) + (random() - 0.5) * 0.05,
              3.8 * sin(2 * pi() * i / 40.0) + (random() - 0.5) * 0.05,
              (random() - 0.5) * 0.08
          ]) WITH ORDINALITY AS u(v, ord)
       ) AS points;

-- max_thresh=0.9: past adjacent-residue spacing (~0.6, ring
-- circumference / 40 residues) but well short of the next-nearest
-- skip-one spacing (~1.19) -- connects the filtration into exactly the
-- ring's own edges, no chords. Verified empirically against this exact
-- fixture: betti1=1 (correct, a single loop) at thresh in [0.7, 1.1];
-- at 1.5 the filtration starts adding chords and betti1 jumps to 41
-- (chord over-counting -- the caveat above made concrete).
\echo '(raw primitive -- no preset wraps this function yet)'
SELECT jsonb_array_length(h0_bars) AS h0_merge_events, betti1
FROM vbg_backbone, fractal_tda_persistence_diagram(points, 3, 1, 0.9::float8, 64);
\echo '(betti1=1: the graph-cycle-rank approximation correctly reads this'
\echo 'point cloud as one closed loop -- the case it is suited for. Full'
\echo 'h0_bars birth/death pairs omitted from output above for brevity --'
\echo 'h0_merge_events is just jsonb_array_length(h0_bars).)'

-- ------------------------------------------------------------------
-- 2. fractal_vector_lp_distance: synthetic scRNA-seq-style per-cell
-- expression profiles (32 genes, log-normalized, non-negative) for
-- three cells -- two of the same underlying cell TYPE (correlated
-- expression pattern plus per-cell noise) and one clearly distinct
-- type. Euclidean (p=2) and a fractional p=0.5 are compared: p=2
-- dilutes the contribution of the many genes near zero across both
-- cells, while fractional p weights those near-zero-vs-nonzero
-- differences more heavily -- often desirable in sparse high-
-- dimensional expression data, at the cost documented below.
--
-- SCOPE CAVEAT (carried verbatim from this function's own COMMENT ON
-- FUNCTION): for 0 < p < 1 this is NOT a proper metric -- the triangle
-- inequality does not hold -- so never substitute it silently for the
-- vector index's native <-> distance as a default; use it explicitly,
-- as here, where fractional-p contrast at high dimensionality is
-- specifically wanted.
--
-- Lp (Minkowski) distance is a standard, widely-used metric family,
-- not attributed to a single originating paper -- no citation, per
-- this repo's own THIRD-PARTY-NOTICES.md.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. fractal_vector_lp_distance: scRNA-seq expression contrast (p=2 vs p=0.5) ==='

DROP TABLE IF EXISTS vbg_cells;
CREATE TABLE vbg_cells (
    id        serial PRIMARY KEY,
    cell_type text,
    -- fractal_vector(32), not float8[] -- fixed-width expression
    -- profile (32 marker genes), same dimension-safety argument as the
    -- other fractal_vector verticals: a malformed profile (wrong gene
    -- count from an upstream pipeline step) should be a hard write-time
    -- error, not a silently corrupted corpus.
    expr      fractal_vector(32)
);

WITH base_profile AS (
    SELECT array_agg(GREATEST(random() * 2.5, 0)) AS v
    FROM generate_series(1, 32)
)
INSERT INTO vbg_cells (cell_type, expr)
SELECT 'T-cell-like',
       (SELECT array_agg(GREATEST(v_i + (random() - 0.5) * 0.3, 0) ORDER BY ord)
          FROM base_profile, unnest(v) WITH ORDINALITY AS u(v_i, ord))::float8[]
FROM base_profile
UNION ALL
SELECT 'T-cell-like',
       (SELECT array_agg(GREATEST(v_i + (random() - 0.5) * 0.3, 0) ORDER BY ord)
          FROM base_profile, unnest(v) WITH ORDINALITY AS u(v_i, ord))::float8[]
FROM base_profile
UNION ALL
SELECT 'B-cell-like',
       (SELECT array_agg(GREATEST(random() * 2.5, 0)) FROM generate_series(1, 32))::float8[];

\echo '(raw primitive -- no preset wraps this function yet)'
SELECT a.cell_type AS cell_a, b.cell_type AS cell_b,
       fractal_vector_lp_distance(a.expr, b.expr, 2.0::float8)  AS dist_p2_euclidean,
       fractal_vector_lp_distance(a.expr, b.expr, 0.5::float8)  AS dist_p0_5_fractional
FROM vbg_cells a, vbg_cells b
WHERE a.id < b.id
ORDER BY a.id, b.id;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vbg_cells;'
