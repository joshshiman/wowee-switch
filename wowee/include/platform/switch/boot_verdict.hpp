#pragma once
// boot_verdict.hpp - the one line that says whether the first boot worked.
//
// The console's only diagnostic is logs/boot.log, and a boot writes about a
// thousand lines to it. Someone who cannot get past the first launch should not
// have to read them: this is the single line that answers "did it come up",
// with every part that can be broken on its own named separately, so one grep
// says which one.
//
// Nothing here touches the platform. The caller gathers the state - all of it
// state the startup path already keeps - and this only turns it into text, so
// the line can be asserted off-console.

#include <string>

namespace wowee {
namespace platform {
namespace switchport {

/// The parts of a first boot that can each be broken on their own.
///
/// Every field is read from something the startup path already established:
/// whether a frame reached the screen (the flag hideSplashScreen sets), the
/// audio engine's own flag, the pad layer's, the socket service's result, the
/// asset manager's, and whether the resource root the renderer reads its
/// compiled shaders from actually carries them. No field costs a probe.
struct BootChecks {
    bool renderer = false;  ///< a frame reached the screen
    bool audio = false;     ///< the audio engine came up
    bool hid = false;       ///< the pads were initialised
    bool net = false;       ///< the socket service came up
    bool data = false;      ///< the user's game archives opened
    bool shaders = false;   ///< the compiled shaders are where the renderer reads them
};

/// Whether every part came up.
///
/// One part down is a failed first boot even though the client keeps running:
/// a client with no sound is still no sound, and that is the whole reason this
/// line exists - the port fails silently by construction.
bool bootVerdictPassed(const BootChecks& checks);

/// The log line, one line, fixed field order, each field `ok` or a short reason:
///
///   SELF-TEST: PASS  renderer=ok audio=ok hid=ok net=ok data=ok shaders=ok failed=none
///   SELF-TEST: FAIL  renderer=ok audio=ok hid=uninitialised net=ok data=ok shaders=ok failed=hid
///
/// The trailing list is what a second grep matches on, so a reader who wants
/// one word gets `failed=hid` rather than six fields to compare.
std::string formatBootVerdict(const BootChecks& checks);

/// The verdict line for a boot that stopped before it could be judged.
///
/// `SELF-TEST: FAIL  renderer=not-reached audio=not-reached ... failed=startup-abort`
///
/// The line above needs state the startup path gathers as it goes, and a boot
/// that dies part-way through renderer initialisation never reaches any of it -
/// which used to mean a failed boot printed no verdict at all, and the last line
/// in the log was a stage breadcrumb rather than an answer. Nothing here claims
/// a part came up or stayed down: every field reads `not-reached`, because a
/// boot that stopped at the grass allocation cannot say whether sound would have
/// worked. What it does say is that it stopped, and the stage it stopped at is
/// the breadcrumb immediately above.
std::string formatBootVerdictOnAbort();

/// The same verdict in words, for the login screen - the one thing a player can
/// read without pulling the SD card:
///
///   Self-test passed: picture, sound, controls, network, game data and shaders are all up.
///   Self-test: no sound. The rest are up. Detail in logs/boot.log.
std::string formatBootVerdictOnScreen(const BootChecks& checks);

}  // namespace switchport
}  // namespace platform
}  // namespace wowee