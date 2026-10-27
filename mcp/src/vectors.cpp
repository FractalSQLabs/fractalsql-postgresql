#include "vectors.h"
#include <charconv>
#include <cmath>
#include <cstring>
#include <sstream>
#include <array>
#include <cstdlib>

namespace fsqlmcp::vectors
{
    Json coerceNumber( const Json& element )
    {
        if( element.is_boolean() )
            return element;                 // bools are NEVER coerced
        if( element.is_number() )
            return element;
        if( element.is_string() )
        {
            const std::string& s = element.get_ref<const std::string&>();
            char* end = nullptr;
            errno = 0;
            const double v = std::strtod( s.c_str(), &end );
            const bool wholeStringConsumed = end != nullptr && *end == '\0' && end != s.c_str();
            if( wholeStringConsumed && errno == 0 && std::isfinite( v ) )
                return Json( v );
        }
        return element;                      // left alone; validation catches it later
    }

    static std::string formatDouble( double v )
    {
        // Shortest round-trippable form — load-bearing for 1.4's byte-identical
        // normalization promise. std::to_chars (C++17, <charconv>) gives the
        // shortest string that round-trips exactly, unlike "%g"/"%f".
        std::array<char, 64> buf{};
        auto res = std::to_chars( buf.data(), buf.data() + buf.size(), v );
        return std::string( buf.data(), res.ptr );
    }

    std::string vectorParamToText( const Json& value, std::string_view paramName )
    {
        if( value.is_null() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must not be null" );
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of numbers" );
        if( value.empty() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must not be an empty array" );

        std::vector<std::string> bad;
        std::ostringstream out;
        bool first = true;
        for( const Json& rawElem : value )
        {
            const Json elem = coerceNumber( rawElem );
            if( !elem.is_number() || elem.is_boolean() || !std::isfinite( elem.get<double>() ) )
            {
                if( bad.size() < 3 )
                    bad.push_back( rawElem.dump() );
                continue;
            }
            if( !first )
                out << ',';
            first = false;
            out << formatDouble( elem.get<double>() );
        }
        if( !bad.empty() )
        {
            std::string msg = std::string( paramName ) + " contains non-numeric element(s): ";
            for( std::size_t i = 0; i < bad.size(); ++i )
                msg += ( i ? ", " : "" ) + bad[ i ];
            throw ToolError( ErrorClass::Schema, msg );
        }
        return out.str();
    }

    std::string intArrayToJsonText( const Json& value, std::string_view paramName )
    {
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of integers" );
        Json out = Json::array();
        for( const Json& e : value )
        {
            if( !e.is_number_integer() )
                throw ToolError( ErrorClass::Schema, std::string( paramName ) + " elements must be integers (no lenient coercion here)" );
            out.push_back( e );
        }
        return out.dump();
    }

    std::string stringArrayToJsonText( const Json& value, std::string_view paramName )
    {
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of strings" );
        for( const Json& e : value )
            if( !e.is_string() )
                throw ToolError( ErrorClass::Schema, std::string( paramName ) + " elements must be strings" );
        return value.dump();
    }

    Json blobToNumbers( const std::uint8_t* data, std::size_t len )
    {
        if( len < 4 )
            throw ToolError( ErrorClass::ServerInternal, "fractal_vector BLOB shorter than its own header" );
        const std::uint16_t dim = static_cast<std::uint16_t>( data[ 0 ] | ( data[ 1 ] << 8 ) );
        // data[2..3] = reserved, ignored.
        const std::size_t need = 4u + static_cast<std::size_t>( dim ) * 4u;
        if( len < need )
            throw ToolError( ErrorClass::ServerInternal, "fractal_vector BLOB shorter than its declared dimension" );

        Json out = Json::array();
        for( std::uint16_t i = 0; i < dim; ++i )
        {
            float f;
            std::memcpy( &f, data + 4 + i * 4, 4 );               // float32 LE
            const double rounded = std::round( static_cast<double>( f ) * 1e14 ) / 1e14;
            out.push_back( rounded );
        }
        return out;
    }

    std::string blobToHex( const std::uint8_t* data, std::size_t len )
    {
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        out.reserve( len * 2 );
        for( std::size_t i = 0; i < len; ++i )
        {
            out.push_back( kHex[ data[ i ] >> 4 ] );
            out.push_back( kHex[ data[ i ] & 0xF ] );
        }
        return out;
    }

    Json wrapScalar( const Json& value )
    {
        if( value.is_null() )
            return Json{ { "value", nullptr } };
        if( value.is_number() && !value.is_boolean() )
        {
            const double d = value.get<double>();
            if( !std::isfinite( d ) )
                return Json{ { "value", nullptr } };
        }
        return Json{ { "value", value } };
    }

    // ---------- Postgres-specific ----------

    // Splits a pg array literal's top-level elements: "{1,2,NULL}" ->
    // ["1","2","NULL"]. Handles quoted elements (text[]) with '"' doubling
    // and backslash escapes; nested arrays are treated atomically (postgres
    // emits sub-literals in braces — callers here never need those).
    static std::vector<std::string> pgArrayElements( const std::string& text )
    {
        auto trimWs = []( const std::string& s )
        {
            std::size_t b = s.find_first_not_of( " \t\r\n" );
            if( b == std::string::npos ) return std::string();
            std::size_t e = s.find_last_not_of( " \t\r\n" );
            return s.substr( b, e - b + 1 );
        };

        // A raw value straight from PQgetvalue on a non-array type may arrive
        // here by accident; only treat braces as brackets when they bracket.
        if( text.size() < 2 || text.front() != '{' || text.back() != '}' )
        {
            if( !text.empty() ) return { text };
            return {};
        }

        std::vector<std::string> out;
        std::string cur;
        bool inQuote = false, escaped = false;
        for( std::size_t i = 1; i + 1 < text.size(); ++i )
        {
            const char c = text[ i ];
            if( inQuote )
            {
                if( escaped )            { cur.push_back( c ); escaped = false; }
                else if( c == '\\' )     { cur.push_back( c ); escaped = true; }
                else if( c == '"' )      { inQuote = false; cur.push_back( c ); }
                else                     cur.push_back( c );
                continue;
            }
            if( c == '"' )               { inQuote = true; cur.push_back( c ); continue; }
            if( c == ',' )
            {
                out.push_back( trimWs( cur ) );
                cur.clear();
                continue;
            }
            cur.push_back( c );
        }
        // The final element is pushed unconditionally EXCEPT for the empty
        // literal "{}": its last cur is "" for a different reason — the
        // literal has no elements at all — and pushing it would decode "{}"
        // as [""], a one-element array, instead of []. A real empty string
        // ELEMENT always arrives quoted in a pg array literal text ("\"\""),
        // which yields a 2-char non-empty cur, so this is safe.
        if( !out.empty() || !cur.empty() ) out.push_back( trimWs( cur ) );
        return out;
    }

    // A bare (unquoted) element equal to NULL is a SQL NULL (postgres array
    // literal convention). stripQuotes removes one level of pg quoting.
    static Json pgElementToJson( const std::string& e, bool numericOnly )
    {
        if( e.size() >= 2 && e.front() == '"' && e.back() == '"' )
        {
            std::string inner;
            bool escaped = false;
            for( std::size_t i = 1; i + 1 < e.size(); ++i )
            {
                const char c = e[ i ];
                if( escaped )      { inner.push_back( c ); escaped = false; continue; }
                if( c == '\\' )    { escaped = true; continue; }
                if( c == '"' && i + 2 < e.size() && e[ i + 1 ] == '"' ) { inner.push_back( '"'); ++i; continue; }
                inner.push_back( c );
            }
            if( !numericOnly )
                return Json( inner );
            // quoted-but-numeric happens only for text arrays; leave as string
            return Json( inner );
        }
        if( e == "NULL" )
            return Json( nullptr );
        char* end = nullptr;
        errno = 0;
        const double v = std::strtod( e.c_str(), &end );
        if( end != nullptr && *end == '\0' && end != e.c_str() && errno == 0 && std::isfinite( v ) )
            return Json( v );
        if( numericOnly )
            return Json( e );   // caller decides; usually better than losing data
        return Json( e );
    }

    Json pgArrayTextToJson( const std::string& text )
    {
        Json out = Json::array();
        for( const std::string& e : pgArrayElements( text ) )
            out.push_back( pgElementToJson( e, false ) );
        return out;
    }

    Json pgArrayToNumbers( const std::string& text )
    {
        Json out = Json::array();
        for( const std::string& e : pgArrayElements( text ) )
            out.push_back( pgElementToJson( e, true ) );
        return out;
    }

    std::string byteaTextToHex( const std::string& text )
    {
        if( text.size() >= 2 && ( text[ 0 ] == '\\' ) && ( text[ 1 ] == 'x' || text[ 1 ] == 'X' ) )
            return text.substr( 2 );
        return text;    // legacy bytea_output=escape form arrives untouched; callers rarely see it with modern defaults
    }

    std::vector<std::uint8_t> hexToBytes( const std::string& hex )
    {
        auto hexVal = []( char c ) -> int
        {
            if( c >= '0' && c <= '9' ) return c - '0';
            if( c >= 'a' && c <= 'f' ) return c - 'a' + 10;
            if( c >= 'A' && c <= 'F' ) return c - 'A' + 10;
            return -1;
        };
        std::vector<std::uint8_t> out;
        out.reserve( hex.size() / 2 );
        int hi = -1;
        for( char c : hex )
        {
            const int v = hexVal( c );
            if( v < 0 )
                throw ToolError( ErrorClass::Schema, "invalid hex string" );
            if( hi < 0 ) hi = v;
            else { out.push_back( static_cast<std::uint8_t>( ( hi << 4 ) | v ) ); hi = -1; }
        }
        if( hi >= 0 )
            throw ToolError( ErrorClass::Schema, "hex string must have an even number of digits" );
        return out;
    }
}