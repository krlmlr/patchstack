# Cleaning Up Stale Patchstack Data

Patchstack uses temporary resources during each run. While these are automatically cleaned up on normal exit, interrupted runs (e.g., killed processes, system crashes) may leave stale data.

## What Gets Created During a Run

Each patchstack run creates:

1. **Temporary Git refs** in `refs/patchstack/runs/$RUN_ID/`
2. **Temporary directory** in `${TMPDIR:-/tmp}/patchstack-$RUN_ID.*/`
3. **Lock directory** at `.git/patchstack.lock` (local to the repository)
4. **Temporary branches** named `patchstack-$RUN_ID-*`

The `$RUN_ID` format is: `YYYYMMDD-HHMMSS-PID-RANDOM` (e.g., `20260125-161530-12345-54321`)

## Normal Cleanup

Patchstack automatically cleans up all temporary resources:

- **On successful completion** - via exit trap
- **On error** - via exit trap
- **On interrupt (Ctrl+C)** - via signal trap

You should rarely need to clean up manually.

## When Manual Cleanup Is Needed

Manual cleanup may be needed if:

- The patchstack process was killed with `kill -9` (SIGKILL)
- System crashed during execution
- Disk was full, preventing cleanup
- Bug in cleanup code (please report!)

## How to Clean Up Stale Data

### 1. Clean Up Stale Lock Directory

If you see "Another patchstack process is already running" but no process is running:

```bash
# Check if patchstack is actually running
ps aux | grep patchstack

# If no process is running, check the lock directory
ls -la .git/patchstack.lock

# If the PID in the lock doesn't match any running process, remove it
rm -rf .git/patchstack.lock
```

### 2. Clean Up Stale Git Refs

List stale temporary refs:

```bash
# List all patchstack temporary refs
git for-each-ref --format='%(refname) %(creatordate:relative)' 'refs/patchstack/runs/'
```

Remove specific run's refs:

```bash
# Remove refs for a specific run ID
RUN_ID="20260125-161530-12345-54321"
git for-each-ref --format='%(refname)' "refs/patchstack/runs/$RUN_ID/" | \
  xargs -I {} git update-ref -d {}
```

Remove ALL stale refs (use with caution):

```bash
# Remove all temporary refs from all runs
git for-each-ref --format='%(refname)' 'refs/patchstack/runs/' | \
  xargs -I {} git update-ref -d {}
```

### 3. Clean Up Stale Temporary Directories

```bash
# List stale temporary directories (older than 1 day)
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'patchstack-*' -type d -mtime +1

# Remove them
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'patchstack-*' -type d -mtime +1 -exec rm -rf {} +
```

### 4. Clean Up Stale Temporary Branches

```bash
# List temporary branches
git branch --list 'patchstack-*'

# Remove specific run's branches
RUN_ID="20260125-161530-12345-54321"
git branch --list "patchstack-${RUN_ID}-*" | xargs -I {} git branch -D {}

# Remove ALL temporary branches (use with caution - only if no patchstack is running)
git branch --list 'patchstack-*' | xargs -I {} git branch -D {}
```

## Complete Cleanup Script

For convenience, here's a complete cleanup script for all stale patchstack data:

```bash
#!/usr/bin/env bash
# cleanup-patchstack.sh - Remove all stale patchstack temporary data

set -euo pipefail

echo "⚠️  This will remove ALL patchstack temporary data"
echo "   Make sure no patchstack process is running!"
echo
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

echo "Cleaning up temporary refs..."
git for-each-ref --format='%(refname)' 'refs/patchstack/runs/' | \
  xargs -I {} git update-ref -d {} || true
echo "✓ Removed temporary refs"

echo "Cleaning up temporary directories..."
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'patchstack-*' -type d -exec rm -rf {} +
echo "✓ Removed temporary directories"

echo "Cleaning up temporary branches..."
git branch --list 'patchstack-*' | xargs -I {} git branch -D {} || true
echo "✓ Removed temporary branches"

echo "Cleaning up lock directory..."
rm -rf .git/patchstack.lock
echo "✓ Removed lock directory"

echo
echo "✓ Cleanup complete"
```

Save this as `cleanup-patchstack.sh`, make it executable with `chmod +x cleanup-patchstack.sh`, and run it when needed.

## Preventing Stale Data

To minimize stale data:

1. **Don't use `kill -9`** - Use `kill` (SIGTERM) or Ctrl+C instead, which allows cleanup
2. **Ensure adequate disk space** - Cleanup requires writing to disk
3. **Monitor long-running syncs** - If stuck, investigate rather than killing

## Monitoring Temporary Resources

Check current resource usage:

```bash
# List current temporary refs
git for-each-ref --format='%(refname) %(creatordate:relative)' 'refs/patchstack/runs/'

# List temporary directories with sizes
du -sh "${TMPDIR:-/tmp}"/patchstack-* 2>/dev/null || echo "No temporary directories"

# Check for lock directory
if [[ -d ".git/patchstack.lock" ]]; then
  echo "Lock directory exists"
  cat ".git/patchstack.lock/pid" 2>/dev/null || echo "  (no PID file)"
else
  echo "No lock directory"
fi

# List temporary branches
git branch --list 'patchstack-*'
```

## Getting Help

If you encounter persistent issues with stale data:

1. Check GitHub issues for similar reports
2. Open a new issue with details about:
   - How the run was interrupted
   - What stale data remains
   - Output of the monitoring commands above

## Technical Details

### Run ID Generation

Each run generates a unique ID using:
```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
```

Components:
- `YYYYMMDD-HHMMSS` - Timestamp for human readability
- `$$` - Process ID for uniqueness within a second
- `${RANDOM}` - Random number for collision resistance

This ensures:
- IDs are unique even if multiple runs start simultaneously
- IDs are sortable by time for easier debugging
- IDs are easily identifiable as patchstack-related

### Automatic Cleanup

Cleanup is handled by an exit trap:
```bash
trap exit_handler EXIT INT TERM
```

This ensures cleanup runs on:
- Normal exit (EXIT)
- Ctrl+C (INT)
- Termination signal (TERM)

**Note:** SIGKILL (kill -9) cannot be trapped, so it prevents cleanup.
