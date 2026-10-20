#pragma once
#include <string_view>
#include <vector>
#include <functional>
#include <optional>
#include <chrono>
#include "mcp_json.h"
#include "errors.h"
#include "logging.h"
#include "rows.h"

namespace fsqlmcp
{
    enum class ToolClass { Cheap, Expensive };

    struct ToolParam
    {
        std::string_view name;
        JsonType         type;
        bool             required;
        Json             defaultValue = nullptr;   // used when !required and absent
        std::string_view description;
        bool             nullable = false;          // JSON-Schema anyOf [type, "null"]
        // Element kind for Array params (for example text[] doc_ids or int4[]
        // edges), advertised in the tool's input schema.
        JsonType         itemType = JsonType::Number;
    };

    struct CallCtx
    {
        std::string clientKey;     // "stdio" or a per-session/per-token key (see concurrency.h)
        bool        cancelled = false;
    };

    // Every tool-table entry uses the 8-element aggregate form {name, category,
    // toolClass, params, retryTier, destructiveHint, readOnlyHint, handler}.
    // The remaining members (description first, via `t.back().description = ...`,
    // then the hints) are assigned right after the push_back; the field order
    // below is what lets each one-push tool row compile.
    struct ToolSpec
    {
        std::string_view name, category;
        ToolClass         toolClass;
        std::vector<ToolParam> params;
        std::optional<std::string_view> retryTier;   // MariaDB only; unset => omitted from tools/list
        bool destructiveHint = true;    // fail-safe: a tool nobody classified is destructive (read-only mode refuses it)
        bool readOnlyHint    = false;
        std::function<Json( const Json& args, CallCtx& )> handler;
        // ---- post-hoc members (assigned via t.back() after push_back) ----
        std::string description = "";
        bool idempotentHint  = false;   // NEW: repeat calls with the same args produce no additional effect
        bool openWorldHint   = false;   // NEW: observes/affects state outside this DB connection (LLM provider)
        bool secretHint      = false;   // NEW: args/result may carry content a client shouldn't echo/log casually
    };

    // The annotation object a client sees in tools/list, and the one the schema
    // hash covers (one definition, so the two cannot drift). The four standard
    // hints are always sent, true or false: in the MCP spec an omitted
    // destructiveHint or openWorldHint defaults to TRUE, so leaving a false one
    // out makes a spec-following client treat a closed-world, non-destructive
    // tool as destructive and open-world. secretHint is not a spec hint and is
    // only sent when set.
    inline Json toolAnnotations( const ToolSpec& t )
    {
        Json a{ { "readOnlyHint", t.readOnlyHint },
                { "destructiveHint", t.destructiveHint },
                { "idempotentHint", t.idempotentHint },
                { "openWorldHint", t.openWorldHint } };
        if( t.secretHint ) a[ "secretHint" ] = true;
        return a;
    }

    // Non-recursive argument check against the tool's declared parameters.
    inline void validateArgs( const ToolSpec& spec, const Json& args )
    {
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        for( const ToolParam& p : spec.params )
        {
            const std::string key( p.name );
            const bool present = args.contains( key ) && !args.at( key ).is_null();

            if( !present )
            {
                if( p.required )
                    throw ToolError( ErrorClass::Schema, "missing required argument: " + key );
                continue;    // handler applies p.defaultValue itself
            }
            const Json& v = args.at( key );
            if( p.nullable && v.is_null() )
                continue;
            if( !jsonTypeMatches( p.type, v ) )
                throw ToolError( ErrorClass::Schema, key + " has the wrong type" );
            // Element-kind check for array params (this repo's addition — the
            // advertised schema promises it, so cheap-time validation keeps
            // the promise honest before any connection is touched).
            if( p.type == JsonType::Array )
            {
                for( const Json& e : v )
                {
                    if( !jsonTypeMatches( p.itemType, e ) )
                        throw ToolError( ErrorClass::Schema, key + " elements must be " + jsonTypeName( p.itemType ) );
                }
            }
        }
    }

    // validateArgs() treats an explicit JSON null on an optional, NON-nullable
    // parameter as "absent -- the handler applies the default". The handlers
    // read optionals with Json::value(key, default), which does NOT do that:
    // on a key that is present but null it throws a type_error (the caller
    // then saw an "internal server error" for what is plain client input).
    // So make the contract true before the handler runs: hand it a copy with
    // those nulls removed. Nullable parameters keep their null (it is a
    // meaningful value for them), and unknown keys are left alone.
    inline Json withoutNullDefaults( const ToolSpec& spec, const Json& args )
    {
        Json out = args;
        for( const ToolParam& p : spec.params )
        {
            if( p.nullable ) continue;
            const std::string key( p.name );
            if( out.contains( key ) && out.at( key ).is_null() ) out.erase( key );
        }
        return out;
    }

    inline Json buildInputSchema( const ToolSpec& spec )
    {
        Json props = Json::object();
        std::vector<std::string> required;
        for( const ToolParam& p : spec.params )
        {
            Json prop;
            JsonType elemType = p.type == JsonType::Array ? p.itemType : p.type;
            switch( p.type )
            {
                case JsonType::String:  prop[ "type" ] = "string";  break;
                case JsonType::Integer: prop[ "type" ] = "integer"; break;
                case JsonType::Number:  prop[ "type" ] = "number";  break;
                case JsonType::Boolean: prop[ "type" ] = "boolean"; break;
                case JsonType::Object:  prop[ "type" ] = "object";  break;
                case JsonType::Array:
                    prop[ "type" ] = "array";
                    prop[ "items" ][ "type" ] = jsonTypeName( elemType );
                    break;
                case JsonType::Null:    prop[ "type" ] = "null";    break;
            }
            if( p.nullable )
                prop[ "type" ] = Json::array( { prop[ "type" ], "null" } );
            prop[ "description" ] = std::string( p.description );
            if( !p.required && !p.defaultValue.is_null() )
                prop[ "default" ] = p.defaultValue;
            props[ std::string( p.name ) ] = prop;
            if( p.required )
                required.push_back( std::string( p.name ) );
        }
        Json schema{ { "type", "object" }, { "properties", props }, { "additionalProperties", false } };
        if( !required.empty() )
            schema[ "required" ] = required;
        if( props.empty() )
            schema[ "x-fractalsql-no-arguments" ] = true;       // marks a tool that takes no arguments
        return schema;
    }

    // validate -> handler -> classify -> always log. The RAII pattern below is
    // C++'s "finally": logging happens on every exit path via the destructor.
    inline Json runTool( const ToolSpec& spec, const Json& args, CallCtx& ctx )
    {
        const auto t0 = std::chrono::steady_clock::now();
        const char* errClass = nullptr;
        Json result;
        struct LogGuard
        {
            const ToolSpec& spec; const Json& args; const char*& errClass;
            std::chrono::steady_clock::time_point t0;
            ~LogGuard()
            {
                const double ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t0 ).count();
                logging::toolCall( spec.name, logging::redactAndCap( args ), ms, errClass );
            }
        } guard{ spec, args, errClass, t0 };

        try
        {
            validateArgs( spec, args );
            result = spec.handler( withoutNullDefaults( spec, args ), ctx );
            if( ctx.cancelled )
                throw ToolError( ErrorClass::Cancelled, "call was cancelled by the client" );
            return result;
        }
        catch( const ToolError& e )
        {
            errClass = errorClassName( e.errorClass );
            throw;
        }
        catch( const std::exception& e )
        {
            errClass = errorClassName( ErrorClass::ServerInternal );
            logging::exceptionDetail( spec.name, sanitizeSecrets( e.what() ) );
            throw ToolError( ErrorClass::ServerInternal, "internal error", sanitizeSecrets( e.what() ) );
        }
    }
}