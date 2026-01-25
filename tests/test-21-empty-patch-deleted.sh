#!/usr/bin/env bash
# Test: Empty patch ref deleted
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

# Create patch that will become empty
git checkout -q -b patch-empty origin/main
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "Add feature"
git push -q origin patch-empty

# Verify ref exists
if ! git rev-parse origin/patch-empty &>/dev/null; then
    echo "ERROR: patch-empty should exist initially"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-empty exists initially"

# Advance upstream with same change
cd "$UPSTREAM_DIR"
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "Add feature (from patch-empty)"

cd "$FORK_DIR"
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check ref was deleted
if git rev-parse origin/patch-empty &>/dev/null; then
    echo "ERROR: patch-empty should be deleted"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-empty was deleted"

# Cleanup
cleanup_test_env

echo "✓ Test passed: empty patch deleted"
