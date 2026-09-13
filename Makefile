# Tangerine Makefile — the GFX/UI lane targets the CI lanes invoke.
#
# The tree had no Makefile while `.woodpecker/verify-gfx.yaml` (and, before
# it, the GitHub `gfx-ui` jobs) ran `make test-gfx-ui`, `make stub-scan` and
# `make abi-layout-check`. This file restores those targets on top of the
# repo's real tooling:
#
#   gfx-ui-build      GFX/UI module compilation check (`tg check` over the
#                     14 production modules)
#   test-gfx-ui       the historical name for the compilation check (the
#                     former GitHub step "GFX/UI module compilation check")
#   gfx-ui-test       the lane's unit/integration/ABI/consistency suites
#   gfx-ui-visual     golden visual-regression + determinism/replay + fuzz
#   gfx-ui-gate       local aggregate over every GFX/UI check (CI
#                     aggregates through the Woodpecker step graph instead)
#   stub-scan         forbidden stub markers in the production std modules
#   abi-layout-check  ABI module check (`std/backend_abi.tg`)
#
# The former `test-gfx-ui` recipe also ran `scripts/conformance_gates.tg`;
# that runner no longer exists in the tree — its conformance assertions are
# the lane's ABI-conformance and consistency suites (tests/abi/,
# tests/consistency/), which gfx-ui-test runs and the CI lane runs.
#
# `TG` defaults to build/tg — the stage3 artifact the lanes materialize
# before running (restore-stage3 + materialize-tg).
# Override with e.g. `make TG=build/tg_stage3 test-gfx-ui`.

SHELL := /bin/bash
TG ?= build/tg

.DEFAULT_GOAL := help

.PHONY: help gfx-ui-build test-gfx-ui gfx-ui-test gfx-ui-visual gfx-ui-gate stub-scan abi-layout-check

# The GFX/UI production modules (the former test-gfx-ui check set).
GFX_UI_MODULES := \
	std/gfx_errors.tg std/geom.tg std/app.tg std/gfx.tg std/gfx_gpu.tg \
	std/image.tg std/text.tg std/ui_toolkit.tg std/platform.tg std/anim.tg \
	std/compositor.tg std/assets.tg std/accessibility.tg std/backend_abi.tg

help:
	@echo "GFX/UI targets:"
	@echo "  test-gfx-ui      GFX/UI module compilation check"
	@echo "  gfx-ui-test      unit/integration/ABI/consistency suites"
	@echo "  gfx-ui-visual    golden visual-regression + determinism + fuzz"
	@echo "  gfx-ui-gate      aggregate over all GFX/UI checks"
	@echo "  stub-scan        forbidden stub markers in production std modules"
	@echo "  abi-layout-check ABI layout check (std/backend_abi.tg)"
	@echo ""
	@echo "TG=$(TG) (override with make TG=/path/to/tg)"

# Fail fast with an actionable message when the CI-materialized compiler is
# absent; `make -n` still succeeds (recipes are printed, not executed).
define require_tg
	@test -x $(TG) || { \
		echo "error: compiler not executable: $(TG)"; \
		echo "       materialize the stage3 artifact (restore-stage3 + materialize-tg) or pass TG=<path>"; \
		exit 1; \
	}
endef

# ————————————————————————————————————————————
# GFX/UI module compilation check (§20)
# ————————————————————————————————————————————

gfx-ui-build:
	$(require_tg)
	@echo "==> Checking GFX/UI modules compile..."
	@for f in $(GFX_UI_MODULES); do \
		echo "    $(TG) check $$f"; \
		$(TG) check $$f || exit 1; \
	done
	@echo "==> GFX/UI modules OK."

test-gfx-ui: gfx-ui-build
	@echo "==> GFX/UI module compilation check passed."

# ————————————————————————————————————————————
# GFX/UI test suites (the lane's unit/integration/ABI/consistency steps)
# ————————————————————————————————————————————

gfx-ui-test:
	$(require_tg)
	@echo "==> Running GFX/UI unit/integration/ABI/consistency suites..."
	$(TG) test tests/unit/test_geom.tg
	$(TG) test tests/unit/test_events.tg
	$(TG) test tests/unit/test_paint.tg
	$(TG) test tests/unit/test_text.tg
	$(TG) test tests/unit/test_capability.tg
	$(TG) test tests/integration/test_pipelines.tg
	$(TG) test tests/abi/test_abi_conformance.tg
	$(TG) test tests/consistency/test_consistency.tg
	@echo "==> GFX/UI suites passed."

# ————————————————————————————————————————————
# GFX/UI visual regression (golden + determinism + fuzz)
# ————————————————————————————————————————————

gfx-ui-visual:
	$(require_tg)
	@echo "==> Running GFX/UI visual-regression suites..."
	$(TG) test tests/golden/test_visual_regression.tg
	$(TG) test tests/determinism/test_replay.tg
	$(TG) test tests/fuzz/test_fuzz.tg
	@echo "==> GFX/UI visual-regression suites passed."

# Local aggregate: every GFX/UI check in one invocation. The CI lane
# aggregates through its step graph (the gfx-ui step, the gfx-ui-visual
# step and the gfx-ui-gate step) so the suites do not run twice.
gfx-ui-gate: gfx-ui-build stub-scan abi-layout-check gfx-ui-test gfx-ui-visual
	@echo "==> All GFX/UI gates passed."

# ————————————————————————————————————————————
# Stub scan (§20 — forbidden stub markers)
# ————————————————————————————————————————————
# Forbidden-marker scan over the production std modules. The two modules
# that IMPLEMENT the marker scanners — std/audit.tg (the MNT-001 stub
# predicate) and std/lint.tg (the todo-comment rule) — must contain the
# literal marker spellings they detect, so they are the only exclusions
# (exact paths, no wildcards).
stub-scan:
	@echo "==> Scanning for forbidden stub markers in production modules..."
	@matches="$$(grep -rnE 'TODO|FIXME|STUB|unimplemented|todo!' std/*.tg \
		| grep -vE '^std/(audit|lint)\.tg:' || true)"; \
	if [ -n "$$matches" ]; then \
		printf '%s\n' "$$matches"; \
		echo "ERROR: Stub markers found in std/ — remove before release"; \
		exit 1; \
	fi
	@echo "==> No stub markers found."

# ————————————————————————————————————————————
# ABI layout check (§20)
# ————————————————————————————————————————————

abi-layout-check:
	$(require_tg)
	@echo "==> Checking ABI struct layout consistency..."
	$(TG) check std/backend_abi.tg
	@echo "==> ABI layout check passed."
