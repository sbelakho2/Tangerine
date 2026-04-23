# Tangerine Compiler Invariants Catalog

This document defines the formal invariants enforced at each compiler stage.
Every invariant has a unique ID, a description, and a severity level.

## Legend

| Column | Meaning |
|--------|---------|
| ID | Unique invariant identifier |
| Stage | Compiler stage that enforces this invariant |
| Description | What the invariant guarantees |
| Severity | `error` (must fix) or `warning` (advisory) |

## Invariants

| ID | Stage | Description | Severity |
|----|-------|-------------|----------|
| INV-PARSE-001 | Lexing | All tokens carry source location spans | error |
| INV-PARSE-002 | Lexing | String literals are UTF-8 validated | error |
| INV-PARSE-003 | Lexing | Numeric literals fit in host integer range | warning |
| INV-PARSE-004 | Parsing | Every parsed item has a non-empty span | error |
| INV-PARSE-005 | Parsing | Block bodies terminate with `end` keyword | error |
| INV-PARSE-006 | Parsing | Function declarations have at least a name | error |
| INV-PARSE-007 | Parsing | Spans are well-ordered (start ≤ end) for non-synthetic nodes | error |
| INV-PARSE-008 | Parsing | Inverted spans are detected and reported by the verifier | error |
| INV-PARSE-009 | Parsing | Duplicate top-level names produce a diagnostic | warning |
| INV-PARSE-010 | Parsing | Macro declarations are preserved in AST | error |
| INV-PARSE-011 | Parsing | Attributes attach to exactly one item | error |
| INV-PARSE-012 | Parsing | Use declarations form valid module paths | error |
| INV-RESOLVE-001 | Name Resolution | All references resolve to a declaration | error |
| INV-RESOLVE-002 | Name Resolution | No ambiguous name references remain | error |
| INV-RESOLVE-003 | Name Resolution | Use imports are validated against module graph | error |
| INV-RESOLVE-004 | Name Resolution | Visibility rules are enforced for cross-module refs | error |
| INV-RESOLVE-005 | Name Resolution | Extern declarations resolve to ABI symbols | warning |
| INV-RESOLVE-006 | Name Resolution | Type aliases expand without cycles | error |
| INV-RESOLVE-007 | Name Resolution | Trait implementations match trait signatures | error |
| INV-RESOLVE-008 | Name Resolution | Const expressions evaluate at compile time | error |
| INV-TYPE-001 | Type Checking | All expressions have an inferred or annotated type | error |
| INV-TYPE-002 | Type Checking | Function return types match body type | error |
| INV-TYPE-003 | Type Checking | Binary operators have compatible operand types | error |
| INV-TYPE-004 | Type Checking | Match arms have consistent return types | error |
| INV-TYPE-005 | Type Checking | Struct field access uses declared field names | error |
| INV-TYPE-006 | Type Checking | Generic type parameters satisfy trait bounds | error |
| INV-TYPE-007 | Type Checking | Closures capture variables with correct ownership | error |
| INV-TYPE-008 | Type Checking | Integer literals fit declared type width | warning |
| INV-TYPE-009 | Type Checking | Enum variant construction matches variant signature | error |
| INV-TYPE-010 | Type Checking | Trait objects use dyn keyword | error |
| INV-OWN-001 | Borrow Checking | No use-after-move errors | error |
| INV-OWN-002 | Borrow Checking | At most one mutable borrow at a time | error |
| INV-OWN-003 | Borrow Checking | No mutable aliasing through closures | error |
| INV-OWN-004 | Borrow Checking | Lifetime annotations are consistent | error |
| INV-OWN-005 | Borrow Checking | Shared borrows are valid for their duration | error |
| INV-OWN-006 | Borrow Checking | Move semantics preserve linear ownership | error |
| INV-OWN-007 | Borrow Checking | Copy types allow implicit duplication | error |
| INV-OWN-008 | Borrow Checking | Drop order follows declaration reverse order | error |
| INV-LOWER-001 | MIR Lowering | Every AST function produces at least one MIR basic block | error |
| INV-LOWER-002 | MIR Lowering | All local variables are allocated in scope | error |
| INV-LOWER-003 | MIR Lowering | Terminators are only at block ends | error |
| INV-LOWER-004 | MIR Lowering | Phi nodes reference valid predecessor blocks | error |
| INV-LOWER-005 | MIR Lowering | Struct field accesses lower to typed offsets | error |
| INV-LOWER-006 | MIR Lowering | Enum variant construction lowers to tagged unions | error |
| INV-LOWER-007 | MIR Lowering | Closures capture environment via capture list | error |
| INV-LOWER-008 | MIR Lowering | Control flow (if/match/loop) lowers to branch instructions | error |
| INV-MIR-001 | MIR Validation | All basic blocks are reachable from entry | error |
| INV-MIR-002 | MIR Validation | SSA values are defined before use | error |
| INV-MIR-003 | MIR Validation | Types in MIR instructions are well-formed | error |
| INV-MIR-004 | MIR Validation | No orphan local variables without definition | error |
| INV-MIR-005 | MIR Validation | Switch targets cover all enum variants | error |
| INV-MIR-006 | MIR Validation | Function calls match callee signature arity | error |
| INV-MIR-007 | MIR Validation | Return instruction type matches function return type | error |
| INV-MIR-008 | MIR Validation | Pretty-print output is deterministic and diffable | error |
| INV-MIR-009 | MIR Validation | MIR serialization round-trips without loss | error |
| INV-MIR-010 | MIR Validation | Entry block is always bb0 | error |
| INV-OPT-001 | Optimization | Inlining preserves observable behavior | error |
| INV-OPT-002 | Optimization | Dead code elimination does not remove side effects | error |
| INV-OPT-003 | Optimization | Constant folding preserves value precision | error |
| INV-OPT-004 | Optimization | Loop transformations preserve termination | warning |
| INV-OPT-005 | Optimization | Common subexpression elimination is correct | error |
| INV-OPT-006 | Optimization | Register allocation spills are correctly inserted | error |
| INV-OPT-007 | Optimization | Optimized MIR passes all MIR validation invariants | error |
| INV-OPT-008 | Optimization | No new undefined values introduced by optimization | error |
| INV-CODEGEN-001 | Code Generation | Output assembly is syntactically valid | error |
| INV-CODEGEN-002 | Code Generation | All MIR instructions have codegen mappings | error |
| INV-CODEGEN-003 | Code Generation | Calling convention matches target ABI | error |
| INV-CODEGEN-004 | Code Generation | Stack frame layout is consistent | error |
| INV-CODEGEN-005 | Code Generation | Debug information maps back to source spans | error |
| INV-CODEGEN-006 | Code Generation | Global constants are emitted in data sections | error |
| INV-CODEGEN-007 | Code Generation | Type layouts match target pointer size | error |
| INV-CODEGEN-008 | Code Generation | Variant tag size matches enum variant count | error |
| INV-ABI-001 | ABI | Function signatures match platform calling convention | error |
| INV-ABI-002 | ABI | Struct layout follows platform struct alignment rules | error |
| INV-ABI-003 | ABI | FFI bridge validates type compatibility | error |
| INV-ABI-004 | ABI | Extern blocks declare valid ABI strings | error |
| INV-ABI-005 | ABI | Pointer types carry correct mutability annotations | error |
| INV-ABI-006 | ABI | Variadic functions use correct va_list protocol | warning |
| INV-ABI-007 | ABI | Trait objects use consistent vtable layout | error |
| INV-ABI-008 | ABI | Cross-compilation targets have complete ABI specs | error |