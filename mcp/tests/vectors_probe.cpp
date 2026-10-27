// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Standalone unit test for mcp/src/vectors.cpp. These functions are pure
// (JSON in, JSON/string/bytes out, no DB/transport dependency), but several
// of their error/coercion branches are only reachable with inputs the MCP
// JSON-schema layer's own "is this an array" check lets through unchanged
// (e.g. an array containing a non-numeric element, or a hex string with an
// odd length) -- exercising them through a live tools/call round trip would
// also depend on which tool's param schema is used as the vehicle, so a
// direct unit test is simpler and more certain to hit each branch
// deliberately. Built from mcp/ so the recorded source path for
// src/vectors.cpp matches the main build's own, merging into its coverage
// rather than duplicating.
// Ported from the SQLite column's vectors_probe (v2.0.9) and EXTENDED with
// this engine's PostgreSQL-specific helpers (pg array-literal decoding and
// bytea text extraction) -- the parts the SQLite column does not have.
#include "../src/vectors.h"
#include "../src/errors.h"

#include <cstdio>
#include <cmath>
#include <cstring>
#include <limits>
#include <functional>

using fsqlmcp::Json;
using fsqlmcp::ToolError;
using fsqlmcp::ErrorClass;
using namespace fsqlmcp::vectors;

static int failed = 0;

static void check( const char* label, bool cond )
{
    std::printf( "%s %s\n", cond ? "OK:" : "FAIL:", label );
    if( !cond ) failed = 1;
}

static bool throws_schema( const char* label, const std::function<void()>& fn )
{
    try { fn(); }
    catch( const ToolError& e )
    {
        check( label, e.errorClass == ErrorClass::Schema );
        return true;
    }
    check( label, false );
    return false;
}

static bool throws_server( const char* label, const std::function<void()>& fn )
{
    try { fn(); }
    catch( const ToolError& e )
    {
        check( label, e.errorClass == ErrorClass::ServerInternal );
        return true;
    }
    check( label, false );
    return false;
}

static bool near( double a, double b, double eps = 1e-9 )
{ return std::fabs( a - b ) < eps; }

int main()
{
    // ---------- coerceNumber ----------
    check( "coerceNumber: bool is never coerced",
           coerceNumber( Json( true ) ) == Json( true ) );
    check( "coerceNumber: a real number passes through",
           coerceNumber( Json( 3.5 ) ) == Json( 3.5 ) );
    check( "coerceNumber: a clean numeric string is coerced",
           coerceNumber( Json( "3.5" ) ) == Json( 3.5 ) );
    check( "coerceNumber: a non-numeric string is left unchanged",
           coerceNumber( Json( "abc" ) ) == Json( "abc" ) );
    check( "coerceNumber: a partially-numeric string (trailing junk) is left unchanged",
           coerceNumber( Json( "12abc" ) ) == Json( "12abc" ) );
    check( "coerceNumber: a numeric string with trailing whitespace is left unchanged "
           "(not fully consumed)",
           coerceNumber( Json( "12 " ) ) == Json( "12 " ) );
    check( "coerceNumber: \"nan\" parses as a number but fails isfinite, left unchanged",
           coerceNumber( Json( "nan" ) ) == Json( "nan" ) );
    check( "coerceNumber: \"inf\" parses as a number but fails isfinite, left unchanged",
           coerceNumber( Json( "inf" ) ) == Json( "inf" ) );

    // ---------- vectorParamToText ----------
    throws_schema( "vectorParamToText: null rejected",
                   [] { vectorParamToText( Json( nullptr ), "v" ); } );
    throws_schema( "vectorParamToText: non-array rejected",
                   [] { vectorParamToText( Json( "not an array" ), "v" ); } );
    throws_schema( "vectorParamToText: empty array rejected",
                   [] { vectorParamToText( Json::array(), "v" ); } );
    check( "vectorParamToText: a valid numeric array converts to CSV text",
           vectorParamToText( Json::array( { 1.0, 2.0, 3.0 } ), "v" ) == "1,2,3" );
    check( "vectorParamToText: numeric strings are leniently coerced",
           vectorParamToText( Json::array( { "1.0", "2.0" } ), "v" ) == "1,2" );
    throws_schema( "vectorParamToText: a single non-numeric element is rejected",
                   [] { vectorParamToText( Json::array( { 1.0, "garbage" } ), "v" ); } );
    throws_schema( "vectorParamToText: a bool element is rejected (never coerced)",
                   [] { vectorParamToText( Json::array( { 1.0, true } ), "v" ); } );
    throws_schema( "vectorParamToText: a non-finite element (NaN via a bad string) is rejected",
                   [] { vectorParamToText( Json::array( { "nan" } ), "v" ); } );
    // bad.size() < 3 cap: 5 bad elements, only the first 3 named in the message
    try
    {
        vectorParamToText( Json::array( { "a", "b", "c", "d", "e" } ), "v" );
        check( "vectorParamToText: more than 3 bad elements still rejected cleanly", false );
    }
    catch( const ToolError& e )
    {
        int commas = 0;
        for( char c : e.message ) if( c == ',' ) ++commas;
        check( "vectorParamToText: more than 3 bad elements still rejected cleanly "
               "(message caps at 3 named offenders)",
               e.errorClass == ErrorClass::Schema && commas == 2 );
    }

    // ---------- intArrayToJsonText ----------
    throws_schema( "intArrayToJsonText: non-array rejected",
                   [] { intArrayToJsonText( Json( 5 ), "ids" ); } );
    throws_schema( "intArrayToJsonText: a float element is rejected (no coercion here)",
                   [] { intArrayToJsonText( Json::array( { 1, 2.5 } ), "ids" ); } );
    throws_schema( "intArrayToJsonText: a bool element is rejected",
                   [] { intArrayToJsonText( Json::array( { 1, true } ), "ids" ); } );
    check( "intArrayToJsonText: a valid integer array round-trips",
           intArrayToJsonText( Json::array( { 1, 2, 3 } ), "ids" ) == "[1,2,3]" );

    // ---------- stringArrayToJsonText ----------
    throws_schema( "stringArrayToJsonText: non-array rejected",
                   [] { stringArrayToJsonText( Json( 5 ), "names" ); } );
    throws_schema( "stringArrayToJsonText: a non-string element is rejected",
                   [] { stringArrayToJsonText( Json::array( { "a", 1 } ), "names" ); } );
    check( "stringArrayToJsonText: a valid string array round-trips",
           stringArrayToJsonText( Json::array( { "a", "b" } ), "names" )
               == "[\"a\",\"b\"]" );

    // ---------- blobToNumbers: u16 dim (LE) + u16 reserved + float32[dim] ----------
    {
        const std::uint8_t tooShortHeader[ 3 ] = { 0, 0, 0 };
        throws_server( "blobToNumbers: a BLOB shorter than its own 4-byte header is rejected",
                       [&] { blobToNumbers( tooShortHeader, 3 ); } );

        // dim=2 declared, but only 4+4=8 bytes present (needs 4+8=12)
        const std::uint8_t shortDim[ 8 ] = { 2, 0, 0, 0, 0, 0, 0, 0 };
        throws_server( "blobToNumbers: a BLOB shorter than its declared dimension is rejected",
                       [&] { blobToNumbers( shortDim, 8 ); } );

        // dim=1, one float32 == 1.5f
        std::uint8_t ok[ 8 ] = { 1, 0, 0, 0 };
        float f = 1.5f;
        std::memcpy( ok + 4, &f, 4 );
        Json out = blobToNumbers( ok, 8 );
        check( "blobToNumbers: a well-formed BLOB decodes its float32 payload",
               out.is_array() && out.size() == 1
               && near( out[ 0 ].get<double>(), 1.5 ) );
    }

    // ---------- hexToBytes (this column's signature takes just the hex) ----------
    throws_schema( "hexToBytes: odd-length hex rejected",
                   [] { hexToBytes( "abc" ); } );
    throws_schema( "hexToBytes: a non-hex character is rejected",
                   [] { hexToBytes( "zz" ); } );
    {
        auto bytes = hexToBytes( "ff00" );
        check( "hexToBytes: valid hex decodes correctly",
               bytes.size() == 2 && bytes[ 0 ] == 0xff && bytes[ 1 ] == 0x00 );
    }

    // ---------- wrapScalar ----------
    check( "wrapScalar: null wraps as {value:null}",
           wrapScalar( Json( nullptr ) ) == Json{ { "value", nullptr } } );
    check( "wrapScalar: a non-finite double (NaN) wraps as {value:null}",
           wrapScalar( Json( std::numeric_limits<double>::quiet_NaN() ) )
               == Json{ { "value", nullptr } } );
    check( "wrapScalar: a finite number wraps as-is",
           wrapScalar( Json( 2.5 ) ) == Json{ { "value", 2.5 } } );
    check( "wrapScalar: a non-number passes through as-is",
           wrapScalar( Json( "x" ) ) == Json{ { "value", "x" } } );

    // ---------- PostgreSQL-specific: pg array-literal decoding ----------
    // pqArrayTextToJson / pgArrayToNumbers decode the PQgetvalue text form of
    // an array column ("{1,2,...}"), incl. per-element NULL and quoted text[].
    {
        Json arr = pgArrayTextToJson( "{1,2,3}" );
        check( "pgArrayTextToJson: a simple numeric array decodes to a JSON array",
               arr.is_array() && arr.size() == 3
               && near( arr[ 0 ].get<double>(), 1.0 ) && near( arr[ 2 ].get<double>(), 3.0 ) );

        arr = pgArrayTextToJson( "{1,NULL,3}" );
        check( "pgArrayTextToJson: a bare NULL element maps to JSON null",
               arr.is_array() && arr.size() == 3 && arr[ 1 ].is_null() );

        // Quoting round-trip: pg quotes elements containing specials with '"' doubling.
        Json txt = pgArrayTextToJson( "{\"a\",\"b\"}" );
        check( "pgArrayTextToJson: quoted text-array elements decode as strings",
               txt.is_array() && txt.size() == 2
               && txt[ 0 ] == Json( "a" ) && txt[ 1 ] == Json( "b" ) );

        Json esc = pgArrayTextToJson( "{\"he said \\\"hi\\\"\"}" );
        check( "pgArrayTextToJson: pg backslash/doubled-quote escapes decode",
               esc.is_array() && esc.size() == 1 && esc[ 0 ] == Json( "he said \"hi\"" ) );

        // Not a bracketed literal: a bare scalar passes through unchanged.
        Json bare = pgArrayToNumbers( "4.5" );
        check( "pgArrayToNumbers: a non-braced scalar is returned as a 1-element result",
               bare.is_array() && bare.size() == 1 && near( bare[ 0 ].get<double>(), 4.5 ) );

        Json empty = pgArrayTextToJson( "{}" );
        check( "pgArrayTextToJson: an empty array literal decodes to an empty JSON array",
               empty.is_array() && empty.empty() );
    }

    // ---------- PostgreSQL-specific: bytea hex text extraction ----------
    check( "byteaTextToHex: strips the \\x prefix",
           byteaTextToHex( std::string( "\\xff00" ) ) == "ff00" );
    check( "byteaTextToHex: handles the uppercase \\X prefix too",
           byteaTextToHex( std::string( "\\Xff00" ) ) == "ff00" );
    check( "byteaTextToHex: the escape form (no \\x) arrives untouched",
           byteaTextToHex( std::string( "abc" ) ) == "abc" );

    return failed ? 1 : 0;
}