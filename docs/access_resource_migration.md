# Access + Resource Model — Migration History

**Status:** historical — the migration described here is complete.
**Normative model:** [`memory_model.md`](memory_model.md). This document
is the archived record of the migration that produced it; it is not a
living plan and nothing here should be read as a current design
assumption. Where this document and `memory_model.md` disagree, the
normative model wins.

**Last Updated:** August 2026.

---

## What this document records

The redesign of the Tangerine memory model from the former
borrow/lifetime model to the access/resource model: per-parameter access
conventions (`let`/`inout`/`sink`/`set`), nominal kinds
(value/resource/capability), the deletion of the borrow checker, and the
typed access/resource checking pipeline that replaced it. All of it was
carried out under the self-hosting bootstrap discipline (stage0 Swift
interpreter → stage1 → stage2 → stage3, with the kernel parse-clean and
type-clean at every commit).

## Verification gate (historical)

During the migration every change had to pass the parse gate and the type
gate (see the archived commands below). These gates are no longer the
migration discipline: the native pipeline (access_check →
resource_check → MIR) now runs unconditionally, and the final ladder
(stage0→stage1→stage2→stage3 with stage2 == stage3 and clean-root
determinism) is the bootstrap release procedure, not a migration check.

```
# Parse gate (historical): kernel must parse 36/36 OK
timeout 110 ./stage0_swift/.build/release/tg_stage0 compile tg_compiler/<file>.tg -o /tmp/pt 2>&1 | grep -E "Parsed:|FAIL"

# Type gate (historical): kernel must type-check clean.
timeout 1500 ./stage0_swift/.build/release/tg_stage0 compile tg_compiler/driver.tg -o /tmp/verify_out > /tmp/verify.log 2>&1
# then: grep -E "Type check failed|Borrow checking|error\[" /tmp/verify.log
# (the "Borrow checking..." line no longer exists — that stage was deleted
# by this migration)
```

## Design (summary) — implemented

The two independent dimensions the migration introduced, both now
implemented:

- **Access convention** per parameter/receiver: `let` (observe), `inout`
  (exclusive mutation), `sink` (transfer/consume), `set` (initialize dead
  storage). No safe first-class references: `&x` is syntax for an access
  marker on a place, never a reference value.
  → Normative: `memory_model.md` §2 (conventions), §3 (the access marker).
- **Nominal kind**: `value` (default), `resource` (noncopyable,
  deterministic deinit at scope exit, viral through containment),
  `capability` (strict linear authority: exactly-once transfer, cannot be
  copied, fabricated, or silently abandoned).
  → Normative: `memory_model.md` §4 (resources), §5 (capabilities),
  §7 (TypeProperties).

The borrow checker was DELETED. It was replaced by (a) an access-overlap
checker (per-call access paths: read/inout/sink/set, reject overlapping
incompatible accesses, static disjointness for fixed struct fields) and
(b) a resource state checker (Uninitialized/Live/Consumed/MaybeLive
dataflow over the CFG).
→ Normative: `memory_model.md` §2.2, §4.2.

## Implementation order (waves) — status

| Wave | Content | Status | Where it landed |
|------|---------|--------|-----------------|
| 1 | P0 bugs: stable_ids init; struct-literal required-field completeness; codegen O(1) type index; strict concrete layout API | IMPLEMENTED | `ids.tg` StableDefId; `types.tg` `type_id_index`; `layout_engine.tg` `layout_of_concrete` (now called from `codegen.tg`) |
| 2 | Additive structures: `AccessConvention` (ast.tg), `TypeKind` (types.tg) — added without changing existing syntax or semantics | IMPLEMENTED | `ast.tg` `AccessConvention`/`NominalKind`; `types.tg` `TypeKind` (Value/Resource/Capability) |
| 3 | Stage0 Swift syntax: `var`, `inout`, `sink`, `set`, `resource`, `deinit` tokens; `Param.convention`; parser accepts both legacy and new syntax, normalizing legacy | IMPLEMENTED | `stage0_swift/Sources/TangerineCompiler/{Token,Parser,AST,MIRLowering,MIRInterpreter}.swift` |
| 4 | Native lexer/parser: same syntax in `tg_compiler/`; normalization `&mut T→inout T`, `&T→let T`, `move→sink` | IMPLEMENTED | `token.tg` keyword table (`var`→`Mut` alias, `inout`/`sink`/`set`/`resource`/`deinit`); `parser.tg` `parse_param` |
| 5 | TypedProgram: ast, resolutions, expr_types, call_targets, field_targets, access_effects, type_kinds; MIR consumes it (no re-inference); DefId = (module, index) | IMPLEMENTED | `types.tg` `TypedProgram`; `ids.tg` `DefId`/`ModuleId`; `mir.tg` MirBuilder (access_effects, field_targets, call_def_ids, call_instances, iteration_plans, edge_cleanup, ...) |
| 6 | Access checker: AccessPath/AccessEffect per-call overlap; sink consumption marking. Delete `borrow_check.tg` | IMPLEMENTED | `access_check.tg`; `borrow_check.tg` deleted; driver/compiler_core run `access_check` unconditionally |
| 7 | Resource checker: resource availability dataflow over the CFG | IMPLEMENTED | `resource_check.tg` (§4.2 of the normative model) |
| 8 | MIR: MirRead/MirConsume; MirCallArg{effect, value}; MirDeinit (auto/explicit/unsafe-raw distinguished); ProjDeref removed for safe places | IMPLEMENTED | `mir.tg` (`MirRead`/`MirConsume` operands, `MirCallArg.effect`, `MirDeinit` terminators with verified deinit names; `ProjRawDeref` only) |
| 9 | Collections: iteration becomes projected access; subscripts are projections; COW backing storage for String/Array/Map/Set | PARTIAL | Projected iteration IMPLEMENTED (`IterationPlan`, `memory_model.md` §10); consuming iteration and COW backing storage remain pending (see the audit table and `memory_model.md` §15) |
| 10 | Core stdlib rewrite: Copyable trait replaced by the Copy/Clone/Move/Drop model; String/Vec/Map inout APIs | IMPLEMENTED | `std/core.tg` ownership-marker families (`memory_model.md` §6); `std/alloc.tg`, `std/collections.tg` convention-based APIs |
| 11 | Compiler source migration: tg_compiler/*.tg to let/var/inout/sink/set/resource syntax; allocators/FFI as resources; caps as linear capabilities | IMPLEMENTED | the whole `tg_compiler/` tree |
| 12 | Kernel shrink: `compiler_core.tg` + `bootstrap_main.tg` split; tooling out of the fixed-point manifest | IMPLEMENTED | `bootstrap/compiler_kernel.manifest`: `compiler: compiler_core.tg`; docgen/formatter/linter/driver/agentic/etc. excluded from the kernel |
| 13 | Strict: bootstrap builds use strict semantics unconditionally | IMPLEMENTED | `type_check_typed` forces `strict_resolution` on every compilation path; permissive mode is editor-recovery only |
| 14 | Final: delete legacy borrow syntax from the parser; rewrite all docs; full ladder | PARTIAL | Docs rewritten (this document + `memory_model.md`). Legacy parameter modifiers (`&T`/`&mut T`/`move`/`own`) are still normalized at parse — `&T`/`&mut T` in general type position is a hard error (E106); parser deletion is a pending target; the full stage0→stage3 ladder is the bootstrap release procedure, pending until the remaining open items below close |

## Exact specs (authoritative during migration) — implemented

The grammar, AST v2, types.tg, TypedProgram, access_check.tg and MIR
shapes specified in the original plan were implemented as specified,
with the following final forms (all normative detail is in
`memory_model.md`):

- `AccessConvention { Let, Inout, Sink, Set }` — `ast.tg`; `ParamType`
  carries conventions into function types (`memory_model.md` §2, §9).
- `NominalKind { Value, Resource }` (`ast.tg`); `TypeKind { Value,
  Resource, Capability }` (`types.tg`); `TypeExprKind` has no Ref/RefMut —
  only `Ptr`/`PtrMut`; `ExprKind` has `ExprAccess` (the `&place` marker)
  and unsafe `ExprRawDeref`; patterns have no Ref/RefMut
  (`memory_model.md` §3, §11).
- `TypedProgram` with `access_effects`/`type_kinds`/`field_targets`/
  `call_targets`/`expr_types`; `DefId { module: ModuleId, index }`
  (`memory_model.md` §2.1, §8).
- `AccessEffect { Read, Modify, Consume, Initialize }`; multiple Reads
  coexist; Modify/Consume/Initialize are exclusive; fixed struct fields
  statically disjoint; dynamic index overlap conservatively rejected;
  raw derefs are UnknownAlias (`memory_model.md` §2.2, §11).
- MIR: `MirCallArg { effect, value }`; `MirRead`/`MirConsume` replace the
  old copy/move/ref forms; `MirDrop → MirDeinit` (auto/explicit/unsafe-raw
  distinguished); `ProjDeref` removed for safe places (`ProjRawDeref`
  only, unsafe) (`memory_model.md` §14.3).

## Audit results (post-wave-12) — status as of August 2026

The 2026-08-15 audit found the transition structurally sound through wave
12 and listed the key latent items. Their status now:

| # | Audit finding (2026-08-15) | Status now |
|---|----------------------------|------------|
| 1 | TypedProgram produced but not consumed by MIR | **RESOLVED** — MirBuilder consumes access_effects, field_targets, call_def_ids, call_instances, ident_resolutions, typed_local_bindings, pattern/param_binding_resolutions, expr_types, closure_captures, iteration_plans, and the checker's TypedCFG (the CleanupEdge table) |
| 2 | MirRead/MirConsume/MirDeinit never emitted; codegen drops arg_effects | **RESOLVED** — MirRead/MirConsume are the operand forms; MirDeinit terminators are emitted with verified deinit names; MirCallArg carries the typed effect (`memory_model.md` §4.3, §14.3) |
| 3 | Expression-level `&` still parsed to ExprRef→MirRef; `let r = &x` not rejected | **RESOLVED** — `&`/`&mut` parse to `ExprAccess`; TypeExprKind Ref/RefMut are gone; E106 flags first-class `&T` type positions (`memory_model.md` §2.3, §3) |
| 4 | Resource auto-deinit not wired | **RESOLVED** — deinit targets/plans registered; finalize plans + edge plans drive MirDeinit emission (`memory_model.md` §4.2–4.3) |
| 5 | trait_resolve method identity convention-blind (Type only) | **SUPERSEDED** — the second trait engine was deleted and trait_resolve.tg is a facade over the one solver; signatures carry `ParamType` conventions (`memory_model.md` §8.5) |
| 6 | Type::Ref/RefMut/Owned + Lifetime deletion pending; collections get→&T pending; COW pending | **PARTIAL** — Type::Ref/RefMut/Owned and Lifetime are gone (`RefInternal` remains, documented MIR-only); reference-returning type positions are gone too (the kernel's transitional `-> &T` / `Option[&T]` / `Vec[&T]` forms were converted to their erased-value forms and E106 is a hard error); COW remains pending |
| 7 | Resolver declaration pass duplication | **ARCHIVED** — no longer a memory-model issue; see `resolver.tg` |
| 8 | TypeEnv lookups return TypeDef by value | **ARCHIVED** — superseded by the identity refactor (`memory_model.md` §8) |
| 9 | layout_of_concrete has no callers | **RESOLVED** — called from `codegen.tg` |
| 10 | No access/resource canary suite yet | **RESOLVED** — `tests/canary` / `tests/canary_neg` cover access/resource negatives (resource index, map get, let-param consume, ...) |
| 11 | compiler_core.tg split pending; tooling back in the manifest | **RESOLVED** — `compiler: compiler_core.tg` in `bootstrap/compiler_kernel.manifest`; docgen/formatter/linter/driver/pkg_manager/refactor/registry/agentic/etc. are outside the kernel |
| 12 | Strictness flag-driven, not the default | **RESOLVED** — every compilation path forces `strict_resolution`; the permissive mode is editor-recovery only |
| 13 | Docs rewrite pending | **RESOLVED** — this document is historical; `memory_model.md` is normative |
| 14 | Closure capture-effect inference not started | **RESOLVED** — typed capture records (`closure_captures`: closure expr node → captured local id → effect) are the only capture source for MIR |
| 15 | Final ladder pending until all of the above are complete | **OPEN** — the full stage0→stage1→stage2→stage3 ladder with stage2 == stage3 and clean-root determinism is the bootstrap release procedure; it stays open until the pending items below close |

## Pending items (current, not assumptions)

The following remain open. They are documented as targets in
`memory_model.md` §15 (the invariant catalog); nothing in this document
should be taken as their specification beyond what that section says:

- **Partial moves** — projected-place consumes/moves/assigns are
  rejected until per-place partial-move state exists.
- **Consuming iteration** — sink-element iteration with per-iteration
  (backedge) cleanup.
- **Typed-HIR migration** — finalizer recognition is name-based
  (`deinit`/`drop`) pending a typed `FinalizerKind`; `ParamModifier` is
  transitional. (The reference-returning type positions were converted
  to their erased-value forms; E106 is a hard error.)
- **Fixed-array size constants** — `[T; N]` counts must be Int literals;
  constant-expression sizes pending.
- **Generated drop glue** — recursive owning types fail closed with
  `PlanLimit` until generated per-TypeDef drop glue exists.
- **StrView registration** — `StrView` is a std struct selected by name
  (hash/eq dispatch in codegen.tg / mono.tg); LangItems-level
  registration pending.
- **LangItems for the name-selected pointers** — UniquePtr/WeakRc/
  ArcStrong/WeakArc are still name-selected.
- **Legacy borrow syntax deletion** — `&T`/`&mut T`/`move`/`own`
  parameter modifiers are still normalized at parse (E106 is a hard
  error in general type position).
- **COW backing storage** for String/Array/Map/Set (wave 9 remainder).

The authoritative pending list is `memory_model.md` §15.2; it is updated
when the compiler changes, this document is not.
