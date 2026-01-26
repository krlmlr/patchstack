# GitHub Copilot Instructions for Patchstack

This file provides GitHub Copilot-specific guidance for working on the Patchstack project.

## Source of Truth

**All comprehensive agent guidelines are in [AGENTS.md](../AGENTS.md).**

This file should be kept minimal and only contain Copilot-specific quick reference. For detailed information about:

- Project overview and core principles
- Implementation strategy and testing philosophy
- Code style and Git operations
- Development workflow and common pitfalls

Please refer to [AGENTS.md](../AGENTS.md).

## Quick Reference for Copilot

### Project Type
- **Bash shell script** Git automation tool
- Test-first development with snapshot testing
- Zero-configuration by default

### Key Files
- `scripts/patchstack` - Main executable bash script
- `tests/harness.sh` - Test infrastructure
- `tests/test-*.sh` - Individual test files
- `tests/snapshots/` - Expected output snapshots
- `Makefile` - Build/test automation

### Code Style Quick Tips
- Always use `set -euo pipefail` in bash scripts
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for tests, not `[ ]`
- Follow all shellcheck warnings
- Keep functions small (<50 lines)

### Testing

**CRITICAL: ALWAYS run `make check` before requesting a code review.**

```bash
# Run all checks (lint + tests)
make check

# Run only linting (shellcheck)
make lint

# Run only tests
make test
```

### When Contributing
1. Read [AGENTS.md](../AGENTS.md) for complete guidelines
2. Write tests first
3. Implement the minimal solution
4. Run `make check` to verify all checks pass
5. Request code review only after `make check` succeeds

For comprehensive information, always refer to [AGENTS.md](../AGENTS.md).
