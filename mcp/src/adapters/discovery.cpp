#include "discovery.h"
#include "../db.h"
#include "../vectors.h"
#include "../rows.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"
#include <cmath>
#include <cstdlib>

namespace fsqlmcp
{
    // Postgres RETURNS void functions surface as a one-row "" (or SQL NULL)
    // through callScalar — normalize to the plugin's {"ok":true} shape.
    static Json okOrParsed( const std::optional<std::string>& r )
    {
        if( !r || r->empty() ) return Json{ { "ok", true } };
        try { return Json::parse( *r ); } catch( ... ) { return Json{ { "ok", true } }; }
    }

    // float8 scalar text (possibly "NaN"/"Infinity") -> wrapScalar with the
    // non-finite -> JSON null folding applied.
    static Json floatTextToScalar( const std::optional<std::string>& r )
    {
        if( !r ) return vectors::wrapScalar( Json( nullptr ) );
        char* end = nullptr;
        errno = 0;
        const double v = std::strtod( r->c_str(), &end );
        if( end == r->c_str() || !std::isfinite( v ) )
            return vectors::wrapScalar( Json( nullptr ) );   // NaN -> null, matching the SQL NaN contract
        return vectors::wrapScalar( Json( v ) );
    }

    // SETOF float8[] rows come back as one column of "{a,b,c}" text per row.
    static Json floatArrayRows( Json rows )
    {
        Json out = Json::array();
        for( const Json& row : rows )
        {
            if( row.is_object() && !row.empty() )
                out.push_back( vectors::pgArrayToNumbers( row.begin().value().get<std::string>() ) );
        }
        return out;
    }

    std::vector<ToolSpec> buildDiscoveryTools( Db& db, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> t;

        // Sniper-mode convergence: fractal_sfs_converge(query float8[], iterations int4=30,
        // population_size int4=50, diffusion_factor int4=2) RETURNS float8[],
        // the best point itself.
        t.push_back( ToolSpec{ "fractal_sfs_converge", "discovery", ToolClass::Cheap,
            { Vec("query", true, "Query vector."),
              Int("iterations", false, "SFS iterations.", 30),
              Int("population_size", false, "SFS population size.", 50),
              Int("diffusion_factor", false, "SFS diffusion factor.", 2) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_sfs_converge", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    bindIf( a, "iterations", "int4" ), bindIf( a, "population_size", "int4" ),
                    bindIf( a, "diffusion_factor", "int4" ) }, false );
                return vectors::wrapScalar( vectors::pgArrayToNumbers(
                    db.callScalar( call.first, call.second ).value_or( "" ) ) );
            } } );
        t.back().description = "Sniper-mode SFS convergence to the single best point minimizing cosine distance "
            "to a query over the unit box — returns the best point as a plain JSON array of numbers. Pure "
            "convergence only on Postgres: use fractal_search_explore for diverse multi-result discovery.";

        t.push_back( ToolSpec{ "fractal_sfs_converge_debug", "discovery", ToolClass::Cheap,
            { Vec("query", true, "Query vector."),
              Int("iterations", false, "SFS iterations.", 30),
              Int("population_size", false, "SFS population size.", 50),
              Int("diffusion_factor", false, "SFS diffusion factor.", 2) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_sfs_converge_debug", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    bindIf( a, "iterations", "int4" ), bindIf( a, "population_size", "int4" ),
                    bindIf( a, "diffusion_factor", "int4" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return Json::parse( *r );   // jsonb straight from libpq
            } } );
        t.back().description = "Same Sniper convergence as fractal_sfs_converge with a full trajectory trace: {dim, "
            "generations, population_size, best_point, best_fit, best_fit_per_gen, paths}. best_point is a plain "
            "JSON array of numbers.";

        // Indexed nearest-neighbour search: fractal_search(table, col, query, k, options) -> TABLE(doc_id, distance, scan_pos).
        t.push_back( ToolSpec{ "fractal_search", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to search."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."), Int("k", false, "Neighbors to return.", 5),
              Obj("options", false, "{index:string, nprobe:int, rerank:int, use_index:bool=true, verify:bool=true, id_col:string='id', ids:int[] (restrict the search to these keys)}", Json::object() ),
              RowLimit() },
            std::nullopt, false, true,
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                auto call = pgSelectCall( "fractal_search", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ),
                    PgBind::s( "jsonb", opts ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().idempotentHint = true;
        t.back().description = "Indexed approximate K-nearest real table rows to a query vector: [{doc_id, distance, scan_pos}]. "
            "Probes the IVF index built by fractal_index_create (default nprobe calibrated at build time) and VERIFIES every "
            "candidate against the stored vectors, so distances are exact cosine distances, not approximations; rows added "
            "after the build are scanned exactly and deleted rows are dropped. Falls back to the exact scan when the table has "
            "no index. Rows are named by an integer key column (option id_col, default id), so doc_id is that key. The ids option "
            "restricts the search to a set of keys (for example to_jsonb(array_agg(id)) over an ordinary WHERE): a short set is scanned "
            "exactly, a long one goes through the index and is filtered. Does not apply Diversify repulsion: use "
            "fractal_search_telemetry for stateful diversity.";

        t.push_back( ToolSpec{ "fractal_index_create", "discovery", ToolClass::Expensive,
            { Str("table_name", true, "Table to index."), Str("vector_col", true, "Embedding column."),
              Obj("options", false, "{name:string, id_col:string='id', vector_format:INT8|INT4|FP16|FP32=INT8, nlist:int, pca_dim:int, target_recall:number=0.95, calibration_samples:int=200}", Json::object() ) },
            std::nullopt, true, false,   /* persists the index: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                auto call = pgSelectCall( "fractal_index_create", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "jsonb", opts ) }, false );
                return Json::parse( db.callScalar( call.first, call.second ).value_or( "null" ) );
            } } );
        t.back().description = "Builds an IVF index (k-means cells, INT8/INT4 residual codes on a PCA basis, or FP16/FP32) over an "
            "embedding column and stores it in the database (fractal_index_meta / fractal_index_cells). Needs an integer key "
            "column (id_col). Samples rows to calibrate the default nprobe to target_recall. Returns {name, format, rows, nlist, "
            "pca_dim, generation, bytes, calibrated_nprobe}. Refuses an existing name: use fractal_index_rebuild.";

        t.push_back( ToolSpec{ "fractal_index_ensure", "discovery", ToolClass::Expensive,
            { Str("table_name", true, "Table to index."), Str("vector_col", true, "Embedding column."),
              Obj("options", false, "Used only when it builds or rebuilds: same as fractal_index_create's options.", Json::object() ) },
            std::nullopt, true, false,   /* may build or change an index: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                auto call = pgSelectCall( "fractal_index_ensure", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "jsonb", opts ) }, false );
                return Json::parse( db.callScalar( call.first, call.second ).value_or( "null" ) );
            } } );
        t.back().description = "Leaves the index on a table and column fit to use, in one call: builds it when missing (created), folds in the "
            "added rows when that is all that is needed (refreshed), rebuilds after more than a quarter of the rows were added or a fifth "
            "deleted (rebuilt), and otherwise changes nothing (unchanged). Returns {name, action, status, generation, rows}. For a setup script "
            "or a scheduled job; a search never builds or changes an index.";

        t.push_back( ToolSpec{ "fractal_index_rebuild", "discovery", ToolClass::Expensive,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_index_rebuild", { PgBind::s( "text", a.at( "name" ).get<std::string>() ) }, false );
                return Json::parse( db.callScalar( call.first, call.second ).value_or( "null" ) );
            } } );
        t.back().description = "Full re-cluster from the table's current rows with the options the index was created with, as a new "
            "generation switched in atomically (readers never see a partial index). Replaces the previous generation.";

        t.push_back( ToolSpec{ "fractal_index_drop", "discovery", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_index_drop", { PgBind::s( "text", a.at( "name" ).get<std::string>() ) }, false );
                return Json{ { "dropped", db.callScalar( call.first, call.second ).value_or( "f" ) == "t" } };
            } } );
        t.back().description = "PERMANENT: deletes the index's stored cells and metadata (the table and its vectors are untouched; "
            "fractal_search falls back to the exact scan).";

        t.push_back( ToolSpec{ "fractal_index_info", "discovery", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_index_info", { PgBind::s( "text", a.at( "name" ).get<std::string>() ) }, false );
                return Json::parse( db.callScalar( call.first, call.second ).value_or( "null" ) );
            } } );
        t.back().idempotentHint = true;
        t.back().description = "Index format, dimension, cells, rows indexed vs now, delta/stale flags, calibrated default nprobe with "
            "its recall estimates, and the last search's statistics in this backend session (used_index, rows_scanned, cells_probed). "
            "Also a status (ready, stale, degraded, empty or orphaned) and an advice list: for example 'refresh: 60 rows were added since the "
            "build', 'rebuild: 30% of the rows were deleted', or 'the build's calibration reached recall 0.63 against a target of 0.95'.";

        t.push_back( ToolSpec{ "fractal_index_list", "discovery", ToolClass::Cheap,
            {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                const auto rows = db.callScalar( "SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text FROM fractal_index_list() t", {} ).value_or( "[]" );
                return Json{ { "indexes", Json::parse( rows ) } };
            } } );
        t.back().idempotentHint = true;
        t.back().description = "The catalog: one entry per index with name, table_name, vector_col, format, dim, rows indexed, rows_now, stale, "
            "status (ready, stale, degraded, empty or orphaned) and generation. An empty list means no index has been built in this database.";

        t.push_back( ToolSpec{ "fractal_index_candidates", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table the index covers."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."),
              Obj("options", false, "{near:int=6, per_cell:int=1, index:string}") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                const auto rows = db.callScalar(
                    "SELECT coalesce(to_json(fractal_index_candidates($1::text, $2::text, $3::float8[], $4::jsonb)), '[]'::json)::text",
                    { a.at( "table_name" ).get<std::string>(), a.at( "vector_col" ).get<std::string>(),
                      vectors::vectorParamToText( a.at( "query" ), "query" ), opts } ).value_or( "[]" );
                return Json{ { "candidates", Json::parse( rows ) } };
            } } );
        t.back().idempotentHint = true;
        t.back().description = "The row keys a Scout pass should look at: every row of the near nearest cells of the index plus per_cell representatives from "
            "the others, plus the rows newer than the index. A shortlist, not an answer: the distances are not computed here.";

        t.push_back( ToolSpec{ "fractal_index_refresh", "discovery", ToolClass::Expensive,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_index_refresh", { PgBind::s( "text", a.at( "name" ).get<std::string>() ) }, false );
                return Json::parse( db.callScalar( call.first, call.second ).value_or( "null" ) );
            } } );
        t.back().description = "Folds the rows added since the build into the index's cells, as a new generation switched in atomically, "
            "without retraining (the model is kept). Returns {name, added, rows, generation, refreshed}. Deleted rows and changed "
            "vectors are not touched: use fractal_index_rebuild when fractal_index_info advises a rebuild.";

        t.push_back( ToolSpec{ "fractal_search_explore", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."),
              Obj("options", false, "Scout options JSON: {iterations:int=15, population_size:int=50, "
                "diffusion_factor:int=2, walk:float=0.0, mmr_lambda:float=0.5}", Json::object() ),
              RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "limit", 100, rowCfg );   // ceiling discipline even though rows come from the option set
                Json options = a.contains( "options" ) && !a.at( "options" ).is_null()
                    ? a.at( "options" ) : Json::object();
                if( !options.is_object() )
                    throw ToolError( ErrorClass::Schema, "options must be a JSON object" );
                options[ "population_size" ] = std::min( bc.passed,
                    options.value( "population_size", bc.passed ) );
                auto call = pgSelectCall( "fractal_search_explore", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    PgBind::s( "jsonb", options.dump() ) }, true );
                return floatArrayRows( db.callRows( call.first, call.second ) );
            } } );
        t.back().description = "Scout-mode diverse population search over a real table's embedding column followed "
            "by MMR re-ranking to prevent mode collapse — the anti-collapsed-top-K primitive. Returns a JSON "
            "array of result vectors.";

        t.push_back( ToolSpec{ "fractal_search_telemetry", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."), Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                auto call = pgSelectCall( "fractal_search_telemetry", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Ground-truth K-nearest real table rows to a query vector, by exact cosine distance: "
            "[{doc_id, distance, scan_pos}]. doc_id is the row's real ctid, stringified — resolve it back with "
            "WHERE ctid::text = doc_id; scan_pos is the 0-indexed position within THIS call's scan, the handle "
            "fractal_feedback_report/fractal_isolate_background want (distinct from doc_id).";

        t.push_back( ToolSpec{ "fractal_hybrid_clinical_search", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."), StrArray("doc_ids", true, "The cohort: ctid-string locators into table_name."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                auto call = pgSelectCall( "fractal_hybrid_clinical_search", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "query" ), "query" ) ),
                    PgBind::textArr( vectors::stringArrayToJsonText( a.at( "doc_ids" ), "doc_ids" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Cohort-restricted sibling of fractal_search_telemetry: pass an explicit JSON array "
            "of ctid-string locators (the doc_ids a prior search returned) to restrict the scan before ranking. "
            "Errors 'docs in cohort did not qualify' on an empty cohort. doc_id/scan_pos semantics match "
            "fractal_search_telemetry, scan_pos counted within the cohort-filtered corpus.";

        t.push_back( ToolSpec{ "fractal_search_trajectory", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("baseline_vector", true, "Baseline state vector."), Vec("current_vector", true, "Current state vector."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                auto call = pgSelectCall( "fractal_search_trajectory", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "baseline_vector" ), "baseline_vector" ) ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "current_vector" ), "current_vector" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Drift-vector search: finds the K nearest rows to (current_vector - baseline_vector) "
            "— 'what changed', not 'where am I'. Returns [{doc_id, distance}]. CAUTION: doc_id here is ALWAYS a "
            "0-indexed scan position, never a row locator.";

        t.push_back( ToolSpec{ "fractal_cross_modal_search", "discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("morphology_vector", true, "Morphology modality vector."), Vec("clinical_vector", true, "Clinical modality vector."),
              Num("alpha_weight", true, "Weight given to the morphology vector, in [0,1]."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                auto call = pgSelectCall( "fractal_cross_modal_search", {
                    PgBind::s( "text", a.at( "table_name" ).get<std::string>() ),
                    PgBind::s( "text", a.at( "vector_col" ).get<std::string>() ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "morphology_vector" ), "morphology_vector" ) ),
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "clinical_vector" ), "clinical_vector" ) ),
                    PgBind::s( "float8", a.at( "alpha_weight" ).dump() ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Weighted concatenation of two modality vectors (e.g. morphology + clinical) before "
            "the search: [morphology*alpha, clinical*(1-alpha)]. Returns [{doc_id, distance}]; doc_id is a "
            "0-indexed scan position, not a row locator.";

        t.push_back( ToolSpec{ "fractal_diversify_enable", "discovery", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_diversify_enable", {}, false );
                return okOrParsed( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Turns on the stateful Diversify/Repulsion layer for THIS session: searches then "
            "avoid the neighbourhoods of negative-reported results ('shadows'). Off by default; session-scoped "
            "(per DB connection — the plugin holds one dedicated connection per client session).";
        t.back().idempotentHint = true;   // re-enabling an already-enabled session is a no-op

        t.push_back( ToolSpec{ "fractal_diversify_disable", "discovery", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_diversify_disable", {}, false );
                return okOrParsed( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Turns the Diversify/Repulsion layer back off for THIS session. "
            "fractal_agent_recommend_diverse leaves it ON — this is that tool's cleanup.";
        t.back().idempotentHint = true;
        // Six nullable arguments, all DEFAULT NULL; the function is not STRICT, so
        // omitted arguments keep the session's current value.
        t.push_back( ToolSpec{ "fractal_diversify_set_params", "discovery", ToolClass::Cheap,
            { Int("window_n", false, "Diversify window size."), Num("stall_threshold", false, "Stall threshold."),
              Num("repulsion_sigma", false, "Repulsion sigma."), Num("repulsion_weight", false, "Repulsion weight."),
              Int("max_shadows_considered", false, "Max shadows considered."), Int("tail_buffer_cap", false, "Tail buffer cap.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_diversify_set_params", {
                    bindIf( a, "window_n", "int4" ), bindIf( a, "stall_threshold", "float8" ),
                    bindIf( a, "repulsion_sigma", "float8" ), bindIf( a, "repulsion_weight", "float8" ),
                    bindIf( a, "max_shadows_considered", "int4" ), bindIf( a, "tail_buffer_cap", "int4" ) }, false );
                return okOrParsed( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Tunes the repulsion layer for THIS session. Every field optional — omitted fields "
            "keep the core's current value for the rest (the function takes six independent nullable arguments "
            "on Postgres, not one JSON blob). Takes effect on the next search.";

        t.push_back( ToolSpec{ "fractal_detect_collapse", "discovery", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_detect_collapse", {}, false );
                return floatTextToScalar( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Current diversity quotient (D_q) for THIS session from the last search. Returns "
            "null when Diversify is off or nothing has searched yet (the SQL layer surfaces NaN; folded to null "
            "here per the result-normalization contract).";

        t.push_back( ToolSpec{ "fractal_explain_result", "discovery", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_explain_result", {}, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return Json::parse( *r );   // session-level diagnostics: {dq, diversify_enabled, overhead_p99_us}
            } } );
        t.back().description = "Session-level Diversify diagnostics JSON: {dq, diversify_enabled, overhead_p99_us}.";

        t.push_back( ToolSpec{ "fractal_feedback_report", "discovery", ToolClass::Cheap,
            { Int("result_handle", true, "The scan_pos handle a prior search returned."),
              StrEnum("kind", true, "One of 'dwell', 'positive', 'negative'."),
              Int("dwell_ms", false, "Dwell time in milliseconds (omit for a bare negative/positive).") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_feedback_report", {
                    PgBind::s( "int8", a.at( "result_handle" ).dump() ),
                    PgBind::s( "text", a.at( "kind" ).get<std::string>() ),
                    bindIf( a, "dwell_ms", "int4" ) }, false );
                return okOrParsed( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Reports dwell/positive/negative engagement on a prior search result, feeding the "
            "shadow store when Diversify is enabled. result_handle is the scan_pos the result came from, NOT its "
            "doc_id. kind must be 'dwell', 'positive' or 'negative'.";

        t.push_back( ToolSpec{ "fractal_isolate_background", "discovery", ToolClass::Cheap,
            { Int("result_handle", true, "The scan_pos handle to reject outright.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_isolate_background", {
                    PgBind::s( "int8", a.at( "result_handle" ).dump() ) }, false );
                return okOrParsed( db.callScalar( call.first, call.second ) );
            } } );
        t.back().description = "Convenience wrapper for fractal_feedback_report(result_handle,'negative') with no "
            "dwell time — reject the result's neighbourhood outright.";

        // Read-only tools are marked idempotent for the whole catalog in
        // buildAllTools (tools_catalog.cpp). Diversify's stateful tools
        // (_enable/_disable/_set_params/feedback) are not read-only; the
        // enable/disable pair is marked idempotent there too.
        return t;
    }
}