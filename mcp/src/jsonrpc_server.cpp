#include "jsonrpc_server.h"
#include <algorithm>
#include "resources.h"
#include "prompts.h"
#include "logging.h"
#include "policy.h"

namespace fsqlmcp
{
    // Every revision this server speaks. The first three are the legacy era
    // (initialize handshake + Mcp-Session-Id); the last two are the modern
    // era (stateless requests, per-request metadata).
    static const std::unordered_set<std::string> kSupportedProtocolVersions{
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    };
    static const char* const kDefaultProtocolVersion = "2025-06-18";

    // The tools that take the model's auto_execute flag. The flag is set by
    // the same actor the control protects against, so the operator's switch
    // (FSQL_MCP_ALLOW_AUTO_EXECUTE) decides, not the model.
    static bool takesAutoExecute( std::string_view name )
    {
        return name == "fractal_sql_agent" || name == "fractal_agent_data_analyst";
    }

    namespace
    {
        // nlohmann's value( key, default ) does not type-check what it finds (and throws on a non-object receiver), so a
        // client sending "params": "x" or "name": 5 used to surface as "internal server error" plus a logged exception.
        // These read only what has the right type: a non-object params is an invalid-params error (-32602, via
        // ToolError/Schema), and a non-string field is treated as absent.
        Json paramsOf( const Json& req )
        {
            const auto it = req.find( "params" );
            if( it == req.end() ) return Json::object();
            if( !it->is_object() ) throw ToolError( ErrorClass::Schema, "params must be an object" );
            return *it;
        }

        std::string strField( const Json& o, const char* key )
        {
            if( !o.is_object() ) return std::string();
            const auto it = o.find( key );
            return ( it != o.end() && it->is_string() ) ? it->get<std::string>() : std::string();
        }
    }

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
        return handleLine( line, clientKey, CallOptions{} );
    }

    std::optional<std::string> JsonRpcServer::handleLine( std::string_view line, const std::string& clientKey,
                                                           const CallOptions& opts )
    {
        Json req;
        if( jsonNestsTooDeep( line ) )
            return makeError( nullptr, -32700, "parse error: nesting too deep" ).dump( -1, ' ', false, Json::error_handler_t::replace );
        try { req = Json::parse( line ); }
        catch( ... ) { return makeError( nullptr, -32700, "parse error" ).dump( -1, ' ', false, Json::error_handler_t::replace ); }   // unparseable input: id is null

        if( !req.is_object() || !req.contains( "jsonrpc" ) || !req.contains( "method" ) )
            // value() throws type_error.306 on a non-object (an array, string,
            // number or null line), which escaped and aborted the whole process.
            return makeError( req.is_object() ? req.value( "id", Json( nullptr ) ) : Json( nullptr ), -32600, "invalid request" ).dump( -1, ' ', false, Json::error_handler_t::replace );

        // Nothing may escape handleLine: the stdio transport runs it on a
        // worker thread and an escaping exception there is std::terminate
        // (the whole server dies).
        try { return dispatch( req, clientKey, opts ); }
        catch( const std::exception& e )
        {
            logging::exceptionDetail( "dispatch", sanitizeSecrets( e.what() ) );
            return makeError( nullptr, -32603, "internal server error" ).dump( -1, ' ', false, Json::error_handler_t::replace );
        }
    }

    std::optional<std::string> JsonRpcServer::dispatch( const Json& req, const std::string& clientKey,
                                                         const CallOptions& opts )
    {
        const bool isNotification = !req.contains( "id" );
        // value() does not type-check, so a non-string "method" would throw.
        // Treat it as an unknown method instead (a normal method-not-found error).
        const std::string method = ( req.contains( "method" ) && req[ "method" ].is_string() )
            ? req[ "method" ].get<std::string>() : std::string();

        if( method == "notifications/cancelled" || method == "$/cancel" )
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

        const bool modern = ( opts.era == ProtocolEra::Modern );

        try
        {
            Json result;
            bool listResult = false;
            if( method == "initialize" )
            {
                if( cfg_.modernOnly )
                    return makeError( id, -32000,
                        "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                        "the initialize handshake is part of the legacy era and is refused. "
                        "Supported versions: 2025-11-25, 2026-07-28" ).dump( -1, ' ', false, Json::error_handler_t::replace );
                result = handleInitialize( paramsOf( req ) );
            }
            else if( method == "server/discover" ) result = handleServerDiscover();
            else if( method == "ping" )           result = Json::object();
            else if( method == "tools/list" )     { result = handleToolsList( opts ); listResult = true; }
            else if( method == "tools/call" )     result = handleToolsCall( paramsOf( req ), clientKey, id.dump( -1, ' ', false, Json::error_handler_t::replace ), opts );
            else if( method == "resources/list" ) { result = handleResourcesList(); listResult = true; }
            else if( method == "resources/read" ) { result = handleResourcesRead( paramsOf( req ) ); listResult = true; }
            else if( method == "resources/templates/list" ) { result = Json{ { "resourceTemplates", Json::array() } }; listResult = true; }
            else if( method == "prompts/list" )   { result = handlePromptsList(); listResult = true; }
            else if( method == "prompts/get" )    result = handlePromptsGet( paramsOf( req ) );
            else return makeError( id, -32601, "method not found: " + method ).dump( -1, ' ', false, Json::error_handler_t::replace );

            if( modern )
            {
                // The modern era's result envelope: every result says what kind
                // of result it is, and a list result says how long it may be
                // cached and in which scope.
                result[ "resultType" ] = "complete";
                if( listResult )
                {
                    result[ "ttlMs" ] = 0;              // this catalog is not cacheable
                    result[ "cacheScope" ] = "session"; // ...and it is scoped to the caller's session
                }
            }
            return makeResult( id, std::move( result ) ).dump( -1, ' ', false, Json::error_handler_t::replace );
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
            { "capabilities", { { "tools", Json::object() }, { "resources", Json::object() },
                                { "prompts", Json::object() }, { "logging", Json::object() } } }
        };
    }

    // The modern era's discovery RPC: which revisions this server speaks, what
    // it can do and who it is. A modern client reads the supported versions
    // from here instead of guessing.
    Json JsonRpcServer::handleServerDiscover()
    {
        Json versions = Json::array();
        for( const std::string& v : { "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" } )
            versions.push_back( v );
        return Json{
            { "protocolVersions", versions },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() }, { "resources", Json::object() },
                                { "prompts", Json::object() }, { "logging", Json::object() } } }
        };
    }

    Json JsonRpcServer::handleToolsList( const CallOptions& opts )
    {
        // A deterministic order (by name) in BOTH eras: the spec asks for it,
        // and a client that compares two listings must see the same order
        // whichever era it asked in.
        std::vector<const ToolSpec*> sorted;
        sorted.reserve( tools_.size() );
        for( const ToolSpec& t : tools_ ) sorted.push_back( &t );
        std::sort( sorted.begin(), sorted.end(),
                   []( const ToolSpec* a, const ToolSpec* b ) { return a->name < b->name; } );

        Json arr = Json::array();
        for( const ToolSpec* tp : sorted )
        {
            const ToolSpec& t = *tp;
            // A per-client credential may be limited to a subset of the
            // catalog; the tools it may not call are not even listed.
            if( opts.toolAllow && opts.toolAllow->count( std::string( t.name ) ) == 0 ) continue;
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

    Json JsonRpcServer::handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId,
                                         const CallOptions& opts )
    {
        // Tool-level rejections are returned as isError tool results (not bare
        // protocol errors) so clients can read error_class from structuredContent.
        const std::string name = strField( params, "name" );
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

        // A per-client credential restricted to a subset of the catalog may
        // not call outside it, even by guessing the name.
        if( opts.toolAllow && opts.toolAllow->count( name ) == 0 )
        {
            std::string allowed;
            for( const std::string& n : *opts.toolAllow )
            {
                if( !allowed.empty() ) allowed += ", ";
                allowed += n;
            }
            const ToolError e( ErrorClass::Schema,
                "tool '" + name + "' is not in this client's tool allowlist; the credential that made "
                "this request may only call: " + allowed );
            return errorResultShaped( e );
        }

        Json args = params.value( "arguments", Json::object() );
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        // The context handle belongs to the transport, not to the engine: it
        // selects which connection the call runs on and never reaches the
        // adapter.
        args.erase( "context_id" );

        // The model's auto_execute flag only counts when the operator turned
        // it on: the parameter is set by the same actor the control protects
        // against, so a flag is not a control.
        if( takesAutoExecute( spec.name ) && args.contains( "auto_execute" )
            && args[ "auto_execute" ].is_boolean() && args[ "auto_execute" ].get<bool>()
            && !autoExecuteAllowed() )
        {
            const ToolError e( ErrorClass::Schema,
                "auto_execute is refused: this server runs with FSQL_MCP_ALLOW_AUTO_EXECUTE unset, so a "
                "generated statement is never executed without an operator turning that switch on "
                "(FSQL_MCP_ALLOW_AUTO_EXECUTE=true). Generate the SQL and run it yourself instead." );
            return errorResultShaped( e );
        }

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
        // Which protocol era the call arrived in: the operator's log says so
        // on every call, so a client that quietly falls back from the modern
        // era to the legacy one is visible.
        ctx.era = ( opts.era == ProtocolEra::Modern ) ? "modern" : "legacy";
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
        {
            Json out{ { "content", { { { "type", "text" }, { "text", result[ "message" ] } } } },
                      { "isError", true }, { "structuredContent", errorPayload } };
            // The context handle the caller may pass back to keep using the
            // same engine state.
            if( !opts.contextId.empty() ) out[ "context_id" ] = opts.contextId;
            return out;
        }
        Json out{ { "content", { { { "type", "text" }, { "text", result.dump( -1, ' ', false, Json::error_handler_t::replace ) } } } },
                  { "isError", false }, { "structuredContent", result } };
        if( !opts.contextId.empty() ) out[ "context_id" ] = opts.contextId;
        return out;
    }

    Json JsonRpcServer::handleResourcesList() { return Resources::list(); }
    Json JsonRpcServer::handleResourcesRead( const Json& params ) { return Resources::read( strField( params, "uri" ) ); }
    Json JsonRpcServer::handlePromptsList()   { return Prompts::list(); }
    Json JsonRpcServer::handlePromptsGet( const Json& params )
    {
        return Prompts::get( strField( params, "name" ), params.value( "arguments", Json::object() ) );
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