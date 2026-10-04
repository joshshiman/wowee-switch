// The CPU half of the minimap projection, against the shader it mirrors.
//
// include/ui/minimap_projection.hpp is the only CPU-side implementation of the
// world-to-minimap-pixel transform: game_screen_minimap.cpp projects every
// marker, quest dot and edge arrow through renderDeltaToMinimapOffset, and
// application.cpp's Minimap:PingLocation and game_screen_minimap.cpp's hover
// read it back through minimapOffsetToRenderDelta. It used to carry the shader's
// own expression, vec2(rotated.y, -rotated.x) * zoom * 2, transposed axes and
// all, so every marker sat a quarter turn from the terrain under it.
//
// A literal transcription is exactly what makes it drift: the shader was
// corrected to vec2(-rotated.x, rotated.y) * zoomRadius and the header was left
// quoting the old line. So this reads the shader and the header and requires the
// axis pairing to agree, rather than hard-coding what it should be - if either
// is edited away from the other, this fails.
#include "ui/minimap_projection.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace {

int failures = 0;

void check(bool okay, const std::string& message) {
    if (!okay) {
        std::fprintf(stderr, "FAIL minimap projection (%d): %s\n", failures + 1, message.c_str());
        ++failures;
    }
}

float close(float a, float b, float tolerance = 1e-4f) {
    return std::fabs(a - b) <= tolerance;
}

std::string read(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        std::fprintf(stderr, "FAIL minimap projection: cannot read %s\n", path.c_str());
        std::exit(1);
    }
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

/// The shader's own mapUV line, and which rotated component feeds u and v.
struct ShaderOffset {
    std::string u;      // the expression the shader negates into composite u
    std::string v;      // ... and the one it adds into composite v
    float gain;         // the literal zoomRadius is multiplied by
};

ShaderOffset shaderOffset(const std::string& frag) {
    const std::regex line(R"(mapUV\s*=\s*push\.playerUV\s*\+\s*vec2\(([^,]+),\s*([^)]+)\)\s*\*\s*push\.zoomRadius\s*\*\s*([0-9.]+))");
    std::smatch match;
    if (!std::regex_search(frag, match, line)) {
        std::fprintf(stderr, "FAIL minimap projection: minimap_display.frag.glsl no longer "
                             "builds mapUV as playerUV + vec2(a, b) * zoomRadius * n\n");
        std::exit(1);
    }
    return {match[1].str(), match[2].str(), std::stof(match[3].str())};
}

}  // namespace

int main(int argc, char** argv) {
    const std::string root = argc > 1 ? argv[1] : ".";

    // --- 1. The shader, read rather than remembered.
    const ShaderOffset shader = shaderOffset(read(root + "/assets/shaders/minimap_display.frag.glsl"));
    std::printf("  display shader: mapUV = playerUV + vec2(%s, %s) * zoomRadius * %g\n",
                shader.u.c_str(), shader.v.c_str(), shader.gain);

    // rotation is 0 in this client, so at R(0) rotated is mapCenter, which is
    // vec2(-center.x, center.y): the shader negates rotated.x to raise composite
    // u with screen right, and adds rotated.y to raise composite v with screen
    // down. So -rotated.x is screen right and rotated.y is screen down.
    check(shader.u == "-rotated.x", "display shader no longer takes composite u from -rotated.x; "
                                    "the pairing this header mirrors has changed");
    check(shader.v == "rotated.y", "display shader no longer takes composite v from rotated.y; "
                                   "the pairing this header mirrors has changed");

    // --- 2. The header, for the same two facts: which way east goes, and which
    // way north goes. It does not transcribe the shader, it states the result in
    // render space, so compare the two numerically on the four compass points.
    const wowee::ui::MinimapView view{/*viewRadius=*/400.0f, /*mapRadius=*/70.0f};

    struct Cardinal { const char* name; float dx; float dy; float px; float py; };
    // Render space: +X is west, +Y is north. Minimap pixels: +x right, +y down.
    const Cardinal points[] = {
        {"east",  -100.0f,    0.0f,  17.5f,   0.0f},
        {"west",   100.0f,    0.0f, -17.5f,   0.0f},
        {"north",   0.0f,  100.0f,   0.0f, -17.5f},
        {"south",   0.0f, -100.0f,   0.0f,  17.5f},
    };
    for (const Cardinal& point : points) {
        const glm::vec2 offset = wowee::ui::renderDeltaToMinimapOffset(point.dx, point.dy, view);
        check(close(offset.x, point.px) && close(offset.y, point.py),
              std::string("renderDeltaToMinimapOffset puts ") + point.name +
              " at (" + std::to_string(offset.x) + ", " + std::to_string(offset.y) +
              "), expected (" + std::to_string(point.px) + ", " + std::to_string(point.py) + ")");
        std::printf("  %-6s render delta (%+.0f, %+.0f) -> minimap %+.2f, %+.2f px\n",
                    point.name, point.dx, point.dy, offset.x, offset.y);
    }

    // --- 3. And the shader's own axes, read as screen directions, are the ones
    // just asserted. Composite u grows east and v grows south (Minimap::
    // compositePass's gridOffset, which minimap_projection_test.py traces), so a
    // sample offset of -rotated.x in u means screen right raises u, i.e. east;
    // rotated.y in v means screen down raises v, i.e. south. Negated for render
    // space, which has +X west and +Y north, that is exactly -dx and -dy.
    // The scale is the documented one: viewRadius yards is the minimap's edge.
    const glm::vec2 edge = wowee::ui::renderDeltaToMinimapOffset(-view.viewRadius, 0.0f, view);
    check(close(edge.x, view.mapRadius) && close(edge.y, 0.0f),
          "a feature viewRadius yards to the east does not land on the minimap's edge");
    check(wowee::ui::renderDeltaToMinimapOffset(-100.0f, 0.0f, view).x > 0.0f,
          "a feature to the east is not drawn to the right of the minimap's centre");
    check(wowee::ui::renderDeltaToMinimapOffset(0.0f, 100.0f, view).y < 0.0f,
          "a feature to the north is not drawn above the minimap's centre");

    // --- 4. The two directions are inverses of each other, or a click that
    // resolves to a world point will not resolve back to the pixel it was over.
    for (const Cardinal& point : points) {
        const glm::vec2 back = wowee::ui::minimapOffsetToRenderDelta(point.px, point.py, view);
        check(close(back.x, point.dx, 1e-3f) && close(back.y, point.dy, 1e-3f),
              std::string("minimapOffsetToRenderDelta does not invert ") + point.name);
    }
    // ... across a sweep, not just the four axis points, so a rotation or a
    // transposition cannot hide between them.
    for (int step = 0; step < 32; ++step) {
        const float angle = 6.2831853f * step / 32.0f;
        const float dx = std::cos(angle) * 250.0f;
        const float dy = std::sin(angle) * 250.0f;
        const glm::vec2 offset = wowee::ui::renderDeltaToMinimapOffset(dx, dy, view);
        const glm::vec2 back = wowee::ui::minimapOffsetToRenderDelta(offset.x, offset.y, view);
        check(close(back.x, dx, 1e-2f) && close(back.y, dy, 1e-2f),
              "the projection and its inverse disagree at " + std::to_string(angle));
    }

    // --- 5. A radius at or below zero collapses to the centre rather than
    // dividing by it, which is what the display shader would then sample. Each
    // direction guards the radius it divides by.
    for (const wowee::ui::MinimapView& bad :
         {wowee::ui::MinimapView{0.0f, 70.0f}, wowee::ui::MinimapView{-10.0f, 70.0f}}) {
        const glm::vec2 out = wowee::ui::renderDeltaToMinimapOffset(100.0f, 100.0f, bad);
        check(out.x == 0.0f && out.y == 0.0f && std::isfinite(out.x) && std::isfinite(out.y),
              "a non-positive viewRadius does not collapse the projected offset to the centre");
    }
    for (const wowee::ui::MinimapView& bad :
         {wowee::ui::MinimapView{400.0f, 0.0f}, wowee::ui::MinimapView{400.0f, -10.0f}}) {
        const glm::vec2 back = wowee::ui::minimapOffsetToRenderDelta(10.0f, 10.0f, bad);
        check(back.x == 0.0f && back.y == 0.0f && std::isfinite(back.x) && std::isfinite(back.y),
              "a non-positive mapRadius does not collapse the inverse to the player");
    }

    // --- 6. The bearing is carried but not applied, because the shader's
    // rotation is pinned to 0. If either side starts turning, this fails.
    check(wowee::ui::renderDeltaToMinimapOffset(100.0f, 0.0f,
             wowee::ui::MinimapView{400.0f, 70.0f, std::cos(1.2f), std::sin(1.2f)}).x ==
              wowee::ui::renderDeltaToMinimapOffset(100.0f, 0.0f, view).x,
          "the projection turns with the bearing while the display shader's rotation stays 0");

    if (failures) {
        std::fprintf(stderr, "FAIL minimap projection: %d check(s)\n", failures);
        return 1;
    }
    std::printf("PASS minimap projection: the CPU header and minimap_display.frag agree on which "
                "way east and north go, the two directions invert, and the gain is %g\n", shader.gain);
    return 0;
}
