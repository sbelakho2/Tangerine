(* tg_derived_clone.ml — audit P0-4: the derived-Clone channel is
   TRAIT-SEMANTIC.

   The checker mints a derived Clone (typecheck.ml's derived channel)
   only when the receiver's components discharge "Copy OR Clone"
   (obligations, anchored at the call span), and the synthesized bodies
   (mir_derive.ml) clone every non-Copy component through that
   component's OWN Clone — the registered (owner, clone) method under
   the same callable identity the source body lowers — never by an
   ordinary Read duplication of owning values.  These legs prove:

    1. a struct holding a String clones through String::clone (a REAL
       call of the registered impl — a custom `self + "!"` impl makes
       the semantic clone observable: the clone's payload is "hi!" and
       the original stays "hi" — independent values), and the program
       verifies + runs;
    2. a struct holding a custom nominal with a registered Clone (a
       counting wrapper over an Int) clones through the impl EXACTLY
       ONCE per clone call (never zero — no value duplication — and
       never twice), the original stays independent (its tag remains 1
       after two clones of it);
    3. an enum clones ONLY the active variant's payload (the String
       variant clones through String::clone; the Int variant copies by
       value read in its OWN branch), under a discriminant SwitchInt —
       the B payload's clone/destructor code never runs for an A
       value;
    4. the mint obligations: Wrapper[Int] succeeds by Copy, Wrapper
       [String] succeeds through the registered String clone, the
       minted signature of a `fn f[T: Clone]` receiver carries the
       `T: Clone` where-clause, and Wrapper[NoClone] / a struct with a
       non-Copy non-Clone field / a clone over an unbounded generic
       parameter all fail with the anchored reason. *)

let contains (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0

(* parse -> graph -> resolver -> checker fixpoint over one module *)
let check_to_fixpoint (src : string) :
    Typecheck.env option * Ast.program * string list =
  let file = Filename.temp_file "tg_derived_clone" ".tg" in
  let oc = open_out_bin file in
  output_string oc src;
  close_out oc;
  let manifest =
    match Bootstrap_manifest.single ~file ~path:[ "dclone" ] () with
    | Ok m -> m
    | Error e -> failwith ("tg_derived_clone manifest: " ^ e)
  in
  let diags = Diagnostic.create_bag () in
  let graph = Module_graph.create_with_sources manifest diags in
  let resolved = Resolver.resolve manifest graph diags in
  let prog_ast = (List.hd graph.Module_graph.nodes).Module_graph.node_program in
  let rec fix env n =
    match Typecheck.check_program env prog_ast with
    | Error m -> failwith ("tg_derived_clone typecheck: " ^ m)
    | Ok (env', errors) ->
        if errors = [] then (Some env', prog_ast, [])
        else if n = 0 then (None, prog_ast, errors)
        else fix env' (n - 1)
  in
  let result = fix (Typecheck.initial_env ~resolved:(Some resolved) ()) 6 in
  Sys.remove file;
  result

let check_ok (src : string) : Typecheck.env * Ast.program =
  match check_to_fixpoint src with
  | Some env, prog, [] -> (env, prog)
  | _, _, errors -> failwith ("typecheck errors: " ^ String.concat "; " errors)

let clone_method_ts (env : Typecheck.env) (owner : string) : Typecheck.typed_signature =
  match List.assoc_opt (owner, "clone") env.Typecheck.methods with
  | Some ts -> ts
  | None -> failwith ("no registered clone method for " ^ owner)

let derived_clone_sigs (env : Typecheck.env) :
    (Ids.Callable_id.t * Typecheck.typed_signature) list =
  List.filter
    (fun (_, ts) -> Util.has_suffix ts.Typecheck.ts_name "::clone")
    env.Typecheck.state.Typecheck.derived_sigs

let tid_of_named (env : Typecheck.env) (name : string) : Ids.Type_id.t =
  match List.assoc_opt name env.Typecheck.type_ids with
  | Some t -> t
  | None -> failwith ("no type id for " ^ name)

(* ── structural analysis over a synthesized function ─────────────── *)

let local_of_place (p : Seed_mir.place) : int option =
  match p.Seed_mir.root with Seed_mir.Local l -> Some l | _ -> None

let place_projects_local (p : Seed_mir.place) (l : int) : bool =
  match p.Seed_mir.root with
  | Seed_mir.Local l' -> l' = l
  | Seed_mir.Static _ -> false

let calls_of (fn : Seed_mir.function_) : (int * Seed_mir.callee) list =
  Array.to_list fn.Seed_mir.blocks
  |> List.concat_map (fun b ->
         match b.Seed_mir.terminator with
         | Seed_mir.Call (dst, callee, _, _, _) -> (
             match local_of_place dst with
             | Some l -> [ (l, callee) ]
             | None -> [])
         | _ -> [])

let callable_of_callee (c : Seed_mir.callee) : Ids.Callable_id.t option =
  match c with
  | Seed_mir.User inst -> Some (Instance_id.callable inst)
  | Seed_mir.Derived (c, _) -> Some c
  | _ -> None

let aggregates_of (fn : Seed_mir.function_) : (Seed_mir.aggregate_kind * Seed_mir.operand list) list =
  Array.to_list fn.Seed_mir.blocks
  |> List.concat_map (fun b ->
         List.filter_map
           (fun st ->
             match st with
             | Seed_mir.Assign (_, Seed_mir.Aggregate (kind, ops)) -> Some (kind, ops)
             | _ -> None)
           b.Seed_mir.statements)

let has_switch (fn : Seed_mir.function_) : bool =
  Array.exists
    (fun b ->
      match b.Seed_mir.terminator with Seed_mir.SwitchInt _ -> true | _ -> false)
    fn.Seed_mir.blocks

(* ── the lowering harness (mirrors the qualified-call proof leg of
   tg_lowersurface): typecheck the single-module source, lower main and
   the impl methods under the checker's final env + the driver's
   semantic variant table, synthesize every derived clone sig, assemble
   the program (types from the checker's concrete closure defs) and run
   the VM. *)

let program_of (env : Typecheck.env) (prog_ast : Ast.program) : Seed_mir.program =
  let funcs =
    List.filter_map
      (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
      prog_ast.Ast.items
  in
  (* impl methods with their OWNER (the impl target — String/Counter/...):
     env.methods is keyed (owner, method); the method bodies lower under
     the registered sig of their own owner *)
  let impl_methods : (string * Ast.function_decl) list =
    List.concat_map
      (fun i ->
        match i.Ast.kind with
        | Ast.ImplBlock d ->
            List.map (fun m -> (d.Ast.i_target_type, m)) d.Ast.i_methods
        | _ -> [])
      prog_ast.Ast.items
  in
  let ts_of_fun (d : Ast.function_decl) : Typecheck.typed_signature =
    match List.assoc_opt d.Ast.fn_sig.Ast.sig_name env.Typecheck.functions with
    | Some ts -> ts
    | None -> (
        match
          List.filter
            (fun (k, _) -> Util.has_suffix k ("::" ^ d.Ast.fn_sig.Ast.sig_name))
            env.Typecheck.functions
        with
        | [ (_, ts) ] -> ts
        | _ -> failwith ("no typed signature for " ^ d.Ast.fn_sig.Ast.sig_name))
  in
  let ts_of_method (owner : string) (m : Ast.function_decl) : Typecheck.typed_signature =
    match List.assoc_opt (owner, m.Ast.fn_sig.Ast.sig_name) env.Typecheck.methods with
    | Some ts -> ts
    | None ->
        failwith
          ("no typed method signature for " ^ owner ^ "::" ^ m.Ast.fn_sig.Ast.sig_name)
  in
  let type_names =
    List.filter_map
      (fun i ->
        match i.Ast.kind with
        | Ast.StructDef d ->
            Some (d.Ast.s_name, Type_repr.Named (List.assoc d.Ast.s_name env.Typecheck.type_ids, [||]))
        | Ast.EnumDef d ->
            Some (d.Ast.e_name, Type_repr.Named (List.assoc d.Ast.e_name env.Typecheck.type_ids, [||]))
        | _ -> None)
      prog_ast.Ast.items
  in
  let env2 : Mir_lower.func_env =
    {
      Mir_lower.consts = [];
      statics = [];
      types =
        type_names
        @ [
            ("Int", Type_repr.Int Type_repr.Int);
            ("Unit", Type_repr.Unit);
            ("Bool", Type_repr.Bool);
            ("String", Type_repr.String);
          ];
      values =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            (n, (ts_of_fun d).Typecheck.ts_return))
          funcs
        (* enum variant constructors are callable values: their
           registered result type lets lowering build the EnumCtor
           aggregate (the driver's lowering env maps env.constructors
           the same way) *)
        @ List.map
            (fun (n, ts) -> (n, ts.Typecheck.ts_return))
            env.Typecheck.constructors;
      callables =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            ( n,
              {
                Mir_lower.ce_callable = Ids.Callable_id.to_int (ts_of_fun d).Typecheck.ts_callable;
                ce_template_args = [||];
                ce_params = [||];
              } ))
          funcs;
      methods =
        List.map
          (fun ((owner, mname), ts) ->
            ( (owner, mname),
              {
                Mir_lower.me_instance =
                  Instance_id.make ~callable:ts.Typecheck.ts_callable
                    ~type_args:
                      (Array.of_list
                         (List.map
                            (fun (_, pid) -> Type_repr.Type_param pid)
                            ts.Typecheck.ts_params_decl));
                me_params = ts.Typecheck.ts_params;
                me_ret = ts.Typecheck.ts_return;
                me_has_self =
                  Array.length ts.Typecheck.ts_params > 0
                  && Array.length ts.Typecheck.ts_param_names > 0
                  && ts.Typecheck.ts_param_names.(0) = "self";
              } ))
          env.Typecheck.methods;
      callables_by_callable = [];
      fn_ret = Type_repr.Int Type_repr.Int;
      struct_fields = Driver.struct_fields_of env;
      enum_payloads = Driver.enum_payloads_of env;
      copy_cache = Type_properties.create_cache ();
      lang_items = Lang_items.of_types env.Typecheck.types;
    }
  in
  let vt = Driver.user_variant_table env in
  let lower_fn (d : Ast.function_decl) : Seed_mir.function_ =
    let ts = ts_of_fun d in
    Mir_lower.lower_function_with_variants vt
      ~typed_nodes:(Driver.typed_nodes_of env)
      { env2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
      d.Ast.fn_sig.Ast.sig_name (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
      [||] [||] d
  in
  let lower_method ((owner, m) : string * Ast.function_decl) : Seed_mir.function_ =
    let ts = ts_of_method owner m in
    Mir_lower.lower_function_with_variants vt
      ~typed_nodes:(Driver.typed_nodes_of env)
      { env2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
      m.Ast.fn_sig.Ast.sig_name (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
      (Array.of_list
         (List.map (fun (_, pid) -> Type_repr.Type_param pid) ts.Typecheck.ts_params_decl))
      (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
      ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
      m
  in
  let derived_fns =
    List.map (fun (_, ts) -> Mir_derive.synthesize env ts) (derived_clone_sigs env)
  in
  {
    Seed_mir.functions =
      Array.of_list
        (List.map lower_fn funcs @ List.map lower_method impl_methods @ derived_fns);
    statics = [||];
    types = Driver.closure_types env;
  }

let run_main (env : Typecheck.env) (prog_ast : Ast.program) (expected : int) : unit =
  let prog = program_of env prog_ast in
  (match Mir_verify.require_valid_template prog with
   | Ok () -> ()
   | Error errs ->
       Printf.printf "  MIR verify (template): FAIL\n";
       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
       Printf.printf "%s\n" (Seed_mir.print_program prog);
       exit 1);
  (match Mir_verify.require_valid_concrete prog with
   | Ok () -> ()
   | Error errs ->
       Printf.printf "  MIR verify (concrete): FAIL\n";
       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
       Printf.printf "%s\n" (Seed_mir.print_program prog);
       exit 1);
  let entry =
    match
      Array.to_list prog.Seed_mir.functions
      |> List.find_opt (fun f -> f.Seed_mir.name = "main")
    with
    | Some f -> f.Seed_mir.instance
    | None -> failwith "no main function"
  in
  let host = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:prog ~entry ~argv:[||] ~host with
   | Error e ->
       Printf.printf "  VM: FAIL %s\n" e.Vm.message;
       exit 1
   | Ok code ->
       Printf.printf "  VM: exit %d\n" code;
       (match Vm.entry_frame_of ~program:prog ~entry ~argv:[||] with
        | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m
        | Ok (vm, frame) -> (
            match Vm.run_inspect vm frame with
            | Ok ret_val ->
                Printf.printf "  main returned: %s\n" ret_val;
                if ret_val = string_of_int expected then
                  Printf.printf "  RESULT: PASS (expected %d)\n" expected
                else begin
                  Printf.printf "  RESULT: FAIL (expected %d)\n" expected;
                  exit 1
                end
            | Error m ->
                Printf.printf "  main returned: <inspect failed: %s>\n" m;
                exit 1)));;


(* ── leg 1: String-field struct — the clone is String::clone, the
   original stays untouched (independent values) ──────────────────── *)
let () =
  Printf.printf "tg_derived_clone leg 1 (String-field struct clones through String::clone):\n";
  let src = {|
impl Clone for String
  def clone(self: Self) -> String
    self + "!"
  end
end

struct Holder
  s: String
end

def main() -> Int
  let h = Holder { s: "hi" }
  let c = h.clone()
  c.s.len() + h.s.len()
end
|} in
  let env, prog_ast = check_ok src in
  let holder_tid = tid_of_named env "Holder" in
  let string_clone_callable = (clone_method_ts env "String").Typecheck.ts_callable in
  let sigs = derived_clone_sigs env in
  (match sigs with
   | [ _ ] ->
       Printf.printf "  mint: PASS (one derived::Holder::clone sig)\n"
   | _ ->
       Printf.printf "  mint: FAIL (%d clone sigs, expected 1)\n" (List.length sigs);
       exit 1);
  List.iter
    (fun (_, sig_) ->
      let receiver = sig_.Typecheck.ts_params.(0).Type_repr.pt_type in
      (match receiver with
       | Type_repr.Named (t, _) when Ids.Type_id.compare t holder_tid = 0 -> ()
       | _ ->
           Printf.printf "  mint: FAIL (unexpected receiver type)\n";
           exit 1);
      if sig_.Typecheck.ts_where <> [] then begin
        Printf.printf "  mint where: FAIL (a concrete receiver must carry no where-clauses)\n";
        exit 1
      end;
      let fn = Mir_derive.synthesize env sig_ in
      (match calls_of fn with
       | [ (_, callee) ] -> (
           match callable_of_callee callee with
           | Some c when Ids.Callable_id.compare c string_clone_callable = 0 ->
               Printf.printf
                 "  body: PASS (exactly one clone call — the registered String::clone callee CallableId#%d)\n"
                 (Ids.Callable_id.to_int c)
           | _ ->
               Printf.printf "  body: FAIL (the single call is not String::clone)\n";
               exit 1)
       | _ ->
           Printf.printf "  body: FAIL (%d clone calls, expected exactly one)\n"
             (List.length (calls_of fn));
           exit 1);
      (* the aggregate must be built from the CALL's result — never a raw
         Read of the String field *)
      let calls = calls_of fn in
      let dest = fst (List.hd calls) in
      let structops =
        List.filter_map
          (fun (kind, ops) ->
            match kind with Seed_mir.StructCtor (t, _) -> Some (t, ops) | _ -> None)
          (aggregates_of fn)
      in
      (match structops with
       | [ (t, [ op ]) ] when Ids.Type_id.compare t holder_tid = 0 -> (
           match op with
           | Seed_mir.Read p -> (
               match local_of_place p with
               | Some l when l = dest ->
                   Printf.printf
                     "  aggregate: PASS (the struct aggregate is built from the String::clone result, never from a raw field Read)\n"
               | _ ->
                   Printf.printf "  aggregate: FAIL (the aggregate op is not the clone result)\n";
                   exit 1)
           | _ ->
               Printf.printf "  aggregate: FAIL (the aggregate op is not a Read)\n";
               exit 1)
       | _ ->
           Printf.printf "  aggregate: FAIL (no Holder StructCtor with one op)\n";
           exit 1))
    sigs;
  run_main env prog_ast 5;;

(* ── leg 2: a custom nominal field with a registered Clone clones
   through the impl EXACTLY ONCE per clone call; the original is
   independent ────────────────────────────────────────────────────── *)
let () =
  Printf.printf "tg_derived_clone leg 2 (custom Clone impl runs exactly once per clone; original independent):\n";
  let src = {|
struct Counter
  tag: Int
end

impl Clone for Counter
  def clone(self: Self) -> Counter
    Counter { tag: self.tag + 1000 }
  end
end

struct Held
  c: Counter
end

def main() -> Int
  let h = Held { c: Counter { tag: 1 } }
  let x = h.clone()
  let y = h.clone()
  x.c.tag + y.c.tag + h.c.tag
end
|} in
  let env, prog_ast = check_ok src in
  let held_tid = tid_of_named env "Held" in
  let counter_clone_callable = (clone_method_ts env "Counter").Typecheck.ts_callable in
  let sigs = derived_clone_sigs env in
  if List.length sigs < 2 then begin
    Printf.printf "  derived sigs: FAIL (%d clone sigs, expected the 2 call sites)\n"
      (List.length sigs);
    exit 1
  end;
  List.iter
    (fun (_, sig_) ->
      (match sig_.Typecheck.ts_params.(0).Type_repr.pt_type with
       | Type_repr.Named (t, _) when Ids.Type_id.compare t held_tid = 0 ->
           Printf.printf "  mint: PASS (a derived::Held::clone sig)\n"
       | _ ->
           Printf.printf "  mint: FAIL (unexpected receiver)\n";
           exit 1);
      let fn = Mir_derive.synthesize env sig_ in
      (match calls_of fn with
       | [ (_, callee) ] -> (
           match callable_of_callee callee with
           | Some c when Ids.Callable_id.compare c counter_clone_callable = 0 ->
               Printf.printf
                 "  body: PASS (exactly one clone call per Held clone — the registered Counter::clone callee CallableId#%d; never zero (no value duplication) and never two)\n"
                 (Ids.Callable_id.to_int c)
           | _ ->
               Printf.printf "  body: FAIL (the single call is not Counter::clone)\n";
               exit 1)
       | _ ->
           Printf.printf "  body: FAIL (%d clone calls, expected exactly one)\n"
             (List.length (calls_of fn));
           exit 1))
    sigs;
  run_main env prog_ast 2003;;

(* ── leg 3: enum — clone dispatches on the discriminant and clones
   ONLY the active variant's payload (A clones through String::clone;
   B copies its Int payload by value read inside its own branch) ─── *)
let () =
  Printf.printf "tg_derived_clone leg 3 (enum clones only the active variant payload):\n";
  let src = {|
impl Clone for String
  def clone(self: Self) -> String
    self + "!"
  end
end

enum E
  A(String)
  B(Int)
end

def main() -> Int
  let a = E::A("hi")
  let ca = a.clone()
  let b = E::B(7)
  let cb = b.clone()
  let m1 = (match ca
            when E::A(s) => s.len()
            when E::B(v) => v
            end)
  let m2 = (match cb
            when E::A(s) => s.len()
            when E::B(v) => v
            end)
  let m3 = (match a
            when E::A(s) => s.len()
            when E::B(v) => v
            end)
  m1 + m2 + m3
end
|} in
  let env, prog_ast = check_ok src in
  let e_tid = tid_of_named env "E" in
  let string_clone_callable = (clone_method_ts env "String").Typecheck.ts_callable in
  let sigs = derived_clone_sigs env in
  if List.length sigs < 2 then begin
    Printf.printf "  derived sigs: FAIL (%d clone sigs, expected the 2 call sites)\n"
      (List.length sigs);
    exit 1
  end;
  List.iter
    (fun (_, sig_) ->
      (match sig_.Typecheck.ts_params.(0).Type_repr.pt_type with
       | Type_repr.Named (t, _) when Ids.Type_id.compare t e_tid = 0 ->
           Printf.printf "  mint: PASS (a derived::E::clone sig)\n"
       | _ ->
           Printf.printf "  mint: FAIL (unexpected receiver)\n";
           exit 1);
      let fn = Mir_derive.synthesize env sig_ in
      if not (has_switch fn) then begin
        Printf.printf "  body: FAIL (no discriminant SwitchInt in the clone body)\n";
        exit 1
      end;
      (match calls_of fn with
       | [ (_, callee) ] -> (
           match callable_of_callee callee with
           | Some c when Ids.Callable_id.compare c string_clone_callable = 0 ->
               Printf.printf
                 "  body: PASS (the only clone call in the enum clone body is String::clone — the B(Int) payload clones by value read in its own branch)\n"
           | _ ->
               Printf.printf "  body: FAIL (the single call is not String::clone)\n";
               exit 1)
       | _ ->
           Printf.printf "  body: FAIL (%d clone calls, expected exactly one)\n"
             (List.length (calls_of fn));
           exit 1);
      let calls = calls_of fn in
      let call_dest = fst (List.hd calls) in
      let enum_ctors =
        List.filter_map
          (fun (kind, ops) ->
            match kind with
            | Seed_mir.EnumCtor (t, idx) -> Some (t, idx, ops)
            | _ -> None)
          (aggregates_of fn)
      in
      if List.length enum_ctors <> 2 then begin
        Printf.printf "  body: FAIL (%d EnumCtor aggregates, expected 2 variants)\n"
          (List.length enum_ctors);
        exit 1
      end;
      List.iter
        (fun (t, idx, ops) ->
          if Ids.Type_id.compare t e_tid <> 0 then begin
            Printf.printf "  body: FAIL (an EnumCtor for the wrong nominal)\n";
            exit 1
          end;
          match Ids.Variant_index.to_int idx with
          | 0 ->
              (* variant A(String): the payload clone is the semantic
                 String::clone call's result *)
              (match ops with
               | [ op ] -> (
                   match op with
                   | Seed_mir.Read p -> (
                       match local_of_place p with
                       | Some l when l = call_dest -> ()
                       | _ ->
                           Printf.printf
                             "  body: FAIL (variant A's aggregate is not built from the String::clone result)\n";
                           exit 1)
                   | _ ->
                       Printf.printf "  body: FAIL (variant A's op is not a Read)\n";
                       exit 1)
               | _ ->
                   Printf.printf "  body: FAIL (variant A must have one payload op)\n";
                   exit 1)
          | 1 ->
              (* variant B(Int): the Copy payload is duplicated by the
                 value read INSIDE its own branch (the semantic clone of
                 a Copy) *)
              (match ops with
               | [ op ] -> (
                   match op with
                   | Seed_mir.Read p when place_projects_local p 1 ->
                       ()
                   | _ ->
                       Printf.printf
                         "  body: FAIL (variant B's Copy payload is not read from its own payload place)\n";
                       exit 1)
               | _ ->
                   Printf.printf "  body: FAIL (variant B must have one payload op)\n";
                   exit 1)
          | _ ->
              Printf.printf "  body: FAIL (unexpected variant index)\n";
              exit 1)
        enum_ctors;
      Printf.printf
        "  body: PASS (variant A clones through String::clone; variant B reads its Copy payload; the branches are disjoint)\n")
    sigs;
  run_main env prog_ast 12;;

(* ── leg 4: the mint obligations ─────────────────────────────────── *)

(* 4a: Wrapper[Int] discharges by Copy; Wrapper[String] discharges
   through the registered String clone; both bodies are semantic *)
let () =
  Printf.printf "tg_derived_clone leg 4a (Wrapper[Int] by Copy, Wrapper[String] by String::clone):\n";
  let src = {|
impl Clone for String
  def clone(self: Self) -> String
    self + ""
  end
end

struct Wrapper[T]
  value: T
end

def main() -> Int
  let wi = Wrapper[Int] { value: 5 }
  let ci = wi.clone()
  let ws = Wrapper[String] { value: "x" }
  let cs = ws.clone()
  ci.value + cs.value.len() + wi.value + ws.value.len()
end
|} in
  let env, _prog_ast = check_ok src in
  let wrapper_tid = tid_of_named env "Wrapper" in
  let string_clone_callable = (clone_method_ts env "String").Typecheck.ts_callable in
  let sigs = derived_clone_sigs env in
  let receiver_of ts = ts.Typecheck.ts_params.(0).Type_repr.pt_type in
  let sig_of_receiver (ty : Type_repr.t) =
    List.find_opt
      (fun (_, ts) -> Typecheck.type_to_string (receiver_of ts) = Typecheck.type_to_string ty)
      sigs
  in
  let int_receiver = Type_repr.Named (wrapper_tid, [| Type_repr.Int Type_repr.Int |]) in
  (match sig_of_receiver int_receiver with
   | Some (_, ts) ->
       if ts.Typecheck.ts_where <> [] then begin
         Printf.printf "  Wrapper[Int] mint where: FAIL (no where-clauses expected)\n";
         exit 1
       end;
       let fn = Mir_derive.synthesize env ts in
       if calls_of fn <> [] then begin
         Printf.printf "  Wrapper[Int] body: FAIL (a Copy receiver body must not call clone)\n";
         exit 1
       end;
       Printf.printf "  Wrapper[Int]: PASS (Copy discharge — the body is pure value reads)\n"
   | None ->
       Printf.printf "  Wrapper[Int] mint: FAIL (no derived sig for the concrete receiver)\n";
       exit 1);
  (match sig_of_receiver (Type_repr.Named (wrapper_tid, [| Type_repr.String |])) with
   | Some (_, ts) -> (
       if ts.Typecheck.ts_where <> [] then begin
         Printf.printf "  Wrapper[String] mint where: FAIL (no where-clauses expected)\n";
         exit 1
       end;
       let fn = Mir_derive.synthesize env ts in
       match calls_of fn with
       | [ (_, callee) ] -> (
           match callable_of_callee callee with
           | Some c when Ids.Callable_id.compare c string_clone_callable = 0 ->
               Printf.printf
                 "  Wrapper[String]: PASS (the field clone is the registered String::clone call, CallableId#%d)\n"
                 (Ids.Callable_id.to_int c)
           | _ ->
               Printf.printf "  Wrapper[String] body: FAIL (not the String::clone callable)\n";
               exit 1)
       | _ ->
           Printf.printf "  Wrapper[String] body: FAIL (expected exactly one clone call)\n";
           exit 1)
   | None ->
       Printf.printf "  Wrapper[String] mint: FAIL (no derived sig for the concrete receiver)\n";
       exit 1);;

(* 4b: the generic `fn f[T: Clone]` clone records the T: Clone
   where-clause on the minted signature *)
let () =
  Printf.printf "tg_derived_clone leg 4b (generic `fn f[T: Clone]` clone records the T: Clone where-clause):\n";
  let src = {|
struct Wrapper[T]
  value: T
end

def clone_wrapper[T: Clone](w: Wrapper[T]) -> Wrapper[T]
  w.clone()
end
|} in
  let env, _prog_ast = check_ok src in
  let sigs = derived_clone_sigs env in
  (match sigs with
   | [ (_, ts) ] -> (
       let where_ok =
         List.exists
           (fun (wt, bs) ->
             match wt with
             | Type_repr.Type_param pid ->
                 List.exists (fun (b, _) -> b = "Clone") bs
                 && List.exists
                      (fun (_, dpid) -> Ids.Generic_param_id.compare dpid pid = 0)
                      ts.Typecheck.ts_params_decl
             | _ -> false)
           ts.Typecheck.ts_where
       in
       if where_ok then
         Printf.printf
           "  where: PASS (the minted clone of a `fn f[T: Clone]` receiver carries the T: Clone obligation)\n"
       else begin
         Printf.printf "  where: FAIL (no T: Clone where-clause on the minted signature)\n";
         exit 1
       end)
   | _ ->
       Printf.printf "  mint: FAIL (expected exactly one derived clone sig)\n";
       exit 1);;

(* 4c: Wrapper[NoClone] and a struct holding a non-Copy non-Clone
   nominal are REFUSED at the mint, with the anchored reason *)
let () =
  Printf.printf "tg_derived_clone leg 4c (Wrapper[NoClone] and non-Copy non-Clone fields are refused):\n";
  let src = {|
struct NoClone
  s: String
end

struct Wrapper[T]
  value: T
end

struct Bad
  x: NoClone
end

def clone_wrapper() -> Int
  let w = Wrapper[NoClone] { value: NoClone { s: "x" } }
  let c = w.clone()
  c.value.s.len()
end

def clone_bad() -> Int
  let b = Bad { x: NoClone { s: "y" } }
  let d = b.clone()
  d.x.s.len()
end
|} in
  (match check_to_fixpoint src with
   | Some _, _, [] ->
       Printf.printf "  rejection: FAIL (the program typechecked)\n";
       exit 1
   | (Some _ | None), _, errors ->
       let on_wrapper =
         List.exists
           (fun e -> contains e "cannot derive Clone for `Wrapper[NoClone]`" && contains e "NoClone")
           errors
       in
       let on_bad =
         List.exists
           (fun e -> contains e "cannot derive Clone for `Bad`" && contains e "field `x`")
           errors
       in
       if on_wrapper && on_bad then
         Printf.printf
           "  rejection: PASS (both mints refused — `Wrapper[NoClone]` and `Bad`, each anchored at its own call site)\n"
       else begin
         Printf.printf "  rejection: FAIL (missing obligation diagnostics)\n";
         List.iter (fun e -> Printf.printf "    %s\n" e) errors;
         exit 1
       end);;

(* 4d: a clone over an unbounded generic parameter is refused inside
   the generic fn (the derived Clone of a generic type is logically
   `impl[T: Clone]`) *)
let () =
  Printf.printf "tg_derived_clone leg 4d (clone over an unbounded generic parameter is refused):\n";
  let src = {|
struct Wrapper[T]
  value: T
end

def bad_clone[T](w: Wrapper[T]) -> Wrapper[T]
  w.clone()
end
|} in
  (match check_to_fixpoint src with
   | Some _, _, [] ->
       Printf.printf "  rejection: FAIL (the unbounded generic clone typechecked)\n";
       exit 1
   | (Some _ | None), _, errors ->
       if List.exists (fun e -> contains e "cannot derive Clone") errors then
         Printf.printf "  rejection: PASS (the unbounded-param clone is refused)\n"
       else begin
         Printf.printf "  rejection: FAIL (no obligation diagnostic)\n";
         List.iter (fun e -> Printf.printf "    %s\n" e) errors;
         exit 1
       end);;

(* ── leg 5: a TUPLE receiver clones through the derived channel — the
   checker mints the elementwise clone (it has no nominal owner to
   register under), the lowering resolves the call through the recorded
   TC_derived callee (the structural-receiver owner candidates are
   empty, exactly like the checker's dispatch), the synthesized body
   clones each element through the element's own registered Clone, and
   the original tuple stays independent.  This is the pipeline shape the
   bootstrap kernel's `rows[i].clone()` on (String, String) vectors
   reaches. ────────────────────────────────────────────────────────── *)
let () =
  Printf.printf
    "tg_derived_clone leg 5 (tuple receiver clones elementwise through the derived channel):\n";
  let src = {|
impl Clone for String
  def clone(self: Self) -> String
    self + "!"
  end
end

def main() -> Int
  let t = ("hi", "xy")
  let c = t.clone()
  c.0.len() + c.1.len() + t.0.len() + t.1.len()
end
|} in
  let env, prog_ast = check_ok src in
  let string_clone_callable = (clone_method_ts env "String").Typecheck.ts_callable in
  let sigs = derived_clone_sigs env in
  (match sigs with
   | [ (_, ts) ] -> (
       (match ts.Typecheck.ts_params.(0).Type_repr.pt_type with
        | Type_repr.Tuple [| Type_repr.String; Type_repr.String |] ->
            Printf.printf "  mint: PASS (one derived clone sig with the (String, String) receiver)\n"
        | _ ->
            Printf.printf "  mint: FAIL (unexpected derived receiver)\n";
            exit 1);
       let fn = Mir_derive.synthesize env ts in
       let clone_calls =
         List.filter
           (fun (_, callee) ->
             match callable_of_callee callee with
             | Some c -> Ids.Callable_id.compare c string_clone_callable = 0
             | None -> false)
           (calls_of fn)
       in
       if List.length (calls_of fn) = 2 && List.length clone_calls = 2 then
         Printf.printf
           "  body: PASS (exactly two clone calls, both the registered String::clone — one per tuple element)\n"
       else begin
         Printf.printf "  body: FAIL (%d clone calls, %d through String::clone, expected 2/2)\n"
           (List.length (calls_of fn)) (List.length clone_calls);
         exit 1
       end)
   | _ ->
       Printf.printf "  mint: FAIL (%d derived clone sigs, expected 1)\n" (List.length sigs);
       exit 1);
  (* program_of lowers main through the REAL Mir_lower: a tuple receiver
     used to fail closed with the non-nominal Seed_bug here *)
  run_main env prog_ast 10;;

let () =
  Printf.printf "tg_derived_clone: ALL LEGS PASS\n"
