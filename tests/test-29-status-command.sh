#!/usr/bin/env bash
# Test: Status shows current patch branches and integration state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1

# Run status
output=$("$PATCHSTACK" status 2>&1)

# Should mention both patches
assert_contains "$output" "patch-alpha"
assert_contains "$output" "patch-beta"

# Should show main branch status
assert_contains "$output" "Main Branch"

# Should show commit counts
assert_contains "$output" "2 commits"
assert_contains "$output" "1 commit"

assert_snapshot "29-status-command" "$output"

cleanup_test_env
echo "✓ Test passed: status shows current patch branches and integration state"
