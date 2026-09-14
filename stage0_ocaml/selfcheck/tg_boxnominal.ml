(* tg_boxnominal.ml — Box NOMINAL-IDENTITY regression self-check
   (the Stage0 Box-transparency audit: Box[T] is a distinct nominal
   type, never one logical type with T).

   The former transparency made `erase_transparent` / `equivalent_ty` /
   `same_instance` erase the Box wrapper, unified Box[T] with T in both
   directions, deref'd fields and clone dispatch through the boxed
   content, and promoted `box_new` to the content at the VM boundary.
   This self-check proves the restored EXACT nominal identity from the
   outside, through the same public channels the pipeline uses:

     [1] canonical instance identity:      Box[T] != T,
         Option[Box[T]] != Option[T], Vec-like specializations distinct,
         while genuine canonical spellings (I64/Int aliases, literal
         defaulting) still intern to ONE id;
     [2] checker identity: passing Box[T] where T is expected FAILS;
         Option[Box[T]] where Option[T] is expected FAILS (no
         reconciliation-through-Box anywhere);
     [3] Box's own surface: `boxed.clone()` resolves Box's registered
         `impl[T: Clone] Box[T]` (the lowered call names that callable),
         never a content clone; `b.ptr` projects the box's own field;
     [4] layout: size_of[Box[[u8; 16]]] is the wrapper's pointer size
         (8), distinct from the 16-byte content, and a recursive
         `Node { next: Option[Box[Node]] }` stays layout-finite;
     [5] drop plans: Box[..] plans are owning DropLeafs while a plain
         `{ ptr: Ptr[T] }` struct plans NoDrop, for both the Box template
         and a materialized Box instance;
     [6] end-to-end: a self-contained Box declaration (alloc + box_new +
         get/into_inner + Clone impl) type-checks, lowers, monomorphizes,
         passes the concrete MIR gate, folds its size_of queries and RUNS
         on the VM with a real wrapper value: `Box::new(42).clone()
         .into_inner()` reads back 42, AND clone is NON-DESTRUCTIVE — the
         source box survives repeated clones (the source is read after a
         clone, and one box is cloned twice; the pre-fix body routed the
         source through into_inner and trapped on the freed region).

   Exit 0 iff every leg passes. *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

let parse_program (name : string) (src : string) : Ast.program =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let src0 = Source.of_bytes ~name ~bytes:src in
  let file_id = Span.add_file sm name src0 in
  let lx = Lexer.create src0.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src0.Source.bytes file_id diags [] in
  if Diagnostic.has_errors diags then (
    Printf.printf "parse errors:\n%s\n" (Diagnostic.render sm diags);
    exit 1);
  program

let check_src (name : string) (src : string) :
    (Typecheck.env * Ast.program, string list) result =
  let program = parse_program name src in
  (* the driver's checker fixpoint: re-registration rounds settle forward
     references, impl method registrations and obligation checks *)
  let rec fix (env : Typecheck.env) (n : int) : (Typecheck.env * string list) =
    match Typecheck.check_program env program with
    | Error m -> (env, [ m ])
    | Ok (env', errors) ->
        if errors = [] || n = 0 then (env', errors) else fix env' (n - 1)
  in
  match fix (Typecheck.initial_env ()) 6 with
  | env, [] -> Ok (env, program)
  | _, errors -> Error errors

let expect_clean (name : string) (src : string) : Typecheck.env option =
  match check_src name src with
  | Ok (env, _) ->
      check name true;
      Some env
  | Error errs ->
      check name false;
      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
      None

let expect_rejected (name : string) (src : string) : unit =
  match check_src name src with
  | Ok _ ->
      check name false;
      Printf.printf "    program was ACCEPTED (expected a type error)\n"
  | Error _ -> check name true

(* ── [1] canonical instance identity ─────────────────────────────── *)

let canonical_part () : unit =
  let box = Ids.Type_id.make 100 in
  let expr = Ids.Type_id.make 101 in
  let gen = Ids.Type_id.make 102 in
  let option_tid = Ids.Type_id.make 3 in
  let ct = Canonical_type_instance.create ~mint_from:1000 () in
  let intern tid args =
    match Canonical_type_instance.intern ct tid args with
    | Some (id, _) -> id
    | None -> failwith "tg_boxnominal: instance not materializable"
  in
  let box_expr = intern box [| Type_repr.Named (expr, [||]) |] in
  let plain_expr = intern expr [||] in
  check "canonical: Box[Expr] and Expr mint distinct ids"
    (Ids.Type_id.compare box_expr plain_expr <> 0);
  check "canonical: same_instance Box[Expr] Expr = false (no wrapper erasure)"
    (not (Canonical_type_instance.same_instance ct box_expr plain_expr));
  let opt_box = intern option_tid [| Type_repr.Named (box, [| Type_repr.Named (expr, [||]) |]) |] in
  let opt_expr = intern option_tid [| Type_repr.Named (expr, [||]) |] in
  check "canonical: Option[Box[Expr]] and Option[Expr] mint distinct ids"
    (Ids.Type_id.compare opt_box opt_expr <> 0);
  check "canonical: same_instance Option[Box[Expr]] Option[Expr] = false"
    (not (Canonical_type_instance.same_instance ct opt_box opt_expr));
  let gen_box = intern gen [| Type_repr.Named (box, [| Type_repr.Named (expr, [||]) |]) |] in
  let gen_plain = intern gen [| Type_repr.Named (expr, [||]) |] in
  check "canonical: Gen[Box[Expr]] and Gen[Expr] are distinct specializations"
    (Ids.Type_id.compare gen_box gen_plain <> 0);
  (* genuine canonical spellings still reconcile: I64 == Int, literal ==
     its defaulted kind *)
  let g_i64 = intern gen [| Type_repr.Int Type_repr.I64 |] in
  let g_int = intern gen [| Type_repr.Int Type_repr.Int |] in
  check "canonical: I64 and Int still intern to ONE id (64-bit alias)"
    (Ids.Type_id.compare g_i64 g_int = 0);
  let g_lit = intern gen [| Type_repr.Int_literal [| 5 |] |] in
  check "canonical: a fitting literal still interns to its defaulted kind"
    (Ids.Type_id.compare g_lit g_int = 0)

(* ── [2] checker identity ────────────────────────────────────────── *)

let box_prelude = {|struct Box[T]
  ptr: Ptr[T]
end

|}

let checker_part () : unit =
  ignore
    (expect_rejected "checker: passing Box[Int] where Int is expected FAILS"
       (box_prelude
       ^ {|def take_int(x: Int) -> Int
  x
end
def pass_box(b: Box[Int]) -> Int
  take_int(b)
end
|}));
  ignore
    (expect_rejected "checker: Option[Box[Int]] where Option[Int] is expected FAILS"
       ({|def take_opt(x: Option[Int]) -> Int
  match x
  when Option::Some(v) then v
  when Option::None then 0
  end
end
def pass_opt(b: Option[Box[Int]]) -> Int
  take_opt(b)
end
|}));
  ignore
    (expect_clean "checker: the same-spelled Option[Box[Int]] call typechecks"
       (box_prelude
       ^ {|def take_opt(x: Option[Box[Int]]) -> Int
  match x
  when Option::Some(v) then 1
  when Option::None then 0
  end
end
def pass_opt(b: Option[Box[Int]]) -> Int
  take_opt(b)
end
|}));
  ignore
    (expect_rejected "checker: Box[Int] content is NOT implicitly deref-field"
       (box_prelude
       ^ {|def bad(b: Box[Int]) -> Int
  b.ptr
end
def main() -> Int
  let b = bad_dummy(b)
  0
end
def bad_dummy(b: Box[Int]) -> Box[Int]
  b
end
|}));
  ignore
    (expect_clean "checker: explicit b.ptr projects the box's own field"
       (box_prelude
       ^ {|def ptr_of(b: Box[Int]) -> Ptr[Int]
  b.ptr
end
|}))

(* ── [3] Box's own clone impl ────────────────────────────────────── *)

let lower_all (env : Typecheck.env) (prog : Ast.program) : Seed_mir.program =
  let base = Driver.lowering_env_of ~items:prog.Ast.items env in
  let variants = Driver.user_variant_table env in
  let lower_one (d : Ast.function_decl) (ts : Typecheck.typed_signature) : Seed_mir.function_ =
    let name = d.Ast.fn_sig.Ast.sig_name in
    Mir_lower.lower_function_with_variants
      ~typed_nodes:(Driver.typed_nodes_of env)
      ~typed_patterns:(Driver.typed_patterns_of env)
      ~typed_for_patterns:(Driver.typed_for_patterns_of env)
      ~typed_let_patterns:(Driver.typed_let_patterns_of env)
      ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
      variants
      { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
      name
      (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
      (Array.of_list
         (List.map (fun (_, pid) -> Type_repr.Type_param pid) ts.Typecheck.ts_params_decl))
      (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
      d
  in
  let funcs =
    List.filter_map
      (fun i ->
        match i.Ast.kind with
        | Ast.Function d -> (
            match Driver.lookup_typed_fn_qualified env [] d.Ast.fn_sig.Ast.sig_name with
            | Some ts -> Some (lower_one d ts)
            | None -> None)
        | _ -> None)
      prog.Ast.items
  in
  let methods =
    List.concat_map
      (fun i ->
        match i.Ast.kind with
        | Ast.ImplBlock d ->
            List.filter_map
              (fun (m : Ast.function_decl) ->
                match
                  List.assoc_opt (d.Ast.i_target_type, m.Ast.fn_sig.Ast.sig_name)
                    env.Typecheck.methods
                with
                | Some ts -> Some (lower_one m ts)
                | None -> None)
              d.Ast.i_methods
        | _ -> [])
      prog.Ast.items
  in
  {
    Seed_mir.functions = Array.of_list (funcs @ methods);
    statics = Driver.closure_statics env prog.Ast.items;
    types = Driver.closure_types env;
  }

let clone_part () : unit =
  let src =
    box_prelude
    ^ {|impl[T] Box[T]
  def clone(self: Self) -> Box[T]
    Box { ptr: self.ptr }
  end
end
def dup(b: Box[Int]) -> Box[Int]
  b.clone()
end
|}
  in
  match check_src "clone" src with
  | Error errs ->
      check "clone: Box's own clone impl typechecks" false;
      List.iter (fun e -> Printf.printf "    %s\n" e) errs
  | Ok (env, prog) ->
      check "clone: Box's own clone impl typechecks" true;
      let impl_callable =
        match List.assoc_opt ("Box", "clone") env.Typecheck.methods with
        | Some ts -> ts.Typecheck.ts_callable
        | None -> failwith "tg_boxnominal: (Box, clone) not registered"
      in
      let mir = lower_all env prog in
      let fn =
        Array.to_list mir.Seed_mir.functions
        |> List.find_opt (fun f -> f.Seed_mir.name = "dup")
      in
      let calls =
        match fn with
        | None -> []
        | Some f ->
            Array.to_list f.Seed_mir.blocks
            |> List.filter_map (fun b ->
                   match b.Seed_mir.terminator with
                   | Seed_mir.Call (_, Seed_mir.User inst, _, _, _) ->
                       Some (Instance_id.callable inst)
                   | Seed_mir.Call (_, Seed_mir.Derived (c, _), _, _, _) -> Some c
                   | _ -> None)
      in
      check "clone: the lowered `b.clone()` names Box's registered clone callable"
        (List.exists
           (fun c -> Ids.Callable_id.compare c impl_callable = 0)
           calls)

(* ── [4] layout ──────────────────────────────────────────────────── *)

let i64 = Type_repr.Int Type_repr.Int

let size_query_prog (qty : Type_repr.t) : Seed_mir.program =
  let dest : Seed_mir.place = { Seed_mir.root = Seed_mir.Local 0; projections = [] } in
  {
    Seed_mir.functions =
      [|
        {
          Seed_mir.name = "size_probe";
          instance =
            Instance_id.make ~callable:(Ids.Callable_id.make 1) ~type_args:[||];
          params = [||];
          locals = [| i64 |];
          blocks =
            [|
              {
                Seed_mir.id = 0;
                statements = [];
                terminator =
                  Seed_mir.Call (dest, Seed_mir.TypeQuery (Seed_mir.SizeOf, [| qty |]), [||], 0, None);
              };
            |];
          entry = 0;
        };
      |];
    statics = [||];
    types = [||];
  }

let folded_size (lang_items : Lang_items.t) (qty : Type_repr.t) : int =
  let prog =
    Layout_fold.fold_program ~lang_items
      ~name_of:(fun tid ->
        if Lang_items.tid_eq lang_items.Lang_items.box_ tid then Some "Box" else None)
      (size_query_prog qty)
  in
  let fn = prog.Seed_mir.functions.(0) in
  let b = fn.Seed_mir.blocks.(0) in
  match List.rev b.Seed_mir.statements with
  | Seed_mir.Assign (_, Seed_mir.Use (Seed_mir.Constant (Seed_mir.Integer v))) :: _ ->
      Int64.to_int (Int_value.to_int64 v)
  | _ -> failwith "tg_boxnominal: size query was not folded to a constant"

let layout_part () : unit =
  let box = Ids.Type_id.make 100 in
  let lang_items = { Lang_items.seed_defaults with Lang_items.box_ = Some box } in
  let content = Type_repr.Fixed_array (Type_repr.Int Type_repr.U8, 16) in
  let box_ty = Type_repr.Named (box, [| content |]) in
  let box_size = folded_size lang_items box_ty in
  let content_size = folded_size lang_items content in
  check "layout: size_of[Box[[u8;16]]] = 8 (the wrapper, not the content)"
    (box_size = 8);
  check "layout: size_of[Box[[u8;16]]] != size_of[[u8;16]]" (box_size <> content_size);
  (* recursive: Node { next: Option[Box[Node]] } is finite because Box is
     an indirection (its own def's Ptr field breaks the inline cycle) *)
  let node = Ids.Type_id.make 103 in
  let option_tid = Ids.Type_id.make 3 in
  let node_ty = Type_repr.Named (node, [||]) in
  let box_node = Type_repr.Named (box, [| node_ty |]) in
  let option_box_node = Type_repr.Named (option_tid, [| box_node |]) in
  let defs =
    [|
      Seed_mir.StructDef
        {
          sd_id = node;
          sd_fields =
            [
              {
                Seed_mir.fd_id = Ids.Field_id.make 1;
                fd_index = Ids.Field_index.make 0;
                fd_ty = option_box_node;
              };
            ];
        };
      Seed_mir.StructDef
        {
          sd_id = box;
          sd_fields =
            [
              {
                Seed_mir.fd_id = Ids.Field_id.make 2;
                fd_index = Ids.Field_index.make 0;
                fd_ty = Type_repr.Raw_ptr (Type_repr.Mutable, node_ty);
              };
            ];
        };
      Seed_mir.EnumDef
        {
          ed_id = option_tid;
          ed_variants =
            [
              {
                Seed_mir.vd_id = Ids.Variant_id.make 1;
                vd_index = Ids.Variant_index.make 0;
                vd_payload = Type_repr.Tuple [| box_node |];
              };
              {
                Seed_mir.vd_id = Ids.Variant_id.make 2;
                vd_index = Ids.Variant_index.make 1;
                vd_payload = Type_repr.Unit;
              };
            ];
        };
    |]
  in
  let prog =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "size_probe";
            instance =
              Instance_id.make ~callable:(Ids.Callable_id.make 1) ~type_args:[||];
            params = [||];
            locals = [| i64 |];
            blocks =
              [|
                {
                  Seed_mir.id = 0;
                  statements = [];
                  terminator =
                    Seed_mir.Call
                      ( { Seed_mir.root = Seed_mir.Local 0; projections = [] },
                        Seed_mir.TypeQuery (Seed_mir.SizeOf, [| node_ty |]),
                        [||],
                        0,
                        None );
                };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = defs;
    }
  in
  let ok =
    try
      let folded =
        Layout_fold.fold_program ~lang_items
          ~name_of:(fun tid -> if Lang_items.tid_eq lang_items.Lang_items.box_ tid then Some "Box" else None)
          prog
      in
      match List.rev folded.Seed_mir.functions.(0).Seed_mir.blocks.(0).Seed_mir.statements with
      | Seed_mir.Assign (_, Seed_mir.Use (Seed_mir.Constant (Seed_mir.Integer v))) :: _ ->
          Int64.to_int (Int_value.to_int64 v) > 0
      | _ -> false
    with Failure _ -> false
  in
  check "layout: recursive Node{next: Option[Box[Node]]} folds to a finite size" ok

(* ── [5] drop plans ──────────────────────────────────────────────── *)

let drop_plan_part () : unit =
  let box = Ids.Type_id.make 100 in
  let expr = Ids.Type_id.make 101 in
  let plain = Ids.Type_id.make 102 in
  let field ptr_ty =
    { Seed_mir.fd_id = Ids.Field_id.make 1; fd_index = Ids.Field_index.make 0; fd_ty = ptr_ty }
  in
  let ptr_expr = Type_repr.Raw_ptr (Type_repr.Mutable, Type_repr.Named (expr, [||])) in
  let prog =
    {
      Seed_mir.functions = [||];
      statics = [||];
      types =
        [|
          Seed_mir.StructDef { sd_id = box; sd_fields = [ field ptr_expr ] };
          Seed_mir.StructDef { sd_id = plain; sd_fields = [ field ptr_expr ] };
        |];
    }
  in
  let lang_items = { Lang_items.seed_defaults with Lang_items.box_ = Some box } in
  let box_instance = Ids.Type_id.make 500 in
  let prog_with_instance =
    {
      prog with
      Seed_mir.types =
        Array.append prog.Seed_mir.types
          [| Seed_mir.StructDef { sd_id = box_instance; sd_fields = [ field ptr_expr ] } |];
    }
  in
  let tbl = Drop_plan.of_program ~lang_items ~box_instances:[ box_instance ] prog_with_instance in
  let cache = Type_properties.create_cache () in
  let node (ty : Type_repr.t) : Drop_plan.plan_node =
    Drop_plan.node_of_type tbl cache ty
  in
  check "drop: the Box template plans as owning DropLeaf (not its Ptr-field shape)"
    (node (Type_repr.Named (box, [| Type_repr.Named (expr, [||]) |])) = Drop_plan.DropLeaf);
  check "drop: a materialized Box instance plans as owning DropLeaf"
    (node (Type_repr.Named (box_instance, [| Type_repr.Named (expr, [||]) |])) = Drop_plan.DropLeaf);
  check "drop: a plain { ptr: Ptr[T] } struct plans NoDrop (distinct from Box)"
    (node (Type_repr.Named (plain, [| Type_repr.Named (expr, [||]) |])) = Drop_plan.NoDrop)

(* ── [6] end-to-end: check -> lower -> mono -> verify -> fold -> VM ── *)

let end_to_end_part () : unit =
  let src =
    {|struct Box[T]
  ptr: Ptr[T]
end

struct Ptr[T]
  address: UInt
end

impl Ptr[T]
  def cast[U](self: Self) -> Ptr[U]
    Ptr { address: self.address }
  end

  def is_null(self: Self) -> Bool
    self.address == 0
  end
end

def panic(msg: String) -> Unit
  ()
end

extern def __intrinsic_mem_alloc(size: UInt) -> Ptr[u8]
extern def __intrinsic_mem_free(ptr: Ptr[u8], size: UInt) -> Unit

def alloc[T](size: UInt) -> Ptr[T]
  __intrinsic_mem_alloc(size).cast[T]()
end

def dealloc[T](ptr: Ptr[T], size: UInt) -> Unit
  __intrinsic_mem_free(ptr.cast[u8](), size)
end

def box_new[T](sink value: T) -> Box[T]
  let ptr = alloc[T](size_of[T]())
  ptr.write(value)
  Box { ptr: ptr }
end

impl[T] Box[T]
  def get(self: Box[T]) -> Ptr[T]
    self.ptr
  end

  def into_inner(sink self: Box[T]) -> T
    match self
    when Box { ptr: ptr } then
      let value = ptr.read()
      dealloc[T](ptr, size_of[T]())
      value
    end
  end
end

impl[T: Clone] Box[T]
  def clone(self: Self) -> Box[T]
    if self.ptr.is_null() then
      panic("Box: use after drop")
    end
    box_new(self.ptr.read().clone())
  end
end

struct Holder
  a: Box[Int]
end

impl Clone for Holder
  def clone(self: Self) -> Holder
    Holder { a: self.a.clone() }
  end
end

def main() -> Int
  let v = 21 * 2
  let b = Box::new(v)
  let c = b.clone()
  let r = c.into_inner()
  let r2 = b.into_inner()
  let h = Holder { a: Box::new(v) }
  let c1 = h.clone()
  let c2 = h.clone()
  let p1 = c1.a.get()
  let p2 = c2.a.get()
  let p3 = h.a.get()
  let v1 = p1.read()
  let v2 = p2.read()
  let v3 = p3.read()
  let total = r + r2 + v1 + v2 + v3
  if total == 210 then 42 else total end
end
|}
  in
  match check_src "end-to-end" src with
  | Error errs ->
      check "end-to-end: Box program typechecks" false;
      List.iter (fun e -> Printf.printf "    %s\n" e) errs
  | Ok (env, prog) ->
      check "end-to-end: Box program typechecks" true;
      let mir = lower_all env prog in
      let entry_name, entry =
        match Driver.resolve_bootstrap_entry mir None with
        | Some e -> e
        | None ->
            check "end-to-end: main resolves" false;
            ("main", Instance_id.make ~callable:(Ids.Callable_id.make 1) ~type_args:[||])
      in
      let lang_items = Typecheck.lang_items_of_env env in
      let query_sigs = Driver.closure_query_sigs ~lowered:(Some mir) env in
      let generic_types = Driver.closure_generic_types env in
      (match
         Driver.run_mono_phase ~entry_name ~entry
           ~box_tid:env.Typecheck.state.Typecheck.box_tid ~lang_items ~generic_types
           ~query_sigs ~env:(Some env) mir
       with
       | Error errs ->
           check "end-to-end: mono + concrete verify" false;
           List.iter (fun e -> Printf.printf "    %s\n" e) errs
       | Ok mo ->
           check "end-to-end: mono + concrete verify" true;
           let vprog =
             Layout_fold.fold_program ~lang_items
               ~name_of:(fun tid -> List.assoc_opt tid !Typecheck.type_names_global)
               mo.Driver.mo_program
           in
           let host = Host.create ~repo_root:"." ~argv:[||] in
           (match
              Vm.run_li ~limits:Vm.default_limits ~lang_items ~program:vprog
                ~entry:mo.Driver.mo_entry ~argv:[||] ~host
            with
            | Error e ->
                check "end-to-end: VM runs the real Box wrapper" false;
                Printf.printf "    VM: %s\n" e.Vm.message
            | Ok _ ->
                (match
                   Vm.entry_frame_of_li ~limits:Vm.default_limits ~lang_items
                     ~program:vprog ~entry:mo.Driver.mo_entry ~argv:[||]
                 with
                 | Error m ->
                     check "end-to-end: VM runs the real Box wrapper" false;
                     Printf.printf "    inspect: %s\n" m
                 | Ok (vm2, frame) -> (
                     (* the inspect VM starts with a fresh arena; share the
                        host arena the executed run used so raw pointers
                        materialized by the host stay resolvable *)
                     vm2.Vm.memory <- host.Host.memory;
                     match Vm.run_inspect vm2 frame with
                     | Ok "42" ->
                         check
                           "end-to-end: Box::new(42).clone().into_inner() = 42 AND the source box survives repeated clones (source read after clone, two clones of one box)"
                           true
                     | Ok other ->
                         check "end-to-end: VM result" false;
                         Printf.printf "    expected 42, got %s\n" other
                     | Error m ->
                         check "end-to-end: VM result" false;
                         Printf.printf "    inspect run: %s\n" m))))

(* ── [7] borrowed-tree walk: read-through vs destructive ─────────────
   Regression for the kernel's residual macro-call scan
   (compiler_core.residual_macro_calls_in_expr): the scan is a READ-ONLY
   query over the program expand_macros is about to return. The pre-fix
   walk consumed every boxed payload with into_inner(), deallocating
   regions in the program it was inspecting; the following
   assign_node_ids then trapped in assign_expr_ids with `deref read:
   access to freed region`. This leg pins both halves: the read-through
   walk (the fix: `*x.get()`, never taking ownership) leaves the owner's
   tree fully usable, and the pre-fix destructive walk leaves it dangling
   so the next reader fails closed. *)

let contains_substring (haystack : string) (needle : string) : bool =
  let n = String.length haystack and m = String.length needle in
  let rec go i = i + m <= n && (String.sub haystack i m = needle || go (i + 1)) in
  go 0

let vm_result_of_src (name : string) (src : string) : (string, string) result =
  match check_src name src with
  | Error errs -> Error ("typecheck: " ^ String.concat "; " errs)
  | Ok (env, prog) ->
      let mir = lower_all env prog in
      let entry_name, entry =
        match Driver.resolve_bootstrap_entry mir None with
        | Some e -> e
        | None -> failwith "tg_boxnominal: no main entry"
      in
      let lang_items = Typecheck.lang_items_of_env env in
      let query_sigs = Driver.closure_query_sigs ~lowered:(Some mir) env in
      let generic_types = Driver.closure_generic_types env in
      (match
         Driver.run_mono_phase ~entry_name ~entry
           ~box_tid:env.Typecheck.state.Typecheck.box_tid ~lang_items ~generic_types
           ~query_sigs ~env:(Some env) mir
       with
       | Error errs -> Error ("mono: " ^ String.concat "; " errs)
       | Ok mo ->
           let vprog =
             Layout_fold.fold_program ~lang_items
               ~name_of:(fun tid -> List.assoc_opt tid !Typecheck.type_names_global)
               mo.Driver.mo_program
           in
           let host = Host.create ~repo_root:"." ~argv:[||] in
           (match
              Vm.run_li ~limits:Vm.default_limits ~lang_items ~program:vprog
                ~entry:mo.Driver.mo_entry ~argv:[||] ~host
            with
            | Error e -> Error e.Vm.message
            | Ok _ -> (
                match
                  Vm.entry_frame_of_li ~limits:Vm.default_limits ~lang_items
                    ~program:vprog ~entry:mo.Driver.mo_entry ~argv:[||]
                with
                | Error m -> Error ("inspect: " ^ m)
                | Ok (vm2, frame) ->
                    (* share BOTH the memory and the host record: the
                       host's intrinsic bindings allocate in
                       host.memory, while the VM dereferences through
                       vm.memory; a fresh vm2 host would allocate in a
                       different arena whose region ids alias the
                       executed run's regions *)
                    vm2.Vm.host <- host;
                    vm2.Vm.memory <- host.Host.memory;
                    (match Vm.run_inspect vm2 frame with
                     | Ok v -> Ok v
                     | Error m -> Error ("inspect run: " ^ m)))))

let borrow_walk_part () : unit =
  let prelude =
    {|struct Box[T]
  ptr: Ptr[T]
end

struct Ptr[T]
  address: UInt
end

impl Ptr[T]
  def cast[U](self: Self) -> Ptr[U]
    Ptr { address: self.address }
  end

  def is_null(self: Self) -> Bool
    self.address == 0
  end
end

def panic(msg: String) -> Unit
  ()
end

extern def __intrinsic_mem_alloc(size: UInt) -> Ptr[u8]
extern def __intrinsic_mem_free(ptr: Ptr[u8], size: UInt) -> Unit

def alloc[T](size: UInt) -> Ptr[T]
  __intrinsic_mem_alloc(size).cast[T]()
end

def dealloc[T](ptr: Ptr[T], size: UInt) -> Unit
  __intrinsic_mem_free(ptr.cast[u8](), size)
end

def box_new[T](sink value: T) -> Box[T]
  let ptr = alloc[T](size_of[T]())
  ptr.write(value)
  Box { ptr: ptr }
end

impl[T] Box[T]
  def get(self: Box[T]) -> Ptr[T]
    self.ptr
  end

  def get_mut(inout self: Box[T]) -> Ptr[T]
    self.ptr
  end

  def into_inner(sink self: Box[T]) -> T
    match self
    when Box { ptr: ptr } then
      let value = ptr.read()
      dealloc[T](ptr, size_of[T]())
      value
    end
  end
end
|}
  in
  let shared =
    {|struct Expr
  kind: ExprKind
  node_id: Int
end

enum ExprKind
  ExprInt(Int)
  ExprBinaryOp(Box[Expr], Box[Expr])
end

def count_nodes(expr: Expr) -> Int
  let here = expr.node_id + 1
  match expr.kind
  when ExprKind::ExprInt(_) then here
  when ExprKind::ExprBinaryOp(lhs, rhs) then
    here + count_nodes(*lhs.get()) + count_nodes(*rhs.get())
  end
end

def sum_ids(expr: Expr) -> Int
  let here = expr.node_id
  match expr.kind
  when ExprKind::ExprInt(_) then here
  when ExprKind::ExprBinaryOp(lhs, rhs) then
    here + sum_ids(*lhs.get()) + sum_ids(*rhs.get())
  end
end

def assign_ids(inout expr: Expr, inout next_id: Int) -> Unit
  expr.node_id = next_id
  next_id = next_id + 1
  match expr.kind
  when ExprKind::ExprInt(_) then ()
  when ExprKind::ExprBinaryOp(lhs, rhs) then
    assign_ids(*lhs.get_mut(), next_id)
    assign_ids(*rhs.get_mut(), next_id)
  end
end

def destroy_nodes(expr: Expr) -> Int
  let here = expr.node_id + 1
  match expr.kind
  when ExprKind::ExprInt(_) then here
  when ExprKind::ExprBinaryOp(lhs, rhs) then
    let l = lhs.into_inner()
    let r = rhs.into_inner()
    here + destroy_nodes(l) + destroy_nodes(r)
  end
end

def build_tree() -> Expr
  let l1 = Expr { kind: ExprKind::ExprInt(1), node_id: 0 }
  let l2 = Expr { kind: ExprKind::ExprInt(2), node_id: 0 }
  let l3 = Expr { kind: ExprKind::ExprInt(3), node_id: 0 }
  let inner = Expr { kind: ExprKind::ExprBinaryOp(box_new(l1), box_new(l2)), node_id: 0 }
  Expr { kind: ExprKind::ExprBinaryOp(box_new(inner), box_new(l3)), node_id: 0 }
end
|}
  in
  (* fixed path: read-through query first, then the assign walk (the
     kernel's post-expansion assign_node_ids shape); preorder ids 1..5. *)
  let fixed_src =
    prelude ^ shared
    ^ {|def main() -> Int
  var e = build_tree()
  let n = count_nodes(&e)
  var ids = 1
  assign_ids(&mut e, &mut ids)
  let s = sum_ids(&e)
  n * 1000 + s
end
|}
  in
  (match vm_result_of_src "borrow-walk" fixed_src with
  | Ok "5015" ->
      check
        "borrow: read-through query (the fixed residual scan) then assign_ids keeps the borrowed tree usable (= 5015)"
        true
  | Ok other ->
      check
        "borrow: read-through query (the fixed residual scan) then assign_ids keeps the borrowed tree usable (= 5015)"
        false;
      Printf.printf "    expected 5015, got %s\n" other
  | Error m ->
      check
        "borrow: read-through query (the fixed residual scan) then assign_ids keeps the borrowed tree usable (= 5015)"
        false;
      Printf.printf "    VM: %s\n" m);
  (* pre-fix shape: the destructive query consumes the boxes of the tree
     it was lent; the owner's next reader must fail closed, never silently
     read the freed region. *)
  let destroyed_src =
    prelude ^ shared
    ^ {|def main() -> Int
  var e = build_tree()
  let n = destroy_nodes(&e)
  var ids = 1
  assign_ids(&mut e, &mut ids)
  n + ids
end
|}
  in
  let _destructive =
  match vm_result_of_src "borrow-walk-destructive" destroyed_src with
  | Error m when contains_substring m "freed region" ->
      check
        "borrow: the pre-fix destructive query leaves the owner's boxes dangling (the next reader traps on the freed region)"
        true
  | Error m ->
      check
        "borrow: the pre-fix destructive query leaves the owner's boxes dangling (the next reader traps on the freed region)"
        false;
      Printf.printf "    expected a freed-region trap, got: %s\n" m
  | Ok v ->
      check
        "borrow: the pre-fix destructive query leaves the owner's boxes dangling (the next reader traps on the freed region)"
        false;
      Printf.printf "    destructive walk did not corrupt the tree (result %s)\n" v
  in
  (* ── resolver/checker-shaped multi-pass reads ───────────────────────
     The kernel's resolve_names / type_check_typed / access_check /
     resource_check are READ-ONLY analyses over the program the pipeline
     still owns: each walks the SAME tree, often the same expression more
     than once (resolve then check; check_expr then check_binary_op's
     independent walk; the deinit-plan walk). The pre-fix walks consumed
     boxed payloads with into_inner(), so the SECOND reader over the same
     tree dereferenced a freed region — the bootstrap VM's
     assign_stmt_ids / check_expr freed-region trap. This leg pins:
       (1) read-only passes before AND after the mutating assign walk
           leave the tree fully usable (the fixed shape: `*x.get()`);
       (2) a PURE read-only pass after a destructive pass fails closed
           (the pre-fix shape; never a silent read of the freed region). *)
  let multi_read_src =
    prelude ^ shared
    ^ {|def main() -> Int
  var e = build_tree()
  let n1 = count_nodes(&e)
  let s1 = sum_ids(&e)
  var ids = 1
  assign_ids(&mut e, &mut ids)
  let n2 = count_nodes(&e)
  let s2 = sum_ids(&e)
  n1 * 1000 + n2 * 100 + s2
end
|}
  in
  (match vm_result_of_src "borrow-walk-multi-read" multi_read_src with
  | Ok "7015" ->
      check
        "borrow: read-only passes before AND after assign_ids keep the borrowed tree usable (resolver/checker multi-pass shape)"
        true
  | Ok other ->
      check
        "borrow: read-only passes before AND after assign_ids keep the borrowed tree usable (resolver/checker multi-pass shape)"
        false;
      Printf.printf "    expected 7015, got %s\n" other
  | Error m ->
      check
        "borrow: read-only passes before AND after assign_ids keep the borrowed tree usable (resolver/checker multi-pass shape)"
        false;
      Printf.printf "    VM: %s\n" m);
  let pure_destroyed_src =
    prelude ^ shared
    ^ {|def main() -> Int
  var e = build_tree()
  let n = destroy_nodes(&e)
  let s = sum_ids(&e)
  n + s
end
|}
  in
  match vm_result_of_src "borrow-walk-pure-after-destructive" pure_destroyed_src with
  | Error m when contains_substring m "freed region" ->
      check
        "borrow: a PURE read-only pass after the destructive walk traps on the freed region (checker-style reader)"
        true
  | Error m ->
      check
        "borrow: a PURE read-only pass after the destructive walk traps on the freed region (checker-style reader)"
        false;
      Printf.printf "    expected a freed-region trap, got: %s\n" m
  | Ok v ->
      check
        "borrow: a PURE read-only pass after the destructive walk traps on the freed region (checker-style reader)"
        false;
      Printf.printf "    pure reader did not trap (result %s)\n" v

let () =
  canonical_part ();
  checker_part ();
  clone_part ();
  layout_part ();
  drop_plan_part ();
  end_to_end_part ();
  borrow_walk_part ();
  if !failures = 0 then begin
    Printf.printf "tg_boxnominal: ALL BOX-NOMINAL IDENTITY LEGS PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_boxnominal: %d FAILURE(S)\n" !failures;
    exit 1
  end
