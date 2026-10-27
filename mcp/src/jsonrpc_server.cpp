#include "jsonrpc_server.h"
#include <algorithm>
#include "resources.h"
#include "prompts.h"
#include "logging.h"

namespace fsqlmcp
{
    static const std::unordered_set<std::string> kSupportedProtocolVersions{
        "2024-11-05", "2025-03-26", "2025-06-18"
    };
    static const char* const kDefaultProtocolVersion = "2025-06-18";

    JsonRpcServer::JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg )
        : cfg_( std::move( cfg ) ), tools_( std::move( tools ) )
    {
        // Process-global caps when shared (HTTP sessions); owned otherwise (stdio).
        if( cfg_.sharedConcurrency )
            conc_ = cfg_.sharedConcurrency;
        else
        {
            ownedConc_ = std::make_unique<ConcurrencyManager>( concCfg );
            conc_ = ownedConc_.get();
        }

        for( const ToolSpec& t : tools_ )
            byName_[ std::string( t.name ) ] = &t;
    }

    static Json makeError( const Json& id, int code, const std::string& message )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "error", { { "code", code }, { "message", message } } } };
    }
    static Json makeResult( const Json& id, Json result )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "result", std::move( result ) } };
    }
    // isError-shaped tool result carrying the structured error class, used for
    // both engine failures and pre-engine rejections so clients see one shape.
    static Json errorResultShaped( const ToolError& e )
    {
        return Json{
            { "content", Json::array( { Json{ { "type", "text" }, { "text", e.message } } } ) },
            { "isError", true },
            { "structuredContent", e.clientPayload() }
        };
    }

    std::optional<std::string> JsonRpcServer::handleLine( std::string_view line, const std::string& clientKey )
    {
        Json req;
        try { req = Json::parse( line ); }
        catch( ... ) { return makeError( nullptr, -32700, "parse error" ).dump( -1, ' ', false, Json::error_handler_t::replace ); }   // unparseable input: id is null

        if( !req.is_object() || !req.contains( "jsonrpc" ) || !req.contains( "method" ) )
            // value() throws type_error.306 on a non-object (an array, string,
            // number or null line), which escaped and aborted the whole process.
            return makeError( req.is_object() ? req.value( "id", Json( nullptr ) ) : Json( nullptr ), -32600, "invalid request" ).dump( -1, ' ', false, Json::error_handler_t::replace );

        const bool isNotification = !req.contains( "id" );
        // value() does not type-check, so a non-string "method" would throw.
        // Treat it as an unknown method instead (a normal method-not-found error).
        const std::string method = ( req.contains( "method" ) && req[ "method" ].is_string() )
            ? req[ "method" ].get<std::string>() : std::string();

        if( method == "notifications/cancelled" )
        {
            if( req.contains( "params" ) && req[ "params" ].contains( "requestId" ) )
                cancel( req[ "params" ][ "requestId" ].dump( -1, ' ', false, Json::error_handler_t::replace ) );
            return std::nullopt;             // never reply to a notification
        }
        if( isNotification )
            return std::nullopt;             // e.g. notifications/initialized

        const Json& id = req[ "id" ];
        // No shuttingDown_ check here: the transport decides acceptance (stdio
        // skips lines read after shutdown; HTTP answers 503 during drain). A
        // request already handed to this dispatcher is always processed.

        try
        {
            if( method == "initialize" )     return makeResult( id, handleInitialize( req.value( "params", Json::object() ) ) ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "ping" )           return makeResult( id, Json::object() ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "tools/list" )     return makeResult( id, handleToolsList() ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "tools/call" )     return makeResult( id, handleToolsCall( req.value( "params", Json::object() ), clientKey, id.dump( -1, ' ', false, Json::error_handler_t::replace ) ) ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "resources/list" ) return makeResult( id, handleResourcesList() ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "resources/read" ) return makeResult( id, handleResourcesRead( req.value( "params", Json::object() ) ) ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "resources/templates/list" ) return makeResult( id, Json{ { "resourceTemplates", Json::array() } } ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "prompts/list" )   return makeResult( id, handlePromptsList() ).dump( -1, ' ', false, Json::error_handler_t::replace );
            if( method == "prompts/get" )    return makeResult( id, handlePromptsGet( req.value( "params", Json::object() ) ) ).dump( -1, ' ', false, Json::error_handler_t::replace );
            return makeError( id, -32601, "method not found: " + method ).dump( -1, ' ', false, Json::error_handler_t::replace );
        }
        catch( const ToolError& e )
        {
            // tools/call builds its own isError result; this catches typed errors
            // from the other handlers (for example resources/read). Schema errors
            // map to -32602 (invalid params), everything else to -32000.
            const int code = ( e.errorClass == ErrorClass::Schema ) ? -32602 : -32000;
            return makeError( id, code, e.message ).dump( -1, ' ', false, Json::error_handler_t::replace );
        }
        catch( const std::exception& e )
        {
            // Unexpected errors get a fixed generic message: exception text can
            // carry file paths, SQL or connection details. The real cause goes
            // to the server log only.
            logging::exceptionDetail( "dispatch", sanitizeSecrets( e.what() ) );
            return makeError( id, -32603, "internal server error" ).dump( -1, ' ', false, Json::error_handler_t::replace );
        }
    }

    Json JsonRpcServer::handleInitialize( const Json& params )
    {
        std::string proto = kDefaultProtocolVersion;
        if( params.contains( "protocolVersion" ) && params[ "protocolVersion" ].is_string() )
        {
            const std::string requested = params[ "protocolVersion" ].get<std::string>();
            if( kSupportedProtocolVersions.count( requested ) )
                proto = requested;      // echo back if recognized; else fall back silently
        }
        return Json{
            { "protocolVersion", proto },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() }, { "resources", Json::object() }, { "prompts", Json::object() } } }
        };
    }

    Json JsonRpcServer::handleToolsList()
    {
        Json arr = Json::array();
        for( const ToolSpec& t : tools_ )
        {
            Json entry{
                { "name", std::string( t.name ) },
                { "description", t.description },
                { "inputSchema", buildInputSchema( t ) },
                { "_meta", { { "x-fractalsql-tier", std::string( t.category ) },
                             { "x-fractalsql-class", t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" } } }
            };
            if( t.retryTier )
                entry[ "_meta" ][ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );   // MariaDB only; omitted elsewhere
            entry[ "annotations" ] = toolAnnotations( t );
            arr.push_back( entry );
        }
        return Json{ { "tools", arr } };
    }

    Json JsonRpcServer::handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId )
    {
        // Tool-level rejections are returned as isError tool results (not bare
        // protocol errors) so clients can read error_class from structuredContent.
        const std::string name = params.value( "name", "" );
        auto it = byName_.find( name );
        if( it == byName_.end() )
        {
            const ToolError e( ErrorClass::Schema, "unknown tool '" + name + "' — see tools/list" );
            return errorResultShaped( e );
        }
        const ToolSpec& spec = *it->second;

        // Read-only mode refuses destructive tools before they take a
        // concurrency slot or reach the engine.
        if( cfg_.readOnlyMode && spec.destructiveHint )
        {
            const ToolError e( ErrorClass::Schema,
                "server is running in read-only mode (FSQL_MCP_READ_ONLY=true); '" + name +
                "' is destructive and was refused before reaching the engine" );
            return errorResultShaped( e );
        }

        const Json args = params.value( "arguments", Json::object() );
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        // Register the call as in-flight BEFORE the concurrency acquire, so a
        // $/cancel landing on either side of it still finds the call to
        // interrupt. The registration carries a unique token (the client may
        // reuse a request id): the token, not the id, is what the cleanup
        // guard below matches on, so a late cleanup from a previous call can
        // never unregister or un-cancel a NEWER call that reused the id.
        std::uint64_t callToken;
        { std::lock_guard<std::mutex> lk( inflightMu_ );
          callToken = ++nextInflightToken_;
          inflightIds_[ requestId ] = callToken; }
        ++active_;
        struct ActiveGuard { std::atomic<std::size_t>& a; ~ActiveGuard() { --a; } } activeGuard{ active_ };

        // RAII cleanup of the in-flight registration: the id MUST leave the
        // set on EVERY exit path — the normal return, the cancelled throw
        // below, the "server busy" throw from conc_->acquire() (per-client
        // cap or queue-wait timeout), and any non-ToolError exception
        // escaping runTool. Before this guard the only erase sat on the
        // normal path, so a throwing acquire() LEAKED the id: the set grew
        // without bound and — because cancel() only marks ids that are still
        // in flight — a later $/cancel naming that id marked the NEXT call
        // that happened to reuse it as cancelled.
        struct InflightGuard
        {
            std::mutex& mu;
            std::unordered_map<std::string, std::uint64_t>& inflight;
            std::unordered_map<std::string, std::uint64_t>& cancelled;
            const std::string& id;
            std::uint64_t token;
            ~InflightGuard()
            {
                std::lock_guard<std::mutex> lk( mu );
                // Remove only this call's own entries (matched by token); a newer
                // call that reused the same request id keeps its registration.
                auto it = inflight.find( id );
                if( it != inflight.end() && it->second == token ) inflight.erase( it );
                auto ct = cancelled.find( id );
                if( ct != cancelled.end() && ct->second == token ) cancelled.erase( ct );
            }
        } inflightGuard{ inflightMu_, inflightIds_, cancelledIds_, requestId, callToken };

        ConcurrencyManager::Token token = conc_->acquire( spec.toolClass, clientKey );

        CallCtx ctx; ctx.clientKey = clientKey;
        { std::lock_guard<std::mutex> lk( inflightMu_ );
          auto ct = cancelledIds_.find( requestId );
          ctx.cancelled = ( ct != cancelledIds_.end() && ct->second == callToken ); }

        Json result;
        bool isError = false;
        Json errorPayload;
        try
        {
            result = runTool( spec, args, ctx );
        }
        catch( const ToolError& e )
        {
            isError = true;
            errorPayload = e.clientPayload();
            result = Json{ { "message", e.errorClass == ErrorClass::ServerInternal ? errorPayload[ "message" ].get<std::string>() : e.message } };
        }

        bool cancelledAfter;
        { std::lock_guard<std::mutex> lk( inflightMu_ );
          auto ct = cancelledIds_.find( requestId );
          cancelledAfter = ( ct != cancelledIds_.end() && ct->second == callToken ); }
        // The in-flight/cancelled entries are removed by inflightGuard's
        // destructor on every exit path from here on (including the throw
        // below) — the erase is NOT done inline any more, so the normal path
        // and the throwing paths clean up identically.
        if( cancelledAfter )
            throw ToolError( ErrorClass::Cancelled, "call was cancelled; result discarded" );   // never deliver a late result

        if( isError )
            return Json{ { "content", { { { "type", "text" }, { "text", result[ "message" ] } } } }, { "isError", true }, { "structuredContent", errorPayload } };
        return Json{ { "content", { { { "type", "text" }, { "text", result.dump( -1, ' ', false, Json::error_handler_t::replace ) } } } }, { "isError", false }, { "structuredContent", result } };
    }

    Json JsonRpcServer::handleResourcesList() { return Resources::list(); }
    Json JsonRpcServer::handleResourcesRead( const Json& params ) { return Resources::read( params.value( "uri", "" ) ); }
    Json JsonRpcServer::handlePromptsList()   { return Prompts::list(); }
    Json JsonRpcServer::handlePromptsGet( const Json& params )
    {
        return Prompts::get( params.value( "name", "" ), params.value( "arguments", Json::object() ) );
    }

    void JsonRpcServer::cancel( const std::string& requestId )
    {
        {
            std::lock_guard<std::mutex> lk( inflightMu_ );
            // Only mark it if actually in flight (a cancel for an unknown id
            // must not poison the next request that happens to reuse the id).
            auto it = inflightIds_.find( requestId );
            if( it == inflightIds_.end() ) return;
            // The mark carries the call's token, so a later call that reuses
            // the request id does not inherit the cancellation.
            cancelledIds_[ requestId ] = it->second;
        }
        // Interrupt the in-flight statement out-of-band (PQcancel).
        if( cfg_.cancelHook ) cfg_.cancelHook();
    }

    void JsonRpcServer::beginShutdown() { shuttingDown_ = true; }

    std::size_t JsonRpcServer::activeRequestCount() { return active_.load(); }
}