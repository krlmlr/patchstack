# Phase 1.1: Test Harness + Branch Discovery

**Goal:** Create the test infrastructure and implement patch branch discovery logic.

## Overview

This phase establishes the foundation for all future development:

1. A test harness that creates isolated Git repositories
2. Branch discovery logic that finds and sorts patch branches
3. Tests that verify the discovery logic works correctly

## Part 1: Test Harness

### File: `tests/test-harness.sh`

Create a test harness that provides:

#### Core Functions

**`setup_test_env()`**

- Creates two temporary Git repositories: upstream and fork
- Returns paths to both repos (or sets global variables)
- Sets up proper remote relationships:
    - Fork has `upstream` remote pointing to upstream repo
    - Fork has `origin` remote pointing to itself (simulates GitHub fork)
- Creates initial commit history in both repos
- Both repos share common initial commits

**Example Setup:**

```bash
setup_test_env() {
    TEST_DIR=$(mktemp -d)
    UPSTREAM_DIR="$TEST_DIR/upstream"
    FORK_DIR="$TEST_DIR/fork"

    # Create upstream
    git init "$UPSTREAM_DIR"
    cd "$UPSTREAM_DIR"
    git commit --allow-empty -m "Initial commit"

    # Clone to fork
    git clone "$UPSTREAM_DIR" "$FORK_DIR"
    cd "$FORK_DIR"
    git remote rename origin upstream
    git remote add origin "$FORK_DIR"  # Points to self

    echo "$FORK_DIR"  # Return fork directory
}
```

**`cleanup_test_env()`**

- Removes temporary test directories
- Should be called after each test or in trap
- Safe to call even if setup failed

**`create_patch_branch(name, num_commits)`**

- Creates a new branch from current HEAD
- Adds specified number of commits
- Commits modify files so they're not empty
- Pushes to origin (simulated remote)

**Example:**

```bash
create_patch_branch "patch-feature-auth" 3
# Creates branch with 3 commits, pushes to origin/patch-feature-auth
```

**`advance_upstream(num_commits)`**

- Adds commits to upstream/main
- Simulates upstream repository advancing
- Returns SHA of new upstream HEAD

**`create_conflict_in_patch(patch_name)`**

- Modifies a patch branch to create a rebase conflict
- Changes same lines that will exist in upstream
- Used to test conflict handling

#### Assertion Functions

**`assert_equal(expected, actual, [message])`**

- Compares two values
- Prints clear error if they differ
- Optional message for context

**`assert_branch_exists(branch_ref)`**

- Verifies a branch reference exists
- Example: `assert_branch_exists "refs/remotes/origin/patch-feature"`

**`assert_branch_not_exists(branch_ref)`**

- Verifies a branch reference does not exist

**`assert_ref_equals(ref1, ref2)`**

- Verifies two refs point to same SHA
- Example: `assert_ref_equals "origin/main" "refs/heads/tmp/patchstack-main"`

**`assert_contains(haystack, needle)`**

- Verifies string contains substring
- Useful for checking command output

### Test Runner

**File: `tests/run-all-tests.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source test harness
source "$(dirname "$0")/test-harness.sh"

# Track results
PASSED=0
FAILED=0
FAILED_TESTS=()

run_test() {
    local test_file=$1
    local test_name=$(basename "$test_file" .sh)

    echo "Running $test_name..."
    if bash "$test_file"; then
        echo "✓ $test_name passed"
        ((PASSED++))
    else
        echo "✗ $test_name FAILED"
        ((FAILED++))
        FAILED_TESTS+=("$test_name")
    fi
    echo
}

# Run all test files
for test_file in tests/test-*.sh; do
    run_test "$test_file"
done

# Report
echo "========================"
echo "Results: $PASSED passed, $FAILED failed"
if [ $FAILED -gt 0 ]; then
    echo "Failed tests:"
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
```

## Part 2: Branch Discovery Logic

### File: `scripts/patchstack`

Create the main script with branch discovery:

#### Script Structure

```bash
#!/usr/bin/env bash
set -euo pipefail

# Default configuration (zero-config)
PATCH_REMOTE="${PATCH_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

# Main entry point
main() {
    local command="${1:-}"

    case "$command" in
        sync)
            cmd_sync
            ;;
        list)
            cmd_list
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

usage() {
    cat <<EOF
Usage: patchstack <command>

Commands:
    sync    Synchronize patch stack with upstream
    list    List patch branches
EOF
}

main "$@"
```

#### Branch Discovery Function

**`discover_patch_branches()`**

Algorithm:

1. Get current state of `origin/main` (the base for patch branches)
2. List all `refs/remotes/origin/*` branches
3. Exclude `origin/main` itself
4. Filter to only branches that are descendants of `origin/main`
5. Extract branch name (remove `patch-` prefix for sorting, or sort by full name)
6. Sort lexicographically
7. Return array of branch names

**Implementation Notes:**

```bash
discover_patch_branches() {
    local base_ref="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"
    local base_sha=$(git rev-parse "$base_ref")

    # Get all remote branches
    local branches=()
    while IFS= read -r ref; do
        # Skip main branch
        [[ "$ref" == "$base_ref" ]] && continue

        # Check if descendant
        local branch_sha=$(git rev-parse "$ref")
        if git merge-base --is-ancestor "$base_sha" "$branch_sha" 2>/dev/null; then
            # Extract branch name
            local branch_name=${ref#refs/remotes/$PATCH_REMOTE/}
            branches+=("$branch_name")
        fi
    done < <(git for-each-ref --format='%(refname)' "refs/remotes/$PATCH_REMOTE")

    # Sort lexicographically
    printf '%s\n' "${branches[@]}" | sort
}
```

**Key Git Commands:**

- `git for-each-ref` - List all refs matching pattern
- `git merge-base --is-ancestor` - Check if one commit is ancestor of another
- `git rev-parse` - Convert ref name to SHA

#### List Command

**`cmd_list()`**

- Calls `discover_patch_branches()`
- Prints each branch on a line
- Shows count at the end

Example output:

```
patch-feature-auth
patch-fix-logging
patch-update-deps

Found 3 patch branches
```

## Part 3: Tests for Discovery

### File: `tests/test-discovery.sh`

Create comprehensive tests:

#### Test 1: No Patch Branches

```bash
test_no_patches() {
    local fork=$(setup_test_env)
    cd "$fork"

    local patches=$(./scripts/patchstack list)
    assert_equal "0" "$(echo "$patches" | grep -c 'patch-' || true)"

    cleanup_test_env
}
```

#### Test 2: Three Patch Branches

```bash
test_three_patches() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create patches out of order
    create_patch_branch "patch-zebra" 1
    create_patch_branch "patch-alpha" 2
    create_patch_branch "patch-beta" 1

    local patches=$(./scripts/patchstack list | grep patch-)

    # Should be sorted lexicographically
    assert_equal "patch-alpha" "$(echo "$patches" | sed -n '1p')"
    assert_equal "patch-beta" "$(echo "$patches" | sed -n '2p')"
    assert_equal "patch-zebra" "$(echo "$patches" | sed -n '3p')"

    cleanup_test_env
}
```

#### Test 3: Excludes Non-Descendants

```bash
test_excludes_non_descendants() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create branch that is NOT a descendant of origin/main
    git checkout -b patch-orphan --orphan
    git commit --allow-empty -m "Orphan commit"
    git push origin patch-orphan

    # Create normal patch branch
    git checkout main
    create_patch_branch "patch-normal" 1

    local patches=$(./scripts/patchstack list | grep patch-)

    # Should only see patch-normal
    assert_equal "1" "$(echo "$patches" | wc -l)"
    assert_contains "$patches" "patch-normal"

    cleanup_test_env
}
```

#### Test 4: Excludes Main Branch

```bash
test_excludes_main() {
    local fork=$(setup_test_env)
    cd "$fork"

    create_patch_branch "patch-test" 1

    local patches=$(./scripts/patchstack list)

    # Should not include 'main' in output
    assert_equal "0" "$(echo "$patches" | grep -c '^main$' || true)"

    cleanup_test_env
}
```

#### Test 5: Empty Result When Only Main Exists

```bash
test_only_main_exists() {
    local fork=$(setup_test_env)
    cd "$fork"

    local patches=$(./scripts/patchstack list | grep patch- || true)
    assert_equal "" "$patches"

    cleanup_test_env
}
```

## Testing Process

### Run Tests

```bash
cd /path/to/patchstack
chmod +x tests/*.sh scripts/patchstack
./tests/run-all-tests.sh
```

### Expected Output

```
Running test-discovery...
✓ test-discovery passed

========================
Results: 1 passed, 0 failed
```

## Success Criteria

- [ ] Test harness can create isolated Git repositories
- [ ] Test harness provides useful helper functions
- [ ] Branch discovery correctly identifies patch branches
- [ ] Branch discovery excludes main branch
- [ ] Branch discovery filters by ancestry
- [ ] Branch discovery sorts lexicographically
- [ ] All 5+ tests pass
- [ ] Tests run in <2 seconds
- [ ] Tests clean up after themselves

## Next Phase

Once this phase is complete:

- Tests for Phase 1.2 will use this harness
- Branch discovery will be called by the sync command
- We can focus on rebase logic knowing discovery works correctly
