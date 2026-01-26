#!/usr/bin/env bash
# Test: Verbose list shows additional details

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patches with different commit counts
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 3

# Regular list
output_regular=$("$PATCHSTACK" list 2>&1)

# Should show patch names
assert_contains "$output_regular" "patch-alpha"

# Verbose list
output_verbose=$("$PATCHSTACK" --verbose list 2>&1)

# Should show commit counts
assert_contains "$output_verbose" "1 commit"
assert_contains "$output_verbose" "3 commits"

# Should show SHAs (7-character hex)
if ! echo "$output_verbose" | grep -qE "\([0-9a-f]{7}"; then
    echo "ERROR: Verbose list should show commit SHAs"
    exit 1
fi

assert_snapshot "31-verbose-list" "$output_verbose"

cleanup_test_env
echo "✓ Test passed: verbose list shows additional details"
