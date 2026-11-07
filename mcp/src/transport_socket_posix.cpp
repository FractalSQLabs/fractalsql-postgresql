// The POSIX leg of the socket shim (transport_socket.h), Linux/macOS.
#if !defined( _WIN32 )
#include "transport_socket.h"
#include <sys/socket.h>
#include <sys/time.h>   // struct timeval (SO_RCVTIMEO); glibc pulls this
                      // in transitively via sys/socket.h, musl doesn't
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cstdint>   // std::intptr_t, not pulled in transitively here
#include <string>

namespace fsqlmcp::net
{
    static int asFd( Socket s ) { return static_cast<int>( reinterpret_cast<std::intptr_t>( s ) ); }

    Socket invalidSocket() { return reinterpret_cast<void*>( static_cast<std::intptr_t>( -1 ) ); }
    bool isInvalid( Socket s ) { return asFd( s ) < 0; }
    std::intptr_t rawHandle( Socket s ) { return reinterpret_cast<std::intptr_t>( s ); }

    void init() {}
    void shutdownNet() {}

    Socket listenTcp( const std::string& host, int port, std::string& errOut )
    {
        const int fd = ::socket( AF_INET, SOCK_STREAM, 0 );
        if( fd < 0 )
        {
            errOut = "socket() failed: errno " + std::to_string( errno );
            return invalidSocket();
        }
        int one = 1;
        ::setsockopt( fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof( one ) );
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( port ) );
        if( ::inet_pton( AF_INET, host.c_str(), &addr.sin_addr ) != 1 )
        {
            errOut = "unparsable listen host: " + host;
            ::close( fd );
            return invalidSocket();
        }
        if( ::bind( fd, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) < 0 ||
            ::listen( fd, 16 ) < 0 )
        {
            errOut = "bind/listen failed: errno " + std::to_string( errno );
            ::close( fd );
            return invalidSocket();
        }
        return reinterpret_cast<void*>( static_cast<std::intptr_t>( fd ) );
    }

    Socket accept( Socket listenSock )
    {
        const int fd = ::accept( asFd( listenSock ), nullptr, nullptr );
        if( fd < 0 ) return invalidSocket();
        return reinterpret_cast<void*>( static_cast<std::intptr_t>( fd ) );
    }

    void stopListening( Socket listenSock ) { ::shutdown( asFd( listenSock ), SHUT_RDWR ); }

    int recv( Socket s, char* buf, int len )
    {
        const int n = ::recv( asFd( s ), buf, len, 0 );
        if( n > 0 ) return n;
        if( n == 0 ) return 0;   // clean EOF
        // EAGAIN/EWOULDBLOCK = no data yet; EINTR = a signal landed mid-read.
        // Both are "idle" for the transport's purposes (the caller closes the
        // connection rather than treating them as protocol errors), and EINTR
        // must be one of them: the shutdown handlers are installed WITHOUT
        // SA_RESTART precisely so a blocked read wakes up.
        return ( errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ) ? -2 : -1;
    }

    int send( Socket s, const char* buf, int len )
    {
        const int sent = ::send( asFd( s ), buf, len, 0 );
        return sent < 0 ? -1 : sent;
    }

    void setRecvTimeout( Socket s, int ms )
    {
        struct timeval tv{ ms / 1000, ( ms % 1000 ) * 1000 };
        ::setsockopt( asFd( s ), SOL_SOCKET, SO_RCVTIMEO,
                      reinterpret_cast<const char*>( &tv ), sizeof( tv ) );
    }

    bool wouldBlock()
    {
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
    }

    void close( Socket s ) { ::close( asFd( s ) ); }
    void closeAfterReply( Socket s, int lingerMs )
    {
        // Half-close: the peer reads the reply and then sees EOF, so a client
        // that is still writing its request is not reset straight away.
        ::shutdown( asFd( s ), SHUT_WR );
        // Read and discard whatever the peer sends until it stops or the
        // linger window ends. Data left unread in the receive buffer at
        // close time makes the kernel reset the connection, and the reset
        // discards the reply that was just written: the client would see a
        // broken connection instead of the refusal it was owed.
        setRecvTimeout( s, 100 );
        char sink[ 4096 ];
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( lingerMs );
        while( std::chrono::steady_clock::now() < deadline )
        {
            const int n = recv( s, sink, static_cast<int>( sizeof( sink ) ) );
            if( n == 0 ) break;   // the peer closed: nothing more can arrive
            if( n == -1 ) break;  // hard error: the socket is finished anyway
            // n == -2 is an idle read (the peer has not written yet) and n > 0
            // is data to discard: both mean "keep waiting for the rest".
        }
        close( s );
    }
}
#endif  // !defined(_WIN32)
