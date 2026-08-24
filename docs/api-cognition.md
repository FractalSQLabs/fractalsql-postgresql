<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the Virtual File System (VFS) surface that connects the SFS core to Large Language Models (LLMs) and embedding providers.

---

## `fractal_reason`
**LLM Dispatch**

Dispatches a natural language query and a context payload to the configured LLM reasoning plugin.

### Signature
```sql
fractal_reason(
    query   text,
    context text DEFAULT '{}'
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `query` | `text` | (Required) | The question or instruction for the LLM. |
| `context` | `text` | `'{}'` | A JSON payload containing search results, schema, or other data. |

---

## `fractal_embed`
**Semantic Vector Generation**

Generates a high-dimensional vector from text using the configured embedding model.

### Signature
```sql
fractal_embed(
    input text
) RETURNS float8[]
```

### Requirements
Requires `fractalsql.http_embed_url` and `fractalsql.http_embed_model` to be configured.

---

## `fractal_text_to_sql`
**Safe SQL Generation**

Turns a natural-language question into a single, EXPLAIN-validated SQL statement.

### Signature
```sql
fractal_text_to_sql(
    question    text,
    table_names text[] DEFAULT NULL
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `question` | `text` | (Required) | The natural language question. |
| `table_names` | `text[]` | `NULL` | Optional list of tables to include in the prompt. If `NULL`, auto-discovers all readable tables. |

### Safety Pipeline
1. **Parse-Check**: Rejects multi-statement or DDL/utility candidates.
2. **Allowlist**: Checks against `fractalsql.text_to_sql_allowed_statements`.
3. **EXPLAIN-Check**: Mechanical planning check inside a subtransaction.

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema for use as LLM context.

### Signature
```sql
fractal_schema_context(
    table_names text[] DEFAULT NULL,
    query_hint  text   DEFAULT NULL
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `table_names` | `text[]` | `NULL` | Tables to describe. If `NULL`, describes all readable tables in the `search_path`. |
| `query_hint` | `text` | `NULL` | Accepted for forward compatibility with future ranking passes. |
