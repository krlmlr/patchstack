# Implementation Plan: Patchstack

**Principles:**

- Zero-config: Use sensible Git defaults (origin, upstream, main)
- Test-first: Every change comes with tests using local throwaway repos
- Minimal scope: Only automate what's hard to do manually with Git
- Clean state: Assume fetched state; no fetching, no destructive operations

## Milestone 1: Functioning Script with Tests

### Phase 1.1: Test Harness + Branch Discovery

**Build:**

- [x] Create `tests/harness.sh` - helpers for local Git repo setup
    - `setup_test_env()` - create throwaway repos (upstream, fork)
    - `create_patch_branch()` - helper to create patch branches
    - `assert_snapshot()` - snapshot testing
    - `assert_*()` - test assertions
- [x] Create `scripts/patchstack` minimal script scaffold
- [x] Implement branch discovery logic (hard part: ancestry + lexicographic sort)
    - List all `refs/remotes/origin/*`
    - Filter descendants of origin/main at sync start
    - Sort lexicographically by branch name

**Test:**

- [x] Test: discovery with no patch branches returns empty
- [x] Test: discovery with 3 patches returns sorted list
- [x] Test: discovery excludes non-descendants
- [x] Test: discovery excludes origin/main

**Detailed Plan:** See [plan/110-test-harness-and-discovery.md](plan/110-test-harness-and-discovery.md)

### Phase 1.2: Replay Patch Commits

**Build:**

- [x] Implement commit replay logic for patch branches
    - List commits between origin/main and patch branch
    - Replay each commit onto upstream/main using cherry-pick
    - Squash merge commits into single commits
    - Store result in temporary local ref
- [x] Detect and handle replay conflicts (leave unresolved, mark failed)
- [x] Detect empty patches (replayed tree equals upstream tree)

**Test:**

- [x] Test: clean replay of patch-A with 2 commits
- [x] Test: replay conflict stops and marks branch failed
- [x] Test: empty patch (already merged upstream) detected
- [x] Test: merge commits are squashed during replay
- [x] Test: multiple patches replay independently

**Detailed Plan:** See [plan/120-rebase-single-patch.md](plan/120-rebase-single-patch.md)

### Phase 1.3: Squash Integration

**Build:**

- [x] Implement sequential squash integration (hardest Git operation)
    - Start from upstream/main
    - For each viable patch in order:
        - Create squash commit of all patch changes
        - Try to apply onto integration branch
    - Build final `refs/patchstack/tmp/main` reference
- [x] Detect integration conflicts (patch rebases but conflicts during squash)
- [x] Gate logic: only viable patches contribute to main

**Test:**

- [x] Test: squash 3 clean patches into new main
- [x] Test: integration conflict excludes patch-B, includes A and C
- [x] Test: verify squash commit messages include patch name
- [x] Test: empty patches excluded from integration
- [x] Test: multiple integration failures handled correctly

**Detailed Plan:** See [plan/130-squash-integration.md](plan/130-squash-integration.md)

### Phase 1.4: Atomic Update (Ref Updates Only)

**Build:**

- [x] Implement local ref updates (no push yet)
    - Update refs/remotes/origin/main to new main
    - Update refs/remotes/origin/* for viable patches
    - Delete refs for empty patches
- [x] Record metadata in refs/notes/patchstack
    - Branch name, old SHA, new SHA, status, timestamp
- [x] Patches remain based on upstream (not rebased onto integrated main)

**Test:**

- [x] Test: successful sync updates all local remote refs
- [x] Test: failed patch keeps old ref unchanged
- [x] Test: empty patch ref deleted
- [x] Test: notes created for all processed branches
- [x] Test: verify ref state matches expected topology

**Detailed Plan:** See [plan/140-atomic-update.md](plan/140-atomic-update.md)

**Status:** ✓ Complete

### Phase 1.5: Atomic Push

**Build:**

- [x] Implement atomic push with multiple refspecs
    - Push main with force-with-lease
    - Push all viable patch branches with force-with-lease
    - Push deletions for empty branches
    - Push notes
- [x] Use `git push --atomic --force-with-lease` for all-or-nothing
- [x] Handle push rejection (concurrent update) gracefully

**Test:**

- [x] Test: atomic push succeeds with all refs updated together
- [x] Test: atomic push with lease failure aborts all updates
- [x] Test: verify remote state after successful push
- [x] Test: verify notes pushed to remote

**Detailed Plan:** See [plan/150-atomic-push.md](plan/150-atomic-push.md)

**Status:** ✓ Complete

### Phase 1.6: End-to-End Scenarios

**Build:**

- [x] Wire all phases together into `patchstack sync` command
- [x] Add comprehensive status reporting and summaries
- [x] Keep operation idempotent (safe to re-run)
- [x] Address all PR review feedback from phases 1.3, 1.4, and 1.5

**Test:**

- [x] All existing tests updated to use bare remotes (30/30 passing)
- [x] Test Scenario A-E: Covered by existing tests (14-18, 21-23, 24-30)
- [x] Test Scenario F: Idempotency verified via test-24+

**Detailed Plan:** See [plan/160-end-to-end-scenarios.md](plan/160-end-to-end-scenarios.md) and [plan/161-pr-review-feedback.md](plan/161-pr-review-feedback.md)

**Status:** ✓ Complete

### Phase 1.7: Dry-Run and Status

**Build:**

- [x] Add `--dry-run` flag (perform all checks, no ref updates)
- [x] Add `status` subcommand (show patch stack state)
- [x] Add `--verbose` flag for detailed logging
- [x] Enhance `list` command with verbose mode

**Test:**

- [x] Test: dry-run shows planned changes without making them
- [x] Test: status shows current patch branches and integration state
- [x] Test: status detects when sync is needed
- [x] Test: verbose list shows commit counts and SHAs

**Detailed Plan:** See [plan/170-dry-run-and-status.md](plan/170-dry-run-and-status.md)

**Status:** ✓ Complete

### Phase 1.8: Error Recovery

**Build:**

- [ ] Pre-flight checks (working tree, HEAD, remotes, refs)
- [ ] Handle dirty working tree (detect, advise user)
- [ ] Handle detached HEAD gracefully
- [ ] Handle missing upstream/main or origin/main
- [ ] Cleanup temporary refs on failure (trap on exit)
- [ ] Safe rollback on ref update failures
- [ ] Context-aware error messages with guidance

**Test:**

- [ ] Test: dirty working tree prevents sync
- [ ] Test: detached HEAD prevents sync
- [ ] Test: missing upstream remote gives clear error
- [ ] Test: missing origin/main gives clear error
- [ ] Test: temporary refs cleaned up after failure

**Detailed Plan:** See [plan/180-error-recovery.md](plan/180-error-recovery.md)

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
