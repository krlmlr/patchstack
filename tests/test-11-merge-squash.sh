#!/usr/bin/env bash
# Test: Merge commit squashing during replay
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

# Create a patch branch with a merge commit
git checkout -q -b patch-with-merge
echo "file1" > file1.txt
git add file1.txt
git commit -q -m "Add file1"

# Create feature branch and merge it
git checkout -q -b feature
echo "file2" > file2.txt
git add file2.txt
git commit -q -m "Add file2"

git checkout -q patch-with-merge
git merge -q feature --no-edit -m "Merge feature"
git push -q origin patch-with-merge
git checkout -q main

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Verify temporary ref exists
assert_patchstack_ref_exists "patch-with-merge"

# Get the actual ref
tmp_ref=$(find_patchstack_ref "patch-with-merge")

# Verify result is linear (no merge commits)
merge_count=$(git rev-list --merges upstream/main.."$tmp_ref" | wc -l | tr -d ' ')
if [[ "$merge_count" == "0" ]]; then
    echo "✓ No merge commits in replayed result (squashed)"
else
    echo "✗ Found $merge_count merge commits (should be 0)"
    cleanup_test_env
    exit 1
fi

# Cleanup
cleanup_test_env

echo "✓ Test passed: merge commit squashing"
