.PHONY: test lint check all

# Default target
all: check

# Run all checks (lint + tests)
check: lint test

# Run shellcheck on all bash scripts
# Uses -x to follow sourced files and -e SC1091 to ignore "not following" warnings for test harness
lint:
	@echo "Running shellcheck..."
	@shellcheck scripts/patchstack
	@for f in tests/*.sh; do \
		shellcheck -x -e SC1091 "$$f" || exit 1; \
	done
	@echo "✓ All shellcheck checks passed"

# Run all tests
test:
	@echo "Running tests..."
	@./tests/run-all-tests.sh
