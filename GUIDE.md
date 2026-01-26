# Patchstack Fork Maintenance: Design & Implementation Guide

This document specifies a Git-based mechanism to maintain a long-living fork as a patch stack on top of an upstream repository using:

- **one standalone shell script** (`scripts/patchstack`)
- a **GitHub Actions workflow** that only invokes the script

It is designed for forks where:

- each patch is represented by a **remote branch** (e.g. `origin/patch-*`)
- the fork’s `main` is a **squashed integration** of all *working* patch branches, applied in **lexicographic order**
- **every sync rewrites (rebases) and force-pushes all patch branches and `main`**
- branches that become **effectively empty** are deleted
- history of feature branch tips is tracked via **Git notes** (or an auxiliary ref index)

The design assumes GitHub-hosted repos, but is general Git.

---

## Goals

1. Keep fork `main` equal to:

   `upstream/main` + squash(patch branches in lexicographic order)

2. On upstream changes:
   - **rebase** every eligible patch branch on top of the new upstream
   - rebuild `main` from upstream + squashed patch branches
   - **force-push all updates at the end** (preferably atomically)

3. Robustness:
   - detect and isolate failures per branch
   - avoid pushing branch rewrites that cannot be integrated
   - prevent race-condition overwrites using **leases** and **concurrency**

4. Hygiene:
   - if a patch becomes empty, delete its branch after a successful run
   - keep an auditable record of processed tips and outcomes via **notes**

---

## Terminology

- **PATCH_REMOTE**: remote containing patch branches, typically `origin`
- **UPSTREAM_REMOTE**: remote pointing to upstream repo, e.g. `upstream`
- **MAIN_BRANCH**: main integration branch, default `main`
- **UPSTREAM_BRANCH**: upstream mainline, default `main`

Patch branches:

- all `refs/remotes/$PATCH_REMOTE/*`
- excluding `$PATCH_REMOTE/$MAIN_BRANCH`
- **descendant of fork main at run start**
- sorted **lexicographically**

---

## Core Invariants

After a successful sync (push completed):

### I1. Main determinism

`origin/main` equals exactly:

- `UP_SHA` (fetched `upstream/main`)
- followed by squash commits for each included patch branch in lexicographic order

### I2. Patch branch consistency

Every patch branch updated by the sync:

- is rebased onto `UP_SHA`
- **can be squashed cleanly** into `main` in the defined order

> A rebased patch branch that cannot be integrated MUST NOT be published.

### I3. No partial publication

Updates to:

- `main`
- patch branches
- notes
- branch deletions
are published in **one atomic push**.
If any ref update is rejected, **nothing is updated**.

### I4. Empty patch traceability

Deleted empty patch branches have their final tips and disposition recorded in `refs/notes/patchstack`.

### I5. Squash commit traceability

Every squash commit on `origin/main` includes a `Patchstack-Patch:` trailer identifying its source patch branch. This enables:

- Detection of alien commits (commits without traceable origin)
- Machine-readable provenance for auditing
- Migration and recovery workflows

---

## Git Notes for History Tracking

Notes namespace:

```
refs/notes/patchstack
```

Each processed patch branch tip commit receives a note with:

- branch name
- original tip SHA
- rebased tip SHA (if any)
- status (`included`, `rebase-failed`, `integrate-failed`, `empty-deleted`, …)
- upstream SHA
- timestamp / run ID

Notes are pushed as part of the atomic publication step.

---

## ASCII Commit Graph Conventions

- `U0, U1, U2...` upstream commits
- `A1, A2...` patch commits
- `A1'` rebased commit
- `SA` squash commit for patch-A
- diagrams are simplified linear projections

---

## Baseline State (three patches)

Upstream:

```
upstream/main:
U0 --- U1 --- U2
```

Fork:

```
origin/main:
U0 --- U1 --- U2 --- SA --- SB --- SC
```

Patch branches (descendants of fork main):

```
origin/patch-A:
U0 --- U1 --- U2 --- SA --- SB --- SC --- A1 --- A2

origin/patch-B:
U0 --- U1 --- U2 --- SA --- SB --- SC --- B1

origin/patch-C:
U0 --- U1 --- U2 --- SA --- SB --- SC --- C1 --- C2
```

---

## Sync Overview (Two-Phase, Single Publication)

### Phase 1: Compute (no remote writes)

- fetch remotes
- discover eligible patch branches
- rebase patches locally onto `upstream/main`
- attempt local squash integration in lexicographic order
- decide final outcomes per branch

### Phase 2: Publish (single atomic push)

- update `main`
- update only **integratable** rebased patch branches
- delete empty branches
- push notes

This preserves invariant **I2**.

---

## Scenario A: Upstream updated, no conflicts

Upstream:

```
U0 --- U1 --- U2 --- U3
```

After sync:

```
origin/patch-A:
U0 --- U1 --- U2 --- U3 --- A1' --- A2'

origin/patch-B:
U0 --- U1 --- U2 --- U3 --- B1'

origin/patch-C:
U0 --- U1 --- U2 --- U3 --- C1' --- C2'

origin/main:
U0 --- U1 --- U2 --- U3 --- SA' --- SB' --- SC'
```

---

## Scenario B: Rebase conflict (patch-B)

```
origin/patch-B:
U0 --- U1 --- U2 --- SA --- SB --- SC --- B1
```

After sync:

```
origin/patch-A:
U0 --- U1 --- U2 --- U3 --- A1' --- A2'

origin/patch-B:
(unchanged)

origin/patch-C:
U0 --- U1 --- U2 --- U3 --- C1' --- C2'

origin/main:
U0 --- U1 --- U2 --- U3 --- SA' -------- SC'
```

---

## Scenario C: Integration conflict (ordering overlap)

Patch-B rebases cleanly but conflicts when squashed after patch-A.

**Key rule:**
Patch-B MUST NOT be published rebased.

After sync:

```
origin/patch-A:
U0 --- U1 --- U2 --- U3 --- A1' --- A2'

origin/patch-B:
(unchanged)

origin/patch-C:
U0 --- U1 --- U2 --- U3 --- C1' --- C2'

origin/main:
U0 --- U1 --- U2 --- U3 --- SA' -------- SC'
```

Invariant I2 preserved.

---

## Scenario D: Patch merged upstream → empty → deleted

```
origin/patch-C:
(deleted)
```

```
origin/main:
U0 --- U1 --- U2 --- U3 --- SA' --- SB'
```

Notes record old tip and deletion reason.

---

## Algorithm Summary (`patchstack sync`)

1. Fetch remotes
2. Record immutable inputs:
   - `UP_SHA`
   - `MAIN_BEFORE`
   - `P_SHA[p]` for each patch
3. Discover eligible patch branches
4. Rebase patches locally (`--onto UP_SHA MAIN_BEFORE`)
5. Build `tmp/main` via squash integration
6. Gate which rebased branches may be published
7. Record notes
8. Atomic push:
   - update `main`
   - update allowed patch branches
   - delete empty branches
   - push notes

---

## Alien Commit Handling

### Definition

An **alien commit** is any commit on `origin/main` that cannot be traced to:

1. The current `upstream/main` history
2. A squash commit from a known patch branch (identified via `Patchstack-Patch:` trailer)
3. A commit recorded in `refs/notes/patchstack` as originating from a prior sync

### Safety Principle

Patchstack **never silently discards commits**. When alien commits exist:

- **Default behavior:** Abort sync with clear error message
- **With `--delete`:** Proceed and remove aliens (user explicitly acknowledges loss)
- **With `--dry-run --delete`:** Preview what would be removed

### Commit Traceability

Following conventions from Quilt and StGit, each squash commit includes a machine-readable trailer:

```
Squash of 3 commits from origin/patch-feature

<original commit messages>

---
Patchstack-Patch: patch-feature
```

This trailer:

- Survives rebases and cherry-picks (unlike notes)
- Is human-readable and grep-able
- Follows Git trailer conventions
- Enables automatic detection of patch provenance

### Recovery Workflow

When alien commits are detected:

1. **Review:** `patchstack history` shows provenance of all commits
2. **Backport:** `patchstack backport` converts aliens to proper patch branches
3. **Sync:** Normal sync proceeds without data loss

---

## Failure Modes & Handling

| Failure              | Effect               | Action                               |
|----------------------|----------------------|--------------------------------------|
| Fetch/auth failure   | No state known       | Abort early                          |
| Rebase conflict      | Patch invalid        | Keep branch unchanged                |
| Integration conflict | Patch inconsistent   | **Do not publish rebased branch**    |
| Empty patch          | No net effect        | Delete or keep per policy            |
| Lease failure        | Concurrent update    | Atomic push aborts                   |
| No atomic support    | Unsafe               | Treat as fatal                       |
| Alien commits found  | Untracked changes    | Abort unless `--delete` specified    |

---

## GitHub Actions (simplified)

```yaml
name: Patchstack sync

on:
  workflow_dispatch:
  schedule:
    - cron: "17 3 * * *"

concurrency:
  group: patchstack-sync
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - run: |
          git config user.name "patchstack-bot"
          git config user.email "patchstack-bot@users.noreply.github.com"

      - run: |
          git remote add upstream https://github.com/OWNER/UPSTREAM.git || true
          git fetch --prune upstream main
          git fetch --prune origin

      - run: |
          bash scripts/patchstack sync
```

---

## Summary

This design ensures:

- deterministic fork `main`
- rebased patch branches are only published if integratable
- conflicts isolate individual patches
- empty patches are cleaned up safely
- race conditions are handled via concurrency + atomic + leases
- full auditability via Git notes
- **alien commits are never silently discarded** (abort unless `--delete`)
- **commit provenance is traceable** via `Patchstack-Patch:` trailers

This document can be used directly as an implementation guide for `scripts/patchstack`.
