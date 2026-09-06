(* mir_derive.ml — compiler-generated bodies for the derived operations
   (audit P0-12).

   The derived Clone::clone / to_string / eq / scalar-hash signatures the
   typechecker mints (typecheck.ml's derived channel: `derived::<owner>::
   <op>` sigs recorded in state.derived_sigs) are REAL function
   declarations whose bodies this module lowers into Seed MIR.  A derived
   signature declares the RECEIVER's own generic carriers (a concrete
   receiver declares none and embeds its concrete self/ret types; a
   receiver spelled with the enclosing item's params declares exactly
   those params), so the emitted function is a genuine template the
   monomorphizer specializes — the synthesized body carries the SAME
   callable identity the call sites reference, the verifier checks a
   real body, and the VM executes a real function.  No body-less derived
   registration survives.

   Body shapes (the checker's and lowering's conventions, mirrored):

   - clone of a struct  — one Read per FIELD in declaration order (Field
     projections carry the def's SEMANTIC FieldIds), rebuilt with a
     StructCtor aggregate;
   - clone of an enum   — Discriminant + SwitchInt over the declaration
     tags, per-variant payload Reads through [Downcast vid; ConstantIndex
     j], rebuilt with EnumCtor aggregates;
   - clone of a tuple /
     fixed array        — per-element Reads (ConstantIndex), rebuilt with
     TupleAgg / ArrayAgg;
   - clone of anything
     else (scalars,
     String-shaped,
     bare generic
     params, refs)      — the value Read.  The seed's runtime values are
     immutable trees — every aggregate mutation rebuilds the spine and
     never mutates a shared subtree — so the duplicated top-level value
     is observationally the field-wise clone;
   - eq                 — the whole-value structural BinaryOp Eq of self
     and other (the checker's fundamental equality accepts the same
     operand class and the VM compares tags + payloads structurally);
   - hash (Int-kind
     receivers only)    — the numeric identity (Int) / Cast to Int;
   - to_string          — per-shape rendering: scalar receivers render
     through the compiler's registered render intrinsics
     (__intrinsic_int/bool/char/float_to_string — body-less registered
     sigs the driver's host-channel normalization rewrites onto the
     Intrinsic channel exactly like source calls), aggregates render
     their fields/variants in declaration order ("Name { f: v, ... }" /
     "Variant(...)" / "(...)" / "[...]" forms), and receivers without a
     nominal shape (bare generic params, def-less nominals) delegate to
     the kernel's universal `def to_string[T: Display](val: T)` — the
     same Display contract the real language resolves such calls
     through.

   The renderer/universal callees are looked up in the checker's
   REGISTERED function table (the same registered sigs source calls to
   them resolve against), so their callable identities are the ones the
   mono / verifier / host-channel machinery already knows. *)

(* ── Registered-callee lookups ─────────────────────────────────────
   The checker's functions-table keys are module-qualified names
   ("std::core::__intrinsic_int_to_string"); the lookup matches the bare
   suffix and verifies the declared shape (arity, parameter types,
   return) so a name collision can never pick the wrong callable. *)

let bare_name (k : string) : string =
  match String.rindex_opt k ':' with
  | Some i when i > 0 && k.[i - 1] = ':' && i + 1 < String.length k ->
      String.sub k (i + 1) (String.length k - i - 1)
  | _ -> k

let op_of_name (name : string) : string =
  (* "derived::<owner>::<op>" -> op *)
  match String.rindex_opt name ':' with
  | Some i when i > 0 && name.[i - 1] = ':' && i + 1 < String.length name ->
      String.sub name (i + 1) (String.length name - i - 1)
  | _ -> failwith ("mir_derive: unrecognized derived signature name " ^ name)

let registered_sig_of_bare (env : Typecheck.env) (bare : string) :
    Typecheck.typed_signature option =
  match
    List.find_opt (fun (k, _) -> bare_name k = bare) env.Typecheck.functions
  with
  | Some (_, ts) -> Some ts
  | None -> None

(* The universal `def to_string[T: Display](val: T) -> String` (the
   kernel's std/core.tg): exactly one declared binder, one parameter
   whose type IS that binder, String return.  (std/fmt.tg registers an
   Int-only `to_string` — no declared binder — which this shape
   rejects.) *)
let universal_to_string_sig (env : Typecheck.env) :
    Typecheck.typed_signature option =
  match
    List.find_opt
      (fun (k, ts) ->
        bare_name k = "to_string"
        && List.length ts.Typecheck.ts_params_decl = 1
        && Array.length ts.Typecheck.ts_params = 1
        && ts.Typecheck.ts_return = Type_repr.String
        &&
        match (ts.Typecheck.ts_params.(0)).Type_repr.pt_type with
        | Type_repr.Type_param p -> (
            match ts.Typecheck.ts_params_decl with
            | [ (_, q) ] -> Ids.Generic_param_id.compare p q = 0
            | _ -> false)
        | _ -> false)
      env.Typecheck.functions
  with
  | Some (_, ts) -> Some ts
  | None -> None

(* The scalar render intrinsics (extern-declared in std/core.tg): the
   parameter type and the String return must match exactly. *)
let registered_renderer (env : Typecheck.env) (bare : string)
    (param_ty : Type_repr.t) : Typecheck.typed_signature option =
  match registered_sig_of_bare env bare with
  | Some ts ->
      if Array.length ts.Typecheck.ts_params = 1
         && ts.Typecheck.ts_return = Type_repr.String
         && Type_repr.compare (ts.Typecheck.ts_params.(0)).Type_repr.pt_type param_ty = 0
      then Some ts
      else None
  | None -> None

(* ── Nominal-def helpers ───────────────────────────────────────────
   The def lookups follow the driver's materialized-type conventions:
   semantic FieldId/VariantId lists when the resolver minted them, else
   the position-derived 1-based ids — exactly the convention
   closure_types / materialize_type_instances apply, so the emitted
   projections resolve against the def tables the verifier and the VM
   use. *)

let nominal_of_tid (env : Typecheck.env) (tid : Ids.Type_id.t) :
    (string * Typecheck.nominal) option =
  List.find_opt
    (fun (name, _nom) ->
      match List.assoc_opt name env.Typecheck.type_ids with
      | Some t -> Ids.Type_id.compare t tid = 0
      | None -> false)
    env.Typecheck.nominals

let nominal_shape_of (env : Typecheck.env) (ty : Type_repr.t) :
    (string * Typecheck.nominal * Type_repr.t array) option =
  match ty with
  | Type_repr.Named (tid, args) -> (
      match nominal_of_tid env tid with
      | Some (name, nom) -> Some (name, nom, args)
      | None -> None)
  | _ -> None

(* The nominal's own parameters substituted by the RECEIVER's argument
   types (positionally — the receiver's args name the nominal's params,
   so a def type over the nominal's params becomes a type over the
   receiver's carriers / concrete args). *)
let nominal_arg_bindings (nom : Typecheck.nominal) (args : Type_repr.t array) :
    (Type_repr.generic_key * Type_repr.t) list =
  let ps = Array.of_list (List.map snd nom.Typecheck.nom_params) in
  if Array.length ps = Array.length args then
    List.map2
      (fun p a -> (Type_repr.KParam p, a))
      (Array.to_list ps) (Array.to_list args)
  else []

let field_ids_of (nom : Typecheck.nominal) : Ids.Field_id.t list =
  if List.length nom.Typecheck.nom_field_ids = List.length nom.Typecheck.nom_fields then
    nom.Typecheck.nom_field_ids
  else List.mapi (fun i _ -> Ids.Field_id.make (i + 1)) nom.Typecheck.nom_fields

let variant_ids_of (nom : Typecheck.nominal) : Ids.Variant_id.t list =
  if List.length nom.Typecheck.nom_variant_ids = List.length nom.Typecheck.nom_variants then
    nom.Typecheck.nom_variant_ids
  else List.mapi (fun i _ -> Ids.Variant_id.make (i + 1)) nom.Typecheck.nom_variants

(* The braced-field names per variant ([] = positional payload) *)
let variant_field_names_of (nom : Typecheck.nominal) (i : int) : string list =
  match List.nth_opt nom.Typecheck.nom_variant_field_names i with
  | Some (_, names) -> names
  | None -> []

(* ── The seed body builder ─────────────────────────────────────────
   Mirrors mir_lower's conventions: local _0 is the return slot;
   parameter i occupies local _i+1; block ids run sequentially from the
   entry (block 0); statements accumulate per block and a block is
   closed exactly once with its terminator. *)

type st = {
  mutable next_local : int;
  mutable locals : Type_repr.t array;
  mutable next_block : int;
  mutable blocks : Seed_mir.block list; (* reversed *)
  mutable cur_block : int;
  mutable cur_stmts : Seed_mir.statement list; (* reversed *)
}

let fresh_local (s : st) (ty : Type_repr.t) : int =
  let id = s.next_local in
  s.next_local <- id + 1;
  if id >= Array.length s.locals then s.locals <- Array.append s.locals [| ty |]
  else s.locals.(id) <- ty;
  id

let place_of (id : int) : Seed_mir.place =
  { Seed_mir.root = Seed_mir.Local id; projections = [] }

let proj (p : Seed_mir.place) (pr : Seed_mir.projection) : Seed_mir.place =
  { Seed_mir.root = p.Seed_mir.root;
    projections = p.Seed_mir.projections @ [ pr ] }

let emit (s : st) (stm : Seed_mir.statement) : unit =
  s.cur_stmts <- stm :: s.cur_stmts

let new_block (s : st) : int =
  let id = s.next_block in
  s.next_block <- id + 1;
  id

let set_cur (s : st) (id : int) : unit =
  s.cur_stmts <- [];
  s.cur_block <- id

let close_with (s : st) (t : Seed_mir.terminator) : unit =
  s.blocks <-
    { Seed_mir.id = s.cur_block; statements = List.rev s.cur_stmts; terminator = t }
    :: s.blocks;
  s.cur_stmts <- []

let read_op (p : Seed_mir.place) : Seed_mir.operand = Seed_mir.Read p

let const_string (v : string) : Seed_mir.operand =
  Seed_mir.Constant (Seed_mir.String v)

(* Discriminant + SwitchInt dispatcher over a subject's declaration-order
   tags.  variant_body i runs with the current block set to variant i's
   block (the driver closes each variant block with a Goto to the shared
   join afterwards); the shared join becomes the current block. *)
let build_variant_switch (s : st) (subject : Seed_mir.place) (n : int)
    (variant_body : int -> unit) : unit =
  let did = fresh_local s (Type_repr.Int Type_repr.UInt) in
  emit s (Seed_mir.Assign (place_of did, Seed_mir.Discriminant subject));
  let bbs = Array.init n (fun _ -> new_block s) in
  let abort_b = new_block s in
  let join_b = new_block s in
  close_with s
    (Seed_mir.SwitchInt
       ( Seed_mir.Copy (place_of did),
         List.init n (fun i -> (Int64.of_int i, bbs.(i))),
         abort_b ));
  set_cur s abort_b;
  close_with s Seed_mir.Abort;
  Array.iteri
    (fun i bb ->
      set_cur s bb;
      variant_body i;
      close_with s (Seed_mir.Goto join_b))
    bbs;
  set_cur s join_b

(* String concatenation: every concat materializes into a fresh String
   local (the seed's String + String form). *)
let concat2 (s : st) (a : Seed_mir.operand) (b : Seed_mir.operand) :
    Seed_mir.operand =
  let nl = fresh_local s Type_repr.String in
  emit s
    (Seed_mir.Assign (place_of nl, Seed_mir.BinaryOp (Seed_mir.Add, a, b)));
  Seed_mir.Read (place_of nl)

let concat_all (s : st) (parts : Seed_mir.operand list) : Seed_mir.operand =
  match parts with
  | [] -> const_string ""
  | p :: rest -> List.fold_left (fun acc q -> concat2 s acc q) p rest

(* A registered renderer call (the intrinsic to_string surface).  The
   call closes the current block; the continuation becomes current.
   The callee is emitted under its CHECKER-side class (audit P0-5: the
   registered renderers are extern-declared names whose registry
   bindings classify as Intrinsic at classification time — the same
   decision the deleted post-mono host-channel rewrite made for these
   calls; a callable without a binding keeps the User form and needs
   its real body). *)
let renderer_call (env : Typecheck.env) (s : st) (bare : string)
    (param_ty : Type_repr.t) (arg : Seed_mir.operand) : Seed_mir.operand =
  match registered_renderer env bare param_ty with
  | None ->
      failwith
        (Printf.sprintf
           "mir_derive: no registered renderer `%s` for derived to_string" bare)
  | Some ts ->
      let dest = fresh_local s Type_repr.String in
      let cont = new_block s in
      let callee =
        Mir_lower.callee_of_typed
          (Typecheck.classify_callee ~hint:Typecheck.CCH_function ts
             ~argc:1 ~type_args:[||])
      in
      close_with s
        (Seed_mir.Call
           ( place_of dest,
             callee,
             [| { Seed_mir.effect_ = Access_effect.Read; value = arg } |],
             cont,
             None ));
      set_cur s cont;
      Seed_mir.Read (place_of dest)

(* The universal `def to_string[T: Display](val: T) -> String` delegate
   (receivers without a structural render). *)
let universal_render_call (env : Typecheck.env) (s : st) (ty : Type_repr.t)
    (arg : Seed_mir.operand) : Seed_mir.operand =
  match universal_to_string_sig env with
  | None ->
      failwith
        "mir_derive: no registered universal `to_string[T: Display]` for a derived to_string delegate"
  | Some ts ->
      let dest = fresh_local s Type_repr.String in
      let cont = new_block s in
      let callee =
        Mir_lower.callee_of_typed
          (Typecheck.classify_callee ~hint:Typecheck.CCH_function ts
             ~argc:1 ~type_args:[| ty |])
      in
      close_with s
        (Seed_mir.Call
           ( place_of dest,
             callee,
             [| { Seed_mir.effect_ = Access_effect.Read; value = arg } |],
             cont,
             None ));
      set_cur s cont;
      Seed_mir.Read (place_of dest)

(* The Int-kind scalar render: only the Int kind renders directly; every
   other kind casts to Int first (the kernel's own convention — sources
   cast narrower/unsigned values before rendering). *)
let render_int_kind (env : Typecheck.env) (s : st) (k : Type_repr.int_kind)
    (arg : Seed_mir.operand) : Seed_mir.operand =
  match k with
  | Type_repr.Int ->
      renderer_call env s "__intrinsic_int_to_string"
        (Type_repr.Int Type_repr.Int) arg
  | _ ->
      let ci = fresh_local s (Type_repr.Int Type_repr.Int) in
      emit s
        (Seed_mir.Assign
           (place_of ci, Seed_mir.Cast (arg, Type_repr.Int Type_repr.Int)));
      renderer_call env s "__intrinsic_int_to_string"
        (Type_repr.Int Type_repr.Int) (read_op (place_of ci))

(* ── The to_string renderer (recursive; nominal enums/structs switch or
   iterate, payload fields recurse through render_into) ──────────── *)

let rec render_into (env : Typecheck.env) (s : st) (dest : int)
    (p : Seed_mir.place) (ty : Type_repr.t) : unit =
  let assign (op : Seed_mir.operand) : unit =
    emit s (Seed_mir.Assign (place_of dest, Seed_mir.Use op))
  in
  match nominal_shape_of env ty with
  | Some (_name, nom, args) when nom.Typecheck.nom_kind = `Enum ->
      (* per-variant rendering: variant name (+ payload renders); each
         variant assigns dest; the shared join continues *)
      let binds = nominal_arg_bindings nom args in
      let variants = nom.Typecheck.nom_variants in
      let vids = variant_ids_of nom in
      let n = List.length variants in
      build_variant_switch s p n (fun i ->
          let vname, flds = List.nth variants i in
          let vid = List.nth vids i in
          let fnames = variant_field_names_of nom i in
          let payload_place = proj p (Seed_mir.Downcast vid) in
          let parts = ref [ const_string vname ] in
          let nf = Array.length flds in
          if nf > 0 then begin
            if fnames = [] then parts := !parts @ [ const_string "(" ]
            else parts := !parts @ [ const_string " { " ];
            Array.iteri
              (fun j fty ->
                if j > 0 then parts := !parts @ [ const_string ", " ];
                if List.length fnames = nf then
                  parts := !parts @ [ const_string (List.nth fnames j ^ ": ") ];
                let fd = fresh_local s Type_repr.String in
                render_into env s fd
                  (proj payload_place (Seed_mir.ConstantIndex j))
                  (Type_repr.substitute binds fty);
                parts := !parts @ [ read_op (place_of fd) ])
              flds;
            if fnames = [] then parts := !parts @ [ const_string ")" ]
            else parts := !parts @ [ const_string " }" ]
          end;
          assign (concat_all s !parts))
  | Some (name, nom, args) when nom.Typecheck.nom_kind = `Struct ->
      let binds = nominal_arg_bindings nom args in
      let fids = field_ids_of nom in
      let fields =
        List.map2
          (fun (fname, fty) fid ->
            (fname, Type_repr.substitute binds fty, fid))
          nom.Typecheck.nom_fields fids
      in
      let parts = ref [ const_string name; const_string " { " ] in
      List.iteri
        (fun i (fname, fty, fid) ->
          if i > 0 then parts := !parts @ [ const_string ", " ];
          parts := !parts @ [ const_string (fname ^ ": ") ];
          let fd = fresh_local s Type_repr.String in
          render_into env s fd (proj p (Seed_mir.Field fid)) fty;
          parts := !parts @ [ read_op (place_of fd) ])
        fields;
      assign (concat_all s (!parts @ [ const_string " }" ]))
  | _ -> (
      match ty with
      | Type_repr.String -> assign (read_op p)
      | Type_repr.Unit -> assign (const_string "")
      | Type_repr.Bool ->
          assign
            (renderer_call env s "__intrinsic_bool_to_string" Type_repr.Bool
               (read_op p))
      | Type_repr.Char ->
          assign
            (renderer_call env s "__intrinsic_char_to_string" Type_repr.Char
               (read_op p))
      | Type_repr.Int k -> assign (render_int_kind env s k (read_op p))
      | Type_repr.Float Type_repr.F64 ->
          assign
            (renderer_call env s "__intrinsic_float_to_string"
               (Type_repr.Float Type_repr.F64) (read_op p))
      | Type_repr.Float Type_repr.F32 ->
          let cf = fresh_local s (Type_repr.Float Type_repr.F64) in
          emit s
            (Seed_mir.Assign
               (place_of cf,
                Seed_mir.Cast (read_op p, Type_repr.Float Type_repr.F64)));
          assign
            (renderer_call env s "__intrinsic_float_to_string"
               (Type_repr.Float Type_repr.F64) (read_op (place_of cf)))
      | Type_repr.Tuple elems ->
          let parts = ref [ const_string "(" ] in
          Array.iteri
            (fun i et ->
              if i > 0 then parts := !parts @ [ const_string ", " ];
              let ed = fresh_local s Type_repr.String in
              render_into env s ed
                (proj p (Seed_mir.ConstantIndex i)) et;
              parts := !parts @ [ read_op (place_of ed) ])
            elems;
          assign (concat_all s (!parts @ [ const_string ")" ]))
      | Type_repr.Fixed_array (et, n) ->
          let parts = ref [ const_string "[" ] in
          for i = 0 to n - 1 do
            if i > 0 then parts := !parts @ [ const_string ", " ];
            let ed = fresh_local s Type_repr.String in
            render_into env s ed (proj p (Seed_mir.ConstantIndex i)) et;
            parts := !parts @ [ read_op (place_of ed) ]
          done;
          assign (concat_all s (!parts @ [ const_string "]" ]))
      | Type_repr.Named _ | Type_repr.Type_param _ | Type_repr.Infer_var _
      | Type_repr.Ref_internal _ | Type_repr.Raw_ptr _ ->
          (* def-less nominals / bare params / references: the universal
             Display delegate *)
          assign (universal_render_call env s ty (read_op p))
      | Type_repr.Never | Type_repr.Error -> assign (const_string "<never>")
      | Type_repr.Function _ -> assign (const_string "<fn>")
      | Type_repr.Int_literal _ -> assign (const_string "?"))

(* ── synthesize ────────────────────────────────────────────────────
   One derived signature -> the Seed MIR function carrying the SAME
   callable identity the call sites reference. *)

let synthesize (env : Typecheck.env) (ts : Typecheck.typed_signature) :
    Seed_mir.function_ =
  let op = op_of_name ts.Typecheck.ts_name in
  let ret_ty = ts.Typecheck.ts_return in
  let param_tys =
    Array.map
      (fun (p : Type_repr.param_type) -> p.Type_repr.pt_type)
      ts.Typecheck.ts_params
  in
  let s =
    {
      next_local = 0;
      locals = [||];
      next_block = 1;
      blocks = [];
      cur_block = 0;
      cur_stmts = [];
    }
  in
  ignore (fresh_local s ret_ty);
  Array.iter (fun t -> ignore (fresh_local s t)) param_tys;
  let self_ty =
    if Array.length param_tys >= 1 then param_tys.(0) else Type_repr.Unit
  in
  let ret_slot = place_of 0 in
  let assign_ret (rv : Seed_mir.rvalue) : unit =
    emit s (Seed_mir.Assign (ret_slot, rv));
    close_with s Seed_mir.Ret
  in
  (match op with
   | "clone" -> (
       match nominal_shape_of env self_ty with
       | Some (_, nom, args) when nom.Typecheck.nom_kind = `Struct ->
           let binds = nominal_arg_bindings nom args in
           let fids = field_ids_of nom in
           let fields =
             List.map2
               (fun (_, fty) fid -> (Type_repr.substitute binds fty, fid))
               nom.Typecheck.nom_fields fids
           in
           let tid =
             match self_ty with
             | Type_repr.Named (tid, _) -> tid
             | _ -> failwith "mir_derive: struct clone receiver identity"
           in
           let ops =
             List.map
               (fun (_, fid) ->
                 read_op (proj (place_of 1) (Seed_mir.Field fid)))
               fields
           in
           assign_ret
             (Seed_mir.Aggregate
                ( Seed_mir.StructCtor
                    ( tid,
                      Array.init (List.length fields) (fun i ->
                          Ids.Field_index.make i) ),
                  ops ))
       | Some (_, nom, _) when nom.Typecheck.nom_kind = `Enum ->
           let tid =
             match self_ty with
             | Type_repr.Named (tid, _) -> tid
             | _ -> failwith "mir_derive: enum clone receiver identity"
           in
           let variants = nom.Typecheck.nom_variants in
           let vids = variant_ids_of nom in
           let n = List.length variants in
           build_variant_switch s (place_of 1) n (fun i ->
               let _, flds = List.nth variants i in
               let vid = List.nth vids i in
               let payload_place =
                 proj (place_of 1) (Seed_mir.Downcast vid)
               in
               let ops =
                 List.init (Array.length flds) (fun j ->
                     read_op
                       (proj payload_place (Seed_mir.ConstantIndex j)))
               in
               emit s
                 (Seed_mir.Assign
                    ( ret_slot,
                      Seed_mir.Aggregate
                        ( Seed_mir.EnumCtor (tid, Ids.Variant_index.make i),
                          ops ) )));
           close_with s Seed_mir.Ret
       | _ -> (
           match self_ty with
           | Type_repr.Tuple elems ->
               assign_ret
                 (Seed_mir.Aggregate
                    ( Seed_mir.TupleAgg,
                      List.init (Array.length elems) (fun j ->
                          read_op
                            (proj (place_of 1) (Seed_mir.ConstantIndex j))) ))
           | Type_repr.Fixed_array (_, n) ->
               assign_ret
                 (Seed_mir.Aggregate
                    ( Seed_mir.ArrayAgg,
                      List.init n (fun j ->
                          read_op
                            (proj (place_of 1) (Seed_mir.ConstantIndex j))) ))
           | _ ->
               (* scalars / String / bare params / refs / def-less
                  nominals: the top-level value read (the seed's
                  immutable value trees make the duplicated value the
                  field-wise clone) *)
               assign_ret (Seed_mir.Use (read_op (place_of 1)))))
   | "eq" ->
       assign_ret
         (Seed_mir.BinaryOp
            ( Seed_mir.Eq,
              read_op (place_of 1),
              read_op (place_of 2) ))
   | "hash" -> (
       match self_ty with
       | Type_repr.Int Type_repr.Int ->
           assign_ret (Seed_mir.Use (read_op (place_of 1)))
       | Type_repr.Int _ ->
           assign_ret
             (Seed_mir.Cast
                (read_op (place_of 1), Type_repr.Int Type_repr.Int))
       | _ -> failwith "mir_derive: scalar-hash receiver is not Int-kind")
   | "to_string" -> (
       render_into env s 0 (place_of 1) self_ty;
       close_with s Seed_mir.Ret)
   | other ->
       failwith
         (Printf.sprintf "mir_derive: unsupported derived operation `%s`"
            other));
  if s.cur_stmts <> [] then
    failwith "mir_derive: unclosed block in the synthesized body";
  let blocks =
    Array.of_list
      (List.sort
         (fun a b -> compare a.Seed_mir.id b.Seed_mir.id)
         (List.rev s.blocks))
  in
  {
    Seed_mir.name = ts.Typecheck.ts_name;
    instance =
      Instance_id.make
        ~callable:ts.Typecheck.ts_callable
        ~type_args:
          (Array.of_list
             (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                ts.Typecheck.ts_params_decl));
    params = ts.Typecheck.ts_params;
    locals = s.locals;
    blocks;
    entry = 0;
  }
