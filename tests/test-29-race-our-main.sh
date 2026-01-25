#!/usr/bin/env bash
# Test: Race condition - concurrent push to our main
# Tests force-with-lease atomicity when someone else pushes to our main
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch
create_patch_branch "patch-alpha" 1
git push origin patch-alpha

# Advance upstream
advance_upstream 1
git fetch -q upstream

# Simulate concurrent push: someone else pushes to OUR main while we're syncing
# This should cause the lease check to fail and abort the entire atomic push

# Record remote state before sync
cd "$REMOTE_DIR"
git config user.email "test@patchstack.test"
git config user.name "Test User"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)

# Create a concurrent commit on main (simulating another user's push)
tree_sha=$(git rev-parse main^{tree})
concurrent_commit=$(echo "Concurrent push to main" | git commit-tree "$tree_sha" -p "$before_main")
git update-ref refs/heads/main "$concurrent_commit"

concurrent_main=$(git rev-parse main)
echo "✓ Simulated concurrent push to main: $before_main -> $concurrent_main"

cd "$FORK_DIR"

# Run sync - should fail due to lease on main
if "$PATCHSTACK" sync >/dev/null 2>&1; then
    echo "ERROR: Sync should fail due to concurrent push to main"
    cleanup_test_env
    exit 1
fi
echo "✓ Sync failed as expected due to lease violation"

# Verify remote was NOT updated (atomic failure - all or nothing)
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)

if [[ "$after_main" != "$concurrent_main" ]]; then
    echo "ERROR: Remote main should not change after failed push"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote main unchanged (still at concurrent commit)"

if [[ "$after_alpha" != "$before_alpha" ]]; then
    echo "ERROR: Remote patch-alpha should not be updated after atomic failure"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-alpha unchanged (atomic rollback)"

# Cleanup
cleanup_test_env

echo "✓ Test passed: race condition with our main (lease protected)"
