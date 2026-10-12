#pragma once

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <fcntl.h>

namespace wowee::platform::switchport {

// Make a socket non-blocking.
//
// fcntl is the POSIX way and is tried first, but the sibling PS4 port recorded
// fcntl returning EACCES on console and stopping login *before it contacted the
// auth server* (CHANGELOG), and Horizon's bsd service is not guaranteed to
// honour it either. So fall back to ioctl(FIONBIO), then to the BSD SO_NBIO
// socket option where the headers have it. The previous single-fcntl version
// treated any failure as fatal to the connect (net_platform.hpp treats a false
// return as fatal), so this is the difference between "connects" and "login
// hard-fails at the first syscall" on the connected-realm path.
inline bool setSocketNonBlocking(int socket) {
    const int flags = ::fcntl(socket, F_GETFL, 0);
    if (flags != -1 && ::fcntl(socket, F_SETFL, flags | O_NONBLOCK) != -1) return true;

    int on = 1;
#ifdef FIONBIO
    if (::ioctl(socket, FIONBIO, &on) == 0) return true;
#endif
#ifdef SO_NBIO
    if (::setsockopt(socket, SOL_SOCKET, SO_NBIO, &on, sizeof(on)) == 0) return true;
#endif
    return false;
}

}  // namespace wowee::platform::switchport
