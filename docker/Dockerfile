# syntax=docker/dockerfile:1.7
#
# fractalsql-postgresql Docker build — zero-dependency posture.
#
# The extension statically links the vendored core .a archive. The
# resulting .so depends on glibc only — no libluajit-5.1.so, no
# libstdc++, no dynamic C++ ABI.
#
# Build artifacts (collected in the final `export` stage, emitted to
# the host via `docker buildx --output type=local,dest=...`):
#   /fractalsql_pg14.so
#   /fractalsql_pg15.so
#   /fractalsql_pg16.so
#   /fractalsql_pg17.so
#   /fractalsql_pg18.so
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     -f docker/Dockerfile .
#
# build.sh drives this for amd64 and arm64 in turn.
#
# --------------------------------------------------------------------
# Important build-system notes:
#
#  * Extra flags are injected through PG_CPPFLAGS / SHLIB_LINK — PGXS
#    appends these to its own invocations, so the canonical
#    EXTENSION / MODULE_big rules stay untouched.
#
#  * -fvisibility=hidden is deliberately NOT set on the extension TU.
#    Postgres' loader resolves _PG_init and PG_MODULE_MAGIC via the
#    .dynsym of the opened .so; hiding them breaks CREATE EXTENSION.
#
#  * Post-link assertions (ldd / nm / size) run in each builder stage
#    so the build fails fast if a dynamic libstdc++ dependency
#    ever sneaks back in.

# --------------------------------------------------------------------
# Global build ARGs (declared before the first FROM so all stages
# below can re-import them with `ARG NAME` and pick up these defaults).
# --------------------------------------------------------------------

# EXT_CFLAGS / EXT_LDFLAGS — appended onto PGXS's own CFLAGS / LDFLAGS
# via PG_CPPFLAGS and SHLIB_LINK inside each build-pgNN stage.
#
# -D_GLIBCXX_USE_CXX11_ABI=0: keeps us on the pre-C++11 std::string ABI,
#   so symbols never reference __cxx11::basic_string even if anything
#   in the toolchain pulled libstdc++ headers.
# -ffunction-sections / -fdata-sections: per-symbol section emission;
#   pairs with -Wl,--gc-sections to drop unused code paths.
# -fvisibility=default: PGXS on PG 16/17/18 debian packages injects
#   -fvisibility=hidden into CFLAGS. _PG_init/_PG_fini in our TU aren't
#   annotated PGDLLEXPORT, so hidden default would drop them out of
#   .dynsym and CREATE EXTENSION would fail with "symbol not found".
#   Appending -fvisibility=default via PG_CPPFLAGS lets the last
#   -fvisibility=* on the gcc command line win and restore visibility.
# -static-libgcc / -static-libstdc++: link the C/C++ runtime helpers
#   statically; combined with --exclude-libs,ALL they stay invisible
#   in the .dynsym.
# -Wl,--strip-all: drop .symtab. .dynsym survives (required for
#   _PG_init / PG_MODULE_MAGIC resolution at CREATE EXTENSION time).
ARG EXT_CFLAGS="-D_GLIBCXX_USE_CXX11_ABI=0 -ffunction-sections -fdata-sections -fvisibility=default"
ARG EXT_LDFLAGS="-static-libgcc -static-libstdc++ -Wl,--gc-sections -Wl,--strip-all -Wl,--exclude-libs,ALL"

# Ceiling on the resulting .so. PG has a heavier ABI surface than a
# typical extension, so this is set loosely. Bump only with a note in
# the commit message — unexpected growth usually means something got
# linked in that shouldn't have.
ARG SIZE_CEILING_BYTES=3145728

# Vendored core archive variant. Default "community-minimal-c" pulls
# the modern glibc-2.34 build. Override to "community-minimal-c-legacy"
# for RHEL 8 / Ubuntu 20.04 (glibc 2.28), or "enterprise-minimal-c"
# for ENT-tier builds.
# Parameterized via this ARG so every builder stage uses the same core variant.
ARG CORE_VARIANT=community-sovereign-c

# --------------------------------------------------------------------
# Stage: PG 14 builder
# --------------------------------------------------------------------
FROM postgres:14-bookworm AS build-pg14
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        file \
        postgresql-server-dev-14 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Makefile            /build/Makefile
COPY fractalsql.control  /build/fractalsql.control
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-run the vendored-artifact deploy step." >&2 \
        && exit 1) \
 && make clean \
 && make PG_CONFIG=/usr/lib/postgresql/14/bin/pg_config \
        PG_CPPFLAGS="-Iinclude ${EXT_CFLAGS}" \
        SHLIB_LINK="/build/${CORE_A} -lm ${EXT_LDFLAGS}" \
 && cp fractalsql.so /fractalsql_pg14.so \
 && sh /build/docker/assert_so.sh /fractalsql_pg14.so "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Stage: PG 15 builder
# --------------------------------------------------------------------
FROM postgres:15-bookworm AS build-pg15
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        file \
        postgresql-server-dev-15 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Makefile            /build/Makefile
COPY fractalsql.control  /build/fractalsql.control
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-run the vendored-artifact deploy step." >&2 \
        && exit 1) \
 && make clean \
 && make PG_CONFIG=/usr/lib/postgresql/15/bin/pg_config \
        PG_CPPFLAGS="-Iinclude ${EXT_CFLAGS}" \
        SHLIB_LINK="/build/${CORE_A} -lm ${EXT_LDFLAGS}" \
 && cp fractalsql.so /fractalsql_pg15.so \
 && sh /build/docker/assert_so.sh /fractalsql_pg15.so "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Stage: PG 16 builder
# --------------------------------------------------------------------
FROM postgres:16-bookworm AS build-pg16
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        file \
        postgresql-server-dev-16 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Makefile            /build/Makefile
COPY fractalsql.control  /build/fractalsql.control
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-run the vendored-artifact deploy step." >&2 \
        && exit 1) \
 && make clean \
 && make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config \
        PG_CPPFLAGS="-Iinclude ${EXT_CFLAGS}" \
        SHLIB_LINK="/build/${CORE_A} -lm ${EXT_LDFLAGS}" \
 && cp fractalsql.so /fractalsql_pg16.so \
 && sh /build/docker/assert_so.sh /fractalsql_pg16.so "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Stage: PG 17 builder
# --------------------------------------------------------------------
FROM postgres:17-bookworm AS build-pg17
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        file \
        postgresql-server-dev-17 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Makefile            /build/Makefile
COPY fractalsql.control  /build/fractalsql.control
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-run the vendored-artifact deploy step." >&2 \
        && exit 1) \
 && make clean \
 && make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config \
        PG_CPPFLAGS="-Iinclude ${EXT_CFLAGS}" \
        SHLIB_LINK="/build/${CORE_A} -lm ${EXT_LDFLAGS}" \
 && cp fractalsql.so /fractalsql_pg17.so \
 && sh /build/docker/assert_so.sh /fractalsql_pg17.so "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Stage: PG 18 builder
# --------------------------------------------------------------------
FROM postgres:18-bookworm AS build-pg18
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        file \
        postgresql-server-dev-18 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Makefile            /build/Makefile
COPY fractalsql.control  /build/fractalsql.control
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-run the vendored-artifact deploy step." >&2 \
        && exit 1) \
 && make clean \
 && make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config \
        PG_CPPFLAGS="-Iinclude ${EXT_CFLAGS}" \
        SHLIB_LINK="/build/${CORE_A} -lm ${EXT_LDFLAGS}" \
 && cp fractalsql.so /fractalsql_pg18.so \
 && sh /build/docker/assert_so.sh /fractalsql_pg18.so "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Export stages — scratch, so `buildx --output=local` drops just the
# chosen .so file(s) onto the host.
#
#   --target export         -> all five .so's (build.sh default)
#   --target export-pg14    -> fractalsql_pg14.so only
#   --target export-pg15    -> fractalsql_pg15.so only
#   --target export-pg16    -> fractalsql_pg16.so only
#   --target export-pg17    -> fractalsql_pg17.so only
#   --target export-pg18    -> fractalsql_pg18.so only
# --------------------------------------------------------------------
FROM scratch AS export-pg14
COPY --from=build-pg14 /fractalsql_pg14.so /fractalsql_pg14.so

FROM scratch AS export-pg15
COPY --from=build-pg15 /fractalsql_pg15.so /fractalsql_pg15.so

FROM scratch AS export-pg16
COPY --from=build-pg16 /fractalsql_pg16.so /fractalsql_pg16.so

FROM scratch AS export-pg17
COPY --from=build-pg17 /fractalsql_pg17.so /fractalsql_pg17.so

FROM scratch AS export-pg18
COPY --from=build-pg18 /fractalsql_pg18.so /fractalsql_pg18.so

FROM scratch AS export
COPY --from=build-pg14 /fractalsql_pg14.so /fractalsql_pg14.so
COPY --from=build-pg15 /fractalsql_pg15.so /fractalsql_pg15.so
COPY --from=build-pg16 /fractalsql_pg16.so /fractalsql_pg16.so
COPY --from=build-pg17 /fractalsql_pg17.so /fractalsql_pg17.so
COPY --from=build-pg18 /fractalsql_pg18.so /fractalsql_pg18.so

# --------------------------------------------------------------------
# Demo stage — a RUNNABLE Postgres server with the extension already
# installed, for docker-compose.yml. Every stage above this line only
# ever hands raw .so files to the host (buildx --output=local); this
# is the first stage in this file you can actually `docker run`.
# Pinned to PG18 (the newest supported major) since this is a fresh
# eval environment, not an existing cluster to match versions with.
#
# Turnkey end-state for `docker compose up -d` (no flags):
#   * PG18 running, DB fractalsql_demo, with BOTH the base `fractalsql`
#     extension AND the dependent `fractalsql_agents` extension enabled
#     (10-fractalsql.sql + 20-fractalsql-agents.sql init scripts).
#   * The `ollama` compose service is up by default with NO model pulled
#     (model download is user-initiated via the `pull-model` profile).
#   * Every demo is in /demo/ and demoable on demand (demos are NOT run
#     at init -- reasoning is inert until a model is pulled, and the
#     demos are re-runnable so the user runs them when ready).
#   * pgvector is apt-installed (only `bench/` -- the head-to-head HNSW
#     vs Scout benchmarks -- needs it) but `CREATE EXTENSION vector` is
#     gated behind the `pgvector` compose profile; that profile also
#     creates the `fractalsql_bench` DB the bench targets.
#   * bench/ is in /bench/ with its Python deps in /bench/.venv so the
#     head-to-head benchmarks run in-container.
# The reasoning plugin is bundled unconditionally (harmless: nothing
# calls fractal_reason()/fractal_text_to_sql()/fractal_embed() unless the
# caller does, and fractalsql.http_url/http_embed_url point at the "ollama"
# compose service -- see docker-compose.yml and docs/docker-demo.md).
# --------------------------------------------------------------------
FROM postgres:18-bookworm AS demo
# libcurl4: runtime dependency of the bundled reasoning plugin (dynamic
# link). Not needed for Sniper/Scout search on its own, but required
# once fractalsql.reasoning_plugin is set.
# postgresql-18-pgvector: only `bench/` (the head-to-head HNSW-vs-Scout
# benchmarks) needs pgvector; the extension is installed here so it is
# available when the `pgvector` compose profile flips CREATE EXTENSION
# vector on. The demos themselves use FractalSQL's own fractal_vector type.
# python3 + python3-venv: the bench is run in-container via a venv (the
# venv ships its own pip via ensurepip, so python3-pip is not needed).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libcurl4 \
        postgresql-18-pgvector \
        python3 \
        python3-venv \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build-pg18 /fractalsql_pg18.so /usr/lib/postgresql/18/lib/fractalsql.so
COPY fractalsql.control       /usr/share/postgresql/18/extension/fractalsql.control
COPY sql/fractalsql--1.0.sql  /usr/share/postgresql/18/extension/fractalsql--1.0.sql
# Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql').
# COPYd into share/extension/ so `CREATE EXTENSION fractalsql_agents` works
# the same way `CREATE EXTENSION fractalsql` already does in this image.
COPY fractalsql_agents/fractalsql_agents.control      /usr/share/postgresql/18/extension/fractalsql_agents.control
COPY fractalsql_agents/sql/fractalsql_agents--1.0.sql /usr/share/postgresql/18/extension/fractalsql_agents--1.0.sql
# Bundled reasoning plugin (vendored prebuilt .so from include/). The build
# stages above select the right arch via `uname -m`; the demo stage does the
# same so the image builds on both linux/amd64 and linux/arm64. include/
# carries the plugin for every supported platform (linux-x86_64,
# linux-aarch64, darwin-arm64, darwin-x86_64; windows-x86_64 ships a .dll via
# the MSI path, not used here). COPY both linux variants and select at build
# time -- `uname -m` yields x86_64 / aarch64, matching the dir suffixes.
COPY include/linux-x86_64/fractalsql-reasoning-http.so  /usr/lib/postgresql/18/lib/fractalsql-reasoning-http.x86_64.so
COPY include/linux-aarch64/fractalsql-reasoning-http.so /usr/lib/postgresql/18/lib/fractalsql-reasoning-http.aarch64.so
RUN set -e \
 && ARCH=$(uname -m) \
 && mv "/usr/lib/postgresql/18/lib/fractalsql-reasoning-http.${ARCH}.so" \
        /usr/lib/postgresql/18/lib/fractalsql-reasoning-http.so \
 && rm -f /usr/lib/postgresql/18/lib/fractalsql-reasoning-http.*.so
# Init scripts run by the official entrypoint on first start, in lexical
# order: 10-fractalsql.sql (base) then 20-fractalsql-agents.sql (agents,
# after base is present). Both are single CREATE EXTENSION IF NOT EXISTS.
COPY docker/demo-initdb.sql        /docker-entrypoint-initdb.d/10-fractalsql.sql
COPY docker/20-fractalsql-agents.sql /docker-entrypoint-initdb.d/20-fractalsql-agents.sql
# bench/ head-to-head benchmarks (HNSW vs Scout). requirements.txt is COPYd
# first so the slow pip install layer-caches independently of bench source.
COPY bench/requirements.txt /bench/requirements.txt
RUN python3 -m venv /bench/.venv \
 && /bench/.venv/bin/pip install --quiet --upgrade pip \
 && /bench/.venv/bin/pip install --quiet -r /bench/requirements.txt \
 && rm -rf /root/.cache
COPY bench/ /bench/
# Every demo, demoable on demand via `psql -f /demo/<demo>.sql`. Not run at
# init: reasoning is inert without a model, and the demos are re-runnable.
COPY demo/ /demo/
