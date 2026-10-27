// The Windows leg of the socket shim (transport_socket.h). Deliberately the
// ONLY Winsock-including TU in mcp/src.
#if defined( _WIN32 )
#include "transport_socket.h"
#define _WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <atomic>
#include <cstdint>
#include <string>

namespace fsqlmcp::net
{
    static SOCKET asSock( Socket s ) { return reinterpret_cast<SOCKET>( s ); }

    // Winsock's refcount: WSAStartup/WSACleanup are process-wide, and the
    // HTTP transport may be entered more than once in a process (the TLS
    // init-failure path tears the layer down again). The counter keeps the
    // cleanup paired with the init, exactly as the transport's own inline
    // Winsock block did before the shim existed.
    static std::atomic<int> g_wsaRefs{ 0 };

    Socket invalidSocket() { return reinterpret_cast<void*>( INVALID_SOCKET ); }
    bool isInvalid( Socket s ) { return asSock( s ) == INVALID_SOCKET; }
    std::intptr_t rawHandle( Socket s ) { return static_cast<std::intptr_t>( asSock( s ) ); }

    void init()
    {
        WSADATA wsa;
        if( WSAStartup( MAKEWORD( 2, 2 ), &wsa ) == 0 ) ++g_wsaRefs;
    }
    void shutdownNet()
    {
        if( --g_wsaRefs == 0 ) WSACleanup();
    }

    Socket listenTcp( const std::string& host, int port, std::string& errOut )
    {
        const SOCKET s = ::socket( AF_INET, SOCK_STREAM, IPPROTO_TCP );
        if( s == INVALID_SOCKET )
        {
            errOut = "socket() failed: WSA error " + std::to_string( WSAGetLastError() );
            return invalidSocket();
        }
        int one = 1;
        ::setsockopt( s, SOL_SOCKET, SO_REUSEADDR,
                      reinterpret_cast<const char*>( &one ), sizeof( one ) );
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( port ) );
        if( InetPtonA( AF_INET, host.c_str(), &addr.sin_addr ) != 1 )
        {
            errOut = "unparsable listen host: " + host;
            ::closesocket( s );
            return invalidSocket();
        }
        if( ::bind( s, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) == SOCKET_ERROR ||
            ::listen( s, 16 ) == SOCKET_ERROR )
        {
            errOut = "bind/listen failed: WSA error " + std::to_string( WSAGetLastError() );
            ::closesocket( s );
            return invalidSocket();
        }
        return reinterpret_cast<void*>( s );
    }

    Socket accept( Socket listenSock )
    {
        const SOCKET s = ::accept( asSock( listenSock ), nullptr, nullptr );
        if( s == INVALID_SOCKET ) return invalidSocket();
        return reinterpret_cast<void*>( s );
    }

    void stopListening( Socket listenSock ) { ::shutdown( asSock( listenSock ), SD_BOTH ); }

    int recv( Socket s, char* buf, int len )
    {
        const int n = ::recv( asSock( s ), buf, len, 0 );
        if( n > 0 ) return n;
        if( n == 0 ) return 0;   // clean EOF
        // A timeout (WSAETIMEDOUT) and a would-block are both "idle" for
        // the transport's purposes: the caller closes the connection rather
        // than treating it as a protocol error.
        const int e = WSAGetLastError();
        return ( e == WSAEWOULDBLOCK || e == WSAETIMEDOUT ) ? -2 : -1;
    }

    int send( Socket s, const char* buf, int len )
    {
        const int sent = ::send( asSock( s ), buf, len, 0 );
        return sent == SOCKET_ERROR ? -1 : sent;
    }

    void setRecvTimeout( Socket s, int ms )
    {
        DWORD v = static_cast<DWORD>( ms );
        ::setsockopt( asSock( s ), SOL_SOCKET, SO_RCVTIMEO,
                      reinterpret_cast<const char*>( &v ), sizeof( v ) );
    }

    bool wouldBlock()
    {
        const int e = WSAGetLastError();
        return e == WSAEWOULDBLOCK || e == WSAETIMEDOUT;
    }

    void close( Socket s ) { ::closesocket( asSock( s ) ); }
}
#endif  // _WIN32
