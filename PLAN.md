# Implementation Plan: Patchstack

**Principles:**

- Zero-config: Use sensible Git defaults (origin, upstream, main)
- Test-first: Every change comes with tests using local throwaway repos
- Minimal scope: Only automate what's hard to do manually with Git
- Clean state: Assume fetched state; no fetching, no destructive operations

## Milestone 1: Functioning Script with Tests

### Phase 1.1: Test Harness + Branch Discovery

**Build:**

- [ ] Create `tests/test-harness.sh` - helpers for local Git repo setup
    - `setup_test_env()` - create throwaway repos (upstream, fork)
    - `create_patch_branch()` - helper to create patch branches
    - `assert_*()` - test assertions
- [ ] Create `scripts/patchstack` minimal script scaffold
- [ ] Implement branch discovery logic (hard part: ancestry + lexicographic sort)
    - List all `refs/remotes/origin/*`
    - Filter descendants of origin/main at sync start
    - Sort lexicographically by branch name

**Test:**

- [ ] Test: discovery with no patch branches returns empty
- [ ] Test: discovery with 3 patches returns sorted list
- [ ] Test: discovery excludes non-descendants
- [ ] Test: discovery excludes origin/main

### Phase 1.2: Replay Patch Commits

**Build:**

- [ ] Implement commit replay logic for patch branches
    - List commits between origin/main and patch branch
    - Replay each commit onto upstream/main using cherry-pick
    - Squash merge commits into single commits
    - Store result in temporary local ref
- [ ] Detect and handle replay conflicts (leave unresolved, mark failed)
- [ ] Detect empty patches (replayed tree equals upstream tree)

**Test:**

- [ ] Test: clean replay of patch-A with 2 commits
- [ ] Test: replay conflict stops and marks branch failed
- [ ] Test: empty patch (already merged upstream) detected
- [ ] Test: merge commits are squashed during replay
- [ ] Test: multiple patches replay independently

### Phase 1.3: Squash Integration

**Build:**

- [ ] Implement sequential squash integration (hardest Git operation)
    - Start from upstream/main
    - For each viable patch in order:
        - Create squash commit of all patch changes
        - Try to apply onto integration branch
    - Build final `tmp/patchstack-main` reference
- [ ] Detect integration conflicts (patch rebases but conflicts during squash)
- [ ] Gate logic: only viable patches contribute to main

**Test:**

- [ ] Test: squash 3 clean patches into new main
- [ ] Test: integration conflict excludes patch-B, includes A and C
- [ ] Test: verify squash commit messages include patch name
- [ ] Test: empty patches excluded from integration

### Phase 1.4: Atomic Update (Ref Updates Only)

**Build:**

- [ ] Implement local ref updates (no push yet)
    - Update refs/remotes/origin/main to new main
    - Update refs/remotes/origin/* for viable patches
    - Delete refs for empty patches
- [ ] Record metadata in refs/notes/patchstack
    - Branch name, old SHA, new SHA, status, timestamp

**Test:**

- [ ] Test: successful sync updates all local remote refs
- [ ] Test: failed patch keeps old ref unchanged
- [ ] Test: empty patch ref deleted
- [ ] Test: notes created for all processed branches
- [ ] Test: verify ref state matches expected topology

### Phase 1.5: Atomic Push

**Build:**

- [ ] Implement atomic push with multiple refspecs
    - Push main with force-with-lease
    - Push all viable patch branches with force-with-lease
    - Push deletions for empty branches
    - Push notes
- [ ] Use `git push --atomic --force-with-lease` for all-or-nothing
- [ ] Handle push rejection (concurrent update) gracefully

**Test:**

- [ ] Test: atomic push succeeds with all refs updated together
- [ ] Test: atomic push with lease failure aborts all updates
- [ ] Test: verify remote state after successful push
- [ ] Test: verify notes pushed to remote

### Phase 1.6: End-to-End Scenarios

**Build:**

- [ ] Wire all phases together into `patchstack sync` command
- [ ] Add basic error handling and status reporting
- [ ] Keep operation idempotent (safe to re-run)

**Test:**

- [ ] Test Scenario A: Clean upstream update (all patches viable)
- [ ] Test Scenario B: Rebase conflict (patch-B excluded)
- [ ] Test Scenario C: Integration conflict (patch-B excluded)
- [ ] Test Scenario D: Empty patch (patch-C deleted)
- [ ] Test Scenario E: Multiple failures (only viable patches included)
- [ ] Test: Re-running sync with no changes is no-op

### Phase 1.7: Dry-Run and Status

**Build:**

- [ ] Add `--dry-run` flag (perform all checks, no ref updates)
- [ ] Add `status` subcommand (show patch stack state)
- [ ] Add basic logging/verbosity

**Test:**

- [ ] Test: dry-run shows planned changes without making them
- [ ] Test: status shows current patch branches and integration state

### Phase 1.8: Error Recovery

**Build:**

- [ ] Handle dirty working tree (detect, advise user)
- [ ] Handle detached HEAD gracefully
- [ ] Handle missing upstream/main or origin/main
- [ ] Cleanup temporary refs on failure

**Test:**

- [ ] Test: dirty working tree prevents sync
- [ ] Test: missing upstream remote gives clear error
- [ ] Test: missing origin/main gives clear error
- [ ] Test: temporary refs cleaned up after failure

## Milestone 2: GitHub Action for Reusable Workflows

### Phase 2.1: Minimal Action Wrapper

**Build:**

- [ ] Create `action.yml` with minimal inputs (zero-config defaults)
    - Remote names default to origin/upstream
    - Branch names default to main
- [ ] Create simple action script that:
    - Checks out repo with fetch-depth: 0
    - Configures Git (user.name, user.email from token)
    - Runs `bash scripts/patchstack sync`
- [ ] Handle authentication via GITHUB_TOKEN

**Test:**

- [ ] Test: action runs in test repository
- [ ] Test: action uses default remote/branch names
- [ ] Test: action fails gracefully with helpful message

### Phase 2.2: Workflow Template

**Build:**

- [ ] Create `.github/workflows/patchstack-sync.yml` template
    - workflow_dispatch for manual runs
    - schedule for daily/weekly automation
    - concurrency: group ensures single sync at a time
- [ ] Add workflow summary output (updated branches, conflicts)

**Test:**

- [ ] Test: workflow triggered manually works
- [ ] Test: concurrency prevents parallel syncs
- [ ] Test: workflow summary shows results

### Phase 2.3: Distribution

**Build:**

- [ ] Tag releases (v1.0.0, v1, v1.1.0, etc.)
- [ ] Create action README with usage examples
- [ ] Add action branding (icon, color)

**Test:**

- [ ] Test: action can be used via `uses: org/patchstack@v1`
- [ ] Test: verify in fresh repository

### Phase 2.4: Advanced Features (Optional)

- [ ] Add conflict notification (GitHub Issues, annotations)
- [ ] Support custom remote names (if zero-config proves limiting)
- [ ] Add metrics/telemetry
- [ ] Support for multiple upstreams

## Success Criteria

### Milestone 1 Complete

- ✅ `scripts/patchstack sync` handles all documented scenarios with tests
- ✅ Zero-config: works with sensible defaults (origin, upstream, main)
- ✅ Every feature has corresponding test in local throwaway repos
- ✅ Test suite runs fast (<10s) with clean setup/teardown
- ✅ Script only does the hard Git operations (rebase, squash, atomic push)
- ✅ Clear error messages for common issues
- ✅ Safe to re-run (idempotent)

### Milestone 2 Complete

- ✅ GitHub Action can be imported via `uses:` in any repository
- ✅ Action works with zero configuration
- ✅ Action provides clear feedback on conflicts
- ✅ Workflow template is copy-paste ready
- ✅ At least one real-world fork using the action successfully
