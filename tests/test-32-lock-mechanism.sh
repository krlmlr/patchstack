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

# Add a slow pre-receive hook to make the push take longer
cd "$REMOTE_DIR"
mkdir -p hooks
cat > hooks/pre-receive << 'HOOK_EOF'
#!/bin/bash
# Make push slow to give time for lock testing
sleep 3
HOOK_EOF
chmod +x hooks/pre-receive

cd "$FORK_DIR"

# Create multiple patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 2

# Advance upstream
advance_upstream 1
git fetch -q upstream

# Start first sync in background and capture its output
"$PATCHSTACK" sync > /tmp/sync1-$$.log 2>&1 &
FIRST_PID=$!

# Give it a moment to acquire the lock and get past discovery
sleep 1

# Check that first process is still running
if ! ps -p "$FIRST_PID" > /dev/null 2>&1; then
    echo "✗ First sync completed too quickly for test"
    cat /tmp/sync1-$$.log || true
    cleanup_test_env
    exit 1
fi
echo "✓ First sync still running"

# Try to start second sync and capture output
second_output=$("$PATCHSTACK" sync 2>&1) || second_exit=$?

# Check if second sync was blocked
if echo "$second_output" | grep -q "Another patchstack process is already running"; then
    echo "✓ Second sync correctly blocked by lock"
else
    echo "✗ Second sync should have been blocked by lock"
    echo "Second sync output:"
    echo "$second_output"
    echo "Second sync exit code: ${second_exit:-0}"
    # Clean up background process
    if ps -p "$FIRST_PID" > /dev/null 2>&1; then
        kill -TERM "$FIRST_PID" 2>/dev/null || true
        sleep 1
    fi
    wait "$FIRST_PID" 2>/dev/null || true
    cleanup_test_env
    exit 1
fi

# Wait for first sync to complete
wait "$FIRST_PID" 2>/dev/null || first_exit=$?

# Check that first sync succeeded
if [[ "${first_exit:-0}" -ne 0 ]]; then
    echo "First sync failed with exit code ${first_exit}"
    cat /tmp/sync1-$$.log || true
fi

# Verify we can run sync again after first completes
if "$PATCHSTACK" list &>/dev/null; then
    echo "✓ Commands work after first sync completes"
else
    echo "✗ Commands should work after first sync"
    cleanup_test_env
    exit 1
fi

# Cleanup
rm -f /tmp/sync1-$$.log
cleanup_test_env

echo "✓ Test passed: lock mechanism works"
