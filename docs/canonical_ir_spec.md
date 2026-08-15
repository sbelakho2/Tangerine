# Tangerine Canonical IR Specification — MIR
## Version 1.0.0

### Name
**MIR** (Mid-level Intermediate Representation)

### Role
MIR is the compiler's canonical narrow waist. All stages below type checking
target MIR, and all stages above codegen consume MIR.

```
Source → Tokens → AST → [Type Check] → [Access Check] → [Resource Check] → MIR → [Optimize] → Codegen → Object → Executable
                                                                           ^^^
                                                                     Canonical IR
```

---

## Core Data Structures

### MirProgram
Top-level container holding all compilation units.
- `functions: Vec[MirFunction]`
- `statics: Vec[MirStatic]`
- `type_defs: Vec[MirTypeDef]`

### MirFunction
A single function in MIR form.
- `name: String`
- `params: Vec[MirLocal]`
- `return_type: MirType`
- `locals: Vec[MirLocal]` (all named locals and temporaries)
- `blocks: Vec[MirBlock]` (basic blocks forming CFG)
- `entry_block: BlockId`
- `is_async: Bool`, `is_unsafe: Bool`, `is_extern: Bool`
- `contracts: Vec[MirContract]` (pre/post/invariant)

### MirBlock
A basic block in the control-flow graph.
- `id: BlockId`
- `statements: Vec[MirStatement]`
- `terminator: MirTerminator`

### MirStatement
| Kind | Description |
|------|-------------|
| Assign(Place, MirRvalue) | Assignment: `place = rvalue` |
| StorageLive(LocalId) | Marks local as live |
| StorageDead(LocalId) | Marks local as dead |
| SetDiscriminant(Place, Int) | Sets enum discriminant |
| Nop | No operation |
| ContractCheck(MirContract) | Pre/post/invariant check |
| BudgetRecord(BudgetEntry) | Budget accounting |
| EffectRecord(EffectEntry) | Effect tracking |

### MirTerminator
| Kind | Description |
|------|-------------|
| Goto(BlockId) | Unconditional jump |
| Return | Return from function |
| SwitchInt(Operand, Vec[SwitchTarget], BlockId) | Multi-way branch |
| Call(Place, Operand, Vec[Operand], BlockId, Option[BlockId]) | Function call |
| Drop(Place, BlockId, Option[BlockId]) | Drop value |
| Assert(Operand, Bool, AssertMessage, BlockId) | Runtime assertion |
| Yield(Operand, BlockId) | Yield (async/generator) |
| Unreachable | Proven unreachable |
| Abort | Abnormal termination |

### Place and Projections
A Place is a `LocalId` plus a chain of projections:
| Projection | Description |
|-----------|-------------|
| Deref | Dereference pointer/reference |
| Field(usize) | Access struct field by index |
| Index(LocalId) | Array indexing |
| ConstantIndex(usize) | Compile-time constant index |
| Downcast(usize) | Enum variant downcast |

### MirOperand
| Kind | Description |
|------|-------------|
| Copy(Place) | Non-consuming read |
| Move(Place) | Consuming read (ownership transfer) |
| Constant(MirConstant) | Literal value |

### MirConstant
| Kind | Description |
|------|-------------|
| Unit | `()` |
| Bool(bool) | Boolean literal |
| Int(i64) | Integer literal |
| Float(f64) | Floating-point literal |
| Char(char) | Character literal |
| Str(String) | String literal |
| FnItem(String) | Function reference |
| ZeroSized | Zero-sized type value |

### MirRvalue
| Kind | Description |
|------|-------------|
| Use(Operand) | Simple copy/move |
| Ref(BorrowKind, Place) | Create reference |
| AddressOf(Mutability, Place) | Create raw pointer |
| Aggregate(AggregateKind, Vec[Operand]) | Construct struct/tuple/array/closure |
| BinaryOp(BinOp, Operand, Operand) | Binary operation |
| UnaryOp(UnOp, Operand) | Unary operation |
| Discriminant(Place) | Read enum discriminant |
| Len(Place) | Array/slice length |
| Cast(CastKind, Operand, MirType) | Type cast |
| Repeat(Operand, usize) | Array repeat `[val; N]` |
| Phi(Vec[MirPhi]) | SSA phi node |

---

## Structural Invariants

### INV-MIR-001: Entry Block Exists
Every MirFunction has an `entry_block` that refers to a valid block in `blocks`.

### INV-MIR-002: Terminator Completeness
Every MirBlock has exactly one MirTerminator.

### INV-MIR-003: Successor Validity
All block references in terminators (Goto, SwitchInt, Call, Drop, Assert) point to valid BlockIds.

### INV-MIR-004: Local Validity
All Place and Operand references use LocalIds that are defined in the function's `locals` or `params`.

### INV-MIR-005: Storage Directive Validity
StorageLive and StorageDead reference valid LocalIds.

### INV-MIR-006: Reachability
All blocks are reachable from the entry block via the CFG. Unreachable blocks are removed or flagged.

### INV-MIR-007: Single Assignment per Statement
Each Assign statement defines exactly one Place.

### INV-MIR-008: Move Semantics
A Move operand consumes the place. After a Move, the place is not used before re-assignment.

### INV-MIR-009: Terminator Coverage
SwitchInt terminators with an `otherwise` target cover all cases not explicitly listed.

---

## Verifier

The MIR verifier (`verify_mir()` in mir.tg) validates invariants INV-MIR-001 through INV-MIR-006.

Verifier returns `Vec[String]` of error messages. An empty vector means the MIR is valid.

---

## Consumers

| Consumer | What it reads | Source file |
|----------|--------------|-------------|
| Optimizer | MirProgram (transforms in place) | mir.tg |
| Codegen | MirProgram → instruction selection + register allocation | codegen.tg |
| Pretty-printer | MirProgram → human-readable text | mir.tg |
| PGO instrumenter | MirProgram (adds counters) | mir.tg |
| Async transformer | MirFunction (generates state machine) | mir.tg |

---

## Optimization Passes Operating on MIR

| Pass | Level | Description |
|------|-------|-------------|
| Dead Code Elimination | O1+ | Remove unreachable blocks |
| Copy Propagation | O1+ | Simplify copy chains |
| Constant Folding | O1+ | Evaluate compile-time expressions |
| Global Value Numbering | O2+ | Eliminate redundant computations |
| Loop-Invariant Code Motion | O2+ | Hoist invariant code from loops |
| Bounds-Check Elimination | O2+ | Remove proven-safe bounds checks |
| Escape Analysis | O2+ | Promote heap → stack for non-escaping allocations |
| Function Inlining | O2+ | Inline small functions (≤30 stmts, ≤5 blocks) |
| SSA Conversion | Infrastructure | Insert phi nodes using dominance frontiers |
| PGO-guided Optimization | O3+ | Hot path optimization, loop unrolling |

---

## Transitional IRs

| IR | Status | Boundary |
|----|--------|----------|
| AST (parsed) | Non-canonical | Verified at parse boundary |
| AST (typed) | Non-canonical | Verified at type-check boundary |
| AST (access/resource-checked) | Non-canonical | Verified at access/resource-check boundary |
| MIR (lowered from AST) | **CANONICAL** | Verified by MIR verifier |
| MIR (optimized) | **CANONICAL** | Should be re-verified (Stage 5 work) |
| CodeBuffer (from codegen) | Non-canonical | Not independently verified |

All non-canonical IRs are consumed only by the immediately following stage.
Only MIR flows to multiple downstream consumers (optimizer, codegen, pretty-printer).

---

## Pretty-Print Format

MIR can be serialized to a human-readable, diffable text format via `pretty_print_mir()`:

```
fn function_name(param1: Type1, param2: Type2) -> ReturnType {
    let mut _0: ReturnType;
    let _1 /* param1 */: Type1;
    let _2 /* param2 */: Type2;

    bb0: {
        _0 = _1 + _2;
        return;
    }
}
```

This format is stable for debugging and snapshot comparison.
