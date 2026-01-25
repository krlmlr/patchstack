#!/usr/bin/env bash
# Test Harness for Patchstack
# Provides functions to create isolated Git repositories and snapshot testing

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global test variables
TEST_DIR=""
UPSTREAM_DIR=""
FORK_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Path to patchstack script
PATCHSTACK="$SCRIPT_DIR/../scripts/patchstack"

# Setup a test environment with upstream and fork repositories
setup_test_env() {
    TEST_DIR=$(mktemp -d)
    UPSTREAM_DIR="$TEST_DIR/upstream"
    FORK_DIR="$TEST_DIR/fork"

    # Create upstream repository
    git init -q --initial-branch=main "$UPSTREAM_DIR"
    cd "$UPSTREAM_DIR"
    git config user.email "test@patchstack.test"
    git config user.name "Test User"
    echo "# Upstream Repository" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    # Clone to fork
    git clone -q "$UPSTREAM_DIR" "$FORK_DIR"
    cd "$FORK_DIR"
    git config user.email "test@patchstack.test"
    git config user.name "Test User"

    # Set up remotes: rename origin to upstream, add origin pointing to self
    git remote rename origin upstream
    git remote add origin "$FORK_DIR"

    # Fetch from origin to populate refs/remotes/origin/*
    git fetch -q origin

    echo "$FORK_DIR"
}

# Clean up test environment
cleanup_test_env() {
    if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
    UPSTREAM_DIR=""
    FORK_DIR=""
}

# Create a patch branch with specified number of commits
create_patch_branch() {
    local branch_name=$1
    local num_commits=${2:-1}

    # Create and checkout new branch
    git checkout -q -b "$branch_name"

    # Add commits
    for ((i=1; i<=num_commits; i++)); do
        echo "Change $i in $branch_name" >> "file-$branch_name.txt"
        git add "file-$branch_name.txt"
        git commit -q -m "$branch_name: commit $i"
    done

    # Push to origin
    git push -q origin "$branch_name"

    # Return to main
    git checkout -q main
}

# Advance upstream repository by adding commits
advance_upstream() {
    local num_commits=${1:-1}
    local current_dir
    current_dir=$(pwd)

    cd "$UPSTREAM_DIR"

    for ((i=1; i<=num_commits; i++)); do
        echo "Upstream change $i" >> upstream-file.txt
        git add upstream-file.txt
        git commit -q -m "Upstream commit $i"
    done

    local new_head
    new_head=$(git rev-parse HEAD)
    cd "$current_dir"
    echo "$new_head"
}

# Create a conflict in a patch branch
create_conflict_in_patch() {
    local patch_name=$1
    local current_dir
    current_dir=$(pwd)

    # First, modify upstream to create conflicting content
    cd "$UPSTREAM_DIR"
    echo "Conflicting content from upstream" > conflict-file.txt
    git add conflict-file.txt
    git commit -q -m "Add conflicting content"

    # Now modify the patch branch with conflicting content
    cd "$current_dir"
    git checkout -q "$patch_name"
    echo "Conflicting content from patch" > conflict-file.txt
    git add conflict-file.txt
    git commit -q -m "Add conflicting content in patch"
    git push -q -f origin "$patch_name"
    git checkout -q main
}

# Assertion: Check if two values are equal
assert_equal() {
    local expected=$1
    local actual=$2
    local message=${3:-""}

    if [[ "$expected" != "$actual" ]]; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        [[ -n "$message" ]] && echo "  Message:  $message"
        return 1
    fi
}

# Assertion: Check if branch exists
assert_branch_exists() {
    local branch_ref=$1

    if ! git show-ref -q "$branch_ref"; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Branch does not exist: $branch_ref"
        return 1
    fi
}

# Helper: Find patchstack temporary ref for a branch
# Returns the full ref path (refs/patchstack/runs/RUN_ID/BRANCH)
find_patchstack_ref() {
    local branch_name=$1
    
    # Find refs matching refs/patchstack/runs/*/BRANCH_NAME
    local ref
    ref=$(git for-each-ref --format='%(refname)' "refs/patchstack/runs/*/$branch_name" 2>/dev/null | head -1)
    
    if [[ -z "$ref" ]]; then
        echo -e "${RED}✗ No patchstack ref found for branch: $branch_name${NC}" >&2
        return 1
    fi
    
    echo "$ref"
}

# Helper: Find patchstack integrated main ref
# Returns the full ref path (refs/patchstack/runs/RUN_ID/main)
find_patchstack_main_ref() {
    # Find refs matching refs/patchstack/runs/*/main
    local ref
    ref=$(git for-each-ref --format='%(refname)' "refs/patchstack/runs/*/main" 2>/dev/null | head -1)
    
    if [[ -z "$ref" ]]; then
        echo -e "${RED}✗ No patchstack integrated main ref found${NC}" >&2
        return 1
    fi
    
    echo "$ref"
}

# Assertion: Check if patchstack temporary ref exists for a branch
assert_patchstack_ref_exists() {
    local branch_name=$1
    
    if ! find_patchstack_ref "$branch_name" >/dev/null 2>&1; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Patchstack temporary ref does not exist for branch: $branch_name"
        return 1
    fi
}

# Assertion: Check if patchstack temporary ref does NOT exist for a branch
assert_patchstack_ref_not_exists() {
    local branch_name=$1
    
    if find_patchstack_ref "$branch_name" >/dev/null 2>&1; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Patchstack temporary ref exists but should not for branch: $branch_name"
        return 1
    fi
}

# Assertion: Check if branch does not exist
assert_branch_not_exists() {
    local branch_ref=$1

    if git show-ref -q "$branch_ref"; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Branch exists but should not: $branch_ref"
        return 1
    fi
}

# Assertion: Check if two refs point to the same commit
assert_ref_equals() {
    local ref1=$1
    local ref2=$2

    local sha1
    local sha2
    sha1=$(git rev-parse "$ref1")
    sha2=$(git rev-parse "$ref2")

    if [[ "$sha1" != "$sha2" ]]; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  Refs do not point to same commit"
        echo "  $ref1: $sha1"
        echo "  $ref2: $sha2"
        return 1
    fi
}

# Assertion: Check if string contains substring
assert_contains() {
    local haystack=$1
    local needle=$2

    if [[ ! "$haystack" =~ $needle ]]; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  String does not contain expected substring"
        echo "  Haystack: '$haystack'"
        echo "  Needle:   '$needle'"
        return 1
    fi
}

# Assertion: Check if string does not contain substring
assert_not_contains() {
    local haystack=$1
    local needle=$2

    if [[ "$haystack" =~ $needle ]]; then
        echo -e "${RED}✗ Assertion failed${NC}"
        echo "  String contains unexpected substring"
        echo "  Haystack: '$haystack'"
        echo "  Needle:   '$needle'"
        return 1
    fi
}

# Snapshot testing: compare command output to expected snapshot
# Usage: assert_snapshot "test-name" "$output"
# Environment: SNAPSHOT_UPDATE=1 to update snapshots instead of comparing
assert_snapshot() {
    local test_name=$1
    local actual=$2
    local snapshot_file="$SCRIPT_DIR/snapshots/${test_name}.snap"

    # Create snapshots directory if it doesn't exist
    mkdir -p "$SCRIPT_DIR/snapshots"

    # Scrub nondeterministic output (SHA hashes, timestamps, temp paths)
    local scrubbed
    scrubbed=$(echo "$actual" | scrub_output)

    if [[ ! -f "$snapshot_file" ]]; then
        # Create new snapshot
        echo "$scrubbed" > "$snapshot_file"
        echo -e "${GREEN}✓ Created snapshot: $test_name${NC}"
        return 0
    fi

    # If SNAPSHOT_UPDATE is set, update the snapshot
    if [[ "${SNAPSHOT_UPDATE:-0}" == "1" ]]; then
        echo "$scrubbed" > "$snapshot_file"
        echo -e "${GREEN}✓ Updated snapshot: $test_name${NC}"
        return 0
    fi

    # Compare with existing snapshot
    local expected
    expected=$(cat "$snapshot_file")

    if [[ "$scrubbed" != "$expected" ]]; then
        echo -e "${RED}✗ Snapshot mismatch: $test_name${NC}"
        echo
        # Show diff as a unified patch
        diff -u "$snapshot_file" <(echo "$scrubbed") || true
        echo
        echo "To update snapshot: run with --apply flag"
        return 1
    fi

    echo -e "${GREEN}✓ Snapshot matches: $test_name${NC}"
}

# Scrub nondeterministic output from test results
scrub_output() {
    sed -e 's|/tmp/[^/]*|/tmp/TEMP_DIR|g' \
        -e 's|[0-9a-f]\{40\}|COMMIT_SHA|g' \
        -e 's|[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}|DATE|g' \
        -e 's|[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}|TIME|g'
}

# Run a test and capture its output for snapshot testing
run_snapshot_test() {
    local test_name=$1
    local setup_func=$2

    # Setup test environment
    $setup_func

    # Run patchstack command and capture output
    local output
    output=$("$PATCHSTACK" list 2>&1 || true)

    # Assert snapshot
    assert_snapshot "$test_name" "$output"

    # Cleanup
    cleanup_test_env
}
