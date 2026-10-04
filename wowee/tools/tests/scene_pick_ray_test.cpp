// Two things the world pick stands on, and the one that was broken underneath it.
//
// The picker (ui/scene_pick.cpp) has no test of its own and cannot easily have
// one: pickScene() takes a GameHandler and asks core::Application for render
// bounds, so exercising the traversal means linking the whole client. What it
// does with the answer, and how the ray that answers it is built, are both
// reachable from the header the picker itself uses, and that is what this file
// covers.
//
// 1. The ray. A click is a pixel, so the question is whether the ray cast from
//    that pixel is the one the projection put there. Projected forward through
//    Camera::getViewProjectionMatrix() and cast back through
//    Camera::screenToWorldRay(), a point has to come back to itself; and against
//    a creature's bounds sphere the picker's own raySphereIntersect() has to
//    agree with the triangle test in rendering/collision_geometry.hpp, which the
//    world collision queries are built on. A ray that came back somewhere else
//    would hit nothing at all, which is what a click on a questgiver looks like
//    from the chair.
//
// 2. The edges. The click reaches the picker through
//    Input::isMouseButtonJustPressed()/isMouseButtonJustReleased(). Those used
//    to be read off one SDL_GetMouseState() poll per frame and nothing else, so
//    a click whose press and release both fell between two polls was not a
//    click: the picker was never called, while every control the interface
//    draws kept working, because ImGui and FrameXML read the events those two
//    polls were standing in for. At thirty frames a second that is rare; at the
//    three this build reaches on a software Vulkan driver it is most of them.
//    The poll still answers for a held button - only the edges are now also
//    taken from the queue.
#include <SDL2/SDL.h>

#include "core/input.hpp"
#include "rendering/camera.hpp"
#include "rendering/collision_geometry.hpp"
#include "ui/scene_pick.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace {

int failures = 0;

void require(bool okay, const char* message) {
    if (okay) return;
    std::fprintf(stderr, "FAIL scene_pick_ray: %s\n", message);
    ++failures;
}

void closeTo(float actual, float expected, float tolerance, const char* message) {
    if (std::isfinite(actual) && std::abs(actual - expected) <= tolerance) return;
    std::fprintf(stderr, "FAIL scene_pick_ray: %s (got %f, wanted %f +/- %f)\n",
                 message, static_cast<double>(actual), static_cast<double>(expected),
                 static_cast<double>(tolerance));
    ++failures;
}

// ---- the geometry a pick tests against -------------------------------------------------

/// A creature's world bounds, as CharacterRenderer::getInstanceBounds hands
/// them over: a sphere in render space, its centre lifted off the ground.
struct CreatureBounds {
    glm::vec3 centre;
    float radius;
};

/// The picker's own treatment of a unit with bounds, from
/// scene_pick.cpp: `hitRadius = max(radius * 1.25, 1.0)`. Written out here so
/// the sphere the ray is tested against is the one the picker builds, not a
/// tidier one of this file's own.
float pickRadiusFor(const CreatureBounds& bounds) {
    return std::max(bounds.radius * 1.25f, 1.0f);
}

/// Where a render-space point lands on the screen, through the same matrix the
/// nameplates project with.
bool projectToPixel(const wowee::rendering::Camera& camera, const glm::vec3& world,
                    float screenW, float screenH, glm::vec2& out) {
    const glm::vec4 clip = camera.getViewProjectionMatrix() * glm::vec4(world, 1.0f);
    if (clip.w <= 0.0f) return false;
    const glm::vec3 ndc = glm::vec3(clip) / clip.w;
    out = glm::vec2((ndc.x * 0.5f + 0.5f) * screenW, (ndc.y * 0.5f + 0.5f) * screenH);
    return true;
}

/// How far along the ray its closest approach to `point` is.
float rayClosestT(const wowee::rendering::Ray& ray, const glm::vec3& point) {
    return glm::dot(point - ray.origin, ray.direction);
}

/// Distance from the ray to the point where it passes closest to `point`.
float rayMissDistance(const wowee::rendering::Ray& ray, const glm::vec3& point) {
    const float t = rayClosestT(ray, point);
    if (t < 0.0f) return glm::length(point - ray.origin);
    return glm::length((ray.origin + ray.direction * t) - point);
}

// ---- the ray ----------------------------------------------------------------------------

void testRayReturnsThePixelItCameFrom() {
    constexpr float kScreenW = 1908.0f;
    constexpr float kScreenH = 999.0f;

    wowee::rendering::Camera camera;
    camera.setFov(60.0f);
    camera.setAspectRatio(kScreenW / kScreenH);
    camera.setClipPlanes(0.1f, 3000.0f);
    // A third-person camera behind the player, looking along +X: yaw 0 faces
    // +X in render space and the pitch leans down at the ground.
    camera.setPosition(glm::vec3(-6.0f, 0.0f, 3.0f));
    camera.setRotation(0.0f, -12.0f);

    // A questgiver a few yards in front of the player, standing on the ground.
    const CreatureBounds creature{glm::vec3(0.0f, 0.0f, 1.0f), 0.7f};

    glm::vec2 pixel{};
    require(projectToPixel(camera, creature.centre, kScreenW, kScreenH, pixel),
            "a creature in front of the camera projects onto the screen");
    require(pixel.x > 0.0f && pixel.x < kScreenW && pixel.y > 0.0f && pixel.y < kScreenH,
            "the creature projects inside the window, so it can be clicked");

    const wowee::rendering::Ray ray =
        camera.screenToWorldRay(pixel.x, pixel.y, kScreenW, kScreenH);

    // The ray is the other half of the click: from the creature's own pixel it
    // has to arrive at the creature, or nothing under the cursor is ever hit.
    closeTo(rayMissDistance(ray, creature.centre), 0.0f, 1e-3f,
            "the ray from the creature's pixel passes through its bounds centre");
    require(glm::dot(glm::normalize(creature.centre - ray.origin), ray.direction) > 0.9f,
            "the ray from the creature's pixel runs towards it");
}

void testPickHitsInsideBoundsAndMissesOutside() {
    constexpr float kScreenW = 1908.0f;
    constexpr float kScreenH = 999.0f;

    wowee::rendering::Camera camera;
    camera.setFov(60.0f);
    camera.setAspectRatio(kScreenW / kScreenH);
    camera.setClipPlanes(0.1f, 3000.0f);
    camera.setPosition(glm::vec3(-6.0f, 0.0f, 3.0f));
    camera.setRotation(0.0f, -12.0f);

    const CreatureBounds creature{glm::vec3(0.0f, 0.0f, 1.0f), 0.7f};
    const float pickRadius = pickRadiusFor(creature);
    require(pickRadius >= 1.0f, "a unit's pick sphere has the picker's one-yard floor");

    glm::vec2 onCreature{};
    require(projectToPixel(camera, creature.centre, kScreenW, kScreenH, onCreature),
            "the creature projects onto the screen");

    // Inside the bounds: the click the player means.
    const wowee::rendering::Ray onRay =
        camera.screenToWorldRay(onCreature.x, onCreature.y, kScreenW, kScreenH);
    float hitT = -1.0f;
    require(wowee::ui::raySphereIntersect(onRay, creature.centre, pickRadius, hitT),
            "a ray cast at the creature's pixel hits its bounds sphere");
    // The ray passes through the centre here, so it enters the sphere a whole
    // radius short of the creature itself.
    closeTo(hitT + pickRadius, rayClosestT(onRay, creature.centre), 0.05f,
            "the hit is reported where the ray meets the creature's bounds");

    // Outside the bounds: empty ground at the far corner of the window.
    float missT = -1.0f;
    require(!wowee::ui::raySphereIntersect(
                camera.screenToWorldRay(kScreenW - 2.0f, kScreenH - 2.0f, kScreenW, kScreenH),
                creature.centre, pickRadius, missT),
            "a ray cast into empty ground misses the creature");

    // A creature the ray has already gone past is not picked again.
    const glm::vec3 past = creature.centre + camera.getForward() * 20.0f;
    float behindT = -1.0f;
    require(!wowee::ui::raySphereIntersect({past, camera.getForward()}, creature.centre,
                                           pickRadius, behindT),
            "a creature behind the ray origin is not picked");

    // And the sphere test agrees with the triangle test the world's collision
    // queries are built on, so the two cannot be describing different shapes.
    // Axis-aligned on purpose: the question is the two helpers, not the camera.
    const float r = pickRadius;
    const glm::vec3 axisRay(-30.0f, 0.0f, 0.0f);
    const glm::vec3 axisDir(1.0f, 0.0f, 0.0f);
    const glm::vec3 v0(-r, -r, -r);
    const glm::vec3 v1(-r, r, -r);
    const glm::vec3 v2(-r, r, r);
    const glm::vec3 v3(-r, -r, r);
    const float triangleT = wowee::rendering::rayTriangleIntersect(axisRay, axisDir, v0, v1, v2);
    const float triangle2T = wowee::rendering::rayTriangleIntersect(axisRay, axisDir, v0, v2, v3);
    require(triangleT > 0.0f || triangle2T > 0.0f,
            "the known-good triangle test reaches the face of the bounds box");
    float sphereT = -1.0f;
    require(wowee::ui::raySphereIntersect({axisRay, axisDir}, glm::vec3(0.0f), r, sphereT),
            "the picker's sphere test reaches the same box");
    closeTo(sphereT, 30.0f - r, 0.01f,
            "sphere and triangle tests agree on where the bounds are entered");
    closeTo(sphereT, triangleT > 0.0f ? triangleT : triangle2T, 0.01f,
            "sphere and triangle tests agree on where the bounds are entered");
}

// ---- what the pick does with what it hit -------------------------------------------------

void testResolve() {
    using wowee::ui::ScenePick;
    constexpr uint64_t kNpc = 0xF130000001ull;
    constexpr uint64_t kStall = 0xF110000002ull;
    constexpr uint64_t kWolf = 0xF130000003ull;
    constexpr uint64_t kCorpse = 0xF130000004ull;

    // Nothing under the cursor is nothing, and says so rather than picking the
    // nearest thing to the player.
    ScenePick empty;
    require(empty.resolve() == 0u, "an empty pick resolves to nothing");

    // The NPC a questgiver is: a living unit, alone under the cursor.
    ScenePick npcOnly;
    npcOnly.livingUnitGuid = kNpc;
    npcOnly.livingUnitCenterT = 8.0f;
    require(npcOnly.resolve() == kNpc, "a lone living unit under the cursor is the click");

    // A wide object beside it must not swallow it.
    ScenePick unitAndObject = npcOnly;
    unitAndObject.closestGuid = kStall;
    unitAndObject.closestT = 6.0f;
    unitAndObject.objectGuid = kStall;
    unitAndObject.objectCenterT = 8.5f;
    require(unitAndObject.resolve() == kNpc, "a unit wins an object beside it");
    require(unitAndObject.closestGuid != unitAndObject.resolve(),
            "resolve() is not the nearest entry point, which is what the affordance must not ask");

    // An object clearly in front takes the click - a mailbox between the player
    // and the NPC is what the player meant.
    unitAndObject.objectCenterT = 5.0f;
    require(unitAndObject.resolve() == kStall, "an object clearly in front takes the click");

    // A hostile outranks everything else under the cursor.
    ScenePick hostile = npcOnly;
    hostile.hostileUnitGuid = kWolf;
    hostile.hostileUnitT = 9.0f;
    require(hostile.resolve() == kWolf, "a hostile outranks the rest");

    // A corpse is picked only when nothing living is there, so a player
    // standing on a body is still clickable.
    ScenePick corpse;
    corpse.deadUnitGuid = kCorpse;
    corpse.deadUnitCenterT = 5.0f;
    require(corpse.resolve() == kCorpse, "a corpse is picked when it is the only thing there");
    corpse.livingUnitGuid = kNpc;
    corpse.livingUnitCenterT = 7.0f;
    require(corpse.resolve() == kNpc, "someone standing on a body takes the click back");
}

// ---- the edges the click arrives on ------------------------------------------------------

/// The frame loop, as the client runs it: drain the events, then update().
struct Frame {
    void pump() {
        // Headless, so the queue is never drained by SDL itself; the tests hand
        // the events straight to Input, which is what the loop's call does.
        wowee::core::Input::getInstance().update();
    }
    wowee::core::Input& input() { return wowee::core::Input::getInstance(); }
};

void testEdgesFromEventsSurviveAPollThatMissedThem() {
    // The dummy video driver: Input::update() asks SDL for the keyboard and the
    // mouse, and neither answers for a machine with no window. That is the point
    // - the poll sees a button that is up, and only the event says otherwise.
    SDL_SetHint(SDL_HINT_VIDEODRIVER, "dummy");
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        std::fprintf(stderr, "FAIL scene_pick_ray: SDL_Init: %s\n", SDL_GetError());
        ++failures;
        return;
    }

    Frame frame;
    auto& input = frame.input();
    constexpr int kLeft = SDL_BUTTON_LEFT;
    constexpr int kRight = SDL_BUTTON_RIGHT;
    constexpr float kX = 812.0f;
    constexpr float kY = 466.0f;

    // A quiet frame edges nothing.
    input.clearVirtualKeys();
    frame.pump();
    require(!input.isMouseButtonJustPressed(kLeft), "a frame with no press is not a press");
    require(!input.isMouseButtonJustReleased(kLeft), "a frame with no release is not a release");

    // The regression: a whole click - press and release - inside one frame. The
    // poll sees the button up on both sides of it, so without the events there
    // is no press to answer and no release to answer: no click.
    input.noteMouseButtonEvent(kLeft, true, static_cast<int>(kX), static_cast<int>(kY));
    input.noteMouseButtonEvent(kLeft, false, static_cast<int>(kX), static_cast<int>(kY));
    frame.pump();
    require(input.isMouseButtonJustPressed(kLeft),
            "a press the poll missed is still a press");
    require(input.isMouseButtonJustReleased(kLeft),
            "a release the poll missed is still a release, so the click is acted on");
    closeTo(input.getMousePosition().x, kX, 0.5f,
            "the pointer is where the event left it, not where the poll found it");
    closeTo(input.getMousePosition().y, kY, 0.5f,
            "the pointer is where the event left it, not where the poll found it");

    // A click is one click: the frame after it is quiet again.
    frame.pump();
    require(!input.isMouseButtonJustPressed(kLeft), "the press is not reported a second time");
    require(!input.isMouseButtonJustReleased(kLeft), "the release is not reported a second time");

    // A click spread over two frames - which is what a click looks like at any
    // frame rate worth the name - still answers the way GameScreen asks for it:
    // the press on the frame it went down, the release on the frame it came up.
    input.noteMouseButtonEvent(kLeft, true, static_cast<int>(kX), static_cast<int>(kY));
    frame.pump();
    require(input.isMouseButtonJustPressed(kLeft), "the press lands on the frame it went down");
    require(!input.isMouseButtonJustReleased(kLeft), "and not the release with it");
    input.noteMouseButtonEvent(kLeft, false, static_cast<int>(kX), static_cast<int>(kY));
    frame.pump();
    require(!input.isMouseButtonJustPressed(kLeft), "and the press is not repeated");
    require(input.isMouseButtonJustReleased(kLeft), "the release lands on the frame it came up");
    frame.pump();
    require(!input.isMouseButtonJustReleased(kLeft), "and is reported once");

    // A press on its own is a press, and the frame after it is not.
    input.noteMouseButtonEvent(kLeft, true, 100, 100);
    frame.pump();
    require(input.isMouseButtonJustPressed(kLeft), "a press on its own is a press");
    frame.pump();
    require(!input.isMouseButtonJustPressed(kLeft), "and it is one press, not a held one");

    // A release on its own is a release, and the frame after it is not.
    input.noteMouseButtonEvent(kLeft, false, 100, 100);
    frame.pump();
    require(input.isMouseButtonJustReleased(kLeft), "a release on its own is a release");
    frame.pump();
    require(!input.isMouseButtonJustReleased(kLeft), "and it is one release");

    // The two buttons are kept apart, so a left click never answers for the
    // right one - which is what tells the picker a drag apart from a click.
    input.noteMouseButtonEvent(kLeft, true, 10, 10);
    frame.pump();
    require(!input.isMouseButtonJustReleased(kRight), "a left press is not a right release");
    require(!input.isMouseButtonJustPressed(kRight), "a left press is not a right press");
    input.noteMouseButtonEvent(kLeft, false, 10, 10);
    frame.pump();

    // The polled level still answers for a held button: nothing about this
    // changes what isMouseButtonPressed says.
    frame.pump();
    require(!input.isMouseButtonPressed(kLeft),
            "the level still comes from the poll, which reports up with no mouse");

    // A button number SDL does not define is refused rather than written past
    // the end of the arrays.
    input.noteMouseButtonEvent(0, true, 0, 0);
    input.noteMouseButtonEvent(999, true, 0, 0);
    frame.pump();
    require(!input.isMouseButtonJustPressed(0), "button 0 is not a button");

    SDL_Quit();
}

} // namespace

int main() {
    testRayReturnsThePixelItCameFrom();
    testPickHitsInsideBoundsAndMissesOutside();
    testResolve();
    testEdgesFromEventsSurviveAPollThatMissedThem();

    if (failures != 0) {
        std::fprintf(stderr, "%d scene_pick_ray check(s) failed\n", failures);
        return 1;
    }
    std::printf("scene_pick_ray: all checks passed\n");
    return 0;
}
