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
#include <switch/runtime/devices/romfs_dev.h>
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
#include <vector>
#include <dirent.h>
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
// Runtime assets are staged beside the .nro rather than embedded: the launch
// directory is sdmc:/switch/wowee, and the assets live in its data/ subdir.
// Only used when the launch path does not lead to them - see appRoot().
constexpr const char* kAppRoot = "sdmc:/switch/wowee/data";
// Used when the .nro carries the assets itself and nothing on the SD card
// overrides them.
constexpr const char* kEmbeddedRoot = "romfs:/";

bool g_initialised = false;
bool g_splashHidden = false;
bool g_frameTraceEnabled = false;
bool g_exitRequested = false;
bool g_romfsMounted = false;
// argv[0] as the launcher passed it, and the resource root resolved from it.
std::string g_launchPath;
std::string g_appRoot;
std::string g_appRootReported;
// The boot log, opened once so the crash-signal path only ever writes to a
// known descriptor (see reportCrashSignal).
volatile std::sig_atomic_t g_bootFd = -1;

void appendBootLine(const char* text) {
    // The one diagnostic channel: a homebrew process's stdout is not surfaced
    // by an emulator, so anything worth reading later goes to the boot log
    // through the descriptor opened once in initSystem().
    const int fd = g_bootFd;
    if (fd < 0) return;
    char stamp[32];
    const std::time_t now = std::time(nullptr);
    std::strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", std::localtime(&now));
    char line[1024];
    const int length = std::snprintf(line, sizeof line, "[%s] %s\n", stamp, text);
    if (length <= 0) return;
    const size_t total = static_cast<size_t>(length) < sizeof line
                             ? static_cast<size_t>(length)
                             : sizeof line - 1;
    ssize_t written = 0;
    while (static_cast<size_t>(written) < total) {
        const ssize_t chunk = ::write(fd, line + written, total - static_cast<size_t>(written));
        if (chunk <= 0) break;
        written += chunk;
    }
}

void klog(const char* fmt, ...) {
    char text[768];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(text, sizeof text, fmt, args);
    va_end(args);

    std::fputs("[wowee/switch] ", stdout);
    std::fputs(text, stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
    appendBootLine(text);
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

// Read `data_path` out of <writable>/config/paths.cfg.
//
// A console user cannot set an environment variable, and the SD card is FAT:
// no symlinks, so relocating a 20 GB client means either copying it or being
// told where it is. This is the only way to say "my Data lives here".
//
//   # sdmc:/wowps/wowps/config/paths.cfg
//   data_path=sdmc:/wotlk
//
// Blank lines and '#' comments are ignored; the first data_path wins.
std::string dataPathFromConfig() {
    const std::string path = std::string(kWritableRoot) + "/config/paths.cfg";
    std::FILE* file = std::fopen(path.c_str(), "r");
    if (!file) return std::string();
    std::string value;
    char line[512];
    while (std::fgets(line, sizeof line, file)) {
        std::string text(line);
        const size_t hash = text.find('#');
        if (hash != std::string::npos) text.erase(hash);
        while (!text.empty() && (text.back() == '\r' || text.back() == '\n' ||
                                  text.back() == ' ' || text.back() == '\t')) {
            text.pop_back();
        }
        size_t start = 0;
        while (start < text.size() && (text[start] == ' ' || text[start] == '\t')) ++start;
        text.erase(0, start);
        static const char kKey[] = "data_path";
        if (text.rfind(kKey, 0) != 0) continue;
        text.erase(0, sizeof(kKey) - 1);
        size_t valueStart = 0;
        while (valueStart < text.size() && (text[valueStart] == ' ' || text[valueStart] == '\t')) {
            ++valueStart;
        }
        // "data_path=<value>": the separator is part of the line, not the path.
        if (valueStart < text.size() && text[valueStart] == '=') ++valueStart;
        while (valueStart < text.size() && (text[valueStart] == ' ' || text[valueStart] == '\t')) {
            ++valueStart;
        }
        value = text.substr(valueStart);
        if (!value.empty()) break;
    }
    std::fclose(file);
    return value;
}

// Set the process environment the rest of the client reads, in the same
// shape as the desktop build: WOW_DATA_PATH points at the user's game
// assets, HOME and TMPDIR at the writable tree.
void applyEnvironment() {
    if (!std::getenv("WOW_DATA_PATH")) {
        const std::string configured = dataPathFromConfig();
        if (!configured.empty()) {
            // Normalised to the form libnx wants, and reported: a data path
            // that silently does not resolve looks exactly like missing assets.
            std::string value = configured;
            if (value.back() == '/') value.pop_back();
            klog("WOW_DATA_PATH from paths.cfg: %s", value.c_str());
            setenv("WOW_DATA_PATH", value.c_str(), 1);
        } else {
            setenv("WOW_DATA_PATH", kDataRoot, 0);
        }
    }
    if (!std::getenv("HOME")) {
        setenv("HOME", kWritableRoot, 0);
    }
    if (!std::getenv("TMPDIR")) {
        setenv("TMPDIR", (std::string(kWritableRoot) + "/tmp").c_str(), 0);
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

    // Opened as soon as the logs directory exists, so the directory failures
    // above reach the file too: a client that cannot write here usually cannot
    // read its assets either, and that is worth seeing in one place.
    const bool directoriesOk = createDirectories();
    const std::string bootLog = std::string(kWritableRoot) + "/logs/boot.log";
    // Append mode, kept open: the crash-signal path only writes to this
    // descriptor, so it never allocates or takes a lock.
    g_bootFd = ::open(bootLog.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (g_bootFd < 0) {
        klog("could not open %s: errno %d (%s)", bootLog.c_str(), errno,
             std::strerror(errno));
    }
if (!directoriesOk) {
        reportBootStage("some directories under sdmc:/wowps could not be created");
    }
    // The assets are embedded in the .nro as a romfs, so a title is one file
    // with no data directory beside it. libnx finds it through argv[0]: it opens
    // the .nro itself and reads the romfs offset and size out of the header. A
    // launcher that passes no argv - an emulator, typically - leaves the romfs
    // unreachable, so a data directory beside the .nro is kept as a fallback.
    //
    // After the boot log is open, because a mount failure is worth recording and
    // romfsInit has no need to run early.
    if (R_SUCCEEDED(romfsInit())) {
        g_romfsMounted = true;
        klog("romfs: mounted the assets embedded in this .nro");
        // What the mount actually contains, once: build_romfs may nest the
        // directory it was given, and guessing wrong here would silently send
        // every asset lookup to the SD card.
        if (DIR* dir = ::opendir(kEmbeddedRoot)) {
            int listed = 0;
            while (struct dirent* entry = ::readdir(dir)) {
                const std::string name = entry->d_name;
                if (name == "." || name == "..") continue;
                klog("romfs: contains %s", name.c_str());
                if (++listed >= 8) break;
            }
            ::closedir(dir);
        }
        // Whether the paths the client actually opens are visible, and whether
        // a file can be read - the difference between "mounted" and "usable".
        for (const char* probe : {"romfs:/assets", "romfs:/assets/shaders",
                                  "romfs:/Data/expansions"}) {
            struct stat info {};
            const int rc = ::stat(probe, &info);
            klog("romfs probe %s rc=%d errno=%d isdir=%d", probe, rc, errno,
                 (rc == 0 && S_ISDIR(info.st_mode)) ? 1 : 0);
        }
        {
            const char* file = "romfs:/assets/shaders/m2.vert.spv";
            std::FILE* handle = std::fopen(file, "rb");
            klog("romfs probe %s opened=%d errno=%d", file, handle ? 1 : 0, errno);
            if (handle) std::fclose(handle);
        }
    } else {
        klog("romfs: not mounted; %s",
             g_launchPath.empty()
                 ? "this launcher passed no path to the .nro"
                 : "the loader could not reopen it from argv[0]");
    }
    applyEnvironment();
    vk_nxvk_loader_init();
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
    // userspace buffer and keep the previous launch's copy. Falls back to
    // opening the file when the persistent descriptor is not up yet, which is
    // the case for anything logged before initSystem finished.
    if (g_bootFd >= 0) {
        appendBootLine(stage);
    } else {
        std::string path = std::string(kWritableRoot) + "/logs/boot.log";
        std::FILE* f = std::fopen(path.c_str(), "a");
        if (f) {
            std::fprintf(f, "[%s] %s\n", "", stage);
            std::fflush(f);
            std::fclose(f);
        }
    }
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

void setLaunchPath(const char* argv0) {
    g_launchPath = (argv0 && *argv0) ? argv0 : "";
    g_appRoot.clear();
    g_appRootReported.clear();
    if (!g_launchPath.empty()) klog("launch path: %s", g_launchPath.c_str());
}

namespace {

// The directory part of a path, without the trailing separator. Empty when the
// path has no directory component.
std::string parentDirectory(const std::string& path) {
    const size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) return std::string();
    if (slash == 0) return "/";
    return path.substr(0, slash);
}

// File name without its extension, for the bare-filename launch case.
std::string stemOf(const std::string& path) {
    const size_t slash = path.find_last_of('/');
    const std::string name =
        (slash == std::string::npos) ? path : path.substr(slash + 1);
    const size_t dot = name.find_last_of('.');
    return (dot == std::string::npos || dot == 0) ? name : name.substr(0, dot);
}

bool isDirectory(const std::string& path) {
    struct stat info {};
    return ::stat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode);
}

// A candidate root with a trailing slash turns every path built from it into
// "root//path", which devfs does not resolve: "romfs:/" is the case that bit,
// and it is why the embedded assets were mounted, listed, read successfully, and
// then not used.
std::string withoutTrailingSlash(std::string root) {
    while (root.size() > 1 && root.back() == '/') root.pop_back();
    return root;
}

// A candidate root only counts when it actually carries the assets: the marker
// is the first shader the renderer cannot start without.
bool holdsAssets(const std::string& root) {
    return !root.empty() && isDirectory(withoutTrailingSlash(root) + "/assets/shaders");
}

// A "<dir>/data" whose shaders are present, found by listing one folder level.
// Used when nothing the launch path suggested worked: an emulator reports the
// .nro's location on the host, which says nothing about the emulated card.
std::string findAssetsBesideLaunchDirs() {
    for (const char* scanRoot : {"sdmc:/", "sdmc:/switch"}) {
        DIR* dir = ::opendir(scanRoot);
        if (!dir) continue;
        int seen = 0;
        std::string found;
        while (struct dirent* entry = ::readdir(dir)) {
            // Bounded: a card can hold hundreds of folders, and the marker test
            // is a stat per entry.
            if (++seen > 64) break;
            const std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            const std::string candidate = std::string(scanRoot) + name + "/data";
            if (holdsAssets(candidate)) {
                found = candidate;
                break;
            }
        }
        ::closedir(dir);
        if (!found.empty()) return found;
    }
    return std::string();
}

}  // namespace

std::string appRoot() {
    if (!g_appRoot.empty()) {
        return g_appRoot;
    }

    // In order: an explicit override, the assets beside the .nro (so a user
    // who edited them wins), the installed SD location, and finally whatever
    // the SD scan turns up. Rejected candidates are logged so a wrong guess is
    // visible in the boot log rather than showing up as a missing file later.
    std::vector<std::string> candidates;
    const char* configured = std::getenv("WOWEE_RESOURCE_ROOT");
    if (configured && *configured) {
        candidates.push_back(withoutTrailingSlash(configured));
    }
    if (!g_launchPath.empty()) {
        const std::string dir = parentDirectory(g_launchPath);
        if (!dir.empty()) {
            candidates.push_back(dir + "/data");
            candidates.push_back(dir);
        }
        // Some launchers pass only the file name, with no directory at all.
        const std::string stem = stemOf(g_launchPath);
        if (!stem.empty()) {
            candidates.push_back("sdmc:/switch/" + stem + "/data");
        }
    }
    if (g_romfsMounted) {
        candidates.emplace_back(kEmbeddedRoot);
    }
    candidates.emplace_back(kAppRoot);

    for (const std::string& candidate : candidates) {
        if (holdsAssets(candidate)) {
            g_appRoot = candidate;
            break;
        }
    }
    if (g_appRoot.empty()) {
        g_appRoot = findAssetsBesideLaunchDirs();
    }
    if (g_appRoot.empty()) {
        // Nothing verified. Keep the override (or the default) so the caller's
        // own check reports the exact path it failed on rather than a guess.
        g_appRoot = withoutTrailingSlash(candidates.front());
    }

    if (g_appRootReported != g_appRoot) {
        g_appRootReported = g_appRoot;
        klog("resource root: %s%s", g_appRoot.c_str(),
             holdsAssets(g_appRoot) ? "" : " (no assets/shaders here)");
        for (const std::string& candidate : candidates) {
            // Compared by value: g_appRoot holds a copy, so comparing
            // addresses would report the chosen root as unused.
            if (candidate != g_appRoot) klog("  not used: %s", candidate.c_str());
        }
    }
    return g_appRoot;
}

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
