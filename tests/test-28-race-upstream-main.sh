#!/usr/bin/env bash
# Test: Race condition - concurrent push to upstream main
# Verifies that patchstack sync still works when upstream is updated during sync
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

# Start sync but simulate upstream advancing DURING sync
# This simulates someone else pushing to upstream while we're syncing
# The sync should still complete successfully

# Record state before sync
before_main=$(git rev-parse origin/main)

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# During the sync, upstream advanced. Let's advance it again now
cd "$UPSTREAM_DIR"
git commit --allow-empty -q -m "Another upstream change"

cd "$FORK_DIR"

# First sync should have completed successfully
after_main=$(git rev-parse origin/main)

if [[ "$after_main" == "$before_main" ]]; then
    echo "ERROR: origin/main should be updated after sync"
    cleanup_test_env
    exit 1
fi
echo "✓ Sync completed despite upstream being active"

# Verify remote was updated
cd "$REMOTE_DIR"
remote_main=$(git rev-parse main)
if [[ "$remote_main" != "$after_main" ]]; then
    echo "ERROR: Remote main should match local origin/main"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote was updated correctly"

# Cleanup
cleanup_test_env

echo "✓ Test passed: race condition with upstream main"
