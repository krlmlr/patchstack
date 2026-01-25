# Phase 1.6.1: Address PR Review Feedback

**Goal:** Address all review comments from merged PRs #7, #10, and #11 to improve robustness, security, and correctness.

## Overview

This document consolidates review feedback from PRs #7 (Phase 1.3), #10 (Phase 1.4), and #11 (Phase 1.5) that should be addressed before considering Milestone 1 complete.

## Issues from PR #11 (Phase 1.5)

### 1. Unbound Variable Error in build_push_refspecs

**Issue:** `old_sha` is read via `${old_shas[$ref]}` under `set -u`. If the key is missing, this will raise an "unbound variable" error.

**Location:** `scripts/patchstack` line 535

**Fix:** Use defaulting expansion `${old_shas[$ref]-}` and validate that captured old SHA exists.

```bash
local old_sha="${old_shas[$ref]-}"
if [[ -z "$old_sha" ]]; then
    echo "ERROR: No captured state for ref $ref" >&2
    return 1
fi
```

### 2. Missing Force-with-Lease for New Refs

**Issue:** Force-with-lease is only added when `old_sha` is non-empty. For new refs, no lease protection is applied, weakening concurrency guarantees.

**Location:** `scripts/patchstack` line 550

**Fix:** Always add force-with-lease, using empty expected value to assert "ref must not exist" when `old_sha` is empty.

```bash
if [[ -n "$old_sha" ]]; then
    lease_opts+=("--force-with-lease=$remote_ref:$old_sha")
else
    # New ref - assert it doesn't exist on remote
    lease_opts+=("--force-with-lease=$remote_ref:")
fi
```

### 3. Insecure Temp File Handling

**Issue:** Ref-state file uses predictable path `/tmp/patchstack-ref-state.$$` which has symlink/race risks on multi-user systems.

**Location:** `scripts/patchstack` line 716

**Fix:** Use `mktemp` with restrictive permissions and pass path around rather than hardcoding.

```bash
local ref_state_file
ref_state_file="$(mktemp "${TMPDIR:-/tmp}/patchstack-ref-state.XXXXXX")"
capture_ref_state > "$ref_state_file"

# Later: pass ref_state_file to build_push_refspecs
# Clean up: rm -f "$ref_state_file"
```

### 4. Stale Tmp Refs from Previous Runs

**Issue:** `calculate_ref_updates` enumerates `refs/patchstack/tmp/*` directly, but nothing clears this namespace at the start. Stale tmp refs from previous runs could corrupt remote state.

**Location:** `scripts/patchstack` line 344

**Fix:** Add cleanup step at the start of `cmd_sync` to delete all `refs/patchstack/tmp/*` refs.

```bash
cmd_sync() {
    echo "🚀 Starting patchstack sync..."
    echo
    
    # Clean up any stale tmp refs from previous runs
    git for-each-ref --format='%(refname)' 'refs/patchstack/tmp/' | while read -r ref; do
        git update-ref -d "$ref" >/dev/null 2>&1 || true
    done
    
    # ... rest of sync
}
```

### 5. Empty Patches Attempted During Integration

**Issue:** Empty patches keep their tmp refs, but `integrate_patches` iterates all `refs/patchstack/tmp/*` refs, causing it to attempt integrating empty patches which fails with "nothing to commit".

**Location:** `scripts/patchstack` line 161

**Fix:** Delete tmp ref for empty patches so integration doesn't attempt to process them.

```bash
if [[ "$replayed_tree" == "$upstream_tree" ]] || [[ $empty -eq 1 ]]; then
    # Empty patch - remove the tmp ref so integration skips it
    git update-ref -d "$tmp_ref" >/dev/null 2>&1 || true
    return 4
fi
```

## Issues from PR #10 (Phase 1.4)

### 6. Notes Written Before Atomic Transaction

**Issue:** In `apply_ref_updates`, `record_notes` is called during the loop before `git update-ref --stdin` runs. If the transaction fails, notes are already written, breaking atomicity.

**Location:** `scripts/patchstack` line 455

**Fix:** Collect note data during loop and write notes only after `git update-ref --stdin` succeeds.

```bash
apply_ref_updates() {
    local updates
    readarray -t updates < <(calculate_ref_updates)
    
    local update_cmds=()
    local note_data=()
    
    for update in "${updates[@]}"; do
        # ... parse update ...
        
        if [[ "$action" == "update" ]]; then
            update_cmds+=("update $ref $new_sha")
            note_data+=("$ref:$old_sha:$new_sha:updated")
        elif [[ "$action" == "delete" ]]; then
            update_cmds+=("delete $ref $old_sha")
            note_data+=("$ref:$old_sha:deleted:empty")
        fi
    done
    
    # Execute atomic transaction
    if printf '%s\n' "${update_cmds[@]}" | git update-ref --stdin; then
        # Only write notes after successful update
        for note in "${note_data[@]}"; do
            # Parse and call record_notes
        done
        return 0
    else
        return 1
    fi
}
```

### 7. Notes Written Before Transaction (Empty-Only Branch)

**Issue:** Same as #6, but in the `viable == 0` branch of `cmd_sync` where empty patch deletions are applied.

**Location:** `scripts/patchstack` line 567

**Fix:** Same pattern - defer note writes until after transaction succeeds.

### 8. Missing Notes for Deleted Patches

**Issue:** `record_notes` skips creating a note when `new_sha` is `deleted`, but docs say deleted patches should have their final tip recorded.

**Location:** `scripts/patchstack` line 394

**Fix:** Write note against `old_sha` for deletions.

```bash
record_notes() {
    local ref=$1
    local old_sha=$2
    local new_sha=$3
    local status=$4
    
    # Add note to the relevant commit (new tip, or old tip for deletions)
    local target_sha
    if [[ "$new_sha" == "deleted" ]]; then
        target_sha="$old_sha"
    else
        target_sha="$new_sha"
    fi
    
    if [[ -n "${target_sha:-}" ]]; then
        local note="ref: $ref
old: $old_sha
new: $new_sha
status: $status
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        
        git notes --ref=patchstack add -f -m "$note" "$target_sha" 2>/dev/null || true
    fi
}
```

### 9. Patches Not Discoverable After Sync

**Issue:** After sync, patch refs point to commits based on `upstream/main`, not the new integrated `origin/main`. `discover_patch_branches` filters by ancestry from `origin/main`, so patches won't be found on next sync.

**Location:** `scripts/patchstack` line 366

**Status:** This is by design per GUIDE.md - patches remain based on upstream. Discovery needs to handle this correctly. This might not be an issue if we're checking ancestry correctly, but needs verification.

### 10. Failed Integration Patches Still Updated

**Issue:** Patch refs are updated whenever tmp refs exist, but tmp refs exist even for patches that fail integration. This contradicts "failed patches remain unchanged".

**Location:** `scripts/patchstack` line 369

**Fix:** Only update refs for patches that were actually integrated. Check if tmp ref is ancestor of integration main.

```bash
if git merge-base --is-ancestor "$tmp_ref" "$integration_main" 2>/dev/null; then
    # Patch was integrated - update the ref
    # ...
fi
# If tmp_ref doesn't exist or wasn't integrated, leave unchanged
```

### 11. Unclear Topology Check in test-23

**Issue:** Comment says "Verify that patches are NOT ancestors of main", but the code treats them being ancestors as OK.

**Location:** `tests/test-23-verify-ref-topology.sh` line 71

**Fix:** Either remove the dead check/comment, or make it a real assertion.

## Issues from PR #7 (Phase 1.3)

### 12. Test Files Use Single-Bracket Conditionals

**Issue:** Tests 14, 15, 17, 18 use `[ ]` instead of `[[ ]]` which is preferred in the repo.

**Locations:** 
- `tests/test-14-squash-three-patches.sh` line 40
- `tests/test-15-integration-conflict.sh` line 59
- `tests/test-17-empty-patch-excluded.sh` line 60
- `tests/test-18-multiple-integration-failures.sh` line 54

**Fix:** Replace all `[ ... ]` with `[[ ... ]]` in these test files.

### 13. Misleading Comment in test-15

**Issue:** File header says "excludes patch-B, includes A and C" but branches are named alpha/beta/gamma.

**Location:** `tests/test-15-integration-conflict.sh` line 2

**Fix:** Update comment to match actual branch names.

### 14. Stale Tmp Refs Re-integrated

**Issue:** `integrate_patches` iterates over all `refs/patchstack/tmp/*` refs which can include stale refs from previous runs.

**Location:** `scripts/patchstack` line 283

**Status:** Addressed by fix #4 above (cleanup at start of sync).

### 15. Detached HEAD Not Handled

**Issue:** `create_squash_commit` only captures branch name. If user is on detached HEAD, it alters their position.

**Location:** `scripts/patchstack` line 218

**Fix:** Capture original HEAD SHA and restore it when `current_branch` is empty.

```bash
local current_branch
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
local current_head
current_head=$(git rev-parse HEAD 2>/dev/null)

# ... do work ...

# Return to original state
if [[ -n "$current_branch" ]]; then
    git checkout -q "$current_branch" 2>/dev/null || true
elif [[ -n "$current_head" ]]; then
    git checkout -q "$current_head" 2>/dev/null || true
fi
```

### 16. PLAN.md Doesn't Match Implementation

**Issue:** PLAN.md says "verify squash commit messages include patch name" but implementation uses `git commit --no-edit` which doesn't include patch name.

**Location:** `PLAN.md` line 75

**Fix:** Update PLAN.md to reflect current behavior.

## Summary

Priority order for fixes:

1. **Critical (breaks functionality):**
   - #4: Stale tmp refs (corrupts remote state)
   - #5: Empty patches in integration (causes errors)
   - #6, #7: Notes before atomic transaction (breaks atomicity)
   - #10: Failed integration patches still updated (wrong behavior)

2. **Important (security/robustness):**
   - #1: Unbound variable error (crashes on edge case)
   - #2: Missing force-with-lease for new refs (weakens concurrency)
   - #3: Insecure temp file (security risk)

3. **Nice to have (code quality):**
   - #8: Missing notes for deleted patches (incomplete metadata)
   - #9: Verify patches still discoverable (might be OK by design)
   - #11: Test topology check unclear (test quality)
   - #12: Use `[[ ]]` in tests (style consistency)
   - #13: Update test comments (documentation)
   - #15: Detached HEAD handling (edge case)
   - #16: Update PLAN.md (documentation)

## Implementation Plan

1. Clean up stale tmp refs at start of sync (#4)
2. Delete tmp ref for empty patches (#5)
3. Defer note writes until after atomic ref updates (#6, #7, #8)
4. Only update refs for actually-integrated patches (#10)
5. Fix force-with-lease for new refs (#2)
6. Use mktemp for ref-state file (#3)
7. Fix unbound variable error (#1)
8. Update test assertions to use `[[ ]]` (#12)
9. Fix test comments (#13, #16)
10. Add detached HEAD handling (#15)
11. Verify or document patch discoverability (#9, #11)
