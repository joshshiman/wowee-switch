#pragma once

#include <glm/glm.hpp>

namespace wowee::ui {

/// The minimap draws the world north-up around the player and scales from yards
/// to pixels. Both directions of that transform live here because the client
/// needs both: markers project outward, clicks invert back.
///
/// Offsets are minimap pixels measured from its centre with **+y down**, which
/// is ImGui's screen space and the space the marker code already worked in.
/// Deltas are render space, relative to the player.
struct MinimapView {
    /// Yards the minimap covers, centre to edge.
    float viewRadius = 100.0f;
    /// Half the minimap's on-screen width.
    float mapRadius = 70.0f;
    /// Clockwise camera bearing from north, pre-resolved. Both are 1/0 when the
    /// map does not rotate with the camera, which is this client's default.
    ///
    /// Carried, not used: Minimap::render pins the display shader's rotation to
    /// zero ("Stabilize transports and correct minimap orientation" is read and
    /// dropped), so the map the shader draws never turns. A projection that
    /// turned with it would put markers off the terrain rather than quarter
    /// turned from it. Whoever re-enables rotation has to make this and the
    /// shader's vec2(-rotated.x, rotated.y) agree, and they will not by
    /// themselves: the shader rotates before it negates, so the result is no
    /// longer diagonal.
    float cosBearing = 1.0f;
    float sinBearing = 0.0f;
};

/// Render-space delta from the player to an offset in minimap pixels.
///
/// The same pairing the minimap display shader samples with, which builds its
/// offset as
///   mapUV = playerUV + vec2(-rotated.x, rotated.y) * zoomRadius
/// from rotated = R(0) * vec2(-center.x, center.y). Composite u grows east and
/// v grows south, render +X is west and +Y is north, and minimap pixels have +y
/// down - so a feature to the east (dx < 0) lands right of centre at -dx * k,
/// and a feature to the north (dy > 0) lands above it at -dy * k. That pairing
/// is the whole of it.
///
/// The old form here was vec2(rotated.y, -rotated.x) * zoom * 2, a literal
/// transcription of the shader as it then read. That transposed the two axes,
/// so every marker - chest, NPC dot, waypoint - sat a quarter turn from the
/// terrain it was marking.
///
/// The scale is the authored one: viewRadius yards is the minimap's edge, so k
/// is mapRadius / viewRadius. The shader's own edge is 0.5 * zoomRadius from the
/// player, because TexCoord runs 0..1 across the quad, which is viewRadius / 2
/// yards. The axes above are what this change fixes; that factor of two between
/// the two scales is a separate, unresolved disagreement, so nothing here asserts
/// the two agree numerically.
inline glm::vec2 renderDeltaToMinimapOffset(float dx, float dy, const MinimapView& v) {
    if (v.viewRadius <= 0.0f) return {0.0f, 0.0f};
    const float k = v.mapRadius / v.viewRadius;
    return {-dx * k, -dy * k};
}

/// An offset in minimap pixels back to a render-space delta from the player.
inline glm::vec2 minimapOffsetToRenderDelta(float px, float py, const MinimapView& v) {
    if (v.mapRadius <= 0.0f) return {0.0f, 0.0f};
    const float k = v.viewRadius / v.mapRadius;
    return {-px * k, -py * k};
}

}  // namespace wowee::ui
