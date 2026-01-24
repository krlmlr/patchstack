#!/usr/bin/env bash
# Test: Discovers branches without 'patch-' prefix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    # Create branches that don't start with 'patch-'
    create_patch_branch "feature-auth" 1
    create_patch_branch "fix-bug-123" 1
    create_patch_branch "patch-normal" 1
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "06-no-patch-prefix" "$output"
cleanup_test_env
