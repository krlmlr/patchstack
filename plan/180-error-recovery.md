# Phase 1.8: Error Recovery

**Goal:** Handle problematic states gracefully with clear error messages and guidance, ensuring patchstack never leaves the repository in a broken state.

## Overview

This phase adds error handling for common problems:

1. Dirty working tree (uncommitted changes)
2. Detached HEAD state
3. Missing remotes or branches
4. Cleanup of temporary refs on failure
5. Safe rollback on errors
6. Clear guidance for manual recovery

**Philosophy:** Detect problems early, fail safely, guide users to fix issues.

## Part 1: Pre-Flight Checks

### Check Working Tree

Before any operations, verify clean state:

```bash
check_working_tree() {
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_error "Working tree has uncommitted changes"
        echo
        echo "Patchstack requires a clean working tree."
        echo
        echo "To fix:"
        echo "  git add -A && git commit -m 'WIP'"
        echo "  or"
        echo "  git stash"
        echo
        echo "Then run patchstack again."
        return 1
    fi

    if ! git diff-index --cached --quiet HEAD -- 2>/dev/null; then
        log_error "Working tree has staged changes"
        echo
        echo "Patchstack requires a clean working tree."
        echo
        echo "To fix:"
        echo "  git commit"
        echo "  or"
        echo "  git reset"
        echo
        echo "Then run patchstack again."
        return 1
    fi

    return 0
}
```

### Check HEAD State

Verify we're on a branch (not detached):

```bash
check_head_state() {
    if ! git symbolic-ref HEAD &>/dev/null; then
        log_error "HEAD is detached"
        echo
        echo "Patchstack requires HEAD to be on a branch."
        echo
        echo "To fix:"
        echo "  git checkout main"
        echo "  or"
        echo "  git checkout -b my-branch"
        echo
        echo "Then run patchstack again."
        return 1
    fi

    return 0
}
```

### Check Remotes

Verify required remotes exist:

```bash
check_remotes() {
    if ! git remote get-url "$UPSTREAM_REMOTE" &>/dev/null; then
        log_error "Remote '$UPSTREAM_REMOTE' not configured"
        echo
        echo "Patchstack requires an '$UPSTREAM_REMOTE' remote."
        echo
        echo "To fix:"
        echo "  git remote add $UPSTREAM_REMOTE <url>"
        echo
        echo "Example:"
        echo "  git remote add upstream https://github.com/upstream/repo.git"
        echo
        return 1
    fi

    if ! git remote get-url "$PATCH_REMOTE" &>/dev/null; then
        log_error "Remote '$PATCH_REMOTE' not configured"
        echo
        echo "Patchstack requires an '$PATCH_REMOTE' remote (your fork)."
        echo
        echo "To fix:"
        echo "  git remote add $PATCH_REMOTE <url>"
        echo
        return 1
    fi

    return 0
}
```

### Check Required Refs

Verify main branches exist:

```bash
check_required_refs() {
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"
    local origin_ref="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"

    if ! git rev-parse "$upstream_ref" &>/dev/null; then
        log_error "Branch '$UPSTREAM_REMOTE/$MAIN_BRANCH' not found"
        echo
        echo "Patchstack requires '$upstream_ref' to exist."
        echo
        echo "To fix:"
        echo "  git fetch $UPSTREAM_REMOTE"
        echo
        echo "If the branch name is different:"
        echo "  export MAIN_BRANCH=master"
        echo "  patchstack sync"
        echo
        return 1
    fi

    if ! git rev-parse "$origin_ref" &>/dev/null; then
        log_error "Branch '$PATCH_REMOTE/$MAIN_BRANCH' not found"
        echo
        echo "Patchstack requires '$origin_ref' to exist."
        echo
        echo "To fix:"
        echo "  git fetch $PATCH_REMOTE"
        echo
        return 1
    fi

    return 0
}
```

### Combined Pre-Flight

Run all checks before sync:

```bash
run_preflight_checks() {
    log_verbose "Running pre-flight checks..."

    if ! check_working_tree; then
        return 1
    fi

    if ! check_head_state; then
        return 1
    fi

    if ! check_remotes; then
        return 1
    fi

    if ! check_required_refs; then
        return 1
    fi

    log_verbose "Pre-flight checks passed"
    return 0
}
```

## Part 2: Cleanup on Failure

### Temporary Ref Cleanup

Ensure temporary refs are cleaned up on any failure:

```bash
# Global trap for cleanup
cleanup_on_exit() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_verbose "Cleaning up temporary refs..."
        cleanup_temp_refs
    fi
}

trap cleanup_on_exit EXIT

cleanup_temp_refs() {
    # Remove all refs under refs/patchstack/tmp/
    local tmp_refs=$(git for-each-ref --format='%(refname)' 'refs/patchstack/tmp/' 2>/dev/null || true)

    for ref in $tmp_refs; do
        log_verbose "Removing temporary ref: $ref"
        git update-ref -d "$ref" 2>/dev/null || true
    done

    # Remove any temporary branches
    local tmp_branches=$(git branch --list 'patchstack-*' --format='%(refname:short)' 2>/dev/null || true)

    for branch in $tmp_branches; do
        log_verbose "Removing temporary branch: $branch"
        git branch -D "$branch" 2>/dev/null || true
    done

    # Abort any in-progress operations
    if git cherry-pick --abort &>/dev/null 2>&1; then
        log_verbose "Aborted cherry-pick"
    fi

    if git merge --abort &>/dev/null 2>&1; then
        log_verbose "Aborted merge"
    fi
}
```

### Safe Rollback

If ref updates fail, rollback to previous state:

```bash
apply_ref_updates_with_rollback() {
    # Record current state
    local backup_file=$(mktemp)

    log_verbose "Backing up current ref state..."
    git for-each-ref --format='%(refname) %(objectname)' 'refs/remotes/origin/' > "$backup_file"

    # Try to apply updates
    if apply_ref_updates; then
        rm "$backup_file"
        return 0
    else
        log_error "Ref updates failed, rolling back..."

        # Restore previous state
        while IFS=' ' read -r refname sha; do
            log_verbose "Restoring $refname to $sha"
            git update-ref "$refname" "$sha" 2>/dev/null || true
        done < "$backup_file"

        rm "$backup_file"
        echo
        echo "Repository restored to previous state"
        return 1
    fi
}
```

## Part 3: Enhanced Error Messages

### Context-Aware Errors

Provide specific guidance based on the error:

```bash
handle_replay_failure() {
    local branch_name=$1
    local error_type=$2

    case "$error_type" in
        conflict)
            echo "✗ Replay conflict in $branch_name"
            echo
            echo "The patch conflicts with upstream changes."
            echo
            echo "To investigate:"
            echo "  git log origin/$branch_name"
            echo "  git diff upstream/main origin/$branch_name"
            echo
            echo "To fix manually:"
            echo "  git checkout $branch_name"
            echo "  git rebase upstream/main"
            echo "  # resolve conflicts"
            echo "  git push origin $branch_name --force-with-lease"
            echo
            ;;
        empty)
            echo "○ Patch $branch_name is empty (already in upstream)"
            echo
            echo "This patch will be removed from your fork."
            echo "The changes are already merged upstream."
            ;;
        error)
            echo "✗ Error replaying $branch_name"
            echo
            echo "An unexpected error occurred."
            echo
            echo "To debug:"
            echo "  patchstack sync --verbose"
            echo
            ;;
    esac
}

handle_integration_failure() {
    local branch_name=$1

    echo "✗ Integration conflict in $branch_name"
    echo
    echo "This patch conflicts with another patch during integration."
    echo
    echo "Likely cause:"
    echo "  Another patch (earlier in alphabetical order) modified the same files."
    echo
    echo "To investigate:"
    echo "  patchstack list"
    echo "  git log origin/main..$PATCH_REMOTE/$MAIN_BRANCH"
    echo
    echo "To fix:"
    echo "  1. Identify conflicting patches"
    echo "  2. Rename or rebase $branch_name to resolve conflict"
    echo "  3. Push updated branch"
    echo "  4. Run patchstack sync again"
    echo
}
```

### Push Failure Guidance

Specific help for push failures:

```bash
handle_push_failure() {
    local exit_code=$1

    echo "✗ Push failed (exit code: $exit_code)"
    echo

    if [ $exit_code -eq 1 ]; then
        echo "Common causes:"
        echo "  1. Concurrent update (someone else pushed while you were syncing)"
        echo "  2. Insufficient permissions"
        echo "  3. Network issues"
        echo
        echo "To fix concurrent update:"
        echo "  git fetch $PATCH_REMOTE"
        echo "  patchstack sync"
        echo
        echo "To fix permissions:"
        echo "  Check your Git credentials and repository access"
        echo
        echo "To fix network issues:"
        echo "  Check your connection and try again"
        echo
    else
        echo "Unexpected push error."
        echo
        echo "To debug:"
        echo "  patchstack sync --verbose"
        echo "  git push $PATCH_REMOTE --dry-run"
        echo
    fi

    echo "Note: Local refs were updated but remote unchanged."
    echo "It is safe to run sync again after fixing the issue."
}
```

## Part 4: Update `cmd_sync`

Integrate all error handling:

```bash
cmd_sync() {
    # Pre-flight checks
    if ! run_preflight_checks; then
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: No changes will be made"
        echo
    fi

    echo "Starting patchstack sync..."
    echo

    # Phase 1: Discovery
    echo "Phase 1: Discovering patch branches"
    local patches
    if ! patches=$(discover_patch_branches 2>&1); then
        log_error "Failed to discover patch branches"
        echo "$patches"
        return 1
    fi

    readarray -t patches <<< "$patches"
    echo "Found ${#patches[@]} patch branches"
    echo

    # Phase 2: Replay
    echo "Phase 2: Replaying patches onto upstream"
    local replay_results
    if ! replay_results=$(replay_all_patches 2>&1); then
        log_error "Failed during replay phase"
        echo "$replay_results"
        cleanup_temp_refs
        return 1
    fi

    readarray -t replay_results <<< "$replay_results"
    echo

    # Phase 3: Integration
    echo "Phase 3: Integrating patches into new main"
    local integration_results
    if ! integration_results=$(integrate_patches 2>&1); then
        log_error "Failed during integration phase"
        echo "$integration_results"
        cleanup_temp_refs
        return 1
    fi

    readarray -t integration_results <<< "$integration_results"
    echo

    # Stop here if dry-run
    if [ "$DRY_RUN" = true ]; then
        echo "==================================="
        echo "DRY RUN Summary (No Changes Made)"
        echo "==================================="
        # ... existing dry-run output ...
        cleanup_temp_refs
        return 0
    fi

    # Phase 4: Update local refs
    echo "Phase 4: Updating local refs"
    if ! apply_ref_updates_with_rollback; then
        log_error "Failed to update refs"
        cleanup_temp_refs
        return 1
    fi
    echo

    # Phase 5: Push to remote
    echo "Phase 5: Pushing to $PATCH_REMOTE"
    if ! push_refs; then
        local exit_code=$?
        handle_push_failure $exit_code
        cleanup_temp_refs
        return 1
    fi

    push_notes
    cleanup_temp_refs
    echo

    # Success summary
    echo "==================================="
    echo "Sync Complete"
    echo "==================================="
    echo
    echo "✓ Remote updated successfully"
}
```

## Part 5: Tests

Create `tests/test-32-dirty-working-tree.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Dirty working tree prevents sync
test_dir=$(setup_test_env)
cd "$test_dir"

# Create uncommitted change
echo "dirty" > dirty.txt

# Try to sync (should fail)
if bash "$SCRIPT_DIR/patchstack" sync 2>&1 | grep -iq "uncommitted changes"; then
    echo "✓ Correctly detected dirty working tree"
else
    echo "ERROR: Should detect dirty working tree"
    exit 1
fi

# Clean up and try again
rm dirty.txt

# Should work now
create_patch_branch "patch-alpha" 1

cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

if bash "$SCRIPT_DIR/patchstack" sync; then
    echo "✓ Sync works with clean working tree"
else
    echo "ERROR: Sync should work with clean working tree"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-33-missing-upstream.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Missing upstream remote gives clear error
test_dir=$(setup_test_env)
cd "$test_dir"

# Remove upstream remote
git remote remove upstream

# Try to sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1 || true)

# Should mention missing upstream
if ! echo "$output" | grep -iq "upstream.*not configured"; then
    echo "ERROR: Should mention missing upstream remote"
    exit 1
fi

# Should provide guidance
if ! echo "$output" | grep -iq "git remote add"; then
    echo "ERROR: Should provide guidance to add remote"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-34-missing-main-branch.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Missing origin/main gives clear error
test_dir=$(setup_test_env)
cd "$test_dir"

# Delete origin/main ref
git update-ref -d refs/remotes/origin/main

# Try to sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1 || true)

# Should mention missing branch
if ! echo "$output" | grep -iq "origin/main.*not found"; then
    echo "ERROR: Should mention missing origin/main"
    exit 1
fi

# Should suggest fetching
if ! echo "$output" | grep -iq "git fetch"; then
    echo "ERROR: Should suggest fetching"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-35-temp-refs-cleanup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Temporary refs cleaned up after failure
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch that will cause failure
git checkout -b patch-conflict origin/main
echo "conflict" > conflict.txt
git add conflict.txt
git commit -m "Conflicting change"
git push origin patch-conflict

# Advance upstream with conflict
cd "$UPSTREAM_DIR"
echo "different" > conflict.txt
git add conflict.txt
git commit -m "Upstream conflict"

cd "$test_dir"
git fetch upstream

# Run sync (will fail)
bash "$SCRIPT_DIR/patchstack" sync 2>&1 || true

# Check no temporary refs remain
tmp_refs=$(git for-each-ref --format='%(refname)' 'refs/patchstack/tmp/' || true)

if [ -n "$tmp_refs" ]; then
    echo "ERROR: Temporary refs should be cleaned up"
    echo "Found: $tmp_refs"
    exit 1
fi

# Check no temporary branches remain
tmp_branches=$(git branch --list 'patchstack-*' || true)

if [ -n "$tmp_branches" ]; then
    echo "ERROR: Temporary branches should be cleaned up"
    echo "Found: $tmp_branches"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-36-detached-head.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Detached HEAD gives clear error
test_dir=$(setup_test_env)
cd "$test_dir"

# Detach HEAD
git checkout --detach HEAD

# Try to sync
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1 || true)

# Should mention detached HEAD
if ! echo "$output" | grep -iq "head.*detached"; then
    echo "ERROR: Should mention detached HEAD"
    exit 1
fi

# Should provide guidance
if ! echo "$output" | grep -iq "git checkout"; then
    echo "ERROR: Should provide guidance to checkout branch"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

## Summary

Phase 1.8 completes error handling:

1. **Pre-flight checks:** Validate state before operations
2. **Clean errors:** Clear messages with actionable guidance
3. **Safe cleanup:** Temporary refs always removed
4. **Rollback:** Can restore state on ref update failure
5. **Never broken:** Repository never left in inconsistent state
6. **User guidance:** Specific instructions for each error type

With this phase, Milestone 1 is complete. The `patchstack sync` command is:
- Fully functional end-to-end
- Well tested with comprehensive scenarios
- Safe and recoverable from errors
- User-friendly with clear messages
- Ready for real-world use

Next milestone adds GitHub Action integration for automation.
