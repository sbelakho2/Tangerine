# Tangerine Compiler Invariants Catalog

This document defines the formal invariants enforced at each compiler stage.
Every invariant has a unique ID, a description, a severity level, and an
honest status: the enforcing function (file/function) when the invariant is
implemented, plus the test identifier that exercises it when one exists —
or the explicit `design` / `not-applicable` status when no pass enforces it.

## Legend

| Column | Meaning |
|--------|---------|
| ID | Unique invariant identifier |
| Stage | Compiler stage that enforces this invariant |
| Description | What the invariant guarantees |
| Severity | `error` (must fix) or `warning` (advisory) |
| Status | `enforced+tested` (implemented with a test identifier), `enforced` (implemented, no dedicated test), `partial`, `design` (specified but not implemented), `not-applicable` |
| Enforcing | The file/function that enforces it; the test identifier when one exists |

Status policy: an invariant listed below is either backed by an enforcing
function (and a test where one exists) or honestly marked `design` /
`partial` / `not-applicable`. Claims without an enforcement are not
presented as features. The "claimed but not implemented" invariants of the
former table — MIR serialization round-tripping, complete codegen mappings,
debug-info correctness, FFI validation, complete cross-compilation ABI
specifications — are re-assigned to their verified status in the rows
below (INV-MIR-009, INV-CODEGEN-002, INV-CODEGEN-005, INV-ABI-003,
INV-ABI-008).

## Invariants

| ID | Stage | Description | Severity | Status | Enforcing / test |
|----|-------|-------------|----------|--------|------------------|
| INV-PARSE-001 | Lexing | All tokens carry source location spans | error | enforced | token.tg `struct Token` (span field); every lexer construction site sets it. Exercised by every canary (error positions render from token spans) |
| INV-PARSE-002 | Lexing | String literals are UTF-8 validated | error | design | no rejection pass exists — the lexer resynchronizes mid-UTF-8 instead of rejecting (lexer.tg byte handling). UTF-8 policy documented in unicode_policy.md only |
| INV-PARSE-003 | Lexing | Numeric literals fit in host integer range | warning | design | no range check found in parser.tg/lexer.tg; an IntLit is the host Int directly |
| INV-PARSE-004 | Parsing | Every parsed item has a non-empty span | error | enforced | parser.tg item constructors derive spans from token spans (span is always start..end of the item's tokens) |
| INV-PARSE-005 | Parsing | Block bodies terminate with `end` keyword | error | enforced | parser.tg block parser — unterminated blocks fail the parse with a positioned diagnostic; exercised by the parse-error canaries (tests/canary_neg, e.g. `canary_neg_ref_pattern.tg` expects the E106 parse rejection) |
| INV-PARSE-006 | Parsing | Function declarations have at least a name | error | enforced | parser.tg `parse_function` (a missing name fails the parse) |
| INV-PARSE-007 | Parsing | Spans are well-ordered (start ≤ end) for non-synthetic nodes | error | design | no span-ordering verifier exists in the compiler |
| INV-PARSE-008 | Parsing | Inverted spans are detected and reported by the verifier | error | design | no span verifier exists |
| INV-PARSE-009 | Parsing | Duplicate top-level names produce a diagnostic | warning | enforced | resolver.tg per-module duplicate test (`record_item_def` / the module tables' first-wins duplicate rejection) |
| INV-PARSE-010 | Parsing | Macro declarations are preserved in AST | error | enforced | parser.tg `ItemMacro` items; the compiler itself is macro-driven (64-pass fixpoint, E105 on non-convergence — compiler_core.tg `prepare_parsed`) |
| INV-PARSE-011 | Parsing | Attributes attach to exactly one item | error | enforced | parser.tg attribute collection attaches to the following item |
| INV-PARSE-012 | Parsing | Use declarations form valid module paths | error | enforced | resolver.tg / compiler_core.tg `merge_imported_deps` (module-table rebuild); exercised by the compiler's own std imports |
| INV-RESOLVE-001 | Name Resolution | All references resolve to a declaration | error | enforced | resolver.tg `resolve_names`; strict resolution is forced on every compile path (compiler_core.tg `analyze_parsed`); unknown names are hard errors (`unknown type` in types.tg under `strict_resolution`) |
| INV-RESOLVE-002 | Name Resolution | No ambiguous name references remain | error | enforced | resolver.tg cross-module ambiguity verification (`resolve_bare_type_name`); a same-module duplicate is rejected |
| INV-RESOLVE-003 | Name Resolution | Use imports are validated against module graph | error | enforced | compiler_core.tg `merge_imported_deps` (dependency merge fails on a missing module) |
| INV-RESOLVE-004 | Name Resolution | Visibility rules are enforced for cross-module refs | error | enforced | resolver.tg visibility checks on cross-module references |
| INV-RESOLVE-005 | Name Resolution | Extern declarations resolve to ABI symbols | warning | partial | the extern ABI CLASSIFICATION is verified (mir.tg `verify_function_v2`: known ABI strings C/System/Ruby/Tangerine); actual symbol binding is link-time (linker.tg) — no front-end symbol resolution for externs |
| INV-RESOLVE-006 | Name Resolution | Type aliases expand without cycles | error | enforced | structural walks terminate alias cycles fail-closed: types.tg `is_trivially_copyable_walk` / `type_props_walk` treat a Visiting alias identity as infinitely-sized (never bit-copyable) instead of looping |
| INV-RESOLVE-007 | Name Resolution | Trait implementations match trait signatures | error | enforced | the one solver: types.tg `solve_obligation` / `impl_bounds_satisfied` (impl-head unification); exercised by `tests/canary/canary_pos_map_entries_cloned.tg` (Clone-bound collection surface) |
| INV-RESOLVE-008 | Name Resolution | Const expressions evaluate at compile time | error | enforced | types.tg const collector (`const_values` fixpoint re-scan) + `eval_const_size_expr` (literal / const-reference / constant-arithmetic); tested by `tests/canary/canary_pos_fixed_array_const_size.tg` |
| INV-TYPE-001 | Type Checking | All expressions have an inferred or annotated type | error | enforced | types.tg `type_check_typed` (typed HIR; every expression resolves to a Type, Type::Error on failure); exercised by the canary suites |
| INV-TYPE-002 | Type Checking | Function return types match body type | error | enforced | types.tg `type_check_typed` return-body unification |
| INV-TYPE-003 | Type Checking | Binary operators have compatible operand types | error | enforced | types.tg operator typing (type_add_error on mismatch) |
| INV-TYPE-004 | Type Checking | Match arms have consistent return types | error | enforced | types.tg match typing; non-exhaustive matches over closed enums are hard errors (`non-exhaustive match: missing variants`, types.tg) |
| INV-TYPE-005 | Type Checking | Struct field access uses declared field names | error | enforced | types.tg field lookup (unknown field is a TypeError) |
| INV-TYPE-006 | Type Checking | Generic type parameters satisfy trait bounds | error | enforced | types.tg `solve_obligation` (where-clause gating via `impl_bounds_satisfied`); String's `impl Clone/Eq/Hash` (std/core.tg) make the bounds satisfiable — tested by `tests/canary/canary_pos_map_entries_cloned.tg` |
| INV-TYPE-007 | Type Checking | Closures capture variables with correct ownership | error | enforced | closure capture typing (capture tuple carries ownership; `inout capture cannot cross await` — canary_neg_closure_async_inout.tg); resource capture tested by `tests/canary/canary_pos_closure_capture_owner.tg` |
| INV-TYPE-008 | Type Checking | Integer literals fit declared type width | warning | design | no per-width literal range check found in types.tg/parser.tg |
| INV-TYPE-009 | Type Checking | Enum variant construction matches variant signature | error | enforced | types.tg variant construction typing |
| INV-TYPE-010 | Type Checking | Trait objects use dyn keyword | error | partial | `dyn Trait` parses to the trait-object form (types.tg `Type::Dyn(TypeId)`; parser.tg dyn handling); no rejection of a bare trait-object position exists |
| INV-OWN-001 | Access Checking | Per-call access overlap is exclusive for Modify/Consume/Initialize | error | enforced+tested | access_check.tg overlap rules (Read coexists; Modify/Consume/Initialize exclusive); `tests/canary_neg` access canaries (`canary_neg_access_inout_dup.tg`, `canary_neg_access_inout_readmut.tg`, `canary_neg_access_sink_twice.tg`) |
| INV-OWN-002 | Access Checking | At most one mutable access is active per call | error | enforced+tested | access_check.tg Modify-vs-Modify exclusivity; `tests/canary_neg/canary_neg_access_inout_dup.tg` |
| INV-OWN-003 | Access Checking | Access duration is the containing call | error | enforced | the typed access effects are per-call records (types.tg `typed_access_effects`, `record_arg_effect`); duration cannot outlive the call because no reference value exists (E106) |
| INV-OWN-004 | Access Checking | Fixed struct fields are statically disjoint under access checks | error | enforced+tested | access_check.tg `Field` projections (typed field identity — distinct fields never overlap); `tests/canary/canary_access_inout.tg` and the access positives |
| INV-OWN-005 | Resource Checking | Resource locals are consumed at most once per CFG path | error | enforced+tested | resource_check.tg state dataflow (Live/Consumed per path, merge inconsistency rejected); `tests/canary_neg` resource canaries (`canary_neg_resource_use_after_consume.tg`, `canary_neg_resource_double_deinit.tg`) |
| INV-OWN-006 | Resource Checking | Capabilities are transferred exactly once | error | enforced+tested | resource_check.tg `validate_capability_exit` + capability consumption tracking; `tests/canary/canary_capability.tg`, `tests/canary_neg/canary_neg_capability_*.tg` |
| INV-OWN-007 | Resource Checking | Resources created in a loop are consumed per iteration | error | enforced+tested | resource_check.tg loop rule (loop-created resources must be consumed per iteration); `tests/canary/canary_pos_resource_loop_auto_clean.tg`, `tests/canary/canary_resource_loop_fixedpoint.tg` |
| INV-OWN-008 | Resource Checking | Resources are auto-deinitialized at scope exit in declaration reverse order | error | enforced+tested | finalize plans (resource_check.tg) materialized by the MIR cleanup chains in reverse drop order (mir.tg `emit_cleanup_chain`); `tests/canary/canary_pos_resource_nested_scope.tg`, `canary_pos_resource_nested_return.tg` |
| INV-LOWER-001 | MIR Lowering | Every AST function produces at least one MIR basic block | error | enforced | mir.tg `verify_function_v2` ("function has no blocks"); `tests/verifier_projection_tests.tg` (verifier unit tests) |
| INV-LOWER-002 | MIR Lowering | All local variables are allocated in scope | error | enforced | mir.tg verifier `valid_locals` checks (locals table + storage statements); `tests/verifier_projection_tests.tg` |
| INV-LOWER-003 | MIR Lowering | Terminators are only at block ends | error | enforced | MIR structure by construction (`MirBlock.terminator`; statements never follow it) — verified by the verifier's per-block walk |
| INV-LOWER-004 | MIR Lowering | Phi nodes reference valid predecessor blocks | error | enforced | mir.tg `verifier_dataflow_init` phi validation (entries == predecessors, no foreign preds, incoming local initialized); `tests/verifier_projection_tests.tg` |
| INV-LOWER-005 | MIR Lowering | Struct field accesses lower to typed offsets | error | enforced+tested | mir.tg `Field(FieldId)` projections + layout_engine offsets; `tests/layout_tests.tg` |
| INV-LOWER-006 | MIR Lowering | Enum variant construction lowers to tagged unions | error | enforced | mir.tg variant/discriminant lowering (verified by the switch coverage + type checks) |
| INV-LOWER-007 | MIR Lowering | Closures capture environment via capture list | error | enforced+tested | mir.tg closure aggregate over the capture tuple; `tests/canary/canary_pos_closure_capture_owner.tg` |
| INV-LOWER-008 | MIR Lowering | Control flow (if/match/loop) lowers to branch instructions | error | enforced | mir.tg `lower_if`/`lower_match`/`lower_for` → MirGoto/MirSwitchInt |
| INV-MIR-001 | MIR Validation | All basic blocks are reachable from entry | error | partial | unreachable blocks are REMOVED by `eliminate_dead_code` (mir.tg, with the side-effect retention rule); the verifier treats unreachable blocks as warnings only (mir.tg — canonical IR spec: "unreachable blocks are warnings only, not errors") |
| INV-MIR-002 | MIR Validation | SSA values are defined before use | error | enforced | MIR is local-slot based with phi nodes; defined-before-use is enforced by mir.tg `verifier_dataflow_init` (definite-init dataflow — uninitialized/consumed uses are errors); `tests/verifier_projection_tests.tg` |
| INV-MIR-003 | MIR Validation | Types in MIR instructions are well-formed | error | enforced | mir.tg `verify_function_v2` type concreteness walk (no Param/Var/Error in concrete MIR, embedded-types walk); `tests/verifier_projection_tests.tg` |
| INV-MIR-004 | MIR Validation | No orphan local variables without definition | error | enforced | mir.tg verifier `valid_locals` / storage-live checks |
| INV-MIR-005 | MIR Validation | Switch targets cover all enum variants | error | partial | match exhaustiveness is enforced CHECKER-side (types.tg: a non-exhaustive match over a closed enum is an error); a verifier-side switch-coverage check is not present |
| INV-MIR-006 | MIR Validation | Function calls match callee signature arity | error | enforced | mir.tg `verifier_check_callees` (arity + callee resolution — every MirFnItem names a lowered function, a known intrinsic, a registered finalizer, or a drop-glue) |
| INV-MIR-007 | MIR Validation | Return instruction type matches function return type | error | enforced | mir.tg verifier return-type check |
| INV-MIR-008 | MIR Validation | Pretty-print output is deterministic and diffable | error | enforced+tested | mir.tg `pretty_print_mir`; the bootstrap ladder's stage2 == stage3 byte-identical determinism gate + `tests/determinism/test_replay.tg` |
| INV-MIR-009 | MIR Validation | MIR serialization round-trips without loss | error | design | no MIR serializer exists — the former claim is re-assigned to `design` (the nearest surface is the deterministic pretty-printer, INV-MIR-008) |
| INV-MIR-010 | MIR Validation | Entry block is always bb0 | error | enforced | mir.tg verifier entry-block existence/identity check (`verifier_block_exists` on `func.entry_block`) |
| INV-OPT-001 | Optimization | Inlining preserves observable behavior | error | enforced | mir.tg `inline_functions` (O2+); every optimization phase is re-verified by `verify_mir` (post-opt) |
| INV-OPT-002 | Optimization | Dead code elimination does not remove side effects | error | enforced | mir.tg `eliminate_dead_code` side-effect retention rule (reachable blocks only; calls/contracts/budgets/effects retained); re-verified post-opt |
| INV-OPT-003 | Optimization | Constant folding preserves value precision | error | enforced | mir.tg `fold_constants`; post-opt `verify_mir` re-checks well-formedness |
| INV-OPT-004 | Optimization | Loop transformations preserve termination | warning | not-applicable | no loop TRANSFORMATION pass exists (LICM only hoists invariant computations; nothing rewrites loops) |
| INV-OPT-005 | Optimization | Common subexpression elimination is correct | error | enforced | mir.tg `global_value_numbering` (O2+); post-opt `verify_mir` |
| INV-OPT-006 | Optimization | Register allocation spills are correctly inserted | error | not-applicable | there is no register allocator — codegen is direct stack-frame + register-targeted emission (codegen.tg) |
| INV-OPT-007 | Optimization | Optimized MIR passes all MIR validation invariants | error | enforced+tested | `verify_mir` runs after every phase (post-lower, post-mono, post-opt — compile_file_core); `tests/verifier_projection_tests.tg` |
| INV-OPT-008 | Optimization | No new undefined values introduced by optimization | error | enforced | post-opt `verify_mir` dataflow re-check |
| INV-CODEGEN-001 | Code Generation | Output assembly is syntactically valid | error | enforced+tested | asm.tg/object.tg emitters (relocations resolved at link); `tests/arm64` encoder/ABI tests + every canary link-and-runs |
| INV-CODEGEN-002 | Code Generation | All MIR instructions have codegen mappings | error | enforced | codegen.tg exhaustive dispatch over MirStatementKind/MirRvalueKind/MirTerminatorKind with fail-closed `panic("codegen_statement/terminator: unsupported ...")` arms — an unmapped instruction is an ICE, never silent |
| INV-CODEGEN-003 | Code Generation | Calling convention matches target ABI | error | enforced+tested | codegen.tg value-category classification (`classify_value_category`, `arg_reg`) on both arches; `tests/arm64/test_arm64_abi.tg` |
| INV-CODEGEN-004 | Code Generation | Stack frame layout is consistent | error | enforced | codegen.tg prologue/epilogue (FP/LR, callee-saved survival — `tests/canary/test_canary_callee_saved_survival.tg`) |
| INV-CODEGEN-005 | Code Generation | Debug information maps back to source spans | error | design | `generate_dwarf_debug_info` exists (object.tg) but has NO caller in any compile path; `opts.debug_info` is inert (language.md flags table) — the former claim is re-assigned to `design` |
| INV-CODEGEN-006 | Code Generation | Global constants are emitted in data sections | error | enforced | codegen.tg/object.tg data emission for statics/constants |
| INV-CODEGEN-007 | Code Generation | Type layouts match target pointer size | error | enforced+tested | layout_engine.tg (pointer_size-driven sizes); `tests/layout_tests.tg` |
| INV-CODEGEN-008 | Code Generation | Variant tag size matches enum variant count | error | enforced | layout_engine.tg enum layout (discriminant sizing) |
| INV-ABI-001 | ABI | Function signatures match platform calling convention | error | enforced+tested | codegen.tg ABI classification + `tests/arm64/test_arm64_abi.tg` (aarch64 host; x64 cross lane via `tests/run_target_lane_canaries.sh`) |
| INV-ABI-002 | ABI | Struct layout follows platform struct alignment rules | error | enforced+tested | layout_engine.tg (repr(C) layout); `tests/layout_tests.tg` |
| INV-ABI-003 | ABI | FFI bridge validates type compatibility | error | partial | the extern ABI classification is verified (mir.tg `verify_function_v2` known-ABI strings); the FFI-safe-type CHECKER the interop.md claims ("Type is not FFI-safe") is not implemented — no pass rejects non-FFI-safe types at extern boundaries |
| INV-ABI-004 | ABI | Extern blocks declare valid ABI strings | error | enforced | mir.tg `verify_function_v2` (unknown extern ABI classification is a structural error; a non-extern function carrying a tag is an error) |
| INV-ABI-005 | ABI | Pointer types carry correct mutability annotations | error | enforced | `Ptr` vs `PtrMut` are distinct type forms (types.tg); the extern-ABI parser maps the spellings exactly |
| INV-ABI-006 | ABI | Variadic functions use correct va_list protocol | warning | design | no variadic function support exists |
| INV-ABI-007 | ABI | Trait objects use consistent vtable layout | error | design | the vtable machinery is DELETED (trait_resolve.tg records the deletion); `Type::Dyn` exists but no vtable emission exists |
| INV-ABI-008 | ABI | Cross-compilation targets have complete ABI specs | error | partial | the x86-64 lane (SysV + Windows x64: HeapAlloc/HeapFree pairing) and the aarch64 Windows path (VirtualAlloc/VirtualFree) are implemented and cross-compiled by the target-lane canaries; wasm32 is not wired into the driver/codegen; "complete specs" for every advertised target are not established |
