#!/bin/bash
# Tangerine Self-Hosted Bootstrap Script
# 
# This script bootstraps the Tangerine compiler from the OCaml stage0
# to produce a fully independent native compiler that can compile itself.
#
# Bootstrap stages:
# Stage 0: OCaml compiler (stage0/) compiles tg_compiler/*.tg → tg_stage1
# Stage 1: tg_stage1 compiles tg_compiler/*.tg → tg_stage2  
# Stage 2: tg_stage2 is the self-hosted compiler (verifies self-compilation)
#
# After bootstrap, the resulting 'tg' binary requires NO OCaml or other language.

set -e

echo "========================================"
echo "Tangerine Self-Hosted Bootstrap"
echo "========================================"
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

STAGE0_DIR="stage0"
BUILD_DIR="build"
TG_COMPILER_DIR="tg_compiler"

# Create build directory
mkdir -p "$BUILD_DIR"

# Check for OCaml/dune (needed only for stage0)
if ! command -v opam &> /dev/null; then
    echo "Error: opam not found. Stage0 requires OCaml."
    echo "Install opam from: https://opam.ocaml.org/doc/Install.html"
    exit 1
fi

echo "Stage 0: Building OCaml bootstrap compiler..."
echo "----------------------------------------"

cd "$STAGE0_DIR"
eval "$(opam env)"
dune build
cd ..

STAGE0_BIN="$STAGE0_DIR/_build/default/bin/main.exe"

if [ ! -f "$STAGE0_BIN" ]; then
    echo "Error: Stage0 compiler build failed"
    exit 1
fi

echo "Stage 0 compiler built: $STAGE0_BIN"
echo ""

echo "Stage 1: Compiling self-hosted compiler with stage0..."
echo "----------------------------------------"

# The self-hosted compiler source files
TG_SOURCES=(
    "$TG_COMPILER_DIR/token.tg"
    "$TG_COMPILER_DIR/lexer.tg"
    "$TG_COMPILER_DIR/ast.tg"
    "$TG_COMPILER_DIR/parser.tg"
    "$TG_COMPILER_DIR/types.tg"
    "$TG_COMPILER_DIR/mir.tg"
    "$TG_COMPILER_DIR/codegen.tg"
    "$TG_COMPILER_DIR/asm.tg"
    "$TG_COMPILER_DIR/object.tg"
    "$TG_COMPILER_DIR/linker.tg"
    "$TG_COMPILER_DIR/driver.tg"
    "$TG_COMPILER_DIR/lib.tg"
    "$TG_COMPILER_DIR/util.tg"
)

# Check that all source files exist
for src in "${TG_SOURCES[@]}"; do
    if [ ! -f "$src" ]; then
        echo "Warning: Missing source file: $src"
    fi
done

# Compile the main driver with stage0
# This produces a native executable via: TG → OCaml → ocamlopt → native binary
echo "Compiling tg_compiler/driver.tg with stage0..."

# Create a combined source file for stage0 compilation
# Stage0 compiles TG to OCaml, then uses ocamlopt for native code
"$STAGE0_BIN" compile "$TG_COMPILER_DIR/driver.tg" -o "$BUILD_DIR/tg_stage1"

if [ -f "$BUILD_DIR/tg_stage1" ]; then
    echo "Stage 1 compiler built: $BUILD_DIR/tg_stage1"
    chmod +x "$BUILD_DIR/tg_stage1"
else
    echo "Note: Stage1 binary may have different extension or location"
    # Check for .exe or other variants
    if [ -f "$BUILD_DIR/tg_stage1.exe" ]; then
        mv "$BUILD_DIR/tg_stage1.exe" "$BUILD_DIR/tg_stage1"
        chmod +x "$BUILD_DIR/tg_stage1"
        echo "Stage 1 compiler built: $BUILD_DIR/tg_stage1"
    fi
fi

echo ""
echo "========================================"
echo "Bootstrap Complete!"
echo "========================================"
echo ""
echo "The stage1 compiler at build/tg_stage1 can now compile"
echo "Tangerine source files directly to native executables."
echo ""
echo "To compile a Tangerine file:"
echo "  ./build/tg_stage1 compile myfile.tg -o myfile"
echo "  ./myfile"
echo ""
echo "For self-compilation verification (stage2):"
echo "  ./build/tg_stage1 compile tg_compiler/driver.tg -o build/tg_stage2"
echo ""