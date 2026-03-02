# Tangerine Project Makefile

.PHONY: all build test test-golden test-stdlib test-compiler test-scripts test-conformance test-frontend test-abi test-gfx-ui test-new-std test-tooling test-all lint fmt fmt-check coverage docs clean install bench stub-scan abi-layout-check ci help

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
	mkdir -p build
	$(TG) build tg_compiler/driver.tg -o build/tg

# ————————————————————————————————————————————
# Tests
# ————————————————————————————————————————————

test: test-golden test-stdlib test-compiler test-scripts

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

test-scripts:
	@echo "==> Running script tests..."
	$(PYTHON) -m unittest scripts.tests.test_scripts

test-conformance:
	@echo "==> Running conformance suite..."
	$(TG) test golden/conformance_runner.tg

test-frontend:
	@echo "==> Running frontend milestone tests..."
	for i in 01 02 03 04 05 06; do \
		$(TG) test golden/frontend_$$i.tg; \
	done

test-abi:
	@echo "==> Running ABI/FFI tests..."
	$(TG) test golden/abi_ffi_tests.tg

test-new-std:
	@echo "==> Checking new std modules compile..."
	$(TG) check std/math.tg
	$(TG) check std/random.tg
	$(TG) check std/path.tg
	$(TG) check std/csv.tg
	$(TG) check std/yaml.tg
	$(TG) check std/cbor.tg
	$(TG) check std/msgpack.tg
	$(TG) check std/signal.tg
	$(TG) check std/auth.tg
	$(TG) check std/config.tg
	$(TG) check std/debug.tg
	$(TG) check std/semver.tg
	$(TG) check std/wasm.tg
	@echo "==> New std modules OK."

test-tooling:
	@echo "==> Checking tooling modules compile..."
	$(TG) check tg_compiler/pkg_manager.tg
	$(TG) check tg_compiler/registry.tg
	$(TG) check tg_compiler/template.tg
	$(TG) check tg_compiler/bindgen.tg
	$(TG) check tg_compiler/cross_compile.tg
	$(TG) check tg_compiler/wasm_target.tg
	$(TG) check tg_compiler/debugger.tg
	@echo "==> Tooling modules OK."

test-all: test test-conformance test-frontend test-abi test-gfx-ui test-new-std test-tooling
	@echo "==> All tests passed."

# ————————————————————————————————————————————
# GFX/UI Module Tests (§20)
# ————————————————————————————————————————————

test-gfx-ui:
	@echo "==> Checking GFX/UI modules compile..."
	$(TG) check std/gfx_errors.tg
	$(TG) check std/geom.tg
	$(TG) check std/app.tg
	$(TG) check std/gfx.tg
	$(TG) check std/gfx_gpu.tg
	$(TG) check std/image.tg
	$(TG) check std/text.tg
	$(TG) check std/ui_toolkit.tg
	$(TG) check std/platform.tg
	$(TG) check std/anim.tg
	$(TG) check std/compositor.tg
	$(TG) check std/assets.tg
	$(TG) check std/accessibility.tg
	$(TG) check std/backend_abi.tg
	@echo "==> Running conformance gates..."
	$(TG) run scripts/conformance_gates.tg
	@echo "==> GFX/UI module tests passed."

# ————————————————————————————————————————————
# Stub Scan (§20 — forbidden stub markers)
# ————————————————————————————————————————————

stub-scan:
	@echo "==> Scanning for forbidden stub markers in production modules..."
	@! grep -rn 'TODO\|FIXME\|STUB\|unimplemented\|todo!' std/*.tg || \
		(echo "ERROR: Stub markers found in std/ — remove before release" && exit 1)
	@echo "==> No stub markers found."

# ————————————————————————————————————————————
# ABI Layout Regression Check (§20)
# ————————————————————————————————————————————

abi-layout-check:
	@echo "==> Checking ABI struct layout consistency..."
	$(TG) check std/backend_abi.tg
	@echo "==> ABI layout check passed."

ci: lint fmt-check test-all stub-scan abi-layout-check coverage
	@echo "==> CI pipeline completed."

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
# Install
# ————————————————————————————————————————————

PREFIX ?= /usr/local

install: build
	@echo "==> Installing to $(PREFIX)/bin..."
	install -d $(PREFIX)/bin
	install -m 755 build/tg $(PREFIX)/bin/tg

# ————————————————————————————————————————————
# Benchmarks
# ————————————————————————————————————————————

bench:
	@echo "==> Running benchmarks..."
	$(TG) bench golden/stdlib_tests.tg
	$(TG) bench golden/compiler_module_tests.tg
	$(TG) bench golden/features_01.tg

# ————————————————————————————————————————————
# Clean
# ————————————————————————————————————————————

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf build/tg target/cqs/coverage/merged.tgcov
	rm -rf target/doc
	find target -type f -name '*.o' -delete 2>/dev/null || true

# ————————————————————————————————————————————
# Help
# ————————————————————————————————————————————

help:
	@echo "Tangerine Makefile targets:"
	@echo "  all             Build and run tests (default)"
	@echo "  build           Compile the Tangerine compiler"
	@echo "  test            Run golden + stdlib + compiler tests"
	@echo "  test-scripts    Run Python script tests"
	@echo "  test-all        Run every test suite including conformance"
	@echo "  test-conformance Run the conformance runner"
	@echo "  test-frontend   Run frontend milestone tests"
	@echo "  lint            Run the linter on all sources"
	@echo "  fmt             Format all sources"
	@echo "  fmt-check       Check formatting (CI-friendly)"
	@echo "  coverage        Generate and merge coverage"
	@echo "  docs            Generate documentation"
	@echo "  clean           Remove build artifacts"
	@echo "  install         Install binary to PREFIX/bin (default /usr/local)"
	@echo "  bench           Run benchmarks"
	@echo "  test-new-std    Check new std modules compile"
	@echo "  test-tooling    Check tooling modules compile"
	@echo "  help            Show this help"
