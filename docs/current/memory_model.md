# Tangerine Memory Model (Normative)

**Version:** 1.1.0
**Status:** normative
**Last Updated:** September 2026

This document is the normative specification of Tangerine's memory model.
It describes the model the self-hosted compiler implements today
(`tg_compiler/`), not a design. Where this document and a compiler source
file disagree, the compiler source file wins and this document is wrong.

The migration that produced this model is recorded as history in
[`access_resource_migration.md`](../history/access_resource_migration.md); this
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
16. [Atomics and the Language-Level Memory Model](#16-atomics-and-the-language-level-memory-model)

---

## 1. Scope and Pipeline Position

Memory safety in Tangerine is enforced by four compiler stages, in this
order (see docs/current/pipeline_manifest.md):

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
`&` forms are the call-argument access marker (§3) and the
`__intrinsic_`-scoped extern-ABI type positions (§2.3). First-class
`&T` / `&mut T` in a general type position is rejected with the hard
error E106 (§2.3); the legacy parameter-convention spellings (`mut x:` /
`&x:` / `&mut x:` / `move x:` / `own x:` prefixes, `x: &T` / `x: &mut T`
markers, `fn(&T)` conventions, `&self` receivers) are hard **E100**
errors — never normalized (§2); ref patterns are likewise rejected with
E106 ("ref patterns are not supported").

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
  trailing `inout` receiver marker (`def m(self: Self) -> Unit inout`), `sink`,
  `set`. `let` is the default for parameters without a modifier.
- Legacy parameter modifiers are **REJECTED, never normalized** (round-9):
  `mut x:` / `&x:` / `&mut x:` / `move x:` / `own x:` prefixes and the
  `x: &T` / `x: &mut T` type markers fail with the E100 "legacy parameter
  spelling … is removed" diagnostic (`parser.tg` `parse_param` /
  `parse_fn_type_param`); the legacy token is consumed only for error
  recovery and the compile fails. In LOCAL position `mut x = e` remains an
  accepted legacy alias of `var x = e` (`let mut x = e` also parses). The
  transitional `ParamModifier` field is **deleted**: `Param` carries the
  `AccessConvention` directly (`convention` field, ast.tg), so the
  let/inout/sink/set map is the one parameter model — no modifier field
  survives on the AST.

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

### 2.3 E106: first-class `&T` is a hard error

`&T`, `&mut T` (and `&&T`) in a **general type position** — return types,
struct fields, variable annotations, tuple members, generic arguments,
container elements — is **not a first-class type** and is **rejected**. The
parser (`parse_type` in `parser.tg`) records an error-level diagnostic:

```text
E106: safe reference types are not first-class; use a parameter access
      convention / access operation
```

and fails the parse: `parse_type` consumes the `&` constructor and returns
`Option::None` — it **never** erases the reference to its inner type, so a
program cannot write `def bad(...) -> &Thing` and have it silently become
`Thing`. The call site must migrate to a **parameter access convention** —
the explicit keyword forms (`inout x: T` / `sink x: T` / `set x: T`, or
the default `let`) — or an explicit **access operation** (`&place`). The
legacy parameter annotations (`x: &T` / `x: &mut T`, `&self` /
`&mut self`) are consumed by the parameter parser and fail with the E100
legacy-spelling diagnostic before `parse_type` is reached; they never
fire E106 and they are never normalized.

The single exception to the E106 rejection: `&T` / `&mut T` (including
nested positions such as `Option[&K]`) inside an `extern` declaration
whose name carries the `__intrinsic_` prefix parse as the internal
address/reference ABI (typed `RefInternal`). The extern-ABI context is
scoped by name (`parser.tg` `parse_extern_fn` / `parse_extern_static`:
`p.extern_abi_context = is_intrinsic_extern_name(&name)`; `ids.tg`
`is_intrinsic_extern_name` = the `__intrinsic_` prefix). An ordinary
user extern is the strict FFI boundary — its `&` type positions are
E106, and the interop guidance is raw pointers / view structs. The
kernel's five record-visit extern signatures in `std/collections.tg`
are the only such positions in the tree.

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
   `Drop::drop(inout self: Self)`) may inspect and mutate the subject, but
   never consume it or its owned fields.
2. **Structural cleanup after**: the compiler destroys still-live owned
   fields, exactly once, in the order the MIR deinit planner computed
   (`DeinitPlan` per concrete type).

The finalizer's subject is **compiler-owned**: `mark_finalizer_self`
registers it with the `DeinitSelf` permission origin, so the hook body is
checked with permissions that make consumption impossible:

```text
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

**The abort-path resource statement (STATE A — panic=abort):** the
destruction protocol above runs ONLY on normal control flow. A panic
terminates the process after the panic hook (`__intrinsic_abort`); the
abort path runs NO finalizers, NO defers, and NO structural cleanup — it
does not unwind. No partial-destruction claim is made: the contract is
"the process ends; whatever the OS reclaims is reclaimed by the OS".
Code that must observe cleanup must use `Result` for recoverable failure
and must not rely on panic paths (see error_handling.md §Panic and
Unrecoverable Errors). The compiler rejects `--panic-strategy unwind`;
the catch/unwind APIs are experimental and make no cleanup claims.

### 4.4 Partial moves: the place-level registry and the masked glue

There **is** per-place partial-move state. The checker's pattern-binding
sites (`record_place_moves` in types.tg, called at the let-initializer
sites after `check_pattern`) record every Consume binding whose source
place is a projection of a local root: the joined field path (struct
field names / tuple `"t<i>"` segments; nested paths join with `.`) is
marked `Consumed` under the root local in `place_move_states`
(root semantic `LocalId` → path → `PlaceMoveState`), and a binding
through a non-field projection (variant/index/deref) marks the root's
whole value `"*"` Consumed — the bounded lattice: enum payload and index
moves are whole-value. The registry is serialized into the
`TypedProgram` and mirrored by the MIR builder (`b.place_move_states`).

The MIR consumes the registry at the drop sites (the Drop actions of
`emit_cleanup_chain`): a root with per-field records emits the
**partial-drop chain** (`mir_emit_partial_drop_chain`) — each LIVE field
is dropped through its own concrete drop-glue with a constant all-ones
mask (nested consumption recurses over the field's own shape), the
CONSUMED fields emit nothing, and a whole-value (`"*"`) record emits no
drop at all. The drop of the partially-moved value drops exactly the
live fields; the glue's `mask` parameter + the mask-conditioned plan
walk (`emit_plan_deinit`'s mask-local mode) is the DIRECT-call form of
the same conditioning. Match destructuring of resources (an
`Option[Resource]` scrutinee is consumed exactly once) and closure
capture of resources (the outer local is consumed exactly once into the
closure frame) flow through this machinery.

**Direct expression-level consumption of a projected resource place is
still rejected** — the root-level frame cannot prove the field's
storage is dead, so the consume/initialize rules fail closed at
root-granularity:

```text
cannot consume a projected place: partial moves are not yet supported
cannot move out of a projected place: partial moves are not yet supported
cannot assign over an owning projected place: exact-place replacement is
not yet supported
cannot initialize a projected place: exact-place state is not yet supported
```

The registry + masked glue are the implemented base; the expression-level
projected-place operations are the remaining pending item (§15.2).

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

```text
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
- **No:** `String` and `str` (the owned String — a bit-copy would
  duplicate the owned buffer without the required clone), the builtin
  containers (Vec/Array/Map/Set — including Vec's registered shape
  `{ ptr: Ptr[T], len, cap }`, whose Ptr field must not be walked),
  the RAW view (UnsafeSlice — the builtin's `{ptr,len}` words
  are structurally copyable but the view borrows; the raw view is
  unsafe/FFI-only), the SAFE shared/pinned views (the source-spelled
  Slice / StrView —
  the ArcStrong field makes them owning, never bit-copyable),
  the owning smart pointers (Box/Rc by LangItems id; UniquePtr/WeakRc/
  ArcStrong/WeakArc by name), resources and capabilities
  (`TypeKind::Resource`/`Capability` are never bit-copyable), closures,
  `dyn`/effect/ref forms, type variables/params/error.
- Recursion through inline storage fails closed: a cycle in the walk means
  the type is infinitely sized — never bit-copyable.

---

## 7. TypeProperties

`TypeProperties { owns_state, requires_drop_glue, is_linear, is_capability,
contains_capability, is_trivially_copyable, is_deferred }` is the memoized
per-type property bundle computed by `type_properties_of` (`types.tg`). It
is the ONE ownership authority: the resource checker and MIR query it on
the concrete (TypeId, substitutions) identity (`engine_snapshot_env` /
`deinit_plan_for_type`), and no ownership decision re-derives from the
nominal declaration.

**The two ownership axes are SPLIT (P0).** `owns_state` (the value carries
semantic ownership: it must be moved/consumed, never duplicated, and the
resource checker tracks it) and `requires_drop_glue` (the value needs a
physical destructor — the buffer release, a registered Drop, a registered
deinit) are independent:

- **String** is `owns_state=true, requires_drop_glue=true`: the String
  object and its data buffer are REAL heap allocations (the
  `_tg_mem_alloc` / `_tg_mem_free` pair — the same allocator the Vec
  buffers use, never the bump arena), and the MIR's
  `DeinitPlan::String` destructor (`_tg_string_drop`, emitted at the
  value's semantic lifetime boundary) frees BOTH the object and the
  buffer — small blocks re-enter the allocator's per-class free list. A
  bit-copy would duplicate the owned buffer — String is Clone, NOT Copy
  (the `impl Clone/Eq/Hash for String` trait impls in std/core.tg make
  the `[T: Clone]` / `[T: Eq]` / `[T: Hash]` bounds satisfiable).
- `requires_drop_glue` gates the DeinitPlan (drop-glue shape);
  `is_trivially_copyable` is the copy authority (the MIR Copy verifier
  queries this axis, never the DeinitPlan).

The remaining axes:

- `is_linear`: move-only — must be consumed, never duplicated.
- `is_capability` / `contains_capability`: `TypeKind::Capability` markers
  and capability containment through composites (an aggregate with a
  capability field, a container with capability elements).
- `is_deferred`: an unsubstituted generic parameter (or unresolved type
  variable) in the type graph — while deferred, the semantic fields are
  non-authoritative (false = "not proven true"); the concrete answer
  appears after substitution.
- `is_trivially_copyable`: §6.1.
- **P1 (FnPtr/Closure split):** a closure's properties derive from its
  CAPTURE TUPLE (a closure capturing an owning value owns it — the capture
  tuple's owns_state / requires_drop_glue / linearity / capability
  containment propagate); a function pointer (FnPtr — no environment)
  carries none.

**The graph algorithm:** the walk is memoized in `type_prop_cache` keyed
by a canonical structural key that includes the concrete generic args
(`Wrapper[Int]` and `Wrapper[File]` are distinct entries). Each key goes
`Unvisited → Visiting → Resolved`; a `Visiting` revisit is recursion
through **inline storage** — an infinitely sized recursive type. The
layout engine panics on such types; the property engine reports the
diagnostic instead ("infinitely sized recursive type: inline storage
cycle (use a pointer or Box to break the cycle)") and treats the revisit
as non-owning-but-unsafe (`requires_drop_glue=false`,
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
| `ClosureId` | closure identity (P1: the closure TYPE carries it — `Type::Closure(ClosureId, signature, capture tuple)`; the per-compilation identity that makes closures fail closed in the public ABI) |
| `EffectId` | a declared effect's identity (P1: builtins registered with fixed ids; user effects interned module-qualified; the canonical type identity renders the canonical ordered effect-ID set) |
| `IntrinsicId` | the semantic intrinsic-KIND classification (P1: attached by the type checker per intrinsic call; an intrinsic DEFINITION's identity remains its DefKind::Intrinsic DefId) |
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
assertion (a duplicate id is an ICE). Fields: the type ids
`option/result/vec/map/set/box_/rc/array/slice` plus `string`,
`str_view` (the literal view type), `unique_ptr`, `arc_strong`,
`weak_rc`, `weak_arc`, `ptr`, `ptr_mut` (the name-selected smart
pointers and the raw-pointer forms are registered, so the property
engine and the hash/eq dispatch select by id with a name fallback only
for snapshots without a registration), and the trait ids
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

`Type` (`types.tg`): the dual
canonical variants (`Type::Option/Result/Map/Set/Box/Rc/Array/Slice`)
are **gone**. The shape is:

- **Primitives** — `Unit Bool Int UInt Float Char String Never`, the
  sized integer/float set for FFI parity (`I8..I128, U8..U128, ISize,
  USize, F32, F64`). `String` is a primitive and an **owned, mutable
  String object**: the String VALUE is one 8-byte pointer
  (the engine's `StringPtr` value width) to a 32-byte String object
  header — the same shape as the Vec header:
  `{ data: Ptr[u8] @ 0, len: Int @ 8, cap: Int @ 16, stride: Int @ 24 }`,
  where `data` points to the null-terminated UTF-8 byte buffer (`len` =
  byte length, `cap` = byte capacity ≥ 8, `stride` = 1).
  The header is what mutation needs: `push`/`push_str` grow the owned
  buffer in place (the String-object operations are the `_tg_string_*`
  runtime functions on both arches). Semantics: moves transfer the
  buffer, `clone()` allocates a new one, the value is never
  bit-copyable. **Real allocation/deallocation semantics**: the String
  object and its buffer are allocated from the REAL heap allocator
  (`_tg_mem_alloc` — the malloc-style pair with `_tg_mem_free`, the same
  allocator the Vec data buffers use), never the raw bump arena;
  `_tg_string_reserve` releases the OLD buffer at the growth boundary;
  and the String destructor — the MIR's `DeinitPlan::String`, emitted at
  the value's semantic lifetime boundary — calls `_tg_string_drop`,
  which frees BOTH the object and the buffer (small blocks link into the
  allocator's per-class free list). `requires_drop_glue=true` for the
  String split; there is no unbounded arena growth for long-running
  apps.
  **Literals are the static string view**: a string literal expression
  lowers to the interned static bytes behind a raw label (the MIR
  internal `Type::StaticStrPtr` — distinct from the shared StrView, the
  std's Arc-backed view); the conversion to an
  owned String is the explicit owned clone (`String::from_static`, the
  `string_from_static` intrinsic) and the compiler inserts it at every
  owned-String demand site (by-value String parameters — the
  diagnostics, format strings, path strings — String destinations,
  `Vec[String]` literals, concat results, `to_string()`, `clone()`). The
  `str` type denotes the borrowed view: `&str` parameters receive the raw
  static/borrowed bytes without conversion.
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
  identity key renders `FixedArray[<elem>;<n>]`). The size expression is
  evaluated by the compiler's **constant-size evaluator**
  (`eval_const_size_expr` in types.tg) BEFORE the `FixedArray(Type, N)`
  identity forms: integer literals, const references (resolved through
  the collected const-value table `env.const_values` under the module's
  qualified key — `[T; CONST]` and the literal spelling produce the
  SAME identity), and the integer arithmetic operators over constant
  operands (`[T; CONST * 2]`). A non-constant size fails closed:
  `fixed array size must be a constant (an integer literal, a const
  reference, or constant arithmetic)` is a TypeError (exercised by
  `tests/canary/canary_pos_fixed_array_const_size.tg`).
- **`Function(Vec[ParamType], Type)`** — the TRANSITIONAL legacy form
  (P1: the FnPtr/Closure split). New construction sites use the distinct
  semantic forms:
  - **`FnPtr(Vec[ParamType], Type)`** — a function POINTER: the signature
    (parameter access conventions + return) and no environment; layout is
    a single code pointer, bit-copyable, Transferable/Shareable per the
    pointer policy;
  - **`Closure(ClosureId, Vec[ParamType], Type, Type)`** — a closure
    VALUE: the closure's identity, its signature, and the CAPTURE TUPLE
    type. The closure object's layout/ABI derives from the captures (the
    capture aggregate plus the code pointer); the closure's TypeProperties
    derive from the capture tuple (§7); the checker types closure
    expressions as this form and the MIR closure aggregate dispatches
    through it. The legacy `Function` variant is retained transitionally
    for the Batch-3 consumers and then deleted.
- **`RefInternal(Type, Bool)`** — MIR-only (parameter re-wrap and
  MirRef typing); not a source-level type.
- **`Ptr(Type)` / `PtrMut(Type)`** — raw pointers (§11). Box/Rc are Adt
  forms of the registered Box/Rc ids, not pointer variants.
- **`Dyn(TypeId)`** — trait objects; **`Effect(Vec[String], Type)`**;
  **`Tuple(Vec[Type])`**; **`Var(TypeVarId)`**; **`Param(String)`**;
  **`Error`**.
- **`Slice`** — THE ONE-REPRESENTATION AUTHORITY (the P0 safe-view
  closure): the SOURCE-spelled `Slice[T]` (and the `[T]` sugar) IS the
  SAFE **shared/pinned form** — the std-declared struct
  `Slice[T] { inner: ArcStrong[SliceBacking[T]] }`
  (std/collections.tg; the reviewer's shared/pinned backing — no
  lifetime inference). The backing record = the pinned buffer + the
  window's offset/len:
  `SliceBacking[T] = { ptr: Ptr[T] @ 0, len: UInt @ 8, offset: UInt @ 16 }`
  (24 bytes). The Arc keeps the pinned backing alive: the view **survives
  the original owner's drop**, and the owner's capacity-changing
  mutations never move it (the backing is the separate pinned allocation
  — the mutation allocates a fresh pinned backing for the new buffer, the
  views keep the old one alive). **Actual layout: the safe Slice value is
  8 bytes — one pointer-sized Arc handle `{ inner @ 0 }` (the Arc-class
  `{ptr,len}`); the pinned backing is the 24-byte record above.** The pin
  operations (`slice_pin` / `str_view_pin`) copy the window into the
  pinned allocation; the backing's deinit releases it when the last Arc
  dies. The shared forms are ordinary owning values — NO escape tracking,
  NO access-scoping, NO "eventual mechanism" (the backing owns).
  **The RAW view is the registered `UnsafeSlice` builtin** (the LangItems
  `slice` id) — the 16-byte borrowed `{ ptr: Ptr[T], len: UInt }` fat
  value (`slice_view_layout` in layout_engine.tg), the explicit
  **unsafe/FFI-only spelling**. Safe code cannot produce it, and its
  escapes are the P0-SL-rejected cases (the escape channels in types.tg +
  the live-view registry in resource_check.tg). The only raw views safe
  code ever sees are the compiler-scoped loop-consumed iterable forms
  (chars/bytes/split/iter/keys/values — consumed by the enclosing
  for-loop) and the compiler-manufactured literal coercion behind `vec!`.
  `str`
  is the registered string escape spelling (`__intrinsic_string_as_str`),
  mapping to the `String` primitive. **The String/StrView distinction is
  implemented**: `StrView` (std/core.tg) is the SAFE shared/pinned
  UTF-8 view — `StrView { inner: ArcStrong[StrViewBacking] }` (8 bytes),
  with `StrViewBacking = { ptr: Ptr[u8] @ 0, len: UInt @ 8, offset: UInt @
  16 }` (24 bytes — the pinned byte backing + the offset/len). The StrView
  survives its source String's drop and growth (the pinned byte backing
  keeps the bytes alive; the backing's deinit releases them at the last
  Arc's drop). `String::as_str_view` pins the owned String's bytes;
  `String::from_str_view` clones the pinned bytes into an owned `String`.
  The raw byte view (16-byte `{ptr,len}`) exists only as the unsafe/FFI
  form (`UnsafeSlice[u8]` / `FfiSlice`). The hash/eq dispatch selects the
  view through the LangItems `str_view` TypeId (mono.tg's key selection),
  with a name-selection fallback only for a snapshot that lacks the
  registration; `str` maps to the `String` primitive.

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

```text
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

Type properties (§7): Box/Rc and UniquePtr/WeakRc/
ArcStrong/WeakArc are selected by their LangItems ids
(`box_`/`rc`/`unique_ptr`/`weak_rc`/`arc_strong`/`weak_arc` —
registered in `build_lang_items`, with a name fallback only for
snapshots without the registration) and are `needs_drop`; Rc is the
sole non-linear owning pointer.

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
suffix — rendered by the ONE canonical type encoding (the
`CanonInternal` frame of `type_canon_render`, types.tg — the same walk
the frontend type identity and the public ABI canonicalization use,
parameterized only by the external symbol framing). Deterministic per
(def, substs).

**P1 (MonoKey deletion): specialization identity is the InstanceId —
never a source/emission name.** The former `MonoKey { func_name,
type_args }` record and the name-derived dedup entry are deleted; the
cache's `instances` map is keyed by the instance key (the canonical
render of the InstanceId — the key IS the emission symbol), so the cache
hit, the emission name and the call-site rewrite all agree on the
instance identity. The work queue's (callee name, InstanceId) pairs use
the name only as the template-lookup key into `mir.functions`; the
specialization itself is keyed exclusively by the instance.

The public ABI's type-to-declaration association is DIRECT (P1): the
checker's registration records every nominal TypeId's defining DefId
(`TypeDef.def`, serialized in `resolutions.type_def_ids`), and the
ABI stable-path derivation joins TypeId → DefId → the qualified
module_symbols registration key — no name/order correlation. The
frontend identity, the internal emission mangling and the public ABI
canonicalization are ONE canonical type encoding
(`type_canon_render`, types.tg).

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

`CfgEdge { kind, source, destination, actions }`: `source` is the
semantic node id of the transfer's originator; `destination` is the
static target when one exists (0 for dynamic targets); `actions` is the
edge's cleanup obligation as an **action sequence in execution order**
(`CleanupAction`): RunDefer actions (the exited scopes' defers, LIFO —
innermost scope first, within a scope reverse registration order), then
Drop actions (the live Sink/OwnedLocal locals of the exit, in reverse
drop order), grounded on the source block's exit frame
(`block_grounded_drop_ids` is the authority for what an edge drops).

**The CleanupEdge table (migration complete).** The String-keyed
serializations — the `edge_cleanup` map (`edge::<kind>::<source>`) and
the finalize-plan edge string keys (`return::<id>`, `break::<id>`,
`continue::<id>`, `backedge::<id>`, `block::<id>`) — are **deleted**.
The resource checker serializes one semantic
`CleanupEdge { edge: CfgEdgeId, actions }` per real CFG edge into the
parallel table `TypedCFG.cleanup` (`cleanup[i]` is edge `i`'s record;
the edge's index IS its `CfgEdgeId`), so an edge can never accidentally
reuse another edge's plan (the loop-exit double-clean and the nested
block::/edge:: double-drop bug class). `validate_cfg_edges` verifies the
model, and MIR merely materializes the resolved edge cleanup through the
single lookup (`lookup_cleanup_edge`); the builder-side defer
registrations remain only as the fallback for synthesized/IR-only edges
that never had a checker record.

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
- MIR lowering (`mir.tg`) lowers each defer body to a **template
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
definition with the args substituted. Every concrete non-trivial plan
owns a **generated drop-glue function** (`mir_glue_instance_for_type` /
`mir_build_all_drop_glues`): an ordinary `MirFunction`
(`__tg_drop_glue$<concrete-key>(ptr: Ptr[T], mask: Int) -> Unit`,
pushed to `MirProgram.functions` with its emission label registered in
`drop_glue_fns`), so the backend knows nothing about "how to destroy a
Map" — every whole-value destruction site is a MirDeinit carrying the
glue's InstanceId, and codegen resolves the label through
`drop_glue_fns`. The glue's `mask` parameter is the initialized-fields
bitmask: whole-value sites pass all-ones, the partial-drop sites
(§4.4) pass the live-field masks. Recursive owning types (Tree →
Vec[Tree], a Box/Rc-linked list) are broken **by symbol**: the
recursion edge is a `DeinitPlan::Call` to the type's own MEMOIZED glue
— the glue calls itself and the recursion terminates at runtime when
the container is empty, instead of expanding the plan tree.
`PlanLimit` remains only as the fail-closed answer for a missing
REGISTERED deinit target (a Box/Rc without a registered Drop impl);
`mir_verified_deinit_call` panics at plan construction on an
unverifiable name.
Emission order on every exit: defer actions (LIFO), then the deinit
chain in reverse drop order; the user finalizer first, then the
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
| String is the OWNED String object: one pointer to the 32-byte {data,len,cap,stride} header; the string_* intrinsics dispatch to the String ABI (`_tg_string_*`), never the Array ABI; literals are the static StrView and convert to owned Strings via `string_from_static` at every owned-String demand site (by-value String params, String destinations, Vec[String] literals, concat, to_string, clone); the destructor `_tg_string_drop` frees object + buffer through `_tg_mem_free` (per-class free-list reclaim) | runtime.tg "String Object Runtime"; codegen.tg `resolve_intrinsic_id` / `string_abi_intrinsic_name`; mir.tg `mir_call_arg_needs_owned_string` / `lower_string_literal_to_owned`; std/core.tg String contract + `impl Clone/Eq/Hash for String` |
| THE SAFE VIEW MODEL — ONE REPRESENTATION, ONE SEMANTIC AUTHORITY: the SOURCE-spelled `Slice[T]`/`StrView` ARE the SHARED/PINNED forms — `Slice[T] { inner: ArcStrong[SliceBacking[T]] }` / `StrView { inner: ArcStrong[StrViewBacking] }` — the Arc-class `{ptr,len}`: 8-byte Arc handle to the 24-byte pinned backing `{ ptr @ 0, len @ 8, offset @ 16 }` (the pinned buffer + the window's offset/len). The backing keeps the storage alive (the view survives the owner's drop and its capacity-changing mutations — the backing is the separate pinned allocation); the backing's deinit releases the pinned allocation at the last Arc's drop. The shared forms need NO escape tracking (ordinary owning values — the backing owns; there is no "eventual mechanism"). The RAW view — the registered `UnsafeSlice` builtin (the LangItems slice id; 16-byte `{ ptr @ 0, len @ 8 }`) — is the explicit unsafe/FFI-only spelling: safe code cannot produce it; its escapes are the P0-SL-rejected cases (return/store/capture channels in types.tg; the live-view registry + IterationPlan mutation scan in resource_check.tg). Safe APIs return the shared form (Vec::as_slice / String::as_str_view — pin-copies); FFI surfaces use the raw form (FfiSlice); the for-loop iterable forms stay compiler-scoped and loop-consumed | std/collections.tg "THE SAFE VIEW MODEL"; std/core.tg StrView contract; types.tg `is_slice_view_type_of` / `is_shared_view_type_of` / `check_no_escaping_slice`; resource_check.tg `slice_views` registry / `check_slice_view_backing_mutation` |
| Type-property graph algorithm with inline-recursion diagnostics; memoized per concrete args | types.tg §7 |
| Monomorphization: seen-set, MAX_MONO_INSTANCES, residual-param aborts | mono.tg §13 |
| Map/set ownership ops: every key-operating map/set intrinsic site injects the CONCRETE `Hash::hash` / `Eq::eq` dispatch calls (core-ABI gates by declared param count; kernel key types dispatch to the runtime helpers) — the impls are reached and specialized with zero inference | mono.tg `inject_map_dispatch_calls` / `apply_dispatch_injection`; codegen.tg `map_hash_dispatch_label` / `map_eq_dispatch_label` |
| Layout tables are CONCRETE-keyed: the layout/offsets/sizes tables are populated per concrete (TypeId, substs) identity (`collect_concrete_adt_types` + `mir_type_identity_key`), so `Wrapper[Int]` and `Wrapper[File]` never share a layout entry | codegen.tg layout tables; mir.tg `mir_type_identity_key` |
| CFG edge model recorded and validated per function | resource_check.tg §14 |
| Destruction names verified against registered deinit targets (fail-closed) | mir.tg §4.3 |
| Partial moves: pattern-binding consumes record per-field state in the place registry; MIR emits the partial-drop chain — live fields dropped through their own masked glues, consumed fields skipped, whole-value ("*") records drop nothing | types.tg `record_place_moves` / `place_move_states` §4.4; mir.tg `mir_emit_partial_drop_chain` / `emit_cleanup_chain` (mask-carrying MirCall glue sites) |
| Generated drop glue: every concrete non-trivial plan owns a memoized drop-glue function; recursive owning types are broken by symbol (the glue calls itself); PlanLimit remains only for missing registered deinit targets | mir.tg `mir_glue_instance_for_type` / `mir_build_all_drop_glues` / `DeinitPlan::Call` §14.3 |
| Fixed-array const sizes: literal / const-reference / constant-arithmetic sizes evaluate before the FixedArray identity forms | types.tg `eval_const_size_expr` / `const_values` §9; `tests/canary/canary_pos_fixed_array_const_size.tg` |
| LangItems built once, structurally unique; the bundle covers option/result/vec/map/set/box/rc/array/slice + string/str_view/unique_ptr/arc_strong/weak_rc/weak_arc/ptr/ptr_mut + the trait ids; semantic identity by DefId/TypeId/TraitId — never strings | types.tg / ids.tg §8 |
| THE SIMD VECTOR ROW: the std Vec2/Vec4/Vec8/Vec16 instantiations with a 16/32/64-byte width lay out as N lanes of the lane type with ALIGNMENT = the vector WIDTH (never the lane alignment), and the ABI classifier's vector cases cross the 16-byte vector THROUGH the registers (`Vector(16)` — never sret) while the 32/64-byte forms cross by address; a non-vector width (Vec2[f32] — 8 bytes) and an ordinary `[T; N]` fixed array keep the element-aligned inline layout | layout_engine.tg `compute_vector_layout` / `is_simd_vector_type` / `classify_value_category`; codegen.tg `AbiArg::Vector` / `category_uses_sret`; tests/simd/simd_layout_test.tg / simd_abi_probe.tg |
| THE WASM32 LINEAR-MEMORY MODEL: the wasm32-unknown-unknown / wasm32-wasi target's address space is the wasm linear memory — pointers and handles are 32-bit linear addresses (i32), aggregates live in linear-memory images addressed by i32 handles, and the wasm stack holds the i32/i64/f32/f64 values; the type mapping (Bool/Char/I8/I16/I32/U8/U16/U32 → i32; Int/I64/U64/ISize/USize → i64; F32 → f32; Float/F64 → f64; Ptr/PtrMut/RefInternal/String/Adt/FnPtr/Dyn/Effect/Closure → i32 handles; Unit/Never → no value; I128/U128 fail closed; the SIMD vectors cross by address) is the single authority in wasm_target.tg, and the category-level classification maps the layout engine's value categories to the wasm32 slots | wasm_target.tg "THE WASM TYPE MAPPING TABLE" / `map_primitive_to_wasm` / `mir_type_to_wasm` / `classify_wasm_value_category`; tests/wasm/wasm_conformance_test.tg (the mapping-table case) |
| THE PER-ORDERING ATOMIC DISCIPLINE: the atomics lower per order code — AArch64 relaxed load/store = plain LDR/STR (acquire/release/SeqCst = LDAR/STLR), AArch64 fence = DMB ISHLD for Acquire and DMB ISH for Release/AcqRel/SeqCst (nothing for Relaxed), x86-64 fence = MFENCE for SeqCst only (nothing for the weaker orders — TSO), x86-64 SeqCst store = the xchg store while weaker stores are plain MOVs; RMW/CAS serve the strongest form (correct for every ordering — stronger-than-requested is always legal) with the per-ordering A/L variants and the CAS failure-order dispatch as documented TODOs | codegen.tg `emit_atomic_intrinsic_a64` / `emit_atomic_intrinsic_x64` §16.8 |
| THE AArch64 STLR ENCODINGS ARE ISA-VERIFIED: the STLR family bases (STLRB 0x089FFC00 / STLRH 0x489FFC00 / STLR(w) 0x889FFC00 / STLR(x) 0xC89FFC00) and the allocator unlock's `stlrb wzr, [x10]` were re-derived from assembled/disassembled encodings (the former `…1F7C00` words were not valid STLR instructions) | codegen.tg `a64_stlr_enc`; runtime.tg `emit_tg_alloc_unlock` §16.8 |
| CAS ordering legality (failure ∉ {Release, AcqRel}; failure ≤ success) enforced at every std compare_exchange/compare_exchange_weak entry with the deterministic panic (the panic=abort stance) | std/atomic.tg `validate_cas_orderings` §16.3 |

### 15.2 Pending (documented targets, not assumptions)

| Item | Current behavior | Target |
|------|------------------|--------|
| **Expression-level projected-place operations** | the place-level registry + masked glue exist (§4.4: pattern-binding partial moves, match destructuring, closure capture); DIRECT expression-level consume/move/assign/initialize of a projected resource place is still rejected at root-granularity ("cannot consume a projected place: partial moves are not yet supported" etc.) | per-place state at the expression-level operations (consume/assign through a projection) |
| **Consuming iteration** | snapshot iteration exists; sink-element iteration rejected | consuming iteration with per-iteration (backedge) cleanup |
| **StrView name fallback** | the hash/eq dispatch selects StrView by the LangItems `str_view` TypeId; the name-selection fallback remains only for snapshots without the registration | drop the name fallback once every snapshot registers the id |

The pending list above is the authoritative one; `access_resource_migration.md`
records the historical status of these items at audit time.

---

## 16. Atomics and the Language-Level Memory Model

This section is the canonical, language-level memory model for atomic
operations — independent of any CPU's behavior. It defines the five
orderings and their formal guarantees, the legal ordering per operation
kind, the data-race status of atomic and non-atomic accesses, the
compiler-reordering restrictions, the compare-exchange success/failure
rules, the fence semantics, and the volatile-versus-atomic distinction.
The per-target instruction mapping in §16.8 is what codegen implements;
the model is NOT "whatever ARM/x86 currently emits" — the tables are the
implementation of this section, and any target (current or future) must
implement at least the guarantees stated here.

Normative authorities: the single atomic primitive layer is the
`__intrinsic_atomic_*` extern family (`std/atomic.tg`, mirrored in
`std/sync.tg`), lowered inline by `codegen.tg`
(`try_emit_atomic_builtin` → `emit_atomic_intrinsic`). The user surface
is `std::atomic` (`AtomicBool`, `AtomicInt`, `AtomicUInt`, `AtomicU8`,
`AtomicU64`, `AtomicPtr[T]`, the `Ordering` enum, `fence`/
`compiler_fence`, and the lock types built on them: `SpinLock`,
`SeqLock`, `TicketLock`, `RcuPtr`). `std::sync` provides the
SeqCst-defaulting convenience types (`AtomicBool`/`AtomicU32`/
`AtomicU64`/`AtomicPtr[T]` with fixed-`SeqCst` load/store/swap/CAS
surfaces — every call passes order code 5, so those APIs are the
SeqCst-only subset). A fence never turns a non-atomic access into an
atomic one: the inline instructions are the atomicity.

### 16.1 Definitions

| Term | Definition |
|------|-----------|
| **Atomic object** | a memory location of a type declared in `std::atomic` / `std::sync` (the `Atomic*` structs wrapping one width-exact scalar field of 1/2/4/8 bytes), accessed ONLY through the `__intrinsic_atomic_*` operations of that object's methods. The language has no per-access `atomic` keyword: atomicity comes from the type + the intrinsic layer. |
| **Atomic access** | a load, store, exchange, read-modify-write (RMW), or compare-exchange performed by an atomic intrinsic on an atomic object. |
| **Non-atomic access** | any other memory access (an ordinary load/store through a raw pointer, a `get_mut()` write, a `_tg_volatile_*` access, a smart-pointer field write). |
| **Sequenced-before** | the program order of the abstract machine within one thread (the order the compiler emits: §16.5). |
| **Happens-before (hb)** | the transitive closure of sequenced-before plus synchronizes-with (§16.2). |
| **Data race** | two conflicting accesses (at least one a write) to the same memory location by different threads, not ordered by happens-before. |
| **Ordering code** | the `c_int` ABI code of an ordering (`ordering_to_c`, std/atomic.tg): 0 = Relaxed, 2 = Acquire, 3 = Release, 4 = AcqRel, 5 = SeqCst. (Code 1 is unused and out of domain.) |

Read-from and coherence are the standard per-location rules: every
atomic load reads from some atomic store (or the initial value) to the
same location; a load cannot read from a store that happens-after it;
two atomic stores to one location have a total modification order; a
load reads the last store before it in that modification order, or a
store from its release sequence (a chain of RMWs from that store).

### 16.2 The five orderings and their guarantees

An ordering on an operation F is a **minimum** requirement: the
implementation may serve any operation with a stronger ordering than
requested, never a weaker one ("stronger" per the strength order of
§16.3). All five orderings guarantee atomicity (a single, indivisible,
width-exact access) and coherence (§16.1). They differ only in what they
order around the operation:

| Ordering | Guarantees (formal) | Typical role |
|----------|--------------------|--------------|
| **Relaxed** | atomicity + coherence only. No synchronizes-with; no reordering restrictions. | counters, statistics, `is_locked` probes |
| **Acquire** | a load with this ordering that reads from a store X (or its release sequence) synchronizes-with X: every side effect sequenced-before X happens-before every operation sequenced-after the load. Subsequent reads and writes in this thread cannot be observed before the load. | lock acquisition, flag polling, RCU read |
| **Release** | a store with this ordering synchronizes-with every acquire load that reads it: every side effect sequenced-before the store happens-before every operation sequenced-after such a load. The store cannot be observed before prior stores. | lock release, publishing, RCU update |
| **AcqRel** | RMW only: the read half is an acquire, the write half is a release (for one operation, one location). | exchange/fetch/CAS in lock-free protocols |
| **SeqCst** | all of the above, plus: the SeqCst operations of a program form a single total order S consistent with each thread's sequenced-before, and every non-SeqCst atomic access that is coherent with that order behaves as if placed somewhere in S. Every SeqCst load reads from the last SeqCst store to its location in S (or a store in its release sequence). | the default discipline of `std::sync`, event ordering across threads |

Derived guarantees (the standard, target-independent facts):

- **Store-store ordering**: a Release (or stronger) store is never
  observed before an earlier store of the same thread.
- **Load-load ordering**: an Acquire (or stronger) load never observes
  a location as newer than a later load of the same thread does (later
  reads happen after the acquire read's synchronize point).
- **No load-store reordering across AcqRel/SeqCst RMWs**.
- **Causality**: an hb-ordered chain of release/acquire pairs transmits
  side effects transitively (T1 release-store → T2 acquire-load →
  T2 release-store → T3 acquire-load makes T1's writes visible to T3).

### 16.3 Ordering legality per operation kind

| Operation kind | Legal orderings |
|----------------|-----------------|
| `load` | Relaxed, Acquire, SeqCst |
| `store` | Relaxed, Release, SeqCst |
| `exchange`, `fetch_*`, `*_fetch` (RMW) | all five (AcqRel is meaningful here) |
| `compare_exchange` / `compare_exchange_weak` — success | all five |
| `compare_exchange` / `compare_exchange_weak` — failure | Relaxed, Acquire, SeqCst ONLY |
| `fence` | all five |

**Strength order** (used by the CAS failure rule):
Relaxed (0) < Release (1) < Acquire (2) < AcqRel (3) < SeqCst (4)
(`ordering_strength`, std/atomic.tg).

**Compare-exchange rules**:

1. The failure ordering is the ordering of the READ performed when the
   comparison fails. A failed CAS performs **no store**, so the failure
   ordering can never be Release or AcqRel (a release is a write-side
   guarantee). A failure ordering of Release/AcqRel is a hard program
   error.
2. The failure ordering must not be **stronger than the success
   ordering** (linear strength order above); e.g. success=Release with
   failure=Acquire is rejected.
3. On failure the `expected` slot is updated with the current value of
   the location (the intrinsic writes it back through the expected
   pointer); `false` is returned. On success the location holds
   `desired`; `true` is returned.
4. `compare_exchange_weak` may fail spuriously (a permission, never an
   obligation); the emitters use the single-attempt strong form, which
   is always conformant.
5. A successful CAS with success ordering O orders like an RMW with O;
   the failed path orders like a load with the failure ordering
   (read-from and coherence still apply).

**Enforcement.** The CAS rules are enforced at the std boundary by
`validate_cas_orderings` (std/atomic.tg): every
`compare_exchange`/`compare_exchange_weak` validates before lowering
and panics deterministically (the panic=abort stance of §4.3 — there is
no unwind) on a Release/AcqRel failure ordering or a failure ordering
stronger than the success ordering. Compile-time diagnosis is possible
only where the ordering arguments are provable literals (no such
diagnostic exists today; the runtime check is the general
enforcement). For the operation-kind legality of the other operations
(loads/stores/RMWs/fences), orderings are runtime values and the
language defines deterministic out-of-domain behavior in the codegen
tables (§16.8): an out-of-domain code is served by the instruction the
branch structure assigns it (typically the strongest legal form; the
tables are the authority) — never weaker than what the table promises.
Such a call is nevertheless a program error (UB per §16.4), not a
supported use.

### 16.4 Data races

- **Atomic vs atomic**: concurrent atomic accesses to the same atomic
  object are always well-defined regardless of orderings; the ordering
  arguments determine only the synchronization guarantees (§16.2).
- **Any access involving a non-atomic access**: if two threads access
  the same memory location, at least one access is a write, and at
  least one of the accesses is not an atomic access, the program has a
  **data race** — **undefined behavior** (the C/C++/Rust convention the
  language adopts). This includes an atomic object reached through
  `get_mut()` (a non-atomic access to what is otherwise an atomic
  location): the moment the storage is touched by a non-atomic access
  that races with another thread, the program is racing — `get_mut` is
  the exclusive-access escape hatch and is subject to the caller
  proving exclusivity.
- **Atomic vs volatile (MMIO)**: a `_tg_volatile_*` access and an
  atomic access to the same address race exactly like a non-atomic vs
  atomic race — never valid (§16.9).
- **Diagnosis stance**: the access checker already rejects statically
  provable conflicting accesses within a call and within one thread
  (§2.2, §11). Cross-thread races on non-atomic accesses cannot
  generally be proven by this compiler; where provable they must be
  diagnosed (future work — no such analysis exists today); otherwise
  this document is the authority: the program is UB. There is no
  "benign race" carve-out and no memory-model guarantee for racy
  non-atomic access: the generated code may tear, reorder, or observe
  stale values. This matches the deterministic stance of the rest of
  the toolchain only in that the compiler itself never invents races
  (§16.5): it never merges, splits, hoists, or sinks memory accesses.
- **Races on atomics are not UB**: a lost update is a normal outcome of
  the ordering, never a model violation.

### 16.5 Compiler-reordering restrictions

The model constrains the observable ordering of accesses; it is the
compiler's duty never to violate it. The Tangerine compiler performs
**no reordering at all**: MIR lowering and codegen emit memory
operations strictly in program order, there is no instruction scheduler
or reordering pass, and no optimization pass elides or merges memory
accesses. Consequently:

1. Atomic operations are never reordered with respect to each other,
   to fences, or to non-atomic accesses (there is no pass that could).
2. Atomic loads are never elided or duplicated; atomic stores are never
   eliminated or coalesced (in particular, the as-if rule does not
   apply to atomics).
3. Non-atomic accesses are never hoisted, sunk, or fused across an
   atomic operation or a fence.
4. The `compiler_fence(order)` API (std/atomic.tg) exists for source
   portability and for `asm volatile`-style compiler barriers; on this
   compiler it is semantically identical to `fence(order)` minus the
   CPU barrier, and its "compiler barrier" role is vacuous because of
   (1)-(3).

(If a future optimizer is added, these restrictions become its
contract; the memory model does not depend on the optimizer's
existence.)

### 16.6 Fences

`fence(order)` (std/atomic.tg) issues a thread fence with the ordering's
guarantees, decoupled from any single operation. Formal semantics
(standard): a Release fence synchronizes-with an Acquire fence (or
Acquire load) when a store appears between them and the acquire side
reads it (or its release sequence); a Release fence followed by a
Relaxed store gives that store release semantics; a Relaxed load
followed by an Acquire fence gives that load acquire semantics.
AcqRel is both halves; SeqCst is a full fence and every SeqCst fence is
in the single total order S with the SeqCst operations. A Relaxed fence
orders nothing (compiler barrier only). A fence orders only atomic and
ordinary accesses per §16.5; it never makes a non-atomic access atomic
and never orders `volatile` accesses in the atomic model sense (§16.9).

The per-target fence instructions are in the §16.8 tables.

### 16.7 Volatile vs atomic

Tangerine has **no `volatile` type qualifier** and no volatile access
keyword: the C-style `volatile` concept is spelled as the explicit
width-exact accessors `_tg_volatile_read8/16/32/64` and
`_tg_volatile_write8/16/32/64` (std/embedded.tg, lowered to the
dedicated runtime functions emitted by `runtime.tg`
`emit_volatile_runtime` on both arches).

| Property | Volatile (`_tg_volatile_*`) | Atomic (`__intrinsic_atomic_*`) |
|----------|------------------------------|----------------------------------|
| Access semantics | a single, width-exact, non-elidable load/store; each call performs exactly one access (the call boundary is opaque to any optimizer) | a single atomic load/store/RMW/CAS per intrinsic call |
| Ordering guarantees | **none** — volatile accesses participate in NO ordering relation of this model; they are not ordered with atomics, fences, or each other (except by program order for the same single access) | the ordering argument's guarantees (§16.2, §16.8) |
| Atomicity | **never atomic**: a volatile access racing any other access is a data race (UB, §16.4) | atomic |
| Purpose | MMIO registers, device memory, interrupt-handler shared flags (audit P1-16: MMIO access is permitted in handlers) | lock-free shared memory between threads |
| Elision/reordering | prevented per access (single-access contract); no cross-access ordering | the ordering model (§16.5, §16.8) |

The two never mix: a fence around volatile accesses provides no atomic
ordering for them, and a volatile access is never a substitute for an
atomic one. A hardware register that must be touched once must use the
volatile accessors; a counter shared between threads must use the
atomic types.

### 16.8 Per-target codegen tables (normative implementation)

All encodings below were verified against the AArch64/x86-64 ISA
(assembled + disassembled). Codegen reads the runtime order code from
the ABI register and branches per ordering where the ISA distinguishes
orders (AArch64 store/load/fence, x86-64 store/fence). Serving an
ordering stronger than requested is always legal (§16.2); the tables
show the minimum-strength instruction actually emitted for each code.
The wasm32 target (wasm_target.tg) has no atomic emission: an atomic
extern lowers to the trapping stub (a runtime trap — fail closed), so
the tables below govern the native aarch64 and x86-64 targets only.

#### 16.8.1 AArch64 (ARMv8.1 LSE-REQUIRED; the LDAR/STLR SC discipline assumes the ARMv8.3+ cumulative semantics of the pair — the LSE-required core baseline provides it)

| Order code | load | store | RMW (fetch/exchange) | CAS | fence |
|-----------|------|-------|----------------------|-----|-------|
| 0 Relaxed | LDR (plain) | STR (plain) | LSE **-al** family (strongest; see TODO) | CASAL (strongest; see TODO) | (nothing) |
| 2 Acquire | LDAR | STLR* | LDADDAL/CASAL/SWPAL… | CASAL | DMB ISHLD |
| 3 Release | LDAR* | STLR | LSE -al | CASAL | DMB ISH |
| 4 AcqRel | LDAR* | STLR* | LSE -al | CASAL | DMB ISH |
| 5 SeqCst | LDAR | STLR | LSE -al | CASAL | DMB ISH |

- LDAR = acquire load (the SeqCst load under the LDAR/STLR pair
  discipline); STLR = release store (the SeqCst store under the same
  discipline). The `*` marks out-of-domain codes for that operation
  kind (UB — §16.3) served deterministically by the strongest legal
  form.
- LSE -al family: LDADDAL (add/sub), LDCLRAL (and), LDSETAL (or),
  LDEORAL (xor), SWPAL (exchange), CASAL (compare-exchange), each
  width 1/2/4/8 with the A/L bits: base | A(0x800000) | L(0x400000) —
  e.g. `ldaddal x1, x9, [x0]` = 0xF8E10009.
- Encodings verified: LDAR base per width 0x08DFFC00/0x48DFFC00/
  0x88DFFC00/0xC8DFFC00; STLR base 0x089FFC00/0x489FFC00/0x889FFC00/
  0xC89FFC00 (codegen `a64_stlr_enc`); DMB ISH 0xD5033BBF; DMB ISHLD
  0xD50339BF; DMB ISHST 0xD5033ABF (store-store only — NOT the language
  release fence: a release fence must also keep later loads from being
  observed before the prior stores — a store->load crossing that DMB
  ISHST does NOT prevent; DMB ISH is the ecosystem-standard release
  fence, matching clang/gcc).

**TODO (exact mapping, not a correctness gap — the -al forms serve
every ordering):** per-ordering RMW variants. The A/L flag bits over
each op's plain base are A = 0x800000, L = 0x400000; the plain bases
are the `*_al_enc` tables minus 0xC00000. Dispatch on the order code in
x2 like the store arm: Relaxed → plain (LDADD/…/SWP), Acquire → +A,
Release → +L, AcqRel/SeqCst → +AL (today's emission). CAS success/
failure dispatch (codes in x4/x5): the failure path is a read; an exact
lowering requires the LL/SC fallback (the documented future portable
mode): relaxed success/relaxed failure → LDXR/STXR loop (LDXR bases
0x085F7C00/0x485F7C00/0x885F7C00/0xC85F7C00, STXR bases 0x08007C00/
0x48007C00/0x88007C00/0xC8007C00), acquire reads → LDAXR (the LDXR
base + 0x8000: 0x085FFC00/0x485FFC00/0x885FFC00/0xC85FFC00 — verified
encodings), release success stores → STLXR (the STXR base + 0x8000:
0x0800FC00/0x4800FC00/0x8800FC00/0xC800FC00).

#### 16.8.2 x86-64 (TSO)

| Order code | load | store | RMW (fetch/exchange) | CAS | fence |
|-----------|------|-------|----------------------|-----|-------|
| 0 Relaxed | MOV (plain) | MOV (plain) | LOCKed op (inherently full strength) | LOCK cmpxchg | (nothing) |
| 2 Acquire | MOV | MOV* | LOCKed | LOCK cmpxchg | (nothing) |
| 3 Release | MOV* | MOV | LOCKed | LOCK cmpxchg | (nothing) |
| 4 AcqRel | MOV* | MOV* | LOCKed | LOCK cmpxchg | (nothing) |
| 5 SeqCst | MOV | XCHG (the SeqCst store; implicitly locked) | LOCKed | LOCK cmpxchg | MFENCE |

- TSO facts this table relies on: loads are never reordered with other
  loads (every load ordering is the same plain MOV); stores are never
  reordered with other stores (a plain MOV store has release
  semantics); a LOCKed instruction is a full barrier (so a Relaxed
  RMW/CAS is served at seq-cst strength — no weaker width-exact atomic
  RMW exists on x86). SeqCst load = plain MOV under the xchg-store
  discipline: the total order S is TSO plus every SeqCst store being an
  xchg full barrier. The `*` marks out-of-domain codes (UB) served
  deterministically.
- Fences: SeqCst → MFENCE (0x0F 0xAE 0xF0); Relaxed/Acquire/Release/
  AcqRel → no instruction (TSO already provides the ordering these
  fences request; this matches clang/gcc `atomic_thread_fence`
  lowering — the `##MEMBARRIER` compiler barrier is vacuous here per
  §16.5). LFENCE/SFENCE are not used: the model covers only cacheable
  regular memory; store-buffer/MMIO-class effects are outside the
  atomic ordering model (§16.9).

**TODO (exact mapping — no weaker instruction exists, so this is a
documentation note rather than a gap):** there is no x86 encoding for a
width-exact atomic RMW below full-barrier strength; per-ordering RMW
lowering is therefore a no-op on x86 by construction.

#### 16.8.3 Shared rules

- The `expected` argument of compare_exchange is the ADDRESS of the
  expected slot; on failure the slot receives the current value.
- The `weak` flag is accepted for ABI compatibility; the emitters use
  the strong single-attempt form (conformant — §16.3 rule 4).
- The `__sync_*` builtins (the kernel/allocator path — Rc/Arc counts,
  the allocator's per-class locks and accounting, the kernel spin
  lock) are the **seq_cst-only kernel approximation**: every `__sync_*`
  emission is the strongest form on both arches (`__sync_synchronize` =
  DMB ISH / MFENCE; `__sync_fetch_and_add`/`sub` = LDADDAL / LOCK XADD;
  `__sync_*_compare_and_swap*` = CASAL / LOCK CMPXCHG). They are NOT
  the user atomic surface and never take an ordering; user code goes
  through `std::atomic` / `std::sync`.

### 16.9 Stage0 and seed approximations

- **Stage0 (the OCaml seed VM, stage0_ocaml)**: the seed executes
  single-threaded programs and its host binding table has **no atomic
  bindings** — any `__intrinsic_atomic_*` call traps
  ("host call … has no binding (fail-closed)", vm.ml `call_host`), and
  `__sync_fetch_and_add`/`__sync_bool_compare_and_swap_1` are
  deliberately unbound. The one seed semantic: `__sync_synchronize` is
  bound as a **no-op** — the correct semantics on the single-threaded
  host (host.ml). So no ordering behavior can be observed or validated
  on the seed; programs that exercise atomics are full-compiler-only.
  **TODO:** per-ordering VM semantics for the atomic intrinsics (the
  seed's memory is the VM heap — implement load/store/exchange/CAS/
  fetch/fence per the order code with the seed's deterministic trap
  discipline for the out-of-domain codes), if the seed is ever required
  to run atomic programs.
- **The kernel `__sync_*` runtime fallback**: `__sync_fetch_and_add`
  as a runtime FUNCTION (runtime.tg `emit_sync_fetch_and_add_runtime`)
  is documented "single-threaded runtime … NOT an atomic RMW" — a
  plain load/add/store; real atomics never route through it (codegen
  inlines them first). It exists only as a link-time fallback for the
  declared extern and must not be relied on for concurrency.
- `std::sync`'s fixed-`SeqCst` convenience methods are the SeqCst
  subset of this model (every call passes order code 5).

### 16.10 Summary of the model's contract

1. An atomic operation with ordering O provides at least O's
   guarantees (§16.2) and is served by the §16.8 instruction for O
   (stronger permitted).
2. A program that races non-atomic accesses, or passes an out-of-domain
   ordering, or violates the CAS failure rules, is in error — the CAS
   rules panic deterministically at the std boundary; the out-of-domain
   codes are served deterministically per the §16.8 tables.
3. The compiler never reorders, elides, merges, hoists, or sinks
   accesses (§16.5).
4. Volatile and atomic are distinct (§16.7); fences order atomics and
   ordinary accesses, never volatile accesses.
5. Where this section and a codegen table disagree, the table above is
   the implementation and this section is wrong (per the document
   preface).

(Anchors: §16.1 definitions; §16.2 orderings; §16.3 legality + CAS
rules; §16.4 races; §16.5 compiler restrictions; §16.6 fences; §16.7
volatile vs atomic; §16.8 per-target implementation tables; §16.9
Stage0 approximations; §16.10 contract.)
