#pragma once
#include <string>
#include <vector>
#include "mcp_json.h"
#include "tool_registry.h"

namespace fsqlmcp
{
    // Canonical projection + SHA-256 over it. Recursively key-sorts
    // every nesting level so source-code field order never changes the hash.
    std::string computeSchemaHash( const std::vector<ToolSpec>& tools );

    enum class LockCheckResult { Ok, Warn, Absent };

    LockCheckResult checkSchemaLock( const std::string& lockFilePath, const std::string& computedHash,
                                       std::string* expectedOut );

    void writeSchemaLock( const std::string& lockFilePath, const std::string& computedHash );
}