#!/usr/bin/env bash
# Test: Trivial workflow from issue - complete lifecycle
# This test mimics the script from the issue to verify the expected behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

echo "=== Test: Trivial Workflow (Issue Script) ==="
echo

# Create a test directory
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

# Configure git
git config --global user.email "test@patchstack.test" 2>/dev/null || true
git config --global user.name "Test User" 2>/dev/null || true

### Setup: Create upstream and fork
echo "### Setup: Creating upstream and fork repositories"

git init --bare --initial-branch=main upstream-repo.git
git clone upstream-repo.git upstream
cd upstream
git config user.email "test@patchstack.test"
git config user.name "Test User"
git checkout -b main
git commit --allow-empty -m "Initial commit"

touch README.md
git add -- README.md
git commit -m "Add README"
git push origin main
cd ..

cp -r upstream-repo.git fork-repo.git
git clone fork-repo.git fork
cd fork
git config user.email "test@patchstack.test"
git config user.name "Test User"
git remote add upstream ../upstream-repo.git
git fetch upstream

echo "✓ Setup complete"
echo

### Create patch branches
echo "### Creating patch branches a and b"

git checkout -b a
touch a.txt
git add -- a.txt
git commit -m "Add a.txt"
git push -u origin HEAD

git checkout main
git checkout -b b
touch b.txt
git add -- b.txt
git commit -m "Add b.txt"
git push -u origin HEAD

git checkout main
echo "✓ Created patch branches a and b"
echo

### First sync
echo "### First sync: Expecting main updated with a.txt and b.txt"
echo "### branches a and b should remain unchanged (no rebase needed)"
echo

# Record SHAs before sync
sha_a_before=$(git rev-parse origin/a)
sha_b_before=$(git rev-parse origin/b)

"$PATCHSTACK" sync

git fetch origin

# Check main has both files
if git ls-tree --name-only origin/main | grep -q "a.txt" && \
   git ls-tree --name-only origin/main | grep -q "b.txt"; then
    echo "✓ origin/main contains a.txt and b.txt"
else
    echo "✗ origin/main missing expected files"
    git ls-tree --name-only origin/main
    rm -rf "$TEST_DIR"
    exit 1
fi

# Check branches a and b are unchanged (same SHA as before since no rebase needed)
sha_a_after=$(git rev-parse origin/a)
sha_b_after=$(git rev-parse origin/b)

if [[ "$sha_a_before" == "$sha_a_after" ]]; then
    echo "✓ Branch a unchanged (no rebase needed)"
else
    echo "✗ Branch a was modified unexpectedly"
    echo "  Before: $sha_a_before"
    echo "  After: $sha_a_after"
    rm -rf "$TEST_DIR"
    exit 1
fi

if [[ "$sha_b_before" == "$sha_b_after" ]]; then
    echo "✓ Branch b unchanged (no rebase needed)"
else
    echo "✗ Branch b was modified unexpectedly"
    echo "  Before: $sha_b_before"
    echo "  After: $sha_b_after"
    rm -rf "$TEST_DIR"
    exit 1
fi

echo

### Add upstream change
echo "### Adding upstream change (CHANGELOG.md)"

touch ../upstream/CHANGELOG.md
git -C ../upstream add -- CHANGELOG.md
git -C ../upstream commit -m "Add CHANGELOG"
git -C ../upstream push origin main

git fetch upstream
echo "✓ Upstream updated with CHANGELOG.md"
echo

### Second sync
echo "### Second sync: Expecting main updated with CHANGELOG.md"
echo "### and both patch branches rebased on top of it"
echo

"$PATCHSTACK" sync

git fetch origin

# Check main has CHANGELOG.md
if git ls-tree --name-only origin/main | grep -q "CHANGELOG.md"; then
    echo "✓ origin/main contains CHANGELOG.md"
else
    echo "✗ origin/main missing CHANGELOG.md"
    rm -rf "$TEST_DIR"
    exit 1
fi

# Check patches are rebased onto new upstream (should have CHANGELOG.md in their history)
if git ls-tree --name-only origin/a | grep -q "CHANGELOG.md"; then
    echo "✓ Branch a includes CHANGELOG.md (rebased)"
else
    echo "✗ Branch a missing CHANGELOG.md"
    rm -rf "$TEST_DIR"
    exit 1
fi

if git ls-tree --name-only origin/b | grep -q "CHANGELOG.md"; then
    echo "✓ Branch b includes CHANGELOG.md (rebased)"
else
    echo "✗ Branch b missing CHANGELOG.md"
    rm -rf "$TEST_DIR"
    exit 1
fi

echo

### Modify patch a
echo "### Modifying patch a locally"

# First, get the rebased version of a
git fetch origin a
git checkout -B a origin/a

echo "Modification in a.txt" >> a.txt
git add -- a.txt
git commit -m "Modify a.txt"
git push origin HEAD

git checkout main
echo "✓ Modified patch a"
echo

### Third sync
echo "### Third sync: Expecting main to include modifications from a"
echo "### Two commits ahead of upstream/main, branches unchanged"
echo

"$PATCHSTACK" sync

git fetch origin

# Check main has the modification
if git show origin/main:a.txt | grep -q "Modification"; then
    echo "✓ origin/main contains modification from a"
else
    echo "✗ origin/main missing modification from a"
    rm -rf "$TEST_DIR"
    exit 1
fi

# Count commits ahead of upstream
commits_ahead=$(git rev-list --count upstream/main..origin/main)
echo "  origin/main is $commits_ahead commits ahead of upstream/main"

echo

### Upstream integrates patch b
echo "### Upstream integrates patch b (adds b.txt)"

touch ../upstream/b.txt
git -C ../upstream add -- b.txt
git -C ../upstream commit -m "Integrate patch b"
git -C ../upstream push origin main

git fetch upstream
echo "✓ Upstream integrated patch b"
echo

### Fourth sync
echo "### Fourth sync: Expecting main one commit ahead of upstream/main"
echo "### Branch b should be deleted, branch a rebased"
echo

"$PATCHSTACK" sync

git fetch origin

# Check if branch b was deleted
if git rev-parse origin/b &>/dev/null; then
    echo "✗ Branch b still exists (should be deleted)"
    rm -rf "$TEST_DIR"
    exit 1
else
    echo "✓ Branch b was deleted (integrated upstream)"
fi

# Check branch a still exists and is rebased
if git rev-parse origin/a &>/dev/null; then
    echo "✓ Branch a still exists"
else
    echo "✗ Branch a was unexpectedly deleted"
    rm -rf "$TEST_DIR"
    exit 1
fi

# Check main has both patch contents
if git show origin/main:a.txt | grep -q "Modification"; then
    echo "✓ origin/main still has modifications from a"
else
    echo "✗ origin/main missing modifications from a"
    rm -rf "$TEST_DIR"
    exit 1
fi

echo
echo "=== All scenarios passed ==="

# Cleanup
rm -rf "$TEST_DIR"

echo "✓ Test passed: trivial workflow"
