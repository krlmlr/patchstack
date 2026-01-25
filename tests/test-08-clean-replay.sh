#!/usr/bin/env bash
# Test: Clean replay of patch with 2 commits
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create a real remote (bare repository)
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch with 2 commits
create_patch_branch "patch-test" 2

# Push patch to remote
git push origin patch-test

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Verify temporary ref exists
assert_branch_exists "refs/patchstack/tmp/patch-test"

# Verify it's based on new upstream
upstream_sha=$(git rev-parse upstream/main)
if git merge-base --is-ancestor "$upstream_sha" refs/patchstack/tmp/patch-test 2>/dev/null; then
    echo "✓ Replayed branch is based on upstream/main"
else
    echo "✗ Replayed branch is NOT based on upstream/main"
    cleanup_test_env
    exit 1
fi

# Cleanup
cleanup_test_env

echo "✓ Test passed: clean replay"
