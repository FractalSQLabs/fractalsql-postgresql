#pragma once
#include <optional>
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <cstdint>
#include <functional>
#include "mcp_json.h"
#include "tool_registry.h"
#include "concurrency.h"

namespace fsqlmcp
{
    struct ServerConfig
    {
        std::string serverName    = "fractalsql-mcp";
        std::string serverVersion = "0.0.0";
        RowLimitConfig rowLimits;
        bool readOnlyMode = false;      // FSQL_MCP_READ_ONLY — refuse destructiveHint tools before the engine
        std::function<void()> cancelHook;   // 1.1's $/cancel side effect: PQcancel/pg_cancel_backend per engine
        // HTTP sessions build one JsonRpcServer each (per-session Db per 1.1) but
        // must keep ONE process-global 10.7 cap: when set, every session instance
        // shares the caller's manager instead of owning per-session counters.
        ConcurrencyManager* sharedConcurrency = nullptr;
    };

    // Transport-agnostic dispatch core — called identically from
    // transport_stdio.cpp (per-line) and transport_http.cpp (per-POST-body).
    class JsonRpcServer
    {
    public:
        JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg );

        // Returns std::nullopt for a notification (never reply to one).
        std::optional<std::string> handleLine( std::string_view line, const std::string& clientKey );

        void cancel( const std::string& requestId );      // notifications/cancelled side effect
        void beginShutdown();
        bool isShuttingDown() const { return shuttingDown_; }
        std::size_t activeRequestCount();

        const std::vector<ToolSpec>& tools() const { return tools_; }

    private:
        Json handleInitialize( const Json& params );
        Json handleToolsList();
        Json handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId );
        Json handleResourcesList();
        Json handleResourcesRead( const Json& params );
        Json handlePromptsList();
        Json handlePromptsGet( const Json& params );

        ServerConfig cfg_;
        std::vector<ToolSpec> tools_;
        std::unordered_map<std::string, const ToolSpec*> byName_;
        std::unique_ptr<ConcurrencyManager> ownedConc_;
        ConcurrencyManager* conc_;
        std::mutex inflightMu_;
        // In-flight and cancelled calls, keyed by request id. Each entry also
        // carries a unique token because clients may reuse request ids.
        std::unordered_map<std::string, std::uint64_t> inflightIds_;
        std::unordered_map<std::string, std::uint64_t> cancelledIds_;
        std::uint64_t nextInflightToken_ = 0;
        // std::atomic: written from the transports' shutdown path (often the
        // main/accept thread) and read from every per-connection thread's
        // isShuttingDown() check — a plain bool here is a data race (TSan
        // confirmed on the fully -fsanitize=thread build, not a
        // LD_PRELOAD-only interception which misses races in uninstrumented
        // code).
        std::atomic<bool> shuttingDown_{ false };
        std::atomic<std::size_t> active_{ 0 };
    };
}