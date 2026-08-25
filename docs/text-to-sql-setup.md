<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Production-Safe Text-to-SQL

`fractal_text_to_sql` is a core primitive of the **Cognition Tier**. It transforms natural-language questions into mechanically validated SQL statements, providing a safe bridge between intent and execution.

Unlike naive LLM-to-SQL wrappers, FractalSQL treats SQL generation as a **hard-constrained engineering problem**, not a probabilistic one. It employs a multi-stage validation pipeline to ensure that every returned statement is syntactically correct, semantically valid, and policy-compliant before it ever reaches your application.

---

## Quick Start

By default, `fractal_text_to_sql` auto-discovers every table the calling role can `SELECT` from. That's the simplest, most effective default for most use cases.

```sql
SELECT fractal_text_to_sql('How many orders does customer ''acme'' have?');
--  SELECT count(*) FROM orders WHERE customer_id = 
--    (SELECT id FROM customers WHERE name = 'acme')
```

### Scoping the Context
For large schemas, you can explicitly narrow the schema context sent to the LLM. This reduces token cost, minimizes noise, and allows you to strictly control what metadata leaves your database boundary.

```sql
SELECT fractal_text_to_sql(
    question    => 'How many orders does customer ''acme'' have?',
    table_names => ARRAY['orders', 'customers']
);
```

---

## The Safety Pipeline: How it Works

FractalSQL implements a rigorous verification loop to eliminate "hallucinated" SQL.

```
GENERATE ──▶ [REVIEW, optional] ──▶ ALLOWLIST ──▶ EXPLAIN ──▶ RETURN
   ▲                                    │              │
   └──────────── retry, with the specific failure fed back ───┘
```

1. **GENERATE**: The question and schema description (from `fractal_schema_context()`) are sent to the LLM.
2. **REVIEW** *(Optional)*: A second LLM call critiques the candidate against the original question.
3. **ALLOWLIST**: The candidate is parsed using the PostgreSQL `raw_parser`. It is rejected if it contains multiple statements, DDL/utility commands (`CREATE`, `DROP`, etc.), or statement types not permitted by `fractalsql.text_to_sql_allowed_statements`. In `select` mode, it also rejects data-modifying CTEs.
4. **EXPLAIN**: The candidate is mechanically planned via the Postgres planner **inside an internal subtransaction**. If a planner error occurs (e.g., bad column name), the error is caught and fed back for a retry without aborting your main transaction.
5. **RETURN or RETRY**: On success, the SQL is returned. On failure, the specific error (from the allowlist or planner) is fed back into the next generation attempt, up to `fractalsql.text_to_sql_max_attempts`.

### The Subtransaction Guardrail (Safe Agency)
While `fractal_text_to_sql` only returns text, its logic is the foundation for the `fractal_sql_agent`. The use of internal subtransactions is a core pillar of our **Safe Agency** promise: it ensures that late-stage constraint failures (e.g., foreign key violations) only roll back the agent's specific attempt, leaving your session intact and allowing the agent to self-correct.

---

## `fractal_schema_context(table_names, query_hint)`

Builds the plain-text schema description used as the LLM's context. You can call this directly to audit exactly what the model sees.

```sql
SELECT fractal_schema_context(ARRAY['orders', 'customers']);
-- Table: public.customers
--   Columns: id integer PK, name text NOT NULL
-- Table: public.orders
--   Columns: id integer PK, customer_id integer NOT NULL, total_cents integer NOT NULL
--   Foreign keys: public.orders: FOREIGN KEY (customer_id) REFERENCES customers(id)
```

**Sovereignty Note**: If `table_names` is omitted, auto-discovery pulls every table readable by the calling role. If your schema contains sensitive metadata (e.g., a `payroll_secrets` table), use explicit `table_names` to keep that metadata inside your database boundary.

---

## Configuration & Security

### GUC Settings
These settings in `postgresql.conf` control the pipeline's behavior:

| GUC | Default | Notes |
| --- | --- | --- |
| `fractalsql.text_to_sql_max_attempts` | `2` | Shared budget across all rejection types. |
| `fractalsql.text_to_sql_allowed_statements` | `'select'` | `'select_insert_update'` permits writes; see **Secure it** below. |
| `fractalsql.text_to_sql_use_review` | `off` | Enable for higher accuracy at the cost of latency. |

### Secure it: Authorization vs. Correctness
**Crucial**: This pipeline is a *correctness* aid, not an *authorization* mechanism. The allowlist and EXPLAIN checks catch shape and schema problems, but they do not replace PostgreSQL grants.

To secure your Text-to-SQL implementation:
1. **Dedicated Role**: Create a restricted role (e.g., `fsql_t2s_role`) with `SELECT` grants only on the tables necessary for the use case.
2. **Execute as Role**: Run the *returned* SQL under this restricted role, not as a superuser.
3. **RLS**: Enable Row-Level Security to ensure the agent only sees rows the calling user is permitted to access.

---

## Validation & Testing

FractalSQL includes a comprehensive test suite to ensure the pipeline's robustness:

- **Fuzz Testing**: `tests/test_text_to_sql_fuzz.py` forces malicious/malformed responses (stacked statements, DDL, prompt injections) to verify the allowlist.
- **Shadow Testing**: `tests/test_text_to_sql_shadow.py` runs complex questions against real models and diffs the results against ground-truth SQL.
- **Memory Safety**: `tests/test_text_to_sql_evil_nonterminating.py` ensures the C-bridge is length-bounded and immune to buffer over-reads.

---

## Known Limitations

- **Distinct-Value Sampling**: The current version does not sample enum-like columns (e.g., `'Completed'` vs `'completed'`) to help the LLM with value normalization.
- **Table Ranking**: For extremely large schemas, `fractal_search`-based table subset ranking is planned to replace the current linear auto-discovery.
- **Schema Caps**: `fractal_schema_context()` caps explicit `table_names[]` at 512 entries to bound SPI overhead.
