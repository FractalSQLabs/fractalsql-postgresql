#!/bin/bash
#
# scripts/package-darwin.sh — macOS build + tarball packaging.
#
# macOS has no native package format for PostgreSQL extensions (no
# .deb/.rpm equivalent), so we ship a self-contained per-(major, arch)
# tarball with an install.sh — mirroring the Linux/Windows philosophy of
# one drop-in artifact per platform.
#
# Unlike the Linux build (docker/Dockerfile), the macOS extension builds
# natively with PGXS against a real mac PostgreSQL, linking the vendored
# darwin core archive (include/darwin-<arch>/). arm64 builds native;
# x86_64 cross-compiles via `-arch x86_64` on an Apple Silicon runner.
#
# Usage:
#   PG_CONFIG=/opt/homebrew/opt/postgresql@17/bin/pg_config ./scripts/package-darwin.sh
#   FSQL_DARWIN_ARCH=x86_64 PG_CONFIG=... ./scripts/package-darwin.sh   # cross
#
# The PG major is taken from `pg_config --version`; one run produces one
# tarball bound to one server ABI (PG_MODULE_MAGIC), same as the Linux
# per-major packages.

set -euo pipefail

# Same single-source-of-truth pattern as package.sh: derive from
# FSQL_VERSION in src/fractalsql.c rather than hardcoding a copy that
# can drift out of sync with what fractal_version() actually returns.
# FSQL_PKG_VERSION lets release.yml pin an exact release version (e.g.
# from the git tag) without touching this file.
VERSION="${FSQL_PKG_VERSION:-$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' src/fractalsql.c)}"
[[ -n "${VERSION}" ]] || { echo "could not determine VERSION (FSQL_VERSION not found in src/fractalsql.c)" >&2; exit 1; }

ARCH="${FSQL_DARWIN_ARCH:-$(uname -m)}"   # arm64 | x86_64
case "${ARCH}" in
    arm64|x86_64) ;;
    *) echo "unknown arch '${ARCH}' — expected arm64 or x86_64" >&2; exit 2 ;;
esac

PG_CONFIG="${PG_CONFIG:-pg_config}"
command -v "${PG_CONFIG}" >/dev/null 2>&1 \
    || { echo "pg_config not found ('${PG_CONFIG}')" >&2; exit 1; }

# "PostgreSQL 17.2" -> 17
PG_MAJOR="$("${PG_CONFIG}" --version | sed -E 's/^PostgreSQL[[:space:]]+([0-9]+).*/\1/')"
[[ -n "${PG_MAJOR}" ]] \
    || { echo "could not parse PG major from '${PG_CONFIG} --version'" >&2; exit 1; }

# DLSUFFIX genuinely differs by PG major on Darwin -- confirmed on real
# CI hardware (2026-08): PostgreSQL itself changed its own default from
# .so to .dylib at a specific major-version boundary that lands INSIDE
# our supported range (PG14/15 still build .so; PG16-18 build .dylib,
# each confirmed directly from a real link command). The value can come
# from Makefile.global's own default OR be overridden later by an
# `include .../Makefile.port` line INSIDE Makefile.global -- Makefile.port
# wins because it's included last, so parsing Makefile.global alone (a
# prior version of this script) silently missed the override and always
# fell back to the wrong guess. PGXS ships a `show_dl_suffix` target
# (Makefile.global: "Show the DLSUFFIX to build scripts (e.g. buildfarm)")
# for exactly this -- ask the same Makefile/PGXS chain the real build
# uses instead of re-deriving the logic ourselves.
DLSUFFIX="$(make PG_CONFIG="${PG_CONFIG}" show_dl_suffix 2>/dev/null | tail -1)"
[[ -n "${DLSUFFIX}" ]] || DLSUFFIX=".dylib"

FSQL_PLATFORM="darwin-${ARCH}"
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
CORE_A="include/${FSQL_PLATFORM}/libfractalsql-community-sovereign-c.a"
for f in "${REASONING_SO}" "${CORE_A}" LICENSE THIRD-PARTY-NOTICES.md \
         fractalsql.control sql/fractalsql--1.0.sql \
         fractalsql_agents/fractalsql_agents.control \
         fractalsql_agents/sql/fractalsql_agents--1.0.sql \
         scripts/macos/install.sh; do
    [[ -f "${f}" ]] \
        || { echo "missing ${f} — re-run the vendored-artifact deploy step" >&2; exit 1; }
done

# MCP server (fractalsql-postgresql-mcp) — built from source on this
# host, same as the Linux/Windows legs; plain C++17 via mcp/Makefile
# (pkg-config libpq + -lssl -lcrypto -lpthread). Homebrew's openssl@3
# is keg-only (never symlinked onto the default -I/-L search path), so
# resolve its prefix explicitly; skip gracefully (warning, not a hard
# failure) when it isn't installed.
#
# -mmacosx-version-min=13.3 overrides the caller's (release.yml's)
# MACOSX_DEPLOYMENT_TARGET=11.0, which the extension .dylib DOES need
# for broad compatibility: mcp/src/vectors.cpp's formatDouble() uses
# std::to_chars on a double for shortest-round-trip formatting, and
# Apple's libc++ marks that overload unavailable before macOS 13.3. The
# MCP server is a separate, optional binary with no compatibility
# promise tying it to the dylib's floor, so it gets its own newer
# minimum instead of raising the whole package's.
HAVE_MCP=0
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"
if [[ "${ARCH}" != "$(uname -m)" ]]; then
    # Homebrew's libpq and openssl@3 are host-arch only; an x86_64 MCP
    # linked on an arm64 runner fails with undefined OpenSSL/libpq symbols.
    echo "warning: cross build (${ARCH} on $(uname -m)) — skipping the MCP server (no ${ARCH} libpq/openssl)" >&2
elif [[ -z "${OPENSSL_PREFIX}" || ! -f "${OPENSSL_PREFIX}/include/openssl/evp.h" ]]; then
    echo "warning: Homebrew openssl@3 not found — skipping the MCP server (brew install openssl@3 to include it)" >&2
else
    # pkg-config must also see libpq.pc: a full-path PG_CONFIG means a
    # Homebrew/opt keg whose pkgconfig dir is likewise off the default
    # search path. A plain `pg_config` on PATH gets no override and
    # falls back to whatever else pkg-config resolves (or nothing).
    # Homebrew keeps libpq.pc under lib/ or lib/postgresql@<major>/pkgconfig,
    # depending on the formula revision, so search for it rather than assume.
    PGBIN_DIR="$(dirname "${PG_CONFIG}")"
    PGPREFIX=""
    PGPCDIR=""
    if [[ "${PGBIN_DIR}" != "." && -d "${PGBIN_DIR}/../lib" ]]; then
        PGPREFIX="$(cd "${PGBIN_DIR}/.." && pwd)"
        PGPC="$(find "${PGPREFIX}/lib/" -name libpq.pc -print -quit 2>/dev/null || true)"
        [[ -n "${PGPC}" ]] && PGPCDIR="$(dirname "${PGPC}")"
    fi
    PGINC="$("${PG_CONFIG}" --includedir 2>/dev/null || true)"
    export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig${PGPCDIR:+:${PGPCDIR}}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    echo "== building fractalsql-postgresql-mcp for darwin-${ARCH} ==" >&2
    CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -arch ${ARCH} -mmacosx-version-min=13.3 ${PGINC:+-I${PGINC}} -I${OPENSSL_PREFIX}/include -L${OPENSSL_PREFIX}/lib" \
        make -C mcp
    lipo -info mcp/fractalsql-postgresql-mcp | grep -q "${ARCH}" \
        || { echo "mcp binary is not ${ARCH}: $(lipo -info mcp/fractalsql-postgresql-mcp)" >&2; exit 1; }
    HAVE_MCP=1
fi

echo "== building fractalsql${DLSUFFIX} for PG ${PG_MAJOR} / darwin-${ARCH} (DLSUFFIX=${DLSUFFIX}) =="
# COPT is appended to both CFLAGS and LDFLAGS by PGXS, so -arch reaches the
# compile and the link. FSQL_PLATFORM overrides the Makefile's host-derived
# value so an x86_64 cross build on an arm64 runner still links the
# darwin-x86_64 vendored archive (not the host's darwin-arm64 one).
#
# Cross-compiling (ARCH != host arch): PGXS's own -bundle_loader
# $(pg_bindir)/postgres can't be used -- Homebrew only installs the
# native-arch Postgres binary, so ld64 silently ignores it on arch
# mismatch and then hard-errors on every backend symbol instead. See
# FSQL_DARWIN_XC_LDFLAGS's own comment in the Makefile for the fix.
# Empty (a no-op) for a native build.
XC_LDFLAGS=""
if [[ "${ARCH}" != "$(uname -m)" ]]; then
    XC_LDFLAGS="-Wl,-undefined,dynamic_lookup"
fi

# EDB's macOS installer bakes its own build machine's SDK path into
# pg_config --cflags, which can point at nothing on this machine and
# break header resolution entirely. Override it with whatever SDK is
# actually active here.
SDK_OVERRIDE=""
# `|| true`: grep exits 1 when there's no -isysroot (the normal case
# on Homebrew), which under pipefail + set -e would otherwise kill the
# script here with no error message.
BAKED_SDK="$("${PG_CONFIG}" --cflags 2>/dev/null | grep -oE -- '-isysroot [^ ]+' | awk '{print $2}' | head -1 || true)"
if [[ -n "${BAKED_SDK}" ]] && [[ ! -d "${BAKED_SDK}" ]]; then
    REAL_SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
    if [[ -n "${REAL_SDK}" ]]; then
        echo "note: pg_config's built-in -isysroot (${BAKED_SDK}) doesn't exist on this machine. Overriding with ${REAL_SDK}." >&2
        SDK_OVERRIDE=" -isysroot ${REAL_SDK}"
    else
        echo "warning: pg_config's built-in -isysroot (${BAKED_SDK}) doesn't exist and 'xcrun --show-sdk-path' found no replacement. The build below will likely fail." >&2
    fi
fi

# PG_CONFIG must be passed here too, or clean silently no-ops when
# pg_config isn't on PATH, letting stale .o's from another build
# survive into the link step.
make clean PG_CONFIG="${PG_CONFIG}" >/dev/null 2>&1 || true
make FSQL_PLATFORM="${FSQL_PLATFORM}" COPT="-arch ${ARCH}${SDK_OVERRIDE}" PG_CONFIG="${PG_CONFIG}" \
    FSQL_DARWIN_XC_LDFLAGS="${XC_LDFLAGS}"

[[ -f "fractalsql${DLSUFFIX}" ]] || { echo "build did not produce fractalsql${DLSUFFIX}" >&2; exit 1; }

PKG="fractalsql-postgresql-${VERSION}-pg${PG_MAJOR}-darwin-${ARCH}"
DIST="dist/packages"
WORK="$(mktemp -d)"
STAGE="${WORK}/${PKG}"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${STAGE}" "${DIST}"

install -m 0755 "fractalsql${DLSUFFIX}"    "${STAGE}/fractalsql${DLSUFFIX}"
install -m 0755 "${REASONING_SO}"       "${STAGE}/fractalsql-reasoning-http.so"
install -m 0644 fractalsql.control      "${STAGE}/fractalsql.control"
install -m 0644 sql/fractalsql--1.0.sql "${STAGE}/fractalsql--1.0.sql"
# Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
# no .so). Ships the .control + install SQL alongside the base extension so
# `CREATE EXTENSION fractalsql_agents` works once the base is loaded.
install -m 0644 fractalsql_agents/fractalsql_agents.control \
    "${STAGE}/fractalsql_agents.control"
install -m 0644 fractalsql_agents/sql/fractalsql_agents--1.0.sql \
    "${STAGE}/fractalsql_agents--1.0.sql"
install -m 0644 LICENSE                  "${STAGE}/LICENSE"
install -m 0644 THIRD-PARTY-NOTICES.md   "${STAGE}/THIRD-PARTY-NOTICES.md"
install -m 0755 scripts/macos/install.sh "${STAGE}/install.sh"
printf '%s\n' "${PG_MAJOR}" > "${STAGE}/PG_MAJOR"

if [[ "${HAVE_MCP}" = "1" ]]; then
    # BSD install (macOS) has no -D to create leading directories, unlike
    # the GNU install the Linux packaging script relies on — mirror the
    # sibling's mcp/ bundle shape (binary + client guide + locks).
    mkdir -p "${STAGE}/mcp"
    install -m 0755 mcp/fractalsql-postgresql-mcp    "${STAGE}/mcp/fractalsql-postgresql-mcp"
    install -m 0644 mcp/README.md                    "${STAGE}/mcp/README.md"
    install -m 0644 mcp/.mcp-schema-lock             "${STAGE}/mcp/.mcp-schema-lock"
    install -m 0644 mcp/.mcp-safety-annotations-lock "${STAGE}/mcp/.mcp-safety-annotations-lock"
    install -m 0644 mcp/manifest.json                "${STAGE}/mcp/manifest.json"
fi

cat > "${STAGE}/README.txt" <<EOF
FractalSQL for PostgreSQL ${PG_MAJOR} (Community) ${VERSION} — macOS ${ARCH}

Install:
  ./install.sh                              # uses pg_config on PATH
  PG_CONFIG=/path/pg_config ./install.sh    # or a specific server

This build is stamped for PostgreSQL ${PG_MAJOR}. Install it against a
PostgreSQL ${PG_MAJOR} server only — a different major will refuse to load
the extension (PG_MODULE_MAGIC mismatch). install.sh checks this for you.

Then enable it in a database:
  psql -c 'CREATE EXTENSION fractalsql;'
  psql -c 'CREATE EXTENSION fractalsql_agents;'
  psql -c 'SELECT fractal_edition(), fractal_version();'

Reasoning is opt-in. The plugin (fractalsql-reasoning-http.so) links the
system libcurl on macOS, so there is nothing extra to install — point
fractalsql.reasoning_plugin at it and configure an endpoint. See
docs/reasoning-setup.md.
EOF

if [[ "${HAVE_MCP}" = "1" ]]; then
cat >> "${STAGE}/README.txt" <<EOF

MCP server (mcp/fractalsql-postgresql-mcp):
  cd "${PKG}"
  xattr -d com.apple.quarantine mcp/fractalsql-postgresql-mcp   # unsigned release
  ./mcp/fractalsql-postgresql-mcp --list-tools                  # 82-tool catalog
  See mcp/README.md for usage.
EOF
fi

TARBALL="${DIST}/${PKG}.tar.gz"
tar -C "${WORK}" -czf "${TARBALL}" "${PKG}"

echo "== wrote ${TARBALL} =="
ls -l "${TARBALL}"
