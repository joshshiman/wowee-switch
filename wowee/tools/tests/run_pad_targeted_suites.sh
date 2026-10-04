#!/usr/bin/env bash
# Run the suites that can see any of the six files the micro-button change
# touched, plus the suites the task lists as the pre-existing baseline, and
# print one line each.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
export SANITIZE=1 ASAN_OPTIONS=detect_leaks=0
run() {
    local name="$1"; shift
    if "$@" >"/tmp/target-$name.log" 2>&1; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s\n' "$name"
        tail -3 "/tmp/target-$name.log" | sed 's/^/        /'
    fi
}
run framexml_pad            bash tools/tests/run_framexml_pad_tests.sh
run framexml_pad_remote     python3 tools/tests/framexml_pad_remote_realm_test.py
run framexml_pad_0178       bash tools/tests/run_framexml_pad_0178_tests.sh
run controller              python3 tools/tests/controller_test.py
run controller_0190         python3 tools/tests/controller_0190_test.py
run controller_p02          python3 tools/tests/controller_p02_regression_test.py
run local_death_pad         python3 tools/tests/run_local_death_pad_tests.py
run local_travel_0185       bash tools/tests/run_local_travel_0185_tests.sh
# character_points_framexml_test.py is not one of the native suites: it takes a
# path to the player's own 3.3.5 ChatFrame.lua and is run by hand.
run quest_rewards_framexml  bash tools/tests/run_quest_rewards_framexml_tests.sh
run local_quest_rewards      bash tools/tests/run_local_quest_rewards_tests.sh
run local_death_framexml     bash tools/tests/run_local_death_framexml_tests.sh
run social_client           python3 tools/tests/social_client_test.py
run social_client_0182      python3 tools/tests/social_client_0182_test.py