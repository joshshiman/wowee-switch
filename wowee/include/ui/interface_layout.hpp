#pragma once

namespace wowee::ui {

constexpr int kInterfaceLayoutVersion = 162;
constexpr int kDefaultSafeAreaPercent = 0;

// Auto-loot is on by default now, so kill + A takes the corpse without opening
// the window. Files written while the default was off carry auto_loot=0, and a
// saved value beats a changed default, so loadSettings forces it once and
// stamps this version. Only the default changes: a later explicit toggle still
// wins, and the stamp keeps the migration from running twice.
constexpr int kAutoLootDefaultVersion = 1;

// 01.61 saved its automatic four-percent console margin as if the user had
// selected it. Remove that old default once; other values and later choices
// of four percent remain explicit preferences.
constexpr int migratedSafeAreaPercent(int percent, int savedVersion) {
    return savedVersion < kInterfaceLayoutVersion && percent == 4
        ? kDefaultSafeAreaPercent : percent;
}

} // namespace wowee::ui
