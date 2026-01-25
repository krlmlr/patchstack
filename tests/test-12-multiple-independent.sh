#!/usr/bin/env bash
# Test: Multiple patches processed independently
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create initial state with a conflict file in main
echo "base" > base.txt
git add base.txt
git commit -q -m "Add base"
git push -q origin main
git fetch -q origin

# Create three patches (all based on the same main)
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 1

# Create gamma that will conflict with upstream
git checkout -q -b patch-gamma
echo "gamma content" > gamma.txt
git add gamma.txt
git commit -q -m "Add gamma"
echo "conflict from patch" > conflict.txt
git add conflict.txt
git commit -q -m "Conflicting change in patch"
git push -q origin patch-gamma
git checkout -q main

# Add conflicting content to upstream
cd "$UPSTREAM_DIR"
echo "conflict from upstream" > conflict.txt
git add conflict.txt
git commit -q -m "Upstream conflict"

cd "$FORK_DIR"
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Verify alpha succeeded
if echo "$output" | grep -q "patch-alpha.*success"; then
    echo "✓ patch-alpha succeeded"
else
    echo "✗ patch-alpha did not succeed"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify beta succeeded
if echo "$output" | grep -q "patch-beta.*success"; then
    echo "✓ patch-beta succeeded"
else
    echo "✗ patch-beta did not succeed"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify gamma conflicted
if echo "$output" | grep -q "patch-gamma.*conflict"; then
    echo "✓ patch-gamma conflicted"
else
    echo "✗ patch-gamma did not conflict"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify successful patches have temp refs
assert_branch_exists "refs/patchstack/tmp/patch-alpha"
assert_branch_exists "refs/patchstack/tmp/patch-beta"

# Verify failed patch does not have temp ref
assert_branch_not_exists "refs/patchstack/tmp/patch-gamma"

# Cleanup
cleanup_test_env

echo "✓ Test passed: multiple patches independent"
