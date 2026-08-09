#!/usr/bin/env bash
# Test: a fork whose own `main` mirrors upstream and whose integration is `fork`
#
# This is the layout a mirroring bot (the Pull app, say) forces: it hard-resets
# the fork's `main` from upstream, so the integration cannot live there. The
# stack is then configured with MAIN_BRANCH=fork UPSTREAM_BRANCH=main, and
# UPSTREAM_REMOTE is the fork itself -- there is no second remote to fetch.
# PATCH_GLOB keeps the release branch such a fork also carries out of the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

echo "=== Test: fork branch layout (MAIN_BRANCH=fork, UPSTREAM_BRANCH=main) ==="
echo

TEST_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cd "$TEST_DIR"

### Setup: one repository, mirroring `main` and integrating on `fork`
git init --bare --initial-branch=main fork-repo.git >/dev/null
git clone -q fork-repo.git fork
cd fork
git config user.email "test@patchstack.test"
git config user.name "Test User"

git commit -q --allow-empty -m "Initial commit"
touch README.md
git add -- README.md
git commit -q -m "Add README"
git push -q origin main

# `fork` starts out equal to `main`; patchstack rebuilds it from there.
git branch fork main
git push -q origin fork

# A release branch, which is a descendant of the base but not a patch.
git checkout -q -b release-1.0 main
touch release-note.txt
git add -- release-note.txt
git commit -q -m "Cut release 1.0"
git push -q origin release-1.0

# Two patch branches, both based on the mirrored `main`.
git checkout -q -b p-alpha main
touch alpha.txt
git add -- alpha.txt
git commit -q -m "Add alpha.txt"
git push -q origin p-alpha

git checkout -q -b p-beta main
touch beta.txt
git add -- beta.txt
git commit -q -m "Add beta.txt"
git push -q origin p-beta

git checkout -q main
echo "✓ Setup complete"
echo

export PATCH_REMOTE=origin
export UPSTREAM_REMOTE=origin
export MAIN_BRANCH=fork
export UPSTREAM_BRANCH=main
export PATCH_GLOB='p-*'

### The stack is the two `p-*` branches, and neither main nor the release
echo "### Discovery"
patches=$("$SCRIPT_DIR/../scripts/patchstack" list)
assert_contains "$patches" "p-alpha"
assert_contains "$patches" "p-beta"
assert_not_contains "$patches" "release-1.0"
assert_not_contains "$patches" "^main$"
echo "✓ the stack is exactly the p-* branches"
echo

### Sync integrates them onto `fork`, leaving `main` alone
echo "### First sync"
main_before=$(git rev-parse refs/remotes/origin/main)
"$SCRIPT_DIR/../scripts/patchstack" sync >/dev/null
git fetch -q origin

assert_equal "$(git rev-parse refs/remotes/origin/main)" "$main_before" \
    "main is untouched by the sync"

tree_fork=$(git rev-parse "refs/remotes/origin/fork^{tree}")
tree_main=$(git rev-parse "refs/remotes/origin/main^{tree}")
if [ "$tree_fork" = "$tree_main" ]; then
    echo "✗ fork should carry the patches, but its tree equals main's" >&2
    exit 1
fi
echo "✓ fork carries the patches"

git checkout -q --detach refs/remotes/origin/fork
for f in alpha.txt beta.txt; do
    if [ ! -f "$f" ]; then
        echo "✗ $f missing from fork" >&2
        exit 1
    fi
done
if [ -f release-note.txt ]; then
    echo "✗ release-1.0 leaked into fork" >&2
    exit 1
fi
echo "✓ fork holds exactly the patches"
echo

### Upstream moves: the mirror advances, and the next sync replays onto it
echo "### Mirror advances"
git checkout -q main
touch upstream-feature.txt
git add -- upstream-feature.txt
git commit -q -m "Upstream adds a feature"
git push -q origin main

"$SCRIPT_DIR/../scripts/patchstack" sync >/dev/null
git fetch -q origin

git checkout -q --detach refs/remotes/origin/fork
for f in upstream-feature.txt alpha.txt beta.txt; do
    if [ ! -f "$f" ]; then
        echo "✗ $f missing from fork after the replay" >&2
        exit 1
    fi
done
echo "✓ fork replayed onto the advanced mirror"

if ! git merge-base --is-ancestor refs/remotes/origin/main refs/remotes/origin/fork; then
    echo "✗ fork is not a descendant of main" >&2
    exit 1
fi
echo "✓ fork descends from main"
echo

echo "=== All scenarios passed ==="
echo "✓ Test passed: fork branch layout"
