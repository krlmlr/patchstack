# Patchstack

**Maintain long-living Git forks as deterministic patch stacks on top of upstream repositories.**

Patchstack is a Git-based mechanism that rebases and integrates multiple patch branches on top of an upstream repository, ensuring your fork's `main` branch is always a clean, reproducible integration of your patches.

## Overview

Patchstack helps you maintain a fork where:

- Each feature/fix is a **separate patch branch** (e.g., `patch-feature-name`)
- Your fork's `main` is a **squashed integration** of all working patches applied in lexicographic order
- Every sync **rebases all patches** on the latest upstream and **rebuilds main** deterministically
- Patches that fail to rebase or integrate are **automatically isolated** without blocking others
- Empty patches (merged upstream) are **automatically cleaned up**
- All changes are published **atomically** to prevent race conditions

## Features

✅ **Deterministic fork maintenance** - Same inputs always produce the same fork state
✅ **Conflict isolation** - One failing patch doesn't break others
✅ **Atomic updates** - All-or-nothing publication prevents partial states
✅ **Empty patch cleanup** - Automatic detection and removal of merged patches
✅ **Full audit trail** - Git notes track every sync operation
✅ **GitHub Action ready** - Easy integration into CI/CD workflows
✅ **Concurrency safe** - Proper locking and leases prevent conflicts

## Quick Start

### Using the Script Directly

```bash
# Clone your fork
git clone https://github.com/yourusername/yourfork.git
cd yourfork

# Add upstream remote
git remote add upstream https://github.com/original/repo.git

# Download patchstack script
curl -o scripts/patchstack https://raw.githubusercontent.com/yourusername/patchstack/main/scripts/patchstack
chmod +x scripts/patchstack

# Run sync
./scripts/patchstack sync
```

### Using the GitHub Action

Add to `.github/workflows/patchstack-sync.yml`:

```yaml
name: Patchstack Sync

on:
  workflow_dispatch:
  schedule:
    - cron: "0 3 * * *"  # Daily at 3 AM

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

      - uses: yourusername/patchstack@v1
        with:
          upstream_repo: https://github.com/original/repo.git
          upstream_branch: main
```

## How It Works

### 1. Branch Organization

Your fork maintains multiple patch branches alongside the main branch:

```
upstream/main:     U0 --- U1 --- U2
fork/main:         U0 --- U1 --- U2 --- SA --- SB --- SC
fork/patch-A:      U0 --- U1 --- U2 --- SA --- SB --- SC --- A1 --- A2
fork/patch-B:      U0 --- U1 --- U2 --- SA --- SB --- SC --- B1
fork/patch-C:      U0 --- U1 --- U2 --- SA --- SB --- SC --- C1 --- C2
```

### 2. Sync Process

When upstream updates to U3, patchstack:

1. **Fetches** latest upstream and fork state
2. **Discovers** all patch branches (descendants of fork main)
3. **Rebases** each patch onto the new upstream (U3)
4. **Integrates** patches sequentially by squashing in lexicographic order
5. **Publishes** all updates atomically (main + patches + notes)

Result:

```
upstream/main:     U0 --- U1 --- U2 --- U3
fork/main:         U0 --- U1 --- U2 --- U3 --- SA' --- SB' --- SC'
fork/patch-A:      U0 --- U1 --- U2 --- U3 --- A1' --- A2'
fork/patch-B:      U0 --- U1 --- U2 --- U3 --- B1'
fork/patch-C:      U0 --- U1 --- U2 --- U3 --- C1' --- C2'
```

### 3. Conflict Handling

If a patch fails to rebase or integrate:

- The patch branch **remains at its old state**
- Other patches continue to integrate
- Notes record the failure for investigation
- Manual resolution required before next successful sync

## Usage

### Commands

```bash
# Sync fork with upstream (main command)
./scripts/patchstack sync

# Show current patch stack status
./scripts/patchstack status

# List all patch branches
./scripts/patchstack list

# Validate without making changes (dry-run)
./scripts/patchstack sync --dry-run
```

### Configuration

Set via environment variables or `.patchstackrc`:

```bash
# Remote containing patch branches (default: origin)
PATCH_REMOTE=origin

# Remote pointing to upstream repo (default: upstream)
UPSTREAM_REMOTE=upstream

# Main integration branch (default: main)
MAIN_BRANCH=main

# Upstream branch to track (default: main)
UPSTREAM_BRANCH=main
```

### Creating Patch Branches

1. Start from fork main:

   ```bash
   git checkout main
   git checkout -b patch-my-feature
   ```

2. Make your changes and commit:

   ```bash
   git commit -am "Add my feature"
   ```

3. Push the patch branch:

   ```bash
   git push -u origin patch-my-feature
   ```

4. Run patchstack sync:

   ```bash
   ./scripts/patchstack sync
   ```

Your patch will be automatically integrated into the fork's main branch!

## Scenarios

### Clean Update

All patches rebase and integrate successfully → All branches updated

### Rebase Conflict

Patch-B conflicts during rebase → Patch-B unchanged, others updated

### Integration Conflict

Patch-B rebases but conflicts when squashing → Patch-B not published (preserves invariant)

### Empty Patch

Patch-C changes merged upstream → Patch-C deleted, recorded in notes

## Requirements

- Git 2.30+ (for atomic push and notes support)
- Bash 4.0+ or compatible shell
- SSH or HTTPS access to repositories

## Architecture

See [GUIDE.md](GUIDE.md) for detailed design specification and [AGENTS.md](AGENTS.md) for the implementation plan.

## Contributing

Contributions welcome! Please:

1. Create a patch branch for your feature
2. Add tests for new functionality
3. Ensure all tests pass
4. Submit a pull request

## License

MIT License - see LICENSE file for details

## Credits

Inspired by the challenges of maintaining long-lived forks and the principles of:

- Quilt patch management
- Git rebase workflows
- Deterministic build systems

---

**Patchstack**: Because forks shouldn't be painful. 🎯
