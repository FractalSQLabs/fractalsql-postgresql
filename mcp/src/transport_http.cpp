#include "transport_http.h"
#include "transport_socket.h"
#include "logging.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <mutex>
#include <thread>
#include <atomic>
#include <map>
#include <cstring>
#include <cstdio>
#include <csignal>
#include <cstdlib>
#include <chrono>
#include <algorithm>
#include <cctype>

namespace fsqlmcp
{
    namespace fs = std::filesystem;

    // ---------- TokenStore: constant-time compare + mtime hot-reload.
    // SIGHUP reloads the token file only; it never shuts the server down.

    // Declared before TokenStore: matches() is the flag's consumer. The
    // SIGHUP handler (below) must stay async-signal-safe BY CONSTRUCTION:
    // a single relaxed atomic store — malloc/logging/std::string inside a
    // signal context can deadlock on the allocator lock (the fully
    // -fsanitize=thread build flags the old form as "signal-unsafe call
    // inside of a signal").
    static std::atomic<bool> g_sighupReload{ false };

    class TokenStore
    {
    public:
        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        bool matches( const std::string& presented )
        {
            // SIGHUP's deferred work happens HERE, on an ordinary request
            // thread: the handler itself is one atomic store, so the actual
            // ifstream/filesystem token-file reload runs under matches()
            // instead of inside the signal context. On Windows there is no
            // SIGHUP handler (mtime-based per-request reload below covers
            // it) and the flag is never set — exchange() is a free no-op.
            const bool sighup = g_sighupReload.exchange( false );
            // ONE critical section for the whole decision (the reload AND
            // the compare). It used to take the lock twice — once for the
            // mtime reload, once for the compare — so a token rotation
            // landing between the two halves could be compared against a
            // half-updated state. The lock is held across the reload and
            // the timing-safe compare, so "the token that is in force" is
            // exactly the one the request is measured against.
            std::lock_guard<std::mutex> lk( mu_ );
            reloadLocked( sighup );
            if( token_.empty() ) return false;
            return presented.size() == token_.size()
                   && CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0;  // timing-safe compare
        }

        void reload( bool force )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            reloadLocked( force );
        }

    private:
        // The body of reload(): the caller MUST hold mu_.
        void reloadLocked( bool force )
        {
            if( !cfg_.authTokenFile.empty() )
            {
                long long mtime = 0;
                try { mtime = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        fs::last_write_time( cfg_.authTokenFile ).time_since_epoch() ).count(); }
                catch( ... ) { return; }   // unreadable token file: keep the current token
                if( force || mtime != lastMtime_ )
                {
                    std::ifstream in( cfg_.authTokenFile );
                    std::string t; std::getline( in, t );
                    while( !t.empty() && ( t.back() == '\n' || t.back() == '\r' ) ) t.pop_back();
                    // An empty or unreadable file keeps the last known token, so a
                    // token file being rewritten does not cause a burst of 401s.
                    // Auth stays closed either way: an empty token never matches.
                    if( !t.empty() ) { token_ = t; lastMtime_ = mtime; }
                }
                return;
            }
            token_ = cfg_.authToken;    // plain env-var form: no hot-reload
        }

        const HttpConfig& cfg_;
        std::mutex mu_;
        std::string token_;
        long long lastMtime_ = 0;
    };

#ifndef _WIN32
    static void onSighup( int ) { g_sighupReload.store( true, std::memory_order_relaxed ); }
#endif
    static std::atomic<bool> g_httpSignalled{ false };
    static void onHttpTermSignal( int ) { g_httpSignalled.store( true ); }

    // Per-client fairness key for the expensive-call cap
    // (FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT). With a static token
    // (FSQL_MCP_AUTH_TOKEN) every client sharing it shares one budget; with a
    // token file each session keeps its own.
    static std::string clientKeyFor( const HttpConfig& cfg, const std::string& bearer,
                                     const std::string& sessionId )
    {
        // Constant-time compare, as in TokenStore::matches, so the choice of
        // budget cannot leak the token by timing. Length is not secret.
        if( !cfg.authToken.empty() && bearer.size() == cfg.authToken.size()
            && CRYPTO_memcmp( bearer.data(), cfg.authToken.data(), bearer.size() ) == 0 )
            return "token:" + bearer.substr( 0, 8 );   // raw token never logged
        return "session:" + sessionId;
    }

    static std::string mintSessionId()
    {
        unsigned char raw[ 16 ] = {};
        if( RAND_bytes( raw, sizeof( raw ) ) != 1 )
        {
            // RAND_bytes failed: re-seed the OpenSSL RNG from the OS entropy
            // pool and try once more (RAND_poll is the documented way to do
            // that). NEVER fall back to ::rand(): an unseeded std::rand()
            // yields the SAME sequence in every process, so every restart
            // would mint the SAME session ids -- and a session id is a
            // credential (whoever holds it owns that session's database
            // connection and its Diversify state), which makes a
            // predictable one a session-hijacking primitive. If the
            // entropy source is still broken, refuse to mint: fail closed.
            RAND_poll();
            if( RAND_bytes( raw, sizeof( raw ) ) != 1 )
                throw ToolError( ErrorClass::ServerInternal,
                    "could not mint a session id: the system entropy source failed" );
        }
        static const char* const kHex = "0123456789abcdef";
        std::string out; out.reserve( 32 );
        for( unsigned char b : raw ) { out.push_back( kHex[ b >> 4 ] ); out.push_back( kHex[ b & 0xF ] ); }
        return out;
    }

    static std::string lowerCopy( std::string s )
    {
        std::transform( s.begin(), s.end(), s.begin(),
                        []( unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        return s;
    }

    static std::string trimCopy( const std::string& s )
    {
        const std::size_t b = s.find_first_not_of( " \t\r\n" );
        if( b == std::string::npos ) return "";
        const std::size_t e = s.find_last_not_of( " \t\r\n" );
        return s.substr( b, e - b + 1 );
    }

    // ---------- TLS plumbing (optional; OpenSSL BIO over the accepted socket) ----------

    class TlsLayer
    {
    public:
        static std::unique_ptr<TlsLayer> make( const HttpConfig& cfg )
        {
            if( !cfg.tlsEnabled ) return nullptr;
            SSL_CTX* ctx = SSL_CTX_new( TLS_server_method() );
            if( !ctx ) throw ToolError( ErrorClass::ServerInternal, "SSL_CTX_new failed" );
            // Fail-fast, one named check per failure mode: a CERTIFICATE load
            // failure and a PRIVATE-KEY load failure are different operator
            // mistakes (wrong file vs wrong contents), and a mismatched key is
            // yet another (SSL_CTX_check_private_key). The HTTPS smoke client
            // pins all three as distinct nonzero-exit startup cases, so the
            // error must say which check failed, plus the OpenSSL error
            // queue's own reason string for the real cause behind it.
            auto lastErrReason = [] {
                const unsigned long e = ERR_peek_last_error();
                const char* r = e ? ERR_reason_error_string( e ) : "";
                return r && *r ? std::string( r ) : std::string();
            };
            // Require TLS 1.2 or newer (TLS 1.0/1.1 are deprecated).
            if( SSL_CTX_set_min_proto_version( ctx, TLS1_2_VERSION ) != 1 )
            {
                const std::string r = lastErrReason();
                SSL_CTX_free( ctx );
                throw ToolError( ErrorClass::ServerInternal,
                    "TLS 1.2 minimum version could not be set"
                    + ( r.empty() ? std::string() : " - " + r ) );
            }
            // The certificate file may carry the full chain (leaf +
            // intermediates): use_certificate_chain_file loads them all, so a
            // client whose trust store holds only the root can still verify
            // us. use_certificate_file loaded the LEAF alone, which broke the
            // handshake for exactly those clients.
            if( SSL_CTX_use_certificate_chain_file( ctx, cfg.tlsCertPath.c_str() ) != 1 )
            {
                const std::string r = lastErrReason();
                SSL_CTX_free( ctx );
                throw ToolError( ErrorClass::ServerInternal,
                    "TLS certificate load failed (FSQL_MCP_TLS_CERT_FILE): not a parseable PEM cert"
                    + ( r.empty() ? std::string() : " - " + r ) );
            }
            if( SSL_CTX_use_PrivateKey_file( ctx, cfg.tlsKeyPath.c_str(), SSL_FILETYPE_PEM ) != 1 )
            {
                const std::string r = lastErrReason();
                SSL_CTX_free( ctx );
                // OpenSSL 3 checks the loaded cert at key-load time too, so a
                // mismatched (but individually valid) key surfaces HERE, not at
                // SSL_CTX_check_private_key — say so explicitly.
                if( r.find( "mismatch" ) != std::string::npos )
                    throw ToolError( ErrorClass::ServerInternal,
                        "TLS cert/key MISMATCH: the private key does not belong to the certificate - " + r );
                throw ToolError( ErrorClass::ServerInternal,
                    "TLS private key load failed (FSQL_MCP_TLS_KEY_FILE): not a parseable PEM or encrypted key"
                    + ( r.empty() ? std::string() : " - " + r ) );
            }
            if( SSL_CTX_check_private_key( ctx ) != 1 )
            {
                const std::string r = lastErrReason();
                SSL_CTX_free( ctx );
                throw ToolError( ErrorClass::ServerInternal,
                    "TLS cert/key MISMATCH: the private key does not belong to the certificate"
                    + ( r.empty() ? std::string() : " - " + r ) );
            }
            return std::unique_ptr<TlsLayer>( new TlsLayer( ctx ) );
        }

        ~TlsLayer() { if( ctx_ ) SSL_CTX_free( ctx_ ); }
        SSL_CTX* ctx() const { return ctx_; }

    private:
        explicit TlsLayer( SSL_CTX* ctx ) : ctx_( ctx ) {}
        SSL_CTX* ctx_ = nullptr;
    };

    class Conn
    {
    public:
        Conn( net::Socket s, SSL_CTX* sslCtx ) : sock_( s ), ssl_( nullptr )
        {
            if( sslCtx ) ssl_ = SSL_new( sslCtx );
        }
        ~Conn()
        {
            if( ssl_ ) { SSL_shutdown( ssl_ ); SSL_free( ssl_ ); }
            net::close( sock_ );
        }
        net::Socket sock() const { return sock_; }
        bool acceptTls()
        {
            if( !ssl_ ) return true;
            // SSL_set_fd takes a plain int; the shim's rawHandle() is the
            // one place that knows the platform's descriptor width.
            if( SSL_set_fd( ssl_, static_cast<int>( net::rawHandle( sock_ ) ) ) != 1 ) return false;
            return SSL_accept( ssl_ ) == 1;
        }
        // -1 hard error, 0 clean EOF, -2 idle, >0 bytes.
        int recvSome( char* buf, int len )
        {
            if( ssl_ )
            {
                const int n = SSL_read( ssl_, buf, len );
                if( n > 0 ) return n;
                const int err = SSL_get_error( ssl_, n );
                if( err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE ) return -2;
                return ( err == SSL_ERROR_ZERO_RETURN ) ? 0 : -1;
            }
            // The shim's recv() already classifies "would block / idle"
            // (-2) against errno, INSIDE the shim, immediately after the
            // syscall.
            const int n = net::recv( sock_, buf, len );
            if( n > 0 ) return n;
            if( n == 0 ) return 0;
            return n == -2 ? -2 : -1;
        }
        bool sendAll( const std::string& data )
        {
            std::size_t off = 0;
            while( off < data.size() )
            {
                int n;
                if( ssl_ )
                    n = SSL_write( ssl_, data.data() + off, static_cast<int>( data.size() - off ) );
                else
                    n = net::send( sock_, data.data() + off, static_cast<int>( data.size() - off ) );
                if( n <= 0 ) return false;
                off += static_cast<std::size_t>( n );
            }
            return true;
        }

    private:
        net::Socket sock_;
        SSL* ssl_;
    };

    // ---------- One HTTP request: header block + content-length body, read
    // incrementally from a persistent buffer. ONE request per connection:
    // every response carries `Connection: close` and the socket closes right
    // after, so a request body executes at most once per connection. Transfer-
    // Encoding: chunked is refused with 411 and over-cap bodies with 413 —
    // loud failures for framing this server deliberately does not implement.
    // Return codes: 0 ok, -1 fatal, -2 idle timeout. ----------

    struct HttpRequest { std::string method, target, version; std::multimap<std::string, std::string> headers; std::string body; bool valid=false; bool malformed=false; };

    // The header block is capped INDEPENDENTLY of the body cap: the body cap
    // is 32 MB by design (a large embedding upload is a legitimate request),
    // but a header block that may grow to the same size is only a way to
    // make the server buffer 32 MB of attacker-chosen header text per
    // connection. 64 KB is far above any real MCP request's headers.
    static constexpr std::size_t kHeaderCapBytes = 64ull * 1024ull;

    static int readRequest( Conn& c, const HttpConfig& cfg, HttpRequest& req, std::string& pending )
    {
        char buf[ 8192 ];
        std::size_t headerEnd;
        // Two-phase receive timeout: a new connection gets a short idle window
        // (2 s, set by the listener) so a silent connection is closed quickly.
        // Once the first byte arrives the window widens to 65 s so a slow
        // client uploading a large request is not cut off mid-request.
        bool widened = false;
        while( ( headerEnd = pending.find( "\r\n\r\n" ) ) == std::string::npos )
        {
            // The pending buffer can only exceed the header cap by the one
            // 8 KB read that carried the header terminator, so the slack
            // below never truncates a legitimate request.
            if( pending.size() > kHeaderCapBytes + sizeof( buf ) ) return -1;
            const int n = c.recvSome( buf, sizeof( buf ) );
            if( n == -2 && !g_httpSignalled.load() ) return -2;   // idle (or pre-request silence)
            if( n <= 0 ) return -1;
            if( !widened ) { widened = true; net::setRecvTimeout( c.sock(), 65000 ); }
            pending.append( buf, static_cast<std::size_t>( n ) );
        }

        {
            std::istringstream head( pending.substr( 0, headerEnd + 2 ) );
            std::string line;
            std::getline( head, line );
            req.method.clear(); req.target.clear(); req.version.clear();
            {
                std::istringstream rl( trimCopy( line ) );
                rl >> req.method >> req.target >> req.version;
            }
            // Strip the query string so "/mcp?x=1" still matches the MCP path.
            {
                const std::size_t q = req.target.find( '?' );
                if( q != std::string::npos ) req.target = req.target.substr( 0, q );
            }
            req.headers.clear();
            while( std::getline( head, line ) )
            {
                const std::size_t colon = line.find( ':' );
                if( colon == std::string::npos ) continue;
                req.headers.insert( { lowerCopy( trimCopy( line.substr( 0, colon ) ) ), trimCopy( line.substr( colon + 1 ) ) } );
            }
        }
        if( req.method.empty() || req.target.empty() ) return -1;

        const std::size_t bodyStart = headerEnd + 4;
        std::size_t contentLength = 0;
        auto cl = req.headers.find( "content-length" );
        if( cl != req.headers.end() )
        {
            // Digit-by-digit validation. strtoull is far too permissive here:
            // it accepts "12abc" (as 12), " 12" and even "-1" (as a huge
            // unsigned value), so a malformed Content-Length silently became
            // a DIFFERENT length -- the server then read a body that did not
            // match the framing the client sent. A Content-Length that is
            // not all digits is a framing error, refused with 400.
            const std::string& v = cl->second;
            if( v.empty() ) { req.malformed = true; req.valid = false; pending.erase( 0, bodyStart ); return 0; }
            for( char ch : v )
                if( ch < '0' || ch > '9' )
                { req.malformed = true; req.valid = false; pending.erase( 0, bodyStart ); return 0; }
            errno = 0;
            const unsigned long long parsed = std::strtoull( v.c_str(), nullptr, 10 );
            if( errno == ERANGE )
            { req.malformed = true; req.valid = false; pending.erase( 0, bodyStart ); return 0; }
            contentLength = static_cast<std::size_t>( parsed );
        }
        if( req.headers.find( "transfer-encoding" ) != req.headers.end() || contentLength > cfg.bodyCapBytes )
        {
            req.valid = false;
            pending.erase( 0, bodyStart );
            return 0;
        }
        while( pending.size() - bodyStart < contentLength )
        {
            const int n = c.recvSome( buf, sizeof( buf ) );
            if( n == -2 && !g_httpSignalled.load() ) return -2;
            if( n <= 0 ) return -1;
            pending.append( buf, static_cast<std::size_t>( n ) );
        }
        req.body.assign( pending, bodyStart, contentLength );
        pending.erase( 0, bodyStart + contentLength );
        req.valid = true;
        return 0;
    }

    static void respond( Conn& c, int status, const std::string& contentType,
                          const std::string& body, const std::map<std::string,std::string>& extraHeaders = {} )
    {
        static const std::map<int, std::string> kText{
            { 200, "OK" }, { 202, "Accepted" }, { 400, "Bad Request" }, { 401, "Unauthorized" }, { 404, "Not Found" },
            { 405, "Method Not Allowed" }, { 411, "Length Required" }, { 413, "Payload Too Large" },
            { 500, "Internal Server Error" }, { 503, "Service Unavailable" }
        };
        std::ostringstream out;
        out << "HTTP/1.1 " << status << ' ' << ( kText.count( status ) ? kText.at( status ) : "Status" ) << "\r\n"
            << "Content-Type: " << contentType << "\r\n"
            << "Content-Length: " << body.size() << "\r\n";
        for( const auto& [ k, v ] : extraHeaders ) out << k << ": " << v << "\r\n";
        // Connection: close on EVERY response — the one-request-per-connection
        // posture (the client opens a fresh connection for its next request).
        out << "Connection: close\r\n\r\n" << body;
        c.sendAll( out.str() );
    }

    static Json httpErrorBody( const char* message ) { return Json{ { "error", message } }; }

    // ---------- The listener. Thread-per-connection; each connection serves
    // exactly ONE request (above posture); receive timeouts make the shutdown
    // drain bounded. ----------

    struct SessionEntry { std::shared_ptr<JsonRpcServer> server; std::string clientKey; };

    // One request's full handling (health, auth, session mint/resolve,
    // dispatch, response) — the named steps of the old loop body; every early
    // exit is a `return` where the loop version said `continue`.
    static void handleRequest( Conn& c, const HttpConfig& cfg, const HttpRequest& req,
                               TokenStore& tokens,
                               const std::function<bool()>& readinessProbe,
                               const std::function<std::shared_ptr<JsonRpcServer>()>& sessionFactory,
                               std::map<std::string, SessionEntry>& sessions, std::mutex& sessionsMu )
    {
        // ---- health endpoints (no token required) ----
        // Only /readyz runs the readiness probe, a live database round trip.
        if( req.method == "GET" && req.target == "/healthz" )
            { respond( c, 200, "application/json", Json{ { "ok", true } }.dump() ); return; }
        if( req.method == "GET" && req.target == "/readyz" )
        {
            const bool ready = readinessProbe();
            // {"ok": <ready>} plus "probe" naming what was checked.
            respond( c, ready ? 200 : 503, "application/json",
                     Json{ { "ok", ready }, { "probe", "engine version query" } }.dump() );
            return;
        }

        // ---- Bearer gate: everything else requires the token ----
        std::string bearer;
        auto auth = req.headers.find( "authorization" );
        if( auth != req.headers.end() )
        {
            const std::string v = auth->second;
            if( lowerCopy( v ).rfind( "bearer ", 0 ) == 0 ) bearer = trimCopy( v.substr( 7 ) );
        }
        if( bearer.empty() || !tokens.matches( bearer ) )
            { respond( c, 401, "application/json", httpErrorBody( "missing or invalid bearer token" ).dump() ); return; }

        const bool pathMatched = req.target == cfg.path || req.target == cfg.path + "/";
        if( !pathMatched )
            { respond( c, 404, "application/json", httpErrorBody( "not found" ).dump() ); return; }

        if( req.method == "GET" )
            { respond( c, 405, "application/json", httpErrorBody( "GET on the mcp path is not served; use POST" ).dump() ); return; }

        if( req.method == "DELETE" )
        {
            // Session close: drops the session's dedicated DB connection.
            auto sid = req.headers.find( "mcp-session-id" );
            bool closed = false;
            if( sid != req.headers.end() )
            {
                std::lock_guard<std::mutex> lkS( sessionsMu );
                closed = sessions.erase( sid->second ) > 0;
            }
            respond( c, closed ? 200 : 404, "application/json", httpErrorBody( closed ? "session closed" : "unknown session" ).dump() );
            return;
        }

        if( req.method != "POST" )
            { respond( c, 405, "application/json", httpErrorBody( "method not allowed" ).dump() ); return; }

        // Once shutdown has begun, new requests are refused here.
        if( g_httpSignalled.load() )
            { respond( c, 503, "application/json", httpErrorBody( "server shutting down" ).dump() ); return; }

        if( !req.valid )
        {
            // A malformed Content-Length is a FRAMING error (400), distinct
            // from the two framing refusals below it: the request declared
            // one length and meant another.
            if( req.malformed )
            { respond( c, 400, "application/json", httpErrorBody( "malformed Content-Length" ).dump() ); return; }
            respond( c, req.headers.find( "transfer-encoding" ) != req.headers.end() ? 411 : 413,
                       "application/json", httpErrorBody( req.headers.find( "transfer-encoding" ) != req.headers.end()
                           ? "chunked transfer-encoding not supported; send Content-Length" : "request body too large" ).dump() );
              return; }

        if( req.body.empty() )
            { respond( c, 400, "application/json", httpErrorBody( "empty request body" ).dump() ); return; }

        // Parse body; MCP batches (JSON arrays) reply as an array.
        Json parsed;
        bool isBatch = false, isJson = false;
        try { parsed = Json::parse( req.body ); isJson = true; isBatch = parsed.is_array(); }
        catch( ... ) { isJson = false; }
        // An empty batch is an invalid request under JSON-RPC 2.0.
        if( !isJson || ( !isBatch && !parsed.is_object() ) || ( isBatch && parsed.empty() ) )
            { respond( c, 400, "application/json", httpErrorBody( "request body is not valid JSON-RPC" ).dump() ); return; }

        // ---- session rules: initialize mints an id; everything else needs one ----
        // nlohmann's value(key, default) does NOT type-check a key it FINDS:
        // value("method", "") throws type_error.302 when "method" is present
        // but not a string (e.g. {"method":123} or {"method":true}). The
        // read below is therefore guarded by is_string() -- a request whose
        // "method" is not a string is simply "not an initialize" here, and
        // the dispatcher rejects it with a proper JSON-RPC error. Without
        // the guard this throws out of handleRequest, out of the
        // connection thread, and std::terminate()s the whole server.
        const bool isInit = [ & ] {
            if( isBatch )
                for( const Json& part : parsed )
                    if( part.is_object() && part.contains( "method" ) && part[ "method" ].is_string()
                        && part[ "method" ].get<std::string>() == "initialize" ) return true;
            return !isBatch && parsed.contains( "method" ) && parsed[ "method" ].is_string()
                && parsed[ "method" ].get<std::string>() == "initialize";
        }();

        auto sidHdr = req.headers.find( "mcp-session-id" );

        if( isInit )
        {
            if( sidHdr != req.headers.end() )
                { respond( c, 400, "application/json", httpErrorBody( "initialize must run on a fresh session; POST without Mcp-Session-Id" ).dump() ); return; }
            // A session id is minted per initialize. If the entropy source
            // is broken, mintSessionId THROWS (fail closed — a predictable
            // session id would be a session-hijacking primitive), so the
            // failure is answered as a 500 rather than closing the socket
            // with no response at all.
            std::string minted;
            try { minted = mintSessionId(); }
            catch( const std::exception& )
            { respond( c, 500, "application/json", httpErrorBody( "could not mint a session id: the system entropy source failed" ).dump() ); return; }
            std::shared_ptr<JsonRpcServer> server;
            std::string clientKey;
            {
                std::lock_guard<std::mutex> lkS( sessionsMu );
                SessionEntry& entry = sessions[ minted ];
                entry.server = sessionFactory();
                entry.clientKey = clientKeyFor( cfg, bearer, minted );
                server = entry.server;
                clientKey = entry.clientKey;
            }
            Json out;
            if( isBatch )
            {
                Json responses = Json::array();
                for( const Json& one : parsed )
                    if( auto r = server->handleLine( one.dump(), clientKey ) ) responses.push_back( Json::parse( *r ) );
                // A batch made up ENTIRELY of notifications produces no
                // JSON-RPC reply at all. Answering 200 with an empty array
                // reads as "the server returned an empty result"; the
                // honest answer is 202 -- accepted, nothing to return.
                if( responses.empty() )
                { respond( c, 202, "application/json", "" ); return; }
                out = responses.size() == 1 ? responses[ 0 ] : Json( responses );
            }
            else
            {
                const auto r = server->handleLine( parsed.dump(), clientKey );
                if( !r )
                {
                    // A NOTIFICATION (a request with no id) has no JSON-RPC
                    // reply -- but the HTTP exchange still needs an answer.
                    // Closing the connection with NO response at all reads
                    // as a protocol error to the client, and on a
                    // keep-alive client as a truncated exchange.
                    respond( c, 202, "application/json", "" );
                    return;
                }
                out = Json::parse( *r );
            }
            respond( c, 200, "application/json", out.dump(), { { "Mcp-Session-Id", minted } } );
            return;
        }

        // every other method requires a KNOWN session id (400 missing / 404 unknown)
        if( sidHdr == req.headers.end() )
            { respond( c, 400, "application/json", httpErrorBody( "missing Mcp-Session-Id" ).dump() ); return; }

        std::shared_ptr<JsonRpcServer> server;
        std::string clientKey;
        {
            std::lock_guard<std::mutex> lkS( sessionsMu );
            auto it = sessions.find( sidHdr->second );
            if( it == sessions.end() )
                { respond( c, 404, "application/json", httpErrorBody( "unknown mcp-session-id" ).dump() ); return; }
            server = it->second.server;
            clientKey = it->second.clientKey;
        }

        Json out;
        if( isBatch )
        {
            Json responses = Json::array();
            for( const Json& one : parsed )
                if( auto r = server->handleLine( one.dump(), clientKey ) ) responses.push_back( Json::parse( *r ) );
            // A batch made up ENTIRELY of notifications produces no JSON-RPC
            // reply at all: 202 (accepted, nothing to return) rather than
            // 200 with an empty array, which reads as an empty result.
            if( responses.empty() )
            { respond( c, 202, "application/json", "" ); return; }
            out = responses.size() == 1 ? responses[ 0 ] : Json( responses );
        }
        else
        {
            const auto r = server->handleLine( parsed.dump(), clientKey );
            if( !r )
            {
                // A NOTIFICATION (a request with no id) has no JSON-RPC
                // reply -- but the HTTP exchange still needs an answer. An
                // empty 202 says "accepted, nothing to return"; closing the
                // connection with NO response at all (what this used to do)
                // reads as a protocol error to the client, and on a
                // keep-alive client as a truncated exchange.
                respond( c, 202, "application/json", "" );
                return;
            }
            out = Json::parse( *r );
        }
        respond( c, 200, "application/json", out.dump(), { { "Mcp-Session-Id", sidHdr->second } } );
    }

    static int runListener( const HttpConfig& cfg, TokenStore& tokens, TlsLayer* tls,
                             std::function<bool()> readinessProbe,
                             std::function<std::shared_ptr<JsonRpcServer>()> sessionFactory,
                             std::map<std::string, SessionEntry>& sessions, std::mutex& sessionsMu )
    {
        // FSQL_MCP_HTTP_HOST / --host pins the listener. The DEFAULT is
        // loopback (127.0.0.1): the server exposes SQL execution behind a
        // bearer token, so binding every interface by default put a
        // database on the network of whatever host it ran on, silently, with
        // the token as the only thing between a stranger and the fractal_*
        // functions. The all-interfaces bind is now opt-in and EXPLICIT:
        // FSQL_MCP_HTTP_HOST=0.0.0.0 or --host 0.0.0.0 (what a published
        // docker port assumes). A set host that does not parse is a config
        // error, never a silent fallback.
        const std::string bindHost = cfg.host.empty() ? std::string( "127.0.0.1" ) : cfg.host;
        std::string listenErr;
        net::Socket listener = net::listenTcp( bindHost, cfg.port, listenErr );
        if( net::isInvalid( listener ) )
        {
            std::cerr << "http listen failed on " << bindHost << ":" << cfg.port
                      << ( listenErr.empty() ? std::string() : " -- " + listenErr ) << "\n";
            return 1;   // a set host that does not parse is a config error, not a bind-all fallback
        }

        // Count of live connection threads, which the shutdown drain waits on.
        // Heap-allocated and intentionally never freed: the threads are
        // detached, and a straggler can still be running after the drain
        // deadline, so the counter must outlive this function.
        std::atomic<int>* liveCount = new std::atomic<int>( 0 );

        while( !g_httpSignalled.load() )
        {
            net::Socket client = net::accept( listener );
            if( net::isInvalid( client ) )
            {
                // accept() returns EINTR on any signal (SIGHUP included):
                // keep serving unless this is a shutdown or a real error.
                if( net::wouldBlock() && !g_httpSignalled.load() ) continue;
                break;
            }
            net::setRecvTimeout( client, 2000 );   // bounds the shutdown drain on an idle connection
            liveCount->fetch_add( 1 );
            // Detached thread: it ends after writing its single response.
            // liveCount is captured by value (the pointer) so it stays valid.
            std::thread( [ &, client, liveCount ]
            {
                // An exception escaping a thread would terminate the whole
                // server; turn it into a logged error and a closed socket.
                try
                {
                    Conn c( client, tls ? tls->ctx() : nullptr );
                    if( !c.acceptTls() ) { liveCount->fetch_sub( 1 ); return; }
                    std::string pending;

                    // ONE request per connection: read exactly one request, handle
                    // it, and return — respond() already advertises `Connection:
                    // close`, so the client opens a new connection for its next
                    // request (and a request body executes at most once per
                    // connection). An idle timeout (-2) on a fresh connection just
                    // closes it.
                    HttpRequest req;
                    const int rc = readRequest( c, cfg, req, pending );
                    if( rc != 0 ) { liveCount->fetch_sub( 1 ); return; }

                    handleRequest( c, cfg, req, tokens, readinessProbe, sessionFactory, sessions, sessionsMu );
                }
                catch( const std::exception& e )
                {
                    logging::exceptionDetail( "http_conn_thread", sanitizeSecrets( e.what() ) );
                }
                catch( ... )
                {
                    logging::exceptionDetail( "http_conn_thread", "unknown exception" );
                }
                liveCount->fetch_sub( 1 );
            } ).detach();
        }

        net::close( listener );
        // Drain: after the listener closes, new connections are refused; give
        // in-flight requests cfg.shutdownDrainMs (FSQL_MCP_SHUTDOWN_DRAIN_MS)
        // to finish — the wait below checks every
        // 50 ms whether the live-connection count has reached zero. If a
        // straggler is STILL mid-request at the deadline (its own tool runtime
        // can be arbitrarily long), we do NOT wait for it: an unbounded wait is
        // exactly the hang this posture exists to prevent. Connection threads
        // only touch intentionally-leaked state (TokenStore/sessions/sessionsMu,
        // see runHttpTransport), so process teardown cuts the tail without a
        // use-after-free; main() routes the HTTP exit through std::exit for
        // the same reason.
        {
            const auto drainDeadline = std::chrono::steady_clock::now()
                + std::chrono::milliseconds( cfg.shutdownDrainMs );
            while( liveCount->load() > 0 && std::chrono::steady_clock::now() < drainDeadline )
                std::this_thread::sleep_for( std::chrono::milliseconds( 50 ) );
        }
        return 0;
    }

    int runHttpTransport( const HttpConfig& cfg, std::function<bool()> readinessProbe,
                           std::function<std::shared_ptr<JsonRpcServer>()> sessionFactory )
    {
        // Intentional leaks: connection threads are cut loose at a drain
        // deadline (above) and can still be INSIDE a request when this
        // function's bounded waits finish; destroying TokenStore (mutex +
        // token string), the sessions map, or its mutex out from under such a
        // thread is a use-after-free. Nobody reads these after the std::exit
        // at teardown, so the leak is reclaimed at process exit exactly like
        // the process's own statics.
        TokenStore& tokens = *new TokenStore( cfg );
        std::map<std::string, SessionEntry>& sessions = *new std::map<std::string, SessionEntry>();
        std::mutex& sessionsMu = *new std::mutex();

        net::init();
        std::unique_ptr<TlsLayer> tls;
        // Fail-fast TLS init: a bad/missing/ mismatched cert or key is a
        // CONFIG error, not a request-time one — refuse to start (the
        // HTTPS smoke client asserts the nonzero exit for each failure
        // mode, cert-parse / key-parse / mismatch, see TlsLayer::make).
        try { tls = TlsLayer::make( cfg ); }
        catch( const ToolError& e )
        {
            std::cerr << "tls init failed: " << e.message << "\n";
            net::shutdownNet();
            // A DISTINCT exit code from the config errors (2): a supervisor
            // must be able to tell "the operator handed us a bad cert file"
            // (fix the cert) from "there is no auth token" (fix the env) --
            // both were exit 2, so an automated restart loop could not act
            // on the difference. The HTTPS smoke client only asserts
            // "nonzero", so the split is invisible to it.
            return 3;
        }

#ifndef _WIN32
        // SIGHUP always means "reload the token file", with or without TLS.
        // Without a handler the default action would terminate the process.
        std::signal( SIGHUP, onSighup );
        // Install TERM/INT without SA_RESTART so a signal interrupts the
        // blocked accept() and the shutdown drain runs.
        {
            struct sigaction sa;
            std::memset( &sa, 0, sizeof( sa ) );
            sa.sa_handler = onHttpTermSignal;
            sigemptyset( &sa.sa_mask );
            sa.sa_flags = 0;   // deliberately NOT SA_RESTART
            ::sigaction( SIGTERM, &sa, nullptr );
            ::sigaction( SIGINT,  &sa, nullptr );
        }
#else
        std::signal( SIGTERM, onHttpTermSignal );
        std::signal( SIGINT,  onHttpTermSignal );
#endif

        const int rc = runListener( cfg, tokens, tls.get(), std::move( readinessProbe ),
                                     std::move( sessionFactory ), sessions, sessionsMu );

        // Close every session's database connection at shutdown. The map is
        // intentionally leaked (see above), so without this the per-session
        // PGconns stayed open until the process died -- on a rolling
        // restart, that is one postgres backend per session held for the
        // whole supervisor's stop timeout. Clearing the map drops the MAP's
        // references: a session no thread is using is destroyed right here
        // (its JsonRpcServer goes with it, and with it the Db it owns, whose
        // destructor closes the connection), while a session a straggler
        // thread is still inside survives until that thread finishes --
        // which is the point: its Db must not be closed under it.
        {
            std::lock_guard<std::mutex> lkS( sessionsMu );
            sessions.clear();
        }

        // A short, SEPARATE grace for the straggler threads the drain cut
        // loose: the drain already waited out its deadline for the live
        // connections, and this window exists so a response that was ALREADY
        // being written can still land before the socket layer is torn down
        // underneath it. It is deliberately short and fixed: the point is
        // not to extend the drain, but to let the socket layer outlive the
        // last write.
        {
            const auto graceDeadline = std::chrono::steady_clock::now()
                + std::chrono::milliseconds( 250 );
            while( std::chrono::steady_clock::now() < graceDeadline )
                std::this_thread::sleep_for( std::chrono::milliseconds( 25 ) );
        }

        // net::shutdownNet() LAST: it tears the socket layer down, so every
        // straggler thread's next recv/send fails. Anything that needed the
        // layer still alive has already been given its grace above.
        net::shutdownNet();
        // Same terminal event the stdio transport emits (transport_stdio.cpp):
        // one "shutdown_complete" line per transport, so an operator (or the
        // smoke gate) can tell a clean drain from a transport that died.
        logging::event( "shutdown_complete", Json{ { "transport", "http" } } );
        return rc;
    }
}