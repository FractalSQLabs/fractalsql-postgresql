-- demo/text-to-sql-spike-1-generate.sql
-- Part 1 of 3 of the text-to-sql validation spike (see
-- text-to-sql-spike-2-review.sql and -3-validate.sql for the rest).
--
-- Generates one candidate using whichever model fractalsql.http_model
-- is currently pointed at -- a quality-control check on
-- fractal_text_to_sql() for YOUR configured model (gpt-oss:20b by
-- default, or whatever you've switched to, local or cloud), not a
-- fixed model comparison.
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=code -- set it and
-- restart PostgreSQL BEFORE running this file. See "Switching modes
-- on an already-running install" in ../docs/reasoning-setup.md.
--
-- Prerequisites: reasoning configured, demo_alerts table present (run
-- demo.sql first if you haven't).

\timing on
\pset pager off
\encoding UTF8

DROP TABLE IF EXISTS spike_candidates;
CREATE TABLE spike_candidates (
    model    text PRIMARY KEY,
    sql_text text,
    review   text
);

SELECT current_setting('fractalsql.http_model') AS model \gset
\echo === GENERATE: :model ===
INSERT INTO spike_candidates (model, sql_text) VALUES (
    :'model',
    fractal_reason(
        'Write a single PostgreSQL SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id serial PK, service text, message text, severity text CHECK IN (''info'',''warning'',''critical''), created_at timestamptz). No foreign keys, this is the only table.'
    )
);

\echo '=== Candidate ==='
SELECT model, sql_text FROM spike_candidates;

\echo ''
\echo '================================================================'
\echo 'Next: switch FSQL_REASONING_HTTP_RESPONSE_MODE=text, restart, then'
\echo 'run demo/text-to-sql-spike-2-review.sql'
\echo '================================================================'
