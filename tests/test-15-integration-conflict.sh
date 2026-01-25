#!/usr/bin/env bash
# Test: Integration conflict excludes patch-beta, includes patch-alpha and patch-gamma
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

# Check integration by verifying file contents
git checkout -q refs/patchstack/tmp/main

# alpha should be integrated (file1.txt should contain alpha's content)
if [[ ! -f "file1.txt" ]] || ! grep -q "alpha-change" file1.txt; then
    echo "ERROR: patch-alpha should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha is integrated"

# beta conflicts with alpha, so alpha's content should be present, not beta's
if grep -q "beta-change" file1.txt 2>/dev/null; then
    echo "ERROR: patch-beta should NOT be integrated (integration conflict)"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-beta is NOT integrated (expected: integration conflict)"

# gamma should be integrated (file2.txt should exist with gamma's content)
if [[ ! -f "file2.txt" ]] || ! grep -q "gamma-change" file2.txt; then
    echo "ERROR: patch-gamma should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-gamma is integrated"

# Should have 2 commits (alpha + gamma)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")
if [[ "$commit_count" != "2" ]]; then
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
