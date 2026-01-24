#!/usr/bin/env bash
# Test: No patch branches returns empty result

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "01-no-patches" "$output"
cleanup_test_env
