# Contributing to Patchstack

Thank you for your interest in contributing to Patchstack! This document provides guidelines for contributing to the project.

## Development Guidelines

### Code Quality Requirements

**All code contributions MUST pass shellcheck before requesting review.**

```bash
# Run shellcheck on the main script
shellcheck scripts/patchstack

# Run shellcheck on test harness
shellcheck tests/harness.sh

# Run shellcheck on all test files
shellcheck tests/test-*.sh
```

Shellcheck warnings should be fixed, not ignored. In exceptional cases where a warning must be ignored:
- Add a comment explaining why the warning is invalid
- Use specific shellcheck disable comments (e.g., `# shellcheck disable=SC2086`)
- Introduce `shellcheck source=` annotations for sourced files

### Shell Script Guidelines

Follow these bash best practices:

- **Always** use `set -euo pipefail` at the start of scripts
- **Quote all variables**: use `"$var"` not `$var`
- Use `[[ ]]` for tests, not `[ ]`
- Keep functions small (< 50 lines)
- Functions should do one thing well
- Provide clear error messages with context
- Use meaningful variable names

### Testing Requirements

**Every feature must have tests before implementation.**

```bash
# Run all tests
./tests/run-all-tests.sh

# Run a specific test
./tests/test-01-no-patches.sh

# Update snapshots after intentional output changes
./tests/run-all-tests.sh --apply
```

Test requirements:
- Tests must be fast (< 10 seconds for full suite)
- Use isolated Git repositories (created in `/tmp`)
- Clean setup and teardown for each test
- Test both success and failure cases
- Use snapshot testing for CLI output

### No Hard-Coded Paths or Shared State

**Critical:** Each patchstack run must be isolated to prevent race conditions:

- **No hard-coded temporary ref paths** - Each run uses `refs/patchstack/runs/$RUN_ID/`
- **No hard-coded temporary branch names** - Use unique names with `$RUN_ID`
- **No hard-coded temporary file paths** - Use `$RUN_TEMP_DIR` per run
- **Lock file prevents concurrent runs** - Automatic acquisition and release
- **Cleanup via trap handlers** - Always cleanup on exit (success or failure)

New code must follow these patterns:
```bash
# Good: Use run-specific paths
local tmp_ref="$RUN_REF_PREFIX/$branch_name"
local tmp_branch="patchstack-${RUN_ID}-tmp-$branch_name"
local tmp_file="$RUN_TEMP_DIR/mydata"

# Bad: Hard-coded paths (don't do this!)
local tmp_ref="refs/patchstack/tmp/$branch_name"
local tmp_branch="patchstack-tmp-$branch_name"
local tmp_file="/tmp/patchstack-mydata"
```

### Git Operations

See [AGENTS.md](AGENTS.md) for detailed information on Git operations that patchstack automates.

Key principles:
- Assume repositories have been fetched (`git fetch`)
- Assume working tree is clean
- Detect and advise on problematic states
- Operations should be idempotent (safe to re-run)
- No destructive operations without clear user intent

### Pull Request Process

1. **Fork and clone** the repository
2. **Create a feature branch** from `main`
3. **Write tests first** for your feature
4. **Implement the feature** with minimal changes
5. **Run shellcheck** on all modified scripts
6. **Run all tests** and ensure they pass
7. **Update documentation** if needed
8. **Submit a pull request** with clear description

### Commit Messages

- Use clear, descriptive commit messages
- Start with a verb in present tense (e.g., "Add", "Fix", "Update")
- Reference issue numbers when applicable
- Keep the first line under 72 characters

Example:
```
Add support for custom upstream branch names

- Allow UPSTREAM_BRANCH environment variable
- Update discovery logic to use configured branch
- Add tests for custom branch names

Fixes #123
```

### Code Review

All contributions will be reviewed for:
- Shellcheck compliance (mandatory)
- Test coverage (mandatory)
- Code style adherence
- Documentation clarity
- Security considerations

## Project Structure

```
patchstack/
├── scripts/
│   └── patchstack          # Main executable script
├── tests/
│   ├── harness.sh          # Test infrastructure
│   ├── test-*.sh           # Individual tests
│   └── snapshots/          # Expected output snapshots
├── docs/
│   └── CLEANUP.md          # Cleanup procedures
├── AGENTS.md               # Detailed development guidelines
├── CONTRIBUTING.md         # This file
└── README.md               # User documentation
```

## Getting Help

- **Issues:** Check existing issues or open a new one
- **Discussions:** Use GitHub Discussions for questions
- **Documentation:** See AGENTS.md for comprehensive guidelines

## License

By contributing to Patchstack, you agree that your contributions will be licensed under the same license as the project.
