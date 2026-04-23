# Tangerine Compiler Pipeline Manifest
## Version 1.0.0

### Purpose
Canonical reference for the compiler's stage order, responsibilities, boundaries,
input/output artifacts, and trust levels. This document is the single source of truth
for Stage 2 of the stabilization checklist.

---

## Stage Order

The compiler executes the following stages in strict sequence.
Each stage runs to completion before the next begins.

| # | Stage | Entry Point | Source File |
|---|-------|-------------|-------------|
| 1 | Lexing | `tokenize(source)` | lexer.tg |
| 2 | Parsing | `parse(lex_result)` | parser.tg |
| 3 | Macro Expansion | `expand_macros(ast)` | parser.tg |
| 4 | Type Checking | `type_check(&ast)` | types.tg |
| 5 | Borrow Checking | `borrow_check(&ast)` | borrow_check.tg |
| 6 | MIR Lowering | `lower_to_mir(&ast)` | mir.tg |
| 7 | Monomorphization | `monomorphize_program(&mut mir, &mut mono_cache)` | trait_resolve.tg |
| 8 | PGO Instrumentation | `instrument_for_pgo(&mut mir)` | mir.tg |
| 9 | PGO Profile Load | `apply_pgo_profile(&mut mir, profile)` | mir.tg |
| 10 | MIR Optimization | `optimize_mir(&mut mir, opt_level)` | mir.tg |
| 11 | Code Generation | `generate_code(target, mir)` | codegen.tg |
| 12 | Object Generation | `generate_object_file(code, target)` | object.tg |
| 13 | Linking | `link(objects, target)` | linker.tg |

### Early Exit Points

- `--check` mode: exits after Stage 2 (Parsing). No lowering or codegen.
- `--emit-mir` mode: exits after Stage 10 (MIR Optimization). No codegen.
- Any error in stages 2, 4, or 5 causes a hard stop.

### Alternative Pipelines

| Pipeline | Stages | Entry |
|----------|--------|-------|
| `compile()` | 1–13 | lib.tg |
| `check()` | 1–5 | lib.tg |
| `parse_only()` | 1–2 | lib.tg |

---

## Single Responsibility Per Stage

| Stage | Responsibility | MUST NOT |
|-------|---------------|----------|
| Lexing | Convert source text to token stream | Resolve names, check types |
| Parsing | Convert tokens to AST | Infer types, resolve imports |
| Macro Expansion | Replace macro invocations with expanded AST | Introduce new types, modify semantics |
| Type Checking | Infer and validate types, generics, bounds | Mutate ownership, emit code |
| Borrow Checking | Validate ownership, moves, borrows, lifetimes | Modify types, emit code |
| MIR Lowering | Convert typed AST to control-flow graph (SSA) | Optimize, select instructions |
| Monomorphization | Instantiate generic functions with concrete types | Re-type-check, re-borrow-check |
| PGO Instrumentation | Insert profiling counters in MIR | Optimize, change semantics |
| PGO Profile Load | Apply profile data to MIR annotations | Optimize, change semantics |
| MIR Optimization | Transform MIR for performance (DCE, inlining) | Change observable semantics |
| Code Generation | Select instructions, allocate registers | Link, generate object headers |
| Object Generation | Emit object file (ELF/Mach-O/PE) | Link multiple objects |
| Linking | Resolve symbols, patch relocations, emit executable | Re-codegen, re-optimize |

---

## Input/Output Artifacts

| Stage | Input | Output | Type |
|-------|-------|--------|------|
| Lexing | `String` (source text) | `Vec[Token]` | LexResult |
| Parsing | `LexResult` | `Program` (AST) | Program |
| Macro Expansion | `Program` | `Program` (macros removed) | Program |
| Type Checking | `Program` | `Program` (type-annotated) + type errors | Program |
| Borrow Checking | `Program` (typed) | `Program` (ownership-verified) + borrow errors | Program |
| MIR Lowering | `Program` (typed, borrow-checked) | `MirProgram` (CFG, SSA) | MirProgram |
| Monomorphization | `MirProgram` | `MirProgram` (generic-free) | MirProgram (mutated) |
| PGO Instrumentation | `MirProgram` | `MirProgram` (instrumented) | MirProgram (mutated) |
| PGO Profile Load | `MirProgram` + profile file | `MirProgram` (annotated) | MirProgram (mutated) |
| MIR Optimization | `MirProgram` | `MirProgram` (optimized) | MirProgram (mutated) |
| Code Generation | `MirProgram` + target triple | `CodeBuffer` (instructions, relocations) | CodeBuffer |
| Object Generation | `CodeBuffer` | `Vec[u8]` (object file bytes) | Bytes |
| Linking | `Vec[u8]` (objects) + target | Executable binary | File |

---

## Trust Levels

| Artifact | Trust Level | Rationale |
|----------|-------------|-----------|
| Source text | UNTRUSTED | User input |
| Token stream | UNTRUSTED | Lexer may produce error tokens |
| Parsed AST | VERIFIED at boundary | Parser emits diagnostics; hard stop on error |
| Macro-expanded AST | UNVERIFIED | Expansion not re-validated after transform |
| Type-annotated AST | VERIFIED at boundary | Type checker emits diagnostics; hard stop on error |
| Borrow-checked AST | VERIFIED at boundary | Borrow checker emits diagnostics; hard stop on error |
| MIR (lowered) | UNVERIFIED | No post-lowering validation |
| MIR (monomorphized) | UNVERIFIED | No post-mono validation |
| MIR (optimized) | UNVERIFIED | No post-optimization validation |
| CodeBuffer | UNVERIFIED | No post-codegen validation |
| Object bytes | UNVERIFIED | Linker will fail on structural errors |
| Executable | UNVERIFIED | Runtime behavior is the final arbiter |

### Trust Gap Analysis

Three artifacts transition from VERIFIED to UNVERIFIED without validation:

1. **Macro expansion**: The expanded AST is not re-parsed or re-validated.
   Recommendation: Add a post-expansion AST integrity check.

2. **MIR lowering**: Lowered MIR is not validated against MIR invariants.
   Recommendation: Add MIR verifier (Stage 5 work).

3. **MIR optimization**: Optimized MIR is not re-verified.
   Recommendation: Add post-optimization MIR verifier (Stage 5 work).

---

## Cross-Stage Work Leakage Audit

| Issue | Location | Severity | Status |
|-------|----------|----------|--------|
| Macro expansion happens post-parse, loses source provenance | driver.tg Phase 2.5 | Medium | DOCUMENTED — macro declarations are preserved as inert AST in bootstrap; stage0 does not expand them |
| PGO profile load failure is a silent warning, not a hard error | driver.tg line 817 | Low | DOCUMENTED — PGO not in bootstrap subset |
| Name resolution not shown as separate stage in driver | driver.tg | Info | DOCUMENTED — resolver.tg exists but is invoked within type_check |

### Resolution

In the bootstrap subset, none of the problematic cross-stage leakage paths are reachable:
- Macro declarations are preserved as inert AST, and stage0 lowers macro invocations explicitly without executing user macro bodies.
- PGO is not part of the bootstrap subset.
- Name resolution within type_check is a design choice, not a leak.

No silent cross-stage work leakage exists in the bootstrap pipeline.

---

## Fallback Path Audit

| Potential Fallback | Present? | Status |
|-------------------|----------|--------|
| Silent default typing fallback | No | Parser and type checker fail hard |
| Symbol invention/recovery | No | Unresolved symbols are errors |
| Placeholder IR emission | No | MIR lowering does not emit placeholders |
| Ownership weakening | No | Borrow checker is strict |
| PGO profile load silent fallback | Yes (warning only) | Not in bootstrap subset |

No fallback paths bypass normal stages in the bootstrap subset.

---

## Stage0 (Swift) Bootstrap Pipeline

The stage0 Swift compiler implements the self-hosted bootstrap pipeline:

| # | Stage | Status | File | Description |
|---|-------|--------|------|-------------|
| 1 | Lexing | ✅ IMPLEMENTED | Lexer.swift | Token stream from source text |
| 2 | Parsing | ✅ IMPLEMENTED | Parser.swift | AST from tokens |
| 2.5 | Subset Check | ✅ IMPLEMENTED | SubsetChecker.swift | Validates bootstrap subset |
| 3 | MIR Lowering | ✅ IMPLEMENTED | MIRLowering.swift | AST → MIR (control-flow graph) |
| 4 | MIR Interpretation | ✅ IMPLEMENTED | MIRInterpreter.swift | Executes MIR directly |
| 5 | Bootstrap Profiling | ✅ IMPLEMENTED | BootstrapProfile.swift | Minimal stdlib for self-host |
| 6 | Self-Host Execution | ✅ IMPLEMENTED | main.swift (cmdSelfHost) | Interprets compiler to compile itself |
| 7 | Native Compilation | ✅ IMPLEMENTED | main.swift (cmdCompile) | Interpreted compiler emits Mach-O/ELF |

### Stage0 Pipeline Commands

| Command | Pipeline Stages | Description |
|---------|----------------|-------------|
| `lex <file>` | 1 | Lex only |
| `parse <file>` | 1–2 | Parse and print summary |
| `check <file>` | 1–2.5 | Parse + subset check |
| `lower <file>` | 1–3 | Parse + lower to MIR |
| `interpret <file>` | 1–4 | Full interpret pipeline |
| `selfhost` | 1–6 | Self-hosted bootstrap (release build required) |
| `compile <file>` | 1–7 | Compile .tg to native binary |

### Build Requirements

**IMPORTANT**: The `selfhost` and `compile` commands require a **release build** (`swift build -c release`).
The debug build is too slow for the MIR interpreter, which needs to execute ~3000+ functions.
Use `make release` or `make selfhost` from the `stage0_swift/` directory.
