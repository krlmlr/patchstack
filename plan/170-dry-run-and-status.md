# Phase 1.7: Dry-Run and Status

**Goal:** Add `--dry-run` flag and `status` subcommand to provide visibility into planned changes and current state without making modifications.

## Overview

This phase adds user-facing features for inspection:

1. `patchstack sync --dry-run` - Show what would be done without doing it
2. `patchstack status` - Show current patch stack state
3. `patchstack list` - Already implemented, may enhance
4. Logging levels for verbosity control

These features help users understand and verify operations before executing them.

## Part 1: Dry-Run Mode

### What Dry-Run Does

Execute all phases except:
- No ref updates (skip `apply_ref_updates`)
- No push (skip `push_refs` and `push_notes`)

Show what would happen:
- Which patches would be integrated
- Which patches would fail (and why)
- Which refs would be updated
- Which refs would be deleted

### Implementation

#### Add Flag Parsing

Update `scripts/patchstack` to support flags:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Default configuration
PATCH_REMOTE="${PATCH_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
DRY_RUN=false
VERBOSE=false

# Parse global flags
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            *)
                # Not a flag, return remaining args
                echo "$@"
                return
                ;;
        esac
    done
}

main() {
    # Parse flags first
    local remaining
    remaining=$(parse_flags "$@")

    # Get command
    local command=""
    if [ -n "$remaining" ]; then
        command=$(echo "$remaining" | awk '{print $1}')
    fi

    case "$command" in
        sync)
            cmd_sync
            ;;
        status)
            cmd_status
            ;;
        list)
            cmd_list
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

usage() {
    cat <<EOF
Usage: patchstack [flags] <command>

Commands:
    sync      Synchronize patch stack with upstream
    status    Show current patch stack state
    list      List patch branches

Flags:
    --dry-run     Show what would be done without doing it
    --verbose     Show detailed output
    -v            Alias for --verbose

Environment:
    PATCH_REMOTE      Remote name for fork (default: origin)
    UPSTREAM_REMOTE   Remote name for upstream (default: upstream)
    MAIN_BRANCH       Main branch name (default: main)

Examples:
    patchstack sync
    patchstack sync --dry-run
    patchstack status
    patchstack list
EOF
}

main "$@"
```

#### Update `cmd_sync` for Dry-Run

```bash
cmd_sync() {
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: No changes will be made"
        echo
    fi

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
    echo

    # Phase 3: Integration
    echo "Phase 3: Integrating patches into new main"
    local integration_results
    readarray -t integration_results < <(integrate_patches)
    echo

    if [ "$DRY_RUN" = true ]; then
        echo "==================================="
        echo "DRY RUN Summary (No Changes Made)"
        echo "==================================="
        echo

        # Show what would be updated
        echo "Would update local refs:"
        local updates
        readarray -t updates < <(calculate_ref_updates)
        for update in "${updates[@]}"; do
            local action=${update%%:*}
            local rest=${update#*:}
            if [ "$action" = "update" ]; then
                local ref=${rest%%:*}
                local branch=${ref#refs/remotes/$PATCH_REMOTE/}
                echo "  ✓ $branch"
            elif [ "$action" = "delete" ]; then
                local ref=$rest
                local branch=${ref#refs/remotes/$PATCH_REMOTE/}
                echo "  ✗ $branch (would be deleted)"
            fi
        done
        echo

        echo "Would push to $PATCH_REMOTE"
        echo
        echo "To apply these changes, run:"
        echo "  patchstack sync"
        return 0
    fi

    # Phase 4: Update local refs (not in dry-run)
    echo "Phase 4: Updating local refs"
    if ! apply_ref_updates; then
        echo "ERROR: Failed to update refs"
        return 1
    fi
    echo

    # Phase 5: Push to remote (not in dry-run)
    echo "Phase 5: Pushing to $PATCH_REMOTE"
    if ! push_refs; then
        echo "ERROR: Push failed"
        echo "Local refs updated but remote unchanged"
        return 1
    fi

    push_notes
    echo

    # Success summary
    echo "==================================="
    echo "Sync Complete"
    echo "==================================="
    echo
    echo "✓ Remote updated successfully"
}
```

## Part 2: Status Command

### What Status Shows

Current state of patch stack:
- Upstream position (SHA, ahead/behind)
- Origin main position
- Each patch branch with status:
  - Number of commits
  - Relationship to origin/main
  - Relationship to upstream/main

### Implementation

```bash
cmd_status() {
    echo "Patchstack Status"
    echo "================="
    echo

    # Check remotes exist
    if ! git remote get-url "$UPSTREAM_REMOTE" &>/dev/null; then
        echo "ERROR: Remote '$UPSTREAM_REMOTE' not configured"
        echo "Expected upstream remote not found"
        return 1
    fi

    if ! git remote get-url "$PATCH_REMOTE" &>/dev/null; then
        echo "ERROR: Remote '$PATCH_REMOTE' not configured"
        return 1
    fi

    # Show remote configuration
    echo "Configuration:"
    echo "  Fork:     $PATCH_REMOTE ($(git remote get-url $PATCH_REMOTE))"
    echo "  Upstream: $UPSTREAM_REMOTE ($(git remote get-url $UPSTREAM_REMOTE))"
    echo "  Branch:   $MAIN_BRANCH"
    echo

    # Check refs exist
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"
    local origin_ref="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"

    if ! git rev-parse "$upstream_ref" &>/dev/null; then
        echo "ERROR: $upstream_ref not found"
        echo "Run 'git fetch $UPSTREAM_REMOTE' first"
        return 1
    fi

    if ! git rev-parse "$origin_ref" &>/dev/null; then
        echo "ERROR: $origin_ref not found"
        echo "Run 'git fetch $PATCH_REMOTE' first"
        return 1
    fi

    # Show main branch status
    echo "Main Branch:"
    local upstream_sha=$(git rev-parse --short "$upstream_ref")
    local origin_sha=$(git rev-parse --short "$origin_ref")

    echo "  Upstream: $upstream_sha"
    echo "  Fork:     $origin_sha"

    # Check if origin/main is behind upstream
    if git merge-base --is-ancestor "$upstream_ref" "$origin_ref"; then
        if [ "$(git rev-parse $upstream_ref)" = "$(git rev-parse $origin_ref)" ]; then
            echo "  Status:   ✓ Up to date"
        else
            local ahead=$(git rev-list --count "$upstream_ref..$origin_ref")
            echo "  Status:   ✓ Ahead by $ahead commits"
        fi
    else
        local behind=$(git rev-list --count "$origin_ref..$upstream_ref")
        echo "  Status:   ⚠ Behind by $behind commits (sync needed)"
    fi
    echo

    # Show patch branches
    local patches
    readarray -t patches < <(discover_patch_branches)

    if [ ${#patches[@]} -eq 0 ]; then
        echo "Patch Branches: None"
        return 0
    fi

    echo "Patch Branches:"
    for patch in "${patches[@]}"; do
        local patch_ref="refs/remotes/$PATCH_REMOTE/$patch"
        local patch_sha=$(git rev-parse --short "$patch_ref")
        local commit_count=$(git rev-list --count "$origin_ref..$patch_ref")

        # Check if based on origin/main
        if git merge-base --is-ancestor "$origin_ref" "$patch_ref"; then
            local status="✓"
        else
            local status="⚠"
        fi

        echo "  $status $patch ($patch_sha)"
        echo "      $commit_count commits ahead of main"

        # Check relationship to upstream
        if ! git merge-base --is-ancestor "$upstream_ref" "$patch_ref"; then
            local behind=$(git rev-list --count "$patch_ref..$upstream_ref")
            echo "      ⚠ Needs rebase ($behind commits behind upstream)"
        fi
    done
}
```

## Part 3: Enhanced List Command

Already implemented in Phase 1.1, but add more details:

```bash
cmd_list() {
    local patches
    readarray -t patches < <(discover_patch_branches)

    if [ ${#patches[@]} -eq 0 ]; then
        echo "No patch branches found"
        return 0
    fi

    local origin_main="refs/remotes/$PATCH_REMOTE/$MAIN_BRANCH"

    for patch in "${patches[@]}"; do
        local patch_ref="refs/remotes/$PATCH_REMOTE/$patch"
        local commit_count=$(git rev-list --count "$origin_main..$patch_ref")

        if [ "$VERBOSE" = true ]; then
            local patch_sha=$(git rev-parse --short "$patch_ref")
            echo "$patch ($patch_sha, $commit_count commits)"
        else
            echo "$patch"
        fi
    done

    echo
    echo "Found ${#patches[@]} patch branches"
}
```

## Part 4: Tests

Create `tests/test-28-dry-run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Dry-run shows planned changes without making them
test_dir=$(setup_test_env)
cd "$test_dir"

# Create real remote
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$test_dir" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

# Create patch
create_patch_branch "patch-alpha" 1
git push origin patch-alpha

# Record initial state
initial_main=$(git rev-parse origin/main)
initial_alpha=$(git rev-parse origin/patch-alpha)

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change"

cd "$test_dir"
git fetch upstream

# Run dry-run
output=$(bash "$SCRIPT_DIR/patchstack" sync --dry-run 2>&1)

# Verify no changes were made
final_main=$(git rev-parse origin/main)
final_alpha=$(git rev-parse origin/patch-alpha)

if [ "$final_main" != "$initial_main" ]; then
    echo "ERROR: Dry-run should not change origin/main"
    exit 1
fi

if [ "$final_alpha" != "$initial_alpha" ]; then
    echo "ERROR: Dry-run should not change origin/patch-alpha"
    exit 1
fi

# Verify remote was not changed
cd "$REMOTE_DIR"
remote_main=$(git rev-parse main)
if [ "$remote_main" != "$initial_main" ]; then
    echo "ERROR: Dry-run should not change remote"
    exit 1
fi

# Verify output mentions dry-run
cd "$test_dir"
if ! echo "$output" | grep -iq "dry.run"; then
    echo "ERROR: Output should mention dry run"
    exit 1
fi

# Verify output shows what would happen
if ! echo "$output" | grep -iq "would.*update\|would.*push"; then
    echo "ERROR: Output should show planned changes"
    exit 1
fi

assert_snapshot "28-dry-run" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-29-status-command.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Status shows current patch branches and integration state
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patches
create_patch_branch "patch-alpha" 2
create_patch_branch "patch-beta" 1

# Run status
output=$(bash "$SCRIPT_DIR/patchstack" status 2>&1)

# Should mention both patches
if ! echo "$output" | grep -q "patch-alpha"; then
    echo "ERROR: Status should show patch-alpha"
    exit 1
fi

if ! echo "$output" | grep -q "patch-beta"; then
    echo "ERROR: Status should show patch-beta"
    exit 1
fi

# Should show main branch status
if ! echo "$output" | grep -iq "main\|upstream"; then
    echo "ERROR: Status should show main branch info"
    exit 1
fi

# Should show commit counts
if ! echo "$output" | grep -q "2 commits"; then
    echo "ERROR: Status should show patch-alpha has 2 commits"
    exit 1
fi

if ! echo "$output" | grep -q "1 commit"; then
    echo "ERROR: Status should show patch-beta has 1 commit"
    exit 1
fi

assert_snapshot "29-status-command" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-30-status-needs-sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Status detects when sync is needed
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patch
create_patch_branch "patch-alpha" 1

# Advance upstream (creates need for sync)
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream change 1"
git commit --allow-empty -m "Upstream change 2"

cd "$test_dir"
git fetch upstream

# Run status
output=$(bash "$SCRIPT_DIR/patchstack" status 2>&1)

# Should indicate sync needed
if ! echo "$output" | grep -iq "behind\|sync needed\|needs rebase"; then
    echo "ERROR: Status should indicate sync is needed"
    exit 1
fi

# Should show how many commits behind
if ! echo "$output" | grep -q "2"; then
    echo "ERROR: Status should show fork is 2 commits behind"
    exit 1
fi

assert_snapshot "30-status-needs-sync" "$output"

cleanup_test_env
echo "✓ Test passed"
```

Create `tests/test-31-verbose-list.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Verbose list shows additional details
test_dir=$(setup_test_env)
cd "$test_dir"

# Create patches with different commit counts
create_patch_branch "patch-alpha" 1
create_patch_branch "patch-beta" 3

# Regular list
output_regular=$(bash "$SCRIPT_DIR/patchstack" list 2>&1)

# Should show patch names
if ! echo "$output_regular" | grep -q "patch-alpha"; then
    echo "ERROR: List should show patch-alpha"
    exit 1
fi

# Verbose list
output_verbose=$(bash "$SCRIPT_DIR/patchstack" list --verbose 2>&1)

# Should show commit counts
if ! echo "$output_verbose" | grep -q "1 commit"; then
    echo "ERROR: Verbose list should show commit count for patch-alpha"
    exit 1
fi

if ! echo "$output_verbose" | grep -q "3 commits"; then
    echo "ERROR: Verbose list should show commit count for patch-beta"
    exit 1
fi

# Should show SHAs
if ! echo "$output_verbose" | grep -qE "[0-9a-f]{7}"; then
    echo "ERROR: Verbose list should show commit SHAs"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

## Part 5: Logging

Add optional verbose logging:

```bash
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[VERBOSE] $*" >&2
    fi
}

log_info() {
    echo "$*"
}

log_error() {
    echo "ERROR: $*" >&2
}

log_warning() {
    echo "WARNING: $*" >&2
}
```

Use throughout the code:

```bash
replay_patch_commits() {
    local branch_name=$1
    log_verbose "Replaying $branch_name..."

    # ... existing code ...

    if [ $failed -eq 1 ]; then
        log_verbose "Replay failed for $branch_name"
        return 3
    fi

    log_verbose "Replay successful for $branch_name"
    return 0
}
```

## Summary

Phase 1.7 adds visibility features:

1. **Dry-run mode:** Preview changes without applying them
2. **Status command:** Show current state and whether sync is needed
3. **Enhanced list:** Show commit counts and SHAs in verbose mode
4. **Logging:** Optional verbose output for debugging

These features make patchstack more user-friendly and transparent. Users can:
- Verify planned changes before executing
- Check patch stack state at any time
- Understand what sync will do
- Debug issues with verbose logging

Next phase (1.8) adds error handling and recovery.
