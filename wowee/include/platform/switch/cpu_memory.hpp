#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>

// The budgets, and the decisions taken from them. They moved into their own
// header because this one cannot be compiled anywhere but the console - the
// include above is the whole reason - and a memory policy that no test can
// execute is a policy nobody ever checks. Every existing user of
// kCpuMemoryBudgetLimit and its neighbours keeps including this file and keeps
// seeing them.
#include "platform/switch/cpu_budget.hpp"

namespace wowee::platform::switchport {

struct AvailableCpuMemory {
    size_t bytes = 0;
    int32_t status = 0;
    bool measured = false;
};

// The Switch has no flexible-memory ABI like the PS4 to query. Ask by
// mapping: probe with a descending ladder of blocks, writing both ends of
// each so the number is backed by real pages and a compiler cannot delete
// the probe. This tracks the residency of the title heap (~3 GiB) versus
// what's already committed by Lua, assets and gameplay paths.
inline std::size_t probeLargestHeapBlock(const std::size_t* sizes, std::size_t count) noexcept {
    for (std::size_t i = 0; i < count; ++i) {
        if (sizes[i] == 0) continue;
        void* block = std::malloc(sizes[i]);
        if (!block) continue;
        volatile unsigned char* bytes = static_cast<volatile unsigned char*>(block);
        bytes[0] = 0;
        bytes[sizes[i] - 1] = 0;
        std::free(block);
        return sizes[i];
    }
    return 0;
}

/// The largest of `sizes` the C++ heap will actually hand back right now.
///
/// Asked by asking. This toolchain's libc offers no arena statistics at all -
/// its <malloc.h> declares malloc, calloc, realloc, free, valloc, memalign and
/// malloc_usable_size, and nothing else; there is no mallinfo to call and no
/// free-list to walk. The alternative to a probe is therefore not a better
/// measurement, it is the flexible-page residue again, which is what put a
/// headroom gate in front of an allocation it does not measure.
///
/// The probe is cheap and it is clean. Every size here is far above musl's
/// mmap threshold, so malloc serves it by mapping the block whole and free
/// unmaps it: the arena is not grown, nothing is left in a bin, and the answer
/// is about the same mechanism that fails - one contiguous mapping of exactly
/// this many bytes, or nullptr.
///
/// Both ends are written before the block is released. Flexible memory is
/// committed at map time on this platform, so a returned pointer is already
/// backed; the writes cost two page faults and remove any question of a lazy
/// mapping answering yes on memory that is not there. They are volatile
/// because an untouched malloc/free pair is a thing a compiler may delete.
inline AvailableCpuMemory queryAvailableCpuMemory() {
    const std::size_t ladder[] = {
        512u * 1024u * 1024u, 256u * 1024u * 1024u, 128u * 1024u * 1024u,
        64u * 1024u * 1024u, 32u * 1024u * 1024u, 16u * 1024u * 1024u,
        8u * 1024u * 1024u, 4u * 1024u * 1024u
    };
    const std::size_t largest = probeLargestHeapBlock(ladder, sizeof(ladder) / sizeof(ladder[0]));
    return {largest < kCpuMemoryBudgetLimit ? largest : kCpuMemoryBudgetLimit, 0, largest != 0};
}

/// What a character skin composite may cost right now.
///
/// One probe in the common case: 4 MiB is what a 1024 atlas needs in one piece,
/// and a console with room says yes to it immediately. The ladder below only
/// runs when that fails, which is exactly when the answer matters.
inline CompositeAdmission probeCompositeAdmission() noexcept {
    const std::size_t ladder[] = {compositeBytesFor(kCompositeEdgeFull),
                                  compositeBytesFor(kCompositeEdgeHalf),
                                  compositeBytesFor(kCompositeEdgeMin)};
    const std::size_t largest =
        probeLargestHeapBlock(ladder, sizeof(ladder) / sizeof(ladder[0]));
    const auto free = queryAvailableCpuMemory();
    return compositeAdmissionFor(largest, free.bytes, free.measured);
}

} // namespace wowee::platform::switchport
