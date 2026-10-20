#pragma once
#include "mcp_json.h"
namespace fsqlmcp
{
    class Db;
    class Resources
    {
    public:
        static void init( Db* db );
        static Json list();
        static Json read( const std::string& uri );
    };
}