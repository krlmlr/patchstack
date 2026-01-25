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

# Start 5 sync processes in parallel without sleeping
PIDS=()
OUTPUTS=()
for i in {1..5}; do
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

# Check outputs - at least one should have failed with lock error
success_count=0
failure_count=0

for output_file in "${OUTPUTS[@]}"; do
    if grep -q "Another patchstack process is already running" "$output_file"; then
        ((failure_count++)) || true
    elif grep -q "Remote updated\|No patches to sync" "$output_file"; then
        ((success_count++)) || true
    else
        echo "✗ Unexpected output in $output_file:"
        cat "$output_file"
        cleanup_test_env
        exit 1
    fi
done

echo "Success: $success_count, Failed (locked): $failure_count"

# Verify at least one failed due to lock
if [[ $failure_count -lt 1 ]]; then
    echo "✗ Expected at least one process to fail due to lock"
    echo "All outputs:"
    for i in {1..5}; do
        echo "=== Output $i ==="
        cat "$TEST_DIR/sync-$i.log"
    done
    cleanup_test_env
    exit 1
fi
echo "✓ At least one process correctly blocked by lock"

# Verify at least one succeeded
if [[ $success_count -lt 1 ]]; then
    echo "✗ Expected at least one process to succeed"
    cleanup_test_env
    exit 1
fi
echo "✓ At least one process succeeded"

# Cleanup
cleanup_test_env

echo "✓ Test passed: lock mechanism works"
