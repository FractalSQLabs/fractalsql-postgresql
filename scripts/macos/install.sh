#!/bin/bash
#
# install.sh — installer bundled inside the fractalsql-postgresql macOS
# tarball. Run it from the extracted tarball directory:
#
#     tar xzf fractalsql-postgresql-<ver>-darwin-<arch>.tar.gz
#     cd fractalsql-postgresql-<ver>-darwin-<arch>
#     ./install.sh                 # uses pg_config on PATH
#     PG_CONFIG=/path/pg_config ./install.sh   # or point at a specific one
#
# Drops the extension + reasoning plugin into the target server's own
# directories (as reported by pg_config), so `CREATE EXTENSION fractalsql;`
# works with no further path munging. Works with any macOS PostgreSQL —
# Postgres.app, Homebrew (postgresql@NN), or EDB.
#
# There is no macOS package manager for PostgreSQL extensions the way
# Debian/RHEL have .deb/.rpm, so this tarball + installer is the delivery
# vehicle on macOS (mirrors the self-contained per-platform artifacts we
# ship on Linux/Windows).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_CONFIG="${PG_CONFIG:-pg_config}"
if ! command -v "${PG_CONFIG}" >/dev/null 2>&1; then
    echo "error: pg_config not found (looked for '${PG_CONFIG}')." >&2
    echo "  Put pg_config on PATH, or run: PG_CONFIG=/path/to/pg_config ./install.sh" >&2
    echo "  Homebrew example: PG_CONFIG=\$(brew --prefix postgresql@17)/bin/pg_config ./install.sh" >&2
    exit 1
fi

PKGLIBDIR="$("${PG_CONFIG}" --pkglibdir)"
EXTDIR="$("${PG_CONFIG}" --sharedir)/extension"
PG_VERSION="$("${PG_CONFIG}" --version)"

# Refuse to install a tarball built for a different PG major — otherwise the
# mismatch only surfaces later as an opaque PG_MODULE_MAGIC error at
# CREATE EXTENSION. PG_MAJOR is written into the tarball by package-darwin.sh.
TARGET_MAJOR="$(printf '%s' "${PG_VERSION}" | sed -E 's/^PostgreSQL[[:space:]]+([0-9]+).*/\1/')"
if [ -f "${HERE}/PG_MAJOR" ]; then
    BUILT_FOR="$(cat "${HERE}/PG_MAJOR")"
    if [ -n "${BUILT_FOR}" ] && [ "${BUILT_FOR}" != "${TARGET_MAJOR}" ]; then
        echo "error: this tarball is built for PostgreSQL ${BUILT_FOR}, but" >&2
        echo "       ${PG_CONFIG} points at PostgreSQL ${TARGET_MAJOR}." >&2
        echo "       Install the pg${TARGET_MAJOR} tarball instead." >&2
        exit 1
    fi
fi

echo "Target PostgreSQL : ${PG_VERSION}"
echo "  pkglibdir       : ${PKGLIBDIR}"
echo "  extension dir   : ${EXTDIR}"
echo

# install(1) with -d creates the dir tree if a non-standard PG layout
# doesn't have it yet; -m sets sane perms. sudo may be needed if the PG
# prefix is root-owned (Homebrew installs are usually user-writable).
INSTALL="install"
if [ ! -w "${PKGLIBDIR}" ] || [ ! -w "${EXTDIR}" ]; then
    echo "note: ${PKGLIBDIR} or ${EXTDIR} is not writable — re-running file"
    echo "      copies under sudo (you may be prompted for your password)."
    INSTALL="sudo install"
fi

${INSTALL} -d "${PKGLIBDIR}" "${EXTDIR}"

${INSTALL} -m 0755 "${HERE}/fractalsql.so" \
    "${PKGLIBDIR}/fractalsql.so"
${INSTALL} -m 0755 "${HERE}/fractalsql-reasoning-http.so" \
    "${PKGLIBDIR}/fractalsql-reasoning-http.so"
${INSTALL} -m 0644 "${HERE}/fractalsql.control" \
    "${EXTDIR}/fractalsql.control"
${INSTALL} -m 0644 "${HERE}/fractalsql--1.0.sql" \
    "${EXTDIR}/fractalsql--1.0.sql"
# Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
# no .so). Installs the .control + SQL into the same extension dir as the
# base so `CREATE EXTENSION fractalsql_agents` works once the base is loaded.
${INSTALL} -m 0644 "${HERE}/fractalsql_agents.control" \
    "${EXTDIR}/fractalsql_agents.control"
${INSTALL} -m 0644 "${HERE}/fractalsql_agents--1.0.sql" \
    "${EXTDIR}/fractalsql_agents--1.0.sql"

echo "Installed:"
echo "  ${PKGLIBDIR}/fractalsql.so"
echo "  ${PKGLIBDIR}/fractalsql-reasoning-http.so"
echo "  ${EXTDIR}/fractalsql.control"
echo "  ${EXTDIR}/fractalsql--1.0.sql"
echo "  ${EXTDIR}/fractalsql_agents.control"
echo "  ${EXTDIR}/fractalsql_agents--1.0.sql"
echo
echo "Next: enable it in a database —"
echo "  psql -c 'CREATE EXTENSION fractalsql;'"
echo "  psql -c 'CREATE EXTENSION fractalsql_agents;'"
echo "  psql -c 'SELECT fractal_edition(), fractal_version();'"
echo
echo "Reasoning is opt-in; point fractalsql.reasoning_plugin at"
echo "  ${PKGLIBDIR}/fractalsql-reasoning-http.so"
echo "and configure an endpoint. See docs/reasoning-setup.md."
