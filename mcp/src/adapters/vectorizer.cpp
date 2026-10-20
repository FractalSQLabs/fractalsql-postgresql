#include "vectorizer.h"
#include "../db.h"
#include "../vectors.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"
#include <stdexcept>

namespace fsqlmcp
{
    static Json voidOk( Db& db, const std::string& fn, const std::vector<std::optional<PgBind>>& args )
    {
        auto call = pgSelectCall( fn, args, false );
        const auto r = db.callScalar( call.first, call.second );
        return ( !r || r->empty() ) ? Json{ { "ok", true } } : Json::parse( *r );
    }

    std::vector<ToolSpec> buildVectorizerTools( Db& db )
    {
        std::vector<ToolSpec> t;

        // All ids are bigint. The registry and queue (fractal_vectorizers /
        // fractal_vectorizer_queue) are persistent tables, and the descriptions say so.
        t.push_back( ToolSpec{ "fractal_vectorizer_create", "vectorizer", ToolClass::Cheap,
            { Str("source_table", true, "Table to sync (needs a single-column primary key)."),
              Str("text_col", true, "Source text column."), Str("embedding_col", true, "Destination embedding column."),
              Obj("options", false, "{max_embeds_per_window:int, rate_window_secs:int=3600}") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && !a.at( "options" ).is_null() ? a.at( "options" ).dump() : "{}";
                auto call = pgSelectCall( "fractal_vectorizer_create", {
                    PgBind::s( "text", a.at( "source_table" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "text_col" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "embedding_col" ).get<std::string>() ),
                    PgBind::s( "jsonb", opts ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r || r->empty() ) throw ToolError( ErrorClass::Engine, "fractal_vectorizer_create returned no id" );
                return Json{ { "id", static_cast<std::int64_t>( std::strtoll( r->c_str(), nullptr, 10 ) ) } };
            } } );
        t.back().description = "Installs the AFTER INSERT/UPDATE sync trigger and immediately backfills the "
            "queue with rows missing an embedding. The (source_table,text_col,embedding_col) triple is unique — "
            "drop the old vectorizer first to re-create. Registry/queue live in persistent tables "
            "(fractal_vectorizers / fractal_vectorizer_queue). Returns {id:N}.";

        t.push_back( ToolSpec{ "fractal_vectorizer_pause", "vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) { return voidOk( db, "fractal_vectorizer_pause", {
                PgBind::s( "int8", a.at( "id" ).dump() ) } ); } } );
        t.back().description = "Disables a vectorizer (idempotent): the enqueue trigger stops queueing new rows "
            "AND the processor skips its pending rows — a full pause. Clean error on a nonexistent id.";

        t.push_back( ToolSpec{ "fractal_vectorizer_resume", "vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) { return voidOk( db, "fractal_vectorizer_resume", {
                PgBind::s( "int8", a.at( "id" ).dump() ) } ); } } );
        t.back().description = "Re-enables a paused vectorizer; already-queued rows are picked up on the next "
            "process-queue call. Clean error on a nonexistent id.";

        t.push_back( ToolSpec{ "fractal_vectorizer_drop", "vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) { return voidOk( db, "fractal_vectorizer_drop", {
                PgBind::s( "int8", a.at( "id" ).dump() ) } ); } } );
        t.back().description = "PERMANENT AND IRREVERSIBLE: deregisters the vectorizer, drops its trigger and "
            "cascades to every fractal_vectorizer_queue row. For a temporary stop use pause instead. Re-embedding "
            "after this needs a fresh create + full backfill.";

        // stale_after is an INTERVAL ('10 minutes' default). The tool takes seconds;
        // a bare integer is valid interval input (600 = '00:10:00'), so the value
        // stays $n-bound with an explicit ::interval cast.
        t.push_back( ToolSpec{ "fractal_vectorizer_process_queue", "vectorizer", ToolClass::Cheap,
            { Int("batch_size", false, "Rows per batch (LIMIT applies server-side).", 100),
              Int("stale_after", false, "Stale-claim reclaim window, seconds (bound as interval — 600 = 10 minutes).", 600) },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_vectorizer_process_queue", {
                    bindIf( a, "batch_size", "int4" ),
                    bindIf( a, "stale_after", "interval" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                return Json{ { "processed", r && !r->empty() ? Json( static_cast<std::int64_t>( std::strtoll( r->c_str(), nullptr, 10 ) ) ) : Json( 0 ) } };
            } } );
        t.back().description = "Drives the actual embedding sync — call on your own schedule; there is NO "
            "background worker in any engine, by design. Runs in a single transaction; failed rows are NOT "
            "retried automatically. Returns {processed:N}. stale_after is a postgres INTERVAL under the hood; "
            "give it seconds.";

        return t;
    }
}