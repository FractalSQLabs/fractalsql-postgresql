# fractalsql-postgresql-mcp — mirrors the repo's own build conventions (13.5):
# its top level is a plain Makefile (PGXS for the extension itself), so this
# standalone client binary gets a plain Makefile too — no CMake introduction.
CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra $(shell pkg-config --cflags libpq)
# src/vectors.cpp uses std::to_chars on a double (shortest round-trip form), which
# Apple's libc++ marks unavailable before macOS 13.3. CI exports
# MACOSX_DEPLOYMENT_TARGET=11.0 for the extension dylib; the MCP server is a
# separate binary, so it carries its own, newer minimum (as package-darwin.sh does).
ifeq ($(shell uname -s),Darwin)
    CXXFLAGS += -mmacosx-version-min=13.3
endif

SRC      := $(wildcard src/*.cpp) $(wildcard src/adapters/*.cpp)
OBJ      := $(SRC:.cpp=.o)
# OUT: where the linked server is written. The default keeps the binary in
# mcp/, where the packaging scripts, the compose file and the CI workflows
# expect it. A build that runs against a shared folder (a bind mount, a synced
# directory) can point OUT at a directory it owns, so the link step never has
# to create its output file in the shared tree -- a link there can fail with
# an opaque linker error that says nothing about the code being linked.
OUT      ?= fractalsql-postgresql-mcp
# openssl's own -L comes first: Homebrew's openssl@3 is keg-only (not on the default
# linker path), so a bare -lssl -lcrypto fails to link on macOS. The explicit
# -lssl -lcrypto stays as the fallback when no openssl.pc is found.
LIBS     := $(shell pkg-config --libs libpq) $(shell pkg-config --libs openssl 2>/dev/null) -lssl -lcrypto -lpthread

# COVERAGE=1: gcda writes must survive a threaded process — this binary runs
# one std::thread per HTTP connection, and gcov's default per-file counter
# updates race under threads (lcov/geninfo then fails with "Unexpected
# negative count"). -fprofile-update=atomic makes every counter increment
# atomic; the rest of the project's single-threaded gate workers do not need
# it, so the flag lives here, in the one threaded build.
ifdef COVERAGE
    CXXFLAGS += -O1 -g --coverage -fprofile-update=atomic
    LIBS     += -lgcov
endif

# ASAN=1 / UBSAN=1 compose freely; TSAN=1 composes with UBSAN=1 but NOT
# with ASAN=1 (the runtimes cannot share a binary). UBSAN builds do not
# recover: the first undefined-behaviour hit aborts the server, so a
# build_test.sh gate cannot pass over it.
SANITIZE =
ifeq ($(ASAN),1)
  SANITIZE += -fsanitize=address
endif
ifeq ($(UBSAN),1)
  SANITIZE += -fsanitize=undefined -fno-sanitize-recover=undefined
endif
ifeq ($(TSAN),1)
  ifeq ($(ASAN),1)
    $(error TSAN=1 cannot be combined with ASAN=1 -- their runtimes cannot link into the same binary)
  endif
  SANITIZE += -fsanitize=thread
endif
ifneq ($(strip $(SANITIZE)),)
  CXXFLAGS := $(CXXFLAGS) -O1 -g -fno-omit-frame-pointer $(SANITIZE)
endif

$(OUT): $(OBJ)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJ) $(LIBS)

# -MMD -MP: write a .d file per object so a header change rebuilds every object
# that includes it (without this, e.g. a class-layout change in db.h left stale
# objects in the link).
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -MMD -MP -Ivendor -c $< -o $@

-include $(OBJ:.o=.d)

clean:
	rm -f $(OBJ) $(OBJ:.o=.d) $(OBJ:.o=.gcno) $(OBJ:.o=.gcda) $(OUT)

.PHONY: clean