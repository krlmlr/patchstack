#!/usr/bin/env bash
set -euo pipefail

# Create GitHub issues for patchstack phases 1.3-1.8
# Requires: gh CLI tool (https://cli.github.com)

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo "Error: gh CLI tool is required but not installed"
    echo "Install: brew install gh"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub"
    echo "Run: gh auth login"
    exit 1
fi

# Array of phases to create issues for
declare -A PHASES
PHASES=(
    ["1.3"]="130-squash-integration.md"
    ["1.4"]="140-atomic-update.md"
    ["1.5"]="150-atomic-push.md"
    ["1.6"]="160-end-to-end-scenarios.md"
    ["1.7"]="170-dry-run-and-status.md"
    ["1.8"]="180-error-recovery.md"
)

# Issue titles
declare -A TITLES
TITLES=(
    ["1.3"]="Phase 1.3: Squash Integration"
    ["1.4"]="Phase 1.4: Atomic Update (Ref Updates Only)"
    ["1.5"]="Phase 1.5: Atomic Push"
    ["1.6"]="Phase 1.6: End-to-End Scenarios"
    ["1.7"]="Phase 1.7: Dry-Run and Status"
    ["1.8"]="Phase 1.8: Error Recovery"
)

# Issue summaries
declare -A SUMMARIES
SUMMARIES=(
    ["1.3"]="Implement sequential squash integration to build a new main branch by combining viable patches in lexicographic order."
    ["1.4"]="Update local remote-tracking refs to reflect the new state after successful integration, and record metadata in Git notes."
    ["1.5"]="Push all local ref updates to the remote repository using atomic force-with-lease to prevent concurrent modification conflicts."
    ["1.6"]="Wire all phases together and test complete workflows from start to finish, ensuring the full sync operation is reliable and idempotent."
    ["1.7"]="Add --dry-run flag and status subcommand to provide visibility into planned changes and current state without making modifications."
    ["1.8"]="Handle problematic states gracefully with clear error messages and guidance, ensuring patchstack never leaves the repository in a broken state."
)

# Create issues in order
for phase in "1.3" "1.4" "1.5" "1.6" "1.7" "1.8"; do
    title="${TITLES[$phase]}"
    summary="${SUMMARIES[$phase]}"
    plan_file="${PHASES[$phase]}"
    
    echo "Creating issue: $title"
    
    # Create issue body
    body=$(cat <<EOF
## Summary

$summary

## Details

See the detailed implementation plan: \`plan/$plan_file\`

## Implementation Checklist

- [ ] Read and understand the phase plan
- [ ] Implement required functions
- [ ] Write comprehensive tests
- [ ] Verify all tests pass
- [ ] Update PLAN.md to mark phase complete
- [ ] Verify implementation (don't trust status markers without verification)

## Labels

phase-${phase/./}, milestone-1
EOF
)
    
    # Create the issue
    gh issue create \
        --title "$title" \
        --body "$body" \
        --label "enhancement,phase-${phase/./-}" \
        --assignee "@me"
    
    echo "✓ Created issue for $phase"
    echo
    
    # Small delay to avoid rate limiting
    sleep 1
done

echo "All issues created successfully!"
