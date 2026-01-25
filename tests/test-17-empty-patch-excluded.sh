#!/usr/bin/env bash
# Test: Empty patches excluded from integration
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

# Create patch-alpha: adds a feature
git checkout -q -b patch-alpha origin/main
echo "feature-a" > feature-a.txt
git add feature-a.txt
git commit -q -m "Add feature A"
git push -q origin patch-alpha
git checkout -q main

# Create patch-empty: adds feature that will be in upstream (will become empty)
git checkout -q -b patch-empty origin/main
echo "already-upstream" > already.txt
git add already.txt
git commit -q -m "Add feature already in upstream"
git push -q origin patch-empty
git checkout -q main

# Create patch-charlie: adds another feature
git checkout -q -b patch-charlie origin/main
echo "feature-c" > feature-c.txt
git add feature-c.txt
git commit -q -m "Add feature C"
git push -q origin patch-charlie
git checkout -q main

# Advance upstream with the "empty" patch content
cd "$UPSTREAM_DIR"
echo "already-upstream" > already.txt
git add already.txt
git commit -q -m "Merge feature from patch-empty"

# Fetch in fork
cd "$FORK_DIR"
git fetch -q upstream

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Check that only alpha and charlie are in integration
main_ref=$(find_patchstack_main_ref)
if [[ -z "$main_ref" ]]; then
    echo "ERROR: Integration ref not created"
    cleanup_test_env
    exit 1
fi

integration_sha=$(git rev-parse "$main_ref")
commit_count=$(git rev-list --count upstream/main.."$integration_sha")

if [[ "$commit_count" != "2" ]]; then
    echo "ERROR: Expected 2 commits (alpha + charlie), got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration has 2 commits (alpha + charlie)"

# Verify patch-empty is marked as empty in output
if ! echo "$output" | grep -q -i "patch-empty.*empty"; then
    echo "ERROR: patch-empty should be marked as empty"
    echo "$output"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-empty marked as empty"

# Verify alpha and charlie are in integration by checking file contents
git checkout -q "$main_ref"

if [[ ! -f "feature-a.txt" ]] || ! grep -q "feature-a" feature-a.txt; then
    echo "ERROR: patch-alpha should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha is integrated"

if [[ ! -f "feature-c.txt" ]] || ! grep -q "feature-c" feature-c.txt; then
    echo "ERROR: patch-charlie should be integrated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-charlie is integrated"

# Cleanup
cleanup_test_env

echo "✓ Test passed: empty patch excluded"
