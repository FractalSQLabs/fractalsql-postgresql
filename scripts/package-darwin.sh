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
[ -n "${VERSION}" ] || { echo "could not determine VERSION (FSQL_VERSION not found in src/fractalsql.c)" >&2; exit 1; }

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
[ -n "${PG_MAJOR}" ] \
    || { echo "could not parse PG major from '${PG_CONFIG} --version'" >&2; exit 1; }

# DLSUFFIX genuinely differs by PG major on Darwin -- confirmed on real
# CI hardware (2026-08): PostgreSQL itself changed its own default from
# .so to .dylib at a specific major-version boundary that lands INSIDE
# our supported range (PG14/15 still build .so; PG16-18 build .dylib,
# each confirmed directly from a real link command). Query the TARGET's
# own Makefile.global (next to its pg_config --pgxs) rather than
# guessing from uname -s, which only ever gets the newer majors right.
DLSUFFIX=""
PGXS_PATH="$("${PG_CONFIG}" --pgxs 2>/dev/null || true)"
if [ -n "${PGXS_PATH}" ]; then
    MAKEFILE_GLOBAL="$(dirname "$(dirname "${PGXS_PATH}")")/Makefile.global"
    DLSUFFIX="$(sed -n 's/^DLSUFFIX[[:space:]]*=[[:space:]]*//p' "${MAKEFILE_GLOBAL}" 2>/dev/null | head -1)"
fi
[ -n "${DLSUFFIX}" ] || DLSUFFIX=".dylib"

FSQL_PLATFORM="darwin-${ARCH}"
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
CORE_A="include/${FSQL_PLATFORM}/libfractalsql-community-sovereign-c.a"
for f in "${REASONING_SO}" "${CORE_A}" LICENSE THIRD-PARTY-NOTICES.md \
         fractalsql.control sql/fractalsql--1.0.sql \
         fractalsql_agents/fractalsql_agents.control \
         fractalsql_agents/sql/fractalsql_agents--1.0.sql \
         scripts/macos/install.sh; do
    [ -f "${f}" ] \
        || { echo "missing ${f} — re-run the vendored-artifact deploy step" >&2; exit 1; }
done

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
if [ "${ARCH}" != "$(uname -m)" ]; then
    XC_LDFLAGS="-Wl,-undefined,dynamic_lookup"
fi

make clean >/dev/null 2>&1 || true
make FSQL_PLATFORM="${FSQL_PLATFORM}" COPT="-arch ${ARCH}" PG_CONFIG="${PG_CONFIG}" \
    FSQL_DARWIN_XC_LDFLAGS="${XC_LDFLAGS}"

test -f "fractalsql${DLSUFFIX}" || { echo "build did not produce fractalsql${DLSUFFIX}" >&2; exit 1; }

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

TARBALL="${DIST}/${PKG}.tar.gz"
tar -C "${WORK}" -czf "${TARBALL}" "${PKG}"

echo "== wrote ${TARBALL} =="
ls -l "${TARBALL}"
