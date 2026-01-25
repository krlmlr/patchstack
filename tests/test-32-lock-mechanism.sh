#!/usr/bin/env bash
# Test: Lock mechanism prevents concurrent runs
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
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 2

# Advance upstream
advance_upstream 1
git fetch -q upstream

# Start 10 sync processes in parallel without sleeping
PIDS=()
OUTPUTS=()
for i in {1..10}; do
    output_file="$TEST_DIR/sync-$i.log"
    OUTPUTS+=("$output_file")
    "$PATCHSTACK" sync > "$output_file" 2>&1 &
    PIDS+=($!)
done

echo "✓ Started ${#PIDS[@]} sync processes in parallel"

# Wait for all processes to complete
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo "✓ All processes completed"

# Check outputs - with local locks, the processes can be:
# 1. Synced successfully (first one and possibly others if they run after the first completes)
# 2. Locked out (if they tried during the first sync)
# 3. Found nothing to sync (shouldn't happen with current logic)
synced_count=0
no_patches_count=0
locked_count=0

for output_file in "${OUTPUTS[@]}"; do
    if grep -q "Another patchstack process is already running" "$output_file"; then
        ((locked_count++)) || true
    elif grep -q "Synced: 2 patches" "$output_file"; then
        ((synced_count++)) || true
    elif grep -q "No patches to sync\|Found 0 patch branches" "$output_file"; then
        ((no_patches_count++)) || true
    else
        echo "✗ Unexpected output in $output_file:"
        cat "$output_file"
        cleanup_test_env
        exit 1
    fi
done

echo "Synced: $synced_count, No patches: $no_patches_count, Locked: $locked_count"

# Verify at least one process did the sync work
if [[ $synced_count -lt 1 ]]; then
    echo "✗ Expected at least one process to sync patches, got $synced_count"
    echo "All outputs:"
    for i in {1..5}; do
        echo "=== Output $i ==="
        cat "$TEST_DIR/sync-$i.log"
    done
    cleanup_test_env
    exit 1
fi
echo "✓ At least one process synced the patches"

# Verify the lock blocked some processes
if [[ $locked_count -lt 1 ]]; then
    echo "✗ Expected at least one process to be blocked by lock, got $locked_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Lock mechanism blocked concurrent processes"

# Cleanup
cleanup_test_env

echo "✓ Test passed: lock mechanism works"
