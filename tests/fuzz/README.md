<p align="center">
  <img src="../../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Fuzzing

libFuzzer targets for the code in this repository that parses input it does
not control: the extension's three string parsers, and the MCP server's
request handling and database-result parsing.

Run them all with:

```
./build_test.sh --fuzz
```

Each target runs for `FSQL_FUZZ_TIME` seconds (default 30). That is long
enough to catch a regression, not long enough to claim thorough coverage;
see "Running a longer campaign" below. You need a clang with libFuzzer
support. Set `FSQL_FUZZ_CC` to choose one; when none is found the fuzz run
is skipped, not failed. The MCP targets also need the libpq and OpenSSL
development packages, and are built on Linux and macOS.

## Extension parsers

`fractalsql-postgresql` is a PostgreSQL extension: almost every function in
`src/fractalsql.c` needs `postgres.h`, SPI and a live backend to run, which
rules out a standalone fuzz binary for most of the code. The three functions
below are the exception. They are plain C99 with no PostgreSQL dependency,
taking a `const char *` and a fixed-size output buffer, so they live in
`src/fractalsql_parse.c` where a fuzz target can link against them directly.

| Target | Function | Input trust |
| --- | --- | --- |
| `fuzz_parse_embedding_array.c` | `fsql_parse_embedding_array()` | **Externally adversarial.** Parses `fractal_embed()`'s raw response from whatever endpoint `fractalsql.http_embed_url` points at, so a malicious or merely buggy HTTP provider fully controls these bytes. |
| `fuzz_extract_best_point.c` | `fsql_extract_best_point()` | Parses the core's own search-result JSON. Lower risk; included as defense in depth. |
| `fuzz_extract_population.c` | `fsql_extract_population()` | Same trust level as above, and the most structurally complex of the three (nested arrays plus dimension-stride bookkeeping). |

## MCP server

Two C++ targets cover what the MCP server accepts from a client and from the
database. Neither needs a running database.

| Target | Entry point | Seeds |
| --- | --- | --- |
| `fuzz_mcp_vectors.cpp` | Argument coercion (`mcp/src/vectors.cpp`), the parsers for the array and `bytea` text PostgreSQL returns, and error-text secret redaction (`sanitizeSecrets`). The first input byte selects the function. | `corpus_mcp_vectors/` |
| `fuzz_mcp_jsonrpc.cpp` | `JsonRpcServer::handleLine`, the function both transports hand each client line to, with two stub tools. | `corpus_mcp_jsonrpc/` |

A `ToolError` is the server's documented rejection and is not a finding. A
crash, hang or sanitizer report is.

### Windows

`build_test.ps1 -Fuzz` builds the same targets with clang-cl and ASan (gate 21
also with UBSan). The argument-coercion target runs under libFuzzer. libFuzzer's
runtime on clang for Windows cannot read a caught C++ exception object, so
`fuzz_mcp_jsonrpc`, whose error replies are exceptions, is built with
`-DFSQL_FUZZ_STANDALONE` instead: a plain executable that replays the corpus and
then mutates it at random for the `-max_total_time` given. It is not
coverage-guided; the Linux run keeps the real libFuzzer.

## Seed corpora

Each `corpus_<target>/` directory holds a few valid-shaped seed files, enough
for libFuzzer to start coverage-guided mutation from a real input instead of
cold. They are not meant to be exhaustive.

libFuzzer writes the new inputs it discovers into the first directory it is
given. The fuzz runs point it at a scratch directory and pass the seed
directory second, so the tracked seeds stay as they are. If you run a target
by hand, do the same.

## Running a longer campaign

Build a target by hand and give it hours, not seconds:

```
clang-18 -std=c99 -O1 -g -fsanitize=fuzzer,address -fno-sanitize-recover=address \
    -Isrc src/fractalsql_parse.c tests/fuzz/fuzz_parse_embedding_array.c \
    -o /tmp/fuzz_parse_embedding_array
mkdir -p /tmp/fuzz_new
ASAN_OPTIONS=detect_leaks=0 /tmp/fuzz_parse_embedding_array \
    -max_total_time=3600 /tmp/fuzz_new tests/fuzz/corpus_parse_embedding_array/
```

The MCP targets build the same way:

```
clang++-18 -std=c++17 -O1 -g -fsanitize=fuzzer,address -Imcp/src -Imcp/vendor \
    $(pkg-config --cflags libpq) tests/fuzz/fuzz_mcp_vectors.cpp \
    mcp/src/vectors.cpp mcp/src/errors.cpp -o /tmp/fuzz_mcp_vectors
```

`fuzz_mcp_jsonrpc` also links the server's logging, prompts, resources and
JSON-RPC sources and libpq and OpenSSL; `build_test.sh` has the full list.

A crash reproduces directly against the same binary:
`/tmp/fuzz_parse_embedding_array <crash-file>`.
