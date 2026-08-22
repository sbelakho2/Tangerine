# Tangerine Compiler Invariants Catalog

GENERATED EVIDENCE — do not edit by hand. The machine-readable
registry is `invariants.toml` (id, stage, severity, summary, status,
assertion implementation, positive/negative/mutation tests, target
coverage, last verified SHA). This document is rendered by
`scripts/gen_invariants.sh`; the CI evidence-gate job regenerates it
and runs `git diff --exit-code`.

Last verified SHA: `9ae5778e8e3dd4d53d44b36a122e4e565be299b7`  ·  Registry version: `3`

## Status policy

Every invariant is either **implemented** (backed by an assertion
implementation — `file:function` — and by positive/negative/mutation
tests that exercise it) or **scoped** (the claim is explicitly removed
from the verified callable: the surface does not exist in the callable
path, the machinery is deleted, the option is inert, the construct is
rejected by the bootstrap subset, or the enforceable core is asserted
elsewhere — the `scoping` text states the concrete action). There are no
`partial` / `design` / `eventually` / `TODO` statuses: every former
gap is classified as **implemented-with-assertions** or
**explicitly-scoped** (see the classification table).

## Classification of former gaps

| ID | Former status | Classification | Status | Assertion / scoping |
|----|---------------|----------------|--------|----------------------|
| INV-ABI-003 | partial | explicitly-scoped | scoped | the 'Type is not FFI-safe' rejection claim is removed from the verified set: no pass rejects non-FFI-safe types at extern boundaries; the enforceable core (ABI classification) remains asserted at mir.tg verify_function_v2 (INV-ABI-004) |
| INV-ABI-006 | design | explicitly-scoped | scoped | the claim's surface does not exist in the callable: variadic functions are not part of the dialect (no va_list protocol, no variadic parse); the invariant is removed from the verified set with this justification |
| INV-ABI-007 | design | explicitly-scoped | scoped | the surface is removed from the callable on both fronts: the vtable machinery is deleted in tg_compiler (no emission exists), and the stage0 subset rejects type-position dyn/impl (E9032) so no bootstrap program can construct a trait object |
| INV-ABI-008 | partial | explicitly-scoped | scoped | the completeness claim is narrowed: the registry asserts the implemented lanes (x64 SysV/Win64, aarch64 Windows via target-lane canaries) and scopes 'complete specs for every advertised target' — wasm32 is wired into the driver (compile_to_wasm_route) and the codegen (wasm_target.tg emission); the conformance lane is the structural wasm parser + the optional wasmtime execution |
| INV-CODEGEN-005 | design | explicitly-scoped | scoped | the surface is removed from the callable: generate_dwarf_debug_info has no caller, and the -g flag is rejected with the explicit 'debug info is not supported' error (the inert debug_info option is gone — no compile path can emit debug info, so the claim is removed from the verified set) |
| INV-MIR-001 | partial | explicitly-scoped | scoped | the claim is re-scoped to the DCE removal rule: dead blocks cannot survive in optimized MIR (the removal is asserted), and the verifier's warning-only stance for pre-opt MIR is the documented contract (canonical_ir_spec.md); the reachability-as-error claim is removed from the verified set |
| INV-MIR-005 | partial | explicitly-scoped | scoped | the verifier-side switch-coverage claim is removed: exhaustiveness is already asserted at the type checker (INV-TYPE-004), and MIR lowering only produces switch terms for checker-validated matches — the duplicate claim is scoped out |
| INV-MIR-009 | design | explicitly-scoped | scoped | the serialization claim is removed from the verified set: no serializer exists in the callable; the former claim is re-assigned to the deterministic pretty-printer (INV-MIR-008) |
| INV-OPT-004 | not-applicable | explicitly-scoped | scoped | the claim's surface does not exist in the callable: there is no loop-transformation pass to violate termination; the invariant is removed from the verified set with this justification |
| INV-OPT-006 | not-applicable | explicitly-scoped | scoped | the claim's surface does not exist in the callable: there is no register allocator (codegen.tg direct emission); the invariant is removed from the verified set with this justification |
| INV-PARSE-002 | design | implemented-with-assertions | implemented | stage0_swift/Sources/TangerineCompiler/SemanticGates.swift:SourceLoader |
| INV-PARSE-003 | design | implemented-with-assertions | implemented | stage0_swift/Sources/TangerineCompiler/SemanticGates.swift:NumericLiteralGuard |
| INV-PARSE-007 | design | implemented-with-assertions | implemented | stage0_swift/Sources/TangerineCompiler/ASTVerifier.swift:verifySpan |
| INV-PARSE-008 | design | implemented-with-assertions | implemented | stage0_swift/Sources/TangerineCompiler/ASTVerifier.swift:verifySpan |
| INV-RESOLVE-005 | partial | explicitly-scoped | scoped | front-end extern symbol binding is link-time (linker.tg) by design — no front-end resolution claim is made; the enforceable core (ABI classification) remains asserted at mir.tg verify_function_v2 |
| INV-TYPE-008 | design | implemented-with-assertions | implemented | tg_compiler/types.tg:check_integer_literal_range |
| INV-TYPE-010 | partial | explicitly-scoped | scoped | bootstrap callable surface removed: SubsetChecker E9032 rejects type-position dyn/impl, so no bootstrap program can reach a bare trait-object position; the stage3 parser has no trait-object type to begin with (dyn/impl desugar to the plain trait) |

## Invariants

| ID | Stage | Description | Severity | Status | Assertion / scoping | Verified SHA |
|----|-------|-------------|----------|--------|---------------------|--------------|
| INV-ABI-001 | ABI | Function signatures match platform calling convention | error | implemented | tg_compiler/codegen.tg:classify_value_category | 9ae5778e8e |
| INV-ABI-002 | ABI | Struct layout follows platform struct alignment rules | error | implemented | tg_compiler/layout_engine.tg:compute_type_layout | 9ae5778e8e |
| INV-ABI-003 | ABI | FFI bridge validates type compatibility | error | scoped | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-ABI-004 | ABI | Extern blocks declare valid ABI strings | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-ABI-005 | ABI | Pointer types carry correct mutability annotations | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-ABI-006 | ABI | Variadic functions use correct va_list protocol | warning | scoped | the claim's surface does not exist in the callable: variadic functions are not part of the dialect (no va_list protocol, no variadic parse); the invariant is removed from the verified set with this justification | 9ae5778e8e |
| INV-ABI-007 | ABI | Trait objects use consistent vtable layout | error | scoped | stage0_swift/Sources/TangerineCompiler/SubsetChecker.swift:checkTypeExpr | 9ae5778e8e |
| INV-ABI-008 | ABI | Cross-compilation targets have complete ABI specs | error | scoped | tests/run_target_lane_canaries.sh:run_target_lane_canaries | 9ae5778e8e |
| INV-CODEGEN-001 | Code Generation | Output assembly is syntactically valid | error | implemented | tg_compiler/asm.tg:emit | 9ae5778e8e |
| INV-CODEGEN-002 | Code Generation | All MIR instructions have codegen mappings | error | implemented | tg_compiler/codegen.tg:codegen_statement | 9ae5778e8e |
| INV-CODEGEN-003 | Code Generation | Calling convention matches target ABI | error | implemented | tg_compiler/codegen.tg:classify_value_category | 9ae5778e8e |
| INV-CODEGEN-004 | Code Generation | Stack frame layout is consistent | error | implemented | tg_compiler/codegen.tg:codegen_prologue | 9ae5778e8e |
| INV-CODEGEN-005 | Code Generation | Debug information maps back to source spans | error | scoped | the surface is removed from the callable: generate_dwarf_debug_info has no caller, and the -g flag is rejected with the explicit 'debug info is not supported' error (the inert debug_info option is gone — no compile path can emit debug info, so the claim is removed from the verified set) | 9ae5778e8e |
| INV-CODEGEN-006 | Code Generation | Global constants are emitted in data sections | error | implemented | tg_compiler/codegen.tg:codegen_static | 9ae5778e8e |
| INV-CODEGEN-007 | Code Generation | Type layouts match target pointer size | error | implemented | tg_compiler/layout_engine.tg:compute_type_layout | 9ae5778e8e |
| INV-CODEGEN-008 | Code Generation | Variant tag size matches enum variant count | error | implemented | tg_compiler/layout_engine.tg:compute_enum_layout | 9ae5778e8e |
| INV-FIREWALL-001 | MIR | Post-monomorphization verification is UNCONDITIONAL (the generic substitution is a transformative boundary every build re-proves) | error | implemented | tg_compiler/compiler_core.tg:compile_file_core | 9ae5778e8e |
| INV-FIREWALL-002 | MIR | The final firewall: verify_mir + the completeness oracle immediately before codegen | error | implemented | tg_compiler/compiler_core.tg:compile_file_core | 9ae5778e8e |
| INV-FIREWALL-003 | MIR | A MirSwitchInt discriminant is an integer-like scalar and its target values are pairwise distinct | error | implemented | tg_compiler/mir.tg:verifier_switch_checks | 9ae5778e8e |
| INV-FIREWALL-004 | MIR | Switch target values over an enum must be DECLARED variant discriminants (impossible enum discriminants rejected) | error | implemented | tg_compiler/mir.tg:verifier_switch_checks | 9ae5778e8e |
| INV-FIREWALL-005 | MIR | The block-id universe of one function is disjoint (the exactly-one-terminator rule) | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-LAYOUT-003 | Code generation | Layout size/offset arithmetic is overflow-fail-closed (checked add/mul, ICE on overflow or negative operands) | error | implemented | tg_compiler/layout_engine.tg:layout_checked_add | 9ae5778e8e |
| INV-LAYOUT-004 | Type checking | The fixed-array element count is bounded at the [T; N] annotation (the user-input path into layout arithmetic) | error | implemented | tg_compiler/types.tg:MAX_FIXED_ARRAY_ELEMS | 9ae5778e8e |
| INV-LOWER-001 | MIR Lowering | Every AST function produces at least one MIR basic block | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-LOWER-002 | MIR Lowering | All local variables are allocated in scope | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-LOWER-003 | MIR Lowering | Terminators are only at block ends | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-LOWER-004 | MIR Lowering | Phi nodes reference valid predecessor blocks | error | implemented | tg_compiler/mir.tg:verifier_dataflow_init | 9ae5778e8e |
| INV-LOWER-005 | MIR Lowering | Struct field accesses lower to typed offsets | error | implemented | tg_compiler/mir.tg:lower_place | 9ae5778e8e |
| INV-LOWER-006 | MIR Lowering | Enum variant construction lowers to tagged unions | error | implemented | tg_compiler/mir.tg:enum_variant_name_matches | 9ae5778e8e |
| INV-LOWER-007 | MIR Lowering | Closures capture environment via capture list | error | implemented | tg_compiler/mir.tg:lower_pending_closures | 9ae5778e8e |
| INV-LOWER-008 | MIR Lowering | Control flow (if/match/loop) lowers to branch instructions | error | implemented | tg_compiler/mir.tg:lower_if | 9ae5778e8e |
| INV-MIR-001 | MIR Validation | All basic blocks are reachable from entry | error | scoped | tg_compiler/mir.tg:eliminate_dead_code | 9ae5778e8e |
| INV-MIR-002 | MIR Validation | SSA values are defined before use | error | implemented | tg_compiler/mir.tg:verifier_dataflow_init | 9ae5778e8e |
| INV-MIR-003 | MIR Validation | Types in MIR instructions are well-formed | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-MIR-004 | MIR Validation | No orphan local variables without definition | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-MIR-005 | MIR Validation | Switch targets cover all enum variants | error | scoped | tg_compiler/types.tg:check_match | 9ae5778e8e |
| INV-MIR-006 | MIR Validation | Function calls match callee signature arity | error | implemented | tg_compiler/mir.tg:verifier_check_callees | 9ae5778e8e |
| INV-MIR-007 | MIR Validation | Return instruction type matches function return type | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-MIR-008 | MIR Validation | Pretty-print output is deterministic and diffable | error | implemented | tg_compiler/mir.tg:pretty_print_mir | 9ae5778e8e |
| INV-MIR-009 | MIR Validation | MIR serialization round-trips without loss | error | scoped | the serialization claim is removed from the verified set: no serializer exists in the callable; the former claim is re-assigned to the deterministic pretty-printer (INV-MIR-008) | 9ae5778e8e |
| INV-MIR-010 | MIR Validation | Entry block is always bb0 | error | implemented | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-OPT-001 | Optimization | Inlining preserves observable behavior | error | implemented | tg_compiler/mir.tg:inline_functions | 9ae5778e8e |
| INV-OPT-002 | Optimization | Dead code elimination does not remove side effects | error | implemented | tg_compiler/mir.tg:eliminate_dead_code | 9ae5778e8e |
| INV-OPT-003 | Optimization | Constant folding preserves value precision | error | implemented | tg_compiler/mir.tg:fold_constants | 9ae5778e8e |
| INV-OPT-004 | Optimization | Loop transformations preserve termination | warning | scoped | the claim's surface does not exist in the callable: there is no loop-transformation pass to violate termination; the invariant is removed from the verified set with this justification | 9ae5778e8e |
| INV-OPT-005 | Optimization | Common subexpression elimination is correct | error | implemented | tg_compiler/mir.tg:global_value_numbering | 9ae5778e8e |
| INV-OPT-006 | Optimization | Register allocation spills are correctly inserted | error | scoped | the claim's surface does not exist in the callable: there is no register allocator (codegen.tg direct emission); the invariant is removed from the verified set with this justification | 9ae5778e8e |
| INV-OPT-007 | Optimization | Optimized MIR passes all MIR validation invariants | error | implemented | tg_compiler/compiler_core.tg:compile_file_core | 9ae5778e8e |
| INV-OPT-008 | Optimization | No new undefined values introduced by optimization | error | implemented | tg_compiler/mir.tg:verifier_dataflow_init | 9ae5778e8e |
| INV-ORACLE-001 | Type checking | The semantic completeness oracle audits every typed channel at the typecheck tail; any residual Type::Error / Type::Var / Param-in-concrete-position is an ICE-class error | error | implemented | tg_compiler/types.tg:run_semantic_completeness_oracle | 9ae5778e8e |
| INV-ORACLE-002 | Type checking | Every recorded call-target and finalizer DefId is a resolver-registered symbol | error | implemented | tg_compiler/types.tg:run_semantic_completeness_oracle | 9ae5778e8e |
| INV-ORACLE-003 | Type checking | Every typed FieldId / VariantId names an existing field/variant of its owner type | error | implemented | tg_compiler/types.tg:oracle_check_field_id | 9ae5778e8e |
| INV-ORACLE-004 | Type checking | Every typed call's receiver and arguments carry the recorded per-node access effect | error | implemented | tg_compiler/types.tg:oracle_walk_typed_expr | 9ae5778e8e |
| INV-ORACLE-005 | Type checking | Every registered trait impl is backed by its trait's declared contract (the obligation-solution backstop) | error | implemented | tg_compiler/types.tg:run_semantic_completeness_oracle | 9ae5778e8e |
| INV-ORACLE-006 | MIR | The MIR completeness oracle proves every post-mono type has a computable layout (fail-closed) | error | implemented | tg_compiler/compiler_core.tg:run_mir_completeness_oracle | 9ae5778e8e |
| INV-ORACLE-007 | Type checking | Every named TypeId the typed channels reference is a registered nominal (the unknown-layout precursor) | error | implemented | tg_compiler/types.tg:run_semantic_completeness_oracle | 9ae5778e8e |
| INV-OWN-001 | Access Checking | Per-call access overlap is exclusive for Modify/Consume/Initialize | error | implemented | tg_compiler/access_check.tg:check_overlaps | 9ae5778e8e |
| INV-OWN-002 | Access Checking | At most one mutable access is active per call | error | implemented | tg_compiler/access_check.tg:check_overlaps | 9ae5778e8e |
| INV-OWN-003 | Access Checking | Access duration is the containing call | error | implemented | tg_compiler/types.tg:record_arg_effect | 9ae5778e8e |
| INV-OWN-004 | Access Checking | Fixed struct fields are statically disjoint under access checks | error | implemented | tg_compiler/access_check.tg:check_overlaps | 9ae5778e8e |
| INV-OWN-005 | Resource Checking | Resource locals are consumed at most once per CFG path | error | implemented | tg_compiler/resource_check.tg:resource_check | 9ae5778e8e |
| INV-OWN-006 | Resource Checking | Capabilities are transferred exactly once | error | implemented | tg_compiler/resource_check.tg:validate_capability_exit | 9ae5778e8e |
| INV-OWN-007 | Resource Checking | Resources created in a loop are consumed per iteration | error | implemented | tg_compiler/resource_check.tg:resource_check | 9ae5778e8e |
| INV-OWN-008 | Resource Checking | Resources are auto-deinitialized at scope exit in declaration reverse order | error | implemented | tg_compiler/mir.tg:emit_cleanup_chain | 9ae5778e8e |
| INV-PANIC-001 | Runtime | panic=abort is the ONLY stable panic strategy; the compiler rejects any stable panic=unwind request | error | implemented | std/core.tg:panic | 9ae5778e8e |
| INV-PARSE-001 | Lexing | All tokens carry source location spans | error | implemented | tg_compiler/token.tg:struct Token | 9ae5778e8e |
| INV-PARSE-002 | Lexing | String literals are UTF-8 validated | error | implemented | stage0_swift/Sources/TangerineCompiler/SemanticGates.swift:SourceLoader | 9ae5778e8e |
| INV-PARSE-003 | Lexing | Numeric literals fit in host integer range | warning | implemented | stage0_swift/Sources/TangerineCompiler/SemanticGates.swift:NumericLiteralGuard | 9ae5778e8e |
| INV-PARSE-004 | Parsing | Every parsed item has a non-empty span | error | implemented | tg_compiler/parser.tg:parse_item | 9ae5778e8e |
| INV-PARSE-005 | Parsing | Block bodies terminate with `end` keyword | error | implemented | tg_compiler/parser.tg:parse_block_body | 9ae5778e8e |
| INV-PARSE-006 | Parsing | Function declarations have at least a name | error | implemented | tg_compiler/parser.tg:parse_function_decl | 9ae5778e8e |
| INV-PARSE-007 | Parsing | Spans are well-ordered (start ≤ end) for non-synthetic nodes | error | implemented | stage0_swift/Sources/TangerineCompiler/ASTVerifier.swift:verifySpan | 9ae5778e8e |
| INV-PARSE-008 | Parsing | Inverted spans are detected and reported by the verifier | error | implemented | stage0_swift/Sources/TangerineCompiler/ASTVerifier.swift:verifySpan | 9ae5778e8e |
| INV-PARSE-009 | Parsing | Duplicate top-level names produce a diagnostic | warning | implemented | tg_compiler/resolver.tg:record_item_def | 9ae5778e8e |
| INV-PARSE-010 | Parsing | Macro declarations are preserved in AST | error | implemented | tg_compiler/parser.tg:parse_macro_decl | 9ae5778e8e |
| INV-PARSE-011 | Parsing | Attributes attach to exactly one item | error | implemented | tg_compiler/parser.tg:parse_attributes | 9ae5778e8e |
| INV-PARSE-012 | Parsing | Use declarations form valid module paths | error | implemented | tg_compiler/compiler_core.tg:merge_imported_deps | 9ae5778e8e |
| INV-RELOC-001 | Link | Relocation offsets are WIDTH-AWARE section-bounded (offset + patch width <= len, overflow-safe) | error | implemented | tg_compiler/object.tg:validate_object_file | 9ae5778e8e |
| INV-RELOC-002 | Link | Every relocation names a symbol the object carries | error | implemented | tg_compiler/object.tg:validate_object_file | 9ae5778e8e |
| INV-RELOC-003 | Link | The AArch64 ADRP/ADD pair invariants: page relocation at O must pair with its lo12 at O+4 for the SAME symbol (and vice versa) | error | implemented | tg_compiler/object.tg:validate_aarch64_adrp_add_pairs | 9ae5778e8e |
| INV-RESOLVE-001 | Name Resolution | All references resolve to a declaration | error | implemented | tg_compiler/resolver.tg:resolve_names | 9ae5778e8e |
| INV-RESOLVE-002 | Name Resolution | No ambiguous name references remain | error | implemented | tg_compiler/resolver.tg:bare_name_resolve | 9ae5778e8e |
| INV-RESOLVE-003 | Name Resolution | Use imports are validated against module graph | error | implemented | tg_compiler/compiler_core.tg:merge_imported_deps | 9ae5778e8e |
| INV-RESOLVE-004 | Name Resolution | Visibility rules are enforced for cross-module refs | error | implemented | tg_compiler/resolver.tg:resolve_names | 9ae5778e8e |
| INV-RESOLVE-005 | Name Resolution | Extern declarations resolve to ABI symbols | warning | scoped | tg_compiler/mir.tg:verify_function_v2 | 9ae5778e8e |
| INV-RESOLVE-006 | Name Resolution | Type aliases expand without cycles | error | implemented | tg_compiler/types.tg:is_trivially_copyable_walk | 9ae5778e8e |
| INV-RESOLVE-007 | Name Resolution | Trait implementations match trait signatures | error | implemented | tg_compiler/types.tg:solve_obligation | 9ae5778e8e |
| INV-RESOLVE-008 | Name Resolution | Const expressions evaluate at compile time | error | implemented | tg_compiler/types.tg:eval_const_size_expr | 9ae5778e8e |
| INV-TYPE-001 | Type Checking | All expressions have an inferred or annotated type | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-TYPE-002 | Type Checking | Function return types match body type | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-TYPE-003 | Type Checking | Binary operators have compatible operand types | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-TYPE-004 | Type Checking | Match arms have consistent return types | error | implemented | tg_compiler/types.tg:check_match | 9ae5778e8e |
| INV-TYPE-005 | Type Checking | Struct field access uses declared field names | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-TYPE-006 | Type Checking | Generic type parameters satisfy trait bounds | error | implemented | tg_compiler/types.tg:solve_obligation | 9ae5778e8e |
| INV-TYPE-007 | Type Checking | Closures capture variables with correct ownership | error | implemented | tg_compiler/types.tg:scan_closure_captures | 9ae5778e8e |
| INV-TYPE-008 | Type Checking | Integer literals fit declared type width | warning | implemented | tg_compiler/types.tg:check_integer_literal_range | 9ae5778e8e |
| INV-TYPE-009 | Type Checking | Enum variant construction matches variant signature | error | implemented | tg_compiler/types.tg:type_check_typed | 9ae5778e8e |
| INV-TYPE-010 | Type Checking | Trait objects use dyn keyword | error | scoped | stage0_swift/Sources/TangerineCompiler/SubsetChecker.swift:checkTypeExpr | 9ae5778e8e |

## Test matrix

| ID | Positive | Negative | Mutation |
|----|----------|----------|----------|
| INV-ABI-001 | tests/arm64/test_arm64_abi.tg, tests/run_target_lane_canaries.sh |  |  |
| INV-ABI-002 | tests/layout_tests.tg |  |  |
| INV-ABI-003 | tests/differential/corpus/14_extern_unsafe.tg |  |  |
| INV-ABI-004 | tests/differential/corpus/14_extern_unsafe.tg |  |  |
| INV-ABI-005 | tests/differential/corpus/14_extern_unsafe.tg |  |  |
| INV-ABI-006 |  |  |  |
| INV-ABI-007 |  | tests/differential/negative/neg_dyn_trait.tg, tests/differential/negative/neg_impl_trait.tg |  |
| INV-ABI-008 | tests/run_target_lane_canaries.sh |  |  |
| INV-CODEGEN-001 | tests/arm64/*.tg, tests/canary/*.tg |  |  |
| INV-CODEGEN-002 | tests/canary/*.tg |  |  |
| INV-CODEGEN-003 | tests/arm64/test_arm64_abi.tg |  |  |
| INV-CODEGEN-004 | tests/canary/test_canary_callee_saved_survival.tg |  |  |
| INV-CODEGEN-005 |  |  |  |
| INV-CODEGEN-006 | tests/differential/corpus/10_consts_statics_aliases.tg |  |  |
| INV-CODEGEN-007 | tests/layout_tests.tg |  |  |
| INV-CODEGEN-008 | tests/layout_tests.tg |  |  |
| INV-FIREWALL-001 | tests/canary/*.tg |  |  |
| INV-FIREWALL-002 | tests/canary/*.tg |  |  |
| INV-FIREWALL-003 | tests/canary/*.tg |  |  |
| INV-FIREWALL-004 | tests/canary/*.tg |  |  |
| INV-FIREWALL-005 | tests/canary/*.tg |  |  |
| INV-LAYOUT-003 | tests/layout/differential_layout_test.tg, tests/layout_tests.tg |  |  |
| INV-LAYOUT-004 | tests/layout/differential_layout_test.tg |  |  |
| INV-LOWER-001 | tests/verifier_projection_tests.tg |  |  |
| INV-LOWER-002 | tests/verifier_projection_tests.tg |  |  |
| INV-LOWER-003 | tests/verifier_projection_tests.tg |  |  |
| INV-LOWER-004 | tests/verifier_projection_tests.tg |  |  |
| INV-LOWER-005 | tests/layout_tests.tg |  |  |
| INV-LOWER-006 | tests/differential/corpus/04_enums_matches.tg |  |  |
| INV-LOWER-007 | tests/canary/canary_pos_closure_capture_owner.tg |  |  |
| INV-LOWER-008 | tests/differential/corpus/05_loops.tg, tests/differential/corpus/13_control_flow.tg |  |  |
| INV-MIR-001 | tests/differential/corpus/*.tg |  |  |
| INV-MIR-002 | tests/verifier_projection_tests.tg |  |  |
| INV-MIR-003 | tests/verifier_projection_tests.tg |  |  |
| INV-MIR-004 | tests/verifier_projection_tests.tg |  |  |
| INV-MIR-005 | tests/differential/corpus/04_enums_matches.tg |  |  |
| INV-MIR-006 | tests/verifier_projection_tests.tg |  |  |
| INV-MIR-007 | tests/verifier_projection_tests.tg |  |  |
| INV-MIR-008 | tests/determinism/test_replay.tg |  |  |
| INV-MIR-009 |  |  |  |
| INV-MIR-010 | tests/verifier_projection_tests.tg |  |  |
| INV-OPT-001 | tests/differential/corpus/*.tg |  |  |
| INV-OPT-002 | tests/differential/corpus/*.tg |  |  |
| INV-OPT-003 | tests/differential/corpus/*.tg |  |  |
| INV-OPT-004 |  |  |  |
| INV-OPT-005 | tests/differential/corpus/*.tg |  |  |
| INV-OPT-006 |  |  |  |
| INV-OPT-007 | tests/verifier_projection_tests.tg |  |  |
| INV-OPT-008 | tests/verifier_projection_tests.tg |  |  |
| INV-ORACLE-001 | tests/canary/*.tg, tests/resource_cfg/cfg_oracle_test.tg |  |  |
| INV-ORACLE-002 | tests/canary/*.tg |  |  |
| INV-ORACLE-003 | tests/canary/*.tg, tests/verifier_projection_tests.tg |  |  |
| INV-ORACLE-004 | tests/canary/*.tg |  |  |
| INV-ORACLE-005 | tests/canary/*.tg |  |  |
| INV-ORACLE-006 | tests/layout/differential_layout_test.tg, tests/layout/test_golden_layout.tg |  |  |
| INV-ORACLE-007 | tests/canary/*.tg |  |  |
| INV-OWN-001 | tests/canary/canary_access_inout.tg | tests/canary_neg/canary_neg_access_inout_dup.tg, tests/canary_neg/canary_neg_access_inout_readmut.tg, tests/canary_neg/canary_neg_access_sink_twice.tg |  |
| INV-OWN-002 | tests/canary/canary_access_inout.tg | tests/canary_neg/canary_neg_access_inout_dup.tg |  |
| INV-OWN-003 | tests/canary/*.tg |  |  |
| INV-OWN-004 | tests/canary/canary_access_inout.tg |  |  |
| INV-OWN-005 | tests/canary/canary_pos_resource_loop_auto_clean.tg | tests/canary_neg/canary_neg_resource_use_after_consume.tg, tests/canary_neg/canary_neg_resource_double_deinit.tg |  |
| INV-OWN-006 | tests/canary/canary_capability.tg | tests/canary_neg/canary_neg_capability_copy.tg, tests/canary_neg/canary_neg_capability_discard.tg |  |
| INV-OWN-007 | tests/canary/canary_pos_resource_loop_auto_clean.tg, tests/canary/canary_resource_loop_fixedpoint.tg |  |  |
| INV-OWN-008 | tests/canary/canary_pos_resource_nested_scope.tg, tests/canary/canary_pos_resource_nested_return.tg |  |  |
| INV-PANIC-001 | tests/canary/*.tg |  |  |
| INV-PARSE-001 | tests/canary/*.tg |  |  |
| INV-PARSE-002 | tests/differential/corpus/02_strings.tg | tests/differential/negative/not_utf8.tg | stage0_swift/Sources/TangerineTestRunner/main.swift |
| INV-PARSE-003 | tests/differential/corpus/01_defs_arith.tg, tests/differential/corpus/10_consts_statics_aliases.tg | tests/differential/negative/neg_int_overflow.tg, tests/differential/negative/neg_int_overflow_hex.tg | stage0_swift/Sources/TangerineTestRunner/main.swift |
| INV-PARSE-004 | tests/differential/corpus/*.tg |  |  |
| INV-PARSE-005 | tests/differential/corpus/*.tg | tests/canary_neg/canary_neg_ref_pattern.tg |  |
| INV-PARSE-006 | tests/differential/corpus/01_defs_arith.tg |  |  |
| INV-PARSE-007 | tests/differential/corpus/*.tg |  | stage0_swift/Sources/TangerineTestRunner/main.swift |
| INV-PARSE-008 | tests/differential/corpus/*.tg |  | stage0_swift/Sources/TangerineTestRunner/main.swift |
| INV-PARSE-009 | tests/differential/corpus/*.tg |  |  |
| INV-PARSE-010 | tests/differential/corpus/*.tg |  |  |
| INV-PARSE-011 | tests/differential/corpus/*.tg |  |  |
| INV-PARSE-012 | tests/differential/corpus/08_collections.tg |  |  |
| INV-RELOC-001 | tests/object/relocation_boundary_test.tg |  |  |
| INV-RELOC-002 | tests/object/relocation_boundary_test.tg |  |  |
| INV-RELOC-003 | tests/object/relocation_boundary_test.tg |  |  |
| INV-RESOLVE-001 | tests/differential/corpus/*.tg |  |  |
| INV-RESOLVE-002 | tests/differential/corpus/*.tg |  |  |
| INV-RESOLVE-003 | tests/differential/corpus/08_collections.tg |  |  |
| INV-RESOLVE-004 | tests/differential/corpus/*.tg |  |  |
| INV-RESOLVE-005 | tests/differential/corpus/14_extern_unsafe.tg |  |  |
| INV-RESOLVE-006 | tests/differential/corpus/*.tg |  |  |
| INV-RESOLVE-007 | tests/canary/canary_pos_map_entries_cloned.tg |  |  |
| INV-RESOLVE-008 | tests/canary/canary_pos_fixed_array_const_size.tg |  |  |
| INV-TYPE-001 | tests/canary/*.tg |  |  |
| INV-TYPE-002 | tests/canary/*.tg |  |  |
| INV-TYPE-003 | tests/canary/*.tg |  |  |
| INV-TYPE-004 | tests/differential/corpus/04_enums_matches.tg |  |  |
| INV-TYPE-005 | tests/differential/corpus/03_structs.tg |  |  |
| INV-TYPE-006 | tests/canary/canary_pos_map_entries_cloned.tg |  |  |
| INV-TYPE-007 | tests/canary/canary_pos_closure_capture_owner.tg | tests/canary_neg/canary_neg_closure_async_inout.tg |  |
| INV-TYPE-008 | tests/numeric_literal_gate_e_test.tg | tests/numeric_literal_gate_e_test.tg | tests/numeric_literal_gate_e_test.tg |
| INV-TYPE-009 | tests/differential/corpus/04_enums_matches.tg |  |  |
| INV-TYPE-010 |  | tests/differential/negative/neg_dyn_trait.tg, tests/differential/negative/neg_impl_trait.tg | stage0_swift/Sources/TangerineTestRunner/main.swift |

## Target coverage

| ID | Coverage |
|----|----------|
| INV-ABI-001 | aarch64 host ABI classification; x64 cross lane via target-lane canaries |
| INV-ABI-002 | repr(C) layout |
| INV-ABI-003 | the extern ABI CLASSIFICATION half is asserted (known ABI strings); the FFI-safe-type checker interop.md claims is not implemented |
| INV-ABI-004 | unknown extern ABI classification is a structural error; a non-extern function carrying a tag is an error |
| INV-ABI-005 | Ptr vs PtrMut are distinct type forms; the extern-ABI parser maps the spellings exactly |
| INV-ABI-006 | no variadic function support exists in the dialect |
| INV-ABI-007 | the vtable machinery is DELETED (trait_resolve.tg records the deletion); Type::Dyn exists but no vtable emission exists; the bootstrap subset rejects type-position dyn/impl (E9032) |
| INV-ABI-008 | the implemented lanes are asserted: x86-64 SysV + Windows x64 (HeapAlloc/HeapFree pairing) and aarch64 Windows (VirtualAlloc/VirtualFree) cross-compiled by the target-lane canaries |
| INV-CODEGEN-001 | relocations resolved at link; every canary links and runs |
| INV-CODEGEN-002 | exhaustive dispatch over MirStatementKind/MirRvalueKind/MirTerminatorKind with fail-closed panic arms — an unmapped instruction is an ICE, never silent |
| INV-CODEGEN-003 | value-category classification on both arches |
| INV-CODEGEN-004 | FP/LR + callee-saved survival |
| INV-CODEGEN-005 | the -g flag is REJECTED at the argument parse ("debug info is not supported") — generate_dwarf_debug_info (object.tg) has no caller in any compile path, and opts.debug_info can never be set by a CLI invocation |
| INV-CODEGEN-006 | data emission for statics/constants |
| INV-CODEGEN-007 | pointer_size-driven sizes |
| INV-CODEGEN-008 | discriminant sizing |
| INV-FIREWALL-001 | verify_mir runs after monomorphize_program in every mode (Dev/Strict/Production/Hardened); the per-pass optimizer checkpoints remain gated on the verify-everything policy |
| INV-FIREWALL-002 | the exact IR instance codegen receives is re-proven right before the EmitMode dispatch; a corruption introduced between the post-opt checkpoint and codegen is caught |
| INV-FIREWALL-003 | the discriminant's static type must be Int/UInt/ISize/USize/I8..I128/U8..U128/Bool/Char — never a float/pointer/aggregate/unresolved type; duplicate target values are rejected (a duplicated arm is unreachable-by-construction) |
| INV-FIREWALL-004 | when the discriminant type is an enum, every MirSwitchInt target value is checked against the MirTypeDef's variant discriminant set — an impossible discriminant is a lowering/optimization corruption (the checker enforces source-side exhaustiveness; this is the IR-side mirror) |
| INV-FIREWALL-005 | two MirBlock records sharing one id would make 'one terminator per block' ambiguous; duplicates are rejected alongside the reachable-placeholder check |
| INV-LAYOUT-003 | layout_align_up, compute_tuple_layout, compute_struct_layout, compute_enum_layout, closure_object_record, and inline_array_storage_size use the checked arithmetic; a wrapped size/offset can never silently reach codegen |
| INV-LAYOUT-004 | a negative or > 2^26 count is a stable diagnostic at resolve_type_expr's FixedArray site, and eval_const_size_expr returns None on overflowing const arithmetic — the user-input path can never overflow the engine's checked arithmetic |
| INV-LOWER-001 | function-has-no-blocks check |
| INV-LOWER-002 | valid_locals checks (locals table + storage statements) |
| INV-LOWER-003 | MirBlock.terminator structure; per-block walk |
| INV-LOWER-004 | entries == predecessors, no foreign preds, incoming local initialized |
| INV-LOWER-005 | Field(FieldId) projections + layout_engine offsets |
| INV-LOWER-006 | variant/discriminant lowering verified by switch coverage + type checks |
| INV-LOWER-007 | closure aggregate over the capture tuple |
| INV-LOWER-008 | lower_if/lower_match/lower_for -> MirGoto/MirSwitchInt |
| INV-MIR-001 | unreachable blocks are REMOVED by eliminate_dead_code with the side-effect retention rule; the verifier treats unreachable blocks as warnings only — the canonical IR spec contract |
| INV-MIR-002 | definite-init dataflow — uninitialized/consumed uses are errors |
| INV-MIR-003 | no Param/Var/Error in concrete MIR; embedded-types walk |
| INV-MIR-004 | valid_locals / storage-live checks |
| INV-MIR-005 | exhaustiveness is enforced CHECKER-side (non-exhaustive match over a closed enum is an error); a verifier-side switch-coverage check does not exist and is not needed |
| INV-MIR-006 | arity + callee resolution (lowered function / intrinsic / finalizer / drop-glue) |
| INV-MIR-007 | verifier return-type check |
| INV-MIR-008 | stage2 == stage3 byte-identical determinism gate |
| INV-MIR-009 | no MIR serializer exists; the nearest surface is the deterministic pretty-printer (INV-MIR-008) |
| INV-MIR-010 | verifier_block_exists on func.entry_block |
| INV-OPT-001 | every optimization phase re-verified by verify_mir (post-opt) |
| INV-OPT-002 | reachable blocks only; calls/contracts/budgets/effects retained; re-verified post-opt |
| INV-OPT-003 | post-opt verify_mir re-checks well-formedness |
| INV-OPT-004 | no loop-transformation pass exists — LICM only hoists invariant computations; nothing rewrites loops |
| INV-OPT-005 | post-opt verify_mir |
| INV-OPT-006 | no register allocator exists — codegen is direct stack-frame + register-targeted emission |
| INV-OPT-007 | verify_mir runs after every phase (post-lower, post-mono, post-opt) |
| INV-OPT-008 | post-opt verify_mir dataflow re-check |
| INV-ORACLE-001 | the extended verify_codegen_readiness scans expr types, typed-HIR records, local bindings, fn signatures, static types (Param-in-concrete-position flagged), solved generic-call substitutions (must be fully concrete — ZERO-INFERENCE), alias inners, struct/enum field tables, and deinit-plan types; user mistakes are recorded earlier with stable diagnostics, so a placeholder reaching the oracle is an internal invariant failure |
| INV-ORACLE-002 | the oracle builds the def_id_numeric registry from ResolvedNames.module_symbols values and checks every typed.call_targets and typed.deinit_targets entry against it; an unknown DefId would reach MIR/codegen |
| INV-ORACLE-003 | the oracle walks the typed-HIR tree (Field/Variant nodes), the typed patterns, the flat field_targets, the pattern_variant_resolutions, and the deinit plans; an index out of range or an unknown owner is an ICE-class error |
| INV-ORACLE-004 | for every Call node in the typed tree: a Def callee must have a call_targets entry, a present receiver must carry receiver_effect, and every argument node must have a typed_access_effects entry |
| INV-ORACLE-005 | validate-first-register-second: an impl whose TraitId is registered but whose trait_contracts entry is missing would silently skip conformance validation — the oracle rejects that state as a missing obligation solution |
| INV-ORACLE-006 | after monomorphization, after optimization, and immediately before codegen: every function signature/local type, every static type, and every registered type definition must pass layout_of_concrete (Var/Error/Param/unregistered named types fail closed); runs alongside verify_mir at every boundary |
| INV-ORACLE-007 | the type_fields / type_variants / deinit_plans keys must all be present in type_kinds — an unknown TypeId can never have a layout; the full layout availability is proven by INV-ORACLE-006 at the MIR boundary |
| INV-OWN-001 | Read coexists; Modify/Consume/Initialize exclusive |
| INV-OWN-002 | Modify-vs-Modify exclusivity |
| INV-OWN-003 | typed access effects are per-call records; duration cannot outlive the call because no reference value exists (E106) |
| INV-OWN-004 | Field projections use typed field identity — distinct fields never overlap |
| INV-OWN-005 | Live/Consumed state dataflow; merge inconsistency rejected |
| INV-OWN-006 | capability consumption tracking |
| INV-OWN-007 | loop-created resources must be consumed per iteration |
| INV-OWN-008 | finalize plans materialized as MIR cleanup chains in reverse drop order |
| INV-PANIC-001 | panic runs the hook then __intrinsic_abort — no unwinding, no catch, no resumption on the stable path; --panic-strategy unwind is rejected at the option boundary (driver.tg parse_args / parse_startup_compile_args); the catch_unwind/catch_panic/resume_unwind/try_invoke APIs are EXPERIMENTAL and make no cleanup claims; the abort path does NOT run finalizers/defers and no partial-destruction claim is made |
| INV-PARSE-001 | token span field set at every lexer construction site; error positions render from token spans |
| INV-PARSE-002 | the E9029 byte-level decode gate runs before any lexing; the lexer operates on a decoded String, valid UTF-8 by construction |
| INV-PARSE-003 | E9030 parse-time range gate over the host UInt64 magnitude domain (decimal/hex/binary/octal, separators, u/i suffix spellings incl. `8_u`); an overflow is a diagnostic, and MIRLowering.parseInt preserves the bit pattern for the unsigned domain (the kernel's u64 FNV hash constants) — never a silent `?? 0` |
| INV-PARSE-004 | item spans derive from the item's token range (span_merge of first..last token) |
| INV-PARSE-005 | unterminated blocks fail with a positioned diagnostic; exercised by parse-error canaries |
| INV-PARSE-006 | a missing function name fails the parse |
| INV-PARSE-007 | V0001: every non-synthetic AST span (items, exprs, types, patterns, stmts, clauses) must satisfy 0 <= start <= end; wired into parse/check/scan/dump/hash/lower/diff |
| INV-PARSE-008 | the same V0001 assertion detects AND reports inverted spans (start > end) with the violating node context |
| INV-PARSE-009 | per-module duplicate rejection (first-wins module tables) |
| INV-PARSE-010 | ItemMacro items; the compiler is macro-driven (64-pass fixpoint, E105 on non-convergence — compiler_core.tg prepare_parsed) |
| INV-PARSE-011 | attribute collection attaches to the following item |
| INV-PARSE-012 | module-table rebuild over the compiler's own std imports |
| INV-RELOC-001 | a relocation patches `width` bytes (8 for R_X86_64_64/R_AARCH64_ABS64, 4 otherwise), so offset == len and offset in (len - width, len) are rejected; the check is width > len - offset after offset <= len — never offset + width, which could wrap; the boundary suite covers offset==len, len-1, len-4, Int-max, negative, 8-byte widths, and the wrong-kind class |
| INV-RELOC-002 | a relocation for a symbol with no symbol-table entry (defined or classified extern) fails the link — the linker never guesses a target for it |
| INV-RELOC-003 | ADR_PREL_PG_HI21/ARM64_RELOC_PAGE21 at O requires ADD_ABS_LO12_NC/ARM64_RELOC_PAGEOFF12 at O+4 with the same symbol; a lone, split, mis-offset, or mismatched-symbol pair fails the link — the address computation would carry the wrong low bits |
| INV-RESOLVE-001 | strict resolution on every compile path (compiler_core.tg analyze_parsed); unknown names are hard errors |
| INV-RESOLVE-002 | cross-module ambiguity verification; same-module duplicates rejected |
| INV-RESOLVE-003 | dependency merge fails on a missing module |
| INV-RESOLVE-004 | visibility checks on cross-module references |
| INV-RESOLVE-005 | the ABI CLASSIFICATION half is asserted (known ABI strings C/System/Ruby/Tangerine); the symbol-BINDING half is link-time by design |
| INV-RESOLVE-006 | structural walks terminate: a Visiting alias identity is infinitely-sized (never bit-copyable) instead of looping |
| INV-RESOLVE-007 | impl-head unification via impl_bounds_satisfied |
| INV-RESOLVE-008 | const_values fixpoint re-scan + literal/const-reference/constant-arithmetic evaluation |
| INV-TYPE-001 | typed HIR: every expression resolves to a Type, Type::Error on failure |
| INV-TYPE-002 | return-body unification |
| INV-TYPE-003 | operator typing fails with a positioned TypeError on mismatch |
| INV-TYPE-004 | match typing; non-exhaustive matches over closed enums are hard errors |
| INV-TYPE-005 | unknown field is a TypeError |
| INV-TYPE-006 | where-clause gating via impl_bounds_satisfied; String's impl Clone/Eq/Hash make the bounds satisfiable |
| INV-TYPE-007 | capture tuple carries ownership; inout capture cannot cross await; resource capture tested |
| INV-TYPE-008 | per-width exact-bound checks against integer_type_bounds (u8..i128, suffix ranges, folded negation) via the end-of-check pass resolve_pending_literal_ranges + int_literal_unify_range_check; float gates via check_float_literal_range (f64 finite / f32 exact); the lexer preserves arbitrary-precision digit strings — the overflow is ONE stable diagnostic, never a silent 0/0.0 |
| INV-TYPE-009 | variant construction typing |
| INV-TYPE-010 | the stage0 subset rejects dyn/impl in type position (E9032); the stage3 parser desugars dyn Trait/impl Trait to the plain trait type (no trait-object type exists in the dialect) |

---

Generated by `scripts/gen_invariants.sh` from `invariants.toml`.
Registry version 3; last verified SHA 9ae5778e8e3dd4d53d44b36a122e4e565be299b7.
