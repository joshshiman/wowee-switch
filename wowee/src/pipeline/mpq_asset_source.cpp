#include "pipeline/mpq_asset_source.hpp"
#include "pipeline/asset_read_bounds.hpp"
#include "core/logger.hpp"

#include <algorithm>
#include <set>
#include <limits>
#include <new>
#include <cstdio>
#include <filesystem>
#include <system_error>
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
    for (const auto& path : archives) {
        HANDLE h = nullptr;
        // No (listfile)/(attributes) parsing at open: name lookups go through
        // the hash tables and need neither, and parsing them for eighteen
        // retail archives cost 45 s on the console (B4 test 7). listFiles()
        // loads the listfiles on first use.
        const uint64_t bytes = archiveBytesOnDisk(path);
        reportArchiveStage("opening", path, bytes);
        if (!SFileOpenArchive(path.c_str(), 0, MPQ_OPEN_READ_ONLY | MPQ_OPEN_NO_LISTFILE | MPQ_OPEN_NO_ATTRIBUTES, &h)) {
            const unsigned code = SErrGetLastError();
            reportArchiveStage("failed", path, code);
            LOG_WARNING("MpqAssetSource: cannot open ", path, " (StormLib error ", code, "); files only in it will be missing");
            if (firstFailure.empty()) firstFailure = path + " (error " + std::to_string(code) + ")";
            continue;
        }
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
        LOG_WARNING("MpqAssetSource: ", source->archives_.size(), "/", archives.size(),
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
