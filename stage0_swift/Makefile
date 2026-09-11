# Tangerine Stage 0 Bootstrap Compiler — Makefile
#
# Usage:
#   make            Build release binary (required for selfhost/compile)
#   make debug      Build debug binary (faster compile, slower runtime)
#   make test       Run unit tests
#   make selfhost   Run self-host build (release mode)
#   make clean      Clean build artifacts
#
# The release build is REQUIRED for Phase 3 (interpret) because the
# interpreter needs to execute ~3000+ functions and debug mode is too slow.

.PHONY: all debug release test selfhost compile clean

SWIFT_BUILD = swift build
SWIFT_TEST = swift test

all: release

debug:
	$(SWIFT_BUILD)

release:
	$(SWIFT_BUILD) -c release

test:
	$(SWIFT_BUILD)
	.build/debug/TangerineTestRunner ..

selfhost: release
	cd .. && stage0_swift/.build/release/tg_stage0 selfhost

compile: release
	@echo "Usage: make compile FILE=path/to/file.tg"
	@echo "  or:  stage0_swift/.build/release/tg_stage0 compile <file> -o <output>"

clean:
	$(SWIFT_BUILD) --clean