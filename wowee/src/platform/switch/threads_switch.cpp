// threads_switch.cpp - let the client ask for generous thread stacks.
//
// The PS4 port needed a real pthread_create interposer because the console
// defaulted to a small stack and miniaudio's device thread (MP3 decode)
// overflowed it. On Switch the practical fix lives where the stack is
// chosen: the miniaudio context is created with an explicit
// ma_context_config.threadStackSize (see audio_backend_switch.cpp), and the
// client asks the same for its own long-lived worker threads through
// defaultThreadStackBytes() so callers can log the value at startup.
#include "platform/switch/switch_platform.hpp"

#include <pthread.h>
#include <cstddef>
#include <cstdint>

namespace {
constexpr size_t kThreadStackBytes = 2u * 1024u * 1024u;
}

namespace wowee {
namespace platform {
namespace switchport {

size_t defaultThreadStackBytes() {
    pthread_attr_t attr{};
    if (pthread_attr_init(&attr) != 0) return kThreadStackBytes;
    size_t bytes = 0;
    pthread_attr_getstacksize(&attr, &bytes);
    pthread_attr_destroy(&attr);
    return bytes ? bytes : kThreadStackBytes;
}

}  // namespace switchport
}  // namespace platform
}  // namespace wowee
