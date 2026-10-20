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

fractalsql-postgresql-mcp: $(OBJ)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJ) $(LIBS)

# -MMD -MP: write a .d file per object so a header change rebuilds every object
# that includes it (without this, e.g. a class-layout change in db.h left stale
# objects in the link).
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -MMD -MP -Ivendor -c $< -o $@

-include $(OBJ:.o=.d)

clean:
	rm -f $(OBJ) $(OBJ:.o=.d) $(OBJ:.o=.gcno) $(OBJ:.o=.gcda) fractalsql-postgresql-mcp

.PHONY: clean