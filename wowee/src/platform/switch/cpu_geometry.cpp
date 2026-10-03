#include "platform/cpu_geometry.hpp"
#include <atomic>
#include <cstdint>
#include <cstdlib>

namespace wowee::platform {
namespace {
constexpr size_t pageBytes = 16 * 1024;
struct alignas(std::max_align_t) Mapping { size_t bytes; };
std::atomic<size_t> mapped{0}, peak{0}, failures{0};
[[noreturn]] void fail() { failures.fetch_add(1, std::memory_order_relaxed); throw std::bad_alloc(); }
}
CpuGeometryStats cpuGeometryStats() noexcept {
    return {mapped.load(std::memory_order_relaxed), peak.load(std::memory_order_relaxed),
            failures.load(std::memory_order_relaxed)};
}
void* allocateCpuGeometry(size_t bytes) {
    if (bytes < kCpuGeometryThreshold) return ::operator new(bytes);
    if (bytes > kCpuGeometryLimit - sizeof(Mapping) - pageBytes) fail();
    const size_t rounded = (bytes + sizeof(Mapping) + pageBytes - 1) & ~(pageBytes - 1);
    size_t before = mapped.load(std::memory_order_relaxed);
    do {
        if (before > kCpuGeometryLimit - rounded) fail();
    } while (!mapped.compare_exchange_weak(before, before + rounded, std::memory_order_relaxed));
    // The Switch heap (__nx_heap_size) is the single contiguous arena; page
    // granularity is plenty for geometry buffers, and the quota keeps one
    // terrain upload from starving Lua/asset paths.
    void* pointer = std::aligned_alloc(pageBytes, rounded);
    if (!pointer) { mapped.fetch_sub(rounded, std::memory_order_relaxed); fail(); }
    auto* header = new (pointer) Mapping{rounded};
    size_t previous = peak.load(std::memory_order_relaxed);
    const size_t current = mapped.load(std::memory_order_relaxed);
    while (previous < current && !peak.compare_exchange_weak(previous, current, std::memory_order_relaxed)) {}
    return static_cast<void*>(header + 1);
}
void freeCpuGeometry(void* pointer, size_t bytes) noexcept {
    if (!pointer) return;
    if (bytes < kCpuGeometryThreshold) { ::operator delete(pointer); return; }
    auto* header = static_cast<Mapping*>(pointer) - 1;
    const Mapping allocation = *header;
    std::free(header);
    mapped.fetch_sub(allocation.bytes, std::memory_order_relaxed);
}
} // namespace wowee::platform
