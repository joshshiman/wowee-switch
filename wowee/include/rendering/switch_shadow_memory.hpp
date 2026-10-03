#pragma once
#include <vulkan/vulkan.h>

#include "core/logger.hpp"

namespace wowee::rendering {

/// Which memory policy the shadow atlas could be given.
enum class SwitchShadowMemoryPolicy {
    /// DEVICE_LOCAL | HOST_VISIBLE and not HOST_CACHED: the host can read the
    /// depth image back without a staging copy. Switch Onion and Garlic both
    /// advertise DEVICE_LOCAL, and cached Onion is picked first by a plain
    /// GPU_ONLY preference, so the uncached type has to be asked for by name.
    UncachedHostVisible,
    /// Some DEVICE_LOCAL type, but none the host can read. Depth inspection is
    /// then unavailable - it is a WOWEE_PS4-only facility, so nothing that runs
    /// here needs it, and refusing to boot over it is the wrong trade.
    DeviceLocalOnly,
    /// No device-local memory at all: nothing to fall back to.
    Unavailable,
};

struct SwitchShadowMemoryChoice {
    uint32_t memoryTypeBits = 0;
    SwitchShadowMemoryPolicy policy = SwitchShadowMemoryPolicy::Unavailable;
};

/// Pick the narrowest memory mask that still lets the renderer start.
inline SwitchShadowMemoryChoice ChooseSwitchShadowMemoryType(
    const VkPhysicalDeviceMemoryProperties& props) {
    SwitchShadowMemoryChoice choice;
    for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
        const auto flags = props.memoryTypes[i].propertyFlags;
        constexpr auto uncachedHostVisible =
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
        const bool deviceLocal = (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0;
        const bool uncached =
            deviceLocal && (flags & uncachedHostVisible) == uncachedHostVisible &&
            !(flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
        const bool cached = deviceLocal && (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
        const uint32_t bit = 1u << i;
        if (uncached) {
            // Best kind: keep the mask to the uncached types so a cached one can
            // never be chosen for the atlas.
            choice.memoryTypeBits |= bit;
            choice.policy = SwitchShadowMemoryPolicy::UncachedHostVisible;
        } else if (cached && choice.policy == SwitchShadowMemoryPolicy::Unavailable) {
            // Remembered as a fallback, but a later uncached type still wins.
            choice.memoryTypeBits |= bit;
            choice.policy = SwitchShadowMemoryPolicy::DeviceLocalOnly;
        }
    }
    // Only DEVICE_LOCAL, uncached-ness irrelevant: what a host without an
    // uncached system heap (an emulator, for one) can offer.
    if (choice.memoryTypeBits == 0) {
        for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
            if (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
                choice.memoryTypeBits |= 1u << i;
            }
        }
        if (choice.memoryTypeBits != 0) {
            choice.policy = SwitchShadowMemoryPolicy::DeviceLocalOnly;
        }
    }
    return choice;
}

/// One line naming every memory type and its flags, for the boot log when the
/// preference cannot be met.
inline void LogSwitchMemoryTypes(const VkPhysicalDeviceMemoryProperties& props) {
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        const auto f = props.memoryTypes[i].propertyFlags;
        LOG_INFO("switch memory type ", i, " heap=", props.memoryTypes[i].heapIndex,
                 " flags=0x", static_cast<uint32_t>(f),
                 " (deviceLocal=", (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) ? 1 : 0,
                 " hostVisible=", (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) ? 1 : 0,
                 " hostCached=", (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) ? 1 : 0,
                 " hostCoherent=", (f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) ? 1 : 0, ")");
    }
}

}  // namespace wowee::rendering