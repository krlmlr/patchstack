#!/usr/bin/env bash
# Test: Multiple patches fail integration
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

# All three patches modify the same file - only the first will integrate
git checkout -q -b patch-a origin/main
echo "version-a" > conflict.txt
git add conflict.txt
git commit -q -m "Version A"
git push -q origin patch-a
git checkout -q main

git checkout -q -b patch-b origin/main
echo "version-b" > conflict.txt
git add conflict.txt
git commit -q -m "Version B"
git push -q origin patch-b
git checkout -q main

git checkout -q -b patch-c origin/main
echo "version-c" > conflict.txt
git add conflict.txt
git commit -q -m "Version C"
git push -q origin patch-c
git checkout -q main

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Only patch-a should integrate (first in lexicographic order)
if ! git rev-parse refs/patchstack/tmp/main >/dev/null 2>&1; then
    echo "ERROR: Integration ref not created"
    cleanup_test_env
    exit 1
fi

integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")

if [[ "$commit_count" != "1" ]]; then
    echo "ERROR: Expected 1 commit (only patch-a), got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration has 1 commit (only patch-a)"

# Verify patch-a is in integration by checking file content
git checkout -q refs/patchstack/tmp/main
if [[ ! -f "conflict.txt" ]] || ! grep -q "version-a" conflict.txt; then
    echo "ERROR: patch-a should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-a is integrated"

# Verify patch-b and patch-c marked as failed
if ! echo "$output" | grep -q "patch-b.*integration-conflict\|patch-b.*Integration conflict"; then
    echo "ERROR: patch-b should have integration conflict"
    echo "$output"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-b has integration conflict"

if ! echo "$output" | grep -q "patch-c.*integration-conflict\|patch-c.*Integration conflict"; then
    echo "ERROR: patch-c should have integration conflict"
    echo "$output"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-c has integration conflict"

# Cleanup
cleanup_test_env

echo "✓ Test passed: multiple integration failures"
