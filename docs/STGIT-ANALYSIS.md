# StGit as Backend: Analysis and Comparison

This document analyzes how StGit (Stacked Git) can be used to implement the patchstack workflow, either as a backend or as a direct replacement.

## What is StGit?

StGit is a tool that maintains a stack of patches on top of a Git branch. It provides commands to:

- Manage patches (create, delete, rename, reorder)
- Rebase patches onto new base commits
- Push/pop patches from the stack
- Detect when patches are merged upstream

## Workflow Comparison

### Patchstack Workflow

Patchstack maintains a long-living fork where:

1. Each patch is a **separate branch** (e.g., `origin/a`, `origin/b`)
2. The fork's `main` is a **squashed integration** of all patches
3. Syncing rebases all patches onto `upstream/main` and rebuilds `main`
4. Empty patches (merged upstream) are automatically deleted

### StGit Workflow

StGit maintains patches as:

1. A **single branch** with a **stack of patches** on top
2. Patches are stored as metadata (refs/patches/\<branch\>/\*)
3. Rebasing is done with `stg rebase` or `stg pull`
4. Merged patches detected with `--merged` flag

## Key Differences

| Feature | Patchstack | StGit |
|---------|------------|-------|
| Patch storage | Separate branches | Single branch, patch metadata |
| Branch structure | Multiple parallel branches | Linear stack on one branch |
| Collaboration | Each patch can be worked on independently | All patches on one branch |
| Merge detection | Compares rebased tree to upstream | Uses `--merged` flag |
| Integration | Squash commits from each patch branch | Patches directly on branch |
| Remote structure | Multiple branches pushed to origin | One branch with optional public branch |

## Mapping Patchstack to StGit

### Core Challenge

**StGit uses a fundamentally different model**: a linear stack on a single branch, while patchstack uses multiple independent branches. This has significant implications:

1. **StGit patches cannot exist independently** - they form an ordered stack
2. **Patchstack patches can be worked on in parallel** - each is its own branch
3. **StGit requires specific ordering** - earlier patches must apply first
4. **Patchstack integrates in lexicographic order** - but patches themselves are independent

### Possible Mapping Strategies

#### Strategy A: Use StGit's Native Model

Abandon the multi-branch model and use StGit directly:

```bash
# Initialize StGit on the fork
cd fork
stg init

# Create patches (instead of branches)
stg new patch-a -m "Add a.txt"
touch a.txt && git add a.txt
stg refresh

stg new patch-b -m "Add b.txt"
touch b.txt && git add b.txt
stg refresh

# Sync with upstream
stg rebase upstream/main --merged

# Publish to remote
git push origin main --force
```

**Pros:**
- Simpler - single branch model
- StGit handles all the hard rebase work
- Built-in merge detection

**Cons:**
- Cannot work on patches independently in parallel
- Patch ordering is fixed (no independent branches)
- Collaborators cannot easily work on specific patches
- Loses the multi-branch flexibility

#### Strategy B: Use StGit as Backend for Patchstack

Keep the multi-branch model but use StGit for the rebase/integration phase:

```bash
# For each patch branch, temporarily convert to StGit
for branch in patch_branches; do
    git checkout $branch
    stg init
    stg uncommit --to upstream/main
    stg rebase upstream/main
    stg commit --all  # Convert back to regular commits
done
```

**Pros:**
- Keeps the multi-branch model
- Uses StGit's robust rebase logic

**Cons:**
- Complexity of converting to/from StGit format
- StGit metadata management overhead
- Not how StGit is designed to be used

#### Strategy C: Direct Comparison (Demo)

The demo script below shows how the trivial example can be implemented using StGit commands, demonstrating the workflow differences.

## Conclusion and Recommendation

### StGit is NOT a suitable backend for patchstack

The fundamental model difference makes StGit unsuitable as a backend:

1. **Different branching philosophy**: StGit assumes one stack per branch; patchstack uses multiple branches
2. **Different collaboration model**: StGit is designed for single-developer patch stack management
3. **Different publication model**: StGit's `publish` command creates merge-friendly branches, but doesn't map to patchstack's per-patch branch model

### StGit CAN replace patchstack for some use cases

If the use case can accept:

- All patches in a linear stack on one branch
- No parallel development on different patches
- Single-developer workflow

Then StGit is a simpler, more mature tool that handles:

- Rebase onto new upstream
- Merge detection
- Patch reordering

### When to use which tool

| Use Case | Recommended Tool |
|----------|------------------|
| Single developer, local patch stack | StGit |
| Multiple developers working on patches | Patchstack |
| Patches need independent branches for CI | Patchstack |
| Simple linear patch development | StGit |
| Automatic fork synchronization | Patchstack |
| GitHub Actions integration | Patchstack |

## Demo Script

See `docs/stgit-demo.sh` for a self-contained script that demonstrates the trivial example from the issue using StGit and git commands instead of patchstack.

## References

- [StGit Documentation](https://stacked-git.github.io/)
- [Patchstack GUIDE.md](../GUIDE.md)
- [StGit Man Pages](https://stacked-git.github.io/man/)
