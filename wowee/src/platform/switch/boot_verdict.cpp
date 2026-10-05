// boot_verdict.cpp - the first-boot self-test line.
//
// Formatting only: no libnx and no platform calls, so the line can be asserted
// without a console (tools/switch/boot_verdict_test.cpp). The state it reports
// is gathered by the caller and is described in the header.

#include "platform/switch/boot_verdict.hpp"

#include <cstddef>

namespace wowee {
namespace platform {
namespace switchport {
namespace {

// One row per checked part: the name the log line carries, what the field reads
// when the part did not come up, and the word the player reads on the screen.
//
// The order here is the order on the line, and it is fixed rather than
// alphabetical because a reader who has seen the line once should find each
// field in the same place on the next launch.
struct CheckedPart {
    const char* key;
    const char* reason;
    const char* plain;
};

constexpr CheckedPart kParts[] = {
    {"renderer", "no-frame",     "picture"},
    {"audio",    "no-engine",    "sound"},
    {"hid",      "uninitialised", "controls"},
    {"net",      "no-sockets",   "network"},
    {"data",     "not-found",    "game data"},
    {"shaders",  "missing",      "shaders"},
};
constexpr std::size_t kPartCount = sizeof(kParts) / sizeof(kParts[0]);

// The struct and the table have to grow together: a field with no row would be
// silently left out of the line, and a row with no field would read a field
// that does not exist.
bool partCameUp(const BootChecks& checks, std::size_t part) {
    switch (part) {
        case 0: return checks.renderer;
        case 1: return checks.audio;
        case 2: return checks.hid;
        case 3: return checks.net;
        case 4: return checks.data;
        default: return checks.shaders;
    }
}

}  // namespace

bool bootVerdictPassed(const BootChecks& checks) {
    for (std::size_t part = 0; part < kPartCount; ++part) {
        if (!partCameUp(checks, part)) return false;
    }
    return true;
}

std::string formatBootVerdict(const BootChecks& checks) {
    std::string line = bootVerdictPassed(checks) ? "SELF-TEST: PASS  " : "SELF-TEST: FAIL  ";
    std::string failed;
    for (std::size_t part = 0; part < kPartCount; ++part) {
        const bool up = partCameUp(checks, part);
        line += kParts[part].key;
        line += '=';
        line += up ? "ok" : kParts[part].reason;
        line += ' ';
        if (!up) {
            if (!failed.empty()) failed += ',';
            failed += kParts[part].key;
        }
    }
    line += "failed=";
    line += failed.empty() ? "none" : failed;
    return line;
}

std::string formatBootVerdictOnAbort() {
    // Same field order as the judged line, so a reader who has seen one knows
    // where to look, and no `ok` anywhere: nothing about which parts would have
    // come up is known at this point.
    std::string line = "SELF-TEST: FAIL  ";
    for (std::size_t part = 0; part < kPartCount; ++part) {
        line += kParts[part].key;
        line += "=not-reached ";
    }
    line += "failed=startup-abort";
    return line;
}

std::string formatBootVerdictOnScreen(const BootChecks& checks) {
    std::string missing;
    for (std::size_t part = 0; part < kPartCount; ++part) {
        if (partCameUp(checks, part)) continue;
        if (!missing.empty()) missing += ", ";
        missing += "no ";
        missing += kParts[part].plain;
    }
    if (missing.empty()) {
        return "Self-test passed: picture, sound, controls, network, game data "
               "and shaders are all up.";
    }
    // Only the parts that are down, and where the rest of the answer is. The
    // screen is not the log: a player cannot grep a television.
    return "Self-test: " + missing +
           ". The rest are up. Detail in logs/boot.log.";
}

}  // namespace switchport
}  // namespace platform
}  // namespace wowee