# Phase 1.2: Replay Patch Commits

**Goal:** Implement and test the ability to replay patch branch commits onto upstream/main using lower-level Git operations, with proper conflict detection and empty patch handling.

**Status:** ✓ Complete

**Dependencies:** Phase 1.1 (test harness and discovery)

**Related Phases:** Provides replayed refs for Phase 1.3 (squash integration)

## Overview

This phase implements the core commit replay logic:

1. Extract commits from each patch branch (everything after origin/main)
2. Replay each commit onto the current upstream/main using `git cherry-pick`
3. Squash any merge commits encountered (replay as single commit)
4. Detect and isolate replay conflicts
5. Detect empty patches (where changes are already in upstream)
6. Store replayed results in temporary local refs
7. Process each patch independently (one failure doesn't affect others)

**Why not use `git rebase`?** Upstream main can be force-pushed, breaking ancestry assumptions. We use lower-level tools to replay commits deterministically.

## Part 1: Understanding the Commit Replay Operation

### What We're Doing

Given this state:

```
upstream/main:   U0 --- U1 --- U2 --- U3
origin/main:     U0 --- U1 --- U2 --- SA --- SB
origin/patch-A:  U0 --- U1 --- U2 --- SA --- SB --- A1 --- A2
```

We want to replay patch-A commits onto U3:

```
Result:          U0 --- U1 --- U2 --- U3 --- A1' --- A2'
```

### Key Insight

The patch commits are everything after `origin/main` on the patch branch. We:

1. List all commits between `origin/main` and `origin/patch-A`
2. Replay each commit onto `upstream/main` using `git cherry-pick`
3. Squash merge commits into single commits
4. Store result without affecting working tree

**Why this approach:**

- Handles force-pushed upstream (no ancestry dependency)
- Merge commits are squashed (deterministic history)
- Full control over conflict handling
- No assumptions about shared history

### Git Commands for Commit Replay

**List commits to replay:**

```bash
# Get list of commits between origin/main and origin/patch-A
git rev-list --reverse --no-merges origin/main..origin/patch-A

# Include merge commits (we'll squash them)
git rev-list --reverse origin/main..origin/patch-A
```

**Replay commits:**

```bash
# Start from upstream/main
git checkout -B tmp/patch-A-replay upstream/main

# Replay each commit
for commit in $commit_list; do
    if git rev-parse "$commit^2" &>/dev/null; then
        # Merge commit - squash it
        git merge --squash "$commit"
        git commit -C "$commit"
    else
        # Regular commit - cherry-pick
        git cherry-pick "$commit"
    fi
done
```

## Part 2: Implementation

### File: `scripts/patchstack`

Add new functions:

#### Function: `replay_patch_commits(branch_name)`

```bash
replay_patch_commits() {
    local branch_name=$1
    local remote_ref="refs/remotes/$PATCH_REMOTE/$branch_name"
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"
    local origin_main="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"
    local tmp_ref="refs/patchstack/tmp/$branch_name"
    local tmp_branch="patchstack-tmp-$branch_name"

    # Check if branch has commits beyond origin/main
    if [ "$(git rev-parse "$remote_ref")" = "$(git rev-parse "$origin_main")" ]; then
        echo "WARNING: $branch_name has no commits beyond main" >&2
        return 2
    fi

    # Get list of commits to replay (between origin/main and patch branch)
    local commits
    if ! commits=$(git rev-list --reverse "$origin_main..$remote_ref" 2>&1); then
        echo "ERROR: Cannot list commits for $branch_name" >&2
        return 1
    fi

    # Check if there are any commits
    if [ -z "$commits" ]; then
        echo "WARNING: $branch_name has no commits to replay" >&2
        return 2
    fi

    # Create temporary branch starting from upstream/main
    git branch -f "$tmp_branch" "$upstream_ref" 2>/dev/null || {
        echo "ERROR: Cannot create temporary branch" >&2
        return 1
    }

    # Replay each commit
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    git checkout -q "$tmp_branch" 2>/dev/null || {
        git branch -D "$tmp_branch" 2>/dev/null
        return 1
    }

    local failed=0
    for commit_sha in $commits; do
        # Check if this is a merge commit
        if git rev-parse "$commit_sha^2" &>/dev/null; then
            # Merge commit - squash it
            if ! git merge --squash --no-commit "$commit_sha" &>/dev/null; then
                failed=1
                break
            fi
            # Create commit with original message
            local msg=$(git log -1 --format=%B "$commit_sha")
            if ! git commit -m "$msg" --allow-empty &>/dev/null; then
                failed=1
                break
            fi
        else
            # Regular commit - cherry-pick
            if ! git cherry-pick "$commit_sha" &>/dev/null 2>&1; then
                failed=1
                break
            fi
        fi
    done

    # Return to original branch/commit
    if [ -n "$current_branch" ]; then
        git checkout -q "$current_branch" 2>/dev/null
    fi

    if [ $failed -eq 1 ]; then
        # Replay failed (conflict)
        git cherry-pick --abort &>/dev/null 2>&1 || true
        git branch -D "$tmp_branch" 2>/dev/null
        return 3
    fi

    # Update the temporary ref
    git update-ref "$tmp_ref" "$tmp_branch"
    git branch -D "$tmp_branch" 2>/dev/null

    # Check if patch is empty (replayed tree equals upstream tree)
    local replayed_tree=$(git rev-parse "$tmp_ref^{tree}")
    local upstream_tree=$(git rev-parse "$upstream_ref^{tree}")

    if [ "$replayed_tree" = "$upstream_tree" ]; then
        # Empty patch
        git update-ref -d "$tmp_ref"
        return 4
    fi

    return 0
}
```

**Return Codes:**

| Code | Meaning              | Description                                         |
|------|----------------------|-----------------------------------------------------|
| 0    | Success              | Replayed ref in `refs/patchstack/tmp/$branch_name`  |
| 1    | Cannot list commits  | Branch relationship error                           |
| 2    | No commits to replay | Branch has no commits beyond main                   |
| 3    | Replay conflict      | Cherry-pick failed, conflict in changes             |
| 4    | Empty patch          | Changes already in upstream (tree matches)          |

#### Function: `replay_all_patches()`

```bash
replay_all_patches() {
    local branches
    readarray -t branches < <(discover_patch_branches)

    local results=()

    for branch in "${branches[@]}"; do
        echo "Replaying $branch..."

        local status
        if replay_patch_commits "$branch"; then
            status="success"
            echo "  ✓ Replayed successfully"
        else
            local code=$?
            case $code in
                1) status="invalid" ;;
                2) status="no-changes" ;;
                3) status="conflict" ;;
                4) status="empty" ;;
                *) status="unknown" ;;
            esac
            echo "  ✗ Failed: $status"
        fi

        results+=("$branch:$status")
    done

    # Return results for later processing
    printf '%s\n' "${results[@]}"
}
```

#### Update `cmd_sync()`

```bash
cmd_sync() {
    echo "Starting patchstack sync..."

    # Discover patches
    local patches
    readarray -t patches < <(discover_patch_branches)
    echo "Found ${#patches[@]} patch branches"

    # Replay patches
    local results
    readarray -t results < <(replay_all_patches)

    # Summary
    echo
    echo "Replay summary:"
    for result in "${results[@]}"; do
        echo "  $result"
    done
}
```

## Part 3: Tests

### File: `tests/test-replay.sh`

#### Test 1: Clean Replay

```bash
test_clean_replay() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create patch with 2 commits
    create_patch_branch "patch-feature" 2

    # Advance upstream
    cd "$UPSTREAM_DIR"
    git commit --allow-empty -m "Upstream change"
    cd "$fork"
    git fetch upstream

    # Replay
    replay_patch_commits "patch-feature"
    local status=$?

    # Check success
    assert_equal "0" "$status"

    # Check temporary ref exists
    assert_branch_exists "refs/patchstack/tmp/patch-feature"

    # Check it's based on new upstream
    local upstream_sha=$(git rev-parse upstream/main)
    local is_ancestor=$(git merge-base --is-ancestor "$upstream_sha" refs/patchstack/tmp/patch-feature && echo "yes" || echo "no")
    assert_equal "yes" "$is_ancestor"

    cleanup_test_env
}
```

#### Test 2: Replay Conflict

```bash
test_rebase_conflict() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create file and patch it
    echo "line 1" > file.txt
    git add file.txt
    git commit -m "Add file"
    git push origin main

    git checkout -b patch-conflict
    echo "line 1 modified in patch" > file.txt
    git commit -am "Modify in patch"
    git push origin patch-conflict

    # Modify same file in upstream
    cd "$UPSTREAM_DIR"
    echo "line 1 modified in upstream" > file.txt
    git commit -am "Modify in upstream"

    cd "$fork"
    git fetch upstream

    # Attempt rebase - should fail with conflict
    rebase_patch_branch "patch-conflict"
    local status=$?

    # Should return conflict code (3)
    assert_equal "3" "$status"

    # Temporary ref should not exist
    local ref_exists=$(git show-ref refs/patchstack/tmp/patch-conflict && echo "yes" || echo "no")
    assert_equal "no" "$ref_exists"

    cleanup_test_env
}
```

#### Test 3: Empty Patch Detection

```bash
test_empty_patch() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create patch
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Add feature"
    git push origin main

    git checkout -b patch-feature
    git push origin patch-feature

    # Same change in upstream
    cd "$UPSTREAM_DIR"
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Add feature (upstream)"

    cd "$fork"
    git fetch upstream

    # Replay should detect empty patch
    replay_patch_commits "patch-feature"
    local status=$?

    # Should return empty code (4)
    assert_equal "4" "$status"

    cleanup_test_env
}
```

#### Test 4: Multiple Patches Independently

```bash
test_multiple_patches_independent() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create three patches
    create_patch_branch "patch-alpha" 1
    create_patch_branch "patch-beta" 1

    # Make gamma conflict
    git checkout main
    echo "conflict" > conflict.txt
    git add conflict.txt
    git commit -m "Add conflict file"
    git push origin main

    git checkout -b patch-gamma
    echo "different" > conflict.txt
    git commit -am "Conflicting change"
    git push origin patch-gamma

    # Advance upstream
    cd "$UPSTREAM_DIR"
    echo "conflict" > conflict.txt
    git add conflict.txt
    git commit -m "Upstream conflict"

    cd "$fork"
    git fetch upstream

    # Replay all
    local results
    readarray -t results < <(replay_all_patches)

    # Alpha should succeed
    assert_contains "${results[0]}" "patch-alpha:success"

    # Beta should succeed
    assert_contains "${results[1]}" "patch-beta:success"

    # Gamma should conflict
    assert_contains "${results[2]}" "patch-gamma:conflict"

    # Successful patches should have temp refs
    assert_branch_exists "refs/patchstack/tmp/patch-alpha"
    assert_branch_exists "refs/patchstack/tmp/patch-beta"

    cleanup_test_env
}
```

#### Test 5: Patch with No New Commits

```bash
test_patch_no_new_commits() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create patch branch but don't add commits
    git checkout -b patch-empty
    git push origin patch-empty
    git checkout main

    # Try to replay
    replay_patch_commits "patch-empty"
    local status=$?

    # Should return no-changes code (2)
    assert_equal "2" "$status"

    cleanup_test_env
}
```

#### Test 6: Merge Commit Squashing

```bash
test_merge_commit_squash() {
    local fork=$(setup_test_env)
    cd "$fork"

    # Create a patch branch with a merge commit
    git checkout -b patch-with-merge
    echo "file1" > file1.txt
    git add file1.txt
    git commit -m "Add file1"

    # Create feature branch and merge it
    git checkout -b feature
    echo "file2" > file2.txt
    git add file2.txt
    git commit -m "Add file2"

    git checkout patch-with-merge
    git merge feature -m "Merge feature"
    git push origin patch-with-merge
    git checkout main

    # Advance upstream
    cd "$UPSTREAM_DIR"
    git commit --allow-empty -m "Upstream change"

    cd "$fork"
    git fetch upstream

    # Replay should squash the merge commit
    replay_patch_commits "patch-with-merge"
    local status=$?

    # Check success
    assert_equal "0" "$status"

    # Verify result is linear (no merge commits)
    local commit_count=$(git rev-list --count upstream/main..refs/patchstack/tmp/patch-with-merge)
    # Should have 3 commits (file1, file2 from feature, merge squashed = 3 total)
    assert_equal "3" "$commit_count"

    # Verify no merge commits in result
    local merge_count=$(git rev-list --merges upstream/main..refs/patchstack/tmp/patch-with-merge | wc -l)
    assert_equal "0" "$merge_count"

    cleanup_test_env
}
```

## Part 4: Test Harness Enhancements

### Update `tests/harness.sh`

Add helper for creating conflicts:

```bash
create_conflict_between() {
    local patch_branch=$1
    local file=${2:-conflict.txt}

    # Modify file in both upstream and patch
    cd "$UPSTREAM_DIR"
    echo "upstream version" > "$file"
    git add "$file"
    git commit -m "Upstream: modify $file"

    cd "$FORK_DIR"
    git checkout "$patch_branch"
    echo "patch version" > "$file"
    git add "$file"
    git commit -m "Patch: modify $file"
    git push origin "$patch_branch"
    git checkout main

    git fetch upstream
}
```

## Testing Process

### Run Tests

```bash
./tests/run-all-tests.sh
```

### Expected Output

```
Running test-discovery...
✓ test-discovery passed

Running test-replay...
✓ test-replay passed

========================
Results: 2 passed, 0 failed
```

## Success Criteria

- [ ] Single patch commits can be replayed onto upstream
- [ ] Merge commits are squashed during replay
- [ ] Replay conflicts detected and isolated
- [ ] Empty patches detected (tree comparison)
- [ ] Multiple patches processed independently
- [ ] Temporary refs created in `refs/patchstack/tmp/*`
- [ ] Failed replays don't create temporary refs
- [ ] Working tree remains clean during operations
- [ ] All 6+ tests pass
- [ ] Tests run in <3 seconds

## Implementation Notes

### Working Tree Safety

The replay operation temporarily checks out a branch. We:

1. Save current HEAD position
2. Create and checkout temporary branch
3. Replay commits via cherry-pick
4. Return to original HEAD
5. Update ref without affecting working tree

### Conflict Detection

Git cherry-pick returns non-zero on conflict. We abort the cherry-pick and clean up. The original ref is untouched.

### Merge Commit Handling

Merge commits are detected via `git rev-parse $commit^2`. We:

1. Use `git merge --squash` to apply all changes
2. Create single commit with original message
3. This ensures deterministic linear history

### Empty Patch Detection

After replay, compare trees:

```bash
git rev-parse <replayed>^{tree}
git rev-parse upstream/main^{tree}
```

If equal, all changes are already in upstream.

### Why Not Use Git Rebase?

- **Force-pushed upstream:** Ancestry may be rewritten, breaking rebase assumptions
- **Merge commits:** Need explicit squashing for deterministic history
- **Full control:** Cherry-pick gives us commit-by-commit control
- **No shared history assumption:** Works even if upstream rewrites history

## Next Phase

Phase 1.3 will use the replayed refs (in `refs/patchstack/tmp/*`) to perform squash integration, building the final main branch.
