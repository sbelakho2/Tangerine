# Tangerine Compiler Pipeline — the Stage Facts (generated)

> **GENERATED EVIDENCE — do not edit by hand.** This document is
> rendered by `scripts/gen_spec_docs.sh` from
> [`compiler_pipeline.toml`](compiler_pipeline.toml), the machine-readable
> source of truth for the stage order, the stopping points, the
> single-authority rule per stage, the verifier's schema and the
> completeness oracles of the self-hosted compiler (`compile_file_core`
> in tg_compiler/compiler_core.tg). The CI evidence-gate job regenerates
> it and runs `git diff --exit-code` on both the schema and this doc —
> a stale hand-edited stage fact cannot merge. The prose companion is
> [`pipeline_manifest.md`](pipeline_manifest.md).

## The canonical semantic pass

Stages 4–9 run as ONE canonical API, `analyze_parsed` (compiler_core.tg), over the
shared `Program` — the driver NEVER re-runs expansion or id assignment
(pre-pass duplication corrupts node-id identity). `analyze_source` (lex +
parse + the canonical pass) is the front door of `tg check` and
`lib::check`; `compile_file_core` performs the same canonical pass then
continues through MIR/mono/optimize/codegen.

## Stage order and the single-authority rule

| # | Stage | Entry Point | Source File | Representation owning the invariant | Single authority | Consumed read-only by |
|---|---|---|---|---|---|---|
| 1 | Lexing | `tokenize(source, file)` | `lexer.tg` | Vec[Token] / LexResult | the token stream is the only authority for source-text boundaries; no stage re-lexes | parser |
| 2 | Parsing | `parse(lex_result)` | `parser.tg` | Program (Program.items) | the parser is the only producer of the Program AST from tokens; parse diagnostics hard-stop before anything semantic | all later stages |
| 3 | Dependency merge | `merge_imported_deps(ast, ...)` | `compiler_core.tg` | Program.crate (Crate.root, Crate.modules: Map[ModuleId, Module]) | merge_imported_deps is the only builder of the Program.crate module graph; later stages read Crate.modules by ModuleId, never rebuild it | resolution, type checking, mono (crate containment for fn_owner_key_of_def) |
| 4 | Macro expansion | `expand_macros(program, diags)` | `compiler_core.tg` | Program (macro-free AST) | expand_macros is the only authority over expansion; a non-converging fixpoint (E105) hard-stops BEFORE resolution — an incompletely expanded AST is never semantically processed | none (the result is a fresh AST) |
| 5 | Node-ID assignment | `assign_node_ids(program)` | `ast.tg` | the globally unique semantic node ids keying every downstream map | assign_node_ids is the single authority that assigns the globally unique semantic node ids; every downstream map (expr_types, call_targets, access_effects, edge_cleanup, finalize_plan) is keyed by them; the driver never re-assigns | resolution, type checking, access, resource, MIR |
| 6 | Name resolution | `resolve_names(program)` | `resolver.tg` | ResolvedNames (call_targets, item_defs, method_defs, module_symbols, def_kinds, stable_ids) | resolve_names is the only producer of ResolvedNames: DefIds (ModuleId + per-module symbol index), call_targets, item_defs, method_defs, module_symbols, def_kinds; strict resolution is forced on for compilation (permissive resolution is editor-recovery only, never codegenable) | type checking, access, resource, MIR, mono |
| 7 | Type checking | `type_check_typed(&mut env, &ast, &res)` | `types.tg` | TypedProgram (flat maps + typed_exprs Typed-HIR) | type_check_typed is the only authority for types: expr_types, call_targets, call_instances (the SOLVED generic substitutions), field_targets (FieldId), the typed_exprs Typed-HIR nodes, deinit_plans, type_names/type_fields/type_variants/type_params/type_kinds; the item-8 semantic completeness oracle runs at the tail (the ICE-oracle for any accepted program with a residual placeholder) | access, resource, MIR, mono |
| 8 | Access checking | `access_check(&ast, &typed)` | `access_check.tg` | TypedProgram.access_effects | access_check is the only authority over per-call access effects (Modify/Consume/Initialize exclusivity), recorded in TypedProgram.access_effects | resource checker, MIR |
| 9 | Resource checking | `resource_check(&ast, &typed)` | `resource_check.tg` | CfgEdge/CfgEdgeKind model; TypedProgram.finalize_plan + edge_cleanup | resource_check is the only authority over the CFG edge model (CfgEdge/CfgEdgeKind + the per-edge action sequences), the per-function finalize_plan (fn owner key → local ids) and the per-edge edge_cleanup map; MIR consumes these instead of re-deriving ownership | MIR cleanup emission |
| 10 | MIR lowering | `driver_lower_to_mir(&ast, &typed)` | `mir.tg` | MirProgram (CFG with semantic projections) | lower_to_mir is the only producer of the MirProgram CFG; semantic projections (Projection::Field(FieldId) / variant identity) are resolved BY ID from the typed program (typed_field_projection) — a missing FieldId is an ICE at the lowering site | mono, optimizer, codegen |
| 11 | MIR verification | `verify_mir(&mir)` | `mir.tg` | the verifier invariant set (the schema below) | verify_mir is the single authority over the MIR invariant set and runs at EVERY boundary: post-lower, post-mono (unconditional — the generic substitution is a transformative boundary every build re-proves), after EVERY transformative optimizer pass (the verify-everything policy: debug/CI), post-opt, and IMMEDIATELY BEFORE codegen (the final firewall re-proves the exact IR instance codegen receives) — a verified MIR that passes is the only MIR that continues | a gate, not a transform |
| 12 | Monomorphization | `monomorphize_program(&mut mir, &mut mono_cache)` | `mono.tg` | MonoCache + InstanceId work queue; the item-8 MIR completeness oracle runs right after | monomorphize_program is the only authority for instance identity (InstanceId = CallableId wrapping the DefId + the concrete substitutions), the mangled emission name (instance_key / mangle_name), and the work queue. ZERO-INFERENCE: the instance payload is the ONLY source of type arguments — a call with a generic base and no solved instance FAILS CLOSED (error, never inference) | optimizer, codegen (emission names) |
| 13 | MIR optimization | `optimize_mir(&mut mir, opt_level)` | `mir.tg` | MirProgram (transformed) | optimize_mir is the only authority for MIR transformations, gated by opt_level; it must never change observable semantics | codegen |
| 14 | Code generation | `generate_object_file / generate_executable` | `codegen.tg` | layout/Repr table + IntrinsicId dispatch; preceded by the final firewall (verify_mir + run_mir_completeness_oracle) | generate_object_file/generate_executable are the only authorities for instruction selection, the register-targeted DIRECT EMISSION (the inline per-function register state RegAllocState — alloc_reg / free_reg / alloc_reg_or_spill — NOT a standalone register-allocation pass), the layout/Repr table (layout_engine.tg), and intrinsic dispatch (IntrinsicId in codegen.tg) | linker, runtime |

## The stopping points

**THE FACT (the contradiction resolved): `tg check` sets
`check_only = true; stop_after = StopAfter::Mir` and stops AFTER stage 11
— MIR lowered AND verified — before monomorphization and codegen. The
code comment says it exactly: "`tg check` stops here: the program has
been lexed, parsed, dependencies resolved, macros expanded, type-checked,
access-checked, lowered to MIR and verified — without generating native
code." The old "stops at StopAfter::Semantic" wording is WRONG.**

| Stopping point | StopAfter / mode | After stage | What completed | Source | Note |
|---|---|---|---|---|---|
| tg check | StopAfter::Mir | 11 | lexed, parsed, dependencies merged, macros expanded, node-id'd, resolved, type/access/resource-checked, lowered to MIR AND verified — without generating native code | `driver.tg cmd_check: check_only = true; stop_after = StopAfter::Mir; compiler_core.tg: the stop return sits immediately after the post-lower verify_mir pass` | the OLD 'tg check stops at StopAfter::Semantic' wording is WRONG (pipeline_manifest.md v2 said 'after stage 9') |
| tg parse | StopAfter::Parse | 2 | lex + parse only; no type-check or codegen | `driver.tg cmd_parse: check_only = true; stop_after = StopAfter::Parse` |  |
| StopAfter::Semantic | StopAfter::Semantic | 9 | after the semantic verification (type/access/resource checking); reachable through the internal CompilerOptions only — NOT the `tg check` CLI | `compiler_core.tg (the StopAfter::Semantic return sits after the semantic-completeness oracle)` |  |
| --dump-phase tokens\|ast | debug dump | 1 | after stages 1/2 (debug dumps, not compilations) | `compiler_core.tg dump_phase handling` |  |
| --dump-phase mir-lowered | StopAfter::Mir | 11 | prints the lowered MIR (after the post-lower verification) and returns | `compiler_core.tg dump_phase mir-lowered` |  |
| --emit-mir / --dump-phase mir-opt | post-opt | 13 | after stage 13 (optimized AND verified) | `compiler_core.tg` |  |
| EmitMode::Object + StopAfter::Object | StopAfter::Object | 14 | after stage 14 object emission (the object file is materialized first) | `compiler_core.tg (EmitMode::Object branch)` |  |

## The verifier's schema (the canonical-MIR lag resolved)

`verify_mir` (mir.tg) enforces the SEVEN invariants below — this is the
live schema (canonical_ir_spec.md's INV-MIR-001..009 list is stale).
It runs at every boundary: post-lower; post-mono (unconditional); after EVERY transformative optimizer pass (the verify-everything policy); post-opt; immediately before codegen (the final firewall).
Return: Vec[String] of error messages; an empty vector means the MIR is valid; violations abort the compilation.

| # | Invariant | Description |
|---|---|---|
| 1 | type concreteness | no Type::Param / Type::Var in MirTypeDef fields or variants; every Named type in a type definition keys a canonical TypeId in the deinit-plan table |
| 2 | callee resolution | every MirFnItem callee names a lowered function or a known intrinsic |
| 3 | structural validity | every function has ≥ 1 block, all block/local ids reference real entries (block ids are DISJOINT — the exactly-one-terminator rule), the entry block exists |
| 4 | projection correctness | FieldId owner matches the projected TypeId (a missing FieldId is an ICE at the lowering site) |
| 5 | cleanup soundness | deinit plans and edge actions agree with the block frames |
| 6 | switch-discriminant contract | a MirSwitchInt discriminant is an integer-like scalar, its target values are pairwise distinct, and every value is a DECLARED variant discriminant when the discriminant type is an enum (an impossible enum discriminant is rejected) |
| 7 | reachable placeholder rule | a reachable block ending in the MirUnreachable placeholder is rejected |

## The completeness oracles (the reviewer's item 8)

Two oracles implement the ICE distinction — USER MISTAKES get the stable
diagnostics (the checker's E-codes, recorded before either oracle runs);
the IMPOSSIBLE POST-TYPECHECK STATE (an accepted program with a residual
placeholder) is the internal invariant failure, recorded as an ICE-class
error that aborts compilation.

| Oracle | Source | Runs | What it proves |
|---|---|---|---|
| run_semantic_completeness_oracle | `types.tg` | at the tail of type_check_typed — AFTER the typecheck, BEFORE the lowering | audits the accepted TypedProgram's channels: Type::Error / unresolved Type::Var / Param-in-concrete-position; UNKNOWN DefId (every call target and finalizer DefId must be a resolver-registered symbol); UNKNOWN FieldId / VariantId; MISSING ACCESS EFFECT (every typed call's receiver and arguments carry the recorded per-node effect); MISSING OBLIGATION SOLUTION (every registered trait impl is backed by its trait contract); UNKNOWN TypeId (the unknown-layout precursor) |
| run_mir_completeness_oracle | `compiler_core.tg` | right after monomorphization, again after optimization, and immediately before codegen | proves every type in the substituted IR — function signatures, locals, statics, and the registered type definitions — has a COMPUTABLE LAYOUT under the fail-closed layout_of_concrete (Var/Error/Param/unregistered named types all fail closed) |

## The register-allocation fact (the wording contradiction resolved)

Stage 14 (codegen) performs DIRECT emission with the inline per-function
register state (`RegAllocState` — `alloc_reg` / `free_reg` /
`alloc_reg_or_spill`, codegen.tg). There is NO standalone
register-allocation pass in the pipeline; "register allocation" in
pipeline prose means this register-targeted emission inside stage 14 —
matching invariants.md INV-OPT-006 ("no register allocator exists —
codegen is direct stack-frame + register-targeted emission").

---

*Generated from `docs/current/compiler_pipeline.toml`.*
