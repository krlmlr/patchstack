#!/usr/bin/env bash
# Test: Excludes non-descendants (orphan branches)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$SCRIPT_DIR/harness.sh"

setup() {
    local fork
    fork=$(setup_test_env)
    cd "$fork"

    # Create orphan branch (not a descendant of main)
    git checkout -q --orphan patch-orphan
    git rm -rf . > /dev/null 2>&1 || true
    echo "orphan" > orphan.txt
    git add orphan.txt
    git commit -q -m "Orphan commit"
    git push -q origin patch-orphan

    # Create normal patch branch
    git checkout -q main
    create_patch_branch "patch-normal" 1
}

setup
output=$("$PATCHSTACK" list 2>&1)
assert_snapshot "03-excludes-orphan" "$output"
cleanup_test_env
