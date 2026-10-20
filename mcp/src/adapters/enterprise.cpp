#include "enterprise.h"
#include "../db.h"
#include "../vectors.h"
#include "../tool_param_helpers.h"
#include "../pg_call.h"

namespace fsqlmcp
{
    static const char* const kEnterprise = " Enterprise tier — returns a clean 'enterprise tier not loaded' error on a Community install.";

    static Json voidOk( Db& db, const std::string& fn )
    {
        auto call = pgSelectCall( fn, {}, false );
        const auto r = db.callScalar( call.first, call.second );
        return ( !r || r->empty() ) ? Json{ { "ok", true } } : Json::parse( *r );
    }

    std::vector<ToolSpec> buildEnterpriseTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_ledger_flush", "enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return voidOk( db, "fractal_ledger_flush" ); } } );
        t.back().description = std::string("Encodes the truth+shadow ledgers into a QTL blob, appends it to the "
            "tamper-evident hash chain. A rewritten row breaks the chain; a deleted row leaves a visible id gap.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_load", "enterprise", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) { return voidOk( db, "fractal_ledger_load" ); } } );
        t.back().description = std::string("Hydrates in-memory ledgers from the chain's latest entry (tip-only, "
            "O(1)). On an integrity failure, diversify is auto-disabled and ledgers left empty.") + kEnterprise;

        // kind is optional (default 1); kind=2 is the decision-audit chain.
        // Verify does not need the enterprise library.
        t.push_back( ToolSpec{ "fractal_ledger_verify", "enterprise", ToolClass::Cheap,
            { Int("kind", false, "1=QTL chain, 2=decision-audit chain.", 1) }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                auto call = pgSelectCall( "fractal_ledger_verify", {
                    PgBind::s( "int4", std::to_string( a.value( "kind", 1 ) ) ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                if( !r ) return Json( nullptr );
                return Json::parse( *r );
            } } );
        t.back().description = "Walks the ENTIRE chain for the given kind (O(n)). Returns "
            "{ok:true,rows_verified:N} or {ok:false,first_failure_id:ID,reason:...}. Pure read-only "
            "forensic query — works even with NO enterprise library loaded, so a CISO audit never needs a license.";

        t.push_back( ToolSpec{ "fractal_ledger_compact", "enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return voidOk( db, "fractal_ledger_compact" ); } } );
        t.back().description = std::string("Defragments/re-packs the in-memory QTL representation. Normally runs "
            "lazily on flush; exposed for a predictable pause.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_reset_soft", "enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return voidOk( db, "fractal_ledger_reset_soft" ); } } );
        t.back().description = std::string("Soft-reset: clears the Shadow Ledger only — truth ledger and current "
            "epoch preserved, diversify state reseeded.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_reset_hard", "enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return voidOk( db, "fractal_ledger_reset_hard" ); } } );
        t.back().description = std::string("DESTRUCTIVE AND IRREVERSIBLE: hard-reset empties the ledgers "
            "completely (Truth + Shadow, epoch counter back to 1). No key rotation happens here.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_truth_count", "enterprise", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_ledger_truth_count", {}, false );
                const auto r = db.callScalar( call.first, call.second );
                return Json{ { "count", r && !r->empty() ? Json( static_cast<std::int64_t>( std::strtoll( r->c_str(), nullptr, 10 ) ) ) : Json( nullptr ) } };
            } } );
        t.back().description = std::string("Truth-side ledger entry count.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_shadow_count", "enterprise", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                auto call = pgSelectCall( "fractal_ledger_shadow_count", {}, false );
                const auto r = db.callScalar( call.first, call.second );
                return Json{ { "count", r && !r->empty() ? Json( static_cast<std::int64_t>( std::strtoll( r->c_str(), nullptr, 10 ) ) ) : Json( nullptr ) } };
            } } );
        t.back().description = std::string("Shadow-side ledger entry count.") + kEnterprise;

        t.push_back( ToolSpec{ "fractal_audit_unpack", "enterprise", ToolClass::Cheap,
            { Str("blob", true, "Hex-encoded QTL blob.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                // hex is converted via decode($1,'hex') in SQL; it is validated
                // here first, so a malformed blob is reported as a parameter error.
                auto call = pgSelectCall( "fractal_audit_unpack", { std::nullopt }, false );
                (void)call;
                (void)vectors::hexToBytes( a.at( "blob" ).get<std::string>() );
                const std::string sql = "SELECT fractal_audit_unpack(decode($1,'hex')::bytea)";
                const auto r = db.callScalar( sql, { a.at( "blob" ).get<std::string>() } );
                if( !r ) return Json( nullptr );
                return Json::parse( *r );
            } } );
        t.back().description = std::string("Decodes a persisted QTL blob into its audit JSON: one "
            "{epoch, doc_id, signal:'truth'|'shadow'|'neutral'} entry per ledger record, a top-level array.") + kEnterprise;

        // fractal_audit_log(entry_type text, payload jsonb) RETURNS void. The
        // payload must be valid JSON; it is checked here and reported as a
        // parameter error if not.
        t.push_back( ToolSpec{ "fractal_audit_log", "enterprise", ToolClass::Cheap,
            { Str("entry_type", true, "Decision-audit entry type."), Str("payload", true, "Payload — must be valid JSON; stored as jsonb.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string payload = a.at( "payload" ).get<std::string>();
                if( !Json::accept( payload ) )
                    throw ToolError( ErrorClass::Schema, "payload must be valid JSON (stored as jsonb on Postgres)" );
                auto call = pgSelectCall( "fractal_audit_log", {
                    PgBind::s( "text", a.at( "entry_type" ).get<std::string>() ),
                    PgBind::s( "jsonb", payload ) }, false );
                const auto r = db.callScalar( call.first, call.second );
                return ( !r || r->empty() ) ? Json{ { "ok", true } } : Json::parse( *r );
            } } );
        t.back().description = std::string("General decision-audit append to the kind=2 chain — every "
            "decision-making agent logs here automatically when enterprise is active; exposed directly too for "
            "custom provenance records. payload is stored as raw jsonb on Postgres (pass a JSON object).") + kEnterprise;

        return t;
    }
}