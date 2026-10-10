#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>

#include "platform/switch/cpu_budget.hpp"

#if defined(__SWITCH__) || defined(WOWEE_SWITCH)
#include <switch.h>
#endif

namespace wowee::platform::switchport {

// Defined in platform/switch/system_switch.cpp (applet type + total RAM at
// startup). Forward-declared here so this header stays includable without
// pulling in switch_platform.hpp.
bool isAppletMode();

struct AvailableCpuMemory {
    size_t bytes = 0;
    int32_t status = 0;
    bool measured = false;
};

inline AvailableCpuMemory queryAvailableCpuMemory() {
#if defined(__SWITCH__) || defined(WOWEE_SWITCH)
    u64 used = 0;
    if (R_SUCCEEDED(svcGetInfo(&used, InfoType_UsedMemorySize, CUR_PROCESS_HANDLE, 0))) {
        // Available is (title cap - used), NOT (mapped - used).
        // InfoType_TotalMemorySize is the *currently mapped* heap, which
        // newlib grows on demand via sbrk - so (mapped - used) is heap slack,
        // a few MiB by design however much room the title still has. Reading
        // it as "free" pinned every headroom gate shut (fonts declined,
        // terrain held back, world entry rejected) in title-override mode
        // with gigabytes actually available. The caps are the real limits:
        // ~453 MB in the Album applet, ~3.25 GB under title override.
        constexpr u64 kAppletCapBytes = 448ull * 1024 * 1024;
        constexpr u64 kOverrideCapBytes = 3328ull * 1024 * 1024;
        const u64 cap = isAppletMode() ? kAppletCapBytes : kOverrideCapBytes;
        if (used >= cap) return {0, 0, true};
        return {static_cast<size_t>(cap - used), 0, true};
    }
    return {kCpuMemoryBudgetLimit, 0, false};
#else
    return {kCpuMemoryBudgetLimit, 0, false};
#endif
}

inline CompositeAdmission probeCompositeAdmission() noexcept {
    const auto free = queryAvailableCpuMemory();
    return compositeAdmissionFor(free.bytes, free.bytes, free.measured);
}

} // namespace wowee::platform::switchport
