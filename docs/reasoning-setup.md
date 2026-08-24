<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Sovereign Reasoning Setup Guide

The **Cognition Tier** is the intelligence layer of FractalSQL. It provides a high-performance Virtual File System (VFS) bridge that allows PostgreSQL to communicate with Large Language Models (LLMs) and embedding providers. 

By bringing reasoning directly into the database kernel, FractalSQL enables **Sovereign Data Intelligence**: the ability to synthesize, analyze, and reason over your data without the risk and latency of exporting it to external application middleware.

---

## 🧠 The Cognition Model

At its core, the Cognition tier provides the `fractal_reason(query, context)` primitive. Unlike traditional RAG, which relies on external orchestrators, FractalSQL performs the synthesis inside the backend:

1. **Context Assembly**: You use ordinary SQL (subqueries, `jsonb_agg`, or `fractal_search_explore`) to gather the precise data needed.
2. **Sovereign Dispatch**: The extension dispatches the query and context to your configured LLM via a dedicated C-bridge.
3. **In-Place Synthesis**: The response is returned directly into your query result, allowing you to combine reasoning with standard SQL filters, joins, and aggregations in a single statement.

---

## 🛠️ Prerequisites

To activate the Cognition tier, you need a reasoning plugin and a configured endpoint.

### 1. The Reasoning Plugin
The reasoning plugin (`fractalsql-reasoning-http.so` or `.dll`) is installed into your PostgreSQL `pkglibdir`. Installing the file does not activate the feature; you must explicitly point the server to the plugin path in `postgresql.conf`.

**Find your `pkglibdir`**:
Run `pg_config --pkglibdir`. Common paths include:
- **Debian/Ubuntu (PGDG)**: `/usr/lib/postgresql/<major>/lib/`
- **RHEL/Rocky (PGDG)**: `/usr/pgsql-<major>/lib/`
- **Windows (EDB default)**: `C:\Program Files\PostgreSQL\<major>\lib\`

### 2. Technical Requirements
- **Extension Version**: `fractalsql-postgresql` 2.0.0+ (`SELECT fractal_version();`).
- **Plugin Version**: `fractalsql-reasoning-http` v1.2.1+ (required for Response Modes and System Tags).
- **Host Dependencies**: `libcurl` 7.75.0+ (required for AWS SigV4 auth).
- **Endpoint**: An LLM provider (Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, or any OpenAI-compatible API).

---

## 🚀 Setup Sequence

## Step 1: Activate the Plugin
Add the following to `postgresql.conf` or a `conf.d/` file:

```ini
# Example for PG 17 on Debian/Ubuntu
fractalsql.reasoning_plugin = '/usr/lib/postgresql/17/lib/fractalsql-reasoning-http.so'
```
Then reload the configuration: `SELECT pg_reload_conf();`. The plugin loads lazily upon the first reasoning call in a session.

## Step 2: Universal LLM Connectivity
One of the core strengths of the Sovereign tier is **Zero Provider Lock-in**. The reasoning VFS abstracts the provider's API, meaning your SQL calls to `fractal_reason()` remain identical whether you are using a local model for privacy or a cloud giant for scale.

Pick your provider and add the corresponding block to your configuration. Only one block should be active at a time.

## Ollama (Local or Private Network)
The gold standard for fully air-gapped, sovereign deployments. Traffic stays inside your network perimeter.

```ini
# Local Ollama
fractalsql.http_url             = 'http://127.0.0.1:11434/v1/chat/completions'
fractalsql.http_allow_plaintext = on
fractalsql.http_model           = 'gpt-oss:20b'
```
*Note: Run `ollama pull gpt-oss:20b` before connecting.*

## OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```ini
fractalsql.http_url   = 'https://api.openai.com/v1/chat/completions'
fractalsql.http_token = 'sk-...'
fractalsql.http_model = 'gpt-4o-mini'
```

## AWS Bedrock
Bedrock uses AWS SigV4 signing. The URL must point to the **OpenAI-compatible** surface.

```ini
# postgresql.conf (GUCs)
fractalsql.http_url   = 'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions'
fractalsql.http_model = 'amazon.nova-lite-v1:0'
```
**Critical**: Auth type and region are **Environment Variables only** (see Configuration Reference).

## Azure OpenAI
Azure requires a separate deployment for the chat model.

```ini
# postgresql.conf (GUCs)
fractalsql.http_url   = 'https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-01'
fractalsql.http_token = '<azure-api-key>'
fractalsql.http_model = 'gpt-4o'
```

## Google Vertex AI
Vertex AI exposes an OpenAI-compatible endpoint on the `openai/v1` path of your
project's region endpoint. Auth is a Google **service-account OAuth access
token** (a short-lived bearer), supplied via `http_token` exactly like an API
key — no SigV4-style signing is needed.

```ini
# postgresql.conf (GUCs)
fractalsql.http_url   = 'https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/chat/completions'
fractalsql.http_token = '<gcp-oauth-access-token>'
fractalsql.http_model = 'google/gemini-2.5-flash'
```

**Generating the token**: the `http_token` must be a valid Google OAuth access
token for a service account with the Vertex AI User role. The canonical way is
a service-account JSON key plus the gcloud CLI:

```sh
gcloud auth activate-service-account --key-file=sa-key.json
gcloud auth print-access-token    # paste the output into http_token
```

The token is short-lived (~1 hour). For a long-running install, refresh it on a
schedule (e.g. `pg_cron` or a sidecar that re-runs `print-access-token` and
`ALTER SYSTEM SET fractalsql.http_token = '...'`). The `fractalsql.http_token`
value is read on every reasoning call, so a reload (`pg_reload_conf()`) is not
strictly required after rotating it — but `ALTER SYSTEM` still needs a reload
to persist, and the env-var form (`FSQL_REASONING_HTTP_TOKEN`) is read once at
plugin load, so prefer the GUC form for rotating tokens.

---

## ⚖️ Hardware & Performance (Local Reasoning)

For users deploying Ollama locally, hardware affects "cold-load" latency.

| Resource | Recommendation | Notes |
| --- | --- | --- |
| **GPU VRAM** | 8GB $\rightarrow$ 16GB | 8GB runs Phi-4/Gemma4 (Q4); 16GB runs GPT-OSS 20B. |
| **System RAM** | 16GB+ | Covers model, OS, and PostgreSQL overhead. |
| **CPU** | AVX2 Support | Essential for acceptable CPU-side inference (Post-2016). |

### Handling Constrained Hardware
Local models can take up to 300s to cold-load into memory. To prevent `curl` from aborting the request, raise the timeout and low-speed windows in the **PostgreSQL process environment**:

```sh
export FSQL_REASONING_HTTP_TIMEOUT_MS=330000
export FSQL_REASONING_HTTP_LOW_SPEED_SECS=300
```
*Note: These are not GUCs. On Linux, add them to the cluster's `environment` file and restart the server.*

---

## 🛠️ Advanced Configuration

### Response Modes (v1.2.1+)
Shape how the plugin post-processes the LLM response via environment variables:
- `text` (default): Raw content.
- `code`: Forces a single fenced code block and extracts it.
- `json`: Forces a fenced JSON block and validates structural integrity.

### Target-System Hints
Set `FSQL_REASONING_HTTP_SYSTEM_TAG=postgresql18` to hint to the model that it should use syntax appropriate for your specific PG version.

---

## 🔒 Security & Governance

### The Sovereign Guardrail: Dedicated Roles
Never run reasoning queries as a superuser. Create a restricted role to bound what the LLM can see.

```sql
CREATE ROLE fsql_reasoning_role NOLOGIN;
GRANT CONNECT ON DATABASE mydb TO fsql_reasoning_role;
GRANT USAGE ON SCHEMA public TO fsql_reasoning_role;
GRANT SELECT (id, title, body) ON TABLE documents TO fsql_reasoning_role;
```

### Row-Level Security (RLS)
Enable RLS to ensure that the context subquery only returns rows the current session's user is permitted to see. This prevents "cross-tenant" data leakage to the LLM.

### Prompt Injection (OWASP LLM01)
FractalSQL is **secure by default**. The plugin prepends a baseline anti-injection instruction to every system message. To replace this, set `FSQL_REASONING_HTTP_SYSTEM_PROMPT`.

---

## 📋 Production Checklist

- [ ] **Plugin Path**: `fractalsql.reasoning_plugin` is absolute and readable by the `postgres` user.
- [ ] **Auth Model**: A dedicated `fsql_reasoning_role` is used with column-level `SELECT` grants.
- [ ] **Isolation**: RLS is enabled on all tenant-sensitive tables.
- [ ] **Egress Review**: Cloud endpoints' DPA/BAA have been reviewed for the specific data classification.
- [ ] **Environment**: `FSQL_REASONING_HTTP_AUTH_TYPE` is correctly exported to the process environment (not just `postgresql.conf`).
- [ ] **Output Safety**: LLM responses are treated as untrusted display text and never executed as SQL.
