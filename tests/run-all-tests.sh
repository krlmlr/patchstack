#!/usr/bin/env bash
# Test Runner for Patchstack
# Runs all test files and reports results
# Usage: ./run-all-tests.sh [--apply]
#   --apply: Update snapshots instead of comparing

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
SNAPSHOT_UPDATE=0
if [[ "${1:-}" == "--apply" ]]; then
    SNAPSHOT_UPDATE=1
    export SNAPSHOT_UPDATE
    echo "Running in snapshot update mode..."
    echo
fi

# Track results
PASSED=0
FAILED=0
FAILED_TESTS=()

# Run a single test file
run_test() {
    local test_file=$1
    local test_name
    test_name=$(basename "$test_file" .sh)

    echo "Running $test_name..."
    if bash "$test_file"; then
        echo "✓ $test_name passed"
        ((PASSED++)) || true
    else
        echo "✗ $test_name FAILED"
        ((FAILED++)) || true
        FAILED_TESTS+=("$test_name")
    fi
    echo
}

# Find and run all test files
for test_file in "$SCRIPT_DIR"/test-*.sh; do
    # Skip if no test files found
    [[ -e "$test_file" ]] || continue
    run_test "$test_file"
done

# Report results
echo "========================"
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    echo "Failed tests:"
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi

echo "All tests passed!"
exit 0
