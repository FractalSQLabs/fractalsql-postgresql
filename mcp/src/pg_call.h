#pragma once
// Postgres adapter-layer call builder (fractalsql-postgresql-mcp only — this
// file is NOT part of the three-repo-identical core). Keeps 10.1 mechanically
// honest across ~70 adapter calls: caller-supplied VALUES only ever appear as
// $n text parameters; the SQL text is built from fixed per-argument cast
// descriptors, never from caller data. Absent optional arguments are omitted
// from the placeholder list entirely — passing NULL would NOT hit the SQL
// function's own DEFAULT (postgres only applies a default when the argument
// is omitted), and several defaults are NULL-vs-value sensitive (seed, context).
#include <optional>
#include <string>
#include <vector>

#include "db.h"

namespace fsqlmcp
{
    struct PgBind
    {
        enum Kind { Simple, TextArray /* jsonb->text[] conversion in SQL */ };
        Kind        kind = Simple;
        std::string cast;       // explicit cast, e.g. "float8[]" / "int4" / "text" / "int8" / "jsonb"
        std::string value;      // already-normalized text (from the vectors:: helpers)

        static PgBind s( const std::string& cast, const std::string& v )
        {
            // Array-typed casts ($n::float8[] / ::int4[]) bind a pg array literal:
            // in text parameter mode the bound string is parsed as-is, so the CSV
            // form must be braced ({0.1,0.2}).
            if( cast.size() >= 2 && cast.compare( cast.size() - 2, 2, "[]" ) == 0 )
                return PgBind{ Simple, cast, "{" + v + "}" };
            return PgBind{ Simple, cast, v };
        }
        static PgBind textArr( const std::string& v ) { return PgBind{ TextArray, "jsonb", v }; }
    };

    // Builds "SELECT [*] fn($1::t1, [snippet($2)], ...)" plus the matching bind
    // vector. Absent (nullopt) binds are omitted, preserving positional order
    // of the REMAINING arguments.
    inline std::pair<std::string, std::vector<std::string>>
    pgSelectCall( const std::string& fn, const std::vector<std::optional<PgBind>>& args, bool tableForm )
    {
        std::string sql = tableForm ? "SELECT * FROM " + fn + "(" : "SELECT " + fn + "(";
        std::vector<std::string> binds;
        bool first = true;
        int n = 0;
        for( const auto& opt : args )
        {
            if( !opt ) continue;
            const PgBind& b = *opt;
            ++n;
            std::string ph;
            switch( b.kind )
            {
                case PgBind::Simple:    ph = "$" + std::to_string( n ) + "::" + b.cast; break;
                case PgBind::TextArray: ph = "(SELECT array_agg(x) FROM jsonb_array_elements_text($" +
                                           std::to_string( n ) + "::jsonb) AS x)"; break;
            }
            if( !first ) sql += ", ";
            first = false;
            sql += ph;
            binds.push_back( b.value );
        }
        sql += ")";
        return { std::move( sql ), std::move( binds ) };
    }

    // Helper for a simple inline bind (keeps adapter tables one line per arg).
    inline std::optional<PgBind> bindIf( const Json& args, const char* key, const std::string& cast )
    {
        if( !args.contains( key ) || args.at( key ).is_null() ) return std::nullopt;
        const Json& v = args.at( key );
        if( v.is_boolean() ) return PgBind::s( cast, v.get<bool>() ? "true" : "false" );
        if( v.is_number() )  return PgBind::s( cast, v.dump() );
        return PgBind::s( cast, v.get<std::string>() );
    }

    // An optional argument that the tool advertises a DEFAULT for, where the
    // SQL function's own signature has NO default: the default has to be
    // passed EXPLICITLY, because postgres only applies a function's DEFAULT
    // when the argument is omitted, and a NULL would not apply it either.
    // Used where the tool's schema default and the handler's value must
    // agree -- a schema that advertises 48 while the handler requires the
    // key is a schema error the caller cannot avoid (gap T-A).
    inline std::optional<PgBind> bindOrDefault( const Json& args, const char* key,
                                                 const std::string& cast, const std::string& def )
    {
        if( !args.contains( key ) || args.at( key ).is_null() ) return PgBind::s( cast, def );
        return bindIf( args, key, cast );
    }
}