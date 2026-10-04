#pragma once

#include <SDL2/SDL.h>
#include <array>
#include <glm/glm.hpp>

namespace wowee {
namespace core {

class Input {
public:
    static Input& getInstance();

    void update();

    // Keyboard
    [[nodiscard]] bool isKeyPressed(SDL_Scancode key) const;

    /// Holds a key down from somewhere that is not a keyboard.
    ///
    /// The on-screen stick is the reason: movement, its animations and the
    /// packets that announce it are a long chain that starts at
    /// isKeyPressed(SDL_SCANCODE_W), and a phone has no W. Setting the key here
    /// drives all of it without any of it knowing where the press came from.
    /// Merged over the hardware state, so a keyboard still works alongside.
    void setVirtualKey(SDL_Scancode key, bool held);
    void clearVirtualKeys();
    [[nodiscard]] bool isKeyJustPressed(SDL_Scancode key) const;

    // Mouse
    //
    // Held and Released are levels; JustPressed and JustReleased are edges.
    //
    // The edges come off the event queue as well as off the poll, because the
    // poll alone only ever sees a click that happens to straddle a frame. A
    // press and a release that both land between two polls read as one sample
    // with the button up, which is no click at all - and the world picker acts
    // on nothing, while every control the interface draws still works, because
    // ImGui and FrameXML read the same events these are read from. The gap is
    // invisible at the frame rate the console runs at and total at the one this
    // build reaches with a software Vulkan driver, where a frame is a third of
    // a second and a click is a tenth.
    [[nodiscard]] bool isMouseButtonPressed(int button) const;
    [[nodiscard]] bool isMouseButtonJustPressed(int button) const;
    [[nodiscard]] bool isMouseButtonJustReleased(int button) const;

    /// Where the pointer was when a motion event said so.
    ///
    /// The poll answers for the frame, which is a frame stale for everything
    /// that wants where the cursor *was* - and the pick is exactly that: the
    /// click casts its ray from the position recorded on the press, so a
    /// position one frame old aims at whatever was under the cursor then.
    void noteMouseMotionEvent(int x, int y);

    /// A button press or release, as the event queue saw it.
    void noteMouseButtonEvent(int button, bool down, int x, int y);

    [[nodiscard]] glm::vec2 getMousePosition() const { return mousePosition; }
    [[nodiscard]] glm::vec2 getMouseDelta() const { return mouseDelta; }

    [[nodiscard]] bool isMouseLocked() const { return mouseLocked; }

private:
    Input() = default;
    ~Input() = default;
    Input(const Input&) = delete;
    Input& operator=(const Input&) = delete;

    static constexpr int NUM_KEYS = SDL_NUM_SCANCODES;
    static constexpr int NUM_MOUSE_BUTTONS = 8;

    std::array<bool, NUM_KEYS> currentKeyState = {};
    std::array<bool, NUM_KEYS> virtualKeyState = {};
    std::array<bool, NUM_KEYS> previousKeyState = {};

    std::array<bool, NUM_MOUSE_BUTTONS> currentMouseState = {};
    std::array<bool, NUM_MOUSE_BUTTONS> previousMouseState = {};

    /// A button that changed hands since the last update().
    ///
    /// Level, not count: a press and a release of the same button between two
    /// frames is one press and one release, and both are what the frame after
    /// them has to answer for. Both are kept apart from the level, because the
    /// level of a button nobody is holding says nothing about which way it went.
    std::array<bool, NUM_MOUSE_BUTTONS> pressedSincePoll = {};
    std::array<bool, NUM_MOUSE_BUTTONS> releasedSincePoll = {};
    std::array<bool, NUM_MOUSE_BUTTONS> edgePressed = {};
    std::array<bool, NUM_MOUSE_BUTTONS> edgeReleased = {};
    /// An edge already reported for this button, so that the queue seeing it
    /// first and the poll catching up a frame later is one click and not two.
    std::array<bool, NUM_MOUSE_BUTTONS> pressSeen = {};
    std::array<bool, NUM_MOUSE_BUTTONS> releaseSeen = {};
    /// This frame's edges. Worked out in update(), where the levels and the
    /// queue's news are both in hand, and read for the whole frame after it -
    /// the pick is answered from the draw, which is long after update() returns.
    std::array<bool, NUM_MOUSE_BUTTONS> justPressedFrame = {};
    std::array<bool, NUM_MOUSE_BUTTONS> justReleasedFrame = {};
    /// The pointer position the last event carried, and whether it carried one.
    bool eventPositionValid = false;
    glm::vec2 eventPosition = glm::vec2(0.0f);

    glm::vec2 mousePosition = glm::vec2(0.0f);
    glm::vec2 previousMousePosition = glm::vec2(0.0f);
    glm::vec2 mouseDelta = glm::vec2(0.0f);
    bool mouseLocked = false;
};

} // namespace core
} // namespace wowee
