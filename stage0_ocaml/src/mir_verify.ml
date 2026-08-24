(* mir_verify.ml — Seed MIR verifier (audit §36).

   Run post-lowering, post-monomorphization, after every Seed MIR
   transformation and immediately before VM execution.  The verifier is
   total over the CONCRETE (post-mono) representation: any program that
   violates a rule is rejected with the full deterministic list of
   violations; nothing reaches execution on a rejected program.

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
       ref/pointer, Field on the declared owner def (struct/tuple) with
       an in-bounds index, Index/ConstantIndex on a fixed array with an
       in-bounds index, Downcast on the declared owner enum with an
       in-bounds variant index;
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

type ctx = {
  prog : program;
  errors : string list ref;
}

let add_err (ctx : ctx) (msg : string) =
  ctx.errors := msg :: !(ctx.errors)

(* ──────────────────────────────────────────────────────────────────
   Type-definition lookup and resolution *)

let find_type (ctx : ctx) (tid : Ids.Type_id.t) : Type_repr.t option =
  List.assoc_opt tid (Array.to_list ctx.prog.types)

let rec resolve_ty (ctx : ctx) (seen : Ids.Type_id.t list) (ty : Type_repr.t) :
    Type_repr.t option =
  match ty with
  | Type_repr.Named (tid, _) ->
      if List.mem tid seen then None
      else (
        match find_type ctx tid with
        | None -> None
        | Some def -> resolve_ty ctx (tid :: seen) def)
  | _ -> Some ty

let resolve_or_self (ctx : ctx) (ty : Type_repr.t) : Type_repr.t =
  match resolve_ty ctx [] ty with
  | Some t -> t
  | None -> ty

let rec is_copy (ctx : ctx) (seen : Ids.Type_id.t list) (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char
  | Type_repr.Int _ | Type_repr.Float _ | Type_repr.Raw_ptr _
  | Type_repr.Ref_internal _ | Type_repr.Function _ | Type_repr.Never ->
      true
  | Type_repr.String -> false
  | Type_repr.Tuple elems -> Array.for_all (is_copy ctx seen) elems
  | Type_repr.Fixed_array (elem, _) -> is_copy ctx seen elem
  | Type_repr.Named (tid, _) ->
      if List.mem tid seen then false
      else (
        match find_type ctx tid with
        | None -> false
        | Some def -> is_copy ctx (tid :: seen) def)
  | Type_repr.Type_param _ -> false

(* Type compatibility after Named resolution.  Function param
   CONVENTIONS are deliberately ignored: they are a call-site concern
   (checked as access effects), not a value-shape concern. *)
let rec types_compatible (ctx : ctx) (a : Type_repr.t) (b : Type_repr.t) : bool =
  match resolve_or_self ctx a, resolve_or_self ctx b with
  | Type_repr.Named (ta, _), Type_repr.Named (tb, _) -> ta = tb
  | Type_repr.Named _, _ | _, Type_repr.Named _ -> false
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
   and the payload type of one of its variants. *)
let enum_variant_payload (ctx : ctx) (ty : Type_repr.t) (vid : Ids.Variant_id.t) :
    Type_repr.t option =
  match resolve_or_self ctx ty with
  | Type_repr.Function (variants, Type_repr.Never) ->
      let i = Ids.Variant_id.to_int vid in
      if i >= 0 && i < Array.length variants then
        Some variants.(i).Type_repr.pt_type
      else None
  | _ -> None

let enum_def_arity (ctx : ctx) (ty : Type_repr.t) : int option =
  match resolve_or_self ctx ty with
  | Type_repr.Function (variants, Type_repr.Never) -> Some (Array.length variants)
  | _ -> None

(* The type produced by applying one projection; None = illegal. *)
let project_type (ctx : ctx) (ty : Type_repr.t) (proj : projection) : Type_repr.t option =
  match proj with
  | Deref -> (
      match resolve_or_self ctx ty with
      | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> Some t
      | _ -> None)
  | Field fid -> (
      let i = Ids.Field_id.to_int fid in
      match resolve_or_self ctx ty with
      | Type_repr.Tuple elems when i >= 0 && i < Array.length elems -> Some elems.(i)
      | _ -> None)
  | Index i | ConstantIndex i -> (
      match resolve_or_self ctx ty with
      | Type_repr.Fixed_array (elem, n) when i >= 0 && i < n -> Some elem
      | _ -> None)
  | Downcast vid -> enum_variant_payload ctx ty vid

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
   declaration-order index, ConstantIndex contributes "<i>", Downcast
   contributes nothing. *)

let place_key (p : place) : string =
  if p.projections = [] then ""
  else
    let segs = ref [] and boundary = ref false in
    List.iter
      (function
        | Deref | Index _ -> boundary := true
        | Downcast _ -> ()
        | Field fid -> segs := string_of_int (Ids.Field_id.to_int fid) :: !segs
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

let check_projection_owners (ctx : ctx) (fn : function_) (bb_ctx : string) (p : place) : unit =
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
            match resolve_or_self ctx ty with
            | Type_repr.Tuple elems ->
                let i = Ids.Field_id.to_int fid in
                if i < 0 || i >= Array.length elems then
                  add_err ctx
                    (Printf.sprintf
                       "%s: field #%d does not exist in the projected def (arity %d)" bb_ctx i
                       (Array.length elems))
                else go elems.(i) rest
            | Type_repr.Function (_, Type_repr.Never) ->
                add_err ctx (Printf.sprintf "%s: field projection on an enum value" bb_ctx)
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: field projection on non-struct type %s" bb_ctx
                     (Seed_mir.print_type ty)))
        | Index i | ConstantIndex i -> (
            match resolve_or_self ctx ty with
            | Type_repr.Fixed_array (elem, n) ->
                if i < 0 || i >= n then
                  add_err ctx
                    (Printf.sprintf "%s: index %d out of bounds for array of length %d" bb_ctx i n)
                else go elem rest
            | _ ->
                add_err ctx
                  (Printf.sprintf "%s: index projection on non-array type %s" bb_ctx
                     (Seed_mir.print_type ty)))
        | Downcast vid -> (
            match enum_variant_payload ctx ty vid with
            | Some payload -> go payload rest
            | None ->
                add_err ctx
                  (Printf.sprintf
                     "%s: variant projection variant#%d does not match the projected type's enum def"
                     bb_ctx (Ids.Variant_id.to_int vid))))
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
    check_projection_owners ctx fn bb_ctx p;
    if p.projections <> [] && place_type ctx fn p = None then
      add_err ctx (Printf.sprintf "%s: invalid projection chain on local _%d" bb_ctx p.local)
  end

let check_dest_place (ctx : ctx) (fn : function_) (bb_ctx : string) (p : place)
    (running : IntSet.t) : unit =
  if p.local < 0 || p.local >= Array.length fn.locals then
    add_err ctx (Printf.sprintf "%s: assignment to undefined local _%d" bb_ctx p.local)
  else begin
    check_projection_owners ctx fn bb_ctx p;
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
      (match p.projections, p.local with
       | [], _ when p.local >= 0 && p.local < Array.length fn.locals -> (
           match fn.locals.(p.local) with
           | Type_repr.Ref_internal (_, _) ->
               add_err ctx
                 (Printf.sprintf "%s: ref-typed local _%d moved (refs are internal ABI temporaries)"
                    bb_ctx p.local)
           | _ -> ())
       | _ -> ())
  | Constant _ -> ()

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
           if not (is_copy ctx [] ty) then
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
      check_ref_operand ctx fn bb_ctx op ~as_call_arg;
      check_place_readable ctx fn bb_ctx p running;
      let k = place_key p in
      if key_moved moved p.local k then
        add_err ctx
          (Printf.sprintf "%s: use-after-move (second consume) of local _%d (key %S)" bb_ctx
             p.local k);
      place_type ctx fn p
  | Consume p ->
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

and function_constant_type (ctx : ctx) (inst : Ids.Instance_id.t) : Type_repr.t =
  match find_function_by_instance ctx inst with
  | Some f ->
      let ret = if Array.length f.locals > 0 then f.locals.(0) else Type_repr.Unit in
      Type_repr.Function
        ( Array.map
            (fun (_, ty) -> { Type_repr.pt_convention = Access_effect.Let; pt_type = ty })
            f.params,
          ret )
  | None -> Type_repr.Unit

and find_function_by_instance (ctx : ctx) (inst : Ids.Instance_id.t) : function_ option =
  let found = ref None in
  Array.iter (fun f -> if f.instance = inst then found := Some f) ctx.prog.functions;
  !found

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
                   (Ids.Variant_id.to_int vid) (Ids.Type_id.to_int tid))
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
          match find_function_by_instance ctx inst with
          | None ->
              add_err ctx
                (Printf.sprintf "%s: closure aggregate references unknown function instance"
                   bb_ctx)
          | Some f ->
              let ret = if Array.length f.locals > 0 then f.locals.(0) else Type_repr.Unit in
              if Array.length f.params <> Array.length sig_params then
                add_err ctx
                  (Printf.sprintf
                     "%s: closure aggregate instance parameter count %d does not match the closure signature %d"
                     bb_ctx (Array.length f.params) (Array.length sig_params))
              else
                Array.iteri
                  (fun i (_, pt) ->
                    if not (types_compatible ctx pt sig_params.(i).Type_repr.pt_type) then
                      add_err ctx
                        (Printf.sprintf
                           "%s: closure aggregate instance parameter %d type mismatch" bb_ctx i))
                  f.params;
              if not (types_compatible ctx ret sig_ret) then
                add_err ctx
                  (Printf.sprintf "%s: closure aggregate instance return type mismatch" bb_ctx)))
let check_rvalue (ctx : ctx) (fn : function_) (bb_ctx : string) (rv : rvalue)
    (running : IntSet.t) (moved : StrSet.t IntMap.t) (dest_ty : Type_repr.t) : Type_repr.t option =
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
  | Cast (op, ty) ->
      ignore (check_operand ctx fn bb_ctx op running moved ~as_call_arg:false);
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
      match find_function_by_instance ctx inst with
      | None ->
          add_err ctx
            (Printf.sprintf "%s: call to unknown function instance %s" bb_ctx
               (Seed_mir.print_instance inst))
      | Some cf -> (
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
               | Some (_, pty) -> (
                   match
                     check_operand ctx fn bb_ctx arg.value running moved ~as_call_arg:true
                   with
                   | Some aty ->
                       if not (types_compatible ctx pty aty) then
                         add_err ctx
                           (Printf.sprintf "%s: call arg %d type mismatch: expected %s got %s"
                              bb_ctx i (Seed_mir.print_type pty) (Seed_mir.print_type aty))
                   | None -> ())
               | None -> ())
            args;
          let ret_ty =
            if Array.length cf.locals > 0 then cf.locals.(0) else Type_repr.Unit
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

let check_embedded_concreteness (ctx : ctx) (fn : function_) : unit =
  let check_what what ty =
    if Type_repr.has_type_param ty then
      add_err ctx
        (Printf.sprintf "fn %s: %s carries an unresolved type parameter (%s)" fn.name what
           (Seed_mir.print_type ty))
  in
  Array.iter (fun (_, ty) -> check_what "param" ty) fn.params;
  Array.iter (fun ty -> check_what "local" ty) fn.locals;
  let check_operand op =
    match op with
    | Constant (Function inst) ->
        Array.iter (check_what "function-constant instance") inst.type_args
    | _ -> ()
  in
  let check_rvalue_instances rv =
    match rv with
    | Use op | Cast (op, _) | UnaryOp (_, op) -> check_operand op
    | Aggregate (kind, ops) ->
        List.iter check_operand ops;
        (match kind with
         | ClosureAgg inst -> Array.iter (check_what "closure instance") inst.type_args
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
            | User inst -> Array.iter (check_what "call instance") inst.type_args
            | Intrinsic _ | Extern _ -> ());
           Array.iter (fun arg -> check_operand arg.value) args)
       | SwitchInt (op, _, _) | Assert (op, _, _, _) -> check_operand op
       | Drop _ | Deinit _ | Goto _ | Ret | Unreachable | Abort -> ()))
    fn.blocks

let verify_function (ctx : ctx) (fn : function_) : unit =
  let fn_ctx = Printf.sprintf "fn %s" fn.name in
  Array.iter
    (fun ty ->
      if Type_repr.has_type_param ty then
        add_err ctx
          (Printf.sprintf "%s: instance type argument %s carries an unresolved type parameter"
             fn_ctx (Seed_mir.print_type ty)))
    fn.instance.type_args;
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
      (fun i (_, pty) ->
        if not (types_compatible ctx fn.locals.(i + 1) pty) then
          add_err ctx
            (Printf.sprintf
               "%s: param _%d type %s does not match its local slot _%d type %s" fn_ctx i
               (Seed_mir.print_type pty) (i + 1)
               (Seed_mir.print_type fn.locals.(i + 1))))
      fn.params;
  check_embedded_concreteness ctx fn;
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
                     let rv_ty = check_rvalue ctx fn bb_ctx rv !running !moved dst_ty in
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
                              bb_ctx (Ids.Variant_id.to_int vid)))
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
    (fun (tid, ty) ->
      if Hashtbl.mem seen tid then
        add_err ctx
          (Printf.sprintf "types table: duplicate TypeId type#%d" (Ids.Type_id.to_int tid))
      else Hashtbl.add seen tid ();
      if Type_repr.has_type_param ty then
        add_err ctx
          (Printf.sprintf "types table: def of type#%d carries an unresolved type parameter (%s)"
             (Ids.Type_id.to_int tid) (Seed_mir.print_type ty)))
    ctx.prog.types

let verify_statics (ctx : ctx) : unit =
  Array.iter
    (fun (name, ty, init) ->
      let what = Printf.sprintf "static %s" name in
      if Type_repr.has_type_param ty then
        add_err ctx (Printf.sprintf "%s: type carries an unresolved type parameter" what);
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
   Entry point *)

let require_valid (prog : program) : (unit, string list) result =
  let ctx = { prog; errors = ref [] } in
  verify_types_table ctx;
  verify_statics ctx;
  verify_function_uniqueness ctx;
  Array.iter (verify_function ctx) prog.functions;
  match !(ctx.errors) with
  | [] -> Ok ()
  | errs -> Error (List.rev errs)
