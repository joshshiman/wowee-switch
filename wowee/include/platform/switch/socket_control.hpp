#pragma once

#include <sys/socket.h>
#include <fcntl.h>

namespace wowee::platform::switchport {

// Newlib over the Horizon bsd service is close enough to POSIX: socket
// mode changes work with fcntl directly.
inline bool setSocketNonBlocking(int socket) {
    const int flags = ::fcntl(socket, F_GETFL, 0);
    return flags != -1 && ::fcntl(socket, F_SETFL, flags | O_NONBLOCK) != -1;
}

}  // namespace wowee::platform::switchport
