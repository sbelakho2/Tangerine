(* mir_verify.ml — Seed MIR verifier (audit §36).

   Two explicit verification modes (audit P0: template vs concrete):
   - require_valid_template runs pre-monomorphization, right after
     lowering: the program is the GENERIC TEMPLATE universe (a function's
     instance carries its declaration rigid GenericParamIds, and params/
     locals/cast targets/constants/embedded instances may reference
     them).  Template mode PERMITS a function's own declared rigid
     params everywhere a template legitimately carries them, and still
     REJECTS Infer_var, Error, unknown TypeId, unknown FieldId/VariantId,
     wrong owner identity, malformed CFG, bad projection, bad call
     arity, and any generic parameter the function's own signature does
     NOT declare.  Generic nominal type templates resolve through the
     registry (the same Mono.generic_def array the driver hands to
     Mono.build) because program.types is concrete-only at this point.
   - require_valid_concrete runs post-monomorphization and before VM
     execution: the verifier is total over the CONCRETE (post-mono)
     representation — zero Type_param/Infer_var/Error anywhere — and any
     program that violates a rule is rejected with the full
     deterministic list of violations; nothing reaches execution on a
     rejected program.

   Checklist implemented (audit §36, §66):
   1.  every function has an entry block;
   2.  block ids unique within a function (exactly-one-terminator is
       unambiguous);
   3.  every terminator target exists (goto, switch arms + default,
       call/drop/deinit success + unwind, assert target);
   4.  every block has exactly one terminator (structural; enforced by
       the duplicate-block-id rule — one identity, one terminator);
   5.  every local reference exists (assigns, operands, StorageLive/
       StorageDead, SetDiscriminant, call destinations);
   6.  every projection is legal for its base type: Deref on a
       ref/pointer, Field on the OWNER struct def of the projected base
       (the native identity rule: the projected FieldId must belong to
       the base type's def; the positional fd_index is derived from the
       def's metadata, never trusted from the projection), ConstantIndex
       on a fixed array (or a tuple — the variant-payload form: tuples
       have no FieldId, so payload positions are indexed positionally,
       like the reference's TupleIndex) with an in-bounds index, Index
       on a fixed array whose index local exists, is definitely
       initialized/readable at that program point and is typed as an
       allowed integer index type (Int/I32/I64/UInt/U32/U64/U8 — the
       runtime index value is bounds-checked by the VM at execution,
       never compared against the container length here), Downcast on
       the OWNER enum def of the projected base (the projected VariantId
       must belong to the base type's def; the runtime tag vd_index is
       derived from the def's metadata);
   7.  operand type matches its operation (binop/unop arities and
       scalar classes, aggregate element types, cast matrix);
   8.  destination type matches the rvalue (assign and call dest);
   9.  call argument count and types exact (against the callee's
       specialized signature);
   10. call access effects exact (Modify/Initialize/Consume args must
       carry place operands; ownership-transfer forms are tracked);
   11. return type exact (call dest type equals the callee's return
       slot type);
   12. switch type legal (Int/Bool/Char/enum);
   13. switch values distinct;
   14. all enum discriminants valid (within the enum's variant set);
   15. no unresolved type parameters anywhere (params, locals, cast
       targets, instance substitutions, static types, type defs);
   16. no copy of a non-Copy value (bitwise copies only of Copy types);
   17. no read-before-initialize (definite-initialization dataflow);
   18. no read-after-consume (projection-aware moved-state dataflow);
   19. no second consume (single use per place key);
   19a. no projected Move/Consume anywhere (the seed VM has no partial-move
       representation: `Move p`/`Consume p` transitions the WHOLE root
       slot to Moved, ignoring p.projections, so the VM and the
       projection-aware moved lattice would disagree about the meaning of
       a projected transfer — every projected Move/Consume is rejected
       categorically, in both modes and at every operand position, until
       the VM executes projected moves);
   20. no duplicate drop (destroyed-state dataflow);
   21. no reachable placeholder/unreachable used as a lowering fallback
       (a reachable block whose terminator is Unreachable is rejected;
       unreachable blocks may deliberately end in Unreachable).

   Deliberate simplifications of the reference verifier, documented:
   - the assign DESTINATION root is not required to be definitely
     initialized (the assign initializes it) — the reference's strict
     dest check is unsound in the presence of StorageLive/StorageDead,
     which the seed emits for storage liveness;
   - storage liveness (StorageLive/StorageDead) contributes no
     definite-initialization facts, so a StorageLive'd-but-never-assigned
     local is read-before-initialize;
   - a CALL's destination is definitely initialized after the call
     (transferred in the init dataflow — the reference does not transfer
     it, which would reject every cross-block call result);
   - Intrinsic/Extern callee indices are registry handles owned by the
     VM layer (the program carries no registry); they are checked for
     non-negativity only;
   - integer switch values are the host Int domain (signed 64-bit), so
     U64/UInt switches may not use values >= 2^63. *)

open Seed_mir

module IntSet = Set.Make (Int)
module StrSet = Set.Make (String)
module IntMap = Map.Make (Int)

(* A checker query signature: callable id, declaration params (the
   template's own rigid Type_params), the full parameter contracts and
   the return type.  Covers the type-query special forms (size_of/
   align_of — no params) AND every compiler-builtin method surface with
   no lowered MIR body (Ptr::write/read/as_ref/as_mut/drop_in_place —
   the checker registers their typed sigs but no source module lowers a
   body, so template-mode calls to them resolve against this registry). *)
type query_sig = {
  qs_callable : Ids.Callable_id.t;
  qs_decl : Type_repr.t array;
  qs_params : Type_repr.param_type array;
  qs_ret : Type_repr.t;
}

type mode =
  | Template_mode (* pre-mono: declared rigid Type_params permitted *)
  | Concrete_mode (* post-mono: zero Type_param/Infer_var/Error anywhere *)

type ctx = {
  prog : program;
  errors : string list ref;
  mode : mode;
  generic_types : Mono.generic_def array; (* generic nominal templates; used in Template_mode *)
  query_sigs : query_sig list;
  (* the checker's type-query special forms (size_of[T]()/align_of[T]()
     — compile-time queries with no lowered MIR function); used in
     Template_mode only *)
  (* the checker's registered Box nominal tid (its transparent-Box
     convention — Box[T] unifies with T in both directions, so the
     verifier's compatibility and projection rules erase the wrapper
     exactly where the checker does; None when the compilation has no
     Box declaration) *)
  box_tid : Ids.Type_id.t option;
  (* Concrete_mode post-mono: the driver's type-instance materializer
     interns every concrete generic-nominal instance through the ONE
     canonical cache (audit P0-13) — same (template, args) always
     yields the same canonical specialized TypeId — and rewrites the
     program's Named mentions to it.  The body-less registered sigs
     (query_sigs) are checker-side and still mention the ORIGINAL
     template ids, so a registered callee's substituted types pass
     through the same canonical-cache rewrite after the call's type
     arguments replace its declaration binders — otherwise a kept
     call's destination (a rewritten local) disagrees with the
     registered callee's return.  Identity in Template_mode. *)
  post_rewrite : Type_repr.t -> Type_repr.t;
  (* Concrete_mode post-mono: the canonical specialized TypeIds the
     materializer minted for the checker's transparent Box nominal
     instances (the cache's (box_tid, args) entries).  Box[T] unifies
     with T in both directions (types_compatible, deref pointee,
     projection chains), and a materialized Box[T] mention — Named
     (fresh, [T]) — must stay transparent exactly like the
     original-tid mention. *)
  box_instances : Ids.Type_id.t list;
  (* The P1-25 copyability cache: the Type_properties engine memoizes
     its answers per canonical (TypeId, args) instance; the cache is
     bound to this ctx's def table (program + registry), so one ctx
     never mixes two tables' answers. *)
  copy_cache : Type_properties.cache;
  (* The P1-26 canonical drop-plan table: per concrete TypeId, the
     ordered (field/payload path, needs_drop) plan derived once from the
     program's defs (drop_plan.ml).  The drop accounting consults it
     when a whole-root drop destroys a local (destroyed_keys_of_drop). *)
  drop_plans : Drop_plan.table;
}

(* Whether a TypeId is the checker's transparent Box nominal — the
   original tid OR a materialized instance def the driver minted for
   it (both are transparent over their single type argument). *)
let is_box_tid (ctx : ctx) (tid : Ids.Type_id.t) : bool =
  List.exists
    (fun b -> Ids.Type_id.compare b tid = 0)
    (match ctx.box_tid with Some b -> b :: ctx.box_instances | None -> ctx.box_instances)

(* The checker's 64-bit alias pairs (the language model — abi_layout:
   "Int is the i64 alias", "UInt is the u64 alias"): Int and I64 are the
   same 64-bit signed value domain, UInt and U64 the same 64-bit
   unsigned domain.  The seed Int_value representation is
   (width, signed) — a 64-bit signed constant is indistinguishably an
   Int or an I64 value — so the checker records I64/U64 literals and
   declarations whose lowered constants the verifier necessarily reads
   as Int/UInt; the aliases reconcile the two spellings of one domain
   everywhere a type is compared, exactly like the checker's own
   int_kind_adopt call-boundary rule. *)
let int_kind_alias (a : Type_repr.int_kind) (b : Type_repr.int_kind) : bool =
  a = b
  ||
  match a, b with
  | Type_repr.Int, Type_repr.I64 | Type_repr.I64, Type_repr.Int -> true
  | Type_repr.UInt, Type_repr.U64 | Type_repr.U64, Type_repr.UInt -> true
  | _ -> false

let int_kind_width (k : Type_repr.int_kind) : int =
  match k with
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

let int_kind_signed (k : Type_repr.int_kind) : bool =
  match k with
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128
  | Type_repr.Int ->
      true
  | Type_repr.U8 | Type_repr.U16 | Type_repr.U32 | Type_repr.U64 | Type_repr.U128
  | Type_repr.UInt ->
      false

(* The checker's IntLiteral adoption (typecheck's unify literal-vs-kind
   rule), mirrored at the MIR: an unsuffixed literal whose checker
   record never adopted a concrete kind (a generic binding solved by a
   literal argument — `out.push(0xC5)` binding the receiver Vec's
   element var) stays Int_literal in the lowered slots/instances, and
   the MIR compares it like the checker did: compatible with any
   concrete integer kind whose range fits the magnitude.  Range
   authority stays the magnitude (never a silent truncation) — exactly
   the checker's fits decision. *)
let int_literal_fits (k : Type_repr.int_kind) (m : Big_nat.t) : bool =
  let p : Literal.parsed_integer =
    { original = ""; radix = 10; magnitude = m; suffix = Literal.No_int_suffix;
      span = Span.synthetic }
  in
  if int_kind_signed k then Literal.fits_signed p (int_kind_width k)
  else Literal.fits_unsigned p (int_kind_width k)

let add_err (ctx : ctx) (msg : string) =
  ctx.errors := msg :: !(ctx.errors)

(* ──────────────────────────────────────────────────────────────────
   Type-definition lookup and resolution *)

(* Registry fallback (Template_mode): program.types is concrete-only by
   contract, so a tid missing from the types table is a generic nominal
   template in the registry.  The registry is ignored in Concrete_mode
   (post-mono programs carry every def they reference). *)
let find_def (ctx : ctx) (tid : Ids.Type_id.t) : Seed_mir.type_def option =
  match
    Array.to_list ctx.prog.types
    |> List.find_opt (fun d -> Seed_mir.def_id d = tid)
  with
  | Some d -> Some d
  | None -> (
      match ctx.mode with
      | Template_mode -> (
          match Mono.find_generic ctx.generic_types tid with
          | Some gd -> Some gd.Mono.gd_def
          | None -> None)
      | Concrete_mode -> None)

let find_type (ctx : ctx) (tid : Ids.Type_id.t) : Type_repr.t option =
  match find_def ctx tid with
  | Some d -> Some (Seed_mir.def_repr d)
  | None -> None

(* Substitute a registry template def's declared params with a base's
   instance args (declaration order — the same positional KParam
   contract as mono's specialization).  Non-template defs pass through
   unchanged; an arity disagreement is a malformed template and fails
   closed. *)
let subst_registry_type (ctx : ctx) (tid : Ids.Type_id.t) (args : Type_repr.t array)
    (ty : Type_repr.t) : Type_repr.t =
  match ctx.mode with
  | Concrete_mode -> ty
  | Template_mode -> (
      match Mono.find_generic ctx.generic_types tid with
      | None -> ty
      | Some gd -> (
          match Mono.type_substitution gd args with
          | Ok subst -> Type_repr.substitute subst ty
          | Error m ->
              add_err ctx (Printf.sprintf "registry: %s" m);
              ty))

(* ── Semantic projection resolution (re-audit) ────────────────────
   A Field projection carries the semantic FieldId; its owner must be
   the projected base's struct def, and the positional fd_index is
   derived from the def's metadata.  A Downcast projection carries the
   semantic VariantId; its owner must be the projected base's enum def,
   and the declaration-order tag (vd_index) is derived from the def's
   metadata.  These lookups fail closed (None) on any identity/owner
   mismatch.  In Template_mode the def may be a registry template, so
   the FIELD/VARIANT TYPE is substituted by the base's instance args —
   the projected type of Named (tid, args) is the def's field type with
   the template's declared params replaced by args (the same positional
   KParam contract as mono). *)
let struct_field_of (ctx : ctx) (tid : Ids.Type_id.t) (fid : Ids.Field_id.t) :
    Seed_mir.field_def option =
  match find_def ctx tid with
  | Some (Seed_mir.StructDef { sd_fields; _ }) ->
      List.find_opt (fun f -> Ids.Field_id.compare f.Seed_mir.fd_id fid = 0) sd_fields
  | _ -> None

let enum_variant_of (ctx : ctx) (tid : Ids.Type_id.t) (vid : Ids.Variant_id.t) :
    Seed_mir.variant_def option =
  match find_def ctx tid with
  | Some (Seed_mir.EnumDef { ed_variants; _ }) ->
      List.find_opt (fun v -> Ids.Variant_id.compare v.Seed_mir.vd_id vid = 0) ed_variants
  | _ -> None

let struct_field_ty (ctx : ctx) (tid : Ids.Type_id.t) (args : Type_repr.t array)
    (fid : Ids.Field_id.t) : Type_repr.t option =
  match struct_field_of ctx tid fid with
  | Some f -> Some (subst_registry_type ctx tid args f.Seed_mir.fd_ty)
  | None -> None

let enum_variant_ty (ctx : ctx) (tid : Ids.Type_id.t) (args : Type_repr.t array)
    (vid : Ids.Variant_id.t) : Type_repr.t option =
  match enum_variant_of ctx tid vid with
  | Some v -> Some (subst_registry_type ctx tid args v.Seed_mir.vd_payload)
  | None -> None

let rec resolve_ty (ctx : ctx) (seen : Ids.Type_id.t list) (ty : Type_repr.t) :
    Type_repr.t option =
  match ty with
  | Type_repr.Named (tid, args) ->
      if List.mem tid seen then None
      else (
        match find_type ctx tid with
        | None -> None
        | Some def ->
            (* registry templates substitute their declared params with
               the base's instance args; concrete defs pass through *)
            resolve_ty ctx (tid :: seen) (subst_registry_type ctx tid args def))
  | _ -> Some ty

let resolve_or_self (ctx : ctx) (ty : Type_repr.t) : Type_repr.t =
  match resolve_ty ctx [] ty with
  | Some t -> t
  | None -> ty

(* Copy property authority (re-audit §36 / P1-25): the seed's property
   engine (Type_properties) with the program's def table as the Named
   resolver.  The engine's rules: scalars/String-owned/immutable refs
   and genuine function pointers behave as before; a def_repr'd enum
   (Function(payloads, Never)) is Copy iff EVERY variant payload is Copy
   — an enum with an owning payload (Result[Int, String]) must be moved,
   consumed or passed by place, never bitwise-copied; a Named type's
   copyability resolves its def and applies the same recursive rule
   (struct Copy iff all fields Copy).  The ctx-level cache memoizes the
   engine's answers per canonical (TypeId, args) instance (P1-25). *)
let is_copy (ctx : ctx) (ty : Type_repr.t) : bool =
  (* the builtin runtime nominals' canonical def shapes: the driver's
     type-instance materializer never remaps Vec/Array/Map/Set/Ptr/PtrMut
     instances (their runtime semantics are keyed on the original ids),
     so in Concrete_mode they have no def-table entry; their
     copyability is their canonical runtime shape — the handle nominals
     (Vec/Map/Set values are pointer-represented containers; Ptr/PtrMut
     are the address handles) are Copy, exactly as their registry
     template defs resolved pre-mono (Vec/Map/Set declare no fields;
     Ptr/PtrMut declare `address: UInt`) *)
  Type_properties.of_type_cached ctx.copy_cache
    (Some (fun tid ->
      match find_type ctx tid with
      | Some t -> Some t
      | None -> (
          match Ids.Type_id.to_int tid with
          | 0 | 1 | 2 -> Some (Type_repr.Tuple [||])
          | 5 | 6 -> Some (Type_repr.Tuple [| Type_repr.Int Type_repr.UInt |])
          | _ -> None)))
    ty
  |> fun p -> p.Type_properties.is_copy

(* Type compatibility.  NOMINAL-vs-NOMINAL comparisons are identity
   comparisons: Named (TypeId, args) is compatible with Named
   (TypeId', args') iff the TypeIds are equal and the concrete arguments
   are pairwise compatible — BEFORE any structural resolution.  Two
   different TypeIds are NEVER compatible merely because their
   definitions happen to share a shape (a UserId and a SocketFd both
   degrade to Tuple[Int] only if the verifier replaces nominal identity
   with physical structure, which it must not).  The definition table is
   consulted only for structural-by-nature comparisons (one side
   nominal, the other already structural — a tuple literal against a
   struct, an enum value against its reconstructed def) and for
   inspecting fields, variants, copy properties and layout; it is never
   used to substitute a nominal value's identity for ordinary equality.
   Function param CONVENTIONS are deliberately ignored: they are a
   call-site concern (checked as access effects), not a value-shape
   concern. *)
let rec types_compatible (ctx : ctx) (a : Type_repr.t) (b : Type_repr.t) : bool =
  match a, b with
  | Type_repr.Type_param pa, Type_repr.Type_param pb ->
      (* rigid params are compatible exactly when they are the SAME
         declaration binder (template bodies legitimately compare their
         own params against themselves — locals, aggregates, casts) *)
      Ids.Generic_param_id.compare pa pb = 0
  | Type_repr.Named (ta, [| t |]), u when is_box_tid ctx ta ->
      (* the checker's transparent-Box unify (typecheck's is_box rule):
         Box[T] erases to T in both directions — a Box-wrapped value
         passes where its content is expected and vice versa (`&lhs`
         with lhs: Box[Expr] at an `expr: Expr` parameter, an Option
         payload that the checker recorded erased), so the lowered MIR
         compares through the wrapper exactly where the checker did *)
      types_compatible ctx t u
  | u, Type_repr.Named (ta, [| t |]) when is_box_tid ctx ta ->
      types_compatible ctx u t
  | Type_repr.Fixed_array (t, _), Type_repr.Named (id, [| e |])
    when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
      (* the checker's fixed-array→Vec element rule (typecheck's method
         dispatch unifies a [T; n]-typed receiver against a Vec[T]
         method's self by element — `let known = [...]` bound values
         used through Vec methods like `.contains`).  The two forms are
         the same runtime value (Vm_value.Array — the ArrayAgg fills
         both), so a Fixed-array actual is compatible with a Vec
         expectation exactly when their elements are; the Vec nominal
         is matched on the concrete type#0 base, never a user nominal. *)
      types_compatible ctx t e
  | Type_repr.Named (id, [| e |]), Type_repr.Fixed_array (t, _)
    when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
      (* the mirror direction (the expected/actual pair may arrive in
         either order at the call-arg/aggregate checks) *)
      types_compatible ctx t e
  | Type_repr.Named (ta, aargs), Type_repr.Named (tb, bargs) ->
      (* NOMINAL identity is EXACT canonical-id equality (audit P0-13):
         two materialized instances of generic templates are the same
         type exactly when they are the SAME canonical specialized id —
         the shared Canonical_type_instance cache interns every consumer,
         so logically identical instances (the checker's literal-solved
         vs integer-kind spellings, the 64-bit alias spellings) always
         materialize under ONE id, never under two defs the verifier
         would have to reconcile by comparing their concrete def shapes
         one level deep.  Distinct canonical ids — genuinely different
         instances (Pair[Int] vs Pair[String]) — are never compatible,
         however similar their def shapes; the args compare pairwise
         under the same compatibility, exactly like every other
         same-id pair. *)
      (ta = tb
       && Array.length aargs = Array.length bargs
       && (let ok = ref true in
           Array.iteri
             (fun i t -> if not (types_compatible ctx aargs.(i) t) then ok := false)
             bargs;
           !ok))
  | Type_repr.Named _, _ | _, Type_repr.Named _ ->
      (* one side nominal, the other structural: the comparison is
         structural-by-nature, so the nominal side is resolved — but
         never both-nominal (handled above); an unresolvable nominal
         (no def-table entry) fails closed *)
      let ra = resolve_or_self ctx a and rb = resolve_or_self ctx b in
      (match ra, rb with
       | Type_repr.Named _, _ | _, Type_repr.Named _ -> false
       | _ -> types_compatible ctx ra rb)
  | Type_repr.Unit, Type_repr.Unit -> true
  | Type_repr.Bool, Type_repr.Bool -> true
  | Type_repr.Char, Type_repr.Char -> true
  | Type_repr.Int k1, Type_repr.Int k2 -> int_kind_alias k1 k2
  | Type_repr.Int_literal m, Type_repr.Int k
  | Type_repr.Int k, Type_repr.Int_literal m ->
      (* the checker's literal adoption: an unsuffixed literal's record
         is compatible with any concrete integer kind its magnitude fits
         (the lowered slots/instances of a literal-solved generic keep
         the raw Int_literal — `out.push(0xC5)` — and compare exactly
         like the checker unified them) *)
      int_literal_fits k m
  | Type_repr.Int_literal _, Type_repr.Int_literal _ -> true
  | Type_repr.Float f1, Type_repr.Float f2 -> f1 = f2
  | Type_repr.String, Type_repr.String -> true
  | Type_repr.Raw_ptr (m1, t1), Type_repr.Raw_ptr (m2, t2) ->
      m1 = m2 && types_compatible ctx t1 t2
  | Type_repr.Ref_internal (m1, t1), Type_repr.Ref_internal (m2, t2) ->
      m1 = m2 && types_compatible ctx t1 t2
  | Type_repr.Tuple e1, Type_repr.Tuple e2 ->
      Array.length e1 = Array.length e2
      && (let ok = ref true in
          Array.iteri
            (fun i t -> if not (types_compatible ctx e1.(i) t) then ok := false)
            e2;
          !ok)
  | Type_repr.Fixed_array (t1, n1), Type_repr.Fixed_array (t2, n2) ->
      n1 = n2 && types_compatible ctx t1 t2
  | Type_repr.Function (p1, r1), Type_repr.Function (p2, r2) ->
      Array.length p1 = Array.length p2
      && (let ok = ref true in
          Array.iteri
            (fun i p ->
              if not (types_compatible ctx p1.(i).Type_repr.pt_type p.Type_repr.pt_type)
              then ok := false)
            p2;
          !ok)
      && types_compatible ctx r1 r2
  | Type_repr.Never, Type_repr.Never -> true
  | _ -> false

(* The ABI address-of allowance (the checker's sanctioned
   ref_to_raw_ptr call-site coercion, mirrored at the MIR call
   boundary): a borrow argument `&x` against a Ptr[T]/PtrMut[T]
   parameter — the __sync_* primitives, the allocator internals —
   LOWERS to the place x itself (the seed represents the address by
   the place), so the callee's Ptr[pointee] parameter accepts an
   actual of the pointee type exactly when the expected nominal's def
   is the raw-pointer handle — the single-{address: UInt}-field struct
   shape — and the pointee matches the actual.  The checker applies
   the coercion only there (never in unify), so the mirror stays
   equally narrow. *)
(* The checker's IntLiteral adoption at a call ARGUMENT whose expected
   was still an unsolved inference variable when the literal was
   checked (`var data = Vec::new(); data.push(0xff)` — the push's
   value param is the receiver's element var, solved only later by the
   fn-return to Vec[u8]): the literal records Int_literal and LOWERS
   as the default Int-kind constant, so an Integer CONSTANT argument
   is accepted at any integer-kind parameter whose range fits its
   magnitude — exactly the checker's fits decision, never a silent
   truncation (the encoder fns' `data.push(0xff)`-style byte pushes —
   the `expected u8 got Int` call-arg class). *)
let const_int_arg_fits_ok (_ctx : ctx) (arg : Seed_mir.operand)
    (expected : Type_repr.t) : bool =
  let int_fits_64 (k : Type_repr.int_kind) (v : int64) : bool =
    if int_kind_signed k then
      (* the signed range of the parameter kind: -(2^(w-1)) .. 2^(w-1)-1 *)
      if int_kind_width k = 64 then true
      else
        let upper = Int64.shift_left 1L (int_kind_width k - 1) in
        Int64.compare v (Int64.neg upper) >= 0 && Int64.compare v (Int64.sub upper 1L) <= 0
    else
      (* an unsigned parameter accepts any non-negative magnitude
         below 2^w (255 fits u8 — the checker's fits_unsigned) *)
      if v < 0L then false
      else if int_kind_width k = 64 then true
      else
        let upper = Int64.shift_left 1L (int_kind_width k) in
        Int64.compare v (Int64.sub upper 1L) <= 0
  in
  match arg with
  | Seed_mir.Constant (Seed_mir.Integer v) -> (
      match expected with
      | Type_repr.Int k ->
          if v.Int_value.width > 64 then false
          else int_fits_64 k (Int_value.to_int64 v)
      | Type_repr.Int_literal _ -> true
      | _ -> false)
  | _ -> false

let ptr_addr_ok (ctx : ctx) (expected : Type_repr.t) (actual : Type_repr.t) : bool =
  match expected with
  | Type_repr.Named (tid, [| pointee |]) -> (
      match find_def ctx tid with
      | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
          match sd_fields with
          | [ f ]
            when
              (match f.Seed_mir.fd_ty with
               | Type_repr.Int Type_repr.UInt -> true
               | _ -> false) ->
              types_compatible ctx pointee actual
          | _ -> false)
      | _ -> false)
  | _ -> false

(* The call-boundary DEREF rule (the checker's sanctioned deref-first
   adaptation, mirrored at the MIR call boundary): an argument of REF
   type at a BY-VALUE parameter derefs to its pointee — `key_ref` (the
   live key's ADDRESS, yielded by the record-visit intrinsics as
   Option[&K]) passed to the intrinsic's opaque `key_ref: K`
   parameter, and the &K receiver of a Clone-contract call whose self
   parameter is K (the seed's by-value ABI for owning parameters
   passes the value by address — the ref argument IS the address).
   The argument operand is the ref-typed READ the lowering emits, so
   the verifier accepts actual = &t against expected = t. *)
let deref_arg_ok (ctx : ctx) (expected : Type_repr.t) (actual : Type_repr.t) : bool =
  match actual with
  | Type_repr.Ref_internal (_, t) -> types_compatible ctx expected t
  | _ -> false

(* Whether a type is the raw-pointer HANDLE nominal (Ptr[T]/PtrMut[T]
   — the single-{address: UInt}-field struct): the cast surface
   (`x as Ptr[T]` — the seed's raw address rebrand, address_of) and
   the verifier's scalar/pointer cast-target matrix treat it as the
   pointer class it is. *)
let is_ptr_handle (ctx : ctx) (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Named (tid, _) -> (
      match find_def ctx tid with
      | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
          match sd_fields with
          | [ f ]
            when
              (match f.Seed_mir.fd_ty with
               | Type_repr.Int Type_repr.UInt -> true
               | _ -> false) ->
              true
          | _ -> false)
      | _ -> false)
  | _ -> false

(* Whether the resolved type is an ENUM def (Function with Never ret),
   and the payload type of one of its variants.  The enum's runtime
   tag is the declaration-order vd_index: EnumCtor tags, SetDiscriminant
   and SwitchInt values are the positional indices (the seed model
   collapses the reference's discriminant table), so these positional
   helpers stay in-bounds checks over the def_repr. *)
let enum_variant_payload (ctx : ctx) (ty : Type_repr.t) (vid : Ids.Variant_index.t) :
    Type_repr.t option =
  match resolve_or_self ctx ty with
  | Type_repr.Function (variants, Type_repr.Never) ->
      let i = Ids.Variant_index.to_int vid in
      if i >= 0 && i < Array.length variants then
        Some variants.(i).Type_repr.pt_type
      else None
  | _ -> None

(* re-audit P0-C: the intrinsic registry's declared types use its own
   placeholder id domain (option=1, vec=2, map=3, set=4) while the MIR
   carries the checker-minted LangItem ids (array=0, map=1, set=2,
   option=3).  The verifier maps the registry ids onto the checker ids
   before the compatibility comparison, so argument and destination
   types are checked for every intrinsic exactly like User calls. *)
let registry_type_to_checker (ty : Type_repr.t) : Type_repr.t =
  let rec go t =
    match t with
    | Type_repr.Named (tid, args) ->
        let tid' =
          if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.option_) = 0 then
            Ids.Type_id.make 3
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.vec) = 0 then
            Ids.Type_id.make 0
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.map) = 0 then
            Ids.Type_id.make 1
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.set) = 0 then
            Ids.Type_id.make 2
          else tid
        in
        Type_repr.Named (tid', Array.map go args)
    | Type_repr.Fixed_array (e, n) -> Type_repr.Fixed_array (go e, n)
    | Type_repr.Tuple elems -> Type_repr.Tuple (Array.map go elems)
    | t -> t
  in
  go ty

let rec intrinsic_type_compatible (ctx : ctx) (declared : Type_repr.t) (actual : Type_repr.t) : bool =
  match declared with
  | Type_repr.Type_param _ -> true
  | Type_repr.Unit -> true
  | Type_repr.Named (id1, a1) -> (
      let id1' =
        if Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.option_) = 0 then
          Ids.Type_id.make 3
        else if Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.vec) = 0 then
          Ids.Type_id.make 0
        else if Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.map) = 0 then
          Ids.Type_id.make 1
        else if Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.set) = 0 then
          Ids.Type_id.make 2
        else id1
      in
      match actual with
      | Type_repr.Named (id2, a2)
        when Ids.Type_id.compare id1' id2 = 0 && Array.length a1 = Array.length a2 ->
          Array.for_all2 (fun d a -> intrinsic_type_compatible ctx d a) a1 a2
      (* the entries cache is lowered as the Fixed_array form — the
         declared Vec[T] element matches the fixed array's element *)
      | Type_repr.Fixed_array (e2, _)
        when Ids.Type_id.compare id1' (Ids.Type_id.make 0) = 0
             && Array.length a1 = 1 ->
          intrinsic_type_compatible ctx a1.(0) e2
      | _ -> false)
  | Type_repr.Fixed_array (e1, n1) -> (
      match actual with
      | Type_repr.Fixed_array (e2, n2) when n1 = n2 ->
          intrinsic_type_compatible ctx e1 e2
      | _ -> false)
  | Type_repr.Tuple a1 -> (
      match actual with
      | Type_repr.Tuple a2 when Array.length a1 = Array.length a2 ->
          Array.for_all2 (fun d a -> intrinsic_type_compatible ctx d a) a1 a2
      | _ -> false)
  | Type_repr.Int _
    when (match actual with Type_repr.Int _ -> true | _ -> false) ->
      (* the int-kind adoption rule (the checker's int_kind_adopt call
         boundary — the kernel passes width-typed values where a plain
         Int is declared, and the VM's Int_value adapters convert by
         width): an intrinsic/registry parameter accepts ANY integer
         kind (__intrinsic_int_to_string receives UInt receivers
         through the derived to_string surface) *)
      true
  | declared' -> types_compatible ctx (registry_type_to_checker declared') actual

let enum_def_arity (ctx : ctx) (ty : Type_repr.t) : int option =
  match resolve_or_self ctx ty with
  | Type_repr.Function (variants, Type_repr.Never) -> Some (Array.length variants)
  (* the checker's Option/Result LangItem nominals are the canonical
     two-variant enums — the program's types table carries their defs
     only when the closure materialized them, so the verifier knows
     the arity by the semantic id (the same id domain the checker
     mints for every use) *)
  | Type_repr.Named (tid, _)
    when Ids.Type_id.compare tid (Ids.Type_id.make 3) = 0
         || Ids.Type_id.compare tid (Ids.Type_id.make 4) = 0 ->
      Some 2
  | _ -> None

(* The raw-pointer HANDLE nominals — the checker's builtin Ptr (id 5)
   and PtrMut (id 6): the source `struct Ptr[T] { address: UInt }`
   pointer class whose VALUES the seed VM represents as RawPtr (deref
   reads/writes go through the simulated memory).  The Rc/Weak/Arc
   stdlib impls deref THROUGH them — `self.ptr.as_mut().refcount`
   (Ptr::as_mut's registered return type IS the PtrMut nominal, never
   a Ref_internal) and the raw-deref PLACE form (deref of self.ptr
   then a field) — so a Deref projection legally applies to the handle
   nominal with pointee = its single type argument, exactly the deref
   rule the checker applies at its field/place layer (typecheck.ml's
   b_ptr/b_ptrmut cases).  The check runs on the UNRESOLVED form: the
   handle's def (when materialized) is the address-UInt struct, whose
   structural resolution must not hide the pointer class. *)
let ptr_handle_pointee (ty : Type_repr.t) : Type_repr.t option =
  match ty with
  | Type_repr.Named (id, [| t |])
    when Ids.Type_id.compare id (Ids.Type_id.make 5) = 0
         || Ids.Type_id.compare id (Ids.Type_id.make 6) = 0 ->
      Some t
  | _ -> None

(* The type produced by applying one projection; None = illegal.
   Field/Downcast resolve the SEMANTIC id in the projected base's own
   def (the owner-identity rule); ConstantIndex also admits Tuple bases
   — the variant-payload positions are tuples (like the reference's
   TupleIndex, tuples have no FieldId), so payload access is positional. *)
let project_type (ctx : ctx) (ty : Type_repr.t) (proj : projection) : Type_repr.t option =
  match proj with
  | Deref -> (
      (* deref over the reference/raw-pointer kinds, the Ptr/PtrMut
         handle nominals (the seed's pointer values) AND the checker's
         transparent Box nominal (its deref-on-field/place rule — the
         Box wrapper derefs to its single type argument, the kernel's
         `*expr` over a Box[Expr] binding) *)
      match ptr_handle_pointee ty with
      | Some t -> Some t
      | None -> (
          match ty with
          | Type_repr.Named (id, [| t |]) when is_box_tid ctx id -> Some t
          | _ -> (
              match resolve_or_self ctx ty with
              | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> Some t
              | _ -> None)))
  | Field fid -> (
      match ty with
      | Type_repr.Named (tid, args) -> struct_field_ty ctx tid args fid
      | _ -> None)
  | ConstantIndex i -> (
      (* the runtime Vec/Array base (the named Array nominal, type-id
         0) is admitted BEFORE def resolution — the same rule as the
         dynamic Index: the Vec[T] def (a field-less declaration whose
         runtime value is a heap header) must not collapse the base to
         its empty structural form (the fs/time kernels' `buf[0] = ...`
         byte-pack writers are the class) *)
      match ty with
      | Type_repr.Named (id, [| elem |])
        when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
          Some elem
      | Type_repr.Fixed_array (elem, n) when i >= 0 && i < n -> Some elem
      | _ -> (
          match resolve_or_self ctx ty with
          | Type_repr.Fixed_array (elem, n) when i >= 0 && i < n -> Some elem
          | Type_repr.Tuple elems when i >= 0 && i < Array.length elems -> Some elems.(i)
          (* re-audit item 17: the String byte-index projection (the seed's
             documented byte convention) — the projected element is Char *)
          | Type_repr.String -> Some Type_repr.Char
          | _ -> None))
  | Index li -> (
      (* dynamic-index form: the payload is the LOCAL whose runtime
         integer value is the index.  The runtime value is unknown at
         compile time, so only the base shape constrains the projected
         type; the index local's existence/initialization/type are
         checked in check_projection_owners and the runtime bounds are
         checked by the VM at execution.  The runtime Vec/Array base
         (the named Array nominal, type-id 0) is admitted — the VM's
         dynamic Index handles the Array value.  The nominal-by-id form
         is matched BEFORE def resolution: the Vec[T] def (a field-less
         declaration in std/collections.tg — the runtime value is a
         heap header, never a struct value) must not collapse the
         base to its empty structural form. *)
      ignore li;
      match ty with
      | Type_repr.Named (id, [| elem |])
        when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
          Some elem
      | _ -> (
          match resolve_or_self ctx ty with
          | Type_repr.Fixed_array (elem, _) -> Some elem
          | Type_repr.String -> Some Type_repr.Char
          | _ -> None))
  | Downcast vid -> (
      match ty with
      | Type_repr.Named (tid, args) -> (
          match enum_variant_ty ctx tid args vid with
          | Some t -> Some t
          | None ->
              (* re-audit P0-B: the checker's Option/Result LangItem
                 nominals are the canonical two-variant enums — variant 0
                 (Some/Ok) carries the payload argument; the program's
                 types table carries their defs only when the closure
                 materialized them, so the verifier resolves the payload
                 by the semantic id *)
              if (Ids.Type_id.compare tid (Ids.Type_id.make 3) = 0
                  || Ids.Type_id.compare tid (Ids.Type_id.make 4) = 0)
                 && Ids.Variant_id.to_int vid = 0
                 && Array.length args > 0
              then Some args.(0)
              else None)
      | _ -> None)

let place_type (ctx : ctx) (fn : function_) (p : place) : Type_repr.t option =
  (* the explicit root (re-audit item 20): a Static root addresses the
     program's statics table directly — exempt from the frame locals *)
  match p.root with
  | Seed_mir.Static idx ->
      if p.projections = [] then
        if idx >= 0 && idx < Array.length ctx.prog.Seed_mir.statics then
          let (_, ty, _, _) = ctx.prog.Seed_mir.statics.(idx) in
          Some ty
        else None
      else
        (* the projected global (re-audit item 20): the projection walk
           applies to the static's declared type exactly like a local
           aggregate — the old negative-root branch rejected any
           projection, disagreeing with the VM's projection machinery *)
        List.fold_left
          (fun acc proj ->
            match acc with None -> None | Some ty -> project_type ctx ty proj)
          (match
             if idx >= 0 && idx < Array.length ctx.prog.Seed_mir.statics then
               let (_, ty, _, _) = ctx.prog.Seed_mir.statics.(idx) in
               Some ty
             else None
           with
          | Some ty -> Some ty
          | None -> None)
          p.projections
  | Seed_mir.Local lid ->
      if lid >= Array.length fn.locals then None
      else
        List.fold_left
          (fun acc proj ->
            match acc with
            | None -> None
            | Some ty -> project_type ctx ty proj)
          (Some fn.locals.(lid)) p.projections

(* ──────────────────────────────────────────────────────────────────
   Place keys for the moved/destroyed lattices (reference-mirroring).

   "" = the whole root; "*" = a whole-value boundary (a chain containing
   a deref or a dynamic-index projection); Field contributes its
   semantic FieldId, ConstantIndex contributes "<i>", Downcast
   contributes nothing. *)

let place_key (p : place) : string =
  if p.projections = [] then ""
  else
    let segs = ref [] and boundary = ref false in
    List.iter
      (function
        | Deref | Index _ -> boundary := true
        | Downcast _ -> ()
        | Field fid -> segs := Printf.sprintf "field#%d" (Ids.Field_id.to_int fid) :: !segs
        | ConstantIndex i -> segs := string_of_int i :: !segs)
      p.projections;
    if !boundary then "*"
    else if !segs = [] then "*"
    else String.concat "." (List.rev !segs)

let key_moved (moved : StrSet.t IntMap.t) (root : int) (key : string) : bool =
  match IntMap.find_opt root moved with
  | None -> false
  | Some set ->
      if StrSet.is_empty set then false
      else if key = "" then true
      else if key = "*" then StrSet.exists (fun m -> m = "" || m = "*") set
      else
        StrSet.exists
          (fun m ->
            m = "" || m = "*" || m = key
            || String.starts_with ~prefix:(m ^ ".") key)
          set

let key_insert (moved : StrSet.t IntMap.t) (root : int) (key : string) : StrSet.t IntMap.t =
  let set = Option.value (IntMap.find_opt root moved) ~default:StrSet.empty in
  let set' =
    if key = "" || key = "*" then StrSet.singleton key
    else
      StrSet.add key
        (StrSet.filter (fun m -> not (String.starts_with ~prefix:(key ^ ".") m)) set)
  in
  IntMap.add root set' moved

let key_clear (moved : StrSet.t IntMap.t) (root : int) (key : string) : StrSet.t IntMap.t =
  match IntMap.find_opt root moved with
  | None -> moved
  | Some set ->
      if key = "" then IntMap.remove root moved
      else
        let keep =
          if key = "*" then StrSet.filter (fun m -> m <> "*") set
          else
            StrSet.filter
              (fun m -> m <> key && not (String.starts_with ~prefix:(key ^ ".") m))
              set
        in
        if StrSet.is_empty keep then IntMap.remove root moved
        else IntMap.add root keep moved

(* Duplicate-drop detection: an exact destroyed key, or a destroyed
   strict prefix covering the key ("x.a" destroyed makes "x.a.b" a
   double-drop).  Whole-root "" does NOT cover field keys (finalizer-
   then-fields), and the "*" boundary (loop-carried glue) is not
   comparable. *)
let destroyed_key_conflict (destroyed : StrSet.t IntMap.t) (root : int) (key : string) : bool =
  match IntMap.find_opt root destroyed with
  | None -> false
  | Some set ->
      StrSet.exists
        (fun m ->
          m <> "*" && (m = key || (m <> "" && String.starts_with ~prefix:(m ^ ".") key)))
        set

(* P1-26 drop-plan consult: a whole-root Drop/Deinit of a LOCAL destroys
   the local's owning component paths — the destroyed lattice records
   the canonical type-level plan's needs_drop paths (per concrete
   TypeId, drop_plan.ml) alongside the root key, so a later drop of any
   owning component of the same root is a duplicate-drop finding,
   exactly as the VM's do_drop (which drops the whole root slot for any
   key) traps on the second drop of the root local.  A value whose type
   has no materialized plan contributes only its own key (the
   structural-glue fallback). *)
let destroyed_keys_of_drop (ctx : ctx) (fn : function_) (p : place) : string list =
  match p.root with
  | Local l when p.projections = [] && l >= 0 && l < Array.length fn.locals ->
      Drop_plan.owning_paths ctx.drop_plans fn.locals.(l)
  | _ -> []

(* ──────────────────────────────────────────────────────────────────
   Constants *)

let int_kind_of (v : int_value) : Type_repr.t =
  match v.width, v.signed with
  | 8, true -> Type_repr.Int Type_repr.I8
  | 16, true -> Type_repr.Int Type_repr.I16
  | 32, true -> Type_repr.Int Type_repr.I32
  | 64, true -> Type_repr.Int Type_repr.Int
  | 128, true -> Type_repr.Int Type_repr.I128
  | 8, false -> Type_repr.Int Type_repr.U8
  | 16, false -> Type_repr.Int Type_repr.U16
  | 32, false -> Type_repr.Int Type_repr.U32
  | 64, false -> Type_repr.Int Type_repr.UInt
  | 128, false -> Type_repr.Int Type_repr.U128
  | _ -> Type_repr.Unit

let int_value_in_range (v : int_value) : bool =
  let w = v.width in
  if w <= 0 || w > 128 then false
  else if v.bits_hi <> 0L && w <= 64 then false
  else if w > 64 then true
  else if v.signed then begin
    if w = 64 then true
    else begin
      let maxv = Int64.sub (Int64.shift_left 1L (w - 1)) 1L in
      let minv = Int64.neg (Int64.shift_left 1L (w - 1)) in
      v.bits_lo >= minv && v.bits_lo <= maxv
    end
  end
  else if w = 64 then true
  else v.bits_lo >= 0L && Int64.unsigned_compare v.bits_lo (Int64.shift_left 1L w) < 0

(* ──────────────────────────────────────────────────────────────────
   CFG helpers *)

let block_table (fn : function_) : (int, block) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  Array.iter (fun b -> Hashtbl.add tbl b.id b) fn.blocks;
  tbl

let terminator_successors (t : terminator) : int list =
  match t with
  | Goto b -> [ b ]
  | Ret | Unreachable | Abort -> []
  | SwitchInt (_, arms, default) -> List.map snd arms @ [ default ]
  | Call (_, _, _, next, unwind) | Drop (_, next, unwind) | Deinit (_, next, unwind) ->
      next :: Option.to_list unwind
  | Assert (_, _, _, target) -> [ target ]

let reachable_blocks (fn : function_) (tbl : (int, block) Hashtbl.t) : IntSet.t =
  let seen = Hashtbl.create 16 in
  let q = Queue.create () in
  let visit id =
    if not (Hashtbl.mem seen id) && Hashtbl.mem tbl id then begin
      Hashtbl.add seen id ();
      Queue.push id q
    end
  in
  visit fn.entry;
  while not (Queue.is_empty q) do
    let id = Queue.pop q in
    let b = Hashtbl.find tbl id in
    List.iter visit (terminator_successors b.terminator)
  done;
  Hashtbl.fold (fun id () acc -> IntSet.add id acc) seen IntSet.empty

(* ──────────────────────────────────────────────────────────────────
   Definite-initialization dataflow: per-block in-sets.

   An assign initializes its root; a CALL initializes its destination;
   StorageLive contributes nothing (storage existence != initialization);
   StorageDead kills the local. *)

let init_in_sets (fn : function_) (tbl : (int, block) Hashtbl.t) : (int, IntSet.t) Hashtbl.t =
  let preds = Hashtbl.create 16 in
  Hashtbl.iter (fun id _ -> Hashtbl.replace preds id []) tbl;
  Hashtbl.iter
    (fun id b ->
      List.iter
        (fun s ->
          Hashtbl.replace preds s
            (id :: Option.value (Hashtbl.find_opt preds s) ~default:[]))
        (terminator_successors b.terminator))
    tbl;
  let block_out (b : block) (new_in : IntSet.t) : IntSet.t =
    let out = ref new_in in
    List.iter
      (function
        | Assign (p, _) -> out := IntSet.add (root_key p.root) !out
        | StorageLive _ -> ()
        | StorageDead l -> out := IntSet.remove l !out
        | SetDiscriminant _ | Nop -> ())
      b.statements;
    (match b.terminator with
     | Call (dest, _, _, _, _) -> out := IntSet.add (root_key dest.root) !out
     | _ -> ());
    !out
  in
  let in_set = Hashtbl.create 16 and out_set = Hashtbl.create 16 in
  (* locals: _0 is the return slot; params occupy _1 .. _n *)
  (* re-audit P0-A: a Set (Initialize) parameter enters the function
     UNINITIALIZED — the definite-initialization dataflow must not
     believe it is live at entry; the callee must initialize it before
     every successful return *)
  let entry_init =
    IntSet.of_list
      (List.filter
         (fun lid ->
           let pidx = lid - 1 in
           pidx < 0 || pidx >= Array.length fn.params
           || (Access_effect.read_effect fn.params.(pidx).Type_repr.pt_convention
              <> Access_effect.Initialize))
         (List.init (Array.length fn.params) (fun i -> i + 1)))
  in
  Hashtbl.add in_set fn.entry entry_init;
  let work = Queue.create () in
  let in_work = Hashtbl.create 16 in
  Hashtbl.add in_work fn.entry ();
  Queue.push fn.entry work;
  while not (Queue.is_empty work) do
    let bid = Queue.pop work in
    Hashtbl.remove in_work bid;
    let new_in =
      if bid = fn.entry then entry_init
      else
        List.fold_left
          (fun acc pid ->
            match Hashtbl.find_opt out_set pid with
            | None -> acc
            | Some oset -> if IntSet.is_empty acc then oset else IntSet.inter acc oset)
          IntSet.empty (Option.value (Hashtbl.find_opt preds bid) ~default:[])
    in
    let changed =
      match Hashtbl.find_opt in_set bid with
      | None -> true
      | Some old -> not (IntSet.equal old new_in) || not (Hashtbl.mem out_set bid)
    in
    Hashtbl.replace in_set bid new_in;
    (match Hashtbl.find_opt tbl bid with
     | None -> ()
     | Some b -> Hashtbl.replace out_set bid (block_out b new_in));
    if changed then
      (match Hashtbl.find_opt tbl bid with
       | None -> ()
       | Some b ->
           List.iter
             (fun sid ->
               if not (Hashtbl.mem in_work sid) then begin
                 Hashtbl.add in_work sid ();
                 Queue.push sid work
               end)
             (terminator_successors b.terminator))
  done;
  in_set

(* ──────────────────────────────────────────────────────────────────
   May-moved dataflow: per-block in-sets of (root -> moved place keys).
   Moves/consumes transfer ownership; assigns re-live the destination
   chain; StorageLive/StorageDead reset the root. *)

let operand_moved_targets (moved : StrSet.t IntMap.t) (op : operand) : StrSet.t IntMap.t =
  match op with
  | Move p | Consume p ->
      (* the "*"-boundary rule (the Rc/Weak class): a transfer whose
         place chain crosses a Deref or dynamic-Index boundary consumes
         a MEMORY/container-domain component — the VM writes the Moved
         hole into the region payload (or the indexed element), never
         into the root local's own slot — so the ROOT stays Live and
         its own fields stay readable (the Rc::try_unwrap payload move
         is followed by as_mut/dealloc reads of the root's ptr field;
         the Arc drop's weak-count re-read happens after the
         refcount-payload decrement).  Recording the "*" whole-value
         key made every later read of the root look consumed.  The
         memory domain is not root-keyed, so nothing is recorded; the
         root-keyed lattice still tracks every field/whole-root
         transfer exactly. *)
      (match place_key p with
       | "*" -> moved
       | key -> key_insert moved (root_key p.root) key)
  | Copy _ | Read _ | Constant _ -> moved

let rvalue_moved_targets (moved : StrSet.t IntMap.t) (rv : rvalue) : StrSet.t IntMap.t =
  match rv with
  | Use op | Cast (op, _) | UnaryOp (_, op) -> operand_moved_targets moved op
  | Aggregate (_, ops) -> List.fold_left operand_moved_targets moved ops
  | BinaryOp (_, l, r) -> operand_moved_targets (operand_moved_targets moved l) r
  | Ref _ | RefMut _ | Discriminant _ | Len _ -> moved

let terminator_moved_targets (moved : StrSet.t IntMap.t) (t : terminator) : StrSet.t IntMap.t =
  match t with
  | Call (dest, _, args, _, _) ->
      (* the call DESTINATION is a definition: the moved-state dataflow
         clears the dest root exactly like an Assign destination — a
         loop that re-runs a call (`cursor = visit_next(...)` — the
         call lands in a fresh temp per iteration and the temp is moved
         into the cursor) would otherwise carry the temp's moved state
         from the previous iteration around the back edge and report a
         spurious second consume on every iteration after the first *)
      key_clear
        (Array.fold_left (fun acc a -> operand_moved_targets acc a.value) moved args)
        (root_key dest.root) (place_key dest)
  | SwitchInt (op, _, _) | Assert (op, _, _, _) -> operand_moved_targets moved op
  | _ -> moved

let moved_in_sets (fn : function_) (tbl : (int, block) Hashtbl.t) : (int, StrSet.t IntMap.t) Hashtbl.t =
  let preds = Hashtbl.create 16 in
  Hashtbl.iter (fun id _ -> Hashtbl.replace preds id []) tbl;
  Hashtbl.iter
    (fun id b ->
      List.iter
        (fun s ->
          Hashtbl.replace preds s
            (id :: Option.value (Hashtbl.find_opt preds s) ~default:[]))
        (terminator_successors b.terminator))
    tbl;
  let merge (acc : StrSet.t IntMap.t) (pm : StrSet.t IntMap.t) : StrSet.t IntMap.t =
    IntMap.fold
      (fun root keys acc ->
        let cur = Option.value (IntMap.find_opt root acc) ~default:StrSet.empty in
        IntMap.add root (StrSet.union cur keys) acc)
      pm acc
  in
  let block_out (b : block) (new_in : StrSet.t IntMap.t) : StrSet.t IntMap.t =
    let out = ref new_in in
    List.iter
      (function
        | Assign (p, rv) ->
            out := rvalue_moved_targets !out rv;
            out := key_clear !out (root_key p.root) (place_key p)
        | StorageLive l | StorageDead l -> out := IntMap.remove l !out
        | SetDiscriminant _ | Nop -> ())
      b.statements;
    out := terminator_moved_targets !out b.terminator;
    !out
  in
  let in_set = Hashtbl.create 16 and out_set = Hashtbl.create 16 in
  Hashtbl.add in_set fn.entry IntMap.empty;
  let work = Queue.create () in
  let in_work = Hashtbl.create 16 in
  Hashtbl.add in_work fn.entry ();
  Queue.push fn.entry work;
  while not (Queue.is_empty work) do
    let bid = Queue.pop work in
    Hashtbl.remove in_work bid;
    let new_in =
      if bid = fn.entry then IntMap.empty
      else
        List.fold_left
          (fun acc pid ->
            match Hashtbl.find_opt out_set pid with
            | None -> acc
            | Some om -> merge acc om)
          IntMap.empty (Option.value (Hashtbl.find_opt preds bid) ~default:[])
    in
    let changed =
      match Hashtbl.find_opt in_set bid with
      | None -> true
      | Some old -> not (IntMap.equal StrSet.equal old new_in) || not (Hashtbl.mem out_set bid)
    in
    Hashtbl.replace in_set bid new_in;
    (match Hashtbl.find_opt tbl bid with
     | None -> ()
     | Some b -> Hashtbl.replace out_set bid (block_out b new_in));
    if changed then
      (match Hashtbl.find_opt tbl bid with
       | None -> ()
       | Some b ->
           List.iter
             (fun sid ->
               if not (Hashtbl.mem in_work sid) then begin
                 Hashtbl.add in_work sid ();
                 Queue.push sid work
               end)
             (terminator_successors b.terminator))
  done;
  in_set

(* ──────────────────────────────────────────────────────────────────
   Destroyed-state dataflow (duplicate-drop detection across blocks). *)

let destroyed_in_sets (ctx : ctx) (fn : function_) (tbl : (int, block) Hashtbl.t) :
    (int, StrSet.t IntMap.t) Hashtbl.t =
  let preds = Hashtbl.create 16 in
  Hashtbl.iter (fun id _ -> Hashtbl.replace preds id []) tbl;
  Hashtbl.iter
    (fun id b ->
      List.iter
        (fun s ->
          Hashtbl.replace preds s
            (id :: Option.value (Hashtbl.find_opt preds s) ~default:[]))
        (terminator_successors b.terminator))
    tbl;
  let merge (acc : StrSet.t IntMap.t) (pm : StrSet.t IntMap.t) : StrSet.t IntMap.t =
    IntMap.fold
      (fun root keys acc ->
        let cur = Option.value (IntMap.find_opt root acc) ~default:StrSet.empty in
        IntMap.add root (StrSet.union cur keys) acc)
      pm acc
  in
  let block_out (b : block) (new_in : StrSet.t IntMap.t) : StrSet.t IntMap.t =
    let out = ref new_in in
    List.iter
      (function
        | Assign (p, _) -> out := key_clear !out (root_key p.root) (place_key p)
        | StorageLive l | StorageDead l -> out := IntMap.remove l !out
        | SetDiscriminant _ | Nop -> ())
      b.statements;
    (match b.terminator with
     | Drop (p, _, _) | Deinit (p, _, _) ->
         out := key_insert !out (root_key p.root) (place_key p);
         List.iter
           (fun k -> out := key_insert !out (root_key p.root) k)
           (destroyed_keys_of_drop ctx fn p)
     | _ -> ());
    !out
  in
  let in_set = Hashtbl.create 16 and out_set = Hashtbl.create 16 in
  Hashtbl.add in_set fn.entry IntMap.empty;
  let work = Queue.create () in
  let in_work = Hashtbl.create 16 in
  Hashtbl.add in_work fn.entry ();
  Queue.push fn.entry work;
  while not (Queue.is_empty work) do
    let bid = Queue.pop work in
    Hashtbl.remove in_work bid;
    let new_in =
      if bid = fn.entry then IntMap.empty
      else
        List.fold_left
          (fun acc pid ->
            match Hashtbl.find_opt out_set pid with
            | None -> acc
            | Some om -> merge acc om)
          IntMap.empty (Option.value (Hashtbl.find_opt preds bid) ~default:[])
    in
    let changed =
      match Hashtbl.find_opt in_set bid with
      | None -> true
      | Some old -> not (IntMap.equal StrSet.equal old new_in) || not (Hashtbl.mem out_set bid)
    in
    Hashtbl.replace in_set bid new_in;
    (match Hashtbl.find_opt tbl bid with
     | None -> ()
     | Some b -> Hashtbl.replace out_set bid (block_out b new_in));
    if changed then
      (match Hashtbl.find_opt tbl bid with
       | None -> ()
       | Some b ->
           List.iter
             (fun sid ->
               if not (Hashtbl.mem in_work sid) then begin
                 Hashtbl.add in_work sid ();
                 Queue.push sid work
               end)
             (terminator_successors b.terminator))
  done;
  in_set

(* ──────────────────────────────────────────────────────────────────
   Place / operand checking.

   check_operand is PURE: it reports errors and returns the operand's
   type but never mutates the moved lattice — the caller inserts the
   ownership transfer (rvalue_moved_targets / terminator_moved_targets)
   after the check. *)

(* Allowed integer types for a dynamic Index projection's index local
   (Seed_mir.Index of local) — matching the widths the VM's
   index_of_local accepts (64-bit-or-narrower integers). *)
let is_index_local_type (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Int Type_repr.Int
  | Type_repr.Int Type_repr.I32
  | Type_repr.Int Type_repr.I64
  | Type_repr.Int Type_repr.UInt
  | Type_repr.Int Type_repr.U32
  | Type_repr.Int Type_repr.U64
  | Type_repr.Int Type_repr.U8 ->
      true
  | _ -> false

let check_projection_owners (ctx : ctx) (fn : function_) (bb_ctx : string)
    (running : IntSet.t) (p : place) : unit =
  let rec go ty projs =
    match projs with
    | [] -> ()
    | proj :: rest -> (
        match proj with
        | Deref -> (
            (* deref over the reference/raw-pointer kinds, the Ptr/PtrMut
               handle nominals AND the transparent Box nominal (mirror
               of project_type) *)
            match ptr_handle_pointee ty with
            | Some t -> go t rest
            | None -> (
                match ty with
                | Type_repr.Named (id, [| t |]) when is_box_tid ctx id -> go t rest
                | _ -> (
                    match resolve_or_self ctx ty with
                    | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> go t rest
                    | _ ->
                        add_err ctx
                          (Printf.sprintf "%s: deref projection on non-pointer type %s" bb_ctx
                             (Seed_mir.print_type ty)))))
        | Field fid -> (
            (* the native owner-identity invariant: the projected
               FieldId must belong to the projected base's OWN struct
               def.  The positional fd_index is derived from the def's
               metadata (never trusted from the projection itself). *)
            match ty with
            | Type_repr.Named (tid, args) -> (
                match find_def ctx tid with
                | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
                    match
                      List.find_opt
                        (fun f -> Ids.Field_id.compare f.Seed_mir.fd_id fid = 0)
                        sd_fields
                    with
                    | Some f -> go (subst_registry_type ctx tid args f.Seed_mir.fd_ty) rest
                    | None ->
                        add_err ctx
                          (Printf.sprintf
                             "%s: field identity owner mismatch: FieldId %d does not belong to the projected base type#%d's struct def"
                             bb_ctx (Ids.Field_id.to_int fid) (Ids.Type_id.to_int tid)))
                | Some (Seed_mir.EnumDef _) ->
                    add_err ctx
                      (Printf.sprintf "%s: field projection on an enum value" bb_ctx)
                | None ->
                    add_err ctx
                      (Printf.sprintf
                         "%s: field projection on a type with no def in the types table" bb_ctx))
            | Type_repr.Tuple _ ->
                add_err ctx
                  (Printf.sprintf
                     "%s: field projection on a tuple (tuples have no FieldId — the seed uses ConstantIndex for tuple/payload positions)"
                     bb_ctx)
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: field projection on non-struct type %s" bb_ctx
                     (Seed_mir.print_type ty)))
        | ConstantIndex i -> (
            (* the runtime Vec/Array base (the named Array nominal,
               type-id 0) is admitted BEFORE def resolution — the same
               rule as the dynamic Index and project_type: the Vec[T]
               def (a field-less declaration) must not collapse the
               base to its empty structural form (the fs/time kernels'
               `buf[0] = ...` byte-pack writers are the class) *)
            match ty with
            | Type_repr.Named (id, [| elem |])
              when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
                go elem rest
            | Type_repr.Fixed_array (elem, n) ->
                if i < 0 || i >= n then
                  add_err ctx
                    (Printf.sprintf "%s: index %d out of bounds for array of length %d" bb_ctx i n)
                else go elem rest
            | _ -> (
            match resolve_or_self ctx ty with
            | Type_repr.Fixed_array (elem, n) ->
                if i < 0 || i >= n then
                  add_err ctx
                    (Printf.sprintf "%s: index %d out of bounds for array of length %d" bb_ctx i n)
                else go elem rest
            | Type_repr.Tuple elems ->
                (* the tuple form (native TupleIndex): variant payloads
                   are tuples with no FieldId, so payload positions are
                   indexed positionally *)
                if i < 0 || i >= Array.length elems then
                  add_err ctx
                    (Printf.sprintf "%s: tuple index %d out of bounds (arity %d)" bb_ctx i
                       (Array.length elems))
                else go elems.(i) rest
            (* re-audit item 17: String byte-index projection — the
               seed's documented byte convention (the VM extracts the
               byte at the index into a Char) *)
            | Type_repr.String -> go Type_repr.Char rest
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: index projection on non-array type %s" bb_ctx
                     (Seed_mir.print_type ty))))
        | Index li ->
            (* dynamic-index form: the payload is the LOCAL whose runtime
               integer value is the index.  The index local must exist,
               be definitely initialized/readable at this program point
               and be typed as an allowed integer index type; the runtime
               value is bounds-checked by the VM at execution, never
               compared against the container length here. *)
            (if li < 0 || li >= Array.length fn.locals then
               add_err ctx
                 (Printf.sprintf
                    "%s: dynamic index local _%d does not exist (the function has %d locals)"
                    bb_ctx li (Array.length fn.locals))
             else begin
               if not (IntSet.mem li running) then
                 add_err ctx
                   (Printf.sprintf
                      "%s: dynamic index local _%d is not definitely initialized at this program point"
                      bb_ctx li);
               if not (is_index_local_type ctx fn.locals.(li)) then
                 add_err ctx
                   (Printf.sprintf
                      "%s: dynamic index local _%d has non-integer index type %s" bb_ctx li
                      (Seed_mir.print_type fn.locals.(li)))
             end);
             (match ty with
              | Type_repr.Named (id, [| elem |])
                when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
                  (* the Vec/Array nominal base (the field-less source
                     declaration): the dynamic Index admits it by id
                     BEFORE def resolution (its def must not collapse
                     the base to the empty structural form) *)
                  go elem rest
              | _ -> (
                  match resolve_or_self ctx ty with
                  | Type_repr.Fixed_array (elem, _) -> go elem rest
                  | Type_repr.String -> go Type_repr.Char rest
                  | _ ->
                      add_err ctx
                        (Printf.sprintf "%s: index projection on non-array type %s" bb_ctx
                           (Seed_mir.print_type ty))))
        | Downcast vid -> (
            (* the native owner-identity invariant for variants: the
               projected VariantId must belong to the projected base's
               OWN enum def; the runtime tag (vd_index) is derived from
               the                 def's metadata. *)
            match ty with
            | Type_repr.Named (tid, args) -> (
                match find_def ctx tid with
                | Some (Seed_mir.EnumDef { ed_variants; _ }) -> (
                    match
                      List.find_opt
                        (fun v -> Ids.Variant_id.compare v.Seed_mir.vd_id vid = 0)
                        ed_variants
                    with
                    | Some v -> go (subst_registry_type ctx tid args v.Seed_mir.vd_payload) rest
                    | None ->
                        add_err ctx
                          (Printf.sprintf
                             "%s: variant identity owner mismatch: VariantId %d does not belong to the projected base type#%d's enum def"
                             bb_ctx (Ids.Variant_id.to_int vid) (Ids.Type_id.to_int tid)))
                | Some (Seed_mir.StructDef _) ->
                    add_err ctx
                      (Printf.sprintf "%s: variant projection on a struct value" bb_ctx)
                | None ->
                    add_err ctx
                      (Printf.sprintf
                         "%s: variant projection on a type with no def in the types table" bb_ctx))
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: variant projection on non-enum type %s" bb_ctx
                     (Seed_mir.print_type ty))))
  in
  (* the explicit root (re-audit item 20): the projection-owner walk
     bases on the LOCAL's type or the STATIC's declared type — the
     negative-root indexing crash is gone *)
  let base_ty =
    match p.root with
    | Seed_mir.Local lid when lid >= 0 && lid < Array.length fn.locals ->
        Some fn.locals.(lid)
    | Seed_mir.Static idx when idx >= 0 && idx < Array.length ctx.prog.Seed_mir.statics ->
        let (_, ty, _, _) = ctx.prog.Seed_mir.statics.(idx) in
        Some ty
    | _ -> None
  in
  (match base_ty with Some ty -> go ty p.projections | None -> ())

let check_place_readable (ctx : ctx) (fn : function_) (bb_ctx : string)
    (p : place) (running : IntSet.t) : unit =
  if root_key p.root < 0 then begin
    (* the global root: no initialization tracking in the running set *)
    check_projection_owners ctx fn bb_ctx running p;
    if p.projections <> [] && place_type ctx fn p = None then
      add_err ctx (Printf.sprintf "%s: invalid projection chain on static slot _%d" bb_ctx (Seed_mir.root_static_index p.root))
  end
  else if (root_key p.root) >= Array.length fn.locals then
    add_err ctx (Printf.sprintf "%s: place references undefined local _%d" bb_ctx (root_key p.root))
  else begin
    if not (IntSet.mem (root_key p.root) running) then
      add_err ctx (Printf.sprintf "%s: use of possibly-uninitialized local _%d" bb_ctx (root_key p.root));
    check_projection_owners ctx fn bb_ctx running p;
    if p.projections <> [] && place_type ctx fn p = None then
      add_err ctx (Printf.sprintf "%s: invalid projection chain on local _%d" bb_ctx (root_key p.root))
  end

let check_dest_place (ctx : ctx) (fn : function_) (bb_ctx : string) (p : place)
    (running : IntSet.t) : unit =
  if root_key p.root < 0 then begin
    (* the global root: no initialization tracking in the running set *)
    check_projection_owners ctx fn bb_ctx running p
  end
  else if (root_key p.root) >= Array.length fn.locals then
    add_err ctx (Printf.sprintf "%s: assignment to undefined local _%d" bb_ctx (root_key p.root))
  else begin
    check_projection_owners ctx fn bb_ctx running p;
    if p.projections <> [] then begin
      if not (IntSet.mem (root_key p.root) running) then
        add_err ctx
          (Printf.sprintf "%s: assign into field of possibly-uninitialized local _%d" bb_ctx
             (root_key p.root));
      if place_type ctx fn p = None then
        add_err ctx (Printf.sprintf "%s: invalid projection chain on local _%d" bb_ctx (root_key p.root))
    end
  end

(* Ref-ABI whitelist: a bare ref-typed local must not be used as a value
   outside a direct call argument, and refs are never moved; reads
   through projections are plain value reads. *)
let check_ref_operand (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    ~(as_call_arg : bool) : unit =
  let check p =
    if p.projections = [] && not (root_is_static p.root)
       && (root_key p.root) >= 0 && (root_key p.root) < Array.length fn.locals
    then match fn.locals.(root_key p.root) with
      | Type_repr.Ref_internal (_, _) when not as_call_arg ->
          add_err ctx
            (Printf.sprintf
               "%s: ref-typed value used outside a direct call argument (refs are internal ABI temporaries)"
               bb_ctx)
      | _ -> ()
  in
  match op with
  | Copy p | Read p ->
      check p
  | Move p | Consume p ->
      (* the projected-move rejection lives in
         check_projected_move_transfer (a projected move is never a
         legal transfer regardless of the root type); this ref rule
         covers the bare form only *)
      (if p.projections = [] && not (root_is_static p.root)
          && (root_key p.root) >= 0 && (root_key p.root) < Array.length fn.locals
        then match fn.locals.(root_key p.root) with
         | Type_repr.Ref_internal (_, _) ->
             add_err ctx
               (Printf.sprintf "%s: ref-typed local _%d moved (refs are internal ABI temporaries)"
                  bb_ctx (root_key p.root))
         | _ -> ());
  | Constant _ -> ()

(* ── Projected Move/Consume (the partial-move representation) ────────
   re-audit P12: the seed VM now EXECUTES projected moves — a
   Move/Consume of `root.field` reads the projected component and
   writes the Moved hole marker INTO the component (the root slot
   stays Live with the hole; the drop glue skips Moved components).
   The verifier's moved lattice is projection-aware (place keys track
   sub-place ownership), so the dataflow and the executor agree: the
   moved path is consumed, the un-moved remainder of the root stays
   readable, and a second consume of the same path is a use-after-move.
   The categorical rejection is retired. *)
let check_projected_move_transfer (ctx : ctx) (bb_ctx : string) (op : operand) : unit =
  ignore ctx;
  ignore bb_ctx;
  match op with
  | Move p | Consume p -> ignore p
  | Copy _ | Read _ | Constant _ -> ()

(* Callee-resolution result (see resolve_callee below). *)
type callee_resolution =
  | Callee_ok of function_ * (Type_repr.t -> Type_repr.t)
  | Callee_unknown
  | Callee_arity_mismatch of string

let rec check_operand (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    (running : IntSet.t) (moved : StrSet.t IntMap.t) ~(as_call_arg : bool)
    ~(init_place : bool) ~(as_place_arg : bool) : Type_repr.t option =
  match op with
  | Copy p ->
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      if not init_place then check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: copy of previously moved place _%d (key %S)" bb_ctx (root_key p.root) k);
      (match place_type ctx fn p with
       | Some ty ->
           (* the by-place arg rule: a MODIFY/Initialize call argument
              passes its PLACE (the callee reads/writes through the
              address) — the operand's Copy form is the place channel,
              never a bitwise value copy, so the no-copy-of-non-Copy
              rule does not apply to it (`drop` glue calling the
              owning handle's inout method with `modify: _1`) *)
           if not (as_place_arg || is_copy ctx ty) then
             add_err ctx
               (Printf.sprintf
                  "%s: copy of non-Copy value of type %s (a bitwise copy of an owning type must be moved, consumed or passed by place)"
                  bb_ctx (Seed_mir.print_type ty));
           Some ty
       | None -> None)
  | Read p ->
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: read of previously consumed local _%d (key %S)" bb_ctx (root_key p.root) k);
      place_type ctx fn p
  | Move p ->
      check_projected_move_transfer ctx bb_ctx op;
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: use-after-move (second consume) of local _%d (key %S)" bb_ctx
             (root_key p.root) k);
      place_type ctx fn p
  | Consume p ->
      check_projected_move_transfer ctx bb_ctx op;
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: consume of previously consumed local _%d (key %S)" bb_ctx
             (root_key p.root) k);
      place_type ctx fn p
  | Constant c -> Some (constant_type ctx c)

and constant_type (ctx : ctx) (c : constant) : Type_repr.t =
  match c with
  | Unit -> Type_repr.Unit
  | Bool _ -> Type_repr.Bool
  | Integer v -> int_kind_of v
  | Float32 _ -> Type_repr.Float Type_repr.F32
  | Float64 _ -> Type_repr.Float Type_repr.F64
  | Char _ -> Type_repr.Char
  | String _ -> Type_repr.String
  | Function inst -> function_constant_type ctx inst
  (* the ctor constants carry the declared INSTANTIATED monotype (the
     driver records it from the typed const registry — the instantiation
     is not recoverable from the def table alone), so the static's
     declared type compares exactly *)
  | Enum (_, ty) | Struct ty | Array ty | Map ty | Set ty -> ty

and function_constant_type (ctx : ctx) (inst : Instance_id.t) : Type_repr.t =
  match resolve_callee ctx inst with
  | Callee_ok (f, subst) ->
      (* template mode: the constant's instance carries the EMBEDDING
         function's params, so the callee's signature is read under the
         substitution (its own declaration binders -> the constant's
         type args) — the same contract mono applies *)
      let ret = if Array.length f.locals > 0 then f.locals.(0) else Type_repr.Unit in
      Type_repr.Function
        ( Array.map
            (fun (p : Type_repr.param_type) -> { p with pt_type = subst p.pt_type })
            f.params,
          subst ret )
  | Callee_unknown | Callee_arity_mismatch _ -> Type_repr.Unit

and find_function_by_instance (ctx : ctx) (inst : Instance_id.t) : function_ option =
  let found = ref None in
  Array.iter (fun f -> if f.instance = inst then found := Some f) ctx.prog.functions;
  !found

(* ── Callee resolution by mode ─────────────────────────────────────
   Concrete mode resolves a User callee by EXACT instance identity (the
   program holds the specialized functions).  Template mode cannot: a
   call's instance carries the CALLER's rigid params (the checker
   instantiates the callee's declaration in the caller's context), never
   the callee template's own declaration binders, so the call instance
   can never equal the template's instance.  The callee is resolved by
   CALLABLE identity and the call's type args are substituted into the
   callee's declaration binders — the exact specialization contract mono
   applies (declaration-order positional KParam substitution).  A
   type-argument arity disagreement fails closed. *)

(* The registered body-less callee fallback (shared by both modes): a
   call whose callable is registered in the checker's tables with a
   typed signature but which NO source module lowers (the type-query
   special forms size_of/align_of, extern-declared names, the
   compiler-builtin method/constructor sigs, the derived clone/to_string
   sigs).  The call's type args substitute the signature's declaration
   binders and the fake callee carries the signature's declared params
   and return slot; the exact-arity contract applies (the call's type
   arguments must number exactly the declaration binders).  Template
   verification never executes the fake; the mono output keeps these
   calls as concrete User callees (Mono.build's ~registered_only
   surface), so the post-mono concrete verification resolves them here
   too. *)
and resolve_registered_fallback (ctx : ctx) (inst : Instance_id.t) : callee_resolution =
  match
    List.find_opt
      (fun q -> Ids.Callable_id.compare q.qs_callable (Instance_id.callable inst) = 0)
      ctx.query_sigs
  with
  | None -> Callee_unknown
  | Some q -> (
      let decl = q.qs_decl in
      let args = Instance_id.type_args inst in
      let decl_params =
        Array.to_list decl
        |> List.map (function
             | Type_repr.Type_param p -> Some p
             | _ -> None)
      in
      if
        List.exists Option.is_none decl_params
        || List.length decl_params <> Array.length args
      then
        Callee_arity_mismatch
          (Printf.sprintf
             "callee %s is a registered body-less signature declaring %d generic parameter(s) but the call carries %d type argument(s)"
             (Seed_mir.print_instance inst) (Array.length decl) (Array.length args))
      else
        let subst =
          List.combine
            (List.map
               (fun p -> Type_repr.KParam (Option.get p))
               decl_params)
            (Array.to_list args)
        in
        let fake : function_ =
          {
            Seed_mir.name = "<body-less registered callee>";
            instance = inst;
            params = q.qs_params;
            locals = [| q.qs_ret |];
            blocks = [||];
            entry = 0;
          }
        in
        (* Concrete_mode: the materializer rewrote the program's generic
           instances to fresh TypeIds, so the substituted signature
           types pass through the same rewrite before any comparison *)
        Callee_ok (fake, fun ty -> ctx.post_rewrite (Type_repr.substitute subst ty)))

and resolve_callee (ctx : ctx) (inst : Instance_id.t) : callee_resolution =
  match ctx.mode with
  | Concrete_mode -> (
      match find_function_by_instance ctx inst with
      | Some f -> Callee_ok (f, fun ty -> ty)
      | None ->
          (* the mono output legitimately keeps calls to the registered
             body-less surface (extern-declared names, compiler-builtin
             methods/constructors, derived clone/to_string sigs, the
             size_of/align_of type queries): no lowered function can
             exist for them, so they resolve against the same registry
             the template verifier uses *)
          resolve_registered_fallback ctx inst)
  | Template_mode -> (
      (* EXACT-instance first: when a lowered function carries the call's
         exact instance identity (a NON-generic callee — its template
         instance declares zero type args — is always lowered under its
         own instance, so a zero-arg call matches it exactly), it is the
         callee — never a same-callable generic sibling.  The resolver's
         CallableId domain is shared by every method registered for a
         type (the kernel's impl-registry can hand one id to two
         (owner, method) sigs — e.g. the source `impl str to_string` and
         the generic `impl[T] Array to_string` both adopt the id of the
         kernel's universal to_string), so a by-callable search alone
         can pick the WRONG template and fail the arity check against
         the call's own type args. *)
      (match find_function_by_instance ctx inst with
       | Some f -> Callee_ok (f, fun ty -> ty)
       | None -> (
      match
        Array.to_list ctx.prog.functions
        |> List.find_opt (fun f ->
               Ids.Callable_id.compare (Instance_id.callable f.instance)
                 (Instance_id.callable inst)
               = 0)
      with
      | None -> resolve_registered_fallback ctx inst
      | Some cf ->
          let decl = Instance_id.type_args cf.instance in
          let args = Instance_id.type_args inst in
          let decl_params =
            Array.to_list decl
            |> List.map (function
                 | Type_repr.Type_param p -> Some p
                 | _ -> None)
          in
          if
            List.exists Option.is_none decl_params
            || List.length decl_params <> Array.length args
          then
            Callee_arity_mismatch
              (Printf.sprintf
                 "callee %s declares %d generic parameter(s) but the call carries %d type argument(s)"
                 cf.name (Array.length decl) (Array.length args))
          else
            let subst =
              List.combine
                (List.map
                   (fun p -> Type_repr.KParam (Option.get p))
                   decl_params)
                (Array.to_list args)
            in
            Callee_ok (cf, fun ty -> Type_repr.substitute subst ty))))

(* ──────────────────────────────────────────────────────────────────
   Rvalue checking — returns the rvalue's type (None when already
   reported).  Aggregate kinds need the destination type as context. *)

let is_int_like (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Int _ | Type_repr.Int_literal _ -> true
  | _ -> false

let is_float_like (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Float _ -> true
  | _ -> false

let is_char_like (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Char -> true
  | _ -> false

let is_scalar (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Int _ | Type_repr.Int_literal _ | Type_repr.Float _
  | Type_repr.Bool | Type_repr.Char | Type_repr.Raw_ptr _ ->
      true
  | _ -> false

let check_int64_in_int_kind (k : Type_repr.int_kind) (v : int64) : bool =
  match k with
  | Type_repr.I8 -> v >= -128L && v <= 127L
  | Type_repr.I16 -> v >= -32768L && v <= 32767L
  | Type_repr.I32 -> v >= Int64.of_string "-2147483648" && v <= Int64.of_string "2147483647"
  | Type_repr.I64 | Type_repr.Int | Type_repr.I128 -> true
  | Type_repr.U8 -> v >= 0L && v <= 255L
  | Type_repr.U16 -> v >= 0L && v <= 65535L
  | Type_repr.U32 -> v >= 0L && v <= Int64.of_string "4294967295"
  | Type_repr.U64 | Type_repr.UInt | Type_repr.U128 -> v >= 0L

(* ──────────────────────────────────────────────────────────────────
   Type-parameter discipline by mode.

   Concrete mode: zero Type_param/Infer_var/Error at every walked type
   position.  Template mode: a function's DECLARED rigid params (the
   Type_params of its own instance — the declaration binders) are
   permitted anywhere a template legitimately carries them; every OTHER
   Type_param — a binder the function never declared — is an error ("the
   template must not reference undeclared params"), and Infer_var/Error
   are rejected exactly like concrete mode.  In template mode every
   Named mention must resolve to a def (the types table or the generic
   nominal registry) — unknown TypeIds fail closed — and a registry
   template mention must carry exactly its declared arity. *)

(* The declared rigid params of a template function: the Type_params of
   its own instance (mir_lower mints template instances from the
   signature's declaration binders). *)
let declared_params (fn : function_) : IntSet.t =
  Array.fold_left
    (fun acc ty ->
      match ty with
      | Type_repr.Type_param pid -> IntSet.add (Ids.Generic_param_id.to_int pid) acc
      | _ -> acc)
    IntSet.empty (Instance_id.type_args fn.instance)

let check_type_walk (ctx : ctx) (where : string) (what : string) (declared : IntSet.t)
    (ty : Type_repr.t) : unit =
  let rec go ty =
    match ty with
    | Type_repr.Type_param pid -> (
        match ctx.mode with
        | Concrete_mode ->
            add_err ctx
              (Printf.sprintf "%s: %s carries an unresolved type parameter (T%d)" where what
                 (Ids.Generic_param_id.to_int pid))
        | Template_mode ->
            if not (IntSet.mem (Ids.Generic_param_id.to_int pid) declared) then
              add_err ctx
                (Printf.sprintf "%s: %s references generic parameter T%d that is not declared in this scope"
                   where what (Ids.Generic_param_id.to_int pid)))
    | Type_repr.Infer_var v ->
        add_err ctx
          (Printf.sprintf "%s: %s carries an unresolved inference variable #%d" where what v)
    | Type_repr.Error ->
        add_err ctx (Printf.sprintf "%s: %s carries the Error recovery type" where what)
    | Type_repr.Named (tid, elems) -> (
        match ctx.mode with
        | Template_mode ->
            if not (Option.is_some (find_def ctx tid)) then
              add_err ctx
                (Printf.sprintf
                   "%s: %s references unknown TypeId type#%d (no def in the types table or the generic nominal registry)"
                   where what (Ids.Type_id.to_int tid));
            (match Mono.find_generic ctx.generic_types tid with
             | Some gd ->
                 if Array.length elems <> Array.length gd.Mono.gd_params then
                   add_err ctx
                     (Printf.sprintf
                        "%s: %s instantiates generic template type#%d with %d argument(s) but it declares %d"
                        where what (Ids.Type_id.to_int tid) (Array.length elems)
                        (Array.length gd.Mono.gd_params))
             | None -> ())
        | Concrete_mode -> ());
        Array.iter go elems
    | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
        go t
    | Type_repr.Tuple elems -> Array.iter go elems
    | Type_repr.Function (params, ret) ->
        Array.iter (fun p -> go p.Type_repr.pt_type) params;
        go ret
    | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
    | Type_repr.String | Type_repr.Int_literal _ | Type_repr.Never ->
        ()
  in
  go ty

let check_aggregate (ctx : ctx) (fn : function_) (bb_ctx : string) (kind : aggregate_kind)
    (ops : operand list) (running : IntSet.t) (moved : StrSet.t IntMap.t) (dest_ty : Type_repr.t) :
    unit =
  let op_types =
    List.map
      (fun op -> check_operand ctx fn bb_ctx op running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false)
      ops
  in
  let check_elem i expected =
    match List.nth_opt op_types i with
    | Some (Some actual) ->
        if not (types_compatible ctx expected actual) then
          add_err ctx
            (Printf.sprintf "%s: aggregate element %d type mismatch: expected %s got %s" bb_ctx i
               (Seed_mir.print_type expected) (Seed_mir.print_type actual))
    | _ -> ()
  in
  let check_count n =
    if List.length ops <> n then
      add_err ctx
        (Printf.sprintf "%s: aggregate count mismatch: expected %d got %d" bb_ctx n
           (List.length ops))
  in
  let rty = resolve_or_self ctx dest_ty in
  match kind with
  | TupleAgg -> (
      match rty with
      | Type_repr.Tuple elems ->
          check_count (Array.length elems);
          Array.iteri (fun i t -> check_elem i t) elems
      | _ ->
          add_err ctx
            (Printf.sprintf "%s: tuple aggregate into non-tuple type %s" bb_ctx
               (Seed_mir.print_type dest_ty)))
  | ArrayAgg -> (
      (* the runtime Vec/Array nominal base (type-id 0) is admitted —
         the checker records an array literal checked against a Vec
         expectation as the Named Vec form and the lowering emits the
         ArrayAgg into the Vec-typed local (the runtime value IS the
         heap Vec — Vm_value.Array — built from an ArrayAgg, exactly
         like the Fixed_array local's Vm_value.Array).  The nominal is
         matched on the UNRESOLVED dest (its field-less def would
         collapse the base to the empty structural form — the same rule
         as the ConstantIndex/dynamic-Index projections). *)
      match dest_ty with
      | Type_repr.Named (id, [| elem |])
        when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
          check_count (List.length ops);
          List.iteri (fun i _ -> check_elem i elem) ops
      | _ -> (
          match rty with
          | Type_repr.Fixed_array (elem, n) ->
              check_count n;
              List.iteri (fun i _ -> check_elem i elem) ops
          | _ ->
              add_err ctx
                (Printf.sprintf "%s: array aggregate into non-array type %s" bb_ctx
                   (Seed_mir.print_type dest_ty))))
  | StructCtor (tid, fields) -> (
      match dest_ty with
      | Type_repr.Named (dtid, _) when dtid = tid -> (
          match rty with
          | Type_repr.Tuple elems ->
              check_count (Array.length elems);
              if Array.length fields <> Array.length elems then
                add_err ctx
                  (Printf.sprintf
                     "%s: struct aggregate field list has %d entries but the def has %d" bb_ctx
                     (Array.length fields) (Array.length elems))
              else Array.iteri (fun i t -> check_elem i t) elems
          | _ ->
              add_err ctx
                (Printf.sprintf "%s: struct aggregate into type#%d whose def is not a struct"
                   bb_ctx (Ids.Type_id.to_int tid)))
      | _ ->
          add_err ctx
            (Printf.sprintf "%s: struct aggregate for type#%d into destination of type %s" bb_ctx
               (Ids.Type_id.to_int tid) (Seed_mir.print_type dest_ty)))
  | EnumCtor (tid, vid) -> (
      match dest_ty with
      | Type_repr.Named (dtid, _) when dtid = tid -> (
          match enum_variant_payload ctx dest_ty vid with
          | None ->
              add_err ctx
                (Printf.sprintf
                   "%s: enum aggregate references invalid variant variant#%d of type#%d" bb_ctx
                   (Ids.Variant_index.to_int vid) (Ids.Type_id.to_int tid))
          | Some payload -> (
              match resolve_or_self ctx payload with
              | Type_repr.Unit -> check_count 0
              | Type_repr.Tuple elems ->
                  check_count (Array.length elems);
                  Array.iteri (fun i t -> check_elem i t) elems
              | _ ->
                  check_count 1;
                  check_elem 0 payload))
      | _ ->
          add_err ctx
            (Printf.sprintf "%s: enum aggregate for type#%d into destination of type %s" bb_ctx
               (Ids.Type_id.to_int tid) (Seed_mir.print_type dest_ty)))
  | ClosureAgg inst -> (
      let code_tail, env_tail =
        match dest_ty with
        | Type_repr.Named _ -> (
            match rty with
            | Type_repr.Tuple elems
              when Array.length elems = 2
                   && (match elems.(0) with
                      | Type_repr.Function _ -> true
                      | _ -> false)
                   && (match resolve_or_self ctx elems.(1) with
                      | Type_repr.Tuple _ -> true
                      | _ -> false) ->
                (Some elems.(0), Some elems.(1))
            | _ -> (None, None))
        | _ -> (None, None)
      in
      match code_tail, env_tail with
      | None, _ ->
          add_err ctx
            (Printf.sprintf "%s: closure aggregate into a def that is not {code, env}" bb_ctx)
      | Some _, None ->
          add_err ctx
            (Printf.sprintf "%s: closure aggregate into a def that is not {code, env}" bb_ctx)
      | Some code_ty, Some env_ty -> (
          let sig_params, sig_ret =
            match code_ty with
            | Type_repr.Function (ps, r) -> (ps, r)
            | _ -> assert false
          in
          let env_tys =
            match resolve_or_self ctx env_ty with
            | Type_repr.Tuple ts -> ts
            | _ -> assert false
          in
          check_count (Array.length env_tys);
          Array.iteri (fun i t -> check_elem i t) env_tys;
          match resolve_callee ctx inst with
          | Callee_unknown | Callee_arity_mismatch _ ->
              add_err ctx
                (Printf.sprintf "%s: closure aggregate references unknown function instance"
                   bb_ctx)
          | Callee_ok (f, subst) ->
              let ret =
                subst (if Array.length f.locals > 0 then f.locals.(0) else Type_repr.Unit)
              in
              if Array.length f.params <> Array.length sig_params then
                add_err ctx
                  (Printf.sprintf
                     "%s: closure aggregate instance parameter count %d does not match the closure signature %d"
                     bb_ctx (Array.length f.params) (Array.length sig_params))
              else
                (* re-audit P0-4: the closure signature comparison is
                   the SHARED signature-identity matcher — arity, each
                   parameter's access convention exact, types
                   alpha-equivalent under ONE binder bijection across
                   the whole signature (params AND return), never a
                   pt_type-only walk.  Both sides live in the same
                   lowered-program domain (the callee side read under
                   the same type-argument substitution the argument
                   checks apply), so no canonicalization is needed. *)
                let callee_sig : Signature_identity.signature =
                  {
                    Signature_identity.sig_params =
                      Array.map
                        (fun (p : Type_repr.param_type) ->
                          { p with Type_repr.pt_type = subst p.Type_repr.pt_type })
                        f.params;
                    sig_ret = ret;
                  }
                in
                let closure_sig : Signature_identity.signature =
                  { Signature_identity.sig_params = sig_params; sig_ret = sig_ret }
                in
                if
                  not
                    (Signature_identity.signatures_match callee_sig closure_sig)
                then
                  match Signature_identity.first_mismatch callee_sig closure_sig with
                  | Some (Signature_identity.Mismatch_param i) ->
                      let render (p : Type_repr.param_type) =
                        Access_effect.to_string p.Type_repr.pt_convention
                        ^ " "
                        ^ Seed_mir.print_type p.Type_repr.pt_type
                      in
                      add_err ctx
                        (Printf.sprintf
                           "%s: closure aggregate instance parameter %d (%s) does not match the closure signature's parameter (%s)"
                           bb_ctx i
                           (render callee_sig.Signature_identity.sig_params.(i))
                           (render closure_sig.Signature_identity.sig_params.(i)))
                  | Some Signature_identity.Mismatch_return ->
                      add_err ctx
                        (Printf.sprintf
                           "%s: closure aggregate instance return type mismatch" bb_ctx)
                  | Some (Signature_identity.Mismatch_arity _) | None -> ()))
let check_rvalue (ctx : ctx) (fn : function_) (bb_ctx : string) (declared : IntSet.t)
    (rv : rvalue) (running : IntSet.t) (moved : StrSet.t IntMap.t) (dest_ty : Type_repr.t) :
    Type_repr.t option =
  match rv with
  | Use op -> check_operand ctx fn bb_ctx op running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false
  | Ref p | RefMut p -> (
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: ref of previously consumed local _%d (key %S)" bb_ctx (root_key p.root) k);
      match place_type ctx fn p with
      | Some t -> Some (Type_repr.Ref_internal (Type_repr.Mutable, t))
      | None -> None)
  | Aggregate (kind, ops) ->
      check_aggregate ctx fn bb_ctx kind ops running moved dest_ty;
      Some dest_ty
  | BinaryOp (op, l, r) -> (
      let lt = check_operand ctx fn bb_ctx l running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false in
      let rt = check_operand ctx fn bb_ctx r running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false in
      match lt, rt with
      | Some lt, Some rt ->
          let same = types_compatible ctx lt rt in
          (* the checker's arithmetic/bitwise acceptance (check_binary):
             ANY integer-kind pair is a legal arithmetic/bitwise operand
             pair (the result carries the left operand's kind — the seed
             VM truncates to the left value's width/signedness), so the
             mixed pairs the checker records (`parse_u64_le`'s
             `value | (buf[i] as u64) << (i * 8)` — a U64 value shifted
             by an Int count) must not fail the MIR operand rule; only
             the non-integer classes require exact matching operands *)
           let int_pair = is_int_like ctx lt && is_int_like ctx rt in
           (* the operand-difference diagnostic applies to the classes
              the checker rejects (Eq/ordering over differing scalars,
              non-integer arithmetic mixes) — a mixed INTEGER-kind pair
              under an arithmetic/bitwise operator is the checker's
              accepted LHS-kind-coercion form (check_binary returns the
              left operand's kind for any integer-kind pair), so it is
              NOT an operand error: only the operator's own class check
              below gates it. *)
           let numeric_int_mix =
             match op with
             | Add | Sub | Mul | Div | Rem | BitAnd | BitOr | BitXor | Shl | Shr ->
                 int_pair
             | And | Or | Eq | Ne | Lt | Le | Gt | Ge -> false
           in
           if not same && not numeric_int_mix then
             add_err ctx
               (Printf.sprintf "%s: binary op operands have different types: %s and %s" bb_ctx
                  (Seed_mir.print_type lt) (Seed_mir.print_type rt));
          (match op with
           | And | Or -> (
               match resolve_or_self ctx lt with
               | Type_repr.Bool -> Some Type_repr.Bool
               | _ ->
                   add_err ctx (Printf.sprintf "%s: logical operator requires Bool operands" bb_ctx);
                   None)
           | BitAnd | BitOr | BitXor | Shl | Shr ->
               if (same || int_pair) && is_int_like ctx lt then Some lt
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: bitwise operator requires matching integer operands" bb_ctx);
                 None
               end
            | Add ->
                (* the String concat rule (the seed's `+` on Strings is
                   the concat operator — the VM's BinaryOp Add executes
                   String ^ String — so Add accepts two matching String
                   operands exactly like the numeric kinds) *)
                if int_pair || (same && (is_float_like ctx lt || lt = Type_repr.String))
                then Some lt
                else begin
                  add_err ctx
                    (Printf.sprintf "%s: arithmetic operator requires matching numeric operands"
                       bb_ctx);
                  None
                end
            | Sub | Mul | Div | Rem ->
                if int_pair || (same && is_float_like ctx lt) then Some lt
                else begin
                  add_err ctx
                    (Printf.sprintf "%s: arithmetic operator requires matching numeric operands"
                       bb_ctx);
                  None
                end
            | Eq | Ne ->
                (* the operands must be matching scalars (or String
                   content) — except in TEMPLATE mode, where equality
                   over the function's OWN declared rigid params is a
                   template-legitimate form (the instantiation-time
                   operand class — mono's concrete re-verification
                   checks the instantiated scalars; the kernel's
                   Copy-bounded container element comparisons
                   (`Array[T]::starts_with`'s `a != b`) lower exactly
                   this shape).  The checker's fundamental equality
                   (check_binary's unify) ALSO accepts whole ENUM /
                   STRUCT / TUPLE operands of one type (`peek(p) ==
                   kind` — the parser's token-kind dispatch compares two
                   TokenKind enum values), and the VM's Eq/Ne execute
                   them structurally (Vm_value.equal — tag + payloads),
                   so the MIR rule admits the same aggregate class. *)
                let param_ok =
                  match lt with
                  | Type_repr.Type_param pid -> (
                      match ctx.mode with
                      | Template_mode ->
                          IntSet.mem (Ids.Generic_param_id.to_int pid)
                            (declared_params fn)
                      | Concrete_mode -> false)
                  | _ -> false
                in
                let aggregate_ok =
                  if is_scalar ctx lt || lt = Type_repr.String || param_ok then true
                  else
                    match resolve_or_self ctx lt with
                    | Type_repr.Tuple _ | Type_repr.Fixed_array _
                    | Type_repr.Function (_, Type_repr.Never) ->
                        true
                    | Type_repr.Named (tid, _) ->
                        (* an unresolvable nominal (no def in the
                           table/registry) is a template legitimately
                           carrying its own def-less shape only when it is
                           a declared enum/struct of the registry in
                           template mode; conservatively admit the
                           builtin Option/Result ids (their defs may be
                           unmaterialized) *)
                        Ids.Type_id.compare tid (Ids.Type_id.make 3) = 0
                        || Ids.Type_id.compare tid (Ids.Type_id.make 4) = 0
                        || Ids.Type_id.compare tid (Ids.Type_id.make 1) = 0
                        || Ids.Type_id.compare tid (Ids.Type_id.make 2) = 0
                    | _ -> false
                in
                if same && aggregate_ok then Some Type_repr.Bool
                else begin
                  add_err ctx
                    (Printf.sprintf
                       "%s: equality operator requires matching scalar operands (%s and %s)"
                       bb_ctx (Seed_mir.print_type lt) (Seed_mir.print_type rt));
                  None
                end
           | Lt | Le | Gt | Ge ->
               (* String joins the ordered set: the kernel's lexicographic
                  String ordering (`elem < sorted[pos]` — canonical_effect
                  _set_render's insertion sort) is accepted by the checker
                  and executed by the VM, exactly like the equality rule's
                  String admission above *)
               if
                 same
                 && (is_int_like ctx lt || is_float_like ctx lt
                    || is_char_like ctx lt || lt = Type_repr.String)
               then Some Type_repr.Bool
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: ordering operator requires matching ordered operands" bb_ctx);
                 None
               end)
      | _ -> None)
  | UnaryOp (op, v) -> (
      match check_operand ctx fn bb_ctx v running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false with
      | Some vt -> (
          match op with
          | Neg ->
              if is_int_like ctx vt || is_float_like ctx vt then Some vt
              else begin
                add_err ctx (Printf.sprintf "%s: Neg requires a numeric operand" bb_ctx);
                None
              end
          | Not -> (
              match resolve_or_self ctx vt with
              | Type_repr.Bool -> Some Type_repr.Bool
              | _ ->
                  add_err ctx (Printf.sprintf "%s: Not requires a Bool operand" bb_ctx);
                  None))
      | None -> None)
  | Discriminant p -> (
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: discriminant of previously consumed local _%d" bb_ctx (root_key p.root));
      match place_type ctx fn p with
      | Some ty -> (
          match enum_def_arity ctx ty with
          | Some _ -> Some (Type_repr.Int Type_repr.UInt)
          | None ->
              add_err ctx
                (Printf.sprintf "%s: discriminant of non-enum value of type %s" bb_ctx
                   (Seed_mir.print_type ty));
              None)
      | None -> None)
  | Len p -> (
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx (Printf.sprintf "%s: len of previously consumed local _%d" bb_ctx (root_key p.root));
      match place_type ctx fn p with
      | Some ty -> (
          (* the Vec/Array nominal base is matched by id BEFORE def
             resolution (its field-less def must not collapse the
             base to the empty structural form) *)
          match ty with
          | Type_repr.Named (id, _)
            when Ids.Type_id.compare id (Ids.Type_id.make 0) = 0 ->
              Some (Type_repr.Int Type_repr.UInt)
          | _ -> (
              match resolve_or_self ctx ty with
              | Type_repr.Fixed_array _ -> Some (Type_repr.Int Type_repr.UInt)
              (* re-audit item 17: the seed's documented Unicode decision —
                 String indices are BYTE indices, consistent with Len's
                 String.length, so Len(String) is the byte count, exactly
                 what the VM computes *)
              | Type_repr.String -> Some (Type_repr.Int Type_repr.UInt)
              | _ ->
                  add_err ctx
                    (Printf.sprintf "%s: len of non-array value of type %s" bb_ctx
                       (Seed_mir.print_type ty));
                  None))
      | None -> None)
  | Cast (op, ty) -> (
      let oty =
        check_operand ctx fn bb_ctx op running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false
      in
      (* re-audit P12: the enum-rebrand cast — the `?` failure path
         moves the WHOLE subject between two instantiations of the SAME
         enum (Result[Int, E] -> Result[String, E]); the operand's type
         must be the same enum family as the target (the runtime
         tag/payload layout is identical, so the value passes through) *)
      let enum_rebrand =
        match oty, ty with
        | Some o, Type_repr.Named (tid_t, _) -> (
            (* the DIRECT comparison first: the operand's place type IS
               the nominal (Result[Vec[u8], E] -> Result[String, E]);
               resolving it to the def (findable for the builtin enums
               through the generic registry) would structurally collapse
               the Named identity and defeat the family check *)
            match o with
            | Type_repr.Named (tid_o, _) -> Ids.Type_id.compare tid_o tid_t = 0
            | _ -> (
                match resolve_or_self ctx o with
                | Type_repr.Named (tid_o, _) -> Ids.Type_id.compare tid_o tid_t = 0
                | _ -> false))
        | _ -> false
      in
      match ctx.mode with
      | Concrete_mode ->
          if Type_repr.has_type_param ty then
            add_err ctx
              (Printf.sprintf "%s: cast target %s carries an unresolved type parameter" bb_ctx
                 (Seed_mir.print_type ty));
          if is_scalar ctx ty || is_ptr_handle ctx ty then Some ty
          else if enum_rebrand then Some ty
          else begin
            add_err ctx
              (Printf.sprintf "%s: cast target %s is not a scalar/pointer type" bb_ctx
                 (Seed_mir.print_type ty));
            None
          end
      | Template_mode ->
          (* template mode: a cast to a DECLARED rigid param is a
             template-legitimate position (its scalar class is an
             instantiation-time fact); every other target must pass the
             scalar/pointer matrix — with the SAME same-enum-family
             rebrand acceptance as concrete mode (the `?` failure path
             moves the whole subject between instantiations of one enum,
             Result[Int, E] -> Result[String, E]; the runtime layout is
             identical, and the target may only reference the
             function's own declared params *)
          (match ty with
           | Type_repr.Type_param pid ->
               if not (IntSet.mem (Ids.Generic_param_id.to_int pid) declared) then
                 add_err ctx
                   (Printf.sprintf
                      "%s: cast target references generic parameter T%d that is not declared by this function's signature"
                      bb_ctx (Ids.Generic_param_id.to_int pid));
               Some ty
            | _ ->
                check_type_walk ctx bb_ctx "cast target" declared ty;
                if is_scalar ctx ty || is_ptr_handle ctx ty then Some ty
                else if enum_rebrand then Some ty
                else begin
                  add_err ctx
                    (Printf.sprintf "%s: cast target %s is not a scalar/pointer type" bb_ctx
                       (Seed_mir.print_type ty));
                  None
                end))

(* ──────────────────────────────────────────────────────────────────
   Terminator checking *)

let check_call (ctx : ctx) (fn : function_) (bb_ctx : string) (dest : place)
    (callee : callee) (args : call_arg array) (running : IntSet.t) (moved : StrSet.t IntMap.t) : unit =
  check_dest_place ctx fn bb_ctx dest running;
  (* the emitted-body callee check — shared by the User class and the
     Derived class (audit P0-5): a Derived callee names the
     compiler-synthesized derived contract under the SAME callable
     identity its real emitted body carries, so both dispatch through
     the instance resolver *)
  let check_user_callee (inst : Instance_id.t) : unit =
    match resolve_callee ctx inst with
    | Callee_unknown ->
        add_err ctx
          (Printf.sprintf "%s: call to unknown function instance %s" bb_ctx
             (Seed_mir.print_instance inst))
    | Callee_arity_mismatch m ->
        add_err ctx (Printf.sprintf "%s: call to instance %s: %s" bb_ctx
                        (Seed_mir.print_instance inst) m)
    | Callee_ok (cf, subst) -> (
        if Array.length args <> Array.length cf.params then
          add_err ctx
            (Printf.sprintf "%s: call argument count mismatch: expected %d got %d" bb_ctx
               (Array.length cf.params) (Array.length args));
        Array.iteri
          (fun i arg ->
            (match arg.effect_ with
             | Access_effect.Read | Access_effect.Consume -> ()
             | Access_effect.Modify | Access_effect.Initialize -> (
                 (* Modify/Initialize are PLACE CHANNELS (the callee's
                    mutation copies back into the caller's storage) —
                    a constant has no storage, so those effects require
                    a place operand.  A Consume argument transfers a
                    VALUE: a constant operand is an immutable value the
                    callee copies in, exactly like the Read form, so
                    Consume-of-a-constant is legal (the io kernel's
                    `vec.resize(len, 0)` fill constants). *)
                 match arg.value with
                 | Constant _ ->
                     add_err ctx
                       (Printf.sprintf
                          "%s: call arg %d has effect %s but is a constant (that effect requires a place operand)"
                          bb_ctx i (Seed_mir.print_effect arg.effect_))
                 | _ -> ()));
            match (if i < Array.length cf.params then Some cf.params.(i) else None) with
             | Some p -> (
                  (* the documented exactness rule: a call argument's
                     access effect must be the read-side of the callee's
                     parameter convention (Let->Read, Inout->Modify,
                     Sink->Consume, Set->Initialize).  The kernel's
                     sanctioned inout-of-a-literal shape (`emit_uleb128
                     (&mut buf, 1)` — the callee's `inout value: u64`
                     receives a literal whose writeback would be
                     meaningless) lowers with the READ effect on the
                     constant operand; the verifier accepts the
                     downgrade exactly there. *)
                  let expected = Access_effect.read_effect p.Type_repr.pt_convention in
                  let inout_const_downgrade =
                    match p.Type_repr.pt_convention, arg.effect_, arg.value with
                    | Access_effect.Inout, Access_effect.Read, Seed_mir.Constant _ -> true
                    | _ -> false
                  in
                  if arg.effect_ <> expected && not inout_const_downgrade then
                    add_err ctx
                      (Printf.sprintf
                         "%s: call arg %d effect %s does not match the callee's %s convention (expected %s)"
                         bb_ctx i (Seed_mir.print_effect arg.effect_)
                         (Access_effect.to_string p.Type_repr.pt_convention)
                         (Seed_mir.print_effect expected));
                   (* template mode: the callee's param type is read under
                      the substitution (its declaration binders <- this
                      call's type args), the same specialization contract
                      mono applies *)
                   let pty = subst p.Type_repr.pt_type in
                   match
                     check_operand ctx fn bb_ctx arg.value running moved ~as_call_arg:true ~init_place:(arg.effect_ = Access_effect.Initialize) ~as_place_arg:(arg.effect_ = Access_effect.Modify || arg.effect_ = Access_effect.Initialize)
                   with
                    | Some aty ->
                        if not
                             (types_compatible ctx pty aty || ptr_addr_ok ctx pty aty
                              || deref_arg_ok ctx pty aty
                              || const_int_arg_fits_ok ctx arg.value pty)
                        then
                          add_err ctx
                            (Printf.sprintf "%s: call arg %d type mismatch: expected %s got %s"
                               bb_ctx i
                               (Seed_mir.print_type pty) (Seed_mir.print_type aty))
                    | None -> ())
                | None -> ())
             args;
          let ret_ty =
            subst (if Array.length cf.locals > 0 then cf.locals.(0) else Type_repr.Unit)
          in
          match place_type ctx fn dest with
          | Some dty ->
              if not (types_compatible ctx dty ret_ty) then
                add_err ctx
                  (Printf.sprintf
                     "%s: call destination type %s does not match callee return type %s" bb_ctx
                     (Seed_mir.print_type dty) (Seed_mir.print_type ret_ty))
          | None -> ())
  in
  match callee with
  | Intrinsic (i, _iargs) -> (
      if i < 0 then
        add_err ctx
          (Printf.sprintf "%s: negative intrinsic callee index %d" bb_ctx i)
      else
        match Intrinsic_registry.by_id Intrinsic_registry.manifest i with
        | None ->
            add_err ctx
              (Printf.sprintf "%s: call to unknown intrinsic id %d (no registry declaration)" bb_ctx i)
        | Some (name, _, sig_) ->
            (* re-audit P0 (intrinsic verification parity): the intrinsic
               call is checked against its declared registry signature —
               arity, argument access effects, a REAL substitution
               accumulated across the arguments and the destination
               (repeated generic placeholders must be consistent), Unit
               exactly, constants by their constant type, and the
               effect/operand-category contract (Consume/Initialize/
               Modify require a place channel). *)
            if Array.length args <> Array.length sig_.Intrinsic_registry.params then
              add_err ctx
                (Printf.sprintf "%s: intrinsic `%s` expects %d argument(s), got %d" bb_ctx name
                   (Array.length sig_.Intrinsic_registry.params) (Array.length args));
            let subst = ref [] in
            (* the declared types live in the registry's own TypeId
               domain; bind maps them to the checker's domain per Named
               node.  Concrete_mode additionally resolves the bindings
               accumulated so far and follows the materializer rewrite
               (the declared mention must land on the same fresh
               instance as the rewritten program side) — a registry id
               numerically collides with a checker id (registry
               Option = 1 = the checker's Map), so the rewrite must run
               INSIDE bind after the domain mapping, never on a
               pre-mapped type.  Template_mode keeps the raw path. *)
            let arg_kind = ref (-1) in
            let chk (t : Type_repr.t) : Type_repr.t =
              (* the registry->checker id translation is applied ONCE:
                 template mode translates per Named node below (raw
                 registry-domain types flow through bind); concrete mode
                 translates whole declared types at bind entry (the
                 domain collision between registry and checker ids makes
                 a second translation corrupt — registry Option = 1 =
                 the checker's Map) *)
              match ctx.mode with
              | Concrete_mode -> t
              | Template_mode -> registry_type_to_checker t
            in
            let raw_arg = ref Type_repr.Unit in
            let rec bind (declared : Type_repr.t) (actual : Type_repr.t) : unit =
              raw_arg := declared;
              let declared =
                match ctx.mode with
                | Concrete_mode ->
                    (* the call sites pre-converted the raw registry sig
                       types to the checker domain ONCE (a second
                       conversion would corrupt the substituted checker
                       values — registry Option = 1 = the checker's
                       Map); here the accumulated bindings resolve and
                       the materializer rewrite lands the declared
                       mention on the same fresh instance as the
                       rewritten program side *)
                    ctx.post_rewrite
                      (Type_repr.substitute (List.rev !subst) declared)
                | Template_mode -> declared
              in
              match declared with
              | Type_repr.Type_param pid -> (
                  match List.assoc_opt (Type_repr.KParam pid) !subst with
                  | Some prev ->
                      if not
                           (types_compatible ctx prev actual
                           || deref_arg_ok ctx prev actual)
                      then
                        add_err ctx
                          (Printf.sprintf
                             "%s: intrinsic `%s` generic parameter is used inconsistently (earlier %s, now %s)"
                             bb_ctx name (Seed_mir.print_type prev)
                             (Seed_mir.print_type actual))
                  | None -> subst := (Type_repr.KParam pid, actual) :: !subst)
              | Type_repr.Named (id1, a1) -> (
                  let id1' =
                    match ctx.mode with
                    | Concrete_mode -> id1
                    | Template_mode -> (
                        if
                          Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.option_) = 0
                        then Ids.Type_id.make 3
                        else if
                          Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.vec) = 0
                        then Ids.Type_id.make 0
                        else if
                          Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.map) = 0
                        then Ids.Type_id.make 1
                        else if
                          Ids.Type_id.compare id1 (Intrinsic_registry.Type_id.set) = 0
                        then Ids.Type_id.make 2
                        else id1)
                  in
                  match actual with
                  | Type_repr.Named (id2, a2)
                    when Ids.Type_id.compare id1' id2 = 0 && Array.length a1 = Array.length a2 ->
                      Array.iter2 (fun d a -> bind d a) a1 a2
                  | Type_repr.Fixed_array (e2, _)
                    when Ids.Type_id.compare id1' (Ids.Type_id.make 0) = 0
                         && Array.length a1 = 1 ->
                      bind a1.(0) e2
                  | _ ->
                      let dbg =
                        if Sys.getenv_opt "TANGERINE_DEBUG_INTRIN" <> None then begin
                          let arg_ts =
                            String.concat ";"
                              (Array.to_list
                                 (Array.map
                                    (fun a ->
                                      Seed_mir.print_type
                                        (match a.Seed_mir.value with
                                         | Copy p | Read p | Move p | Consume p -> (
                                             match place_type ctx fn p with
                                             | Some t -> t
                                             | None -> Type_repr.Unit)
                                         | Constant c -> constant_type ctx c))
                                    args))
                          in
                          Printf.sprintf " [arg=%d rawdecl=%s argtypes=%s dest=%s]"
                            !arg_kind (Seed_mir.print_type !raw_arg) arg_ts
                            (match place_type ctx fn dest with
                             | Some t -> Seed_mir.print_type t
                             | None -> "?")
                        end
                        else ""
                      in
                      add_err ctx
                        (Printf.sprintf
                           "%s: intrinsic `%s` argument type mismatch: expected %s got %s%s"
                           bb_ctx name
                           (Seed_mir.print_type (chk declared))
                           (Seed_mir.print_type actual) dbg))
               | Type_repr.Int _
                 when (match actual with Type_repr.Int _ -> true | _ -> false) ->
                   (* the int-kind adoption rule (the checker's
                      int_kind_adopt call boundary — the kernel passes
                      width-typed values where a plain Int is declared,
                      and the VM's Int_value adapters convert by width):
                      an intrinsic parameter accepts ANY integer kind
                      (__intrinsic_int_to_string receives UInt receivers
                      through the derived to_string surface) *)
                   ()
               | Type_repr.Unit -> (
                  (* a declared Unit parameter is exactly Unit — never a
                     wildcard *)
                  if not (types_compatible ctx Type_repr.Unit actual) then
                    add_err ctx
                      (Printf.sprintf
                         "%s: intrinsic `%s` argument type mismatch: expected Unit got %s" bb_ctx
                         name (Seed_mir.print_type actual)))
              | Type_repr.Fixed_array (e1, n1) -> (
                  match actual with
                  | Type_repr.Fixed_array (e2, n2) when n1 = n2 -> bind e1 e2
                  | _ ->
                      let dbg =
                        if Sys.getenv_opt "TANGERINE_DEBUG_INTRIN" <> None then begin
                          let arg_ts =
                            String.concat ";"
                              (Array.to_list
                                 (Array.map
                                    (fun a ->
                                      Seed_mir.print_type
                                        (match a.Seed_mir.value with
                                         | Copy p | Read p | Move p | Consume p -> (
                                             match place_type ctx fn p with
                                             | Some t -> t
                                             | None -> Type_repr.Unit)
                                         | Constant c -> constant_type ctx c))
                                    args))
                          in
                          Printf.sprintf " [arg=%d rawdecl=%s argtypes=%s dest=%s]"
                            !arg_kind (Seed_mir.print_type !raw_arg) arg_ts
                            (match place_type ctx fn dest with
                             | Some t -> Seed_mir.print_type t
                             | None -> "?")
                        end
                        else ""
                      in
                      add_err ctx
                        (Printf.sprintf
                           "%s: intrinsic `%s` argument type mismatch: expected %s got %s%s"
                           bb_ctx name
                           (Seed_mir.print_type (chk declared))
                           (Seed_mir.print_type actual) dbg))
              | Type_repr.Tuple a1 -> (
                  match actual with
                  | Type_repr.Tuple a2 when Array.length a1 = Array.length a2 ->
                      Array.iter2 (fun d a -> bind d a) a1 a2
                  | _ ->
                      let dbg =
                        if Sys.getenv_opt "TANGERINE_DEBUG_INTRIN" <> None then begin
                          let arg_ts =
                            String.concat ";"
                              (Array.to_list
                                 (Array.map
                                    (fun a ->
                                      Seed_mir.print_type
                                        (match a.Seed_mir.value with
                                         | Copy p | Read p | Move p | Consume p -> (
                                             match place_type ctx fn p with
                                             | Some t -> t
                                             | None -> Type_repr.Unit)
                                         | Constant c -> constant_type ctx c))
                                    args))
                          in
                          Printf.sprintf " [arg=%d rawdecl=%s argtypes=%s dest=%s]"
                            !arg_kind (Seed_mir.print_type !raw_arg) arg_ts
                            (match place_type ctx fn dest with
                             | Some t -> Seed_mir.print_type t
                             | None -> "?")
                        end
                        else ""
                      in
                      add_err ctx
                        (Printf.sprintf
                           "%s: intrinsic `%s` argument type mismatch: expected %s got %s%s"
                           bb_ctx name
                           (Seed_mir.print_type (chk declared))
                           (Seed_mir.print_type actual) dbg))
               | declared' ->
                   if not
                        (types_compatible ctx (chk declared') actual
                        || deref_arg_ok ctx (chk declared') actual)
                   then
                     add_err ctx
                       (Printf.sprintf
                          "%s: intrinsic `%s` argument type mismatch: expected %s got %s" bb_ctx
                          name
                          (Seed_mir.print_type (chk declared'))
                          (Seed_mir.print_type actual))
            in
            Array.iteri
              (fun k a ->
                if k < Array.length sig_.Intrinsic_registry.params then
                  let declared =
                    Access_effect.read_effect
                      sig_.Intrinsic_registry.params.(k).Type_repr.pt_convention
                  in
                  arg_kind := k;
                  if a.Seed_mir.effect_ <> declared then
                    add_err ctx
                      (Printf.sprintf
                         "%s: intrinsic `%s` argument %d carries effect %s but the declaration requires %s"
                         bb_ctx name (k + 1) (Seed_mir.print_effect a.Seed_mir.effect_)
                         (Seed_mir.print_effect declared));
                  (* the effect/operand-category contract: Initialize /
                     Modify arguments must be PLACE channels (a constant
                     cannot be written back).  A Consume of a constant is
                     the VALUE copy (`set.insert(5)` — the sink of a
                     literal) — the constant is immutable, the callee
                     receives the copied value, nothing transfers. *)
                  (match a.Seed_mir.effect_ with
                   | Access_effect.Initialize | Access_effect.Modify -> (
                       match a.Seed_mir.value with
                       | Seed_mir.Constant _ ->
                           add_err ctx
                             (Printf.sprintf
                                "%s: intrinsic `%s` argument %d has effect %s but is a constant (a place channel is required)"
                                bb_ctx name (k + 1)
                                (Seed_mir.print_effect a.Seed_mir.effect_))
                       | _ -> ())
                   | Access_effect.Read | Access_effect.Consume -> ());
                  let declared_ty =
                    sig_.Intrinsic_registry.params.(k).Type_repr.pt_type
                  in
                  let actual_ty =
                    match a.Seed_mir.value with
                    | Seed_mir.Constant c -> Some (constant_type ctx c)
                    | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p
                    | Seed_mir.Consume p -> place_type ctx fn p
                  in
                  (match actual_ty with
                   | Some aty ->
                       bind
                         (match ctx.mode with
                          | Concrete_mode -> registry_type_to_checker declared_ty
                          | Template_mode -> declared_ty)
                         aty
                   | None -> ()))
              args;
            (match place_type ctx fn dest with
             | Some dty ->
                 bind
                   (match ctx.mode with
                    | Concrete_mode ->
                        registry_type_to_checker sig_.Intrinsic_registry.ret
                    | Template_mode -> sig_.Intrinsic_registry.ret)
                   dty
             | None -> ());
            ())
  | Extern (i, _eargs) ->
      (* re-audit P7: the extern call is checked against its declared
         registry signature — arity, argument access effects, the
         argument/destination types (registry-placeholder domain mapped
         to the checker ids), exactly like the Intrinsic path.  The
         seed's extern surface is the manifest closure's extern
         declarations (std/ffi.tg etc.), transcribed into the registry;
         a call to an unregistered index is an invariant break. *)
      if i < 0 then
        add_err ctx
          (Printf.sprintf "%s: negative extern callee index %d" bb_ctx i)
      else begin
        let sig_ =
          Extern_registry.manifest.Extern_registry.by_name
          |> List.find_map (fun (_name, (id, s)) ->
                 if Extern_registry.Id.to_int id = i then Some s else None)
        in
        match sig_ with
        | None ->
            add_err ctx
              (Printf.sprintf "%s: extern callee index %d is not registered in the extern registry" bb_ctx i)
        | Some esig ->
            if Array.length args <> Array.length esig.Intrinsic_registry.params then
              add_err ctx
                (Printf.sprintf "%s: extern call expects %d argument(s), got %d" bb_ctx
                   (Array.length esig.Intrinsic_registry.params) (Array.length args));
            Array.iteri
              (fun k a ->
                if k < Array.length esig.Intrinsic_registry.params then
                  let declared =
                    Access_effect.read_effect
                      esig.Intrinsic_registry.params.(k).Type_repr.pt_convention
                  in
                  if a.Seed_mir.effect_ <> declared then
                    add_err ctx
                      (Printf.sprintf
                         "%s: extern argument %d carries effect %s but the declaration requires %s"
                         bb_ctx (k + 1) (Seed_mir.print_effect a.Seed_mir.effect_)
                         (Seed_mir.print_effect declared));
                  let declared_ty =
                    esig.Intrinsic_registry.params.(k).Type_repr.pt_type
                  in
                  let actual_ty =
                    match a.Seed_mir.value with
                    | Seed_mir.Constant c -> Some (constant_type ctx c)
                    | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p
                    | Seed_mir.Consume p -> place_type ctx fn p
                  in
                  (match actual_ty with
                   | Some aty ->
                       if
                         not
                           (intrinsic_type_compatible ctx declared_ty aty
                           || ptr_addr_ok ctx (registry_type_to_checker declared_ty) aty)
                       then
                         add_err ctx
                           (Printf.sprintf
                              "%s: extern argument %d type mismatch: expected %s got %s" bb_ctx
                              (k + 1)
                              (Seed_mir.print_type (registry_type_to_checker declared_ty))
                              (Seed_mir.print_type aty))
                   | None -> ()))
              args;
            (match place_type ctx fn dest with
             | Some dty ->
                 if not (intrinsic_type_compatible ctx esig.Intrinsic_registry.ret dty) then
                   add_err ctx
                     (Printf.sprintf
                        "%s: extern destination type %s does not match declared result %s"
                        bb_ctx (Seed_mir.print_type dty)
                        (Seed_mir.print_type (registry_type_to_checker esig.Intrinsic_registry.ret)))
             | None -> ())
      end
  | FnValue op -> (
      (* re-audit P12: the closure-VALUE call — the callee operand must
         evaluate to a function value: its type is a fn type, the
         argument count matches the fn type's params, the args' effects
         match the declared conventions (the fn type's params carry
         them), and the destination equals the fn type's return. *)
      match
        check_operand ctx fn bb_ctx op running moved ~as_call_arg:false
          ~init_place:false ~as_place_arg:false
      with
      | None -> ()
      | Some oty -> (
          match resolve_or_self ctx oty with
          | Type_repr.Function (ptys, ret) -> (
              if Array.length args <> Array.length ptys then
                add_err ctx
                  (Printf.sprintf
                     "%s: fn-value call argument count mismatch: expected %d got %d" bb_ctx
                     (Array.length ptys) (Array.length args));
              Array.iteri
                (fun i arg ->
                  (match arg.effect_ with
                   | Access_effect.Read -> ()
                   | Access_effect.Modify | Access_effect.Initialize
                   | Access_effect.Consume -> (
                       match arg.value with
                       | Constant _ ->
                           add_err ctx
                             (Printf.sprintf
                                "%s: fn-value call arg %d has effect %s but is a constant (that effect requires a place operand)"
                                bb_ctx i (Seed_mir.print_effect arg.effect_))
                       | _ -> ()));
                  if i < Array.length ptys then
                    let expected =
                      Access_effect.read_effect ptys.(i).Type_repr.pt_convention
                    in
                    if arg.effect_ <> expected then
                      add_err ctx
                        (Printf.sprintf
                           "%s: fn-value call arg %d effect %s does not match the fn type's %s convention (expected %s)"
                           bb_ctx i (Seed_mir.print_effect arg.effect_)
                           (Access_effect.to_string ptys.(i).Type_repr.pt_convention)
                           (Seed_mir.print_effect expected));
                  match
                    check_operand ctx fn bb_ctx arg.value running moved ~as_call_arg:true
                      ~init_place:(arg.effect_ = Access_effect.Initialize)
                      ~as_place_arg:(arg.effect_ = Access_effect.Modify || arg.effect_ = Access_effect.Initialize)
                  with
                  | Some aty -> (
                      if i < Array.length ptys
                         && not
                              (types_compatible ctx ptys.(i).Type_repr.pt_type aty)
                      then
                        add_err ctx
                          (Printf.sprintf
                             "%s: fn-value call arg %d type mismatch: expected %s got %s"
                             bb_ctx i
                             (Seed_mir.print_type ptys.(i).Type_repr.pt_type)
                             (Seed_mir.print_type aty)))
                  | None -> ())
                args;
              match place_type ctx fn dest with
              | Some dty ->
                  if not (types_compatible ctx dty ret) then
                    add_err ctx
                      (Printf.sprintf
                         "%s: fn-value call destination type %s does not match the fn type's return %s"
                         bb_ctx (Seed_mir.print_type dty)
                         (Seed_mir.print_type ret))
              | None -> ())
          | _ ->
              add_err ctx
                (Printf.sprintf
                   "%s: fn-value call: callee operand has non-function type %s" bb_ctx
                   (Seed_mir.print_type oty))))
  | User inst -> check_user_callee inst
  | Derived (c, cargs) ->
      (* audit P0-5: the compiler-synthesized derived contract class —
         the callee names the derived function under the SAME callable
         identity the emitted body carries, so the emitted-body checks
         (instance resolution, arity, per-argument conventions, the
         destination) apply exactly like a User callee *)
      check_user_callee (Instance_id.make ~callable:c ~type_args:cargs)
  | TypeQuery (k, qargs) ->
      (* audit P0-5: the compile-time type-query class (size_of/
         align_of).  The query has NO runtime parameters: the call must
         carry zero arguments, the destination is the UInt the query
         returns, and the queried type args obey the mode's type-param
         discipline (concrete post-mono — a TypeQuery whose queried
         type is not concrete at the concrete gate is an error). *)
      let what = Printf.sprintf "%s query" (Seed_mir.type_query_name k) in
      let declared = declared_params fn in
      Array.iter
        (fun ty -> check_type_walk ctx bb_ctx what declared ty)
        qargs;
      if Array.length args <> 0 then
        add_err ctx
          (Printf.sprintf "%s: %s takes no runtime arguments (got %d)" bb_ctx what
             (Array.length args));
      (match place_type ctx fn dest with
       | Some dty ->
           if not (types_compatible ctx (Type_repr.Int Type_repr.UInt) dty) then
             add_err ctx
               (Printf.sprintf "%s: %s destination type %s is not UInt" bb_ctx what
                  (Seed_mir.print_type dty))
       | None -> ())

let check_switch (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    (targets : (int64 * int) list) (running : IntSet.t) (moved : StrSet.t IntMap.t) : unit =
  match check_operand ctx fn bb_ctx op running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false with
  | None -> ()
  | Some oty -> (
      let rty = resolve_or_self ctx oty in
      let legal_scalar =
        match rty with
        | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ -> true
        | _ -> false
      in
      let enum_n = if legal_scalar then None else enum_def_arity ctx oty in
      if not legal_scalar && enum_n = None then
        add_err ctx
          (Printf.sprintf "%s: switch discriminant has non-scalar type %s (Int/Bool/Char/enum only)"
             bb_ctx (Seed_mir.print_type oty))
      else begin
        let seen = ref [] in
        List.iter
          (fun (v, _) ->
            if List.mem v !seen then
              add_err ctx
                (Printf.sprintf "%s: switch carries duplicate target value %Ld" bb_ctx v)
            else seen := v :: !seen;
            match rty with
            | Type_repr.Int k ->
                if not (check_int64_in_int_kind k v) then
                  add_err ctx
                    (Printf.sprintf "%s: switch target value %Ld out of range for %s" bb_ctx v
                       (Seed_mir.print_type oty))
            | Type_repr.Bool ->
                if v <> 0L && v <> 1L then
                  add_err ctx
                    (Printf.sprintf "%s: switch target value %Ld out of range for Bool" bb_ctx v)
            | Type_repr.Char ->
                if v < 0L || v > 0x10FFFFL then
                  add_err ctx
                    (Printf.sprintf "%s: switch target value %Ld out of range for Char" bb_ctx v)
            | _ -> (
                match enum_n with
                | Some n ->
                    if v < 0L || v >= Int64.of_int n then
                      add_err ctx
                        (Printf.sprintf
                           "%s: switch target value %Ld is not a declared discriminant of the enum (0..%d)"
                           bb_ctx v (n - 1))
                | None -> ()))
          targets
      end)

let check_terminator (ctx : ctx) (fn : function_) (bb_ctx : string) (t : terminator)
    (running : IntSet.t) (moved : StrSet.t IntMap.t) (destroyed : StrSet.t IntMap.t) : unit =
  let tbl = block_table fn in
  let check_target bid =
    if not (Hashtbl.mem tbl bid) then
      add_err ctx (Printf.sprintf "%s: references invalid block bb%d" bb_ctx bid)
  in
  match t with
  | Goto b -> check_target b
  | Ret -> (
      if Array.length fn.locals > 0 then
        match fn.locals.(0) with
        | Type_repr.Never | Type_repr.Unit -> ()
        | _ ->
            if not (IntSet.mem 0 running) then
              add_err ctx
                (Printf.sprintf
                   "%s: return with the return slot _0 not definitely initialized" bb_ctx))
  | SwitchInt (op, targets, default) ->
      check_target default;
      List.iter (fun (_, b) -> check_target b) targets;
      check_switch ctx fn bb_ctx op targets running moved
  | Call (dest, callee, args, next, unwind) ->
      check_call ctx fn bb_ctx dest callee args running moved;
      check_target next;
      Option.iter check_target unwind
  | Drop (p, next, unwind) | Deinit (p, next, unwind) ->
      check_target next;
      Option.iter check_target unwind;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved (root_key p.root) k then
        add_err ctx
          (Printf.sprintf "%s: drop of previously moved/consumed local _%d (key %S)" bb_ctx
             (root_key p.root) k);
      if destroyed_key_conflict destroyed (root_key p.root) k then
        add_err ctx (Printf.sprintf "%s: duplicate drop of local _%d (key %S)" bb_ctx (root_key p.root) k)
  | Assert (op, _, _, target) -> (
      check_target target;
      match check_operand ctx fn bb_ctx op running moved ~as_call_arg:false ~init_place:false ~as_place_arg:false with
      | Some oty ->
          if not (types_compatible ctx Type_repr.Bool oty) then
            add_err ctx
              (Printf.sprintf "%s: assert condition has non-Bool type %s" bb_ctx
                 (Seed_mir.print_type oty))
      | None -> ())
  | Unreachable | Abort -> ()

(* ──────────────────────────────────────────────────────────────────
   Per-function verification *)

(* Embedded type-position audit: params, locals and every instance
   embedded in the body (function constants, closure aggregates, call
   callees and call-argument constants) are walked under the function's
   declared-param discipline.  Concrete mode: zero Type_param/Infer_var/
   Error.  Template mode: the function's own declared rigid params are
   permitted, undeclared params / Infer_var / Error / unknown TypeIds
   are rejected. *)
let check_embedded_types (ctx : ctx) (fn : function_) : unit =
  let where = Printf.sprintf "fn %s" fn.name in
  let declared = declared_params fn in
  let check_what what ty = check_type_walk ctx where what declared ty in
  Array.iter (fun p -> check_what "param" p.Type_repr.pt_type) fn.params;
  Array.iter (fun ty -> check_what "local" ty) fn.locals;
  let check_operand op =
    match op with
    | Constant (Function inst) ->
        Array.iter (check_what "function-constant instance") (Instance_id.type_args inst)
    | _ -> ()
  in
  let check_rvalue_instances rv =
    match rv with
    | Use op | Cast (op, _) | UnaryOp (_, op) -> check_operand op
    | Aggregate (kind, ops) ->
        List.iter check_operand ops;
        (match kind with
         | ClosureAgg inst ->
             Array.iter (check_what "closure instance") (Instance_id.type_args inst)
         | _ -> ())
    | BinaryOp (_, l, r) ->
        check_operand l;
        check_operand r
    | Ref _ | RefMut _ | Discriminant _ | Len _ -> ()
  in
  Array.iter
    (fun b ->
      List.iter
        (fun st ->
          match st with
          | Assign (_, rv) -> check_rvalue_instances rv
          | _ -> ())
        b.statements;
      (match b.terminator with
       | Call (_, callee, args, _, _) -> (
           (match callee with
            | User inst ->
                Array.iter (check_what "call instance") (Instance_id.type_args inst)
            | Derived (_, cargs) ->
                Array.iter (check_what "derived callee instance") cargs
            | TypeQuery (k, qargs) ->
                Array.iter
                  (check_what
                     (Printf.sprintf "%s query" (Seed_mir.type_query_name k)))
                  qargs
            | Intrinsic (_, iargs) ->
                Array.iter (check_what "intrinsic callee instance") iargs
            | Extern (_, eargs) ->
                Array.iter (check_what "extern callee instance") eargs
            | FnValue op -> check_operand op);
           Array.iter (fun arg -> check_operand arg.value) args)
       | SwitchInt (op, _, _) | Assert (op, _, _, _) -> check_operand op
       | Drop _ | Deinit _ | Goto _ | Ret | Unreachable | Abort -> ()))
    fn.blocks

let verify_function (ctx : ctx) (fn : function_) : unit =
  let fn_ctx = Printf.sprintf "fn %s" fn.name in
  (* the function's own instance is its declaration: in template mode
     every Type_param it carries IS declared (the declared set is
     exactly these binders); concrete mode rejects any residual
     Type_param/Infer_var/Error here like everywhere else *)
  let declared = declared_params fn in
  Array.iter
    (fun ty -> check_type_walk ctx fn_ctx "instance type argument" declared ty)
    (Instance_id.type_args fn.instance);
  if Array.length fn.locals = 0 then
    add_err ctx
      (Printf.sprintf "%s: function has no locals (missing the return slot _0)" fn_ctx)
  else
    (match fn.locals.(0) with
     | Type_repr.Ref_internal (_, _) ->
         add_err ctx
           (Printf.sprintf
              "%s: function returns a ref value (refs are internal ABI and must not escape)"
              fn_ctx)
     | _ -> ());
  (* Local convention (seed_mir.ml): local _0 is the return slot;
     parameter i occupies local _(i+1), so the locals array must be at
     least 1 + |params| long. *)
  if Array.length fn.locals < 1 + Array.length fn.params then
    add_err ctx
      (Printf.sprintf
         "%s: %d parameters require %d locals (return slot _0 plus one slot per parameter), but the function has %d locals"
         fn_ctx (Array.length fn.params) (1 + Array.length fn.params)
         (Array.length fn.locals))
  else
    Array.iteri
      (fun i p ->
        let pty = p.Type_repr.pt_type in
        if not (types_compatible ctx fn.locals.(i + 1) pty) then
          add_err ctx
            (Printf.sprintf
               "%s: param _%d type %s does not match its local slot _%d type %s" fn_ctx i
               (Seed_mir.print_type pty) (i + 1)
               (Seed_mir.print_type fn.locals.(i + 1))))
      fn.params;
  check_embedded_types ctx fn;
  if Array.length fn.blocks = 0 then
    add_err ctx (Printf.sprintf "%s: function has no blocks" fn_ctx)
  else begin
    let tbl = block_table fn in
    if not (Hashtbl.mem tbl fn.entry) then
      add_err ctx (Printf.sprintf "%s: entry block bb%d does not exist" fn_ctx fn.entry);
    let seen_ids = Hashtbl.create 16 in
    Array.iter
      (fun b ->
        if Hashtbl.mem seen_ids b.id then
          add_err ctx
            (Printf.sprintf "%s: duplicate block id bb%d (one identity, two terminators)" fn_ctx
               b.id)
        else Hashtbl.add seen_ids b.id ())
      fn.blocks;
    (* Block convention (seed_mir.ml): the blocks array is indexed by
       block id — ids must be exactly 0..n-1 and the array position
       equals the id.  Enforce it: the array length equals the max id+1
       and every id 0..n-1 is present exactly once. *)
    let nblocks = Array.length fn.blocks in
    Array.iter
      (fun b ->
        if b.id < 0 || b.id >= nblocks then
          add_err ctx
            (Printf.sprintf
               "%s: block id bb%d out of range: the blocks array is indexed by block id, so ids must be exactly 0..%d (array position == id)"
               fn_ctx b.id (nblocks - 1)))
      fn.blocks;
    for i = 0 to nblocks - 1 do
      if not (Hashtbl.mem seen_ids i) then
        add_err ctx
          (Printf.sprintf
             "%s: missing block id bb%d: every id 0..%d must be present exactly once (the blocks array is indexed by block id)"
             fn_ctx i (nblocks - 1))
    done;
    let reachable = reachable_blocks fn tbl in
    let in_sets = init_in_sets fn tbl in
    let moved_sets = moved_in_sets fn tbl in
    let destroyed_sets = destroyed_in_sets ctx fn tbl in
    Array.iter
      (fun b ->
        let bb_ctx = Printf.sprintf "%s bb%d" fn_ctx b.id in
        let block_in =
          if IntSet.mem b.id reachable then
            Option.value (Hashtbl.find_opt in_sets b.id) ~default:IntSet.empty
          else IntSet.of_list (List.init (Array.length fn.locals) (fun i -> i))
        in
        let running = ref block_in in
        let moved =
          ref (Option.value (Hashtbl.find_opt moved_sets b.id) ~default:IntMap.empty)
        in
        let destroyed =
          ref (Option.value (Hashtbl.find_opt destroyed_sets b.id) ~default:IntMap.empty)
        in
        List.iter
          (fun st ->
            match st with
            | Assign (p, rv) ->
                (match rv with
                 | Ref _ | RefMut _ ->
                     if p.projections <> [] then
                       add_err ctx
                         (Printf.sprintf
                            "%s: value stored into aggregate (refs must only be assigned to plain temps)"
                            bb_ctx)
                 | _ -> ());
                (* re-audit item 21: static MUTABILITY reaches MIR
                   verification — an Assign into an immutable static is
                   rejected here, not only at the frontend (defense in
                   depth: the global place's declaration is the table's
                   mutable flag, so the const/static conflation cannot
                   smuggle a write past the verifier) *)
                (if root_key p.root < 0 then
                   let sidx = Seed_mir.root_static_index p.root in
                   if sidx >= 0 && sidx < Array.length ctx.prog.Seed_mir.statics then
                     let (_, _, mutable_, _) = ctx.prog.Seed_mir.statics.(sidx) in
                     if not mutable_ then
                       add_err ctx
                         (Printf.sprintf
                            "%s: assignment to immutable static _%d (the declaration is not `mut`; the verifier rejects the write at the MIR layer)"
                            bb_ctx sidx));
                check_dest_place ctx fn bb_ctx p !running;
                 (match place_type ctx fn p with
                  | Some dst_ty -> (
                      let rv_ty =
                        check_rvalue ctx fn bb_ctx declared rv !running !moved dst_ty
                      in
                      match rv_ty with
                     | Some t ->
                         if not (types_compatible ctx dst_ty t) then
                           add_err ctx
                             (Printf.sprintf "%s: assign type mismatch: %s into %s" bb_ctx
                                (Seed_mir.print_type t) (Seed_mir.print_type dst_ty))
                     | None -> ())
                 | None -> ());
                running := IntSet.add (root_key p.root) !running;
                moved := rvalue_moved_targets !moved rv;
                let akey = place_key p in
                if p.projections <> [] && akey <> "*" && key_moved !moved (root_key p.root) "" then
                  add_err ctx
                    (Printf.sprintf
                       "%s: assign into a field of consumed local _%d (the whole root was moved out)"
                       bb_ctx (root_key p.root));
                moved := key_clear !moved (root_key p.root) akey;
                destroyed := key_clear !destroyed (root_key p.root) akey
            | StorageLive l ->
                if l < 0 || l >= Array.length fn.locals then
                  add_err ctx (Printf.sprintf "%s: StorageLive for undefined local _%d" bb_ctx l)
                else begin
                  running := IntSet.remove l !running;
                  moved := IntMap.remove l !moved;
                  destroyed := IntMap.remove l !destroyed
                end
            | StorageDead l ->
                if l < 0 || l >= Array.length fn.locals then
                  add_err ctx (Printf.sprintf "%s: StorageDead for undefined local _%d" bb_ctx l)
                else begin
                  running := IntSet.remove l !running;
                  moved := IntMap.remove l !moved;
                  destroyed := IntMap.remove l !destroyed
                end
            | SetDiscriminant (p, vid) ->
                check_place_readable ctx fn bb_ctx p !running;
                let k = place_key p in
                if key_moved !moved (root_key p.root) k then
                  add_err ctx
                    (Printf.sprintf "%s: SetDiscriminant of previously consumed local _%d" bb_ctx
                       (root_key p.root));
                (match place_type ctx fn p with
                 | Some ty -> (
                     match enum_variant_payload ctx ty vid with
                     | Some _ -> ()
                     | None ->
                         add_err ctx
                           (Printf.sprintf
                              "%s: SetDiscriminant references invalid variant variant#%d (not a variant of the place's enum type)"
                              bb_ctx (Ids.Variant_index.to_int vid)))
                 | None -> ())
            | Nop -> ())
          b.statements;
        if IntSet.mem b.id reachable then
          (match b.terminator with
           | Unreachable ->
               add_err ctx
                 (Printf.sprintf
                    "%s: reachable block ends in Unreachable (the lowering placeholder was never replaced)"
                    bb_ctx)
           | _ -> ());
        check_terminator ctx fn bb_ctx b.terminator !running !moved !destroyed;
        (match b.terminator with
         | Call (dest, _, args, _, _) ->
             running := IntSet.add (root_key dest.root) !running;
             let dkey = place_key dest in
             moved := key_clear !moved (root_key dest.root) dkey;
             destroyed := key_clear !destroyed (root_key dest.root) dkey;
             (* re-audit P0 (Set semantics): a successful call proves
                every Set (Initialize) argument's place initialized —
                the callee must have initialized it before returning
                (the VM traps otherwise).  Mark those roots initialized
                on the successful edge. *)
             Array.iter
               (fun a ->
                 if a.Seed_mir.effect_ = Access_effect.Initialize then
                   match a.Seed_mir.value with
                   | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p
                   | Seed_mir.Consume p ->
                       running := IntSet.add (root_key p.root) !running;
                       moved := key_clear !moved (root_key p.root) (place_key p);
                       destroyed := key_clear !destroyed (root_key p.root) (place_key p)
                   | Seed_mir.Constant _ -> ())
               args
          | Drop (p, _, _) | Deinit (p, _, _) ->
              destroyed := key_insert !destroyed (root_key p.root) (place_key p);
              List.iter
                (fun k -> destroyed := key_insert !destroyed (root_key p.root) k)
                (destroyed_keys_of_drop ctx fn p)
          | _ -> ()))
      fn.blocks
  end

(* ──────────────────────────────────────────────────────────────────
   Global checks *)

let verify_types_table (ctx : ctx) : unit =
  let seen = Hashtbl.create 16 in
  Array.iter
    (fun d ->
      let tid = Seed_mir.def_id d in
      if Hashtbl.mem seen tid then
        add_err ctx
          (Printf.sprintf "types table: duplicate TypeId type#%d" (Ids.Type_id.to_int tid))
      else Hashtbl.add seen tid ();
      (* program.types is CONCRETE-only by contract in both modes: the
         generic templates live in the registry (verify_registry) *)
      check_type_walk ctx "types table" (Printf.sprintf "def of type#%d"
                                            (Ids.Type_id.to_int tid))
        IntSet.empty (Seed_mir.def_repr d))
    ctx.prog.types

(* Template-mode audit of the generic nominal-template registry: a
   template def may reference ONLY its own declared binders (gd_params)
   and never Infer_var/Error — the registry is the pre-mono source of
   generic def identities, so a malformed template is a closed gate. *)
let verify_registry (ctx : ctx) : unit =
  Array.iter
    (fun (gd : Mono.generic_def) ->
      let declared =
        Array.fold_left
          (fun acc p -> IntSet.add (Ids.Generic_param_id.to_int p) acc)
          IntSet.empty gd.Mono.gd_params
      in
      let where =
        Printf.sprintf "registry template type#%d" (Ids.Type_id.to_int gd.Mono.gd_tid)
      in
      check_type_walk ctx where "def" declared (Seed_mir.def_repr gd.Mono.gd_def))
    ctx.generic_types

let verify_statics (ctx : ctx) : unit =
  Array.iter
    (fun (name, ty, _, init) ->
      let what = Printf.sprintf "static %s" name in
      (* statics are module-level: nothing is declared, so template mode
         rejects Type_params here exactly like concrete mode *)
      check_type_walk ctx what "type" IntSet.empty ty;
      match init with
      | None -> ()
      | Some c -> (
          (match c with
           | Integer v ->
               if not (int_value_in_range v) then
                 add_err ctx
                   (Printf.sprintf "%s: integer initializer %s out of range for its declared width"
                      what (Seed_mir.print_constant c))
           | Function inst -> (
               match find_function_by_instance ctx inst with
               | Some _ -> ()
               | None ->
                   add_err ctx
                     (Printf.sprintf "%s: function initializer references unknown instance %s"
                        what (Seed_mir.print_instance inst)))
           | _ -> ());
          let cty = constant_type ctx c in
          if not (types_compatible ctx ty cty) then
            add_err ctx
              (Printf.sprintf "%s: initializer type %s does not match the declared type %s" what
                 (Seed_mir.print_type cty) (Seed_mir.print_type ty))))
    ctx.prog.statics

let verify_function_uniqueness (ctx : ctx) : unit =
  let seen = Hashtbl.create 16 in
  Array.iter
    (fun f ->
      if Hashtbl.mem seen f.instance then
        add_err ctx
          (Printf.sprintf
             "program: duplicate function instance %s (two functions share one identity)"
             (Seed_mir.print_instance f.instance))
      else Hashtbl.add seen f.instance ())
    ctx.prog.functions

(* ──────────────────────────────────────────────────────────────────
   Entry points: the template/concrete split (audit P0).

   require_valid_template  — pre-monomorphization: permits each
       function's own declared rigid GenericParamIds wherever a template
       legitimately carries them (instance args, params, locals, cast
       targets, constants, embedded instances) and resolves generic
       nominal identities through the optional registry (the same
       Mono.generic_def array the driver hands to Mono.build; program.types
       is concrete-only at this point).  Still rejects Infer_var, Error,
       unknown TypeId, unknown FieldId/VariantId, wrong owner identity,
       malformed CFG, bad projection, bad call arity and undeclared
       generic parameters.
   require_valid_concrete — post-monomorphization / immediately before
       VM execution: zero Type_param/Infer_var/Error anywhere. *)

let verify_all (ctx : ctx) (prog : program) : (unit, string list) result =
  verify_types_table ctx;
  (match ctx.mode with
   | Template_mode -> verify_registry ctx
   | Concrete_mode -> ());
  verify_statics ctx;
  verify_function_uniqueness ctx;
  Array.iter (verify_function ctx) prog.functions;
  match !(ctx.errors) with
  | [] -> Ok ()
  | errs -> Error (List.rev errs)

let require_valid_template ?(generic_types : Mono.generic_def array = [||])
    ?(query_sigs : query_sig list = []) ?(box_tid : Ids.Type_id.t option = None)
    (prog : program) : (unit, string list) result =
  verify_all
    {
      prog;
      errors = ref [];
      mode = Template_mode;
      generic_types;
      query_sigs;
      box_tid;
      post_rewrite = (fun ty -> ty);
      box_instances = [];
      copy_cache = Type_properties.create_cache ();
      drop_plans = Drop_plan.of_program prog;
    }
    prog

let require_valid_concrete ?(query_sigs : query_sig list = [])
    ?(post_rewrite : Type_repr.t -> Type_repr.t = fun ty -> ty)
    ?(box_instances : Ids.Type_id.t list = [])
    ?(box_tid : Ids.Type_id.t option = None)
    (prog : program) : (unit, string list) result =
  verify_all
    {
      prog;
      errors = ref [];
      mode = Concrete_mode;
      generic_types = [||];
      query_sigs;
      box_tid;
      post_rewrite;
      box_instances;
      copy_cache = Type_properties.create_cache ();
      drop_plans = Drop_plan.of_program prog;
    }
    prog

(* Deprecated strict alias: the pre-existing entry point is the CONCRETE
   (post-mono) verifier — never the template mode.  Callers that want
   pre-mono verification must name require_valid_template explicitly. *)
let require_valid (prog : program) : (unit, string list) result =
  require_valid_concrete prog
