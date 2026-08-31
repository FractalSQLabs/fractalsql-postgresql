-- sql/fractalsql--1.0.sql
\echo Use "CREATE EXTENSION fractalsql" to load this file. \quit

CREATE FUNCTION fractal_search(
    query            float8[],
    iterations       int4 DEFAULT 30,
    population_size  int4 DEFAULT 50,
    diffusion_factor int4 DEFAULT 2
) RETURNS float8[]
AS 'MODULE_PATHNAME', 'fractal_search'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search(float8[], int4, int4, int4) IS
  'Stochastic Fractal Search (minimizing cosine distance to query). '
  'Returns the best point found in the unit box [-1, 1]^dim.';

CREATE FUNCTION fractal_search_debug(
    query            float8[],
    iterations       int4 DEFAULT 30,
    population_size  int4 DEFAULT 50,
    diffusion_factor int4 DEFAULT 2
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_search_debug'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search_debug(float8[], int4, int4, int4) IS
  'Like fractal_search, but returns a JSONB document with per-generation '
  'particle positions for visualization. Keys: dim, generations, '
  'population_size, best_point, best_fit, best_fit_per_gen, paths.';

CREATE FUNCTION fractal_search_explore(
    table_name  text,
    vector_col  text,
    query       float8[],
    options     jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF float8[]
AS 'MODULE_PATHNAME', 'fractal_search_explore'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search_explore(text, text, float8[], jsonb) IS
  'Diversity mode: scans table_name.vector_col once, scores every row''s '
  'cosine relevance to query, then MMR-selects population_size rows '
  'balancing relevance against redundancy with already-selected rows. '
  'Returns all N picks as SETOF float8[] — intended for discovering '
  'distinct basins of attraction (clusters) in the stored embedding '
  'distribution. Options (jsonb): iterations, population_size, '
  'diffusion_factor, walk, mmr_lambda. Defaults: 15 / 50 / 2 / 0.0 / 0.5. '
  'mmr_lambda in [0,1] trades relevance (1.0, collapses toward Sniper''s '
  'nearest-neighbor behavior) against diversity (0.0); lower it when a '
  'query sits deep inside one large, tightly-clustered basin and the '
  'default 0.5 balance is still returning mostly that one basin.';

CREATE FUNCTION fractal_reason(
    query   text,
    context text DEFAULT '{}'
) RETURNS text
AS 'MODULE_PATHNAME', 'fractal_reason'
LANGUAGE C;

COMMENT ON FUNCTION fractal_reason(text, text) IS
  'Dispatch query + JSON context to the configured LLM reasoning plugin '
  'and return the response as text. Requires fractalsql.reasoning_plugin '
  'to be set in postgresql.conf (absolute path to a compiled '
  'fractalsql-reasoning-*.so) and a server restart. The function errors '
  'with a clear hint if called without the plugin configured. All search '
  'functions (fractal_search, fractal_search_explore) continue to work '
  'regardless of whether the reasoning plugin is loaded.';

CREATE FUNCTION fractal_schema_context(
    table_names text[] DEFAULT NULL,
    query_hint  text   DEFAULT NULL
) RETURNS text
AS 'MODULE_PATHNAME', 'fractal_schema_context'
LANGUAGE C;

COMMENT ON FUNCTION fractal_schema_context(text[], text) IS
  'Build a plain-text schema description (columns, types, PK/NOT NULL '
  'flags, table/column comments, foreign keys) for the given tables, or '
  'every table visible via the current search_path and readable by the '
  'calling role if table_names is NULL. Introspection only -- no LLM '
  'call. Intended as context input to fractal_reason() or '
  'fractal_text_to_sql(). query_hint is accepted for forward '
  'compatibility with future table-subset ranking and is not yet used.';

CREATE FUNCTION fractal_text_to_sql(
    question    text,
    table_names text[] DEFAULT NULL
) RETURNS text
AS 'MODULE_PATHNAME', 'fractal_text_to_sql'
LANGUAGE C;

COMMENT ON FUNCTION fractal_text_to_sql(text, text[]) IS
  'Generate a single SQL statement answering `question` against the '
  'live schema (table_names, or every readable table if NULL). Pipeline: '
  'GENERATE (LLM) -> [REVIEW, optional] -> ALLOWLIST (raw_parser: '
  'single statement, no DDL/utility, statement type per '
  'fractalsql.text_to_sql_allowed_statements) -> EXPLAIN (mechanical '
  'planner check) -> RETURN, retrying GENERATE with the specific '
  'failure reason fed back on rejection, up to '
  'fractalsql.text_to_sql_max_attempts. The returned SQL is NEVER '
  'executed by this function -- execution is a separate, explicit, '
  'caller-side act. Requires fractalsql.reasoning_plugin to be '
  'configured. See docs/text-to-sql-setup.md for the security model '
  '(execution-role grants are the real gate, not this pipeline).';

CREATE FUNCTION fractal_embed(
    input text
) RETURNS float8[]
AS 'MODULE_PATHNAME', 'fractal_embed'
LANGUAGE C;

COMMENT ON FUNCTION fractal_embed(text) IS
  'Dispatch input to the configured embedding endpoint and return the '
  'parsed vector. Requires fractalsql.reasoning_plugin and '
  'fractalsql.http_embed_url to be set in postgresql.conf -- there is no '
  'fallback to the chat http_url/http_model, since a chat model is not a '
  'substitute for a purpose-trained embedding model and chat/embeddings '
  'are different endpoint paths even on the same provider host.';

CREATE FUNCTION fractal_edition() RETURNS text
AS 'MODULE_PATHNAME', 'fractal_edition'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_edition() IS
  'Returns the FractalSQL edition string (e.g. ''Community'').';

CREATE FUNCTION fractal_version() RETURNS text
AS 'MODULE_PATHNAME', 'fractal_version'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_version() IS
  'Returns the FractalSQL extension version (e.g. ''1.1.0'').';

-- Agent-tier results types
CREATE TYPE fractal_search_agent_result AS (
    answer text,
    source_doc_ids int8[],
    execution_time_ms int4
);

CREATE TYPE fractal_sql_agent_result AS (
    generated_sql text,
    execution_status text,
    retry_count int4,
    result_json jsonb
);

CREATE TYPE fractal_plan_explore_result AS (
    branch_id int8,
    plan_trajectory float8[],
    confidence_score float8
);

CREATE TYPE fractal_trajectory_predict_result AS (
    predicted_state_vector float8[],
    projected_drift_delta float8,
    risk_threshold_exceeded boolean
);

CREATE TYPE fractal_loop_detect_result AS (
    agent_id text,
    dfa_exponent float8,
    is_loop_detected boolean
);

-- ------------------------------------------------------------------
-- Agent-tier compositions -- bind the sovereign-tier C agent symbols.
-- These were previously dead: their PG_FUNCTION_INFO_V1 symbols existed
-- in the DLL but no SQL binding pointed at them, so they were unreachable
-- from SQL. They require a reasoning plugin + an OpenAI-compatible
-- chat/embed endpoint configured via the fractalsql.* GUCs to do useful
-- work, but the functions are callable as soon as the extension loads.
-- Signatures mirror the C in src/fractalsql.c exactly (arg order, types,
-- defaults, STRICTness) -- see docs/api-agency.md for usage.
-- ------------------------------------------------------------------

-- fractal_search_agent: Search -> Synthesize. Embeds the query, runs a
-- diverse (Scout) search over table_name.vector_col, then reasons over
-- the retrieved context to produce an answer.
CREATE FUNCTION fractal_search_agent(
    query       text,
    table_name  text,
    vector_col  text,
    pop_size    int4 DEFAULT 50,
    iterations  int4 DEFAULT 15
) RETURNS fractal_search_agent_result
AS 'MODULE_PATHNAME', 'fractal_search_agent'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_search_agent(query text, table_name text, vector_col text, pop_size int4, iterations int4) IS
'End-to-end Search->Synthesize agent: embeds the query, runs a diverse Scout search over table_name.vector_col, then reasons over the retrieved context.';

-- fractal_sql_agent: self-correcting Text-to-SQL. Generates SQL, validates
-- it via EXPLAIN, and retries with the planner feedback up to max_retries.
-- With auto_execute=true the final statement is run through SPI and the
-- row result is returned in result_json.
CREATE FUNCTION fractal_sql_agent(
    question      text,
    table_names   text[] DEFAULT NULL,
    max_retries   int4  DEFAULT 2,
    auto_execute  bool  DEFAULT false
) RETURNS fractal_sql_agent_result
AS 'MODULE_PATHNAME', 'fractal_sql_agent'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_sql_agent(question text, table_names text[], max_retries int4, auto_execute bool) IS
'Self-correcting Text-to-SQL: generates SQL, validates via EXPLAIN, retries with feedback up to max_retries. With auto_execute=true, runs the final SQL via SPI.';

-- fractal_agent_plan_explore: MCTS-style exploration of diverse strategy
-- trajectories from initial_state over strategy_table.vector_col. Returns
-- one row per explored branch (SETOF).
CREATE FUNCTION fractal_agent_plan_explore(
    initial_state    text,
    strategy_table   text,
    vector_col       text,
    max_branches     int4
) RETURNS SETOF fractal_plan_explore_result
AS 'MODULE_PATHNAME', 'fractal_agent_plan_explore'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_agent_plan_explore(initial_state text, strategy_table text, vector_col text, max_branches int4) IS
'MCTS-style exploration of diverse strategy trajectories from initial_state over strategy_table.vector_col. Returns one row per branch.';

-- fractal_agent_trajectory_predict: forecast a future state vector by
-- extrapolating the delta from baseline_id and searching the corpus for
-- the nearest predicted state. Resolves table_name's primary key via
-- pg_catalog, reads the baseline row (PK = baseline_id) and the current
-- row (max PK) via SPI, derives dim from the baseline vector, computes a
-- real delta (current - baseline), and Scout-searches the corpus for the
-- nearest point to that delta. Returns the real predicted state vector,
-- the real drift distance, and whether it exceeds the 0.5 risk threshold.
CREATE FUNCTION fractal_agent_trajectory_predict(
    table_name      text,
    vector_col      text,
    baseline_id     int8,
    forecast_steps  int4
) RETURNS fractal_trajectory_predict_result
AS 'MODULE_PATHNAME', 'fractal_agent_trajectory_predict'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_agent_trajectory_predict(table_name text, vector_col text, baseline_id int8, forecast_steps int4) IS
'Forecast a future state vector by extrapolating the real delta (current - baseline, both read from table_name.vector_col via SPI, keyed by baseline_id and the max primary key) and searching the corpus for the nearest predicted state. Returns (predicted_state_vector, projected_drift_delta, risk_threshold_exceeded), all real computed values.';

-- fractal_agent_detect_loop: DFA-based safety monitor. Analyzes the
-- scaling exponent (alpha) of an agent state-hash sequence (int8[]) to
-- detect infinite loops (alpha > 0.9).
CREATE FUNCTION fractal_agent_detect_loop(
    log_arr int8[]
) RETURNS fractal_loop_detect_result
AS 'MODULE_PATHNAME', 'fractal_agent_detect_loop'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_agent_detect_loop(log_arr int8[]) IS
'DFA-based safety monitor: analyzes the scaling exponent of an agent state-hash sequence (int8[]) to detect infinite loops (alpha > 0.9).';

-- fractal_rag_agent: hybrid retrieve -> reason agent. Embeds the query,
-- Scout-searches table_name.vector_col (meta_filter reserved for a future
-- metadata WHERE filter), then reasons over the retrieved context. No
-- result type was predeclared, so add one here (single text answer).
CREATE TYPE fractal_rag_agent_result AS (
    answer text
);

CREATE FUNCTION fractal_rag_agent(
    query        text,
    table_name   text,
    vector_col   text,
    meta_filter  text DEFAULT '{}'
) RETURNS fractal_rag_agent_result
AS 'MODULE_PATHNAME', 'fractal_rag_agent'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_rag_agent(query text, table_name text, vector_col text, meta_filter text) IS
'Hybrid RAG agent: embeds the query, Scout-searches table_name.vector_col (meta_filter reserved for a future WHERE filter), then reasons over the retrieved context. Returns a single answer.';

-- ------------------------------------------------------------------
-- Vectorizer -- trigger + queue table + one callable function, no

-- background worker, no hard scheduler dependency.
-- Pure SQL/PL/pgSQL (no new C symbols) -- fractal_embed() above is the
-- only C-level piece this depends on.
-- ------------------------------------------------------------------

CREATE TABLE fractal_vectorizers (
    id             bigserial PRIMARY KEY,
    source_table   text    NOT NULL,
    source_pk_col  text    NOT NULL,
    text_col       text    NOT NULL,
    embedding_col  text    NOT NULL,
    options        jsonb   NOT NULL DEFAULT '{}'::jsonb,
    -- Pause/resume: false stops BOTH future enqueueing (the trigger
    -- no-ops) AND processing of already-pending rows (process_queue()'s
    -- join excludes it) -- a full pause, not just "stop enqueueing" --
    -- see fractal_vectorizer_pause()/_resume() below. Defaults true so
    -- every existing vectorizer keeps v1.0 behavior unchanged.
    enabled        boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_table, text_col, embedding_col)
);

COMMENT ON TABLE fractal_vectorizers IS
  'One row per fractal_vectorizer_create() call -- which table/columns '
  'are being kept embedded, and how. See fractal_vectorizer_queue for '
  'the actual work queue and fractal_vectorizer_status for observability.';

-- fractal_vectorizer_create() stays SECURITY INVOKER (unlike the enqueue
-- trigger below) -- its own CREATE TRIGGER step is what actually
-- enforces "caller must own source_table", via Postgres's normal DDL
-- privilege model. That check only works correctly under INVOKER
-- semantics; making this function SECURITY DEFINER would let any role
-- install a trigger on any table by riding the definer's privileges,
-- which would be a real escalation, not a fix. Because of that, the
-- calling role still needs its own grant here for the config-row
-- INSERT to succeed -- safe to open broadly: a row can only ever be
-- durably committed if the CREATE TRIGGER step also succeeded in the
-- same function call (same transaction, so a DDL failure there rolls
-- the INSERT back too), so table ownership is still the real gate.
--
-- UPDATE is granted too (not just SELECT/INSERT) so fractal_vectorizer_
-- pause()/_resume() below -- and the `enabled` column they toggle -- work
-- for any role, not just the table owner. Accepted tradeoff, same shape
-- as the INSERT-abuse note on fractal_vectorizer_queue below: any role
-- can pause or resume ANY vectorizer by id, not just its own. Bounded
-- impact -- it only ever stops/starts that vectorizer's future
-- enqueue+processing (a denial-of-service on someone else's vectorizer,
-- not a data leak, and instantly fixable by calling _resume() again).
-- Revoke UPDATE and grant it per-role explicitly instead if that's not
-- acceptable for a given deployment.
GRANT SELECT, INSERT, UPDATE ON fractal_vectorizers TO PUBLIC;
GRANT USAGE ON fractal_vectorizers_id_seq TO PUBLIC;

CREATE TABLE fractal_vectorizer_queue (
    id                     bigserial PRIMARY KEY,
    vectorizer_id          bigint NOT NULL REFERENCES fractal_vectorizers(id) ON DELETE CASCADE,
    source_pk_value        text   NOT NULL,
    status                 text   NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'processing', 'done', 'failed')),
    error                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    processing_started_at  timestamptz,
    updated_at             timestamptz NOT NULL DEFAULT now()
);

-- Covers both 'pending' AND 'processing' (not just 'pending') so a
-- source-row UPDATE that fires while a previous embed for that same row
-- is still in flight doesn't insert a second, redundant queue entry for
-- it -- closes the race window, not just the steady-state duplicate case.
CREATE UNIQUE INDEX fractal_vectorizer_queue_pending_uniq
    ON fractal_vectorizer_queue (vectorizer_id, source_pk_value)
    WHERE status IN ('pending', 'processing');

CREATE INDEX fractal_vectorizer_queue_pending_scan
    ON fractal_vectorizer_queue (created_at)
    WHERE status = 'pending';

COMMENT ON TABLE fractal_vectorizer_queue IS
  'Work queue for the vectorizer. A status column + timestamp does the '
  'job at this scale -- no pgmq dependency for v1 (visibility timeouts / '
  'delivery guarantees are an easy later upgrade if real volume ever '
  'demands it).';

-- INSERT is granted broadly too, deliberately, not locked down to the
-- SECURITY DEFINER trigger above -- fractal_vectorizer_create()'s own
-- backfill step also inserts directly, under INVOKER security (it has
-- to stay INVOKER, same reasoning as fractal_vectorizer_create() itself
-- below: a SECURITY DEFINER helper taking table/column names as plain
-- arguments would let ANY role read ANY table by calling it directly
-- with someone else's table name, riding the definer's privileges --
-- a real escalation, considered and rejected here, not an oversight).
-- Given that constraint, direct INSERT has to be broadly grantable for
-- backfill to work for non-owner-of-this-table roles at all. The actual
-- blast radius of that is bounded: a role can insert a queue row
-- pointing at ANY vectorizer_id/pk_value, but fractal_vectorizer_
-- process_queue() (SECURITY INVOKER) only ever reads/embeds a row's
-- real content using the PROCESSING role's own SELECT grant on that
-- row's source table -- an injected row for a table the processor
-- can't see fails that row cleanly (marked 'failed', no data returned),
-- and one for a real row the processor CAN see just causes redundant
-- (not unauthorized) work. Net effect of abuse: wasted embedding-API
-- calls/cost on someone else's queue, not a confidentiality break. See
-- docs/vectorizer-setup.md's "Open questions" for this as a documented
-- characteristic, not a fixed guarantee.
GRANT SELECT, INSERT, UPDATE ON fractal_vectorizer_queue TO PUBLIC;
GRANT USAGE ON fractal_vectorizer_queue_id_seq TO PUBLIC;

-- Generic per-table trigger function (one definition, reused by every
-- vectorized table via its own CREATE TRIGGER call passing vectorizer_id
-- and the PK column name as trigger arguments -- avoids a catalog
-- lookup on every single row write). to_jsonb(NEW)->>pk_col extracts
-- the PK value generically regardless of the source table's actual
-- column set or PK type.
-- SECURITY DEFINER: any role with INSERT/UPDATE on a vectorized source
-- table must be able to fire this trigger, but by default (SECURITY
-- INVOKER) it would need its own direct grant on fractal_vectorizer_queue
-- too -- an ordinary application role writing its own table would hit
-- "permission denied for table fractal_vectorizer_queue" on every write,
-- breaking the write itself (the trigger runs in the same transaction),
-- not just silently skipping vectorization. Safe to elevate here
-- specifically because: (a) it only ever inserts a tracking row built
-- from NEW, data the invoking role already legitimately wrote/saw via
-- its own privilege on the source table -- no new data exposure; (b)
-- vectorizer_id and pk_col come from the TRIGGER DEFINITION (fixed at
-- fractal_vectorizer_create() time by whoever owned the table then),
-- never from the invoking role at fire-time, so a write on table A can
-- never be redirected to enqueue against table B's or another
-- vectorizer's queue rows. SET search_path pinned per SECURITY DEFINER
-- best practice (see CREATE FUNCTION docs) so a role that can create
-- objects earlier in some other search_path can't shadow anything this
-- function resolves unqualified.
CREATE FUNCTION fractal_vectorizer_enqueue() RETURNS trigger
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_id      bigint := TG_ARGV[0]::bigint;
    pk_col    text   := TG_ARGV[1];
    pk_val    text;
    v_enabled boolean;
BEGIN
    -- Paused vectorizer: no-op, not an error -- the write to the source
    -- table itself must still succeed. COALESCE(..., false) so a
    -- vectorizer row deleted out from under a still-installed trigger
    -- (shouldn't happen, ON DELETE CASCADE drops the trigger's table
    -- row set together, but not the trigger object itself if the source
    -- table survives some other way) fails safe by not enqueueing,
    -- rather than raising inside every write to the source table.
    SELECT enabled INTO v_enabled FROM fractal_vectorizers WHERE id = v_id;
    IF NOT COALESCE(v_enabled, false) THEN
        RETURN NEW;
    END IF;

    pk_val := (to_jsonb(NEW) ->> pk_col);
    INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value)
    VALUES (v_id, pk_val)
    ON CONFLICT (vectorizer_id, source_pk_value)
        WHERE status IN ('pending', 'processing')
        DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION fractal_vectorizer_create(
    source_table  text,
    text_col      text,
    embedding_col text,
    options       jsonb DEFAULT '{}'::jsonb
) RETURNS bigint AS $$
DECLARE
    v_id        bigint;
    v_pk_col    text;
    v_trg       text;
    v_tbl_ident text;
BEGIN
    -- Canonicalize source_table through ::regclass ONCE, up front, and
    -- use its text form (v_tbl_ident) for every dynamic-SQL identifier
    -- slot below via %s, never %I again. Why: regclass's own text output
    -- already quotes-and-escapes a name correctly IF it needs it --
    -- Postgres's own "safe to interpolate" form for a relation name, the
    -- same mechanism \d/pg_dump rely on -- so passing that value through
    -- %I a second time would double-quote it (confirmed live: an exotic
    -- table name -- one containing an embedded double-quote -- passed in
    -- its only valid ::regclass-resolvable form broke the later %I-based
    -- CREATE TRIGGER with a "relation does not exist" error; never an
    -- injection -- every failure mode here is a clean error with
    -- fractal_vectorizers/fractal_vectorizer_queue provably untouched,
    -- just a real usability bug for anyone with a name needing SQL
    -- quoting). Incidentally also fixes schema-qualified callers
    -- (`fractal_vectorizer_create('myschema.my_table', ...)`), which the
    -- old raw-%I-on-the-dotted-string code would have wrongly quoted as
    -- one single (and therefore nonexistent) identifier.
    v_tbl_ident := source_table::regclass::text;

    -- Single-column primary key only, in v1 -- a composite or missing
    -- PK has no single generic value to key the queue on. Introspected
    -- so callers don't have to name it themselves.
    SELECT a.attname INTO v_pk_col
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = source_table::regclass
      AND i.indisprimary
      AND cardinality(i.indkey) = 1;

    IF v_pk_col IS NULL THEN
        RAISE EXCEPTION 'fractal_vectorizer_create: % has no single-column primary key '
            '(composite and missing-PK tables are not supported in v1)', v_tbl_ident;
    END IF;

    BEGIN
        INSERT INTO fractal_vectorizers (source_table, source_pk_col, text_col, embedding_col, options)
        VALUES (v_tbl_ident, v_pk_col, text_col, embedding_col, options)
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        -- Same (source_table, text_col, embedding_col) triple already has
        -- a vectorizer. Re-raised as a clear, fractal_-prefixed message
        -- naming the existing vectorizer's id (findable in
        -- fractal_vectorizer_status), matching this file's own error-
        -- message convention -- not the raw "duplicate key value
        -- violates unique constraint ..." text, which leaks the
        -- constraint's internal name and a PL/pgSQL stack frame.
        SELECT fv.id INTO v_id FROM fractal_vectorizers fv
         WHERE fv.source_table = v_tbl_ident
           AND fv.text_col = fractal_vectorizer_create.text_col
           AND fv.embedding_col = fractal_vectorizer_create.embedding_col;
        RAISE EXCEPTION 'fractal_vectorizer_create: a vectorizer for %.% -> % already exists (id=%)',
            v_tbl_ident, text_col, embedding_col, v_id;
    END;

    v_trg := format('fractal_vectorizer_trg_%s', v_id);
    EXECUTE format(
        'CREATE TRIGGER %I AFTER INSERT OR UPDATE OF %I ON %s '
        'FOR EACH ROW EXECUTE FUNCTION fractal_vectorizer_enqueue(%L, %L)',
        v_trg, text_col, v_tbl_ident, v_id::text, v_pk_col);

    -- Backfill: queue existing rows that don't have an embedding yet,
    -- not the whole table -- a vectorizer retrofitted onto a table that
    -- already has some embeddings shouldn't redo them.
    EXECUTE format(
        'INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value) '
        'SELECT %L, %I::text FROM %s WHERE %I IS NULL AND %I IS NOT NULL '
        'ON CONFLICT (vectorizer_id, source_pk_value) '
        '  WHERE status IN (''pending'', ''processing'') DO NOTHING',
        v_id, v_pk_col, v_tbl_ident, embedding_col, text_col);

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_vectorizer_create(text, text, text, jsonb) IS
  'Start keeping embedding_col in sync with text_col on source_table: '
  'installs an AFTER INSERT/UPDATE trigger that queues rows on write, '
  'and immediately backfills any existing rows missing an embedding. '
  'Requires source_table to have a single-column primary key. Returns '
  'the new vectorizer id. Call fractal_vectorizer_process_queue() on '
  'whatever schedule fits your platform (pg_cron, OS cron, Windows Task '
  'Scheduler, your own app scheduler -- this function installs no '
  'scheduler of its own) to actually generate the embeddings.';

-- SECURITY INVOKER (default) -- a plain UPDATE against a table PUBLIC
-- already has UPDATE on (see the grant above), no elevation needed.
-- Idempotent (pausing an already-paused vectorizer is a no-op, not an
-- error) -- the only real failure mode is an id that doesn't exist.
CREATE FUNCTION fractal_vectorizer_pause(vectorizer_id bigint) RETURNS void AS $$
BEGIN
    UPDATE fractal_vectorizers SET enabled = false WHERE id = vectorizer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fractal_vectorizer_pause: no vectorizer with id %', vectorizer_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_vectorizer_pause(bigint) IS
  'Stops a vectorizer without dropping its config: the enqueue trigger '
  'stops queueing new rows AND fractal_vectorizer_process_queue() stops '
  'processing its already-pending rows -- a full pause, not just a '
  'future-writes pause. Existing pending/done/failed queue rows are '
  'untouched and left exactly where they are. Reverse with '
  'fractal_vectorizer_resume(). Typical use: the upstream embedding '
  'endpoint is down or rate-limiting hard and you want process_queue() '
  'to stop throwing per-row failures into fractal_vectorizer_status '
  'until it recovers.';

CREATE FUNCTION fractal_vectorizer_resume(vectorizer_id bigint) RETURNS void AS $$
BEGIN
    UPDATE fractal_vectorizers SET enabled = true WHERE id = vectorizer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fractal_vectorizer_resume: no vectorizer with id %', vectorizer_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_vectorizer_resume(bigint) IS
  'Reverses fractal_vectorizer_pause(): the enqueue trigger resumes '
  'queueing new rows on write, and fractal_vectorizer_process_queue() '
  'resumes processing this vectorizer''s pending rows -- whatever was '
  'already queued before the pause (nothing new could queue while '
  'paused, since the trigger itself was a no-op for the whole '
  'duration), picked up on the next process_queue() call.';

-- Per-vectorizer rolling-window embed-call counter, consulted by
-- fractal_vectorizer_process_queue() below when a vectorizer's own
-- `options` sets max_embeds_per_window. One row per vectorizer that has
-- ever had a capped call (not pre-populated for every vectorizer --
-- see the INSERT ... ON CONFLICT DO NOTHING in process_queue()).
--
-- Why this can't just be a process_queue() parameter (a per-call
-- batch_size-style cap): a parameter only bounds a SINGLE call. A tight
-- cron calling process_queue() every minute forever has no aggregate
-- cap at all today -- it relies entirely on the provider's own rate
-- limiting plus fractalsql-reasoning-http's retry/backoff (see
-- docs/vectorizer-setup.md's former "no spend or rate cap" open
-- question). Only a counter that PERSISTS across calls can actually cap
-- a rate over time, hence a table instead of a variable.
CREATE TABLE fractal_vectorizer_rate_window (
    vectorizer_id  bigint PRIMARY KEY REFERENCES fractal_vectorizers(id) ON DELETE CASCADE,
    window_start   timestamptz NOT NULL DEFAULT now(),
    window_calls   int NOT NULL DEFAULT 0
);

COMMENT ON TABLE fractal_vectorizer_rate_window IS
  'Rolling-window embed-call counter for vectorizers with '
  'options.max_embeds_per_window set. Reset automatically once '
  'options.rate_window_secs (default 3600) elapses since window_start.';

-- Same broad-grant-with-documented-blast-radius shape as
-- fractal_vectorizer_queue below: any role calling process_queue() may
-- need to read/increment ANY vectorizer's counter in the same batch
-- (a batch can span multiple vectorizers), so this can't be locked to
-- one role without breaking that. Worst case from abuse is a role
-- resetting/inflating someone else's counter to fight their cap --
-- annoying, not a data leak.
GRANT SELECT, INSERT, UPDATE ON fractal_vectorizer_rate_window TO PUBLIC;

CREATE FUNCTION fractal_vectorizer_process_queue(
    batch_size int      DEFAULT 100,
    stale_after interval DEFAULT '10 minutes'
) RETURNS int AS $$
DECLARE
    r              record;
    n_processed    int := 0;
    v_text         text;
    vec            float8[];
    v_max_calls    int;
    v_window_secs  int;
    v_window_start timestamptz;
    v_window_calls int;
BEGIN
    -- Reclaim rows stranded in 'processing' by a caller that crashed or
    -- was killed mid-batch -- SELECT ... FOR UPDATE SKIP LOCKED only
    -- protects against concurrent callers racing each other, not against
    -- a caller that claimed a row and then never came back.
    UPDATE fractal_vectorizer_queue
       SET status = 'pending', processing_started_at = NULL
     WHERE status = 'processing'
       AND processing_started_at < now() - stale_after;

    FOR r IN
        SELECT q.id, q.vectorizer_id, q.source_pk_value,
               v.source_table, v.source_pk_col, v.text_col, v.embedding_col,
               v.options
        FROM fractal_vectorizer_queue q
        JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
        WHERE q.status = 'pending'
          AND v.enabled
        ORDER BY q.created_at
        FOR UPDATE OF q SKIP LOCKED
        LIMIT batch_size
    LOOP
        -- Per-vectorizer rate cap, read from `options` fresh on every
        -- row (not cached across the loop) so a cap edited mid-batch
        -- takes effect on the very next row, and so a batch mixing rows
        -- from several vectorizers applies each one's own cap
        -- correctly. No-op (v_max_calls IS NULL) for any vectorizer
        -- that hasn't set options.max_embeds_per_window -- bit-for-bit
        -- unchanged behavior for every existing vectorizer.
        v_max_calls := (r.options ->> 'max_embeds_per_window')::int;

        IF v_max_calls IS NOT NULL THEN
            v_window_secs := COALESCE((r.options ->> 'rate_window_secs')::int, 3600);

            INSERT INTO fractal_vectorizer_rate_window (vectorizer_id, window_start, window_calls)
            VALUES (r.vectorizer_id, now(), 0)
            ON CONFLICT (vectorizer_id) DO NOTHING;

            SELECT window_start, window_calls INTO v_window_start, v_window_calls
            FROM fractal_vectorizer_rate_window
            WHERE vectorizer_id = r.vectorizer_id
            FOR UPDATE;

            IF now() - v_window_start > make_interval(secs => v_window_secs) THEN
                v_window_start := now();
                v_window_calls := 0;
            END IF;

            IF v_window_calls >= v_max_calls THEN
                -- Cap hit for this vectorizer's current window: leave
                -- the row 'pending' (still untouched -- it was never
                -- moved to 'processing') and move on to the next queue
                -- row, which may belong to a different, uncapped (or
                -- not-yet-capped-out) vectorizer. Not counted in
                -- n_processed -- it wasn't processed, just deferred.
                CONTINUE;
            END IF;

            UPDATE fractal_vectorizer_rate_window
               SET window_start = v_window_start, window_calls = v_window_calls + 1
             WHERE vectorizer_id = r.vectorizer_id;
        END IF;

        UPDATE fractal_vectorizer_queue
           SET status = 'processing', processing_started_at = now()
         WHERE id = r.id;

        BEGIN
            -- Cast the PK column to text for the comparison (rather than
            -- casting source_pk_value to the column's actual type) so
            -- this works generically across int/bigint/uuid/text PKs
            -- without a catalog lookup for the PK's type. Correctness
            -- over index-usability in this v1.
            --
            -- %s (not %I) for r.source_table -- it's already the
            -- canonical, self-quoted ::regclass text form stored by
            -- fractal_vectorizer_create(), so %I would double-quote it.
            -- See that function's v_tbl_ident comment for why.
            EXECUTE format('SELECT %I FROM %s WHERE %I::text = $1',
                           r.text_col, r.source_table, r.source_pk_col)
                INTO v_text USING r.source_pk_value;

            IF v_text IS NULL THEN
                -- Source row deleted, or its text column went NULL,
                -- since this queue entry was created -- nothing to
                -- embed, not a failure.
                UPDATE fractal_vectorizer_queue
                   SET status = 'done', updated_at = now(), error = NULL
                 WHERE id = r.id;
            ELSE
                vec := fractal_embed(v_text);
                EXECUTE format('UPDATE %s SET %I = $1 WHERE %I::text = $2',
                               r.source_table, r.embedding_col, r.source_pk_col)
                    USING vec, r.source_pk_value;
                UPDATE fractal_vectorizer_queue
                   SET status = 'done', updated_at = now(), error = NULL
                 WHERE id = r.id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- A bad row (rate limit, malformed input, deleted table)
            -- must not stall the whole batch -- mark it failed and
            -- visible in fractal_vectorizer_status, move on. PL/pgSQL's
            -- exception block is itself a subtransaction, so this rolls
            -- back only this row's own failed work, not the batch.
            UPDATE fractal_vectorizer_queue
               SET status = 'failed', error = SQLERRM, updated_at = now()
             WHERE id = r.id;
        END;

        n_processed := n_processed + 1;
    END LOOP;

    RETURN n_processed;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_vectorizer_process_queue(int, interval) IS
  'Process up to batch_size pending queue rows: read the source text, '
  'call fractal_embed(), write the vector back, mark done or failed. '
  'Safe to call concurrently (SELECT ... FOR UPDATE SKIP LOCKED) and on '
  'any schedule you like -- this extension installs no scheduler of its '
  'own. Also reclaims rows stuck in ''processing'' for longer than '
  'stale_after (a caller that crashed mid-batch). Skips any vectorizer '
  'paused via fractal_vectorizer_pause(), and honors a per-vectorizer '
  'options.max_embeds_per_window rate cap if one is set (see '
  'fractal_vectorizer_rate_window). Returns the number of rows actually '
  'processed (done + failed), not just successes -- a row deferred by '
  'the rate cap or belonging to a paused vectorizer isn''t counted.';

CREATE VIEW fractal_vectorizer_status AS
SELECT v.id AS vectorizer_id,
       v.source_table,
       v.text_col,
       v.embedding_col,
       v.enabled,
       q.status,
       count(*) AS n,
       max(q.updated_at) FILTER (WHERE q.status = 'failed') AS last_failure_at,
       (array_agg(q.error ORDER BY q.updated_at DESC)
           FILTER (WHERE q.status = 'failed'))[1] AS last_error
FROM fractal_vectorizers v
JOIN fractal_vectorizer_queue q ON q.vectorizer_id = v.id
GROUP BY v.id, v.source_table, v.text_col, v.embedding_col, v.enabled, q.status;

COMMENT ON VIEW fractal_vectorizer_status IS
  'pending/processing/done/failed counts per vectorizer, plus whether '
  'it''s currently paused (fractal_vectorizer_pause()) and the most '
  'recent failure''s error message -- the direct answer to "is my '
  'backfill actually making progress" without querying the tracking '
  'tables directly.';

-- Broad SELECT here does mean any role can see every vectorizer's
-- source_table/text_col/embedding_col names and recent error text, not
-- just their own -- a minor metadata-disclosure tradeoff (table/column
-- NAMES, not row data) accepted for the same "just works for any role
-- that can already create/process a vectorizer" usability reason as
-- the grants above. Revoke and grant per-role explicitly instead if
-- that's not acceptable for a given deployment.
GRANT SELECT ON fractal_vectorizer_status TO PUBLIC;

-- v2.x additions -- Diversify/Repulsion controls, feedback, fractal-
-- dimension analysis, portfolio optimization, domain-specific geometry,
-- and the named feature store. All C functions here wrap the sovereign-
-- tier v2.x core ABI (see include/fractalsql_sql.h) except the feature
-- store, which is postgres-side only. Runs to EOF -- extracted verbatim
-- by build_test.sh's pg_setup() (MODULE_PATHNAME substituted for $SO),
-- same low-drift pattern as the Vectorizer section above.

-- ----- Diversify / Repulsion controls ---------------------------------

CREATE FUNCTION fractal_diversify_enable() RETURNS void
AS 'MODULE_PATHNAME', 'fractal_diversify_enable'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_diversify_enable() IS
  'Enables the Diversify/Repulsion layer on this session''s search '
  'context: fractal_search results start avoiding candidates near '
  'shadows recorded via fractal_feedback_report/fractal_isolate_background. '
  'Disabled by default (bit-for-bit identical to v1.0 behavior).';

CREATE FUNCTION fractal_diversify_disable() RETURNS void
AS 'MODULE_PATHNAME', 'fractal_diversify_disable'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_diversify_disable() IS
  'Disables the Diversify/Repulsion layer on this session''s search context.';

CREATE FUNCTION fractal_diversify_set_params(
    window_n               int4   DEFAULT NULL,
    stall_threshold        float8 DEFAULT NULL,
    repulsion_sigma        float8 DEFAULT NULL,
    repulsion_weight       float8 DEFAULT NULL,
    max_shadows_considered int4   DEFAULT NULL,
    tail_buffer_cap        int4   DEFAULT NULL
) RETURNS void
AS 'MODULE_PATHNAME', 'fractal_diversify_set_params'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_diversify_set_params(int4, float8, float8, float8, int4, int4) IS
  'Tunes Diversify/Repulsion parameters. Each argument left NULL keeps '
  'the core''s current value for that field; only supplied fields are '
  'overridden. Takes effect on the next fractal_search call.';

CREATE FUNCTION fractal_detect_collapse() RETURNS float8
AS 'MODULE_PATHNAME', 'fractal_detect_collapse'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_detect_collapse() IS
  'Current D_q (diversity quotient) from the last search on this '
  'session''s context. Low values indicate the search population has '
  'collapsed toward a single basin. Returns NaN if no search has run '
  'yet or Diversify is disabled.';

CREATE FUNCTION fractal_explain_result() RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_explain_result'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_explain_result() IS
  'Session-level Diversify diagnostics: {dq, diversify_enabled, '
  'overhead_p99_us}. NOT a per-candidate "this result was penalized by '
  'shadow X" trace -- the core ABI does not currently expose shadow '
  'attribution at that granularity.';

-- ----- Feedback --------------------------------------------------------

CREATE FUNCTION fractal_feedback_report(
    result_handle int8,
    kind          text,
    dwell_ms      int4 DEFAULT NULL
) RETURNS void
AS 'MODULE_PATHNAME', 'fractal_feedback_report'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_feedback_report(int8, text, int4) IS
  'Reports engagement on a prior search result (result_handle: the '
  'corpus row index it came from). kind is one of ''dwell'', ''positive'', '
  '''negative''. Feeds the Diversify/Repulsion shadow store when enabled; '
  'inert otherwise.';

CREATE FUNCTION fractal_isolate_background(result_handle int8) RETURNS void
AS 'MODULE_PATHNAME', 'fractal_isolate_background'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_isolate_background(int8) IS
  'Convenience wrapper: reports negative engagement on result_handle '
  '(no dwell time). Inert until fractal_diversify_enable() has been '
  'called on this session.';

-- ----- Fractal Dimension Analysis ---------------------------------------

CREATE FUNCTION fractal_dimension_dfa(series float8[]) RETURNS float8
AS 'MODULE_PATHNAME', 'fractal_dimension_dfa'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_dimension_dfa(float8[]) IS
  'Detrended Fluctuation Analysis scaling exponent (Peng et al. 1994) '
  'for a numeric, time-ordered series. ~0.5 uncorrelated, ~1.0 1/f '
  '"pink" noise, ~1.5 Brownian motion/random walk. Requires >= 16 points.';

CREATE FUNCTION fractal_dimension_boxcount(points float8[], dim int4) RETURNS float8
AS 'MODULE_PATHNAME', 'fractal_dimension_boxcount'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_dimension_boxcount(float8[], int4) IS
  'Box-counting (Minkowski-Bouligand) fractal dimension. points is a '
  'flat, row-major array of n_points * dim doubles. Requires >= 8 '
  'points and a non-degenerate bounding box.';

CREATE FUNCTION fractal_dimension_drift(series float8[], win int4) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_dimension_drift'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_dimension_drift(float8[], int4) IS
  'DFA drift between a series'' recent `win` points and everything '
  'before them. Returns {drift, recent_alpha, baseline_alpha}. Positive '
  'drift = increasing complexity/irregularity. Requires n >= win + 16, '
  'win >= 16. (Parameter named "win" not "window" -- the latter is a '
  'reserved SQL keyword.)';

-- ----- Portfolio Optimization --------------------------------------------

CREATE FUNCTION fractal_optimize_portfolio(
    mu              float8[],
    cov             float8[],
    k               int4,
    seed            int8 DEFAULT NULL,
    use_obl         boolean DEFAULT false,
    diffusion_mode  text    DEFAULT 'gaussian'
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_optimize_portfolio'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_optimize_portfolio(float8[], float8[], int4, int8, boolean, text) IS
  'Cardinality-constrained Sharpe-ratio maximization. mu: n_assets '
  'expected returns. cov: flat, row-major n_assets x n_assets covariance '
  'matrix. k: at most k of n_assets get nonzero weight (1 <= k <= '
  'n_assets). use_obl: apply Opposition-Based Learning to each SFS trial '
  'candidate (evaluate both the candidate and its bound-reflected opposite, '
  'keep whichever fits better) -- off by default, doubles fitness-eval cost '
  'of the affected step when enabled. diffusion_mode: ''gaussian'' (default, '
  'canonical SFS) or ''levy'' (heavy-tailed Mantegna steps, can help escape '
  'local optima on highly multimodal problems). Returns {sharpe, weights}. '
  'Uses the SFS engine internally (~28x faster than scipy '
  'differential_evolution for near-equal quality on this problem class, '
  'validated separately from core''s vector search retrieval).';

CREATE FUNCTION fractal_optimize_portfolio_multimodal(
    mu                float8[],
    cov               float8[],
    k                 int4,
    n_restarts        int4   DEFAULT 8,
    overlap_threshold float8 DEFAULT 0.15,
    quality_frac      float8 DEFAULT 0.90,
    seed              int8   DEFAULT NULL,
    use_obl           boolean DEFAULT false,
    diffusion_mode    text    DEFAULT 'gaussian'
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_optimize_portfolio_multimodal'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_optimize_portfolio_multimodal(float8[], float8[], int4, int4, float8, float8, int8, boolean, text) IS
  'Enterprise tier. Like fractal_optimize_portfolio but returns up to '
  'n_restarts structurally distinct candidates instead of one: each a '
  'portfolio within quality_frac of the best Sharpe found, no two '
  'sharing more than overlap_threshold of their selected assets. use_obl/'
  'diffusion_mode: same OBL/Lévy-flight knobs as fractal_optimize_portfolio, '
  'applied uniformly to every restart -- requires an enterprise core build '
  'with OBL/Lévy-flight support; omit both (or leave at their defaults) '
  'against an older enterprise_lib. Returns '
  '{candidates: [{sharpe, weights}, ...], n_found}. Errors with '
  '''enterprise tier not loaded'' until fractalsql.enterprise_lib is set.';

CREATE FUNCTION fractal_optimize_portfolio_multimodal_pareto(
    mu              float8[],
    cov             float8[],
    k               int4,
    n_restarts      int4 DEFAULT 8,
    max_front       int4 DEFAULT 8,
    seed            int8 DEFAULT NULL,
    use_obl         boolean DEFAULT false,
    diffusion_mode  text    DEFAULT 'gaussian'
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_optimize_portfolio_multimodal_pareto'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_optimize_portfolio_multimodal_pareto(float8[], float8[], int4, int4, int4, int8, boolean, text) IS
  'Enterprise tier. Pareto-front sibling of fractal_optimize_portfolio_multimodal: '
  'runs the same n_restarts independent searches, but scores each by decomposed '
  '(return, risk) instead of scalar Sharpe and reduces them to a genuine non-'
  'dominated Pareto front (NSGA-II crowding-distance truncation if the front '
  'exceeds max_front, 1 <= max_front <= n_restarts) instead of the sharpe-'
  'threshold + asset-overlap selection the sharpe-mode function uses. Does not '
  'change that function''s selection semantics or output shape -- purely additive. '
  'use_obl/diffusion_mode: same OBL/Lévy-flight knobs as '
  'fractal_optimize_portfolio, applied uniformly to every restart. Returns '
  '{candidates: [{return, risk, sharpe, weights}, ...], n_found} where '
  'sharpe = return/risk is informational, not the selection criterion. Errors '
  'with ''enterprise tier not loaded'' until fractalsql.enterprise_lib is set.';

-- ----- Domain-specific geometric/topological metrics ---------------------
-- Scope boundary: all four take PRE-EXTRACTED geometry (vessel graphs,
-- meshes, skeleton graphs, point-cloud masks), not raw medical imaging
-- data. Segmentation/extraction from raw imaging is a categorically
-- different, much larger problem, out of scope here.

CREATE FUNCTION fractal_vascular_network(
    node_coords     float8[],
    edges           int4[],
    edge_arc_length float8[]
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_vascular_network'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_vascular_network(float8[], int4[], float8[]) IS
  'Vessel-network tortuosity/branch-density/dimension. node_coords: flat '
  'n_nodes * 3 (x,y,z). edges: flat n_edges * 2 node-index pairs. '
  'edge_arc_length: n_edges true centerline arc lengths (from an '
  'upstream centerline trace, e.g. VMTK). Returns {mean_tortuosity, '
  'branch_density, fractal_dimension}.';

CREATE FUNCTION fractal_cortical_folding(
    vertices float8[],
    faces    int4[]
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_cortical_folding'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_cortical_folding(float8[], int4[]) IS
  'Gyrification Index (Zilles et al. 1988): mesh surface area / convex '
  'hull surface area. vertices: flat n_vertices * 3. faces: flat '
  'n_faces * 3 triangle vertex indices. Returns {mesh_area, hull_area, '
  'gyrification_index}. Requires >= 4 non-coplanar vertices.';

CREATE FUNCTION fractal_nerve_plexus_metric(
    node_coords float8[],
    dim         int4,
    edges       int4[]
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_nerve_plexus_metric'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_nerve_plexus_metric(float8[], int4, int4[]) IS
  'Nerve fiber plexus metrics (corneal confocal microscopy convention). '
  'node_coords: flat n_nodes * dim (dim typically 2). edges: flat '
  'n_edges * 2 node-index pairs. Returns {fiber_length_density, '
  'branch_density, fractal_dimension}.';

CREATE FUNCTION fractal_morphological_complexity(
    points float8[],
    dim    int4
) RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_morphological_complexity'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION fractal_morphological_complexity(float8[], int4) IS
  'Morphological complexity of a pre-segmented mask: box-counting '
  'dimension + fixed-grid lacunarity. points: flat n_points * dim '
  'occupied mask points. Returns {dimension, lacunarity}.';

-- ----- Named feature store -------------------------------------------------
-- fractal_store_morphology / fractal_mine_topology_negatives were originally
-- scoped to a core ledger primitive (arbitrary per-item storage, shadow-
-- vector read-back) that doesn't exist in fsql_ledger_* (whole-ledger admin
-- + two counters only, in any edition). Implemented entirely at this layer
-- instead: a plain table holding one caller-supplied vector per doc_id, and
-- a brute-force k-NN scan over it. Independent of core's ledger/repulsion
-- mechanism.

CREATE TABLE fractalsql_feature_store (
    doc_id     bigint PRIMARY KEY,
    features   float8[] NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE fractalsql_feature_store IS
  'One named feature vector per doc_id, written by fractal_store_morphology '
  'and scanned by fractal_mine_topology_negatives. Caller decides what a '
  'doc_id''s vector represents (a computed morphology feature, a flagged '
  'negative example, etc.) -- this table is a generic per-item store, not '
  'specific to any one function''s original name.';

GRANT SELECT, INSERT, UPDATE ON fractalsql_feature_store TO PUBLIC;

CREATE FUNCTION fractal_store_morphology(
    doc_id        int8,
    feature_array float8[]
) RETURNS void
AS 'MODULE_PATHNAME', 'fractal_store_morphology'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_store_morphology(int8, float8[]) IS
  'Upserts feature_array against doc_id in fractalsql_feature_store '
  '(insert, or overwrite if doc_id already has a stored vector). Postgres-'
  'side named feature store -- see fractal_mine_topology_negatives for the '
  'matching k-NN read side.';

CREATE FUNCTION fractal_mine_topology_negatives(
    surrogate_vector float8[],
    k                int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_mine_topology_negatives'
LANGUAGE C STABLE STRICT;

COMMENT ON FUNCTION fractal_mine_topology_negatives(float8[], int4) IS
  'Brute-force k-NN (squared-Euclidean distance) over '
  'fractalsql_feature_store: the k stored vectors closest to '
  'surrogate_vector, ascending by distance. Intended for a curated store '
  '(e.g. vectors flagged via fractal_store_morphology as rejected/negative '
  'examples), not a full corpus scan -- O(n) per call, no index.';

-- ----- Table-backed top-k telemetry search + thin compositions -------------
-- fractal_search_explore returns Scout's raw population (diversity-shaped),
-- and fractal_search/fractal_search_debug use a single-row dummy corpus (the
-- query itself) -- neither gives "k nearest ROWS from a real table, with
-- their row indices and distances". fractal_search_telemetry is that
-- primitive; the other three are thin compositions on top of it.

CREATE FUNCTION fractal_search_telemetry(
    table_name  text,
    vector_col  text,
    query       float8[],
    k           int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_search_telemetry'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search_telemetry(text, text, float8[], int4) IS
  'k nearest rows in table_name.vector_col to query, via the v2.x brute-'
  'force cosine-distance search engine (exact, not approximate; '
  'Diversify/Repulsion applies if enabled on this session). Returns '
  '(doc_id, distance) ascending by distance, where doc_id is the '
  '0-indexed row position in the scan (matches fractal_feedback_report''s '
  'result_handle convention).';

CREATE FUNCTION fractal_hybrid_clinical_search(
    table_name  text,
    vector_col  text,
    query       float8[],
    doc_ids     int8[],
    k           int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_hybrid_clinical_search'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_hybrid_clinical_search(text, text, float8[], int8[], int4) IS
  'fractal_search_telemetry restricted to a caller-supplied cohort '
  '(doc_ids). doc_ids is computed by the caller with ordinary SQL (e.g. '
  '"SELECT array_agg((row_number() OVER () - 1)) FROM patients WHERE '
  'age > 65 AND condition = ''sepsis''") -- deliberately NOT a raw SQL '
  'filter/predicate string, to avoid the dynamic-SQL injection class this '
  'extension''s text-to-sql pipeline otherwise guards against carefully. '
  'Errors if doc_ids matches zero rows.';

CREATE FUNCTION fractal_search_trajectory(
    table_name       text,
    vector_col       text,
    baseline_vector  float8[],
    current_vector   float8[],
    k                int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_search_trajectory'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search_trajectory(text, text, float8[], float8[], int4) IS
  'Searches table_name.vector_col near the DELTA (current_vector - '
  'baseline_vector), not either vector directly -- "what changed", the '
  'natural query shape for drift/trajectory monitoring (e.g. a patient''s '
  'physiological state this hour vs. their own baseline). '
  'baseline_vector and current_vector must have the same dimension.';

CREATE FUNCTION fractal_cross_modal_search(
    table_name         text,
    vector_col         text,
    morphology_vector  float8[],
    clinical_vector    float8[],
    alpha_weight       float8,
    k                  int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_cross_modal_search'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_cross_modal_search(text, text, float8[], float8[], float8, int4) IS
  'Searches table_name.vector_col in a combined space: '
  '[morphology_vector * alpha_weight, clinical_vector * (1 - alpha_weight)] '
  '(weighted concatenation, not a blend -- each modality keeps its own '
  'dimensions). vector_col must already be stored in this same combined '
  'shape upstream. alpha_weight must be in [0,1].';

-- ---------------------------------------------------------------------
-- fractal_vector: native varlena vector type
-- ---------------------------------------------------------------------
-- float4 storage, typmod-enforced dimension (fractal_vector(n)),
-- binary I/O, distance operators reading the payload directly (no
-- float8[] array-header/null-bitmap unpack step). Additive alongside
-- float8[] -- nothing about the array-based surface above is changed
-- or deprecated. See docs/vectorizer-setup.md's "float8[] vs
-- fractal_vector(n)" section for when to prefer this type.

CREATE TYPE fractal_vector;

CREATE FUNCTION fractal_vector_in(cstring, oid, int4) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_out(fractal_vector) RETURNS cstring
  AS 'MODULE_PATHNAME', 'fractal_vector_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_recv(internal, oid, int4) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_recv' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_send(fractal_vector) RETURNS bytea
  AS 'MODULE_PATHNAME', 'fractal_vector_send' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_typmod_in(cstring[]) RETURNS int4
  AS 'MODULE_PATHNAME', 'fractal_vector_typmod_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_typmod_out(int4) RETURNS cstring
  AS 'MODULE_PATHNAME', 'fractal_vector_typmod_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE fractal_vector (
    INPUT          = fractal_vector_in,
    OUTPUT         = fractal_vector_out,
    RECEIVE        = fractal_vector_recv,
    SEND           = fractal_vector_send,
    TYPMOD_IN      = fractal_vector_typmod_in,
    TYPMOD_OUT     = fractal_vector_typmod_out,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = external,
    ALIGNMENT      = double,
    CATEGORY       = 'U'
);

COMMENT ON TYPE fractal_vector IS
  'Native float4 vector type. Declare a column as fractal_vector(n) to '
  'enforce dimension n at insert/update time. Text format matches '
  'pgvector''s convention: ''[0.1,0.2,0.3]''.';

-- Typmod length-coercion self-cast (the varchar(n)/numeric(p,s)
-- pattern) -- this is what actually enforces the dimension at
-- runtime; TYPMOD_IN/TYPMOD_OUT above only parse/print "(n)" in DDL.
-- Postgres invokes this automatically on assignment into a typmod'd
-- column, including a fractal_vector produced by the float8[] cast
-- below -- the two casts compose.
CREATE FUNCTION fractal_vector(fractal_vector, integer, boolean) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_enforce_typmod'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (fractal_vector AS fractal_vector)
  WITH FUNCTION fractal_vector(fractal_vector, integer, boolean) AS IMPLICIT;

CREATE FUNCTION fractal_vector_dims(fractal_vector) RETURNS int4
  AS 'MODULE_PATHNAME', 'fractal_vector_dims' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

COMMENT ON FUNCTION fractal_vector_dims(fractal_vector) IS
  'Returns the actual dimension of a fractal_vector value.';

-- float8[] interop -- ASSIGNMENT (not IMPLICIT) for the float8[] ->
-- fractal_vector direction deliberately: this is the mechanism that
-- makes fractal_vectorizer_process_queue''s dynamic
-- "UPDATE ... SET embedding_col = $1" raise on a dimension mismatch
-- with zero changes to that function''s PL/pgSQL body -- an ASSIGNMENT
-- cast fires on INSERT/UPDATE target-column coercion without
-- participating in general function-overload resolution.
CREATE FUNCTION fractal_vector_from_float8_array(float8[]) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_from_float8_array' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_to_float8_array(fractal_vector) RETURNS float8[]
  AS 'MODULE_PATHNAME', 'fractal_vector_to_float8_array' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (float8[] AS fractal_vector)
  WITH FUNCTION fractal_vector_from_float8_array(float8[]) AS ASSIGNMENT;
CREATE CAST (fractal_vector AS float8[])
  WITH FUNCTION fractal_vector_to_float8_array(fractal_vector) AS IMPLICIT;

-- Distance operators, adopting pgvector's own <->/<=>/<#> convention
-- deliberately -- inventing bespoke operator syntax would cost users
-- familiarity for no benefit.
CREATE FUNCTION fractal_vector_l2_distance(fractal_vector, fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_l2_distance' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_cosine_distance(fractal_vector, fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_cosine_distance' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_negative_inner_product(fractal_vector, fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_negative_inner_product' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR <-> (
    LEFTARG = fractal_vector, RIGHTARG = fractal_vector,
    PROCEDURE = fractal_vector_l2_distance, COMMUTATOR = <->
);
CREATE OPERATOR <=> (
    LEFTARG = fractal_vector, RIGHTARG = fractal_vector,
    PROCEDURE = fractal_vector_cosine_distance, COMMUTATOR = <=>
);
CREATE OPERATOR <#> (
    LEFTARG = fractal_vector, RIGHTARG = fractal_vector,
    PROCEDURE = fractal_vector_negative_inner_product, COMMUTATOR = <#>
);

COMMENT ON OPERATOR <-> (fractal_vector, fractal_vector) IS 'Euclidean (L2) distance.';
COMMENT ON OPERATOR <=> (fractal_vector, fractal_vector) IS 'Cosine distance (1 - cosine similarity).';
COMMENT ON OPERATOR <#> (fractal_vector, fractal_vector) IS 'Negative inner product (dot product, negated).';

-- General-purpose arithmetic. fractalsql-core's fsql_vector_* module
-- (float32, src/vector/vector.c) already implements all of these; this
-- is purely SQL-surface wiring, no new core math. Callers who only need
-- distance for ORDER BY/ANN want the operators above -- these exist for
-- users doing their own vector math (building a centroid, scaling by a
-- weight, similarity as a filter predicate) without round-tripping
-- through float8[].
CREATE FUNCTION fractal_vector_l2_squared(fractal_vector, fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_l2_squared' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_cosine_similarity(fractal_vector, fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_cosine_similarity' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_norm(fractal_vector) RETURNS float8
  AS 'MODULE_PATHNAME', 'fractal_vector_norm' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_normalize(fractal_vector) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_normalize' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_add(fractal_vector, fractal_vector) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_add' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_sub(fractal_vector, fractal_vector) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_sub' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION fractal_vector_scale(fractal_vector, float8) RETURNS fractal_vector
  AS 'MODULE_PATHNAME', 'fractal_vector_scale' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR + (
    LEFTARG = fractal_vector, RIGHTARG = fractal_vector,
    PROCEDURE = fractal_vector_add, COMMUTATOR = +
);
CREATE OPERATOR - (
    LEFTARG = fractal_vector, RIGHTARG = fractal_vector,
    PROCEDURE = fractal_vector_sub
);
CREATE OPERATOR * (
    LEFTARG = fractal_vector, RIGHTARG = float8,
    PROCEDURE = fractal_vector_scale, COMMUTATOR = *
);

COMMENT ON FUNCTION fractal_vector_l2_squared(fractal_vector, fractal_vector) IS
  'Squared Euclidean distance -- skips the sqrt in <->, useful when only relative ordering matters.';
COMMENT ON FUNCTION fractal_vector_cosine_similarity(fractal_vector, fractal_vector) IS
  'Cosine similarity in [-1,1] -- the non-distance twin of <=> (which returns 1 - similarity).';
COMMENT ON FUNCTION fractal_vector_norm(fractal_vector) IS 'Euclidean (L2) magnitude.';
COMMENT ON FUNCTION fractal_vector_normalize(fractal_vector) IS 'Unit-length copy (divides by norm).';
COMMENT ON FUNCTION fractal_vector_add(fractal_vector, fractal_vector) IS 'Elementwise sum.';
COMMENT ON FUNCTION fractal_vector_sub(fractal_vector, fractal_vector) IS 'Elementwise difference.';
COMMENT ON FUNCTION fractal_vector_scale(fractal_vector, float8) IS 'Elementwise scalar multiply.';

-- fractal_search_trajectory / fractal_cross_modal_search overloads
-- taking fractal_vector directly -- additive, the float8[] signatures
-- above are unchanged. Backed by C entry points that call fsql_vector_*
-- for the arithmetic (sub / weighted-concat) instead of hand-rolled
-- float8[] unpack/repack, widening float->double once at the boundary
-- before the existing double-precision search path.
CREATE FUNCTION fractal_search_trajectory(
    table_name       text,
    vector_col       text,
    baseline_vector  fractal_vector,
    current_vector   fractal_vector,
    k                int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_search_trajectory_fv'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_search_trajectory(text, text, fractal_vector, fractal_vector, int4) IS
  'fractal_vector overload of fractal_search_trajectory(text, text, float8[], float8[], int4) -- '
  'same semantics, direct varlena reads instead of array unpacking.';

CREATE FUNCTION fractal_cross_modal_search(
    table_name         text,
    vector_col         text,
    morphology_vector  fractal_vector,
    clinical_vector    fractal_vector,
    alpha_weight       float8,
    k                  int4
) RETURNS TABLE(doc_id int8, distance float8)
AS 'MODULE_PATHNAME', 'fractal_cross_modal_search_fv'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_cross_modal_search(text, text, fractal_vector, fractal_vector, float8, int4) IS
  'fractal_vector overload of fractal_cross_modal_search(text, text, float8[], float8[], float8, int4) -- '
  'same semantics, direct varlena reads instead of array unpacking.';

-- ==================================================================
-- Enterprise: QTL ledger + CISO audit (runtime-gated)
-- ==================================================================
-- These functions are built into the extension on EVERY edition
-- (community + enterprise). On community they are DORMANT: on first use
-- they dlopen the enterprise core library named by the
-- fractalsql.enterprise_lib GUC and, if it is absent, raise a clear
-- 'enterprise tier not loaded' error. On enterprise they activate and
-- persist the QTL (Quantized Ternary Ledger) -- a Truth/Shadow record of
-- search/feedback events -- to the fractalsql_ledger table (created lazily
-- on first flush) as an APPEND-ONLY hash chain: every row links to its
-- predecessor via entry_hash = SHA256(prev_hash || blob || mac), so a
-- rewritten row breaks the chain and a deleted row leaves a visible gap in
-- the id sequence -- genuine history, not a last-writer-wins snapshot.
-- fractal_ledger_load() verifies only the chain's tip on every call (O(1),
-- cheap): the latest entry's hash recomputes correctly and links to its
-- predecessor. fractal_ledger_verify() walks the ENTIRE chain (O(n), for
-- on-demand CISO audits, not run on every load) and returns a jsonb
-- report. Set fractalsql.enterprise_ledger_key to additionally
-- HMAC-SHA256-tag each blob on flush and verify it on load/verify --
-- without a key the chain is still fully tamper-evident structurally
-- (entry_hash covers the blob either way), a key adds cryptographic
-- authentication on top. CISO audit is fractal_audit_unpack(blob),
-- decoding a persisted QTL blob to a JSON array of
-- {"epoch","doc_id","signal"} entries.
--
-- Community operation is unaffected: search/diversify/feedback run without
-- the enterprise library, and these functions simply error until it is
-- configured. Set fractalsql.enterprise_lib to the absolute path of the
-- enterprise core library (libfractalsql-enterprise-sovereign-c.so /
-- .dll / .dylib) and reload to activate.

CREATE FUNCTION fractal_ledger_flush()
RETURNS void
AS 'MODULE_PATHNAME', 'fractal_ledger_flush'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_load()
RETURNS void
AS 'MODULE_PATHNAME', 'fractal_ledger_load'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_compact()
RETURNS void
AS 'MODULE_PATHNAME', 'fractal_ledger_compact'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_reset_soft()
RETURNS void
AS 'MODULE_PATHNAME', 'fractal_ledger_reset_soft'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_reset_hard()
RETURNS void
AS 'MODULE_PATHNAME', 'fractal_ledger_reset_hard'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_truth_count()
RETURNS bigint
AS 'MODULE_PATHNAME', 'fractal_ledger_truth_count'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_shadow_count()
RETURNS bigint
AS 'MODULE_PATHNAME', 'fractal_ledger_shadow_count'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_ledger_verify(kind int4 DEFAULT 1)
RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_ledger_verify'
LANGUAGE C VOLATILE;

CREATE FUNCTION fractal_audit_log(
    entry_type text,
    payload    jsonb
) RETURNS void
AS 'MODULE_PATHNAME', 'fractal_audit_log'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION fractal_audit_log(text, jsonb) IS
  'Append a provenance record to the general decision-audit chain (kind=2 '
  'in fractalsql_ledger -- a second, independent append-only chain '
  'alongside kind=1''s QTL Truth/Shadow blobs, same hash-chain guarantees, '
  'verifiable via fractal_ledger_verify(2)). Stores '
  '{"type": entry_type, "entry": payload}. Query back directly: SELECT '
  'id, updated, convert_from(blob, ''UTF8'')::jsonb FROM fractalsql_ledger '
  'WHERE kind = 2 ORDER BY id. Errors with ''enterprise tier not loaded'' '
  'until fractalsql.enterprise_lib is set.';

CREATE FUNCTION fractal_audit_unpack(blob bytea)
RETURNS jsonb
AS 'MODULE_PATHNAME', 'fractal_audit_unpack'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION fractal_ledger_flush() IS
  'Persist the current Truth + Shadow ledgers as a QTL blob to fractalsql_ledger. Enterprise tier: errors with ''enterprise tier not loaded'' until fractalsql.enterprise_lib is set.';
COMMENT ON FUNCTION fractal_ledger_load() IS
  'Reload the persisted QTL blob back into the in-memory Truth + Shadow ledgers. Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_compact() IS
  'Compact the in-memory ledgers (drop decayed/evicted shadow entries). Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_reset_soft() IS
  'Clear the in-memory Shadow ledger (preserve Truth). Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_reset_hard() IS
  'Clear both in-memory Truth + Shadow ledgers. Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_truth_count() IS
  'Number of entries in the in-memory Truth ledger. Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_shadow_count() IS
  'Number of entries in the in-memory Shadow ledger. Enterprise tier.';
COMMENT ON FUNCTION fractal_ledger_verify(int4) IS
  'Full O(n) walk of the append-only ledger chain for the given kind (default 1, the QTL Truth/Shadow chain; kind=2 is the general decision-audit chain written by fractal_audit_log). Recomputes every entry_hash/prev_hash link (and MAC, if fractalsql.enterprise_ledger_key is set) and checks the id sequence for gaps. Returns a jsonb report -- {"ok":true,"rows_verified":N} or {"ok":false,"first_failure_id":...,"reason":...} -- rather than raising, since this is a forensic query, not a gate. Does not require the enterprise library to be loaded (pure storage-layer check). Not run on every fractal_ledger_load() (that is O(1), tip-only) -- call this on demand for a full CISO audit.';
COMMENT ON FUNCTION fractal_audit_unpack(bytea) IS
  'Decode a persisted QTL blob (e.g. from fractalsql_ledger.blob) into a JSON array of {"epoch","doc_id","signal"} entries for CISO audit. Enterprise tier.';
