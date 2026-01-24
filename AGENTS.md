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
- Obey all shellcheck warnings, use shellcheck annotations only in exceptional cases

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
2. Read the detailed plan in `plan/[phase-number]-*.md`
3. Create test harness helpers if needed
4. Write tests for the feature (they should fail)
5. Implement the feature
6. Verify tests pass
7. Test edge cases
8. Move to next phase

### When Stuck

1. Consult GUIDE.md for design intent
2. Test your assumptions with a manual Git experiment
3. Simplify the problem
4. Write a simpler test that isolates the issue

### Before Committing

1. All tests pass
2. Code follows style guidelines
3. Comments explain "why" not "what"
4. Error messages are clear and actionable

## Testing Philosophy

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

- Each test creates its own repos
- Tests don't depend on execution order
- Tests clean up after themselves
- Tests should be runnable individually

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
