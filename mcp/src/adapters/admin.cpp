#include "admin.h"
#include "../db.h"
#include "../vectors.h"
#include "../logging.h"
#include "../policy.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

namespace fsqlmcp
{
    // The ONE documented no-$n exception: ALTER SYSTEM SET is a utility
    // statement — postgres rejects $n parameter binding in utility statements —
    // so the GUC NAME comes from this fixed allowlist (compile-time constants,
    // never caller data) and the VALUE is a bound parameter rendered into the
    // statement with single-quote doubling only. The enterprise GUCs are
    // deliberately not in the allowlist.
    static const std::vector<std::pair<const char*, const char*>> kFieldMap{
        { "provider_url",   "fractalsql.http_url" },
        { "embed_url",      "fractalsql.http_embed_url" },
        { "model",          "fractalsql.http_model" },
        { "embed_model",    "fractalsql.http_embed_model" },
        { "allow_plaintext","fractalsql.http_allow_plaintext" },
        { "think_mode",     "fractalsql.http_think" }
    };

    // The engine's fractalsql.* settings by bare key (the fractalsql.-prefixed
    // spelling is accepted too). http_token is deliberately absent: it is a
    // secret that is never set or read back through MCP; it belongs in the
    // operator's postgresql.conf or environment.
    static const std::array<const char*, 17> kKnownKeys{
        "reasoning_plugin", "http_url", "http_model", "http_allow_plaintext",
        "http_embed_url", "http_embed_model", "http_think", "http_think_provider",
        "http_native_url", "http_num_ctx", "text_to_sql_max_attempts",
        "text_to_sql_allowed_statements", "text_to_sql_use_review",
        "enterprise_lib", "enterprise_require_signature", "enterprise_ledger_key",
        "agent_partial_reasoning_fail"
    };

    // Secrets: enterprise_ledger_key (the HMAC key) and http_token (the provider
    // bearer token) are never read back through MCP, and http_token is never set
    // through it either.
    // Strips the optional "fractalsql." prefix so every key comparison, secret
    // check and redaction works on the bare key name in either spelling.
    static std::string asBareKey( const std::string& k )
    {
        // An array (not a pointer), so sizeof gives the string length + NUL.
        constexpr char kPfx[] = "fractalsql.";
        return k.rfind( kPfx, 0 ) == 0 ? k.substr( sizeof( kPfx ) - 1 ) : k;
    }

    static bool isSecretKey( const std::string& k )
    {
        const std::string bare = asBareKey( k );
        return bare == "enterprise_ledger_key" || bare == "http_token";
    }

    static bool isEnterpriseKey( const std::string& k )
    {
        const std::string bare = asBareKey( k );
        return bare == "enterprise_lib" || bare == "enterprise_require_signature" ||
               bare == "enterprise_ledger_key";
    }

    // Accepts either spelling; the engine's GUC is always the fractalsql.-prefixed one.
    static std::string normalizeKey( const std::string& k )
    {
        return k.rfind( "fractalsql.", 0 ) == 0 ? k : "fractalsql." + k;
    }

    static std::string quoteDouble( const std::string& v )
    {
        std::string out; out.reserve( v.size() + 2 );
        out.push_back( '\'' );
        for( char c : v ) { out.push_back( c ); if( c == '\'' ) out.push_back( '\'' ); }
        out.push_back( '\'' );
        return out;
    }

    static std::string lowerAscii( const std::string& s )
    {
        std::string o; o.reserve( s.size() );
        for( char c : s ) o.push_back( (char) std::tolower( (unsigned char) c ) );
        return o;
    }

    // GUC read-back comparison. postgres NORMALIZES a boolean GUC's value
    // (true/1 -> on, false/0 -> off), so a literal compare against what the
    // caller asked for would report a false "the set did not stick" for
    // every boolean key. Compare case-insensitively and treat the boolean
    // spellings as one class.
    static bool gucValueMatches( const std::string& want, const std::string& have )
    {
        const std::string w = lowerAscii( want );
        const std::string h = lowerAscii( have );
        if( w == h ) return true;
        static const std::array<const char*, 5> kTrue{ "on", "true", "t", "yes", "1" };
        static const std::array<const char*, 5> kFalse{ "off", "false", "f", "no", "0" };
        const auto in = []( const std::string& v, const std::array<const char*, 5>& opts ) {
            return std::find_if( opts.begin(), opts.end(),
                                 [&]( const char* o ) { return v == o; } ) != opts.end();
        };
        if( in( w, kTrue ) && in( h, kTrue ) ) return true;
        if( in( w, kFalse ) && in( h, kFalse ) ) return true;
        return false;
    }

    // A short, non-reversible tag of the calling client, for the refusal
    // log: enough to tell two clients apart in an incident, never the
    // credential itself.
    static std::string clientTag( const std::string& clientKey )
    {
        if( clientKey.empty() ) return std::string();
        char buf[ 24 ];
        std::snprintf( buf, sizeof buf, "c-%08zx",
                       std::hash<std::string>{}( clientKey ) & 0xffffffffu );
        return buf;
    }

    // The config-writes switch. off: no key may be written through the MCP
    // boundary. safe (the default): only the low-risk keys -- the model
    // names and the think mode -- may be; every other key is refused. all:
    // every key may be (the enterprise keys still need their own per-call
    // consent).
    //
    // The refusal names the key, says what it is set to now, and says where
    // to set it instead: the operator's own configuration, not a tool call a
    // model can make.
    static void refuseConfigWrite( Db& db, const std::string& key, const CallCtx& ctx )
    {
        // The current value is part of the refusal: a caller that wanted to
        // point the key somewhere else can see what it is now. A key this
        // session's role cannot read reports itself as unreadable rather
        // than failing the refusal.
        std::string current = "<unreadable>";
        try
        {
            const auto v = db.callScalar( "SELECT current_setting($1::text, true)", { normalizeKey( key ) } );
            if( v.has_value() ) current = *v;
        }
        catch( ... ) { /* leave it unreadable */ }
        if( isSecretKey( key ) ) current = "***";
        logging::event( "config_write_refused", Json{
            { "key", key },
            { "mode", configWritesModeName() },
            { "client", clientTag( ctx.clientKey ) } } );
        throw ToolError( ErrorClass::Schema,
            "config write refused: '" + key + "' may not be written through this tool while "
            "FSQL_MCP_CONFIG_WRITES=" + std::string( configWritesModeName() ) + ". The safe set is the "
            "chat model name (http_model), the embedding model name (http_embed_model) and the think mode "
            "(http_think); the endpoint URLs, the plaintext flag, the plugin path, the token and the "
            "enterprise keys are not in it. '" + key + "' is currently set to '" + current + "'. Set it in "
            "the server's own configuration -- the operator's postgresql.conf or the server's environment, "
            "reloaded by the operator -- instead of through this tool, or run the server with "
            "FSQL_MCP_CONFIG_WRITES=all if you really want this tool to write it." );
    }

    std::vector<ToolSpec> buildAdminTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_version", "admin", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                const auto v = db.callScalar( "SELECT fractal_version()", {} );
                const auto e = db.callScalar( "SELECT fractal_edition()", {} );
                return Json{ { "version", v.value_or( "" ) }, { "edition", e.value_or( "" ) } };
            } } );
        t.back().description = "Confirms the FractalSQL install is alive and which edition (Community/Enterprise) "
            "is active: fractal_version() and fractal_edition(). The one-line sanity check after installing; "
            "expect a real edition/version back (e.g. Community|2.0.20), plus a startup warning if the engine "
            "version differs from what this server was built against (the version-skew guard warns, never hard-fails).";

        // The config-key tools over the engine's GUCs, per-session scoped
        // (the wrappers over fractal_config_set/get —
        // keys map 1:1 onto the DefineCustom*Variable surface in src/fractalsql.c;
        // the scope is THIS session's dedicated connection instead of a file).
        t.push_back( ToolSpec{ "fractal_config_set", "admin", ToolClass::Cheap,
            { StrEnum( "key", true, "One of the documented config keys (enforced): reasoning_plugin, "
                                    "http_url, http_model, http_allow_plaintext, http_embed_url, "
                                    "http_embed_model, http_think, http_think_provider, http_native_url, "
                                    "http_num_ctx, text_to_sql_max_attempts, text_to_sql_allowed_statements, "
                                    "text_to_sql_use_review, enterprise_lib, enterprise_require_signature, "
                                    "enterprise_ledger_key, agent_partial_reasoning_fail. "
                                    "SCOPE, per key (the engine's own GUC contexts, from src/fractalsql.c): "
                                    "agent_partial_reasoning_fail is PGC_USERSET (any user, session-settable); "
                                    "enterprise_ledger_key is PGC_SUSET (superuser only -- the server's privilege "
                                    "error surfaces verbatim); the other 15 are PGC_SIGHUP (reload-scoped) and are "
                                    "changed server-side -- postgres refuses a session-level set of those "
                                    "('cannot be changed now'), so this tool writes them with ALTER SYSTEM SET + "
                                    "pg_reload_conf() and answers 'queued', because that is what they are: the "
                                    "running session keeps the value it had and the next backend picks the new "
                                    "one up. A key that DID take at session scope is verified by reading the "
                                    "value back." ),
              Str( "value", true, "The value to set (GUC spelling: on/off for booleans; integers as integers)." ),
              Bool_( "allow_secrets", false,
                     "Must be true to set an enterprise-posture key (enterprise_lib, "
                     "enterprise_require_signature, enterprise_ledger_key) through the MCP boundary: an "
                     "explicit operator intent, never a default.", false ) },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ctx ) {
                const std::string key = a.at( "key" ).get<std::string>();
                if( isEnterpriseKey( key ) && !a.value( "allow_secrets", false ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' changes the enterprise tier's library/signature/key posture: "
                        "pass allow_secrets=true to make the operator's explicit intent explicit; "
                        "a client UI prompts a human first for these changes" );
                // Compare the bare key name so both spellings are accepted.
                if( std::find_if( kKnownKeys.begin(), kKnownKeys.end(),
                                  [&]( const char* k ) { return asBareKey( key ) == k; } ) == kKnownKeys.end() )
                    throw ToolError( ErrorClass::Schema,
                        "unknown config key '" + key + "': fractal_config_set accepts the documented "
                        "keys (reasoning_plugin, http_url, http_model, http_allow_plaintext, http_embed_url, "
                        "http_embed_model, http_think, http_think_provider, http_native_url, http_num_ctx, "
                        "text_to_sql_max_attempts, text_to_sql_allowed_statements, text_to_sql_use_review, "
                        "enterprise_lib, enterprise_require_signature, enterprise_ledger_key, "
                        "agent_partial_reasoning_fail); the fractalsql.-prefixed spelling is accepted too — "
                        "and http_token is never set through the MCP boundary" );
                // The config-writes switch: a key the current mode does not
                // allow is refused BEFORE anything is changed.
                if( !configWriteAllowed( key ) )
                    refuseConfigWrite( db, key, ctx );
                const std::string guc = normalizeKey( key );
                const std::string oldVal = db.callScalar( "SELECT current_setting($1::text, true)", { guc } ).value_or( "<unset>" );
                const std::string newVal = a.at( "value" ).get<std::string>();
                // Session-scoped (set_config is_local=false): survives until THIS
                // connection closes. SCOPE honesty by VERIFICATION, not by assertion:
                // whether the server accepts a session-level set of a given GUC
                // depends on that GUC's own context (PGC_USERSET / PGC_SUSET /
                // PGC_SIGHUP / PGC_POSTMASTER), and the engine's keys span all of
                // them. The earlier shape of this tool asserted that postgres
                // rejects a session-level set on every PGC_SIGHUP key and pointed
                // the caller at ALTER SYSTEM -- an unverified claim about postgres
                // internals that also made the "did it take effect?" answer a
                // guess. So: perform the set, READ THE VALUE BACK, and report
                // what actually happened. "effective" below is a checked fact.
                // A key postgres refuses to change for the session (a
                // reload-scoped one) is written the way postgres changes it --
                // server-side, with ALTER SYSTEM SET + pg_reload_conf() -- and
                // the answer says "queued", because it is: the running session
                // keeps the value it had.
                // The failure is captured inside the catch and thrown AFTER it: a new exception thrown from
                // within a catch funclet crashes the Windows MSVC ASan runtime (__FrameHandler3::GetUnwindTryBlock).
                std::optional<ToolError> setFailed;
                try
                {
                    db.callScalar( "SELECT set_config($1::text, $2::text, false)", { guc, newVal } );
                }
                catch( const ToolError& e )
                {
                    setFailed = e;
                }
                if( setFailed )
                {
                    if( setFailed->message.find( "cannot be changed now" ) == std::string::npos )
                        throw *setFailed;
                    // A reload-scoped key (PGC_SIGHUP) cannot be changed for
                    // the session: postgres changes it server-side and hands
                    // it to the next backend. The operator's config-writes
                    // switch has already decided that this key MAY be
                    // written, so the write happens the only way postgres
                    // allows -- server-side -- and the answer says plainly
                    // that it is queued rather than live.
                    db.callScalar( "ALTER SYSTEM SET " + guc + " = " + quoteDouble( newVal ), {} );
                    db.callScalar( "SELECT pg_reload_conf()", {} );
                    logging::configChange( guc, isSecretKey( key ) ? "***" : oldVal, isSecretKey( key ) ? "***" : newVal );
                    return Json{ { "key", guc },
                                 { "old", isSecretKey( key ) ? Json( "***" ) : Json( oldVal ) },
                                 { "new", isSecretKey( key ) ? Json( "***" ) : Json( newVal ) },
                                 { "effective", false },
                                 { "scope", "server-wide (ALTER SYSTEM SET + pg_reload_conf(): the value is "
                                            "written to the server's configuration and is handed to the "
                                            "next backend/session -- this session's own value is unchanged)" },
                                 { "status", "queued; takes effect on the next backend/session "
                                             "(pg_reload_conf is async)" } };
                }
                // Read-back: a silent no-op must never be reported as success.
                const auto back = db.callScalar( "SELECT current_setting($1::text, true)", { guc } );
                const std::string applied = back.value_or( "<unset>" );
                if( !gucValueMatches( newVal, applied ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + guc + "' was set but still reads '" + applied + "': the value did not stick at "
                        "session scope -- for a reload-scoped (PGC_SIGHUP) key use ALTER SYSTEM SET + "
                        "pg_reload_conf() (or the operator's postgresql.conf) instead" );
                // Every successful admin-config call is logged with old and new value,
                // so a silent endpoint swap (http_url repointed at an attacker endpoint,
                // where every subsequent reasoning call sends prompts and embeddings)
                // is catchable after the fact. Secret values are redacted in the log.
                logging::configChange( guc, isSecretKey( key ) ? "***" : oldVal, isSecretKey( key ) ? "***" : newVal );
                return Json{ { "key", guc },
                             { "old", isSecretKey( key ) ? Json( "***" ) : Json( oldVal ) },
                             { "new", isSecretKey( key ) ? Json( "***" ) : Json( newVal ) },
                             { "effective", true },
                             { "scope", "per-session (THIS MCP session's dedicated PostgreSQL connection only: "
                                        "set_config(..., false) state does not survive the connection)" },
                             { "note", "session scope only: the value is NOT written to postgresql.conf and does "
                                       "not survive this connection; a backend that has already loaded the engine's "
                                       "reasoning/embedding context keeps the values it captured, and "
                                       "fractalsql.enterprise_lib additionally cannot be re-pointed while a "
                                       "library is already loaded (the engine refuses that at use time)" } };
            } } );
        t.back().description = "Sets a config key to a value (the PostgreSQL column's wrapper over the engine's "
            "fractalsql.* GUCs for the documented keys: reasoning plugin path, http_url/http_embed_url, models, "
            "think knobs, text-to-sql keys, agent partial-failure mode). SCOPE honesty by VERIFICATION: the tool "
            "performs the set and then READS THE VALUE BACK -- 'effective' is a checked fact, never a claim. Two of "
            "the seventeen keys are session-settable (agent_partial_reasoning_fail, PGC_USERSET, any user; "
            "enterprise_ledger_key, PGC_SUSET, superuser only -- the server's privilege error surfaces verbatim) "
            "and are changed for THIS session only. The other fifteen are PGC_SIGHUP: postgres refuses a "
            "session-level set of those ('cannot be changed now'), so this tool writes them the way postgres "
            "changes them -- ALTER SYSTEM SET + pg_reload_conf() -- and answers 'queued', because that is what "
            "they are: the running session keeps the value it had, the next backend picks the new one up. "
            "destructiveHint-flagged: repointing http_url/http_embed_url redirects every subsequent "
            "reasoning/embedding dispatch on reload; a client UI that honors annotations will prompt a human first. "
            "The secret GUC http_token is NEVER set through the MCP boundary; enterprise-posture keys require "
            "allow_secrets=true. "
            "Config writes are governed by the server's own switch (FSQL_MCP_CONFIG_WRITES): off refuses every key, "
            "safe (the default) allows only the model names and the think mode, all allows every documented key. "
            "A refused key is not changed at all, and the refusal names the key, its current value and where to "
            "set it instead.";
        t.back().secretHint = true;   // credential-shaped values pass through even though logs redact

        t.push_back( ToolSpec{ "fractal_config_get", "admin", ToolClass::Cheap,
            { Str( "key", true, "Config key to read back (engine-key or fractalsql.-prefixed spelling)." ) }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string key = a.at( "key" ).get<std::string>();
                // The secret check covers both spellings of the key.
                if( isSecretKey( key ) || isSecretKey( normalizeKey( key ) ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is a secret and is never read back through any MCP tool or "
                        "resource; check the operator-side postgresql.conf / environment that set it" );
                const std::string guc = normalizeKey( key );
                if( guc.rfind( "fractalsql.", 0 ) == 0 &&
                    std::find_if( kKnownKeys.begin(), kKnownKeys.end(),
                                  [&]( const char* k ) { return guc == normalizeKey( k ); } ) == kKnownKeys.end() )
                    throw ToolError( ErrorClass::Schema, "unknown config key '" + key + "'" );
                const auto val = db.callScalar( "SELECT current_setting($1::text, true)", { guc } );
                // current_setting(missing_ok=true) returns NULL for an unset GUC.
                return Json{ { "key", guc },
                             { "value", val.has_value() && !val->empty() ? Json( *val ) : Json( nullptr ) },
                             { "scope", "per-session (THIS MCP session's dedicated PostgreSQL connection)" } };
            } } );
        t.back().description = "Reads back a config key's resolved value on THIS session's connection (the "
            "PostgreSQL column's wrapper over current_setting()). Secrets (http_token, enterprise_ledger_key) "
            "are refused: they are never read back through any tool or resource. Unset keys return null. "
            "Values read back reflect the resolved (config-file + reload) state for reload-scoped keys. "
            "The whole fractalsql.http_* provider family (url, token, model, embed_url, embed_model, think, "
            "think_provider, native_url, num_ctx, allow_plaintext) is superuser-only in the engine -- a "
            "non-superuser session gets the server's privilege error verbatim for those keys, exactly as it "
            "does for the other superuser-only settings.";

        t.push_back( ToolSpec{ "fractal_configure_reasoning", "admin", ToolClass::Cheap,
            { Str("provider_url",false,"Chat endpoint URL (e.g. http://127.0.0.1:11434/v1/chat/completions for ollama, or an OpenAI-compatible /v1/chat/completions)."),
              Str("embed_url",false,"Embeddings endpoint URL (e.g. .../v1/embeddings); a distinct path from chat."),
              Str("model",false,"Chat model name (e.g. gpt-oss:20b, gpt-4o-mini)."),
              Str("embed_model",false,"Embedding model name (e.g. nomic-embed-text); never reuse a chat model here."),
              ToolParam{ "allow_plaintext", JsonType::Boolean, false, nullptr,
                         "Allow plaintext http:// endpoints (needed for local Ollama).", false },
              Str("think_mode",false,"Reasoning effort for hybrid-thinker models: unset/none (model default), 'off', or any provider-verbatim value (low/medium/high/...).") },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ctx ) {
                // Collect EVERY requested field FIRST: a call that names a key
                // the current mode refuses must change NOTHING, so the
                // refusal has to happen before the first ALTER SYSTEM.
                std::vector<std::pair<std::string, std::string>> pending;
                for( auto& [ field, guc ] : kFieldMap )
                {
                    if( !a.contains( field ) || a.at( field ).is_null() ) continue;
                    const std::string newVal = std::string( field ) == "allow_plaintext"
                        ? ( a.at( field ).get<bool>() ? "on" : "off" )
                        : a.at( field ).get<std::string>();
                    pending.emplace_back( std::string( guc ), newVal );
                }
                if( pending.empty() ) throw ToolError( ErrorClass::Schema, "nothing to set — supply at least one field" );
                // The config-writes switch: refuse before anything is changed.
                for( const auto& p : pending )
                    if( !configWriteAllowed( p.first ) )
                        refuseConfigWrite( db, p.first, ctx );
                Json updated = Json::object();
                for( const auto& p : pending )
                {
                    const std::string guc = p.first;
                    const std::string newVal = p.second;
                    std::string oldVal;
                    {
                        const auto old = db.callScalar( "SELECT current_setting($1::text, true)", { guc } );
                        oldVal = old.value_or( "<unset>" );
                    }
                    // ALTER SYSTEM SET <allowlisted-guc> = '<value-with-doubled-quotes>' —
                    // the value text itself is plain data; quote doubling is the only
                    // rendering step and cannot terminate early (every ' becomes '').
                    db.callScalar( "ALTER SYSTEM SET " + guc + " = " + quoteDouble( newVal ), {} );
                    logging::configChange( guc, oldVal, newVal );
                    updated[ guc ] = newVal;
                }
                db.callScalar( "SELECT pg_reload_conf()", {} );
                // 5.1's async-reload caveat, VERBATIM in the result — never claim liveness.
                return Json{ { "updated", updated },
                             { "status", "queued; takes effect on the next backend/session (pg_reload_conf is async; some GUCs are SIGHUP-scoped)" } };
            } } );
        t.back().description = "Configure the reasoning/embedding provider via ALTER SYSTEM SET + pg_reload_conf(). "
            "NEVER claims the change is live immediately — states 'queued' per the documented async-reload caveat. "
            "NEVER touches enterprise_lib/enterprise_ledger_key/enterprise_require_signature — enabling or "
            "disabling the enterprise tier is an operator action against Postgres, never an MCP client action. "
            "Config writes are governed by the server's own switch (FSQL_MCP_CONFIG_WRITES): off refuses every key, "
            "safe (the default) allows only the model names and the think mode, all allows every provider key. "
            "A call that names a refused key changes NOTHING at all.";
        t.back().secretHint = true;   // credential-shaped values pass through even though logs redact

        return t;
    }
}