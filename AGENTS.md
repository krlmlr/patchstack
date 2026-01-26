# Guidelines for AI Agents Working on Patchstack

## Project Overview

Patchstack is a Git automation tool that maintains long-living forks as deterministic patch stacks on top of upstream repositories. The core challenge is performing complex Git operations (rebase, squash integration, atomic updates) that are tedious or error-prone when done manually.

## Core Principles

### 1. Zero Configuration

- Use sensible Git defaults everywhere: `origin`, `upstream`, `main`
- No config files, no environment variables (initially)
- The tool should "just work" in a standard Git fork setup
- Configuration options can be added later if proven necessary

### 2. Test-First Development

- **Every feature must have tests before implementation**
- Tests use local throwaway Git repositories only
- Tests must be fast (<10 seconds for full suite)
- Clean setup and teardown for each test
- Tests should verify both success and failure cases

### 3. Minimal Scope

- Only automate what is genuinely hard to do with Git directly
- Do NOT implement features Git already provides well (fetching, basic branching)
- Assume clean state or state that can be safely reached
- No destructive operations without clear user intent

### 4. Clean State Assumptions

- Assume repositories have been fetched (`git fetch`)
- Assume working tree is clean
- Detect and advise on problematic states rather than trying to fix them
- Operations should be safe to re-run (idempotent)

## Implementation Strategy

### Phase Structure

Each phase follows this pattern:

1. **Build:** Implement the minimal feature
2. **Test:** Write comprehensive tests immediately
3. **Verify:** Run tests before moving to next phase

### Test Harness Requirements

- Create isolated Git repositories for each test
- Use real Git operations, not mocks
- Test repositories should be in `/tmp` or similar
- Clean up after each test
- Provide helpers for common operations:
    - `setup_test_env()` - create upstream and fork repos
    - `create_patch_branch()` - add test patch branches
    - `assert_*()` - various assertions

### Git Operations to Master

**Easy (Git handles these well):**

- Fetching remotes
- Basic branching
- Viewing history
- Creating commits

**Hard (what patchstack automates):**

- Finding all patch branches that are descendants of a specific commit
- Replaying commits from multiple branches with conflict isolation
- Squashing merge commits during replay for deterministic history
- Squash integration of multiple patches in order
- Detecting integration conflicts vs replay conflicts
- Atomic updates of multiple refs with force-with-lease
- Handling force-pushed upstream without ancestry assumptions

## Code Style

### Shell Script Guidelines

- Use bash with `set -euo pipefail`
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for tests, not `[ ]`
- Clear error messages with context
- Functions should do one thing
- Keep functions small (<50 lines)
- Obey all shellcheck warnings, introduce `shellcheck source` annotations, use shellcheck ignore annotations only in exceptional cases

### Test Style

```bash
test_feature_name() {
    # Setup
    local upstream=$(setup_test_env)

    # Execute
    run_patchstack sync

    # Assert
    assert_equal "expected" "$(git rev-parse origin/main)"

    # Cleanup happens automatically
}
```

## Git Concepts Critical to This Project

### Remote Tracking Branches

- `refs/remotes/origin/main` - what origin's main was at last fetch
- `refs/remotes/origin/patch-A` - what origin's patch-A was at last fetch
- These are read-only from user's perspective
- Patchstack updates these locally, then pushes to update remote

### Ancestry and Merge-Base

- `git merge-base A B` - common ancestor of A and B
- Patch branches must be descendants of fork main at sync start
- This ensures patches are "on top of" the integrated state

### Squash Commits

- Collapse all commits in a range into one commit
- Preserves changes, loses individual commit history
- Command: `git merge --squash` or manual tree manipulation

### Atomic Push

- `git push --atomic` - all ref updates succeed or all fail
- Critical for maintaining consistency
- Combined with `--force-with-lease` for safety

### Git Notes

- Stored in `refs/notes/patchstack`
- Metadata attached to commits
- Used to track sync history and decisions

## Common Pitfalls to Avoid

### 1. Over-Engineering

- Don't add features "because we might need them"
- Don't create abstraction layers prematurely
- Start with the simplest thing that could possibly work

### 2. Skipping Tests

- Never implement without corresponding tests
- Tests catch edge cases you won't think of
- Tests document expected behavior

### 3. Assuming User Environment

- Don't assume specific Git version beyond 2.30+
- Don't assume specific shell beyond bash 4.0+
- Don't assume specific OS features

### 4. Complex Error Recovery

- Better to fail safely with a clear message
- Don't try to auto-fix complex problems
- User should always be able to recover manually

### 5. Ignoring Git's Complexity

- Git's data model is subtle
- Read git documentation carefully
- Test edge cases (empty commits, merge commits, etc.)

## Development Workflow

### Starting a New Phase

1. Read the phase specification in PLAN.md
2. **Verify the phase is truly incomplete** by checking:
   - Functions are implemented in scripts/patchstack
   - Tests exist and pass
   - Never trust "Status: ✓ Complete" in plan docs without verification
3. Read the detailed plan in `plan/[phase-number]-*.md`
4. Create test harness helpers if needed
5. Write tests for the feature (they should fail)
6. Implement the feature
7. Verify tests pass
8. Test edge cases
9. Update PLAN.md with checkboxes marking completion
10. Move to next phase

### When Stuck

1. Consult GUIDE.md for design intent
2. Test your assumptions with a manual Git experiment
3. Simplify the problem
4. Write a simpler test that isolates the issue

### Before Committing

1. Run `make check` to verify all linting and tests pass
2. Code follows style guidelines
3. Comments explain "why" not "what"
4. Error messages are clear and actionable

### Before Requesting Review

**ALWAYS run `make check` before requesting a code review.** This runs:
- `make lint` - shellcheck on all bash scripts
- `make test` - full test suite

This ensures code quality and prevents CI failures.

## Testing Philosophy

### Snapshot Testing

Patchstack uses **snapshot testing** for all CLI commands:

- Each test runs the actual `patchstack` command in an isolated environment
- Output is compared against committed snapshot files in `tests/snapshots/`
- Nondeterministic output (SHAs, timestamps, temp paths) is scrubbed before comparison
- Snapshots are versioned in Git, making it easy to review output changes

**Benefits:**

- Tests verify the actual user-facing behavior
- Easy to review what changed when tests fail
- Forces us to think about output format and clarity
- Snapshots serve as documentation of expected behavior

**Workflow:**

1. Write a test that runs a patchstack command
2. Run the test to generate initial snapshot
3. Commit the snapshot file to Git
4. Future test runs compare output to the snapshot
5. If output changes, review the diff and update snapshot if intended

### Test Structure

Each test is a standalone bash script:

- **Setup:** Create test repositories with specific conditions
- **Execute:** Run `patchstack` command
- **Assert:** Compare output to snapshot using `assert_snapshot`
- **Cleanup:** Remove temporary test directories

Tests should be numbered sequentially (test-01-*, test-02-*, etc.) for predictable execution order when needed.

### What to Test

- Happy path (everything works)
- Rebase conflicts
- Integration conflicts
- Empty patches
- Missing references
- Concurrent updates (lease failures)
- Edge cases (no patches, all patches fail, etc.)

### What Not to Test

- Git's internal operations (assume Git works)
- Network operations (use local repos)
- User's environment setup (assume reasonable setup)

### Test Independence

- Each test creates its own isolated Git repositories
- Tests don't depend on execution order (except when explicitly numbered)
- Tests clean up after themselves
- Tests should be runnable individually

### Updating Snapshots

When output format changes intentionally:

```bash
# Update all snapshots with --apply flag
./tests/run-all-tests.sh --apply

# Or update a specific snapshot
SNAPSHOT_UPDATE=1 ./tests/test-01-no-patches.sh

# Review and commit the updated snapshots
git diff tests/snapshots/
git add tests/snapshots/
git commit -m "Update snapshots for new output format"
```

When a snapshot test fails, the diff is shown as a unified patch:

```
✗ Snapshot mismatch: 04-excludes-main

--- /path/to/tests/snapshots/04-excludes-main.snap
+++ actual output
@@ -1 +1,3 @@
-wrong content
+patch-test
+
+Found 1 patch branches

To update snapshot: run with --apply flag
```

## Communication with Users

### Error Messages Should

- Be specific about what went wrong
- Explain what state the repo is in
- Suggest how to fix or investigate
- Never leave repo in broken state

### Good Error Message

```text
Error: patch-feature-auth failed to rebase onto upstream/main
Conflict in: src/auth.c
The branch has been left unchanged at: a1b2c3d
To resolve: manually rebase patch-feature-auth and re-run sync
```

### Bad Error Message

```text
Error: rebase failed
```

## File Organization

```text
patchstack/
├── GUIDE.md           # Design specification (reference)
├── PLAN.md            # High-level implementation plan
├── AGENTS.md          # This file - agent guidelines
├── README.md          # User documentation
├── plan/
│   ├── 110-*.md      # Detailed plan for phase 1.1
│   ├── 120-*.md      # Detailed plan for phase 1.2
│   └── ...           # One detailed plan per phase
├── scripts/
│   └── patchstack    # Main script (bash)
└── tests/
    ├── test-harness.sh        # Test infrastructure
    ├── test-discovery.sh      # Tests for phase 1.1
    ├── test-rebase.sh         # Tests for phase 1.2
    └── run-all-tests.sh       # Test runner
```

## Key Decision Points

### When to Add Configuration

Wait until multiple users request the same override. Start with hardcoded sensible defaults.

### When to Add Features

Only when solving a real problem that Git can't handle well. Resist feature creep.

### When to Refactor

When you need to copy-paste code. Not before.

### When to Optimize

When tests become slow (>10s). Not before.

## Success Metrics

### Phase Complete When

- All planned features implemented
- All tests pass
- Tests run fast
- Code is readable
- Error messages are clear
- Edge cases handled

### Milestone Complete When

- All phases in milestone complete
- End-to-end scenarios work
- Documentation updated
- Ready for real-world use

## Remember

This is a Git automation tool. The complexity is in Git's data model and operations, not in our code. Keep the code simple. Let Git do the heavy lifting. Our job is to orchestrate Git operations in a way that's hard to do manually.

When in doubt:

1. Test it manually with Git first
2. Write a test
3. Make the test pass
4. Move on

## Implementation History

### Phase 1.2 - Replay Patch Commits (January 2026)

**Issue Found:** The plan document marked Phase 1.2 as "Complete" but the implementation was missing:

- `replay_patch_commits()` function was not implemented
- `replay_all_patches()` function was missing
- `cmd_sync()` was a placeholder
- No tests existed (test-08 through test-13)

**Implemented:**

- Added `replay_patch_commits()` with proper conflict and empty patch detection
- Added `replay_all_patches()` to process all patches independently
- Updated `cmd_sync()` to discover and replay patches
- Created 6 comprehensive tests covering:
    - Clean replay (test-08)
    - Conflict detection (test-09)
    - Empty patch detection (test-10)
    - Merge commit squashing (test-11)
    - Multiple independent patches (test-12)
    - No new commits (test-13)

**Key Implementation Details:**

- Empty patches detected by checking if cherry-pick fails with clean working tree
- Merge commits replayed by creating new commit with merge's tree (not re-merging)
- Each patch processed independently - one failure doesn't affect others
- Temporary refs stored in `refs/patchstack/tmp/*`

**Lesson:** Always verify phase completion by checking for actual implementation and passing tests, not just status markers in plan documents.
