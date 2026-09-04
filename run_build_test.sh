#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# run_build_test.sh — containerized wrapper around build_test.sh.
# build_test.sh runs INSIDE docker/Dockerfile.test as a RUN step, so
# `docker build` succeeding IS the test passing — no separate
# `docker run` / cleanup dance needed.
#
# Deliberately simple (single axis: PG_MAJOR). Each postgres:<major>-
# bookworm base image already pins its own toolchain/glibc, so there's
# no separate libc/arch/profile matrix to manage here.
#
# Usage:
#   ./run_build_test.sh                # PG 14..18, sequential
#   ./run_build_test.sh --pg 16        # one major only
#   ./run_build_test.sh 14 16          # explicit majors
#   ./run_build_test.sh --pg 16 --asan  # ASan-instrumented (see
#   ./run_build_test.sh --pg 16 --ubsan # docker/Dockerfile.test's
#                                        # FSQL_SAN_MODE build-arg)
#                                        # NOTE: --asan hangs on this
#                                        # image (Debian Bookworm glibc
#                                        # 2.36 + LD_PRELOAD=libasan.so
#                                        # deadlocks the dynamic linker).
#                                        # CI's linux-asan/linux-ubsan
#                                        # jobs run build_test.sh directly
#                                        # on ubuntu-latest instead of
#                                        # through this wrapper.
#
# Prereqs: docker (with buildx).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Z="\033[0m"; else G=""; R=""; Z=""; fi

SAN_MODE=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --asan)    SAN_MODE="asan" ;;
    --ubsan)   SAN_MODE="ubsan" ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not on PATH." >&2
  exit 2
fi

MAJORS=(14 15 16 17 18)
if [[ "${1:-}" = "--pg" ]]; then
  MAJORS=("$2")
elif [[ $# -gt 0 ]]; then
  MAJORS=("$@")
fi

FAILED=0
for v in "${MAJORS[@]}"; do
  echo ""
  echo "== docker build_test PG${v} =="
  if docker build -f docker/Dockerfile.test \
       --build-arg "PG_MAJOR=${v}" \
       --build-arg "FSQL_TEST_TIMEOUT_MULT=${FSQL_TEST_TIMEOUT_MULT:-1}" \
       --build-arg "FSQL_SAN_MODE=${SAN_MODE}" \
       -t "fractalsql-postgresql-test:pg${v}${SAN_MODE:+-$SAN_MODE}" \
       . ; then
    printf "  [${G}PASS${Z}] PG%s\n" "$v"
  else
    printf "  [${R}FAIL${Z}] PG%s\n" "$v"
    FAILED=1
  fi
done

echo ""
if [[ "$FAILED" -eq 0 ]]; then printf "${G}run_build_test: PASS${Z}\n"; exit 0
else printf "${R}run_build_test: FAIL${Z}\n"; exit 1
fi
