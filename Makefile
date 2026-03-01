# Tangerine Project Makefile
# SCRIPT-004: CI/CD & build automation

.PHONY: all build test golden lint fmt coverage clean help

SHELL := /bin/bash
TG    := tg
PYTHON := python3

# Default target
all: build test

# ————————————————————————————————————————————
# Build
# ————————————————————————————————————————————

build:
	@echo "==> Building Tangerine compiler..."
	$(TG) build tg_compiler/driver.tg -o target/tg

# ————————————————————————————————————————————
# Tests
# ————————————————————————————————————————————

test: test-golden test-stdlib test-compiler

test-golden:
	@echo "==> Running golden tests..."
	$(TG) test golden/smoke_test.tg
	$(TG) test golden/simple_test.tg
	$(TG) test golden/features_01.tg

test-stdlib:
	@echo "==> Running stdlib tests..."
	$(TG) test golden/stdlib_tests.tg
	$(TG) test golden/stdlib_extended_tests.tg

test-compiler:
	@echo "==> Running compiler module tests..."
	$(TG) test golden/compiler_module_tests.tg
	$(TG) test golden/negative_tests.tg
	$(TG) test golden/lsp_tests.tg
	$(TG) test golden/abi_ffi_tests.tg

test-conformance:
	@echo "==> Running conformance suite..."
	$(TG) test golden/conformance_runner.tg

test-frontend:
	@echo "==> Running frontend milestone tests..."
	for i in 01 02 03 04 05 06; do \
		$(TG) test golden/frontend_$$i.tg; \
	done

test-all: test test-conformance test-frontend
	@echo "==> All tests passed."

# ————————————————————————————————————————————
# Linting & Formatting
# ————————————————————————————————————————————

lint:
	@echo "==> Linting..."
	$(TG) lint std/*.tg tg_compiler/*.tg

fmt:
	@echo "==> Formatting..."
	$(TG) fmt std/*.tg tg_compiler/*.tg golden/*.tg

fmt-check:
	@echo "==> Checking format..."
	$(TG) fmt --check std/*.tg tg_compiler/*.tg

# ————————————————————————————————————————————
# Coverage
# ————————————————————————————————————————————

coverage:
	@echo "==> Generating coverage..."
	$(TG) test --coverage golden/stdlib_tests.tg -o target/cqs/coverage/stdlib.tgcov
	$(TG) test --coverage golden/features_01.tg  -o target/cqs/coverage/features.tgcov
	$(PYTHON) scripts/tg_cov_merge.py \
		--in "target/cqs/coverage/*.tgcov" \
		--out target/cqs/coverage/merged.tgcov
	@echo "Coverage merged to target/cqs/coverage/merged.tgcov"

# ————————————————————————————————————————————
# Documentation
# ————————————————————————————————————————————

docs:
	@echo "==> Generating documentation..."
	$(TG) doc std/*.tg -o target/doc

# ————————————————————————————————————————————
# Clean
# ————————————————————————————————————————————

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf target/tg target/doc target/cqs/coverage/merged.tgcov

# ————————————————————————————————————————————
# Help
# ————————————————————————————————————————————

help:
	@echo "Tangerine Makefile targets:"
	@echo "  all             Build and run tests (default)"
	@echo "  build           Compile the Tangerine compiler"
	@echo "  test            Run golden + stdlib + compiler tests"
	@echo "  test-all        Run every test suite including conformance"
	@echo "  test-conformance Run the conformance runner"
	@echo "  test-frontend   Run frontend milestone tests"
	@echo "  lint            Run the linter on all sources"
	@echo "  fmt             Format all sources"
	@echo "  fmt-check       Check formatting (CI-friendly)"
	@echo "  coverage        Generate and merge coverage"
	@echo "  docs            Generate documentation"
	@echo "  clean           Remove build artifacts"
	@echo "  help            Show this help"
