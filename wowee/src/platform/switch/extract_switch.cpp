// extract_switch.cpp - first-launch MPQ extraction on the console.
//
// The include/platform/switch/extract_switch.hpp half of the platform layer. The
// portable logic (what to extract, where, when it is stale) is
// tools/asset_extract/first_launch.cpp, shared with the Linux test in
// switch/tests/extract_smoke; this file adds the console paths, the thread
// budget and the progress reporting.
//
// Paths (see system_switch.cpp):
//   sdmc:/wowps/Data                        the user's archives (input)
//   sdmc:/wowps/expansions/<expansion>/     manifest.json + extracted files
//
// The progress is logged and boot-staged; it is driven from the main thread
// while the extraction runs on a worker.

#include "platform/switch/extract_switch.hpp"
#include "platform/switch/switch_platform.hpp"
#include "first_launch.hpp"
#include "core/logger.hpp"
#include "core/config_paths.hpp"

#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <thread>

namespace wowee {
namespace platform {
namespace switchport {

namespace {

// Two extraction workers: the archive reads are serialised by a mutex in the
// extractor anyway, so the second thread only overlaps CRC and disk writes
// with the next read. WOWEE_EXTRACT_THREADS overrides.
constexpr int kDefaultThreads = 2;

// The progress bar's target id (SCE_MSG_DIALOG_PROGRESSBAR_TARGET_BAR_DEFAULT).
// How often the main thread refreshes the dialog and drains the system queue.
constexpr unsigned kPollMicros = 100 * 1000;

tools::FirstLaunchPlan makePlan() {
    return tools::planFirstLaunch(dataRoot(), dataRoot() + "/Data");
}

int threadBudget() {
    if (const char* env = std::getenv("WOWEE_EXTRACT_THREADS")) {
        const int n = std::atoi(env);
        if (n > 0 && n <= 8) return n;
    }
    return kDefaultThreads;
}

// The bundled Data tree used to be copied into the user's client directory so
// ExpansionRegistry would find expansions/*/expansion.json next to the MPQs.
// It reads them out of the bundled resources instead, so the game data stays
// read-only: nothing this title does should ever write into it.
void mirrorBundledData() {
    reportBootStage("assets: bundled metadata (read-only)");
}

// ---- the system progress dialog ------------------------------------------------

class ProgressDialog {
public:
    bool open(const std::string& message) {
        reportBootStage("assets: extraction progress opening");
        open_ = true;
        LOG_INFO(message);
        hideSplashScreen();
        return true;
    }

    // Main thread, once per poll. Text and value only change the log when
    // they actually changed.
    void update(const std::string& stage, float progress) {
        if (!open_) return;
        const uint32_t pct = static_cast<uint32_t>(std::lround(std::fmin(std::fmax(progress, 0.0f), 1.0f) * 100.0f));
        if (pct != lastPct_) {
            lastPct_ = pct;
            if (pct % 10 == 0) LOG_INFO("extract ", pct, "% ", stage);
        }
        if (stage != lastStage_) {
            lastStage_ = stage;
            LOG_INFO("extract: ", stage);
        }
    }

    void close() {
        if (!open_) return;
        for (int i = 0; i < 3; ++i) {
            pumpSystemEvents();
            ::usleep(kPollMicros);
        }
        finish();
    }

    ~ProgressDialog() { close(); }

private:
    void finish() { open_ = false; }

    std::string lastStage_;
    uint32_t lastPct_ = ~0u;
    bool open_ = false;
};

} // namespace

// ---- public API --------------------------------------------------------------

bool needsExtraction() {
    const auto plan = makePlan();
    if (!plan.hasArchives) {
        LOG_INFO("On-console extraction: ", plan.reason);
        return false;
    }
    LOG_INFO("On-console extraction: ", plan.archives.size(), " archive(s) under ", plan.mpqDir,
             ", expansion '", plan.expansion, "', locale '", plan.locale, "': ",
             plan.needed ? "needed" : "not needed", " (", plan.reason, ")");
    return plan.needed;
}

bool runExtraction(std::function<void(const std::string& stage, float progress)> report) {
    const auto plan = makePlan();
    if (!plan.hasArchives || plan.expansion.empty()) {
        LOG_WARNING("On-console extraction: nothing to extract (", plan.reason, ")");
        return false;
    }

    // The profile metadata first: the registry needs expansion.json beside
    // the manifest, and a run that dies half way should still leave it.
    mirrorBundledData();

    const int threads = threadBudget();
    reportBootStage("assets: MPQ worker entering extractor");
    LOG_INFO("On-console extraction: ", plan.mpqDir, " -> ", plan.outputDir, " (", threads, " thread(s)",
             plan.listFile.empty() ? "" : ", listfile " + plan.listFile, ")");
    const auto start = std::chrono::steady_clock::now();
    bool ok = false;
    try {
        // Routes Extractor::Options::diagnostic into wowps.log: previously
        // a single archive that failed SFileOpenArchive (a partial FTP/USB
        // copy, a permission quirk on one file among the client's ~18)
        // discarded the whole extraction with only "extraction failed after
        // 0 s" in wowps.log and nothing at all naming the archive or the
        // StormLib error code. It is non-fatal now (see extractor.cpp); this
        // is where its detail becomes visible to whoever reports the log.
        ok = tools::runFirstLaunch(plan, threads, report,
            [](const std::string& message) { LOG_WARNING("On-console extraction: ", message); });
    } catch (const std::exception& e) {
        LOG_ERROR("On-console extraction threw: ", e.what());
    } catch (...) {
        LOG_ERROR("On-console extraction threw an unknown exception");
    }
    const auto secs = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start).count();
    if (ok) {
        LOG_INFO("On-console extraction finished in ", secs, " s; manifest at ", plan.manifestPath);
    } else {
        LOG_ERROR("On-console extraction failed after ", secs, " s; continuing with what exists under ", dataRoot());
    }
    return ok;
}

void prepareAssetMetadata() {
    mirrorBundledData();
    const auto plan = makePlan();
    if (!plan.hasArchives) {
        LOG_WARNING("No MPQ archives under ", dataRoot(), "/Data (", plan.reason, "); the client cannot stream game data");
        reportBootStage("assets: no archives to stream from");
        return;
    }
    LOG_INFO("Streaming game data from ", plan.archives.size(), " archive(s) under ", plan.mpqDir, " (",
             plan.expansion, ", ", plan.locale.empty() ? "no locale" : plan.locale, "); no extraction");
    reportBootStage("assets: streaming from archives");
}

bool extractAtStartup(std::function<void(const std::string&, float)> onProgress) {
    // Keep the package's expansion metadata in step even when nothing needs
    // extracting (a tree copied from a PC has its own copy; the package's is
    // the one this build was made with).
    mirrorBundledData();

    if (!needsExtraction()) return false;
    reportBootStage("assets: extraction required (worker not started)");

    // Make the native overlay available before any GPU progress work. B2's
    // last log line was inside this first callback, before an MPQ was opened.
    ProgressDialog dialog;
    dialog.open("wow_ps is preparing your game data.\nThe first launch can take a while.");
    bool progressFailed = false;
    bool firstProgress = true;
    auto drawProgress = [&](const std::string& stage, float progress) {
        if (!onProgress || progressFailed) return;
        const bool first = firstProgress;
        firstProgress = false;
        if (first) reportBootStage("assets: first GPU progress frame enter (worker not started)");
        try {
            onProgress(stage, progress);
            if (first) reportBootStage("assets: first GPU progress frame returned");
        } catch (const std::exception& e) {
            progressFailed = true;
            LOG_ERROR("Extraction progress rendering failed: ", e.what());
            reportBootStage("assets: GPU progress exception, native overlay remains active");
        } catch (...) {
            progressFailed = true;
            LOG_ERROR("Extraction progress rendering failed with an unknown exception");
            reportBootStage("assets: GPU progress unknown exception, native overlay remains active");
        }
    };
    drawProgress("Preparing game data", 0.0f);

    // Progress from the worker threads lands here; the main thread reads it
    // while it pumps the system queue and the dialog.
    struct Shared {
        std::mutex mutex;
        std::string stage = "Preparing";
        float progress = 0.0f;
        std::atomic<bool> finished{false};
        bool ok = false;
    } shared;

    std::thread worker;
    try {
        reportBootStage("assets: launching MPQ worker");
        worker = std::thread([&shared]() {
            bool ok = false;
            reportBootStage("assets: MPQ worker started");
            try {
                ok = runExtraction([&shared](const std::string& stage, float progress) {
                    std::lock_guard<std::mutex> lock(shared.mutex);
                    if (shared.stage != stage) {
                        LOG_INFO("MPQ extraction stage: ", stage);
                        reportBootStage((std::string("assets: MPQ ") + stage).c_str());
                    }
                    shared.stage = stage;
                    shared.progress = progress;
                });
            } catch (const std::exception& e) {
                LOG_ERROR("MPQ worker exception: ", e.what());
                ok = false;
            } catch (...) {
                LOG_ERROR("MPQ worker unknown exception");
                ok = false;
            }
            shared.ok = ok;
            shared.finished.store(true, std::memory_order_release);
        });
    } catch (const std::exception& e) {
        LOG_ERROR("Could not create MPQ worker: ", e.what());
        reportBootStage("assets: MPQ worker creation failed");
        return false;
    }
    // A drawing callback may throw (for example on a device error). Joining
    // on every path prevents std::thread's destructor from terminating the
    // process while extraction still uses shared stack storage.
    struct JoinWorker {
        std::thread& thread;
        ~JoinWorker() { if (thread.joinable()) thread.join(); }
    } joinWorker{worker};

    std::string lastLogged;
    auto lastLog = std::chrono::steady_clock::now();
    while (!shared.finished.load(std::memory_order_acquire)) {
        pumpSystemEvents();
        std::string stage;
        float progress;
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            stage = shared.stage;
            progress = shared.progress;
        }
        dialog.update(stage, progress);
        drawProgress(stage, progress);
        // A line in the log every few seconds, so the klog shows movement
        // when the dialog is not available.
        const auto now = std::chrono::steady_clock::now();
        if (now - lastLog >= std::chrono::seconds(5) || stage != lastLogged) {
            LOG_INFO("Extraction: ", stage, " ", static_cast<int>(progress * 100.0f), "%");
            lastLogged = stage;
            lastLog = now;
        }
        ::usleep(kPollMicros);
    }
    worker.join();
    dialog.update(shared.ok ? "Done" : "Failed", shared.ok ? 1.0f : shared.progress);
    dialog.close();
    drawProgress(shared.ok ? "Game data ready" : "Game data extraction failed", shared.ok ? 1.0f : shared.progress);
    reportBootStage(shared.ok ? "assets: extraction complete" : "assets: extraction failed");
    return shared.ok;
}

} // namespace switch
} // namespace platform
} // namespace wowee
