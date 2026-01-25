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

# Check outputs - with local locks, only one should do the actual sync work
# The others will either be blocked (if they try during the first sync) or
# find nothing to do (if they run after the first completes)
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

# Verify exactly one process did the sync work
if [[ $synced_count -ne 1 ]]; then
    echo "✗ Expected exactly one process to sync patches, got $synced_count"
    echo "All outputs:"
    for i in {1..5}; do
        echo "=== Output $i ==="
        cat "$TEST_DIR/sync-$i.log"
    done
    cleanup_test_env
    exit 1
fi
echo "✓ Exactly one process synced the patches"

# The other 9 should either be locked or find nothing to do
other_count=$((no_patches_count + locked_count))
if [[ $other_count -ne 9 ]]; then
    echo "✗ Expected 9 other processes, got $other_count"
    cleanup_test_env
    exit 1
fi
echo "✓ Other processes correctly handled (locked or found nothing to sync)"

# Cleanup
cleanup_test_env

echo "✓ Test passed: lock mechanism works"
