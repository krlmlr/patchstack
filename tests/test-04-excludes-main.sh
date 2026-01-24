#!/usr/bin/env bash
# Test: Excludes main branch from results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    create_patch_branch "patch-test" 1
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "04-excludes-main" "$output"
cleanup_test_env
