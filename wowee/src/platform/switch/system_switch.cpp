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
#include <netdb.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <cerrno>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "addons/framexml_recovery.hpp"

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
    if (!makeDirectory(kDataRoot)) return false;
    if (!makeDirectory(kWritableRoot)) return false;
    makeDirectory(kWritableRoot + "/logs");
    makeDirectory(kWritableRoot + "/cache");
    makeDirectory(kWritableRoot + "/saves");
    makeDirectory(kWritableRoot + "/config");
    makeDirectory(kWritableRoot + "/tmp");
    return true;
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
    g_initialised = true;
    reportBootStage("initSystem");
    return true;
}

void shutdownSystem() {
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
    // Async-signal-safe: append to the already-open boot log. No locks.
    std::string path = std::string(kWritableRoot) + "/logs/boot.log";
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (!f) return;
    std::fprintf(f, "FATAL SIGNAL %d\n", signal);
    std::fflush(f);
    std::fclose(f);
}

bool installCrashReporter() {
    // libnx delivers errors to the OS error applet on abnormal exit; the
    // per-thread signal handler in main.cpp already logs markers to
    // boot.log, so there is nothing further to install here.
    return true;
}

void registerCrashReportingThread(const char* /*name*/) {
    // Horizon has no per-thread alternate signal stack service, and newlib's
    // default thread stacks are large enough for the loaders that call this.
}

size_t defaultThreadStackBytes() {
    // libnx threads default to 8 KiB plus an explicit size at creation.
    return 8192;
}

void showStartupError(const char* message) {
    // The fatal service is the Switch's system error dialog: it shows the
    // error code on screen and writes a report. The full diagnosis stays in
    // the boot log, which is why the text is logged here first.
    std::fprintf(stderr, "[wowee/switch] FATAL: %s\n", message ? message : "(null)");
    reportBootStage("fatal: startup error");
    fatalThrow(MAKERESULT(Module_Libnx, LibnxError_ShouldNotHappen));
}

std::string dataRoot() { return kDataRoot; }
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
    // libnx titles have no per-frame system event queue to drain; the OS
    // suspend/applet lifecycle is handled by keeping the applet's main
    // loop alive. Home/PS buttons show the system overlay, which has its
    // own path back to the title.
    (void)g_splashHidden;
}

}  // namespace switchport
}  // namespace platform
}  // namespace wowee
