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

## Exact specs (authoritative for all waves)

### New grammar (native + stage0 must converge)

Keywords added: `var`, `inout`, `sink`, `set`, `resource`, `deinit`.
`var` is the canonical mutable-binding keyword (existing `mut`/`let mut` remain migration aliases, normalized to `var`).

```
param        = [ 'inout' | 'sink' | 'set' ] IDENT [ ':' type_expr ]
             | legacy: [ 'mut' | '&' | '&mut' | 'move' | 'own' ] IDENT [ ':' type_expr ]
resource_def = [ 'pub' ] 'resource' IDENT [ type_params ] { field_def | function_def } 'end'
method_head  = def NAME ... 'inout'            # receiver convention after '-> ret' or params
```
Legacy normalization (immediately after parsing, one semantic implementation):
`&mut T` → `inout T`; `&T` / `&self` → `let T`; `move T` → `sink T`;
`own T` → `sink T`; `mut x`/`let mut x` → `var x`.

### AST v2 (tg_compiler/ast.tg)

```
enum AccessConvention { Let, Inout, Sink, Set }
struct Param { name, convention: AccessConvention, modifier: ParamModifier /*transitional*/, ty, ... }
enum NominalKind { Value, Resource }
TypeExprKind: delete Ref, RefMut; keep Ptr/PtrMut (later renamed RawPtr/RawMutPtr).
ExprKind: delete ExprRef, ExprRefMut, ExprMove, ExprCopy, ExprDeref;
         add ExprAccess(Box[Expr]) /* &place access marker */; unsafe ExprRawDeref(Box[Expr]).
Pattern: delete Ref, RefMut.
```
Transitional rule: legacy `&expr` parses to ExprAccess; `&`/`&mut`/`move`/`own` parameter
modifiers normalize to conventions above; ParamModifier is retained during migration and
deleted only after all semantic layers consume AccessConvention.

### types.tg

```
enum TypeKind { Value, Resource, Capability }
struct TypeDef { ..., kind: TypeKind }           # default Value; CapabilityDecl -> Capability
struct ParamType { ty: Type, convention: AccessConvention }
Function(Vec[ParamType], Type)                   # function types carry per-param conventions
```
Deferred deletions (after semantic layers are migrated): Type::Ref/RefMut/Owned, Lifetime,
lifetime_* helpers, TypeEnv.lifetime_counter/current_lifetime.

### TypedProgram (resolver + type checker produce; MIR consumes)

```
struct TypedProgram {
  ast: Program
  resolutions: ResolvedNames
  expr_types: Map[NodeId, Type]
  call_targets: Map[NodeId, DefId]
  field_targets: Map[NodeId, FieldId]
  access_effects: Map[NodeId, AccessEffect]
  type_kinds: Map[TypeId, TypeKind]
}
struct DefId { module: ModuleId, index: UInt }
```

### access_check.tg (replaces borrow_check.tg)

```
enum AccessEffect { Read, Modify, Consume, Initialize }
struct AccessPath { root: LocalId, projections: Vec[AccessProjection] }
struct ActiveAccess { path: AccessPath, effect: AccessEffect }
```
Rules: multiple Reads coexist; Modify/Consume/Initialize are exclusive; fixed struct fields
statically disjoint; dynamic index overlap conservatively rejected. Sink sources marked
consumed. Resource dataflow: Uninitialized/Live/Consumed/MaybeLive over CFG; auto deinit at
scope exit; branch merge inconsistency rejected; loop-created resources must be consumed per
iteration.

### MIR

MirCallArg { effect: AccessEffect, value: MirCallValue }; MirCallValue = Value(MirOperand) | Place(Place).
MirRead(Place)/MirConsume(Place) replace MirCopy/MirMovePlace and MirRef/MirRefMut;
no general MirRef value; MirDrop → MirDeinit (auto/explicit/unsafe-raw distinguished);
ProjDeref removed for safe places (ProjRawDeref only, unsafe).

## Audit results (post-wave-12)

Audit date: 2026-08-15.

The transition is structurally sound through wave 12: the driver pipeline now
runs lex → parse → expand → assign_node_ids → resolve → type_check_typed →
access_check → resource_check → MIR → verify → monomorphize → optimize →
codegen, and one critical item was fixed by this audit — the pipeline manifest
closure (all borrow-check references replaced with the access/resource stages;
docs/pipeline_manifest.md, docs/invariants.md, docs/canonical_ir_spec.md,
tools/type_check_gate.tg). The key latent items below remain, in priority order:

1. TypedProgram is produced but not consumed by MIR (call_targets/
   field_targets/access_effects/type_kinds empty; DefId never constructed) —
   the central architecture flip.
2. MirRead/MirConsume/MirDeinit are never emitted by lowering; codegen drops
   arg_effects; MirCallArg{effect,value} not implemented.
3. Expression-level `&` still parses to ExprRef→MirRef (spec: ExprAccess) —
   references survive end-to-end; `let r = &x` not rejected.
4. Resource auto-deinit not wired (MirDeinit never emitted; deinit is only a
   user method).
5. trait_resolve method identity is convention-blind (Type only).
6. Type::Ref/RefMut/Owned + Lifetime deletion pending; collections
   get→&T/ArrayIterator pending; COW pending.
7. Resolver declaration pass duplication (point 23).
8. TypeEnv lookups return TypeDef by value (point 26).
9. layout_of_concrete has no callers; permissive fallbacks still live in
   codegen's path (point 25 partial).
10. No access/resource canary suite yet (point 32).
11. compiler_core.tg split pending; DRIVER_SRC still driver.tg
    (transitional); tooling temporarily back in the manifest.
12. Strictness is flag-driven, not the default compilation semantics
    (point 29 partial).
13. Docs rewrite (grammar/memory model/language) pending — this doc remains
    the reference until then.
14. Closure capture-effect inference (point 19) not started.
15. Final ladder: stage0→stage1→stage2→stage3, stage2==stage3, clean-root
    determinism, canary suite — pending until all of the above are complete
    (per the migration rule: no bootstrap runs until the migration is done).
