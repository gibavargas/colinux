# CoLinux — developer task runner
# =============================================================================
# Common targets:
#   make test       # lint + unit tests (the v0.3 quality gate)
#   make lint       # shellcheck gate on scripts/*.sh (+ wrapper report)
#   make test-unit  # bats unit + contract suite
#   make test-iso   # QEMU ISO boot regression (needs a built ISO + QEMU)
#   make check      # alias for test
#   make clean      # remove test artifacts
# =============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

PHONY_TARGETS := help test lint test-unit test-iso check clean

.PHONY: $(PHONY_TARGETS)

help: ## Show this help
	@echo "CoLinux — developer tasks"
	@echo ""
	@echo "  make test       lint + unit tests (default gate)"
	@echo "  make lint       shellcheck gate (scripts/*.sh)"
	@echo "  make test-unit  bats unit + contract suite"
	@echo "  make test-iso   QEMU ISO boot regression"
	@echo "  make check      alias for 'test'"
	@echo "  make clean      remove test artifacts"
	@echo ""
	@echo "Run a single bats file: ./tests/.bats/bin/bats tests/unit/wrappers.bats"

test: ## lint + unit tests
	@./tests/run-tests.sh lint unit

check: test ## alias for test

lint: ## shellcheck gate
	@./tests/run-tests.sh lint

test-unit: ## bats unit tests
	@./tests/run-tests.sh unit

test-iso: ## QEMU ISO boot regression
	@./tests/run-tests.sh iso

clean: ## remove test artifacts
	@rm -rf tests/.bats dist/test-results.log dist/serial-output.log
	@echo "cleaned test artifacts"
