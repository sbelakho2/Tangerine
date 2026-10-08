(* tg_kernel_runtime_parity.ml — seed-vs-kernel RUNTIME OBSERVABLE parity.

   The convergence cleanup's Patch 4 lane: ~10 high-value programs whose
   SEMANTICS matter to bootstrap are executed on the SEED side
   (check-to-fixpoint -> lower -> MIR verify -> seed VM, the
   tg_identity_collision / tg_semantic_parity harness) and probed on the
   KERNEL side.  The kernel compiler has NO MIR interpreter (lib.tg:
   "tg_compiler has no MIR interpreter"; equivalence.tg's differential
   layer returns the documented "requires a runner" Unknown), so the
   kernel-side observable is the strongest channel that PROVES the same
   value semantics:

     DIMENSION=lowered_constants
       the kernel's own lower_to_mir output is inspected inside the VM:
       the aggregate operand produced by its struct-literal lowering
       (with omitted declared defaults materialized) is decoded through
       the operand chain — constants, the kernel's lowered statics
       (MirStatic.init), binary ops — exactly the value the kernel MIR
       would execute at that field.  The decoded value must equal the
       seed VM's executed value.

     DIMENSION=channel_identity
       the kernel's checker/lowering IDENTITY record: which declaration
       a default/read resolves to (the recorded GbConst DefId and the
       MirStaticRef consuming it), that two same-named mutable statics
       lower to DISTINCT static identities, the solved callable
       instance / intrinsic stamp of a same-named private-intrinsic
       spelling, or the concrete solved generic channels (no Type::Var /
       Type::Error before readiness).  The seed value anchors the
       semantics the identity must correspond to.

   Every row reports its dimension explicitly.  The kernel battery
   (infer_probe.tg's RUNTIME_PARITY_BATTERY, asserted by tg_infer's
   RUNTIME_PARITY_BATTERY fails=0) embeds the same cases and their
   expected observables; this suite writes the cases to
   build/runtime_parity_cases.txt and the battery byte-compares the
   embedded sources against that file (drift is a hard failure), so the
   two sides can never silently diverge.

   Zero silent skips: a case whose kernel observable is missing,
   BLOCKED, or unequal to its expected token is a MISMATCH; any blocked
   case exits 1 with the blocked list.

   Development aid: TG_KRP_SEED_ONLY=1 prints the seed rows and exits 2
   without a pass claim. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_kernel_runtime_parity: FAIL: %s\n" s;
      exit 1)
    fmt

let ensure_dir path =
  let rec go p =
    if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      | Unix.Unix_error (e, _, _) ->
          fail "cannot create directory %s: %s" p (Unix.error_message e)
    end
  in
  go path

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  if m = 0 then true
  else
    let rec go i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else go (i + 1)
    in
    go 0

(* ── the corpus ─────────────────────────────────────────────────────── *)

(* the std prelude files the seeded closure lane copies from the real
   tree (the same 14 records bootstrap/std_mini.manifest carries). *)
let std_closure_files =
  [
    "alloc.tg"; "core.tg"; "collections.tg"; "taint.tg"; "ffi.tg";
    "gfx_errors.tg"; "fmt.tg"; "args.tg"; "env.tg"; "io.tg"; "time.tg";
    "fs.tg"; "process.tg"; "bench.tg";
  ]

type layout =
  | Single_root of string
  (* one temp file at the module root (Bootstrap_manifest.single) *)
  | Closure of (string * string) list
  (* (record kind, file name) pairs under a throwaway repo root; record
     kind is "selfcheck" — the case files — or "std" (the real std tree
     is copied into the throwaway root). *)

type case_ = {
  label : string;
  layout : layout;
  dimension : string; (* lowered_constants | channel_identity *)
  kernel_token : string; (* the expected kernel observable token *)
  seed_value : string; (* the seed VM's executed value *)
}

let cases : case_ list =
  [
    {
      label = "simple_field_default";
      layout =
        Single_root
          "struct S\n  n: Int = 7\nend\n\ndef main() -> Int\n  let s = S {}\n  s.n\nend\n";
      dimension = "lowered_constants";
      kernel_token = "int:7";
      seed_value = "7";
    };
    {
      label = "local_shadow_field_default";
      layout =
        Single_root
          "const X: Int = 1\n\nstruct S\n  n: Int = X\nend\n\ndef main() -> Int\n  let X: Int = 99\n  let s = S {}\n  s.n\nend\n";
      dimension = "channel_identity";
      kernel_token = "gbconst:1";
      seed_value = "1";
    };
    {
      label = "nested_field_default";
      layout =
        Single_root
          "const X: Int = 1\n\nstruct Inner\n  v: Int = 2\nend\n\nstruct Outer\n  n: Int = Inner {}.v + X\nend\n\ndef main() -> Int\n  let X: Int = 99\n  let o = Outer {}\n  o.n\nend\n";
      dimension = "lowered_constants";
      kernel_token = "int:3";
      seed_value = "3";
    };
    {
      label = "imported_aliased_default";
      layout =
        Closure
          [
            ("selfcheck", "values.tg");
            ("selfcheck", "main.tg");
          ];
      dimension = "channel_identity";
      kernel_token = "gbconst:77";
      seed_value = "77";
    };
    {
      label = "duplicate_module_static_write";
      layout =
        Closure
          [
            ("selfcheck", "a.tg");
            ("selfcheck", "b.tg");
          ];
      dimension = "channel_identity";
      kernel_token = "writes:11@a,22@b_distinct";
      seed_value = "11221122";
    };
    {
      label = "enum_payload_match";
      layout =
        Single_root
          "enum E\n  Ready(Int)\n  Idle\nend\n\ndef main() -> Int\n  let e = E::Ready(4)\n  match e\n  when E::Ready(v) then v\n  when E::Idle then 0\n  end\nend\n";
      dimension = "lowered_constants";
      kernel_token = "int:4";
      seed_value = "4";
    };
    {
      label = "owning_field_default";
      layout =
        Single_root
          "struct Holder\n  n: Int = 7\n  text: String = \"d\"\nend\n\ndef main() -> Int\n  let h = Holder {}\n  if h.text.len() == 1 then h.n else 0 end\nend\n";
      dimension = "lowered_constants";
      kernel_token = "int:7";
      seed_value = "7";
    };
    {
      label = "generic_vec_new_inference";
      layout =
        Closure
          (List.map (fun n -> ("std", n)) std_closure_files
          @ [ ("selfcheck", "vec_case.tg") ]);
      dimension = "channel_identity";
      kernel_token = "vec_new_elem=Int";
      seed_value = "1";
    };
    {
      label = "map_set_construct_lookup";
      layout =
        Closure
          (List.map (fun n -> ("std", n)) std_closure_files
          @ [ ("selfcheck", "map_case.tg") ]);
      dimension = "channel_identity";
      kernel_token = "map_new=String,Int";
      seed_value = "2";
    };
    {
      label = "private_intrinsic_same_name";
      layout =
        Single_root
          "def __intrinsic_map_clone(v: Int) -> Int\n  v + 6\nend\n\ndef main() -> Int\n  __intrinsic_map_clone(1)\nend\n";
      dimension = "channel_identity";
      kernel_token = "user_call_intrinsic=none";
      seed_value = "7";
    };
  ]

(* the closure cases' file bodies (values.tg / main.tg / a.tg / b.tg /
   vec_case.tg / map_case.tg) — byte-identical to the kernel battery's
   embedded sources. *)
let closure_file_body (kind : string) (name : string) : string =
  ignore kind;
  match name with
  | "values.tg" -> "const X: Int = 7\n"
  | "main.tg" ->
      "use stage0_ocaml::selfcheck::values::{X}\n\
       use stage0_ocaml::selfcheck::values::X as Y\n\n\
       struct S\n  n: Int = X\nend\n\n\
       struct T\n  m: Int = Y\nend\n\n\
       def main() -> Int\n  let s = S {}\n  let t = T {}\n  s.n * 10 + t.m\nend\n"
  | "a.tg" ->
      "static mut CELL: Int = 10\n\n\
       def set() -> Int\n  CELL = 11\n  CELL\nend\n\n\
       def cell() -> Int = CELL\n"
  | "b.tg" ->
      "static mut CELL: Int = 20\n\n\
       def set() -> Int\n  CELL = 22\n  CELL\nend\n\n\
       def cell() -> Int = CELL\n\n\
       def main() -> Int\n\
      \  let xa = a::set()\n\
      \  let xb = set()\n\
      \  let read_a = a::cell()\n\
      \  let read_b = cell()\n\
      \  xa * 1000000 + xb * 10000 + read_a * 100 + read_b\n\
       end\n"
  | "vec_case.tg" ->
      "def main() -> Int\n  var v = Vec::new()\n  v.push(1)\n  v.len()\nend\n"
  | "map_case.tg" ->
      "def main() -> Int\n\
      \  var m: Map[String, Int] = Map::new()\n\
      \  let _old = m.insert(\"a\", 1)\n\
      \  let _old2 = m.insert(\"b\", 2)\n\
      \  var s: Set[Int] = Set::new()\n\
      \  let _i = s.insert(7)\n\
      \  let hit = m.contains_key(\"a\")\n\
      \  if hit && s.contains(7) then m.len() else 0 end\n\
       end\n"
  | other -> fail "no closure body for %s" other

(* ── the seed pipeline ──────────────────────────────────────────────── *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      (try Unix.rmdir path with _ -> ())
    end
    else try Sys.remove path with _ -> ()

(* Materialize the case's seed closure under a throwaway repo root.  The
   std records copy the REAL std sources from the repo; selfcheck records
   write the case bodies.  The manifest is a plain `version: 1` + record
   list. *)
let materialize_seed (repo_root : string) (c : case_) :
    string * string option * string =
  match c.layout with
  | Single_root src ->
      let file = Filename.temp_file ("tg_krp_" ^ c.label) ".tg" in
      write_file file src;
      (file, None, file)
  | Closure files ->
      let root = Filename.temp_file ("tg_krp_root_" ^ c.label) "" in
      Sys.remove root;
      Unix.mkdir root 0o755;
      let rec ensure p =
        if not (Sys.file_exists p) then begin
          ensure (Filename.dirname p);
          try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        end
      in
      let lines = Buffer.create 256 in
      Buffer.add_string lines "version: 1\n";
      List.iter
        (fun (kind, name) ->
          let rel =
            if kind = "std" then "std/" ^ name
            else "stage0_ocaml/selfcheck/" ^ name
          in
          let dst = Filename.concat root rel in
          ensure (Filename.dirname dst);
          if kind = "std" then begin
            let src_path = Filename.concat repo_root rel in
            write_file dst (read_file src_path)
          end
          else write_file dst (closure_file_body kind name);
          Buffer.add_string lines (kind ^ ": " ^ name ^ "\n"))
        files;
      let manifest_path = Filename.concat root "krp.manifest" in
      write_file manifest_path (Buffer.contents lines);
      (root, Some manifest_path, root)

let build_graph (manifest : Bootstrap_manifest.t) :
    Typecheck.env * Ast.program * Module_graph.t =
  let diags = Diagnostic.create_bag () in
  let graph = Module_graph.create_with_sources manifest diags in
  if Diagnostic.has_errors diags then begin
    Printf.printf "%s\n" (Diagnostic.render (Module_graph.source_map graph) diags);
    fail "parse errors"
  end;
  let resolved = Resolver.resolve manifest graph diags in
  if Diagnostic.has_errors diags then begin
    Printf.printf "%s\n" (Diagnostic.render (Module_graph.source_map graph) diags);
    fail "resolution errors"
  end;
  let merged =
    match graph.Module_graph.nodes with
    | [ single ] -> single.Module_graph.node_program
    | nodes ->
        let items =
          List.concat_map
            (fun (n : Module_graph.module_node) -> n.Module_graph.node_items)
            nodes
        in
        { Ast.items; prog_span = (List.hd nodes).Module_graph.node_program.Ast.prog_span;
          prog_module_path = [] }
  in
  let rec fix env n =
    match Typecheck.check_program env merged with
    | Error m -> fail "typecheck: %s" m
    | Ok (env', errors) ->
        if errors = [] then env'
        else if n = 0 then begin
          Printf.printf "check errors:\n";
          List.iter (fun e -> Printf.printf "  %s\n" e) errors;
          fail "%d checker error(s)" (List.length errors)
        end
        else fix env' (n - 1)
  in
  let env = fix (Typecheck.initial_env ~resolved:(Some resolved) ()) 6 in
  (env, merged, graph)

(* Lower every free function + every impl method of the checked graph (the
   driver's own builder pattern, copied from tg_semantic_parity). *)
let lower_all (env : Typecheck.env) (graph : Module_graph.t) : Seed_mir.program =
  let all_items =
    List.concat_map
      (fun (n : Module_graph.module_node) -> n.Module_graph.node_items)
      graph.Module_graph.nodes
  in
  let base = Driver.lowering_env_of ~items:all_items env in
  let typed_nodes_tbl = Driver.typed_nodes_table_of env in
  let typed_patterns_tbl = Driver.typed_patterns_table_of env in
  let typed_for_patterns_tbl = Driver.typed_for_patterns_table_of env in
  let typed_let_patterns_tbl = Driver.typed_let_patterns_table_of env in
  let variants = Driver.user_variant_table env in
  let lowered = ref [] in
  let lower_fn (prefix : string list) (d : Ast.function_decl)
      (ts : Typecheck.typed_signature) =
    let fn =
      Mir_lower.lower_function_with_variants ~typed_bindings_complete:true
        ~typed_nodes_tbl ~typed_patterns_tbl ~typed_for_patterns_tbl
        ~typed_let_patterns_tbl
        ~param_tys_opt:
          (Array.map (fun (p : Type_repr.param_type) -> p.Type_repr.pt_type)
             ts.Typecheck.ts_params)
        variants
        { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
        (String.concat "::" (prefix @ [ d.Ast.fn_sig.Ast.sig_name ]))
        (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
        (Array.of_list
           (List.map
              (fun (_, pid) -> Type_repr.Type_param pid)
              ts.Typecheck.ts_params_decl))
        (Array.map
           (fun (p : Type_repr.param_type) -> p.Type_repr.pt_convention)
           ts.Typecheck.ts_params)
        d
    in
    lowered := fn :: !lowered
  in
  List.iter
    (fun (n : Module_graph.module_node) ->
      let prefix = n.Module_graph.node_path in
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.kind with
          | Ast.Function d -> (
              let qname =
                String.concat "::" (prefix @ [ d.Ast.fn_sig.Ast.sig_name ])
              in
              match List.assoc_opt qname env.Typecheck.functions with
              | Some ts -> lower_fn prefix d ts
              | None -> ())
          | Ast.ImplBlock d ->
              let okey = Typecheck.qualified_name prefix d.Ast.i_target_type in
              List.iter
                (fun (m : Ast.function_decl) ->
                  let ts_opt =
                    match
                      List.assoc_opt (okey, m.Ast.fn_sig.Ast.sig_name)
                        env.Typecheck.methods
                    with
                    | Some ts -> Some ts
                    | None ->
                        List.assoc_opt
                          (d.Ast.i_target_type, m.Ast.fn_sig.Ast.sig_name)
                          env.Typecheck.methods
                  in
                  match ts_opt with
                  | Some ts -> lower_fn prefix m ts
                  | None -> ())
                d.Ast.i_methods
          | _ -> ())
        n.Module_graph.node_items)
    graph.Module_graph.nodes;
  {
    Seed_mir.functions = Array.of_list (List.rev !lowered);
    statics = Driver.closure_statics env all_items;
    types = Driver.closure_types env;
  }

let find_main (prog : Seed_mir.program) : Seed_mir.function_ option =
  Array.to_list prog.Seed_mir.functions
  |> List.find_opt (fun (f : Seed_mir.function_) ->
         f.Seed_mir.name = "main" || Util.has_suffix f.Seed_mir.name "::main")

let run_seed_case (repo_root : string) (c : case_) : string =
  let root, manifest_path, cleanup = materialize_seed repo_root c in
  match c.layout with
  | Closure _ ->
      (* multi-module / std-prelude closures run through the driver's REAL
         seed closure pipeline (strict resolution, check fixpoint, lower,
         MIR verify, mono, VM).  The in-memory merged-program harness loses
         the per-item module context: a full-path call
         `stage0_ocaml::selfcheck::a::set()` and an aliased function import
         both fail to resolve there even though the real pipeline accepts
         them (evidence: "unknown name `stage0_ocaml::selfcheck::a`",
         "unknown function `a_set`"), so the real pipeline is the only
         faithful seed-side execution for these cases.  The VM's entry
         return value is the bootstrap exit code bs_vm_code. *)
      let target =
        match Target.unsupported_triple "aarch64-apple-darwin" with
        | Error m -> fail "target: %s" m
        | Ok t -> t
      in
      let mp = match manifest_path with Some m -> m | None -> fail "manifest missing" in
      let stages =
        match
          Driver.run_bootstrap_closure ~repo_root:root ~manifest_path:mp
            ~target ~entry:None ~kernel_args:[]
        with
        | Error m ->
            rm_rf cleanup;
            fail "%s: closure pipeline: %s" c.label m
        | Ok s -> s
      in
      (match stages.Driver.bs_vm_code with
      | Some code ->
          rm_rf cleanup;
          string_of_int code
      | None ->
          let errs = stages.Driver.bs_ctx.Driver.ctx_type_errors in
          List.iter
            (fun e -> Printf.printf "  closure type error: %s\n" e)
            (List.filteri (fun i _ -> i < 8) errs);
          rm_rf cleanup;
          fail "%s: the seed closure VM produced no exit value (%d typecheck error(s))"
            c.label (List.length errs))
  | Single_root _ ->
      let result =
        match Bootstrap_manifest.single ~file:root ~path:[] () with
        | Error e -> fail "%s: manifest: %s" c.label e
        | Ok manifest -> build_graph manifest
      in
      let env, _prog, graph = result in
      let prog = lower_all env graph in
      (match
         Mir_verify.require_valid_template
           ~generic_types:(Driver.closure_generic_types env)
           ~lang_items:(Typecheck.lang_items_of_env env)
           ~query_sigs:(Driver.closure_query_sigs ~lowered:(Some prog) env)
           prog
       with
      | Ok () -> ()
      | Error errs ->
          Printf.printf "MIR template verify errors for %s:\n" c.label;
          List.iter (fun e -> Printf.printf "  %s\n" e) errs;
          rm_rf cleanup;
          fail "%s: Mir_verify.require_valid_template rejected the program" c.label);
      let main_fn =
        match find_main prog with
        | Some f -> f
        | None ->
            rm_rf cleanup;
            fail "%s: no lowered main" c.label
      in
      let got =
        match
          Vm.entry_frame_of_li ~limits:Vm.default_limits
            ~lang_items:(Typecheck.lang_items_of_env env)
            ~program:prog ~entry:main_fn.Seed_mir.instance ~argv:[||]
        with
        | Error m ->
            rm_rf cleanup;
            fail "%s: VM entry: %s" c.label m
        | Ok (vm, entry_frame) -> (
            match Vm.run_inspect vm entry_frame with
            | Error m ->
                rm_rf cleanup;
                fail "%s: VM run: %s" c.label m
            | Ok got -> got)
      in
      rm_rf cleanup;
      got

(* ── the kernel side ────────────────────────────────────────────────── *)

(* The cases file consumed by the kernel battery's byte-identity check. *)
let cases_file_format () : string =
  let b = Buffer.create 8192 in
  Buffer.add_string b (Printf.sprintf "KRP_CASES %d\n" (List.length cases));
  List.iter
    (fun c ->
      let files =
        match c.layout with
        | Single_root src -> [ ("single", "__root__.tg", src) ]
        | Closure fs ->
            List.map
              (fun (k, n) ->
                if k = "std" then ("std", n, "")
                else ("selfcheck", n, closure_file_body k n))
              fs
      in
      Buffer.add_string b
        (Printf.sprintf "KRP_CASE %s %d %s %s %s\n" c.label (List.length files)
           c.dimension c.kernel_token c.seed_value);
      List.iter
        (fun (kind, name, body) ->
          Buffer.add_string b
            (Printf.sprintf "KRP_FILE %s %s %d\n" kind name (String.length body));
          Buffer.add_string b body)
        files)
    cases;
  Buffer.contents b

type kernel_row = {
  k_label : string;
  k_dimension : string;
  k_observable : string;
  k_verdict : string;
  k_reason : string;
}

let field_upto (line : string) (key : string) : string option =
  let k = key ^ "=" in
  let kl = String.length k in
  let n = String.length line in
  let rec find i =
    if i + kl > n then None
    else if String.sub line i kl = k then begin
      let j = ref (i + kl) in
      while !j < n && line.[!j] <> ' ' do
        incr j
      done;
      Some (String.sub line (i + kl) (!j - i - kl))
    end
    else find (i + 1)
  in
  find 0

let parse_kernel_rows (report : string) : kernel_row list =
  String.split_on_char '\n' report
  |> List.filter_map (fun line ->
         if String.length line > 15 && String.sub line 0 15 = "RUNTIME_PARITY "
         then begin
           let rest = String.sub line 15 (String.length line - 15) in
           match String.index_opt rest ' ' with
           | None -> None
           | Some i ->
               let label = String.sub rest 0 i in
               Some
                 {
                   k_label = label;
                   k_dimension =
                     (match field_upto line "dimension" with Some v -> v | None -> "?");
                   k_observable =
                     (match field_upto line "observable" with Some v -> v | None -> "?");
                   k_verdict =
                     (match field_upto line "verdict" with Some v -> v | None -> "?");
                   k_reason =
                     (match field_upto line "reason" with Some v -> v | None -> "");
                 }
         end
         else None)

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  ensure_dir (Filename.concat repo_root "build");
  let seed_only = Sys.getenv_opt "TG_KRP_SEED_ONLY" = Some "1" in
  (* seed rows first: the executed values are the comparison anchor. *)
  let seed_values =
    List.map
      (fun c ->
        let got = run_seed_case repo_root c in
        Printf.printf "SEED %s vm=%s expected=%s dimension=%s kernel_token=%s\n"
          c.label got c.seed_value c.dimension c.kernel_token;
        if got <> c.seed_value then
          fail "%s: seed VM executed %s, expected %s" c.label got c.seed_value;
        (c, got))
      cases
  in
  if seed_only then begin
    (* also materialize the cases file so the embedded kernel corpus can be
       byte-compared during development *)
    let cases_path = Filename.concat repo_root "build/runtime_parity_cases.txt" in
    write_file cases_path (cases_file_format ());
    Printf.printf
      "tg_kernel_runtime_parity: DEV MODE (TG_KRP_SEED_ONLY=1) — kernel comparison skipped; no pass claim (cases written to %s)\n"
      cases_path;
    exit 2
  end;
  let cases_path = Filename.concat repo_root "build/runtime_parity_cases.txt" in
  write_file cases_path (cases_file_format ());
  let report_path = Filename.concat repo_root "build/infer_probe.txt" in
  (try Sys.remove report_path with Sys_error _ -> ());
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let t0 = Unix.gettimeofday () in
  let run =
    match
      Driver.run_bootstrap_vm ~repo_root
        ~manifest_path:"bootstrap/infer_mini.manifest" ~target ~entry:None
        ~kernel_args:[ "infer"; "-o"; "infer_probe.out" ]
        ~vm_cache:(Filename.concat repo_root "build/kernel_runtime_parity.vmcache")
        ()
    with
    | Error m -> fail "kernel closure pipeline: %s" m
    | Ok run -> run
  in
  let dt = Unix.gettimeofday () -. t0 in
  (match run.Driver.bvr_vm_code with
  | Some 0 -> ()
  | Some code ->
      if run.Driver.bvr_stdout <> "" then
        Printf.printf "kernel stdout:\n%s\n" run.Driver.bvr_stdout;
      fail "kernel probe VM exit %d (expected 0) after %.1fs" code dt
  | None ->
      if run.Driver.bvr_stdout <> "" then
        Printf.printf "kernel stdout:\n%s\n" run.Driver.bvr_stdout;
      if run.Driver.bvr_stderr <> "" then
        Printf.printf "kernel stderr:\n%s\n" run.Driver.bvr_stderr;
      fail "the kernel VM run did not complete (upstream stage failed)");
  if not (Sys.file_exists report_path) then
    fail "kernel probe report %s missing" report_path;
  let report = read_file report_path in
  if not (contains_sub report "RUNTIME_PARITY_BATTERY fails=0") then begin
    (* print the battery rows to make the failure actionable *)
    String.split_on_char '\n' report
    |> List.iter (fun l ->
           if
             contains_sub l "RUNTIME_PARITY"
             || contains_sub l "RUNTIME "
           then Printf.printf "%s\n" l);
    fail "the kernel RUNTIME_PARITY battery reported failures (rows above)"
  end;
  let rows = parse_kernel_rows report in
  let mismatches = ref 0 in
  let blocked = ref [] in
  List.iter
    (fun ((c : case_), seed_got) ->
      let matches =
        List.filter (fun (k : kernel_row) -> k.k_label = c.label) rows
      in
      match matches with
      | [] ->
          Printf.printf
            "COMPARE %s MISMATCH: the kernel battery emitted no RUNTIME_PARITY row\n"
            c.label;
          incr mismatches
      | _ :: _ :: _ ->
          Printf.printf "COMPARE %s MISMATCH: duplicate kernel rows\n" c.label;
          incr mismatches
      | [ k ] -> (
          if k.k_verdict = "blocked" then begin
            blocked := (c.label, k.k_reason) :: !blocked;
            Printf.printf
              "COMPARE %s BLOCKED dimension=%s reason=%s\n" c.label k.k_dimension
              k.k_reason
          end
          else begin
            let token_match = k.k_observable = c.kernel_token in
            if not token_match then incr mismatches;
            Printf.printf
              "COMPARE %s dimension=%s seed_vm=%s kernel_observable=%s expected=%s verdict=%s\n"
              c.label c.dimension seed_got k.k_observable c.kernel_token
              (if token_match then "match" else "MISMATCH")
          end))
    seed_values;
  if !blocked <> [] then begin
    Printf.printf "KERNEL_RUNTIME_PARITY blocked=%d:\n" (List.length !blocked);
    List.iter (fun (l, r) -> Printf.printf "  BLOCKED %s reason=%s\n" l r)
      (List.rev !blocked)
  end;
  Printf.printf "KERNEL_RUNTIME_PARITY compared=%d mismatches=%d blocked=%d\n"
    (List.length seed_values) !mismatches (List.length !blocked);
  if !mismatches <> 0 || !blocked <> [] then
    fail
      "%d runtime parity mismatch(es), %d blocked case(s) (see the rows above)"
      !mismatches (List.length !blocked);
  Printf.printf
    "PASS: seed execution values and kernel observables agree on %d runtime-parity cases (no case silently skipped)\n"
    (List.length seed_values);
  Selfcheck_sentinel.emit_and_exit "tg_kernel_runtime_parity"
