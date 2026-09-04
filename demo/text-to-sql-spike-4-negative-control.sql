-- demo/text-to-sql-spike-4-negative-control.sql
-- Negative control for the review step: does review correctly say
-- FAIL on a deliberately WRONG candidate, or does it rubber-stamp
-- anything? Parts 1-3 only proved review says PASS on GOOD SQL --
-- this is the harder, more valuable check.
--
-- No restart needed -- still in FSQL_REASONING_HTTP_RESPONSE_MODE=text
-- from part 2. Review-only, no generate/explain/execute. Uses
-- whichever model fractalsql.http_model is currently pointed at, same
-- as parts 1-3.
--
-- The wrong candidate is the SAME query as the correct answer with the
-- critical-only filter simply removed -- syntactically perfect SQL
-- that answers a DIFFERENT, wrong question (includes payments and
-- auth-service, which have no critical alerts and should be excluded).

\timing on
\pset pager off
\encoding UTF8

DROP TABLE IF EXISTS spike_negative_control;
CREATE TABLE spike_negative_control (
    model    text PRIMARY KEY,
    sql_text text,
    review   text
);

SELECT current_setting('fractalsql.http_model') AS model \gset

INSERT INTO spike_negative_control (model, sql_text) VALUES (
    :'model',
    'SELECT service, severity, COUNT(*) FROM demo_alerts GROUP BY service, severity;'
);

\echo '=== What the wrong candidate actually produces (for reference) ==='
SELECT service, severity, COUNT(*) FROM demo_alerts GROUP BY service, severity ORDER BY service, severity;
\echo 'Note payments and auth-service present -- that is the bug review should catch.'

\echo === REVIEW (wrong candidate): :model ===
UPDATE spike_negative_control SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = :'model';

\echo '=== Review of the WRONG candidate ==='
SELECT model, review FROM spike_negative_control;

\echo ''
\echo '================================================================'
\echo 'Interpretation:'
\echo '  - FAIL, correctly citing the missing critical-only filter ->'
\echo '    review is discriminating, not rubber-stamping. Strong signal.'
\echo '  - PASS on this obviously-wrong candidate -> review is not'
\echo '    reliable for this model, do not depend on it as a real gate.'
\echo ''
\echo 'Clean up: DROP TABLE spike_negative_control;'
\echo '(spike_candidates from parts 1-3 is untouched by this file.)'
\echo '================================================================'
