#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>

#include "platform/switch/cpu_budget.hpp"

#if defined(__SWITCH__) || defined(WOWEE_SWITCH)
#include <switch.h>
#endif

namespace wowee::platform::switchport {

struct AvailableCpuMemory {
    size_t bytes = 0;
    int32_t status = 0;
    bool measured = false;
};

inline AvailableCpuMemory queryAvailableCpuMemory() {
#if defined(__SWITCH__) || defined(WOWEE_SWITCH)
    u64 total = 0, used = 0;
    Result rcTotal = svcGetInfo(&total, InfoType_TotalMemorySize, CUR_PROCESS_HANDLE, 0);
    Result rcUsed = svcGetInfo(&used, InfoType_UsedMemorySize, CUR_PROCESS_HANDLE, 0);
    if (R_SUCCEEDED(rcTotal) && R_SUCCEEDED(rcUsed) && total > used) {
        size_t freeBytes = static_cast<size_t>(total - used);
        return {freeBytes, 0, true};
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
