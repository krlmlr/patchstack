#!/usr/bin/env bash
# Test: Empty patch detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create a patch with a change
git checkout -q -b patch-feature
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "Add feature"
git push -q origin patch-feature
git checkout -q main

# Apply exact same change to upstream (making the patch empty when replayed)
cd "$UPSTREAM_DIR"
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "Add feature (upstream)"

# Fetch in fork
cd "$FORK_DIR"
git fetch -q upstream

# Run sync - should detect empty patch
output=$("$PATCHSTACK" sync 2>&1)

# Verify output shows empty
if echo "$output" | grep -q "empty"; then
    echo "✓ Empty patch detected in output"
else
    echo "✗ Empty patch not detected in output"
    echo "$output"
    cleanup_test_env
    exit 1
fi

# Verify temporary ref does not exist (empty patch)
if git show-ref -q refs/patchstack/tmp/patch-feature; then
    echo "✗ Temporary ref exists but should not (empty patch)"
    cleanup_test_env
    exit 1
else
    echo "✓ Temporary ref does not exist (expected for empty patch)"
fi

# Cleanup
cleanup_test_env

echo "✓ Test passed: empty patch detection"
