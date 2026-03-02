# Tangerine Stage0 Bootstrap Compiler

This is the stage0 bootstrap compiler for the Tangerine programming language, written in OCaml.

## Overview

The stage0 compiler is a minimal implementation of the Tangerine compiler used to bootstrap the self-hosted compiler. It supports the core language features needed to compile the full Tangerine compiler.

## Building

### Prerequisites

- OCaml 4.14 or later
- opam (OCaml package manager)
- dune 3.0 or later

### Setup

```bash
# Install OCaml and opam (macOS)
brew install opam
opam init
eval $(opam env)

# Install dependencies
cd stage0
opam install . --deps-only

# Build the compiler
make build
```

### Running

```bash
# Compile a file
dune exec -- tgc hello.tg

# Dump the AST
dune exec -- tgc --dump-ast hello.tg

# Dump the MIR
dune exec -- tgc --dump-mir hello.tg
```

## Architecture

```
stage0/
├── lib/                    # Compiler library
│   ├── ast.ml             # Abstract Syntax Tree
│   ├── diagnostics.ml     # Error reporting
│   ├── driver.ml          # Compilation driver
│   ├── env.ml             # Type environment
│   ├── lexer.mll          # Lexer (OCamllex)
│   ├── location.ml        # Source locations
│   ├── lower.ml           # AST to MIR lowering
│   ├── mir.ml             # Mid-level IR
│   ├── parser.mly         # Parser (Menhir)
│   ├── source.ml          # Source file handling
│   ├── tangerine.ml       # Library interface
│   ├── typecheck.ml       # Type checker
│   └── types.ml           # Type representation
├── bin/                    # CLI executable
│   └── main.ml            # CLI entry point
├── test/                   # Tests
│   └── test_tangerine.ml  # Unit tests
├── dune-project            # Dune project file
└── Makefile               # Build commands
```

## Compilation Pipeline

1. **Lexing** (`lexer.mll`): Tokenizes source files
2. **Parsing** (`parser.mly`): Builds the AST
3. **Type Checking** (`typecheck.ml`): Infers and checks types
4. **MIR Lowering** (`lower.ml`): Converts AST to MIR
5. **Code Generation**: (TODO) Generate native code

## Supported Language Features

- [x] Basic types (Int, Float, Bool, String, Char, Unit)
- [x] Functions with type annotations
- [x] Structs and enums
- [x] Pattern matching (match/when)
- [x] Control flow (if/elsif/else, while, for, loop)
- [x] Closures
- [x] References and borrows
- [x] Traits and implementations
- [x] Modules
- [x] Capabilities (parsing only)
- [x] Effects (parsing only)
- [x] Contracts (pre/post/invariant)
- [x] Guard clauses
- [ ] Generics (partial)
- [ ] Borrow checking
- [ ] Code generation

## Testing

```bash
# Run all tests
make test

# Run specific test
dune exec ./test/test_tangerine.exe
```

## Development

```bash
# Watch for changes
make watch

# Format code
make fmt

# Build documentation
make doc
```

## License

This compiler is part of the Tangerine project. See the root LICENSE file for details.
