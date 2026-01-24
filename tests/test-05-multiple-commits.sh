#!/usr/bin/env bash
# Test: Handles patch branches with multiple commits

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    # Create patches with varying numbers of commits
    create_patch_branch "patch-one" 1
    create_patch_branch "patch-five" 5
    create_patch_branch "patch-ten" 10
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "05-multiple-commits" "$output"
cleanup_test_env
