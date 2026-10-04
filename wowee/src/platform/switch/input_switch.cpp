// input_switch.cpp - DualShock 4 -> keyboard/mouse emulation for WoWee on switch.
//
// The input_switch.cpp half of include/platform/switch/switch_platform.hpp, plus the
// private surface in include/platform/switch/input_switch.hpp and the SDL functions
// declared by include/platform/switch/sdl_scancode_compat.h.
//
// The client's shared code reads a keyboard (core::Input::isKeyPressed with
// SDL scancodes), a mouse (cursor, buttons, wheel, relative mode for the
// camera) and an SDL event queue (key, text, mouse and wheel events, drained
// by Application::run). None of that exists on the console, so every frame
// pumpInput reads the pad and produces all three:
//
//   - the pad mapping (kBindings, one table, kept in the header so it can be
//     tuned in one place and asserted off-console) turns buttons into held
//     scancodes, the left stick into W/S/Q/E with hysteresis, and edges into
//     SDL_KEYDOWN/SDL_KEYUP events;
//   - Cross and Circle are the mouse buttons, the right stick is mouse-look
//     (a right-button drag with relative motion, which is what the camera
//     controller already understands) or, off the world and with R3, cursor
//     movement; the touchpad is an absolute cursor; the D-pad is the wheel;
//   - the in-game on-screen keyboard answers text fields; its
//     result is delivered as SDL_TEXTINPUT events like typed text.
//
// Main-thread only. The keyboard modal is drawn at EndFrame; src/platform/switch/
// imgui_impl_switch.cpp feeds ImGui from the same events and state.

#include "platform/switch/switch_platform.hpp"
#include "platform/switch/input_switch.hpp"
#include "platform/switch/sdl_scancode_compat.h"
#include "core/logger.hpp"

#include "platform/switch/switch_pad_buttons.h"
#include "ui/controller_text_keyboard.hpp"
#include <imgui.h>
#include <switch.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <string>
#include <vector>

namespace wowee {
namespace platform {
namespace switchport {

namespace {

// ---- tunables --------------------------------------------------------------------

// Radial dead zone of both sticks, after which the deflection is rescaled to
// 0..1 so the first usable value is small rather than a jump.
constexpr float kStickDeadzone = 0.20f;

// Left stick -> movement keys. Sideways asks for more of the stick than
// forward, and each direction lets go later than it took hold (the same
// scheme as the Android on-screen stick, ui/touch_controls.cpp).
constexpr float kWalkDeadzone = 0.30f;
constexpr float kStrafeDeadzone = 0.45f;
constexpr float kReleaseHysteresis = 0.10f;

// Right stick -> mouse-look. Engages past the dead zone, lets go a little
// inside it. Pixels per second at full deflection, with a response curve so
// small deflections are fine adjustments.
constexpr float kLookEngage = 0.25f;
constexpr float kLookRelease = 0.15f;
constexpr float kLookPixelsPerSecond = 1400.0f;
constexpr float kLookCurve = 1.6f;

// Right stick -> cursor, when it is not looking.
constexpr float kCursorPixelsPerSecond = 1100.0f;
constexpr float kCursorCurve = 1.5f;

// D-pad up/down -> wheel: one notch on the press, then repeats while held.
constexpr uint32_t kWheelFirstRepeatMs = 350;
constexpr uint32_t kWheelRepeatMs = 140;

// Two presses of the same mouse button within this count as a double click
// (SDL's own interval), which is what stops autorun.
constexpr uint32_t kDoubleClickMs = 500;

// After the system keyboard closes, the press that closed it is still on the
// pad. Ignore the buttons for this long so it does not become a click.
constexpr uint32_t kDialogGraceMs = 200;

// How many samples of the pad's own history to read each frame. libnx keeps a
// 17-entry LIFO per Npad and hands back as many as are asked for, newest first
// (hid.c:_hidGetStates, called through _hidGetNpadStates), so the whole window
// is cheap: 17 x sizeof(HidNpadCommonState) per source, off the shared memory,
// with no waiting and nothing to stall for.
constexpr size_t kNpadHistory = 17;



// The pad mapping - Layer, Action, PadBinding, kBindings and padLayerFor - is
// in the header. Everything else in this file needs the OpenOrbis SDK, so a
// table kept here could only ever be checked on the console, which is the one
// place a wrong slot is found by a player rather than by a test.

// Left stick -> keys. Q and E rather than A and D for sideways: with the
// right button up this client turns the character on A/D and strafes on Q/E,
// and a stick pushed sideways should move the feet, not swing the view (the
// view is the other stick's job).
constexpr SDL_Scancode kStickForward = SDL_SCANCODE_W;
constexpr SDL_Scancode kStickBack    = SDL_SCANCODE_S;
constexpr SDL_Scancode kStickLeft    = SDL_SCANCODE_Q;
constexpr SDL_Scancode kStickRight   = SDL_SCANCODE_E;

// ---- state -----------------------------------------------------------------------

using Clock = std::chrono::steady_clock;

bool s_initialised = false;
bool s_padConnected = false;      // a handle was opened

PadSnapshot s_padState;
uint32_t s_prevButtons = 0;
Clock::time_point s_lastPump{};
bool s_pumpedOnce = false;

// The pad's own LIFO, and how far into it this pump has read. Reading the
// history does not drain it - _hidGetStates only loads header->count and
// header->tail - so the same tap sits in the window for many frames after it
// happened. Each sample carries the sampling number the pad gave it, and that
// is what tells an entry this pump has not seen from one it has already
// reported: without it every edge would repeat for as long as its sample
// survived in the ring, and the invariant consumers rely on (a press once,
// never a repeat - include/ui/local_pad_focus.hpp) would be gone.
struct NpadHistory {
    uint64_t lastSampling = 0;
    bool primed = false;
};
NpadHistory s_handheldHistory;
NpadHistory s_no1History;
// Static rather than per-frame stack: they are two reads deep and this runs
// every frame for the life of the process.
HidNpadCommonState s_handheldStates[kNpadHistory];
HidNpadCommonState s_no1States[kNpadHistory];

// What the interface says.
int s_displayW = 1920;
int s_displayH = 1080;
bool s_inWorld = false;
bool s_actionBarNavigation = false;
bool s_textFocus = false;
bool s_uiFocus = false;
unsigned s_menuOwners = 0;
uint32_t s_menuSuppressedButtons = 0;
bool s_cursorMode = false;        // R3: the right stick moves the cursor even in the world
bool s_keyboardRequest = false;

// The emulated keyboard: what the pad holds, indexed by scancode. Also what
// SDL_GetKeyboardState returns.
std::array<Uint8, SDL_NUM_SCANCODES> s_held{};
bool s_walkForward = false, s_walkBack = false, s_strafeLeft = false, s_strafeRight = false;

// The emulated mouse.
MouseState s_mouse;
float s_cursorX = 960.0f;
float s_cursorY = 540.0f;
float s_lookRemX = 0.0f;          // sub-pixel remainders of the relative motion
float s_lookRemY = 0.0f;
bool s_lookEngaged = false;
bool s_leftHeld = false;          // as reported last frame
bool s_rightHeld = false;
uint32_t s_lastLeftPressMs = 0;
uint32_t s_lastRightPressMs = 0;
bool s_relativeMode = false;
float s_relativeOriginX = 0.0f;
float s_relativeOriginY = 0.0f;
bool s_restoreCursorPending = false;
bool s_touchWasDown = false;
int s_wheelDir = 0;               // +1 up, -1 down, 0 idle
uint32_t s_wheelNextMs = 0;
float s_wheelThisFrame = 0.0f;
uint32_t s_ignoreButtonsUntilMs = 0;

// The event queue behind SDL_PollEvent.
std::deque<SDL_Event> s_events;

// Process-local clipboard.
std::string s_clipboard;

// The on-screen keyboard.
struct KeyboardDialog {
    bool open = false, justOpened = false;
    uint32_t rawPressed = 0, rawPrevious = 0;
    KeyboardOptions options;
    ui::ControllerTextKeyboard model;
    std::function<void(const std::string&, bool)> done;
};
KeyboardDialog s_keyboard;
bool s_applicationKeyboardOpen = false;

TextFieldHint s_fieldHint;
bool s_haveFieldHint = false;

// ---- small helpers -------------------------------------------------------------

uint32_t nowMs() {
    static const Clock::time_point start = Clock::now();
    return static_cast<uint32_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count());
}

float clampf(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }

// Switch stick (centered at 0, roughly +/-32767) -> -1..1 with the radial
// dead zone removed and the rest rescaled so the smallest deflection past it
// is small.
void stickToFloatRaw(s32 rawX, s32 rawY, float& x, float& y) {
    const float fx = static_cast<float>(rawX) / 32767.0f;
    const float fy = static_cast<float>(rawY) / 32767.0f;
    const float mag = std::sqrt(fx * fx + fy * fy);
    if (mag < kStickDeadzone || mag <= 0.0f) {
        x = y = 0.0f;
        return;
    }
    const float scaled = std::min(1.0f, (mag - kStickDeadzone) / (1.0f - kStickDeadzone));
    x = clampf(fx / mag * scaled, -1.0f, 1.0f);
    y = clampf(fy / mag * scaled, -1.0f, 1.0f);
}


// The hysteresis of the movement keys: takes hold past the threshold, lets
// go a little inside it.
bool heldWithHysteresis(float axis, float threshold, bool wasOn) {
    const float release = std::max(threshold - kReleaseHysteresis, 0.05f);
    return axis > (wasOn ? release : threshold);
}

SDL_Event makeEvent(Uint32 type) {
    SDL_Event e;
    std::memset(&e, 0, sizeof(e));
    e.type = type;
    e.common.timestamp = nowMs();
    return e;
}

Uint32 mouseButtonMask() {
    Uint32 mask = 0;
    if (s_mouse.left) mask |= SDL_BUTTON_LMASK;
    if (s_mouse.right) mask |= SDL_BUTTON_RMASK;
    if (s_mouse.middle) mask |= SDL_BUTTON_MMASK;
    return mask;
}

Uint16 modState() {
    Uint16 mod = KMOD_NONE;
    if (s_held[SDL_SCANCODE_LSHIFT]) mod |= KMOD_LSHIFT;
    if (s_held[SDL_SCANCODE_RSHIFT]) mod |= KMOD_RSHIFT;
    if (s_held[SDL_SCANCODE_LCTRL]) mod |= KMOD_LCTRL;
    if (s_held[SDL_SCANCODE_RCTRL]) mod |= KMOD_RCTRL;
    if (s_held[SDL_SCANCODE_LALT]) mod |= KMOD_LALT;
    if (s_held[SDL_SCANCODE_RALT]) mod |= KMOD_RALT;
    if (s_held[SDL_SCANCODE_LGUI]) mod |= KMOD_LGUI;
    if (s_held[SDL_SCANCODE_RGUI]) mod |= KMOD_RGUI;
    return mod;
}

// SDL's default (US) keymap: printable keys are their ASCII, the rest carry
// the scancode with the keycode bit.
SDL_Keycode keycodeFor(SDL_Scancode sc) {
    if (sc >= SDL_SCANCODE_A && sc <= SDL_SCANCODE_Z) return 'a' + (sc - SDL_SCANCODE_A);
    if (sc >= SDL_SCANCODE_1 && sc <= SDL_SCANCODE_9) return '1' + (sc - SDL_SCANCODE_1);
    switch (sc) {
        case SDL_SCANCODE_0: return '0';
        case SDL_SCANCODE_RETURN: return SDLK_RETURN;
        case SDL_SCANCODE_ESCAPE: return SDLK_ESCAPE;
        case SDL_SCANCODE_BACKSPACE: return SDLK_BACKSPACE;
        case SDL_SCANCODE_TAB: return SDLK_TAB;
        case SDL_SCANCODE_SPACE: return SDLK_SPACE;
        case SDL_SCANCODE_MINUS: return SDLK_MINUS;
        case SDL_SCANCODE_EQUALS: return SDLK_EQUALS;
        case SDL_SCANCODE_LEFTBRACKET: return SDLK_LEFTBRACKET;
        case SDL_SCANCODE_RIGHTBRACKET: return SDLK_RIGHTBRACKET;
        case SDL_SCANCODE_BACKSLASH: return SDLK_BACKSLASH;
        case SDL_SCANCODE_SEMICOLON: return SDLK_SEMICOLON;
        case SDL_SCANCODE_APOSTROPHE: return SDLK_QUOTE;
        case SDL_SCANCODE_GRAVE: return SDLK_BACKQUOTE;
        case SDL_SCANCODE_COMMA: return SDLK_COMMA;
        case SDL_SCANCODE_PERIOD: return SDLK_PERIOD;
        case SDL_SCANCODE_SLASH: return SDLK_SLASH;
        case SDL_SCANCODE_DELETE: return SDLK_DELETE;
        case SDL_SCANCODE_UNKNOWN: return SDLK_UNKNOWN;
        default: return SDL_SCANCODE_TO_KEYCODE(sc);
    }
}

void pushKey(SDL_Scancode sc, bool down) {
    SDL_Event e = makeEvent(down ? SDL_KEYDOWN : SDL_KEYUP);
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.repeat = 0;
    e.key.keysym.scancode = sc;
    e.key.keysym.sym = keycodeFor(sc);
    e.key.keysym.mod = modState();
    s_events.push_back(e);
}

void pushMouseMotion(int xrel, int yrel) {
    SDL_Event e = makeEvent(SDL_MOUSEMOTION);
    e.motion.state = mouseButtonMask();
    e.motion.x = static_cast<Sint32>(s_cursorX);
    e.motion.y = static_cast<Sint32>(s_cursorY);
    e.motion.xrel = xrel;
    e.motion.yrel = yrel;
    s_events.push_back(e);
}

void pushMouseButton(Uint8 button, bool down, Uint8 clicks) {
    SDL_Event e = makeEvent(down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP);
    e.button.button = button;
    e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.button.clicks = clicks;
    e.button.x = static_cast<Sint32>(s_cursorX);
    e.button.y = static_cast<Sint32>(s_cursorY);
    s_events.push_back(e);
}

void pushWheel(float notches) {
    SDL_Event e = makeEvent(SDL_MOUSEWHEEL);
    e.wheel.y = notches > 0.0f ? 1 : -1;
    e.wheel.preciseY = notches;
    e.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
    e.wheel.mouseX = static_cast<Sint32>(s_cursorX);
    e.wheel.mouseY = static_cast<Sint32>(s_cursorY);
    s_events.push_back(e);
    s_wheelThisFrame += notches;
}

// Move the cursor, keeping it on the display. Returns the whole pixels it
// moved by, carrying the fractions to the next call.
void moveCursor(float dx, float dy, int& xrel, int& yrel) {
    const float nx = clampf(s_cursorX + dx, 0.0f, static_cast<float>(std::max(s_displayW - 1, 0)));
    const float ny = clampf(s_cursorY + dy, 0.0f, static_cast<float>(std::max(s_displayH - 1, 0)));
    xrel = static_cast<int>(std::lround(nx) - std::lround(s_cursorX));
    yrel = static_cast<int>(std::lround(ny) - std::lround(s_cursorY));
    s_cursorX = nx;
    s_cursorY = ny;
}

// ---- UTF-8 <-> UTF-16 (the IME dialog speaks UTF-16) ---------------------------

std::u16string toUtf16(const std::string& utf8) {
    std::u16string out;
    size_t i = 0;
    while (i < utf8.size()) {
        const unsigned char c = static_cast<unsigned char>(utf8[i]);
        uint32_t cp = 0;
        size_t len = 1;
        if (c < 0x80) { cp = c; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; len = 2; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; len = 3; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; len = 4; }
        else { ++i; continue; }
        if (i + len > utf8.size()) break;
        for (size_t k = 1; k < len; ++k) {
            cp = (cp << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        }
        i += len;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
        } else {
            out.push_back(static_cast<char16_t>(cp));
        }
    }
    return out;
}

std::string toUtf8(const char16_t* s, size_t maxLen) {
    std::string out;
    for (size_t i = 0; i < maxLen && s[i] != 0; ++i) {
        uint32_t cp = s[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < maxLen && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
            ++i;
        }
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

// ---- the on-screen keyboard ------------------------------------------------------

void finishKeyboard(bool accepted, const std::string& text) {
    s_keyboard.open = false;
    auto done = std::move(s_keyboard.done);
    s_keyboard.done = nullptr;
    // The press that closed the dialog is still on the pad.
    s_ignoreButtonsUntilMs = nowMs() + kDialogGraceMs;
    if (done) done(accepted ? text : std::string(), accepted);
}

// ---- pumpInput pieces ------------------------------------------------------------

Layer activeLayer(uint32_t buttons) {
    return padLayerFor(buttons, s_textFocus, s_inWorld, s_actionBarNavigation);
}

// Whether libnx's per-frame readers may be called at all. hidGetNpadStates*
// reaches _hidGetNpadInternalState and hidGetTouchScreenStates reaches the
// shared memory directly, and both abort the process rather than return when
// that memory is not mapped (references/libnx/nx/source/services/hid.c:86-89
// and :237-241, LibnxError_NotInitialized). Application::run pumps every frame
// whether or not initInput succeeded - the window logs "Switch pads not
// initialised; the client has no input" and carries on (core/window.cpp) - so
// every HID read below is behind this one check. Without it a failed
// initialisation was a fatal-error screen on frame 1 instead of a client that
// runs with no input; with it nothing is held, so every key the pad had down is
// released on this frame and the client sits there.
bool hidReady() {
    // s_initialised is the module's own state (hidExit took the memory away and
    // the mapping check is what libnx itself asks before using it).
    return s_initialised && hidGetSharedmemAddr() != nullptr;
}

// Fold one Npad LIFO window into the buttons it says are held now, OR-ing into
// `pressed` every press that happened between two of its samples and that this
// pump has not reported yet. states[] is newest first and the walk below runs
// oldest to newest, which is the order the pad pressed them in, so the result
// is one press per button however many samples the tap took.
//
// A button that went down and up inside one window is the case this exists
// for: the held set alone cannot show it, so readPad gives it a frame of held
// state (see there) and the release follows from the ordinary diff.
uint32_t foldNpadWindow(const HidNpadCommonState* states, size_t total,
                        NpadHistory& history, uint32_t& pressed) {
    if (total == 0) return 0;
    const uint32_t newest = static_cast<uint32_t>(states[0].buttons);
    if (!history.primed) {
        // The window holds samples from before this client ever pumped, which
        // is the wrong window to diff against: starting it at the newest entry
        // means the chain begins where the pad is now, and whatever is down
        // this frame is reported once by the ordinary held-set edge rather
        // than once per historical press.
        history.primed = true;
        history.lastSampling = states[0].sampling_number;
        return newest;
    }
    uint32_t older = static_cast<uint32_t>(states[total - 1].buttons);
    uint64_t reported = history.lastSampling;
    for (size_t i = total - 1; i-- > 0;) {
        const uint32_t newer = static_cast<uint32_t>(states[i].buttons);
        if (states[i].sampling_number > reported) {
            pressed |= newer & ~older;
            reported = states[i].sampling_number;
        }
        older = newer;
    }
    history.lastSampling = reported;
    return newest;
}

void readPad(float dt) {
    (void)dt;
    PadSnapshot st;
    st.connected = false;
    // Every button that went down since the last pump, from either source's
    // history. A tap that has already finished leaves no held state behind, and
    // the rows that act on it - the keys and the mouse buttons ask "is it held",
    // and the keyboard button, R3 and the world map the bridge reads off
    // padSnapshot().pressed ask "was it pressed" - are all empty-handed without
    // this. Nothing here without HID: it stays 0 and the frame is an empty,
    // disconnected pad.
    uint32_t pressed = 0;
    // Nothing below may run without HID (hidReady).
    if (hidReady()) {
        // The console reports the built-in Joy-Cons as one Npad (Handheld) and
        // any docked/attached controller as another (No1). Both are read and
        // merged - picking one would make the held set flicker whenever one of
        // them reports activity. Each is read with the whole of its history,
        // not one sample: see kNpadHistory.
        const size_t handheldSamples =
            hidGetNpadStatesHandheld(HidNpadIdType_Handheld, s_handheldStates, kNpadHistory);
        const size_t fullKeySamples =
            hidGetNpadStatesFullKey(HidNpadIdType_No1, s_no1States, kNpadHistory);
        const HidNpadCommonState& handheld = s_handheldStates[0];
        const HidNpadCommonState& fullkey = s_no1States[0];

        uint64_t buttons = 0;
        float lx = 0.0f, ly = 0.0f, rx = 0.0f, ry = 0.0f;
        bool connected = false;
        // Take each stick from whichever source deflects it most: two sticks
        // can be live at once (handheld Joy-Cons plus a Pro controller) and the
        // stronger deflection is the one the player means.
        auto takeStick = [](const HidAnalogStickState& state, float& x, float& y) {
            stickToFloatRaw(state.x, state.y, x, y);
        };
        if (handheldSamples > 0 && (handheld.attributes & HidNpadAttribute_IsConnected) != 0) {
            connected = true;
            buttons |= foldNpadWindow(s_handheldStates, handheldSamples, s_handheldHistory, pressed);
            takeStick(handheld.analog_stick_l, lx, ly);
            takeStick(handheld.analog_stick_r, rx, ry);
        }
        if (fullKeySamples > 0 && (fullkey.attributes & HidNpadAttribute_IsConnected) != 0) {
            connected = true;
            buttons |= foldNpadWindow(s_no1States, fullKeySamples, s_no1History, pressed);
            float flx = 0.0f, fly = 0.0f, frx = 0.0f, fry = 0.0f;
            takeStick(fullkey.analog_stick_l, flx, fly);
            takeStick(fullkey.analog_stick_r, frx, fry);
            if (std::fabs(flx) + std::fabs(fly) > std::fabs(lx) + std::fabs(ly)) {
                lx = flx;
                ly = fly;
            }
            if (std::fabs(frx) + std::fabs(fry) > std::fabs(rx) + std::fabs(ry)) {
                rx = frx;
                ry = fry;
            }
        }
        if (connected) {
            st.connected = true;
            st.buttons = static_cast<uint32_t>(buttons);
            st.lx = lx;
            st.ly = ly;
            st.rx = rx;
            st.ry = ry;
            // ZL/ZR are reported as buttons, not analog triggers, so these are
            // 0 or 1. The mapping only asks "is it held".
            st.l2 = (st.buttons & ORBIS_PAD_BUTTON_L2) ? 1.0f : 0.0f;
            st.r2 = (st.buttons & ORBIS_PAD_BUTTON_R2) ? 1.0f : 0.0f;
        }

        // Touchscreen: the first finger is the cursor, absolutely. The touch
        // surface is 1280x720 for the default NWindow.
        HidTouchScreenState ts{};
        if (hidGetTouchScreenStates(&ts, 1) > 0 && ts.count > 0) {
            const HidTouchState& t = ts.touches[0];
            const float nx = static_cast<float>(t.x) / 1280.0f;
            const float ny = static_cast<float>(t.y) / 720.0f;
            const float px = clampf(nx, 0.0f, 1.0f) * static_cast<float>(std::max(s_displayW - 1, 0));
            const float py = clampf(ny, 0.0f, 1.0f) * static_cast<float>(std::max(s_displayH - 1, 0));
            if (!s_lookEngaged) {
                int xrel = 0, yrel = 0;
                moveCursor(px - s_cursorX, py - s_cursorY, xrel, yrel);
                if (xrel != 0 || yrel != 0 || !s_touchWasDown) pushMouseMotion(xrel, yrel);
            }
            s_touchWasDown = true;
        } else {
            s_touchWasDown = false;
        }
    }

    if (s_keyboard.open) {
        // The modal owns the pad while it is up, so it reads the raw pad and not
        // the masked snapshot below - and it reads the taps as well, for the
        // same reason everything else in this layer does.
        s_keyboard.rawPressed = (st.buttons | pressed) & ~s_keyboard.rawPrevious;
        s_keyboard.rawPrevious = st.buttons;
    }
    // The in-game keyboard has the pad while it is up, and the press that
    // closed it lingers a little after.
    if (s_keyboard.open || nowMs() < s_ignoreButtonsUntilMs) {
        st.buttons = 0;
        st.lx = st.ly = st.rx = st.ry = 0.0f;
        st.l2 = st.r2 = 0.0f;
    } else if (pressed) {
        // A press that began and ended between two pumps is given one frame of
        // held state, so the rows that ask "is it held" act on it and the whole
        // tap is over by the next frame: the release below is the same diff
        // against the same s_prevButtons. Without this a tap shorter than a
        // frame was not a click, not a key and not a spell - one sample with
        // the button up, which is indistinguishable from never touching it.
        st.buttons |= pressed & ~st.buttons;
    }

    // The press edge is the union of what the held set changed by and what the
    // history saw since the last pump: the two differ only for a button that
    // was already down when the window opened and was pressed again inside it.
    st.pressed = (st.buttons & ~s_prevButtons) | pressed;
    st.released = s_prevButtons & ~st.buttons;
    s_prevButtons = st.buttons;
    s_padState = st;
}

// The left stick's four keys, with hysteresis. Off with text focus: the game
// already ignores movement then, but the keys would still reach the box.
void applyLeftStick(std::array<bool, SDL_NUM_SCANCODES>& want) {
    const PadSnapshot& st = s_padState;
    if (s_textFocus || !st.connected) {
        s_walkForward = s_walkBack = s_strafeLeft = s_strafeRight = false;
        return;
    }
    s_walkForward = heldWithHysteresis(-st.ly, kWalkDeadzone, s_walkForward);
    s_walkBack    = heldWithHysteresis( st.ly, kWalkDeadzone, s_walkBack);
    s_strafeLeft  = heldWithHysteresis(-st.lx, kStrafeDeadzone, s_strafeLeft);
    s_strafeRight = heldWithHysteresis( st.lx, kStrafeDeadzone, s_strafeRight);
    want[kStickForward] = want[kStickForward] || s_walkForward;
    want[kStickBack]    = want[kStickBack]    || s_walkBack;
    want[kStickLeft]    = want[kStickLeft]    || s_strafeLeft;
    want[kStickRight]   = want[kStickRight]   || s_strafeRight;
}

// The right stick: mouse-look in the world (a right-button drag the camera
// controller already understands), the cursor everywhere else.
void applyRightStick(float dt, bool& rightButton) {
    const PadSnapshot& st = s_padState;
    const float mag = std::sqrt(st.rx * st.rx + st.ry * st.ry);
    const bool lookAllowed = s_inWorld && !s_menuOwners && !s_cursorMode && !s_textFocus && st.connected;

    if (!lookAllowed) {
        s_lookEngaged = false;
    } else if (!s_lookEngaged && mag > kLookEngage) {
        s_lookEngaged = true;
        s_lookRemX = s_lookRemY = 0.0f;
        // No motion on the frame the look takes hold: the button-down that
        // starts the drag is queued after the motion (applyMouseButtons runs
        // last), and the camera ignores motion until it has seen the button.
        // Moving now would also shift the spot the cursor is put back on.
        rightButton = true;
        return;
    } else if (s_lookEngaged && mag < kLookRelease) {
        s_lookEngaged = false;
    }

    if (mag <= 0.0f) return;
    // Where the stick looks, a deflection short of engaging is nothing: it
    // must not creep the cursor across the world before the look begins.
    if (lookAllowed && !s_lookEngaged) return;
    const float curveMag = std::pow(mag, s_lookEngaged ? kLookCurve : kCursorCurve);
    const float speed = s_lookEngaged ? kLookPixelsPerSecond : kCursorPixelsPerSecond;
    const float dx = st.rx / mag * curveMag * speed * dt + s_lookRemX;
    const float dy = st.ry / mag * curveMag * speed * dt + s_lookRemY;

    if (s_lookEngaged) {
        rightButton = true;
        // Relative motion is what turns the camera; the cursor position is
        // moved too, clamped, so the click-versus-drag test in GameScreen
        // sees a drag and does not interact where the look began.
        const int xrel = static_cast<int>(dx);
        const int yrel = static_cast<int>(dy);
        s_lookRemX = dx - static_cast<float>(xrel);
        s_lookRemY = dy - static_cast<float>(yrel);
        s_cursorX = clampf(s_cursorX + static_cast<float>(xrel), 0.0f, static_cast<float>(std::max(s_displayW - 1, 0)));
        s_cursorY = clampf(s_cursorY + static_cast<float>(yrel), 0.0f, static_cast<float>(std::max(s_displayH - 1, 0)));
        if (xrel != 0 || yrel != 0) pushMouseMotion(xrel, yrel);
    } else {
        int xrel = 0, yrel = 0;
        moveCursor(dx, dy, xrel, yrel);
        s_lookRemX = s_lookRemY = 0.0f;
        if (xrel != 0 || yrel != 0) pushMouseMotion(xrel, yrel);
    }
}

void applyWheel(int dir) {
    const uint32_t now = nowMs();
    if (dir == 0) {
        s_wheelDir = 0;
        return;
    }
    if (dir != s_wheelDir) {
        s_wheelDir = dir;
        s_wheelNextMs = now + kWheelFirstRepeatMs;
        pushWheel(static_cast<float>(dir));
        return;
    }
    if (now >= s_wheelNextMs) {
        s_wheelNextMs = now + kWheelRepeatMs;
        pushWheel(static_cast<float>(dir));
    }
}

void applyMouseButtons(bool left, bool right) {
    const uint32_t now = nowMs();
    if (left != s_leftHeld) {
        Uint8 clicks = 1;
        if (left) {
            clicks = (now - s_lastLeftPressMs < kDoubleClickMs) ? 2 : 1;
            s_lastLeftPressMs = now;
        }
        s_leftHeld = left;
        s_mouse.left = left;
        pushMouseButton(SDL_BUTTON_LEFT, left, clicks);
    }
    if (right != s_rightHeld) {
        Uint8 clicks = 1;
        if (right) {
            clicks = (now - s_lastRightPressMs < kDoubleClickMs) ? 2 : 1;
            s_lastRightPressMs = now;
        }
        s_rightHeld = right;
        s_mouse.right = right;
        pushMouseButton(SDL_BUTTON_RIGHT, right, clicks);
    }
}

void applyKeys(const std::array<bool, SDL_NUM_SCANCODES>& want) {
    for (int sc = 0; sc < SDL_NUM_SCANCODES; ++sc) {
        const bool held = s_held[static_cast<size_t>(sc)] != 0;
        if (want[static_cast<size_t>(sc)] == held) continue;
        s_held[static_cast<size_t>(sc)] = want[static_cast<size_t>(sc)] ? 1 : 0;
        pushKey(static_cast<SDL_Scancode>(sc), want[static_cast<size_t>(sc)]);
    }
}

}  // namespace

// ---- contract: init / shutdown --------------------------------------------------------

bool initInput() {
    if (s_initialised) return s_padConnected;
    s_initialised = true;
    s_cursorX = static_cast<float>(s_displayW) * 0.5f;
    s_cursorY = static_cast<float>(s_displayH) * 0.5f;

    // Both Npad sources plus the touchscreen: the built-in Joy-Cons, and
    // whatever the player docked or attached.
    if (R_FAILED(hidInitialize())) {
        LOG_ERROR("hidInitialize failed");
        s_initialised = false;
        return false;
    }
    hidInitializeNpad();
    hidInitializeTouchScreen();
    static const HidNpadIdType kIds[] = {HidNpadIdType_No1, HidNpadIdType_Handheld};
    const Result idsResult = hidSetSupportedNpadIdType(kIds, 2);
    const Result stylesResult = hidSetSupportedNpadStyleSet(HidNpadStyleSet_NpadFullCtrl);
    if (R_FAILED(idsResult) || R_FAILED(stylesResult)) {
        LOG_ERROR("could not declare the supported Npad ids/styles");
        s_initialised = false;
        return false;
    }
    s_padConnected = true;
    LOG_INFO("Switch HID ready (No1 + handheld Joy-Cons, full key style, touchscreen)");
    return true;
}

void shutdownInput() {
    if (!s_initialised) return;
    if (s_keyboard.open) {
        finishKeyboard(false, std::string());
    }
    hidExit();
    s_padConnected = false;
    s_padState = PadSnapshot{};
    s_held.fill(0);
    s_events.clear();
    s_initialised = false;
}

// ---- contract: the frame ----------------------------------------------------------------

void pumpInput() {
    const Clock::time_point now = Clock::now();
    float dt = 1.0f / 60.0f;
    if (s_pumpedOnce) {
        dt = std::chrono::duration<float>(now - s_lastPump).count();
        dt = clampf(dt, 0.0f, 0.1f);
    }
    s_lastPump = now;
    s_pumpedOnce = true;

    // Leaving relative mode puts the cursor back where it was. Deferred to
    // here, one frame later, so the frame that saw the button go up still
    // sees the distance the drag covered.
    if (s_restoreCursorPending) {
        s_restoreCursorPending = false;
        s_cursorX = s_relativeOriginX;
        s_cursorY = s_relativeOriginY;
    }

    const float prevX = s_cursorX;
    const float prevY = s_cursorY;
    s_wheelThisFrame = 0.0f;

    readPad(dt);

    const PadSnapshot& st = s_padState;
    s_menuSuppressedButtons &= st.buttons;
    if (s_menuOwners) s_menuSuppressedButtons |= st.buttons;
    const uint32_t gameplayButtons = st.buttons & ~s_menuSuppressedButtons;
    const Layer layer = activeLayer(gameplayButtons);

    std::array<bool, SDL_NUM_SCANCODES> want{};
    bool left = false;
    bool right = false;
    int wheel = 0;
    for (const PadBinding& b : kBindings) {
        if (s_applicationKeyboardOpen || s_menuOwners || b.layer != layer) continue;
        if(s_inWorld && s_actionBarNavigation && !s_textFocus &&
           (b.button==ORBIS_PAD_BUTTON_SQUARE || b.button==ORBIS_PAD_BUTTON_TRIANGLE))continue;
        const bool held = (gameplayButtons & b.button) != 0;
        const bool pressed = (st.pressed & gameplayButtons & b.button) != 0;
        switch (b.action) {
            case Action::Key:
                if (held) want[static_cast<size_t>(b.key)] = true;
                break;
            case Action::MouseLeft:
                // Base Cross jumps in camera mode. Menus own Cross separately;
                // the explicit R3 cursor mode retains left click.
                if (b.layer == Layer::Base && s_inWorld && !s_cursorMode && !s_textFocus)
                    want[SDL_SCANCODE_SPACE] = want[SDL_SCANCODE_SPACE] || held;
                else left = left || held;
                break;
            case Action::MouseRight:
                right = right || held;
                break;
            case Action::WheelUp:
                if (held && !s_uiFocus) wheel = 1;
                break;
            case Action::WheelDown:
                if (held && !s_uiFocus) wheel = -1;
                break;
            case Action::Keyboard:
                if (pressed) s_keyboardRequest = true;
                break;
            case Action::CursorToggle:
                if (pressed) {
                    s_cursorMode = !s_cursorMode;
                    LOG_DEBUG("Right stick: ", s_cursorMode ? "cursor" : "look");
                }
                break;
            case Action::WorldMap:
                // Nothing here, and the row exists anyway. Opening the map
                // needs the interface's own ToggleWorldMap, which this file
                // cannot reach, and closing it again needs a press this loop
                // never sees: the loop is skipped outright while a menu owns
                // the pad, which is what the open map is. So the bridge reads
                // the button off padSnapshot() and the table keeps the row, so
                // that what the middle of the pad does is still written in the
                // one place the mapping is written.
                break;
        }
    }
    // The D-pad belongs to ImGui's navigation while an interface window has
    // the focus: neither turn nor zoom then.
    if (s_uiFocus && layer == Layer::Base) {
        want[SDL_SCANCODE_A] = false;
        want[SDL_SCANCODE_D] = false;
    }

    if (s_menuOwners && !s_applicationKeyboardOpen)
        want[SDL_SCANCODE_ESCAPE] = (st.buttons & ORBIS_PAD_BUTTON_OPTIONS) != 0;
    // Chat. No row in the table can reach it, because in the world nothing is
    // free: the face buttons are the click, the interact, the target and the
    // action bar, + is the game menu, - the world map, the D-pad zooms and
    // turns, L3 is autorun and R3 the cursor. Both index shoulders together is
    // the one gesture that is left, because the original interface's own
    // hotbars read that press as L1 and R1 at once and step by zero
    // (addons/local_framexml_input.cpp navigateBars) and the table's L1 layer
    // leaves R1 unbound - a shoulder on its own walks the action bar or the
    // menu icons, so it cannot have this.
    //
    // Return, not a new key: that is what the client's own chat key is
    // (ui/game_screen.cpp:1384 opens the interface's box on Return and
    // TOGGLE_CHAT defaults to Enter), and Enter is already how the box sends,
    // so one key opens and one key sends. The 200ms grace and the keyboard's
    // own ownership are above and are not touched by this.
    if (s_inWorld && !s_menuOwners && !s_applicationKeyboardOpen && !s_textFocus &&
        (gameplayButtons & (ORBIS_PAD_BUTTON_L1 | ORBIS_PAD_BUTTON_R1)) ==
            (ORBIS_PAD_BUTTON_L1 | ORBIS_PAD_BUTTON_R1)) {
        want[SDL_SCANCODE_RETURN] = true;
    }
    if (!s_applicationKeyboardOpen && !s_menuOwners) applyLeftStick(want);
    applyRightStick(dt, right);
    if (!s_applicationKeyboardOpen) applyWheel(wheel);
    applyKeys(want);
    applyMouseButtons(left, right);

    s_mouse.x = s_cursorX;
    s_mouse.y = s_cursorY;
    s_mouse.dx = s_cursorX - prevX;
    s_mouse.dy = s_cursorY - prevY;
    s_mouse.wheel = s_wheelThisFrame;
    s_mouse.relativeMode = s_relativeMode;
}

const MouseState& mouseState() { return s_mouse; }

bool inputCameraLooking() { return s_relativeMode || s_lookEngaged; }

bool inputCursorVisible() {
    if (inputCameraLooking()) return false;
    return !s_inWorld || s_cursorMode || s_textFocus || s_uiFocus || s_menuOwners || s_applicationKeyboardOpen;
}

bool isVirtualKeyHeld(int sdlScancode) {
    if (sdlScancode < 0 || sdlScancode >= SDL_NUM_SCANCODES) return false;
    return s_held[static_cast<size_t>(sdlScancode)] != 0;
}

// ---- contract: the on-screen keyboard ---------------------------------------------------

void showKeyboardEx(const KeyboardOptions& options,
                    std::function<void(const std::string&, bool)> done) {
    if (s_keyboard.open) {
        LOG_WARNING("showKeyboard: a keyboard is already open");
        if (done) done(std::string(), false);
        return;
    }
    if (!s_initialised) {
        LOG_WARNING("showKeyboard: no user (initInput failed?)");
        if (done) done(std::string(), false);
        return;
    }

    s_keyboard.options = options;
    s_keyboard.model.begin(options.initialText, options.maxLength, options.numeric);
    s_keyboard.rawPrevious = s_padState.buttons; s_keyboard.rawPressed = 0;
    s_keyboard.justOpened = true; s_keyboard.open = true;
    s_keyboard.done = std::move(done);
    s_lookEngaged = false;
    LOG_DEBUG("In-game keyboard opened (field contents are not logged)");
}

void showKeyboard(const std::string& title, const std::string& initialText,
                  bool password, std::function<void(const std::string&, bool accepted)> done) {
    KeyboardOptions options;
    options.title = title;
    options.initialText = initialText;
    options.password = password;
    showKeyboardEx(options, std::move(done));
}

void renderKeyboard() {
    if (!s_keyboard.open) return;
    // The same 3x10 modal and pad controls as character creation, extended
    // with a symbol/number page for realm names, chat and connection fields.
    ImGui::OpenPopup("Text entry##wowps_keyboard");
    const auto display = ImGui::GetIO().DisplaySize;
    const float scale = std::clamp(display.y / 768.0f, 0.7f, 1.6f);
    ImGui::SetNextWindowPos(ImVec2(display.x*.5f, display.y*.5f), ImGuiCond_Always, ImVec2(.5f,.5f));
    ImGui::SetNextWindowSize(ImVec2(620*scale, 330*scale), ImGuiCond_Always);
    bool finish = false, accepted = false; std::string result;
    if (ImGui::BeginPopupModal("Text entry##wowps_keyboard", nullptr,
        ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings)) {
        auto& model = s_keyboard.model;
        ImGui::TextUnformatted(s_keyboard.options.title.c_str());
        const std::string shown = s_keyboard.options.password ? std::string(model.draft.size(), '*') : model.draft;
        ImGui::TextWrapped("%s", shown.empty() ? "_" : shown.c_str());
        ImGui::TextUnformatted("D-pad: select   Cross: type   Square: delete   R2: Done   Circle: Cancel");
        ImGui::TextUnformatted("R1: ABC / 123 symbols   Triangle: upper/lower case");
        ImGui::Separator();
        const uint32_t pressed = s_keyboard.justOpened ? 0 : s_keyboard.rawPressed;
        s_keyboard.justOpened = false; s_keyboard.rawPressed = 0;
        if (pressed & ORBIS_PAD_BUTTON_LEFT) model.move(-1,0);
        if (pressed & ORBIS_PAD_BUTTON_RIGHT) model.move(1,0);
        if (pressed & ORBIS_PAD_BUTTON_UP) model.move(0,-1);
        if (pressed & ORBIS_PAD_BUTTON_DOWN) model.move(0,1);
        if (pressed & ORBIS_PAD_BUTTON_R1) model.nextPage();
        if (pressed & ORBIS_PAD_BUTTON_TRIANGLE) model.choose(27);
        int key = -1;
        if (pressed & ORBIS_PAD_BUTTON_CROSS) key = model.selected;
        if (pressed & ORBIS_PAD_BUTTON_SQUARE) key = 26;
        if (pressed & ORBIS_PAD_BUTTON_R2) key = 28;
        if (pressed & ORBIS_PAD_BUTTON_CIRCLE) key = 29;
        for (int i=0; i<30; ++i) {
            char label[32]; const char c = model.character(i);
            if (i<26) std::snprintf(label,sizeof(label),"%s%c##key%d", c==' ' ? "Space" : "", c && c!=' ' ? c : ' ',i);
            else std::snprintf(label,sizeof(label),"%s##key%d", i==26 ? "Del" : i==27 ? "Aa" : i==28 ? (s_keyboard.options.sendLabel ? "Send" : "Done") : "Cancel",i);
            if (i%10) ImGui::SameLine();
            if (i==model.selected) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(.5f,.22f,.08f,1));
            if (ImGui::Button(label,ImVec2(51*scale,45*scale))) key=i;
            if (i==model.selected) ImGui::PopStyleColor();
        }
        const auto choice = model.choose(key);
        if (choice != ui::ControllerTextKeyboard::Result::Editing) {
            accepted = choice == ui::ControllerTextKeyboard::Result::Accepted;
            result = model.draft; finish = true; ImGui::CloseCurrentPopup();
        }
        ImGui::EndPopup();
    }
    // Deliver after closing the modal: focus and the target buffer still belong
    // to the caller. The existing SDL replace-text path is preserved.
    if (finish) finishKeyboard(accepted, result);
}

bool keyboardOpen() { return s_keyboard.open || s_applicationKeyboardOpen; }
bool keyboardCapturesInput() { return keyboardOpen() || nowMs() < s_ignoreButtonsUntilMs; }
bool applicationKeyboardOpen() { return s_applicationKeyboardOpen; }
void setApplicationKeyboardOpen(bool open) {
    s_applicationKeyboardOpen = open;
    if (!open) s_ignoreButtonsUntilMs = nowMs() + kDialogGraceMs;
}

// ---- private helpers (input_switch.hpp) -----------------------------------------------------

void setInputDisplaySize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (width == s_displayW && height == s_displayH) return;
    // Keep the cursor where it was, proportionally.
    s_cursorX = s_cursorX / static_cast<float>(std::max(s_displayW, 1)) * static_cast<float>(width);
    s_cursorY = s_cursorY / static_cast<float>(std::max(s_displayH, 1)) * static_cast<float>(height);
    s_displayW = width;
    s_displayH = height;
    s_cursorX = clampf(s_cursorX, 0.0f, static_cast<float>(width - 1));
    s_cursorY = clampf(s_cursorY, 0.0f, static_cast<float>(height - 1));
}

void getInputDisplaySize(int* width, int* height) {
    if (width) *width = s_displayW;
    if (height) *height = s_displayH;
}

void setInputActionBars(bool enabled) { s_actionBarNavigation=enabled; }
void setInputInWorld(bool inWorld) {
    if (s_inWorld == inWorld) return;
    s_inWorld = inWorld;
    if(!inWorld)s_actionBarNavigation=false;
    s_lookEngaged = false;
    // A settings window from the old session must not own the character menu.
    s_menuOwners = 0;
}

void setInputTextFocus(bool focused) { s_textFocus = focused; }
bool inputTextFocus() { return s_textFocus; }
void setInputUiFocus(bool focused) { s_uiFocus = focused; }
void setInputMenuNavigation(MenuOwner owner, bool open) {
    const unsigned bit = static_cast<unsigned>(owner);
    if (open) s_menuOwners |= bit; else s_menuOwners &= ~bit;
}
bool inputMenuNavigation() { return s_menuOwners != 0; }

bool takeKeyboardRequest() {
    const bool r = s_keyboardRequest;
    s_keyboardRequest = false;
    return r;
}

const PadSnapshot& padSnapshot() { return s_padState; }
bool padConnected() { return s_padConnected; }

void pushKeyEvent(SDL_Scancode scancode, bool down) {
    if (scancode <= SDL_SCANCODE_UNKNOWN || scancode >= SDL_NUM_SCANCODES) return;
    s_held[static_cast<size_t>(scancode)] = down ? 1 : 0;
    pushKey(scancode, down);
}

void pushTextInput(const std::string& utf8) {
    // At most 31 bytes per event, never splitting a character.
    size_t i = 0;
    while (i < utf8.size()) {
        size_t end = std::min(utf8.size(), i + static_cast<size_t>(SDL_TEXTINPUTEVENT_TEXT_SIZE - 1));
        while (end < utf8.size() && end > i &&
               (static_cast<unsigned char>(utf8[end]) & 0xC0) == 0x80) {
            --end;
        }
        if (end == i) end = std::min(utf8.size(), i + 1);
        SDL_Event e = makeEvent(SDL_TEXTINPUT);
        std::memcpy(e.text.text, utf8.data() + i, end - i);
        e.text.text[end - i] = '\0';
        s_events.push_back(e);
        i = end;
    }
}

void noteTextField(const TextFieldHint& hint) {
    s_fieldHint = hint;
    s_haveFieldHint = true;
}

bool takeTextFieldHint(TextFieldHint& out) {
    if (!s_haveFieldHint) return false;
    out = s_fieldHint;
    s_haveFieldHint = false;
    return true;
}

void setRelativeMouseMode(bool enabled) {
    if (enabled == s_relativeMode) return;
    s_relativeMode = enabled;
    s_mouse.relativeMode = enabled;
    if (enabled) {
        s_relativeOriginX = s_cursorX;
        s_relativeOriginY = s_cursorY;
        s_restoreCursorPending = false;
    } else {
        s_restoreCursorPending = true;
    }
}

}  // namespace switch
}  // namespace platform
}  // namespace wowee

// ---- the SDL functions (sdl_scancode_compat.h) ------------------------------------------

namespace ps4in = wowee::platform::switchport;

int SDL_PollEvent(SDL_Event* event) {
    using namespace wowee::platform::switchport;
    if (s_events.empty()) return 0;
    if (event) *event = s_events.front();
    s_events.pop_front();
    return 1;
}

int SDL_PushEvent(SDL_Event* event) {
    using namespace wowee::platform::switchport;
    if (!event) return -1;
    SDL_Event copy = *event;
    if (copy.common.timestamp == 0) copy.common.timestamp = nowMs();
    if (copy.type == SDL_MOUSEWHEEL) s_wheelThisFrame += copy.wheel.preciseY;
    s_events.push_back(copy);
    return 1;
}

Uint32 SDL_GetTicks(void) { return wowee::platform::switchport::nowMs(); }

void SDL_Delay(Uint32 ms) { svcSleepThread((s64)ms * 1000000LL); }

const Uint8* SDL_GetKeyboardState(int* numkeys) {
    if (numkeys) *numkeys = SDL_NUM_SCANCODES;
    return wowee::platform::switchport::s_held.data();
}

SDL_Keymod SDL_GetModState(void) {
    return static_cast<SDL_Keymod>(wowee::platform::switchport::modState());
}

SDL_Keycode SDL_GetKeyFromScancode(SDL_Scancode scancode) {
    return wowee::platform::switchport::keycodeFor(scancode);
}

const char* SDL_GetScancodeName(SDL_Scancode scancode) {
    static const char* const letters[] = {
        "A","B","C","D","E","F","G","H","I","J","K","L","M",
        "N","O","P","Q","R","S","T","U","V","W","X","Y","Z"};
    static const char* const digits[] = {"1","2","3","4","5","6","7","8","9","0"};
    if (scancode >= SDL_SCANCODE_A && scancode <= SDL_SCANCODE_Z) return letters[scancode - SDL_SCANCODE_A];
    if (scancode >= SDL_SCANCODE_1 && scancode <= SDL_SCANCODE_0) return digits[scancode - SDL_SCANCODE_1];
    switch (scancode) {
        case SDL_SCANCODE_RETURN: return "Return";
        case SDL_SCANCODE_ESCAPE: return "Escape";
        case SDL_SCANCODE_BACKSPACE: return "Backspace";
        case SDL_SCANCODE_TAB: return "Tab";
        case SDL_SCANCODE_SPACE: return "Space";
        case SDL_SCANCODE_MINUS: return "-";
        case SDL_SCANCODE_EQUALS: return "=";
        case SDL_SCANCODE_GRAVE: return "`";
        case SDL_SCANCODE_DELETE: return "Delete";
        case SDL_SCANCODE_UP: return "Up";
        case SDL_SCANCODE_DOWN: return "Down";
        case SDL_SCANCODE_LEFT: return "Left";
        case SDL_SCANCODE_RIGHT: return "Right";
        case SDL_SCANCODE_LSHIFT: return "Left Shift";
        case SDL_SCANCODE_RSHIFT: return "Right Shift";
        case SDL_SCANCODE_LCTRL: return "Left Ctrl";
        case SDL_SCANCODE_RCTRL: return "Right Ctrl";
        case SDL_SCANCODE_LALT: return "Left Alt";
        case SDL_SCANCODE_RALT: return "Right Alt";
        case SDL_SCANCODE_NUMLOCKCLEAR: return "Numlock";
        case SDL_SCANCODE_PRINTSCREEN: return "PrintScreen";
        case SDL_SCANCODE_KP_ENTER: return "Keypad Enter";
        case SDL_SCANCODE_F1: return "F1";
        case SDL_SCANCODE_F8: return "F8";
        case SDL_SCANCODE_F12: return "F12";
        default: return "";
    }
}

const char* SDL_GetKeyName(SDL_Keycode key) {
    if (key & SDLK_SCANCODE_MASK) {
        return SDL_GetScancodeName(static_cast<SDL_Scancode>(key & ~SDLK_SCANCODE_MASK));
    }
    // Printable ASCII: SDL names it by its upper-case character.
    static thread_local char one[2] = {0, 0};
    switch (key) {
        case SDLK_RETURN: return "Return";
        case SDLK_ESCAPE: return "Escape";
        case SDLK_BACKSPACE: return "Backspace";
        case SDLK_TAB: return "Tab";
        case SDLK_SPACE: return "Space";
        case SDLK_DELETE: return "Delete";
        default: break;
    }
    if (key >= 0x20 && key < 0x7F) {
        one[0] = static_cast<char>((key >= 'a' && key <= 'z') ? key - 'a' + 'A' : key);
        return one;
    }
    return "";
}

Uint32 SDL_GetMouseState(int* x, int* y) {
    using namespace wowee::platform::switchport;
    if (x) *x = static_cast<int>(s_cursorX);
    if (y) *y = static_cast<int>(s_cursorY);
    return mouseButtonMask();
}

int SDL_SetRelativeMouseMode(SDL_bool enabled) {
    ps4in::setRelativeMouseMode(enabled == SDL_TRUE);
    return 0;
}

SDL_bool SDL_GetRelativeMouseMode(void) {
    return wowee::platform::switchport::s_relativeMode ? SDL_TRUE : SDL_FALSE;
}

int SDL_ShowCursor(int toggle) {
    // ImGui draws the cursor (a software cursor, imgui_impl_switch.cpp); the
    // visibility follows relative mode, not this switch.
    (void)toggle;
    return wowee::platform::switchport::s_relativeMode ? SDL_DISABLE : SDL_ENABLE;
}

char* SDL_GetClipboardText(void) {
    const std::string& text = wowee::platform::switchport::s_clipboard;
    char* copy = static_cast<char*>(std::malloc(text.size() + 1));
    if (!copy) return nullptr;
    std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
}

int SDL_SetClipboardText(const char* text) {
    wowee::platform::switchport::s_clipboard = text ? text : "";
    return 0;
}

SDL_bool SDL_HasClipboardText(void) {
    return wowee::platform::switchport::s_clipboard.empty() ? SDL_FALSE : SDL_TRUE;
}

void SDL_GetWindowSize(SDL_Window* window, int* w, int* h) {
    (void)window;
    ps4in::getInputDisplaySize(w, h);
}
