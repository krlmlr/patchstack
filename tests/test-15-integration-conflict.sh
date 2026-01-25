#!/usr/bin/env bash
# Test: Integration conflict excludes patch-B, includes A and C
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patch-alpha: modifies file1.txt
git checkout -q -b patch-alpha origin/main
echo "alpha-change" > file1.txt
git add file1.txt
git commit -q -m "Alpha: add file1"
git push -q origin patch-alpha
git checkout -q main

# Create patch-beta: also modifies file1.txt (will conflict with alpha during integration!)
git checkout -q -b patch-beta origin/main
echo "beta-change" > file1.txt
git add file1.txt
git commit -q -m "Beta: add file1"
git push -q origin patch-beta
git checkout -q main

# Create patch-gamma: modifies different file (no conflict)
git checkout -q -b patch-gamma origin/main
echo "gamma-change" > file2.txt
git add file2.txt
git commit -q -m "Gamma: add file2"
git push -q origin patch-gamma
git checkout -q main

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Check that patch-alpha and patch-gamma are integrated but not patch-beta
if ! git rev-parse refs/patchstack/tmp/main >/dev/null 2>&1; then
    echo "ERROR: Integration ref not created"
    cleanup_test_env
    exit 1
fi

integration_sha=$(git rev-parse refs/patchstack/tmp/main)
log_output=$(git log --oneline upstream/main.."$integration_sha")

if ! echo "$log_output" | grep -q "patch-alpha"; then
    echo "ERROR: patch-alpha should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha is integrated"

if echo "$log_output" | grep -q "patch-beta"; then
    echo "ERROR: patch-beta should NOT be integrated (integration conflict)"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-beta is NOT integrated (expected: integration conflict)"

if ! echo "$log_output" | grep -q "patch-gamma"; then
    echo "ERROR: patch-gamma should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-gamma is integrated"

# Should have 2 commits (alpha + gamma)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")
if [ "$commit_count" != "2" ]; then
    echo "ERROR: Expected 2 commits, got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration has 2 commits (alpha + gamma)"

# Check output shows integration conflict
if ! echo "$output" | grep -q "integration-conflict\|Integration conflict"; then
    echo "ERROR: Output should mention integration conflict"
    echo "$output"
    cleanup_test_env
    exit 1
fi
echo "✓ Output mentions integration conflict"

# Cleanup
cleanup_test_env

echo "✓ Test passed: integration conflict"
