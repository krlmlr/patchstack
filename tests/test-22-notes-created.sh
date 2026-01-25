#!/usr/bin/env bash
# Test: Notes created for all processed branches
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create a real remote (bare repository)
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

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check notes exist for new main
new_main=$(git rev-parse origin/main)
notes=$(git notes --ref=patchstack show "$new_main" 2>/dev/null || echo "")

if [[ -z "$notes" ]]; then
    echo "ERROR: Notes should exist for new main"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes exist for new main"

# Notes should contain metadata
if ! echo "$notes" | grep -q "Patchstack sync"; then
    echo "ERROR: Notes should contain sync metadata"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes contain sync metadata"

if ! echo "$notes" | grep -q "main"; then
    echo "ERROR: Notes should contain branch name"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes contain branch name"

# Check notes for patch-alpha
new_alpha=$(git rev-parse origin/patch-alpha)
alpha_notes=$(git notes --ref=patchstack show "$new_alpha" 2>/dev/null || echo "")

if [[ -z "$alpha_notes" ]]; then
    echo "ERROR: Notes should exist for patch-alpha"
    cleanup_test_env
    exit 1
fi
echo "✓ Notes exist for patch-alpha"

# Cleanup
cleanup_test_env

echo "✓ Test passed: notes created"
