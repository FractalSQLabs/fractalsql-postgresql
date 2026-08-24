# FractalSQL — PostgreSQL extension build (v1: pure-C, vendored core).
#
# Statically links the FractalSQL community-sovereign-c archive vendored
# at include/<platform>/libfractalsql-community-sovereign-c.a. The
# sovereign tier adds the reasoning VFS surface (fsql_new_sovereign,
# fsql_load_reasoning, fsql_dispatch_ai) on top of the minimal SFS ABI.
# For search-only deployments the reasoning surface is simply not used
# and the cost is zero.
#
# Refresh include/ from the foundry:
#   cd ../fractalsql-core
#   make validated-drop-native
#   ./scripts/deploy.sh --git fractalsql-postgresql
#
# Build: make
# Ship:  sudo make install && psql -c 'CREATE EXTENSION fractalsql;'
#
# CORE_VARIANT selects the vendored archive:
#   community-sovereign-c          (default; reasoning + search, glibc 2.34)
#   community-sovereign-c-legacy   (glibc 2.28 hosts)

# Ensure 'all' is the default goal even though verify-vendor is defined
# before include $(PGXS) below (verify-vendor would otherwise win as
# the first real target, making bare 'make' a no-op for compilation).
.DEFAULT_GOAL := all

MODULE_big = fractalsql
EXTENSION  = fractalsql
DATA       = sql/fractalsql--1.0.sql
PGFILEDESC = "fractalsql - Stochastic Fractal Search (pure-C core)"

OBJS = src/fractalsql.o src/fractalsql_parse.o src/fractalsql_vector.o

CORE_VARIANT ?= community-sovereign-c
# v1.2 platform layout: link the per-platform subdir
# include/<os>-<arch>/ (os = uname -s lower-cased, arch = uname -m, which
# is x86_64/aarch64 on Linux and arm64 on Apple Silicon — no translation).
# Falls back to the flat include/ layout during the dual-write window so
# this builds whether or not the subdir has been deployed yet; when core
# drops the flat layout (v1.3) the fallback resolves to the subdir.
FSQL_PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
CORE_ARCHIVE  := $(firstword \
    $(wildcard include/$(FSQL_PLATFORM)/libfractalsql-$(CORE_VARIANT).a) \
    include/libfractalsql-$(CORE_VARIANT).a)

# Verify the vendored archive at make-time. PGXS will fail later
# anyway, but a clear error here saves debugging.
ifeq (,$(wildcard $(CORE_ARCHIVE)))
  $(error $(CORE_ARCHIVE) missing — run `cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-postgresql`)
endif

# text-to-sql's statement-type allowlist uses the backend's own
# raw_parser() (parser/parser.h) -- no vendored SQL-parser dependency.
# An earlier build vendored pganalyze/libpg_query for this; it was
# dropped because statically linking its 6 MB slice of backend source
# corrupted the extension DLL's load-time state on Windows (crashed
# every function). raw_parser is already in the backend we link against,
# so nothing extra to vendor. See src/fractalsql.c's allowlist comment.

# make COVERAGE=1: gcov-instrument the extension TU for lcov reporting
# (build_test.sh --coverage). --coverage must be on both the compile
# and link line (compile emits the .gcno/counters, link pulls in
# libgcov). Does not touch the vendored core archive -- only
# src/fractalsql.o gets instrumented, matching what the gate matrix
# can actually attribute coverage to.
ifdef COVERAGE
  # -fno-lto: this distro's PGXS CFLAGS default to -flto=auto
  # -ffat-lto-objects. LTO's IR-based compilation produces a .gcno
  # gcov considers a version/toolchain mismatch against its own
  # runtime ("stamp mismatch with notes file", "no functions found")
  # even within a single gcc -- coverage and LTO don't mix cleanly.
  FSQL_COV_FLAGS := --coverage -fno-lto
else
  FSQL_COV_FLAGS :=
endif

# make ASAN=1 / UBSAN=1: sanitizer-instrument the extension TU
# (build_test.sh --asan / --ubsan). Same scoping as COVERAGE above --
# only src/fractalsql.o gets instrumented, the vendored
# core archive is linked in as-is, matching this repo's own Windows
# build_test.ps1 -Asan/-Ubsan (Build-AsanExtension/Build-UbsanExtension)
# design exactly, just ported to gcc/clang + PGXS instead of MSVC/clang-cl.
# Mutually exclusive with each other and with COVERAGE (never combined
# in one build_test.sh invocation).
ifdef ASAN
  FSQL_SAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer
else ifdef UBSAN
  FSQL_SAN_FLAGS := -fsanitize=undefined -fno-sanitize-recover=undefined
else
  FSQL_SAN_FLAGS :=
endif

# FSQL_OPENSSL_CPPFLAGS/_LDFLAGS: escape hatch for a local, non-system
# OpenSSL install (e.g. a from-source build on a Mac too old for a
# current Homebrew, or any host whose PGXS defines its own CPPFLAGS/
# LDFLAGS internally -- confirmed on real hardware that an inherited
# ambient CPPFLAGS/LDFLAGS env var gets silently shadowed by such a
# PGXS's own plain assignment, since a Makefile's own `=`/`:=` always
# wins over an environment variable of the same name; PG_CPPFLAGS/
# SHLIB_LINK below are THIS extension's own variables, never touched by
# PGXS itself, so appending here is not subject to that shadowing).
# Empty by default -- a no-op everywhere OpenSSL is found via the
# normal system/SDK include and library search paths.
FSQL_OPENSSL_CPPFLAGS ?=
FSQL_OPENSSL_LDFLAGS ?=

PG_CPPFLAGS = -Iinclude $(FSQL_COV_FLAGS) $(FSQL_SAN_FLAGS) $(FSQL_OPENSSL_CPPFLAGS)
# Static-link the core archive into the extension .so.
# -lm: math symbols (sqrt, etc.) the core depends on.
# -ldl: dlopen/dlsym used by fsql_load_reasoning inside the sovereign archive.
#       Linux-only — on macOS dlopen lives in libSystem (linked by default)
#       and there is no separate libdl to link against.
FSQL_UNAME_S := $(shell uname -s)
ifeq ($(FSQL_UNAME_S),Darwin)
  FSQL_DL_LIB :=
else
  FSQL_DL_LIB := -ldl
endif
# -lcrypto: OpenSSL EVP for Ed25519 detached-signature verification of the
# enterprise core .so before dlopen (ensure_enterprise_lib in fractalsql.c).
# Postgres itself already links libcrypto when built --with-openssl (the
# common case), so this is not a new runtime dependency on the server --
# only a new link-time one for this extension's own .so.
# FSQL_DARWIN_XC_LDFLAGS: escape hatch for cross-compiling the Darwin
# .dylib for an arch other than the build host's (e.g. x86_64 on an
# arm64 macos-14 CI runner). PGXS's own Darwin link rule adds
# -bundle_loader $(pg_bindir)/postgres so ld can verify Postgres
# backend symbols (SPI_*, errmsg, etc.) exist -- but ld64 silently
# IGNORES that file outright on an arch mismatch ("ignoring file ...
# found architecture 'arm64', required architecture 'x86_64'",
# confirmed on a real run), and then falls back to its default
# undefined-symbol-is-a-hard-error policy for a -bundle target, so
# every Postgres backend symbol fails to link. -undefined dynamic_lookup
# defers ALL symbol resolution to dyld at load time instead -- exactly
# what actually happens anyway once this .dylib is dlopen'd into a real
# x86_64 postgres process, which is the only place it will ever run.
# Empty by default -- a no-op for every native (non-cross) build.
FSQL_DARWIN_XC_LDFLAGS ?=

SHLIB_LINK  = $(CORE_ARCHIVE) $(FSQL_OPENSSL_LDFLAGS) -lm -lcrypto $(FSQL_DL_LIB) $(FSQL_COV_FLAGS) $(FSQL_SAN_FLAGS) $(FSQL_DARWIN_XC_LDFLAGS)

# --- Supply-chain verification (B5) -----------------------------------------
# The vendored archive is dropped from fractalsql-core's deploy.sh
# together with `.artifacts.sha256` (sha256sum of every shipped
# .h/.a/.so). Verify it matches the bytes on disk before linking —
# catches a tampered .a in this repo's include/ at build time.
#
# PGXS-specific wiring: PGXS's `all` target is defined inside
# $(PGXS); we use a double-colon rule below to append a pre-build
# dependency without overriding PGXS's own definition.
.PHONY: verify-vendor
verify-vendor:
	@if [ ! -f include/.artifacts.sha256 ]; then \
		echo "ERROR: include/.artifacts.sha256 missing — re-deploy from core" >&2; \
		echo "  cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-postgresql" >&2; \
		exit 1; \
	fi
	@cd include && { \
		if command -v sha256sum >/dev/null 2>&1; then \
			sha256sum -c .artifacts.sha256 >/dev/null; \
		else \
			shasum -a 256 -c .artifacts.sha256 >/dev/null; \
		fi; \
	} || { \
		echo "ERROR: vendored artifact checksum mismatch in include/." >&2; \
		echo "  Possible causes: tampered .a/.so, partial deploy, or stale .sha256." >&2; \
		echo "  Re-deploy from core to recover." >&2; \
		exit 1; \
	}

# --- PGXS -------------------------------------------------------------------
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Append verify-vendor as a prerequisite on PGXS's `all` target.
# `all: verify-vendor` adds verify-vendor to the dependency list of
# the existing PGXS-defined rule (Make merges deps across multiple
# rules with the same target as long as only one provides a body).
all: verify-vendor

# --- Source dependency ------------------------------------------------------
#
# The .c source compiles against the vendored fractalsql.h and links
# against the vendored core archive. Both are dropped from the foundry
# (see verify-vendor above).
src/fractalsql.o: include/fractalsql.h include/fractalsql_sql.h src/fractalsql_parse.h $(CORE_ARCHIVE)

# --- Benchmark -------------------------------------------------------------
#
# `make bench` runs the HNSW-vs-Scout-Mode head-to-head at demo scale
# (dim=128, 100k vectors; completes in ~2 minutes end-to-end).
#
# `make bench-full` runs the same benchmark at dim=768. HNSW index build
# at this scale takes 10-20 minutes; see bench/README.md.
#
# Both targets assume the extension is installed in a local PG and that
# Python deps from bench/requirements.txt are available.
PYTHON ?= python3

.PHONY: bench bench-full bench-data bench-run bench-vector

bench: bench-data bench-run

bench-data:
	$(PYTHON) bench/data_gen.py

bench-run:
	$(PYTHON) bench/head_to_head.py

bench-full:
	$(PYTHON) bench/data_gen.py --dim 768
	$(PYTHON) bench/head_to_head.py

# fractal_vector(n) vs float8[] at scale -- storage, COPY throughput,
# search latency, peak RSS. Separate from bench/bench-full above (which
# stays scoped to its own HNSW-vs-Scout algorithm comparison).
bench-vector:
	$(PYTHON) bench/data_gen.py --with-fractal-vector
	$(PYTHON) bench/vector_type_head_to_head.py
