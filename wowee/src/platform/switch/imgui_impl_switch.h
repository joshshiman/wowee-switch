#pragma once
// imgui_impl_switch.h - Dear ImGui platform backend for WoWee on switch.
//
// Replaces imgui_impl_sdl2 on the console (the renderer side stays
// imgui_impl_vulkan, running over the real Vulkan ICD in
// switch/third_party/nxvk). It feeds ImGuiIO from the pad layer in
// src/platform/switch/input_switch.cpp:
//
//   - display size and delta time;
//   - the emulated mouse: position every frame, buttons and wheel from the
//     SDL-style events the pad mapping queues, a software cursor;
//   - keys: the SDL_KEYDOWN/KEYUP events the pad mapping queues, translated
//     to ImGuiKey (with the modifier keys as ImGuiMod_*), so ImGui's own
//     shortcuts and the client's ImGuiKey bindings work off the pad;
//   - gamepad navigation (ImGuiBackendFlags_HasGamepad): the D-pad as
//     ImGuiKey_GamepadDpad* while an ImGui window has the focus;
//   - text: SDL_TEXTINPUT events as AddInputCharactersUTF8, and the
//     on-screen keyboard, opened when a text field takes the focus and
//     delivered back through the same events.
//
// Call order per frame, from UIManager:
//   ImGui_ImplSwitch_ProcessEvent for every event the application drains,
//   ImGui_ImplSwitch_NewFrame before ImGui::NewFrame,
//   ImGui_ImplSwitch_SetInWorld from render (which knows the app state),
//   ImGui_ImplSwitch_EndFrame after the interface is built, before ImGui::Render.

#include <SDL2/SDL.h>   // the switch compat shim: SDL_Event

bool ImGui_ImplSwitch_Init(int displayWidth, int displayHeight);
void ImGui_ImplSwitch_Shutdown();

/// Display size, delta time, mouse position, gamepad navigation. Before
/// ImGui::NewFrame.
void ImGui_ImplSwitch_NewFrame(int displayWidth, int displayHeight);

/// One event from the application's queue: keys, text, mouse buttons and
/// wheel, mouse motion. Returns true when ImGui took something from it.
bool ImGui_ImplSwitch_ProcessEvent(const SDL_Event* event);

/// Whether the client is in the world (the right stick looks) or on a menu
/// screen (the right stick is the cursor).
void ImGui_ImplSwitch_SetInWorld(bool inWorld);

/// After the interface is built, before ImGui::Render: opens the on-screen
/// keyboard when a text field has just taken focus (or Triangle asked for
/// it), and tells the pad layer what the interface is doing.
/// `interfaceWantsText` is ui::interfaceTakingTypedInput(): a FrameXML edit
/// box has the keyboard, which ImGui's WantTextInput knows nothing about.
void ImGui_ImplSwitch_EndFrame(bool interfaceWantsText);
