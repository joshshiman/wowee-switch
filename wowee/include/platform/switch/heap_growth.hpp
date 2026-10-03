#pragma once
#include <cstddef>
#include <cstdint>

namespace wowee::platform::switchport {

// The Switch homebrew heap is one contiguous arena (__nx_heap_size), so
// there is no mmap-extension growth to budget against. The stats shape is
// kept so the existing instrumentation in application.cpp, addon_manager.cpp
// and renderer.cpp compiles unchanged; the values stay at zero.
inline constexpr std::size_t kHeapPageBytes = 64 * 1024;
inline constexpr std::size_t kHeapGrowthReserveBytes = 0;

struct HeapGrowthStats {
    std::size_t mappedBytes;   // Cumulative arena mappings, NOT live allocations.
    std::size_t extensions;
    std::size_t largestMapping;
    std::size_t mappingFailures;
};
inline HeapGrowthStats heapGrowthStats() noexcept { return {0, 0, 0, 0}; }
} // namespace wowee::platform::switchport
