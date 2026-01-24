# Phase 1.1: Test Harness + Branch Discovery

**Goal:** Create the test infrastructure and implement patch branch discovery logic.

**Testing Approach:** Snapshot testing - each test runs actual commands and compares output to committed snapshots.

## Overview

This phase establishes the foundation for all future development:

1. A test harness that creates isolated Git repositories
2. Snapshot testing infrastructure for CLI output validation
3. Branch discovery logic that finds and sorts patch branches
4. Individual test files for each test case (test-01-*, test-02-*, etc.)

## Part 1: Test Harness

### File: `tests/harness.sh`

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

#### Snapshot Testing Functions

**`assert_snapshot(test_name, output)`**

- Compares command output to a committed snapshot file
- Creates snapshot if it doesn't exist
- Scrubs nondeterministic output (SHAs, timestamps, paths)
- Shows diff as unified patch if output doesn't match
- Honors SNAPSHOT_UPDATE=1 environment variable to update snapshots
- Snapshots are stored in `tests/snapshots/*.snap` with numeric prefixes

**`scrub_output()`**

- Removes nondeterministic output from test results
- Replaces:
  - Temporary paths: `/tmp/xyz123` → `/tmp/TEMP_DIR`
  - Git SHAs: `a1b2c3d...` → `COMMIT_SHA`
  - Dates/times: `2024-01-24` → `DATE`

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

### Test Structure

Each test is a separate file (test-01-*.sh, test-02-*.sh, etc.) that:

1. Sources the test harness
2. Sets up a specific scenario
3. Runs `patchstack list`
4. Compares output to a snapshot file
5. Cleans up

**Benefits:**

- Each test is counted individually in the test runner
- Tests can be run independently
- Easy to see which specific test failed
- Snapshots make expected output explicit

### File: `tests/test-01-no-patches.sh`

Test: No patch branches

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "no-patches" "$output"
cleanup_test_env
```

### File: `tests/test-02-three-patches.sh`

Test: Three patches sorted lexicographically

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    # Create patches out of order
    create_patch_branch "patch-zebra" 1
    create_patch_branch "patch-alpha" 2
    create_patch_branch "patch-beta" 1
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "three-patches" "$output"
cleanup_test_env
```

### Additional Test Files

- `test-03-excludes-orphan.sh` - Excludes non-descendants
- `test-04-excludes-main.sh` - Excludes main branch
- `test-05-multiple-commits.sh` - Handles multiple commits per branch
- `test-06-no-patch-prefix.sh` - Branches without 'patch-' prefix
- `test-07-single-patch.sh` - Single patch branch

### Snapshot Files

After first run, snapshots are created in `tests/snapshots/` with numeric prefixes:

```
tests/snapshots/
├── 01-no-patches.snap
├── 02-three-patches.snap
├── 03-excludes-orphan.snap
├── 04-excludes-main.snap
├── 05-multiple-commits.snap
├── 06-no-patch-prefix.snap
└── 07-single-patch.snap
```

Example snapshot content (`02-three-patches.snap`):

```
patch-alpha
patch-beta
patch-zebra

Found 3 patch branches
```

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

## Testing Process

### Run Tests

```bash
cd /path/to/patchstack
chmod +x tests/*.sh scripts/patchstack
./tests/run-all-tests.sh
```

### Expected Output

```
Running test-01-no-patches...
✓ Snapshot matches: no-patches
✓ test-01-no-patches passed

Running test-02-three-patches...
✓ Snapshot matches: three-patches
✓ test-02-three-patches passed

[... more tests ...]

========================
Results: 7 passed, 0 failed
All tests passed!
```

### Updating Snapshots

When output format changes:

```bash
# Update all snapshots
./tests/run-all-tests.sh --apply

# Update specific snapshot
SNAPSHOT_UPDATE=1 ./tests/test-01-no-patches.sh

# Review changes
git diff tests/snapshots/

# Commit if correct
git add tests/snapshots/
git commit -m "Update snapshots for new output format"
```

When a test fails, diff is shown as a unified patch:

```
✗ Snapshot mismatch: 04-excludes-main

--- /path/to/tests/snapshots/04-excludes-main.snap
+++ actual output
@@ -1,3 +1,2 @@
 patch-test
-
-Found 1 patch branches
+Found 2 patch branches

To update snapshot: run with --apply flag
```

## Success Criteria

- [ ] Test harness can create isolated Git repositories
- [ ] Test harness provides snapshot testing functions
- [ ] Branch discovery correctly identifies patch branches
- [ ] Branch discovery excludes main branch
- [ ] Branch discovery filters by ancestry
- [ ] Branch discovery sorts lexicographically
- [ ] All 7+ tests pass with snapshots
- [ ] Tests run in <2 seconds
- [ ] Tests clean up after themselves
- [ ] Snapshots are committed to Git

## Next Phase

Once this phase is complete:

- Tests for Phase 1.2 will use this harness
- Snapshot testing will be used for all CLI output
- Branch discovery will be called by the sync command
- We can focus on rebase logic knowing discovery works correctly
