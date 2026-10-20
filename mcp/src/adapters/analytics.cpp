#include "analytics.h"
#include "../db.h"
#include "../vectors.h"
#include "../rows.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"
#include <cmath>
#include <cstdlib>

namespace fsqlmcp
{
    // jsonb-returning analytics primitives (vascular_network, cortical_folding,
    // nerve_plexus_metric, morphological_complexity): the result fields are
    // JSON keys, not a composite record.
    static Json jsonbScalar( Db& db, const std::string& fn, const std::vector<std::optional<PgBind>>& args )
    {
        auto call = pgSelectCall( fn, args, false );
        const auto r = db.callScalar( call.first, call.second );
        if( !r ) return Json( nullptr );
        return Json::parse( *r );
    }

    static Json scalarJson( Db& db, const std::string& fn, const std::vector<std::optional<PgBind>>& args )
    { return jsonbScalar( db, fn, args ); }

    static Json voidOk( Db& db, const std::string& fn, const std::vector<std::optional<PgBind>>& args )
    {
        auto call = pgSelectCall( fn, args, false );
        const auto r = db.callScalar( call.first, call.second );
        return ( !r || r->empty() ) ? Json{ { "ok", true } } : Json::parse( *r );
    }

    // Vector-typed args (fractal_vector LP/quantize family): bind the float8[]
    // text literal and convert with the extension's own constructor — explicit,
    // overload-safe, and immune to pg cast ambiguity.
    static PgBind fv( const Json& a, const char* key )
    { return PgBind::s( "float8[]", vectors::vectorParamToText( a.at( key ), key ) ); }   // cast applied via fractal_vector_from_float8_array wrapper below

    static std::optional<PgBind> fvOpt( const Json& a, const char* key )
    {
        if( !a.contains( key ) || a.at( key ).is_null() ) return std::nullopt;
        return fv( a, key );
    }

    std::vector<ToolSpec> buildAnalyticsTools( Db& db, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> t;

        // Vector-typed primitives use "fractal_vector_from_float8_array($n::float8[])"
        // — pg_call.h emits the placeholder; the tools below build their own
        // templates inline, so nothing wraps the call SQL here any more.

        t.push_back( ToolSpec{ "fractal_dimension_dfa", "analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_dimension_dfa", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "series" ), "series" ) ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return vectors::wrapScalar( Json( nullptr ) );
                char* end = nullptr;
                const double v = std::strtod( r->c_str(), &end );
                if( end == r->c_str() ) return vectors::wrapScalar( Json( nullptr ) );
                return vectors::wrapScalar( Json( v ) );
            } } );
        t.back().description = "DFA scaling exponent (alpha): ~0.5 uncorrelated noise, ~1.0 1/f pink noise, ~1.5 "
            "Brownian motion, <0.5 anti-correlated. Documented minimum 16 points; this org's own testing found "
            "~24 is the real floor for a stable estimate.";

        t.push_back( ToolSpec{ "fractal_dimension_boxcount", "analytics", ToolClass::Cheap,
            { Vec("points", true, "Point cloud."), Int("dim", true, "Spatial dimension.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_dimension_boxcount", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "points" ), "points" ) ),
                    PgBind::s( "int4", a.at( "dim" ).dump() ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return vectors::wrapScalar( Json( nullptr ) );
                return vectors::wrapScalar( Json( std::strtod( r->c_str(), nullptr ) ) );
            } } );
        t.back().description = "Minkowski-Bouligand box-counting dimension of a point cloud. Documented minimum 8 "
            "points; for a STABLE estimate this org's own testing found it needs hundreds.";

        t.push_back( ToolSpec{ "fractal_dimension_drift", "analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series."), Int("win", false, "Window size (requires n >= win+16, win >= 16).", 48) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                // "win" is OPTIONAL with a default of 48 (the schema says so,
                // and the schema now emits that default). The SQL function's
                // own signature has no DEFAULT for it, so the default is
                // passed explicitly -- previously the key was REQUIRED while
                // the description advertised a default the handler could
                // never use, so a caller that omitted it got a schema error
                // instead of the documented default.
                auto call = pgSelectCall( "fractal_dimension_drift", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "series" ), "series" ) ),
                    bindOrDefault( a, "win", "int4", "48" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return Json::parse( *r );
            } } );
        t.back().description = "Regime-change detection: DFA exponent of the recent window vs the baseline. "
            "Returns {drift, recent_alpha, baseline_alpha}; drift is a SIGNED numeric (recent - baseline): "
            "positive = increasing complexity/irregularity, negative = approaching a more ordered state. "
            "Requires n >= win + 16, win >= 16.";

        t.push_back( ToolSpec{ "fractal_change_point_detect", "analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series."), Int("window", true, "Sliding window size (n >= 2*window)."),
              Num("threshold", false, "Pooled-stddev units to flag a boundary.", 2.0), Int("max_points", false, "Max boundaries returned.", 16) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_change_point_detect", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "series" ), "series" ) ),
                    PgBind::s( "int4", a.at( "window" ).dump() ),
                    bindIf( a, "threshold", "float8" ), bindIf( a, "max_points", "int4" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return vectors::pgArrayToNumbers( *r );   // RETURNS int8[]
            } } );
        t.back().description = "DFA's complement: localizes WHERE a series' mean and/or variance shifted, via a "
            "sliding two-sample test over adjacent windows. Returns a plain array of boundary indices, ascending, "
            "up to max_points.";

        t.push_back( ToolSpec{ "fractal_periodogram", "analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series (>= 4 points)."), Int("max_peaks", false, "Top peaks to return.", 8) },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "max_peaks", 8, rowCfg );
                auto call = pgSelectCall( "fractal_periodogram", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "series" ), "series" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Classical periodogram via exact O(n^2) DFT (not FFT). Returns [{freq, power}]: "
            "top max_peaks bins, descending power. Catches network-beaconing/retry-cadence DFA alone misses.";

        t.push_back( ToolSpec{ "fractal_spectrogram_entropy", "analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series (n >= win)."),
              Int("win", false, "Frame length, 8..512.", 64),
              Int("hop", false, "Samples between frame starts, >= 1.", 32),
              Int("max_frames", false, "Max frames returned, 1..4096.", 4096) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_spectrogram_entropy", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "series" ), "series" ) ),
                    bindOrDefault( a, "win", "int4", "64" ), bindOrDefault( a, "hop", "int4", "32" ),
                    bindOrDefault( a, "max_frames", "int4", "4096" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return vectors::pgArrayToNumbers( *r );   // RETURNS float8[]
            } } );
        t.back().description = "Short-time spectral entropy: slides a window over a series and returns, per frame, "
            "the normalized Shannon entropy (0..1) of its power spectrum (mean removed, Hann tapered). Low = energy "
            "in a few frequencies (beacon, retry loop, locked carrier); high = spread across the band (noise, "
            "jamming, lost structure). A constant frame reports 0.0, never NaN. Returns a plain array, one value "
            "per frame; feed it to fractal_change_point_detect to localize WHEN the structure changed.";

        // OUT-param record: SELECT * FROM fn(...); h0_bars is jsonb (auto-parsed
        // by decodeField), betti1 is int8.
        t.push_back( ToolSpec{ "fractal_tda_persistence_diagram", "analytics", ToolClass::Cheap,
            { Vec("points", true, "Point cloud (capped at 512 points)."), Int("dim", true, "Spatial dimension."),
              Int("max_dim", false, "0 (H0 only) or 1 (H0 + Betti-1 graph-cycle-rank estimate).", 1),
              Num("max_thresh", false, "Filtration threshold.", 1.0), Int("max_h0_bars", false, "Max H0 bars returned.", 64) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_tda_persistence_diagram", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "points" ), "points" ) ),
                    PgBind::s( "int4", a.at( "dim" ).dump() ),
                    bindIf( a, "max_dim", "int4" ), bindIf( a, "max_thresh", "float8" ),
                    bindIf( a, "max_h0_bars", "int4" ) }, true );
                auto row = db.callRow( call.first, call.second );
                if( !row ) throw ToolError( ErrorClass::Engine, "fractal_tda_persistence_diagram returned no row" );
                return *row;
            } } );
        t.back().description = "Topological persistence over a point cloud's Vietoris-Rips filtration. Returns the "
            "composite row {h0_bars, betti1} — betti1 is the underlying GRAPH's cycle rank (an integer), NOT full "
            "simplicial H1 — over-counts when a filled triangle exists.";

        t.push_back( ToolSpec{ "fractal_state_fingerprint", "analytics", ToolClass::Cheap,
            { Vec("vec", true, "State vector."), Int("n_bits", true, "SimHash bits."), Num("seed", false, "SimHash seed.", 0.0) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                // "seed" is optional and defaults to 0.0, matching the SQL function.
                // The seed picks the random hyperplanes, so fingerprints are only
                // comparable when computed with the same seed.
                auto call = pgSelectCall( "fractal_state_fingerprint", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "vec" ), "vec" ) ),
                    PgBind::s( "int4", a.at( "n_bits" ).dump() ),
                    bindOrDefault( a, "seed", "float8", "0.0" ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return Json( vectors::byteaTextToHex( *r ) );   // bytea "\x..." -> bare hex string
            } } );
        t.back().description = "Random-hyperplane SimHash (Charikar 2002) of a state vector, returned as a hex "
            "string, (n_bits+7)/8 bytes. Near-identical states collapse to the same or low-Hamming-distance "
            "fingerprint. GOTCHA: encode scalar states one-hot, not 1-dim.";

        // fingerprints bytea[]: bind hex strings as jsonb, convert with decode()
        // server-side — no binary literals ever appear in SQL text.
        t.push_back( ToolSpec{ "fractal_cycle_detect", "analytics", ToolClass::Cheap,
            { StrArray("fingerprints", true, "Hex fingerprints from fractal_state_fingerprint."),
              Int("hamming_threshold", false, "Match tolerance.", 0) },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "limit", 100, rowCfg ); (void)bc;
                const std::string sql = "SELECT * FROM fractal_cycle_detect(("
                    "SELECT array_agg(decode(x,'hex')::bytea) FROM jsonb_array_elements_text($1::jsonb) AS x"
                    "), $2::int4)";
                const std::vector<std::string> binds{
                    vectors::stringArrayToJsonText( a.at( "fingerprints" ), "fingerprints" ),
                    std::to_string( a.value( "hamming_threshold", 0 ) ) };
                return db.callRows( sql, binds );
            } } );
        t.back().description = "Brent's-algorithm streaming cycle detection over a fingerprint stream. Returns "
            "rows [{at_index, cycle_len}] (ascending); an empty array when no cycle was found. Stops at the "
            "FIRST cycle.";

        // arg type: fractal_vector — bind through the constructor (ASSIGNMENT cast exists, but we stay explicit).
        t.push_back( ToolSpec{ "fractal_vector_lp_distance", "analytics", ToolClass::Cheap,
            { Vec("a", true, "Vector a."), Vec("b", true, "Vector b."), Num("p", true, "Order (NOT a metric for 0<p<1).") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_vector_lp_distance", { std::nullopt, std::nullopt, std::nullopt }, false );
                (void)call;   // custom template below (fractal_vector constructor wrapping)
                const std::string sql =
                    "SELECT fractal_vector_lp_distance(fractal_vector_from_float8_array($1::float8[]),"
                    " fractal_vector_from_float8_array($2::float8[]), $3::float8)";
                const auto r = db.callScalar( sql, {
                    pgFloat8ArrayLiteral( vectors::vectorParamToText( a.at( "a" ), "a" ) ),
                    pgFloat8ArrayLiteral( vectors::vectorParamToText( a.at( "b" ), "b" ) ),
                    a.at( "p" ).dump() } );
                if( !r ) return vectors::wrapScalar( Json( nullptr ) );
                return vectors::wrapScalar( Json( std::strtod( r->c_str(), nullptr ) ) );
            } } );
        t.back().description = "Generalized L_p distance, any p > 0, over the engine's canonical fractal_vector "
            "representation. For 0 < p < 1 this is NOT a proper metric — never substitute silently for cosine/L2.";

        t.push_back( ToolSpec{ "fractal_vector_quantize_int8", "analytics", ToolClass::Cheap,
            { Vec("v", true, "Vector to quantize.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string sql = "SELECT * FROM fractal_vector_quantize_int8("
                    "fractal_vector_from_float8_array($1::float8[]))";
                auto row = db.callRow( sql, { pgFloat8ArrayLiteral( vectors::vectorParamToText( a.at( "v" ), "v" ) ) } );
                if( !row ) throw ToolError( ErrorClass::Engine, "fractal_vector_quantize_int8 returned no row" );
                Json out = *row;
                if( out.is_object() && out.contains( "codes" ) && out[ "codes" ].is_string() )
                    out[ "codes" ] = vectors::byteaTextToHex( out[ "codes" ].get<std::string>() );
                return out;   // {codes: hex, scale: float}
            } } );
        t.back().description = "Symmetric int8 quantization of one vector — 4x compression. Returns "
            "{codes: hex, scale}; dequantize via v[i] ~= codes[i]*scale.";

        t.push_back( ToolSpec{ "fractal_vector_quantize_binary", "analytics", ToolClass::Cheap,
            { Vec("v", true, "Vector to quantize.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string sql = "SELECT fractal_vector_quantize_binary("
                    "fractal_vector_from_float8_array($1::float8[]))";
                const auto r = db.callScalar( sql, { pgFloat8ArrayLiteral( vectors::vectorParamToText( a.at( "v" ), "v" ) ) } );
                if( !r ) return Json( nullptr );
                return Json( vectors::byteaTextToHex( *r ) );
            } } );
        t.back().description = "1-bit (sign) quantization — 32x compression, (dim+7)/8 bytes, MSB-first, returned "
            "as a hex string. Pairs with fractal_vector_hamming_distance for cheap pre-filtering.";

        t.push_back( ToolSpec{ "fractal_vector_hamming_distance", "analytics", ToolClass::Cheap,
            { Str("a", true, "Hex string from fractal_vector_quantize_binary."), Str("b", true, "Hex string from fractal_vector_quantize_binary.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                // (bytea, bytea) RETURNS int8; hex is converted to bytea via
                // decode($n,'hex') in SQL, never spliced into the text.
                auto call = pgSelectCall( "fractal_vector_hamming_distance", { std::nullopt, std::nullopt }, false );
                (void)call;
                // hexToBytes validates both strings are real hex, paired, before the call.
                (void)vectors::hexToBytes( a.at( "a" ).get<std::string>() );
                (void)vectors::hexToBytes( a.at( "b" ).get<std::string>() );
                const std::string sql = "SELECT fractal_vector_hamming_distance(decode($1,'hex')::bytea, decode($2,'hex')::bytea)";
                const std::vector<std::string> binds{ a.at( "a" ).get<std::string>(), a.at( "b" ).get<std::string>() };
                const auto r = db.callScalar( sql, binds );
                if( !r ) return vectors::wrapScalar( Json( nullptr ) );
                return vectors::wrapScalar( Json( static_cast<std::int64_t>( std::strtoll( r->c_str(), nullptr, 10 ) ) ) );
            } } );
        t.back().description = "Hamming distance between two binary-quantized vectors (hex strings). A cheap "
            "pre-filter ahead of a full-precision re-rank, not a distance substitute. Returns an integer.";

        // int4[] edges/faces — geometry-index arrays, flat pairs (verified v1.0.sql:1178-1214).
        t.push_back( ToolSpec{ "fractal_vascular_network", "analytics", ToolClass::Cheap,
            { Vec("node_coords", true, "Flat n_nodes x 3 coordinates."), IntArray("edges", true, "Flat n_edges x 2 node-index pairs."),
              Vec("arc_length", true, "Per-edge arc length.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return jsonbScalar( db, "fractal_vascular_network", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "node_coords" ), "node_coords" ) ),
                PgBind::s( "int4[]", vectors::vectorParamToText( a.at( "edges" ), "edges" ) ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "arc_length" ), "arc_length" ) ) } ); } } );
        t.back().description = "Vessel-network tortuosity + branch-density + fractal dimension from PRE-EXTRACTED "
            "graph geometry (not raw imaging). Returns {mean_tortuosity, branch_density, fractal_dimension} (jsonb).";

        t.push_back( ToolSpec{ "fractal_cortical_folding", "analytics", ToolClass::Cheap,
            { Vec("vertices", true, "Flat n_vertices x 3."), IntArray("faces", true, "Flat n_faces x 3 vertex indices.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return jsonbScalar( db, "fractal_cortical_folding", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "vertices" ), "vertices" ) ),
                PgBind::s( "int4[]", vectors::vectorParamToText( a.at( "faces" ), "faces" ) ) } ); } } );
        t.back().description = "Gyrification Index (Zilles et al. 1988) from a pre-extracted brain-surface mesh. "
            "Returns {mesh_area, hull_area, gyrification_index} (jsonb).";

        t.push_back( ToolSpec{ "fractal_nerve_plexus_metric", "analytics", ToolClass::Cheap,
            { Vec("node_coords", true, "Flat n_nodes x dim."), Int("dim", true, "Spatial dimension (typically 2)."),
              IntArray("edges", true, "Skeleton edges: flat node-index pairs.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return jsonbScalar( db, "fractal_nerve_plexus_metric", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "node_coords" ), "node_coords" ) ),
                PgBind::s( "int4", a.at( "dim" ).dump() ),
                PgBind::s( "int4[]", vectors::vectorParamToText( a.at( "edges" ), "edges" ) ) } ); } } );
        t.back().description = "Nerve-fiber plexus density + dimension from pre-extracted skeleton geometry "
            "(corneal confocal microscopy convention). Returns {fiber_length_density, branch_density, "
            "fractal_dimension} (jsonb).";

        t.push_back( ToolSpec{ "fractal_morphological_complexity", "analytics", ToolClass::Cheap,
            { Vec("points", true, "Pre-segmented mask's occupied points (~256+ for a stable read)."), Int("dim", true, "Spatial dimension.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return jsonbScalar( db, "fractal_morphological_complexity", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "points" ), "points" ) ),
                PgBind::s( "int4", a.at( "dim" ).dump() ) } ); } } );
        t.back().description = "Box-counting dimension + lacunarity of a pre-segmented mask. GOTCHA: wants ~256+ "
            "occupied points for a stable read — smaller clouds fail with rc=-1 rather than a confident wrong "
            "number. Returns {dimension, lacunarity} (jsonb).";

        // Postgres folds use_obl/diffusion_mode into trailing optionals; seed int8 DEFAULT NULL
        // (NOT a required seed like SQLite — do not require it here).
        t.push_back( ToolSpec{ "fractal_optimize_portfolio", "analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened 1-D row-major n x n covariance."),
              Int("k", true, "Max nonzero assets."), NullableNum("seed", "RNG seed."),
              Bool_("use_obl", false, "Opposition-Based Learning per SFS trial (off by default; doubles the affected step's cost).", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy' (heavy-tailed, can escape local optima).", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return scalarJson( db, "fractal_optimize_portfolio", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "mu" ), "mu" ) ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "cov" ), "cov" ) ),
                PgBind::s( "int4", a.at( "k" ).dump() ),
                bindIf( a, "seed", "int8" ),
                PgBind::s( "boolean", a.value( "use_obl", false ) ? "true" : "false" ),
                PgBind::s( "text", a.value( "diffusion_mode", std::string( "gaussian" ) ) ) } ); } } );
        t.back().description = "SFS cardinality-constrained Sharpe-ratio maximizer: the best K assets out of a "
            "large universe without brute-force exponential cost. Returns {sharpe, weights} (<=k nonzero, "
            "non-negative, summing to 1.0).";

        t.push_back( ToolSpec{ "fractal_optimize_portfolio_multimodal", "analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened covariance."), Int("k", true, "Max nonzero assets."),
              Int("n_restarts", false, "Independent restarts.", 8), Num("overlap_threshold", false, "Asset-overlap threshold.", 0.15),
              Num("quality_frac", false, "Quality fraction gate.", 0.90), NullableNum("seed", "RNG seed."),
              Bool_("use_obl", false, "Requires an enterprise core build with OBL support.", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy'.", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return scalarJson( db, "fractal_optimize_portfolio_multimodal", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "mu" ), "mu" ) ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "cov" ), "cov" ) ),
                PgBind::s( "int4", a.at( "k" ).dump() ),
                bindIf( a, "n_restarts", "int4" ), bindIf( a, "overlap_threshold", "float8" ),
                bindIf( a, "quality_frac", "float8" ), bindIf( a, "seed", "int8" ),
                PgBind::s( "boolean", a.value( "use_obl", false ) ? "true" : "false" ),
                PgBind::s( "text", a.value( "diffusion_mode", std::string( "gaussian" ) ) ) } ); } } );
        t.back().description = "Multi-restart diverse-candidate sibling of fractal_optimize_portfolio. Returns "
            "{candidates:[{sharpe,weights}...], n_found}. Enterprise tier — clean 'not loaded' error on Community.";

        t.push_back( ToolSpec{ "fractal_optimize_portfolio_multimodal_pareto", "analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened covariance."), Int("k", true, "Max nonzero assets."),
              Int("n_restarts", false, "Independent restarts.", 8), Int("max_front", false, "Pareto-front cap (1<=max_front<=n_restarts).", 8),
              NullableNum("seed", "RNG seed."), Bool_("use_obl", false, "OBL per trial.", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy'.", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return scalarJson( db, "fractal_optimize_portfolio_multimodal_pareto", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "mu" ), "mu" ) ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "cov" ), "cov" ) ),
                PgBind::s( "int4", a.at( "k" ).dump() ),
                bindIf( a, "n_restarts", "int4" ), bindIf( a, "max_front", "int4" ),
                bindIf( a, "seed", "int8" ),
                PgBind::s( "boolean", a.value( "use_obl", false ) ? "true" : "false" ),
                PgBind::s( "text", a.value( "diffusion_mode", std::string( "gaussian" ) ) ) } ); } } );
        t.back().description = "Pareto-front sibling: same restarts, scored by decomposed (return,risk), NSGA-II "
            "crowding-distance truncated. Returns {candidates:[{return,risk,sharpe,weights}...], n_found}. "
            "Enterprise tier.";

        t.push_back( ToolSpec{ "fractal_optimize_subset", "analytics", ToolClass::Cheap,
            { Vec("item_values", true, "Per-item scores."), Vec("upper_bounds", true, "Per-item weight cap, each in [0,1]."),
              Int("k", true, "Max nonzero items."), Vec("prev_weights", false, "Previous weights (enables turnover_penalty)."),
              Num("turnover_penalty", false, "Only meaningful with prev_weights set.", 0.0), NullableNum("seed", "RNG seed.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return scalarJson( db, "fractal_optimize_subset", {
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "item_values" ), "item_values" ) ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "upper_bounds" ), "upper_bounds" ) ),
                PgBind::s( "int4", a.at( "k" ).dump() ),
                fvOpt( a, "prev_weights" ),
                bindIf( a, "turnover_penalty", "float8" ),
                bindIf( a, "seed", "int8" ) } ); } } );
        t.back().description = "Value-weighted k-subset allocation over ANY scored item list: maximize "
            "sum(weight[i]*item_values[i]) with at most k nonzero, each weight<=upper_bounds[i], summing to 1.0. "
            "Returns {score, weights}. The sum of the k largest upper_bounds must reach 1.0 or no feasible "
            "subset exists (clean engine error).";

        // (doc_id int8, feature_array float8[]) RETURNS void -> {"ok":true}.
        t.push_back( ToolSpec{ "fractal_store_morphology", "analytics", ToolClass::Cheap,
            { Int("doc_id", true, "Feature-store key."), Vec("feature_array", true, "Feature vector.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) { return voidOk( db, "fractal_store_morphology", {
                PgBind::s( "int8", a.at( "doc_id" ).dump() ),
                PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "feature_array" ), "feature_array" ) ) } ); } } );
        t.back().description = "Upserts a feature vector against a doc_id key in the generic per-item feature "
            "store (fractalsql_feature_store, auto-created on first use). Last-writer-wins. Returns {ok:true}.";

        t.push_back( ToolSpec{ "fractal_mine_topology_negatives", "analytics", ToolClass::Cheap,
            { Vec("surrogate_vector", true, "Query vector into the feature store."), Int("k", false, "Neighbors to return.", 10), RowLimit() },
            std::nullopt, false, true,
            // rowCfg is captured by value: handlers outlive the build step.
            [&db,rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 10, rowCfg );
                auto call = pgSelectCall( "fractal_mine_topology_negatives", {
                    PgBind::s( "float8[]", vectors::vectorParamToText( a.at( "surrogate_vector" ), "surrogate_vector" ) ),
                    PgBind::s( "int4", std::to_string( bc.passed ) ) }, true );
                return annotateRows( db.callRows( call.first, call.second ), bc );
            } } );
        t.back().description = "Brute-force k-NN (true Euclidean, ascending) over the fractal_store_morphology "
            "feature store. Returns [{doc_id, distance}], nearest first. A stored row whose dimension "
            "mismatches the surrogate is skipped, not an error.";

        // Read-only tools are marked idempotent in buildAllTools. store_morphology
        // (an upsert) is neither read-only nor idempotent.
        return t;
    }
}