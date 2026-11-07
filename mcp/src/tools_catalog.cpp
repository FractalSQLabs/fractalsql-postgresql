// Tool-catalog assembly (14.1 main.cpp's buildAllTools TODO, its own TU so the
// entrypoint doesn't instantiate the whole JSON/adapter surface at once).
#include "tools_catalog.h"
#include "rows.h"
#include "adapters/discovery.h"
#include "adapters/cognition.h"
#include "adapters/agency.h"
#include "adapters/analytics.h"
#include "adapters/enterprise.h"
#include "adapters/vectorizer.h"
#include "adapters/admin.h"
#include "resources.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAllTools( Db& db, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> all;
        for( std::vector<ToolSpec> v : { buildDiscoveryTools( db, rowCfg ), buildCognitionTools( db ),
                                         buildAgencyTools( db ), buildAnalyticsTools( db, rowCfg ),
                                         buildEnterpriseTools( db ), buildVectorizerTools( db ), buildAdminTools( db ) } )
            all.insert( all.end(), v.begin(), v.end() );

        // A read-only tool is idempotent by definition, so idempotentHint
        // follows readOnlyHint for the whole catalog.
        for( ToolSpec& x : all )
            if( x.readOnlyHint ) x.idempotentHint = true;

        // Also idempotent without being read-only: enabling or disabling
        // Diversify twice leaves the same state.
        for( ToolSpec& x : all )
            if( x.name == "fractal_diversify_enable" || x.name == "fractal_diversify_disable" )
                x.idempotentHint = true;

        classifyStateMutatingTools( all );

        // The tools whose effect lives in the ENGINE's session state take the
        // optional "context_id" argument. In the modern protocol era there is
        // no protocol session to carry that state, so the handle is explicit:
        // the first call without one mints a handle and returns it, and
        // passing the handle back keeps using the same engine state. Added
        // here, in the one place the tool table is assembled, so the schema,
        // the manifest and the locks all describe the same argument.
        for( ToolSpec& x : all )
            if( isContextScopedTool( x.name ) )
                x.params.push_back( contextIdParam() );

        Resources::init( &db );
        return all;   // 14 discovery + 4 cognition + 22 agency + 23 analytics + 10 enterprise + 5 vectorizer + 4 admin = 82
    }
}