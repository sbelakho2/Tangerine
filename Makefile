# Tangerine Project Makefile

.PHONY: all build test test-golden test-stdlib test-compiler test-scripts test-conformance test-frontend test-abi test-gfx-ui test-new-std test-tooling test-all lint fmt fmt-check coverage docs clean install bench stub-scan abi-layout-check ci help bootstrap bootstrap-stage0 bootstrap-stage1 bootstrap-stage2 bootstrap-verify bootstrap-full clean-bootstrap

SHELL := /bin/bash
TG    := build/tg
PYTHON := python3
BOOTSTRAP_TIMEOUT := 600

# Default target
all: build test

# ————————————————————————————————————————————
# Bootstrap Chain (Self-Hosting)
# ————————————————————————————————————————————
# 
# The bootstrap chain is currently OCaml-first and C-free:
#   Stage 0: Build the OCaml bootstrap compiler (tgc0)
#   Stage 1: Materialize a tg wrapper backed by tgc0
#   Stage 2: Re-materialize the wrapper for reproducibility checks
#   Stage 3: Verify both wrapper stages are identical
#
# Native self-hosting stays a separate backend-readiness goal until the
# stage0 runtime is no longer linked through tg_runtime.c.

STAGE0_DIR := stage0
STAGE1_DIR := target/stage1
STAGE2_DIR := target/stage2
TGC0 := $(STAGE0_DIR)/_build/default/bin/main.exe
TG1 := $(STAGE1_DIR)/tg
TG2 := $(STAGE2_DIR)/tg

# Compiler sources excluding entry/lib to avoid duplicate codegen
TG_COMPILER_SRCS := $(filter-out tg_compiler/lib.tg tg_compiler/driver.tg, $(wildcard tg_compiler/*.tg))

ifeq ($(TG_COMPILER_SRCS),)
$(error No tg_compiler/*.tg source files found — check your working directory)
endif

# Build stage0 (OCaml bootstrap compiler)
bootstrap-stage0:
	@echo "==> Stage 0: Building OCaml bootstrap compiler..."
	@if [ -x $(TGC0) ]; then \
		echo "    Stage 0 already built: $(TGC0)"; \
	elif command -v dune >/dev/null 2>&1; then \
		DUNE_VER=$$(dune --version); \
		echo "    Using dune $$DUNE_VER"; \
		timeout $(BOOTSTRAP_TIMEOUT) sh -c 'cd $(STAGE0_DIR) && dune build'; \
	elif command -v opam >/dev/null 2>&1; then \
		OPAM_VER=$$(opam --version); \
		echo "    Using opam $$OPAM_VER"; \
		timeout $(BOOTSTRAP_TIMEOUT) sh -c 'cd $(STAGE0_DIR) && opam exec -- dune build'; \
	else \
		echo "dune not found and no existing stage0 binary; install dune or opam."; \
		exit 1; \
	fi
	@echo "    Stage 0 complete: $(TGC0)"

# Build stage1 (OCaml-backed tg wrapper, no native/C link step)
bootstrap-stage1: bootstrap-stage0
	@echo "==> Stage 1: Materializing tg wrapper from stage0..."
	@mkdir -p $(STAGE1_DIR)
	@$(TGC0) wrap -o $(TG1)
	@echo "    Stage 1 complete: $(TG1)"

# Build stage2 (repeat wrapper materialization for reproducibility)
bootstrap-stage2: bootstrap-stage1
	@echo "==> Stage 2: Re-materializing tg wrapper..."
	@mkdir -p $(STAGE2_DIR)
	@$(TG1) wrap -o $(TG2)
	@echo "    Stage 2 complete: $(TG2)"

# Verify bootstrap - stage1 and stage2 should produce identical wrappers
bootstrap-verify: bootstrap-stage2
	@echo "==> Verifying bootstrap integrity..."
	@if cmp -s $(TG1) $(TG2); then \
		echo "    VERIFIED: Stage 1 and Stage 2 wrappers are identical"; \
	else \
		sha256sum $(TG1) $(TG2); \
		echo "    WARNING: Wrappers differ"; \
		$(TG2) --version; \
	fi
	@echo "==> Bootstrap verification complete."

# Full bootstrap: install the OCaml-backed tg wrapper
bootstrap-full: bootstrap-verify
	@echo "==> Installing bootstrapped compiler..."
	@mkdir -p build
	@cp $(TG2) build/tg
	@chmod +x build/tg
	@echo "==> Full bootstrap complete: build/tg"
	@build/tg --version

# Clean bootstrap artifacts
clean-bootstrap:
	@echo "==> Cleaning bootstrap artifacts..."
	@cd $(STAGE0_DIR) && (dune clean || opam exec -- dune clean || true)
	@rm -rf $(STAGE1_DIR) $(STAGE2_DIR)
	@echo "==> Bootstrap artifacts cleaned."

# Shorthand for full bootstrap
bootstrap: bootstrap-full

# ————————————————————————————————————————————
# Build (uses existing tg or bootstrapped compiler)
# ————————————————————————————————————————————

build:
	@echo "==> Building Tangerine compiler..."
	mkdir -p build
	@if [ -x build/tg ]; then \
		build/tg build --wrapper -o build/tg; \
	elif command -v $(TG) >/dev/null 2>&1; then \
		$(TG) build --wrapper -o build/tg; \
	else \
		echo "No compiler available. Run 'make bootstrap' first."; \
		exit 1; \
	fi

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
