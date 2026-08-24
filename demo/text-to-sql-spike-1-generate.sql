-- demo/text-to-sql-spike-1-generate.sql
-- Part 1 of 3 of the text-to-sql validation spike (see
-- text-to-sql-spike-2-review.sql and -3-validate.sql for the rest).
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

\echo '=== GENERATE: phi4:14b ==='
ALTER SYSTEM SET fractalsql.http_model = 'phi4:14b';
SELECT pg_reload_conf();
\c
\encoding UTF8
INSERT INTO spike_candidates (model, sql_text) VALUES (
    'phi4:14b',
    fractal_reason(
        'Write a single PostgreSQL SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id serial PK, service text, message text, severity text CHECK IN (''info'',''warning'',''critical''), created_at timestamptz). No foreign keys, this is the only table.'
    )
);

\echo '=== GENERATE: gemma4:12b ==='
ALTER SYSTEM SET fractalsql.http_model = 'gemma4:12b';
SELECT pg_reload_conf();
\c
\encoding UTF8
INSERT INTO spike_candidates (model, sql_text) VALUES (
    'gemma4:12b',
    fractal_reason(
        'Write a single PostgreSQL SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id serial PK, service text, message text, severity text CHECK IN (''info'',''warning'',''critical''), created_at timestamptz). No foreign keys, this is the only table.'
    )
);

\echo '=== GENERATE: gpt-oss:20b ==='
ALTER SYSTEM SET fractalsql.http_model = 'gpt-oss:20b';
SELECT pg_reload_conf();
\c
\encoding UTF8
INSERT INTO spike_candidates (model, sql_text) VALUES (
    'gpt-oss:20b',
    fractal_reason(
        'Write a single PostgreSQL SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id serial PK, service text, message text, severity text CHECK IN (''info'',''warning'',''critical''), created_at timestamptz). No foreign keys, this is the only table.'
    )
);

\echo '=== All three candidates ==='
SELECT model, sql_text FROM spike_candidates ORDER BY model;

\echo ''
\echo '================================================================'
\echo 'Next: switch FSQL_REASONING_HTTP_RESPONSE_MODE=text, restart, then'
\echo 'run demo/text-to-sql-spike-2-review.sql'
\echo '================================================================'
