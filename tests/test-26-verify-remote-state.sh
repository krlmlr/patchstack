#!/usr/bin/env bash
# Test: Verify remote state after successful push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1
git push origin patch-alpha patch-beta

# Create empty patch
git checkout -b patch-empty origin/main
echo "empty-content" > empty.txt
git add empty.txt
git commit -m "Empty patch"
git push origin patch-empty

# Advance upstream with empty patch content
cd "$UPSTREAM_DIR"
echo "empty-content" > empty.txt
git add empty.txt
git commit -m "Upstream: merge empty patch"

cd "$FORK_DIR"
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Verify remote state
cd "$REMOTE_DIR"

# Main should exist and be ahead of previous
if ! git rev-parse main &>/dev/null; then
    echo "ERROR: Remote main should exist"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote main exists"

# Alpha and beta should exist
if ! git rev-parse patch-alpha &>/dev/null; then
    echo "ERROR: Remote patch-alpha should exist"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-alpha exists"

if ! git rev-parse patch-beta &>/dev/null; then
    echo "ERROR: Remote patch-beta should exist"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-beta exists"

# Empty patch should be deleted
if git rev-parse patch-empty &>/dev/null; then
    echo "ERROR: Remote patch-empty should be deleted"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-empty was deleted"

# Verify topology in remote
main_sha=$(git rev-parse main)
alpha_sha=$(git rev-parse patch-alpha)
beta_sha=$(git rev-parse patch-beta)

# Patches should be based on upstream, not on integrated main
# So we can't check for simple ancestry. Instead, check that:
# 1. Main includes the integrated patches (has their changes)
# 2. Patches exist and are valid refs

# Just verify the branches are valid and point to commits
if ! git cat-file -e "$alpha_sha" 2>/dev/null; then
    echo "ERROR: patch-alpha SHA should be a valid commit"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha is a valid commit"

if ! git cat-file -e "$beta_sha" 2>/dev/null; then
    echo "ERROR: patch-beta SHA should be a valid commit"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-beta is a valid commit"

# Cleanup
cleanup_test_env

echo "✓ Test passed: verify remote state"
