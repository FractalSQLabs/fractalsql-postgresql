#include "resources.h"
#include "db.h"
#include "errors.h"
#include "pg_call.h"
#include <array>
#include <tuple>

namespace fsqlmcp
{
    static Db* g_db = nullptr;
    void Resources::init( Db* db ) { g_db = db; }

    // Non-secret config keys read back through current_setting(). The
    // enterprise GUCs (fractalsql.enterprise_lib aside — readable, non-secret)
    // and any token/key-shaped GUC are never listed here.
    // agent_partial_reasoning_fail is per-session (see db.h applyAgentPartial)
    // and listed so a client can see this session's failure behaviour.
    static const std::array<const char*, 12> kConfigKeys{
        "fractalsql.reasoning_plugin", "fractalsql.http_url", "fractalsql.http_model",
        "fractalsql.http_allow_plaintext", "fractalsql.http_embed_url", "fractalsql.http_embed_model",
        "fractalsql.http_think", "fractalsql.text_to_sql_max_attempts",
        "fractalsql.text_to_sql_allowed_statements", "fractalsql.text_to_sql_use_review",
        "fractalsql.enterprise_lib", "fractalsql.agent_partial_reasoning_fail"
    };

    static Json textResource( const std::string& uri, const std::string& text )
    {
        return Json{ { "contents", Json::array( { Json{ { "uri", uri }, { "mimeType", "text/plain" }, { "text", text } } } ) } };
    }
    static Json jsonResource( const std::string& uri, const Json& body )
    {
        return Json{ { "contents", Json::array( { Json{ { "uri", uri }, { "mimeType", "application/json" }, { "text", body.dump() } } } ) } };
    }

    Json Resources::list()
    {
        return Json{ { "resources", Json::array( {
            Json{ {"uri","fractalsql://schema"}, {"name","Schema context"}, {"mimeType","text/plain"} },
            Json{ {"uri","fractalsql://config"}, {"name","Resolved config (non-secret)"}, {"mimeType","application/json"} },
            Json{ {"uri","fractalsql://ledger/{kind}"}, {"name","Ledger audit report"}, {"mimeType","application/json"} },
            Json{ {"uri","fractalsql://vectorizer/status"}, {"name","Vectorizer status"}, {"mimeType","application/json"} },
            Json{ {"uri","fractalsql://agents"}, {"name","Installable-agent catalog"}, {"mimeType","application/json"} }
        } ) } };
    }

    Json Resources::read( const std::string& uri )
    {
        if( !g_db ) throw ToolError( ErrorClass::ServerInternal, "resources not initialized" );

        if( uri == "fractalsql://schema" )
        {
            // LIVE (never cached) — walks the catalogs visible to this connection.
            auto call = pgSelectCall( "fractal_schema_context", {}, false );
            const auto t = g_db->callScalar( call.first, call.second );
            return textResource( uri, t.value_or( "" ) );
        }
        if( uri == "fractalsql://config" )
        {
            Json cfg = Json::object();
            for( const char* k : kConfigKeys )
            {
                const auto v = g_db->callScalar( "SELECT current_setting($1::text, true)", { std::string( k ) } );
                cfg[ k ] = v.has_value() && !v->empty() ? Json( *v ) : Json( nullptr );
            }
            Json body{ { "scope", "ALTER SYSTEM / GUC (async reload)" }, { "config", cfg },
                        { "secrets", "never exposed through any resource or tool" } };
            return jsonResource( uri, body );
        }
        if( uri.rfind( "fractalsql://ledger/", 0 ) == 0 )
        {
            const std::string kindStr = uri.substr( std::string( "fractalsql://ledger/" ).size() );
            int kind = 0;
            try { kind = std::stoi( kindStr ); } catch( ... ) { throw ToolError( ErrorClass::Schema, "ledger kind must be an integer" ); }
            if( kind != 1 && kind != 2 )
                throw ToolError( ErrorClass::Schema, "ledger kind must be 1 (QTL chain) or 2 (decision-audit chain)" );
            const auto t = g_db->callScalar( "SELECT fractal_ledger_verify($1::int4)", { std::to_string( kind ) } );
            return jsonResource( uri, t ? Json::parse( *t ) : Json( nullptr ) );
        }
        if( uri == "fractalsql://vectorizer/status" )
        {
            // fractal_vectorizer_status is a view, so SELECT * FROM it. If the
            // extension is not installed, the engine's "relation does not exist"
            // error is returned as-is.
            return jsonResource( uri, Json{ { "vectorizers", g_db->callRows( "SELECT * FROM fractal_vectorizer_status", {} ) } } );
        }
        if( uri == "fractalsql://agents" )
        {
            // Static catalog mirroring the 16 installable agents — one
            // {problem, agent, recipe} entry per agent, from the starter-kit map.
            static const std::array<std::tuple<const char*, const char*, const char*, const char*>, 16> kAgents{{
                { "A", "Page on-call at 3am with a drifting metric.",
                  "fractal_agent_anomaly_triage",
                  "log_table, metric_col, time_col, filter_col, filter_val (one entity's series)." },
                { "B", "Pick a cardinality-constrained portfolio and explain it.",
                  "fractal_agent_allocate",
                  "mu, cov (flattened), cardinality." },
                { "C", "Route an incoming task to the right sub-agent under budget.",
                  "fractal_agent_route_task",
                  "task_emb, cap_table, cap_emb_col, cap_id_col, budget." },
                { "D", "Pre-commit intercept of a bad state before acting.",
                  "fractal_agent_outlier_intercept",
                  "state_vec, history_table, emb_col, threshold, metric." },
                { "E", "Recall relevant memories under a hard metadata filter.",
                  "fractal_agent_recall_hybrid",
                  "mem_table, vec_col, query_vec, filter_col/filter_val, k." },
                { "F", "Diverse recommendations that avoid mode collapse.",
                  "fractal_agent_recommend_diverse",
                  "catalog_table, emb_col, query_vec, k (leaves Diversify ON)." },
                { "G", "Ask a natural-language question of your data, get a reasoned analysis.",
                  "fractal_agent_data_analyst",
                  "question, table_names (optional), max_retries, context." },
                { "H", "Cohort-restricted patient deterioration triage with drift.",
                  "fractal_agent_patient_deterioration_triage",
                  "patient_table, vec_col, query_vec, baseline_vec, current_vec, cohort_doc_ids." },
                { "I", "Prove the Diversify layer is healthy end to end.",
                  "fractal_agent_feedback_audit",
                  "catalog_table, emb_col, query_vec, warmup_table, warmup_vec_col." },
                { "J", "Place a workload on the best node in a cluster.",
                  "fractal_agent_schedule_workload",
                  "task_vec, node_table, node_emb_col, node_id_col." },
                { "K", "Rebalance a portfolio against its own history.",
                  "fractal_agent_rebalance_sibling",
                  "mu, cov, cardinality, alloc_table, alloc_emb_col, baseline_vec, seed." },
                { "L", "Classify a vehicle detour from its GPS trace.",
                  "fractal_agent_detour_classify",
                  "vehicle_table, emb_col, baseline_vec, current_vec, gps_trace." },
                { "M", "Flag maritime/cyber track deviation and beaconing.",
                  "fractal_agent_track_anomaly",
                  "track_table, emb_col, baseline_vec, current_vec, heading_series." },
                { "N", "Alert when a sensor grid's coverage has drifted.",
                  "fractal_agent_network_coverage_alert",
                  "point_cloud (256+ pts), drift_series, drift_win, drift_threshold." },
                { "O", "Triage a regime change in a single series.",
                  "fractal_agent_regime_triage",
                  "series, win, drift_threshold, context." },
                { "P", "Several structurally distinct good portfolios (Enterprise).",
                  "fractal_agent_diverse_portfolios",
                  "mu, cov, cardinality, n_restarts, objective_mode (sharpe/pareto)." }
            }};
            Json agents = Json::array();
            for( const auto& [ id, problem, agent, recipe ] : kAgents )
                agents.push_back( Json{ { "id", id }, { "problem", problem }, { "agent", agent }, { "recipe", recipe } } );
            return jsonResource( uri, Json{ { "agents", agents } } );
        }
        throw ToolError( ErrorClass::Schema, "unknown resource: " + uri );
    }
}