<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Enterprise Tier — CISO Decision Audit & Quantized Ternary Ledger (QTL)

QTL is a hash-chained, tamper-evident audit ledger for agent and optimizer
decisions. The mechanism is described in full below.

The core FractalSQL extension (Discovery, Cognition, and Agency) ships in
the Community edition and works fine on its own; none of it needs anything
described on this page. This tier exists for regulated environments
that need to prove what an agent decided, not just claim it:
every optimizer call and agent decision can write a tamper-evident record a
CISO or auditor can verify, rather than a log line they simply have to trust.

This is delivered as a drop-in core library: **no rebuild, no extension
reload**. The same community extension binary ships the SQL signatures;
whether they do real work depends entirely on a runtime GUC.

**Community edition (default):** all nine functions are present but
**dormant**. Calling one returns a clear, actionable error:

```
ERROR: fractalsql: enterprise tier not loaded
HINT: QTL ledger and CISO audit are FractalSQL Enterprise features. Set
fractalsql.enterprise_lib to the path of the enterprise core library
(libfractalsql-enterprise-sovereign-c.so / .dll / .dylib) and reconnect,
or contact your vendor for FractalSQL Enterprise.
```

**Enterprise edition:** drop the enterprise core shared library into
`include/` (or anywhere readable by the server) and point the GUC at it:

```sql
ALTER SYSTEM SET fractalsql.enterprise_lib =
  '/path/to/libfractalsql-enterprise-sovereign-c.so';
SELECT pg_reload_conf();
```

`pg_reload_conf()` is asynchronous. A fresh backend started a moment later
picks up the new value (the GUC is `SIGHUP`-scoped, so it cannot be set with a
per-session `SET`). The nine functions then activate and operate on the same
in-memory context the community search engine already built (eight ledger-
management functions plus `fractal_audit_unpack` for CISO decode), and the
ledger persists through a Postgres-backed storage VFS into the
`fractalsql_ledger` table:

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush()` | Encode truth + shadow ledgers into a QTL blob and append it to the chain. |
| `fractal_ledger_load()` | Hydrate the in-memory ledgers from the chain's latest entry (verifies only the tip, O(1)). |
| `fractal_ledger_verify()` | Walk the ENTIRE chain (O(n), on demand) and return a `jsonb` audit report. |
| `fractal_ledger_compact()` | Defragment / re-pack the in-memory QTL representation. |
| `fractal_ledger_reset_soft()` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard()` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count()` | Truth-side entry count (`bigint`). |
| `fractal_ledger_shadow_count()` | Shadow-side entry count (`bigint`). |
| `fractal_audit_unpack(bytea)` | Decode a persisted QTL blob into its audit JSON (`jsonb`). |

**Removing the library re-dormants the surface**: point the GUC back at a
missing path (or unset it) and reload. The functions return to the
*enterprise tier not loaded* error with no recompile. The search engine and
every community primitive keep working unchanged; only the ledger/audit
surface is gated.

**`fractal_audit_log(entry_type, payload)`**: the general decision-audit
chain. A second, independent append-only chain in `fractalsql_ledger`
(`kind=2`, same hash-chain guarantees as the QTL chain, verify with
`fractal_ledger_verify(2)`) for provenance records rather than QTL blobs.
`fractal_text_to_sql`, `fractal_optimize_portfolio`,
`fractal_optimize_portfolio_multimodal`, and
`fractal_optimize_portfolio_multimodal_pareto` log to it automatically
when enterprise is active. Silently skipped on community, so none of
them ever depend on a license to keep working. Query it directly: `SELECT id,
updated, convert_from(blob, 'UTF8')::jsonb FROM fractalsql_ledger WHERE
kind = 2 ORDER BY id`.

Every decision-making agent in `fractalsql_agents` logs its own decision
to the same chain with the same best-effort, community-safe pattern (each
wraps its `fractal_audit_log` call in `BEGIN ... EXCEPTION WHEN
object_not_in_prerequisite_state THEN NULL; END;`, so a missing enterprise
tier never breaks the agent): `fractal_agent_anomaly_triage`,
`fractal_agent_allocate`, `fractal_agent_route_task`,
`fractal_agent_outlier_intercept`, `fractal_agent_data_analyst`,
`fractal_agent_patient_deterioration_triage`,
`fractal_agent_schedule_workload`, `fractal_agent_rebalance_sibling`,
`fractal_agent_detour_classify`, `fractal_agent_track_anomaly`,
`fractal_agent_network_coverage_alert`, `fractal_agent_regime_triage`,
and `fractal_agent_diverse_portfolios`. The pure-retrieval/pure-analytics
engines (`fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`,
`fractal_agent_feedback_audit`) don't make a decision worth auditing, so
they're intentionally not wired up.

**`fractal_optimize_portfolio_multimodal()`** (enterprise tier): like
`fractal_optimize_portfolio` but runs several independent restarts and
returns up to `n_restarts` structurally distinct portfolios instead of
one: candidates within `quality_frac` of the best Sharpe found, no two
sharing more than `overlap_threshold` of their assets. Same entropy
engine as the single-best version; the gate gives access to the
multi-restart + diverse-selection capability, not a different algorithm.
Paired agent: `fractal_agent_diverse_portfolios` in `fractalsql_agents`.
It logs to the decision-audit chain above the same way.

**`fractal_optimize_portfolio_multimodal_pareto()`** (enterprise tier):
Pareto-front sibling of the function above: same `n_restarts`
independent searches, but scores each by decomposed **return/risk**
instead of scalar Sharpe and reduces them to a genuine non-dominated
Pareto front (NSGA-II crowding-distance truncation past `max_front`)
rather than sharpe-threshold + asset-overlap selection. Purely
additive, doesn't change the sibling function's semantics. All three
`fractal_optimize_portfolio*` functions also accept `use_obl`
(Opposition-Based Learning: evaluate each SFS trial candidate's
bound-reflected opposite, keep whichever fits better) and
`diffusion_mode` (`'gaussian'` default or `'levy'`, a heavy-tailed
Mantegna-algorithm step that can help escape local optima on highly
multimodal problems). Same `fractal_agent_diverse_portfolios` agent
exposes both via its `objective_mode := 'sharpe' | 'pareto'` parameter.

**Append-only chain, not a snapshot.** The ledger is a genuine history: every
row links to its predecessor via `entry_hash = SHA256(prev_hash || blob ||
mac)`, and writes are plain `INSERT`s, never `UPDATE`/`UPSERT`. A rewritten
row breaks the chain; a deleted row leaves a visible gap in the `id`
sequence. This holds **even without a MAC key**: `entry_hash` covers the
blob unconditionally, so a byte-flip anywhere in history is structurally
detectable, not just cryptographically. Set the `fractalsql.enterprise_ledger_key`
GUC (superuser-only, `PGC_SUSET`, settable per-session) to additionally
**HMAC-SHA256-tag** each blob, authenticating it against forgery by anyone
who doesn't hold the key. `fractal_ledger_load()` checks only the chain's
tip on every call (cheap, O(1));
`fractal_ledger_verify()` walks the full chain for a periodic or on-demand
CISO audit (O(n), not run automatically). One honest limit: the chain can
prove nothing in the *middle* was altered or removed, but it can't prove
nothing was truncated off the very *end*: there's nothing after the last
row to notice its absence. That needs an external anchor (e.g. publishing
the head hash somewhere independent). See **External anchoring** below
for a ready-to-use recipe. (See `demo/enterprise-stress.sql` Phase E and
`build_test` gate 25 Phase E.)

### External anchoring (closing the truncation gap)

`scripts/enterprise/anchor-ledger.sh` periodically records the chain's tip
(`kind`, `id`, `entry_hash`) somewhere outside this database: a place the
Postgres admin's own credentials can't retroactively edit. Run it on a
schedule (cron, systemd timer) per `kind` you audit:

```bash
*/15 * * * * PGHOST=... PGDATABASE=... /path/to/anchor-ledger.sh 1 >> /var/log/fractalsql/anchor.log
*/15 * * * * PGHOST=... PGDATABASE=... /path/to/anchor-ledger.sh 2 >> /var/log/fractalsql/anchor.log
```

The script itself only formats and prints the anchor record. Where it
*publishes* to (syslog for SIEM ingestion, an S3 Object Lock bucket, a
compliance mailbox) is a few commented-out lines you uncomment for your
own environment; see the script's own header for each option and why
plain stdout redirection alone doesn't satisfy the guarantee.

To verify an anchor later, confirm the live table still has a row at the
anchored `id`, for that `kind`, with that exact `entry_hash`:

```sql
SELECT entry_hash = '\x<anchored hex>'::bytea
FROM fractalsql_ledger WHERE kind = <kind> AND id = <anchored id>;
```

`false` or no matching row means the row was altered, or the chain was
rewound past it, after the anchor was taken.

**Detached signature verification (optional hardening).** The 8-symbol
`dlsym` check in `ensure_enterprise_lib()` only proves a file has the right
function *names*. A tampered file with the same names sails through it
untouched. Set `fractalsql.enterprise_require_signature = on` (superuser-only,
`PGC_SIGHUP`) to additionally require a valid detached Ed25519 signature (a
sibling `<path>.sig` file, 64 raw bytes) against a fixed FractalSQLabs public
key before the library is `dlopen`'d. Off by default: a missing `.sig` only
logs a `WARNING` and the library still loads, so this is backward compatible
with unsigned releases. An **invalid** signature (present but wrong) is
always refused regardless of the setting: unambiguous tamper evidence,
unlike a merely absent file. New enterprise releases only need a fresh
signature from the same long-lived key; this extension never needs
rebuilding, preserving the drop-in-`.so` design a hash pin would have broken.
(See `build_test` gate 26.)

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.
