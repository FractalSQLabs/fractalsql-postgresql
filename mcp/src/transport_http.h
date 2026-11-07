#pragma once
#include <string>
#include <vector>
#include <functional>
#include <memory>
#include "jsonrpc_server.h"

namespace fsqlmcp
{
    struct HttpConfig
    {
        int port = 8765;
        std::string host;               // FSQL_MCP_HTTP_HOST / --host (default 127.0.0.1; "0.0.0.0" = all interfaces)
        std::string path = "/mcp";
        std::string authToken;          // FSQL_MCP_AUTH_TOKEN
        std::string authTokenFile;      // FSQL_MCP_AUTH_TOKEN_FILE (hot-reloaded, 10.3)
        // Per-client credentials (FSQL_MCP_TOKEN_POLICY_FILE): a JSON file
        // naming clients, each with the SHA-256 of its token, an optional
        // expiry and an optional tool allowlist. The file holds no secret.
        std::string tokenPolicyFile;
        // Browser origins allowed to call this server (FSQL_MCP_ALLOWED_ORIGINS),
        // comma-separated. Loopback origins are always allowed.
        std::vector<std::string> allowedOrigins;
        bool tlsEnabled = false;
        std::string tlsCertPath, tlsKeyPath;
        int shutdownDrainMs = 5000;
        std::size_t bodyCapBytes = 32ull * 1024ull * 1024ull;   // 10.7's abuse cap
    };

    // Minimal threaded HTTP/1.1 listener — no Boost.Asio/libuv, per 7.0's toolchain
    // rule. Every path except GET /healthz and GET /readyz requires a valid Bearer
    // token. One dedicated DB session per Mcp-Session-Id (1.1's per-client
    // isolation requirement — Diversify/shadow state is per backend connection):
    // sessionFactory builds a fresh Db-backed JsonRpcServer per minted session
    // (main.cpp wires it), so all dispatch goes through per-session servers while
    // ConcurrencyManager stays process-global via ServerConfig::sharedConcurrency.
    // The modern protocol era mints no session: its state handles ("context_id")
    // get their own server from the same factory, so a context's connection is
    // as isolated as a session's.
    int runHttpTransport( const HttpConfig& cfg, std::function<bool()> readinessProbe,
                           std::function<std::shared_ptr<JsonRpcServer>()> sessionFactory );

    // The startup check for the per-client credential file: an empty string
    // means the file is absent or valid; a non-empty one says what is wrong
    // with it. A credential file that cannot be read or parsed is a startup
    // failure, never a silent "no authentication".
    std::string tokenPolicyError( const HttpConfig& cfg );
}
