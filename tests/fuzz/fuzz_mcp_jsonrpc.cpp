// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// libFuzzer entry point for the MCP server's JSON-RPC front door:
// JsonRpcServer::handleLine, the function both transports hand every
// client line to. The server is built once with two stub tools (one cheap,
// one expensive) so initialize, tools/list, tools/call argument validation,
// resources, prompts and cancellation are all reachable without a database.
//
// The input is one raw protocol line. Any reply, including an error
// response, is fine; a crash, hang or sanitizer report is the finding.
//
// Built and run by the MCP fuzz gate (49) of build_test.sh and build_test.ps1.
#include "jsonrpc_server.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace fsqlmcp;

static JsonRpcServer& server()
{
    static JsonRpcServer* s = []
    {
        // Keep stderr quiet: the server logs every call.
        logging::init( { logging::Level::Info } );
        std::vector<ToolSpec> tools;
        ToolSpec cheap;
        cheap.name = "fuzz_cheap";
        cheap.category = "fuzz";
        cheap.toolClass = ToolClass::Cheap;
        cheap.params = {
            { "text", JsonType::String, true, nullptr, "a string" },
            { "n", JsonType::Integer, false, 3, "an integer" },
            { "v", JsonType::Array, false, nullptr, "an array" },
        };
        cheap.readOnlyHint = true;
        cheap.destructiveHint = false;
        cheap.description = "fuzz stub";
        cheap.handler = []( const Json& args, CallCtx& ) { return Json{ { "echo", args } }; };
        tools.push_back( cheap );
        ToolSpec costly = cheap;
        costly.name = "fuzz_expensive";
        costly.toolClass = ToolClass::Expensive;
        costly.destructiveHint = true;
        costly.readOnlyHint = false;
        tools.push_back( costly );
        return new JsonRpcServer( ServerConfig{}, std::move( tools ), ConcurrencyConfig{} );
    }();
    return *s;
}

extern "C" int LLVMFuzzerTestOneInput( const uint8_t* data, size_t size )
{
    const std::string line( reinterpret_cast<const char*>( data ), size );
    try
    {
        ( void ) server().handleLine( line, "fuzz" );
    }
    catch( const std::exception& ) {}
    return 0;
}

// FSQL_FUZZ_STANDALONE: a driver with no libFuzzer, for Windows. libFuzzer's runtime breaks
// C++ exception objects in clang's Windows build (a caught std::runtime_error reads back a bad
// what()), so this target is built as a plain executable instead. It replays every input from the
// corpus directories and files given, then, for -max_total_time=N (or -runs=N), mutates corpus
// entries at random. Not coverage-guided; the Linux build keeps the real libFuzzer run. Other
// libFuzzer-style flags are accepted and ignored so the caller's command line is the same.
#ifdef FSQL_FUZZ_STANDALONE
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>

namespace
{
    using Bytes = std::vector<uint8_t>;

    Bytes slurp( const std::filesystem::path& p )
    {
        std::ifstream f( p, std::ios::binary );
        return Bytes( std::istreambuf_iterator<char>( f ), std::istreambuf_iterator<char>() );
    }

    void run( const Bytes& d )
    {
        static const uint8_t none = 0;
        LLVMFuzzerTestOneInput( d.empty() ? &none : d.data(), d.size() );
    }

    void mutate( Bytes& d, const std::vector<Bytes>& corpus, std::mt19937_64& rng )
    {
        auto r = [ & ]( size_t n ) { return n ? static_cast<size_t>( rng() % n ) : size_t( 0 ); };
        static const char* const tokens[] = { "0", "-1", "2147483647", "9223372036854775807", "null",
                                              "[]", "{}", "\"\"", "1e999", "true" };
        for( size_t rounds = 1 + r( 4 ); rounds; --rounds )
        {
            switch( r( 7 ) )
            {
                case 0: if( !d.empty() ) d[ r( d.size() ) ] ^= static_cast<uint8_t>( 1u << r( 8 ) ); break;
                case 1: if( !d.empty() ) d[ r( d.size() ) ] = static_cast<uint8_t>( rng() ); break;
                case 2: d.insert( d.begin() + r( d.size() + 1 ), static_cast<uint8_t>( rng() ) ); break;
                case 3: if( !d.empty() ) d.erase( d.begin() + r( d.size() ) ); break;
                case 4:
                    if( !corpus.empty() )
                    {
                        const Bytes& o = corpus[ r( corpus.size() ) ];
                        if( !o.empty() )
                        {
                            const size_t from = r( o.size() ), n = 1 + r( o.size() - from );
                            d.insert( d.begin() + r( d.size() + 1 ), o.begin() + from, o.begin() + from + n );
                        }
                    }
                    break;
                case 5:
                {
                    const char* t = tokens[ r( 10 ) ];
                    d.insert( d.begin() + r( d.size() + 1 ), t, t + std::strlen( t ) );
                    break;
                }
                default: if( d.size() > 1 ) std::swap( d[ r( d.size() ) ], d[ r( d.size() ) ] ); break;
            }
        }
        if( d.size() > 4096 ) d.resize( 4096 );
    }
}

int main( int argc, char** argv )
{
    namespace fs = std::filesystem;
    double maxTime = 0;
    long runs = -1;
    std::vector<Bytes> corpus;
    for( int i = 1; i < argc; ++i )
    {
        const std::string a = argv[ i ];
        if( a.rfind( "-max_total_time=", 0 ) == 0 ) { maxTime = std::atof( a.c_str() + 16 ); continue; }
        if( a.rfind( "-runs=", 0 ) == 0 )           { runs = std::atol( a.c_str() + 6 ); continue; }
        if( !a.empty() && a[ 0 ] == '-' ) continue;
        std::error_code ec;
        if( fs::is_directory( a, ec ) )
        {
            for( const auto& e : fs::directory_iterator( a, ec ) )
                if( e.is_regular_file() ) corpus.push_back( slurp( e.path() ) );
        }
        else if( fs::is_regular_file( a, ec ) )
            corpus.push_back( slurp( a ) );
    }

    run( Bytes() );
    if( runs == 0 ) return 0;
    for( const Bytes& d : corpus ) run( d );
    unsigned long executed = corpus.size() + 1;

    if( maxTime > 0 || runs > 0 )
    {
        const auto seed = std::random_device{}();
        std::fprintf( stderr, "standalone mutator: seed %u, %zu corpus inputs\n", seed, corpus.size() );
        std::mt19937_64 rng( seed );
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>( maxTime );
        for( long n = 0; ( runs < 0 || n < runs ) && ( maxTime <= 0 || std::chrono::steady_clock::now() < deadline ); ++n )
        {
            Bytes d = corpus.empty() ? Bytes() : corpus[ rng() % corpus.size() ];
            mutate( d, corpus, rng );
            run( d );
            ++executed;
        }
    }
    std::fprintf( stderr, "standalone mutator: %lu inputs run, no crash\n", executed );
    return 0;
}
#endif
