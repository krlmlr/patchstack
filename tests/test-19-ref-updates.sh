#!/usr/bin/env bash
# Test: Successful sync updates all local remote refs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Record initial SHAs
initial_main=$(git rev-parse origin/main)

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1

initial_alpha=$(git rev-parse origin/patch-alpha)
initial_beta=$(git rev-parse origin/patch-beta)

# Advance upstream
advance_upstream 1

# Fetch upstream changes
git fetch -q upstream

# Run sync
"$PATCHSTACK" sync >/dev/null 2>&1

# Check main was updated
new_main=$(git rev-parse origin/main)
if [[ "$new_main" == "$initial_main" ]]; then
    echo "ERROR: origin/main should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ origin/main was updated"

# Check patches were updated
new_alpha=$(git rev-parse origin/patch-alpha)
new_beta=$(git rev-parse origin/patch-beta)

if [[ "$new_alpha" == "$initial_alpha" ]]; then
    echo "ERROR: origin/patch-alpha should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ origin/patch-alpha was updated"

if [[ "$new_beta" == "$initial_beta" ]]; then
    echo "ERROR: origin/patch-beta should be updated"
    cleanup_test_env
    exit 1
fi
echo "✓ origin/patch-beta was updated"

# Check patches are based on upstream
upstream_main=$(git rev-parse upstream/main)
if ! git merge-base --is-ancestor "$upstream_main" "$new_alpha"; then
    echo "ERROR: patch-alpha should have upstream as ancestor"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-alpha is based on upstream"

if ! git merge-base --is-ancestor "$upstream_main" "$new_beta"; then
    echo "ERROR: patch-beta should have upstream as ancestor"
    cleanup_test_env
    exit 1
fi
echo "✓ patch-beta is based on upstream"

# Cleanup
cleanup_test_env

echo "✓ Test passed: ref updates"
