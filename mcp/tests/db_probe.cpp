// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Standalone unit probe for mcp/src/db.h, built from mcp/ so the recorded
// source path for db.h merges into the main build's coverage (db.h is fully
// inline, like concurrency.h — this TU is the only place its off-the-wire
// failure branches get covered at all).
//
// Ported from the SQLite column's db_probe (v2.0.9) and RE-EXPRESSED for the
// PostgreSQL column: there is no SQLite amalgamation/.load/.memory/PRAGMA
// story here to copy — instead the probe drives the libpq error taxonomy
// (SQLSTATE 57014 cancel / class-08 + 53300 connectivity / everything else
// engine), the refused-connection path, and the version-skew /
// agent_partial_warning recording, against whatever PG* env the caller
// wires (the throwaway gate-41 cluster; checks that need a live server are
// SKIPPED, not failed, when no PG env is present — mirroring mcp/test/
// smoke.py's exit-77 posture so the probe still runs DB-less).
#include "../src/db.h"
#include "../src/errors.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>

using fsqlmcp::Db;
using fsqlmcp::Json;
using fsqlmcp::ToolError;
using fsqlmcp::ErrorClass;

static int failed = 0;

static void check( const char* label, bool cond )
{
    std::printf( "%s %s\n", cond ? "OK:" : "FAIL:", label );
    if( !cond ) failed = 1;
}

static bool throws_class( const char* label, ErrorClass expect, const std::function<void()>& fn )
{
    try { fn(); }
    catch( const ToolError& e )
    {
        check( label, e.errorClass == expect );
        return true;
    }
    check( label, false );
    return false;
}

// True when the caller wired a live PG (PGDATABASE/PGHOST style env).
static bool pgEnvPresent()
{
    return std::getenv( "PGDATABASE" ) != nullptr || std::getenv( "PGHOST" ) != nullptr ||
           std::getenv( "PGCONN" ) != nullptr;
}

int main()
{
    std::setvbuf( stdout, nullptr, _IONBF, 0 );   // unbuffered: a crash must not swallow the lines already printed
    // ---------- unconnected paths (no server needed) ----------
    throws_class( "unconnected callScalar throws Connectivity", ErrorClass::Connectivity,
                  [] { Db db; db.callScalar( "SELECT 1", {} ); } );
    throws_class( "unconnected callRows throws Connectivity", ErrorClass::Connectivity,
                  [] { Db db; db.callRows( "SELECT 1", {} ); } );
    throws_class( "unconnected callRow throws Connectivity", ErrorClass::Connectivity,
                  [] { Db db; db.callRow( "SELECT 1", {} ); } );
    {
        Db db;
        check( "probeAlive() is false when unconnected", !db.probeAlive() );
        check( "connected() is false before connect()", !db.connected() );
        check( "startupWarnings() is empty before any guarded call",
               db.startupWarnings().empty() );
    }

    // ---------- refused connection: a real socket that nobody accepts ----------
    throws_class( "connect() to a dead host:port throws Connectivity", ErrorClass::Connectivity,
                  [] { Db db; db.connect( "host=127.0.0.1 port=1 connect_timeout=3 dbname=postgres" ); } );
    // The failed connect() must leave the Db reusable for a later attempt.
    {
        Db db;
        bool threw = false;
        try { db.connect( "host=127.0.0.1 port=1 connect_timeout=3 dbname=postgres" ); }
        catch( const ToolError& ) { threw = true; }
        check( "failed connect() threw, then the Db reports unconnected",
               threw && !db.connected() );
    }

    // ---------- SQLSTATE classification (static, no server involved) ----------
    {
        const ToolError c = Db::classifyError( "cancelled by client", "57014" );
        check( "classifyError: 57014 -> Cancelled", c.errorClass == ErrorClass::Cancelled );
        const ToolError e = Db::classifyError( "duplicate key value violates unique constraint \"t_pkey\"", "23505" );
        check( "classifyError: 23505 (unique_violation) -> Engine", e.errorClass == ErrorClass::Engine );
        const ToolError e2 = Db::classifyError( "geometry error", "22023" );
        check( "classifyError: another non-conn class -> Engine", e2.errorClass == ErrorClass::Engine );
        const ToolError e3 = Db::classifyError( "numeric value out of range", "22003" );
        check( "classifyError: 22003 -> Engine", e3.errorClass == ErrorClass::Engine );
        const ToolError e4 = Db::classifyError( "function does not exist", "42883" );
        check( "classifyError: 42883 -> Engine", e4.errorClass == ErrorClass::Engine );
    }
    {
        const ToolError c1 = Db::classifyError( "server closed the connection unexpectedly", "08006" );
        check( "classifyError: 08006 (class 08) -> Connectivity", c1.errorClass == ErrorClass::Connectivity );
        const ToolError c2 = Db::classifyError( "too many connections for role", "53300" );
        check( "classifyError: 53300 -> Connectivity", c2.errorClass == ErrorClass::Connectivity );
        const ToolError c3 = Db::classifyError( "unrecognized error", "" );
        check( "classifyError: empty SQLSTATE -> Engine (not Connectivity)",
               c3.errorClass == ErrorClass::Engine );
    }

    // ---------- live-DB checks: skipped (not failed) without a cluster ----------
    if( !pgEnvPresent() )
    {
        std::printf( "db_probe %s: live-DB checks skipped (no PG* env)\n",
                     failed ? "FAILED EARLY CHECKS" : "ok" );
        return failed ? 1 : 0;
    }

    // ---------- connected paths ----------
    {
        Db db;
        db.connect( std::getenv( "FSQL_MCP_TEST_CONNINFO" ) ? std::getenv( "FSQL_MCP_TEST_CONNINFO" ) : "" );
        check( "connect() reports connected", db.connected() );
        const auto one = db.callScalar( "SELECT 1::int8", {} );
        check( "callScalar returns the scalar text of the first column", one && *one == "1" );
        const auto nul = db.callScalar( "SELECT NULL::text", {} );
        check( "callScalar returns nullopt for SQL NULL", !nul );
        const auto empty = db.callRow( "SELECT 'x'::text AS v WHERE 1 = 0", {} );
        check( "callRow returns nullopt on an empty one-row contract", !empty );
        const Json rows = db.callRows( "SELECT 1::int8 AS a, 'z'::text AS b", {} );
        check( "callRows decodes rows keyed by column name",
               rows.is_array() && rows.size() == 1
               && rows[ 0 ][ "a" ] == Json( 1 ) && rows[ 0 ][ "b" ] == Json( "z" ) );
        check( "probeAlive() is true when connected", db.probeAlive() );

        // Engine-function prepare-failure classes: an undefined function is a
        // 42883 error class -> Engine, surfaced as a ToolError (not a crash).
        throws_class( "undefined engine function -> Engine", ErrorClass::Engine,
                      [&db] { ( void )db.callScalar( "SELECT fractal_this_function_does_not_exist_42()", {} ); } );

        // Engine-parameter over-bind: libpq is NOT tolerant — a bind message
        // supplying more parameters than the statement contains is rejected
        // with 08P01 (protocol_violation; the server-side check), which the
        // classification maps to ServerInternal: it is the CALL TEMPLATE's
        // own bug, not connectivity and not an engine error. (The sqlite
        // column's SQLITE_RANGE analog, with postgres's own error code.)
        throws_class( "over-binding raises a ServerInternal error (libpq bind-count check)", ErrorClass::ServerInternal,
                      [&db] { ( void )db.callScalar( "SELECT 2::int8", { std::string( "unused" ) } ); } );

        // Version-skew: expect a version the engine cannot report — the guard
        // WARNS (startupWarnings) and continues; nothing throws.
        db.checkVersion( "9.9.9-THIS-DOES-NOT-EXIST" );
        check( "checkVersion against a bogus expected version records a warning, not a throw",
               !db.startupWarnings().empty() );

        // agent-partial: the real engine defines fractalsql.agent_partial_reasoning_fail
        // (PGC_USERSET), so with the extension in place this sets the key without
        // a warning; with a bare (no-extension) cluster, the pg_settings probe
        // records the predates-the-key warning instead.
        const auto has = db.callScalar(
            "SELECT count(*)::int4 FROM pg_settings WHERE name = $1",
            { std::string( "fractalsql.agent_partial_reasoning_fail" ) } );
        db.applyAgentPartial( true );
        if( has && *has == "0" )
        {
            check( "applyAgentPartial on a no-extension engine records its warning",
                   std::any_of( db.startupWarnings().begin(), db.startupWarnings().end(),
                                []( const std::string& w ) {
                                    return w.find( "does not define fractalsql.agent_partial_reasoning_fail" )
                                           != std::string::npos;
                                } ) );
        }
        else
        {
            const auto set = db.callScalar( "SELECT current_setting($1::text, false)",
                                            { std::string( "fractalsql.agent_partial_reasoning_fail" ) } );
            check( "applyAgentPartial on the engine sets the session key to on",
                   set && *set == "on" );
        }
    }

    std::printf( "db_probe %s\n", failed ? "FAILED" : "ok" );
    return failed ? 1 : 0;
}