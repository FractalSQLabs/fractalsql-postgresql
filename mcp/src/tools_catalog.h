#pragma once
#include <vector>
#include "tool_registry.h"
namespace fsqlmcp
{
    class Db;
    struct RowLimitConfig;
    // rowCfg must outlive every returned ToolSpec: handlers capture it and
    // run after buildAllTools() returns.
    std::vector<ToolSpec> buildAllTools( Db& db, const RowLimitConfig& rowCfg );
}