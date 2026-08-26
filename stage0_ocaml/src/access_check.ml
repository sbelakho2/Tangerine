(* access_check.ml — The access-conflict matrix (audit §29, §64).

   A place is (root local, projection chain). Conflicts are determined by
   the effect pair and the place relationship; distinct fixed fields are
   disjoint, dynamic indexes stay conservative (overlap).

   The post-resolution access representation is FieldId-based ONLY: the
   kernel resolver assigns FieldIds (Ids.Field_id.make; see ids.ml) and
   Seed MIR projects with `Field of Ids.Field_id.t` (mir_verify.ml), so
   there is no name-keyed projection. *)

type projection =
  | Field of Ids.Field_id.t
  | Index
  | Deref

type access_path = {
  root : int;
  projections : projection list;
}

type conflict = {
  path_a : access_path;
  effect_a : Access_effect.read_effect;
  path_b : access_path;
  effect_b : Access_effect.read_effect;
}

(* The effect pair matrix (audit §64). *)
let effects_conflict (a : Access_effect.read_effect) (b : Access_effect.read_effect) : bool =
  match a, b with
  | Access_effect.Read, Access_effect.Read -> false
  | Access_effect.Read, Access_effect.Modify -> true
  | Access_effect.Read, Access_effect.Consume -> true
  | Access_effect.Read, Access_effect.Initialize -> true
  | Access_effect.Modify, Access_effect.Modify -> true
  | Access_effect.Modify, Access_effect.Consume -> true
  | Access_effect.Modify, Access_effect.Initialize -> true
  | Access_effect.Consume, Access_effect.Consume -> true
  | Access_effect.Consume, Access_effect.Initialize -> true
  | Access_effect.Initialize, Access_effect.Initialize -> true
  | Access_effect.Modify, Access_effect.Read -> true
  | Access_effect.Consume, Access_effect.Read -> true
  | Access_effect.Consume, Access_effect.Modify -> true
  | Access_effect.Initialize, Access_effect.Read -> true
  | Access_effect.Initialize, Access_effect.Modify -> true
  | Access_effect.Initialize, Access_effect.Consume -> true

(* Same root local. *)
let same_root (a : access_path) (b : access_path) = a.root = b.root

(* Disjoint fixed-field prefixes: x.a vs x.b with a <> b — disjoint.
   Any dynamic component (Index/Deref) is conservative (overlap). *)
let rec disjoint_projs (pa : projection list) (pb : projection list) : bool option =
  match pa, pb with
  | [], _ | _, [] -> None (* prefixes — overlap *)
  | Field fa :: ra, Field fb :: rb ->
      if Ids.Field_id.compare fa fb = 0 then disjoint_projs ra rb
      else Some true
  | (Index | Deref) :: _, _ | _, (Index | Deref) :: _ -> None (* conservative *)

let places_conflict (a : access_path) (b : access_path) : bool =
  if not (same_root a b) then false
  else begin
    match disjoint_projs a.projections b.projections with
    | Some true -> false
    | _ -> true
  end

(* Check a set of argument accesses; returns the first conflict.

   Pairwise conflict checking applies ONLY to DISTINCT argument accesses
   (i <> j): a single access never conflicts with itself, so a lone
   Consume (Sink) argument `f(sink x)` is accepted — there is no second
   overlapping access to conflict with. *)
let check_call_args (accesses : (access_path * Access_effect.read_effect) array) :
    (unit, conflict) result =
  let n = Array.length accesses in
  let rec outer i =
    if i >= n then Ok ()
    else begin
      let (pa, ea) = accesses.(i) in
      let rec inner j =
        if j >= n then outer (i + 1)
        else begin
          let (pb, eb) = accesses.(j) in
          if i <> j && places_conflict pa pb && effects_conflict ea eb then
            Error { path_a = pa; effect_a = ea; path_b = pb; effect_b = eb }
          else inner (j + 1)
        end
      in
      inner i
    end
  in
  outer 0

let effects_of_convention (c : Access_effect.t) : Access_effect.read_effect =
  match c with
  | Access_effect.Let -> Access_effect.Read
  | Access_effect.Inout -> Access_effect.Modify
  | Access_effect.Sink -> Access_effect.Consume
  | Access_effect.Set -> Access_effect.Initialize

(* ── The recorded-access channel and the first integrated pass ────────
   (re-audit P0-11).

   The typechecker appends one `access` record per checked call
   argument: the place path when one is derivable (root local +
   projection chain; None otherwise), the callee-side read effect, the
   argument's type, the enclosing item key and the call sequence number.
   The channel ACCUMULATES across the closure (it is not reset per
   item), so the integrated pass can walk the whole recorded closure in
   one shot.

   run_closure consumes that channel and returns a finding list:
     (a) ACCESS: per statement group — one call's argument list — the
         recorded effects are run through the effect-pair conflict
         matrix (check_call_args); two conflicting effects on
         overlapping place paths within one call are findings.
     (b) OWNERSHIP: per item, the recorded operations are replayed on
         Resource_check's per-local state lattice in program order and
         state conflicts (double-move, use-after-consume,
         re-initialization of a live value) are findings.  The lattice
         tracks ONLY genuinely owned (non-Copy) roots — the root's
         copyability comes from its recorded type via
         Resource_check.is_copy (the verifier's rule: scalars and
         references Copy, String owning, a nominal Copy iff every field
         / payload Copy); Copy-typed roots are routed read-only (moving
         them is a copy).  A first Initialize transitions
         Uninitialized -> Live without the re-initialization error (the
         first sight of a `set`-convention write is the initialization
         itself, so the pass cannot manufacture its own conflict).

   HONEST BOUNDARY: the pass walks the RECORDED typed channels — the
   full CFG-based stage (finalize_plan + edge_cleanup consumed by MIR)
   remains future work.  A clean result from this recorded-channel
   replay is NOT Stage 8/9 ownership completeness: the real
   implementation must operate on the same typed CFG/native ownership
   model.  The pass is additive: it reports findings and changes
   nothing in the typechecker's counts. *)

type access = {
  a_item : string;                 (* module::item key of the enclosing function *)
  a_call : int;                    (* per-call sequence number (statement-group key) *)
  a_path : access_path option;     (* None when the argument is not a derivable place *)
  a_effect : Access_effect.read_effect;
  a_span : Span.span;
  a_type : Type_repr.t;            (* the argument's type at the call site *)
}

type finding = {
  f_item : string;
  f_kind : string;                 (* "access-conflict" | "state-conflict" *)
  f_message : string;
}

let effect_to_string (e : Access_effect.read_effect) : string =
  match e with
  | Access_effect.Read -> "read"
  | Access_effect.Modify -> "modify"
  | Access_effect.Consume -> "consume"
  | Access_effect.Initialize -> "initialize"

let path_to_string (p : access_path) : string =
  let buf = Buffer.create 16 in
  Buffer.add_string buf (Printf.sprintf "_%d" p.root);
  List.iter
    (fun proj ->
      match proj with
      | Field fid -> Buffer.add_string buf (Printf.sprintf ".field#%d" (Ids.Field_id.to_int fid))
      | Index -> Buffer.add_string buf "[_]"
      | Deref -> Buffer.add_string buf ".*")
    p.projections;
  Buffer.contents buf

(* The first integrated semantic pass (re-audit P0-11).  Consumes the
   closure's recorded typed access channel (accumulated per call
   argument by the typechecker; each record carries the argument's type)
   and returns the finding list.  `resolve` maps a nominal type id to
   its definition shape so Resource_check.is_copy can decide which
   tracked roots are genuinely owned (see resource_check.ml). *)
let run_closure (resolve : Ids.Type_id.t -> Type_repr.t option) (accesses : access list) :
    finding list =
  (* the channel is recorded by prepending: restore program order *)
  let accesses = List.rev accesses in
  (* one pass: group by statement group (item, call) and by item,
     preserving first-appearance order *)
  let call_buckets : (string * int, access list) Hashtbl.t = Hashtbl.create 256 in
  let call_order : (string * int) list ref = ref [] in
  let item_buckets : (string, access list) Hashtbl.t = Hashtbl.create 64 in
  let item_order : string list ref = ref [] in
  List.iter
    (fun (a : access) ->
      match a.a_path with
      | None -> ()
      | Some _ ->
          let key = (a.a_item, a.a_call) in
          (match Hashtbl.find_opt call_buckets key with
           | Some b -> Hashtbl.replace call_buckets key (a :: b)
           | None ->
               Hashtbl.add call_buckets key [ a ];
               call_order := key :: !call_order);
          (match Hashtbl.find_opt item_buckets a.a_item with
           | Some b -> Hashtbl.replace item_buckets a.a_item (a :: b)
           | None ->
               Hashtbl.add item_buckets a.a_item [ a ];
               item_order := a.a_item :: !item_order))
    accesses;
  (* ── (a) per-call (statement-group) access conflicts ────────────── *)
  let call_findings =
    List.filter_map
      (fun key ->
        let (item, _) = key in
        let bucket = List.rev (Hashtbl.find call_buckets key) in
        let places =
          Array.of_list
            (List.filter_map
               (fun (a : access) ->
                 match a.a_path with Some p -> Some (p, a.a_effect) | None -> None)
               bucket)
        in
        match check_call_args places with
        | Ok () -> None
        | Error c ->
            Some
              {
                f_item = item;
                f_kind = "access-conflict";
                f_message =
                  Printf.sprintf "%s %s conflicts with %s %s (same statement group)"
                    (effect_to_string c.effect_a) (path_to_string c.path_a)
                    (effect_to_string c.effect_b) (path_to_string c.path_b);
              })
      (List.rev !call_order)
  in
  (* ── (b) per-item ownership-state replay (Resource_check lattice) ─ *)
  let item_findings =
    List.concat_map
      (fun item ->
        let accs = List.rev (Hashtbl.find item_buckets item) in
        (* roots in first-seen order, carrying the first-seen type.  The
           owned-local lattice tracks ONLY genuinely owned (non-Copy)
           roots: a Copy-typed root (Int/Bool scalar, reference, ...) is
           routed read-only — moving it is a copy, there is no resource
           state to track.  The first-seen type is the root local's own
           type (the local's type is stable across its accesses). *)
        let roots = ref [] in
        List.iter
          (fun (a : access) ->
            match a.a_path with
            | Some p ->
                if not (List.exists (fun (r, _) -> r = p.root) !roots) then
                  roots := (p.root, a.a_type) :: !roots
            | None -> ())
          accs;
        let owned_roots =
          List.filter
            (fun (_, ty) -> not (Resource_check.is_copy resolve [] ty))
            (List.rev !roots)
        in
        let env = Resource_check.create_env (List.map fst owned_roots) in
        List.iter
          (fun (a : access) ->
            match a.a_path with
            | None -> ()
            | Some p ->
                (* a recorded access implies the local's binding was
                   accepted by the typechecker: materialize the binding
                   as Live at first sight (the lattice starts
                   Uninitialized for locals created in the body).  A
                   FIRST Initialize is the initialization itself, so it
                   transitions Uninitialized -> Live WITHOUT the
                   re-initialization error — the re-initialization
                   error applies only to subsequent Initialize accesses
                   on a root that is already Live (otherwise the pass
                   manufactures its own conflict). *)
                let was_uninitialized =
                  Resource_check.state_of env p.root = Resource_check.Uninitialized
                in
                if was_uninitialized then
                  Resource_check.set_state env p.root Resource_check.Live;
                (match a.a_effect with
                 | Access_effect.Consume ->
                     (* the move's copyability comes from the argument's
                        recorded type (scalars/immutables copy; owning
                        types move) — not a hard-coded move *)
                     Resource_check.check_move env p.root
                       (Resource_check.is_copy resolve [] a.a_type)
                       a.a_item
                 | Access_effect.Initialize ->
                     if was_uninitialized then ()
                     else Resource_check.check_initialize env p.root a.a_item
                 | Access_effect.Read | Access_effect.Modify ->
                     Resource_check.check_read env p.root a.a_item))
          accs;
        List.map
          (fun e -> { f_item = item; f_kind = "state-conflict"; f_message = e })
          (List.rev env.Resource_check.errors))
      (List.rev !item_order)
  in
  call_findings @ item_findings
