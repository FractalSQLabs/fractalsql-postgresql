# fractalsql-postgresql-mcp

The FractalSQL **MCP plugin for PostgreSQL**: a standalone C++17 binary that
exposes the extension's SQL surface to MCP clients (Model Context Protocol) —
one tool per SQL function, with every argument passed through libpq's
`$n`-placeholder binding (never string-built SQL), structured
`error_class`-tagged errors, and the engine's own row-locator (`ctid`) and
vector semantics carried through unmodified.

For the client-facing guide (configs for Claude Desktop, Cursor, Windsurf,
Claude Code and framework adapters such as LangChain, LlamaIndex and CrewAI,
worked examples, troubleshooting) see [`docs/mcp-plugin.md`](../docs/mcp-plugin.md).

## What it is

- `fractalsql-postgresql-mcp` — one binary, two transports: newline-delimited
  JSON-RPC over **stdio** (the desktop-client shape) by default, or
  **streamable HTTP** (`--http PORT` / `FSQL_MCP_TRANSPORT=http`) with
  Bearer-token auth and direct TLS (`--https` / `--tls-cert` / `--tls-key`).
- **82 tools** across seven categories (discovery 14, cognition 4,
  agency 22, analytics 23, enterprise 10, vectorizer 5, admin 4), each named
  after the SQL function it calls and whose `inputSchema` mirrors the
  function's documented signature 1:1.
- 5 resources (`fractalsql://schema|config|ledger/{kind}|vectorizer/status|agents`)
  and 11 task prompts (`incident_triage`, `portfolio_rebalance`, …).
- Postgres 14+, with **both** `CREATE EXTENSION fractalsql` and
  `CREATE EXTENSION fractalsql_agents` already installed — this server is a
  *caller*, never an installer: it runs zero DDL and never touches the
  enterprise GUCs.

## Build

Linux/macOS (pkg-config libpq + OpenSSL, g++/clang):

```sh
cd mcp
make
./fractalsql-postgresql-mcp --version
```

Windows (MSVC `cl /std:c++17 /EHsc`, linked against the PostgreSQL install's
`libpq.lib` and a vcpkg `x64-windows-static` OpenSSL — same dependency story
as the extension build itself): activate the VS dev env
(`scripts\windows\Import-VsDevEnv.ps1`) and either
`mcp\scripts\windows\build.bat`, or `build_test.ps1 -Gate 33`, which performs
the same compile+link and exercises the result end-to-end against a throwaway
cluster.

## Run

```sh
export PGHOST=localhost PGPORT=5432 PGUSER=app PGDATABASE=mydb
# libpq also honors PGPASSWORD/PGSERVICEFILE/.pgpass — or set FSQL_MCP_PG_CONN_URI
./fractalsql-postgresql-mcp                    # stdio, for an MCP client config
./fractalsql-postgresql-mcp --http 8765        # HTTP; set FSQL_MCP_AUTH_TOKEN
./fractalsql-postgresql-mcp --https 8765 --tls-cert cert.pem --tls-key key.pem
                                               # direct TLS (env form: FSQL_MCP_HTTPS +
                                               # FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE);
                                               # a missing/unparseable/mismatched pair is a
                                               # nonzero-exit config error, never a fallback
./fractalsql-postgresql-mcp --list-tools       # print the catalog (name, category), no connection
```

Transport note: the HTTP transport is **streamable HTTP** (POST to the MCP
path, JSON responses, `Mcp-Session-Id` per session). The MCP "HTTP + SSE"
transport of the 2024-11-05 protocol era is deliberately not implemented —
the 2025-03-26+ protocol revisions this server speaks (`initialize` echoes
`2024-11-05`/`2025-03-26`/`2025-06-18`) replaced SSE with streamable HTTP.
What the spec's per-SSE-session isolation requirement becomes here is
implemented unchanged: every `Mcp-Session-Id` gets its own dedicated
database connection for its lifetime, never shared while its session is
open.

Claude Desktop / Cursor / Windsurf / Claude Code style config (any MCP client that takes an `mcpServers` block):

```json
{ "mcpServers": { "fractalsql": {
    "command": "/path/to/mcp/fractalsql-postgresql-mcp",
    "env": { "PGHOST": "localhost", "PGDATABASE": "mydb", "PGUSER": "app" } } } }
```

## Least privilege

The server enforces nothing beyond whatever role its connection opened as.
Create a dedicated role instead of pointing it at a superuser:

```sql
CREATE ROLE fractalsql_mcp LOGIN PASSWORD '...';
GRANT USAGE ON SCHEMA public TO fractalsql_mcp;
GRANT SELECT, INSERT, UPDATE ON my_tables TO fractalsql_mcp;   -- scope tightly
-- cross-tenant isolation is RLS' job: enable row security on tenant tables
```

## Safety posture

- Every argument reaches SQL as a `$n` bound parameter with an explicit cast.
  The single documented exception is the admin tool's `ALTER SYSTEM SET
  fractalsql.<guc>` (utility statements reject `$n`): the GUC name comes from
  a fixed allowlist and the value is quote-doubled — never interpolated input.
- Structured errors (`error_class`: schema / engine / connectivity / server /
  cancelled); `server` class never leaks internals; engine errors surface
  verbatim. No retries are ever performed by the transport.
- Concurrency caps (cheap 50 / expensive 5 / per-client 2 — env-overridable),
  row ceilings (default 100, hard cap 1000), read-only kill switch
  (`FSQL_MCP_READ_ONLY=true` refuses every `destructiveHint` tool — the
  seven destructive ones, not every write; the real no-write boundary is
  the connection's role + RLS), `$ /cancel`
  → `PQcancel` with late-result discard.
- Untrusted tool output (reasoning answers, agent rows) is passed to clients
  labeled as DATA, never auto-executed; `auto_execute` defaults off everywhere.
- Supply chain: one vendored third-party header (`vendor/json.hpp`,
  nlohmann v3.11.3 pinned); the committed `.mcp-schema-lock` (SHA-256 over
  the canonical tool projection), `.mcp-safety-annotations-lock` (human-
  diffable per-tool safety hints — mismatches hard-fail startup), and
  `manifest.json` are all regenerated with `--write-schema-lock`,
  `--write-safety-annotations-lock`, `--write-manifest`.
  The server reads the two locks from **its own directory** (the directory
  the executable lives in — `FSQL_MCP_LOCK_DIR`, `FSQL_MCP_SCHEMA_LOCK` and
  `FSQL_MCP_SAFETY_LOCK` override the location), so every package ships them
  next to the binary: `/usr/lib/postgresql/<ver>/lib/` (deb),
  `/usr/pgsql-<ver>/lib/` (rpm), `mcp/` (macOS tarball, Windows MSI). An
  absent lock is a pass (dev-tree friendly) — a packaged install has one,
  so the safety-annotation pin is enforced there (a mismatch exits 3).

## Development

```sh
make && ./fractalsql-postgresql-mcp --write-schema-lock      # after tool-table edits
./build_test.sh -G 33      # full gate: rebuild + stdio smoke vs a throwaway cluster
python3 test/smoke.py      # standalone assert suite (FSQL_MCP_EXE=/path/to/binary)
```