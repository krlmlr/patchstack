#!/usr/bin/env bash
# Test: Atomic push with lease failure aborts all updates
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

# Fetch upstream changes
git fetch -q upstream

# Simulate concurrent update: someone else pushes to remote
cd "$REMOTE_DIR"
# Configure git for the bare repo
git config user.email "test@patchstack.test"
git config user.name "Test User"
# Advance main to simulate another sync
# Create a new commit on top of main
main_sha=$(git rev-parse main)
tree_sha=$(git rev-parse "main^{tree}")
new_commit=$(echo "Concurrent change" | git commit-tree "$tree_sha" -p "$main_sha")
git update-ref refs/heads/main "$new_commit"

cd "$FORK_DIR"

# Record remote state
cd "$REMOTE_DIR"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)

cd "$FORK_DIR"

# Run sync - should fail due to lease
if "$PATCHSTACK" sync >/dev/null 2>&1; then
    echo "ERROR: Sync should fail due to concurrent update"
    cleanup_test_env
    exit 1
fi
echo "✓ Sync failed as expected due to lease"

# Check remote was NOT updated (atomic failure)
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)

if [[ "$after_main" != "$before_main" ]]; then
    echo "ERROR: Remote main should NOT be updated after lease failure"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote main was not updated (atomic)"

if [[ "$after_alpha" != "$before_alpha" ]]; then
    echo "ERROR: Remote patch-alpha should NOT be updated after lease failure"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-alpha was not updated (atomic)"

# Cleanup
cleanup_test_env

echo "✓ Test passed: lease failure"
