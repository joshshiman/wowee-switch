#pragma once
#include <vulkan/vulkan.h>

#include <cstdint>

namespace wowee::rendering {

/// A memory type that satisfies `bits`, preferring one that also has
/// `preferred`.
///
/// `preferred` is a preference, never a requirement. Images and buffers are
/// legal in any memory the resource reports as compatible, and a driver is not
/// obliged to publish a device-local heap: the Switch exposes its heaps through
/// NVK, and an emulator hosting guest VRAM as host memory publishes one
/// host-visible heap and no device-local one at all. Requiring the preferred
/// flags there does not degrade the allocation, it deletes the resource.
///
/// Returns UINT32_MAX only when no compatible type exists at all. `fellBack` is
/// set when the preference could not be met, so a caller can say so once rather
/// than guess from a later failure.
inline uint32_t chooseMemoryType(VkPhysicalDevice physical, uint32_t bits,
                                 VkMemoryPropertyFlags preferred, bool* fellBack = nullptr) {
    if (fellBack) *fellBack = false;
    VkPhysicalDeviceMemoryProperties properties{};
    vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    uint32_t any = UINT32_MAX;
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((bits & (1u << i)) == 0) continue;
        if (any == UINT32_MAX) any = i;
        if ((properties.memoryTypes[i].propertyFlags & preferred) == preferred) return i;
    }
    if (any != UINT32_MAX && fellBack) *fellBack = true;
    return any;
}

}  // namespace wowee::rendering