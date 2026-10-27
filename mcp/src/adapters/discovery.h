#pragma once
#include <vector>
#include "../tool_registry.h"
namespace fsqlmcp { class Db; struct RowLimitConfig;
    std::vector<ToolSpec> buildDiscoveryTools( Db& db, const RowLimitConfig& rowCfg ); }