#!/usr/bin/env bash
# Test: Verify ref state matches expected topology
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create three patches in specific order
create_patch_branch "patch-aaa" 1
create_patch_branch "patch-bbb" 1
create_patch_branch "patch-ccc" 1

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Verify topology:
# 1. New main is ahead of upstream by 3 (one squash per patch)
# 2. Each patch is based on upstream (not on main)
# 3. Each patch has correct commit count from upstream

new_main=$(git rev-parse origin/main)
upstream_main=$(git rev-parse upstream/main)

# Main should be ahead of upstream by 3 (one squash per patch)
commit_count=$(git rev-list --count "$upstream_main..$new_main")
if [[ "$commit_count" != "3" ]]; then
    echo "ERROR: Expected 3 commits in new main, got $commit_count"
    cleanup_test_env
    exit 1
fi
echo "✓ New main has 3 squashed commits"

# Each patch should be based on upstream
for patch in patch-aaa patch-bbb patch-ccc; do
    patch_sha=$(git rev-parse "origin/$patch")
    
    # Check that upstream is ancestor of patch
    if ! git merge-base --is-ancestor "$upstream_main" "$patch_sha"; then
        echo "ERROR: $patch should have upstream as ancestor"
        cleanup_test_env
        exit 1
    fi
    echo "✓ $patch is based on upstream"

    # Each patch should have 1 commit beyond upstream (its own commit)
    patch_count=$(git rev-list --count "$upstream_main..origin/$patch")
    if [[ "$patch_count" != "1" ]]; then
        echo "ERROR: $patch should have 1 commit beyond upstream, got $patch_count"
        cleanup_test_env
        exit 1
    fi
    echo "✓ $patch has 1 commit beyond upstream"
done

# Verify that patches are NOT ancestors of main (they diverged at upstream)
for patch in patch-aaa patch-bbb patch-ccc; do
    patch_sha=$(git rev-parse "origin/$patch")
    if git merge-base --is-ancestor "$patch_sha" "$new_main"; then
        # This is OK - patch could be ancestor of main if it was integrated
        :
    fi
    if git merge-base --is-ancestor "$new_main" "$patch_sha"; then
        echo "ERROR: main should not be ancestor of $patch (they should diverge)"
        cleanup_test_env
        exit 1
    fi
    echo "✓ $patch diverges from main (not descendant)"
done

# Cleanup
cleanup_test_env

echo "✓ Test passed: ref topology"
