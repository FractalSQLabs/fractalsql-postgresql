#pragma once
// Platform socket shim for the HTTP transport: the only place in mcp/src that
// touches Winsock2/POSIX sockets. It deliberately includes no heavy standard
// or JSON headers, because including <winsock2.h> in the same translation unit
// as the JSON header exhausts memory on some Windows GCC/MinGW toolchains.
//
// It also provides a settable per-connection receive timeout and a tri-state
// recv() that keeps the errno inspection inside this file.
#include <cstdint>
#include <string>

namespace fsqlmcp::net
{
    // Opaque, no-include socket handles (fd on POSIX, SOCKET on Windows);
    // kept typeless here so no TU besides the .cpp needs the platform
    // headers.
    using Socket = void*;

    Socket invalidSocket();
    bool isInvalid( Socket s );

    // The underlying OS descriptor (fd on POSIX, SOCKET on Windows) as an
    // intptr_t, exposed ONLY so the optional direct-TLS mode can hand it to
    // OpenSSL's SSL_set_fd(), which takes a plain int either way -- the same
    // narrowing every OpenSSL-on-Windows caller accepts (real socket values
    // never approach INT_MAX in practice).
    std::intptr_t rawHandle( Socket s );

    void init();          // WSAStartup on Windows; no-op on POSIX
    void shutdownNet();   // WSACleanup on Windows; no-op on POSIX

    // Returns invalidSocket() + a human-readable reason on failure.
    Socket listenTcp( const std::string& host, int port, std::string& errOut );

    Socket accept( Socket listenSock );      // invalidSocket() when the listener has stopped
    void stopListening( Socket listenSock ); // shutdown(both); wakes a blocked accept()
    void close( Socket s );

    // recv(): >0 bytes read, 0 = clean EOF, -1 = hard error, -2 = "would
    // block / idle" (EWOULDBLOCK, a receive timeout, or an interrupted
    // call). The tri-state keeps the errno inspection INSIDE this file,
    // immediately after the syscall -- reading errno across a call boundary
    // is fragile.
    int recv( Socket s, char* buf, int len );

    // send(): >0 bytes written, <=0 = failure.
    int send( Socket s, const char* buf, int len );

    // Bounded idle-read window (milliseconds) on an accepted connection.
    void setRecvTimeout( Socket s, int ms );

    // True when the LAST socket call on this thread failed with a retryable
    // condition (EWOULDBLOCK/EINTR on POSIX; WSAEWOULDBLOCK/WSAETIMEDOUT on
    // Windows). The caller decides whether that is benign (an interrupted
    // accept) or fatal.
    bool wouldBlock();
}
