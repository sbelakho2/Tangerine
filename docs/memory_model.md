# Tangerine Memory Model (Normative)

**Version:** 1.0.0
**Status:** normative
**Last Updated:** August 2026

This document is the normative specification of Tangerine's memory model.
It describes the model the self-hosted compiler implements today
(`tg_compiler/`), not a design. Where this document and a compiler source
file disagree, the compiler source file wins and this document is wrong.

The migration that produced this model is recorded as history in
[`access_resource_migration.md`](access_resource_migration.md); this
document supersedes that plan. Companion documents: the pipeline stage
order is [`pipeline_manifest.md`](pipeline_manifest.md), the invariant
catalog of the wider compiler is [`invariants.md`](invariants.md), the
language surface is [`language.md`](language.md), the IR-level cleanup
details are [`canonical_ir_spec.md`](canonical_ir_spec.md), and FFI
guidance is [`interop.md`](interop.md).

---

## Table of Contents

1. [Scope and Pipeline Position](#1-scope-and-pipeline-position)
2. [Access Conventions](#2-access-conventions)
3. [The Access Marker (`&place`)](#3-the-access-marker-place)
4. [Resource Linearity](#4-resource-linearity)
5. [Capabilities](#5-capabilities)
6. [Copy vs Clone vs Move vs Drop](#6-copy-vs-clone-vs-move-vs-drop)
7. [TypeProperties](#7-typeproperties)
8. [The Module Graph and the Identity System](#8-the-module-graph-and-the-identity-system)
9. [The Type Representation](#9-the-type-representation)
10. [Iteration](#10-iteration)
11. [The Raw-Pointer Unsafe Boundary](#11-the-raw-pointer-unsafe-boundary)
12. [Smart-Pointer Semantics](#12-smart-pointer-semantics)
13. [Monomorphization](#13-monomorphization)
14. [The CFG/Cleanup Model](#14-the-cfgcleanup-model)
15. [The Invariant Catalog](#15-the-invariant-catalog)

---

## 1. Scope and Pipeline Position

Memory safety in Tangerine is enforced by four compiler stages, in this
order (see `docs/pipeline_manifest.md`):

| # | Stage | Source | What it enforces |
|---|-------|--------|------------------|
| 4 | Type checking | `tg_compiler/types.tg` | types, generics, bounds, and the **typed access effects** of every call argument and method receiver |
| 5 | Access checking | `tg_compiler/access_check.tg` | per-call access-overlap exclusivity (Modify/Consume/Initialize vs Read) |
| 6 | Resource checking | `tg_compiler/resource_check.tg` | resource state flow (Uninitialized/Live/Consumed/MaybeLive), finalize plans, capability exits, iteration plans |
| 7 | MIR lowering | `tg_compiler/mir.tg` | materialization of the cleanup the resource checker planned (deinit emission, defer actions, edge cleanups) |

Monomorphization (stage 8, `tg_compiler/mono.tg`) performs **no**
inference and no ownership analysis (§13); codegen (stage 12,
`tg_compiler/codegen.tg`) only executes what MIR contains.

There is no borrow checker. There are no safe reference types and no
lifetimes; those concepts are not supported by the language. The only
`&` forms are the access marker (§3) and the legacy parameter-modifier
syntax that the parser normalizes away (§2). First-class `&T` / `&mut T`
types are a migration target for deletion (§15).

---

## 2. Access Conventions

Every parameter and every method receiver carries exactly one
**access convention** (`AccessConvention` in `tg_compiler/ast.tg`):

| Convention | Source meaning | Typed effect | Callee obligations |
|------------|----------------|--------------|--------------------|
| `let` | observe only | Read | never consumes, never finalizes by the callee |
| `inout` | exclusive mutation | Modify | may modify but never consumes/escapes the value; caller-owned |
| `sink` | transfer/consume | Consume | owns the value: may consume it; must finalize it if still live |
| `set` | initialize dead storage | Initialize | entry state Uninitialized; must be exactly Live on every return edge (`validate_set_postconditions`) |

The conventions are the type system's replacement for the former
reference kinds. Function types carry them per parameter
(`Type::Function(Vec[ParamType], Type)`; `ParamType { ty, convention }`),
so a function's type records how it accesses each argument.

Sources of a convention:

- Explicit keywords on parameters and receivers: `def f(inout x: T)`, a
  trailing `inout` receiver marker (`def m(self: Self) ... inout`), `sink`,
  `set`. `let` is the default for parameters without a modifier.
- Legacy modifiers are normalized by the parser immediately after parsing
  (one semantic implementation): `&mut T` → `inout T`, `&T` / `&self` →
  `let T`, `move T` / `own T` → `sink T`, `mut x` / `let mut x` → `var x`
  (`var` is an alias of `mut` in the keyword table). The transitional
  `ParamModifier` field is retained during migration and is a deletion
  target (§15).

### 2.1 The typed access effects are authoritative

The type checker derives the effect of every call argument and method
receiver from the callee's declared convention —
`convention_to_effect` (Let→Read, Inout→Modify, Sink→Consume,
Set→Initialize) — and records it per AST node id in
`typed_access_effects` (`types.tg`, `record_arg_effect`; the inner node of
an `&place` marker is recorded with the same effect). Downstream consumers
never re-derive effects from source text:

- The access checker (`access_check.tg`) reads the typed effects through
  `call_arg_effects` / `method_receiver_effect`; a missing entry for a
  well-formed argument is a compiler-internal error, never an assumed
  Read.
- MIR lowering (`mir.tg`) pairs the typed effect with each `MirCallArg`.

### 2.2 Per-call access overlap

The access checker models each argument as an `AccessPath` (root semantic
`LocalId` plus projections) with its typed effect, and rejects conflicting
accesses within one call:

- Reads coexist freely (Read vs Read never conflicts).
- Modify/Consume/Initialize are exclusive with everything except Reads.
- Projections: `Field(FieldId, name)` — typed field identity, so distinct
  fields of a fixed struct are statically disjoint; `Index` — dynamic
  indexing conservatively overlaps; `RawDeref` — unknown alias (§11).
- `self` uses a negative root so it can never collide with a real local id.

### 2.3 E106: first-class `&T` is a migration diagnostic

`&T`, `&mut T` (and `&&T`) in a **general type position** — return types,
struct fields, generic type arguments — is **not a first-class type**. The
parser (`parse_type` in `parser.tg`) emits a warning-level diagnostic:

```
E106: safe reference types are not first-class; use a parameter access
      convention / access operation
```

and recovers by returning the inner type, so the pipeline keeps working
while the transitional reference-returning APIs (`Box.get -> &T`,
`Option[&T]`, `Vec[&T]`, ...) migrate. It is warning-level so the
self-hosted build is not aborted by those APIs; the migration target is
their removal (§15). Parameter annotations are normalized before
`parse_type` is reached, so legacy `&T` parameters never fire E106.

---

## 3. The Access Marker (`&place`)

`&place` (and `&mut place`) in **expression position** is `ExprAccess`
(`ast.tg`) — an **access marker on a place**, never a reference value.
There is no safe reference value: nothing can be stored, returned, or
named as `&T`, and `let r = &x` is not a way to capture a value.

The effect of a marked argument is the effect of the callee's declared
convention (§2.1), not the marker's text: `&x` passed to a `sink`
parameter consumes `x`; `&x` passed to a `let` parameter reads it.
`&mut place` is likewise only a marker (the parser emits the same
`ExprAccess` node for both spellings); the exclusivity comes from the
typed effects, not from the marker spelling.

The access checker treats `ExprAccess` transparently when deriving the
access path (`derive_access_path` recurses through it).

---

## 4. Resource Linearity

### 4.1 Nominal kinds

A type is declared `resource` (`NominalKind::Resource` in `ast.tg` →
`TypeKind::Resource` in `types.tg`) or is a plain `value` type.
Linearity is **viral through containment**: the type-property engine and
the MIR deinit planner compute resource-ness from the substituted concrete
fields, so `struct Wrapper[T] { item: T }` is linear exactly when
`Wrapper[File]` is instantiated with a resource (a Value-kind type with a
registered drop runs its drop — e.g. `Box[T] { ptr }` would otherwise leak
the pointee through a structural walk that sees only a `Ptr`).

### 4.2 Resource state flow

The resource checker (`resource_check.tg`) runs a state dataflow over the
function's flow graph with `ResourceState = Uninitialized | Live |
Consumed | MaybeLive`. Frames are keyed by the semantic `LocalId`
(ids.tg) — a pattern node id can never index the frame. Rules:

- Branch-merge inconsistency (Live on one path, Consumed on another) is
  rejected.
- Loop-created resources must be consumed per iteration.
- A `set` parameter must be exactly Live on every return edge (entry
  Uninitialized, exit Live).
- The **finalize plan** records, per function owner key, the local ids
  that are Live at function end with `Sink`/`OwnedLocal` permission; the
  deinit method's own sink `self` is excluded (recursive
  re-finalization). MIR consumes this plan (mapping semantic ids through
  `semantic_to_mir`) instead of re-deriving ownership from declared
  locals.

### 4.3 The single destruction protocol

Destruction follows **one protocol, exactly once**:

1. **User hook first**: the `deinit(sink self)` method (or the trait
   `Drop::drop(self: &mut Self)`) may inspect and mutate the subject, but
   never consume it or its owned fields.
2. **Structural cleanup after**: the compiler destroys still-live owned
   fields, exactly once, in the order the MIR deinit planner computed
   (`DeinitPlan` per concrete type).

The finalizer's subject is **compiler-owned**: `mark_finalizer_self`
registers it with the `DeinitSelf` permission origin, so the hook body is
checked with permissions that make consumption impossible:

```
cannot consume resource `x`: a finalizer must not consume its own subject
(compiler-owned structural cleanup)
```

The generated wrapper runs the user hook first and the structural field
cleanup after (`mir.tg`, "User finalizer first, then compiler-owned
structural cleanup"). Trait-default finalizer bodies get the same
`DeinitSelf` protection. Destruction is emitted as `MirDeinit`
terminators carrying the place, the **verified** registered deinit name
(fail-closed: an unverifiable name panics at plan construction), and
target/unwind.

### 4.4 Projected-place rejections until partial moves

There is no per-place partial-move state yet. Moving a resource **out of a
projected place** is rejected:

```
cannot consume a projected place: partial moves are not yet supported
cannot move out of a projected place: partial moves are not yet supported
cannot assign over an owning projected place: exact-place replacement is
not yet supported
```

Whole-place moves, match destructuring of resources (an `Option[Resource]`
scrutinee is consumed exactly once), and closure capture of resources
(the outer local is consumed exactly once into the closure frame) all
work. Partial moves are a documented pending item (§15).

---

## 5. Capabilities

`capability` declarations (`CapabilityDecl` in `ast.tg` →
`TypeKind::Capability` in `types.tg`) are **strict linear authority**:
move-only, never copied, never fabricated, never silently abandoned.

The exit invariant (`validate_capability_exit` in `resource_check.tg`):
a live capability reaching a function exit must have been returned,
transferred, delegated, or explicitly consumed by a capability operation.
**An automatic deinitializer must not satisfy its linearity** — an
auto-deinit at scope exit is not an acceptable way to dispose of
authority:

```
capability `x` must be returned, transferred, delegated, or explicitly
consumed before function exit (authority cannot be silently discarded)
```

The type-property engine carries `is_capability` as its own property
(§7); `TypeKind::Capability` is linear by kind.

---

## 6. Copy vs Clone vs Move vs Drop

The final model (`std/core.tg`, "Ownership marker families" — one
distinction per concept):

| Concept | Definition | Notes |
|---------|-----------|-------|
| **Copy** | the semantic guarantee that raw value duplication is valid | decided structurally by `is_trivially_copyable` (§6.1); the primitives and raw pointers only — **String is NOT Copy** |
| **Clone** | the explicit duplication operation | may allocate/retain; **required body** — there is no default (not every Clone type is Copy) |
| **Move** | ownership transfer | the default for non-Copy values |
| **Drop** | destruction | the trait method and the standalone sink drop (`def drop[T](sink x: T)`) |
| Transferable / Shareable | Send / Sync concurrency properties | solved through the obligation solver (§8); the legacy name sets (`non_send_types` / `non_sync_types` in types.tg) are documentation mirrors, not decision inputs |

The transitional `Copyable` trait is **removed**. The `Copy` trait remains
as a source-level marker used by generic bounds on the raw-read APIs
(`get`/`slice`/`entries` in `std::collections`). The obligation solver
special-cases it: when no explicit impl candidate applies, the structural
property decides — a raw bit-copy is valid and requires no retain/clone
(`solve_obligation` in `types.tg`). This is what separates Copy
(bit-copy semantics) from Clone (explicit, may allocate) and from
move/sink (transfer).

### 6.1 `is_trivially_copyable`

`is_trivially_copyable(env, ty)` is the decided bit-copy set:

- **Yes:** all primitives (including the c-FFI spellings), raw pointers
  (`Ptr`/`PtrMut`) regardless of pointee, tuples of trivially-copyable
  elements, `FixedArray` of trivially-copyable elements (the count-0
  array is trivially copyable), `Option`/`Result` over trivially-copyable
  arguments, user structs/enums whose fields/payloads are all
  trivially copyable.
- **No:** `String` and `str` (heap-backed — a bit-copy would duplicate the
  buffer state without the retain/clone it requires), the builtin
  containers (Vec/Array/Map/Set/Slice — including Vec's registered shape
  `{ ptr: Ptr[T], len, cap }`, whose Ptr field must not be walked),
  the owning smart pointers (Box/Rc by LangItems id; UniquePtr/WeakRc/
  ArcStrong/WeakArc by name), resources and capabilities
  (`TypeKind::Resource`/`Capability` are never bit-copyable), closures,
  `dyn`/effect/ref forms, type variables/params/error.
- Recursion through inline storage fails closed: a cycle in the walk means
  the type is infinitely sized — never bit-copyable.

---

## 7. TypeProperties

`TypeProperties { needs_drop, is_linear, is_capability,
is_trivially_copyable }` is the memoized per-type property bundle
computed by `type_properties_of` (`types.tg`).

**`needs_drop` is separate from linearity.** A type can need cleanup
without being linear (e.g. `Rc[T]` — shared ownership) and can be linear
without per-value drop.

- `needs_drop`: true for a type with a registered `impl Drop` (matched by
  the LangItems `drop_trait` TraitId, never by name), for the owning
  smart pointers (Box/Rc by LangItems TypeId; UniquePtr/WeakRc/ArcStrong/
  WeakArc by name — LangItems entries for them are a migration target),
  and for containers whose **concrete arguments** need drop.
- Container `needs_drop` is **content-viral over the concrete args**:
  `Vec[Int]` needs no drop, `Vec[File]` does; the container layer itself
  never owns drop (Vec's registered shape is never walked as owning
  storage).
- `is_linear`: resources/capabilities by nominal kind, and content-linearity
  through fields/variants/args/containers.
- `is_capability`: the `TypeKind::Capability` marker.
- `is_trivially_copyable`: §6.1.

**The graph algorithm:** the walk is memoized in `type_prop_cache` keyed
by a canonical structural key that includes the concrete generic args
(`Wrapper[Int]` and `Wrapper[File]` are distinct entries). Each key goes
`Unvisited → Visiting → Resolved`; a `Visiting` revisit is recursion
through **inline storage** — an infinitely sized recursive type. The
layout engine panics on such types; the property engine reports the
diagnostic instead ("infinitely sized recursive type: inline storage
cycle (use a pointer or Box to break the cycle)") and treats the revisit
as non-owning-but-unsafe (`needs_drop=false`,
`is_trivially_copyable=false`). Indirections (Ptr/Box/Rc) terminate the
walk: their properties are decided by the pointer layer, not the pointee.
The visiting set is local per top-level call (a fresh call must not see a
stale `Visiting` state); cache entries are inserted only once fully
`Resolved`; a depth guard (64) bounds degenerate nesting.

---

## 8. The Module Graph and the Identity System

### 8.1 One module graph

`Program.crate` is the single module table (`ast.tg`):
`Crate { root: ModuleId, modules: Map[ModuleId, Module] }`. Each `Module`
carries its `ModuleId`, a path (diagnostics only), `item_indices` into the
flat `Program.items`, and imports. The root module (id 0) covers the
top-level items; `merge_imported_deps` (`compiler_core.tg`) rebuilds the
module table when dependencies are flattened in.

### 8.2 Identity domains (`ids.tg`)

Every semantic identity is a strong struct over an Int payload, so
cross-domain confusion is hard to express:

| Domain | Payload |
|--------|---------|
| `ModuleId` | the module graph's vertex identity |
| `DefId` | owner `ModuleId` + per-module symbol index — **equality is (module, index) only**; the kind is metadata (the resolver's `def_kind_of`), not part of the identity |
| `TypeId` / `TraitId` / `ImplId` | definition identities |
| `VariantId` | owner TypeId + variant index |
| `GenericParamId` | owner DefId + param index |
| `CallableId` | newtype over DefId (every invocable) |
| `InstanceId` | CallableId + the concrete type substitutions (§13) |
| `ClosureId` | closure identity |
| `CfgBlockId` / `CfgEdgeId` | CFG vertex/edge identities |
| `NodeId` | AST node identity |
| `LocalId` | semantic local identity — the resource checker's frame key; distinct from the MIR's own local-slot domain |
| `FieldId` | owner TypeId + index |
| `StableDefId` | content-based, survives across compilations (hash + canonical key) |

**Strings are not identities.** Module-path strings belong only to
diagnostics and to final symbol mangling; the mangled emission name is
derived at the mangling boundary (`fn_owner_key_of_def` /
`instance_key`) and never compared or keyed as an identity.

### 8.3 The nominal identity

The identity of a definition is its `DefId` (the resolver's
`record_item_def` guarantees one for every top-level function); the
identity of a type is its declaration's `TypeId`; the identity of a trait
is its declaration's `TraitId` (reusing the trait declaration's TypeId
value for the transition; `TraitId(-1)` is the no-registration sentinel).
Builtin behaviors are selected by **LangItems ids, never names**.

### 8.4 LangItems

`LangItems` (`types.tg`) is the bundle of well-known intrinsic
type/trait ids, built **once** at environment initialization after every
builtin registration (`build_lang_items`), with structural uniqueness
assertion (a duplicate id is an ICE). Fields: the nine type ids
`option/result/vec/map/set/box_/rc/array/slice` and the trait ids
`drop_trait/clone_trait/copy_trait/eq_trait/hash_trait/
transferable_trait/shareable_trait`; `-1` marks a name unregistered at
init (Transferable/Shareable are std-declared traits whose TraitIds
arrive through the registry in pass 2). Consumers include: the
special-behavior selector of the Adt form (§9), the container
classification in `is_trivially_copyable` and `type_named_props`, the
`Drop` identity check, the Rc policy, and the resource checker's
non-shareable-type classification.

### 8.5 The one trait solver

There is exactly one trait solver: `solve_obligation` over `env.impls`
(the impl registry) in `types.tg`. Impl applicability, where-clause
obligation gating (`impl_bounds_satisfied`, driven by impl-head
unification), builtin-trait checks, and the Copy structural fallback all
run there. `trait_resolve.tg` is a thin facade (satisfies_trait /
check_where_bounds / implementors_of) and the re-export point for
monomorphization. The former second trait engine — duplicate
candidate ranking, duplicate coherence/orphan checking, AST-side impl
collection, and the vtable machinery — is deleted.

---

## 9. The Type Representation

`Type` (`types.tg`) after the representation collapse (P0-K): the dual
canonical variants (`Type::Option/Result/Map/Set/Box/Rc/Array/Slice`)
are **gone**. The shape is:

- **Primitives** — `Unit Bool Int UInt Float Char String Never`, the
  sized integer/float set for FFI parity (`I8..I128, U8..U128, ISize,
  USize, F32, F64`). `String` is a primitive: heap-backed but
  arena-managed — no per-value drop, never bit-copyable.
- **`Adt(TypeId, Vec[Type])`** — the ONE nominal form, builtin or
  user-defined. `builtin_adt` is the single construction helper for the
  builtins (fail-closed: an unverifiable name yields `Type::Error`,
  never an Adt with an unverifiable id). The LangItems ids select the
  builtin special behaviors (option/result/vec/map/set/box_/rc/array/
  slice). The named `Array[T]` syntax **is** the heap vector — the Vec
  Adt (Array is aliased to Vec); Vec's registered shape is
  `{ ptr: Ptr[T], len, cap }`, where `ptr` is a pointer to the element
  buffer, not an element field.
- **`FixedArray(Type, Int)`** — the `[T; N]` annotation, distinct from
  the heap vector. The count is carried **in the type** (0 is a legal
  zero-length fixed array) and is part of the type identity (the
  identity key renders `FixedArray[<elem>;<n>]`). The size expression
  must be a constant: `fixed array size must be a constant` is a
  TypeError for a non-IntLit size; constant-expression sizes are a
  pending item (§15).
- **`Function(Vec[ParamType], Type)`** — function types carry the
  per-parameter access conventions (§2).
- **`RefInternal(Type, Bool)`** — MIR-only (parameter re-wrap and
  MirRef/MirRefMut typing); not a source-level type.
- **`Ptr(Type)` / `PtrMut(Type)`** — raw pointers (§11). Box/Rc are Adt
  forms of the registered Box/Rc ids, not pointer variants.
- **`Dyn(TypeId)`** — trait objects; **`Effect(Vec[String], Type)`**;
  **`Tuple(Vec[Type])`**; **`Var(TypeVarId)`**; **`Param(String)`**;
  **`Error`**.
- **`Slice`** is a registered builtin Opaque generic Adt (the LangItems
  `slice` id is the special-behavior selector) — the target for
  slice-views of heap data; `str` is registered for the string escape
  (`__intrinsic_string_as_str`). The **String / StrView distinction is a
  target**: today `String` is the single builtin string type; a
  non-owning `StrView` view type over string data is not yet
  implemented (§15).

Normalization at unification: aliases resolve to their underlying type,
the Named primitive spellings map to the canonical variants, Ref/RefMut/
Ptr names unwrap to their payloads, the Rc-of-resource policy applies,
and the id-0 placeholder guard holds. The builtin compound Adt forms pass
through unchanged.

---

## 10. Iteration

`for` loops are compiled from a typed **`IterationPlan`**
(`resource_check.tg`), produced by the resource checker's `check_for` —
the semantic authority (the MIR's old name-use scan is only a documented
fallback for IR-only loops) — and consumed by MIR lowering (`lower_for`,
keyed by the for-stmt node id). Fields:

| Field | Meaning |
|-------|---------|
| `source_kind` | the iterable's projected-iteration class: 0 = array/vec, 1 = map, 2 = set, 3 = range |
| `access` | `Read` = projected iteration; `Consume` = snapshot iteration |
| `element_type` | the per-iteration binding type (Int for ranges) |
| `binding_ids` | the semantic local ids bound by the for pattern, in pattern order |

**Projected mode (`AccessEffect::Read`):** `for item in items` binds the
element **by reference** into the iterated collection — zero-copy, no
clone. The projected-iteration guard (`check_iter_binding_escape`) is the
authority that the binding cannot move out of the loop body, cannot be
captured by a closure escaping the iteration, etc.:

```
cannot move the iteration binding out of the loop body under projected
iteration (consuming iteration is not supported yet)
```

**Snapshot mode (`AccessEffect::Consume`):** each element is copied/moved
into the binding. **Consuming iteration** (a sink element binding with
per-iteration cleanup — backedge cleanup per iteration) is a documented
pending item (§15).

Subscripts and field access on places are projections for the access
checker (§2.2); indexing a resource container is a shared read and must
not extract a resource value.

---

## 11. The Raw-Pointer Unsafe Boundary

Safe code has **no first-class references**. The only way to reach memory
through a pointer is the raw-deref **place** operation: `*ptr` is
`ExprRawDeref` (`ast.tg`), usable only inside `unsafe` blocks. The stdlib
surface is built on it: `*b.get()` reads a boxed value,
`(*b.get()).id` reads a field, `*b.get_mut() = v` writes (§12).

Raw pointers are bit-copyable, non-owning, and terminate ownership walks
(§7: no drop, no linearity from the pointee).

**`RawDeref = UnknownAlias`.** In the access checker, every access path
containing the `RawDeref` projection is classified as potentially
overlapping with every other path — raw derefs may alias any storage, and
two derefs of different pointer variables may address the same memory.
This classification runs **before** root comparison, so a raw deref can
never be proved disjoint by the variables holding the addresses; a
conflicting access through a raw deref is conservatively rejected.

`&place` is not a deref — it is the access marker (§3), and it does not
cross the unsafe boundary.

---

## 12. Smart-Pointer Semantics

The smart pointers in `std/alloc.tg` are ordinary structs over raw
pointers — `Box[T] { ptr: Ptr[T] }`, `UniquePtr[T] { ptr: Ptr[T] }`,
`Rc[T] { ptr: Ptr[RcInner[T]] }` (with `RcInner { value, strong_count,
weak_count }`), plus `WeakRc[T]`, `ArcStrong[T]`, `WeakArc[T]`. There are
no hidden safe references inside owning pointers: `UniquePtr` previously
stored `allocator: &dyn Allocator` — a hidden non-owning reference that
could dangle — and now allocates through the global allocator only.

**The Ptr-based access surface** (the replacement for the former
reference-returning APIs): **no stdlib API returns a safe reference.**
`get`/`get_mut` hand out the raw non-owning pointer — a first-class
handle with no attached validity guarantee — and the caller accesses the
pointee through the raw-deref place operation. The pointer must not be
stored past the point where the box is dropped. `Box.get` additionally
panics on a nulled pointer ("Box: use after drop").

Construction and destruction:

- `box_new` / `unique_ptr_new` / `rc_new` take `sink value` — ownership
  transfers into the heap block.
- `Box::into_inner(sink self)` reads the payload, deallocs the block, and
  returns the value; consuming `self` by the match means the registered
  `Drop` never runs against the already-deallocated pointee.
- `Drop` impls run `drop_in_place`, dealloc, and null the `ptr` field
  (guarding against double drop).
- `Rc::clone` increments the strong count with `__sync_fetch_and_add` —
  shared ownership, **not linear**; `downgrade` gives a `WeakRc`;
  `try_unwrap(sink self)` performs the raw payload move out of the
  control block and releases the block when no weaks remain.

Type properties (§7): Box/Rc (LangItems ids) and UniquePtr/WeakRc/
ArcStrong/WeakArc (name-selected — LangItems entries are a migration
target) are `needs_drop`; Rc is the sole non-linear owning pointer.

---

## 13. Monomorphization

### 13.1 The zero-inference principle

The type checker is the **only** inference engine; the monomorphizer
performs **no call-site inference** (fail-closed):

- Every generic call's substitution is solved during type checking and
  recorded per call node in `typed_call_instances` (in the callee's
  parameter order).
- A generic call whose substitution is only solvable by later
  caller-context unification (e.g. a return-type-only parameter) is
  parked in `pending_call_instances` and re-resolved after the whole
  program is checked (`resolve_pending_call_instances` in
  `type_check_typed`).
- A call a context never solves is a **hard error** at the end of
  checking: `cannot infer type parameter \`T\`: add an annotation`.

### 13.2 InstanceId and the work queue

`InstanceId { def: CallableId, substs: Vec[Type] }` (ids.tg) is a
monomorphized callee's identity: the definition the call resolves to plus
the concrete type substitutions. The instance payload is the **only
authority** for type arguments at the monomorphizer — a generic call that
reaches `monomorphize_program` without a solved instance records an error
and the compilation aborts (`Result::Err`).

`monomorphize_program` (`mono.tg`) is the single instance work queue:

1. **Seed**: scan every function's call sites; enqueue each generic
   callee that carries a solved, fully concrete instance (seen-set
   checked at enqueue time — each instance is popped at most once).
2. **Drain**: pop one instance, specialize its body under the instance
   key, append it to the program, and immediately re-walk the
   specialized body's own calls — transitive discovery. Cache hits skip.
   Residual-param violations and fail-closed gaps abort; a genuine
   infinite expansion is bounded by `MAX_MONO_INSTANCES` (8192) with a
   monomorphization-recursion diagnostic.
3. **Rewrite**: one final pass points every generic call site at its
   mangled instance name.

The instance → mangled-name mapping (`instance_key` /
`mangle_name`) is the symbol-mangling boundary: the DefId render
(`fn_owner_key_of_def` — the crate containment scan of the owner ModuleId
plus the resolver's def_kinds metadata, from the cache's
program/resolutions snapshot, so every render is byte-identical to the
MIR builder's emission-name renders) plus the concrete-substitution
suffix. Deterministic per (def, substs).

---

## 14. The CFG/Cleanup Model

### 14.1 The real edge model

The resource checker analyzes a **real control-flow edge model**
(`CfgEdge` / `CfgEdgeKind` in `resource_check.tg`) — one edge per
control-flow transfer, so the cleanup a transfer requires is attached to
that transfer:

| Edge kind | The transfer |
|-----------|--------------|
| `Normal` | the lexical block's fallthrough |
| `True` / `False` | the if-split branches (no obligation of their own; their cleanups serialize through the branch blocks' Normal edges) |
| `Break` / `Continue` | loop-exit terminators |
| `Return` | a return terminator |
| `Backedge` | the loop body → header backedge |
| `GuardElse` | a guard's else exit (return/break/continue under the guard stmt's id) |

`CfgEdge { kind, source, destination, cleanup_ids }`: `source` is the
semantic node id of the transfer's originator; `destination` is the
static target when one exists (0 for dynamic targets); `cleanup_ids` are
the semantic local ids in reverse drop order that must be finalized on
this edge.

The obligations serialize into the **`edge_cleanup` map** keyed
`edge::<kind>::<source node id>` (e.g. `edge::Return::42`), with values
byte-identical to the compatibility-layer finalize-plan string keys
(`return::<id>`, `break::<id>`, `continue::<id>`, `backedge::<id>`,
`block::<id>`). `validate_cfg_edges` (end of `check_fn_body`) verifies
the model. MIR consults the edge map first and falls back to the string
keys for synthesized/IR-only nodes.

**`CleanupEdge` target.** The finalize-plan string keys are a second, ad
hoc CFG. The documented target is a single semantic
`CleanupEdge { source_cfg_edge, exited_scopes,
locals_in_reverse_drop_order, destination }` attached to each real CFG
edge, so an edge can never accidentally reuse another edge's plan (the
loop-exit double-clean and the nested block::/edge:: double-drop bug
class). MIR would then merely materialize the resolved edge cleanup.
This unification is pending (§15).

### 14.2 defer as an action

`defer` (`StmtDefer`) registers a deferred body in the enclosing lexical
scope:

- The checker's **defer chain** walks scopes LIFO — innermost first, and
  within a scope in reverse registration order — **before** the edge's
  ordinary cleanup. Loop-body scopes are stored negated so
  break/continue/backedge edges stop the walk exactly at the loop
  boundary (which is included); return edges exit every scope and run
  the whole chain. The `defer::<block key>` plan carries the defer stmt
  ids in registration order.
- MIR lowering (`mir.tg`, P0-Y) lowers each defer body to a **template
  block** and **clones** it into every exit chain that runs it — one
  scope's defers can run on several distinct exits (fallthrough,
  return, break/continue, backedge), and each exit has its own cleanup
  successor, which a single block cannot express. Defers run **exactly
  once** per exit, before the edge's deinit chain. The builder-side
  registrations are the source-level authority when the checker
  recorded no plan for a scope.

### 14.3 Destruction emission

Deinit plans are computed per **concrete** type (`deinit_plan_for_type`
in `mir.tg`): resource containment can depend on the generic args
(`Wrapper[Int]` vs `Wrapper[File]`), so plans are built from the type
definition with the args substituted. Recursive owning types fail closed
with `PlanLimit` (until generated drop glue exists) rather than silently
expanding. Emission order on every exit: defer actions (LIFO), then the
deinit chain in reverse drop order; the user finalizer first, then the
compiler-owned structural field cleanup — exactly once.

---

## 15. The Invariant Catalog

### 15.1 Enforced today

| Invariant | Where |
|-----------|-------|
| Every parameter/receiver has exactly one access convention; effects derive from it | ast.tg §2; types.tg `convention_to_effect` |
| Typed access effects are authoritative — missing entries are internal errors, never assumed Read | types.tg §2.1; access_check.tg §2.2 |
| Per-call overlap: Reads coexist; Modify/Consume/Initialize exclusive; fixed struct fields statically disjoint; dynamic indexes conservatively overlap | access_check.tg §2.2 |
| Raw deref is UnknownAlias — never proved disjoint | access_check.tg §11 |
| Resource state flow: Uninitialized/Live/Consumed/MaybeLive; merge inconsistency rejected; loop-created resources consumed per iteration | resource_check.tg §4.2 |
| `set` params exactly Live on every return edge | resource_check.tg §4.2 |
| Finalize plans: Live Sink/OwnedLocal locals finalized at exit; edge plans for early exits; the deinit's own sink self excluded | resource_check.tg §4.2 |
| Single destruction protocol: user hook first, structural cleanup after, exactly once; the subject is DeinitSelf — non-consumable | resource_check.tg §4.3; mir.tg §14.3 |
| Capability exit invariants; no automatic deinitializer satisfies linearity | resource_check.tg §5 |
| Projected iteration bindings cannot escape the loop body | resource_check.tg §10 |
| Zero-inference fail-closed: unsolved generic parameters are hard errors; the monomorphizer performs no inference | types.tg / mono.tg §13 |
| LangItems built once, structurally unique; semantic identity by DefId/TypeId/TraitId — never strings | types.tg / ids.tg §8 |
| Type-property graph algorithm with inline-recursion diagnostics; memoized per concrete args | types.tg §7 |
| Monomorphization: seen-set, MAX_MONO_INSTANCES, residual-param aborts | mono.tg §13 |
| CFG edge model recorded and validated per function | resource_check.tg §14 |
| Destruction names verified against registered deinit targets (fail-closed) | mir.tg §4.3 |

### 15.2 Pending (documented targets, not assumptions)

| Item | Current behavior | Target |
|------|------------------|--------|
| **Partial moves** | projected-place consumes/moves/assigns rejected ("partial moves are not yet supported", "exact-place replacement is not yet supported") | per-place partial-move state in the resource checker |
| **Consuming iteration** | snapshot iteration exists; sink-element iteration rejected | consuming iteration with per-iteration (backedge) cleanup |
| **Typed-HIR migration** | finalizer recognition is name-based (`deinit`/`drop`); `ParamModifier` retained transitionally; transitional reference-returning APIs still fire E106 | a typed `FinalizerKind` on method metadata (the deinit-plans/user-finalizer layer); `ParamModifier` deletion; reference-returning API removal (then E106 becomes an error) |
| **Fixed-array size constants** | `[T; N]` requires an IntLit count ("fixed array size must be a constant") | constant-expression sizes in the type identity |
| **StrView** | `String` is the single builtin string type; `str` is the registered escape | the String/StrView distinction (a non-owning view type) |
| **LangItems for the name-selected pointers** | UniquePtr/WeakRc/ArcStrong/WeakArc are name-selected in the property engine and copy analysis | registered LangItems entries |
| **CleanupEdge unification** | finalize-plan string keys + the edge_cleanup map coexist | a single `CleanupEdge` per real CFG edge (§14.1) |
| **Legacy borrow syntax deletion** | `&T`/`&mut T`/`move`/`own` parameter modifiers are normalized at parse; E106 is warning-level | remove the legacy syntax from the parser entirely |

The pending list above is the authoritative one; `access_resource_migration.md`
records the historical status of these items at audit time.
