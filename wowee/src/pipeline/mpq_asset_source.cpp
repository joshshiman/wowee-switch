#include "pipeline/mpq_asset_source.hpp"
#include "pipeline/asset_read_bounds.hpp"
#include "core/logger.hpp"

#include <algorithm>
#include <set>
#include <limits>
#include <new>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <system_error>
#include <utility>
#ifdef WOWEE_SWITCH
#include "platform/switch/cpu_memory.hpp"
#include "platform/switch/switch_platform.hpp"
#endif

#if defined(WOWEE_MPQ_SOURCE_AVAILABLE)
#include "extractor.hpp"
#include <StormLib.h>
#endif

namespace wowee {
namespace pipeline {

#if defined(WOWEE_MPQ_SOURCE_AVAILABLE)

namespace {
struct MpqFileCloser {
    void operator()(void* file) const noexcept { if (file) SFileCloseFile(file); }
};
using MpqFileHandle = std::unique_ptr<void, MpqFileCloser>;

std::string lowerBackslash(std::string s) {
    for (char& c : s) {
        if (c == '/') c = '\\';
        else c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

// One breadcrumb per archive open, and one per open attempt's outcome. Fixed
// buffer, no allocation, and at most a couple of lines per archive, so the whole
// set costs a few dozen writes once per boot.
//
// This exists because the log level on the console is pinned to WARNING, so
// every LOG_INFO below - including the count of what opened - is suppressed and
// a boot that died between two archives left nothing at all between them. The
// breadcrumb goes through reportBootStage, which writes the boot log's open
// descriptor with snprintf and no lock, so it is still available when the heap
// is what has run out. Off the console there is a log file the user reads, so
// the breadcrumbs would be noise there and compile away.
void reportArchiveStage(const char* stage, const std::string& path, uint64_t bytes) {
#ifdef WOWEE_SWITCH
    char line[320];
    std::snprintf(line, sizeof line, "assets: archive %s %s (%llu bytes)", stage,
                  path.c_str(), static_cast<unsigned long long>(bytes));
    platform::switchport::reportBootStage(line);
#else
    (void)stage; (void)path; (void)bytes;
#endif
}

// The archive's size on the SD card, for the breadcrumb. Worth its own stat
// because the outcome line says nothing about what the open is about to ask
// for: StormLib sizes its file table from the header's table counts, not from
// the file's length, so two archives of very different size can cost the same
// and the interesting question - is this one missing, or is this one large -
// needs the number.
uint64_t archiveBytesOnDisk(const std::string& path) {
    std::error_code ec;
    const auto size = std::filesystem::file_size(path, ec);
    return ec ? 0 : static_cast<uint64_t>(size);
}

// StormLib builds an archive's hash, block and file tables when it opens the
// handle and keeps them for as long as the handle lives, and MpqAssetSource
// holds every handle for the whole session - so an archive's tables are a
// permanent charge, not a spike, and the charge is paid once per archive in the
// user's set. Every one of those three tables is sized from the header's own
// table counts rather than from the file's length, so a 2.9 GB common.MPQ and a
// 0.6 GB patch.MPQ differ by less than an order of magnitude in what the open
// asks the heap for.
//
// What the retail Data set asks for, from the headers on disk and the sizes
// StormLib actually allocates in this tree (sizeof(TFileEntry) is 64, not the
// ~272 an entry costs in a StormLib that stores the name inline - this fork
// keeps a pointer and no name, because MpqAssetSource opens with
// MPQ_OPEN_NO_LISTFILE and never builds one):
//
//   common.MPQ    hash 131072 block 83672   10.0 MiB held, 11.3 MiB at the peak
//   patch.MPQ     hash  65536 block 41162    5.0 MiB held,  5.6 MiB at the peak
//   common-2.MPQ  hash  65536 block 43085    5.0 MiB held,  5.7 MiB at the peak
//   lichking.MPQ  hash  32768 block 16181    2.5 MiB held,  2.8 MiB at the peak
//   expansion.MPQ hash  16384 block 11873    1.3 MiB held,  1.4 MiB at the peak
//   patch-2.MPQ   hash  16384 block 11813    1.3 MiB held,  1.4 MiB at the peak
//   patch-3.MPQ   hash   4096 block  2996    0.3 MiB held,  0.4 MiB at the peak
//   the set as opened by the seven that exist in a WotLK install  25.3 MiB
//
// So the set is affordable on its own terms and the arithmetic above is not by
// itself an explanation for a console dying inside the first open. It is still
// the only thing that decides whether an open is safe, because it is the one
// number available *before* the open, and the open is where the heap is spent.
//
// So the cost is charged twice. Once from the 32-byte header, before the open,
// against the largest block the console's allocator will actually hand back at
// that moment; and once from StormLib's own counts after the open, against a
// static ceiling. Either check can refuse an archive, and either refusal names
// the archive and both numbers and carries on with the rest of the set.
constexpr uint64_t kArchiveTableCeilingBytes = 48ull * 1024 * 1024;
constexpr uint64_t kTotalTableCeilingBytes = 96ull * 1024 * 1024;

uint64_t archiveTableBytes(void* archive) {
    uint64_t bytes = 0;
    DWORD entries = 0;
    if (SFileGetFileInfo(archive, SFileMpqFileTableSize, &entries, sizeof entries, nullptr)) {
        bytes += static_cast<uint64_t>(entries) * sizeof(TFileEntry);
    }
    if (SFileGetFileInfo(archive, SFileMpqHashTableSize, &entries, sizeof entries, nullptr)) {
        bytes += static_cast<uint64_t>(entries) * sizeof(TMPQHash);
    }
    return bytes;
}

// The two table counts a classic MPQ header carries, and nothing else. Read
// here rather than through StormLib because the whole point is to know what the
// open will cost before spending it.
struct MpqHeaderCounts {
    uint32_t hashEntries = 0;
    uint32_t blockEntries = 0;
};

// The first 32 bytes of a classic (format 0/1) archive, big-endian, laid out as
// the packed TMPQHeader in StormLib.h: signature, header size, archive size,
// format version, sector size, hash table position, block table position, hash
// table entries, block table entries. The retail Data set is entirely this
// shape; StormLib converts it to its own format-4 header afterwards.
bool readMpqHeaderCounts(const std::string& path, MpqHeaderCounts& out) {
    unsigned char header[32] = {};
    std::ifstream file(path, std::ios::binary);
    if (!file.read(reinterpret_cast<char*>(header), sizeof header)) return false;
    if (header[0] != 'M' || header[1] != 'P' || header[2] != 'Q' || header[3] != 0x1A) return false;
    const auto be32 = [&header](size_t at) {
        return (static_cast<uint32_t>(header[at]) << 24) | (static_cast<uint32_t>(header[at + 1]) << 16) |
               (static_cast<uint32_t>(header[at + 2]) << 8) | static_cast<uint32_t>(header[at + 3]);
    };
    // Masked because SFileOpenArchive masks these two fields itself before it
    // allocates anything out of them (BLOCK_INDEX_MASK), so the estimate has to
    // be of the table StormLib will really ask for rather than of the number a
    // malformed header carries.
    out.hashEntries = be32(0x18) & BLOCK_INDEX_MASK;
    out.blockEntries = be32(0x1C) & BLOCK_INDEX_MASK;
    return true;
}

// What one archive's tables cost, split by when the money is spent.
struct ArchiveTableBudget {
    uint64_t retainedBytes = 0;  ///< Held for as long as the handle is open.
    uint64_t peakBytes = 0;      ///< Live at the open's high-water mark.
    uint64_t neededBytes = 0;    ///< peakBytes doubled - see below.
};

// From the header's two counts, without opening anything.
//
// Three allocations, in the order BuildFileTable makes them, all of them live
// together at the moment the block table has been read and the file table has
// not yet been filled:
//
//   hash table   hashEntries * sizeof(TMPQHash)      16 an entry, retained
//   file table   max(hash, block) * sizeof(TFileEntry)  64 an entry, retained,
//                sized by the block count too because StormLib sizes it
//                max(dwBlockTableSize, dwMaxFileCount) and dwMaxFileCount is
//                the hash table size
//   block table  blockEntries * sizeof(TMPQBlock)     16 an entry, released
//                once the file table is built
//
// That is the peak. The multiplier on it is StormLib's own growth: the table is
// grown by realloc doubling, so the transient high-water mark of a table that
// ends up at S bytes is about 2S, and the cost of an open that the heap cannot
// absorb is paid at that doubling rather than at the final size. Requiring
// twice the peak against one contiguous block is what leaves room for it.
//
// The block table also covers the one allocation the file itself asks for and
// the model above does not name: when StormLib finds a table cut short by the
// end of the file it builds a block-table-sized translation table (4 bytes an
// entry) alongside the file table, which is well inside the doubling's spare
// half.
ArchiveTableBudget archiveTableBudgetFor(uint32_t hashEntries, uint32_t blockEntries) {
    const uint64_t entries = hashEntries > blockEntries ? hashEntries : blockEntries;
    ArchiveTableBudget budget;
    budget.retainedBytes = static_cast<uint64_t>(hashEntries) * sizeof(TMPQHash) +
                           entries * sizeof(TFileEntry);
    budget.peakBytes = budget.retainedBytes +
                       static_cast<uint64_t>(blockEntries) * sizeof(TMPQBlock);
    budget.neededBytes = budget.peakBytes * 2;
    return budget;
}

// The largest contiguous block the CPU heap will hand back right now, or 0
// where there is no such measurement to ask for. A ladder of real
// allocations, one short-lived probe per rung, so the answer is about the same
// mechanism that fails: one contiguous mapping of exactly this many bytes, or
// null.
uint64_t largestFreeBlockBytes() {
#ifdef WOWEE_SWITCH
    return static_cast<uint64_t>(platform::switchport::queryAvailableCpuMemory().bytes);
#else
    return 0;
#endif
}

// StormLib's own step-by-step trace of an archive open, into the boot log, and
// only for the duration of the open loop.
//
// A boot that died inside SFileOpenArchive left the log ending at the
// breadcrumb that announced the open and nothing else: no exception, no signal
// marker, and no way to tell a failed table allocation from a failed header
// read. The trace is StormLib's own answer to that - every fstat, lseek, read
// and every named stage of the open - it is already used this way by the
// extractor's --diagnostic, and it formats into a fixed buffer, so it is safe
// to have armed on the one heap that has just been found short.
//
// Twenty-odd lines per archive, once per boot, and off the console it compiles
// away: there the open either succeeds or reports an error code.
#ifdef WOWEE_SWITCH
void forwardOpenTrace(const char* message) {
    char line[576];
    std::snprintf(line, sizeof line, "assets: storm %s", message ? message : "");
    platform::switchport::reportBootStage(line);
}

// Armed for the open loop and disarmed on the way out, including on the way out
// of an exception: a trace left armed would follow every later MPQ read into
// the boot log, one line per sector read.
struct OpenTraceScope {
    OpenTraceScope() { SErrSetOpenTrace(&forwardOpenTrace); }
    ~OpenTraceScope() { SErrSetOpenTrace(nullptr); }
};
#define WOWEE_OPEN_TRACE_ON OpenTraceScope openTraceScope
#else
#define WOWEE_OPEN_TRACE_ON
#endif

// A warning about giving something up must not itself be the thing that fails.
// Logger formats the line into an ostringstream, keeps a copy in its dedupe
// cache, and may open the log file; all of that allocates, and the skip below
// is the one place in the open where the heap is known to be short. The
// breadcrumb already recorded the same fact without allocating, so a dropped
// warning costs the log a duplicate and nothing else.
template <typename... Args>
void warnBestEffort(Args&&... args) {
    try {
        LOG_WARNING(std::forward<Args>(args)...);
    } catch (...) {
    }
}
} // namespace

std::unique_ptr<MpqAssetSource> MpqAssetSource::open(const std::string& archiveDir, std::string* error) {
    if (error) error->clear();
    std::string expansion, locale;
    try {
        expansion = tools::Extractor::detectExpansion(archiveDir);
        locale = tools::Extractor::detectLocale(archiveDir);
    } catch (const std::exception& e) {
        if (error) *error = std::string("archive detection failed: ") + e.what();
        return nullptr;
    }
    if (expansion.empty()) {
        if (error) *error = "no recognised client archives under " + archiveDir;
        return nullptr;
    }
    const auto archives = tools::Extractor::discoverArchives(archiveDir, expansion, locale);
    if (archives.empty()) {
        if (error) *error = "no archives in the client's load order under " + archiveDir;
        return nullptr;
    }
    reportArchiveStage("discovered", archiveDir, archives.size());
    std::unique_ptr<MpqAssetSource> source(new MpqAssetSource());
    source->expansion_ = expansion;
    source->locale_ = locale;
    std::string firstFailure;
    uint64_t tablesTotal = 0;
    WOWEE_OPEN_TRACE_ON;
    for (const auto& path : archives) {
        HANDLE h = nullptr;
        // No (listfile)/(attributes) parsing at open: name lookups go through
        // the hash tables and need neither, and parsing them for eighteen
        // retail archives cost 45 s on the console (B4 test 7). listFiles()
        // loads the listfiles on first use.
        const uint64_t bytes = archiveBytesOnDisk(path);
        // Ask the header what this open would cost before spending it. Both
        // numbers in the refusal below are then known on this side of the
        // SFileOpenArchive call rather than inferred from a heap that died.
        MpqHeaderCounts counts;
        if (readMpqHeaderCounts(path, counts)) {
            const ArchiveTableBudget budget = archiveTableBudgetFor(counts.hashEntries, counts.blockEntries);
            // Where the console cannot measure a free block, the same static
            // per-archive ceiling the post-open check uses is the whole of the
            // policy. Where it can, the measurement is the tighter of the two
            // and the ceiling does not apply - an archive that fits in what
            // the heap will really hand back is worth opening even if it is a
            // large one.
            const uint64_t freeBytes = largestFreeBlockBytes();
            const uint64_t room = freeBytes ? freeBytes : kArchiveTableCeilingBytes;
            if (budget.neededBytes > room) {
                reportArchiveStage("over budget", path, budget.neededBytes);
                warnBestEffort("MpqAssetSource: not opening ", path, "; its tables need ",
                               budget.neededBytes, " bytes at the open's peak and the largest free "
                               "block was ", room, " bytes, so files only in it will be missing");
                if (firstFailure.empty()) firstFailure = path;
                continue;
            }
        }
        reportArchiveStage("opening", path, bytes);
        if (!SFileOpenArchive(path.c_str(), 0, MPQ_OPEN_READ_ONLY | MPQ_OPEN_NO_LISTFILE | MPQ_OPEN_NO_ATTRIBUTES, &h)) {
            const unsigned code = SErrGetLastError();
            reportArchiveStage("failed", path, code);
            warnBestEffort("MpqAssetSource: cannot open ", path, " (StormLib error ", code, "); files only in it will be missing");
            if (firstFailure.empty()) firstFailure = path + " (error " + std::to_string(code) + ")";
            continue;
        }
        // Already open, so already paid for. Decide now whether it is
        // affordable, before the next one is added on top of it.
        const uint64_t tables = archiveTableBytes(h);
        const bool overOne = tables > kArchiveTableCeilingBytes;
        const bool overAll = !overOne && tablesTotal + tables > kTotalTableCeilingBytes;
        if (overOne || overAll) {
            SFileCloseArchive(h);
            reportArchiveStage("skipped", path, tables);
            warnBestEffort("MpqAssetSource: skipped ", path, "; its tables hold ", tables,
                           " bytes, over the ", (overOne ? "per-archive" : "whole-set"),
                           " budget of ", (overOne ? kArchiveTableCeilingBytes : kTotalTableCeilingBytes),
                           " bytes that the archives in this set are allowed between them; files only in it will be missing");
            if (firstFailure.empty()) firstFailure = path;
            continue;
        }
        tablesTotal += tables;
        reportArchiveStage("opened", path, bytes);
        source->archives_.push_back(h);
        source->paths_.push_back(path);
    }
    if (source->archives_.empty()) {
        if (error) *error = "none of the archives could be opened; first failure: " + firstFailure;
        return nullptr;
    }
    // The shortfall in numbers as well as in the per-archive warnings: an
    // archive that did not open is missing every file only it holds, and how
    // many that is decides whether the session is worth starting.
    if (source->archives_.size() != archives.size()) {
        warnBestEffort("MpqAssetSource: ", source->archives_.size(), "/", archives.size(),
                       " archive(s) open; files only in the other ",
                       archives.size() - source->archives_.size(),
                       " will be missing");
    }
    LOG_INFO("MpqAssetSource: ", source->archives_.size(), "/", archives.size(), " archive(s) open under ",
             archiveDir, " (", expansion, ", ", locale.empty() ? "no locale" : locale, ")");
    return source;
}

MpqAssetSource::~MpqAssetSource() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = archives_.rbegin(); it != archives_.rend(); ++it) {
        if (*it) SFileCloseArchive(*it);
    }
    archives_.clear();
}

bool MpqAssetSource::hasFile(const std::string& requestedPath) const {
    // StormLib's lookup does not fold '/' to '\\' on every path through the
    // hash tables (the host smoke test caught it), so the fold is done here.
    const std::string normalizedPath = lowerBackslash(requestedPath);
    if (normalizedPath.empty()) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = archives_.rbegin(); it != archives_.rend(); ++it) {
        if (SFileHasFile(*it, normalizedPath.c_str())) return true;
    }
    return false;
}

std::vector<uint8_t> MpqAssetSource::readFile(const std::string& requestedPath) const {
    return readFileBounded(requestedPath, std::numeric_limits<size_t>::max());
}

std::vector<uint8_t> MpqAssetSource::readFileBounded(const std::string& requestedPath, size_t maxBytes) const {
    const std::string normalizedPath = lowerBackslash(requestedPath);
    if (normalizedPath.empty()) return {};
    std::lock_guard<std::mutex> lock(mutex_);
    // Highest priority first: a patch archive's copy shadows the base one.
    for (auto it = archives_.rbegin(); it != archives_.rend(); ++it) {
        HANDLE archive = *it;
        if (!SFileHasFile(archive, normalizedPath.c_str())) continue;
        HANDLE file = nullptr;
        if (!SFileOpenFileEx(archive, normalizedPath.c_str(), SFILE_OPEN_FROM_MPQ, &file)) {
            const unsigned openError = SErrGetLastError();
            // Open allocates StormLib's per-file state too. Preserve patch
            // precedence on exhaustion just as we do for a failed sector read.
            if (openError == ERROR_NOT_ENOUGH_MEMORY) throw std::bad_alloc();
            LOG_WARNING("MpqAssetSource: open failed for ", normalizedPath, " (error ", openError, ")");
            continue;
        }
        // Buffer allocation and StormLib reads can fail after open. Keep the
        // handle owned throughout unwinding, including std::bad_alloc.
        MpqFileHandle ownedFile(file);
        DWORD sizeHigh = 0;
        const DWORD size = SFileGetFileSize(file, &sizeHigh);
        const uint64_t logicalSize = (uint64_t(sizeHigh) << 32) | uint64_t(size);
        if (size != SFILE_INVALID_SIZE && logicalSize > maxBytes) {
            logAssetReadLimit("MpqAssetSource", normalizedPath, logicalSize, maxBytes);
            // A valid but oversized patch still shadows the base archive.
            // Do not allocate its data or silently load an older version.
            return {};
        }
        if (size == SFILE_INVALID_SIZE || sizeHigh != 0 || size > std::vector<uint8_t>().max_size()) {
            LOG_WARNING("MpqAssetSource: bad size for ", normalizedPath);
            continue;
        }
#ifdef WOWEE_SWITCH
        // A single CPU buffer cannot exceed the title's entire flexible-memory
        // budget. This is an existing platform ceiling, not a per-asset cutoff
        // based on file extension or current unmapped malloc pages.
        if (size > platform::switchport::kCpuMemoryBudgetLimit) {
            LOG_WARNING("MpqAssetSource: file exceeds CPU memory budget: ", normalizedPath, " (", size, " bytes)");
            continue;
        }
#endif
        std::vector<uint8_t> data(size);
        DWORD read = 0;
        bool ok = true;
        if (size != 0) {
            ok = SFileReadFile(file, data.data(), size, &read, nullptr) && read == size;
        }
        const unsigned readError = ok ? 0 : SErrGetLastError();
        ownedFile.reset();
        if (!ok) {
            // Exhaustion is not a corrupt patch. Falling through here used
            // to retry every lower-priority archive, sometimes accepting an
            // older model/skin revision, while repeating the same allocation.
            // Let AssetManager classify the read as transient memory pressure.
            if (readError == ERROR_NOT_ENOUGH_MEMORY) throw std::bad_alloc();
            LOG_WARNING("MpqAssetSource: read failed for ", normalizedPath, " (", read, "/", size, " bytes, error ",
                        readError, "); trying a lower-priority archive");
            continue;
        }
        return data;
    }
    return {};
}

std::vector<std::string> MpqAssetSource::listFiles(const std::string& normalizedPrefix) const {
    std::set<std::string> names;
    const std::string mask = normalizedPrefix + "*";
    std::lock_guard<std::mutex> lock(mutex_);
    if (!listfilesLoaded_) {
        listfilesLoaded_ = true;
        for (HANDLE archive : archives_) SFileAddListFile(archive, nullptr);
    }
    for (HANDLE archive : archives_) {
        SFILE_FIND_DATA found{};
        HANDLE find = SFileFindFirstFile(archive, mask.c_str(), &found, nullptr);
        if (!find) continue;
        do {
            if (found.cFileName[0] == '(') continue;   // (listfile), (attributes), ...
            std::string name = lowerBackslash(found.cFileName);
            if (name.compare(0, normalizedPrefix.size(), normalizedPrefix) != 0) continue;
            names.insert(std::move(name));
        } while (SFileFindNextFile(find, &found));
        SFileFindClose(find);
    }
    return std::vector<std::string>(names.begin(), names.end());
}

#else  // no StormLib in this build: the extracted tree remains the only source

std::unique_ptr<MpqAssetSource> MpqAssetSource::open(const std::string&, std::string* error) {
    if (error) *error = "this build has no MPQ support";
    return nullptr;
}
MpqAssetSource::~MpqAssetSource() = default;
bool MpqAssetSource::hasFile(const std::string&) const { return false; }
std::vector<uint8_t> MpqAssetSource::readFile(const std::string&) const { return {}; }
std::vector<uint8_t> MpqAssetSource::readFileBounded(const std::string&, size_t) const { return {}; }
std::vector<std::string> MpqAssetSource::listFiles(const std::string&) const { return {}; }

#endif

} // namespace pipeline
} // namespace wowee
