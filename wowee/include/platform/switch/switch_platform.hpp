#pragma once
// Nintendo Switch (libnx) platform layer for the WoWee client.
//
// Contract between the platform pieces (src/platform/switch/*.cpp) and the
// upstream code that calls them from #ifdef WOWEE_SWITCH branches. Everything
// here is main-thread only unless stated otherwise.
//
//   system_switch.cpp         libnx services, paths, logging, DNS, lifecycle
//   input_switch.cpp          libnx HID -> core::Input (keyboard/mouse emulation)
//   audio_backend_switch.cpp  miniaudio custom backend on audout (see its header)

#include <cstddef>
#include <cstdint>
#include <string>
#include <functional>

#include "platform/switch/boot_verdict.hpp"

struct ImGuiContext;

namespace wowee {
namespace platform {
namespace switchport {

// ---- system_switch.cpp -------------------------------------------------------

/// Bring the title up: mount sdmc:/, initialize the applet and socket
/// services, set WOW_DATA_PATH/HOME/TMPDIR, create the writable tree and arm
/// the Vulkan loader shim. Call first. Does NOT hide the splash screen - see
/// hideSplashScreen() below.
bool initSystem();
/// Undo initSystem (socketExit, unmounts) and write the closing breadcrumb.
void shutdownSystem();

/// The title has presented its first frame (or opened a system error screen).
/// There is no separate splash service on the console: the loader's own
/// splash is dismissed when the first frame reaches the screen, so this is
/// only the port's bookkeeping point.
void hideSplashScreen();

/// Main-thread startup checkpoints, written without a userspace buffer to
/// logs/boot.log.
void reportBootStage(const char* stage);

/// The first-boot self-test line: every part that can be broken on its own, one
/// line, in logs/boot.log beside the breadcrumbs. Read the parts off the state
/// the startup path already keeps (see the getters below) rather than probing
/// again - the verdict is a summary of the boot, not a second opinion on it.
void reportBootVerdict(const BootChecks& checks);

/// What the platform already knows, for the self-test line above. Each is the
/// state the corresponding startup step left behind, so answering costs
/// nothing and cannot disagree with the breadcrumbs.
bool firstFramePresented();    ///< a frame reached the screen
bool socketsReady();          ///< socketInitializeDefault succeeded
bool padsReady();             ///< the pad layer opened HID
bool resourceAssetsPresent(); ///< the resource root carries the compiled shaders
// Main-thread scope: extend backend breadcrumbs through the first world frames.
void setFrameTraceEnabled(bool enabled);
bool frameTraceEnabled();
/// Async-signal-safe: append the fatal signal to the already-open boot log.
/// Does not call the core logger, allocate, acquire locks or format strings.
void reportCrashSignal(int signal);
/// Whether the crash marker is armed. Horizon has no per-thread signal-stack
/// service and no sigaction ABI worth bending to: a false answer tells main()
/// to install its own std::signal handlers (the fallback it already has), and
/// the fatal service is what raises the error screen after an abnormal exit.
bool installCrashReporter();
/// Give the calling thread a named alternate signal stack, when the platform
/// has one. On Switch this is a no-op (see installCrashReporter).
void registerCrashReportingThread(const char* name);
/// The stack size a thread created with no attributes gets from newlib.
size_t defaultThreadStackBytes();
/// Show a bounded system error dialog on initialization failure (libnx fatal).
/// Does not return. Independent of the game renderer; the full diagnosis
/// remains in the log files.
void showStartupError(const char* message);

/// Root the user fills with their own game client: sdmc:/wowps
/// (MPQs under sdmc:/wowps/Data). Also the default WOW_DATA_PATH.
std::string dataRoot();
/// Writable directory for settings, logs, caches and saved variables:
/// sdmc:/wowps/wowps (created by initSystem).
std::string writableRoot();
/// Directory the bundled assets were staged into: the data/ directory beside
/// the .nro. Discovered from the launch path (argv[0]); WOWEE_RESOURCE_ROOT
/// overrides it. Falls back to sdmc:/switch/wowee/data.
std::string appRoot();

/// Record argv[0] so appRoot() can look for the data directory beside the
/// .nro. Call before anything resolves an asset. Homebrew launchers pass the
/// full path; some pass a bare filename, which is handled as well.
void setLaunchPath(const char* argv0);

/// Resolve a host name through libnx's bsd service (getaddrinfo). Returns the
/// IPv4 address in network byte order, or 0.
uint32_t resolveIPv4(const std::string& host);

/// Per-frame lifecycle check (appletMainLoop) so an OS exit request is noticed
/// and boot-staged. Never blocks.
void pumpSystemEvents();

// ---- input_switch.cpp --------------------------------------------------------

/// Open the pad for the initial user.
bool initInput();
void shutdownInput();

/// Read the pad once per frame and:
///  - drive core::Input through its virtual-key API (left stick -> WASD,
///    L3 -> autorun, R3 -> mouse-look toggle, triggers/shoulders -> action
///    bar rows, D-pad -> targeting/UI focus, Plus -> Escape, Minus -> world map)
///  - move the emulated mouse cursor (right stick or the touchscreen) and report
///    mouse buttons (X = left click, Circle = right click)
///  - feed ImGui (mouse position/buttons/wheel, nav gamepad keys, text input
///    from the on-screen keyboard)
void pumpInput();

/// Emulated mouse state for core::Input (client pixels).
struct MouseState {
    float x = 0, y = 0;
    float dx = 0, dy = 0;
    bool left = false, right = false, middle = false;
    float wheel = 0;
    bool relativeMode = false;   // right-stick mouse-look active
};
const MouseState& mouseState();
/// Cursor mode is explicit on console; camera drag need not enable SDL relative mode.
bool inputCursorVisible();
/// True only while the input backend owns a camera drag, including stick look.
bool inputCameraLooking();

/// Whether the given SDL scancode is currently held through the pad mapping.
/// (Input::update merges this with its own state on console.)
bool isVirtualKeyHeld(int sdlScancode);

/// Open the in-game on-screen keyboard for a text field.
/// The callback receives the final UTF-8 text on the main thread; empty
/// string + accepted=false when cancelled.
void showKeyboard(const std::string& title, const std::string& initialText,
                  bool password, std::function<void(const std::string&, bool accepted)> done);
bool keyboardOpen();

} // namespace switchport
} // namespace platform
} // namespace wowee
