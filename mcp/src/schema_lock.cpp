#include "schema_lock.h"
#include <openssl/evp.h>
#include <fstream>
#include <algorithm>

namespace fsqlmcp
{
    static OrderedJson sortKeysRecursive( const Json& v )
    {
        if( v.is_object() )
        {
            std::vector<std::string> keys;
            for( auto it = v.begin(); it != v.end(); ++it ) keys.push_back( it.key() );
            std::sort( keys.begin(), keys.end() );
            OrderedJson out = OrderedJson::object();
            for( const std::string& k : keys )
                out[ k ] = sortKeysRecursive( v.at( k ) );
            return out;
        }
        if( v.is_array() )
        {
            OrderedJson out = OrderedJson::array();
            for( const Json& e : v ) out.push_back( sortKeysRecursive( e ) );
            return out;
        }
        return v;
    }

    std::string computeSchemaHash( const std::vector<ToolSpec>& tools )
    {
        Json projection = Json::object();
        for( const ToolSpec& t : tools )
        {
            Json annotations = toolAnnotations( t );
            if( t.retryTier )       annotations[ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );

            projection[ std::string( t.name ) ] = Json{
                { "category", std::string( t.category ) },
                { "toolClass", t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" },
                { "description", t.description },
                { "annotations", annotations },
                { "inputSchema", buildInputSchema( t ) }
            };
        }
        const std::string canonical = sortKeysRecursive( projection ).dump( -1 );

        unsigned char digest[ EVP_MAX_MD_SIZE ]; unsigned int len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr );
        EVP_DigestUpdate( ctx, canonical.data(), canonical.size() );
        EVP_DigestFinal_ex( ctx, digest, &len );
        EVP_MD_CTX_free( ctx );

        static const char* const kHex = "0123456789abcdef";
        std::string hex;
        for( unsigned int i = 0; i < len; ++i )
        {
            hex.push_back( kHex[ digest[ i ] >> 4 ] );
            hex.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return hex;
    }

    LockCheckResult checkSchemaLock( const std::string& lockFilePath, const std::string& computedHash,
                                       std::string* expectedOut )
    {
        std::ifstream in( lockFilePath );
        if( !in )
            return LockCheckResult::Absent;    // dev-mode friendly — not a failure
        std::string expected;
        std::getline( in, expected );
        // \r-tolerant: an artifact written on Windows in text mode carries
        // CRLF; a hash string read from there must compare equal to the
        // computed one regardless of the writer's platform.
        while( !expected.empty() && expected.back() == '\r' ) expected.pop_back();
        if( expectedOut ) *expectedOut = expected;
        return ( expected == computedHash ) ? LockCheckResult::Ok : LockCheckResult::Warn;
    }

    void writeSchemaLock( const std::string& lockFilePath, const std::string& computedHash )
    {
        // BINARY mode: the pin stays canonical-LF byte-identical on every
        // platform (text mode would write CRLF on Windows).
        std::ofstream out( lockFilePath, std::ios::trunc | std::ios::binary );
        out << computedHash << '\n';
    }
}