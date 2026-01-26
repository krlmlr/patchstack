#!/usr/bin/env bash
# Test: Status detects when sync is needed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patch
create_patch_branch "patch-alpha" 1

# Advance upstream (creates need for sync)
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change 1"
git commit --allow-empty -m "Upstream change 2"

cd "$FORK_DIR"
git fetch upstream

# Run status
output=$("$PATCHSTACK" status 2>&1)

# Should indicate sync needed
# Looking for any of: behind, sync needed, or needs rebase
if ! echo "$output" | grep -qiE "behind|sync needed|needs rebase"; then
    echo "ERROR: Status should indicate sync is needed"
    exit 1
fi

# Should show how many commits behind
assert_contains "$output" "2"

assert_snapshot "30-status-needs-sync" "$output"

cleanup_test_env
echo "✓ Test passed: status detects when sync is needed"
