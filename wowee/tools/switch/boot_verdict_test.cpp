// Exercise the first-boot self-test line: the format, the field order, and the
// wording the login screen shows. Pure text, so it runs off-console.
//
// Deliberately not in tools/tests: the switch platform's own tests are driven
// from there, and this one belongs with the switch tree it reports on.
#include "platform/switch/boot_verdict.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

using namespace wowee::platform::switchport;

void require(bool okay, const char* description) {
    if (!okay) { std::fprintf(stderr, "FAIL: %s\n", description); std::abort(); }
}

// The same, with the line that failed: the whole point of these is a string
// that a grep matches, so the wrong string is the diagnostic.
void require(bool okay, const std::string& text, const char* description) {
    if (!okay) {
        std::fprintf(stderr, "FAIL: %s\n  in: %s\n", description, text.c_str());
        std::abort();
    }
}

BootChecks allUp() {
    BootChecks checks;
    checks.renderer = checks.audio = checks.hid = true;
    checks.net = checks.data = checks.shaders = true;
    return checks;
}

// The exact line, because it is the contract: `grep SELF-TEST` has to keep
// working, and a field moving would break every grep written against it.
void passesReadAsOneLine() {
    const std::string line = formatBootVerdict(allUp());
    require(line ==
            "SELF-TEST: PASS  renderer=ok audio=ok hid=ok net=ok data=ok shaders=ok failed=none",
            line, "a clean boot is one PASS line with every field ok");
    require(line.find('\n') == std::string::npos, "the line is a single line");
    require(bootVerdictPassed(allUp()), "a clean boot passes");
}

void oneDownPartIsNamedWithItsReason() {
    struct Case {
        bool BootChecks::*field;
        const char* key;
        const char* reason;
    };
    const Case cases[] = {
        {&BootChecks::renderer, "renderer", "no-frame"},
        {&BootChecks::audio,    "audio",    "no-engine"},
        {&BootChecks::hid,      "hid",      "uninitialised"},
        {&BootChecks::net,      "net",      "no-sockets"},
        {&BootChecks::data,     "data",     "not-found"},
        {&BootChecks::shaders,  "shaders",  "missing"},
    };
    for (const Case& c : cases) {
        BootChecks checks = allUp();
        checks.*c.field = false;
        const std::string line = formatBootVerdict(checks);
        require(!bootVerdictPassed(checks), "one part down is a failed boot");
        require(line.rfind("SELF-TEST: FAIL  ", 0) == 0, "a part down reads FAIL");
        require(line.find(std::string(c.key) + "=" + c.reason + " ") != std::string::npos,
                "the field that is down carries its reason");
        require(line.find(std::string("failed=") + c.key) != std::string::npos,
                "the trailing list names the part that is down");
        // The other five still read ok: a broken sound device is not a broken
        // renderer, and a line that said otherwise would send the reader after
        // the wrong subsystem.
        std::size_t okCount = 0;
        for (const char* other : {"renderer", "audio", "hid", "net", "data", "shaders"}) {
            if (std::strcmp(other, c.key) != 0 &&
                line.find(std::string(other) + "=ok ") != std::string::npos) {
                ++okCount;
            }
        }
        require(okCount == 5, "the parts that came up still read ok");
        require(line.find('\n') == std::string::npos, "the line is a single line");
    }
}

void severalDownPartsKeepFieldOrder() {
    BootChecks checks;  // nothing came up
    const std::string line = formatBootVerdict(checks);
    require(line ==
            "SELF-TEST: FAIL  renderer=no-frame audio=no-engine hid=uninitialised "
            "net=no-sockets data=not-found shaders=missing "
            "failed=renderer,audio,hid,net,data,shaders",
            line, "every reason, in field order, with the whole list behind failed=");
    require(!bootVerdictPassed(checks), "nothing up is not a pass");

    checks.hid = true;
    checks.audio = true;
    require(formatBootVerdict(checks).find(
                "failed=renderer,net,data,shaders") != std::string::npos,
            "the list holds only what is down, still in field order");
}

void screenTextSaysItInWords() {
    const std::string passed = formatBootVerdictOnScreen(allUp());
    require(passed ==
            "Self-test passed: picture, sound, controls, network, game data "
            "and shaders are all up.",
            passed, "a clean boot says so on the login screen");

    BootChecks checks = allUp();
    checks.audio = false;
    const std::string silent = formatBootVerdictOnScreen(checks);
    require(silent == "Self-test: no sound. The rest are up. Detail in logs/boot.log.",
            silent, "a silent client says which part is down, and where the log is");
    require(silent.find("picture") == std::string::npos,
            "the screen line names only what is down");
    require(silent.find('\n') == std::string::npos, "the screen line is one line");

    checks = allUp();
    checks.hid = false;
    checks.renderer = false;
    const std::string two = formatBootVerdictOnScreen(checks);
    require(two ==
            "Self-test: no picture, no controls. The rest are up. Detail in logs/boot.log.",
            two, "two parts down read as a list, in field order");
}

// Nothing the line carries may name where the player put their game, or any
// path but the log: the line is the part of the log that gets pasted into a
// bug report.
void lineCarriesNoPaths() {
    for (const BootChecks& checks : {allUp(), BootChecks{}}) {
        for (const std::string& text :
             {formatBootVerdict(checks), formatBootVerdictOnScreen(checks)}) {
            require(text.find("sdmc:") == std::string::npos, "no SD path on the line");
            require(text.find("romfs:") == std::string::npos, "no romfs path on the line");
            require(text.find("Data/") == std::string::npos, "no game data path on the line");
            // The one path allowed. The slash inside "logs/boot.log" is the only one, so
            // every other separator on either line would be caught here.
            const std::string logPath = "/boot.log";
            std::size_t at = 0;
            while ((at = text.find('/', at)) != std::string::npos) {
                require(text.compare(at, logPath.size(), logPath) == 0, text,
                        "the only path on the line is the boot log");
                at += 1;
            }
        }
    }
}

// A boot that stopped before it could be judged still has to leave a verdict
// behind, and must not claim any part came up: it cannot know.
void anAbortedBootStillLeavesAVerdict() {
    const std::string line = formatBootVerdictOnAbort();
    require(line ==
            "SELF-TEST: FAIL  renderer=not-reached audio=not-reached hid=not-reached "
            "net=not-reached data=not-reached shaders=not-reached failed=startup-abort",
            line, "an aborted boot reads FAIL with every part not-reached");
    require(line.find('\n') == std::string::npos, "the line is a single line");
    require(line.find("=ok ") == std::string::npos,
            "nothing is claimed to have come up");
}

}  // namespace

int main() {
    passesReadAsOneLine();
    oneDownPartIsNamedWithItsReason();
    severalDownPartsKeepFieldOrder();
    anAbortedBootStillLeavesAVerdict();
    screenTextSaysItInWords();
    lineCarriesNoPaths();
    std::printf("boot verdict: all checks passed\n");
    return 0;
}