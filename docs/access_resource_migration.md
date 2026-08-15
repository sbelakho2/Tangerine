# Access + Resource Model — Bootstrap Migration Plan

Authoritative implementation plan for the Tangerine memory-model redesign.
The compiler is self-hosting; the bootstrap chain (stage0 Swift interpreter →
stage1 → stage2 → stage3, requiring stage2 == stage3 and clean-root
determinism) must never break. Every change must keep the kernel parse-clean
and type-clean at every commit.

## Verification gate (mandatory for every change)

```
# Parse gate (fast, ~60-90s): kernel must parse 36/36 OK
timeout 110 ./stage0_swift/.build/release/tg_stage0 compile tg_compiler/<file>.tg -o /tmp/pt 2>&1 | grep -E "Parsed:|FAIL"

# Type gate (~10-12 min): kernel must type-check clean.
# Run in background, then poll. "Type check failed" = errors.
# "Borrow checking..." printed = type check passed (do NOT wait for the
# borrow check; it takes ~3 hours and is being deleted by this migration).
timeout 1500 ./stage0_swift/.build/release/tg_stage0 compile tg_compiler/driver.tg -o /tmp/verify_out > /tmp/verify.log 2>&1
# then: grep -E "Type check failed|Borrow checking|error\[" /tmp/verify.log
```

The machine has 18 cores; the interpreter is single-threaded. Parallel
verification gates are fine. NEVER wait for the borrow check to complete.

## Design (summary)

Two independent dimensions:
- **Access convention** per parameter/receiver: `let` (observe), `inout`
  (exclusive mutation), `sink` (transfer/consume), `set` (initialize dead
  storage). No safe first-class references: `&x` is syntax for an access
  marker on a place, never a reference value.
- **Nominal kind**: `value` (default, copyable), `resource` (noncopyable,
  deterministic deinit at scope exit, viral through containment),
  `capability` (strict linear authority: exactly-once transfer, cannot be
  copied, fabricated, or silently abandoned).

The borrow checker is DELETED; replaced by (a) an access-overlap checker
(per-call access paths: read/inout/sink/set, reject overlapping incompatible
accesses, static disjointness for fixed struct fields) and (b) a resource
state checker (Uninitialized/Live/Consumed/MaybeLive dataflow over the CFG).

## Implementation order (waves)

1. [P0 bugs] stable_ids init; struct-literal required-field completeness;
   codegen O(1) type index; strict concrete layout API.
2. [Additive structures] `AccessConvention` (ast.tg), `TypeKind`
   (types.tg) — added WITHOUT changing any existing syntax or semantics.
3. [Stage0 Swift syntax] `var`, `inout`, `sink`, `set`, `resource`,
   `deinit` tokens; `Param.convention: AccessConvention`; parser accepts
   both legacy (`&mut x`, `&T`, `move`) and new syntax, normalizing legacy
   to the new internal representation. Stage0: Token.swift, Lexer.swift,
   AST.swift, Parser.swift, ASTDumper.swift, ASTVerifier.swift,
   MIR.swift, MIRLowering.swift, MIRInterpreter.swift, SubsetChecker,
   StableIDs, CompilerCanary.
4. [Native lexer/parser] same syntax in tg_compiler/token.tg, lexer.tg,
   parser.tg; normalization `&mut T→inout T`, `&T→let T`, `move→sink`.
5. [TypedProgram] `struct TypedProgram { ast, resolutions, expr_types:
   Map[NodeId, Type], call_targets: Map[NodeId, DefId],
   field_targets: Map[NodeId, FieldId], access_effects,
   type_kinds }`; resolver+type checker produce it; MIR lowering consumes
   it (no re-inference). DefId = (module, index) instead of String keys;
   deterministic symbol interning.
6. [Access checker] tg_compiler/access_check.tg: AccessPath
   (root LocalId + projections), AccessEffect (Read/Modify/Consume/
   Initialize), per-call overlap test, sink consumption marking.
   Delete tg_compiler/borrow_check.tg; remove Phase 4 from driver.tg;
   remove borrow_check.tg from bootstrap/compiler_kernel.manifest.
7. [Resource checker] resource availability dataflow over CFG.
8. [MIR] MirRead/MirConsume; MirCallArg{effect, value}; MirDeinit
   (distinguish auto deinit / explicit consume / unsafe raw free);
   remove MirRef/MirRefMut/MirDeref for safe places (ProjRawDeref only).
9. [Collections] iteration becomes projected access (`for item in items`
   = let projection, no clone; `for inout item in &items`; `for sink
   item in items`); subscripts are projections; COW backing storage for
   String/Array/Map/Set.
10. [Core stdlib] rewrite std/core.tg: Copyable trait (`def copy -> Self`),
    Eq with value params, deinit; String/Vec/Map inout APIs.
11. [Compiler source migration] rewrite tg_compiler/*.tg to let/var/inout/
    sink/set/resource syntax; allocators/FFI as resources; caps as linear
    capabilities; async/thread/sync Transferable/Shareable.
12. [Kernel shrink] compiler_core.tg + bootstrap_main.tg split; remove
    docgen.tg/formatter.tg/linter.tg from the fixed-point manifest.
13. [Strict] all bootstrap builds use strict semantics unconditionally
    (unresolved name/type/method/access/layout = error).
14. [Final] delete legacy borrow syntax from the parser; rewrite all docs;
    full ladder: stage0→stage1→stage2→stage3 with stage2==stage3,
    clean-root determinism, and the access/resource critical canary suite
    under stage1 and stage2.

## Conventions

- Never remove the ability to parse the CURRENT syntax before the new
  syntax is fully implemented and normalized. One semantic implementation:
  legacy syntax is normalized into the new representation immediately after
  parsing.
- Every commit must leave the kernel parse-clean and type-clean (the two
  gates above). If a change cannot pass, do not commit it; fix or revert.
- No comments unless they explain a non-obvious semantic rule.
- Determinism: no map-iteration-order dependence in any output.
