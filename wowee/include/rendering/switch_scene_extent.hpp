#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vulkan/vulkan.h>

namespace wowee::rendering {

// The world is rendered into an off-screen target and sampled up to the
// console's native output, so its height is a quality setting rather than a
// display mode: the UI, the menus and VideoOut all stay at 1080p either way.
//
// Bounded, predictable sizes only. An invalid or missing value selects the
// performance default; "native" keeps whatever output size VideoOut supplied.
inline uint32_t parseSwitchSceneHeight(const char* value) noexcept {
    if (value && (std::strcmp(value, "native") == 0 || std::strcmp(value, "1080") == 0))
        return 0;
    // Any other plain number is a world height (360/480/720/900...), clamped to
    // the supported range. Previously only "900" was recognised and every other
    // number fell through to the default, so "480" matched 480 only by
    // coincidence and "720" never worked at all.
    if (value && value[0] != '\0') {
        char* end = nullptr;
        const long parsed = std::strtol(value, &end, 10);
        if (end && end != value && *end == '\0' && parsed > 0)
            return static_cast<uint32_t>(std::clamp(parsed, 360L, 2160L));
    }
#ifdef WOWEE_SWITCH
    // In-world frames are ~240 ms of GPU fill at 720p with shadows, volumetric
    // and bloom all off (run 56) — fill is what's left, so the default world
    // height is 360 (UI/menus stay native). 360 is the performance default;
    // 480 and 720 are the quality options the video menu offers above it. FSR1
    // is blocked on nxvk, so this profile is the render-scale lever. Raisable
    // at runtime in the video options; the env var still seeds it. (540 first,
    // then 480 chasing the 15 fps target alongside the object-distance cuts,
    // now 360 as the shipped default.)
    return 360;
#else
    return 720;
#endif
}

// B39: selectable at runtime.
//
// This used to be a function-local static read once from the environment, so
// the only way to change the world resolution was to relaunch with a different
// variable - which is not a setting a player on a console can reach. The value
// now lives in an atomic that the video options write, and
// PostProcessPipeline::desiredSceneExtent() already re-reads it every frame
// and prepares an extent change before the next frame is recorded, so a change
// takes effect on the next frame rather than the next launch.
//
// The environment variable still seeds the initial value, so every existing
// launch script and note keeps working.
namespace detail {
inline std::atomic<uint32_t>& SwitchSceneHeightCell() noexcept {
    static std::atomic<uint32_t> height{
        parseSwitchSceneHeight(std::getenv("WOWEE_SWITCH_SCENE_HEIGHT"))};
    return height;
}
} // namespace detail

inline uint32_t configuredSwitchSceneHeight() noexcept {
    return detail::SwitchSceneHeightCell().load(std::memory_order_relaxed);
}

// 0 means native. Any other value is clamped into the supported range rather
// than trusted: this is reached from the interface, and an out-of-range height
// would allocate a scene target the console cannot afford. The floor is the
// 360 performance default - the smallest profile the video menu offers - so a
// selection can never fall below it.
inline void setSwitchSceneHeight(uint32_t height) noexcept {
    if (height != 0) height = std::clamp(height, 360u, 2160u);
    detail::SwitchSceneHeightCell().store(height, std::memory_order_relaxed);
}

inline VkExtent2D fitSwitchSceneExtent(VkExtent2D output, uint32_t heightLimit) noexcept {
    if (!output.width || !output.height || !heightLimit || output.height <= heightLimit)
        return output;
    const uint32_t width = static_cast<uint32_t>(
        (static_cast<uint64_t>(output.width) * heightLimit) / output.height);
    return {std::max(1u, width), heightLimit};
}

} // namespace wowee::rendering
