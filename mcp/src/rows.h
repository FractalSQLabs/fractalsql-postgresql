#pragma once
#include "mcp_json.h"
#include "errors.h"

#include <algorithm>
#include <string_view>

namespace fsqlmcp
{
    struct RowLimitConfig
    {
        int maxRowsCeiling = 1000;   // FSQL_MCP_MAX_ROWS_CEILING
    };

    struct BoundedCount
    {
        int  passed;          // what the adapter should actually pass to the SQL call
        int  ceiling;
        bool truncated;       // requested > passed
        int  requested;       // echoed back for total_scanned bookkeeping
    };

    // Bounds a tool's result count. countKey names the tool's own
    // "how many results" argument (e.g. "k", "population_size"); its JSON
    // default is defaultCount when the argument was omitted.
    inline BoundedCount boundedCount( const Json& args, std::string_view countKey,
                                       int defaultCount, const RowLimitConfig& cfg )
    {
        int requested = defaultCount;
        if( args.contains( countKey ) && !args.at( std::string( countKey ) ).is_null() )
        {
            const Json& v = args.at( std::string( countKey ) );
            if( !v.is_number_integer() )
                throw ToolError( ErrorClass::Schema, std::string( countKey ) + " must be an integer" );
            requested = v.get<int>();
        }
        if( requested < 1 || requested >= 1'000'000 )
            throw ToolError( ErrorClass::Schema, std::string( countKey ) + " out of range [1, 1000000)" );

        int limit = 100;
        if( args.contains( "limit" ) && !args.at( "limit" ).is_null() )
        {
            const Json& v = args.at( "limit" );
            if( !v.is_number_integer() || v.get<int>() < 1 )
                throw ToolError( ErrorClass::Schema, "limit must be a positive integer" );
            limit = v.get<int>();
        }

        const int ceiling = std::min( limit, cfg.maxRowsCeiling );
        const int passed  = std::min( requested, ceiling );
        return BoundedCount{ passed, ceiling, requested > passed, requested };
    }

    // Shared result annotator. rowsJson must be a JSON array; it is wrapped
    // into {"rows":..., "truncated":..., "total_scanned":...} only when the
    // ceiling was actually hit, otherwise returned unwrapped.
    inline Json annotateRows( Json rowsJson, const BoundedCount& bc )
    {
        if( !bc.truncated )
            return rowsJson;
        Json out;
        out[ "rows" ]          = std::move( rowsJson );
        out[ "truncated" ]     = true;
        out[ "total_scanned" ] = bc.requested;
        return out;
    }
}