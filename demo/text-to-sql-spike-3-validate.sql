-- demo/text-to-sql-spike-3-validate.sql
-- Part 3 of 3 of the text-to-sql validation spike. Requires Parts 1
-- and 2 to have already run. No mode dependency, no restart needed --
-- EXPLAIN and EXECUTE are mechanical, not reasoning calls.
--
-- Correct result: exactly 2 rows in the EXECUTE output,
-- service=api-gateway, (severity=info, count=2) and
-- (severity=critical, count=2). payments and auth-service must NOT
-- appear.

\timing on
\pset pager off
\encoding UTF8

SELECT current_setting('fractalsql.http_model') AS model \gset

-- ================================================================
-- EXPLAIN (mechanical). SAVEPOINT/ROLLBACK matches the real design's
-- safety net. \gexec runs the preceding query's result as a live
-- command, so this actually EXPLAINs the stored candidate.
-- ================================================================

\echo === EXPLAIN: :model ===
BEGIN;
SAVEPOINT before_explain;
SELECT 'EXPLAIN ' || sql_text FROM spike_candidates WHERE model = :'model';
\gexec
ROLLBACK TO SAVEPOINT before_explain;
COMMIT;

-- ================================================================
-- EXECUTE (manual validation only -- the real feature never
-- auto-executes; this is us checking the answer is actually correct,
-- not just syntactically valid).
-- ================================================================

\echo === EXECUTE: :model ===
SELECT sql_text FROM spike_candidates WHERE model = :'model';
\gexec

\echo ''
\echo '================================================================'
\echo 'Done. Interpretation:'
\echo '  - EXPLAIN failed -> syntactically broken SQL, a real problem'
\echo '    (EXPLAIN-only validation would have caught it).'
\echo '  - EXPLAIN passed but EXECUTE shows payments/auth-service rows'
\echo '    -> syntactically valid, semantically WRONG. This is exactly'
\echo '    the gap review exists to catch -- check whether review said'
\echo '    PASS or FAIL for this (wrong) candidate.'
\echo '  - Review said PASS on a candidate that executes wrong -> the'
\echo '    review step itself is not reliable for this model.'
\echo '  - EXPLAIN passes, EXECUTE shows only api-gateway (info=2,'
\echo '    critical=2) -> strong go signal for this model.'
\echo ''
\echo 'Clean up when done: DROP TABLE spike_candidates;'
\echo '================================================================'
