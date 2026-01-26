# Phase 3.1: Backport Command

**Goal:** Provide a `patchstack backport` command that takes unidentifiable ("alien") commits from `origin/main` and creates new patch branches to preserve them.

**Status:** Planned

**Related Phases:**

- Depends on Phase 1.9 (Check Alien Commits) for alien commit detection
- Depends on Phase 1.6 (End-to-End Scenarios) for core sync functionality
- Part of Milestone 3: Recovery and Migration Tools

## Overview

### The Problem

When users have alien commits on `origin/main` (commits not traced to a patch branch), they face a dilemma:

1. **Run `patchstack sync --delete`:** Loses the commits forever
2. **Don't run sync:** Fork falls behind upstream

The `patchstack backport` command solves this by converting alien commits into proper patch branches that survive sync operations.

### Use Cases

1. **Migration:** Converting an existing fork to use patchstack
2. **Hotfix preservation:** Keeping emergency fixes that were pushed directly to main
3. **Recovery:** Salvaging work after discovering alien commits
4. **History cleanup:** Organizing ad-hoc commits into proper patches

## Part 1: Command Design

### Basic Usage

```bash
# Create patch branches for all alien commits
patchstack backport

# Preview what would be created (dry-run)
patchstack backport --dry-run

# Specify a prefix for generated branch names
patchstack backport --prefix="patch-backport"

# Create a single branch for all aliens (squashed together)
patchstack backport --single

# Interactive mode - choose which commits to backport
patchstack backport --interactive
```

### Default Behavior

By default, `patchstack backport`:

1. Finds all alien commits on `origin/main`
2. For each alien commit, creates a new patch branch
3. Branch names are auto-generated: `patch-backport-001`, `patch-backport-002`, etc.
4. Branches are based on current `upstream/main`
5. Each branch contains a single commit with the alien's changes
6. Reports what was created

### Single Branch Mode

With `--single`, all alien commits are combined:

1. Creates one branch: `patch-backport` (or specified name)
2. Applies all alien commits in order
3. Results in a multi-commit patch branch
4. Useful when aliens are logically related

## Part 2: Implementation

### Function: `cmd_backport()`

Main entry point for the backport command:

```bash
cmd_backport() {
    # Parse backport-specific flags
    local dry_run=false
    local prefix="patch-backport"
    local single_branch=false
    local interactive=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            --prefix=*)
                prefix="${1#*=}"
                shift
                ;;
            --single)
                single_branch=true
                shift
                ;;
            --interactive)
                interactive=true
                shift
                ;;
            *)
                echo "Unknown option: $1"
                return 1
                ;;
        esac
    done

    # Find alien commits
    local alien_commits
    readarray -t alien_commits < <(find_alien_commits)

    if [[ ${#alien_commits[@]} -eq 0 ]]; then
        echo "No alien commits found on origin/main."
        echo "Nothing to backport."
        return 0
    fi

    echo "Found ${#alien_commits[@]} alien commit(s) to backport."
    echo

    # Interactive selection
    if [[ "$interactive" == true ]]; then
        select_commits_interactive alien_commits
        if [[ ${#alien_commits[@]} -eq 0 ]]; then
            echo "No commits selected. Aborting."
            return 0
        fi
    fi

    # Show what will be done
    format_backport_preview alien_commits "$prefix" "$single_branch"

    if [[ "$dry_run" == true ]]; then
        echo
        echo "DRY RUN: No branches created."
        echo "Run without --dry-run to create the branches."
        return 0
    fi

    # Confirm with user
    echo
    read -p "Create these branches? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        return 0
    fi

    # Create the branches
    if [[ "$single_branch" == true ]]; then
        create_single_backport_branch alien_commits "$prefix"
    else
        create_multiple_backport_branches alien_commits "$prefix"
    fi

    echo
    echo "Backport complete!"
    echo
    echo "Next steps:"
    echo "  1. Review the created branches:"
    echo "     git log origin/main..origin/$prefix-001"
    echo "  2. Run patchstack sync to integrate:"
    echo "     patchstack sync"
    echo "  3. The alien commits will now be properly tracked."
}
```

### Function: `format_backport_preview()`

Shows what will be created:

```bash
format_backport_preview() {
    local -n commits=$1
    local prefix=$2
    local single=$3

    echo "Backport Plan"
    echo "============="
    echo

    if [[ "$single" == true ]]; then
        echo "Will create single branch: $prefix"
        echo "  Containing ${#commits[@]} commits:"
        for commit in "${commits[@]}"; do
            local short_sha
            short_sha=$(git rev-parse --short "$commit")
            local subject
            subject=$(git log -1 --format='%s' "$commit")
            echo "    $short_sha $subject"
        done
    else
        echo "Will create ${#commits[@]} branches:"
        local num=1
        for commit in "${commits[@]}"; do
            local branch_name
            branch_name=$(printf "%s-%03d" "$prefix" "$num")
            local short_sha
            short_sha=$(git rev-parse --short "$commit")
            local subject
            subject=$(git log -1 --format='%s' "$commit")
            echo "  $branch_name"
            echo "    ← $short_sha $subject"
            ((num++))
        done
    fi
}
```

### Function: `create_single_backport_branch()`

Creates one branch containing all alien commits:

```bash
create_single_backport_branch() {
    local -n commits=$1
    local branch_name=$2
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"

    echo "Creating branch: $branch_name"

    # Save current position
    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    local current_head
    current_head=$(git rev-parse HEAD)

    # Create branch from upstream
    if ! git checkout -b "$branch_name" "$upstream_ref" >/dev/null 2>&1; then
        echo "ERROR: Failed to create branch $branch_name"
        return 1
    fi

    local success=true
    for commit in "${commits[@]}"; do
        local short_sha
        short_sha=$(git rev-parse --short "$commit")

        echo "  Cherry-picking $short_sha..."

        if ! git cherry-pick "$commit" >/dev/null 2>&1; then
            echo "    ERROR: Cherry-pick failed for $short_sha"
            echo "    Conflict detected. Resolving by keeping changes..."

            # Try to auto-resolve by accepting the incoming change
            if git cherry-pick --abort >/dev/null 2>&1; then
                # Try with theirs strategy
                if ! git cherry-pick --strategy-option=theirs "$commit" >/dev/null 2>&1; then
                    echo "    WARNING: Could not apply $short_sha cleanly"
                    echo "    Creating partial backport."
                    git cherry-pick --abort >/dev/null 2>&1 || true
                fi
            fi
        fi
    done

    # Push the branch
    if ! git push origin "$branch_name" >/dev/null 2>&1; then
        echo "ERROR: Failed to push $branch_name"
        success=false
    else
        echo "  ✓ Pushed $branch_name"
    fi

    # Return to original state
    if [[ -n "$current_branch" ]]; then
        git checkout -q "$current_branch" >/dev/null 2>&1 || true
    elif [[ -n "$current_head" ]]; then
        git checkout -q "$current_head" >/dev/null 2>&1 || true
    fi

    if [[ "$success" == false ]]; then
        return 1
    fi
    return 0
}
```

### Function: `create_multiple_backport_branches()`

Creates separate branches for each alien commit:

```bash
create_multiple_backport_branches() {
    local -n commits=$1
    local prefix=$2
    local upstream_ref="refs/remotes/$UPSTREAM_REMOTE/$MAIN_BRANCH"

    # Save current position
    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    local current_head
    current_head=$(git rev-parse HEAD)

    local num=1
    local created=0
    local failed=0

    for commit in "${commits[@]}"; do
        local branch_name
        branch_name=$(printf "%s-%03d" "$prefix" "$num")
        local short_sha
        short_sha=$(git rev-parse --short "$commit")

        echo "Creating $branch_name from $short_sha..."

        # Create branch from upstream
        if ! git checkout -b "$branch_name" "$upstream_ref" >/dev/null 2>&1; then
            echo "  ERROR: Failed to create branch"
            ((failed++))
            ((num++))
            continue
        fi

        # Cherry-pick the commit
        if ! git cherry-pick "$commit" >/dev/null 2>&1; then
            echo "  WARNING: Cherry-pick has conflicts"

            # Try to resolve automatically
            if git cherry-pick --abort >/dev/null 2>&1; then
                # Create an empty commit with the original message
                local msg
                msg=$(git log -1 --format='%B' "$commit")
                git commit --allow-empty -m "[CONFLICT] $msg

Original commit: $commit
This commit could not be cleanly backported.
Manual intervention required." >/dev/null 2>&1
            fi
        fi

        # Push the branch
        if ! git push origin "$branch_name" >/dev/null 2>&1; then
            echo "  ERROR: Failed to push"
            git branch -D "$branch_name" >/dev/null 2>&1 || true
            ((failed++))
        else
            echo "  ✓ Created and pushed"
            ((created++))
        fi

        # Clean up before next iteration
        git checkout -q "$upstream_ref" >/dev/null 2>&1 || true

        ((num++))
    done

    # Return to original state
    if [[ -n "$current_branch" ]]; then
        git checkout -q "$current_branch" >/dev/null 2>&1 || true
    elif [[ -n "$current_head" ]]; then
        git checkout -q "$current_head" >/dev/null 2>&1 || true
    fi

    echo
    echo "Created $created branches, $failed failed."
}
```

### Function: `select_commits_interactive()`

Interactive commit selection:

```bash
select_commits_interactive() {
    local -n commits=$1
    local selected=()

    echo "Select commits to backport (space to toggle, enter to confirm):"
    echo

    # Simple interactive selection
    for i in "${!commits[@]}"; do
        local commit=${commits[$i]}
        local short_sha
        short_sha=$(git rev-parse --short "$commit")
        local subject
        subject=$(git log -1 --format='%s' "$commit")

        read -p "  [$((i+1))] $short_sha $subject? [Y/n] " choice
        if [[ "$choice" != "n" && "$choice" != "N" ]]; then
            selected+=("$commit")
        fi
    done

    # Update the array
    commits=("${selected[@]}")
}
```

## Part 3: Conflict Handling Strategies

### Best-Effort Application

When cherry-picking fails:

1. **Strategy 1: Accept incoming (default)**
   - Use `--strategy-option=theirs`
   - Preserves alien changes, may override upstream

2. **Strategy 2: Create conflict marker commit**
   - Create commit noting the conflict
   - Leave resolution to user

3. **Strategy 3: Skip conflicting commits**
   - Report but don't create branch
   - User must handle manually

### Implementation of Conflict Strategies

```bash
apply_commit_with_strategy() {
    local commit=$1
    local strategy=${2:-"theirs"}

    case "$strategy" in
        theirs)
            # Accept incoming changes
            if ! git cherry-pick --strategy-option=theirs "$commit" >/dev/null 2>&1; then
                return 1
            fi
            ;;
        marker)
            # Create a marker commit
            local msg
            msg=$(git log -1 --format='%B' "$commit")
            local diff
            diff=$(git diff "$commit^" "$commit" 2>/dev/null | head -100)

            git commit --allow-empty -m "[NEEDS MANUAL RESOLUTION] $msg

Original commit: $commit

This commit conflicted when backporting. The original changes were:

$diff
..." >/dev/null 2>&1
            ;;
        skip)
            # Just report and skip
            return 1
            ;;
    esac

    return 0
}
```

## Part 4: Usage Updates

### Update Main Usage

```bash
usage() {
    cat <<EOF
Usage: patchstack [flags] <command>

Commands:
    sync          Synchronize patch stack with upstream
    status        Show current patch stack state
    list          List patch branches
    history       Show origin/main commit history with provenance
    backport      Convert alien commits to patch branches

Backport Command:
    patchstack backport [options]

    Creates patch branches from alien commits on origin/main,
    allowing them to be properly tracked by patchstack.

    Options:
        --dry-run         Preview what would be created
        --prefix=NAME     Branch name prefix (default: patch-backport)
        --single          Create one branch with all commits
        --interactive     Select which commits to backport

    Examples:
        patchstack backport                    # Backport all aliens
        patchstack backport --dry-run          # Preview
        patchstack backport --prefix=patch-fix # Custom prefix
        patchstack backport --single           # Single branch

...rest of usage...
EOF
}
```

## Part 5: Tests

### Test: Basic Backport

Create `tests/test-50-backport-basic.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Backport creates branches for alien commits
test_dir=$(setup_test_env)
cd "$test_dir"

setup_bare_remote

# Create initial patch and sync
create_patch_branch "patch-alpha" 1
git push origin patch-alpha
bash "$SCRIPT_DIR/patchstack" sync

# Add alien commits
git checkout main
echo "fix1" > fix1.txt
git add fix1.txt
git commit -m "Hotfix 1"
echo "fix2" > fix2.txt
git add fix2.txt
git commit -m "Hotfix 2"
git push origin main

git fetch origin

# Run backport (with auto-confirm via yes pipe)
echo "y" | bash "$SCRIPT_DIR/patchstack" backport

# Verify branches were created
git fetch origin
if ! git rev-parse origin/patch-backport-001 &>/dev/null; then
    echo "ERROR: patch-backport-001 should exist"
    exit 1
fi

if ! git rev-parse origin/patch-backport-002 &>/dev/null; then
    echo "ERROR: patch-backport-002 should exist"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

### Test: Backport Dry-Run

Create `tests/test-51-backport-dry-run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Backport dry-run shows plan without creating branches
test_dir=$(setup_test_env)
cd "$test_dir"

setup_bare_remote

# Create alien commits
create_patch_branch "patch-alpha" 1
git push origin patch-alpha
bash "$SCRIPT_DIR/patchstack" sync

git checkout main
git commit --allow-empty -m "Alien commit"
git push origin main

git fetch origin

# Run backport in dry-run mode
output=$(bash "$SCRIPT_DIR/patchstack" backport --dry-run 2>&1)

# Should show preview
if ! echo "$output" | grep -q "patch-backport-001"; then
    echo "ERROR: Should show planned branch name"
    exit 1
fi

if ! echo "$output" | grep -q "DRY RUN"; then
    echo "ERROR: Should indicate dry run"
    exit 1
fi

# Should NOT have created branch
git fetch origin
if git rev-parse origin/patch-backport-001 &>/dev/null 2>&1; then
    echo "ERROR: Branch should not exist in dry-run"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

### Test: Backport Single Branch

Create `tests/test-52-backport-single.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Backport --single creates one branch with all commits
test_dir=$(setup_test_env)
cd "$test_dir"

setup_bare_remote

# Setup
create_patch_branch "patch-alpha" 1
git push origin patch-alpha
bash "$SCRIPT_DIR/patchstack" sync

# Add multiple alien commits
git checkout main
git commit --allow-empty -m "Alien 1"
git commit --allow-empty -m "Alien 2"
git commit --allow-empty -m "Alien 3"
git push origin main

git fetch origin

# Run backport with --single
echo "y" | bash "$SCRIPT_DIR/patchstack" backport --single --prefix=patch-fixes

# Should create single branch
git fetch origin
if ! git rev-parse origin/patch-fixes &>/dev/null; then
    echo "ERROR: patch-fixes branch should exist"
    exit 1
fi

# Branch should have 3 commits above upstream
commit_count=$(git rev-list --count upstream/main..origin/patch-fixes)
if [[ "$commit_count" != "3" ]]; then
    echo "ERROR: Expected 3 commits, got $commit_count"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

### Test: Backport Then Sync

Create `tests/test-53-backport-then-sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: After backport, sync works without alien warnings
test_dir=$(setup_test_env)
cd "$test_dir"

setup_bare_remote

# Initial setup
create_patch_branch "patch-alpha" 1
git push origin patch-alpha
bash "$SCRIPT_DIR/patchstack" sync

# Add alien commit
git checkout main
echo "hotfix" > hotfix.txt
git add hotfix.txt
git commit -m "Emergency hotfix"
git push origin main

git fetch origin

# Backport the alien
echo "y" | bash "$SCRIPT_DIR/patchstack" backport

# Advance upstream
cd "$UPSTREAM_DIR"
git commit --allow-empty -m "Upstream progress"

cd "$test_dir"
git fetch upstream
git fetch origin

# Sync should now work without --delete
output=$(bash "$SCRIPT_DIR/patchstack" sync 2>&1)

# Should succeed
if [[ $? -ne 0 ]]; then
    echo "ERROR: Sync should succeed after backport"
    echo "$output"
    exit 1
fi

# Should NOT mention alien commits
if echo "$output" | grep -qi "alien"; then
    echo "ERROR: Should not have alien commits after backport"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

### Test: No Aliens to Backport

Create `tests/test-54-backport-no-aliens.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/harness.sh"

# Test: Backport with no aliens reports nothing to do
test_dir=$(setup_test_env)
cd "$test_dir"

setup_bare_remote

# Create clean state (no aliens)
create_patch_branch "patch-alpha" 1
git push origin patch-alpha
bash "$SCRIPT_DIR/patchstack" sync

git fetch origin

# Run backport
output=$(bash "$SCRIPT_DIR/patchstack" backport 2>&1)

# Should report nothing to do
if ! echo "$output" | grep -qi "no alien\|nothing to backport"; then
    echo "ERROR: Should report no aliens found"
    exit 1
fi

cleanup_test_env
echo "✓ Test passed"
```

## Part 6: Advanced Features (Future)

### Automatic Conflict Resolution

```bash
# Specify conflict strategy
patchstack backport --conflict-strategy=theirs    # Accept alien changes
patchstack backport --conflict-strategy=skip      # Skip conflicting commits
patchstack backport --conflict-strategy=manual    # Create markers
```

### Branch Name Templates

```bash
# Use date-based naming
patchstack backport --template="patch-hotfix-{date}"

# Use commit info
patchstack backport --template="patch-{short-sha}-{subject}"
```

### Integration with Issue Tracking

```bash
# Create branches referencing issues
patchstack backport --issue-prefix="patch-issue-"
# Creates: patch-issue-123 (if commit message has #123)
```

## Summary

Phase 3.1 provides recovery tools:

1. **`patchstack backport`**: Converts alien commits to patch branches
2. **Multiple modes**: Individual branches, single branch, interactive selection
3. **Conflict handling**: Best-effort application with configurable strategies
4. **Dry-run support**: Preview before creating branches
5. **Integration**: Backported branches become normal patches for future syncs

This completes the alien commit handling story started in Phase 1.9, providing a full workflow:

1. Detect aliens → Phase 1.9
2. Review with `patchstack history` → Phase 1.9
3. Convert to patches with `patchstack backport` → Phase 3.1
4. Sync normally → Phase 1.6

Users never lose commits unintentionally.
