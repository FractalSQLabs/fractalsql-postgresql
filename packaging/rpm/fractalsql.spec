%global         pg_major %{?pg_major}%{!?pg_major:16}
# The vendored reasoning plugin ships from the caller-staged arch tree
# (include/linux-<fsql_arch>/fractalsql-reasoning-http.so): pass
# --define "fsql_arch aarch64" for an arm64 build (default x86_64).
%global         fsql_arch    %{?fsql_arch}%{!?fsql_arch:x86_64}

%global         pg_libdir     %{_libdir}/pgsql
%global         pg_extensiondir %{_datadir}/pgsql/extension
%global         mcpdocdir     %{_docdir}/postgresql-%{pg_major}-fractalsql/mcp

# Caller passes --define "pg_major 16|17|18" to pick the matching
# prebuilt .so from dist/${arch}/fractalsql_pg${pg_major}.so.

Name:           postgresql-%{pg_major}-fractalsql
Version:        2.0.22
Release:        1%{?dist}
Summary:        Stochastic Fractal Search extension for PostgreSQL %{pg_major}

License:        Apache-2.0
URL:            https://github.com/FractalSQLabs/fractalsql-postgresql
Source0:        %{name}-%{version}.tar.gz

# gcc-c++ + openssl-devel build the bundled MCP server (mcp/Makefile):
# plain C++17 against pkg-config libpq + -lssl -lcrypto, no per-arch
# vendored core archive involved (unlike fractalsql.so itself).
BuildRequires:  gcc, gcc-c++, make, postgresql%{pg_major}-devel, openssl-devel, pkgconfig
Requires:       postgresql%{pg_major}-server
Requires:       openssl-libs
# Soname capability (provided by both libcurl and libcurl-minimal) so we
# don't conflict with the libcurl-minimal that ships in RHEL/Rocky base.
Requires:       libcurl.so.4()(64bit)

%description
FractalSQL registers a pure-C Stochastic Fractal Search optimizer
(fractal_search()/fractal_search_explore()) inside PostgreSQL %{pg_major}
plus the full Discovery/Cognition/Text-to-SQL/Agency/Analytics/Enterprise
tier surface (see docs/features.md), including the dependent
fractalsql_agents extension's sixteen installable agents. Optional LLM
reasoning plugin (fractalsql-reasoning-http, which links libcurl). Also
ships the fractalsql-postgresql-mcp MCP (Model Context Protocol)
JSON-RPC server (in the PG libdir, alongside the extension .so)
exposing the same surface as one-tool-per-function for external agent
clients over stdio or an optional TLS / Bearer-token-authenticated HTTP
transport -- see /usr/share/doc/postgresql-%{pg_major}-fractalsql/mcp/README.md.

%prep
%setup -q

%build
# The per-PG-version .so is produced out-of-band by build.sh on a Docker
# builder; this spec just stages it into the RPM.
test -f dist/fractalsql_pg%{pg_major}.so
# The MCP server builds right here: it isn't cross-built per arch
# (no vendored core archive involved), just plain C++17 + this host's
# libpq/OpenSSL (same as package.sh's packaging-host build).
make -C mcp

%install
install -Dm0755 dist/fractalsql_pg%{pg_major}.so \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/fractalsql.so
# The standalone reasoning plugin ships alongside the extension (the fpm
# path in package.sh stages it the same way — reasoning-setup.md points
# fractalsql.reasoning_plugin at this path; it links libcurl, hence the
# Requires below).
install -Dm0755 include/linux-%{fsql_arch}/fractalsql-reasoning-http.so \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/fractalsql-reasoning-http.so
install -Dm0644 include/linux-%{fsql_arch}/fractalsql-reasoning-http.so.sig \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/fractalsql-reasoning-http.so.sig
install -Dm0644 fractalsql.control \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql.control
install -Dm0644 sql/fractalsql--1.0.sql \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql--1.0.sql
# Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
# no .so). Ships the .control + install SQL alongside the base extension so
# `CREATE EXTENSION fractalsql_agents` works once the base is loaded.
install -Dm0644 fractalsql_agents/fractalsql_agents.control \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents.control
install -Dm0644 fractalsql_agents/sql/fractalsql_agents--1.0.sql \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents--1.0.sql
# Bundled MCP server: the binary goes into the PG libdir like the
# extension .so, and the supply-chain pins go NEXT TO THAT BINARY — the
# server resolves its lock paths relative to the directory the executable
# lives in (main.cpp's selfDir(); FSQL_MCP_LOCK_DIR / FSQL_MCP_SCHEMA_LOCK
# / FSQL_MCP_SAFETY_LOCK override it) and treats an ABSENT lock as a pass
# (dev-mode friendly). Shipping the pins in the doc dir instead meant a
# packaged install never read them and the safety-annotation pin was never
# enforced. The doc dir keeps the client guide + the manifest.
install -Dm0755 mcp/fractalsql-postgresql-mcp \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/fractalsql-postgresql-mcp
install -Dm0644 mcp/.mcp-schema-lock \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/.mcp-schema-lock
install -Dm0644 mcp/.mcp-safety-annotations-lock \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/.mcp-safety-annotations-lock
install -Dm0644 mcp/README.md \
    %{buildroot}%{mcpdocdir}/README.md
install -Dm0644 mcp/manifest.json \
    %{buildroot}%{mcpdocdir}/manifest.json

%files
%license LICENSE
%license THIRD-PARTY-NOTICES.md
/usr/pgsql-%{pg_major}/lib/fractalsql.so
/usr/pgsql-%{pg_major}/lib/fractalsql-reasoning-http.so
/usr/pgsql-%{pg_major}/lib/fractalsql-reasoning-http.so.sig
/usr/pgsql-%{pg_major}/lib/fractalsql-postgresql-mcp
/usr/pgsql-%{pg_major}/lib/.mcp-schema-lock
/usr/pgsql-%{pg_major}/lib/.mcp-safety-annotations-lock
/usr/pgsql-%{pg_major}/share/extension/fractalsql.control
/usr/pgsql-%{pg_major}/share/extension/fractalsql--1.0.sql
/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents.control
/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents--1.0.sql
%{mcpdocdir}/README.md
%{mcpdocdir}/manifest.json

%changelog
* Fri Nov 13 2026 FractalSQLabs - 2.0.22-1
- the configuration functions are now fractal_config_set() and
  fractal_config_get(). The MCP tools follow: fractal_version,
  fractal_config_set, fractal_config_get, fractal_configure_reasoning.
- fractal_tda_persistence_diagram() requires max_dim and
  max_thresh (no defaults). The MCP tool takes max_dim (default 0) and a
  required max_thresh, and is marked EXPERIMENTAL.
- MCP: parameters renamed and tidied to the shared standard: window
  (spectrogram_entropy), vector (state fingerprint and both quantize
  tools), n_bits optional (default 128), integer seeds, optional
  parameters published as plain types. trajectory_predict is read-only
  and idempotent.
- MCP: FSQL_MCP_DUMP_PROJECTION writes the canonical projection the
  schema hash is taken over, for diagnosing a lock mismatch.
- Tests updateed for build_test.sh --profile runs valgrind memcheck over the
  extension (a postmaster under valgrind, the demo kits) and the MCP
  server; a unit test of the audit redaction (hash and truncate modes);
  fuzz-corpus replay for the coverage run; a coverage floor.
* Sat Nov 07 2026 FractalSQLabs - 2.0.21-1
- Safety update the reasoning plugin is now signed. It ships with a detached
  Ed25519 signature (.sig) beside it and loads only when that file is
  present and valid; a missing signature is refused unless
  FSQL_REASONING_REQUIRE_SIGNATURE=0 is set in the server environment,
  and a wrong one is always refused. The enterprise library signature
  requirement is unchanged.
- MCP server: stricter defaults and new limits for authentication,
  origins, locks and sessions; see docs/mcp-plugin.md.
- Audit: the text of an agent's question can be hashed or truncated
  before it is written to an audit entry (FSQL_AUDIT_REDACT).
- Packaging the plugin's .sig is installed beside the plugin, and the
  Windows installer now includes the reasoning plugin.

* Tue Oct 20 2026 FractalSQLabs - 2.0.20-1
- Ships the MCP server binary in every package (fractalsql-postgresql-mcp,
  in the PG libdir alongside the extension .so), built on the packaging
  host by package.sh / this spec against pkg-config libpq + OpenSSL.
- TLS enabled on the MCP server HTTP transport (--https with
  --tls-cert/--tls-key or FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE).
- MCP thread-safety hardening: atomic shutdown flag,
  async-signal-safe SIGHUP handling, leaked session state cleaned up.
- 82-tool MCP catalog: the four fractalsql_* config/admin tools added
  (tool surface + schema/safety-annotation locks regenerated).
- Demo one-pass runner and bench script injection guards.
- CI TLS pinning (--proto '=https' enforcement across install/CI
  download paths).
* Mon Oct 12 2026 FractalSQLabs - 2.0.19-1
- Update RHEL install-test CI baseurl to use dnf releasever.
- Update macOS build_test for quantize_int8 testing.
- Update sql_agent_savepoint test.
* Mon Oct 12 2026 FractalSQLabs - 2.0.18-1
- CI gates for vector ops, new analytics primitives, activation, 
  and sovereign-tier agent functions; fractal_agent_detect_loop
  STRICT fix; fractal_search_agent execution_time_ms Datum fix.
* Sun Sep 21 2026 FractalSQLabs - 2.0.17-1
- Description updated for the full Discovery/Cognition/Text-to-SQL/
  Agency/Analytics/Enterprise tier surface; Version was stale at 1.0.0.
* Sat Apr 18 2026 FractalSQLabs - 1.0.0-1
- Initial Factory-standardized release for PostgreSQL 16 / 17 / 18.
