#!/bin/bash
#
# fractalsql-postgresql packaging.
#
# Assumes ./build.sh ${ARCH} has already produced:
#   dist/${ARCH}/fractalsql_pg14.so
#   dist/${ARCH}/fractalsql_pg15.so
#   dist/${ARCH}/fractalsql_pg16.so
#   dist/${ARCH}/fractalsql_pg17.so
#   dist/${ARCH}/fractalsql_pg18.so
#
# Emits one .deb and one .rpm per (PG major, arch) pair into
# dist/packages/:
#   dist/packages/postgresql-14-fractalsql-amd64.deb
#   dist/packages/postgresql-14-fractalsql-amd64.rpm
#   dist/packages/postgresql-18-fractalsql-arm64.deb
#   ...
#
# Usage:
#   ./package.sh [amd64|arm64]     # default: amd64
#
# Modern profile only — fractalsql-postgresql is intentionally
# modern-only at this time (no legacy / glibc-2.28 channel). Operators
# on RHEL 8 / Ubuntu 20.04 / Debian 11 are not a supported target for
# the PG extension.

set -euo pipefail

# Single source of truth is FSQL_VERSION in src/fractalsql.c (what
# fractal_version() actually returns at runtime) — hardcoding a separate
# VERSION here drifted out of sync with it before (packages claimed
# 1.0.0 while the compiled-in extension reported 1.1.0). FSQL_PKG_VERSION
# lets release.yml pin an exact release version (e.g. from the git tag)
# without touching this file.
VERSION="${FSQL_PKG_VERSION:-$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' src/fractalsql.c)}"
[[ -n "${VERSION}" ]] || { echo "could not determine VERSION (FSQL_VERSION not found in src/fractalsql.c)" >&2; exit 1; }
ITERATION="1"
DIST_DIR="dist/packages"
mkdir -p "${DIST_DIR}"

# Absolute repo root, captured before any -C chdir'd fpm invocation.
# Used as the source side of the license-file mappings below so they
# resolve outside each per-package STAGE dir.
REPO_ROOT="$(pwd)"
for f in LICENSE THIRD-PARTY-NOTICES.md; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "missing ${REPO_ROOT}/${f} — refusing to package without it" >&2
        exit 1
    fi
done

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

case "${PKG_ARCH}" in
    amd64) RPM_ARCH="x86_64" ;;
    arm64) RPM_ARCH="aarch64" ;;
esac

# Map the package arch to the vendored-artifact platform dir so we
# stage the reasoning plugin built for the matching architecture.
case "${PKG_ARCH}" in
    amd64) FSQL_PLATFORM="linux-x86_64" ;;
    arm64) FSQL_PLATFORM="linux-aarch64" ;;
esac

SRC_DIR="dist/${PKG_ARCH}"

# The reasoning plugin (fractalsql-reasoning-http.so) is a standalone
# dlopen plugin, vendored — the same binary for every PG
# major, arch-specific. It ships alongside fractalsql.so so that setting
# fractalsql.reasoning_plugin to a path inside the PG pkglibdir Just Works
# after install. It links libcurl at runtime; the libcurl dependency is
# declared on both packages below.
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
if [[ ! -f "${REASONING_SO}" ]]; then
    echo "missing ${REASONING_SO} — re-run the vendored-artifact deploy step" >&2
    exit 1
fi

for PG_VER in 14 15 16 17 18; do
    SO="${SRC_DIR}/fractalsql_pg${PG_VER}.so"
    if [[ ! -f "${SO}" ]]; then
        echo "missing ${SO} — run ./build.sh ${PKG_ARCH} first" >&2
        exit 1
    fi

    PKG_NAME="postgresql-${PG_VER}-fractalsql"
    DEB_OUT="${DIST_DIR}/${PKG_NAME}-${PKG_ARCH}.deb"
    RPM_OUT="${DIST_DIR}/${PKG_NAME}-${PKG_ARCH}.rpm"

    # Build per-format staging roots. PostgreSQL extensions live under
    # fundamentally different trees on Debian (PG Community APT) vs
    # RHEL (PGDG yum), not just lib vs lib64. CREATE EXTENSION looks
    # in {pkglibdir, extension-dir}; if those don't match the shipped
    # layout, CREATE EXTENSION fractalsql fails at load time with
    # "could not open extension control file".
    #
    #   Debian (postgresql-<ver> package):
    #       /usr/lib/postgresql/<ver>/lib/fractalsql.so
    #       /usr/share/postgresql/<ver>/extension/fractalsql.control
    #       /usr/share/postgresql/<ver>/extension/fractalsql--1.0.sql
    #
    #   RHEL PGDG (postgresql<ver>-server package):
    #       /usr/pgsql-<ver>/lib/fractalsql.so
    #       /usr/pgsql-<ver>/share/extension/fractalsql.control
    #       /usr/pgsql-<ver>/share/extension/fractalsql--1.0.sql
    #
    # LICENSE ledger: staged into /usr/share/doc/<pkg>/ so the usr
    # walk below picks them up. Explicit src=dst fpm mappings won't
    # work here — fpm's -C chroots absolute source paths too, so any
    # arg like ${REPO_ROOT}/LICENSE is resolved as ${STAGE}${REPO_ROOT}/…
    # and fpm can't find the file.
    STAGE_DEB="$(mktemp -d)"
    STAGE_RPM="$(mktemp -d)"
    trap 'rm -rf "${STAGE_DEB}" "${STAGE_RPM}"' EXIT

    stage_common_docs() {
        local stage="$1"
        install -Dm0644 "${REPO_ROOT}/LICENSE" \
            "${stage}/usr/share/doc/${PKG_NAME}/LICENSE"
        install -Dm0644 "${REPO_ROOT}/THIRD-PARTY-NOTICES.md" \
            "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-THIRD-PARTY"
    }

    # Debian layout. The reasoning plugin lands in the same pkglibdir as
    # fractalsql.so; reasoning-setup.md points fractalsql.reasoning_plugin
    # at .../lib/fractalsql-reasoning-http.so there.
    install -Dm0755 "${SO}" \
        "${STAGE_DEB}/usr/lib/postgresql/${PG_VER}/lib/fractalsql.so"
    install -Dm0755 "${REASONING_SO}" \
        "${STAGE_DEB}/usr/lib/postgresql/${PG_VER}/lib/fractalsql-reasoning-http.so"
    install -Dm0644 fractalsql.control \
        "${STAGE_DEB}/usr/share/postgresql/${PG_VER}/extension/fractalsql.control"
    install -Dm0644 sql/fractalsql--1.0.sql \
        "${STAGE_DEB}/usr/share/postgresql/${PG_VER}/extension/fractalsql--1.0.sql"
    # Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
    # no .so). Ships the .control + install SQL alongside the base extension so
    # `CREATE EXTENSION fractalsql_agents` works once the base is loaded.
    install -Dm0644 fractalsql_agents/fractalsql_agents.control \
        "${STAGE_DEB}/usr/share/postgresql/${PG_VER}/extension/fractalsql_agents.control"
    install -Dm0644 fractalsql_agents/sql/fractalsql_agents--1.0.sql \
        "${STAGE_DEB}/usr/share/postgresql/${PG_VER}/extension/fractalsql_agents--1.0.sql"
    stage_common_docs "${STAGE_DEB}"

    # RHEL PGDG layout.
    install -Dm0755 "${SO}" \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/lib/fractalsql.so"
    install -Dm0755 "${REASONING_SO}" \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/lib/fractalsql-reasoning-http.so"
    install -Dm0644 fractalsql.control \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/share/extension/fractalsql.control"
    install -Dm0644 sql/fractalsql--1.0.sql \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/share/extension/fractalsql--1.0.sql"
    # Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
    # no .so). Ships the .control + install SQL alongside the base extension.
    install -Dm0644 fractalsql_agents/fractalsql_agents.control \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/share/extension/fractalsql_agents.control"
    install -Dm0644 fractalsql_agents/sql/fractalsql_agents--1.0.sql \
        "${STAGE_RPM}/usr/pgsql-${PG_VER}/share/extension/fractalsql_agents--1.0.sql"
    stage_common_docs "${STAGE_RPM}"

    echo "------------------------------------------"
    echo "Packaging ${PKG_NAME} (${PKG_ARCH})"
    echo "------------------------------------------"

    # The SFS core is statically linked into fractalsql.so — no script
    # runtime, so no luajit/lua dependency is declared. libcurl is
    # required by the bundled reasoning plugin (fractalsql-reasoning-http.so),
    # which dlopen-links it at runtime when reasoning is enabled.
    fpm -s dir -t deb \
        -n "${PKG_NAME}" \
        -v "${VERSION}" \
        -a "${PKG_ARCH}" \
        --iteration "${ITERATION}" \
        --description "FractalSQL: Stochastic Fractal Search extension for PostgreSQL ${PG_VER}" \
        --license "Apache-2.0" \
        --depends "libc6 (>= 2.34)" \
        --depends "libcurl4" \
        --depends "postgresql-${PG_VER}" \
        -C "${STAGE_DEB}" \
        -p "${DEB_OUT}" \
        usr

    # fpm's rpm backend needs the PGDG tree rooted at /usr/pgsql-<ver>/
    # instead of /usr/, so include both top-level dirs.
    fpm -s dir -t rpm \
        -n "${PKG_NAME}" \
        -v "${VERSION}" \
        -a "${RPM_ARCH}" \
        --iteration "${ITERATION}" \
        --description "FractalSQL: Stochastic Fractal Search extension for PostgreSQL ${PG_VER}" \
        --license "Apache-2.0" \
        --depends "libcurl.so.4()(64bit)" \
        --depends "postgresql${PG_VER}-server" \
        -C "${STAGE_RPM}" \
        -p "${RPM_OUT}" \
        usr

    rm -rf "${STAGE_DEB}" "${STAGE_RPM}"
    trap - EXIT
done

echo
echo "Done. Packages in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
