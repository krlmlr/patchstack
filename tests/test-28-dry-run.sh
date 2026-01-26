#!/usr/bin/env bash
# Test: Dry-run shows planned changes without making them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

# Setup test environment
setup_test_env
cd "$FORK_DIR"

# Create real remote (bare repo)
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch
create_patch_branch "patch-alpha" 1

# Record initial state
git fetch origin
initial_main=$(git rev-parse refs/remotes/origin/main)
initial_alpha=$(git rev-parse refs/remotes/origin/patch-alpha)

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$FORK_DIR"
git fetch upstream

# Run dry-run
output=$("$PATCHSTACK" --dry-run sync 2>&1)

# Verify no changes were made to local refs
final_main=$(git rev-parse refs/remotes/origin/main)
final_alpha=$(git rev-parse refs/remotes/origin/patch-alpha)

assert_equal "$initial_main" "$final_main" "origin/main should not change"
assert_equal "$initial_alpha" "$final_alpha" "origin/patch-alpha should not change"

# Verify remote was not changed
cd "$REMOTE_DIR"
remote_main=$(git rev-parse main)
assert_equal "$initial_main" "$remote_main" "Remote main should not change"

# Verify output mentions dry run
cd "$FORK_DIR"
assert_contains "$output" "DRY RUN"

# Verify output shows what would happen
assert_contains "$output" "Would"

assert_snapshot "28-dry-run" "$output"

cleanup_test_env
echo "✓ Test passed: dry-run shows planned changes without making them"
