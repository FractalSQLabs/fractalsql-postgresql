#include "prompts.h"
#include "errors.h"
#include <vector>
#include <string>

namespace fsqlmcp
{
    struct PromptArg { const char* name; const char* desc; bool required; };
    // leastPrivSuffix: the per-prompt least-privilege note. It lives on the
    // prompt DEFINITION (not as a name check in get()) so that adding a
    // prompt cannot silently pick up — or silently lose — the safety note,
    // and so the list/read responses can expose which prompts carry it.
    struct PromptDef { const char* name; const char* desc; std::vector<PromptArg> args; const char* templateStr; const char* leastPrivSuffix; };

    static const char* const kLeastPriv =
        "\n\nSafety: point this connection at a least-privilege account (column-level grants, RLS where available) "
        "— this server enforces nothing beyond whatever role it was opened as. If this flow reaches "
        "fractal_sql_agent/fractal_text_to_sql, auto_execute defaults OFF; only pass auto_execute:true if you "
        "intend this agent to run the generated SQL under that same role.";

    // The value an OPTIONAL slot renders when the caller did not supply it.
    static const char* const kNotProvided = "(not provided)";

    // A slot counts as ABSENT when it is missing, JSON null, or the EMPTY
    // STRING. The empty string is the case that used to slip through: a
    // required slot supplied as "" rendered a hole into the prompt text
    // ("Call fractal_agent_data_analyst(question=)."), and the model was
    // left to guess what the empty argument meant. An empty required slot
    // is a parameter error now, exactly like a missing one.
    static bool slotAbsent( const Json& args, const PromptArg& a )
    {
        if( !args.contains( a.name ) ) return true;
        const Json& v = args.at( a.name );
        if( v.is_null() ) return true;
        return v.is_string() && v.get_ref<const std::string&>().empty();
    }

    static std::string slotValue( const Json& args, const PromptArg& a )
    {
        if( slotAbsent( args, a ) )
        {
            if( a.required )
                throw ToolError( ErrorClass::Schema, std::string( "missing required prompt argument: " ) + a.name );
            return kNotProvided;
        }
        const Json& v = args.at( a.name );
        return v.is_string() ? v.get_ref<const std::string&>() : v.dump();
    }

    // table_names is not a free-text slot: it scopes a call to a set of
    // tables, and the tool's own parameter is a JSON ARRAY of names (null =
    // auto-discover). The slot is documented as comma-separated, so the
    // value arrives as "orders, customers" — but the tool takes an array,
    // and the bare string would be read as ONE table named
    // "orders, customers". The value is normalised into the array form the
    // tool's schema documents; absent/empty renders as null, which is the
    // tool's own "auto-discover" spelling.
    static std::string formatTableNamesValue( const Json& args, const PromptArg& a )
    {
        if( slotAbsent( args, a ) )
        {
            // A required table_names slot is still a parameter error — the
            // special case only changes how a PRESENT value is rendered.
            if( a.required )
                throw ToolError( ErrorClass::Schema, std::string( "missing required prompt argument: " ) + a.name );
            return "null";
        }
        const Json& v = args.at( a.name );
        if( v.is_array() ) return v.dump();          // already the tool's shape
        const std::string raw = v.is_string() ? v.get_ref<const std::string&>() : v.dump();
        std::vector<std::string> names;
        std::string cur;
        auto flush = [&]()
        {
            const std::size_t b = cur.find_first_not_of( " \t\r\n" );
            if( b == std::string::npos ) { cur.clear(); return; }
            const std::size_t e = cur.find_last_not_of( " \t\r\n" );
            names.push_back( cur.substr( b, e - b + 1 ) );
            cur.clear();
        };
        for( char c : raw )
        {
            if( c == ',' ) flush();
            else cur.push_back( c );
        }
        flush();
        if( names.empty() ) return "null";
        return Json( names ).dump();
    }

    // The 11 prompts are engine-agnostic (section 4) — identical names, slots
    // and templates across the suite.
    static const std::vector<PromptDef> kPrompts{
        { "incident_triage", "DevOps/SRE: triage drift on one entity's metric series.",
          { {"log_table","Table holding the metric series.",true}, {"metric_col","Metric column.",true},
            {"time_col","Time-ordering column.",true}, {"filter_col","Entity filter column.",true}, {"filter_val","Entity filter value.",true} },
          "Call fractal_agent_anomaly_triage(log_table={log_table}, metric_col={metric_col}, time_col={time_col}, "
          "filter_col={filter_col}, filter_val={filter_val}). If it flags an anomaly, consider chaining into "
          "fractal_agent_route_task and fractal_agent_outlier_intercept.", kLeastPriv },
        { "portfolio_rebalance", "FinTech: rebalance a portfolio against its own history.",
          { {"mu","Expected returns.",true}, {"cov","Flattened covariance.",true}, {"cardinality","Max nonzero assets.",true}, {"alloc_table","Allocation-snapshots table.",true} },
          "Call fractal_agent_rebalance_sibling(mu={mu}, cov={cov}, cardinality={cardinality}, alloc_table={alloc_table}, ...). "
          "For a multi-candidate view, also try fractal_agent_diverse_portfolios (Enterprise).", nullptr },
        { "patient_triage", "MedTech: cohort-restricted patient deterioration triage.",
          { {"patient_table","Patient table.",true}, {"vec_col","Embedding column.",true}, {"query_vec","Query vector.",true}, {"cohort_predicate","Optional cohort filter.",false} },
          "Call fractal_agent_patient_deterioration_triage(patient_table={patient_table}, vec_col={vec_col}, query_vec={query_vec}, "
          "cohort_doc_ids=<{cohort_predicate} ctid doc_ids>).", nullptr },
        { "fleet_detour_check", "Fleet-logistics: classify a vehicle detour.",
          { {"vehicle_table","Fleet table.",true}, {"baseline_vec","Baseline vector.",true}, {"current_vec","Current vector.",true}, {"gps_trace","GPS trace.",true} },
          "Call fractal_agent_detour_classify(vehicle_table={vehicle_table}, baseline_vec={baseline_vec}, current_vec={current_vec}, gps_trace={gps_trace}).", nullptr },
        { "track_anomaly_check", "Maritime/cybersecurity: track-deviation / beaconing check.",
          { {"track_table","Track table.",true}, {"baseline_vec","Baseline vector.",true}, {"current_vec","Current vector.",true}, {"heading_series","Heading series.",true} },
          "Call fractal_agent_track_anomaly(track_table={track_table}, baseline_vec={baseline_vec}, current_vec={current_vec}, heading_series={heading_series}).", nullptr },
        { "sensor_grid_health", "Smart-cities: sensor-grid coverage alert.",
          { {"point_cloud","Sensor-grid point cloud.",true}, {"drift_series","Drift series.",true} },
          "Call fractal_agent_network_coverage_alert(point_cloud={point_cloud}, drift_series={drift_series}).", nullptr },
        { "churn_recovery", "Customer-Support: recall + diverse recommend for a churn-risk customer.",
          { {"customer_id","Customer id.",true}, {"mem_table","Memory table.",true}, {"catalog_table","Catalog table.",true} },
          "Call fractal_agent_recall_hybrid against {mem_table} for {customer_id}'s history, then "
          "fractal_agent_recommend_diverse against {catalog_table}.", nullptr },
        { "ask_my_data", "Horizontal catch-all: ask a natural-language question of your data.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Call fractal_agent_data_analyst(question={question}, table_names={table_names}).", kLeastPriv },
        { "safe_sql_question", "Just show me the SQL — never auto-executes.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Call fractal_text_to_sql(question={question}) — or fractal_sql_agent with auto_execute explicitly OFF — "
          "and show the generated statement without running it.", kLeastPriv },
        { "diversity_audit", "Self-contained Diversify health-check cycle.",
          { {"catalog_table","Catalog table.",true}, {"emb_col","Embedding column.",true}, {"warmup_table","Warmup table.",true} },
          "Call fractal_agent_feedback_audit(catalog_table={catalog_table}, emb_col={emb_col}, warmup_table={warmup_table}).", nullptr },
        { "ciso_ledger_check", "Enterprise: periodic ledger-chain integrity audit.",
          { {"kind","1 (QTL) or 2 (decision audit).",true} },
          "Call fractal_ledger_verify(kind={kind}) and report ok / rows_verified or the first_failure_id and reason.", nullptr }
    };

    Json Prompts::list()
    {
        Json arr = Json::array();
        for( const PromptDef& p : kPrompts )
        {
            Json args = Json::array();
            for( const PromptArg& a : p.args )
                args.push_back( Json{ {"name",a.name}, {"description",a.desc}, {"required",a.required} } );
            Json entry{ {"name",p.name}, {"description",p.desc}, {"arguments",args} };
            // The safety note is part of the prompt's contract, so it is
            // visible in the list too — a client can tell which prompts
            // carry it without having to render each one first.
            if( p.leastPrivSuffix ) entry[ "leastPrivSuffix" ] = std::string( p.leastPrivSuffix );
            arr.push_back( entry );
        }
        return Json{ { "prompts", arr } };
    }

    Json Prompts::get( const std::string& name, const Json& args )
    {
        for( const PromptDef& p : kPrompts )
        {
            if( p.name != name ) continue;
            std::string filled = p.templateStr;
            for( const PromptArg& a : p.args )
            {
                const std::string placeholder = "{" + std::string( a.name ) + "}";
                // table_names is the one slot with a shape of its own; every
                // other slot renders its value verbatim.
                const std::string value = ( std::string( a.name ) == "table_names" )
                    ? formatTableNamesValue( args, a )
                    : slotValue( args, a );
                std::size_t pos = 0;
                while( ( pos = filled.find( placeholder, pos ) ) != std::string::npos )
                {
                    filled.replace( pos, placeholder.size(), value );
                    // Resume AFTER the inserted text: a value that itself
                    // contains the placeholder must not make this loop spin
                    // forever on the substituted copy.
                    pos += value.size();
                }
            }
            if( p.leastPrivSuffix ) filled += p.leastPrivSuffix;
            Json out{ { "description", p.desc },
                { "messages", Json::array( { Json{ {"role","user"}, {"content", { {"type","text"}, {"text", filled} } } } } ) } };
            if( p.leastPrivSuffix ) out[ "leastPrivSuffix" ] = std::string( p.leastPrivSuffix );
            return out;
        }
        throw ToolError( ErrorClass::Schema, "unknown prompt: " + name );
    }
}