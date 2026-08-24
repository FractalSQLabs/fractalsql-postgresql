-- demo/text-to-sql-spike-3-validate.sql
-- Part 3 of 3 of the text-to-sql validation spike. Requires Parts 1
-- and 2 to have already run. No mode dependency, no restart needed --
-- EXPLAIN and EXECUTE are mechanical, not reasoning calls.
--
-- Correct result for ALL three models: exactly 2 rows in the EXECUTE
-- output, service=api-gateway, (severity=info, count=2) and
-- (severity=critical, count=2). payments and auth-service must NOT
-- appear.

\timing on
\pset pager off
\encoding UTF8

-- ================================================================
-- EXPLAIN (mechanical). SAVEPOINT/ROLLBACK matches the real design's
-- safety net. \gexec runs the preceding query's result as a live
-- command, so this actually EXPLAINs each stored candidate.
-- ================================================================

\echo '=== EXPLAIN: phi4:14b ==='
BEGIN;
SAVEPOINT before_explain;
SELECT 'EXPLAIN ' || sql_text FROM spike_candidates WHERE model = 'phi4:14b';
\gexec
ROLLBACK TO SAVEPOINT before_explain;
COMMIT;

\echo '=== EXPLAIN: gemma4:12b ==='
BEGIN;
SAVEPOINT before_explain;
SELECT 'EXPLAIN ' || sql_text FROM spike_candidates WHERE model = 'gemma4:12b';
\gexec
ROLLBACK TO SAVEPOINT before_explain;
COMMIT;

\echo '=== EXPLAIN: gpt-oss:20b ==='
BEGIN;
SAVEPOINT before_explain;
SELECT 'EXPLAIN ' || sql_text FROM spike_candidates WHERE model = 'gpt-oss:20b';
\gexec
ROLLBACK TO SAVEPOINT before_explain;
COMMIT;

-- ================================================================
-- EXECUTE (manual validation only -- the real feature never
-- auto-executes; this is us checking the answer is actually correct,
-- not just syntactically valid).
-- ================================================================

\echo '=== EXECUTE: phi4:14b ==='
SELECT sql_text FROM spike_candidates WHERE model = 'phi4:14b';
\gexec

\echo '=== EXECUTE: gemma4:12b ==='
SELECT sql_text FROM spike_candidates WHERE model = 'gemma4:12b';
\gexec

\echo '=== EXECUTE: gpt-oss:20b ==='
SELECT sql_text FROM spike_candidates WHERE model = 'gpt-oss:20b';
\gexec

\echo ''
\echo '================================================================'
\echo 'Done. Interpretation:'
\echo '  - EXPLAIN failed for a model -> syntactically broken SQL, a'
\echo '    real problem (EXPLAIN-only validation would have caught it).'
\echo '  - EXPLAIN passed but EXECUTE shows payments/auth-service rows'
\echo '    -> syntactically valid, semantically WRONG. This is exactly'
\echo '    the gap review exists to catch -- check whether that model'
\echo '    review said PASS or FAIL for its own (wrong) candidate.'
\echo '  - Review said PASS on a candidate that executes wrong -> the'
\echo '    review step itself is not reliable for that model.'
\echo '  - All three: EXPLAIN passes, EXECUTE shows only api-gateway'
\echo '    (info=2, critical=2) -> strong go signal.'
\echo ''
\echo 'Clean up when done: DROP TABLE spike_candidates;'
\echo '================================================================'
