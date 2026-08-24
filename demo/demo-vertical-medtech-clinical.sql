-- demo/demo-vertical-medtech-clinical.sql
--
-- Industry vertical: MedTech, Clinical Telemetry & Patient Monitoring.
--
-- Synthetic patient vitals + telemetry (cohort-filtered search, current-
-- vs-baseline drift) plus the four domain-specific geometry functions on
-- small, pre-extracted geometric fixtures (a vessel graph, a triangulated
-- mesh, a nerve fiber skeleton) -- these take PRE-EXTRACTED geometry, not
-- raw imaging data (see fractal_vascular_network/_cortical_folding/
-- _nerve_plexus_metric's own doc comments for that scope boundary).
--
-- Prerequisites: extension installed (sections 0-6 need nothing else).
-- Section 7 calls fractal_reason() -- see ../docs/reasoning-setup.md.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-medtech-clinical.sql
--   docker compose exec postgres psql -U postgres -d fractalsql_demo -f /demo/demo-vertical-medtech-clinical.sql
--
-- Safe to re-run: vmc_* tables are dropped and recreated each time.

\timing on
SELECT setseed(0.17);

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 40 synthetic patients with a demographic/condition cohort and a
-- 5-dim current-vitals vector (heart rate, SpO2, systolic, diastolic,
-- temperature, each roughly normalized). One flagged "sepsis-watch"
-- cohort (age > 65 AND condition = 'sepsis') for Section 2.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. 40 synthetic patients: demographics + current vitals ==='

DROP TABLE IF EXISTS vmc_patients;
CREATE TABLE vmc_patients (
    id        serial PRIMARY KEY,
    age       int,
    condition text,
    -- fractal_vector(5), not float8[] -- [hr_z, spo2_z, systolic_z,
    -- diastolic_z, temp_z] is a fixed, known-width vector where
    -- dimension-drift protection actually matters clinically: a
    -- malformed vitals write (wrong field count from an upstream
    -- monitor integration) should raise loudly, not silently corrupt
    -- a patient record. See docs/vectorizer-setup.md's "Storage:
    -- float8[] vs fractal_vector(n)" section.
    vitals    fractal_vector(5)
);

-- The INSERT below is UNCHANGED from the float8[] version of this demo
-- (still literal ::float8[] values) -- the float8[]->fractal_vector
-- assignment cast handles the column coercion automatically on write,
-- same mechanism fractal_vectorizer_process_queue() relies on. Zero
-- code changes needed here for the type swap above.
INSERT INTO vmc_patients (age, condition, vitals)
SELECT
    (22 + (random() * 68))::int,
    CASE WHEN random() < 0.2 THEN 'sepsis'
         WHEN random() < 0.4 THEN 'post-op'
         ELSE 'routine' END,
    ARRAY[random() * 2 - 1, random() * 2 - 1, random() * 2 - 1,
          random() * 2 - 1, random() * 2 - 1]::float8[]
FROM generate_series(1, 40);

-- Force at least a few real hits in the cohort filter below, deterministically.
UPDATE vmc_patients SET age = 70, condition = 'sepsis'
 WHERE id IN (3, 11, 27);

\echo ''
\echo '=== 2. fractal_hybrid_clinical_search: cohort-restricted search ==='
\echo '(cohort = age > 65 AND condition = sepsis, computed with ordinary SQL --'
\echo 'never a raw SQL predicate string, see that function''s own doc comment.'
\echo 'query stays float8[] here -- vitals being fractal_vector(5) only changes'
\echo 'how the CORPUS is read, not this function''s query argument type.)'

-- Blueprint (raw primitive): cohort-restricted hybrid search (the
-- age>65 AND condition='sepsis' sepsis-watch cohort). Generalized by the
-- shipped fractal_agent_patient_deterioration_triage preset in Section 3,
-- which folds this cohort search together with the baseline->current
-- drift search and a reasoning step. (The preset builds cohort_doc_ids
-- in ctid order -- the scan order the underlying search actually uses --
-- rather than this raw form's id order, which only matches scan order
-- for a never-UPDATEd table; vmc_patients' Section 1 cohort-force UPDATE
-- relocates tuples, so ctid order is the correct one.)
-- WITH cohort_rows AS (
--     SELECT (row_number() OVER (ORDER BY id) - 1) AS idx
--       FROM vmc_patients WHERE age > 65 AND condition = 'sepsis'
-- ),
-- cohort AS (
--     SELECT array_agg(idx) AS ids FROM cohort_rows
-- )
-- SELECT doc_id, distance
-- FROM cohort, fractal_hybrid_clinical_search(
--     'vmc_patients', 'vitals', ARRAY[1, -1, 1, 1, 0.5]::float8[],
--     cohort.ids, 5
-- );

-- ------------------------------------------------------------------
-- 3. fractal_search_trajectory: one patient's CURRENT vitals vs their
-- own admission BASELINE -- "what changed", the natural query shape
-- for drift/trajectory monitoring (this function's own doc comment
-- uses this exact patient-baseline example).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. fractal_search_trajectory: patient drift from admission baseline ==='
\echo '(::fractal_vector literals here -- exercises the fractal_vector overload'
\echo 'directly, reading vitals'' varlena payload with no array-unpack step)'

-- Blueprint (raw primitive): one patient's current vitals vs their
-- admission baseline -- the "what changed" drift search. Generalized
-- below by the shipped fractal_agent_patient_deterioration_triage
-- preset, which folds this trajectory search together with the Section 2
-- cohort-restricted hybrid search and a reasoning step.
-- SELECT doc_id, distance
-- FROM fractal_search_trajectory(
--     'vmc_patients', 'vitals',
--     '[0.1,0.05,0.0,0.0,0.0]'::fractal_vector,   -- admission baseline
--     '[1.4,-1.1,0.9,0.7,1.2]'::fractal_vector,   -- current (deteriorating)
--     5
-- );

-- Productized preset: the shipped engine runs the cohort-restricted
-- hybrid search (nearest sepsis-watch cohort patient to the query
-- vitals, resolved via ctid) and the baseline->current drift search,
-- then reasons. nearest_cohort_id/cohort_distance/drift_distance are
-- real; rationale is the real fractal_reason output. cohort_doc_ids is
-- caller-built from age>65 AND condition='sepsis' (the two-predicate
-- cohort fractal_agent_recall_hybrid's single filter can't express) in
-- ctid scan order.
\echo '--- Preset: fractal_agent_patient_deterioration_triage (raw hybrid+trajectory form preserved above) ---'
SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale
FROM fractal_agent_patient_deterioration_triage(
    'vmc_patients', 'vitals',
    ARRAY[1, -1, 1, 1, 0.5]::float8[],
    ARRAY[0.1, 0.05, 0.0, 0.0, 0.0]::float8[],
    ARRAY[1.4, -1.1, 0.9, 0.7, 1.2]::float8[],
    (SELECT array_agg(doc_id ORDER BY doc_id) FROM
       (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id
          FROM vmc_patients
         WHERE age > 65 AND condition = 'sepsis') x),
    5, 'id');

-- ------------------------------------------------------------------
-- 4. fractal_vascular_network: a branching vessel graph -- a 28-node
-- centerline chain plus 2 branch leaves off node 10, node_coords in 3D
-- with real arc lengths from an upstream centerline trace. Needs >= 8
-- nodes AND enough of them for the internal box-counting dimension
-- estimator to find >= 3 valid eps-octaves (its own documented
-- "avg >= 3 points/occupied-cell" validity filter, same one
-- fractalsql-core's own boxcount unit tests calibrate against) -- a
-- too-small skeleton returns rc=-1, not a wrong number.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. fractal_vascular_network: vessel tortuosity/branch-density/dimension ==='

DROP TABLE IF EXISTS vmc_vessel;
CREATE TEMP TABLE vmc_vessel AS
SELECT
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 27) i
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.0, 0.0]) WITH ORDINALITY AS u(v, ord))
    || ARRAY[10, 1, 0, 10, 0, 1]::float8[] AS nodes,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 26) i
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
    || ARRAY[10, 28, 10, 29]::int4[] AS edges,
    (SELECT array_agg(1.02) FROM generate_series(0, 28)) AS arcs;

SELECT fractal_vascular_network(nodes, edges, arcs) FROM vmc_vessel;

-- ------------------------------------------------------------------
-- 5. fractal_cortical_folding: a unit-cube surface mesh (8 vertices,
-- 12 triangular faces) -- a "smooth" (unfolded) reference case where
-- mesh area should closely match hull area (GI ~1.0), the same known-
-- answer sanity check fractalsql-core's own cortical.c unit tests use.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. fractal_cortical_folding: Gyrification Index on a reference mesh ==='

SELECT fractal_cortical_folding(
    ARRAY[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]::float8[],
    ARRAY[0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
          3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5]::int4[]
);

-- ------------------------------------------------------------------
-- 6. fractal_nerve_plexus_metric: an 80-fiber zigzag skeleton (corneal
-- confocal microscopy convention -- fiber length density, branch
-- density, box-counting dimension). Same box-counting-scale note as
-- Section 4 above -- 80 points is comfortably past the internal
-- estimator's minimum for a reliable answer.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. fractal_nerve_plexus_metric: corneal nerve fiber plexus ==='

DROP TABLE IF EXISTS vmc_nerve;
CREATE TEMP TABLE vmc_nerve AS
SELECT
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 79) i
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.05 * sin(i::float8)]) WITH ORDINALITY AS u(v, ord)) AS coords,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 78) i
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[] AS edges;

SELECT fractal_nerve_plexus_metric(coords, 2, edges) FROM vmc_nerve;

-- ------------------------------------------------------------------
-- 7. Reasoning: the cohort-search + trajectory-drift clinical narrative
-- is now produced by the fractal_agent_patient_deterioration_triage
-- preset's rationale column in Section 3. The vessel/cortical/nerve
-- geometry primitives in Sections 4-6 stay raw (domain geometry with no
-- engine home) -- their own output columns are the showcase.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 7. Reasoning: absorbed into the Section 3 patient_deterioration_triage rationale ==='

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE vmc_patients;'
