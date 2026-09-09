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
     (g) a conditional move joins the chain to Maybe_live and a
         later use of the chain rejects                        -> reject
         (canary_neg_resource_partial_conditional); consuming on
         BOTH paths joins to Consumed and the sibling stays live -> ok
         (canary_pos_resource_partial_both_paths);
     (h) assignment over a LIVE owning field runs the masked
         whole-root drop: the sibling DIRECT fields are destroyed
         (marked Consumed) — the sibling read then rejects; the
         depth-1 over a partially-moved root is rejected; the nested
         exact-place replacement over a partially-moved root is ok;
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

(* ── (h) assignment over a live owning field — the masked drop ────── *)
(* (h1) the fully-live depth-1 assign is the whole-root masked drop:
   the sibling DIRECT fields are destroyed (marked Consumed) — the
   sibling read then rejects like a moved-out field. *)
let test_assign_over_live_sibling_destroyed () =
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
          Seed_mir.Ret;
      |]
  in
  check "h1: assign over a live owning field marks the sibling destroyed"
    (n_errors errs = 1 && any errs "read of moved-out owned field [1]")

(* (h2) the depth-1 assign over a live owning field of a
   PARTIALLY-MOVED root rejects (the masked whole-root drop is not
   representable). *)
let test_assign_over_live_partial_root () =
  let locals = [| ss_ty; str_ty |] in
  let errs =
    check_prog locals ss_ty [||]
      [|
        blk 0
          [
            Seed_mir.Assign (place 2 [], Seed_mir.Use (Seed_mir.Move (place 1 [ ci 0 ])));
            Seed_mir.Assign
              (place 1 [ ci 1 ], Seed_mir.Use (Seed_mir.Constant (str_const "z")));
          ]
          Seed_mir.Ret;
      |]
  in
  check "h2: assign over a live owning field of a partial root rejects"
    (n_errors errs = 1
    && any errs "root is partially moved out (the masked drop-before-store is not representable)")

(* (h3) the NESTED assign over a live owning chain is the exact-place
   replacement: it is allowed even when the root has other dead chains. *)
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
          Seed_mir.Ret;
      |]
  in
  check "h3: nested exact-place assign over a live chain is clean"
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
  test_conditional_join_maybe ();
  test_conditional_both_paths ();
  test_assign_over_live_sibling_destroyed ();
  test_assign_over_live_partial_root ();
  test_nested_assign_exact_place ();
  test_whole_consume_after_field_move ();
  test_struct_field_chains ();
  test_enum_payload_chains ();
  test_loop_after_partial_move ();
  if !failures = 0 then begin
    Printf.printf "tg_placechain: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_placechain: %d FAILURE(S)\n" !failures;
    exit 1
  end
