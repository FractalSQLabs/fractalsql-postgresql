#pragma once
#include <optional>
#include <set>
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
    // Which protocol era a request belongs to. The modern era (MCP revision
    // 2026-07-28) is stateless: every request carries its own metadata and
    // there is no protocol session. The legacy era (2024-11-05 .. 2025-11-25)
    // keeps the initialize handshake and the Mcp-Session-Id header.
    enum class ProtocolEra { Legacy, Modern };

    // Per-request options the transport fills in and the dispatch core reads.
    struct CallOptions
    {
        ProtocolEra era = ProtocolEra::Legacy;
        // The context handle this request runs under (the modern era's
        // explicit per-client state handle). Empty when the request does not
        // address a stateful tool; in the legacy era the protocol session
        // supplies the context instead.
        std::string contextId;
        // The presenting credential's tool allowlist; unset means every tool.
        std::optional<std::set<std::string>> toolAllow;
    };

    struct ServerConfig
    {
        std::string serverName    = "fractalsql-mcp";
        std::string serverVersion = "0.0.0";
        RowLimitConfig rowLimits;
        bool readOnlyMode = false;      // FSQL_MCP_READ_ONLY — refuse destructiveHint tools before the engine
        // FSQL_MCP_PROTOCOL_ERA=modern: refuse the legacy handshake outright
        // and answer GET/DELETE with 405 for every request.
        bool modernOnly = false;
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
        std::optional<std::string> handleLine( std::string_view line, const std::string& clientKey,
                                               const CallOptions& opts );

        void cancel( const std::string& requestId );      // notifications/cancelled side effect
        void beginShutdown();
        bool isShuttingDown() const { return shuttingDown_; }
        std::size_t activeRequestCount();

        const std::vector<ToolSpec>& tools() const { return tools_; }

    private:
        std::optional<std::string> dispatch( const Json& req, const std::string& clientKey,
                                              const CallOptions& opts );
        Json handleInitialize( const Json& params );
        Json handleServerDiscover();
        Json handleToolsList( const CallOptions& opts );
        Json handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId,
                              const CallOptions& opts );
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