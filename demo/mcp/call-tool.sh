#!/usr/bin/env bash
# demo/mcp/call-tool.sh -- the docker demo's MCP entrypoint (spec 9.1/14.7).
#
# NOT a second server: it is the mcp/ C++ implementation's own binary,
# restricted to the demo's four pinned tools via --tool (category/white-list
# filtering, spec 15.1's FSQL_MCP_TOOL_WHITELIST as a CLI arg):
#   Discovery:  fractal_search
#   Cognition:  fractal_reason
#   Community:  fractal_agent_data_analyst
#   Enterprise: fractal_agent_diverse_portfolios  (proves the clean
#               "enterprise tier not loaded" error path on Community)
# Per the spec the demo server is deliberately narrow: it proves call shapes
# and output normalization end to end on real data; the full 82-tool catalog
# in mcp/ (see mcp/Makefile + mcp/src/) is what production client config
# points at. In the compose service the mcp tree is mounted at /work/mcp,
# hence the /work fallback for the binary.
#
# Three call shapes:
#   call-tool.sh <tool> '<json-args>'   one tool call round-trip (the demo
#                                       one-liner; builds the JSON-RPC lines)
#   call-tool.sh serve [--http PORT ..] the compose service's long-running
#                                       streamable-HTTP server (Bearer-token
#                                       gated; port from FSQL_MCP_HTTP_PORT)
#   printf .. | call-tool.sh            raw JSON-RPC lines on stdin (the
#                                       inspector's docker-exec shape)
BIN_CANDIDATES=(
  "${FSQL_MCP_SERVER:-}"
  "$(dirname "$0")/../../mcp/fractalsql-postgresql-mcp"
  /work/mcp/fractalsql-postgresql-mcp
  "$(dirname "$0")/../../mcp/fractalsql-postgresql-mcp.exe"
)
BIN=""
for cand in "${BIN_CANDIDATES[@]}"; do
  [ -n "$cand" ] && [ -x "$cand" ] && { BIN="$cand"; break; }
done
if [ -z "$BIN" ]; then
  echo "demo/mcp: the mcp/ binary was not found or not built." >&2
  echo "Locally:  cd mcp && make   (needs pkg-config libpq/openssl)" >&2
  echo "Compose:  the mcp service builds it on first start (apt + make)." >&2
  exit 2
fi

PINS=fractal_search,fractal_reason,fractal_agent_data_analyst,fractal_agent_diverse_portfolios

# serve: the compose service's long-running streamable-HTTP form (1.1/10.3).
# stdio stays the default so a `docker compose exec` one-liner always works.
#
# --host 0.0.0.0 is EXPLICIT and required here: the server's bind default is
# 127.0.0.1 (loopback only -- the all-interfaces bind is opt-in, so a
# database server never lands on the network by accident), and inside a
# container "loopback" would make the compose-published port (18765:8765)
# unreachable. The published host port is still the operator's to control
# (docker publishes to 127.0.0.1 by default), and the Bearer token still
# gates every request.
if [ "${1:-}" = "serve" ]; then
  shift
  exec "$BIN" --tool "$PINS" --http "${FSQL_MCP_HTTP_PORT:-8765}" \
       --host "${FSQL_MCP_HTTP_HOST:-0.0.0.0}" "$@"
fi

# Positional demo one-liner (spec 9.2's `call-tool.sh tool '<json>'` shape):
# synthesize the initialize -> initialized -> tools/call sequence ourselves.
if [ $# -ge 1 ]; then
  tool="$1"
  args="${2:-{}}"
  printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fractalsql-demo","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}" \
    | "$BIN" --tool "$PINS"
  exit $?
fi

# No arguments: pass raw JSON-RPC lines through on stdin unchanged.
exec "$BIN" --tool "$PINS" "$@"