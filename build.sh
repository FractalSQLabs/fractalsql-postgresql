#!/bin/bash
#
# fractalsql-postgresql multi-version, multi-arch build.
#
# Drives docker/Dockerfile to produce one .so per PG major for a single
# target architecture. Output layout:
#   dist/amd64/fractalsql_pg14.so  ..  fractalsql_pg18.so
#   dist/arm64/fractalsql_pg14.so  ..  fractalsql_pg18.so
#
# Usage:
#   ./build.sh [amd64|arm64]        # default: amd64
#
# Cross-arch builds need QEMU + binfmt_misc. In CI this is handled by
# docker/setup-qemu-action; locally:
#   docker run --privileged --rm tonistiigi/binfmt --install all

set -euo pipefail

# Index-counted arg walk: $1 is the arch, and everything after it must be
# nothing (there is no --profile-style option in this build; docker build
# inputs flow through env vars: DIST_DIR / DOCKERFILE). Silently ignoring
# trailing junk would accept e.g. `./build.sh amd64 --profile=modern` and
# surprise the user -- reject it (the sibling column's same-cause fix).
if [[ $# -gt 1 ]]; then
    echo "unexpected arguments after arch: $*" >&2
    echo "usage: ./build.sh [amd64|arm64]" >&2
    exit 2
fi

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-postgresql for ${PLATFORM}"
echo "  -> ${OUT_DIR}/fractalsql_pg{16,17,18}.so"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifacts for ${ARCH}:"
ls -l "${OUT_DIR}"/fractalsql_pg*.so
