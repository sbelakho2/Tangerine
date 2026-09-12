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

    - clone of a struct  — one semantic clone per FIELD in declaration
      order (Field projections carry the def's SEMANTIC FieldIds),
      rebuilt with a StructCtor aggregate;
    - clone of an enum   — Discriminant + SwitchInt over the declaration
      tags, per-variant payload clones through [Downcast vid;
      ConstantIndex j], rebuilt with EnumCtor aggregates;
    - clone of a tuple /
      fixed array        — per-element semantic clones (ConstantIndex),
      rebuilt with TupleAgg / ArrayAgg;
    - clone of a Copy
      component         — the value Read (only trivially copyable
                          components — scalars, tuples/arrays of Copy
                          elements, defs whose fields are Copy — ever
                          duplicate a value: their duplication IS the
                          semantic clone);
    - clone of a non-Copy
      component (String,
      Vec[T], Map[K,V],
      Set[T], Box[T], a
      custom non-Copy Clone
      type, a rigid
      generic carrier
      discharged through
      its declared Clone
      bound)             — a REAL call of the component's own Clone
                          (audit P0-4): the registered (owner, clone)
                          method for the component type — String::clone,
                          the container clones, `impl Clone for C`'s
                          clone — under the same callable identity the
                          source body lowers; a rigid carrier clones
                          through the Clone trait contract exactly like
                          the kernel's bound-generic `x.clone()` calls
                          (`impl[T: Clone] ... { t.clone() }` lower the
                          contract instance).  NO non-Copy component is
                          ever duplicated by an ordinary Read: the
                          checker's derived-Clone mint (typecheck.ml,
                          audit P0-4) refuses the mint unless every
                          component discharges Copy OR Clone, and the
                          minted signature carries the rigid-carrier
                          Clone bounds as where-clauses — this module
                          re-checks the same obligations at synthesis
                          (resolve_clone_impl over the SAME registered
                          tables typecheck consulted), so a body without
                          its obligation is an internal error, never a
                          silent structural copy;
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

(* ── Diagnostics (env-gated) ───────────────────────────────────────
   TANGERINE_DEBUG_DERIVE=1 turns on derived-body synthesis diagnostics
   (per-body summaries and sampled fresh-local lines).  Nothing prints
   unconditionally: the old [derive-dbg] traces wrote one line per fresh
   local / render call with %! and turned stderr into megabytes of
   flush-bound output during the full-closure lowering. *)
let derive_debug =
  try Sys.getenv "TANGERINE_DEBUG_DERIVE" <> "" with Not_found -> false

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
  (* the SAME authority the checker's nominal_of_tid resolves through
     (its O(1) lookup cache — first nominal wins, exactly the walk
     this used to spell out) *)
  Typecheck.nominal_entry_of_tid env tid

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

(* Runaway tripwire (audit P0-12): the derive renderer cuts nominal
   cycles by calling the repeated type's own derived op, so a body is
   bounded by the distinct nominal types on the render path.  A body
   beyond this many locals means a cycle was NOT cut (the pre-fix
   ItemKind::to_string reached 480k+); fail deterministically with the
   signature name instead of growing the process to OOM.  Override with
   TANGERINE_MAX_DERIVED_LOCALS if a legitimate closure ever needs more. *)
let max_derived_locals =
  match Sys.getenv_opt "TANGERINE_MAX_DERIVED_LOCALS" with
  | Some s -> (match int_of_string_opt s with Some n -> n | None -> 200_000)
  | None -> 200_000

let current_derived_sig = ref "?"

let fresh_local (s : st) (ty : Type_repr.t) : int =
  let id = s.next_local in
  s.next_local <- id + 1;
  if id > max_derived_locals then
    failwith
      (Printf.sprintf
         "mir_derive: derived body %s exceeded %d locals (uncut recursion)"
         !current_derived_sig max_derived_locals);
  let cap = Array.length s.locals in
  if id >= cap then begin
    (* geometric growth: a derived body can allocate tens of thousands of
       locals (large recursive struct/enum renders); the previous
       one-element Array.append recopied the whole prefix per local and
       turned synthesis quadratic.  The buffer is truncated back to
       next_local in synthesize, so the emitted locals array is exactly
       the old one. *)
    let ncap = if cap = 0 then 16 else cap * 2 in
    let grown = Array.make ncap ty in
    Array.blit s.locals 0 grown 0 cap;
    s.locals <- grown
  end
  else s.locals.(id) <- ty;
  if derive_debug && id > 0 && id mod 20000 = 0 then
    Printf.eprintf "[derive-dbg] fresh_local id=%d arrlen=%d ty=%s\n" id
      (Array.length s.locals) (Seed_mir.print_type ty);
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

(* ── Cycle-safe rendering: auxiliary derived to_string functions ──
   A recursive nominal type (the compiler's own TypeExpr/TypeExprKind,
   Expr/ExprKind, ...) has NO finite inline rendering: inlining the
   fields of `TypeExprKind::Slice(TypeExpr)` re-enters TypeExpr, whose
   fields re-enter TypeExprKind, forever.  render_into therefore tracks
   the nominal types currently being rendered and, on re-entry, emits a
   runtime CALL to that type's own derived to_string instead of inlining
   it (exactly the recursive call a hand-written renderer would make, so
   the produced string is unchanged).  The auxiliary receiver template
   is minted through the checker's mk_sig with the SAME shape the
   checker's derived mint uses (receiver's own carriers, `self: Let`,
   String return) and queued on the lowering's pending list; the driver
   synthesizes a real body for it exactly like the checker-minted
   derived sigs, and the monomorphizer resolves the call to that body
   (the derived-contract class). *)

let aux_to_string_sigs : (string, Typecheck.typed_signature) Hashtbl.t =
  Hashtbl.create 32

let pending_derived :
    (Ids.Callable_id.t * Typecheck.typed_signature) list ref =
  ref []

let take_pending_derived () =
  let l = List.rev !pending_derived in
  pending_derived := [];
  l

let find_derived_to_string (env : Typecheck.env) (ty : Type_repr.t) :
    Typecheck.typed_signature option =
  List.find_opt
    (fun (_, (ts : Typecheck.typed_signature)) ->
      Array.length ts.Typecheck.ts_params = 1
      && Type_repr.compare ts.Typecheck.ts_params.(0).Type_repr.pt_type ty = 0
      &&
      let n = ts.Typecheck.ts_name in
      let l = String.length n in
      l >= 11 && String.sub n (l - 11) 11 = "::to_string")
    env.Typecheck.state.Typecheck.derived_sigs
  |> Option.map snd

let mint_derived_to_string (env : Typecheck.env) (owner : string)
    (ty : Type_repr.t) : Typecheck.typed_signature =
  let key = owner ^ "\000" ^ Typecheck.type_to_string ty in
  match Hashtbl.find_opt aux_to_string_sigs key with
  | Some ts -> ts
  | None ->
      let ts =
        match find_derived_to_string env ty with
        | Some ts -> ts
        | None ->
            let params_decl =
              List.mapi
                (fun i p -> ("T" ^ string_of_int i, p))
                (Typecheck.params_in ty)
            in
            let ts =
              Typecheck.mk_sig env.Typecheck.state
                ~name:("derived::" ^ owner ^ "::to_string")
                ~params_decl
                ~params:[ ("self", Access_effect.Let, ty) ]
                ~ret:Type_repr.String ~where:[]
            in
            env.Typecheck.state.Typecheck.derived_sigs <-
              (ts.Typecheck.ts_callable, ts)
              :: env.Typecheck.state.Typecheck.derived_sigs;
            env.Typecheck.state.Typecheck.oracle.o_derived_callables <-
              ts.Typecheck.ts_callable
              :: env.Typecheck.state.Typecheck.oracle.o_derived_callables;
            pending_derived := (ts.Typecheck.ts_callable, ts) :: !pending_derived;
            ts
      in
      Hashtbl.replace aux_to_string_sigs key ts;
      ts

(* The derived Clone counterpart: the mono dispatch injection re-dispatches
   a bodyless `Clone::clone` contract call on a concrete receiver through
   the checker's derived-Clone mint when the receiver has no registered
   Clone impl.  The minted signature carries the receiver's own carriers
   and the Clone where-clauses the checker's obligation authority
   (`derived_clone_obligations`) returned; synthesis emits the real body
   under the same callable identity. *)
let find_derived_clone (env : Typecheck.env) (ty : Type_repr.t) :
    Typecheck.typed_signature option =
  List.find_opt
    (fun (_, (ts : Typecheck.typed_signature)) ->
      Array.length ts.Typecheck.ts_params = 1
      && Type_repr.compare ts.Typecheck.ts_params.(0).Type_repr.pt_type ty = 0
      &&
      let n = ts.Typecheck.ts_name in
      let l = String.length n in
      l >= 7 && String.sub n (l - 7) 7 = "::clone")
    env.Typecheck.state.Typecheck.derived_sigs
  |> Option.map snd

let mint_derived_clone (env : Typecheck.env) (owner : string)
    (ty : Type_repr.t) : (Typecheck.typed_signature, string) result =
  match find_derived_clone env ty with
  | Some ts -> Ok ts
  | None ->
      (* The where-clauses the checker's obligation authority recorded (the
         Clone bounds of rigid carriers).  A structural derivation is
         admissible even when the checker's strict obligation check
         reported a component without a registered Clone: the synthesized
         body recursively derives that component's own Clone (the
         emit_clone_value fallback), so the obligation is discharged by
         construction — never by raw duplication of an owning value. *)
      let where =
        match Typecheck.derived_clone_obligations env ty with
        | Ok w -> w
        | Error _ -> []
      in
      let params_decl =
        List.mapi
          (fun i p -> ("T" ^ string_of_int i, p))
          (Typecheck.params_in ty)
      in
      let ts =
        Typecheck.mk_sig env.Typecheck.state
          ~name:("derived::" ^ owner ^ "::clone")
          ~params_decl
          ~params:[ ("self", Access_effect.Let, ty) ]
          ~ret:ty ~where
      in
      env.Typecheck.state.Typecheck.derived_sigs <-
        (ts.Typecheck.ts_callable, ts)
        :: env.Typecheck.state.Typecheck.derived_sigs;
      env.Typecheck.state.Typecheck.oracle.o_derived_callables <-
        ts.Typecheck.ts_callable
        :: env.Typecheck.state.Typecheck.oracle.o_derived_callables;
      pending_derived := (ts.Typecheck.ts_callable, ts) :: !pending_derived;
      Ok ts

(* The instance type arguments of a derived signature: its declared
   binders positionally (the template spelling the monomorphizer
   substitutes). *)
let derived_instance_args (ts : Typecheck.typed_signature) : Type_repr.t array =
  Array.of_list
    (List.map (fun (_, pid) -> Type_repr.Type_param pid) ts.Typecheck.ts_params_decl)

(* One runtime call of `ty`'s derived to_string on a value place: closes
   the current block (the call terminator) and continues in a fresh
   block with the returned String. *)
let to_string_value_call (env : Typecheck.env) (s : st) (owner : string)
    (ty : Type_repr.t) (place : Seed_mir.place) : Seed_mir.operand =
  let ts = mint_derived_to_string env owner ty in
  let dest = fresh_local s Type_repr.String in
  let cont = new_block s in
  let type_args =
    Array.of_list
      (List.map
         (fun (_, pid) -> Type_repr.Type_param pid)
         ts.Typecheck.ts_params_decl)
  in
  let callee =
    Mir_lower.callee_of_typed
      (Typecheck.classify_method_callee ~owner:None "to_string" ts ~argc:1
         ~type_args)
  in
  close_with s
    (Seed_mir.Call
       ( place_of dest,
         callee,
         [| { Seed_mir.effect_ = Access_effect.Read; value = read_op place } |],
         cont,
         None ));
  set_cur s cont;
  read_op (place_of dest)

(* ── The to_string renderer (recursive; nominal enums/structs switch or
   iterate, payload fields recurse through render_into) ──────────── *)

let render_stack : Type_repr.t list ref = ref []

(* TANGERINE_DEBUG_DERIVE=1: the first render calls of each body with
   their inline depth and type identity (Type ids, so two same-named
   nominals stay distinguishable). *)
let dbg_render = ref 0

let rec render_into (env : Typecheck.env) (s : st) (dest : int)
    (p : Seed_mir.place) (ty : Type_repr.t) : unit =
  if derive_debug && !dbg_render < 200 then begin
    incr dbg_render;
    Printf.eprintf "[derive-dbg] render #%d depth=%d ty=%s\n" !dbg_render
      (List.length !render_stack) (Seed_mir.print_type ty)
  end;
  let repeated =
    List.exists (fun t -> Type_repr.compare t ty = 0) !render_stack
  in
  match if repeated then nominal_shape_of env ty else None with
  | Some (name, _, _) ->
      (* a recursive nominal type: call its own derived to_string — the
         recursive runtime call a hand-written renderer would make *)
      let op = to_string_value_call env s name ty p in
      emit s (Seed_mir.Assign (place_of dest, Seed_mir.Use op))
  | None ->
      render_stack := ty :: !render_stack;
      render_into_inline env s dest p ty;
      render_stack := List.tl !render_stack

and render_into_inline (env : Typecheck.env) (s : st) (dest : int)
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

(* ── audit P0-4: trait-semantic derived Clone ──────────────────────
   The synthesized clone body is a SEMANTIC clone, never a structural
   Read duplication of owning values.  The emission decision is the
   SAME obligation authority the checker's mint used (typecheck.ml's
   tc_is_copy / registered_clone_method — one engine, no drift): a
   component is read only when it is trivially copyable; every other
   component is duplicated through its own Clone call.  A component
   that reaches emission without discharging the obligation is an
   internal error — the checker's mint refused such receivers, so a
   body here means the obligations were recorded. *)

(* The registered clone method of a component type (mirror of the
   checker's obligation authority — same tables, same alias
   convention, same receiver-self unification). *)
let resolve_clone_impl (env : Typecheck.env) (ty : Type_repr.t) :
    (string * Typecheck.typed_signature * Type_repr.t array) option =
  match Typecheck.registered_clone_method env ty with
  | None -> None
  | Some (owner, ts, subst) ->
      let type_args =
        Array.of_list
          (List.map
             (fun (_, pid) ->
               match List.assoc_opt (Type_repr.KParam pid) subst with
               | Some t -> Typecheck.substitute_fixpoint subst t
               | None -> Type_repr.Type_param pid)
             ts.Typecheck.ts_params_decl)
      in
      Some (owner, ts, type_args)

(* One semantic Clone::clone call of a component (the receiver value is
   passed by value — the derived clone's receiver convention — and the
   callee is classified exactly like a source receiver-method call of
   the registered clone: TC_user under the clone method's callable (the
   real lowered body when the program declares the impl; a
   registered-only callee otherwise, exactly like every other
   body-less registration the template verifier admits).  The call
   closes the current block; the continuation becomes current. *)
let clone_call (s : st) (ts : Typecheck.typed_signature)
    (owner : string) (type_args : Type_repr.t array) (ret_ty : Type_repr.t)
    (arg : Seed_mir.operand) : Seed_mir.operand =
  let dest = fresh_local s ret_ty in
  let cont = new_block s in
  let callee =
    Mir_lower.callee_of_typed
      (Typecheck.classify_method_callee ~owner:(Some owner) "clone" ts
         ~argc:1 ~type_args)
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

(* The clone of ONE value component: `ty` at `place` -> an operand of a
   fresh clone of it.  A REGISTERED clone method clones first and
   governs the component's semantics (a nominal that declares
   `impl Clone for C` clones through the impl even when it is
   structurally copyable — derived Clone is trait-semantic, never a
   value duplication that bypasses the impl); without a registered
   clone, trivially copyable components read; aggregate VALUE shapes
   with no nominal owner (tuples, fixed arrays) recurse elementwise; a
   NOMINAL component with no registered clone gets its own derived
   Clone minted and CALLED (recursively — the mint registers the
   signature before its body synthesizes, so a cycle reaches the
   already-minted function at runtime); a rigid generic carrier
   discharges through the Clone trait contract (the kernel's
   bound-generic clone surface), which the minted signature's
   where-clause recorded.  A component with no discharge at all is an
   internal error. *)
let rec emit_clone_value (env : Typecheck.env) (s : st)
    (clone_bound : Ids.Generic_param_id.t list) (ty : Type_repr.t)
    (place : Seed_mir.place) : Seed_mir.operand =
  match resolve_clone_impl env ty with
  | Some (owner, ts, type_args) ->
      clone_call s ts owner type_args ty (read_op place)
  | None ->
      if Typecheck.tc_is_copy env (Typecheck.lang_items_of_env env) ty then read_op place
      else
        match ty with
        | Type_repr.Tuple elems ->
            let ops =
              List.mapi
                (fun i et ->
                  emit_clone_value env s clone_bound et
                    (proj place (Seed_mir.ConstantIndex i)))
                (Array.to_list elems)
            in
            let dl = fresh_local s ty in
            emit s (Seed_mir.Assign (place_of dl, Seed_mir.Aggregate (Seed_mir.TupleAgg, ops)));
            read_op (place_of dl)
        | Type_repr.Fixed_array (et, n) ->
            let ops =
              List.init n (fun i ->
                  emit_clone_value env s clone_bound et
                    (proj place (Seed_mir.ConstantIndex i)))
            in
            let dl = fresh_local s ty in
            emit s (Seed_mir.Assign (place_of dl, Seed_mir.Aggregate (Seed_mir.ArrayAgg, ops)));
            read_op (place_of dl)
        | Type_repr.Type_param pid ->
            (* a rigid carrier: its Clone bound is a where-clause of the
               minted signature — the clone goes through the Clone trait
               contract exactly like the kernel's bound-generic clone calls *)
            if not (List.mem pid clone_bound) then
              failwith
                (Printf.sprintf
                   "mir_derive: internal error — derived Clone emitted for generic parameter #%d without a recorded Clone obligation"
                   (Ids.Generic_param_id.to_int pid));
            (match List.assoc_opt ("Clone", "clone") env.Typecheck.methods with
             | Some ts when Array.length ts.Typecheck.ts_params >= 1 ->
                 clone_call s ts "Clone" [| Type_repr.Type_param pid |] ty (read_op place)
             | _ ->
                 failwith
                   "mir_derive: internal error — the Clone trait contract method is not registered")
        | Type_repr.Named (tid, _) -> (
            (* A nominal component with NO registered Clone impl: the
               component's own derived Clone is minted and CALLED (never a
               raw duplication — derived Clone stays trait-semantic).  The
               mint registers the signature before its body synthesizes,
               so a recursive component reaches the already-minted derived
               function at runtime and the synthesis terminates. *)
            match nominal_of_tid env tid with
            | Some (name, _) -> (
                match mint_derived_clone env name ty with
                | Ok ts ->
                    clone_call s ts name (derived_instance_args ts) ty
                      (read_op place)
                | Error m ->
                    failwith
                      (Printf.sprintf
                         "mir_derive: cannot derive the Clone of component type `%s`: %s"
                         (Seed_mir.print_type ty) m))
            | None ->
                failwith
                  (Printf.sprintf
                     "mir_derive: internal error — derived Clone emitted for nominal `%s` with no registered Clone and no def to derive from"
                     (Seed_mir.print_type ty)))
        | _ ->
            failwith
              (Printf.sprintf
                 "mir_derive: internal error — derived Clone emitted without Clone obligation for type `%s` (the checker's mint obligation authority must have rejected this receiver)"
                 (Seed_mir.print_type ty))

(* The receiver-level clone: nominal receivers clone per their def
   shape (struct fields / the discriminant-dispatched active variant's
   payloads) through emit_clone_value; everything else — tuples, fixed
   arrays, Copy scalars, String/container/LangItem receivers (whose
   registered clone owns the duplication) — is one emit_clone_value. *)
let emit_clone_receiver (env : Typecheck.env) (s : st)
    (clone_bound : Ids.Generic_param_id.t list) (dest : int)
    (ty : Type_repr.t) (place : Seed_mir.place) : unit =
  match nominal_shape_of env ty with
  | Some (_, nom, args) when nom.Typecheck.nom_kind = `Struct ->
      let binds = nominal_arg_bindings nom args in
      let fids = field_ids_of nom in
      let fields =
        List.map2
          (fun (_, fty) fid -> (Type_repr.substitute binds fty, fid))
          nom.Typecheck.nom_fields fids
      in
      let tid =
        match ty with
        | Type_repr.Named (tid, _) -> tid
        | _ -> failwith "mir_derive: struct clone receiver identity"
      in
      let ops =
        List.map
          (fun (fty, fid) ->
            emit_clone_value env s clone_bound fty (proj place (Seed_mir.Field fid)))
          fields
      in
      emit s
        (Seed_mir.Assign
           ( place_of dest,
             Seed_mir.Aggregate
               ( Seed_mir.StructCtor
                   ( tid,
                     Array.init (List.length fields) (fun i ->
                         Ids.Field_index.make i) ),
                 ops ) ))
  | Some (_, nom, _) when nom.Typecheck.nom_kind = `Enum ->
      let tid =
        match ty with
        | Type_repr.Named (tid, _) -> tid
        | _ -> failwith "mir_derive: enum clone receiver identity"
      in
      let variants = nom.Typecheck.nom_variants in
      let vids = variant_ids_of nom in
      let n = List.length variants in
      build_variant_switch s place n (fun i ->
          let _, flds = List.nth variants i in
          let vid = List.nth vids i in
          let payload_place = proj place (Seed_mir.Downcast vid) in
          let ops =
            List.init (Array.length flds) (fun j ->
                emit_clone_value env s clone_bound flds.(j)
                  (proj payload_place (Seed_mir.ConstantIndex j)))
          in
          emit s
            (Seed_mir.Assign
               ( place_of dest,
                 Seed_mir.Aggregate
                   (Seed_mir.EnumCtor (tid, Ids.Variant_index.make i), ops) )))
  | Some _ | None ->
      (* no nominal shape to recurse into: the whole value clones as
         one component (tuple/array/scalar/String/LangItem receivers) *)
      emit s (Seed_mir.Assign (place_of dest, Seed_mir.Use (emit_clone_value env s clone_bound ty place)))

(* ── Derived-body cache (audit P0-12 cost bound) ───────────────────
   The checker's derived channel mints a FRESH signature (and callable
   id) per accepted call site, so state.derived_sigs holds many
   structurally identical templates ("derived::MirProgram::clone" etc.
   48 times in the full closure).  The synthesized body depends only on
   the derivation identity — operation, receiver/param/return types and
   the Clone where-clauses — never on the callable id, so one body is
   synthesized per identity and every duplicate signature reuses it
   under its own callable identity (the same body the first synthesis
   emitted; internal callee ids are stable across duplicates because
   they resolve through the same env tables).

   The cache is cleared once per closure by reset_derived_state (called
   from the driver's lower_closure): Type_ids are only stable within one
   compilation env. *)
let synthesized_bodies : (string, Seed_mir.function_) Hashtbl.t =
  Hashtbl.create 256

(* Perf kill-switch (default: cache ON): lets a run measure the
   cache-free synthesis cost for the same binary. *)
let derive_cache_enabled =
  match Sys.getenv_opt "TANGERINE_NO_DERIVE_CACHE" with
  | Some "1" -> false
  | _ -> true

let body_key (ts : Typecheck.typed_signature) : string =
  let b = Buffer.create 256 in
  let add_ty (t : Type_repr.t) =
    Buffer.add_char b '\000';
    Buffer.add_string b (Seed_mir.print_type t)
  in
  Buffer.add_string b ts.Typecheck.ts_name;
  Buffer.add_char b '\001';
  Array.iter
    (fun (p : Type_repr.param_type) ->
      Buffer.add_string b (Access_effect.to_string p.Type_repr.pt_convention);
      Buffer.add_char b ' ';
      add_ty p.Type_repr.pt_type)
    ts.Typecheck.ts_params;
  add_ty ts.Typecheck.ts_return;
  List.iter
    (fun (wt, bounds) ->
      add_ty wt;
      List.iter
        (fun (name, args) ->
          Buffer.add_char b '\002';
          Buffer.add_string b name;
          Array.iter add_ty args)
        bounds)
    ts.Typecheck.ts_where;
  Buffer.contents b

let reset_derived_state () =
  Hashtbl.reset synthesized_bodies;
  Hashtbl.reset aux_to_string_sigs;
  pending_derived := []

(* synthesize ────────────────────────────────────────────────────
   One derived signature -> the Seed MIR function carrying the SAME
   callable identity the call sites reference. *)

let rec synthesize (env : Typecheck.env) (ts : Typecheck.typed_signature) :
    Seed_mir.function_ =
  let instance_of () : Instance_id.t =
    Instance_id.make ~callable:ts.Typecheck.ts_callable
      ~type_args:
        (Array.of_list
           (List.map (fun (_, pid) -> Type_repr.Type_param pid)
              ts.Typecheck.ts_params_decl))
  in
  match
    if derive_cache_enabled then Hashtbl.find_opt synthesized_bodies (body_key ts)
    else None
  with
  | Some cached ->
      if derive_debug then
        Printf.eprintf "[derive-dbg] reuse %s (cached)\n" ts.Typecheck.ts_name;
      {
        cached with
        Seed_mir.name = ts.Typecheck.ts_name;
        instance = instance_of ();
        params = ts.Typecheck.ts_params;
      }
  | None -> synthesize_fresh env ts instance_of

and synthesize_fresh (env : Typecheck.env) (ts : Typecheck.typed_signature)
    (instance_of : unit -> Instance_id.t) : Seed_mir.function_ =
  let dbg_t0 = Unix.gettimeofday () in
  current_derived_sig := ts.Typecheck.ts_name;
  if derive_debug then begin
    dbg_render := 0;
    Printf.eprintf "[derive-dbg] begin %s\n" ts.Typecheck.ts_name
  end;
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
   (* audit P0-4: the rigid carriers whose Clone bound the minted
      signature's where-clauses recorded — the receivers whose clone
      the checker discharged through a declared `T: Clone` bound.  A
      clone body that reaches one of these carriers without the bound
      is an internal error (the mint refused it). *)
   let clone_bound_params =
     List.filter_map
       (fun (wt, bs) ->
         match wt with
         | Type_repr.Type_param pid ->
             if List.exists (fun (b, _) -> b = "Clone") bs then Some pid else None
         | _ -> None)
       ts.Typecheck.ts_where
   in
   (match op with
    | "clone" ->
        (* the semantic receiver clone: nominal receivers clone per
           their def shape, every component through its own Clone (the
           checker's obligation authority admitted this receiver; a
           component that cannot discharge is an internal error) *)
        emit_clone_receiver env s clone_bound_params 0 self_ty (place_of 1);
        close_with s Seed_mir.Ret
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
  let dbg_stmts =
    Array.fold_left
      (fun acc (b : Seed_mir.block) -> acc + List.length b.Seed_mir.statements)
      0 blocks
  in
  if derive_debug then begin
    Printf.eprintf
      "[derive-dbg] %s: locals=%d blocks=%d stmts=%d elapsed=%.2fs\n"
      ts.Typecheck.ts_name s.next_local (Array.length blocks) dbg_stmts
      (Unix.gettimeofday () -. dbg_t0)
  end;
  let locals =
    if Array.length s.locals = s.next_local then s.locals
    else Array.sub s.locals 0 s.next_local
  in
  let f =
    {
      Seed_mir.name = ts.Typecheck.ts_name;
      instance = instance_of ();
      params = ts.Typecheck.ts_params;
      locals;
      blocks;
      entry = 0;
    }
  in
  Hashtbl.replace synthesized_bodies (body_key ts) f;
  f
