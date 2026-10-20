#pragma once
#include <libpq-fe.h>
#include <string>
#include <vector>
#include <optional>
#include <memory>
#include <mutex>
#include <cstdlib>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp
{
    // FSQL_MCP_DEBUG_SQL is read once at program start.
    static const bool kDbDebugSql = ( std::getenv( "FSQL_MCP_DEBUG_SQL" ) != nullptr );

    // Postgres connection layer: one persistent PGconn* per process (stdio) or
    // per HTTP session. Every call goes through PQexecParams with $1..$n
    // placeholders in text mode, never string-built SQL. The one exception is
    // admin.cpp's ALTER SYSTEM SET, which postgres does not accept parameters
    // in; it uses a fixed allowlist of GUC names and quote-doubling.
    class Db
    {
    public:
        ~Db() { close(); }
        Db() = default;
        Db( const Db& ) = delete;
        Db& operator=( const Db& ) = delete;

        void connect( const std::string& conninfo )
        {
            std::lock_guard<std::mutex> lk( connMu_ );
            PGconn* raw = PQconnectdb( conninfo.c_str() );
            // PQconnectdb returns NULL only on allocation failure, but
            // PQstatus(NULL) would fault — check before dereferencing.
            if( !raw || PQstatus( raw ) != CONNECTION_OK )
            {
                const std::string msg = raw ? sanitizeSecrets( PQerrorMessage( raw ) )
                                            : std::string( "could not connect to postgres" );
                if( raw ) PQfinish( raw );
                throw ToolError( ErrorClass::Connectivity, msg );
            }
            // Every string this server hands to a client is JSON, i.e. UTF-8. Without
            // this the engine's error text arrives in the database's own encoding
            // (a Windows ANSI code page, for one), and a non-UTF-8 byte in a tool
            // result made the JSON serializer throw -> "internal server error".
            PQsetClientEncoding( raw, "UTF8" );
            std::lock_guard<std::mutex> plk( connPtrMu_ );
            conn_ = std::shared_ptr<PGconn>( raw, &pgFinish );
        }

        void close()
        {
            // Taking connMu_ first waits for any running query to finish.
            std::lock_guard<std::mutex> lk( connMu_ );
            std::shared_ptr<PGconn> dying;
            { std::lock_guard<std::mutex> plk( connPtrMu_ ); dying = std::move( conn_ ); }
            // PQfinish runs when the last reference is released, which may be a
            // concurrent cancel() still holding the connection.
        }

        bool connected() const
        {
            std::lock_guard<std::mutex> lk( connPtrMu_ );
            return static_cast<bool>( conn_ );
        }

        // Scalar call: SELECT fn($1,$2,...) for jsonb/scalar-returning functions.
        // Returns the column-0 text of row 0, or std::nullopt for SQL NULL.
        std::optional<std::string> callScalar( const std::string& sql, const std::vector<std::string>& textParams )
        {
            std::lock_guard<std::mutex> lk( connMu_ );
            PGresult* res = execParamsLocked( sql, textParams );

            const ExecStatusType st = PQresultStatus( res );
            if( st != PGRES_TUPLES_OK && st != PGRES_COMMAND_OK )
            {
                const ToolError err = classifyErrorLocked( res );
                PQclear( res );
                throw err;
            }
            std::optional<std::string> out;
            if( PQntuples( res ) > 0 && !PQgetisnull( res, 0, 0 ) )
                out = std::string( PQgetvalue( res, 0, 0 ), PQgetlength( res, 0, 0 ) );
            PQclear( res );
            return out;
        }

        // Table-returning call: SELECT * FROM fn($1,...) — decodes every row into a
        // JSON object keyed by column name (for TABLE(...)/SETOF functions).
        Json callRows( const std::string& sql, const std::vector<std::string>& textParams )
        {
            std::lock_guard<std::mutex> lk( connMu_ );
            PGresult* res = execParamsLocked( sql, textParams );

            const ExecStatusType st = PQresultStatus( res );
            if( st != PGRES_TUPLES_OK )
            {
                const ToolError err = classifyErrorLocked( res );
                PQclear( res );
                throw err;
            }

            Json rows = Json::array();
            const int nCols = PQnfields( res );
            for( int r = 0; r < PQntuples( res ); ++r )
                rows.push_back( rowToJson( res, r, nCols ) );
            PQclear( res );
            return rows;
        }

        // Composite-row convenience: SELECT * FROM fn(...) expected to return
        // exactly one row; decoded as a single JSON object. An empty
        // result is an engine-layer error for the one-row agent contract.
        std::optional<Json> callRow( const std::string& sql, const std::vector<std::string>& textParams )
        {
            std::lock_guard<std::mutex> lk( connMu_ );
            PGresult* res = execParamsLocked( sql, textParams );

            const ExecStatusType st = PQresultStatus( res );
            if( st != PGRES_TUPLES_OK )
            {
                const ToolError err = classifyErrorLocked( res );
                PQclear( res );
                throw err;
            }
            std::optional<Json> out;
            if( PQntuples( res ) > 0 )
                out = rowToJson( res, 0, PQnfields( res ) );
            PQclear( res );
            return out;
        }

        // Cancels the running statement via PQcancel on a separate cancel
        // handle (never a second query on this connection). Wired to
        // JsonRpcServer's cancelHook in main.cpp.
        void cancel()
        {
            // Keep the connection alive across PQgetCancel/PQcancel: a
            // concurrent close() must not free it in between. connMu_ cannot be
            // taken here (the running query holds it), so a reference-counted
            // handle is used; PQfinish runs when the last holder releases it.
            std::shared_ptr<PGconn> conn;
            { std::lock_guard<std::mutex> lk( connPtrMu_ ); conn = conn_; }
            if( !conn ) return;
            // PQgetCancel/PQcancel are documented thread-safe against the conn.
            PGcancel* c = PQgetCancel( conn.get() );
            if( c )
            {
                char errbuf[ 256 ];
                PQcancel( c, errbuf, sizeof( errbuf ) );
                PQfreeCancel( c );
            }
        }

        bool probeAlive()
        {
            try { return callScalar( "SELECT 1", {} ).has_value(); }
            catch( ... ) { return false; }
        }

        // Version-skew guard: warn, never hard-fail. Compares the
        // engine's reported version against the version this plugin was
        // built/expected for; FSQL_MCP_EXPECT_VERSION overrides.
        void checkVersion( const std::string& engineVersionExpected )
        {
            try
            {
                const auto v = callScalar( "SELECT fractal_version()", {} );
                if( v && *v != engineVersionExpected )
                    warnings_.push_back( "version skew: engine reports " + *v
                                          + ", plugin built against " + engineVersionExpected );
            }
            catch( ... ) { /* non-fatal: surfaced via startupWarnings(), never thrown */ }
        }

        const std::vector<std::string>& startupWarnings() const { return warnings_; }

        // Maps a SQLSTATE to an error class (engine, connectivity or cancelled).
        // Public so tests/db_probe.cpp can test the rules without a cluster.
        static ToolError classifyError( const std::string& msg, const std::string& sqlstate )
        {
            if( sqlstate == "57014" )          return ToolError( ErrorClass::Cancelled, "call was cancelled" );   // query_canceled
            if( sqlstate == "08P01" )          return ToolError( ErrorClass::ServerInternal, msg );  // protocol_violation:
                // e.g. "bind message supplies N parameters, but ... requires 0" — the CALL
                // TEMPLATE's own bug (an unused over-bind or a missing placeholder), never
                // connectivity — the server must not tell the client to reconnect.
            if( sqlstate.size() >= 2 && sqlstate.compare( 0, 2, "08" ) == 0 )
                return ToolError( ErrorClass::Connectivity, msg );                    // connection_exception class
            if( sqlstate == "53300" )          return ToolError( ErrorClass::Connectivity, msg );  // too_many_connections
            return ToolError( ErrorClass::Engine, msg );
        }

        // Opt-in agent_partial_reasoning_fail, session-scoped (documented in
        // api-agency.md): when on=true,
        // every session SETs the engine's key so a domain agent's LLM-step
        // failure returns the computed data half plus a 'reasoning_step_failed'
        // marker instead of a hard raise. Warn-and-continue when the connected
        // engine predates the key (no pg_settings row) or the SET itself errors —
        // same never-fatal stance as checkVersion(); surfaced via startupWarnings().
        void applyAgentPartial( bool on )
        {
            if( !on ) return;
            try
            {
                const auto has = callScalar(
                    "SELECT count(*)::int4 FROM pg_settings WHERE name = $1",
                    { std::string( "fractalsql.agent_partial_reasoning_fail" ) } );
                if( has && *has == "0" )
                {
                    warnings_.push_back( "engine does not define fractalsql.agent_partial_reasoning_fail"
                                         "; partial-reasoning behavior unavailable here" );
                    return;
                }
                callScalar( "SELECT set_config($1, $2, false)",
                            { std::string( "fractalsql.agent_partial_reasoning_fail" ), std::string( "on" ) } );
            }
            catch( const ToolError& e )
            {
                warnings_.push_back( "could not SET fractalsql.agent_partial_reasoning_fail for this session: "
                                     + e.message );
            }
        }

    private:
        PGresult* execParamsLocked( const std::string& sql, const std::vector<std::string>& textParams )
        {
            // Snapshot the handle under the pointer lock: the reference keeps
            // the PGconn alive for the whole PQexecParams call even if a
            // close() lands concurrently.
            std::shared_ptr<PGconn> conn;
            { std::lock_guard<std::mutex> plk( connPtrMu_ ); conn = conn_; }
            if( !conn )
                throw ToolError( ErrorClass::Connectivity,
                    "not connected to postgres — check PG* env vars / FSQL_MCP_PG_CONN_URI or the server log" );
            std::vector<const char*> values; values.reserve( textParams.size() );
            for( const std::string& p : textParams ) values.push_back( p.c_str() );
            PGresult* res = PQexecParams( conn.get(), sql.c_str(), static_cast<int>( textParams.size() ),
                                 nullptr, values.data(), nullptr, nullptr, 0 );   // all-text mode
            // FSQL_MCP_DEBUG_SQL=1: log the statement of a failed execution to
            // stderr. Bound values are never logged (they are caller data); only
            // the parameter count is. The statement itself is passed through the
            // secret sanitizer.
            if( PQresultStatus( res ) != PGRES_TUPLES_OK && PQresultStatus( res ) != PGRES_COMMAND_OK
                && kDbDebugSql )
            {
                std::fprintf( stderr, "[sql-debug] %s\n[sql-debug] binds: %lu (redacted)\n",
                              sanitizeSecrets( sql ).c_str(),
                              static_cast<unsigned long>( textParams.size() ) );
                std::fflush( stderr );
            }
            return res;
        }

        static Json rowToJson( PGresult* res, int r, int nCols )
        {
            Json row = Json::object();
            for( int c = 0; c < nCols; ++c )
            {
                const std::string col = PQfname( res, c );
                if( PQgetisnull( res, r, c ) ) { row[ col ] = nullptr; continue; }
                row[ col ] = decodeField( std::string( PQgetvalue( res, r, c ), PQgetlength( res, r, c ) ) );
            }
            return row;
        }

        static Json decodeField( const std::string& text )
        {
            // jsonb/json columns already contain JSON text; everything else (float8,
            // int8, text, ctid) is passed through as a JSON string and the caller
            // re-types it (ctid stays text; vectors and int8[] are decoded by the
            // tool handler via vectors::pgArrayTo*).
            try { return Json::parse( text ); } catch( ... ) { return Json( text ); }
        }

        ToolError classifyErrorLocked( PGresult* res )
        {
            const char* msg = PQresultErrorMessage( res );
            const char* st = PQresultErrorField( res, PG_DIAG_SQLSTATE );
            return classifyError( sanitizeSecrets( msg ? msg : "" ), st ? st : "" );
        }

        // The connection is held by a shared_ptr so that a cancel() in flight
        // can keep the PGconn alive across its PQgetCancel/PQcancel pair
        // (libpq's PGcancel points back at the PGconn); the deleter runs
        // PQfinish only when the LAST holder releases it.
        static void pgFinish( PGconn* c ) { if( c ) PQfinish( c ); }
        std::shared_ptr<PGconn> conn_;
        std::mutex connMu_;    // one connection, N worker threads (stdio runs a thread per request line) — serialize PQexecParams
        // Guards the conn_ HANDLE itself (the shared_ptr member), not the
        // query stream: cancel() must be able to read the handle while a
        // query holds connMu_, so the handle needs its own, very short-
        // lived lock. Lock order is always connMu_ -> connPtrMu_; nothing
        // takes them the other way round.
        mutable std::mutex connPtrMu_;
        std::vector<std::string> warnings_;
    };

    // float8[] text-format literal, bound as a single $n text parameter with an
    // explicit cast in the SQL template.
    inline std::string pgFloat8ArrayLiteral( const std::string& csv ) { return "{" + csv + "}"; }   // libpq text-array literal form

    // Same form for int4[] (edge and face index arrays).
    inline std::string pgInt4ArrayLiteral( const std::string& csv ) { return "{" + csv + "}"; }

    // text[] binding used by the adapters: bind the JSON array text as a
    // ::jsonb parameter and convert it in the call template, e.g.
    //   SELECT fractal_text_to_sql($1, (SELECT array_agg(x) FROM jsonb_array_elements_text($2::jsonb) AS x))
    // Values always arrive bound, never spliced into the SQL text.
    inline const char* kPgTextArrayBind = "array_agg(x) FROM jsonb_array_elements_text";
}