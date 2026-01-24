#!/usr/bin/env bash
# Test: Single patch branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    create_patch_branch "patch-single" 3
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "07-single-patch" "$output"
cleanup_test_env
