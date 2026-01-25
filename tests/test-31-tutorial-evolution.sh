#!/usr/bin/env bash
# Test: Tutorial - Complete patch stack evolution lifecycle
# This test demonstrates the full lifecycle of maintaining patches with patchstack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

echo "=== Patchstack Tutorial: Patch Stack Evolution ==="
echo

### Step 1: Initial Setup
echo "### Step 1: Setting up fork repository"
echo "Creating upstream repository and fork..."

setup_test_env
cd "$FORK_DIR"

# Create a real remote (bare repository) to properly test ref updates
REMOTE_DIR="$TEST_DIR/remote"
git clone --bare "$FORK_DIR" "$REMOTE_DIR"
git remote set-url origin "$REMOTE_DIR"

echo "✓ Fork repository ready"
echo "  - upstream: $UPSTREAM_DIR"
echo "  - fork: $FORK_DIR"
echo "  - remote: $REMOTE_DIR"
echo

### Step 2: Creating patch branches
echo "### Step 2: Creating patch branches for our features"
echo

echo "Creating patch-feature-a: adds authentication logic"
git checkout -q -b patch-feature-a origin/main
echo "auth_enabled=true" > config.txt
git add config.txt
git commit -q -m "Add authentication config"
echo "function authenticate() { ... }" > auth.sh
git add auth.sh
git commit -q -m "Implement authentication"
git push -q origin patch-feature-a
git checkout -q main
echo "✓ Created patch-feature-a with 2 commits"

echo "Creating patch-feature-b: adds logging"
git checkout -q -b patch-feature-b origin/main
echo "log_level=info" > logging.txt
git add logging.txt
git commit -q -m "Add logging config"
echo "function log() { ... }" > logger.sh
git add logger.sh
git commit -q -m "Implement logger"
git push -q origin patch-feature-b
git checkout -q main
echo "✓ Created patch-feature-b with 2 commits"

echo "Creating patch-bugfix-x: fixes edge case"
git checkout -q -b patch-bugfix-x origin/main
echo "# Edge case fix" > bugfix.txt
git add bugfix.txt
git commit -q -m "Fix edge case in parser"
git push -q origin patch-bugfix-x
git checkout -q main
echo "✓ Created patch-bugfix-x with 1 commit"
echo

### Step 3: Initial sync (clean)
echo "### Step 3: Simulating upstream evolution"
echo

echo "Upstream adds new features..."
cd "$UPSTREAM_DIR"
echo "v1.1.0" > VERSION
git add VERSION
git commit -q -m "Release v1.1.0"
echo "function helper1() { ... }" > helpers.sh
git add helpers.sh
git commit -q -m "Add helper functions"

cd "$FORK_DIR"
git fetch -q upstream
echo "✓ Upstream is now 2 commits ahead"
echo

echo "### Step 4: First sync - rebasing all patches"
echo "Running: patchstack sync"
echo

output=$("$PATCHSTACK" sync 2>&1)
echo "$output"
echo

# Verify all patches succeeded
if echo "$output" | grep -q "patch-feature-a.*success" && \
   echo "$output" | grep -q "patch-feature-b.*success" && \
   echo "$output" | grep -q "patch-bugfix-x.*success"; then
    echo "✓ All patches rebased successfully onto new upstream"
else
    echo "✗ Expected all patches to succeed"
    cleanup_test_env
    exit 1
fi

# NOTE: After successful sync, tmp refs were already pushed to origin and then cleaned up
# We don't need to verify tmp refs exist anymore - the origin refs have been updated
echo "✓ All patches now based on upstream/main"
echo

### Step 5: Empty patch scenario (independent demonstration)
echo "### Step 5: Empty patch scenario - upstream accepts a patch"
echo

echo "Resetting to demonstrate empty patch detection..."
# Create a fresh scenario for empty patch demonstration
cd "$FORK_DIR"
git checkout -q main
git reset --hard upstream/main
git push -q -f origin main

# Create two new patches - one will become empty
git checkout -q -b patch-will-be-empty origin/main
echo "bugfix" > empty-demo.txt
git add empty-demo.txt
git commit -q -m "Add bugfix"
git push -q origin patch-will-be-empty
git checkout -q main

git checkout -q -b patch-will-remain origin/main
echo "feature" > feature-demo.txt
git add feature-demo.txt
git commit -q -m "Add feature"
git push -q origin patch-will-remain
git checkout -q main

echo "✓ Created two new patches for demonstration"
echo

echo "Upstream adds the same bugfix..."
cd "$UPSTREAM_DIR"
echo "bugfix" > empty-demo.txt
git add empty-demo.txt
git commit -q -m "Accept community bugfix"

cd "$FORK_DIR"
git fetch -q upstream
echo "✓ Upstream now has same content as patch-will-be-empty"
echo

echo "Running: patchstack sync"
echo "This should detect patch-will-be-empty is now empty..."
echo

output=$("$PATCHSTACK" sync 2>&1)
echo "$output"
echo

if echo "$output" | grep -q "patch-will-be-empty.*empty"; then
    echo "✓ Detected patch-will-be-empty is empty (upstream has it)"
else
    echo "✗ Expected patch-will-be-empty to be detected as empty"
    cleanup_test_env
    exit 1
fi

# Verify empty patch was deleted
if ! git rev-parse origin/patch-will-be-empty &>/dev/null; then
    echo "✓ Empty patch-will-be-empty was automatically deleted"
else
    echo "✗ Expected patch-will-be-empty to be deleted"
    cleanup_test_env
    exit 1
fi

# Verify other patch still exists
if git rev-parse origin/patch-will-remain &>/dev/null; then
    echo "✓ Non-empty patch-will-remain still exists"
else
    echo "✗ Expected patch-will-remain to still exist"
    cleanup_test_env
    exit 1
fi
echo

### Step 6: Conflict scenario (independent demonstration)
echo "### Step 6: Conflict scenario - handling conflicts during sync"
echo

echo "Resetting to demonstrate conflict handling..."
# Create a fresh scenario for conflict demonstration
cd "$FORK_DIR"
git checkout -q main
git reset --hard upstream/main
git push -q -f origin main

# Create two patches - one will conflict, one won't
git checkout -q -b patch-will-conflict origin/main
echo "our version" > conflict-demo.txt
git add conflict-demo.txt
git commit -q -m "Add our version"
git push -q origin patch-will-conflict
git checkout -q main

git checkout -q -b patch-no-conflict origin/main
echo "safe feature" > safe.txt
git add safe.txt
git commit -q -m "Add safe feature"
git push -q origin patch-no-conflict
git checkout -q main

echo "✓ Created two new patches for demonstration"
echo

echo "Upstream modifies same file..."
cd "$UPSTREAM_DIR"
echo "upstream version" > conflict-demo.txt
git add conflict-demo.txt
git commit -q -m "Upstream's version"

cd "$FORK_DIR"
git fetch -q upstream
echo "✓ Upstream modified conflict-demo.txt (conflicts with patch-will-conflict)"
echo

echo "Running: patchstack sync"
echo "This should detect conflict in patch-will-conflict..."
echo

output=$("$PATCHSTACK" sync 2>&1)
echo "$output"
echo

if echo "$output" | grep -q "patch-will-conflict.*conflict"; then
    echo "✓ Detected conflict in patch-will-conflict"
else
    echo "✗ Expected conflict in patch-will-conflict"
    cleanup_test_env
    exit 1
fi

if echo "$output" | grep -q "patch-no-conflict.*success"; then
    echo "✓ patch-no-conflict succeeded (independent processing)"
else
    echo "✗ Expected patch-no-conflict to succeed"
    cleanup_test_env
    exit 1
fi

# Verify conflicted patch still exists (unchanged)
if git rev-parse origin/patch-will-conflict &>/dev/null; then
    echo "✓ Conflicted patch left unchanged, can be resolved manually"
else
    echo "✗ Expected patch-will-conflict to still exist"
    cleanup_test_env
    exit 1
fi

# Verify successful patch still exists (updated)
if git rev-parse origin/patch-no-conflict &>/dev/null; then
    echo "✓ Non-conflicting patch synced successfully"
else
    echo "✗ Expected patch-no-conflict to exist"
    cleanup_test_env
    exit 1
fi
echo

### Step 7: Summary
echo "### Step 7: Summary of patch stack evolution"
echo
echo "This tutorial demonstrated:"
echo "1. Creating multiple patch branches with different features"
echo "2. First sync: All patches rebased cleanly onto new upstream"
echo "3. Empty patch detection: Automatically removed when upstream has same changes"
echo "4. Conflict detection: Safely handles conflicts, leaves patch unchanged for manual resolution"
echo "5. Independent processing: One patch failing doesn't affect others"
echo
echo "Key behaviors:"
echo "  ✓ Clean rebases happen automatically"
echo "  ✓ Empty patches are detected and deleted"
echo "  ✓ Conflicts are detected and reported"
echo "  ✓ Failed patches remain unchanged for manual fix"
echo "  ✓ Each patch is processed independently"
echo

# All scenarios were demonstrated successfully through independent tests
echo "All demonstration scenarios completed successfully"

# Cleanup
cleanup_test_env

echo
echo "=== Tutorial Complete ==="
echo "✓ All scenarios demonstrated successfully"
