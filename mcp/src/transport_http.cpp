#include "transport_http.h"
#include "transport_socket.h"
#include "logging.h"
#include "policy.h"
#include <cstdint>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <mutex>
#include <thread>
#include <atomic>
#include <map>
#include <memory>
#include <set>
#include <vector>
#include <stdexcept>
#include <iterator>
#include <ctime>
#include <cstring>
#include <cstdio>
#include <csignal>
#include <cstdlib>
#include <chrono>
#include <algorithm>
#include <cctype>
#ifndef _WIN32
  #include <sys/resource.h>
#endif

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
        // What a presented credential turned out to be.
        struct Credential
        {
            bool ok = false;
            bool expired = false;
            std::string clientName;                        // the policy entry's name, or a token-derived key
            std::optional<std::set<std::string>> allow;    // unset = every tool
        };

        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        Credential check( const std::string& presented )
        {
            // SIGHUP's deferred work happens HERE, on an ordinary request
            // thread: the handler itself is one atomic store, so the actual
            // ifstream/filesystem token-file reload runs under check()
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
            if( presented.empty() ) return Credential{};

            // The deployment token (FSQL_MCP_AUTH_TOKEN / _FILE): one secret
            // for the whole deployment; every holder shares one identity.
            if( !token_.empty() && presented.size() == token_.size()
                && CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0 )   // timing-safe
            {
                Credential c;
                c.ok = true;
                // The identity of a deployment-token holder: a short digest of
                // the token, never the token itself.
                c.clientName = "token:" + sha256Hex( presented ).substr( 0, 8 );
                return c;
            }

            if( policies_.empty() ) return Credential{};

            // Per-client credentials: the presented token's SHA-256 against
            // every entry. No early exit: the work per attempt stays the
            // same whether or not the hash matches.
            const std::string hex = sha256Hex( presented );
            Credential out;
            bool known = false;
            for( const PolicyEntry& e : policies_ )
            {
                if( e.sha256.size() != hex.size() ) continue;
                if( CRYPTO_memcmp( e.sha256.data(), hex.data(), hex.size() ) != 0 ) continue;
                known = true;
                if( e.expired() ) { out.expired = true; continue; }
                out.ok = true;
                out.clientName = e.name.empty() ? ( "client:" + hex.substr( 0, 8 ) ) : e.name;
                out.allow = e.allTools ? std::nullopt
                                       : std::optional<std::set<std::string>>( e.tools );
            }
            if( !known ) return Credential{};
            return out;
        }

        static std::string sha256Hex( const std::string& v )
        {
            unsigned char d[ SHA256_DIGEST_LENGTH ];
            SHA256( reinterpret_cast<const unsigned char*>( v.data() ), v.size(), d );
            static const char* const kHex = "0123456789abcdef";
            std::string out;
            for( int i = 0; i < SHA256_DIGEST_LENGTH; ++i )
            { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
            return out;
        }

        // A malformed policy file keeps the last good one and says so; the
        // caller surfaces the message at startup.
        std::string policyError()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            return policyError_;
        }

        void reload( bool force )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            reloadLocked( force );
        }

    private:
        struct PolicyEntry
        {
            std::string name;
            std::string sha256;
            bool allTools = false;
            std::set<std::string> tools;
            std::time_t expiresAt = 0;      // 0 = never expires
            bool expired() const
            {
                if( expiresAt == 0 ) return false;
                return std::time( nullptr ) >= expiresAt;
            }
        };

        // Parses an ISO-8601 expiry: "YYYY-MM-DD" or
        // "YYYY-MM-DDTHH:MM:SSZ". Returns 0 when the text is not a usable
        // expiry, which the caller treats as "no expiry given".
        static std::time_t parseExpiry( const std::string& text )
        {
            if( text.size() < 10 ) return 0;
            std::tm tm{};
            int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
            if( std::sscanf( text.c_str(), "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &se ) < 3 &&
                std::sscanf( text.c_str(), "%d-%d-%d", &y, &mo, &d ) < 3 )
                return 0;
            if( y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 ) return 0;
            tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d;
            tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = se;
            return utcToTimeT( tm );
        }

        // UTC calendar time -> time_t. timegm() is POSIX; the MSVC CRT has
        // _mkgmtime() instead.
#if defined( _WIN32 )
        static std::time_t utcToTimeT( std::tm& tm )
        { return static_cast<std::time_t>( _mkgmtime( &tm ) ); }
#else
        static std::time_t utcToTimeT( std::tm& tm )
        { return timegm( &tm ); }
#endif

        void loadPolicyLocked()
        {
            if( cfg_.tokenPolicyFile.empty() ) return;
            std::ifstream in( cfg_.tokenPolicyFile, std::ios::binary );
            if( !in ) { policyError_ = "cannot read " + cfg_.tokenPolicyFile; return; }
            const std::string text( ( std::istreambuf_iterator<char>( in ) ), std::istreambuf_iterator<char>() );
            std::vector<PolicyEntry> next;
            try
            {
                const Json doc = Json::parse( text );
                if( !doc.is_object() || !doc.contains( "tokens" ) || !doc.at( "tokens" ).is_array() )
                    throw std::runtime_error( "expected {\"tokens\":[...]}" );
                for( const Json& t : doc.at( "tokens" ) )
                {
                    PolicyEntry e;
                    if( t.contains( "name" ) && t.at( "name" ).is_string() ) e.name = t.at( "name" ).get<std::string>();
                    e.sha256 = t.at( "sha256" ).get<std::string>();
                    if( e.sha256.size() != 64 ) throw std::runtime_error( "sha256 must be 64 hex digits" );
                    for( char& c : e.sha256 ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                    const Json& tools = t.at( "tools" );
                    if( tools.is_string() && tools.get<std::string>() == "*" ) e.allTools = true;
                    else if( tools.is_array() )
                        for( const Json& n : tools ) e.tools.insert( n.get<std::string>() );
                    else throw std::runtime_error( "tools must be \"*\" or an array of tool names" );
                    if( t.contains( "expires" ) && t.at( "expires" ).is_string() )
                    {
                        e.expiresAt = parseExpiry( t.at( "expires" ).get<std::string>() );
                        if( e.expiresAt == 0 )
                            throw std::runtime_error( "expires must be an ISO-8601 date/time (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)" );
                    }
                    next.push_back( std::move( e ) );
                }
            }
            catch( const std::exception& ex )
            {
                policyError_ = std::string( "FSQL_MCP_TOKEN_POLICY_FILE is not valid: " ) + ex.what();
                return;   // keep the last good policy
            }
            policies_ = std::move( next );
            policyError_.clear();
        }

        // The body of reload(): the caller MUST hold mu_.
        void reloadLocked( bool force )
        {
            if( !cfg_.authTokenFile.empty() )
            {
                // Raw clock ticks, only compared for change: converting a Windows
                // file time (100 ns ticks since 1601) to nanoseconds overflows.
                long long mtime = 0;
                try { mtime = static_cast<long long>(
                        fs::last_write_time( cfg_.authTokenFile ).time_since_epoch().count() ); }
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
            }
            else
                token_ = cfg_.authToken;    // plain env-var form: no hot-reload

            // The per-client credential file hot-reloads like the token file:
            // it is re-read whenever its own mtime changes, and on a forced
            // reload (SIGHUP). It holds no secret, only hashes.
            if( !cfg_.tokenPolicyFile.empty() )
            {
                long long mtime = 0;
                bool readable = true;
                try { mtime = static_cast<long long>(
                        fs::last_write_time( cfg_.tokenPolicyFile ).time_since_epoch().count() ); }
                catch( ... ) { readable = false; }
                if( force || !policyLoaded_ || ( readable && mtime != policyMtime_ ) )
                    loadPolicyLocked();
                policyLoaded_ = true;
                if( readable ) policyMtime_ = mtime;
            }
        }

        // A copy, not a reference: the store may outlive the caller's
        // configuration object (the transport hands it to connection threads
        // that can still be running when the serving code has returned).
        HttpConfig cfg_;
        std::mutex mu_;
        std::string token_;
        long long lastMtime_ = 0;
        std::vector<PolicyEntry> policies_;
        std::string policyError_;
        long long policyMtime_ = 0;
        bool policyLoaded_ = false;
    };

    // The startup check for the per-client credential file.
    std::string tokenPolicyError( const HttpConfig& cfg )
    {
        TokenStore store( cfg );
        return store.policyError();
    }

#ifndef _WIN32
    static void onSighup( int ) { g_sighupReload.store( true, std::memory_order_relaxed ); }
#endif
    static std::atomic<bool> g_httpSignalled{ false };
    static void onHttpTermSignal( int ) { g_httpSignalled.store( true ); }

    // Most connections served at once. Each one holds a thread and a
    // descriptor before it has authenticated, so the count is bounded:
    // FSQL_MCP_MAX_CONNECTIONS overrides the default of 256, and on POSIX
    // the result never exceeds half the process's descriptor limit.
    static int maxConnections()
    {
        long n = 256;
        if( const char* v = std::getenv( "FSQL_MCP_MAX_CONNECTIONS" ) )
        {
            const long x = std::strtol( v, nullptr, 10 );
            if( x > 0 ) n = x;
        }
#ifndef _WIN32
        rlimit rl{};
        if( getrlimit( RLIMIT_NOFILE, &rl ) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur > 8 )
            n = std::min<long>( n, static_cast<long>( rl.rlim_cur / 2 ) );
#endif
        return static_cast<int>( std::min<long>( n, 1L << 20 ) );
    }

    // A refused connection is closed only after the peer's request has been
    // read and discarded, so the refusal itself is not lost. The window is
    // long enough for a client that is slow to write its request, and short
    // enough that a refused connection does not hold anything for long.
    static constexpr int kRefusalLingerMs = 1000;

    // How many refusals may be delivering themselves at once. A flood of
    // connections past the limit must not turn into a flood of threads.
    static constexpr int kMaxRefusalsInFlight = 64;

    // Per-client fairness key for the expensive-call cap
    // (FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT). With a static token
    // (FSQL_MCP_AUTH_TOKEN) every client sharing it shares one budget; with a
    // token file each session keeps its own.
    // Failed-auth backoff: each failure stalls its own connection thread for a growing interval (capped at 2 s),
    // which throttles online token guessing without a lockout an attacker could turn against legitimate clients.
    // A success pays one failure back.
    static std::atomic<int>& authFailureCounter() { static std::atomic<int> n{ 0 }; return n; }
    static void authFailed()
    {
        const int fails = std::min( authFailureCounter().fetch_add( 1 ) + 1, 20 );
        std::this_thread::sleep_for( std::chrono::milliseconds( fails * 100 ) );
    }
    static void authOk()
    {
        int f = authFailureCounter().load();
        while( f > 0 && !authFailureCounter().compare_exchange_weak( f, f - 1 ) ) {}
    }

    // Non-reversible fingerprint of the presented bearer token (never log or return it). A session belongs
    // to the credential that created it: another token can neither adopt nor close it.
    static std::string tokenFingerprint( const std::string& bearer )
    {
        unsigned char d[ SHA256_DIGEST_LENGTH ];
        SHA256( reinterpret_cast<const unsigned char*>( bearer.data() ), bearer.size(), d );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 16; ++i ) { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
        return out;
    }

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
        // Reference-counted so that a connection thread which is still
        // running when the serving code returns keeps the TLS context alive
        // for as long as it needs it.
        static std::shared_ptr<TlsLayer> make( const HttpConfig& cfg )
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
            return std::shared_ptr<TlsLayer>( new TlsLayer( ctx ) );
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

    // ---------- The modern protocol era's request shape ----------
    //
    // A modern-era request is stateless: it names its own revision, its own
    // method and (where it addresses something by name) its own target, and
    // the server checks the headers against the body before dispatching it.

    // The RFC 6750 challenge a 401 carries. No scope and no
    // resource_metadata: this server authenticates one bearer token (or a
    // per-client credential from the policy file) and does not implement
    // the OAuth 2.1 resource-server flow.
    static const char* const kAuthRealm = "Bearer realm=\"fractalsql-mcp\"";

    // A JSON-RPC error body for a refusal that happened before the request
    // reached the dispatch core. There is no id to correlate it with, so
    // the body carries none.
    static std::string rpcErrorBody( int code, const std::string& message, const Json& data = Json() )
    {
        Json err{ { "code", code }, { "message", message } };
        if( !data.is_null() ) err[ "data" ] = data;
        return Json{ { "jsonrpc", "2.0" }, { "error", err } }.dump();
    }

    // True when the origin names a loopback host. The host part is what
    // matters: a page served from http://127.0.0.1:3000 is a loopback
    // origin whatever its port.
    static bool originIsLoopback( const std::string& origin )
    {
        const std::size_t sep = origin.find( "://" );
        if( sep == std::string::npos ) return false;
        std::string host = origin.substr( sep + 3 );
        const std::size_t slash = host.find( '/' );
        if( slash != std::string::npos ) host = host.substr( 0, slash );
        if( !host.empty() && host.front() == '[' )
        {
            const std::size_t close = host.find( ']' );
            if( close == std::string::npos ) return false;
            const std::string inner = host.substr( 1, close - 1 );
            return inner == "::1";
        }
        const std::size_t colon = host.rfind( ':' );
        if( colon != std::string::npos ) host = host.substr( 0, colon );
        if( host == "localhost" ) return true;
        if( host.rfind( "127.", 0 ) == 0 ) return true;
        return false;
    }

    // An Origin header, when present, must be one this deployment allows:
    // a loopback origin by default, plus whatever FSQL_MCP_ALLOWED_ORIGINS
    // lists (browser tools such as the MCP Inspector need their origin
    // there). A request with no Origin header is not a browser request and
    // is allowed through.
    static bool originAllowed( const std::string& origin, const HttpConfig& cfg )
    {
        if( origin.empty() ) return true;
        if( originIsLoopback( origin ) ) return true;
        const std::string o = lowerCopy( trimCopy( origin ) );
        for( const std::string& allowed : cfg.allowedOrigins )
            if( lowerCopy( trimCopy( allowed ) ) == o ) return true;
        return false;
    }

    // base64url decode, for the Mcp-Name header's "=?base64?...?=" form. A
    // self-contained decoder: the padding and the length rules are explicit,
    // so a malformed payload yields an empty string rather than a
    // half-decoded one.
    static std::string base64Decode( const std::string& in )
    {
        auto value = []( char c ) -> int {
            if( c >= 'A' && c <= 'Z' ) return c - 'A';
            if( c >= 'a' && c <= 'z' ) return c - 'a' + 26;
            if( c >= '0' && c <= '9' ) return c - '0' + 52;
            if( c == '+' ) return 62;
            if( c == '/' ) return 63;
            return -1;
        };
        std::string out;
        // Only the bits not yet emitted matter, so the accumulator is kept
        // unsigned and masked to 20 bits (at most 13 are ever live); an int that kept every bit
        // ever shifted in would overflow on a long value.
        std::uint32_t buf = 0;
        int bits = 0;
        // The padding characters are not part of the value: count them and
        // leave them out of the payload, so the decoded text is exactly the
        // bytes the sender encoded (and not the text plus the padding).
        std::size_t pad = 0;
        while( pad < in.size() && in[ in.size() - 1 - pad ] == '=' ) ++pad;
        const std::size_t body = in.size() - pad;
        for( std::size_t i = 0; i < body; ++i )
        {
            const char c = in[ i ];
            const int v = value( c );
            if( v < 0 ) return std::string();  // not base64 at all
            buf = ( ( buf << 6 ) | static_cast<std::uint32_t>( v ) ) & 0xFFFFFu;
            bits += 6;
            if( bits >= 8 )
            {
                bits -= 8;
                out.push_back( static_cast<char>( ( buf >> bits ) & 0xFF ) );
            }
        }
        return out;
    }

    // The Mcp-Name header may carry the name in the base64 form the spec
    // allows. Decoded, it is the same string; a value that is not in that
    // form is taken literally.
    static std::string decodeMcpName( const std::string& raw )
    {
        static const std::string kPrefix = "=?base64?";
        const std::string v = trimCopy( raw );
        if( v.rfind( kPrefix, 0 ) != 0 ) return v;
        const std::size_t end = v.rfind( "?=" );
        if( end == std::string::npos || end < kPrefix.size() ) return std::string();
        std::string b64 = v.substr( kPrefix.size(), end - kPrefix.size() );
        for( char& c : b64 ) { if( c == '-' ) c = '+'; else if( c == '_' ) c = '/'; }
        while( b64.size() % 4 != 0 ) b64.push_back( '=' );
        return base64Decode( b64 );
    }

    // The modern era's per-request protocol version, carried in the body's
    // metadata. The spec names it
    // _meta.io.modelcontextprotocol/protocolVersion; the nested spelling is
    // accepted too, because a client that builds the metadata as a tree
    // rather than as a namespaced key produces that.
    static std::string modernMetaVersion( const Json& body )
    {
        if( !body.is_object() ) return std::string();
        auto meta = body.find( "_meta" );
        if( meta == body.end() || !meta->is_object() ) return std::string();
        auto it = meta->find( "io.modelcontextprotocol/protocolVersion" );
        if( it != meta->end() && it->is_string() ) return it->get<std::string>();
        auto ns = meta->find( "io.modelcontextprotocol" );
        if( ns != meta->end() && ns->is_object() )
        {
            auto v = ns->find( "protocolVersion" );
            if( v != ns->end() && v->is_string() ) return v->get<std::string>();
        }
        return std::string();
    }

    // A string field of the request's params, or "" when it is absent or
    // not a string. Never throws on a wrongly typed params object.
    static std::string paramsString( const Json& body, const std::string& key )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto v = p->find( key );
        if( v == p->end() || !v->is_string() ) return std::string();
        return v->get<std::string>();
    }

    // The revisions the modern protocol era covers. A modern request must
    // name one of them.
    static const std::vector<std::string>& modernProtocolVersions()
    {
        static const std::vector<std::string> v{ "2025-11-25", "2026-07-28" };
        return v;
    }

    // The revisions the legacy protocol era covers.
    static const std::vector<std::string>& legacyProtocolVersions()
    {
        static const std::vector<std::string> v{ "2024-11-05", "2025-03-26", "2025-06-18" };
        return v;
    }

    // The JSON-RPC methods this server answers. A modern request naming
    // anything else is answered with 404 and -32601; a legacy request keeps
    // the legacy behaviour (the dispatch core answers -32601).
    static bool isKnownRpcMethod( const std::string& m )
    {
        static const char* const kMethods[] = {
            "initialize", "ping", "tools/list", "tools/call",
            "resources/list", "resources/read", "resources/templates/list",
            "prompts/list", "prompts/get", "server/discover", "logging/setLevel",
            "notifications/initialized", "notifications/cancelled", "$/cancel"
        };
        for( const char* k : kMethods ) if( m == k ) return true;
        return false;
    }

    // The outcome of validating a modern-era request's headers against its
    // body.
    struct ModernCheck
    {
        bool ok = true;
        int httpStatus = 200;
        int code = 0;                 // the JSON-RPC error code, 0 = no error
        std::string message;
        Json data = Json();           // the error's data, when it carries any
    };

    // A modern protocol era request must carry MCP-Protocol-Version,
    // Mcp-Method and, where the method addresses something by name,
    // Mcp-Name; and the headers must agree with the body. A disagreement
    // is -32020 (HeaderMismatch), an unsupported revision is -32022
    // (UnsupportedProtocolVersionError).
    static ModernCheck validateModernRequest( const HttpRequest& req, const Json& body,
                                               const std::string& bodyMethod )
    {
        ModernCheck out;

        auto pv = req.headers.find( "mcp-protocol-version" );
        if( pv == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing MCP-Protocol-Version header: a modern protocol era request "
                          "must name the revision it speaks";
            return out;
        }
        const std::string headerVersion = trimCopy( pv->second );
        const auto& versions = modernProtocolVersions();
        if( std::find( versions.begin(), versions.end(), headerVersion ) == versions.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32022;
            out.message = "unsupported protocol version: " + headerVersion;
            Json supported = Json::array();
            for( const std::string& v : versions ) supported.push_back( v );
            out.data = Json{ { "supported", supported }, { "requested", headerVersion } };
            return out;
        }

        const std::string bodyVersion = modernMetaVersion( body );
        if( bodyVersion.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing _meta.io.modelcontextprotocol/protocolVersion: a modern protocol "
                          "era request carries its revision in the body as well as in the header";
            return out;
        }
        // The body's own revision must be one this era speaks too, and the
        // two must agree.
        if( std::find( versions.begin(), versions.end(), bodyVersion ) == versions.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32022;
            out.message = "unsupported protocol version: " + bodyVersion;
            Json supported = Json::array();
            for( const std::string& v : versions ) supported.push_back( v );
            out.data = Json{ { "supported", supported }, { "requested", bodyVersion } };
            return out;
        }
        if( bodyVersion != headerVersion )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the protocol version: header says "
                          + headerVersion + ", body says " + bodyVersion;
            return out;
        }

        auto mm = req.headers.find( "mcp-method" );
        if( mm == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing Mcp-Method header: a modern protocol era request must name its method";
            return out;
        }
        if( trimCopy( mm->second ) != bodyMethod )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the method: header says '"
                          + trimCopy( mm->second ) + "', body says '" + bodyMethod + "'";
            return out;
        }

        // Mcp-Name, for the methods that address something by name.
        std::string expectedName;
        bool nameRequired = false;
        if( bodyMethod == "tools/call" || bodyMethod == "prompts/get" )
        {
            expectedName = paramsString( body, "name" );
            nameRequired = true;
        }
        else if( bodyMethod == "resources/read" )
        {
            expectedName = paramsString( body, "uri" );
            nameRequired = true;
        }
        if( nameRequired )
        {
            auto mn = req.headers.find( "mcp-name" );
            if( mn == req.headers.end() )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "missing Mcp-Name header: " + bodyMethod + " must name what it addresses";
                return out;
            }
            const std::string headerName = decodeMcpName( mn->second );
            if( headerName != expectedName )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "header and body disagree about the name: header says '" + headerName
                              + "', body says '" + expectedName + "'";
                return out;
            }
        }
        return out;
    }

    // How long an idle session or context survives, and how many may exist
    // at once. Both default to the values the design documents.
    static long sessionTtlSeconds()
    {
        const char* v = std::getenv( "FSQL_MCP_SESSION_TTL_SECS" );
        const long n = ( v && *v ) ? std::atol( v ) : 3600;
        return n > 0 ? n : 3600;
    }
    static std::size_t maxSessions()
    {
        const char* v = std::getenv( "FSQL_MCP_MAX_SESSIONS" );
        const long n = ( v && *v ) ? std::atol( v ) : 64;
        return static_cast<std::size_t>( n > 0 ? n : 64 );
    }

    // A context handle: 128 bits of randomness, hex.
    static std::string mintContextId()
    {
        unsigned char raw[ 16 ] = {};
        if( RAND_bytes( raw, sizeof( raw ) ) != 1 )
        {
            RAND_poll();
            if( RAND_bytes( raw, sizeof( raw ) ) != 1 )
                throw ToolError( ErrorClass::ServerInternal,
                    "could not mint a context handle: the system entropy source failed" );
        }
        static const char* const kHex = "0123456789abcdef";
        std::string out; out.reserve( 32 );
        for( unsigned char b : raw ) { out.push_back( kHex[ b >> 4 ] ); out.push_back( kHex[ b & 0xF ] ); }
        return out;
    }

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
        // The widened timeout applies to each read, so a client sending a byte
        // a minute would hold the thread; the head as a whole gets a deadline.
        const auto headDeadline = std::chrono::steady_clock::now() + std::chrono::seconds( 30 );
        while( ( headerEnd = pending.find( "\r\n\r\n" ) ) == std::string::npos )
        {
            // The pending buffer can only exceed the header cap by the one
            // 8 KB read that carried the header terminator, so the slack
            // below never truncates a legitimate request.
            if( pending.size() > kHeaderCapBytes + sizeof( buf ) ) return -1;
            const int n = c.recvSome( buf, sizeof( buf ) );
            if( n == -2 && !g_httpSignalled.load() ) return -2;   // idle (or pre-request silence)
            if( n <= 0 ) return -1;
            if( widened && std::chrono::steady_clock::now() > headDeadline ) return -1;
            if( !widened ) { widened = true; net::setRecvTimeout( c.sock(), 65000 ); }
            pending.append( buf, static_cast<std::size_t>( n ) );
        }

        bool dupLength = false;
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
                const std::string key = lowerCopy( trimCopy( line.substr( 0, colon ) ) );
                // A repeated Content-Length is ambiguous framing, not "the first one wins".
                if( key == "content-length" && req.headers.count( key ) ) dupLength = true;
                // A repeated header name keeps the LAST value: the earlier
                // occurrences are dropped, so the request is served with the
                // value it named last rather than silently with the first
                // one, which would hide the ambiguity from the client that
                // sent it.
                {
                    const auto range = req.headers.equal_range( key );
                    req.headers.erase( range.first, range.second );
                }
                req.headers.insert( { key, trimCopy( line.substr( colon + 1 ) ) } );
            }
        }
        if( req.method.empty() || req.target.empty() ) return -1;

        const std::size_t bodyStart = headerEnd + 4;
        if( dupLength ) { req.malformed = true; req.valid = false; pending.erase( 0, bodyStart ); return 0; }
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
            { 200, "OK" }, { 202, "Accepted" }, { 400, "Bad Request" }, { 401, "Unauthorized" },
            { 403, "Forbidden" }, { 404, "Not Found" },
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

    // A protocol session (the legacy era's Mcp-Session-Id): a dedicated
    // server, and with it a dedicated database connection, per session.
    struct SessionEntry
    {
        std::shared_ptr<JsonRpcServer> server;
        std::string clientKey;
        std::string owner;
        std::chrono::steady_clock::time_point lastUsed = std::chrono::steady_clock::now();
    };

    // A context handle (the modern era's explicit state handle): its own
    // server, and with it its own database connection. It is bound to the
    // credential that created it, so another token is told the handle does
    // not exist -- a client can neither use nor probe for a handle it does
    // not own.
    struct ContextEntry
    {
        std::shared_ptr<JsonRpcServer> server;
        std::string clientKey;
        std::string owner;
        std::chrono::steady_clock::time_point lastUsed = std::chrono::steady_clock::now();
    };

    // The credential's own server: the connection a modern-era call that
    // keeps no state runs on, so a session-scoped setting one client
    // changes never leaks into another credential's calls.
    struct CredEntry
    {
        std::shared_ptr<JsonRpcServer> server;
        std::chrono::steady_clock::time_point lastUsed = std::chrono::steady_clock::now();
    };

    // All the per-client state, under one lock.
    struct ClientState
    {
        std::mutex mu;
        std::map<std::string, SessionEntry> sessions;
        std::map<std::string, ContextEntry> contexts;
        std::map<std::string, CredEntry> creds;
    };

    // Drops the idle sessions, contexts and credential servers. The released
    // servers are handed back to the caller so they are destroyed OUTSIDE
    // the lock (a server owns a database connection, and closing one can
    // take a moment).
    static void expireIdle( ClientState& state, std::vector<std::shared_ptr<JsonRpcServer>>& released )
    {
        const auto now = std::chrono::steady_clock::now();
        const auto ttl = std::chrono::seconds( sessionTtlSeconds() );
        for( auto it = state.sessions.begin(); it != state.sessions.end(); )
            if( now - it->second.lastUsed > ttl ) { released.push_back( it->second.server ); it = state.sessions.erase( it ); }
            else ++it;
        for( auto it = state.contexts.begin(); it != state.contexts.end(); )
            if( now - it->second.lastUsed > ttl ) { released.push_back( it->second.server ); it = state.contexts.erase( it ); }
            else ++it;
        for( auto it = state.creds.begin(); it != state.creds.end(); )
            if( now - it->second.lastUsed > ttl ) { released.push_back( it->second.server ); it = state.creds.erase( it ); }
            else ++it;
    }

    // The context handle a request names in its arguments ("" when it names
    // none).
    static std::string requestedContextId( const Json& body )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto a = p->find( "arguments" );
        if( a == p->end() || !a->is_object() ) return std::string();
        auto c = a->find( "context_id" );
        if( c == a->end() || !c->is_string() ) return std::string();
        return c->get<std::string>();
    }

    // The credential's own server for a modern-era call that keeps no state.
    static std::shared_ptr<JsonRpcServer> credentialServer( ClientState& state, const std::string& clientName,
                                                            const std::function<std::shared_ptr<JsonRpcServer>()>& sessionFactory )
    {
        {
            std::lock_guard<std::mutex> lk( state.mu );
            auto it = state.creds.find( clientName );
            if( it != state.creds.end() )
            {
                it->second.lastUsed = std::chrono::steady_clock::now();
                return it->second.server;
            }
        }
        // The connection is opened OUTSIDE the lock: a database connect can
        // take a while, and holding the lock through it would stall every
        // other client's request.
        std::shared_ptr<JsonRpcServer> fresh = sessionFactory();
        std::lock_guard<std::mutex> lk( state.mu );
        auto it = state.creds.find( clientName );
        if( it != state.creds.end() ) return it->second.server;   // another thread won the race
        state.creds[ clientName ] = CredEntry{ fresh, std::chrono::steady_clock::now() };
        return fresh;
    }

    // A version header that names a revision of the modern era, or one this
    // server does not know at all (so the request is answered with the
    // unsupported-version error rather than with the legacy refusal). A
    // header naming a LEGACY revision keeps the legacy flow, so a legacy
    // client that sends its version header still works.
    static bool isModernVersionHeader( const std::string& v )
    {
        if( v.empty() ) return false;
        const auto& modern = modernProtocolVersions();
        if( std::find( modern.begin(), modern.end(), v ) != modern.end() ) return true;
        const auto& legacy = legacyProtocolVersions();
        return std::find( legacy.begin(), legacy.end(), v ) == legacy.end();
    }

    // Whether a request belongs to the modern protocol era. The body's own
    // metadata names the revision (that is the modern era); "initialize" is
    // the legacy handshake and always selects the legacy flow; everything
    // else follows the version header.
    static bool isModernRequest( const HttpRequest& req, const Json& body, const std::string& bodyMethod )
    {
        if( bodyMethod == "initialize" ) return false;
        auto pv = req.headers.find( "mcp-protocol-version" );
        const std::string headerVersion = pv == req.headers.end() ? std::string() : trimCopy( pv->second );
        const std::string bodyVersion = modernMetaVersion( body );
        if( !bodyVersion.empty() )
        {
            // A client that echoes a LEGACY revision in its metadata is a
            // legacy client: it stays in the legacy flow. A body that names
            // a modern revision (or one this server does not know) is the
            // modern era.
            const auto& legacy = legacyProtocolVersions();
            const bool bodyIsLegacy = std::find( legacy.begin(), legacy.end(), bodyVersion ) != legacy.end();
            const bool headerIsLegacy = std::find( legacy.begin(), legacy.end(), headerVersion ) != legacy.end();
            if( !( bodyIsLegacy && ( headerVersion.empty() || headerIsLegacy ) ) ) return true;
            return false;
        }
        if( headerVersion.empty() ) return false;
        return isModernVersionHeader( headerVersion );
    }

    // A modern-era request: stateless, no protocol session. The engine
    // context comes from the request's own context_id argument when the call
    // addresses a stateful tool; otherwise the call runs on the credential's
    // own connection.
    static void handleModernRequest( Conn& c, const HttpRequest& req, const Json& body,
                                     const TokenStore::Credential& cred, const std::string& callerFp,
                                     const std::function<std::shared_ptr<JsonRpcServer>()>& sessionFactory,
                                     ClientState& state )
    {
        const std::string method = ( body.contains( "method" ) && body[ "method" ].is_string() )
            ? body[ "method" ].get<std::string>() : std::string();
        const bool isRequest = body.contains( "id" );

        // The modern era's own request validation: the headers must be
        // present and must agree with the body.
        const ModernCheck check = validateModernRequest( req, body, method );
        if( !check.ok )
        {
            respond( c, check.httpStatus, "application/json", rpcErrorBody( check.code, check.message, check.data ) );
            return;
        }
        if( !isKnownRpcMethod( method ) )
        {
            respond( c, 404, "application/json", rpcErrorBody( -32601, "method not found: " + method ) );
            return;
        }

        // The engine context: the request's own handle when it names one and
        // the tool is stateful, a fresh handle when it does not, and the
        // credential's own connection for a tool that keeps no state.
        const std::string toolName = ( method == "tools/call" ) ? paramsString( body, "name" ) : std::string();
        const bool stateful = !toolName.empty() && isContextScopedTool( toolName );
        const std::string requested = stateful ? requestedContextId( body ) : std::string();

        std::shared_ptr<JsonRpcServer> server;
        std::string contextId;
        if( !stateful )
        {
            server = credentialServer( state, cred.clientName, sessionFactory );
        }
        else if( !requested.empty() )
        {
            bool unknown = false;
            {
                std::lock_guard<std::mutex> lk( state.mu );
                auto it = state.contexts.find( requested );
                if( it == state.contexts.end() || it->second.owner != callerFp )
                    unknown = true;   // another credential's handle is reported as unknown
                else
                {
                    it->second.lastUsed = std::chrono::steady_clock::now();
                    server = it->second.server;
                    contextId = requested;
                }
            }
            if( unknown )
            {
                respond( c, 404, "application/json", httpErrorBody(
                    "unknown context handle: it does not exist, or it belongs to another credential" ).dump() );
                return;
            }
        }
        else
        {
            // A state-creating call with no handle of its own: mint one and
            // the connection behind it, and return the handle with the result.
            std::string id;
            try { id = mintContextId(); }
            catch( const std::exception& )
            {
                respond( c, 500, "application/json",
                         httpErrorBody( "could not mint a context handle: the system entropy source failed" ).dump() );
                return;
            }
            std::shared_ptr<JsonRpcServer> fresh = sessionFactory();
            std::vector<std::shared_ptr<JsonRpcServer>> released;
            bool tooMany = false;
            {
                std::lock_guard<std::mutex> lk( state.mu );
                expireIdle( state, released );
                tooMany = ( state.sessions.size() + state.contexts.size() >= maxSessions() );
                if( !tooMany )
                {
                    state.contexts[ id ] = ContextEntry{ fresh, cred.clientName, callerFp,
                                                        std::chrono::steady_clock::now() };
                    server = fresh;
                    contextId = id;
                }
            }
            if( tooMany )
            {
                respond( c, 503, "application/json", httpErrorBody( "too many open MCP sessions" ).dump() );
                return;
            }
        }

        CallOptions opts;
        opts.era = ProtocolEra::Modern;
        opts.contextId = contextId;
        opts.toolAllow = cred.allow;
        const auto resp = server->handleLine( body.dump(), cred.clientName, opts );
        if( resp )
            respond( c, 200, "application/json", *resp );
        else
            // A notification has no JSON-RPC reply; the HTTP exchange still
            // needs an answer, and 202 says "accepted, nothing to return".
            respond( c, isRequest ? 200 : 202, "application/json", "" );
    }

    // One request's full handling (health, origin, auth, session mint/resolve,
    // dispatch, response) — the named steps of the old loop body; every early
    // exit is a `return` where the loop version said `continue`.
    static void handleRequest( Conn& c, const HttpConfig& cfg, const HttpRequest& req,
                               TokenStore& tokens,
                               const std::function<bool()>& readinessProbe,
                               const std::function<std::shared_ptr<JsonRpcServer>()>& sessionFactory,
                               ClientState& state )
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

        // ---- Origin validation ----
        // A browser origin that this deployment does not allow is refused
        // before the request is looked at any further. A request with no
        // Origin header is not a browser request and is allowed through.
        {
            auto originIt = req.headers.find( "origin" );
            const std::string origin = originIt == req.headers.end() ? std::string() : trimCopy( originIt->second );
            if( !originAllowed( origin, cfg ) )
            {
                respond( c, 403, "application/json", rpcErrorBody( -32000,
                    "origin not allowed: " + origin + " is not a loopback origin and is not "
                    "listed in FSQL_MCP_ALLOWED_ORIGINS" ) );
                return;
            }
        }

        // ---- Bearer gate: everything else requires a credential ----
        // The Authorization header is the ONLY place a credential is read
        // from: a token in the URL's query string is not a credential (it
        // would end up in proxy logs and browser history anyway).
        std::string bearer;
        {
            auto auth = req.headers.find( "authorization" );
            if( auth != req.headers.end() )
            {
                const std::string v = auth->second;
                if( lowerCopy( v ).rfind( "bearer ", 0 ) == 0 ) bearer = trimCopy( v.substr( 7 ) );
            }
        }
        const TokenStore::Credential cred = tokens.check( bearer );
        if( !cred.ok )
        {
            // 401 BEFORE the request reaches the adapter layer. The
            // presented value is never logged. The challenge names the
            // realm; a token that WAS presented but is wrong or expired
            // also says why.
            authFailed();
            std::map<std::string,std::string> extra;
            extra[ "WWW-Authenticate" ] = std::string( kAuthRealm ) +
                ( bearer.empty() ? "" : ", error=\"invalid_token\"" );
            respond( c, 401, "application/json",
                     Json{ { "error", bearer.empty() ? "missing bearer token" : "invalid bearer token" } }.dump(),
                     extra );
            return;
        }
        authOk();
        const std::string callerFp = tokenFingerprint( bearer );

        const bool pathMatched = req.target == cfg.path || req.target == cfg.path + "/";
        if( !pathMatched )
            { respond( c, 404, "application/json", httpErrorBody( "not found" ).dump() ); return; }

        if( req.method == "GET" || req.method == "DELETE" )
        {
            // The modern era has no GET stream and no session teardown, so
            // both are refused for a modern request.
            auto pv = req.headers.find( "mcp-protocol-version" );
            const bool modernHeader = pv != req.headers.end()
                && isModernVersionHeader( trimCopy( pv->second ) );
            if( modernHeader || modernEraOnly() )
            {
                respond( c, 405, "application/json", httpErrorBody(
                    req.method == "GET"
                        ? "GET is not used by the modern protocol era; POST JSON-RPC 2.0 messages"
                        : "DELETE is not used by the modern protocol era; it has no protocol session to tear down" ).dump() );
                return;
            }
            if( req.method == "GET" )
                { respond( c, 405, "application/json", httpErrorBody( "GET on the mcp path is not served; use POST" ).dump() ); return; }

            // Session close: drops the session's dedicated DB connection.
            auto sid = req.headers.find( "mcp-session-id" );
            bool closed = false;
            {
                std::lock_guard<std::mutex> lkS( state.mu );
                if( sid != req.headers.end() )
                {
                    auto sit = state.sessions.find( sid->second );
                    if( sit != state.sessions.end() && sit->second.owner == callerFp )
                    { state.sessions.erase( sit ); closed = true; }
                }
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
        if( !jsonNestsTooDeep( req.body ) )
        {
            try { parsed = Json::parse( req.body ); isJson = true; isBatch = parsed.is_array(); }
            catch( ... ) { isJson = false; }
        }
        // An empty batch is an invalid request under JSON-RPC 2.0.
        if( !isJson || ( !isBatch && !parsed.is_object() ) || ( isBatch && parsed.empty() ) )
        {
            // A body that is not a JSON-RPC message is a PARSE ERROR, and the
            // JSON-RPC error object says so -- the same shape every other
            // pre-dispatch refusal in this file uses.
            respond( c, 400, "application/json",
                     rpcErrorBody( -32700, "parse error: the request body is not a JSON-RPC 2.0 message" ) );
            return;
        }

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

        // ---- the era of this request ----
        // "initialize" is the legacy handshake and always selects the legacy
        // flow; a body carrying the modern metadata, or a version header
        // naming a modern (or unknown) revision, selects the modern era.
        // A batch is a legacy-era feature (the modern era is one request at
        // a time), so it always takes the legacy flow.
        const std::string bodyMethod = ( !isBatch && parsed.contains( "method" ) && parsed[ "method" ].is_string() )
            ? parsed[ "method" ].get<std::string>() : std::string();
        const bool isModern = !isBatch && isModernRequest( req, parsed, bodyMethod );

        if( modernEraOnly() && !isModern )
        {
            // A modern-only server refuses the legacy era outright, and says
            // which revisions it speaks.
            respond( c, 400, "application/json", rpcErrorBody( -32000,
                "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                "the legacy initialize handshake and the legacy session headers are refused. "
                "Supported versions: 2025-11-25, 2026-07-28" ) );
            return;
        }

        if( isModern )
        {
            handleModernRequest( c, req, parsed, cred, callerFp, sessionFactory, state );
            return;
        }

        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;

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
            // Bound the map: idle sessions expire and the live count is
            // capped, since each pins a database connection.
            {
                std::vector<std::shared_ptr<JsonRpcServer>> released;
                bool tooMany = false;
                {
                    std::lock_guard<std::mutex> lkS( state.mu );
                    expireIdle( state, released );
                    tooMany = ( state.sessions.size() + state.contexts.size() >= maxSessions() );
                }
                if( tooMany )
                {
                    respond( c, 503, "application/json", httpErrorBody( "too many open MCP sessions" ).dump() );
                    return;
                }
            }
            // The session's server (and with it its database connection) is
            // created OUTSIDE the lock.
            std::shared_ptr<JsonRpcServer> server = sessionFactory();
            std::string clientKey;
            {
                std::lock_guard<std::mutex> lkS( state.mu );
                SessionEntry& entry = state.sessions[ minted ];
                entry.server = server;
                entry.clientKey = clientKeyFor( cfg, bearer, minted );
                entry.owner = callerFp;
                clientKey = entry.clientKey;
            }
            Json out;
            if( isBatch )
            {
                Json responses = Json::array();
                for( const Json& one : parsed )
                    if( auto r = server->handleLine( one.dump(), clientKey, opts ) ) responses.push_back( Json::parse( *r ) );
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
                const auto r = server->handleLine( parsed.dump(), clientKey, opts );
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
        bool knownSession = false;
        {
            std::lock_guard<std::mutex> lkS( state.mu );
            auto it = state.sessions.find( sidHdr->second );
            if( it != state.sessions.end() && it->second.owner == callerFp )
            {
                server = it->second.server;
                clientKey = it->second.clientKey;
                it->second.lastUsed = std::chrono::steady_clock::now();
                knownSession = true;
            }
        }
        if( !knownSession )
            { respond( c, 404, "application/json", httpErrorBody( "unknown mcp-session-id" ).dump() ); return; }

        // In the legacy era the protocol session supplies the context. A
        // request that names a context handle explicitly must name the
        // session's own context -- the session id IS that context's handle.
        {
            const std::string ctx = requestedContextId( parsed );
            if( !ctx.empty() && ctx != sidHdr->second )
            {
                respond( c, 404, "application/json", httpErrorBody(
                    "unknown context handle: it does not exist, or it belongs to another credential" ).dump() );
                return;
            }
        }

        Json out;
        if( isBatch )
        {
            Json responses = Json::array();
            for( const Json& one : parsed )
                if( auto r = server->handleLine( one.dump(), clientKey, opts ) ) responses.push_back( Json::parse( *r ) );
            // A batch made up ENTIRELY of notifications produces no JSON-RPC
            // reply at all: 202 (accepted, nothing to return) rather than
            // 200 with an empty array, which reads as an empty result.
            if( responses.empty() )
            { respond( c, 202, "application/json", "" ); return; }
            out = responses.size() == 1 ? responses[ 0 ] : Json( responses );
        }
        else
        {
            const auto r = server->handleLine( parsed.dump(), clientKey, opts );
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

    static int runListener( const HttpConfig& cfg,
                             std::shared_ptr<TokenStore> tokens,
                             std::shared_ptr<TlsLayer> tls,
                             std::function<bool()> readinessProbe,
                             std::function<std::shared_ptr<JsonRpcServer>()> sessionFactory,
                             std::shared_ptr<ClientState> state )
    {
        // The configuration is copied: a connection thread may still be running
        // when the serving code returns, and it must not read the caller's
        // configuration object after that.
        const HttpConfig cfgCopy = cfg;
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
        if( !cfg.tlsEnabled && !( bindHost.empty() || bindHost == "localhost" || bindHost == "::1" || bindHost.rfind( "127.", 0 ) == 0 ) )
        {
            std::cerr << "WARNING: the HTTP transport is bound to non-loopback address '" << bindHost
                      << "' WITHOUT TLS; the bearer token and all results travel in clear text (set FSQL_MCP_HTTPS=true)\n";
            const char* allowPlain = std::getenv( "FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK" );
            if( !( allowPlain && *allowPlain && std::string( allowPlain ) != "0" && std::string( allowPlain ) != "false" ) )
            {
                std::cerr << "refusing a non-loopback HTTP bind without TLS (set FSQL_MCP_HTTPS=true, or FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=true to accept the risk)\n";
                return 1;
            }
        }
        std::string listenErr;
        net::Socket listener = net::listenTcp( bindHost, cfg.port, listenErr );
        if( net::isInvalid( listener ) )
        {
            std::cerr << "http listen failed on " << bindHost << ":" << cfg.port
                      << ( listenErr.empty() ? std::string() : " -- " + listenErr ) << "\n";
            return 1;   // a set host that does not parse is a config error, not a bind-all fallback
        }

        // Count of live connection threads, which the shutdown drain waits on.
        // Shared, so a thread that is still running after the drain deadline
        // keeps the counter alive for as long as it needs it.
        std::shared_ptr<std::atomic<int>> liveCount = std::make_shared<std::atomic<int>>( 0 );
        // Refusals in flight: connections that were turned away at the limit
        // and are still having their reply delivered. They are not counted
        // against the connection limit (they serve nothing), but the drain
        // waits for them too, so a refusal is not cut in half by a shutdown.
        std::shared_ptr<std::atomic<int>> refusalsInFlight = std::make_shared<std::atomic<int>>( 0 );
        const int connLimit = maxConnections();
        logging::event( "http_max_connections", Json{ { "limit", connLimit } } );

        while( !g_httpSignalled.load() )
        {
            net::Socket client = net::accept( listener );
            if( net::isInvalid( client ) )
            {
                // accept() returns EINTR on any signal (SIGHUP included), and
                // fails when descriptors run out: keep serving unless this is
                // a shutdown.
                if( g_httpSignalled.load() ) break;
                if( !net::wouldBlock() )
                    std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
                continue;
            }
            if( liveCount->load() >= connLimit )
            {
                // Over the limit: refuse before spending a thread on the
                // request itself. A TLS client cannot read a plaintext reply;
                // it just sees the close.
                if( !cfg.tlsEnabled )
                {
                    static const char kBusy[] = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
                                                "Content-Length: 0\r\nConnection: close\r\n\r\n";
                    net::send( client, kBusy, static_cast<int>( sizeof( kBusy ) - 1 ) );
                    // The refusal is finished on its own short-lived thread:
                    // draining the peer's request takes a moment, and the
                    // accept loop must keep accepting while it does. A bounded
                    // number of these may be in flight; past that the socket
                    // is closed at once, because a flood of refused
                    // connections must not cost the server more than it is
                    // already refusing.
                    if( refusalsInFlight->fetch_add( 1 ) < kMaxRefusalsInFlight )
                    {
                        std::thread( [ client, refusalsInFlight ] {
                            net::closeAfterReply( client, kRefusalLingerMs );
                            refusalsInFlight->fetch_sub( 1 );
                        } ).detach();
                    }
                    else
                    {
                        refusalsInFlight->fetch_sub( 1 );
                        net::close( client );
                    }
                }
                else
                    net::close( client );
                continue;
            }
            net::setRecvTimeout( client, 2000 );   // bounds the shutdown drain on an idle connection
            liveCount->fetch_add( 1 );
            // Detached thread: it ends after writing its single response.
            // Everything it touches is captured BY VALUE (the configuration
            // copy, the token store, the client state, the TLS context, the
            // connection counter and the session factory), so a thread that is
            // still running when the serving code returns keeps every object it
            // needs alive.
            std::thread( [ cfgCopy, client, liveCount, tokens, tls,
                           readinessProbe, sessionFactory, state ]
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
                    const int rc = readRequest( c, cfgCopy, req, pending );
                    if( rc != 0 ) { liveCount->fetch_sub( 1 ); return; }

                    handleRequest( c, cfgCopy, req, *tokens, readinessProbe, sessionFactory, *state );
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
        // hold shared ownership of everything they touch (the token store, the
        // client state, the TLS context), so a straggler that outlives the
        // drain keeps those objects alive until it finishes; process teardown
        // cuts the tail without a use-after-free.
        {
            const auto drainDeadline = std::chrono::steady_clock::now()
                + std::chrono::milliseconds( cfg.shutdownDrainMs );
            while( ( liveCount->load() > 0 || refusalsInFlight->load() > 0 )
                   && std::chrono::steady_clock::now() < drainDeadline )
                std::this_thread::sleep_for( std::chrono::milliseconds( 50 ) );
        }
        return 0;
    }

    int runHttpTransport( const HttpConfig& cfg, std::function<bool()> readinessProbe,
                           std::function<std::shared_ptr<JsonRpcServer>()> sessionFactory )
    {
        // The token store and the per-client state are shared, not owned by
        // this function alone: connection threads are cut loose at the drain
        // deadline (above) and can still be INSIDE a request when this
        // function's bounded waits finish. Sharing the ownership keeps both
        // alive for as long as such a thread needs them, and releases them
        // when the last holder is done.
        std::shared_ptr<TokenStore> tokens = std::make_shared<TokenStore>( cfg );
        std::shared_ptr<ClientState> state = std::make_shared<ClientState>();

        net::init();
        std::shared_ptr<TlsLayer> tls;
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

        const int rc = runListener( cfg, tokens, tls, std::move( readinessProbe ),
                                     std::move( sessionFactory ), state );

        // Close every session's database connection at shutdown. Without this
        // the per-session PGconns stayed open until the process died -- on a
        // rolling restart, that is one postgres backend per session held for
        // the whole supervisor's stop timeout. Clearing the map drops the MAP's
        // references: a session no thread is using is destroyed right here
        // (its JsonRpcServer goes with it, and with it the Db it owns, whose
        // destructor closes the connection), while a session a straggler
        // thread is still inside survives until that thread finishes --
        // which is the point: its Db must not be closed under it. The same
        // goes for the modern era's context handles and the per-credential
        // connections: each owns a connection of its own.
        {
            std::lock_guard<std::mutex> lkS( state->mu );
            state->sessions.clear();
            state->contexts.clear();
            state->creds.clear();
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