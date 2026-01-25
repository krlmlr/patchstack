#!/usr/bin/env bash
# Test: Failed patch keeps old ref unchanged
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create clean patch
create_patch_branch "patch-alpha" 1
initial_alpha=$(git rev-parse origin/patch-alpha)

# Create conflicting patch
git checkout -q -b patch-beta origin/main
echo "content" > conflict.txt
git add conflict.txt
git commit -q -m "Beta: add conflict file"
git push -q origin patch-beta
initial_beta=$(git rev-parse origin/patch-beta)

# Advance upstream with conflicting change
cd "$UPSTREAM_DIR"
echo "different-content" > conflict.txt
git add conflict.txt
git commit -q -m "Upstream: add conflict file"

cd "$FORK_DIR"
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check patch-alpha was updated
new_alpha=$(git rev-parse origin/patch-alpha)
if [[ "$new_alpha" == "$initial_alpha" ]]; then
    echo "ERROR: patch-alpha should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha was updated"

# Check patch-beta was NOT updated (conflict)
new_beta=$(git rev-parse origin/patch-beta)
if [[ "$new_beta" != "$initial_beta" ]]; then
    echo "ERROR: patch-beta should remain unchanged (got $new_beta, expected $initial_beta)"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-beta remains unchanged (conflict)"

# Cleanup
cleanup_test_env

echo "✓ Test passed: failed patch unchanged"
