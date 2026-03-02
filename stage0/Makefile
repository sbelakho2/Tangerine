# Tangerine Stage0 Compiler Makefile

.PHONY: all build clean test fmt install uninstall

DUNE = dune

all: build

# Build the compiler
build:
	$(DUNE) build

# Clean build artifacts
clean:
	$(DUNE) clean

# Run tests
test:
	$(DUNE) runtest

# Format code
fmt:
	$(DUNE) fmt

# Install the compiler
install:
	$(DUNE) install

# Uninstall the compiler
uninstall:
	$(DUNE) uninstall

# Build documentation
doc:
	$(DUNE) build @doc

# Open documentation in browser
doc-open: doc
	open _build/default/_doc/_html/index.html

# Run the compiler in development mode
run:
	$(DUNE) exec -- tgc

# Parse a file (for debugging)
parse:
	$(DUNE) exec -- tgc --dump-ast $(FILE)

# Dump MIR (for debugging)
mir:
	$(DUNE) exec -- tgc --dump-mir $(FILE)

# Watch mode for development
watch:
	$(DUNE) build --watch

# Check all code without building
check:
	$(DUNE) build @check

# Install dependencies
deps:
	opam install . --deps-only --with-test

# Lock dependencies
lock:
	opam lock .

.DEFAULT_GOAL := build
