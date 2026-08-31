-- sql/fractalsql_agents--1.0.sql
\echo Use "CREATE EXTENSION fractalsql_agents" to load this file. \quit

-- fractalsql_agents: a second-tier, optional dependent extension (requires
-- 'fractalsql') shipping parameterized PL/pgSQL "agent engines" — the
-- productized, installable form of the reference Domain Agent blueprints
-- defined in demo/demo-agentic-*.sql. Each engine composes real
-- fractalsql primitives (Discovery + Cognition + Analytics) end-to-end, with
-- the user's tables and columns passed as arguments instead of hardcoded.
--
-- Sixteen engines ship (A-P), all real compositions. G-O are the
-- vertical-demo preset engines; P (enterprise tier) is allocate's
-- multimodal companion:
--   A. fractal_agent_anomaly_triage  — fractal_dimension_drift + fractal_reason
--   B. fractal_agent_allocate        — fractal_optimize_portfolio + fractal_reason
--   C. fractal_agent_route_task      — fractal_search_telemetry + fractal_reason
--   D. fractal_agent_outlier_intercept — fractal_search_telemetry + fractal_reason
--   E. fractal_agent_recall_hybrid   — fractal_hybrid_clinical_search (pure retrieval)
--   F. fractal_agent_recommend_diverse — fractal_diversify_enable + fractal_search_telemetry (pure retrieval)
--   G. fractal_agent_data_analyst    — fractal_sql_agent + fractal_reason (horizontal catch-all)
--   H. fractal_agent_patient_deterioration_triage — hybrid_clinical_search + search_trajectory + reason
--   I. fractal_agent_feedback_audit  — diversify loop + detect_collapse + explain_result (pure analytics, no LLM)
--   J. fractal_agent_schedule_workload — fractal_search + search_telemetry + reason
--   K. fractal_agent_rebalance_sibling — optimize_portfolio + search_trajectory + reason
--   L. fractal_agent_detour_classify — search_trajectory + dimension_boxcount + reason
--   M. fractal_agent_track_anomaly   — search_trajectory + dimension_dfa + reason
--   N. fractal_agent_network_coverage_alert — morphological_complexity + dimension_drift + reason
--   O. fractal_agent_regime_triage   — dimension_dfa + dimension_drift + reason
--   P. fractal_agent_diverse_portfolios — optimize_portfolio_multimodal + reason (enterprise tier)
-- A/B/C/D/G/H/J/K/L/M/N/O/P are cognition engines (end in fractal_reason); E/F
-- are pure retrieval; I is pure analytics -- none of E/F/I have an LLM step.
-- The demo reference functions stay in the demos as copy-the-pattern
-- blueprints; the eight vertical demos are wired as presets to these
-- engines. See docs/api-agency.md > "The sixteen recipes".
--
-- The extension is relocatable with no schema: it co-locates with the base
-- fractalsql extension, so the unqualified base-function calls below
-- (fractal_dimension_drift, fractal_reason, fractal_optimize_portfolio,
-- fractal_search_telemetry, fractal_hybrid_clinical_search,
-- fractal_diversify_enable) resolve via the caller's search_path exactly as
-- the base's own PL/pgSQL functions do.

-- =====================================================================
-- Engine A: fractal_agent_anomaly_triage
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-ops-devops.sql's fractal_agent_threat_triage
-- (the one real composition in that file). Generalizes the hardcoded
-- incident_logs(latency_ms, event_ts, agent_id) schema into parameters via
-- dynamic SQL, preserving the real fractal_dimension_drift -> fractal_reason
-- composition. Covers any "drift on a metric time series for one entity"
-- workflow: Cybersecurity host triage, DevOps incident triage, MedTech patient
-- monitoring, Smart-Cities sensor regime change.

CREATE FUNCTION fractal_agent_anomaly_triage(
    log_table       text,
    metric_col      text,
    time_col        text,
    filter_col      text,
    filter_val      text,
    baseline_window int  DEFAULT 32
) RETURNS TABLE(threat_score float8, anomaly_type text, triage_summary text)
AS $$
DECLARE
    drift_res     jsonb;
    series        float8[];
    reasoning_res text;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF log_table IS NULL OR metric_col IS NULL OR time_col IS NULL OR filter_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_anomaly_triage: identifier arguments must not be NULL';
    END IF;
    -- PL/pgSQL cannot parameterize identifiers in a static query, so build the
    -- series-fetch dynamically. %I/%L quote the identifier/literal safely.
    -- pg_catalog.array_agg is schema-qualified to defend against shadowing
    -- the builtin inside this user-supplied-identifier statement.
    EXECUTE format(
        'SELECT pg_catalog.array_agg(%I ORDER BY %I) FROM %I WHERE %I = %L',
        metric_col, time_col, log_table, filter_col, filter_val)
        INTO series;

    IF series IS NULL THEN
        RAISE EXCEPTION
            'fractal_agent_anomaly_triage: no rows in %.% matching % = %',
            log_table, metric_col, filter_col, filter_val;
    END IF;

    -- 1. Real Analytics: regime-change drift on the entity's metric series.
    drift_res := fractal_dimension_drift(series, baseline_window);

    -- 2. Real Cognition: reason a human-readable triage over the drift result.
    -- fractal_reason's context arg is text (a JSON-shaped string), so cast the
    -- jsonb build_object to text.
    reasoning_res := fractal_reason(
        'Triage this anomaly: ' || drift_res::text,
        jsonb_build_object('table', log_table, filter_col, filter_val)::text);

    -- 3. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_anomaly_triage', jsonb_build_object(
            'threat_score', COALESCE((drift_res->>'drift')::float8, 0.0),
            'anomaly_type', 'vector_drift', 'triage_summary', reasoning_res));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT
        COALESCE((drift_res->>'drift')::float8, 0.0),
        'vector_drift'::text,
        reasoning_res;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_anomaly_triage(text, text, text, text, text, int) IS
  'Anomaly-triage agent engine. Reads one entity''s metric time series from '
  'log_table (filtered by filter_col = filter_val, ordered by time_col), runs '
  'fractal_dimension_drift over it, then fractal_reason to synthesize a '
  'triage summary. Returns (threat_score, anomaly_type, triage_summary). '
  'threat_score is the real drift exponent; triage_summary is the LLM''s read. '
  'Raises a clean ERROR if the filter matches no rows. Generalizes the '
  'fractal_agent_threat_triage reference blueprint in demo/demo-agentic-'
  'ops-devops.sql (which hardcoded incident_logs/latency_ms/event_ts/agent_id).';

-- =====================================================================
-- Engine B: fractal_agent_allocate
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-fintech-mcts.sql's
-- fractal_agent_portfolio_rebalance (a real composition with two stub
-- aspects: canned mu/cov inputs and a hardcoded drift_score literal). Here
-- mu/cov are parameters (the user feeds real data via array_agg, as
-- demo/demo-vertical-quant-finance.sql shows) and the fake 0.042 drift_score is
-- replaced by the REAL sharpe ratio the optimizer computes itself
-- (fractal_optimize_portfolio returns {sharpe, weights}). Covers cardinality-
-- constrained allocation: Quant-Finance portfolios, Sovereign-Edge resource
-- allocation, FinTech rebalancing.

CREATE FUNCTION fractal_agent_allocate(
    mu          float8[],
    cov         float8[],
    cardinality int,
    context     text  DEFAULT NULL
) RETURNS TABLE(allocation jsonb, sharpe float8, rationale text)
AS $$
DECLARE
    opt_res    jsonb;
    reason_res text;
    s          float8;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    -- 1. Real Analytics: SFS cardinality-constrained Sharpe maximization.
    -- cov must be a FLATTENED 1-D row-major n x n matrix (see the demo's
    -- note: fractal_optimize_portfolio reads it via float8_array_to_doubles,
    -- which rejects 2-D matrices). A mismatched cov length raises a clean
    -- 'cov length' ERROR from the primitive, which propagates here unchanged.
    opt_res := fractal_optimize_portfolio(mu, cov, cardinality);

    -- 2. Real risk-adjusted return from the optimizer's own output (replaces
    -- the demo's hardcoded 0.042 'drift_score' literal — which was always a
    -- misnomer for a constant).
    s := COALESCE((opt_res->>'sharpe')::float8, 0.0);

    -- 3. Real Cognition: reason a rationale for the allocation. context is a
    -- text label (a JSON-shaped string) passed straight through to fractal_reason.
    reason_res := fractal_reason(
        'Explain this cardinality-constrained allocation and its risk/return: '
        || opt_res::text,
        COALESCE(context, '{}')::text);

    -- 4. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users. Complements
    -- fractal_optimize_portfolio's own audit entry with the agent-level
    -- decision (rationale, cardinality).
    BEGIN
        PERFORM fractal_audit_log('agent_allocate', jsonb_build_object(
            'sharpe', s, 'cardinality', cardinality, 'rationale', reason_res));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT opt_res, s, reason_res;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_allocate(float8[], float8[], int, text) IS
  'Cardinality-constrained allocation agent engine. Runs '
  'fractal_optimize_portfolio(mu, cov, cardinality) — the SFS Sharpe-ratio '
  'maximizer — then fractal_reason to synthesize a rationale. Returns '
  '(allocation, sharpe, rationale): allocation is the optimizer''s {sharpe, '
  'weights} jsonb, sharpe is the real risk-adjusted return it computed, and '
  'rationale is the LLM''s explanation. context is an optional label passed '
  'to the reason call as its context jsonb. Generalizes the '
  'fractal_agent_portfolio_rebalance reference blueprint in '
  'demo/demo-vertical-agentic-fintech-mcts.sql (which used canned mu/cov and a '
  'hardcoded 0.042 drift_score).';

-- =====================================================================
-- Engine C: fractal_agent_route_task
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-ops-devops.sql's fractal_agent_route_task
-- (a stub that returned the constant 'root-cause-analyzer', 0.92, budget-150
-- and ignored its cap_map argument). The stub's cap_map jsonb duplicated the
-- demo's real agent_capabilities table inline -- the wrong abstraction. This
-- engine searches the capability table directly: it finds the capability
-- whose embedding is nearest to the task embedding (fractal_search_telemetry,
-- real C), resolves the 0-indexed scan position to the named capability id
-- (the repo's ctid-row_number mapping), derives a confidence from the real
-- distance, accounts the budget, and reasons a routing rationale. Covers any
-- "match an incoming task to the best capable sub-agent" workflow across
-- DevOps, Customer Support, Cybersecurity, Sovereign-Edge orchestration.

CREATE FUNCTION fractal_agent_route_task(
    task_emb       float8[],
    cap_table      text,
    cap_emb_col    text,
    cap_id_col     text,
    budget         int,
    cost_per_route int  DEFAULT 150
) RETURNS TABLE(routed_to text, confidence float8, remaining_budget int, rationale text)
AS $$
DECLARE
    nearest_doc  int8;
    nearest_dist float8;
    routed_to    text;
    confidence   float8;
    rationale    text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF cap_table IS NULL OR cap_emb_col IS NULL OR cap_id_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_route_task: identifier arguments must not be NULL';
    END IF;
    -- 0. Empty-table pre-check. The C primitive (fractal_search_telemetry)
    -- raises its own "no corpus rows to search" on an empty table, which would
    -- surface BEFORE the post-call NULL guard below -- so check first and raise
    -- this engine's clearer, engine-named message instead. NOTE: EXECUTE ...
    -- INTO of a SELECT does NOT set FOUND (only PERFORM / static SELECT INTO
    -- do), so guard on the target variable itself: 0 rows -> has_row stays
    -- NULL; >=1 row -> has_row = 1.
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', cap_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_route_task: no capability rows in %',
            cap_table;
    END IF;

    -- 1. Real Analytics: nearest capability embedding to the task embedding.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_telemetry(cap_table, cap_emb_col, task_emb, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_route_task: no capability rows in %',
            cap_table;
    END IF;

    -- 2. Resolve the 0-indexed heap-scan position to the named capability id
    -- via the repo's robust ctid-row_number mapping (matches the C engine's
    -- physical scan order; the same pattern the maritime/cybersecurity demos
    -- use to map doc_id back to a PK).
    EXECUTE format(
        'SELECT %I FROM (SELECT %I, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'WHERE x.doc_id = %L',
        cap_id_col, cap_id_col, cap_table, nearest_doc)
        INTO routed_to;

    -- 3. Real Cognition: reason a one-line routing rationale.
    rationale := fractal_reason(
        'Route this task to capability ' || COALESCE(routed_to, '?') ||
        ' (cosine distance ' || nearest_dist || '). Justify the routing in one sentence.',
        jsonb_build_object('budget', budget, 'cost_per_route', cost_per_route)::text);

    -- confidence is real, derived from the real nearest distance.
    confidence := 1.0 / (1.0 + nearest_dist);

    -- 4. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_route_task', jsonb_build_object(
            'routed_to', routed_to, 'confidence', confidence,
            'remaining_budget', budget - cost_per_route, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT routed_to, confidence,
        budget - cost_per_route, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_route_task(float8[], text, text, text, int, int) IS
  'Sub-agent dispatcher engine. Embeds nothing itself -- the caller passes the '
  'task embedding (task_emb) at the same dimensionality as the capability '
  'embeddings -- then runs fractal_search_telemetry(cap_table, cap_emb_col, '
  'task_emb, 1) to find the nearest capability, resolves the 0-indexed scan '
  'position to the named capability id (cap_id_col) via a ctid-row_number '
  'mapping, derives confidence = 1/(1+distance) from the real distance, '
  'accounts the budget (remaining_budget = budget - cost_per_route), and '
  'calls fractal_reason for a one-line routing rationale. Returns (routed_to, '
  'confidence, remaining_budget, rationale). Raises a clean ERROR if the '
  'capability table is empty. Generalizes the fractal_agent_route_task '
  'reference blueprint in demo/demo-vertical-agentic-ops-devops.sql (which returned '
  'the constant root-cause-analyzer/0.92/budget-150 and ignored its cap_map '
  'jsonb arg -- the cap_map was an inline duplicate of the real '
  'agent_capabilities table this engine searches instead).';

-- =====================================================================
-- Engine D: fractal_agent_outlier_intercept
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-ops-devops.sql's
-- fractal_agent_outlier_intercept (a stub that returned the constant
-- false/'state within normal variance' and ignored all its arguments). The
-- stub's own comment described the real composition ("Use
-- fractal_search_telemetry to find distance to known bad states; if distance
-- < threshold, we intercept") -- this engine implements exactly that. Covers
-- any pre-commit safety barrier: DevOps action screening, Cybersecurity
-- known-bad-state interception, MedTech out-of-range vital interception,
-- Sovereign-Edge anomalous command interception.

CREATE FUNCTION fractal_agent_outlier_intercept(
    state_vec      float8[],
    history_table  text,
    emb_col        text,
    threshold      float8
) RETURNS TABLE(intercepted boolean, reason text)
AS $$
DECLARE
    nearest_doc  int8;
    nearest_dist float8;
    intercepted  boolean;
    reason       text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF history_table IS NULL OR emb_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_outlier_intercept: identifier arguments must not be NULL';
    END IF;
    -- 0. Empty-table pre-check (same rationale and idiom as route_task: the C
    -- primitive would raise "no corpus rows to search" first; raise this
    -- engine's clearer message instead. Guard on the target variable, not
    -- FOUND -- EXECUTE ... INTO does not set FOUND.)
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', history_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_outlier_intercept: no bad-state rows in %',
            history_table;
    END IF;

    -- 1. Real Analytics: distance from the proposed state to the nearest
    -- known-bad state in the history table.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_telemetry(history_table, emb_col, state_vec, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_outlier_intercept: no bad-state rows in %',
            history_table;
    END IF;

    -- 2. Real decision: intercept iff the nearest bad state is within the
    -- threshold. This is a genuine comparison of a real distance, not a
    -- constant.
    intercepted := nearest_dist < threshold;

    -- 3. Real Cognition: reason a one-line justification.
    reason := fractal_reason(
        'Outlier intercept: nearest known-bad state is at cosine distance '
        || nearest_dist || ', threshold ' || threshold || ', so '
        || CASE WHEN intercepted THEN 'INTERCEPT' ELSE 'allow' END
        || '. Justify the decision in one sentence.',
        jsonb_build_object('threshold', threshold, 'intercepted', intercepted)::text);

    -- 4. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users. High-value trail since
    -- this engine can block a proposed state/action.
    BEGIN
        PERFORM fractal_audit_log('agent_outlier_intercept', jsonb_build_object(
            'intercepted', intercepted, 'nearest_distance', nearest_dist,
            'threshold', threshold, 'reason', reason));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT intercepted, reason;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_outlier_intercept(float8[], text, text, float8) IS
  'Pre-commit safety-barrier engine. Runs fractal_search_telemetry('
  'history_table, emb_col, state_vec, 1) to find the distance from the '
  'proposed state vector to the nearest known-bad state, sets intercepted = '
  '(distance < threshold) -- a real comparison of a real distance -- and '
  'calls fractal_reason for a one-line justification. Returns (intercepted, '
  'reason). Raises a clean ERROR if the history table is empty. Generalizes '
  'the fractal_agent_outlier_intercept reference blueprint in '
  'demo/demo-vertical-agentic-ops-devops.sql (which returned the constant '
  'false/''state within normal variance'' and ignored its arguments, even '
  'though its own comment described this exact composition).';

-- =====================================================================
-- Engine E: fractal_agent_recall_hybrid
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-customer-support.sql's
-- fractal_agent_recall_hybrid (a stub that returned generate_series(1,5) with
-- canned 'recalled memory snippet N' content and ignored its query/mem_table/
-- alpha arguments). The stub's comment said "blends a SQL filter with a
-- fractal_search_trajectory call," but the engine's actual job -- recall
-- similar past memories for a query, restricted by a metadata filter -- is a
-- query-vector recall with a cohort, which is exactly what
-- fractal_hybrid_clinical_search does natively (filter-first-then-search, so k
-- is respected within the cohort; a trajectory+post-filter alternative would
-- over-fetch and shrink k after filtering). The cohort is computed internally
-- from filter_col/filter_val via the repo's own row_number() OVER () - 1 recipe
-- (the same one fractal_hybrid_clinical_search's docstring and C source use).
-- The stub's query text becomes a query_vec (caller embeds); alpha is dropped
-- (the blend is the cohort, not a scalar). Covers Customer Support memory
-- recall, MedTech cohort-restricted patient search, Smart-Cities zone-filtered
-- sensor recall.

CREATE FUNCTION fractal_agent_recall_hybrid(
    mem_table    text,
    vec_col      text,
    query_vec    float8[],
    filter_col   text  DEFAULT NULL,
    filter_val   text  DEFAULT NULL,
    k            int   DEFAULT 5,
    id_col       text  DEFAULT 'id',
    content_col  text  DEFAULT NULL
) RETURNS TABLE(mem_id bigint, content text)
AS $$
DECLARE
    cohort       int8[];
    where_clause text;
    content_sel  text;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF mem_table IS NULL OR vec_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_recall_hybrid: identifier arguments must not be NULL';
    END IF;
    -- 1. The "hybrid" is the cohort: a strict SQL filter (filter_col =
    -- filter_val) mapped to 0-indexed scan positions via row_number() over
    -- ctid order -- the repo's own cohort recipe (see the
    -- fractal_hybrid_clinical_search docstring and src/fractalsql.c). The
    -- row_number() must be computed in a subquery before array_agg -- postgres
    -- rejects array_agg(row_number() OVER (...)) directly ("aggregate
    -- function calls cannot contain window function calls"); the C source
    -- itself uses a WITH numbered AS (...) CTE for the same reason. When
    -- filter_col is NULL the cohort is every row.
    where_clause := CASE WHEN filter_col IS NULL THEN ''
                         ELSE format(' WHERE %I = %L', filter_col, filter_val) END;
    EXECUTE format(
        'SELECT array_agg(idx) FROM (SELECT (row_number() OVER (ORDER BY ctid) - 1)::int8 AS idx FROM %I%s) s',
        mem_table, where_clause) INTO cohort;
    IF cohort IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_recall_hybrid: filter matched no rows in %',
            mem_table;
    END IF;

    -- 2. Real Analytics: fractal_hybrid_clinical_search restricts the vector
    -- search to the cohort. Then join its 0-indexed doc_ids back to the named
    -- id (id_col, cast to bigint) and optional content via the ctid mapping.
    content_sel := CASE WHEN content_col IS NULL THEN 'NULL::text'
                        ELSE format('%I', content_col) END;
    RETURN QUERY EXECUTE format(
        'SELECT x.idv::bigint, x.cnt '
        'FROM fractal_hybrid_clinical_search(%L, %L, $1, $2, %L) r '
        'JOIN (SELECT %I AS idv, %s AS cnt, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'ON x.doc_id = r.doc_id ORDER BY r.distance',
        mem_table, vec_col, k, id_col, content_sel, mem_table)
        USING query_vec, cohort;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_recall_hybrid(text, text, float8[], text, text, int, text, text) IS
  'Hybrid memory-recall engine. Builds a cohort of 0-indexed scan positions '
  'from an optional metadata filter (filter_col = filter_val) via '
  'row_number() over ctid order, then runs fractal_hybrid_clinical_search to '
  'restrict the vector search to that cohort, and resolves the returned '
  '0-indexed doc_ids back to the named id (id_col, cast to bigint) and '
  'optional content (content_col) via the same ctid mapping. Returns (mem_id, '
  'content). The caller passes the query as an embedding (query_vec); the '
  'stub-era query text and alpha blend weight are replaced by the cohort (the '
  'blend is the filter, not a scalar). Raises a clean ERROR if the filter '
  'matches no rows. id_col must be bigint-castable. No LLM step -- this is '
  'pure retrieval (real ids + real content), not a cognition engine. '
  'Generalizes the fractal_agent_recall_hybrid reference blueprint in '
  'demo/demo-vertical-agentic-customer-support.sql (which returned generate_series '
  'with canned content and ignored its arguments).';

-- =====================================================================
-- Engine F: fractal_agent_recommend_diverse
-- =====================================================================
-- Promoted from demo/demo-vertical-agentic-customer-support.sql's
-- fractal_agent_recommend_diverse (a stub whose only real line was
-- PERFORM fractal_diversify_enable(); the rest returned generate_series(1,k)
-- with canned 0.95 - i*0.01 scores and ignored customer_id/catalog_table).
-- The stub's comment said "Use Scout search to find diverse candidate items,"
-- but fractal_search_explore returns SETOF float8[] (embeddings, no ids) --
-- wrong for an id-returning engine. fractal_search_telemetry's docstring
-- states "Diversify/Repulsion applies if enabled on this session," so enabling
-- diversify then telemetry is the real, id-returning, repulsion-diverse top-k.
-- customer_id is dropped (the stub ignored it; diversify state is
-- session-global, not per-customer). Covers Customer Support diverse recovery
-- strategies, Recommendation diverse "you might also like," Smart-Cities
-- diverse representative-zone sampling.

CREATE FUNCTION fractal_agent_recommend_diverse(
    catalog_table  text,
    emb_col        text,
    query_vec      float8[],
    k              int   DEFAULT 10,
    id_col         text  DEFAULT 'id'
) RETURNS TABLE(item_id bigint, score float8)
AS $$
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF catalog_table IS NULL OR emb_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_recommend_diverse: identifier arguments must not be NULL';
    END IF;
    -- 1. Enable session-global repulsion so the search avoids recently-
    -- rejected items (matches the stub's PERFORM fractal_diversify_enable()).
    -- The caller owns session policy; this engine does not disable it.
    PERFORM fractal_diversify_enable();

    -- 2. Real Analytics: telemetry with diversify enabled = repulsion-diverse
    -- top-k (per the primitive's docstring). score = 1 - cosine_distance is
    -- real, from the primitive; the 0-indexed doc_id is resolved to the named
    -- item id (id_col, cast to bigint) via the ctid mapping.
    RETURN QUERY EXECUTE format(
        'SELECT x.idv::bigint, (1.0 - r.distance) '
        'FROM fractal_search_telemetry(%L, %L, $1, %L) r '
        'JOIN (SELECT %I AS idv, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'ON x.doc_id = r.doc_id ORDER BY r.distance',
        catalog_table, emb_col, k, id_col, catalog_table)
        USING query_vec;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_recommend_diverse(text, text, float8[], int, text) IS
  'Feedback-aware diverse-recommender engine. Calls fractal_diversify_enable() '
  '(session-global repulsion, so re-searches avoid recently-rejected items via '
  'fractal_feedback_report) then fractal_search_telemetry for the top-k, which '
  'the primitive applies repulsion to when diversify is enabled. score = '
  '1 - cosine_distance is real, from the primitive; item_id is the named '
  'catalog id (id_col, cast to bigint) resolved from the 0-indexed scan '
  'position via a ctid-row_number mapping. Returns (item_id, score). The '
  'stub-era customer_id is dropped (diversify state is session-global, not '
  'per-customer). No LLM step -- pure retrieval. id_col must be bigint-'
  'castable. Note: diversify_enable is a session side effect the caller is '
  'responsible for resetting (fractal_diversify_disable). Generalizes the '
  'fractal_agent_recommend_diverse reference blueprint in '
  'demo/demo-vertical-agentic-customer-support.sql (which enabled diversify for '
  'real but returned generate_series with canned 0.95 - i*0.01 scores).';

-- =====================================================================
-- Engine G: fractal_agent_data_analyst
-- =====================================================================
-- The horizontal catch-all: natural-language analytics over any tables the
-- base fractal_sql_agent can reach. Composes fractal_sql_agent (NL -> SQL ->
-- execute, with its own retry loop) then fractal_reason to synthesize a
-- human-readable read of the result. Unlike the vertical engines (which are
-- fixed compositions of vector/dimension primitives), this one answers
-- arbitrary questions -- the closest thing to a general-purpose agent in the
-- roster. No vertical-demo preset (none of the 8 demos call fractal_sql_agent);
-- validated via demo/demo-agents.sql and build_test gate 23.

CREATE FUNCTION fractal_agent_data_analyst(
    question      text,
    table_names   text[]  DEFAULT NULL,
    max_retries   int     DEFAULT 2,
    context       text    DEFAULT '{}'
) RETURNS TABLE(analysis text, generated_sql text, result_json jsonb)
AS $$
DECLARE
    res      fractal_sql_agent_result;
    analysis text;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    -- 1. Real Analytics: NL -> SQL -> execute. fractal_sql_agent owns its
    -- retry loop and reports empty/failed results via execution_status; this
    -- engine does not second-guess them (no empty-table guard -- there is no
    -- fixed table to pre-check). auto_execute=true so result_json carries the
    -- real row count (or a captured execution-failure reason) -- with false
    -- result_json is always NULL, which would break the real-output invariant.
    SELECT * INTO res FROM fractal_sql_agent(question, table_names, max_retries, true);

    -- 2. Real Cognition: reason a one-paragraph read over the query result.
    analysis := fractal_reason(
        'Analyze this database query result and answer in one paragraph: '
        || COALESCE(res.result_json::text, 'null'),
        context);

    -- 3. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users. High-value trail since
    -- this engine auto-executes LLM-generated SQL.
    BEGIN
        PERFORM fractal_audit_log('agent_data_analyst', jsonb_build_object(
            'question', question, 'generated_sql', res.generated_sql,
            'execution_status', res.execution_status, 'analysis', analysis));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT analysis, res.generated_sql, res.result_json;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_data_analyst(text, text[], int, text) IS
  'Horizontal data-analyst engine. Calls fractal_sql_agent(question, '
  'table_names, max_retries, true) -- the NL-to-SQL-to-execute pipeline with '
  'its own retry loop, auto_execute=true so result_json carries the real row '
  'count (or a captured execution-failure reason) -- then fractal_reason to '
  'synthesize a one-paragraph analysis of the result. Returns (analysis, '
  'generated_sql, result_json): analysis is the LLM''s read, generated_sql and '
  'result_json are the agent''s own real outputs (no canned constants). context '
  'is an optional label passed to the reason call. No empty-table guard (no '
  'fixed table to pre-check; fractal_sql_agent handles its own errors). This is '
  'the horizontal catch-all -- no vertical demo is wired to it.';

-- =====================================================================
-- Engine H: fractal_agent_patient_deterioration_triage
-- =====================================================================
-- MedTech: triage a patient's deterioration by combining a cohort-restricted
-- similarity search (fractal_hybrid_clinical_search) with a baseline->current
-- drift search (fractal_search_trajectory), then reasoning over both. The
-- cohort_doc_ids parameter accepts a caller-built multi-predicate cohort (e.g.
-- age > 65 AND condition = 'sepsis') -- the two-predicate case
-- fractal_agent_recall_hybrid's single (filter_col, filter_val) cannot express.
-- Generalizes the medtech-clinical demo's hybrid search + trajectory sections.

CREATE FUNCTION fractal_agent_patient_deterioration_triage(
    patient_table   text,
    vec_col         text,
    query_vec       float8[],
    baseline_vec    float8[],
    current_vec     float8[],
    cohort_doc_ids  int8[]  DEFAULT NULL,
    k               int     DEFAULT 5,
    id_col          text    DEFAULT 'id'
) RETURNS TABLE(nearest_cohort_id bigint, cohort_distance float8, drift_distance float8, rationale text, cohort_matches jsonb)
AS $$
DECLARE
    cohort         int8[];
    cohort_matches jsonb;
    cohort_dist    float8;
    traj_doc       int8;
    traj_dist      float8;
    resolved_id    bigint;
    rationale      text;
    has_row        int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF patient_table IS NULL OR vec_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_patient_deterioration_triage: identifier arguments must not be NULL';
    END IF;
    -- 0. Empty-table pre-check (the has_row IS NULL idiom; EXECUTE ... INTO
    -- does not set FOUND -- guard on the target variable, not FOUND).
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', patient_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_patient_deterioration_triage: no patient rows in %',
            patient_table;
    END IF;

    -- 1. Build the cohort. If cohort_doc_ids is NULL, use every row (mapped to
    -- 0-indexed scan positions via the repo's row_number() recipe). Otherwise
    -- the caller supplied a pre-built multi-predicate cohort. The row_number()
    -- must be computed in a subquery before array_agg -- postgres rejects
    -- array_agg(row_number() OVER (...)) directly.
    IF cohort_doc_ids IS NULL THEN
        EXECUTE format(
            'SELECT array_agg(idx) FROM (SELECT (row_number() OVER (ORDER BY ctid) - 1)::int8 AS idx FROM %I) s',
            patient_table) INTO cohort;
    ELSE
        cohort := cohort_doc_ids;
    END IF;
    IF cohort IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_patient_deterioration_triage: cohort matched no rows in %',
            patient_table;
    END IF;

    -- 2. Real Analytics: up to k nearest patients in the cohort (hybrid
    -- search), resolved to the named patient id via the ctid mapping in the
    -- same query -- the fractal_agent_recall_hybrid pattern above, adapted
    -- here so the cohort-search and id-resolution steps aren't two separate
    -- round trips. Ranked ascending by distance; nearest_cohort_id/
    -- cohort_distance below are always cohort_matches[0], kept for
    -- backward compatibility with callers written against the old
    -- single-match return shape.
    EXECUTE format(
        'SELECT jsonb_agg(jsonb_build_object(''id'', x.idv, ''distance'', r.distance) ORDER BY r.distance) '
        'FROM fractal_hybrid_clinical_search(%L, %L, $1, $2, %L) r '
        'JOIN (SELECT %I::bigint AS idv, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'ON x.doc_id = r.doc_id',
        patient_table, vec_col, k, id_col, patient_table)
        USING query_vec, cohort
        INTO cohort_matches;
    IF cohort_matches IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_patient_deterioration_triage: hybrid search returned no row in %', patient_table;
    END IF;
    resolved_id := (cohort_matches->0->>'id')::bigint;
    cohort_dist := (cohort_matches->0->>'distance')::float8;

    -- 3. Real Analytics: drift from baseline to current (trajectory
    -- search). Always a single result by design: this is a scalar "how far
    -- did this patient move" question, not a k-NN one, so k does not apply
    -- here.
    SELECT doc_id, distance INTO traj_doc, traj_dist
      FROM fractal_search_trajectory(patient_table, vec_col, baseline_vec, current_vec, 1);

    -- 4. Real Cognition: reason a triage over both signals. Reasons only
    -- over the single nearest cohort match plus the drift distance, not
    -- over every entry in cohort_matches, to keep this call's cost and
    -- wording unchanged regardless of k.
    rationale := fractal_reason(
        'Triage this patient: nearest cohort match is id ' || COALESCE(resolved_id::text, '?') ||
        ' at cosine distance ' || cohort_dist || '; baseline->current drift distance is ' || traj_dist ||
        '. Justify the deterioration triage in one sentence.',
        jsonb_build_object('cohort_distance', cohort_dist, 'drift_distance', traj_dist)::text);

    -- 5. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_patient_deterioration_triage', jsonb_build_object(
            'nearest_cohort_id', resolved_id, 'cohort_distance', cohort_dist,
            'drift_distance', traj_dist, 'rationale', rationale, 'cohort_matches', cohort_matches));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT resolved_id, cohort_dist, traj_dist, rationale, cohort_matches;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_patient_deterioration_triage(text, text, float8[], float8[], float8[], int8[], int, text) IS
  'Patient-deterioration triage engine. Builds a cohort of 0-indexed scan '
  'positions (from cohort_doc_ids if supplied, else every row), runs '
  'fractal_hybrid_clinical_search for the k nearest cohort patients and '
  'fractal_search_trajectory for the baseline->current drift, resolves each '
  'cohort match to its named patient id (id_col) via a ctid-row_number '
  'mapping, and calls fractal_reason to synthesize a triage over the single '
  'nearest match and the drift. Returns (nearest_cohort_id, '
  'cohort_distance, drift_distance, rationale, cohort_matches), where '
  'cohort_matches is a jsonb array of up to k {"id":..,"distance":..} '
  'entries ranked ascending by distance and nearest_cohort_id/ '
  'cohort_distance are always cohort_matches[0]. k controls only the '
  'cohort-search width; the drift search is always a single result. The '
  'cohort_doc_ids parameter lets the caller pass a multi-predicate cohort '
  '(e.g. age>65 AND condition=sepsis) that fractal_agent_recall_hybrid''s '
  'single (filter_col, filter_val) cannot express. Raises a clean ERROR if the '
  'patient table is empty or the cohort matches no rows. id_col must be '
  'bigint-castable. Generalizes the medtech-clinical demo''s hybrid-search + '
  'trajectory sections.';

-- =====================================================================
-- Engine I: fractal_agent_feedback_audit
-- =====================================================================
-- Recommendation-system feedback audit: a self-contained cycle that enables
-- session-global repulsion, warms the D_q rolling window with varied queries,
-- reports negative feedback on a target result (fractal_isolate_background),
-- then reads back the diversity quotient (fractal_detect_collapse) and session
-- diagnostics (fractal_explain_result). Pure analytics -- NO LLM step. Unlike
-- fractal_agent_recommend_diverse (which leaves diversify on for the caller),
-- this engine disables diversify itself -- it is a complete audit cycle.
-- Generalizes the recommendation-search demo's section-4 diversify loop.

CREATE FUNCTION fractal_agent_feedback_audit(
    catalog_table   text,
    emb_col         text,
    query_vec       float8[],
    warmup_table    text,
    warmup_vec_col  text,
    warmup_count    int   DEFAULT 8,
    k               int   DEFAULT 3
) RETURNS TABLE(diversity_quotient float8, explanation jsonb)
AS $$
DECLARE
    v          float8[];
    target_doc int8;
    dq         float8;
    diag       jsonb;
    has_row    int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF warmup_count IS NULL THEN
        warmup_count := 8;
    END IF;
    IF catalog_table IS NULL OR emb_col IS NULL OR warmup_table IS NULL OR warmup_vec_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_feedback_audit: identifier arguments must not be NULL';
    END IF;
    -- 0. Empty-table pre-check on the catalog.
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', catalog_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_feedback_audit: no catalog rows in %',
            catalog_table;
    END IF;

    -- 1. Enable session-global repulsion + the audit defaults (matching the
    -- recommendation-search demo section 4).
    PERFORM fractal_diversify_enable();
    PERFORM fractal_diversify_set_params(window_n => 5, repulsion_sigma => 0.3,
                                         repulsion_weight => 0.5);

    -- 2. Warm the D_q rolling window with varied queries (the window is empty
    -- until several searches have run; detect_collapse returns NaN otherwise).
    FOR v IN EXECUTE format('SELECT %I::float8[] FROM %I LIMIT %L',
                            warmup_vec_col, warmup_table, warmup_count) LOOP
        PERFORM * FROM fractal_search_telemetry(catalog_table, emb_col, v, k);
    END LOOP;

    -- 3. Capture the audit target's top doc_id and report negative feedback on
    -- it. fractal_isolate_background takes the doc_id (the demo passes the k=1
    -- telemetry doc_id as the handle).
    SELECT doc_id INTO target_doc
      FROM fractal_search_telemetry(catalog_table, emb_col, query_vec, 1);
    PERFORM fractal_isolate_background(target_doc);

    -- 4. Pure Analytics: diversity quotient + session diagnostics.
    dq := fractal_detect_collapse();
    diag := fractal_explain_result();

    -- 5. Self-contained audit cycle: disable diversify (unlike
    -- recommend_diverse, which leaves it on for the caller).
    PERFORM fractal_diversify_disable();

    RETURN QUERY SELECT dq, diag;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_feedback_audit(text, text, float8[], text, text, int, int) IS
  'Feedback-audit engine (pure analytics, NO LLM). Enables session-global '
  'repulsion (fractal_diversify_enable + set_params), warms the D_q rolling '
  'window by running fractal_search_telemetry over warmup_count varied vectors '
  'pulled from warmup_table, captures the k=1 telemetry doc_id for the audit '
  'target, calls fractal_isolate_background on it (the doc_id IS the handle), '
  'then returns (diversity_quotient, explanation) from fractal_detect_collapse '
  'and fractal_explain_result. Disables diversify itself -- a complete audit '
  'cycle (unlike fractal_agent_recommend_diverse, which leaves diversify on). '
  'Raises a clean ERROR if the catalog is empty. Generalizes the '
  'recommendation-search demo''s section-4 diversify loop.';

-- =====================================================================
-- Engine J: fractal_agent_schedule_workload
-- =====================================================================
-- Sovereign-Edge: schedule a workload onto the best node by first refining the
-- task vector with fractal_search (the "sniper search" in the abstract search
-- space), then finding the nearest node via fractal_search_telemetry, then
-- reasoning the placement. Like fractal_agent_route_task but with the
-- fractal_search refinement step route_task lacks. Generalizes the
-- sovereign-edge demo's section-3 sniper search.

CREATE FUNCTION fractal_agent_schedule_workload(
    task_vec      float8[],
    node_table    text,
    node_emb_col  text,
    node_id_col   text,
    iterations    int   DEFAULT 30,
    population    int   DEFAULT 50,
    k             int   DEFAULT 5,
    context       text  DEFAULT '{}'
) RETURNS TABLE(assigned_node text, confidence float8, rationale text)
AS $$
DECLARE
    refined      float8[];
    nearest_doc  int8;
    nearest_dist float8;
    assigned     text;
    confidence   float8;
    rationale    text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF node_table IS NULL OR node_emb_col IS NULL OR node_id_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_schedule_workload: identifier arguments must not be NULL';
    END IF;
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', node_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_schedule_workload: no node rows in %', node_table;
    END IF;

    -- 1. Real Analytics: refine the task vector (the "sniper search").
    refined := fractal_search(task_vec, iterations, population, 2);

    -- 2. Nearest node to the refined task vector.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_telemetry(node_table, node_emb_col, refined, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_schedule_workload: no node rows in %', node_table;
    END IF;

    -- 3. Resolve the 0-indexed scan position to the named node id via ctid.
    EXECUTE format(
        'SELECT %I FROM (SELECT %I, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'WHERE x.doc_id = %L',
        node_id_col, node_id_col, node_table, nearest_doc) INTO assigned;

    -- 4. Real Cognition: reason a one-line placement rationale.
    rationale := fractal_reason(
        'Schedule this workload onto node ' || COALESCE(assigned, '?') ||
        ' (cosine distance ' || nearest_dist || ' after fractal_search refinement). ' ||
        'Justify the placement in one sentence.',
        context);

    -- confidence is real, derived from the real nearest distance.
    confidence := 1.0 / (1.0 + nearest_dist);

    -- 5. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_schedule_workload', jsonb_build_object(
            'assigned_node', assigned, 'confidence', confidence, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT assigned, confidence, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_schedule_workload(float8[], text, text, text, int, int, int, text) IS
  'Workload-scheduling engine. Refines the task vector with fractal_search '
  '(iterations, population, diffusion_factor=2), then runs '
  'fractal_search_telemetry(node_table, node_emb_col, refined, 1) to find the '
  'nearest node, resolves the 0-indexed scan position to the named node id '
  '(node_id_col) via a ctid-row_number mapping, derives confidence = '
  '1/(1+distance) from the real distance, and calls fractal_reason for a '
  'one-line placement rationale. Returns (assigned_node, confidence, '
  'rationale). Like fractal_agent_route_task but with the fractal_search '
  'refinement step route_task lacks. Raises a clean ERROR if the node table '
  'is empty. Generalizes the sovereign-edge demo''s section-3 sniper search.';

-- =====================================================================
-- Engine K: fractal_agent_rebalance_sibling
-- =====================================================================
-- Quant-Finance: rebalance a portfolio by running the SFS cardinality-
-- constrained optimizer (fractal_optimize_portfolio), then finding the nearest
-- historical allocation pattern (fractal_search_trajectory over an allocation
-- snapshots table), then reasoning over both. Generalizes the quant-finance
-- demo's optimize_portfolio + search_trajectory sections (and the
-- fintech-mcts reference blueprint).

CREATE FUNCTION fractal_agent_rebalance_sibling(
    mu            float8[],
    cov           float8[],
    cardinality   int,
    alloc_table   text,
    alloc_emb_col text,
    baseline_vec  float8[],
    seed          bigint DEFAULT NULL,
    k             int    DEFAULT 5,
    id_col        text   DEFAULT 'id',
    context       text   DEFAULT '{}'
) RETURNS TABLE(sharpe float8, weights jsonb, nearest_alloc_id bigint, nearest_distance float8, rationale text)
AS $$
DECLARE
    opt          jsonb;
    w            float8[];
    s            float8;
    nearest_doc  int8;
    nearest_dist float8;
    resolved_id  bigint;
    rationale    text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF alloc_table IS NULL OR alloc_emb_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_rebalance_sibling: identifier arguments must not be NULL';
    END IF;
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', alloc_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_rebalance_sibling: no allocation rows in %', alloc_table;
    END IF;

    -- 1. Real Analytics: SFS cardinality-constrained Sharpe maximization.
    opt := fractal_optimize_portfolio(mu, cov, cardinality, seed);
    s := COALESCE((opt->>'sharpe')::float8, 0.0);
    -- weights as a float8[] vector for the trajectory search.
    w := ARRAY(SELECT jsonb_array_elements_text(opt->'weights')::float8);

    -- 2. Nearest historical allocation pattern to the optimized weights.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_trajectory(alloc_table, alloc_emb_col, baseline_vec, w, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_rebalance_sibling: no allocation rows in %', alloc_table;
    END IF;

    -- 3. Resolve to the named allocation id via ctid.
    EXECUTE format(
        'SELECT %I FROM (SELECT %I, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'WHERE x.doc_id = %L',
        id_col, id_col, alloc_table, nearest_doc) INTO resolved_id;

    -- 4. Real Cognition.
    rationale := fractal_reason(
        'Rebalance triage: the optimized portfolio has Sharpe ' || s ||
        ' and is nearest to historical allocation id ' || COALESCE(resolved_id::text, '?') ||
        ' (cosine distance ' || nearest_dist || '). Justify the rebalance in one sentence.',
        context);

    -- 5. Best-effort audit-chain provenance -- enterprise tier only;
    -- must not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_rebalance_sibling', jsonb_build_object(
            'sharpe', s, 'nearest_alloc_id', resolved_id,
            'nearest_distance', nearest_dist, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT s, opt->'weights', resolved_id, nearest_dist, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_rebalance_sibling(float8[], float8[], int, text, text, float8[], bigint, int, text, text) IS
  'Portfolio-rebalance engine. Runs fractal_optimize_portfolio(mu, cov, '
  'cardinality, seed) -- the SFS Sharpe maximizer -- extracts the weights as a '
  'float8[] vector, runs fractal_search_trajectory(alloc_table, alloc_emb_col, '
  'baseline_vec, weights, 1) to find the nearest historical allocation pattern, '
  'resolves its doc_id to the named allocation id (id_col) via a ctid-row_number '
  'mapping, and calls fractal_reason to synthesize the rebalance rationale. '
  'Returns (sharpe, weights, nearest_alloc_id, nearest_distance, rationale). '
  'cov must be a flattened 1-D row-major matrix. Raises a clean ERROR if the '
  'allocation table is empty. Also logs the decision to the audit chain via '
  'fractal_audit_log (enterprise tier; silently skipped on community). '
  'Generalizes the quant-finance demo''s optimize_portfolio + '
  'search_trajectory sections (and the fintech-mcts reference blueprint).';

-- =====================================================================
-- Engine L: fractal_agent_detour_classify
-- =====================================================================
-- Fleet-Logistics: classify a vehicle detour by combining the route-deviation
-- search (fractal_search_trajectory: current vs baseline across the fleet) with
-- the GPS trace's fractal complexity (fractal_dimension_boxcount), then
-- reasoning over both. Generalizes the fleet-logistics demo's trajectory +
-- boxcount + reason sections.

CREATE FUNCTION fractal_agent_detour_classify(
    vehicle_table  text,
    emb_col        text,
    baseline_vec   float8[],
    current_vec    float8[],
    gps_trace      float8[],
    k              int   DEFAULT 5,
    id_col         text  DEFAULT 'id',
    boxcount_dim   int   DEFAULT 2
) RETURNS TABLE(nearest_fleet_id bigint, trajectory_distance float8, trace_complexity float8, rationale text)
AS $$
DECLARE
    nearest_doc  int8;
    nearest_dist float8;
    resolved_id  bigint;
    bc           float8;
    rationale    text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF vehicle_table IS NULL OR emb_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_detour_classify: identifier arguments must not be NULL';
    END IF;
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', vehicle_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_detour_classify: no vehicle rows in %', vehicle_table;
    END IF;

    -- 1. Real Analytics: deviation of the current route vs. the fleet.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_trajectory(vehicle_table, emb_col, baseline_vec, current_vec, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_detour_classify: no vehicle rows in %', vehicle_table;
    END IF;

    -- 2. Real Analytics: GPS trace fractal complexity.
    bc := fractal_dimension_boxcount(gps_trace, boxcount_dim);

    -- 3. Resolve the nearest fleet peer's doc_id to the named vehicle id.
    EXECUTE format(
        'SELECT %I FROM (SELECT %I, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'WHERE x.doc_id = %L',
        id_col, id_col, vehicle_table, nearest_doc) INTO resolved_id;

    -- 4. Real Cognition.
    rationale := fractal_reason(
        'Detour classify: vehicle ' || COALESCE(resolved_id::text, '?') ||
        ' deviates from its baseline by cosine distance ' || nearest_dist ||
        ' (nearest fleet peer); its GPS trace has box-counting dimension ' || bc ||
        '. Classify the detour in one sentence.',
        jsonb_build_object('trajectory_distance', nearest_dist, 'trace_complexity', bc)::text);

    -- 5. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_detour_classify', jsonb_build_object(
            'nearest_fleet_id', resolved_id, 'trajectory_distance', nearest_dist,
            'trace_complexity', bc, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT resolved_id, nearest_dist, bc, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_detour_classify(text, text, float8[], float8[], float8[], int, text, int) IS
  'Detour-classification engine. Runs fractal_search_trajectory(vehicle_table, '
  'emb_col, baseline_vec, current_vec, 1) for the route deviation vs. the '
  'fleet, fractal_dimension_boxcount(gps_trace, boxcount_dim) for the GPS '
  'trace complexity, resolves the nearest fleet peer''s doc_id to the named '
  'vehicle id (id_col) via a ctid-row_number mapping, and calls fractal_reason '
  'to classify the detour. Returns (nearest_fleet_id, trajectory_distance, '
  'trace_complexity, rationale). Raises a clean ERROR if the vehicle table is '
  'empty. id_col must be bigint-castable. Generalizes the fleet-logistics '
  'demo''s trajectory + boxcount + reason sections.';

-- =====================================================================
-- Engine M: fractal_agent_track_anomaly
-- =====================================================================
-- Maritime / Cybersecurity: triage a track anomaly by combining the track-
-- deviation search (fractal_search_trajectory) with the heading-change series'
-- DFA exponent (fractal_dimension_dfa), then reasoning over both. Generalizes
-- the maritime-defense and cybersecurity demo sections. (dfa may return -1
-- "insufficient window" -- passed through; the reason step notes it.)

CREATE FUNCTION fractal_agent_track_anomaly(
    track_table    text,
    emb_col        text,
    baseline_vec   float8[],
    current_vec    float8[],
    heading_series float8[],
    k              int   DEFAULT 5,
    id_col         text  DEFAULT 'id'
) RETURNS TABLE(nearest_fleet_id bigint, trajectory_distance float8, dfa_exponent float8, rationale text)
AS $$
DECLARE
    nearest_doc  int8;
    nearest_dist float8;
    resolved_id  bigint;
    dfa          float8;
    rationale    text;
    has_row      int4;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF track_table IS NULL OR emb_col IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_track_anomaly: identifier arguments must not be NULL';
    END IF;
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', track_table) INTO has_row;
    IF has_row IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_track_anomaly: no track rows in %', track_table;
    END IF;

    -- 1. Real Analytics: deviation of the current track vs. the fleet.
    SELECT doc_id, distance INTO nearest_doc, nearest_dist
      FROM fractal_search_trajectory(track_table, emb_col, baseline_vec, current_vec, 1);
    IF nearest_doc IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_track_anomaly: no track rows in %', track_table;
    END IF;

    -- 2. Real Analytics: DFA exponent of the heading-change series.
    dfa := fractal_dimension_dfa(heading_series);

    -- 3. Resolve the nearest fleet peer's doc_id to the named track id.
    EXECUTE format(
        'SELECT %I FROM (SELECT %I, row_number() OVER (ORDER BY ctid) - 1 AS doc_id FROM %I) x '
        'WHERE x.doc_id = %L',
        id_col, id_col, track_table, nearest_doc) INTO resolved_id;

    -- 4. Real Cognition.
    rationale := fractal_reason(
        'Track anomaly: vessel/host ' || COALESCE(resolved_id::text, '?') ||
        ' deviates from baseline by cosine distance ' || nearest_dist ||
        '; its heading-change series has DFA exponent ' || dfa ||
        ' (dfa=-1 means insufficient window). Triage the track in one sentence.',
        jsonb_build_object('trajectory_distance', nearest_dist, 'dfa_exponent', dfa)::text);

    -- 5. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_track_anomaly', jsonb_build_object(
            'nearest_fleet_id', resolved_id, 'trajectory_distance', nearest_dist,
            'dfa_exponent', dfa, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT resolved_id, nearest_dist, dfa, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_track_anomaly(text, text, float8[], float8[], float8[], int, text) IS
  'Track-anomaly triage engine. Runs fractal_search_trajectory(track_table, '
  'emb_col, baseline_vec, current_vec, 1) for the track deviation vs. the '
  'fleet, fractal_dimension_dfa(heading_series) for the heading-change '
  'long-range-correlation exponent, resolves the nearest fleet peer''s doc_id '
  'to the named track id (id_col) via a ctid-row_number mapping, and calls '
  'fractal_reason to triage. Returns (nearest_fleet_id, trajectory_distance, '
  'dfa_exponent, rationale). dfa_exponent may be -1 (insufficient window) -- '
  'passed through. Raises a clean ERROR if the track table is empty. id_col '
  'must be bigint-castable. Generalizes the maritime-defense and cybersecurity '
  'demo sections.';

-- =====================================================================
-- Engine N: fractal_agent_network_coverage_alert
-- =====================================================================
-- Smart-Cities: issue a coverage alert by combining the sensor grid's spatial
-- morphology (fractal_morphological_complexity -> dimension + lacunarity) with
-- the telemetry series' regime-change drift (fractal_dimension_drift), then
-- reasoning over both. Generalizes the smart-cities demo's morphological +
-- drift + reason sections.

CREATE FUNCTION fractal_agent_network_coverage_alert(
    point_cloud      float8[],
    drift_series     float8[],
    boxcount_dim     int   DEFAULT 2,
    drift_win        int   DEFAULT 48,
    drift_threshold  float8 DEFAULT 0.5,
    context          text  DEFAULT '{}'
) RETURNS TABLE(morph_dimension float8, lacunarity float8, drift_detected boolean, rationale text)
AS $$
DECLARE
    morph     jsonb;
    drift     jsonb;
    md        float8;
    lac       float8;
    dv        float8;
    dd        boolean;
    rationale text;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF point_cloud IS NULL OR drift_series IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_network_coverage_alert: point_cloud and drift_series are required';
    END IF;

    -- 1. Real Analytics: spatial coverage morphology.
    morph := fractal_morphological_complexity(point_cloud, boxcount_dim);
    md := COALESCE((morph->>'dimension')::float8, 0.0);
    lac := COALESCE((morph->>'lacunarity')::float8, 0.0);

    -- 2. Real Analytics: regime-change drift on the telemetry series. The
    -- drift field is recent_alpha - baseline_alpha (a signed numeric, NOT a
    -- boolean); drift_detected is |drift| > drift_threshold (0.5 cleanly
    -- separates a real regime change from baseline noise).
    drift := fractal_dimension_drift(drift_series, drift_win);
    dv := COALESCE((drift->>'drift')::float8, 0.0);
    dd := abs(dv) > drift_threshold;

    -- 3. Real Cognition.
    rationale := fractal_reason(
        'Network coverage alert: the sensor grid has morphological dimension ' || md ||
        ' and lacunarity ' || lac || '; the telemetry drift is ' || dv ||
        ' (drift_detected=' || dd || ', threshold ' || drift_threshold || '). ' ||
        'Issue the coverage alert in one sentence.',
        context);

    -- 4. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_network_coverage_alert', jsonb_build_object(
            'morph_dimension', md, 'lacunarity', lac,
            'drift_detected', dd, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT md, lac, dd, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_network_coverage_alert(float8[], float8[], int, int, float8, text) IS
  'Network-coverage-alert engine. Runs fractal_morphological_complexity('
  'point_cloud, boxcount_dim) for the sensor grid''s spatial dimension + '
  'lacunarity, fractal_dimension_drift(drift_series, drift_win) for the '
  'telemetry regime-change drift (the drift field is recent_alpha - '
  'baseline_alpha, a signed numeric; drift_detected = |drift| > '
  'drift_threshold, default 0.5), and calls fractal_reason to synthesize the '
  'alert. Returns (morph_dimension, lacunarity, drift_detected, rationale). '
  'Raises a clean ERROR if point_cloud or drift_series is NULL. No table args '
  '-- pass the point cloud and drift series directly. Generalizes the '
  'smart-cities demo''s morphological + drift + reason sections.';

-- =====================================================================
-- Engine O: fractal_agent_regime_triage
-- =====================================================================
-- General: triage a regime change in a time series by combining the DFA
-- long-range-correlation exponent (fractal_dimension_dfa) with the regime-
-- change drift (fractal_dimension_drift), then reasoning over both. The
-- array-in shape fits any single series (no per-row time/metric table needed,
-- unlike fractal_agent_anomaly_triage). Generalizes the smart-cities, quant-
-- finance, and cybersecurity demos' dfa + drift sections.

CREATE FUNCTION fractal_agent_regime_triage(
    series           float8[],
    win              int   DEFAULT 64,
    drift_threshold  float8 DEFAULT 0.5,
    context          text  DEFAULT '{}'
) RETURNS TABLE(dfa_exponent float8, drift_detected boolean, recent_alpha float8, baseline_alpha float8, rationale text)
AS $$
DECLARE
    dfa       float8;
    drift     jsonb;
    dv        float8;
    dd        boolean;
    ra        float8;
    ba        float8;
    rationale text;
BEGIN
    -- Pin the base fractalsql extension's schema ahead of the caller's
    -- search_path so the unqualified fractal_* calls below resolve to the
    -- real base functions and cannot be shadowed by a hostile function in
    -- an attacker-writable schema earlier in the caller's search_path. The
    -- caller's search_path is appended (not replaced) so user table/column
    -- names passed as args and interpolated via %I still resolve. Resolved
    -- at runtime (not @extschema:fractalsql@, which is PG16+ only) to keep
    -- this extension portable across PG14-18. set_config(..., true) is
    -- transaction-local, so it reverts at the call's transaction end.
    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);
    IF series IS NULL THEN
        RAISE EXCEPTION 'fractal_agent_regime_triage: series is required';
    END IF;

    -- 1. Real Analytics: DFA long-range-correlation exponent.
    dfa := fractal_dimension_dfa(series);
    -- 2. Real Analytics: regime-change drift. The drift field is
    -- recent_alpha - baseline_alpha (a signed numeric, NOT a boolean);
    -- drift_detected is |drift| > drift_threshold.
    drift := fractal_dimension_drift(series, win);
    dv := COALESCE((drift->>'drift')::float8, 0.0);
    dd := abs(dv) > drift_threshold;
    ra := COALESCE((drift->>'recent_alpha')::float8, 0.0);
    ba := COALESCE((drift->>'baseline_alpha')::float8, 0.0);

    -- 3. Real Cognition.
    rationale := fractal_reason(
        'Regime triage: the series has DFA exponent ' || dfa ||
        ' and drift ' || dv || ' (drift_detected=' || dd || ', recent_alpha=' || ra ||
        ', baseline_alpha=' || ba || '). Triage the regime change in one sentence.',
        context);

    -- 4. Best-effort audit-chain provenance -- enterprise tier only; must
    -- not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_regime_triage', jsonb_build_object(
            'dfa_exponent', dfa, 'drift_detected', dd, 'drift', dv, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY SELECT dfa, dd, ra, ba, rationale;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_regime_triage(float8[], int, float8, text) IS
  'Regime-triage engine (general-purpose). Runs fractal_dimension_dfa(series) '
  'for the long-range-correlation exponent and fractal_dimension_drift(series, '
  'win) for the regime-change drift (the drift field is recent_alpha - '
  'baseline_alpha, a signed numeric; drift_detected = |drift| > '
  'drift_threshold, default 0.5) + recent/baseline alphas, then calls '
  'fractal_reason to synthesize the triage. Returns (dfa_exponent, '
  'drift_detected, recent_alpha, baseline_alpha, rationale). The array-in shape '
  'fits any single series (no per-row time/metric table, unlike '
  'fractal_agent_anomaly_triage). dfa_exponent may be -1 (insufficient window). '
  'Raises a clean ERROR if series is NULL. Generalizes the smart-cities, '
  'quant-finance, and cybersecurity demos'' dfa + drift sections.';

-- =====================================================================
-- Engine P: fractal_agent_diverse_portfolios
-- =====================================================================
-- Quant-Finance: enterprise tier. Like fractal_agent_allocate (Engine B)
-- but returns several structurally distinct good portfolios instead of
-- one, via fractal_optimize_portfolio_multimodal, plus one rationale
-- covering the tradeoffs across all of them.

CREATE FUNCTION fractal_agent_diverse_portfolios(
    mu                float8[],
    cov               float8[],
    cardinality       int,
    n_restarts        int    DEFAULT 8,
    overlap_threshold float8 DEFAULT 0.15,
    quality_frac      float8 DEFAULT 0.90,
    seed              bigint DEFAULT NULL,
    context           text   DEFAULT '{}',
    objective_mode    text   DEFAULT 'sharpe'
) RETURNS TABLE(candidate_id int, sharpe float8, weights jsonb, rationale text)
AS $$
DECLARE
    opt       jsonb;
    n_found   int;
    rationale text;
BEGIN
    IF objective_mode NOT IN ('sharpe', 'pareto') THEN
        RAISE EXCEPTION 'fractal_agent_diverse_portfolios: objective_mode must be '
            '''sharpe'' or ''pareto'' (got %)', objective_mode;
    END IF;

    PERFORM pg_catalog.set_config('search_path',
        COALESCE((SELECT e.extnamespace::regnamespace::text
                    FROM pg_catalog.pg_extension e
                   WHERE e.extname = 'fractalsql') || ',', '')
        || pg_catalog.current_setting('search_path'),
        true);

    IF objective_mode = 'pareto' THEN
        -- 1. Real Analytics: Pareto-front return/risk optimizer.
        -- overlap_threshold/quality_frac are ignored in this mode --
        -- they're specific to the sharpe-threshold + asset-overlap
        -- selection the 'sharpe' mode below uses, and have no
        -- equivalent in dominance-based selection.
        opt := fractal_optimize_portfolio_multimodal_pareto(
            mu, cov, cardinality, n_restarts, n_restarts, seed);
        n_found := (opt->>'n_found')::int;
        IF n_found IS NULL OR n_found = 0 THEN
            RAISE EXCEPTION 'fractal_agent_diverse_portfolios: no candidates found';
        END IF;

        -- 2. Real Cognition: one rationale covering the front's return/risk tradeoffs.
        rationale := fractal_reason(
            'Found ' || n_found || ' Pareto-optimal (non-dominated return-vs-risk) '
            'portfolios: ' ||
            (SELECT string_agg('return=' || (c->>'return') || ' risk=' || (c->>'risk'), '; ')
               FROM jsonb_array_elements(opt->'candidates') c) ||
            '. Summarize in one paragraph the return/risk tradeoffs a portfolio '
            'manager should weigh between these options.',
            context);

        -- 3. Best-effort audit-chain provenance -- enterprise tier only;
        -- must not break this agent for community users.
        BEGIN
            PERFORM fractal_audit_log('agent_diverse_portfolios', jsonb_build_object(
                'objective_mode', objective_mode, 'n_found', n_found,
                'cardinality', cardinality, 'rationale', rationale));
        EXCEPTION
            WHEN object_not_in_prerequisite_state THEN
                NULL;
        END;

        -- weights carries {weights, return, risk} in this mode --
        -- machine-queryable return/risk per row without a second call.
        RETURN QUERY
        SELECT (row_number() OVER () - 1)::int, (c->>'sharpe')::float8,
               jsonb_build_object('weights', c->'weights', 'return', c->'return', 'risk', c->'risk'),
               rationale
        FROM jsonb_array_elements(opt->'candidates') c;
        RETURN;
    END IF;

    -- 1. Real Analytics: enterprise multimodal Sharpe maximizer.
    opt := fractal_optimize_portfolio_multimodal(
        mu, cov, cardinality, n_restarts, overlap_threshold, quality_frac, seed);
    n_found := (opt->>'n_found')::int;
    IF n_found IS NULL OR n_found = 0 THEN
        RAISE EXCEPTION 'fractal_agent_diverse_portfolios: no candidates found';
    END IF;

    -- 2. Real Cognition: one rationale covering all candidates' tradeoffs.
    rationale := fractal_reason(
        'Found ' || n_found || ' structurally distinct portfolios with Sharpe ratios: ' ||
        (SELECT string_agg(c->>'sharpe', ', ') FROM jsonb_array_elements(opt->'candidates') c) ||
        '. Summarize in one paragraph the strategic tradeoffs a portfolio '
        'manager should weigh between these options.',
        context);

    -- 3. Best-effort audit-chain provenance -- enterprise tier only;
    -- must not break this agent for community users.
    BEGIN
        PERFORM fractal_audit_log('agent_diverse_portfolios', jsonb_build_object(
            'objective_mode', objective_mode, 'n_found', n_found,
            'cardinality', cardinality, 'rationale', rationale));
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;

    RETURN QUERY
    SELECT (row_number() OVER () - 1)::int, (c->>'sharpe')::float8, c->'weights', rationale
    FROM jsonb_array_elements(opt->'candidates') c;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fractal_agent_diverse_portfolios(float8[], float8[], int, int, float8, float8, bigint, text, text) IS
  'Diverse-portfolio engine (enterprise tier). objective_mode = ''sharpe'' '
  '(default) runs fractal_optimize_portfolio_multimodal(mu, cov, cardinality, '
  'n_restarts, overlap_threshold, quality_frac, seed) for up to n_restarts '
  'structurally distinct candidates, sharpe-threshold + asset-overlap selected; '
  'weights is a bare array. objective_mode = ''pareto'' instead runs '
  'fractal_optimize_portfolio_multimodal_pareto(mu, cov, cardinality, n_restarts, '
  'n_restarts, seed) for a genuine non-dominated return/risk Pareto front '
  '(overlap_threshold/quality_frac are ignored in this mode); weights becomes '
  '{weights, return, risk} so per-row return/risk are machine-queryable without '
  'a second call. Either mode then calls fractal_reason once to summarize the '
  'tradeoffs across all candidates. Returns one row per candidate: '
  '(candidate_id, sharpe, weights, rationale) -- rationale repeats per row (one '
  'reasoning call covering all candidates). cov must be a flattened row-major '
  'matrix. Errors with ''enterprise tier not loaded'' until '
  'fractalsql.enterprise_lib is set. Companion to fractal_agent_allocate '
  '(Engine B), which returns one portfolio.';