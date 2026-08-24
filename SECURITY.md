<p align="center">
  <img src="FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Security Policy

This repository follows the FractalSQLabs organization-wide security
policy. The full policy — reporting channels, supported versions,
disclosure timeline, scope, and artifact-integrity verification — is
maintained at:

> <https://github.com/FractalSQLabs/.github/blob/main/SECURITY.md>

## Sovereign Safety Model

FractalSQL is built on the principle of **Sovereign Data Intelligence**: the belief that data is a liability when it leaves your control. To enable autonomous agency without compromising database integrity, the engine implements a tiered safety model.

### 1. Safe Agency Guardrails
To prevent "hallucination-driven" corruption or unauthorized access, the Agent Tier employs three primary barriers:
- **The Subtransactional Barrier**: Agents run generated SQL inside internal subtransactions. If a constraint is violated or an error occurs, only the agent's attempt is rolled back. The main session remains intact, allowing the agent to reflect on the error and retry safely.
- **The Deterministic Allowlist**: A strict GUC-controlled filter (`fractalsql.text_to_sql_allowed_statements`) prevents the generation of destructive SQL (e.g., `DROP TABLE` or `GRANT`) regardless of LLM suggestions.
- **The Visibility Boundary**: Agents are subject to standard PostgreSQL Role-Based Access Control (RBAC) and Row-Level Security (RLS). An agent cannot "see" or "touch" any data that the calling role is not explicitly granted access to.

### 2. Data Egress Control
FractalSQL minimizes the "sovereignty gap" by allowing intelligence to happen *beside* the data:
- **Local-First Reasoning**: Native support for local/VPC model endpoints (e.g., Ollama) ensures that data never leaves your network perimeter.
- **Metadata Scoping**: Tools like `fractal_schema_context()` allow you to explicitly narrow the schema metadata sent to cloud providers, ensuring sensitive identifiers stay internal.

---

## Quick reference


**To report a vulnerability:**

1. **Preferred: GitHub private vulnerability reporting.** Go to this
   repository's **Security** tab → **"Report a vulnerability"**. The
   advisory is private and visible only to maintainers.
2. **Email:** `security@fractalsqlabs.com`

**Do not open public GitHub issues** for security-sensitive reports.

We acknowledge valid reports within **3 business days** and follow a
**90-day coordinated disclosure window**. See the org-wide policy for
the full timeline, scope (in/out), and what we commit to in return.

## Supported versions

| Version | Supported |
| ------- | :-------: |
| 1.x     | ✅        |
| < 1.0   | ❌        |

## Artifact integrity

Every release artifact ships with a Syft SBOM, a Sigstore signature,
and a GitHub build-provenance attestation. Verification commands and
the full third-party component ledger are in the org-wide policy.
