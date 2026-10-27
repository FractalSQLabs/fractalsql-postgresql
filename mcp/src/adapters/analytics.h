#pragma once
#include <vector>
#include "../tool_registry.h"
namespace fsqlmcp { class Db; struct RowLimitConfig;
    std::vector<ToolSpec> buildAnalyticsTools( Db& db, const RowLimitConfig& rowCfg ); }