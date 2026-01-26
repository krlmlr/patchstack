#!/usr/bin/env bash
# Test: Race condition - concurrent push to one of our patch branches
# Tests force-with-lease atomicity when someone else pushes to a patch branch
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

# Create patches
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 1
git push origin patch-alpha patch-beta

# Advance upstream
advance_upstream 1
git fetch -q upstream

# Simulate concurrent push: someone else force-pushes to patch-alpha while we're syncing
# This should cause the lease check to fail and abort the entire atomic push

# Record remote state before sync
cd "$REMOTE_DIR"
git config user.email "test@patchstack.test"
git config user.name "Test User"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)
before_beta=$(git rev-parse patch-beta)

# Create a concurrent commit on patch-alpha (simulating another user's force-push)
tree_sha=$(git rev-parse "patch-alpha^{tree}")
concurrent_commit=$(echo "Concurrent push to patch-alpha" | git commit-tree "$tree_sha" -p "$before_alpha")
git update-ref refs/heads/patch-alpha "$concurrent_commit"

concurrent_alpha=$(git rev-parse patch-alpha)
echo "✓ Simulated concurrent push to patch-alpha: $before_alpha -> $concurrent_alpha"

cd "$FORK_DIR"

# Run sync - should fail due to lease on patch-alpha
if "$PATCHSTACK" sync >/dev/null 2>&1; then
    echo "ERROR: Sync should fail due to concurrent push to patch-alpha"
    cleanup_test_env
    exit 1
fi
echo "✓ Sync failed as expected due to lease violation on patch branch"

# Verify remote was NOT updated (atomic failure - all or nothing)
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)
after_beta=$(git rev-parse patch-beta)

if [[ "$after_main" != "$before_main" ]]; then
    echo "ERROR: Remote main should not be updated after atomic failure"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote main unchanged (atomic rollback)"

if [[ "$after_alpha" != "$concurrent_alpha" ]]; then
    echo "ERROR: Remote patch-alpha should remain at concurrent commit"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-alpha at concurrent commit (lease violation detected)"

if [[ "$after_beta" != "$before_beta" ]]; then
    echo "ERROR: Remote patch-beta should not be updated after atomic failure"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-beta unchanged (atomic rollback)"

# Cleanup
cleanup_test_env

echo "✓ Test passed: race condition with patch branch (lease protected)"
