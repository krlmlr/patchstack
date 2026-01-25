#!/usr/bin/env bash
# Test: Squash 3 clean patches into new main
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

# Create three patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 3
create_patch_branch "patch-gamma" 1

# Push patches to remote
git push origin patch-alpha patch-beta patch-gamma

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check integration ref exists
if ! git rev-parse refs/patchstack/tmp/main >/dev/null 2>&1; then
    echo "ERROR: Integration ref not created"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration ref created"

# Check integration ref has 3 commits beyond upstream
upstream_sha=$(git rev-parse upstream/main)
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count "$upstream_sha..$integration_sha")

if [[ "$commit_count" != "3" ]]; then
    echo "ERROR: Expected 3 commits, got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration has 3 commits beyond upstream"

# Check that files from all patches exist in integration
git checkout -q refs/patchstack/tmp/main

if [[ ! -f "file-patch-alpha.txt" ]]; then
    echo "ERROR: Missing file-patch-alpha.txt"
    cleanup_test_env
    exit 1
fi

if [[ ! -f "file-patch-beta.txt" ]]; then
    echo "ERROR: Missing file-patch-beta.txt"
    cleanup_test_env
    exit 1
fi

if [[ ! -f "file-patch-gamma.txt" ]]; then
    echo "ERROR: Missing file-patch-gamma.txt"
    cleanup_test_env
    exit 1
fi
echo "✓ All patch files present in integration"

# Cleanup
cleanup_test_env

echo "✓ Test passed: squash three patches"
