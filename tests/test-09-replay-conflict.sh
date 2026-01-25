#!/usr/bin/env bash
# Test: Replay conflict detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create file and commit to main
echo "line 1" > conflict.txt
git add conflict.txt
git commit -q -m "Add conflict.txt"
git push -q origin main

# Create patch that modifies the file
git checkout -q -b patch-conflict
echo "line 1 modified in patch" > conflict.txt
git commit -q -am "Modify in patch"
git push -q origin patch-conflict
git checkout -q main

# Modify same file in upstream
cd "$UPSTREAM_DIR"
echo "line 1 modified in upstream" > conflict.txt
git add conflict.txt
git commit -q -m "Modify in upstream"

# Fetch in fork
cd "$FORK_DIR"
git fetch -q upstream

# Run sync - should detect conflict
output=$("$PATCHSTACK" sync 2>&1)

# Verify output shows conflict
if echo "$output" | grep -q "conflict"; then
    echo "✓ Conflict detected in output"
else
    echo "✗ Conflict not detected in output"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify temporary ref does not exist (failed replay)
if git show-ref -q refs/patchstack/tmp/patch-conflict; then
    echo "✗ Temporary ref exists but should not (replay failed)"
    cleanup_test_env
    exit 1
else
    echo "✓ Temporary ref does not exist (expected for conflict)"
fi

# Cleanup
cleanup_test_env

echo "✓ Test passed: replay conflict"
