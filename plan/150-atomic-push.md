# Phase 1.5: Atomic Push

**Goal:** Push all local ref updates to the remote repository using atomic force-with-lease to prevent concurrent modification conflicts.

## Overview

This phase implements the final step of sync - pushing changes to remote:

1. Push new main with `--force-with-lease`
2. Push all updated patch branches with `--force-with-lease`
3. Push deletions for empty patches
4. Push notes to remote
5. Use `--atomic` to ensure all-or-nothing push
6. Handle concurrent update failures gracefully

**Why atomic push?**
- Prevents partial updates (all refs update or none do)
- Maintains consistency if someone else pushes concurrently
- `--force-with-lease` protects against accidental overwrites

## Part 1: Understanding Force-With-Lease

### Problem: Concurrent Updates

Two users syncing simultaneously:

```
# Initial remote state
origin/main: A --- B --- C

# User 1 syncs (integrates patch-X)
# Local: A --- B --- C --- SX

# User 2 syncs (integrates patch-Y)
# Local: A --- B --- C --- SY

# Both try to push at the same time
```

Without protection, last push wins and one user's work is lost.

### Solution: Force-With-Lease

`git push --force-with-lease=<ref>:<expected-sha>` only succeeds if the remote ref is at the expected SHA.

```bash
# User 1 pushes first
git push --force-with-lease=refs/heads/main:C origin main
# Success! Remote was at C, now at SX

# User 2 tries to push
git push --force-with-lease=refs/heads/main:C origin main
# Fails! Remote is at SX, not C
```

### Atomic Push

`git push --atomic` ensures all refspecs in the push succeed or all fail:

```bash
# All these happen together or not at all
git push --atomic origin \
    main:main \
    patch-A:patch-A \
    patch-B:patch-B \
    :refs/heads/patch-empty  # deletion
```

## Part 2: Implementation

### File: `scripts/patchstack`

#### Function: `build_push_refspecs()`

Builds refspec list for atomic push with force-with-lease.

```bash
build_push_refspecs() {
    local refspecs=()
    local lease_options=()

    # Get all updated refs from previous phase
    local updates
    readarray -t updates < <(calculate_ref_updates)

    for update in "${updates[@]}"; do
        local action=${update%%:*}
        local rest=${update#*:}

        if [ "$action" = "update" ]; then
            local ref=${rest%%:*}
            local new_sha=${rest#*:}
            local old_sha=$(git rev-parse "$ref" 2>/dev/null || echo "")

            # Extract branch name from ref
            local branch_name=${ref#refs/remotes/$PATCH_REMOTE/}

            # Add refspec: local_sha:remote_ref
            refspecs+=("$new_sha:refs/heads/$branch_name")

            # Add force-with-lease for this ref
            if [ -n "$old_sha" ]; then
                lease_options+=("--force-with-lease=refs/heads/$branch_name:$old_sha")
            fi

        elif [ "$action" = "delete" ]; then
            local ref=$rest
            local branch_name=${ref#refs/remotes/$PATCH_REMOTE/}
            local old_sha=$(git rev-parse "$ref" 2>/dev/null || echo "")

            # Add deletion refspec: :remote_ref
            refspecs+=(":refs/heads/$branch_name")

            # Add force-with-lease for deletion
            if [ -n "$old_sha" ]; then
                lease_options+=("--force-with-lease=refs/heads/$branch_name:$old_sha")
            fi
        fi
    done

    # Output refspecs and lease options
    for spec in "${refspecs[@]}"; do
        echo "refspec:$spec"
    done

    for opt in "${lease_options[@]}"; do
        echo "lease:$opt"
    done
}
```

#### Function: `push_refs()`

Executes the atomic push with all refspecs.

```bash
push_refs() {
    echo "Preparing push..."

    local pushspecs
    readarray -t pushspecs < <(build_push_refspecs)

    if [ ${#pushspecs[@]} -eq 0 ]; then
        echo "No changes to push"
        return 0
    fi

    # Parse refspecs and lease options
    local refspecs=()
    local lease_opts=()

    for spec in "${pushspecs[@]}"; do
        local type=${spec%%:*}
        local value=${spec#*:}

        if [ "$type" = "refspec" ]; then
            refspecs+=("$value")
        elif [ "$type" = "lease" ]; then
            lease_opts+=("$value")
        fi
    done

    echo "Pushing ${#refspecs[@]} refs to $PATCH_REMOTE..."

    # Build push command
    local push_cmd=(git push --atomic)

    # Add lease options
    for opt in "${lease_opts[@]}"; do
        push_cmd+=("$opt")
    done

    # Add remote
    push_cmd+=("$PATCH_REMOTE")

    # Add refspecs
    for spec in "${refspecs[@]}"; do
        push_cmd+=("$spec")
    done

    # Execute push
    if "${push_cmd[@]}" 2>&1; then
        echo "✓ Push successful"
        return 0
    else
        local code=$?
        echo "✗ Push failed (exit code: $code)"
        echo
        echo "This usually means:"
        echo "  - Someone else pushed to origin while you were syncing"
        echo "  - Run 'git fetch' and try sync again"
        echo "  - Or check remote permissions"
        return 1
    fi
}
```

#### Function: `push_notes()`

Pushes Git notes to remote.

```bash
push_notes() {
    echo "Pushing notes..."

    if git push "$PATCH_REMOTE" refs/notes/patchstack 2>&1; then
        echo "✓ Notes pushed"
        return 0
    else
        echo "⚠ Notes push failed (non-fatal)"
        return 0  # Don't fail sync if notes fail
    fi
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

    # Phase 4: Update local refs
    echo "Phase 4: Updating local refs"
    if ! apply_ref_updates; then
        echo "ERROR: Failed to update refs"
        return 1
    fi
    echo

    # Phase 5: Push to remote
    echo "Phase 5: Pushing to $PATCH_REMOTE"
    if ! push_refs; then
        echo "ERROR: Push failed"
        echo "Local refs updated but remote unchanged"
        return 1
    fi

    # Push notes (non-fatal)
    push_notes
    echo

    # Success summary
    echo "==================================="
    echo "Sync Complete"
    echo "==================================="
    echo
    echo "✓ All patches synced successfully"
    echo "✓ Remote updated"
}
```

## Part 3: Tests

Create `tests/test-18-atomic-push-success.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Atomic push succeeds with all refs updated together
test_dir=$(setup_test_env)
cd "$test_dir"

# Create a real remote (not just local)
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$test_dir" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patches
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 1

# Push patches to remote
git push origin patch-alpha patch-beta

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Record remote state before sync
cd "$REMOTE_DIR"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)
before_beta=$(git rev-parse patch-beta)

cd "$test_dir"

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Check remote was updated
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)
after_beta=$(git rev-parse patch-beta)

if [ "$after_main" = "$before_main" ]; then
    echo "ERROR: Remote main should be updated"
    exit 1
fi

if [ "$after_alpha" = "$before_alpha" ]; then
    echo "ERROR: Remote patch-alpha should be updated"
    exit 1
fi

if [ "$after_beta" = "$before_beta" ]; then
    echo "ERROR: Remote patch-beta should be updated"
    exit 1
fi

cd "$test_dir"
cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-19-lease-failure.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Atomic push with lease failure aborts all updates
test_dir=$(setup_test_env)
cd "$test_dir"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$test_dir" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch
create_patch_branch "patch-alpha" 1
git push origin patch-alpha

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Simulate concurrent update: someone else pushes to remote
cd "$REMOTE_DIR"
# Advance main to simulate another sync
git update-ref refs/heads/main HEAD
echo "concurrent-change" | git hash-object -w --stdin | xargs git commit-tree HEAD^{tree} -p HEAD -m "Concurrent change" | xargs git update-ref refs/heads/main

cd "$test_dir"

# Record remote state
cd "$REMOTE_DIR"
before_main=$(git rev-parse main)
before_alpha=$(git rev-parse patch-alpha)

cd "$test_dir"

# Run sync - should fail due to lease
if bash "$SCRIPT_DIR/patchstack" sync 2>&1; then
    echo "ERROR: Sync should fail due to concurrent update"
    exit 1
fi

# Check remote was NOT updated (atomic failure)
cd "$REMOTE_DIR"
after_main=$(git rev-parse main)
after_alpha=$(git rev-parse patch-alpha)

if [ "$after_main" != "$before_main" ]; then
    echo "ERROR: Remote main should NOT be updated after lease failure"
    exit 1
fi

if [ "$after_alpha" != "$before_alpha" ]; then
    echo "ERROR: Remote patch-alpha should NOT be updated after lease failure"
    exit 1
fi

cd "$test_dir"
cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-20-verify-remote-state.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Verify remote state after successful push
test_dir=$(setup_test_env)
cd "$test_dir"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$test_dir" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1
git push origin patch-alpha patch-beta

# Create empty patch
git checkout -b patch-empty origin/main
echo "empty-content" > empty.txt
git add empty.txt
git commit -m "Empty patch"
git push origin patch-empty

# Advance upstream with empty patch content
cd "$UPSTREAM_DIR"
echo "empty-content" > empty.txt
git add empty.txt
git commit -m "Upstream: merge empty patch"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Verify remote state
cd "$REMOTE_DIR"

# Main should exist and be ahead of previous
if ! git rev-parse main &>/dev/null; then
    echo "ERROR: Remote main should exist"
    exit 1
fi

# Alpha and beta should exist
if ! git rev-parse patch-alpha &>/dev/null; then
    echo "ERROR: Remote patch-alpha should exist"
    exit 1
fi

if ! git rev-parse patch-beta &>/dev/null; then
    echo "ERROR: Remote patch-beta should exist"
    exit 1
fi

# Empty patch should be deleted
if git rev-parse patch-empty &>/dev/null; then
    echo "ERROR: Remote patch-empty should be deleted"
    exit 1
fi

# Verify topology in remote
main_sha=$(git rev-parse main)
alpha_sha=$(git rev-parse patch-alpha)
beta_sha=$(git rev-parse patch-beta)

# Use git merge-base to check ancestry
if ! git merge-base --is-ancestor "$main_sha" "$alpha_sha"; then
    echo "ERROR: patch-alpha should be descendant of main in remote"
    exit 1
fi

if ! git merge-base --is-ancestor "$main_sha" "$beta_sha"; then
    echo "ERROR: patch-beta should be descendant of main in remote"
    exit 1
fi

cd "$test_dir"
cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-21-notes-pushed.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Verify notes pushed to remote
test_dir=$(setup_test_env)
cd "$test_dir"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$test_dir" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch
create_patch_branch "patch-alpha" 1
git push origin patch-alpha

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run sync
bash "$SCRIPT_DIR/patchstack" sync

# Fetch notes from remote
git fetch origin refs/notes/patchstack:refs/notes/patchstack

# Check notes exist for new main
new_main=$(git rev-parse origin/main)
notes=$(git notes --ref=patchstack show "$new_main" 2>/dev/null || echo "")

if [ -z "$notes" ]; then
    echo "ERROR: Notes should exist for new main"
    exit 1
fi

if ! echo "$notes" | grep -q "Patchstack sync"; then
    echo "ERROR: Notes should contain sync metadata"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

## Part 4: Error Handling

### Concurrent Update

When force-with-lease fails:

```
✗ Push failed (exit code: 1)

This usually means:
  - Someone else pushed to origin while you were syncing
  - Run 'git fetch' and try sync again
  - Or check remote permissions
```

User should:
1. Run `git fetch origin` to get latest remote state
2. Run `patchstack sync` again
3. The new sync will integrate any concurrent changes

### Network Issues

If push fails due to network:

```
ERROR: Push failed
Local refs updated but remote unchanged
```

User can:
1. Fix network issue
2. Re-run `patchstack sync`
3. Since local refs are already updated, sync will attempt push again

### Partial State

The `--atomic` flag ensures we never have partial updates:
- Either all refs update or none do
- No risk of inconsistent remote state
- Safe to retry after any failure

## Summary

Phase 1.5 implements atomic push with safety:

1. **Force-with-lease:** Prevents concurrent update conflicts
2. **Atomic push:** All-or-nothing ref updates
3. **Multiple refspecs:** Main + all patches + deletions in one push
4. **Notes included:** Sync metadata pushed to remote
5. **Clear errors:** User knows what happened and how to fix it
6. **Safe retry:** Failed push can be retried after fetch

The sync operation is now complete end-to-end. Next phases add usability features (dry-run, status) and error handling.
