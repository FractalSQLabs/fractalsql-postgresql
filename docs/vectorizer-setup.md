<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Vectorizer Setup Guide

The Vectorizer is the Cognition tier's automation engine. It enables **Sovereign Data Intelligence** by closing the loop between raw text and semantic embeddings—ensuring your data is always "search-ready" without requiring external middleware or complex ETL pipelines.

By automating the synchronization of embeddings directly within the PostgreSQL kernel, FractalSQL eliminates the "data shuffle" and ensures that your semantic index is a real-time reflection of your sovereign data.

---

## Prerequisites

To enable automated embeddings, the following sovereign-tier configuration is required:

1. **Reasoning Plugin**: `fractalsql.reasoning_plugin` must be set to a compiled `fractalsql-reasoning-*.so` (see [reasoning-setup.md](reasoning-setup.md)).
2. **Embeddings Endpoint**: `fractalsql.http_embed_url` must be set to your provider's **embeddings** endpoint. This is a distinct path from the chat endpoint (e.g., `/v1/embeddings` vs `/v1/chat/completions`).
3. **Embedding Model**: `fractalsql.http_embed_model` specifies the purpose-trained model. If left unset, the plugin defaults to `text-embedding-3-small`. **Important**: Never reuse a chat model for embeddings; they are mathematically distinct tasks.

**Connectivity Check**:
Confirm the embed path is active before creating a vectorizer:
```sql
SELECT fractal_embed('hello world');
--  {0.0023064255,-0.009327292,...}
```

---

## Quick Start: Automated Sync

### 1. Define your table
We recommend using the native `fractal_vector(n)` type instead of `float8[]` to enable **dimension-drift protection**, which prevents misconfigured models from corrupting your index.

```sql
CREATE TABLE docs (
    id        serial PRIMARY KEY,
    body      text NOT NULL,
    -- Use fractal_vector(n) where n is your model's dimension (e.g., 1536)
    embedding fractal_vector(1536) 
);

INSERT INTO docs (body) VALUES ('first doc'), ('second doc');
```

### 2. Create the Vectorizer
This installs an `AFTER INSERT OR UPDATE` trigger and immediately queues existing rows missing an embedding.

```sql
SELECT fractal_vectorizer_create('docs', 'body', 'embedding');
```

### 3. Process the Queue
Since FractalSQL respects your resource boundaries, it does not run a background worker. You trigger the embedding process on your own schedule (e.g., via `pg_cron` or a system task).

```sql
SELECT fractal_vectorizer_process_queue();
-- returns the number of rows processed (done + failed)
```

### 4. Monitor Progress
```sql
SELECT * FROM fractal_vectorizer_status;
-- View pending/processing/done/failed counts and recent errors
```

---

## Storage: `float8[]` vs `fractal_vector(n)`

FractalSQL stores and searches embeddings in one of two column types:

- **`float8[]`** — the plain PostgreSQL array. Universally portable, but the
  linear scan must `deconstruct_array` every row to unpack the doubles, and the
  dimension is *unchecked*: a `float8[]` column happily accepts a 384-dim vector
  one day and a 1536-dim vector the next, silently corrupting your index.
- **`fractal_vector(n)`** — the native type. `n` is a **typmod** (e.g.
  `fractal_vector(768)`), so PostgreSQL **rejects** any vector whose length is
  not exactly `n` at insert time — dimension-drift protection that prevents a
  misconfigured or swapped embedding model from writing wrong-width rows. It is
  also a varlena type read directly off the tuple, so the linear scan skips the
  array-unpack step: a measured **~1.3×–1.7× speedup** over `float8[]`.

Prefer `fractal_vector(n)` whenever the embedding width is fixed by your model
(which it almost always is — `768` for `nomic-embed-text`, `1536` for
`text-embedding-3-small`, `3072` for `text-embedding-3-large`). Use `float8[]`
only when you genuinely need to store variable-width vectors in one column.

### Operators & helpers
The native type carries its own distance operators and vector arithmetic, so a
query can stay entirely in `fractal_vector` without round-tripping through
`float8[]`:

| Operator / function | Meaning |
| --- | --- |
| `a <-> b` (`fractal_vector_l2_distance`) | L2 (Euclidean) distance |
| `a <=> b` (`fractal_vector_cosine_distance`) | Cosine distance |
| `a <#> b` (`fractal_vector_negative_inner_product`) | Negative inner product (for max-inner-product ranking) |
| `fractal_vector_l2_squared(a, b)` | Squared L2 distance (no `sqrt`, cheaper for ordering) |
| `fractal_vector_cosine_similarity(a, b)` | Cosine *similarity* (1 − `<=>`) |
| `fractal_vector_norm(a)` / `fractal_vector_normalize(a)` | L2 norm / unit vector |
| `a + b`, `a - b`, `a * s` | Element-wise add / subtract / scalar-multiply |

### Casts
The bidirectional cast lets you move between the two representations when you
need array-only tooling (e.g. `unnest`, PL/pgSQL array aggregates):

```sql
-- float8[] -> fractal_vector (also implicit on insert into a fractal_vector col)
SELECT '[1,0,0]'::float8[]::fractal_vector;
-- fractal_vector -> float8[] (via fractal_vector_to_float8_array)
SELECT embedding::float8[] FROM docs LIMIT 1;
-- dimension of a stored vector
SELECT fractal_vector_dims(embedding) FROM docs LIMIT 1;
```

Inserting a wrong-width vector into a `fractal_vector(n)` column raises a
typmod `ERROR` rather than silently storing garbage — see the dimension-mismatch
assertion in `demo/demo-fractal-vector.sql` (Section 3), which is a deliberate
regression test of that hard-fail. `demo/demo-fractal-vector.sql` exercises the
full operator/helper surface above end to end.

---

## Endpoint Providers

The Vectorizer leverages the same auth-bridge as the Cognition tier's reasoning endpoint. Credentials and region settings are shared; only the URL and model change.

### Ollama (Local or Private Network)
Ideal for fully air-gapped deployments where data never leaves your VPC.

```ini
# chat / text-to-sql
fractalsql.http_url         = 'http://127.0.0.1:11434/v1/chat/completions'
fractalsql.http_model       = 'gpt-oss:20b'
fractalsql.http_allow_plaintext = on

# embeddings
fractalsql.http_embed_url   = 'http://127.0.0.1:11434/v1/embeddings'
fractalsql.http_embed_model = 'nomic-embed-text'
```
*Note: You must run `ollama pull nomic-embed-text` separately.*

### OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```ini
fractalsql.http_url         = 'https://api.openai.com/v1/chat/completions'
fractalsql.http_token       = 'sk-...'
fractalsql.http_model       = 'gpt-4o-mini'

fractalsql.http_embed_url   = 'https://api.openai.com/v1/embeddings'
fractalsql.http_embed_model = 'text-embedding-3-small'
```

### AWS Bedrock
Uses `AUTH_TYPE=aws-sigv4` via environment variables (see `docs/reasoning-setup.md`).

```ini
fractalsql.http_url         = 'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions'
fractalsql.http_embed_url   = 'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/embeddings'
fractalsql.http_embed_model = 'amazon.titan-embed-text-v2:0'
```

### Azure OpenAI
Requires a **separate deployment resource** for the embedding model.

```ini
fractalsql.http_url         = 'https://<resource>.openai.azure.com/openai/deployments/<chat-deploy>/chat/completions?api-version=2024-02-01'
fractalsql.http_embed_url   = 'https://<resource>.openai.azure.com/openai/deployments/<embed-deploy>/embeddings?api-version=2024-02-01'
```

### Google Vertex AI
Uses the same OAuth access token as the reasoning endpoint (see
`docs/reasoning-setup.md` — Vertex AI block), only the URL and model change.
Point the embed path at the `openapi/v1/embeddings` surface of your project's
region endpoint.

```ini
fractalsql.http_embed_url   = 'https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/embeddings'
fractalsql.http_embed_model = 'text-embedding-005'
```

---

## SQL API Reference

### `fractal_vectorizer_create(source_table, text_col, embedding_col, options DEFAULT '{}')`
Sets up the automation trigger and backfills the queue. Requires a single-column primary key.

### `fractal_vectorizer_pause(id)` / `fractal_vectorizer_resume(id)`
Toggles the `enabled` state. When paused, new writes are not queued and the processor skips existing pending rows.

### `fractal_vectorizer_process_queue(batch_size DEFAULT 100, stale_after DEFAULT '10 minutes')`
The engine that drives the synchronization. Safe for concurrent execution via `SKIP LOCKED`.

### Rate Capping
To prevent provider throttling, set `options.max_embeds_per_window` (int) and `options.rate_window_secs` (default 3600) during creation.
```sql
SELECT fractal_vectorizer_create(
    'documents', 'body', 'embedding',
    '{"max_embeds_per_window": 500, "rate_window_secs": 3600}'::jsonb
);
```

---

## Design & Safety

### The "No-Worker" Architecture
Unlike traditional extensions that spawn background workers—which can be unstable on Windows or conflict with managed cloud environments—FractalSQL uses a **pull-based queue**. You control exactly when and how often the embedder runs, making it compatible with every PostgreSQL deployment from a laptop to a massive cluster.

### Crash Safety & Authorization
- **Atomic Recovery**: `process_queue` runs in a single transaction. If the backend crashes mid-batch, all changes revert, and the rows remain `pending` for the next run.
- **Sovereign Authorization**: The process runs as `SECURITY INVOKER`. If the processing role lacks `SELECT` grants on the source table, the row is marked `failed` rather than leaking data.
- **Identifier Safety**: All table and column names are handled via `format()` quoting to prevent SQL injection.

---

## Known Constraints & Roadmap

- **Text Chunking**: Current version sends the full text of the column to the provider. For documents exceeding model context limits, we recommend pre-chunking into a separate "chunks" table.
- **Spend Caps**: Rate capping is based on call count, not dollar cost.
- **Automatic Retries**: Failed rows are not retried automatically; they must be reset to `pending` by the administrator.
- **Backfill Batching**: Initial backfill for very large tables (millions of rows) happens in a single transaction.

---

## When to use the Vectorizer

The Vectorizer is the right choice when you need **seamless semantic synchronization**. If your application requires that every single text update is immediately reflected in your vector index without managing external Python/Node.js workers, the Vectorizer closes that gap.

If you already have a robust external ETL pipeline, you can skip the Vectorizer and use `fractal_embed()` directly to populate your `fractal_vector` columns.
