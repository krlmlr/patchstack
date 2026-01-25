#!/usr/bin/env bash
# Test: Patch with no new commits beyond main
# A branch pointing to the same commit as main has no commits to sync,
# so it's not discovered as a patch branch at all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create patch branch but don't add commits beyond main
git checkout -q -b patch-empty
git push -q origin patch-empty
git checkout -q main

# Run sync
output=$("$PATCHSTACK" sync 2>&1)

# Verify output indicates no patches found (branch has no commits beyond base)
if echo "$output" | grep -q "No patches to sync\|Found 0 patch branches"; then
    echo "✓ No patches detected (branch has no commits)"
else
    echo "✗ Expected no patches to sync"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify temporary ref does not exist
if find_patchstack_ref "patch-empty" >/dev/null 2>&1; then
    echo "✗ Temporary ref exists but should not"
    cleanup_test_env
    exit 1
else
    echo "✓ Temporary ref does not exist (expected)"
fi

# Cleanup
cleanup_test_env

echo "✓ Test passed: no new commits"
