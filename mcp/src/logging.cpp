#include "logging.h"
#include <openssl/evp.h>
#include <cstdio>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <ctime>
#include <mutex>

namespace fsqlmcp::logging
{
    static Config g_cfg;

    void init( const Config& cfg ) { g_cfg = cfg; }

    static std::string sha256_8( const std::string& s )
    {
        unsigned char digest[ EVP_MAX_MD_SIZE ];
        unsigned int  len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr );
        EVP_DigestUpdate( ctx, s.data(), s.size() );
        EVP_DigestFinal_ex( ctx, digest, &len );
        EVP_MD_CTX_free( ctx );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 4 && static_cast<unsigned>( i ) < len; ++i )
        {
            out.push_back( kHex[ digest[ i ] >> 4 ] );
            out.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return out;
    }

    static bool looksSecretKey( const std::string& key )
    {
        std::string lower = key;
        std::transform( lower.begin(), lower.end(), lower.begin(),
                         []( unsigned char c ) { return std::tolower( c ); } );
        for( const char* needle : { "token", "password", "key", "secret" } )
            if( lower.find( needle ) != std::string::npos )
                return true;
        return false;
    }

    Json redactAndCap( const Json& v, int depth )
    {
        if( v.is_object() )
        {
            if( depth >= 2 )
                return Json( "<object>" );
            Json out = Json::object();
            for( auto it = v.begin(); it != v.end(); ++it )
                out[ it.key() ] = looksSecretKey( it.key() ) ? Json( "***" )
                                                              : redactAndCap( it.value(), depth + 1 );
            return out;
        }
        if( v.is_array() )
        {
            const std::string dump = v.dump();
            return Json( "<array len=" + std::to_string( v.size() ) + " sha256_8=" + sha256_8( dump ) + ">" );
        }
        if( v.is_string() )
        {
            const std::string& s = v.get_ref<const std::string&>();
            if( s.size() > 256 )
                return Json( "<str len=" + std::to_string( s.size() ) + " sha256_8=" + sha256_8( s ) + ">" );
            return v;
        }
        return v;
    }

    // ISO-8601 UTC stamp for every log line. Without it a stderr line carries
    // no ordering information at all across the HTTP transport's one-thread-
    // per-connection model, and correlating a client-visible failure with the
    // server's own log is guesswork. UTC (gmtime), so lines from hosts in
    // different zones stay comparable.
    static std::string nowIso()
    {
        const std::time_t now = std::time( nullptr );
        std::tm tmv{};
#if defined( _WIN32 )
        gmtime_s( &tmv, &now );
#else
        gmtime_r( &now, &tmv );
#endif
        char buf[ 32 ] = { 0 };
        std::strftime( buf, sizeof( buf ), "%Y-%m-%dT%H:%M:%SZ", &tmv );
        return std::string( buf );
    }

    // Process-wide stderr lock: the HTTP transport runs a thread per
    // connection and stderr's own locking does NOT make a multi-call write
    // atomic — two threads interleaving fputs/fputc tear the JSON line in
    // half, and a torn line is unparseable exactly when it matters (a crash
    // post-mortem). One mutex around the whole line, not per call.
    static std::mutex g_stderrMu;

    static void emitLine( const Json& line )
    {
        // "ts" is added here (not at each call site) so EVERY line carries
        // it, including the ones the generic event/config paths build.
        Json out{ { "ts", nowIso() } };
        if( line.is_object() )
            for( auto it = line.begin(); it != line.end(); ++it ) out[ it.key() ] = it.value();
        std::lock_guard<std::mutex> lk( g_stderrMu );
        std::fputs( out.dump().c_str(), stderr );
        std::fputc( '\n', stderr );
        std::fflush( stderr );
    }

    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                    double latencyMs, const char* errorClassOrNull )
    {
        if( static_cast<int>( g_cfg.level ) < static_cast<int>( Level::Info ) )
            return;
        Json line{
            { "event", "tool_call" },
            { "tool", std::string( toolName ) },
            { "latency_ms", latencyMs }
        };
        if( errorClassOrNull )
            line[ "error_class" ] = errorClassOrNull;
        if( g_cfg.level == Level::Debug || ( errorClassOrNull && std::string_view( errorClassOrNull ) == "schema" ) )
            line[ "args" ] = argsRedactedCapped;   // 13.6's verbose fix: args actually wired through at verbose level
        emitLine( line );
    }

    void configChange( std::string_view key, std::string_view oldValueRedacted, std::string_view newValueRedacted )
    {
        emitLine( Json{
            { "event", "config_change" }, { "key", std::string( key ) },
            { "old", std::string( oldValueRedacted ) }, { "new", std::string( newValueRedacted ) }
        } );
    }

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail )
    {
        emitLine( Json{ { "event", "exception" }, { "where", std::string( where ) },
                         { "detail", std::string( sanitizedDetail ) }, { "level", "error" } } );
    }

    // Generic structured event, e.g. schema_lock_ok. The entries of `fields`
    // are merged at the top level of the log line.
    void event( std::string_view name, const Json& fields )
    {
        Json line{ { "event", std::string( name ) } };
        if( fields.is_object() )
            for( auto it = fields.begin(); it != fields.end(); ++it ) line[ it.key() ] = it.value();
        emitLine( line );
    }
}