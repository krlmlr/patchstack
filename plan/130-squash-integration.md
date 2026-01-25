# Phase 1.3: Squash Integration

**Goal:** Implement sequential squash integration to build a new `main` branch by combining viable patches in lexicographic order.

## Overview

This phase implements the most complex Git operation in patchstack:

1. Start from upstream/main as the integration base
2. For each viable patch (in lexicographic order):
   - Create a squash commit of all patch changes
   - Apply it onto the integration branch
   - Handle integration conflicts (different from replay conflicts)
3. Build final `refs/patchstack/tmp/main` reference
4. Only include patches that succeeded in replay AND integration

**Key Insight:** A patch can replay cleanly onto upstream but still conflict during squash integration with other patches.

## Part 1: Understanding Squash Integration

### What We're Doing

Given replayed patches:

```
upstream/main:     U0 --- U1 --- U2 --- U3
replayed patch-A:  U0 --- U1 --- U2 --- U3 --- A1' --- A2'
replayed patch-B:  U0 --- U1 --- U2 --- U3 --- B1' --- B2' --- B3'
replayed patch-C:  U0 --- U1 --- U2 --- U3 --- C1'
```

We want to create:

```
new main:          U0 --- U1 --- U2 --- U3 --- SA --- SB --- SC
```

Where:
- SA = squash commit of all changes in patch-A (A1' + A2')
- SB = squash commit of all changes in patch-B (B1' + B2' + B3')
- SC = squash commit of all changes in patch-C (C1')

### Why Squash?

1. **Deterministic history:** Each patch contributes exactly one commit to main
2. **Clean integration:** No complex merge commits, easy to understand
3. **Ordered application:** Patches are applied in a known, repeatable order
4. **Atomic units:** Each squash represents one logical feature/fix

### Replay Conflict vs Integration Conflict

**Replay conflict:** Patch changes conflict with upstream changes
- Example: Patch modifies line 10 in file.c, upstream modified line 10 differently
- Detected in phase 1.2
- Patch excluded from integration

**Integration conflict:** Patch conflicts with another patch during squash
- Example: Patch-A modifies line 10, patch-B modifies line 10 differently
- Both replay cleanly onto upstream
- Detected in phase 1.3
- Only the conflicting patch excluded

## Part 2: Implementation

### File: `scripts/patchstack`

#### Function: `create_squash_commit(branch_name, parent_ref, tmp_ref)`

Creates a squash commit of all changes in a patch branch.

```bash
create_squash_commit() {
    local branch_name=$1
    local parent_ref=$2      # Current tip of integration branch
    local tmp_ref=$3         # Replayed patch ref
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"

    # Get the tree from the replayed patch
    local patch_tree=$(git rev-parse "$tmp_ref^{tree}")

    # Get commit message from first commit in patch
    local patch_remote_ref="refs/remotes/$PATCH_REMOTE/$branch_name"
    local origin_main="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"
    local first_commit=$(git rev-list --reverse "$origin_main..$patch_remote_ref" | head -n1)
    local commit_msg=$(git log -1 --format=%B "$first_commit")

    # Create squash commit message
    local squash_msg="Squash: $branch_name

$commit_msg

Original commits: $(git rev-list --count "$origin_main..$patch_remote_ref")"

    # Try to create merge with squash
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    local tmp_branch="patchstack-integrate-$branch_name"

    # Create integration branch
    git branch -f "$tmp_branch" "$parent_ref" 2>/dev/null || return 1
    git checkout -q "$tmp_branch" 2>/dev/null || {
        git branch -D "$tmp_branch" 2>/dev/null
        return 1
    }

    # Attempt squash merge
    if ! git merge --squash --no-commit "$tmp_ref" 2>/dev/null; then
        # Conflict during integration
        git merge --abort 2>/dev/null || true
        git checkout -q "$current_branch" 2>/dev/null
        git branch -D "$tmp_branch" 2>/dev/null
        return 2
    fi

    # Create the squash commit
    if ! git commit -m "$squash_msg" 2>/dev/null; then
        git checkout -q "$current_branch" 2>/dev/null
        git branch -D "$tmp_branch" 2>/dev/null
        return 1
    fi

    # Get the commit SHA
    local squash_sha=$(git rev-parse HEAD)

    # Return to original state
    git checkout -q "$current_branch" 2>/dev/null
    git branch -D "$tmp_branch" 2>/dev/null

    echo "$squash_sha"
    return 0
}
```

**Return Codes:**
- 0: Success, outputs squash commit SHA
- 1: Git operation error
- 2: Integration conflict

#### Function: `integrate_patches()`

Builds the new main branch by integrating patches sequentially.

```bash
integrate_patches() {
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"
    local integration_ref="refs/patchstack/tmp/main"

    # Start from upstream/main
    local current_tip=$(git rev-parse "$upstream_ref")

    # Get viable patches (successfully replayed)
    local viable_patches=()
    local tmp_refs=$(git for-each-ref --format='%(refname)' 'refs/patchstack/tmp/')

    for ref in $tmp_refs; do
        # Skip main ref (we're building it)
        [[ "$ref" == "$integration_ref" ]] && continue

        # Extract branch name
        local branch_name=${ref#refs/patchstack/tmp/}
        viable_patches+=("$branch_name")
    done

    # Sort lexicographically
    IFS=$'\n' viable_patches=($(sort <<<"${viable_patches[*]}"))
    unset IFS

    # Track results
    local integrated=()
    local failed=()

    echo "Integrating ${#viable_patches[@]} viable patches..."

    for branch_name in "${viable_patches[@]}"; do
        local tmp_ref="refs/patchstack/tmp/$branch_name"

        echo "  Integrating $branch_name..."

        # Create squash commit
        local squash_sha
        if squash_sha=$(create_squash_commit "$branch_name" "$current_tip" "$tmp_ref"); then
            echo "    ✓ Integrated"
            current_tip="$squash_sha"
            integrated+=("$branch_name")
        else
            local code=$?
            if [ $code -eq 2 ]; then
                echo "    ✗ Integration conflict"
                failed+=("$branch_name:integration-conflict")
            else
                echo "    ✗ Integration error"
                failed+=("$branch_name:error")
            fi
        fi
    done

    # Set the integration ref to final tip
    git update-ref "$integration_ref" "$current_tip"

    echo
    echo "Integration summary:"
    echo "  Integrated: ${#integrated[@]} patches"
    echo "  Failed: ${#failed[@]} patches"

    # Output results
    for branch in "${integrated[@]}"; do
        echo "integrated:$branch"
    done

    for result in "${failed[@]}"; do
        echo "failed:$result"
    done
}
```

#### Update `cmd_sync()`

```bash
cmd_sync() {
    echo "Starting patchstack sync..."
    echo

    # Phase 1: Discovery
    echo "Phase 1: Discovering patch branches"
    local patches
    readarray -t patches < <(discover_patch_branches)
    echo "Found ${#patches[@]} patch branches"
    echo

    # Phase 2: Replay
    echo "Phase 2: Replaying patches onto upstream"
    local replay_results
    readarray -t replay_results < <(replay_all_patches)

    # Count viable patches
    local viable=0
    for result in "${replay_results[@]}"; do
        [[ "$result" == *:success ]] && ((viable++))
    done
    echo "Viable patches: $viable"
    echo

    # Phase 3: Integration
    echo "Phase 3: Integrating patches into new main"
    local integration_results
    readarray -t integration_results < <(integrate_patches)
    echo

    # Final summary
    echo "==================================="
    echo "Sync Summary"
    echo "==================================="
    echo
    echo "Replay results:"
    for result in "${replay_results[@]}"; do
        echo "  $result"
    done
    echo
    echo "Integration results:"
    for result in "${integration_results[@]}"; do
        echo "  $result"
    done
}
```

## Part 3: Tests

Create `tests/test-08-squash-three-patches.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Squash 3 clean patches into new main
test_dir=$(setup_test_env)
cd "$test_dir"

# Create three patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 3
create_patch_branch "patch-gamma" 1

# Advance upstream
cd "$UPSTREAM_DIR"
echo "upstream-change" > upstream.txt
git add upstream.txt
git commit -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1)

# Check integration ref exists
if ! git rev-parse refs/patchstack/tmp/main >/dev/null 2>&1; then
    echo "ERROR: Integration ref not created"
    exit 1
fi

# Check integration ref has 3 commits beyond upstream
upstream_sha=$(git rev-parse upstream/main)
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count "$upstream_sha..$integration_sha")

if [ "$commit_count" != "3" ]; then
    echo "ERROR: Expected 3 commits, got $commit_count"
    exit 1
fi

# Check squash commit messages contain patch names
log_output=$(git log --oneline "$upstream_sha..$integration_sha")

if ! echo "$log_output" | grep -q "patch-alpha"; then
    echo "ERROR: Missing patch-alpha in log"
    exit 1
fi

if ! echo "$log_output" | grep -q "patch-beta"; then
    echo "ERROR: Missing patch-beta in log"
    exit 1
fi

if ! echo "$log_output" | grep -q "patch-gamma"; then
    echo "ERROR: Missing patch-gamma in log"
    exit 1
fi

# Assert snapshot
assert_snapshot "08-squash-three-patches" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-09-integration-conflict.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Integration conflict excludes patch-B, includes A and C
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch-A: modifies file1.txt
git checkout -b patch-alpha origin/main
echo "alpha-change" > file1.txt
git add file1.txt
git commit -m "Alpha: add file1"
git push origin patch-alpha

# Create patch-beta: also modifies file1.txt (conflict!)
git checkout -b patch-beta origin/main
echo "beta-change" > file1.txt
git add file1.txt
git commit -m "Beta: add file1"
git push origin patch-beta

# Create patch-gamma: modifies different file
git checkout -b patch-gamma origin/main
echo "gamma-change" > file2.txt
git add file2.txt
git commit -m "Gamma: add file2"
git push origin patch-gamma

# Advance upstream
cd "$UPSTREAM_DIR"
echo "upstream-change" > upstream.txt
git add upstream.txt
git commit -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1)

# Check that patch-alpha and patch-gamma are integrated
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
log_output=$(git log --oneline upstream/main.."$integration_sha")

if ! echo "$log_output" | grep -q "patch-alpha"; then
    echo "ERROR: patch-alpha should be integrated"
    exit 1
fi

if echo "$log_output" | grep -q "patch-beta"; then
    echo "ERROR: patch-beta should NOT be integrated"
    exit 1
fi

if ! echo "$log_output" | grep -q "patch-gamma"; then
    echo "ERROR: patch-gamma should be integrated"
    exit 1
fi

# Should have 2 commits (alpha + gamma)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")
if [ "$commit_count" != "2" ]; then
    echo "ERROR: Expected 2 commits, got $commit_count"
    exit 1
fi

assert_snapshot "09-integration-conflict" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-10-empty-patch-excluded.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Empty patches excluded from integration
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch-A: adds a feature
git checkout -b patch-alpha origin/main
echo "feature-a" > feature-a.txt
git add feature-a.txt
git commit -m "Add feature A"
git push origin patch-alpha

# Create patch-empty: adds feature that will be in upstream
git checkout -b patch-empty origin/main
echo "already-upstream" > already.txt
git add already.txt
git commit -m "Add feature already in upstream"
git push origin patch-empty

# Create patch-C: adds another feature
git checkout -b patch-charlie origin/main
echo "feature-c" > feature-c.txt
git add feature-c.txt
git commit -m "Add feature C"
git push origin patch-charlie

# Advance upstream with the "empty" patch content
cd "$UPSTREAM_DIR"
echo "already-upstream" > already.txt
git add already.txt
git commit -m "Merge feature from patch-empty"

cd "$test_dir"
git fetch upstream

# Run sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1)

# Check that only alpha and charlie are in integration
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")

if [ "$commit_count" != "2" ]; then
    echo "ERROR: Expected 2 commits (alpha + charlie), got $commit_count"
    exit 1
fi

# Verify patch-empty is marked as empty in output
if ! echo "$output" | grep -q "patch-empty.*empty"; then
    echo "ERROR: patch-empty should be marked as empty"
    exit 1
fi

assert_snapshot "10-empty-patch-excluded" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-11-squash-commit-messages.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Verify squash commit messages include patch name and count
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch with multiple commits
git checkout -b patch-feature origin/main
echo "commit 1" > file1.txt
git add file1.txt
git commit -m "Feature: part 1"
echo "commit 2" > file2.txt
git add file2.txt
git commit -m "Feature: part 2"
echo "commit 3" > file3.txt
git add file3.txt
git commit -m "Feature: part 3"
git push origin patch-feature

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync 2>&1

# Check squash commit message
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
squash_msg=$(git log -1 --format=%B "$integration_sha")

# Should contain patch name
if ! echo "$squash_msg" | grep -q "patch-feature"; then
    echo "ERROR: Squash message should contain patch name"
    echo "Message was: $squash_msg"
    exit 1
fi

# Should contain commit count
if ! echo "$squash_msg" | grep -q "3"; then
    echo "ERROR: Squash message should contain commit count (3)"
    echo "Message was: $squash_msg"
    exit 1
fi

# Should contain "Squash:"
if ! echo "$squash_msg" | grep -q "Squash:"; then
    echo "ERROR: Squash message should contain 'Squash:'"
    echo "Message was: $squash_msg"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

## Part 4: Edge Cases

### Multiple Integration Conflicts

When patch-B and patch-D both conflict during integration, both should be excluded. Test this with:

Create `tests/test-12-multiple-integration-failures.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Multiple patches fail integration
test_dir=$(setup_test_env)
cd "$test_dir"

# All three patches modify the same file
git checkout -b patch-a origin/main
echo "version-a" > conflict.txt
git add conflict.txt
git commit -m "Version A"
git push origin patch-a

git checkout -b patch-b origin/main
echo "version-b" > conflict.txt
git add conflict.txt
git commit -m "Version B"
git push origin patch-b

git checkout -b patch-c origin/main
echo "version-c" > conflict.txt
git add conflict.txt
git commit -m "Version C"
git push origin patch-c

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1)

# Only patch-a should integrate (first in lexicographic order)
integration_sha=$(git rev-parse refs/patchstack/tmp/main)
commit_count=$(git rev-list --count upstream/main.."$integration_sha")

if [ "$commit_count" != "1" ]; then
    echo "ERROR: Expected 1 commit (only patch-a), got $commit_count"
    exit 1
fi

# Verify patch-b and patch-c marked as failed
if ! echo "$output" | grep -q "patch-b.*integration-conflict"; then
    echo "ERROR: patch-b should have integration conflict"
    exit 1
fi

if ! echo "$output" | grep -q "patch-c.*integration-conflict"; then
    echo "ERROR: patch-c should have integration conflict"
    exit 1
fi

assert_snapshot "12-multiple-integration-failures" "$output"

cleanup_test_env
echo "✓ Test passed"
```

## Summary

Phase 1.3 implements the critical squash integration logic:

1. **Sequential application:** Patches applied in lexicographic order
2. **Squash commits:** Each patch becomes one commit in main
3. **Conflict isolation:** Integration conflicts don't affect other patches
4. **Deterministic result:** Same patches always produce same history
5. **Clear messages:** Squash commits document original patch and commit count

This phase completes the core Git operations. Subsequent phases handle ref updates, pushing, and error handling.
