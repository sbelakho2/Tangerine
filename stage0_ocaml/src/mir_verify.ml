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

type mode =
  | Template_mode (* pre-mono: declared rigid Type_params permitted *)
  | Concrete_mode (* post-mono: zero Type_param/Infer_var/Error anywhere *)

type ctx = {
  prog : program;
  errors : string list ref;
  mode : mode;
  generic_types : Mono.generic_def array; (* generic nominal templates; used in Template_mode *)
}

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

(* Copy property authority (re-audit §36): the seed's property engine
   (Type_properties.of_type) with the program's def table as the Named
   resolver.  The engine's rules: scalars/String-owned/immutable refs
   and genuine function pointers behave as before; a def_repr'd enum
   (Function(payloads, Never)) is Copy iff EVERY variant payload is Copy
   — an enum with an owning payload (Result[Int, String]) must be moved,
   consumed or passed by place, never bitwise-copied; a Named type's
   copyability resolves its def and applies the same recursive rule
   (struct Copy iff all fields Copy). *)
let is_copy (ctx : ctx) (ty : Type_repr.t) : bool =
  (Type_properties.of_type ~resolve_def:(fun tid -> find_type ctx tid) ty).is_copy

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
  | Type_repr.Named (ta, aargs), Type_repr.Named (tb, bargs) ->
      ta = tb
      && Array.length aargs = Array.length bargs
      && (let ok = ref true in
          Array.iteri
            (fun i t -> if not (types_compatible ctx aargs.(i) t) then ok := false)
            bargs;
          !ok)
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
  | Type_repr.Int k1, Type_repr.Int k2 -> k1 = k2
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

let enum_def_arity (ctx : ctx) (ty : Type_repr.t) : int option =
  match resolve_or_self ctx ty with
  | Type_repr.Function (variants, Type_repr.Never) -> Some (Array.length variants)
  | _ -> None

(* The type produced by applying one projection; None = illegal.
   Field/Downcast resolve the SEMANTIC id in the projected base's own
   def (the owner-identity rule); ConstantIndex also admits Tuple bases
   — the variant-payload positions are tuples (like the reference's
   TupleIndex, tuples have no FieldId), so payload access is positional. *)
let project_type (ctx : ctx) (ty : Type_repr.t) (proj : projection) : Type_repr.t option =
  match proj with
  | Deref -> (
      match resolve_or_self ctx ty with
      | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> Some t
      | _ -> None)
  | Field fid -> (
      match ty with
      | Type_repr.Named (tid, args) -> struct_field_ty ctx tid args fid
      | _ -> None)
  | ConstantIndex i -> (
      match resolve_or_self ctx ty with
      | Type_repr.Fixed_array (elem, n) when i >= 0 && i < n -> Some elem
      | Type_repr.Tuple elems when i >= 0 && i < Array.length elems -> Some elems.(i)
      | _ -> None)
  | Index li -> (
      (* dynamic-index form: the payload is the LOCAL whose runtime
         integer value is the index.  The runtime value is unknown at
         compile time, so only the base shape constrains the projected
         type; the index local's existence/initialization/type are
         checked in check_projection_owners and the runtime bounds are
         checked by the VM at execution. *)
      ignore li;
      match resolve_or_self ctx ty with
      | Type_repr.Fixed_array (elem, _) -> Some elem
      | _ -> None)
  | Downcast vid -> (
      match ty with
      | Type_repr.Named (tid, args) -> enum_variant_ty ctx tid args vid
      | _ -> None)

let place_type (ctx : ctx) (fn : function_) (p : place) : Type_repr.t option =
  if p.local < 0 || p.local >= Array.length fn.locals then None
  else
    List.fold_left
      (fun acc proj ->
        match acc with
        | None -> None
        | Some ty -> project_type ctx ty proj)
      (Some fn.locals.(p.local)) p.projections

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
        | Assign (p, _) -> out := IntSet.add p.local !out
        | StorageLive _ -> ()
        | StorageDead l -> out := IntSet.remove l !out
        | SetDiscriminant _ | Nop -> ())
      b.statements;
    (match b.terminator with
     | Call (dest, _, _, _, _) -> out := IntSet.add dest.local !out
     | _ -> ());
    !out
  in
  let in_set = Hashtbl.create 16 and out_set = Hashtbl.create 16 in
  (* locals: _0 is the return slot; params occupy _1 .. _n *)
  let entry_init = IntSet.of_list (List.init (Array.length fn.params) (fun i -> i + 1)) in
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
  | Move p | Consume p -> key_insert moved p.local (place_key p)
  | Copy _ | Read _ | Constant _ -> moved

let rvalue_moved_targets (moved : StrSet.t IntMap.t) (rv : rvalue) : StrSet.t IntMap.t =
  match rv with
  | Use op | Cast (op, _) | UnaryOp (_, op) -> operand_moved_targets moved op
  | Aggregate (_, ops) -> List.fold_left operand_moved_targets moved ops
  | BinaryOp (_, l, r) -> operand_moved_targets (operand_moved_targets moved l) r
  | Ref _ | RefMut _ | Discriminant _ | Len _ -> moved

let terminator_moved_targets (moved : StrSet.t IntMap.t) (t : terminator) : StrSet.t IntMap.t =
  match t with
  | Call (_, _, args, _, _) -> Array.fold_left (fun acc a -> operand_moved_targets acc a.value) moved args
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
            out := key_clear !out p.local (place_key p)
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

let destroyed_in_sets (fn : function_) (tbl : (int, block) Hashtbl.t) :
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
        | Assign (p, _) -> out := key_clear !out p.local (place_key p)
        | StorageLive l | StorageDead l -> out := IntMap.remove l !out
        | SetDiscriminant _ | Nop -> ())
      b.statements;
    (match b.terminator with
     | Drop (p, _, _) | Deinit (p, _, _) -> out := key_insert !out p.local (place_key p)
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
            match resolve_or_self ctx ty with
            | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> go t rest
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: deref projection on non-pointer type %s" bb_ctx
                     (Seed_mir.print_type ty)))
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
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: index projection on non-array type %s" bb_ctx
                     (Seed_mir.print_type ty)))
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
            (match resolve_or_self ctx ty with
             | Type_repr.Fixed_array (elem, _) -> go elem rest
             | _ ->
                 add_err ctx
                   (Printf.sprintf "%s: index projection on non-array type %s" bb_ctx
                      (Seed_mir.print_type ty)))
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
  if p.local >= 0 && p.local < Array.length fn.locals then
    go fn.locals.(p.local) p.projections

let check_place_readable (ctx : ctx) (fn : function_) (bb_ctx : string)
    (p : place) (running : IntSet.t) : unit =
  if p.local < 0 || p.local >= Array.length fn.locals then
    add_err ctx (Printf.sprintf "%s: place references undefined local _%d" bb_ctx p.local)
  else begin
    if not (IntSet.mem p.local running) then
      add_err ctx (Printf.sprintf "%s: use of possibly-uninitialized local _%d" bb_ctx p.local);
    check_projection_owners ctx fn bb_ctx running p;
    if p.projections <> [] && place_type ctx fn p = None then
      add_err ctx (Printf.sprintf "%s: invalid projection chain on local _%d" bb_ctx p.local)
  end

let check_dest_place (ctx : ctx) (fn : function_) (bb_ctx : string) (p : place)
    (running : IntSet.t) : unit =
  if p.local < 0 || p.local >= Array.length fn.locals then
    add_err ctx (Printf.sprintf "%s: assignment to undefined local _%d" bb_ctx p.local)
  else begin
    check_projection_owners ctx fn bb_ctx running p;
    if p.projections <> [] then begin
      if not (IntSet.mem p.local running) then
        add_err ctx
          (Printf.sprintf "%s: assign into field of possibly-uninitialized local _%d" bb_ctx
             p.local);
      if place_type ctx fn p = None then
        add_err ctx (Printf.sprintf "%s: invalid projection chain on local _%d" bb_ctx p.local)
    end
  end

(* Ref-ABI whitelist: a bare ref-typed local must not be used as a value
   outside a direct call argument, and refs are never moved; reads
   through projections are plain value reads. *)
let check_ref_operand (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    ~(as_call_arg : bool) : unit =
  let check p =
    if p.projections = [] && p.local >= 0 && p.local < Array.length fn.locals then
      match fn.locals.(p.local) with
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
      (if p.projections = [] && p.local >= 0 && p.local < Array.length fn.locals then
         match fn.locals.(p.local) with
         | Type_repr.Ref_internal (_, _) ->
             add_err ctx
               (Printf.sprintf "%s: ref-typed local _%d moved (refs are internal ABI temporaries)"
                  bb_ctx p.local)
         | _ -> ());
  | Constant _ -> ()

(* ── Categorical projected-Move/Consume rejection (audit P0) ─────────
   The seed VM has NO partial-move representation: `Move p` /
   `Consume p` evaluates `move_slot frame.locals.(p.local)` — the WHOLE
   root slot transitions to Moved, and `p.projections` is ignored.  The
   verifier's moved lattice is projection-aware (place keys track
   sub-place ownership), so a projected move would DISAGREE with the
   executor about the basic meaning of the instruction: the VM would
   move `root.field` by moving the entire root.  Until the VM executes
   projected moves, every projected Move/Consume is rejected here —
   categorically, in both verification modes and at every operand
   position (statements, aggregate operands, call arguments with
   Consume/Initialize effects, SwitchInt/Assert conditions).  The VM
   also traps on the same programs (fail-closed), so no executor can
   ever observe the root-slot semantics the verifier forbids. *)
let check_projected_move_transfer (ctx : ctx) (bb_ctx : string) (op : operand) : unit =
  match op with
  | Move p | Consume p ->
      if p.projections <> [] then
        let kind = match op with Move _ -> "move" | Consume _ -> "consume" | _ -> "transfer" in
        add_err ctx
          (Printf.sprintf
             "%s: projected %s is unsupported by the seed VM (no partial-move representation: a Move/Consume of local _%d through a projection would transition the WHOLE root slot to Moved, disagreeing with the projection-aware moved lattice; rejected until the VM executes projected moves)"
             bb_ctx kind p.local)
  | Copy _ | Read _ | Constant _ -> ()

(* Callee-resolution result (see resolve_callee below). *)
type callee_resolution =
  | Callee_ok of function_ * (Type_repr.t -> Type_repr.t)
  | Callee_unknown
  | Callee_arity_mismatch of string

let rec check_operand (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    (running : IntSet.t) (moved : StrSet.t IntMap.t) ~(as_call_arg : bool) : Type_repr.t option =
  match op with
  | Copy p ->
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: copy of previously moved place _%d (key %S)" bb_ctx p.local k);
      (match place_type ctx fn p with
       | Some ty ->
           if not (is_copy ctx ty) then
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
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: read of previously consumed local _%d (key %S)" bb_ctx p.local k);
      place_type ctx fn p
  | Move p ->
      check_projected_move_transfer ctx bb_ctx op;
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: use-after-move (second consume) of local _%d (key %S)" bb_ctx
             p.local k);
      place_type ctx fn p
  | Consume p ->
      check_projected_move_transfer ctx bb_ctx op;
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: consume of previously consumed local _%d (key %S)" bb_ctx p.local
             k);
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

and resolve_callee (ctx : ctx) (inst : Instance_id.t) : callee_resolution =
  match ctx.mode with
  | Concrete_mode -> (
      match find_function_by_instance ctx inst with
      | Some f -> Callee_ok (f, fun ty -> ty)
      | None -> Callee_unknown)
  | Template_mode -> (
      match
        Array.to_list ctx.prog.functions
        |> List.find_opt (fun f ->
               Ids.Callable_id.compare (Instance_id.callable f.instance)
                 (Instance_id.callable inst)
               = 0)
      with
      | None -> Callee_unknown
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
            Callee_ok (cf, fun ty -> Type_repr.substitute subst ty))

(* ──────────────────────────────────────────────────────────────────
   Rvalue checking — returns the rvalue's type (None when already
   reported).  Aggregate kinds need the destination type as context. *)

let is_int_like (ctx : ctx) (ty : Type_repr.t) : bool =
  match resolve_or_self ctx ty with
  | Type_repr.Int _ -> true
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
  | Type_repr.Int _ | Type_repr.Float _ | Type_repr.Bool | Type_repr.Char
  | Type_repr.Raw_ptr _ ->
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
      (fun op -> check_operand ctx fn bb_ctx op running moved ~as_call_arg:false)
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
      match rty with
      | Type_repr.Fixed_array (elem, n) ->
          check_count n;
          List.iteri (fun i _ -> check_elem i elem) ops
      | _ ->
          add_err ctx
            (Printf.sprintf "%s: array aggregate into non-array type %s" bb_ctx
               (Seed_mir.print_type dest_ty)))
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
                Array.iteri
                  (fun i p ->
                    if
                      not
                        (types_compatible ctx (subst p.Type_repr.pt_type)
                           sig_params.(i).Type_repr.pt_type)
                    then
                      add_err ctx
                        (Printf.sprintf
                           "%s: closure aggregate instance parameter %d type mismatch" bb_ctx i))
                  f.params;
              if not (types_compatible ctx ret sig_ret) then
                add_err ctx
                  (Printf.sprintf "%s: closure aggregate instance return type mismatch" bb_ctx)))
let check_rvalue (ctx : ctx) (fn : function_) (bb_ctx : string) (declared : IntSet.t)
    (rv : rvalue) (running : IntSet.t) (moved : StrSet.t IntMap.t) (dest_ty : Type_repr.t) :
    Type_repr.t option =
  match rv with
  | Use op -> check_operand ctx fn bb_ctx op running moved ~as_call_arg:false
  | Ref p | RefMut p -> (
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: ref of previously consumed local _%d (key %S)" bb_ctx p.local k);
      match place_type ctx fn p with
      | Some t -> Some (Type_repr.Ref_internal (Type_repr.Mutable, t))
      | None -> None)
  | Aggregate (kind, ops) ->
      check_aggregate ctx fn bb_ctx kind ops running moved dest_ty;
      Some dest_ty
  | BinaryOp (op, l, r) -> (
      let lt = check_operand ctx fn bb_ctx l running moved ~as_call_arg:false in
      let rt = check_operand ctx fn bb_ctx r running moved ~as_call_arg:false in
      match lt, rt with
      | Some lt, Some rt ->
          let same = types_compatible ctx lt rt in
          if not same then
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
               if same && is_int_like ctx lt then Some lt
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: bitwise operator requires matching integer operands" bb_ctx);
                 None
               end
           | Add | Sub | Mul | Div | Rem ->
               if same && (is_int_like ctx lt || is_float_like ctx lt) then Some lt
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: arithmetic operator requires matching numeric operands"
                      bb_ctx);
                 None
               end
           | Eq | Ne ->
               if same && is_scalar ctx lt then Some Type_repr.Bool
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: equality operator requires matching scalar operands" bb_ctx);
                 None
               end
           | Lt | Le | Gt | Ge ->
               if same && (is_int_like ctx lt || is_float_like ctx lt || is_char_like ctx lt)
               then Some Type_repr.Bool
               else begin
                 add_err ctx
                   (Printf.sprintf "%s: ordering operator requires matching ordered operands" bb_ctx);
                 None
               end)
      | _ -> None)
  | UnaryOp (op, v) -> (
      match check_operand ctx fn bb_ctx v running moved ~as_call_arg:false with
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
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: discriminant of previously consumed local _%d" bb_ctx p.local);
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
      if key_moved moved p.local k then
        add_err ctx (Printf.sprintf "%s: len of previously consumed local _%d" bb_ctx p.local);
      match place_type ctx fn p with
      | Some ty -> (
          match resolve_or_self ctx ty with
          | Type_repr.Fixed_array _ -> Some (Type_repr.Int Type_repr.UInt)
          | _ ->
              add_err ctx
                (Printf.sprintf "%s: len of non-array value of type %s" bb_ctx
                   (Seed_mir.print_type ty));
              None)
      | None -> None)
  | Cast (op, ty) -> (
      ignore (check_operand ctx fn bb_ctx op running moved ~as_call_arg:false);
      match ctx.mode with
      | Concrete_mode ->
          if Type_repr.has_type_param ty then
            add_err ctx
              (Printf.sprintf "%s: cast target %s carries an unresolved type parameter" bb_ctx
                 (Seed_mir.print_type ty));
          if is_scalar ctx ty then Some ty
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
             scalar/pointer matrix, and the target may only reference
             the function's own declared params *)
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
               if is_scalar ctx ty then Some ty
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
  match callee with
  | Intrinsic i | Extern i ->
      if i < 0 then
        add_err ctx
          (Printf.sprintf "%s: negative intrinsic/extern callee index %d" bb_ctx i)
  | User inst -> (
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
               | Access_effect.Read -> ()
               | Access_effect.Modify | Access_effect.Initialize | Access_effect.Consume -> (
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
                      Sink->Consume, Set->Initialize) *)
                   let expected = Access_effect.read_effect p.Type_repr.pt_convention in
                   if arg.effect_ <> expected then
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
                     check_operand ctx fn bb_ctx arg.value running moved ~as_call_arg:true
                   with
                   | Some aty ->
                       if not (types_compatible ctx pty aty) then
                         add_err ctx
                           (Printf.sprintf "%s: call arg %d type mismatch: expected %s got %s"
                              bb_ctx i (Seed_mir.print_type pty)
                              (Seed_mir.print_type aty))
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
          | None -> ()))

let check_switch (ctx : ctx) (fn : function_) (bb_ctx : string) (op : operand)
    (targets : (int64 * int) list) (running : IntSet.t) (moved : StrSet.t IntMap.t) : unit =
  match check_operand ctx fn bb_ctx op running moved ~as_call_arg:false with
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
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: drop of previously moved/consumed local _%d (key %S)" bb_ctx
             p.local k);
      if destroyed_key_conflict destroyed p.local k then
        add_err ctx (Printf.sprintf "%s: duplicate drop of local _%d (key %S)" bb_ctx p.local k)
  | Assert (op, _, _, target) -> (
      check_target target;
      match check_operand ctx fn bb_ctx op running moved ~as_call_arg:false with
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
            | User inst -> Array.iter (check_what "call instance") (Instance_id.type_args inst)
            | Intrinsic _ | Extern _ -> ());
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
    let destroyed_sets = destroyed_in_sets fn tbl in
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
                running := IntSet.add p.local !running;
                moved := rvalue_moved_targets !moved rv;
                let akey = place_key p in
                if p.projections <> [] && akey <> "*" && key_moved !moved p.local "" then
                  add_err ctx
                    (Printf.sprintf
                       "%s: assign into a field of consumed local _%d (the whole root was moved out)"
                       bb_ctx p.local);
                moved := key_clear !moved p.local akey;
                destroyed := key_clear !destroyed p.local akey
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
                if key_moved !moved p.local k then
                  add_err ctx
                    (Printf.sprintf "%s: SetDiscriminant of previously consumed local _%d" bb_ctx
                       p.local);
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
         | Call (dest, _, _, _, _) ->
             running := IntSet.add dest.local !running;
             let dkey = place_key dest in
             moved := key_clear !moved dest.local dkey;
             destroyed := key_clear !destroyed dest.local dkey
         | Drop (p, _, _) | Deinit (p, _, _) ->
             destroyed := key_insert !destroyed p.local (place_key p)
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
    (fun (name, ty, init) ->
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
    (prog : program) : (unit, string list) result =
  verify_all { prog; errors = ref []; mode = Template_mode; generic_types } prog

let require_valid_concrete (prog : program) : (unit, string list) result =
  verify_all { prog; errors = ref []; mode = Concrete_mode; generic_types = [||] } prog

(* Deprecated strict alias: the pre-existing entry point is the CONCRETE
   (post-mono) verifier — never the template mode.  Callers that want
   pre-mono verification must name require_valid_template explicitly. *)
let require_valid (prog : program) : (unit, string list) result =
  require_valid_concrete prog
