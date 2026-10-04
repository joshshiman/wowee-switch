#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Sanitizers are on in the release gate: the loader walks subspan views of the
# file, so a level size that ran past one has to fail loudly rather than quietly.
san_flags=()
if [ "${SANITIZE:-0}" = 1 ]; then san_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CXX:-c++}" -std=c++20 -O1 -g "${san_flags[@]}" -I"$root/include" \
    "$root/tools/tests/blp_mip_chain_test.cpp" \
    "$root/src/pipeline/blp_loader.cpp" "$root/src/core/logger.cpp" -pthread -o "$tmpdir/test"
# Run from the temp directory: the loader logs the chains it prunes, and Logger
# puts logs/wowps.log under the working directory, which would otherwise be the
# checkout. This file's own name keeps it out of anyone's way if that changes.
WOWEE_LOG_FILE=blp-mip-chain-test.log bash -c 'cd "$1" && "$1/test"' _ "$tmpdir"
