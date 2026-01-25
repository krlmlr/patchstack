#!/usr/bin/env bash
# Test: Verify notes pushed to remote
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

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Fetch notes from remote
if ! git fetch origin refs/notes/patchstack:refs/notes/patchstack-remote 2>/dev/null; then
    echo "ERROR: Failed to fetch notes from remote"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes fetched from remote"

# Check notes exist for new main
new_main=$(git rev-parse origin/main)
notes=$(git notes --ref=patchstack-remote show "$new_main" 2>/dev/null || echo "")

if [[ -z "$notes" ]]; then
    echo "ERROR: Notes should exist for new main"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes exist for new main"

if ! echo "$notes" | grep -q "Patchstack sync"; then
    echo "ERROR: Notes should contain sync metadata"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes contain sync metadata"

# Cleanup
cleanup_test_env

echo "✓ Test passed: notes pushed"
