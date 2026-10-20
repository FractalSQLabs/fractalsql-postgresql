#include "admin.h"
#include "../db.h"
#include "../vectors.h"
#include "../logging.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <optional>

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

    std::vector<ToolSpec> buildAdminTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractalsql_get_version", "admin", ToolClass::Cheap, {}, std::nullopt, false, true,
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
        // (POSTGRES analog of the SQLite column's fractalsql_set/get wrappers —
        // keys map 1:1 onto the DefineCustom*Variable surface in src/fractalsql.c;
        // the scope is THIS session's dedicated connection instead of a file).
        t.push_back( ToolSpec{ "fractalsql_set_config", "admin", ToolClass::Cheap,
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
                                    "ALTER SYSTEM-only -- the server refuses a session-level set of those outright "
                                    "('cannot be changed now'), so this tool reports that as a clean error naming "
                                    "the ALTER SYSTEM + pg_reload_conf() path (fractalsql_configure_reasoning does "
                                    "exactly that for the provider keys) instead of claiming a change took effect. "
                                    "A key that DID take is verified by reading the value back." ),
              Str( "value", true, "The value to set (GUC spelling: on/off for booleans; integers as integers)." ),
              Bool_( "allow_secrets", false,
                     "Must be true to set an enterprise-posture key (enterprise_lib, "
                     "enterprise_require_signature, enterprise_ledger_key) through the MCP boundary: an "
                     "explicit operator intent, never a default.", false ) },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
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
                        "unknown config key '" + key + "': fractalsql_set_config accepts the documented "
                        "keys (reasoning_plugin, http_url, http_model, http_allow_plaintext, http_embed_url, "
                        "http_embed_model, http_think, http_think_provider, http_native_url, http_num_ctx, "
                        "text_to_sql_max_attempts, text_to_sql_allowed_statements, text_to_sql_use_review, "
                        "enterprise_lib, enterprise_require_signature, enterprise_ledger_key, "
                        "agent_partial_reasoning_fail); the fractalsql.-prefixed spelling is accepted too — "
                        "and http_token is never set through the MCP boundary" );
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
                try
                {
                    db.callScalar( "SELECT set_config($1::text, $2::text, false)", { guc, newVal } );
                }
                catch( const ToolError& e )
                {
                    if( e.message.find( "cannot be changed now" ) != std::string::npos )
                        throw ToolError( ErrorClass::Schema,
                            "'" + guc + "' is not session-settable (a reload-scoped key: it is changed "
                            "server-side, not per session): set it via ALTER SYSTEM SET + "
                            "pg_reload_conf() -- the fractalsql_configure_reasoning admin tool does "
                            "exactly that for the provider keys -- or the operator's postgresql.conf" );
                    throw;
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
        t.back().description = "Sets a config key to a value for THIS session (the PostgreSQL column's wrapper "
            "over set_config(key, value, false) on the engine's fractalsql.* GUCs for the documented keys: "
            "reasoning plugin path, http_url/http_embed_url, models, think knobs, text-to-sql keys, agent "
            "partial-failure mode). SCOPE honesty by VERIFICATION: the tool performs the session-level set and then "
            "READS THE VALUE BACK -- 'effective' is a checked fact, never a claim. Two of the seventeen keys are "
            "session-settable: agent_partial_reasoning_fail (PGC_USERSET, any user) and enterprise_ledger_key "
            "(PGC_SUSET, superuser only -- the server's privilege error surfaces verbatim). The other fifteen are "
            "PGC_SIGHUP and are ALTER SYSTEM-only: the server refuses a session-level set of those outright ('cannot "
            "be changed now'), and this tool turns that refusal into a clean error naming the ALTER SYSTEM + "
            "pg_reload_conf() path (fractalsql_configure_reasoning does exactly that for the provider keys) "
            "instead of claiming a change took effect. "
            "destructiveHint-flagged: repointing http_url/http_embed_url redirects every subsequent "
            "reasoning/embedding dispatch on reload; a client UI that honors annotations will prompt a human first. "
            "The secret GUC http_token is NEVER set through the MCP boundary; enterprise-posture keys require "
            "allow_secrets=true.";
        t.back().secretHint = true;   // credential-shaped values pass through even though logs redact

        t.push_back( ToolSpec{ "fractalsql_get_config", "admin", ToolClass::Cheap,
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

        t.push_back( ToolSpec{ "fractalsql_configure_reasoning", "admin", ToolClass::Cheap,
            { NullableStr("provider_url","Chat endpoint URL (e.g. http://127.0.0.1:11434/v1/chat/completions for ollama, or an OpenAI-compatible /v1/chat/completions)."),
              NullableStr("embed_url","Embeddings endpoint URL (e.g. .../v1/embeddings); a distinct path from chat."),
              NullableStr("model","Chat model name (e.g. gpt-oss:20b, gpt-4o-mini)."),
              NullableStr("embed_model","Embedding model name (e.g. nomic-embed-text); never reuse a chat model here."),
              ToolParam{ "allow_plaintext", JsonType::Boolean, false, nullptr,
                         "Allow plaintext http:// endpoints (needed for local Ollama).", true },
              NullableStr("think_mode","Reasoning effort for hybrid-thinker models: unset/none (model default), 'off', or any provider-verbatim value (low/medium/high/...).") },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                bool any = false;
                Json updated = Json::object();
                for( auto& [ field, guc ] : kFieldMap )
                {
                    if( !a.contains( field ) || a.at( field ).is_null() ) continue;
                    any = true;
                    const std::string newVal = std::string( field ) == "allow_plaintext"
                        ? ( a.at( field ).get<bool>() ? "on" : "off" )
                        : a.at( field ).get<std::string>();
                    std::string oldVal;
                    {
                        const auto old = db.callScalar( "SELECT current_setting($1::text, true)", { std::string( guc ) } );
                        oldVal = old.value_or( "<unset>" );
                    }
                    // ALTER SYSTEM SET <allowlisted-guc> = '<value-with-doubled-quotes>' —
                    // the value text itself is plain data; quote doubling is the only
                    // rendering step and cannot terminate early (every ' becomes '').
                    db.callScalar( "ALTER SYSTEM SET " + std::string( guc ) + " = " + quoteDouble( newVal ), {} );
                    logging::configChange( guc, oldVal, newVal );
                    updated[ guc ] = newVal;
                }
                if( !any ) throw ToolError( ErrorClass::Schema, "nothing to set — supply at least one field" );
                db.callScalar( "SELECT pg_reload_conf()", {} );
                // 5.1's async-reload caveat, VERBATIM in the result — never claim liveness.
                return Json{ { "updated", updated },
                             { "status", "queued; takes effect on the next backend/session (pg_reload_conf is async; some GUCs are SIGHUP-scoped)" } };
            } } );
        t.back().description = "Configure the reasoning/embedding provider via ALTER SYSTEM SET + pg_reload_conf(). "
            "NEVER claims the change is live immediately — states 'queued' per the documented async-reload caveat. "
            "NEVER touches enterprise_lib/enterprise_ledger_key/enterprise_require_signature — enabling or "
            "disabling the enterprise tier is an operator action against Postgres, never an MCP client action.";
        t.back().secretHint = true;   // credential-shaped values pass through even though logs redact

        return t;
    }
}