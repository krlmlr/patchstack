#!/usr/bin/env bash
# Test: Verify squash commit messages include patch name and count
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patch with multiple commits
git checkout -q -b patch-feature origin/main
echo "commit 1" > file1.txt
git add file1.txt
git commit -q -m "Feature: part 1"
echo "commit 2" > file2.txt
git add file2.txt
git commit -q -m "Feature: part 2"
echo "commit 3" > file3.txt
git add file3.txt
git commit -q -m "Feature: part 3"
git push -q origin patch-feature
git checkout -q main

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

# Check squash commit message
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
squash_msg=$(git log -1 --format=%B "$integration_sha")

# Should contain patch name
if ! echo "$squash_msg" | grep -q "patch-feature"; then
    echo "ERROR: Squash message should contain patch name"
    echo "Message was: $squash_msg"
    cleanup_test_env
    exit 1
fi
echo "✓ Squash message contains patch name"

# Should contain commit count
if ! echo "$squash_msg" | grep -q "3"; then
    echo "ERROR: Squash message should contain commit count (3)"
    echo "Message was: $squash_msg"
    cleanup_test_env
    exit 1
fi
echo "✓ Squash message contains commit count"

# Should contain "Squash:"
if ! echo "$squash_msg" | grep -q "Squash:"; then
    echo "ERROR: Squash message should contain 'Squash:'"
    echo "Message was: $squash_msg"
    cleanup_test_env
    exit 1
fi
echo "✓ Squash message contains 'Squash:'"

# Cleanup
cleanup_test_env

echo "✓ Test passed: squash commit messages"
