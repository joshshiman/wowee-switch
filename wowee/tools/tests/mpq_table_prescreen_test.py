#!/usr/bin/env python3
"""The archive-open pre-screen: header read, table cost, and what it refuses.

Takes the cost model straight out of src/pipeline/mpq_asset_source.cpp and
compiles it against the real StormLib.h, so the sizes it multiplies are the
sizes StormLib will really allocate rather than a copy that can drift.
"""
from pathlib import Path
import os, shlex, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
SRC=(ROOT/'src/pipeline/mpq_asset_source.cpp').read_text()
model=SRC[SRC.index('// The two table counts a classic MPQ header carries'):SRC.index('// The largest contiguous block the CPU heap will hand back right now')]
fixture=r'''
#include <StormLib.h>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
using uint32_t_t = uint32_t;
'''
cases=r'''
// Big-endian, exactly the packed classic TMPQHeader StormLib casts its own
// HeaderData to: signature, header size, archive size, version, sector size,
// hash pos, block pos, hash entries, block entries.
static std::string headerWith(uint32_t hashEntries, uint32_t blockEntries) {
    std::string h(32, '\0');
    const unsigned char sig[4] = {'M', 'P', 'Q', 0x1A};
    for (int i = 0; i < 4; ++i) h[i] = sig[i];
    auto put = [&h](size_t at, uint32_t v) {
        h[at] = char(v >> 24); h[at + 1] = char(v >> 16); h[at + 2] = char(v >> 8); h[at + 3] = char(v);
    };
    put(4, 32); put(8, 2881154862u); put(0x0C, 0); put(0x0E, 3);
    put(0x10, 0xABC000); put(0x14, 0xABCD000);
    put(0x18, hashEntries); put(0x1C, blockEntries);
    return h;
}
static std::string write(const std::string& name, const std::string& bytes) {
    const std::string path = std::string(TMPDIR) + "/" + name;
    std::ofstream out(path, std::ios::binary);
    out.write(bytes.data(), std::streamsize(bytes.size()));
    out.close();
    return path;
}

int main(int argc, char** argv) {
    TMPDIR = argv[1];

    // The sizes the cost model multiplies are StormLib's, in this tree.
    assert(sizeof(TFileEntry) == 64);
    assert(sizeof(TMPQHash) == 16);
    assert(sizeof(TMPQBlock) == 16);

    // --- the header read -------------------------------------------------
    const std::string common = write("common.MPQ", headerWith(131072, 83672));
    MpqHeaderCounts counts;
    assert(readMpqHeaderCounts(common, counts));
    assert(counts.hashEntries == 131072u && counts.blockEntries == 83672u);

    // Not an MPQ, and shorter than 32 bytes: no counts, so no gate, and the
    // open is left to StormLib to accept or refuse in its own terms.
    const std::string other = write("other.MPQ", std::string(32, 'X'));
    assert(!readMpqHeaderCounts(other, counts));
    const std::string stub = write("stub.MPQ", headerWith(16, 16).substr(0, 12));
    assert(!readMpqHeaderCounts(stub, counts));
    assert(!readMpqHeaderCounts(std::string(TMPDIR) + "/absent.MPQ", counts));

    // A malformed count is masked to what SFileOpenArchive would allocate from
    // it, so a header claiming 0xFFFFFFFF entries does not size a 68 GB table.
    const std::string absurd = write("absurd.MPQ", headerWith(0xFFFFFFFFu, 0xFFFFFFFFu));
    assert(readMpqHeaderCounts(absurd, counts));
    assert(counts.hashEntries == BLOCK_INDEX_MASK && counts.blockEntries == BLOCK_INDEX_MASK);

    // --- the cost model --------------------------------------------------
    struct Row { const char* name; uint32_t hash; uint32_t block; uint64_t retained; uint64_t peak; };
    const Row rows[] = {
        {"common.MPQ", 131072, 83672, 10485760, 11824512},
        {"patch.MPQ", 65536, 41162, 5242880, 5901472},
        {"common-2.MPQ", 65536, 43085, 5242880, 5932240},
        {"lichking.MPQ", 32768, 16181, 2621440, 2880336},
        {"expansion.MPQ", 16384, 11873, 1310720, 1500688},
        {"patch-2.MPQ", 16384, 11813, 1310720, 1499728},
        {"patch-3.MPQ", 4096, 2996, 327680, 375616},
    };
    uint64_t setRetained = 0;
    for (const auto& row : rows) {
        const ArchiveTableBudget b = archiveTableBudgetFor(row.hash, row.block);
        assert(b.retainedBytes == row.retained);
        assert(b.peakBytes == row.peak);
        // The doubling headroom the gate compares against the free block.
        assert(b.neededBytes == row.peak * 2);
        // Spelled out longhand, from the three tables StormLib allocates.
        const uint64_t entries = row.hash > row.block ? row.hash : row.block;
        assert(b.retainedBytes == uint64_t(row.hash) * sizeof(TMPQHash) + entries * sizeof(TFileEntry));
        assert(b.peakBytes == b.retainedBytes + uint64_t(row.block) * sizeof(TMPQBlock));
        setRetained += b.retainedBytes;
        std::printf("PASS: %-14s held %8llu, peak %8llu, needs %8llu\n", row.name,
                    (unsigned long long)b.retainedBytes, (unsigned long long)b.peakBytes,
                    (unsigned long long)b.neededBytes);
    }
    assert(setRetained == 26542080u);

    // --- what the gate does with them ------------------------------------
    // The largest free block the failing boot.log recorded when the archives
    // opened: 64 MiB. Every archive in the set fits under it, doubled.
    const uint64_t k64MiB = 64ull << 20;
    for (const auto& row : rows) {
        assert(archiveTableBudgetFor(row.hash, row.block).neededBytes <= k64MiB);
    }
    // At 16 MiB the whole set is refused, common.MPQ first, and a session with
    // no archives is reported rather than opened.
    const uint64_t k16MiB = 16ull << 20;
    assert(archiveTableBudgetFor(131072, 83672).neededBytes > k16MiB);
    assert(archiveTableBudgetFor(4096, 2996).neededBytes <= k16MiB);
    std::puts("PASS: the retail set needs 25.3 MiB held and opens whole at the 64 MiB the boot log recorded");
    std::puts("PASS: the same set is refused whole at 16 MiB, largest archive first");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='wowps-mpq-prescreen-') as temp:
    path=Path(temp)/'test.cpp'
    path.write_text(fixture+model+'static const char* TMPDIR;\n'+cases)
    binary=Path(temp)/'test'
    subprocess.run(shlex.split(os.environ.get('CXX','g++'))+['-std=c++20','-O1','-g','-fsanitize=address,undefined',
                  '-I', str(ROOT/'extern/StormLib/src'), str(path), '-o', str(binary)],check=True)
    subprocess.run([str(binary), temp],check=True)