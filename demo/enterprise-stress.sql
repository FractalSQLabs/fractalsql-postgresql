-- demo/enterprise-stress.sql
--
-- Enterprise Tier -- QTL Ledger under stress + tamper-evidence.
--
-- Companion to enterprise-qtl-audit.sql (which walks the 8 functions one
-- call at a time). This demo hammers the same surface: it fills the
-- in-memory Truth/Shadow ledgers to their capacity bound (64 each), churns
-- repeated flush/load cycles, and probes the ledger's tamper-evidence by
-- corrupting the persisted QTL blob and confirming load rejects it.
--
-- Like the audit demo, this runs cleanly in BOTH states and tells you which:
--
--   * Enterprise ACTIVE  -- fills to cap (128 events), round-trips them
--     through the QTL encode -> fractalsql_ledger table -> decode path,
--     churns 5 flush/load cycles, confirms a structurally corrupted
--     (truncated) blob is rejected on load (Phase B), an HMAC-tagged
--     payload byte-flip is rejected even when structurally valid (Phase
--     D), and walks the append-only chain: multi-row
--     fractal_ledger_verify(), a middle-row tamper that load()'s O(1)
--     tip-only check cannot see but verify()'s full walk catches (Phase
--     E).
--
--   * Enterprise DORMANT -- the first enterprise call raises
--     object_not_in_prerequisite_state and the handler prints a single
--     NOTICE explaining the surface is enterprise-only. Community search
--     is unaffected.
--
-- Concurrency / cross-session persistence (parallel last-writer-wins
-- flush, and load-in-a-fresh-backend) are exercised by build_test gate 25
-- (gate_25_enterprise_stress / Gate25EnterpriseStress), which can fork
-- parallel psql backends -- not something a single `psql -f` can do.
--
-- Activate in the Docker demo container (enterprise assets are NOT shipped
-- in the image, so stage one in by hand to see the active path):
--
--   docker compose cp libfractalsql-enterprise-sovereign-c.so \
--       postgres:/tmp/libfractalsql-enterprise-sovereign-c.so
--   docker compose exec postgres psql -d fractalsql_demo -c \
--       "ALTER SYSTEM SET fractalsql.enterprise_lib = '/tmp/libfractalsql-enterprise-sovereign-c.so'; \
--        SELECT pg_reload_conf();"
--   docker compose exec postgres psql -d fractalsql_demo -f /demo/enterprise-stress.sql
--
-- Safe to re-run: the persisted ledger table is dropped up front and the
-- in-memory ledger context is per-session (a fresh `psql -f` starts empty).

\pset pager off
\encoding UTF8

-- Re-runnable: clear any prior persisted QTL blob.
DROP TABLE IF EXISTS fractalsql_ledger;

\echo '=== Enterprise QTL Ledger -- stress + tamper-evidence ==='
\echo 'fractal_feedback_report() is a COMMUNITY primitive used to seed the'
\echo 'in-memory Truth/Shadow ledgers that the enterprise tier later seals'
\echo 'into a QTL blob. Caps: 64 Truth + 64 Shadow (FSQL_TRUTH/SHADOW_DEFAULT_CAP).'

-- The diversify/repulsion path is the documented precondition for
-- engagement recording; the inserts themselves are ledger-level.
SELECT fractal_diversify_enable();

-- One exception-guarded DO block. The first enterprise call
-- (fractal_ledger_reset_hard) is the dormant probe: it succeeds under the
-- enterprise tier and raises object_not_in_prerequisite_state otherwise.
DO $$
DECLARE
    i    int;
    c    int;
    tc   bigint;
    sc   bigint;
    ev   int;
    audit jsonb;
BEGIN
    -- ---------- Phase A: fill to capacity bound + audit round-trip ----
    PERFORM fractal_ledger_reset_hard();
    -- 64 distinct Truth events (doc_ids 1..64) + 64 distinct Shadow
    -- events (doc_ids 65..128). Disjoint doc_ids => no QTL dedup => the
    -- blob encodes all 128. Beyond 64 of either kind the ledger evicts
    -- the lowest-weight entry, so 64/64 is the cap.
    FOR i IN 1..64 LOOP
        PERFORM fractal_feedback_report(i, 'positive');
    END LOOP;
    FOR i IN 65..128 LOOP
        PERFORM fractal_feedback_report(i, 'negative');
    END LOOP;
    SELECT fractal_ledger_truth_count()  INTO tc;
    SELECT fractal_ledger_shadow_count() INTO sc;
    RAISE NOTICE 'Phase A - fill:   truth=%  shadow=%  (caps 64/64)', tc, sc;

    PERFORM fractal_ledger_flush();
    SELECT fractal_audit_unpack(blob) INTO audit
      FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
    ev := jsonb_array_length(audit);
    RAISE NOTICE 'Phase A - audit:  % CISO events decoded from the persisted QTL blob', ev;
    IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
        RAISE EXCEPTION 'Phase A mismatch: truth=% shadow=% events=% (expected 64/64/128)', tc, sc, ev;
    END IF;

    -- ---------- Phase B: churn (5 flush/load cycles at capacity) -------
    FOR c IN 1..5 LOOP
        PERFORM fractal_ledger_reset_hard();
        FOR i IN 1..64 LOOP
            PERFORM fractal_feedback_report(i + 1000 * c, 'positive');
        END LOOP;
        FOR i IN 65..128 LOOP
            PERFORM fractal_feedback_report(i + 1000 * c, 'negative');
        END LOOP;
        PERFORM fractal_ledger_flush();
        PERFORM fractal_ledger_load();
    END LOOP;
    SELECT fractal_ledger_truth_count()  INTO tc;
    SELECT fractal_ledger_shadow_count() INTO sc;
    SELECT fractal_audit_unpack(blob) INTO audit
      FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
    ev := jsonb_array_length(audit);
    RAISE NOTICE 'Phase B - churn:  5 flush/load cycles -> truth=% shadow=% events=%', tc, sc, ev;
    IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
        RAISE EXCEPTION 'Phase B mismatch: truth=% shadow=% events=% (expected 64/64/128)', tc, sc, ev;
    END IF;

    -- ---------- Phase C: tamper-evidence (structural) -----------------
    -- Flush a small clean blob, then truncate it in the table below the
    -- 24-byte QTL header. load() must reject it (FSQL_ELEDGER_INTEGRITY ->
    -- the SQL wrapper raises ERRCODE_INTERNAL_ERROR, caught here as
    -- internal_error). If load SUCCEEDS on a truncated blob, that is a
    -- tamper-evidence FAILURE and we raise.
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(1, 'positive');
    PERFORM fractal_feedback_report(2, 'negative');
    PERFORM fractal_ledger_flush();
    UPDATE fractalsql_ledger
       SET blob = substring(blob from 1 for 5)   -- 5 bytes < 24-byte header
     WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
    BEGIN
        PERFORM fractal_ledger_load();
        RAISE EXCEPTION 'Phase C: tamper NOT detected -- load accepted a truncated QTL blob';
    EXCEPTION
        WHEN internal_error THEN
            RAISE NOTICE 'Phase C - tamper: structural corruption DETECTED -- load rejected the truncated QTL blob';
    END;
    -- NOTE: by default (no fractalsql.enterprise_ledger_key) the QTL format
    -- carries no MAC and the seal VFS op is a no-op, so this Phase C is
    -- STRUCTURAL tamper-evidence only (truncation / count-length mismatch).
    -- A targeted payload byte-flip (e.g. changing a stored doc_id) is NOT
    -- detected by the structural check. Phase D below sets
    -- fractalsql.enterprise_ledger_key to add an HMAC-SHA256 envelope that
    -- DOES catch that byte-flip (cryptographic tamper-evidence).

    RAISE NOTICE 'Enterprise stress + tamper-evidence demo: ACTIVE -- all phases ran clean.';
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        RAISE NOTICE 'Enterprise tier not loaded. fractal_ledger_* and fractal_audit_unpack are enterprise-tier features and are dormant on this community image. To activate: stage libfractalsql-enterprise-sovereign-c.so into the container, run "ALTER SYSTEM SET fractalsql.enterprise_lib = ''<path>''; SELECT pg_reload_conf();", then re-run this demo. Concurrency/cross-session coverage lives in build_test gate 25.';
END $$;

\echo ''
\echo '=== Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_key) ==='
\echo 'fractal_ledger_load() verifies an HMAC-SHA256 tag over the persisted blob'
\echo 'before the core decodes it, so a payload byte-flip the structural check'
\echo 'cannot see (length + count preserved) is now rejected. PGC_SUSET key: a'
\echo 'superuser SETs it per-session (no reload).'

-- PGC_SUSET: a superuser can SET it per-session -- no ALTER SYSTEM/reload.
SET fractalsql.enterprise_ledger_key = 'demo-mac-key';

DO $$
BEGIN
    -- Tag a fresh blob, then load (MAC verifies -> ok).
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(1, 'positive');
    PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_load();
    RAISE NOTICE 'Phase D - tag+load: HMAC-SHA256 tagged the blob, load verified it';

    -- Tamper: flip a MIDDLE payload byte. Length and the 24-byte header
    -- count field are preserved, so the structural decode check cannot see
    -- it (it would decode to a corrupted doc_id). The MAC must catch it.
    UPDATE fractalsql_ledger
       SET blob = set_byte(blob, length(blob) / 2, 254)
     WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
    BEGIN
        PERFORM fractal_ledger_load();
        RAISE EXCEPTION 'Phase D: MAC tamper NOT detected -- load accepted a byte-flipped blob';
    EXCEPTION
        WHEN internal_error THEN
            RAISE NOTICE 'Phase D - tamper: payload byte-flip DETECTED by HMAC -- load rejected the tampered blob';
    END;

    -- Recovery: re-flush re-tags a fresh, consistent blob; load verifies ok.
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(1, 'positive');
    PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_load();
    RAISE NOTICE 'Phase D - recover: re-flush re-tagged the blob, load verified clean';
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        RAISE NOTICE 'Enterprise tier not loaded -- Phase D (MAC) skipped.';
END $$;

RESET fractalsql.enterprise_ledger_key;

\echo ''
\echo '=== Phase E: append-only chain ==='
\echo 'The ledger is now an append-only hash chain, not a last-writer-wins'
\echo 'snapshot: every row links to its predecessor via'
\echo 'entry_hash = SHA256(prev_hash || blob || mac). fractal_ledger_load()'
\echo 'only checks the chain TIP (O(1), cheap, every load) --'
\echo 'fractal_ledger_verify() walks the WHOLE chain (O(n), on demand) and'
\echo 'catches tampering anywhere in history, not just the latest row.'
\echo '(Fresh chain for this phase -- Phase C left a deliberately corrupted'
\echo 'row in history above, and verify() correctly never forgets that; a'
\echo 'clean slate here isolates THIS phase''s own tamper demonstration.)'

DROP TABLE IF EXISTS fractalsql_ledger;

DO $$
DECLARE v jsonb;
BEGIN
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(1, 'positive'); PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(2, 'positive'); PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(3, 'positive'); PERFORM fractal_ledger_flush();

    SELECT fractal_ledger_verify() INTO v;
    RAISE NOTICE 'Phase E - verify: % (expect ok=true, rows_verified=3)', v;

    -- Tamper a MIDDLE row (id=2), not the latest (id=3).
    UPDATE fractalsql_ledger SET blob = set_byte(blob, 0, 254) WHERE id = 2;

    -- load() only checks the tip (id=3) -- still succeeds. This is the
    -- documented O(1) scope boundary, not a bug: it's the same tradeoff
    -- every load() has always made (cheap check on the hot path), now
    -- made visible because there's finally history to have a boundary
    -- against.
    PERFORM fractal_ledger_load();
    RAISE NOTICE 'Phase E - load: still succeeds after a MIDDLE-row tamper (O(1) tip-only scope)';

    -- verify()'s full walk catches it.
    SELECT fractal_ledger_verify() INTO v;
    RAISE NOTICE 'Phase E - verify after tamper: % (expect ok=false, first_failure_id=2)', v;

    -- There is no in-place "recovery" from a tampered row: reset_hard only
    -- clears the IN-MEMORY ledgers, not the persisted table, so a new
    -- flush appends on top of the still-corrupted history -- verify()
    -- correctly keeps reporting the historical break. That is the point
    -- of an append-only chain: it does not forget. Genuine recovery means
    -- starting a fresh chain (DROP the table -- in a real deployment,
    -- archive the old one first with a documented incident record).
    PERFORM fractal_ledger_reset_hard();
    PERFORM fractal_feedback_report(1, 'positive');
    PERFORM fractal_ledger_flush();
    SELECT fractal_ledger_verify() INTO v;
    RAISE NOTICE 'Phase E - new activity does NOT erase history: % (still ok=false -- the tampered row is permanent)', v;
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        RAISE NOTICE 'Enterprise tier not loaded -- Phase E (append-only chain) skipped.';
END $$;

\echo ''
\echo 'Deletion is also visible: DELETE any row but the latest and'
\echo 'fractal_ledger_verify() reports a sequence gap at that id (try it --'
\echo '"DELETE FROM fractalsql_ledger WHERE id = 2;" then re-run'
\echo 'fractal_ledger_verify()). Concurrency (parallel append-only writers'
\echo 'staying one unforked chain) and detached-signature verification of'
\echo 'the enterprise .so itself (fractalsql.enterprise_require_signature)'
\echo 'are exercised by build_test gates 25 and 26 -- not something a'
\echo 'single `psql -f` session can drive.'

\echo ''
\echo '=== Demo complete ==='