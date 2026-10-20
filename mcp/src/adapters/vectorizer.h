#pragma once
#include <vector>
#include "../tool_registry.h"
namespace fsqlmcp { class Db;
    std::vector<ToolSpec> buildVectorizerTools( Db& db ); }