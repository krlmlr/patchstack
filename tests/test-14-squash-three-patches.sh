#!/usr/bin/env bash
# Test: Squash 3 clean patches into new main
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create three patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 3
create_patch_branch "patch-gamma" 1

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check integration ref exists
if ! git rev-parse refs/patchstack/tmp/main >/dev/null 2>&1; then
    echo "ERROR: Integration ref not created"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration ref created"

# Check integration ref has 3 commits beyond upstream
upstream_sha=$(git rev-parse upstream/main)
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count "$upstream_sha..$integration_sha")

if [ "$commit_count" != "3" ]; then
    echo "ERROR: Expected 3 commits, got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Integration has 3 commits beyond upstream"

# Check squash commit messages contain patch names
log_output=$(git log --oneline "$upstream_sha..$integration_sha")

if ! echo "$log_output" | grep -q "patch-alpha"; then
    echo "ERROR: Missing patch-alpha in log"
    cleanup_test_env
    exit 1
fi

if ! echo "$log_output" | grep -q "patch-beta"; then
    echo "ERROR: Missing patch-beta in log"
    cleanup_test_env
    exit 1
fi

if ! echo "$log_output" | grep -q "patch-gamma"; then
    echo "ERROR: Missing patch-gamma in log"
    cleanup_test_env
    exit 1
fi
echo "✓ All patch names present in commit messages"

# Check commits are in lexicographic order (alpha before beta before gamma)
# The log shows most recent first, so gamma should be first line
first_line=$(echo "$log_output" | head -n1)
last_line=$(echo "$log_output" | tail -n1)

if ! echo "$first_line" | grep -q "patch-gamma"; then
    echo "ERROR: patch-gamma should be the most recent commit"
    cleanup_test_env
    exit 1
fi

if ! echo "$last_line" | grep -q "patch-alpha"; then
    echo "ERROR: patch-alpha should be the first commit"
    cleanup_test_env
    exit 1
fi
echo "✓ Commits are in lexicographic order"

# Cleanup
cleanup_test_env

echo "✓ Test passed: squash three patches"
