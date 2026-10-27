#pragma once
#include "tool_registry.h"
#include <string>

namespace fsqlmcp
{
    // Safety-annotation lock: one line per tool, sorted by name, listing its
    // safety hints. Plain text so a change is easy to review in a diff.
    std::string renderSafetyAnnotations( const std::vector<ToolSpec>& tools );

    // A mismatch is always fatal (main exits 3), regardless of
    // FSQL_MCP_STRICT_SCHEMA_HASH.
    bool checkSafetyAnnotations( const std::string& lockPath, const std::string& rendered, std::string* diffOut );

    void writeSafetyAnnotations( const std::string& lockPath, const std::string& rendered );
}