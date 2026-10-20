#pragma once
#include "mcp_json.h"
namespace fsqlmcp { class Prompts { public: static Json list(); static Json get( const std::string& name, const Json& args ); }; }