// system_switch.cpp - Nintendo Switch process and system services for WoWee.
//
// The system half of include/platform/switch/switch_platform.hpp: one-time
// init/shutdown, writable tree creation, environment defaults, logging path,
// host-name resolution over libnx's BSD sockets, crash reporting through
// libnx fatal, and the per-frame pump that keeps the title responsible to
// the OS.
//
// Main-thread only, except resolveIPv4, which may be called from any thread
// once initSystem has returned.

#include "platform/switch/switch_platform.hpp"
#include "core/env.hpp"
#include "core/logger.hpp"

#include <switch.h>
#include <switch/runtime/devices/fs_dev.h>
#include <switch/runtime/devices/socket.h>
#include <switch/services/fatal.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <cerrno>
#include <fstream>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>


namespace wowee {
namespace platform {
namespace switchport {

// From src/platform/switch/vk_nxvk_loader.cpp: NVK's documented bring-up
// requirement before any Vulkan call.
extern "C" void vk_nxvk_loader_init(void);

namespace {

constexpr const char* kDataRoot = "sdmc:/wowps";
constexpr const char* kWritableRoot = "sdmc:/wowps/wowps";
constexpr const char* kAppRoot = "romfs:/";

bool g_initialised = false;
bool g_splashHidden = false;
bool g_frameTraceEnabled = false;
bool g_exitRequested = false;
// The boot log, opened once so the crash-signal path only ever writes to a
// known descriptor (see reportCrashSignal).
volatile std::sig_atomic_t g_bootFd = -1;

void klog(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::fputs("[wowee/switch] ", stdout);
    std::vfprintf(stdout, fmt, args);
    std::fputc('\n', stdout);
    std::fflush(stdout);
    va_end(args);
}

// mkdir that treats "already there" as success. One level per call.
bool makeDirectory(const std::string& path) {
    if (::mkdir(path.c_str(), 0777) == 0) return true;
    if (errno == EEXIST) return true;
    klog("mkdir(%s) failed: errno %d (%s)", path.c_str(), errno, std::strerror(errno));
    return false;
}

bool createDirectories() {
    bool ok = makeDirectory(kDataRoot);
    ok = makeDirectory(kWritableRoot) && ok;
    // Parent first: the log/cache/saves/config/tmp children only resolve once
    // the writable root itself exists.
    for (const char* relative : {"/logs", "/cache", "/saves", "/config", "/tmp"}) {
        ok = makeDirectory(std::string(kWritableRoot) + relative) && ok;
    }
    return ok;
}

// Set the process environment the rest of the client reads, in the same
// shape as the desktop build: WOW_DATA_PATH points at the user's game
// assets, HOME and TMPDIR at the writable tree.
void applyEnvironment() {
    if (!std::getenv("WOW_DATA_PATH")) {
        setenv("WOW_DATA_PATH", kDataRoot, 0);
    }
    if (!std::getenv("HOME")) {
        setenv("HOME", kWritableRoot, 0);
    }
    if (!std::getenv("TMPDIR")) {
        setenv("TMPDIR", (kWritableRoot + "/tmp").c_str(), 0);
    }
}

}  // namespace

bool initSystem() {
    if (g_initialised) return true;

    fsInitialize();
    if (R_FAILED(fsdevMountSdmc())) {
        klog("fsdevMountSdmc failed; sdmc:/ assets are unavailable");
    }
    appletInitialize();

    if (R_FAILED(socketInitializeDefault())) {
        klog("socketInitializeDefault failed");
    }

    createDirectories();
    applyEnvironment();
    vk_nxvk_loader_init();
    // Opened once, in append mode: reportCrashSignal only writes to this
    // descriptor, so the signal path never allocates or takes a lock.
    const std::string bootLog = std::string(kWritableRoot) + "/logs/boot.log";
    g_bootFd = ::open(bootLog.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0666);
    g_initialised = true;
    reportBootStage("initSystem");
    return true;
}

void shutdownSystem() {
    if (!g_initialised) return;
    reportBootStage("shutdown");
    socketExit();
    fsdevUnmountAll();
    g_initialised = false;
}

void hideSplashScreen() {
    // libnx titles surface a system error/loader screen; the game's own
    // loading screen takes over presentation as soon as the first frame
    // is committed. There is no separate splash service to dismiss.
    g_splashHidden = true;
}

void setFrameTraceEnabled(bool enabled) { g_frameTraceEnabled = enabled; }
bool frameTraceEnabled() { return g_frameTraceEnabled; }

void reportBootStage(const char* stage) {
    if (!stage) return;
    // Mirrors the PS4 breadcrumb file: append to logs/boot.log with no
    // userspace buffer and keep the previous launch's copy.
    std::string path = std::string(kWritableRoot) + "/logs/boot.log";
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (!f) return;
    std::time_t t = std::time(nullptr);
    char ts[32];
    std::strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", std::localtime(&t));
    std::fprintf(f, "[%s] %s\n", ts, stage);
    std::fflush(f);
    std::fclose(f);
    std::printf("[boot] %s\n", stage);
}

void reportCrashSignal(int signal) {
    // Async-signal-safe: the boot log is already open (opened once in
    // initSystem), so this only writes a fixed line to a known descriptor. No
    // allocation, no locks, no formatting beyond one integer.
    static const char kPrefix[] = "[signal] FATAL SIGNAL ";
    if (g_bootFd < 0) return;
    char digits[12];
    size_t n = 0;
    unsigned value = signal < 0 ? static_cast<unsigned>(-signal) : static_cast<unsigned>(signal);
    do {
        digits[n++] = static_cast<char>('0' + (value % 10));
        value /= 10;
    } while (value != 0 && n < sizeof(digits));
    char line[sizeof(kPrefix) + sizeof(digits) + 2];
    size_t at = 0;
    for (size_t i = 0; kPrefix[i]; ++i) line[at++] = kPrefix[i];
    if (signal < 0) line[at++] = '-';
    while (n > 0) line[at++] = digits[--n];
    line[at++] = '\n';
    ::write(g_bootFd, line, at);
}

bool installCrashReporter() {
    // libnx has no per-thread signal stack service and its fatal service only
    // raises after the process is already unwinding, so the marker written by
    // reportCrashSignal above is the whole of the crash reporting here.
    return g_bootFd >= 0;
}

void registerCrashReportingThread(const char* /*name*/) {
    // Horizon has no per-thread alternate signal stack service, and newlib's
    // default thread stacks are large enough for the loaders that call this.
}

void showStartupError(const char* message) {
    // The fatal service is the Switch's system error dialog: it shows the
    // error code on screen and writes a report. The full diagnosis stays in
    // the boot log, which is why the text is logged here first.
    std::fprintf(stderr, "[wowee/switch] FATAL: %s\n", message ? message : "(null)");
    reportBootStage("fatal: startup error");
    fatalThrow(MAKERESULT(Module_Libnx, LibnxError_ShouldNotHappen));
}

std::string dataRoot() {
    const char* configured = std::getenv("WOW_DATA_PATH");
    return (configured && *configured) ? configured : kDataRoot;
}
std::string writableRoot() { return kWritableRoot; }
std::string appRoot() { return kAppRoot; }

uint32_t resolveIPv4(const std::string& host) {
    // libnx's newlib getaddrinfo resolves names through the bsd service.
    struct addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = nullptr;
    if (::getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) {
        return 0;
    }
    uint32_t ip = 0;
    if (res->ai_addr && res->ai_addr->sa_family == AF_INET) {
        auto* in = reinterpret_cast<sockaddr_in*>(res->ai_addr);
        ip = in->sin_addr.s_addr;
    }
    ::freeaddrinfo(res);
    return ip;
}

void pumpSystemEvents() {
    // The title's lifecycle. appletMainLoop() is false once the OS has asked
    // the title to close; a frame budget is kept open for libnx to deliver
    // applet events (Home is the system overlay's, suspend/resume is handled
    // by the OS around the title). Nothing here blocks - this runs per frame.
    if (!appletMainLoop()) {
        if (!g_exitRequested) {
            g_exitRequested = true;
            klog("applet reported exit");
            reportBootStage("system: exit requested");
        }
    }
    (void)g_splashHidden;
}

}  // namespace switchport
}  // namespace platform
}  // namespace wowee
