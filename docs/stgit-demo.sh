#!/usr/bin/env bash
# Demo: StGit workflow equivalent to patchstack trivial example
#
# This script demonstrates how to implement the patchstack workflow
# using StGit commands. It shows both the possibilities and limitations
# of mapping patchstack's multi-branch model to StGit's linear stack model.
#
# Key insight: StGit uses a fundamentally different model (linear stack)
# than patchstack (multiple independent branches), so this demo shows
# an APPROXIMATION of the patchstack workflow using StGit concepts.

set -euo pipefail

echo "=== StGit Demo: Trivial Workflow ==="
echo "This demonstrates patchstack-like behavior using StGit and git commands"
echo

# Create a temporary directory for the demo
DEMO_DIR=$(mktemp -d)
echo "Working in: $DEMO_DIR"
echo

# Cleanup function
cleanup() {
    echo
    echo "Cleaning up..."
    rm -rf "$DEMO_DIR"
}
trap cleanup EXIT

cd "$DEMO_DIR"

### Setup: Create upstream and fork repositories
echo "### Setup: Creating upstream and fork repositories"

git init --bare --initial-branch=main upstream-repo.git 2>/dev/null
git clone upstream-repo.git upstream 2>/dev/null
cd upstream
git config user.email "demo@stgit.test"
git config user.name "Demo User"
git checkout -b main 2>/dev/null
git commit --allow-empty -m "Initial commit"

touch README.md
git add -- README.md
git commit -m "Add README"
git push origin main 2>/dev/null
cd ..

cp -r upstream-repo.git fork-repo.git
git clone fork-repo.git fork 2>/dev/null
cd fork
git config user.email "demo@stgit.test"
git config user.name "Demo User"
git remote add upstream ../upstream-repo.git
git fetch --all 2>/dev/null

echo "✓ Setup complete"
echo

### Initialize StGit on the fork's main branch
echo "### Initializing StGit on fork's main branch"

stg init

echo "✓ StGit initialized"
echo

### Create patches using StGit (instead of separate branches)
echo "### Creating patches a and b using StGit"

# In StGit, patches are stacked on the current branch
# This is different from patchstack which uses separate branches

# Create patch 'a'
stg new a -m "Add a.txt"
touch a.txt
git add -- a.txt
stg refresh

# Create patch 'b'
stg new b -m "Add b.txt"
touch b.txt
git add -- b.txt
stg refresh

echo "✓ Created patches a and b"
echo "Current patch series:"
stg series
echo

### First "sync" - push to origin
echo "### First sync: Publishing patches to origin"
echo "### In StGit model, all patches live on main branch"
echo

# In patchstack: main would be updated with a.txt and b.txt squashed
# In StGit: patches are already applied on main, we just push
git push origin main --force 2>/dev/null

echo "Current state after push:"
git log --oneline -5
echo "✓ Patches pushed to origin/main"
echo

### Upstream adds CHANGELOG.md
echo "### Adding upstream change (CHANGELOG.md)"

cd ../upstream
touch CHANGELOG.md
git add -- CHANGELOG.md
git commit -m "Add CHANGELOG"
git push origin main 2>/dev/null
cd ../fork

git fetch upstream 2>/dev/null
echo "✓ Upstream updated with CHANGELOG.md"
echo

### Second sync - rebase onto new upstream
echo "### Second sync: Rebasing patches onto new upstream"
echo "### StGit's rebase command handles this"
echo

# Pop all patches, update base, push patches back
# This is what stg rebase does internally
stg rebase upstream/main

echo "After rebase:"
stg series
echo
git log --oneline -5
echo

# Verify CHANGELOG.md is now in history
if [[ -f CHANGELOG.md ]]; then
    echo "✓ CHANGELOG.md present (patches rebased onto new upstream)"
else
    echo "✗ Missing CHANGELOG.md"
fi

# Push updated main to origin
git push origin main --force 2>/dev/null
echo "✓ Rebased patches pushed to origin"
echo

### Modify patch a
echo "### Modifying patch a"

# In StGit, we need to go to the patch to modify it
stg goto a
echo "Modification in a.txt" >> a.txt
git add -- a.txt
stg refresh -m "Add a.txt (modified)"

# Apply remaining patches back to stack
stg push -a

echo "✓ Modified patch a"
echo "Current state:"
stg series
echo

# Push to origin
git push origin main --force 2>/dev/null
echo

### Upstream integrates patch b
echo "### Upstream integrates patch b (adds b.txt directly)"

cd ../upstream
touch b.txt
git add -- b.txt
git commit -m "Integrate patch b"
git push origin main 2>/dev/null
cd ../fork

git fetch upstream 2>/dev/null
echo "✓ Upstream integrated patch b"
echo

### Fourth sync - detect merged patch
echo "### Fourth sync: Detecting merged patch b"
echo "### Using stg rebase --merged to detect integrated patches"
echo

# The --merged flag tells StGit to detect patches merged upstream
# Note: This doesn't automatically delete the patch, just detects it
stg rebase --merged upstream/main 2>&1 || true

echo
echo "Patch series after rebase with --merged:"
stg series
echo

# Check if patch b was detected as merged
# StGit's --merged flag detects merged patches but still applies them
# The patch content is now empty because upstream has the same changes
echo "Checking patch status with --empty flag..."
stg series --empty

# Check if b is empty now by verifying it has no diff content
# The --empty flag shows "0" prefix for empty patches in the series output
if ! stg show b 2>/dev/null | grep -q "^diff --git"; then
    echo "✓ Patch b is now empty (merged upstream)"
    # Clean up empty patches manually - this is what patchstack does automatically
    stg delete b 2>/dev/null || echo "  (keeping patch for demonstration)"
    echo "✓ Deleted empty patch b using 'stg delete'"
else
    echo "Note: Patch b still shows content (StGit detected merge but didn't empty it)"
    echo "  This is different from patchstack which would delete it automatically"
    # Try to clean it anyway for demonstration
    stg clean 2>/dev/null || true
    echo "  Ran 'stg clean' to remove any empty patches"
fi

echo
echo "Final patch series:"
stg series
echo
echo "Final commit log:"
git log --oneline -5
echo

# Push final state
git push origin main --force 2>/dev/null

echo
echo "=== Demo Complete ==="
echo
echo "Key observations:"
echo "1. StGit uses a LINEAR STACK model (all patches on one branch)"
echo "2. Patchstack uses MULTIPLE BRANCHES (one per patch)"
echo "3. StGit's --merged flag can detect upstream-integrated patches"
echo "4. StGit handles rebasing well but doesn't maintain separate branches"
echo "5. For patchstack's multi-branch workflow, StGit is not a direct fit"
echo
echo "See docs/STGIT-ANALYSIS.md for detailed comparison"
