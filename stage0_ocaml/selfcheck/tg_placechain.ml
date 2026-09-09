(* tg_placechain.ml — projected-place (chain) ownership parity self-check.

   Mirrors the native compiler's partial-move canaries
   (tests/canary{,_neg}/canary_{pos,neg}_resource_partial_*.tg) at the
   Stage0 level: hand-constructed Seed MIR functions (same construction
   style as tg_mono.ml / tg_vmsem.ml) run through the CFG resource
   dataflow (Resource_check.cfg_check_program) and are asserted to
   accept / reject exactly like the native resource_check.tg lattice:

     (a) move the first field, then read the sibling           -> ok
         (canary_pos_resource_partial_extract);
     (b) whole-value use after a field move                    -> reject
         (canary_neg_resource_partial_whole_use);
     (c) double field move                                     -> reject
         (canary_neg_resource_partial_double_consume);
     (d) re-init the moved-out field, then whole use           -> ok
         (canary_pos_resource_partial_reassign); the whole-root
         move -> re-assign -> whole-use flow is also ok
         (canary_pos_resource_move_then_reassign);
     (e) deinit the root with a moved-out field                -> ok
         (the masked drop);
     (f) a consuming move through a dynamic index              -> reject
         with the element-state rule (canary_neg_resource_index);
         a CONSTANT index over a fixed array tracks the single
         element, siblings stay live (canary_pos_resource_partial_index);
         the ownership-safe container take call (Vec pop/remove,
         Map remove — the inout intrinsic surface) extracts the owned
         element cleanly with no per-index row (the take-style
         positives canary_pos_resource_array_take / vec_remove /
         map_remove); a boundary consume rejected by the element-state
         rule is never healed by a later root store (the Maybe_live
         commit rejects the store itself);
     (g) a conditional move joins the chain to Maybe_live and a
         later use of the chain rejects                        -> reject
         (canary_neg_resource_partial_conditional); consuming on
         BOTH paths joins to Consumed and the sibling stays live -> ok
         (canary_pos_resource_partial_both_paths);
      (h) assignment over a live owning chain runs the EXACT-place
          replacement: the old value of the target chain itself is
          destroyed (masked to its own consumed extensions) and the
          sibling chains stay live and usable — the depth-1 field, the
          nested chain, the tuple / fixed-array element and the enum
          payload position all follow the same rule (the canaries
          canary_pos_replace_live_string_field_preserves_sibling /
          replace_nested_owned_field / replace_tuple_owned_element /
          replace_fixed_array_constant_element /
          replace_enum_payload_field / replace_rhs_reads_sibling /
          replace_rhs_moves_sibling / replace_live_field_drops_old_exactly_once);
          the same-chain RHS overlaps (self / extension) reject
          (replace_same_field_from_itself_rejected_or_staged_correctly —
          the rejection arm) and a chain under a consumed proper prefix
          rejects; the whole-root replace over a moved-out child is the
          one remaining masked whole-value form (allowed);
     (i) a whole-root consume of a partially-moved root          -> reject
         (the whole-value boundary gate);
     (j) Field chains resolve through program.types (semantic
         FieldIds) and enum payload chains through Downcast ids;
     (k) a loop after a partial move keeps the chain state at the
         fixpoint and accepts the sibling reads
         (canary_pos_cfg_loop_after_partial_move).

   Tuple / fixed-array roots carry the positional ConstantIndex chain
   keys; struct / enum roots carry the semantic Field / Downcast keys
   with the def table present.

   Prints PASS/FAIL per check and a final ALL CHAIN-PARITY PASS line. *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

(* Substring test (same as tg_vmsem's). *)
let contains (haystack : string) (needle : string) : bool =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else begin
    let rec go i =
      i + n <= h && (String.sub haystack i n = needle || go (i + 1))
    in
    go 0
  end

(* ── construction helpers ─────────────────────────────────────────── *)

let int_ty = Type_repr.Int Type_repr.Int
let str_ty = Type_repr.String
let pair_ty = Type_repr.Tuple [| str_ty; int_ty |]           (* S { a: String; b: Int } *)
let ss_ty = Type_repr.Tuple [| str_ty; str_ty |]             (* two owning fields *)
let arr3_ty = Type_repr.Fixed_array (str_ty, 3)             (* [String; 3] *)
let nested_ty = Type_repr.Tuple [| Type_repr.Tuple [| str_ty; str_ty |]; int_ty |]

let ci i = Seed_mir.ConstantIndex i
let fid i = Seed_mir.Field (Ids.Field_id.make i)
let vid i = Seed_mir.Downcast (Ids.Variant_id.make i)

let place (l : int) (projs : Seed_mir.projection list) : Seed_mir.place =
  { Seed_mir.root = Seed_mir.Local l; projections = projs }

let str_const (s : string) : Seed_mir.constant = Seed_mir.String s

let let_param (ty : Type_repr.t) : Type_repr.param_type =
  { Type_repr.pt_convention = Access_effect.Let; pt_type = ty }

let inst (callable : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:[||]

let blk (id : int) (statements : Seed_mir.statement list)
    (terminator : Seed_mir.terminator) : Seed_mir.block =
  { Seed_mir.id; statements; terminator }

let mk_fn (locals : Type_repr.t array) (param_ty : Type_repr.t) (blocks : Seed_mir.block array)
    (entry : int) : Seed_mir.function_ =
  {
    Seed_mir.name = "parity_fn";
    instance = inst 7000;
    params = [| let_param param_ty |];
    locals = Array.append [| int_ty |] locals;
    blocks;
    entry;
  }

let check_prog (locals : Type_repr.t array) (param_ty : Type_repr.t)
    (types : Seed_mir.type_def array) (blocks : Seed_mir.block array) : string list =
  let fn = mk_fn locals param_ty blocks 0 in
  Resource_check.cfg_check_program
    { Seed_mir.functions = [| fn |]; statics = [||]; types }

let n_errors (errs : string list) : int = List.length errs

let any (errs : string list) (needle : string) : bool =
  List.exists (fun e -> contains e needle) errs

(* ── (a) move first field + sibling read — ok ───────────────────────
   canary_pos_resource_partial_extract: `let a = s.a` moves the a field
   out while s.b stays live; reading the sibling is fine. *)
let test_extract_sibling_read () =
  let locals = [| pair_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 2 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "a: move first field + sibling read is clean"
    (n_errors errs = 0);
  if n_errors errs <> 0 then
    List.iter (fun e -> Printf.printf "    unexpected: %s\n" e) errs

(* ── (b) whole-value use after a field move — reject ────────────────
   canary_neg_resource_partial_whole_use. *)
let test_whole_use_after_field_move () =
  let locals = [| pair_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "b: whole-value use after a field move rejects"
    (n_errors errs = 1 && any errs "cannot use owned local as a whole")

(* ── (c) double field move — reject ─────────────────────────────────
   canary_neg_resource_partial_double_consume. *)
let test_double_field_move () =
  let locals = [| pair_ty; str_ty; str_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "c: double field move rejects" (n_errors errs = 1 && any errs "double-move of owned field")

(* ── (d) re-init then whole use — ok ────────────────────────────────
   canary_pos_resource_partial_reassign: the store re-lives the
   moved-out field (the deviation row dies), so a later whole-value use
   is clean again.  The whole-root move -> re-assign -> whole-use flow
   (canary_pos_resource_move_then_reassign) is clean too. *)
let test_reinit_field_then_whole_use () =
  let locals = [| pair_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Constant (str_const "x")));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 2 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "d: field re-init then whole use is clean" (n_errors errs = 0)

let test_reinit_root_then_whole_use () =
  let locals = [| pair_ty; str_ty; int_ty |] in
  let agg =
    Seed_mir.Aggregate
      ( Seed_mir.TupleAgg,
        [ Seed_mir.Constant (str_const "y");
          Seed_mir.Constant
            (Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true 3L)) ] )
  in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [])));
            Seed_mir.Assign (place 1 [], agg);
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "d2: whole move -> whole re-init -> whole use is clean" (n_errors errs = 0)

(* ── (e) deinit with a moved field — ok ─────────────────────────────
   The whole-root destroy is the MASKED drop: the dead chain's storage
   is skipped. *)
let test_deinit_with_moved_field () =
  let locals = [| pair_ty; str_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [ Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          (Seed_mir.Deinit (place 1 [], 1, None));
        blk 1 [] Seed_mir.Ret;
      |]
  in
  check "e: deinit of the root with a moved-out field is clean" (n_errors errs = 0)

(* ── (f) dynamic index consume — reject (element-state rule) ────────
   canary_neg_resource_index / the Vec[i] consuming move; the constant
   index over a fixed array tracks the single element
   (canary_pos_resource_partial_index). *)
let test_dynamic_index_consume () =
  let locals = [| arr3_ty; int_ty; str_ty |] in
  let errs =
    check_prog locals arr3_ty [||]
      [|
        blk 0
          [ Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ Seed_mir.Index 2 ]))) ]
          Seed_mir.Ret;
      |]
  in
  check "f: dynamic-index consuming move rejects with the element-state rule"
    (n_errors errs = 1 && any errs "element-level state is not tracked")

let test_const_index_array_extract () =
  let locals = [| arr3_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals arr3_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "f2: constant-index fixed-array extract + sibling read is clean"
    (n_errors errs = 0)

(* ── (f3) the ownership-safe container take surface — the take-style
   POSITIVE (canary_pos_resource_array_take / vec_remove / map_remove at
   the MIR level): an inout container operation (Vec pop/remove(index),
   Map remove(key) — the __intrinsic_array_pop/remove /
   __intrinsic_map_remove family) reads the container ROOT by place and
   returns the owned element into an ordinary owned local.  The checker
   creates NO per-index chain row and rejects nothing: the container
   stays Live (a whole-value read) and the extracted element is dropped
   exactly once at its own site.  The owning container root is the
   unresolvable Named type (the engine's conservative Owned answer). *)
let vec_root_ty = Type_repr.Named (Ids.Type_id.make 200, [||])

let test_take_style_container_call () =
  let locals = [| vec_root_ty; str_ty |] in
  let errs =
    check_prog locals vec_root_ty [||]
      [|
        blk 0
          []
          (Seed_mir.Call
             ( place 2 [],
               Seed_mir.User (inst 7001),
               [| { Seed_mir.effect_ = Access_effect.Modify; value = Seed_mir.Copy (place 1 []) } |],
               1,
               None ));
        blk 1 [] (Seed_mir.Drop (place 2 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "f3: an ownership-safe container take call extracts the owned element cleanly"
    (n_errors errs = 0)

(* ── (f4) the boundary consume is an unconditional rule rejection: the
   element-state error fires AT the dynamic-index consuming move and a
   later whole-root store cannot erase it — the store re-lives the root
   (the whole-store commit) but the rejection stands (the native
   whole-boundary commit + rule error mirror this). *)
let test_boundary_consume_then_relive () =
  let locals = [| arr3_ty; str_ty |] in
  let agg =
    Seed_mir.Aggregate
      ( Seed_mir.ArrayAgg,
        [ Seed_mir.Constant (str_const "a");
          Seed_mir.Constant (str_const "b");
          Seed_mir.Constant (str_const "c") ] )
  in
  let errs =
    check_prog locals arr3_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ Seed_mir.Index 1 ])));
            Seed_mir.Assign (place 1 [], agg);
          ]
          Seed_mir.Ret;
      |]
  in
  check "f4: a boundary consume's rule rejection is unconditional (a later root store cannot heal it)"
    (n_errors errs = 1 && any errs "element-level state is not tracked")

(* ── (g) conditional move: join to Maybe_live ───────────────────────
   canary_neg_resource_partial_conditional: the chain consumed on one
   path only joins to Maybe_live; a later use of the chain rejects.
   Consuming on BOTH paths joins to Consumed and the sibling stays
   live (canary_pos_resource_partial_both_paths). *)
let test_conditional_join_maybe () =
  let locals = [| pair_ty; int_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0 [] (Seed_mir.SwitchInt (Seed_mir.Copy (place 2 []), [ (0L, 1) ], 2));
        blk 1
          [ Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          (Seed_mir.Goto 3);
        blk 2 [] (Seed_mir.Goto 3);
        blk 3
          [ Seed_mir.Assign (place 4 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 0 ]))) ]
          Seed_mir.Ret;
      |]
  in
  check "g: conditional move joins to Maybe_live; the chain use rejects"
    (n_errors errs = 1 && any errs "owned field [0] may be consumed on one path")

let test_conditional_both_paths () =
  let locals = [| pair_ty; int_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0 [] (Seed_mir.SwitchInt (Seed_mir.Copy (place 2 []), [ (0L, 1) ], 2));
        blk 1
          [ Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          (Seed_mir.Goto 3);
        blk 2
          [ Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          (Seed_mir.Goto 3);
        blk 3
          [ Seed_mir.Assign (place 4 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ]))) ]
          Seed_mir.Ret;
      |]
  in
  check "g2: both-paths consume joins to Consumed; the sibling stays live"
    (n_errors errs = 0)

(* ── (h) assignment over a live owning chain — the EXACT-PLACE
   replacement (audit item: the canonical replacement model) ────────── *)
(* (h1) replace_live_string_field_preserves_sibling: assigning a live
   owning field destroys ONLY the field's old value — the sibling stays
   live, readable afterwards and drops exactly once at the scope exit. *)
let test_replace_live_field_sibling_live () =
  let locals = [| ss_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Constant (str_const "x")));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 0 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h1: replace of a live owning field keeps the sibling live and readable"
    (n_errors errs = 0)

(* (h2) replace_live_string_field_preserves_sibling over a PARTIALLY-MOVED
   root: the depth-1 assign is the exact-place replacement — it is
   allowed over a root that carries other consumed chains (the sibling
   that was moved out stays dead, the replaced chain re-lives). *)
let test_replace_live_field_partial_root () =
  let locals = [| ss_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign
              (place 1 [ ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "z")));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 2 [], 2, None));
        blk 2 [] (Seed_mir.Drop (place 1 [], 3, None));
        blk 3 [] Seed_mir.Ret;
      |]
  in
  check "h2: exact-place replace of a live owning field over a partial root is clean"
    (n_errors errs = 0)

(* (h3) replace_nested_owned_field over a root with a consumed sibling
   chain — the exact-place replacement (the nested form) is clean. *)
let test_nested_assign_exact_place () =
  let locals = [| nested_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals nested_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0; ci 0 ])));
            Seed_mir.Assign
              (place 1 [ ci 0; ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "q")));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 0; ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h3: nested exact-place assign over a live chain is clean"
    (n_errors errs = 0)

(* (h4) replace_tuple_owned_element / replace_fixed_array_constant_element:
   a live owning element of a tuple / fixed-array root is replaced
   exactly — the other elements stay live and readable. *)
let test_replace_tuple_element () =
  let locals = [| ss_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "y")));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h4: replace of a live owning tuple element keeps the sibling live"
    (n_errors errs = 0)

let test_replace_fixed_array_element () =
  let locals = [| arr3_ty; int_ty |] in
  let errs =
    check_prog locals arr3_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "x")));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 2 ])));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h5: replace of a live owning fixed-array element keeps the others live"
    (n_errors errs = 0)

(* (h6) replace_live_field_drops_old_exactly_once: after the exact
   replacement the scope exit's whole-root drop is clean — the replaced
   value (and the untouched sibling) drop exactly once, no double-drop. *)
let test_replace_then_whole_drop () =
  let locals = [| ss_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Constant (str_const "x")));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h6: replace of a live owning field then the whole-root drop is clean"
    (n_errors errs = 0)

(* (h7) replace_rhs_reads_sibling: the RHS READING a disjoint sibling
   chain of an exact-place replacement is accepted (the exact drop never
   touches the sibling's storage). *)
let test_replace_rhs_reads_sibling () =
  let locals = [| ss_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 0 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h7: exact-place replace with a sibling READ RHS is clean"
    (n_errors errs = 0)

(* (h8) replace_rhs_moves_sibling: the RHS MOVING a disjoint sibling
   chain into the replaced field is accepted (canary
   canary_pos_replace_rhs_moves_sibling): the old target value drops at
   the replacement, the sibling's value moves into the target and drops
   at the scope exit, every other sibling stays live. *)
let test_replace_rhs_moves_sibling () =
  let locals = [| ss_ty; int_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ ci 1 ], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ])));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 1 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h8: exact-place replace with a sibling MOVE RHS is clean"
    (n_errors errs = 0)

(* (h9) replace_same_field_from_itself / a sub-value of the replaced
   field: the RHS operand OVERLAPS the target chain (equal or an
   extension of it) — the exact drop would destroy the operand's source
   before it materializes — rejected (canary-neg rows). *)
let test_replace_self_rhs_rejected () =
  let locals = [| ss_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [ Seed_mir.Assign (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          Seed_mir.Ret;
      |]
  in
  check "h9: replace of a field from ITSELF rejects (overlap)"
    (n_errors errs = 1 && any errs "replaced value's own storage")

let test_replace_extension_rhs_rejected () =
  let locals = [| nested_ty |] in
  let errs =
    check_prog locals nested_ty [||]
      [|
        blk 0
          [ Seed_mir.Assign (place 1 [ ci 0 ], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0; ci 0 ]))) ]
          Seed_mir.Ret;
      |]
  in
  check "h10: replace of a field from its own sub-value rejects (overlap)"
    (n_errors errs = 1 && any errs "replaced value's own storage")

(* (h11) a chain UNDER a CONSUMED proper prefix rejects the assignment
   (the write would go through the moved-out containing value). *)
let test_replace_under_consumed_prefix_rejected () =
  let locals = [| nested_ty; str_ty |] in
  let errs =
    check_prog locals nested_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign
              (place 1 [ ci 0; ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "z")));
          ]
          Seed_mir.Ret;
      |]
  in
  check "h11: assign into a field under a consumed prefix rejects"
    (n_errors errs = 1 && any errs "containing value was moved out")

(* (h12) replace_enum_payload_field: the live owning payload position of
   an enum value is replaced exactly; the sibling payload position stays
   live.  (Registered with the enum section at the file end — the enum
   type-def fixtures live there.) *)

(* (h13) the whole-root replacement of a root that carries a consumed
   child is allowed — the masked whole-root drop destroys only the LIVE
   children; the dead child's storage is skipped (the whole-root replace
   is the one remaining whole-value masked-drop form). *)
let test_whole_root_replace_with_moved_child () =
  let locals = [| ss_ty; str_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign
              (place 1 [],
               Seed_mir.Aggregate
                 ( Seed_mir.TupleAgg,
                   [
                     Seed_mir.Constant (str_const "a");
                     Seed_mir.Constant (str_const "b");
                   ] ));
          ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.Drop (place 2 [], 2, None));
        blk 2 [] Seed_mir.Ret;
      |]
  in
  check "h13: whole-root replace over a moved-out child is clean"
    (n_errors errs = 0)

(* ── (i) whole-root consume of a partially-moved root — reject ────── *)
let test_whole_consume_after_field_move () =
  let locals = [| pair_ty; str_ty; pair_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "i: whole-root consume after a field move rejects"
    (n_errors errs = 1 && any errs "cannot consume owned local as a whole")

(* ── (j) semantic Field chains through program.types ────────────────
   The struct root carries Field projections resolved through the
   StructDef (semantic FieldIds); the enum payload chain passes through
   the Downcast (semantic VariantId). *)
let struct_tid = Ids.Type_id.make 100
let enum_tid = Ids.Type_id.make 101
let field_a = Ids.Field_id.make 10
let field_b = Ids.Field_id.make 11
let var_payload = Ids.Variant_id.make 20

let struct_def : Seed_mir.type_def =
  Seed_mir.StructDef
    {
      sd_id = struct_tid;
      sd_fields =
        [
          { fd_id = field_a; fd_index = Ids.Field_index.make 0; fd_ty = str_ty };
          { fd_id = field_b; fd_index = Ids.Field_index.make 1; fd_ty = int_ty };
        ];
    }

let enum_def : Seed_mir.type_def =
  Seed_mir.EnumDef
    {
      ed_id = enum_tid;
      ed_variants =
        [
          {
            vd_id = var_payload;
            vd_index = Ids.Variant_index.make 0;
            vd_payload = Type_repr.Tuple [| str_ty; int_ty |];
          };
        ];
    }

let test_struct_field_chains () =
  let root_ty = Type_repr.Named (struct_tid, [||]) in
  let locals = [| root_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals root_ty [| struct_def |]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ fid 10 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Read (place 1 [ fid 11 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "j: semantic Field chain extract + sibling read is clean"
    (n_errors errs = 0);
  (* a second move of the same Field chain is the double move *)
  let errs2 =
    check_prog [| root_ty; str_ty; str_ty |] root_ty [| struct_def |]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ fid 10 ])));
            Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ fid 10 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "j2: double move of the semantic Field chain rejects"
    (n_errors errs2 = 1 && any errs2 "double-move of owned field")

let test_enum_payload_chains () =
  let root_ty = Type_repr.Named (enum_tid, [||]) in
  let locals = [| root_ty; str_ty; str_ty |] in
  let errs =
    check_prog locals root_ty [| enum_def |]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ vid 20; ci 0 ])));
            Seed_mir.Assign
              (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ vid 20; ci 0 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "k: double move of the Downcast payload chain rejects"
    (n_errors errs = 1 && any errs "double-move of owned field")

(* ── (m) replace_enum_payload_field (registered with the enum
   fixtures): the live owning payload position of an enum value is
   replaced exactly; the sibling payload position stays live. *)
let test_replace_enum_payload_field () =
  let root_ty = Type_repr.Named (enum_tid, [||]) in
  let locals = [| root_ty; int_ty |] in
  let errs =
    check_prog locals root_ty [| enum_def |]
      [|
        blk 0
          [
            Seed_mir.Assign
              (place 1 [ vid 20; ci 0 ], Seed_mir.Use (Seed_mir.Constant (str_const "q")));
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Read (place 1 [ vid 20; ci 1 ])));
          ]
          Seed_mir.Ret;
      |]
  in
  check "m: replace of a live owning enum-payload field is clean"
    (n_errors errs = 0)

(* ── (l) a loop after a partial move keeps the chain at the fixpoint ─
   canary_pos_cfg_loop_after_partial_move. *)
let test_loop_after_partial_move () =
  let locals = [| pair_ty; int_ty; str_ty; int_ty |] in
  let errs =
    check_prog locals pair_ty [||]
      [|
        blk 0
          [ Seed_mir.Assign (place 3 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ]))) ]
          (Seed_mir.Goto 1);
        blk 1 [] (Seed_mir.SwitchInt (Seed_mir.Copy (place 2 []), [ (0L, 3) ], 2));
        blk 2
          [ Seed_mir.Assign (place 4 [], Seed_mir.Use (Seed_mir.Read (place 1 [ ci 1 ]))) ]
          (Seed_mir.Goto 1);
        blk 3 [] Seed_mir.Ret;
      |]
  in
  check "l: loop after a partial move converges; the sibling reads are clean"
    (n_errors errs = 0)

let () =
  test_extract_sibling_read ();
  test_whole_use_after_field_move ();
  test_double_field_move ();
  test_reinit_field_then_whole_use ();
  test_reinit_root_then_whole_use ();
  test_deinit_with_moved_field ();
  test_dynamic_index_consume ();
  test_const_index_array_extract ();
  test_take_style_container_call ();
  test_boundary_consume_then_relive ();
  test_conditional_join_maybe ();
  test_conditional_both_paths ();
  test_replace_live_field_sibling_live ();
  test_replace_live_field_partial_root ();
  test_nested_assign_exact_place ();
  test_replace_tuple_element ();
  test_replace_fixed_array_element ();
  test_replace_then_whole_drop ();
  test_replace_rhs_reads_sibling ();
  test_replace_rhs_moves_sibling ();
  test_replace_self_rhs_rejected ();
  test_replace_extension_rhs_rejected ();
  test_replace_under_consumed_prefix_rejected ();
  test_whole_root_replace_with_moved_child ();
  test_whole_consume_after_field_move ();
  test_struct_field_chains ();
  test_enum_payload_chains ();
  test_replace_enum_payload_field ();
  test_loop_after_partial_move ();
  if !failures = 0 then begin
    Printf.printf "tg_placechain: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_placechain: %d FAILURE(S)\n" !failures;
    exit 1
  end
