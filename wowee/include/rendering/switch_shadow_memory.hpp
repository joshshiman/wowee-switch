#pragma once
#include <ios>

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
    /// No DEVICE_LOCAL type at all, only host-visible system memory. Images
    /// are legal there and render correctly; they are simply not cached by the
    /// GPU's texture units, which costs bandwidth.
    HostVisibleOnly,
    /// The driver reported no memory types whatsoever.
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
        const uint32_t bit = 1u << i;
        if (uncached) {
            // Best kind: keep the mask to the uncached types so a cached one can
            // never be chosen for the atlas.
            choice.memoryTypeBits |= bit;
            choice.policy = SwitchShadowMemoryPolicy::UncachedHostVisible;
        } else if (deviceLocal && choice.policy == SwitchShadowMemoryPolicy::Unavailable) {
            // Remembered as a fallback; a later uncached type still wins.
            choice.memoryTypeBits |= bit;
            choice.policy = SwitchShadowMemoryPolicy::DeviceLocalOnly;
        }
    }
    if (choice.memoryTypeBits == 0) {
        for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
            const auto flags = props.memoryTypes[i].propertyFlags;
            if ((flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) ||
                (flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
                choice.memoryTypeBits |= 1u << i;
                choice.policy = SwitchShadowMemoryPolicy::HostVisibleOnly;
            }
        }
    }
    return choice;
}

/// One line per memory type with its flags. WARNING, not INFO: this is only
/// called when the preference could not be met, and the caller's log level may
/// well be hiding INFO.
inline void LogSwitchMemoryTypes(const VkPhysicalDeviceMemoryProperties& props) {
    LOG_WARNING("switch memory: ", props.memoryTypeCount, " type(s) in ",
                props.memoryHeapCount, " heap(s)");
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        const auto raw = static_cast<uint32_t>(props.memoryTypes[i].propertyFlags);
        const auto f = props.memoryTypes[i].propertyFlags;
        // Both forms: the decimal value is what a reader can compare against
        // VkMemoryPropertyFlags, and the hex is what belongs in a bug report.
        LOG_WARNING("switch memory type ", i, " heap=", props.memoryTypes[i].heapIndex,
                    " flags=", raw, " (0x", std::hex, raw, std::dec,
                    ") deviceLocal=", (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) ? 1 : 0,
                    " hostVisible=", (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) ? 1 : 0,
                    " hostCoherent=", (f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) ? 1 : 0,
                    " hostCached=", (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) ? 1 : 0,
                    " lazilyAllocated=", (f & VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT) ? 1 : 0);
    }
    for (uint32_t i = 0; i < props.memoryHeapCount; ++i) {
        LOG_WARNING("switch memory heap ", i, " size=", props.memoryHeaps[i].size,
                    " flags=", static_cast<uint32_t>(props.memoryHeaps[i].flags));
    }
}

}  // namespace wowee::rendering