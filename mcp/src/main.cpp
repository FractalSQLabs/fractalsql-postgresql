// fractalsql-postgresql-mcp — entrypoint (14.1 template filled for libpq).
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <iostream>
#include <fstream>
#include <memory>
#include <algorithm>
#ifdef _WIN32
// WIN32_LEAN_AND_MEAN keeps <windows.h> from pulling in the legacy
// <winsock.h>, which conflicts with Winsock 2 and with the JSON header. Only
// GetModuleFileNameA is needed from the Windows API here.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <unistd.h>
#endif
#include "jsonrpc_server.h"
#include "transport_stdio.h"
#include "transport_http.h"
#include "schema_lock.h"
#include "safety_lock.h"
#include "logging.h"
#include "db.h"
#include "tools_catalog.h"

using namespace fsqlmcp;

#ifndef FSQL_MCP_VERSION
#define FSQL_MCP_VERSION "2.0.20"
#endif

static std::string envOr( const char* name, const std::string& def )
{
    const char* v = std::getenv( name );
    // An empty variable counts as unset (an empty value is almost always an
    // unset interpolation in a compose file or shell profile).
    return ( v && *v ) ? std::string( v ) : def;
}
static int envIntOr( const char* name, int def )
{
    const char* v = std::getenv( name );
    return ( v && *v ) ? std::atoi( v ) : def;
}
// Boolean env knob: "true", "1", "on" or "yes", case-insensitive.
static bool envBoolOr( const char* name, bool def )
{
    const char* v = std::getenv( name );
    if( !v || !*v ) return def;
    std::string s( v );
    std::transform( s.begin(), s.end(), s.begin(),
                    []( unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
    return s == "true" || s == "1" || s == "on" || s == "yes";
}
// Comma-separated list; surrounding spaces/tabs are trimmed and empty items
// dropped, so "--tool a, b" means {a, b}. (Without the trim, " b" matched no
// tool and the filter silently served an EMPTY catalog.)
static std::vector<std::string> splitCsv( const std::string& s )
{
    std::vector<std::string> out;
    std::string cur;
    const auto flush = [ & ]() {
        const std::size_t b = cur.find_first_not_of( " \t" );
        if( b != std::string::npos )
            out.push_back( cur.substr( b, cur.find_last_not_of( " \t" ) - b + 1 ) );
        cur.clear();
    };
    for( char c : s )
    {
        if( c == ',' ) { flush(); continue; }
        cur.push_back( c );
    }
    flush();
    return out;
}

// Narrows the served catalog by category (--category / FSQL_MCP_ENABLED_CATEGORIES)
// and/or tool name (--tool / FSQL_MCP_TOOL_WHITELIST).
static std::vector<ToolSpec> filterTools( std::vector<ToolSpec> tools,
                                            const std::vector<std::string>& enabledCategories,
                                            const std::vector<std::string>& toolWhitelist )
{
    if( enabledCategories.empty() && toolWhitelist.empty() ) return tools;
    // Category names match case-insensitively ("Discovery" and "discovery").
    std::vector<std::string> wantCats;
    wantCats.reserve( enabledCategories.size() );
    for( const std::string& c : enabledCategories )
    {
        std::string l = c;
        std::transform( l.begin(), l.end(), l.begin(),
                        []( unsigned char ch ) { return static_cast<char>( std::tolower( ch ) ); } );
        wantCats.push_back( l );
    }
    std::vector<ToolSpec> out;
    for( ToolSpec& t : tools )
    {
        std::string cat( t.category );   // direct-init: the string_view->string
                                        // conversion is explicit in libstdc++,
                                        // so copy-init here breaks the g++ build
        std::transform( cat.begin(), cat.end(), cat.begin(),
                        []( unsigned char ch ) { return static_cast<char>( std::tolower( ch ) ); } );
        const bool categoryOk = wantCats.empty() ||
            std::find( wantCats.begin(), wantCats.end(), cat ) != wantCats.end();
        const bool nameOk = toolWhitelist.empty() ||
            std::find( toolWhitelist.begin(), toolWhitelist.end(), std::string( t.name ) ) != toolWhitelist.end();
        if( categoryOk && nameOk ) out.push_back( std::move( t ) );
    }
    return out;
}

static char g_selfPathBuf[ 4096 ];
static std::string selfDir()
{
#ifdef _WIN32
    const DWORD n = GetModuleFileNameA( nullptr, g_selfPathBuf, sizeof( g_selfPathBuf ) );
    if( n == 0 || n >= sizeof( g_selfPathBuf ) ) return ".";
#else
    const ssize_t n = readlink( "/proc/self/exe", g_selfPathBuf, sizeof( g_selfPathBuf ) - 1 );
    if( n <= 0 ) return ".";
    g_selfPathBuf[ n ] = '\0';
#endif
    std::string p( g_selfPathBuf );
    const std::size_t slash = p.find_last_of( "\\/" );
    return slash == std::string::npos ? std::string( "." ) : p.substr( 0, slash );
}

static void usage()
{
    std::cout <<
        "fractalsql-postgresql-mcp " << FSQL_MCP_VERSION <<
        ", the FractalSQL for PostgreSQL MCP server\n"
        "\n"
        "Runs as an MCP server over stdio by default (one JSON-RPC 2.0 message per line).\n"
        "Connect env: FSQL_MCP_PG_CONN_URI (or the standard PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE).\n"
        "\n"
        "Flags:\n"
        "  --version                        print the server version and exit\n"
        "  --write-schema-lock              regenerate mcp/.mcp-schema-lock and exit\n"
        "  --schema-lock-path PATH          override the lock file path\n"
        "  --write-safety-annotations-lock  regenerate mcp/.mcp-safety-annotations-lock and exit\n"
        "  --safety-lock-path PATH          override the safety-annotation lock file path\n"
        "  --write-manifest                 regenerate mcp/manifest.json and exit\n"
        "  --list-tools                     print the full catalog (name, category) and exit\n"
        "  --tool a,b,c                     serve only these tools\n"
        "  --category x,y                   serve only these categories\n"
        "  --http [PORT]                    run the HTTP transport (default 8765; needs an env auth token)\n"
        "  --https [PORT]                   run the HTTP transport with direct TLS (needs --tls-cert/\n"
        "                                   --tls-key or FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE;\n"
        "                                   default OFF — TLS terminating in front via a reverse proxy\n"
        "                                   remains the documented zero-config posture)\n"
        "  --host H, --path P               HTTP/HTTPS transport host/path\n"
        "  --tls-cert PATH, --tls-key PATH  PEM certificate / unencrypted PEM private key for --https\n"
        "\n"
        "Knobs (env): FSQL_MCP_AUTH_TOKEN, FSQL_MCP_AUTH_TOKEN_FILE, FSQL_MCP_MAX_ROWS_CEILING,\n"
        "FSQL_MCP_MAX_CONCURRENT_CHEAP/EXPENSIVE/EXPENSIVE_PER_CLIENT, FSQL_MCP_MAX_QUEUE_WAIT_MS,\n"
        "FSQL_MCP_SHUTDOWN_DRAIN_MS, FSQL_MCP_STRICT_SCHEMA_HASH, FSQL_MCP_READ_ONLY,\n"
        "FSQL_MCP_HTTPS, FSQL_MCP_TLS_CERT_FILE, FSQL_MCP_TLS_KEY_FILE,\n"
        "FSQL_MCP_LOCK_DIR, FSQL_MCP_SCHEMA_LOCK, FSQL_MCP_SAFETY_LOCK, FSQL_MCP_MANIFEST_PATH,\n"
        "FSQL_MCP_LOG_LEVEL (normal|info|verbose|debug).\n";
}

// All of main()'s command-line/env state, parsed by parseArgs() below.
struct CliArgs
{
    bool writeLock = false, writeSafetyLock = false, writeManifest = false, listTools = false;
    bool httpMode = false, httpsMode = false;
    int httpPort = 8765;
    std::string httpHost, httpPath, tlsCertFile, tlsKeyFile, lockPath, safetyLockPath;
    std::vector<std::string> toolWhitelist, enabledCategories;
};

// Parses argv into args. Returns true iff the process must exit right now
// with exitCode (--help, --version, an unknown flag). A flag missing its
// value exits std::exit(2) from inside next() (same as before, unchanged);
// an unknown flag is now REJECTED (exit 2) instead of silently ignored.
static bool parseArgs( int argc, char** argv, CliArgs& args, int& exitCode )
{
    for( int i = 1; i < argc; ++i )
    {
        const std::string arg( argv[ i ] );
        auto next = [ & ]( const char* flagName ) -> std::string {
            if( i + 1 >= argc )
            {
                std::cerr << "missing value for " << flagName << "\n";
                std::exit( 2 );
            }
            return std::string( argv[ ++i ] );
        };
        if( arg == "--write-schema-lock" ) args.writeLock = true;
        else if( arg == "--write-safety-annotations-lock" ) args.writeSafetyLock = true;
        else if( arg == "--write-manifest" ) args.writeManifest = true;
        else if( arg == "--list-tools" ) args.listTools = true;
        else if( arg == "--schema-lock-path" ) args.lockPath = next( "--schema-lock-path" );
        else if( arg == "--safety-lock-path" ) args.safetyLockPath = next( "--safety-lock-path" );
        else if( arg == "--tool" ) args.toolWhitelist = splitCsv( next( "--tool" ) );
        else if( arg == "--category" ) args.enabledCategories = splitCsv( next( "--category" ) );
        // --http PORT wins; an optional PORT also accepts FSQL_MCP_HTTP_PORT.
        else if( arg == "--http" || arg == "--http-transport" )
        { args.httpMode = true; if( i + 1 < argc && argv[ i + 1 ][ 0 ] != '-' ) args.httpPort = std::atoi( argv[ ++i ] ); }
        else if( arg == "--https" )
        { args.httpMode = true; args.httpsMode = true; if( i + 1 < argc && argv[ i + 1 ][ 0 ] != '-' ) args.httpPort = std::atoi( argv[ ++i ] ); }
        else if( arg == "--host" ) args.httpHost = next( "--host" );
        else if( arg == "--path" ) args.httpPath = next( "--path" );
        else if( arg == "--tls-cert" ) args.tlsCertFile = next( "--tls-cert" );
        else if( arg == "--tls-key" ) args.tlsKeyFile = next( "--tls-key" );
        else if( arg == "--help" || arg == "-h" ) { usage(); exitCode = 0; return true; }
        else if( arg == "--version" )
        {
            std::cout << FSQL_MCP_VERSION << "\n";
            exitCode = 0;
            return true;
        }
        else
        {
            std::cerr << "unknown argument '" << arg << "' (try --help)\n";
            exitCode = 2;
            return true;
        }
    }
    return false;
}

// The --write-schema-lock / --write-safety-annotations-lock /
// --write-manifest / --list-tools one-shot paths: at most one applies
// (checked in this exact order, matching the old inline chain), each
// prints/what-was-written and the process exits immediately after.
// Returns the exit code, or -1 if none of the flags were set (meaning:
// keep going and actually serve).
static int maybeRunOneShot( const CliArgs& args, const std::vector<ToolSpec>& full,
                            const std::string& hash, const std::string& renderedSafety,
                            const std::string& lockBase )
{
    if( args.writeLock ) { writeSchemaLock( args.lockPath, hash ); std::cout << hash << "\n"; return 0; }
    if( args.listTools )
    {
        // Prints "name<TAB>category" per tool; needs no database connection.
        std::vector<const ToolSpec*> sorted;
        for( const ToolSpec& t : full ) sorted.push_back( &t );
        std::sort( sorted.begin(), sorted.end(), []( auto* a, auto* b ) { return std::string_view( a->name ) < b->name; } );
        for( const ToolSpec* t : sorted )
            std::cout << t->name << "\t" << t->category << "\n";
        return 0;
    }
    // All --write-* branches run BEFORE the move that filters the served set:
    // `full` is consumed by filterTools below and would read as empty here.
    if( args.writeSafetyLock )
    { writeSafetyAnnotations( args.safetyLockPath, renderedSafety ); std::cout << args.safetyLockPath << " written\n"; return 0; }
    if( args.writeManifest )
    {
        Json tools_json = Json::array();
        for( const ToolSpec& t : full )
            tools_json.push_back( Json{ { "name", std::string( t.name ) }, { "description", t.description } } );
        Json manifest{
            { "name", "fractalsql-postgresql-mcp" }, { "version", FSQL_MCP_VERSION },
            { "server", { { "type", "binary" }, { "entry_point", "fractalsql-postgresql-mcp" } } },
            { "tools", tools_json }
        };
        // FSQL_MCP_MANIFEST_PATH overrides where the manifest is written.
        const std::string manifestPath = envOr( "FSQL_MCP_MANIFEST_PATH", lockBase + "/manifest.json" );
        // Binary mode keeps the file byte-identical across platforms (no CRLF).
        std::ofstream out( manifestPath, std::ios::trunc | std::ios::binary );
        out << manifest.dump( 2 ) << "\n";
        std::cout << manifestPath << " written (" << full.size() << " tools)\n";
        return 0;
    }
    return -1;
}

// Safety-annotation check: a mismatch is always fatal (exit 3), regardless of
// FSQL_MCP_STRICT_SCHEMA_HASH. Returns 0 to continue serving.
static int checkSafetyGate( const std::string& safetyLockPath, const std::string& renderedSafety )
{
    std::string diff;
    if( !checkSafetyAnnotations( safetyLockPath, renderedSafety, &diff ) )
    {
        std::cerr << "safety-annotation lock mismatch (" << safetyLockPath << "):\n"
                  << diff << "--- regenerate with --write-safety-annotations-lock\n";
        return 3;
    }
    return 0;
}

// Schema-lock check: warns on mismatch, or exits 2 when
// FSQL_MCP_STRICT_SCHEMA_HASH is set. Logs a schema_lock_ok event on a match.
static int checkSchemaGate( const std::string& lockPath, const std::string& hash )
{
    std::string expected;
    const LockCheckResult lockResult = checkSchemaLock( lockPath, hash, &expected );
    if( lockResult == LockCheckResult::Warn )
    {
        std::cerr << "schema hash mismatch: expected " << expected << " got " << hash << "; regenerate via "
                                                                                               "fractalsql-postgresql-mcp --write-schema-lock\n";
        if( envBoolOr( "FSQL_MCP_STRICT_SCHEMA_HASH", false ) ) return 2;
    }
    else if( lockResult == LockCheckResult::Ok )
        logging::event( "schema_lock_ok", Json{ { "hash", hash } } );
    return 0;
}

// Builds the HttpConfig from CliArgs/env, validates it, and runs the
// HTTP/HTTPS transport. Returns 2 on a config error (missing auth token, or
// --https without a cert/key), 2 on TLS init failure; otherwise the
// transport's drain/exit code. NOTE: main() routes the result through
// std::exit — connection threads cut loose at the drain deadline may still
// be inside a request, and main's stack objects must not be unwound under
// them (the transport leaks the state such a thread touches by design).
static int runHttpMode( const CliArgs& args, Db& db, RowLimitConfig& rowLimits,
                        const std::vector<std::string>& categories,
                        const std::vector<std::string>& whitelist,
                        const ConcurrencyConfig& concCfg, bool agentPartial )
{
    HttpConfig httpCfg;
    // Binds to loopback by default; use FSQL_MCP_HTTP_HOST=0.0.0.0 or --host
    // 0.0.0.0 to listen on all interfaces.
    httpCfg.host = args.httpHost.empty() ? envOr( "FSQL_MCP_HTTP_HOST", "127.0.0.1" ) : args.httpHost;
    httpCfg.port = args.httpPort;
    httpCfg.path = args.httpPath.empty() ? envOr( "FSQL_MCP_HTTP_PATH", "/mcp" ) : args.httpPath;
    httpCfg.authToken     = envOr( "FSQL_MCP_AUTH_TOKEN", "" );
    httpCfg.authTokenFile = envOr( "FSQL_MCP_AUTH_TOKEN_FILE", "" );
    httpCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
    httpCfg.tlsEnabled    = args.httpsMode || envBoolOr( "FSQL_MCP_HTTPS", false );
    httpCfg.tlsCertPath   = args.tlsCertFile.empty() ? envOr( "FSQL_MCP_TLS_CERT_FILE", "" ) : args.tlsCertFile;
    httpCfg.tlsKeyPath    = args.tlsKeyFile.empty()  ? envOr( "FSQL_MCP_TLS_KEY_FILE", "" )  : args.tlsKeyFile;
    if( httpCfg.authToken.empty() && httpCfg.authTokenFile.empty() )
    {
        std::cerr << "the HTTP transport requires FSQL_MCP_AUTH_TOKEN or "
                     "FSQL_MCP_AUTH_TOKEN_FILE\n";
        return 2;
    }
    if( httpCfg.tlsEnabled && ( httpCfg.tlsCertPath.empty() || httpCfg.tlsKeyPath.empty() ) )
    {
        std::cerr << "--https requires a TLS cert and key: pass --tls-cert/--tls-key or set "
                     "FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE\n";
        return 2;
    }

    ServerConfig serverCfg;
    serverCfg.serverName = "fractalsql-postgresql-mcp";
    serverCfg.serverVersion = FSQL_MCP_VERSION;
    serverCfg.rowLimits = rowLimits;   // same ceiling, same owner (main's frame)
    serverCfg.readOnlyMode = envBoolOr( "FSQL_MCP_READ_ONLY", false );
    // cancelHook is set per session in sessionFactory below.

    // Each MCP session gets its own database connection and server instance;
    // the concurrency caps stay process-wide via sharedConcurrency.
    auto sessionFactory = [ &serverCfg, &rowLimits, &concCfg, &categories, &whitelist, agentPartial ]()
                              -> std::shared_ptr<JsonRpcServer>
    {
        auto sessionDb = std::make_shared<Db>();
        try { sessionDb->connect( envOr( "FSQL_MCP_PG_CONN_URI", "" ) );
              sessionDb->applyAgentPartial( agentPartial );
              for( const std::string& w : sessionDb->startupWarnings() )
                  logging::exceptionDetail( "http-session", sanitizeSecrets( w ) ); }
        catch( const ToolError& e ) { logging::exceptionDetail( "http-session", sanitizeSecrets( e.message ) ); }
        ServerConfig sc = serverCfg;
        sc.cancelHook = [ sessionDb ] { sessionDb->cancel(); };
        // Same category/tool filter as the stdio path; handlers bind to this
        // session's connection.
        std::vector<ToolSpec> sessionTools = buildAllTools( *sessionDb, rowLimits );
        return std::make_shared<JsonRpcServer>( sc, filterTools( std::move( sessionTools ), categories, whitelist ), concCfg );
    };
    // Process-global caps stay shared across every per-session server (the
    // shared-manager pointer must be set before the sessions exist).
    ConcurrencyManager globalConcurrency( concCfg );
    serverCfg.sharedConcurrency = &globalConcurrency;
    // share the same object shape the stdio path builds (process-global caps)
    return runHttpTransport( httpCfg, [ &db ] { return db.probeAlive(); }, sessionFactory );
}

int main( int argc, char** argv )
{
    CliArgs args;
    args.httpPort = envIntOr( "FSQL_MCP_HTTP_PORT", 8765 );
    args.httpHost = envOr( "FSQL_MCP_HTTP_HOST", "127.0.0.1" );
    args.httpPath = envOr( "FSQL_MCP_HTTP_PATH", "/mcp" );
    args.tlsCertFile = envOr( "FSQL_MCP_TLS_CERT_FILE", "" );
    args.tlsKeyFile  = envOr( "FSQL_MCP_TLS_KEY_FILE", "" );
    args.lockPath = envOr( "FSQL_MCP_SCHEMA_LOCK", "" );
    args.safetyLockPath = envOr( "FSQL_MCP_SAFETY_LOCK", "" );

    int earlyExitCode = 0;
    if( parseArgs( argc, argv, args, earlyExitCode ) ) return earlyExitCode;

    const std::string selfDir_ = selfDir();

    // The row-limit config must outlive every tool spec, because handlers run
    // after buildAllTools returns. It is owned here for the server's lifetime.
    RowLimitConfig rowLimits;
    rowLimits.maxRowsCeiling = envIntOr( "FSQL_MCP_MAX_ROWS_CEILING", 1000 );

    // The tool table binds only a Db REFERENCE — no connection is touched at
    // build time, so --write-* flags and the whole lock workflow run offline.
    Db db;
    // The locks always describe the full catalog, so a --tool/--category
    // deployment is checked against the same committed locks.
    std::vector<ToolSpec> full = buildAllTools( db, rowLimits );
    const std::string hash = computeSchemaHash( full );
    const std::string renderedSafety = renderSafetyAnnotations( full );

    const std::string lockBase = envOr( "FSQL_MCP_LOCK_DIR", selfDir_ );
    // Lock file precedence: --schema-lock-path / --safety-lock-path, then
    // FSQL_MCP_SCHEMA_LOCK / FSQL_MCP_SAFETY_LOCK, then the binary's directory.
    if( args.lockPath.empty() ) args.lockPath = envOr( "FSQL_MCP_SCHEMA_LOCK", lockBase + "/.mcp-schema-lock" );
    if( args.safetyLockPath.empty() ) args.safetyLockPath = envOr( "FSQL_MCP_SAFETY_LOCK", lockBase + "/.mcp-safety-annotations-lock" );

    const int oneShotExit = maybeRunOneShot( args, full, hash, renderedSafety, lockBase );
    if( oneShotExit >= 0 ) return oneShotExit;

    // --tool/--category override the matching environment variables and
    // narrow what is served (tools/list and tools/call).
    std::vector<std::string> categories = args.enabledCategories.empty()
        ? splitCsv( envOr( "FSQL_MCP_ENABLED_CATEGORIES", "" ) ) : args.enabledCategories;
    std::vector<std::string> whitelist = args.toolWhitelist.empty()
        ? splitCsv( envOr( "FSQL_MCP_TOOL_WHITELIST", "" ) ) : args.toolWhitelist;
    std::vector<ToolSpec> tools = filterTools( std::move( full ), categories, whitelist );

    // Lock checks run after the one-shot flags (exit 2 = schema, 3 = safety).
    if( const int schemaExit = checkSchemaGate( args.lockPath, hash ) ) return schemaExit;
    if( const int safetyExit = checkSafetyGate( args.safetyLockPath, renderedSafety ) ) return safetyExit;

    // A database that is down at startup does not stop the server; each tool
    // call reports a connectivity error instead. The server never installs or
    // alters the extension.
    const bool agentPartial = envBoolOr( "FSQL_MCP_AGENT_PARTIAL", true );
    try
    {
        // libpq reads PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE natively; a full
        // conninfo (or FSQL_MCP_PG_CONN_URI) overrides. No DDL is ever run here.
        db.connect( envOr( "FSQL_MCP_PG_CONN_URI", "" ) );
        db.checkVersion( envOr( "FSQL_MCP_EXPECT_VERSION", FSQL_MCP_VERSION ) );
        db.applyAgentPartial( agentPartial );
    }
    catch( const ToolError& e )
    {
        std::cerr << "warning: initial connection failed; calls will surface connectivity errors: "
                  << sanitizeSecrets( e.message ) << "\n";
    }
    // Startup warnings MUST print after the connect block: checkVersion's
    // version-skew warning and applyAgentPartial's predates-the-key warning are
    // only pushed onto startupWarnings() once connected, so a loop placed above
    // the connect (the original order) silently swallowed every warning it
    // claimed to surface -- exactly how a stale core DLL's missing
    // agent_partial_reasoning_fail first hid from the gate.
    for( const std::string& w : db.startupWarnings() )
        std::cerr << "warning: " << sanitizeSecrets( w ) << "\n";

    const std::string logLevel = envOr( "FSQL_MCP_LOG_LEVEL", "normal" );
    logging::init( { logLevel == "verbose" ? logging::Level::Debug
                   : logLevel == "error"   ? logging::Level::Error
                                           : logging::Level::Info } );

    ConcurrencyConfig concCfg;
    concCfg.cheapLimit         = envIntOr( "FSQL_MCP_MAX_CONCURRENT_CHEAP", 50 );
    concCfg.expensiveLimit     = envIntOr( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE", 5 );
    concCfg.expensivePerClient = envIntOr( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT", 2 );
    concCfg.maxQueueWaitMs     = envIntOr( "FSQL_MCP_MAX_QUEUE_WAIT_MS", 900'000 );

    // --http PORT wins; FSQL_MCP_TRANSPORT=http (1.2's env-form knob) also
    // selects the HTTP transport for env-only deployments like the compose demo.
    if( !args.httpMode && envOr( "FSQL_MCP_TRANSPORT", "stdio" ) == "http" ) args.httpMode = true;
    if( args.httpMode )
    {
        // HTTP connection threads are cut loose at the drain deadline and can
        // still be inside a request: main's stack objects (db, server-cfg
        // locals) must stay alive through process teardown — exit() runs
        // atexit handlers (coverage flush in coverage builds) but does not
        // unwind main's stack. The transport leaks the state a straggler
        // touches by design; this is the paired half of that posture.
        std::exit( runHttpMode( args, db, rowLimits, categories, whitelist, concCfg, agentPartial ) );
    }

    ServerConfig serverCfg;
    serverCfg.serverName = "fractalsql-postgresql-mcp";
    serverCfg.serverVersion = FSQL_MCP_VERSION;
    serverCfg.rowLimits = rowLimits;   // same ceiling, same owner
    serverCfg.readOnlyMode = envBoolOr( "FSQL_MCP_READ_ONLY", false );
    serverCfg.cancelHook = [ &db ] { db.cancel(); };   // 1.1 $/cancel -> PQcancel

    JsonRpcServer server( serverCfg, std::move( tools ), concCfg );
    StdioConfig stdioCfg;
    stdioCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
    return runStdioTransport( server, stdioCfg );
}