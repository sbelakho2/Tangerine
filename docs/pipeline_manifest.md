# Tangerine Compiler Pipeline Manifest
## Version 2.0.0

### Purpose
Canonical reference for the self-hosted compiler's stage order, responsibilities,
the exact representation that owns each invariant, and the single-authority rule
per stage. This document is the single source of truth for the driver pipeline
(compile_file_core in tg_compiler/compiler_core.tg).

---

## Stage Order

The compiler executes the following stages in strict sequence.
Each stage runs to completion before the next begins; a stage's output is the
next stage's input, and no stage re-runs the work of an earlier stage.

| # | Stage | Entry Point | Source File | Representation owning the invariant |
|---|-------|-------------|-------------|-------------------------------------|
| 1 | Lexing | `tokenize(source, file)` | lexer.tg | `Vec[Token]` / `LexResult` |
| 2 | Parsing | `parse(lex_result)` | parser.tg | `Program` (`Program.items`) |
| 3 | Dependency merge | `merge_imported_deps(ast, ...)` | compiler_core.tg | `Program.crate` (`Crate.root`, `Crate.modules: Map[ModuleId, Module]`) |
| 4 | Macro expansion | `expand_macros(program, diags)` | compiler_core.tg | `Program` (macro-free AST) |
| 5 | Node-ID assignment | `assign_node_ids(program)` | ast.tg | the globally unique semantic node ids keying every downstream map |
| 6 | Name resolution | `resolve_names(program)` | resolver.tg | `ResolvedNames` (`call_targets`, `item_defs`, `method_defs`, `module_symbols`, `def_kinds`, `stable_ids`) |
| 7 | Type checking | `type_check_typed(&mut env, &ast, &res)` | types.tg | `TypedProgram` (flat maps + `typed_exprs` Typed-HIR) |
| 8 | Access checking | `access_check(&ast, &typed)` | access_check.tg | `TypedProgram.access_effects` |
| 9 | Resource checking | `resource_check(&ast, &typed)` | resource_check.tg | `CfgEdge`/`CfgEdgeKind` model; `TypedProgram.finalize_plan` + `edge_cleanup` |
| 10 | MIR lowering | `driver_lower_to_mir(&ast, &typed)` | mir.tg | `MirProgram` (CFG with semantic projections) |
| 11 | MIR verification | `verify_mir(&mir)` | mir.tg | the verifier invariant set (runs after lower, mono, and opt) |
| 12 | Monomorphization | `monomorphize_program(&mut mir, &mut mono_cache)` | mono.tg | `MonoCache` + `InstanceId` work queue |
| 13 | MIR optimization | `optimize_mir(&mut mir, opt_level)` | mir.tg | `MirProgram` (transformed) |
| 14 | Code generation | `generate_object_file` / `generate_executable` | codegen.tg | layout/`Repr` table + `IntrinsicId` dispatch |

PGO (instrumentation `instrument_for_pgo` / profile load `apply_pgo_profile`,
mir.tg) is an OPTIONAL, flag-gated sub-step of stage 13: `--pgo-gen` instruments
before optimization, `--pgo-use` loads a profile (a requested profile must load;
a failed read is a hard error, never a silent fallback). PGO is not part of the
default pipeline.

### The canonical semantic pass

Stages 4–9 run as ONE canonical API, `analyze_parsed` (compiler_core.tg), over
the shared `Program` — the driver NEVER re-runs expansion or id assignment
(pre-pass duplication corrupts node-id identity: a second pass renumbers ids).
`analyze_source` (lex + parse + the canonical pass) is the front-door used by
`tg check` and `lib::check`; `compile_file_core` performs the same canonical
pass then continues through MIR/mono/optimize/codegen.

### Early Exit Points

- `--dump-phase tokens|ast`: after stages 1/2 (debug dumps, not compilations).
- `tg check` / `StopAfter::Semantic`: after stage 9 (semantic verification).
- `StopAfter::Mir` / `--dump-phase mir-lowered`: after stage 11 (MIR lowered AND verified).
- `--emit-mir` / `--dump-phase mir-opt`: after stage 13 (optimized and verified).
- `EmitMode::Object` + `StopAfter::Object`: after stage 14 object emission.
- Any error in stages 2, 4–9, 11, 12, 14 causes a hard stop.

---

## Single-Authority Rule Per Stage

Each stage is the ONLY authority over its representation. No later stage
re-derives what an earlier stage decided; a later stage consumes the earlier
representation read-only.

| # | Stage | Single authority | Consumed read-only by |
|---|-------|------------------|-----------------------|
| 1 | Lexing | the token stream is the only authority for source-text boundaries; no stage re-lexes | parser |
| 2 | Parsing | the parser is the only producer of the `Program` AST from tokens; parse diagnostics hard-stop before anything semantic | all later stages |
| 3 | Dependency merge | `merge_imported_deps` is the only builder of the `Program.crate` module graph; later stages read `Crate.modules` by `ModuleId`, never rebuild it | resolution, type checking, mono (crate containment for `fn_owner_key_of_def`) |
| 4 | Macro expansion | `expand_macros` is the only authority over expansion; a non-converging fixpoint (E105) hard-stops BEFORE resolution — an incompletely expanded AST is never semantically processed | none (result is a fresh AST) |
| 5 | Node-ID assignment | `assign_node_ids` is the single authority that assigns the globally unique semantic node ids; every downstream map (`expr_types`, `call_targets`, `access_effects`, `edge_cleanup`, `finalize_plan`) is keyed by them; the driver never re-assigns | resolution, type checking, access, resource, MIR |
| 6 | Name resolution | `resolve_names` is the only producer of `ResolvedNames`: DefIds (`ModuleId` + per-module symbol index), `call_targets`, `item_defs`, `method_defs`, `module_symbols`, `def_kinds`; strict resolution is forced on for compilation (permissive resolution is editor-recovery only, never codegenable) | type checking, access, resource, MIR, mono |
| 7 | Type checking | `type_check_typed` is the only authority for types: `expr_types`, `call_targets`, `call_instances` (the SOLVED generic substitutions), `field_targets` (FieldId), the `typed_exprs` Typed-HIR nodes, `deinit_plans`, `type_names`/`type_fields`/`type_variants`/`type_params`/`type_kinds` | access, resource, MIR, mono |
| 8 | Access checking | `access_check` is the only authority over per-call access effects (Modify/Consume/Initialize exclusivity), recorded in `TypedProgram.access_effects` | resource checker, MIR |
| 9 | Resource checking | `resource_check` is the only authority over the CFG edge model (`CfgEdge`/`CfgEdgeKind` + the per-edge action sequences), the per-function `finalize_plan` (fn owner key → local ids) and the per-edge `edge_cleanup` map (`"edge::<kind>::<source id>"` keys). MIR consumes these instead of re-deriving ownership | MIR cleanup emission |
| 10 | MIR lowering | `lower_to_mir` is the only producer of the `MirProgram` CFG; semantic projections (`Projection::Field(FieldId)` / variant identity) are resolved BY ID from the typed program (`typed_field_projection`) — a missing FieldId is an ICE at the lowering site | mono, optimizer, codegen |
| 11 | MIR verification | `verify_mir` is the single authority over the MIR invariant set and runs at EVERY boundary: post-lower, post-mono, post-opt — a verified MIR that passes is the only MIR that continues | (a gate, not a transform) |
| 12 | Monomorphization | `monomorphize_program` is the only authority for instance identity (`InstanceId` = `CallableId` wrapping the DefId + the concrete substitutions), the mangled emission name (`instance_key` / `mangle_name`), and the work queue. ZERO-INFERENCE: the instance payload is the ONLY source of type arguments — a call with a generic base and no solved instance FAILS CLOSED (error, never inference) | optimizer, codegen (emission names) |
| 13 | Optimization | `optimize_mir` is the only authority for MIR transformations, gated by opt_level; it must never change observable semantics | codegen |
| 14 | Code generation | `generate_object_file`/`generate_executable` are the only authorities for instruction selection, register allocation, the layout/`Repr` table (layout_engine.tg), and intrinsic dispatch (`IntrinsicId` in codegen.tg) | linker, runtime |

---

## The Exact Representation Owning Each Invariant

### Program — the crate/module graph (stages 2–3)

`struct Program { items: Vec[Item], crate: Crate, span: Span }` (ast.tg). The
`crate` field is the module table: `Crate.root: ModuleId` + `Crate.modules:
Map[ModuleId, Module]` where `Module { id, path, item_indices, imports }`.
`ModuleId` lives in ids.tg (the central semantic identity domain); `DefId.module`
points into this graph BY IDENTITY, never by path String. The item index
(position in `Program.items`) is the anchor for `ResolvedNames.item_defs`.

### ResolvedNames — the id system (stage 6)

`struct ResolvedNames` (resolver.tg) owns: `expr_resolutions`/`type_resolutions`/
`pattern_resolutions` (node id → resolved symbol), `call_targets` (node id →
DefId), `method_defs` (`"Type::method"` → DefId), `item_defs` (item index →
DefIds in declaration order — the stable, cross-file collision-free owner
identity), `module_symbols` (`"path::name"` → DefId snapshot), `def_kinds`
(`"module_id::index"` → DefKind metadata — DefId carries no kind; consumers
render via `def_kind_of`), and `stable_ids` (the incremental-compilation id
records). Every DefId = owner ModuleId + per-module symbol index; two functions
at the same byte offset in different files never collide.

### TypedProgram — the maps + the Typed-HIR nodes (stages 7–9)

`struct TypedProgram` (types.tg) owns the flat maps keyed by semantic node id —
`expr_types: Map[Int, Type]`, `call_targets: Map[Int, DefId]`,
`call_instances: Map[Int, Vec[Type]]` (the type checker's SOLVED substitutions —
the AUTHORITY for the monomorphizer), `field_targets: Map[Int, FieldId]`,
`access_effects: Map[Int, AccessEffect]`, `closure_captures`,
`local_bindings`, `ident_resolutions`, `param_binding_resolutions` (keyed by
owner fn key), `pattern_binding_resolutions`, `aggregate_ownership`, and the
`typed_exprs: Map[Int, TypedExpr]` — the Typed-HIR nodes (kind + resolved type
per expression node). Ownership decisions flow through `deinit_plans`
(per-TypeId DeinitPlan), `type_names`, `deinit_targets`, `type_fields`,
`type_variants`, `type_params`, `type_kinds`. The resource checker's authority
is injected by compiler_core: `finalize_plan` (fn owner key → local ids) and
`edge_cleanup` (edge identity → local ids in reverse drop order).

### CfgEdge — the flow model (stage 9)

`struct CfgEdge { kind: CfgEdgeKind, source: Int, destination: Int, actions:
Vec[(Int, Int)] }` (resource_check.tg). `CfgEdgeKind` = Normal/True/False/
Break/Continue/Return/Backedge/GuardElse. Source is the semantic node id of the
transfer's originator; destination is the static target (0 when dynamic).
`actions` are the cleanup obligations as ACTION SEQUENCES in execution order:
`(0, local id)` = drop the local, `(1, defer stmt id)` = run the registered
defer. The block-grounded derivation (P0-BF/P0-BG) is the authority for what an
edge drops; `validate_cfg_edges` checks recorded actions against block frames.
The MIR-visible string keys (`"return::<id>"`, `"edge::Return::<id>"`, ...)
carry the same sets — MIR consults `edge_cleanup` first, falling back to string
keys only for synthesized/IR-only nodes.

### MIR — the CFG with semantic projections (stage 10)

`struct MirProgram { functions, statics, types, deinit_plans, ... }` (mir.tg).
The `MirFunction` is a block CFG (block ids, locals, terminators). The
distinctive invariant: projections are SEMANTIC — `Projection::Field(FieldId)`
resolved BY ID (`typed_field_projection`), with the `FieldId.owner` matching the
projected type's TypeId (the verifier checks this; a missing FieldId is an ICE
at the lowering site). Call callees are `MirFnItem` constants that carry the
`InstanceId` payload as semantic identity; the name remains the mangled EMISSION
key. MIR cleanup emission is single-sourced: it consumes
`TypedProgram.finalize_plan` / `edge_cleanup` / `deinit_plans` instead of
re-deriving ownership.

### The mono InstanceId work queue (stage 12)

`monomorphize_program` (mono.tg) owns a `VecDeque[(String, InstanceId)]` work
queue. Phase 1 seeds it by scanning call sites; every generic call reaching the
queue carries its SOLVED instance (from `typed.call_instances` threaded through
`mir_call_instance`). Phase 2 drains: each pop specializes ONE instance under
its `instance_key` (the same name the rewrite pass emits), appends the body, and
re-walks its call sites (transitive discovery; deferred instances become
concrete under the caller's substitution). The seen-set guarantees each instance
specializes at most once; `MAX_MONO_INSTANCES` bounds the queue. Phase 3 rewrites
call sites. ZERO-INFERENCE: no call-site type-argument inference exists
(inference helpers removed); a generic callee without a usable payload is a
recorded ERROR — the monomorphizer fails closed, never guesses.

### The verifier invariants (stage 11)

`verify_mir` (mir.tg) enforces: (1) type concreteness — no `Type::Param`/
`Type::Var` in MirTypeDef fields or variants; every Named type in a type
definition keys a canonical TypeId in the deinit-plan table; (2) callee
resolution — every MirFnItem callee names a lowered function or a known
intrinsic; (3) structural validity — every function has ≥ 1 block, all block/
local ids reference real entries; (4) projection correctness — FieldId owner
matches the projected TypeId; (5) cleanup soundness — deinit plans and edge
actions agree with the block frames. Runs post-lower, post-mono, and post-opt;
violations abort the compilation.

### The layout/Repr table (stage 14, codegen)

`enum Repr` (layout_engine.tg): `Immediate` (primitives/Unit/Never), `RawPtr`
(Ptr/PtrMut/Box/Rc/RefInternal), `StringPtr` (String — 8-byte raw pointer to
null-terminated UTF-8, no inline header), `HeapVecHeader` (Vec/Array/Slice —
heap `{ptr:0, len:8, cap:16}`), `HeapMapHeader` (Map — `{buckets:0, len:8,
cap:16}`), `HeapSetHeader` (Set — map-backed, same 24-byte map header),
`Inline` (structs, tagged enums, tuples, FixedArray — `[T; N]` is inline element
storage, `n == 0` legal), `TaggedPtr` (reserved), `OpaquePtr` (Option/Result/
Dyn/Effect/Function/unknown). `type_repr` is THE single decision function; every
storage-shape decision in the engine reads from it.

### The IntrinsicId dispatch (stage 14, codegen)

`enum IntrinsicId` (codegen.tg) is the closed set of runtime/intrinsic
operations (`ArrayPush`, `StrSlice`, `MapInsert`, `IntToString`, `Clone`, `Len`,
...). The codegen pass maps every intrinsic call to exactly one IntrinsicId;
there is no fallback or open-ended string dispatch. A call that names no known
intrinsic is a verifier error before codegen ever sees it.

---

## Input/Output Artifacts

| Stage | Input | Output | Type |
|-------|-------|--------|------|
| Lexing | source text | token stream | `Vec[Token]` |
| Parsing | `Vec[Token]` | AST | `Program` |
| Dependency merge | `Program` | `Program` with populated `crate` module graph | `Program` |
| Macro expansion | `Program` | macro-free `Program` | `Program` |
| Node IDs | `Program` | `Program` with node ids assigned | `Program` |
| Resolution | `Program` | name resolution | `ResolvedNames` |
| Type checking | `Program` + `ResolvedNames` | typed program | `TypedProgram` |
| Access checking | `Program` + `TypedProgram` | access-verified | `TypedProgram` (mutated) |
| Resource checking | `Program` + `TypedProgram` | resource-verified + finalize/edge plans | `TypedProgram` (final) |
| MIR lowering | `TypedProgram` | CFG | `MirProgram` |
| Verification | `MirProgram` | verified `MirProgram` | `Vec[String]` errors (empty = pass) |
| Monomorphization | `MirProgram` + `MonoCache` | generic-free `MirProgram` | `MirProgram` (mutated) |
| Optimization | `MirProgram` | optimized `MirProgram` | `MirProgram` (mutated) |
| Codegen | `MirProgram` + target | object bytes / executable | bytes / file |

---

## Trust Levels

| Artifact | Trust Level | Rationale |
|----------|-------------|-----------|
| Source text | UNTRUSTED | user input |
| Token stream | UNTRUSTED | lexer may produce error tokens |
| Parsed AST | VERIFIED at boundary | parser diagnostics hard-stop |
| Merged module graph | VERIFIED at boundary | merge failures are errors |
| Macro-expanded AST | VERIFIED at boundary | E105 expansion-fixpoint diagnostics hard-stop BEFORE resolution |
| Node-id'd AST | VERIFIED by construction | assign_node_ids is single-shot, never re-run |
| ResolvedNames | VERIFIED at boundary | strict resolution; unresolved symbols are errors |
| TypedProgram | VERIFIED at boundary | type errors hard-stop |
| Access-checked | VERIFIED at boundary | access errors hard-stop |
| Resource-checked | VERIFIED at boundary | resource errors hard-stop; finalize/edge plans are the ownership authority |
| MIR (lowered) | VERIFIED at boundary | `verify_mir` runs post-lower |
| MIR (monomorphized) | VERIFIED at boundary | `verify_mir` runs post-mono; zero-inference failures hard-stop |
| MIR (optimized) | VERIFIED at boundary | `verify_mir` runs post-opt |
| CodeBuffer / object | UNVERIFIED | linker fails on structural errors |
| Executable | UNVERIFIED | runtime behavior is the final arbiter |

### Trust Gap Analysis

The former gaps are CLOSED by design:

1. **Macro expansion**: no longer unverified — expansion-fixpoint diagnostics
   (E105) hard-stop before resolution; an incompletely expanded AST is never
   semantically processed.
2. **MIR lowering**: no longer unverified — `verify_mir` runs immediately after
   lowering, after monomorphization, and after optimization.
3. **MIR optimization**: no longer unverified — post-opt `verify_mir` is part
   of the default pipeline.

---

## Fallback Path Audit

| Potential Fallback | Present? | Status |
|-------------------|----------|--------|
| Silent default typing fallback | No | parser/type checker fail hard |
| Symbol invention/recovery | No | unresolved symbols are errors (strict resolution) |
| Placeholder IR emission | No | MIR lowering emits no placeholders; missing FieldIds are ICEs |
| Ownership weakening | No | access/resource checkers are strict; MIR consumes the plans, never re-derives |
| Generic type-argument inference at mono | No | ZERO-INFERENCE: unsolved instances fail closed |
| PGO profile load silent fallback | No | `--pgo-use` with a failed read is a hard error |
| Unknown-type layout fallback | No | the layout engine computes every field offset; unknowns are errors (see stabilized_subset.md F8 removal) |

No fallback path bypasses the normal stages in the self-hosted pipeline.
