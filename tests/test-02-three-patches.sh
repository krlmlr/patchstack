#!/usr/bin/env bash
# Test: Three patch branches are discovered and sorted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    # Create patches out of order
    create_patch_branch "patch-zebra" 1
    create_patch_branch "patch-alpha" 2
    create_patch_branch "patch-beta" 1
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "02-three-patches" "$output"
cleanup_test_env
