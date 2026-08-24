-- demo/enterprise-qtl-audit.sql
--
-- Enterprise Tier -- Quantized Ternary Ledger (QTL) + CISO Audit, end to end.
--
-- The QTL ledger and CISO audit surface are enterprise-tier features,
-- runtime-gated behind the enterprise core shared library. The community
-- extension (what the Docker image ships by default) carries all eight SQL
-- signatures, but they are DORMANT until the GUC `fractalsql.enterprise_lib`
-- points at a present enterprise core library (libfractalsql-enterprise-
-- sovereign-c.so / .dylib / .dll) AND the config has been reloaded.
--
-- This demo runs cleanly in BOTH states and tells you which one it found:
--
--   * Enterprise ACTIVE  -- the eight functions run for real: it seeds real
--     Truth/Shadow engagement events, flushes them to the `fractalsql_ledger`
--     table via the Postgres storage VFS, decodes the persisted QTL blob back
--     into a tamper-evident CISO audit log, and exercises load/compact/reset.
--
--   * Enterprise DORMANT -- the first enterprise call is caught and the demo
--     prints a single NOTICE explaining the surface is enterprise-only and
--     how to activate it. The community search engine is unaffected.
--
-- Both paths exit successfully (no ERROR) so this script is safe to drop into
-- a CI / demo run on a community-only image -- it self-reports rather than
-- blowing up.
--
-- Activate in the Docker demo container (enterprise assets are NOT shipped in
-- the image, so stage one in by hand to see the active path):
--
--   docker compose cp libfractalsql-enterprise-sovereign-c.so \
--       postgres:/tmp/libfractalsql-enterprise-sovereign-c.so
--   docker compose exec postgres psql -d fractalsql_demo -c \
--       "ALTER SYSTEM SET fractalsql.enterprise_lib = '/tmp/libfractalsql-enterprise-sovereign-c.so'; \
--        SELECT pg_reload_conf();"
--   docker compose exec postgres psql -d fractalsql_demo -f /demo/enterprise-qtl-audit.sql
--
-- Then remove the asset to confirm re-dormancy (the shipped, default state):
--
--   docker compose exec postgres rm /tmp/libfractalsql-enterprise-sovereign-c.so
--   docker compose exec postgres psql -d fractalsql_demo -f /demo/enterprise-qtl-audit.sql
--
-- Safe to re-run: the persisted ledger table is dropped up front and the
-- in-memory ledger context is per-session (a fresh `psql -f` starts empty).

\pset pager off
\encoding UTF8

-- Re-runnable: clear any prior persisted QTL blob. (fractalsql_ledger is a
-- plain table created lazily by the first successful flush, not an extension
-- member, so a bare DROP IF EXISTS is safe and does not need the enterprise
-- tier loaded.)
DROP TABLE IF EXISTS fractalsql_ledger;

\echo '=== 1. Seed real engagement events into the in-memory Truth/Shadow ledgers ==='
\echo 'fractal_feedback_report() is a COMMUNITY primitive -- it records search'
\echo 'engagement (dwell / positive -> Truth, negative -> Shadow) into the same'
\echo 'in-memory context the enterprise ledger later seals. No enterprise tier'
\echo 'needed for this step.'

-- Enable the diversify/repulsion path so the documented precondition for
-- engagement recording is met (the inserts themselves are ledger-level, but
-- this matches the contract the SQL comments describe).
SELECT fractal_diversify_enable();

-- Record two Truth events (positive + dwell) and two Shadow events (negative).
-- result_handle is the corpus row index the event refers to; the ledger stores
-- (doc_id, signal, epoch) per event.
SELECT fractal_feedback_report(1, 'positive', 500);   -- Truth: doc 1
SELECT fractal_feedback_report(2, 'dwell',   1200);    -- Truth: doc 2
SELECT fractal_feedback_report(3, 'negative');          -- Shadow: doc 3
SELECT fractal_feedback_report(4, 'negative');          -- Shadow: doc 4

\echo ''
\echo '=== 2. Enterprise QTL Ledger + CISO Audit ==='

-- One DO block, exception-guarded so the dormant path prints a message
-- instead of erroring out. The first enterprise call (fractal_ledger_flush)
-- is the probe: if the enterprise core library is loaded it succeeds and the
-- whole active sequence runs; if not it raises object_not_in_prerequisite_state
-- and the handler reports the dormant state.
DO $$
DECLARE
    tc bigint;
    sc bigint;
    audit jsonb;
BEGIN
    -- Flush: encode the in-memory Truth + Shadow ledgers into a QTL blob and
    -- persist it to fractalsql_ledger (kind = 1) via the storage VFS.
    PERFORM fractal_ledger_flush();
    SELECT fractal_ledger_truth_count()  INTO tc;
    SELECT fractal_ledger_shadow_count() INTO sc;
    RAISE NOTICE 'Phase A - flush:    persisted QTL blob   ->  truth_count=%  shadow_count=%', tc, sc;

    -- CISO audit: decode the just-flushed blob back into its tamper-evident
    -- event log (one {"epoch","doc_id","signal"} object per ledger entry,
    -- sorted by doc_id). This is the round-trip: in-memory -> QTL blob ->
    -- persisted table -> decoded audit log.
    SELECT fractal_audit_unpack(blob) INTO audit
      FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
    RAISE NOTICE 'Phase B - audit:    CISO event log = %', audit;

    -- Load: rehydrate the in-memory ledgers from the persisted blob.
    PERFORM fractal_ledger_load();
    RAISE NOTICE 'Phase C - load:     rehydrated ledgers from persisted QTL blob';

    -- Compact: defragment / re-pack the in-memory QTL representation.
    PERFORM fractal_ledger_compact();
    RAISE NOTICE 'Phase D - compact:  ledger defragmented';

    -- Reset soft: clear the Shadow ledger, preserve Truth.
    PERFORM fractal_ledger_reset_soft();
    SELECT fractal_ledger_truth_count()  INTO tc;
    SELECT fractal_ledger_shadow_count() INTO sc;
    RAISE NOTICE 'Phase E - reset_soft: shadow cleared      ->  truth_count=%  shadow_count=%', tc, sc;

    -- Reset hard: clear both ledgers.
    PERFORM fractal_ledger_reset_hard();
    SELECT fractal_ledger_truth_count()  INTO tc;
    SELECT fractal_ledger_shadow_count() INTO sc;
    RAISE NOTICE 'Phase F - reset_hard: both cleared        ->  truth_count=%  shadow_count=%', tc, sc;

    RAISE NOTICE 'Enterprise QTL Ledger + CISO Audit demo: ACTIVE -- all 8 functions ran clean.';
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        RAISE NOTICE 'Enterprise tier not loaded. fractal_ledger_* and fractal_audit_unpack are enterprise-tier features and are dormant on this community image. To activate: stage libfractalsql-enterprise-sovereign-c.so into the container, run "ALTER SYSTEM SET fractalsql.enterprise_lib = ''<path>''; SELECT pg_reload_conf();", then re-run this demo. The community search engine above ran normally.';
END $$;

\echo ''
\echo '=== Demo complete ==='