# Patchstack Tutorial: Managing a Patch Stack

This tutorial demonstrates how to use patchstack to maintain a fork as a patch stack on top of an upstream repository.

## What is Patchstack?

Patchstack maintains long-living forks as deterministic patch stacks. It automatically rebases your patches onto upstream changes, integrates them, and handles conflicts gracefully.

## Tutorial Scenario

This tutorial walks through a complete patch stack lifecycle, demonstrating:
- Creating multiple patch branches
- Upstream evolution and syncing
- Empty patch detection (when upstream accepts your changes)
- Conflict detection and handling
- Independent patch processing

## Prerequisites

- Git repository with `origin` (your fork) and `upstream` remotes configured
- Patchstack installed (`scripts/patchstack` in your PATH)

## Step-by-Step Walkthrough

The following walkthrough is extracted from our integration test that validates these scenarios.

---

*Note: This tutorial is automatically generated from `tests/test-31-tutorial-evolution.sh`. To see the full test output with Git commands and results, run:*

```bash
./tests/test-31-tutorial-evolution.sh
```

Or to regenerate the live output document:

```bash
./docs/extract-tutorial.sh > docs/tutorial-output.md
```

---

## Summary

This tutorial demonstrated:

✓ **Clean rebases happen automatically** - When upstream evolves, patchstack rebases all your patches onto the new base

✓ **Empty patches are detected and deleted** - When upstream accepts your changes, patchstack automatically removes the redundant patch

✓ **Conflicts are detected and reported** - When patches conflict with upstream, patchstack reports them clearly and leaves them unchanged for manual resolution

✓ **Failed patches remain unchanged for manual fix** - You maintain full control over conflict resolution

✓ **Each patch is processed independently** - One failing patch doesn't affect others

## Next Steps

- Learn about dry-run mode: `patchstack sync --dry-run` (coming in Phase 1.7)
- Check patch status: `patchstack status` (coming in Phase 1.7)
- List your patches: `patchstack list`

## Additional Resources

- [Implementation Plan](../PLAN.md) - Full development roadmap
- [Design Guide](../GUIDE.md) - Architecture and design decisions
- [Test Suite](../tests/) - Comprehensive test coverage
