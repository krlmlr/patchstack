#!/usr/bin/env bash
# Test: Atomic push succeeds with all refs updated together
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create a real remote (not just local)
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patches
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 1

# Push patches to remote
git push origin patch-alpha patch-beta

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Record remote state before sync
cd "$REMOTE_DIR"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)
before_beta=$(git rev-parse patch-beta)

cd "$FORK_DIR"

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check remote was updated
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)
after_beta=$(git rev-parse patch-beta)

if [[ "$after_main" == "$before_main" ]]; then
    echo "ERROR: Remote main should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote main was updated"

if [[ "$after_alpha" == "$before_alpha" ]]; then
    echo "ERROR: Remote patch-alpha should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-alpha was updated"

if [[ "$after_beta" == "$before_beta" ]]; then
    echo "ERROR: Remote patch-beta should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ Remote patch-beta was updated"

# Cleanup
cleanup_test_env

echo "✓ Test passed: atomic push success"
