-- demo/text-to-sql-spike-2-review.sql
-- Part 2 of 3 of the text-to-sql validation spike. Requires Part 1 to
-- have already run (reads from spike_candidates).
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=text -- set it and
-- restart PostgreSQL BEFORE running this file (switching back from
-- the code mode Part 1 needed). See "Switching modes on an
-- already-running install" in ../docs/reasoning-setup.md.
--
-- Each model reviews its OWN candidate, matching how the real feature
-- would run (same configured endpoint for both steps).

\timing on
\pset pager off
\encoding UTF8

\echo '=== REVIEW: phi4:14b ==='
ALTER SYSTEM SET fractalsql.http_model = 'phi4:14b';
SELECT pg_reload_conf();
\c
\encoding UTF8
UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = 'phi4:14b';

\echo '=== REVIEW: gemma4:12b ==='
ALTER SYSTEM SET fractalsql.http_model = 'gemma4:12b';
SELECT pg_reload_conf();
\c
\encoding UTF8
UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = 'gemma4:12b';

\echo '=== REVIEW: gpt-oss:20b ==='
ALTER SYSTEM SET fractalsql.http_model = 'gpt-oss:20b';
SELECT pg_reload_conf();
\c
\encoding UTF8
UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = 'gpt-oss:20b';

\echo '=== All three reviews ==='
SELECT model, review FROM spike_candidates ORDER BY model;

\echo ''
\echo '================================================================'
\echo 'Next: run demo/text-to-sql-spike-3-validate.sql (no restart'
\echo 'needed -- EXPLAIN and EXECUTE have no mode dependency).'
\echo '================================================================'
