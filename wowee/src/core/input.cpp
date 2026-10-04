#include "core/input.hpp"
#ifdef WOWEE_SWITCH
#include "platform/switch/switch_platform.hpp"
#endif

namespace wowee {
namespace core {

Input& Input::getInstance() {
    static Input instance;
    return instance;
}

void Input::update() {
    // Copy current state to previous
    previousKeyState = currentKeyState;
    previousMouseState = currentMouseState;
    previousMousePosition = mousePosition;

    // The events drained since the last call are this frame's edges. They are
    // taken here, at the top, because the poll below is where the levels are
    // read - and the two are read together, so that a press one of them saw and
    // the other did not is still one press and not two.
    edgePressed = pressedSincePoll;
    edgeReleased = releasedSincePoll;
    pressedSincePoll.fill(false);
    releasedSincePoll.fill(false);

#ifdef WOWEE_SWITCH
    // No keyboard or mouse on the console. The pad layer
    // (src/platform/switch/input_switch.cpp) holds scancodes on the player's behalf
    // - left stick W/S/Q/E, face buttons the action bar, and so on - and moves
    // an emulated cursor. Merged over the virtual keys exactly as the hardware
    // state is on the desktop, so the on-screen stick's hook still works.
    for (int i = 0; i < NUM_KEYS; ++i) {
        currentKeyState[i] = platform::switchport::isVirtualKeyHeld(i) || virtualKeyState[i];
    }

    const platform::switchport::MouseState& pad = platform::switchport::mouseState();
    mousePosition = glm::vec2(pad.x, pad.y);
    currentMouseState.fill(false);
    currentMouseState[SDL_BUTTON_LEFT] = pad.left;
    currentMouseState[SDL_BUTTON_MIDDLE] = pad.middle;
    currentMouseState[SDL_BUTTON_RIGHT] = pad.right;
    mouseLocked = pad.relativeMode;
#else
    // Get current keyboard state
    const Uint8* keyState = SDL_GetKeyboardState(nullptr);
    for (int i = 0; i < NUM_KEYS; ++i) {
        currentKeyState[i] = keyState[i] || virtualKeyState[i];
    }

    // Get current mouse state
    int mouseX, mouseY;
    Uint32 mouseState = SDL_GetMouseState(&mouseX, &mouseY);
    mousePosition = glm::vec2(static_cast<float>(mouseX), static_cast<float>(mouseY));

    // SDL_BUTTON(x) is defined as (1 << (x-1)), so button indices are 1-based.
    // SDL_BUTTON(0) is undefined behavior (negative shift). Start at 1.
    currentMouseState[0] = false;
    for (int i = 1; i < NUM_MOUSE_BUTTONS; ++i) {
        currentMouseState[i] = (mouseState & SDL_BUTTON(i)) != 0;
    }
#endif

    // Calculate mouse delta
    mouseDelta = mousePosition - previousMousePosition;

    // An event's position is the truth and the poll's is a frame old, so the
    // event wins wherever one arrived. Nothing reads the delta and the frame's
    // own hover - the cursor affordance, the link rects - all want the place
    // the cursor is rather than the place it was when the frame began.
    if (eventPositionValid) mousePosition = eventPosition;
    eventPositionValid = false;

    // The frame's edges, from both sources at once.
    //
    // What the poll saw change is one half. The other half is an edge the queue
    // saw and the poll could not have - a click whose press and release both
    // fell between two polls, which reads as one sample with the button up and
    // is no click at all. The queue half only counts while the level says the
    // button is not being held: a level that says "down" is already the poll's
    // answer, and a level that says "up" cannot also be the frame that reports
    // a press that has been given back.
    //
    // Each is reported once, whichever source saw it first. The queue gets the
    // news first and the poll catches up a frame later, and two reports of one
    // click are two clicks to whatever is counting them.
    for (int b = 1; b < NUM_MOUSE_BUTTONS; ++b) {
        const bool pressed = (currentMouseState[b] && !previousMouseState[b]) ||
                             (edgePressed[b] && !currentMouseState[b]);
        const bool released = (!currentMouseState[b] && previousMouseState[b]) ||
                              (edgeReleased[b] && !currentMouseState[b]);
        justPressedFrame[b] = pressed && !pressSeen[b];
        justReleasedFrame[b] = released && !releaseSeen[b];
        if (pressed) pressSeen[b] = true;
        if (released) pressSeen[b] = false;
        if (released) releaseSeen[b] = true;
        if (pressed) releaseSeen[b] = false;
    }
}

void Input::noteMouseMotionEvent(int x, int y) {
    eventPosition = glm::vec2(static_cast<float>(x), static_cast<float>(y));
    eventPositionValid = true;
}

void Input::noteMouseButtonEvent(int button, bool down, int x, int y) {
    // The button index is SDL's own 1-based one, the same numbering
    // isMouseButtonPressed asks in, so nothing shifts it on the way in.
    if (button <= 0 || button >= NUM_MOUSE_BUTTONS) return;
    if (down) pressedSincePoll[button] = true;
    else releasedSincePoll[button] = true;
    // A press and a release can both have come in since the last update. Both
    // are latched, and neither is cancelled by the other: the level the poll
    // reports is up, and each of them is still a thing that happened.
    noteMouseMotionEvent(x, y);
}

void Input::setVirtualKey(SDL_Scancode key, bool held) {
    if (key < 0 || key >= NUM_KEYS) return;
    virtualKeyState[key] = held;
}

void Input::clearVirtualKeys() {
    virtualKeyState.fill(false);
}

bool Input::isKeyPressed(SDL_Scancode key) const {
    if (key < 0 || key >= NUM_KEYS) return false;
    return currentKeyState[key];
}

bool Input::isKeyJustPressed(SDL_Scancode key) const {
    if (key < 0 || key >= NUM_KEYS) return false;
    return currentKeyState[key] && !previousKeyState[key];
}
bool Input::isMouseButtonPressed(int button) const {
    if (button < 0 || button >= NUM_MOUSE_BUTTONS) return false;
    return currentMouseState[button];
}

bool Input::isMouseButtonJustPressed(int button) const {
    if (button < 0 || button >= NUM_MOUSE_BUTTONS) return false;
    return justPressedFrame[button];
}

bool Input::isMouseButtonJustReleased(int button) const {
    if (button < 0 || button >= NUM_MOUSE_BUTTONS) return false;
    return justReleasedFrame[button];
}
} // namespace core
} // namespace wowee
