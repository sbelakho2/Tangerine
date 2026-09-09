(* tg_type_props.ml — Type-property authority self-check (audit P0-2).

   The P0-2 property matrix and its pipeline consequences, proven
   directly against the authority modules (Type_properties, Lang_items,
   Drop_plan) and through the verifier/VM:

   (a) PROPERTY MATRIX — representation vs ownership (Type_properties
       with the LangItems record + a def resolver):
         Int                      copy/no-drop;
         Ptr[Int], PtrMut[Int]    copy/no-drop  (the raw-pointer class);
         (Int, Int)               copy/no-drop;
         FnPtr (Int) -> Int       copy/no-drop;
         String                   no-copy/needs-drop;
         Vec[Int], Vec[String]    no-copy/needs-drop (owning LangItems);
         Map[Int,Int], Set[Int]   no-copy/needs-drop;
         Box[Int]                 no-copy/needs-drop;
         (Int, String)            no-copy/needs-drop;
         [String; 4096]           no-copy/needs-drop.
       The owning answers are the LangItems DIRECT properties — the
       field-less container defs are never faked as empty tuples.
   (b) LANGITEMS — the record carries the identities (of_types builder),
       the classification is {copy=false,drop=true} for the owning
       handles and {copy=true,drop=false} for Ptr/PtrMut; no numeric
       builtin-id knowledge is consulted by the engine.
   (c) CANONICAL-INSTANCE CACHE — the structural key never conflates
       Wrapper[Int] with Wrapper[String] (materialized defs), and two
       mentions of one generic nominal at different substitutions never
       share one entry.
   (d) DROP PLANS — a struct holding [String; 1_000_000] has the
       CONSTANT-SIZE plan Fields [ { f; Repeat { count = 1_000_000;
       element = DropLeaf } } ] (no materialization cutoff); the
       lattice-key expansion stays bounded (owning_paths); smaller
       arrays (4096) still expand per-index lattice keys.
   (e) VERIFIER — a raw-MIR Copy of Vec[Int] is rejected ("copy of a
       non-Copy"), the Move of the same value is accepted, a second
       Move is rejected ("second consume"), and a Drop of a moved local
       is rejected ("drop of previously moved").
   (f) VM — drop-after-move is NOT a double destruction (the moved slot
       drops as a no-op; a second drop of the DROPPED slot traps), and
       the plan-driven typed drop walks plan_node (struct def with a
       String field and a Vec field, enum defs with payload variants).
   (g) RESOURCE-CHECK CONSUMER (audit item 3) — the CFG resource
       dataflow (Resource_check.cfg_check_program) answers its
       owned-root and owning-chain queries through this SAME engine
       (its resolver is the program's def table + the LangItems
       overlay): an all-Copy struct def root is untracked (moves are
       copies); an owning enum (String payload) reached as a
       struct-field chain answers through its def — a double move of
       the chain is a double-move finding; a def-less Ptr[Int] root
       answers Copy under the LangItems overlay and conservative-owned
       without it.

   Prints PASS/FAIL per check and a final ALL PASS line. *)

let failures = ref 0

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; incr failures) fmt
let pass fmt = Printf.ksprintf (fun s -> Printf.printf "PASS: %s\n" s) fmt

let contains_sub (haystack : string) (needle : string) : bool =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else begin
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  end

(* ── small type/operand helpers (the tg_vmsem conventions) ────────── *)

let i64 = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String
let vec_tid = Ids.Type_id.make 0
let map_tid = Ids.Type_id.make 1
let set_tid = Ids.Type_id.make 2
let ptr_tid = Ids.Type_id.make 5
let ptrmut_tid = Ids.Type_id.make 6

let vec_ty (t : Type_repr.t) : Type_repr.t = Type_repr.Named (vec_tid, [| t |])
let map_ty (k : Type_repr.t) (v : Type_repr.t) : Type_repr.t = Type_repr.Named (map_tid, [| k; v |])
let set_ty (t : Type_repr.t) : Type_repr.t = Type_repr.Named (set_tid, [| t |])
let ptr_ty (t : Type_repr.t) : Type_repr.t = Type_repr.Named (ptr_tid, [| t |])

let int_value (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

let int_op (n : int) : Seed_mir.operand = Seed_mir.Constant (int_value (Int64.of_int n))
let str_op (s : string) : Seed_mir.operand = Seed_mir.Constant (Seed_mir.String s)

let instance (callable : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:[||]

let entry_of (prog : Seed_mir.program) : Instance_id.t =
  prog.Seed_mir.functions.(0).Seed_mir.instance

let fn1 (locals : Type_repr.t array) (statements : Seed_mir.statement list)
    (terminator : Seed_mir.terminator) : Seed_mir.program =
  {
    Seed_mir.functions =
      [|
        {
          Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals;
          blocks = [| { id = 0; statements; terminator } |];
          entry = 0;
        };
      |];
    statics = [||];
    types = [||];
  }

let fn_types (locals : Type_repr.t array) (types : Seed_mir.type_def array)
    (blocks : Seed_mir.block array) : Seed_mir.program =
  {
    Seed_mir.functions =
      [|
        {
          Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals;
          blocks;
          entry = 0;
        };
      |];
    statics = [||];
    types;
  }

(* ── (a) the property matrix ──────────────────────────────────────── *)

let no_def_resolver : Type_properties.def_resolver =
  Type_properties.structural_resolver (fun _tid -> None)

let matrix_resolver (li : Lang_items.t) : Type_properties.def_resolver =
  Type_properties.with_lang_items (Some li) no_def_resolver

let check_prop (name : string) (ty : Type_repr.t) ~(copy : bool) ~(drop : bool) : unit =
  let p = Type_properties.of_type_uncached (Some (matrix_resolver Lang_items.seed_defaults)) ty in
  let ok = p.Type_properties.is_copy = copy && p.Type_properties.needs_drop = drop in
  if ok then pass "%s (copy=%b needs_drop=%b)" name copy drop
  else
    fail "%s: got copy=%b needs_drop=%b (expected copy=%b needs_drop=%b)" name
      p.Type_properties.is_copy p.Type_properties.needs_drop copy drop

let check_prop_li (name : string) (li : Lang_items.t) (ty : Type_repr.t)
    ~(copy : bool) ~(drop : bool) : unit =
  let p = Type_properties.of_type_uncached (Some (matrix_resolver li)) ty in
  let ok = p.Type_properties.is_copy = copy && p.Type_properties.needs_drop = drop in
  if ok then pass "%s (copy=%b needs_drop=%b)" name copy drop
  else
    fail "%s: got copy=%b needs_drop=%b (expected copy=%b needs_drop=%b)" name
      p.Type_properties.is_copy p.Type_properties.needs_drop copy drop

let check_property_matrix () =
  (* Immediate: copy, no drop *)
  check_prop "Int is Copy / no drop" i64 ~copy:true ~drop:false;
  check_prop "unit is Copy / no drop" Type_repr.Unit ~copy:true ~drop:false;
  check_prop "(Int, Int) is Copy / no drop" (Type_repr.Tuple [| i64; i64 |]) ~copy:true ~drop:false;
  (* FnPtr (Function with a non-Never return): Immediate *)
  check_prop
    "FnPtr (Int) -> Int is Copy / no drop"
    (Type_repr.Function ([| { Type_repr.pt_convention = Access_effect.Let; pt_type = i64 } |], i64))
    ~copy:true ~drop:false;
  (* the raw-pointer LangItem class: Ptr/PtrMut are Copy address handles *)
  check_prop "Ptr[Int] is Copy / no drop" (ptr_ty i64) ~copy:true ~drop:false;
  check_prop "PtrMut[Int] is Copy / no drop"
    (Type_repr.Named (ptrmut_tid, [| i64 |]))
    ~copy:true ~drop:false;
  check_prop "*Int (raw) is Copy / no drop"
    (Type_repr.Raw_ptr (Type_repr.Immutable, i64))
    ~copy:true ~drop:false;
  (* the OWNED LangItems: move + clone, never bit-Copy *)
  check_prop "String is owned / needs drop" string_ty ~copy:false ~drop:true;
  check_prop "Vec[Int] is owned / needs drop" (vec_ty i64) ~copy:false ~drop:true;
  check_prop "Vec[String] is owned / needs drop" (vec_ty string_ty) ~copy:false ~drop:true;
  check_prop "Map[Int,Int] is owned / needs drop" (map_ty i64 i64) ~copy:false ~drop:true;
  check_prop "Set[Int] is owned / needs drop" (set_ty i64) ~copy:false ~drop:true;
  (* structural: elementwise *)
  check_prop "(Int, String) is not Copy / needs drop"
    (Type_repr.Tuple [| i64; string_ty |])
    ~copy:false ~drop:true;
  check_prop "[String; 4096] is not Copy / needs drop"
    (Type_repr.Fixed_array (string_ty, 4096))
    ~copy:false ~drop:true;
  check_prop "[Int; 100] is Copy / no drop"
    (Type_repr.Fixed_array (i64, 100))
    ~copy:true ~drop:false;
  check_prop "[Ptr[Int]; 8] is Copy / no drop"
    (Type_repr.Fixed_array (ptr_ty i64, 8))
    ~copy:true ~drop:false;
  (* the Box LangItem (per-compilation identity in the record) *)
  let li_box =
    { Lang_items.seed_defaults with box_ = Some (Ids.Type_id.make 200) }
  in
  check_prop_li "Box[Int] is owned / needs drop" li_box
    (Type_repr.Named (Ids.Type_id.make 200, [| i64 |]))
    ~copy:false ~drop:true;
  (* an owning answer is the DIRECT property — never an empty-tuple def
     shape: the resolver has NO def for Vec, yet Vec[Int] is owned *)
  (match
     Type_properties.of_type_uncached (Some (matrix_resolver Lang_items.seed_defaults))
       (vec_ty i64)
   with
   | p when p.Type_properties.needs_drop && not p.Type_properties.is_copy ->
       pass "owned LangItems answer direct properties (no def present, no empty-tuple shape)"
   | p ->
       fail "owned LangItems resolved through a fake shape: copy=%b needs_drop=%b"
         p.Type_properties.is_copy p.Type_properties.needs_drop)

(* ── (b) the LangItems record ─────────────────────────────────────── *)

let check_lang_items () =
  let box_p = Ids.Generic_param_id.make 1 in
  let table =
    [
      ("Int", i64);
      ("String", string_ty);
      ("Vec", Type_repr.Named (vec_tid, [| Type_repr.Type_param box_p |]));
      ("Array", Type_repr.Named (vec_tid, [| Type_repr.Type_param box_p |]));
      ("List", Type_repr.Named (vec_tid, [| Type_repr.Type_param box_p |]));
      ("Map", map_ty (Type_repr.Type_param box_p) (Type_repr.Type_param box_p));
      ("Set", set_ty (Type_repr.Type_param box_p));
      ("Option", Type_repr.Named (Ids.Type_id.make 3, [| Type_repr.Type_param box_p |]));
      ("Result", Type_repr.Named (Ids.Type_id.make 4, [| Type_repr.Type_param box_p |]));
      ("Ptr", Type_repr.Named (ptr_tid, [| Type_repr.Type_param box_p |]));
      ("PtrMut", Type_repr.Named (ptrmut_tid, [| Type_repr.Type_param box_p |]));
    ]
  in
  let li = Lang_items.of_types table in
  let ok =
    Lang_items.tid_eq li.Lang_items.vec vec_tid
    && Lang_items.tid_eq li.Lang_items.map map_tid
    && Lang_items.tid_eq li.Lang_items.set set_tid
    && Lang_items.tid_eq li.Lang_items.option (Ids.Type_id.make 3)
    && Lang_items.tid_eq li.Lang_items.result (Ids.Type_id.make 4)
    && Lang_items.tid_eq li.Lang_items.ptr ptr_tid
    && Lang_items.tid_eq li.Lang_items.ptr_mut ptrmut_tid
    && li.Lang_items.string = None
  in
  if ok then pass "of_types adopts the shared LangItem identities from the name table"
  else fail "of_types adoption mismatch";
  let class_ok =
    Lang_items.is_owning_handle li vec_tid
    && Lang_items.is_owning_handle li map_tid
    && Lang_items.is_owning_handle li set_tid
    && Lang_items.is_raw_pointer li ptr_tid
    && Lang_items.is_raw_pointer li ptrmut_tid
    && not (Lang_items.is_owning_handle li (Ids.Type_id.make 3))
    && not (Lang_items.is_raw_pointer li (Ids.Type_id.make 3))
  in
  if class_ok then
    pass "classification: owning handles {copy=false;drop=true}, pointers {copy=true;drop=false}, Option/Result excluded"
  else fail "classification mismatch";
  let li_box =
    { Lang_items.seed_defaults with box_ = Some (Ids.Type_id.make 200) }
  in
  if Lang_items.is_owning_handle li_box (Ids.Type_id.make 200) then
    pass "Box membership answers owning (per-compilation id in the record)"
  else fail "Box membership missing"

(* ── (c) the canonical-instance cache ─────────────────────────────── *)
(* Wrapper[T] materialized at two canonical ids: Wrapper[Int] (def
   Tuple[Int]) is Copy; Wrapper[String] (def Tuple[String]) is not.
   One cache serves both — the structural key must keep them apart. *)
let check_cache_specialization () =
  let w_int = Ids.Type_id.make 101 in
  let w_str = Ids.Type_id.make 102 in
  let resolver : Type_properties.def_resolver =
    Type_properties.structural_resolver (fun tid ->
      if Ids.Type_id.compare tid w_int = 0 then Some (Type_repr.Tuple [| i64 |])
      else if Ids.Type_id.compare tid w_str = 0 then Some (Type_repr.Tuple [| string_ty |])
      else None)
  in
  let cache = Type_properties.create_cache () in
  let p_int = Type_properties.of_type_cached cache (Some resolver) (Type_repr.Named (w_int, [||])) in
  let p_str = Type_properties.of_type_cached cache (Some resolver) (Type_repr.Named (w_str, [||])) in
  let p_int2 = Type_properties.of_type_cached cache (Some resolver) (Type_repr.Named (w_int, [||])) in
  if p_int.Type_properties.is_copy && p_int2.Type_properties.is_copy then
    pass "Wrapper[Int] materialized instance: Copy (memoized by structural key)"
  else fail "Wrapper[Int] cache answer wrong";
  if not p_str.Type_properties.is_copy && p_str.Type_properties.needs_drop then
    pass "Wrapper[String] materialized instance: owned (never shares the Wrapper[Int] entry)"
  else fail "Wrapper[String] cache answer wrong (cross-instance contamination)";
  (* one generic nominal at two substitutions under one cache: the
     def's field is the nominal's own param (the template-scope form) —
     both are non-copy, but the entries live under DISTINCT keys *)
  let w_tpl = Ids.Type_id.make 100 in
  let param = Ids.Generic_param_id.make 7 in
  let tpl_resolver : Type_properties.def_resolver =
    Type_properties.structural_resolver (fun tid ->
      if Ids.Type_id.compare tid w_tpl = 0 then
        Some (Type_repr.Tuple [| Type_repr.Type_param param |])
      else None)
  in
  let cache2 = Type_properties.create_cache () in
  let a1 = Type_repr.Named (w_tpl, [| i64 |]) in
  let a2 = Type_repr.Named (w_tpl, [| string_ty |]) in
  let r1 = Type_properties.of_type_cached cache2 (Some tpl_resolver) a1 in
  let r2 = Type_properties.of_type_cached cache2 (Some tpl_resolver) a2 in
  if not r1.Type_properties.is_copy && not r2.Type_properties.is_copy then
    pass "Wrapper[Int] vs Wrapper[String] template mentions: separate structural entries, equal conservative answers"
  else fail "template-substitution cache answers wrong"

(* ── (d) drop plans: constant-size Repeat, no materialization cutoff ── *)

let check_drop_plans () =
  let fid = Ids.Field_id.make 1 in
  let fidx = Ids.Field_index.make 0 in
  let field_seg = Printf.sprintf "field#%d" (Ids.Field_id.to_int fid) in
  let struct_def (tid : Ids.Type_id.t) (fty : Type_repr.t) : Seed_mir.type_def =
    Seed_mir.StructDef
      { sd_id = tid; sd_fields = [ { Seed_mir.fd_id = fid; fd_index = fidx; fd_ty = fty } ] }
  in
  let prog_big =
    fn_types [||] [| struct_def (Ids.Type_id.make 7) (Type_repr.Fixed_array (string_ty, 1_000_000)) |]
      [||]
  in
  let tbl_big = Drop_plan.of_program prog_big in
  (match Drop_plan.plan_of_type tbl_big (Type_repr.Named (Ids.Type_id.make 7, [||])) with
   | Some plan -> (
       match plan.Drop_plan.node with
       | Drop_plan.Fields [| fp |] -> (
           match fp.Drop_plan.fp_node with
           | Drop_plan.Repeat { count; element = Drop_plan.DropLeaf }
             when count = 1_000_000 ->
               pass "[String; 1_000_000] field plan is ONE Repeat (1_000_000, DropLeaf) — constant-size, no cutoff"
           | Drop_plan.Repeat { count; element = _ } ->
               fail "[String; 1_000_000] field plan Repeat shape wrong (count=%d)"
                 count
           | other ->
               fail "[String; 1_000_000] field plan node is not Repeat: %s"
                 (match other with
                 | Drop_plan.NoDrop -> "NoDrop"
                 | Drop_plan.DropLeaf -> "DropLeaf"
                 | Drop_plan.Fields _ -> "Fields"
                 | Drop_plan.EnumVariants _ -> "EnumVariants"
                 | Drop_plan.Repeat _ -> "Repeat"))
       | other ->
           fail "struct-with-array plan top node is not Fields: %s"
             (match other with
             | Drop_plan.NoDrop -> "NoDrop"
             | Drop_plan.DropLeaf -> "DropLeaf"
             | Drop_plan.Fields _ -> "Fields"
             | Drop_plan.EnumVariants _ -> "EnumVariants"
             | Drop_plan.Repeat _ -> "Repeat"))
   | None -> fail "no plan for the array-holding struct def");
  (* the plan for the owning-array def itself: constant-time, no
     per-element work (the plan built successfully above is the proof);
     the lattice-key expansion stays bounded for the huge array *)
  let paths_big = Drop_plan.owning_paths tbl_big (Type_repr.Named (Ids.Type_id.make 7, [||])) in
  if paths_big = [ field_seg ] then
    pass "owning_paths stays bounded for [String; 1_000_000] (approximate lattice, exact Repeat plan)"
  else
    fail "owning_paths materialized %d keys for [String; 1_000_000]" (List.length paths_big);
  (* arrays up to the lattice bound (1024) still expand exact
     per-index lattice keys *)
  let prog_mid =
    fn_types [||]
      [| struct_def (Ids.Type_id.make 8) (Type_repr.Fixed_array (string_ty, 1000)) |]
      [||]
  in
  let tbl_mid = Drop_plan.of_program prog_mid in
  let paths_mid = Drop_plan.owning_paths tbl_mid (Type_repr.Named (Ids.Type_id.make 8, [||])) in
  let expect (i : int) : string = field_seg ^ "." ^ string_of_int i in
  let first_ok = List.exists (fun k -> k = expect 0) paths_mid in
  let last_ok = List.exists (fun k -> k = expect 999) paths_mid in
  if List.length paths_mid = 1001 && first_ok && last_ok then
    pass "[String; 1000] struct field expands the owning field key + 1000 exact index keys"
  else
    fail "[String; 1000] lattice keys wrong: %d keys, first=%b last=%b"
      (List.length paths_mid) first_ok last_ok;
  (* a scalar-only struct def has a NoDrop-only plan *)
  let prog_scalar =
    fn_types [||] [| struct_def (Ids.Type_id.make 9) i64 |] [||]
  in
  let tbl_scalar = Drop_plan.of_program prog_scalar in
  (match Drop_plan.plan_of_type tbl_scalar (Type_repr.Named (Ids.Type_id.make 9, [||])) with
   | Some plan -> (
       match plan.Drop_plan.node with
       | Drop_plan.Fields [| fp |] when fp.Drop_plan.fp_node = Drop_plan.NoDrop ->
           pass "scalar struct field plan is NoDrop"
       | _ -> fail "scalar struct field plan is not a NoDrop field")
   | None -> fail "no plan for the scalar struct def")

(* ── (e) verifier: Copy/Move/double-move/drop-after-move on Vec ───── *)

let vec_copy_prog (second : Seed_mir.operand) : Seed_mir.program =
  (* _0 = return (Unit), _1 = Vec[Int], _2/_3 = Vec[Int] *)
  let vty = vec_ty i64 in
  fn1
    [| Type_repr.Unit; vty; vty; vty |]
    [
      Seed_mir.Assign
        ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
          Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]) );
      Seed_mir.Assign
        ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
          Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
      Seed_mir.Assign
        ( { Seed_mir.root = Seed_mir.Local 3; projections = [] },
          Seed_mir.Use second );
    ]
    Seed_mir.Ret

let check_verifier () =
  (* a raw-MIR bitwise Copy of Vec[Int] is rejected *)
  (match
     Mir_verify.require_valid_concrete
       (vec_copy_prog (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [] }))
   with
   | Error errs ->
       if List.exists (fun e -> contains_sub e "copy of non-Copy") errs then
         pass "verifier rejects Copy(Vec[Int]) in raw MIR (bitwise copy of an owning type)"
       else begin
         Printf.printf "    %s\n" (String.concat "\n    " errs);
         fail "Copy(Vec[Int]) rejected without the copy-of-non-Copy finding"
       end
   | Ok () -> fail "verifier ACCEPTED a bitwise Copy of Vec[Int]");
  (* the same value MOVES cleanly *)
  (match
     Mir_verify.require_valid_concrete
       (vec_copy_prog (Seed_mir.Move { root = Seed_mir.Local 2; projections = [] }))
   with
   | Ok () -> pass "verifier accepts the Move of Vec[Int]"
   | Error errs ->
       Printf.printf "    %s\n" (String.concat "\n    " errs);
       fail "verifier rejected a legal Move of Vec[Int]");
  (* a second Move of the same local is a use-after-move *)
  let double_move =
    fn1
      [| Type_repr.Unit; vec_ty i64; vec_ty i64; vec_ty i64 |]
      [
        Seed_mir.Assign
          ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
            Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1 ]) );
        Seed_mir.Assign
          ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
            Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
        Seed_mir.Assign
          ( { Seed_mir.root = Seed_mir.Local 3; projections = [] },
            Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
      ]
      Seed_mir.Ret
  in
  (match Mir_verify.require_valid_concrete double_move with
   | Error errs ->
       if List.exists (fun e -> contains_sub e "second consume") errs then
         pass "verifier rejects the double Move of Vec[Int] (single-use rule)"
       else begin
         Printf.printf "    %s\n" (String.concat "\n    " errs);
         fail "double Move rejected without the second-consume finding"
       end
   | Ok () -> fail "verifier ACCEPTED a double Move of Vec[Int]");
  (* a Drop of a moved local is rejected (the destroy would be empty) *)
  let drop_moved =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| Type_repr.Unit; string_ty; string_ty |];
            blocks =
              [|
                {
                  id = 0;
                  statements =
                    [
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
                          Seed_mir.Use (str_op "x") );
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                          Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
                    ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None);
                };
                { id = 1; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = [||];
    }
  in
  (match Mir_verify.require_valid_concrete drop_moved with
   | Error errs ->
       if List.exists (fun e -> contains_sub e "drop of previously moved") errs then
         pass "verifier rejects a Drop of a moved local"
       else begin
         Printf.printf "    %s\n" (String.concat "\n    " errs);
         fail "Drop-of-moved rejected without the moved-drop finding"
       end
   | Ok () -> fail "verifier ACCEPTED a Drop of a moved local");
  (* a duplicate Drop of a live local is rejected *)
  let dup_drop =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| Type_repr.Unit; string_ty |];
            blocks =
              [|
                {
                  id = 0;
                  statements =
                    [
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
                          Seed_mir.Use (str_op "x") );
                    ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None);
                };
                {
                  id = 1;
                  statements = [];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 2, None);
                };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = [||];
    }
  in
  (match Mir_verify.require_valid_concrete dup_drop with
   | Error errs ->
       if List.exists (fun e -> contains_sub e "duplicate drop") errs then
         pass "verifier rejects the duplicate Drop (destroyed-lattice via the owning paths)"
       else begin
         Printf.printf "    %s\n" (String.concat "\n    " errs);
         fail "duplicate Drop rejected without the duplicate-drop finding"
       end
   | Ok () -> fail "verifier ACCEPTED a duplicate Drop")

(* ── (f) VM: drop-after-move / plan-driven typed drop ─────────────── *)

let vm_run (prog : Seed_mir.program) : (int, Vm.vm_error) result =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  Vm.run_li ~lang_items:Lang_items.seed_defaults ~program:prog ~entry:(entry_of prog) ~argv:[||]
    ~host

let vm_inspect (prog : Seed_mir.program) : (string, string) result =
  match
    Vm.entry_frame_of_li ~lang_items:Lang_items.seed_defaults ~program:prog
      ~entry:(entry_of prog) ~argv:[||]
  with
  | Error m -> Error m
  | Ok (vm, frame) -> Vm.run_inspect vm frame

let check_vm () =
  (* drop-after-move is NOT a double destruction: the moved slot's drop
     is a no-op (only a drop of a DROPPED slot traps) *)
  let drop_after_move =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| Type_repr.Unit; string_ty; Type_repr.Tuple [| string_ty |] |];
            blocks =
              [|
                {
                  id = 0;
                  statements =
                    [
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
                          Seed_mir.Use (str_op "hello") );
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                          Seed_mir.Aggregate
                            (Seed_mir.TupleAgg, [ Seed_mir.Move { root = Seed_mir.Local 1; projections = [] } ]) );
                    ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 2; projections = [] }, 1, None);
                };
                {
                  id = 1;
                  statements = [];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 2, None);
                };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = [||];
    }
  in
  (match Vm.entry_frame_of_li ~lang_items:Lang_items.seed_defaults ~program:drop_after_move
          ~entry:(entry_of drop_after_move) ~argv:[||]
   with
   | Error m -> fail "drop-after-move: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match Vm.run_inspect vm frame with
       | Error m -> fail "drop-after-move: %s" m
       | Ok _ ->
           if Vm_value.slot_state frame.locals.(1) = "moved" then
             pass "drop-after-move: the moved String slot drops as a no-op (state moved, no trap)"
           else
             fail "drop-after-move: slot state is %s (expected moved)"
               (Vm_value.slot_state frame.locals.(1))));
  (* the plan-driven typed drop walks plan_node: a STRUCT def with a
     String field and a Vec field; an ENUM def with payload variants *)
  let sid = Ids.Type_id.make 7 in
  let eid = Ids.Type_id.make 8 in
  let vfid = Ids.Field_id.make 1 in
  let sfid = Ids.Field_id.make 2 in
  let prog_plan =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals =
              [| Type_repr.Unit; Type_repr.Named (sid, [||]); Type_repr.Named (eid, [||]) |];
            blocks =
              [|
                {
                  id = 0;
                  statements =
                    [
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 1; projections = [] },
                          Seed_mir.Aggregate
                            ( Seed_mir.StructCtor (sid, [| Ids.Field_index.make 0; Ids.Field_index.make 1 |]),
                              [ str_op "s"; Seed_mir.Constant (Seed_mir.Array i64) ] ) );
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                          Seed_mir.Aggregate
                            ( Seed_mir.EnumCtor (eid, Ids.Variant_index.make 0),
                              [ str_op "payload" ] ) );
                    ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None);
                };
                {
                  id = 1;
                  statements = [];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 2; projections = [] }, 2, None);
                };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types =
        [|
          Seed_mir.StructDef
            {
              sd_id = sid;
              sd_fields =
                [
                  { Seed_mir.fd_id = sfid; fd_index = Ids.Field_index.make 0; fd_ty = string_ty };
                  { Seed_mir.fd_id = vfid; fd_index = Ids.Field_index.make 1; fd_ty = vec_ty i64 };
                ];
            };
          Seed_mir.EnumDef
            {
              ed_id = eid;
              ed_variants =
                [
                  {
                    Seed_mir.vd_id = Ids.Variant_id.make 1;
                    vd_index = Ids.Variant_index.make 0;
                    vd_payload = Type_repr.Tuple [| string_ty |];
                  };
                  {
                    Seed_mir.vd_id = Ids.Variant_id.make 2;
                    vd_index = Ids.Variant_index.make 1;
                    vd_payload = Type_repr.Unit;
                  };
                ];
            };
        |];
    }
  in
  (match vm_inspect prog_plan with
   | Error m -> fail "plan-driven typed drop: %s" m
   | Ok _ -> pass "plan-driven typed drop: struct + enum defs drop through their plan nodes without a trap");
  (* a second drop of the DROPPED slot still traps (double destruction) *)
  let double_drop =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| Type_repr.Unit; string_ty |];
            blocks =
              [|
                {
                  id = 0;
                  statements = [ Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (str_op "x")) ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None);
                };
                {
                  id = 1;
                  statements = [];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 2, None);
                };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = [||];
    }
  in
  (match vm_run double_drop with
   | Error e when contains_sub e.Vm.message "drop of a dropped slot" ->
       pass "a second drop of the DROPPED slot traps (drop-after-move is the only no-op)"
   | Error e ->
       fail "double-drop VM trap message wrong: %s" e.Vm.message
   | Ok _ -> fail "double drop did not trap in the VM")

(* ── (g) the RESOURCE-CHECK consumer (audit item 3) ──────────────────
   The CFG resource dataflow consumes the ONE engine: its owned-root
   and owning-chain queries run Type_properties with the program's def
   table as the resolver and the optional LangItems overlay — the same
   answers the verifier/drop planner give the identical concrete types.
   The matrix rows are proven to REACH the ownership pass: *)

(* two whole-value consumes of one root (a move of a Copy value is a
   copy; of an owned value the second consume is a use-after-consume) *)
let double_whole_move_prog (locals : Type_repr.t array)
    (types : Seed_mir.type_def array) : Seed_mir.program =
  fn_types locals types
    [|
      {
        Seed_mir.id = 0;
        statements =
          [
            Seed_mir.Assign
              ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
            Seed_mir.Assign
              ( { Seed_mir.root = Seed_mir.Local 3; projections = [] },
                Seed_mir.Use (Seed_mir.Move { root = Seed_mir.Local 1; projections = [] }) );
          ];
        terminator = Seed_mir.Ret;
      };
    |]

let check_cfg_all_copy_struct_root () =
  (* g1: an all-Copy STRUCT def root (the def is in program.types) —
     the engine resolves the def, answers Copy, and the pass does NOT
     track the root: two whole-value consumes are two copies *)
  let c_tid = Ids.Type_id.make 300 in
  let c_fid = Ids.Field_id.make 30 in
  let c_ty = Type_repr.Named (c_tid, [||]) in
  let prog =
    double_whole_move_prog [| i64; c_ty; c_ty; c_ty |]
      [|
        Seed_mir.StructDef
          {
            sd_id = c_tid;
            sd_fields =
              [ { Seed_mir.fd_id = c_fid; fd_index = Ids.Field_index.make 0; fd_ty = i64 } ];
          };
      |]
  in
  let errs = Resource_check.cfg_check_program prog in
  if errs = [] then
    pass "g1: all-Copy struct root is untracked by the cfg dataflow (double whole-value consume is two copies)"
  else begin
    List.iter (fun e -> Printf.printf "    %s\n" e) errs;
    fail "g1: the cfg dataflow tracked an all-Copy struct root (%d finding(s))"
      (List.length errs)
  end

let check_cfg_owning_enum_chain () =
  (* g2: an OWNING enum (String payload) held as a struct field —
     reaching the chain through the semantic Field projection, the
     engine answers the enum NON-Copy through its def (the payload
     rule), so the field chain is tracked and its double move is a
     double-move finding *)
  let h_tid = Ids.Type_id.make 301 in
  let e_tid = Ids.Type_id.make 302 in
  let h_fid = Ids.Field_id.make 31 in
  let e_var = Ids.Variant_id.make 40 in
  let h_ty = Type_repr.Named (h_tid, [||]) in
  let e_ty = Type_repr.Named (e_tid, [||]) in
  let prog =
    fn_types [| i64; h_ty; e_ty |]
      [|
        Seed_mir.StructDef
          {
            sd_id = h_tid;
            sd_fields =
              [ { Seed_mir.fd_id = h_fid; fd_index = Ids.Field_index.make 0; fd_ty = e_ty } ];
          };
        Seed_mir.EnumDef
          {
            ed_id = e_tid;
            ed_variants =
              [
                {
                  Seed_mir.vd_id = e_var;
                  vd_index = Ids.Variant_index.make 0;
                  vd_payload = Type_repr.Tuple [| string_ty |];
                };
              ];
          };
      |]
      [|
        {
          Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign
                ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                  Seed_mir.Use
                    (Seed_mir.Move
                       { root = Seed_mir.Local 1; projections = [ Seed_mir.Field h_fid ] }) );
              Seed_mir.Assign
                ( { Seed_mir.root = Seed_mir.Local 2; projections = [] },
                  Seed_mir.Use
                    (Seed_mir.Move
                       { root = Seed_mir.Local 1; projections = [ Seed_mir.Field h_fid ] }) );
            ];
          terminator = Seed_mir.Ret;
        };
      |]
  in
  let errs = Resource_check.cfg_check_program prog in
  if List.length errs = 1 && List.exists (fun e -> contains_sub e "double-move of owned field") errs then
    pass "g2: an owning enum (String payload) field chain is tracked — the double move is a double-move finding"
  else begin
    List.iter (fun e -> Printf.printf "    %s\n" e) errs;
    fail "g2: the owning-enum chain answer is wrong (%d finding(s), expected exactly the double-move finding)"
      (List.length errs)
  end

let check_cfg_langitems_overlay () =
  (* g3: a def-less Ptr[Int] nominal root — the LangItems overlay's
     raw-pointer answer (Copy) is threaded into the pass: WITH the
     compilation record the root is untracked; WITHOUT it the same
     def-less nominal answers the engine's conservative owned *)
  let ptr_ty = Type_repr.Named (Ids.Type_id.make 5, [| i64 |]) in
  let prog = double_whole_move_prog [| i64; ptr_ty; ptr_ty; ptr_ty |] [||] in
  let errs_li = Resource_check.cfg_check_program ~lang_items:(Some Lang_items.seed_defaults) prog in
  if errs_li = [] then
    pass "g3: Ptr[Int] root answers Copy under the LangItems overlay (untracked)"
  else begin
    List.iter (fun e -> Printf.printf "    %s\n" e) errs_li;
    fail "g3: Ptr[Int] root was tracked despite the LangItems overlay (%d finding(s))"
      (List.length errs_li)
  end;
  let errs_none = Resource_check.cfg_check_program prog in
  if List.length errs_none = 1 && List.exists (fun e -> contains_sub e "use-after-consume") errs_none then
    pass "g3: the same def-less Ptr[Int] root answers conservative-owned without the overlay"
  else begin
    List.iter (fun e -> Printf.printf "    %s\n" e) errs_none;
    fail "g3: the no-overlay Ptr[Int] answer is wrong (%d finding(s), expected the use-after-consume)"
      (List.length errs_none)
  end

let () =
  check_property_matrix ();
  check_lang_items ();
  check_cache_specialization ();
  check_drop_plans ();
  check_verifier ();
  check_vm ();
  check_cfg_all_copy_struct_root ();
  check_cfg_owning_enum_chain ();
  check_cfg_langitems_overlay ();
  if !failures = 0 then begin
    Printf.printf "tg_type_props: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_type_props: %d FAILURE(S)\n" !failures;
    exit 1
  end
