# tests/fuzz/

libFuzzer drivers for `fractalsql-postgresql`'s three hand-rolled
string parsers (`src/fractalsql_parse.c`). Run via `build_test.sh
--fuzz` (gate 21) -- see that script's own header comment for the full
gate description. Do not invoke the compile lines in these files by
hand for anything other than local iteration; the gate is the source
of truth for flags.

## Why only three targets, and why a separate translation unit

`fractalsql-postgresql` is a PostgreSQL extension: almost every
function in `src/fractalsql.c` requires `postgres.h`, SPI, and a live
backend to run at all, which rules out a standalone libFuzzer binary
for most of the codebase (OSS-Fuzz's builder can't spin up a
PostgreSQL cluster either, for the same reason -- see the project's
own notes on why OSS-Fuzz packaging isn't set up here yet).

The three functions fuzzed here are the exception: they are pure C99,
no PostgreSQL dependency, taking a `const char *` and a fixed-size
output buffer. They were factored out of `fractalsql.c` into
`src/fractalsql_parse.c`/`.h` specifically so a fuzz driver can link
against them directly. `fractalsql.c` still calls them (via
`#include "fractalsql_parse.h"`) exactly as before -- this was a pure
relocation, not a behavior change.

| Target | Function | Input trust |
| --- | --- | --- |
| `fuzz_parse_embedding_array.c` | `fsql_parse_embedding_array()` | **Externally adversarial.** Parses `fractal_embed()`'s raw response from whatever endpoint `fractalsql.http_embed_url` points at -- a malicious or merely buggy third-party HTTP provider fully controls these bytes. |
| `fuzz_extract_best_point.c` | `fsql_extract_best_point()` | Parses the vendored core's own `fsql_search_ptr` result JSON. Lower risk, included as defense-in-depth. |
| `fuzz_extract_population.c` | `fsql_extract_population()` | Same trust tier as above; the most structurally complex of the three (nested-array + dim-stride bookkeeping), the likeliest to have an edge case the other two don't share. |

## Corpus

`corpus_<target>/` holds a handful of valid-shaped seed files per
target -- enough for libFuzzer to bootstrap coverage-guided mutation
from a real starting point rather than cold. Not meant to be
exhaustive; the fuzzer's own mutation is what finds the interesting
cases.

## Running a real campaign (not just the pre-push smoke)

Gate 21 runs each target for `FSQL_FUZZ_TIME` seconds (default 30) --
enough to catch a regression, not enough to claim thorough coverage.
For a real campaign, build the same binaries by hand and give them
hours, not seconds:

```
clang-18 -std=c99 -O1 -g -fsanitize=fuzzer,address -fno-sanitize-recover=address \
    -Isrc src/fractalsql_parse.c tests/fuzz/fuzz_parse_embedding_array.c \
    -o /tmp/fuzz_parse_embedding_array
ASAN_OPTIONS=detect_leaks=0 /tmp/fuzz_parse_embedding_array \
    -max_total_time=3600 tests/fuzz/corpus_parse_embedding_array/
```

A crash reproduces directly against the same binary:
`/tmp/fuzz_parse_embedding_array <crash-file>`.
