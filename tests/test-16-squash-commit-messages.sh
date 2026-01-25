#!/usr/bin/env bash
# Test: Verify squash commit messages use git's default format
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

# Check squash commit message uses git's default format
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
squash_msg=$(git log -1 --format=%B "$integration_sha")

# Git's default squash message contains "Squashed commit of the following:"
if ! echo "$squash_msg" | grep -q "Squashed commit"; then
    echo "ERROR: Squash message should contain 'Squashed commit'"
    echo "Message was: $squash_msg"
    cleanup_test_env
    exit 1
fi
echo "✓ Squash message uses git's default format"

# Should contain the individual commit messages
if ! echo "$squash_msg" | grep -q "Feature: part 1"; then
    echo "ERROR: Squash message should contain original commit messages"
    echo "Message was: $squash_msg"
    cleanup_test_env
    exit 1
fi
echo "✓ Squash message contains original commit messages"

# Cleanup
cleanup_test_env

echo "✓ Test passed: squash commit messages"
