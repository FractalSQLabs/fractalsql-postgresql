-- demo/text-to-sql-spike-2-review.sql
-- Part 2 of 3 of the text-to-sql validation spike. Requires Part 1 to
-- have already run (reads from spike_candidates).
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=text -- set it and
-- restart PostgreSQL BEFORE running this file (switching back from
-- the code mode Part 1 needed). See "Switching modes on an
-- already-running install" in ../docs/reasoning-setup.md.
--
-- The model reviews its OWN candidate, matching how the real feature
-- would run (same configured endpoint for both steps). fractalsql.
-- http_model must still be the model spike-1 generated with -- this
-- doesn't re-check that for you.

\timing on
\pset pager off
\encoding UTF8

SELECT current_setting('fractalsql.http_model') AS model \gset
\echo === REVIEW: :model ===
UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = :'model';

\echo '=== Review ==='
SELECT model, review FROM spike_candidates;

\echo ''
\echo '================================================================'
\echo 'Next: run demo/text-to-sql-spike-3-validate.sql (no restart'
\echo 'needed -- EXPLAIN and EXECUTE have no mode dependency).'
\echo '================================================================'
