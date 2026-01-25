# Phase 1.4: Atomic Update (Ref Updates Only)

**Goal:** Update local remote-tracking refs to reflect the new state after successful integration, and record metadata in Git notes.

## Overview

This phase implements local ref updates without pushing to remote (pushing comes in Phase 1.5):

1. Update `refs/remotes/origin/main` to point to integrated main
2. Update `refs/remotes/origin/*` for each successfully integrated patch
3. Delete refs for empty patches (already merged upstream)
4. Leave failed patches unchanged (at their old SHAs)
5. Record complete metadata in `refs/notes/patchstack`
6. All updates must be atomic (all succeed or all fail)

**Why separate from push?**
- Allows testing of ref update logic independently
- Prepares for atomic push in next phase
- Makes debugging easier

## Part 1: Understanding Ref Updates

### Current State After Integration

```
refs/remotes/origin/main:        SA --- SB (old main)
refs/remotes/origin/patch-A:     SA --- SB --- A1 --- A2
refs/remotes/origin/patch-B:     SA --- SB --- B1 --- B2 (failed integration)
refs/remotes/origin/patch-C:     SA --- SB (empty patch)
refs/patchstack/tmp/main:        U3 --- SA' --- SC' (new main)
refs/patchstack/tmp/patch-A:     U3 --- A1' --- A2' (replayed)
refs/patchstack/tmp/patch-C:     deleted (empty)
```

### Desired State After Update

```
refs/remotes/origin/main:        U3 --- SA' --- SC' (updated)
refs/remotes/origin/patch-A:     U3 --- SA' --- SC' --- A1' --- A2' (updated)
refs/remotes/origin/patch-B:     SA --- SB --- B1 --- B2 (unchanged)
refs/remotes/origin/patch-C:     deleted (was empty)
```

### What Gets Updated

**Updated refs:**
- `origin/main` → new integrated main
- `origin/patch-A` → rebased patch-A (on top of new main)
- Any other successful patches

**Unchanged refs:**
- Patches that failed replay or integration
- These remain at their original SHAs

**Deleted refs:**
- Empty patches (changes already in upstream)

### Why This Structure?

After the sync, each patch branch should be rebased onto the new main (which includes all integrated patches). This maintains the patch stack invariant: all patches are descendants of main.

## Part 2: Implementation

### File: `scripts/patchstack`

#### Function: `calculate_ref_updates()`

Determines which refs need updating based on integration results.

```bash
calculate_ref_updates() {
    local integration_main="refs/patchstack/tmp/main"
    local new_main_sha=$(git rev-parse "$integration_main")

    # Track updates
    declare -A ref_updates
    declare -A ref_deletes

    # Update main
    ref_updates["refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"]="$new_main_sha"

    # Process each patch
    local patches
    readarray -t patches < <(discover_patch_branches)

    for branch in "${patches[@]}"; do
        local remote_ref="refs/remotes/$PATCH_REMOTE/$branch"
        local tmp_ref="refs/patchstack/tmp/$branch"

        # Check if patch was integrated
        if git rev-parse "$tmp_ref" &>/dev/null; then
            # Patch exists in tmp - check if it's in the integrated main
            local patch_tree=$(git rev-parse "$tmp_ref^{tree}")

            # Is this patch's tree included in new main?
            if git merge-base --is-ancestor "$tmp_ref" "$integration_main" 2>/dev/null; then
                # Empty patch - already in main
                ref_deletes["$remote_ref"]=1
            else
                # Need to put replayed commits on top of new main
                local rebased_sha=$(rebase_patch_on_main "$branch" "$tmp_ref" "$integration_main")
                if [ -n "$rebased_sha" ]; then
                    ref_updates["$remote_ref"]="$rebased_sha"
                fi
            fi
        fi
        # If no tmp_ref exists, patch failed - leave unchanged
    done

    # Output updates
    for ref in "${!ref_updates[@]}"; do
        echo "update:$ref:${ref_updates[$ref]}"
    done

    for ref in "${!ref_deletes[@]}"; do
        echo "delete:$ref"
    done
}
```

#### Function: `rebase_patch_on_main(branch_name, tmp_ref, new_main)`

Rebases a patch's commits onto the new integrated main.

```bash
rebase_patch_on_main() {
    local branch_name=$1
    local tmp_ref=$2
    local new_main=$3
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"

    # Get commits from replayed patch (everything after upstream)
    local commits
    commits=$(git rev-list --reverse "$upstream_ref..$tmp_ref")

    if [ -z "$commits" ]; then
        echo "" >&2
        return 1
    fi

    # Create temp branch from new main
    local tmp_branch="patchstack-rebase-$branch_name"
    git branch -f "$tmp_branch" "$new_main" 2>/dev/null || return 1

    # Save current HEAD
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

    # Checkout temp branch
    git checkout -q "$tmp_branch" 2>/dev/null || {
        git branch -D "$tmp_branch" 2>/dev/null
        return 1
    }

    # Cherry-pick each commit
    for commit_sha in $commits; do
        if ! git cherry-pick "$commit_sha" &>/dev/null 2>&1; then
            # Should not happen if integration succeeded
            git cherry-pick --abort &>/dev/null 2>&1 || true
            git checkout -q "$current_branch" 2>/dev/null
            git branch -D "$tmp_branch" 2>/dev/null
            return 1
        fi
    done

    # Get final SHA
    local final_sha=$(git rev-parse HEAD)

    # Cleanup
    git checkout -q "$current_branch" 2>/dev/null
    git branch -D "$tmp_branch" 2>/dev/null

    echo "$final_sha"
    return 0
}
```

#### Function: `record_notes(ref, old_sha, new_sha, status)`

Records metadata about the sync operation in Git notes.

```bash
record_notes() {
    local ref=$1
    local old_sha=$2
    local new_sha=$3
    local status=$4

    local branch_name=${ref#refs/remotes/$PATCH_REMOTE/}
    local timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    local note="Patchstack sync: $timestamp
Branch: $branch_name
Status: $status
Old SHA: $old_sha
New SHA: $new_sha
"

    # Add note to the new commit
    if [ "$new_sha" != "deleted" ]; then
        git notes --ref=patchstack add -f -m "$note" "$new_sha" 2>/dev/null || true
    fi
}
```

#### Function: `apply_ref_updates()`

Applies all calculated ref updates atomically (within local repo).

```bash
apply_ref_updates() {
    local updates
    readarray -t updates < <(calculate_ref_updates)

    if [ ${#updates[@]} -eq 0 ]; then
        echo "No ref updates needed"
        return 0
    fi

    echo "Applying ${#updates[@]} ref updates..."

    # Build list of updates for atomic transaction
    local update_cmds=()

    for update in "${updates[@]}"; do
        local action=${update%%:*}
        local rest=${update#*:}

        if [ "$action" = "update" ]; then
            local ref=${rest%%:*}
            local new_sha=${rest#*:}
            local old_sha=$(git rev-parse "$ref" 2>/dev/null || echo "")

            echo "  Updating $ref"

            # Prepare update-ref command
            if [ -n "$old_sha" ]; then
                update_cmds+=("update $ref $new_sha $old_sha")
            else
                update_cmds+=("create $ref $new_sha")
            fi

            # Record notes
            record_notes "$ref" "$old_sha" "$new_sha" "updated"

        elif [ "$action" = "delete" ]; then
            local ref=$rest
            local old_sha=$(git rev-parse "$ref" 2>/dev/null || echo "")

            echo "  Deleting $ref"

            if [ -n "$old_sha" ]; then
                update_cmds+=("delete $ref $old_sha")
                record_notes "$ref" "$old_sha" "deleted" "empty"
            fi
        fi
    done

    # Execute atomic update
    if [ ${#update_cmds[@]} -gt 0 ]; then
        printf '%s\n' "${update_cmds[@]}" | git update-ref --stdin

        if [ $? -eq 0 ]; then
            echo "✓ All refs updated successfully"
            return 0
        else
            echo "✗ Ref update failed"
            return 1
        fi
    fi

    return 0
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

    # Phase 4: Update refs
    echo "Phase 4: Updating local refs"
    if ! apply_ref_updates; then
        echo "ERROR: Failed to update refs"
        return 1
    fi
    echo

    # Summary
    echo "==================================="
    echo "Sync Complete"
    echo "==================================="
    echo
    echo "Local refs updated. Ready to push."
}
```

## Part 3: Tests

Create `tests/test-13-ref-updates.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Successful sync updates all local remote refs
test_dir=$(setup_test_env)
cd "$test_dir"

# Record initial SHAs
initial_main=$(git rev-parse origin/main)

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1

initial_alpha=$(git rev-parse origin/patch-alpha)
initial_beta=$(git rev-parse origin/patch-beta)

# Advance upstream
cd "$UPSTREAM_DIR"
echo "upstream-change" > upstream.txt
git add upstream.txt
git commit -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Check main was updated
new_main=$(git rev-parse origin/main)
if [ "$new_main" = "$initial_main" ]; then
    echo "ERROR: origin/main should be updated"
    exit 1
fi

# Check patches were updated
new_alpha=$(git rev-parse origin/patch-alpha)
new_beta=$(git rev-parse origin/patch-beta)

if [ "$new_alpha" = "$initial_alpha" ]; then
    echo "ERROR: origin/patch-alpha should be updated"
    exit 1
fi

if [ "$new_beta" = "$initial_beta" ]; then
    echo "ERROR: origin/patch-beta should be updated"
    exit 1
fi

# Check patches are descendants of new main
if ! git merge-base --is-ancestor "$new_main" "$new_alpha"; then
    echo "ERROR: patch-alpha should be descendant of new main"
    exit 1
fi

if ! git merge-base --is-ancestor "$new_main" "$new_beta"; then
    echo "ERROR: patch-beta should be descendant of new main"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-14-failed-patch-unchanged.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Failed patch keeps old ref unchanged
test_dir=$(setup_test_env)
cd "$test_dir"

# Create clean patch
create_patch_branch "patch-alpha" 1
initial_alpha=$(git rev-parse origin/patch-alpha)

# Create conflicting patch
git checkout -b patch-beta origin/main
echo "content" > conflict.txt
git add conflict.txt
git commit -m "Beta: add conflict file"
git push origin patch-beta
initial_beta=$(git rev-parse origin/patch-beta)

# Advance upstream with conflicting change
cd "$UPSTREAM_DIR"
echo "different-content" > conflict.txt
git add conflict.txt
git commit -m "Upstream: add conflict file"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Check patch-alpha was updated
new_alpha=$(git rev-parse origin/patch-alpha)
if [ "$new_alpha" = "$initial_alpha" ]; then
    echo "ERROR: patch-alpha should be updated"
    exit 1
fi

# Check patch-beta was NOT updated (conflict)
new_beta=$(git rev-parse origin/patch-beta)
if [ "$new_beta" != "$initial_beta" ]; then
    echo "ERROR: patch-beta should remain unchanged"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-15-empty-patch-deleted.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Empty patch ref deleted
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch that will become empty
git checkout -b patch-empty origin/main
echo "feature" > feature.txt
git add feature.txt
git commit -m "Add feature"
git push origin patch-empty

# Verify ref exists
if ! git rev-parse origin/patch-empty &>/dev/null; then
    echo "ERROR: patch-empty should exist initially"
    exit 1
fi

# Advance upstream with same change
cd "$UPSTREAM_DIR"
echo "feature" > feature.txt
git add feature.txt
git commit -m "Add feature (from patch-empty)"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Check ref was deleted
if git rev-parse origin/patch-empty &>/dev/null; then
    echo "ERROR: patch-empty should be deleted"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-16-notes-created.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Notes created for all processed branches
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patches
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 1

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Check notes exist for new main
new_main=$(git rev-parse origin/main)
notes=$(git notes --ref=patchstack show "$new_main" 2>/dev/null || echo "")

if [ -z "$notes" ]; then
    echo "ERROR: Notes should exist for new main"
    exit 1
fi

# Notes should contain metadata
if ! echo "$notes" | grep -q "Patchstack sync"; then
    echo "ERROR: Notes should contain sync metadata"
    exit 1
fi

if ! echo "$notes" | grep -q "main"; then
    echo "ERROR: Notes should contain branch name"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-17-verify-ref-topology.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Verify ref state matches expected topology
test_dir=$(setup_test_env)
cd "$test_dir"

# Create three patches in specific order
create_patch_branch "patch-aaa" 1
create_patch_branch "patch-bbb" 1
create_patch_branch "patch-ccc" 1

# Advance upstream
cd "$UPSTREAM_DIR"
echo "upstream" > upstream.txt
git add upstream.txt
git commit -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Verify topology:
# 1. All patches are descendants of new main
# 2. New main includes squashed commits in order
# 3. Each patch has correct commit count

new_main=$(git rev-parse origin/main)
upstream_main=$(git rev-parse upstream/main)

# Main should be ahead of upstream by 3 (one squash per patch)
commit_count=$(git rev-list --count "$upstream_main..$new_main")
if [ "$commit_count" != "3" ]; then
    echo "ERROR: Expected 3 commits in new main, got $commit_count"
    exit 1
fi

# Each patch should be descendant of new main
for patch in patch-aaa patch-bbb patch-ccc; do
    patch_sha=$(git rev-parse "origin/$patch")
    if ! git merge-base --is-ancestor "$new_main" "$patch_sha"; then
        echo "ERROR: $patch should be descendant of new main"
        exit 1
    fi

    # Each patch should have 1 commit beyond main
    patch_count=$(git rev-list --count "$new_main..origin/$patch")
    if [ "$patch_count" != "1" ]; then
        echo "ERROR: $patch should have 1 commit, got $patch_count"
        exit 1
    fi
done

cleanup_test_env
echo "✓ Test passed"
```

## Part 4: Atomicity

The `git update-ref --stdin` command provides transaction semantics:

```bash
# All updates happen or none happen
git update-ref --stdin <<EOF
update refs/remotes/origin/main <new-sha> <old-sha>
update refs/remotes/origin/patch-A <new-sha> <old-sha>
update refs/remotes/origin/patch-B <new-sha> <old-sha>
delete refs/remotes/origin/patch-C <old-sha>
EOF
```

If any operation fails (e.g., SHA doesn't match), all operations are rolled back.

## Summary

Phase 1.4 implements local ref updates:

1. **Main updated:** Points to integrated main with all patches
2. **Patches updated:** Rebased onto new main
3. **Failed patches:** Left unchanged at original SHA
4. **Empty patches:** Refs deleted
5. **Notes recorded:** Metadata for each sync operation
6. **Atomic updates:** All refs updated together

Next phase (1.5) will push these local changes to the remote repository.
