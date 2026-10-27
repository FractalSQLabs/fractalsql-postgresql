#pragma once
#include <string>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp::logging
{
    enum class Level { Error = 10, Info = 5, Debug = 20 };

    struct Config
    {
        Level level = Level::Info;    // FSQL_MCP_LOG_LEVEL=normal|verbose|error -> Info|Debug|Error
    };

    void init( const Config& cfg );

    // One JSON-line to stderr per tool call. argsRedacted is the already-
    // capped/redacted copy (see redactAndCap below) — callers must not pass
    // raw caller-supplied arguments here.
    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                    double latencyMs, const char* errorClassOrNull );

    // Admin-tool config changes: logs old+new value explicitly.
    void configChange( std::string_view key, std::string_view oldValueRedacted,
                        std::string_view newValueRedacted );

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail );

    // Generic structured event line (e.g. "schema_lock_ok") — a JSON object
    // with {"event": name, ...fields} merged at the top level.
    void event( std::string_view name, const Json& fields );

    // Capping/redaction rules for logged arguments: arrays -> "<array len=N sha256_8=XXXXXXXX>",
    // long strings -> "<str len=N sha256_8=XXXXXXXX>", any key ending in
    // token/password/key/secret (case-insensitive) -> "***", recursing at
    // most 2 levels. Returns a NEW json value; never mutates the input.
    Json redactAndCap( const Json& args, int depth = 0 );
}