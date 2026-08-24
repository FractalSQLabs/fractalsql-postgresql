-- demo/response-modes.sql
--
-- FractalSQL reasoning response modes: text | code | json.
--
-- Unlike demo.sql, this is NOT meant to be run start-to-finish in one
-- `psql -f` pass. FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-only
-- setting read once when the reasoning plugin initializes -- switching
-- modes on an already-running install needs an OS-level environment
-- variable change plus a full PostgreSQL service/cluster restart. A
-- `SELECT pg_reload_conf();` is NOT enough (that only reloads GUCs from
-- postgresql.conf, and this isn't one). See "Switching modes on an
-- already-running install" in ../docs/reasoning-setup.md for the exact
-- commands on your platform (Windows/Linux/macOS all differ here).
--
-- Prerequisites:
--   1. Run demo.sql first -- this reuses its demo_alerts table.
--   2. Reasoning already configured per ../docs/reasoning-setup.md.
--
-- Workflow for each section below:
--   1. Set FSQL_REASONING_HTTP_RESPONSE_MODE to that section's mode.
--   2. Restart the PostgreSQL service/cluster.
--   3. Run ONLY that section's query -- not the whole file at once.

\timing on

-- ============================================================
-- MODE: text (the default -- nothing to configure or restart for)
-- ============================================================
-- Raw model output, unchanged. This is what demo.sql and every other
-- example in the docs already use.

SELECT fractal_reason(
    'summarize what happened in demo_alerts in one sentence',
    (SELECT jsonb_agg(row_to_json(t))::text
       FROM (SELECT service, message, severity, created_at FROM demo_alerts) t)
);

-- ============================================================
-- MODE: code   (FSQL_REASONING_HTTP_RESPONSE_MODE=code, then restart)
-- ============================================================
-- The plugin auto-appends an instruction telling the model to answer
-- with a single fenced code block, then strips the fence markers on
-- extraction. Expect back a bare SQL statement -- no "Here's a query
-- that does that:" preamble, no explanation, no visible ``` markers.

SELECT fractal_reason(
    'write a SQL query that selects all rows from demo_alerts where severity is critical'
);

-- ============================================================
-- MODE: json   (FSQL_REASONING_HTTP_RESPONSE_MODE=json, then restart)
-- ============================================================
-- Same fenced-block extraction as code mode, plus a structural
-- validity check (balanced braces/brackets) on the plugin side before
-- it's returned. The trailing ::jsonb cast below is a second,
-- independent proof: if the plugin's own validation somehow let
-- something malformed through, Postgres's own JSON parser catches it
-- here instead of silently accepting bad output.

SELECT fractal_reason(
    'return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present',
    (SELECT jsonb_agg(row_to_json(t))::text FROM (SELECT severity FROM demo_alerts) t)
)::jsonb;
