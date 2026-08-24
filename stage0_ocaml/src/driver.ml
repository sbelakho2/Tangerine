(* driver.ml — CLI driver for the OCaml stage0 bootstrap compiler.

   Command surface (audit §47-51):
     lex <file>             Lex and print tokens
     parse <file>           UTF8 -> lex -> parse -> structural verification
     check <file>           parse + bootstrap profile + resolution + typing
     dump-ast <file>        Deterministic AST dump
     dump-resolved <file>   Resolution report
     dump-types <file>      Typing report
     lower <file>           check + mono + Seed MIR + verifier + dump
     interpret <args...>    Interpret a compiled Seed MIR artifact
     compile <args...>      Bootstrap compile (interprets the compiler)
     bootstrap-check        Full seed-quality gate over the manifest
     version / help

   Strict option parsing: an unknown option exits nonzero (audit §47). *)

let version_string = "tg_stage0 0.2.0 (OCaml bootstrap seed)"

let usage =
  {|Usage: tg_stage0 <command> [args]

Commands:
  lex <file>                Lex a .tg file and print tokens
  parse <file>              UTF8 -> lex -> parse -> structural verification
  check <file>              parse + profile + resolution + typing
  dump-ast <file>           Deterministic AST dump
  lower <file>              check + mono + Seed MIR + verifier + dump
  bootstrap-check           Full seed-quality gate over the manifest closure
    --repo-root ROOT
    --manifest FILE
    --target TRIPLE
  compile ...               Bootstrap compile (interprets the compiler)
  version                   Print version info
  help                      Print this help message
|}

let die fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt

(* ── Strict option parsing (audit §47) ─────────────────────────── *)

type 'a opt_spec = {
  name : string;
  takes_value : bool;
  apply : string option -> 'a -> 'a;
}

let parse_options (specs : 'a opt_spec list) (default : 'a) (args : string list) :
    'a * string list =
  let rec go acc = function
    | [] -> (acc, [])
    | arg :: rest ->
        if String.length arg >= 2 && arg.[0] = '-' && arg <> "-" then begin
          let eq = String.index_opt arg '=' in
          let name, inline =
            match eq with
            | Some i -> (String.sub arg 0 i, Some (String.sub arg (i + 1) (String.length arg - i - 1)))
            | None -> (arg, None)
          in
          match List.find_opt (fun s -> s.name = name) specs with
          | None -> die "unknown option '%s'" name
          | Some spec ->
              if spec.takes_value then begin
                match inline with
                | Some v -> go (spec.apply (Some v) acc) rest
                | None -> (
                    match rest with
                    | v :: rest' when not (String.length v >= 2 && v.[0] = '-') ->
                        go (spec.apply (Some v) acc) rest'
                    | _ -> die "option '%s' requires a value" name)
              end
              else begin
                if inline <> None then die "option '%s' does not take a value" name;
                go (spec.apply None acc) rest
              end
        end
        else (acc, arg :: rest)
  in
  go default args

(* ── Front-end (parse / check / dump-ast) ──────────────────────── *)

let load_source_or_report (path : string) : Source.source option =
  match Source_loader.load path with
  | Ok s -> Some s
  | Error e -> (
      match e with
      | Source_loader.Unreadable p -> die "cannot read file '%s'" p
      | Source_loader.NotUTF8 (p, uerr) ->
          die "E9029: source file is not valid UTF-8: '%s' (%s at byte %d)" p
            (Utf8.error_string uerr.Utf8.kind) uerr.Utf8.offset
      | Source_loader.Security (p, msg) -> die "source security scan failed: '%s' (%s)" p msg)

let front_end (path : string) : (Diagnostic.bag * Span.source_map * Ast.program) =
  let src = match load_source_or_report path with Some s -> s | None -> exit 1 in
  let sm = Span.create () in
  let file_id = Span.add_file sm src.Source.name src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let module_path = Parser.module_path_of_file path in
  let program = Parser.parse tokens src.Source.bytes file_id diags module_path in
  if not (Diagnostic.has_errors diags) then Verify.verify diags program;
  (diags, sm, program)

let report_errors (diags : Diagnostic.bag) (sm : Span.source_map) : unit =
  if Diagnostic.has_errors diags || Diagnostic.has_warnings diags then begin
    prerr_string ("\n" ^ Diagnostic.render sm diags ^ "\n");
    if Diagnostic.has_errors diags then exit 1
  end

let cmd_lex (args : string list) : int =
  match args with
  | path :: _ ->
      let src = match load_source_or_report path with Some s -> s | None -> exit 1 in
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      List.iter
        (fun t ->
          match Span.resolve sm t.Token.span with
          | Some (_, line, col) -> Printf.printf "%d:%d  %s\n" line col (Token.display_name t.Token.kind)
          | None -> Printf.printf "?:?  %s\n" (Token.display_name t.Token.kind))
        tokens;
      report_errors diags sm;
      Printf.printf "\n%d tokens, 0 errors\n" (List.length tokens);
      0
  | [] -> die "'lex' requires a file path"

let cmd_parse (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      Printf.printf "Parsed %d top-level items\n" (List.length program.Ast.items);
      List.iter (fun i -> Printf.printf "  %s\n" (Ast.item_summary i.Ast.kind)) program.Ast.items;
      0
  | [] -> die "'parse' requires a file path"

let cmd_check (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      if not (Diagnostic.has_errors diags) then Subset.check diags program;
      report_errors diags sm;
      Printf.printf "Checked %d top-level items: 0 errors, %d warnings\n"
        (List.length program.Ast.items)
        (Diagnostic.warning_count diags);
      0
  | [] -> die "'check' requires a file path"

let cmd_dump_ast (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      print_string (Dump.dump program);
      print_newline ();
      0
  | [] -> die "'dump-ast' requires a file path"

(* Typecheck modules in import-dependency (topological) order so that
   forward references between kernel modules resolve (the manifest lists
   modules alphabetically, not dependency-ordered). *)
let topological_nodes (graph : Module_graph.t) : Module_graph.module_node list =
  (* Deduplicate by source file: lib_kernel.tg creates re-export subtree
     nodes whose node_path aliases the same file (e.g. lib_kernel::token
     vs token). Prefer the canonical (non-lib_kernel) copy. *)
  let seen_files = Hashtbl.create 64 in
  let canonical =
    List.filter
      (fun node ->
        if Hashtbl.mem seen_files node.Module_graph.node_file then false
        else begin
          Hashtbl.add seen_files node.Module_graph.node_file ();
          true
        end)
      graph.Module_graph.nodes
  in
  let nodes = Array.of_list canonical in
  let n = Array.length nodes in
  let by_path = Hashtbl.create 64 in
  Array.iteri
    (fun i node -> Hashtbl.replace by_path (String.concat "::" node.Module_graph.node_path) i)
    nodes;
  let deps = Array.make n [] in
  let rdeps = Array.make n [] in
  Array.iteri
    (fun i node ->
      let imports =
        List.filter_map
          (fun it -> match it.Ast.kind with Ast.UseDecl u -> Some u | _ -> None)
          node.Module_graph.node_program.Ast.items
      in
      let add (path : string list) =
        match Hashtbl.find_opt by_path (String.concat "::" path) with
        | Some j when j <> i ->
            deps.(i) <- j :: deps.(i);
            rdeps.(j) <- i :: rdeps.(j)
        | _ -> ()
      in
      List.iter
        (fun (u : Ast.use_decl) ->
          match u.Ast.u_path with
          | Ast.UseSimple p | Ast.UseAliased (p, _) | Ast.UseGlob p -> add p
          | Ast.UseGroup (p, items) ->
              add p;
              List.iter
                (fun (it : Ast.use_item) -> add (p @ [ it.Ast.ui_name ]))
                items)
        imports)
    nodes;
  let indeg = Array.map List.length deps in
  Array.iteri
    (fun i node ->
      Printf.printf "      topo %d %s deps=%s\n" i (String.concat "::" node.Module_graph.node_path)
        (String.concat "," (List.map string_of_int deps.(i))))
    nodes;
  let queue = Queue.create () in
  Array.iteri (fun i d -> if d = 0 then Queue.push i queue) indeg;
  let order = ref [] in
  while not (Queue.is_empty queue) do
    let i = Queue.pop queue in
    order := i :: !order;
    List.iter (fun j ->
      indeg.(j) <- indeg.(j) - 1;
      if indeg.(j) = 0 then Queue.push j queue) rdeps.(i)
  done;
  let order = List.rev !order in
  Printf.printf "      kahn order: %s\n"
    (String.concat "," (List.map string_of_int order));
  if List.length order <> n then begin
    (* import cycles exist: append the remaining nodes in manifest order;
       cross-module forward references are then resolved by the flat
       global namespace (the resolver's contract). *)
    let in_order = Hashtbl.create 16 in
    List.iter (fun i -> Hashtbl.add in_order i ()) order;
    let rest =
      List.filter (fun i -> not (Hashtbl.mem in_order i)) (List.init n Fun.id)
    in
    List.map (Array.get nodes) (order @ rest)
  end
  else List.map (Array.get nodes) order

(* Build the Mir_lower func_env from the typed environment. *)
let lowering_env_of (env : Typecheck.env) : Mir_lower.func_env =
  let values =
    List.map
      (fun (n, ts : string * Typecheck.typed_signature) -> (n, ts.Typecheck.ts_return))
      env.Typecheck.functions
  in
  let callables =
    List.map
      (fun (n, ts : string * Typecheck.typed_signature) -> (n, Ids.Callable_id.to_int ts.Typecheck.ts_callable))
      env.Typecheck.functions
  in
  let methods =
    List.map
      (fun ((t, m), ts : (string * string) * Typecheck.typed_signature) ->
        ((t, m), Ids.Instance_id.make ~callable:ts.Typecheck.ts_callable ~type_args:[||]))
      env.Typecheck.methods
  in
  {
    Mir_lower.types = env.Typecheck.types;
    values;
    callables;
    methods;
    fn_ret = Type_repr.Unit;
  }

let lower_and_report (path : string) (env : Typecheck.env) (program : Ast.program) : int =
  let module_path = Parser.module_path_of_file path in
  let funcs =
    List.filter_map
      (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
      program.Ast.items
  in
  Printf.printf "// lower %s (module %s): %d items, %d functions\n" path
    (String.concat "::" module_path)
    (List.length program.Ast.items)
    (List.length funcs);
  let base = lowering_env_of env in
  let mir_funcs =
    List.mapi
      (fun i d ->
        let fn_ret, callable =
          match List.assoc_opt d.Ast.fn_sig.Ast.sig_name env.Typecheck.functions with
          | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
          | None -> (Type_repr.Unit, i)
        in
        Mir_lower.lower_function { base with Mir_lower.fn_ret } d.Ast.fn_sig.Ast.sig_name
          callable d)
      funcs
  in
  let prog =
    { Seed_mir.functions = Array.of_list mir_funcs; statics = [||]; types = [||] }
  in
  match Mir_verify.require_valid prog with
  | Error errs ->
      Printf.printf "// MIR verify FAILED:\n";
      List.iter (fun e -> Printf.printf "//   %s\n" e) errs;
      1
  | Ok () ->
      Printf.printf "// MIR verify PASS (%d functions)\n" (Array.length prog.Seed_mir.functions);
      print_string (Seed_mir.print_program prog);
      (match
         Array.to_list prog.Seed_mir.functions
         |> List.find_opt (fun f -> f.Seed_mir.name = "main")
       with
      | None -> 0
      | Some main ->
          let host = Host.create ~repo_root:"." ~argv:[||] in
          (match Vm.run ~program:prog ~entry:main.Seed_mir.instance ~argv:[||] ~host with
           | Ok _ -> Printf.printf "// VM: exit 0\n"; 0
           | Error e -> Printf.printf "// VM: %s\n" e.Vm.message; 1))


let cmd_lower (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      Subset.check diags program;
      report_errors diags sm;
      let env = Typecheck.initial_env () in
      (match Typecheck.check_program env program with
       | Error m -> die "typecheck failed: %s" m
       | Ok (env, errors) ->
           List.iter (fun e -> Printf.printf "  type error: %s\n" e) (List.rev errors);
           if errors <> [] then begin
             Printf.printf "lower %s: FAILED (typecheck)\n" path;
             1
           end
           else lower_and_report path env program)
  | [] -> die "'lower' requires a file path"

(* ── bootstrap-check (audit §51) ───────────────────────────────── *)

type boot_opts = {
  repo_root : string;
  manifest : string;
  target : string;
}

let cmd_bootstrap_check (args : string list) : int =
  let specs =
    [
      { name = "--repo-root"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with repo_root = v } | None -> o) };
      { name = "--manifest"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with manifest = v } | None -> o) };
      { name = "--target"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with target = v } | None -> o) };
    ]
  in
  let opts, positional = parse_options specs { repo_root = "."; manifest = "bootstrap/compiler_kernel.manifest"; target = "aarch64-apple-darwin" } args in
  if positional <> [] then die "unexpected positional arguments to bootstrap-check";
  let target =
    match Target.unsupported_triple opts.target with
    | Ok t -> t
    | Error m -> die "%s" m
  in
  Printf.printf "TANGERINE OCAML SEED — bootstrap-check\n";
  Printf.printf "  target: %s\n" (Target.to_string target);
  (match Bootstrap_manifest.load ~repo_root:opts.repo_root ~manifest_path:opts.manifest with
   | Error m -> die "manifest: %s" m
   | Ok manifest ->
       let n = List.length (Bootstrap_manifest.entries manifest) in
       Printf.printf "  manifest: %d entries, version %s\n" n
         (match Bootstrap_manifest.version_of manifest with Some v -> v | None -> "(none)");
       Printf.printf "  fingerprint: %s\n" (Bootstrap_manifest.fingerprint manifest);
       let diags = Diagnostic.create_bag () in
       let graph = Module_graph.create_with_root opts.repo_root manifest diags in
       Printf.printf "  module graph: %d modules, %d items\n" graph.Module_graph.node_count
         graph.Module_graph.item_count;
       let resolved = Resolver.resolve manifest graph diags in
       Printf.printf "  resolver: %d expr defs, %d type defs, %d field defs, %d variant defs, %d call candidates\n"
         (List.length resolved.Resolver.expr_defs)
         (List.length resolved.Resolver.type_defs)
         (List.length resolved.Resolver.field_defs)
         (List.length resolved.Resolver.variant_defs)
         (List.length resolved.Resolver.call_candidates);
       if Diagnostic.has_errors diags then begin
         prerr_string (Diagnostic.render (Module_graph.source_map graph) diags);
         prerr_newline ();
         Printf.printf "  RESULT: FAIL\n";
         1
       end
       else begin
         Printf.printf "  diagnostics: 0\n";
         (* typecheck modules to a fixpoint: registration is non-fatal, so
            modules with forward/cyclic references retry with the growing
            env until no module makes progress *)
         let env = ref (Typecheck.initial_env ()) in
         let type_errors = ref [] in
         let items = ref 0 in
         let functions = ref 0 in
         let pending = ref (topological_nodes graph) in
         let rounds = ref 0 in
         while !pending <> [] && !rounds < 8 do
           incr rounds;
           let this_round = !pending in
           pending := [];
           List.iter
             (fun node ->
               match Typecheck.check_program !env node.Module_graph.node_program with
               | Error m ->
                   type_errors :=
                     (String.concat "::" node.Module_graph.node_path ^ ": " ^ m)
                     :: !type_errors
               | Ok (env', errors) ->
                   env := env';
                   if errors <> [] then begin
                     pending := node :: !pending;
                     type_errors :=
                       List.rev_append
                         (List.map
                            (fun e ->
                              String.concat "::" node.Module_graph.node_path ^ ": " ^ e)
                            errors)
                         !type_errors
                   end)
             this_round
         done;
         List.iter
           (fun node ->
             items := !items + List.length node.Module_graph.node_items)
           (topological_nodes graph);
         Printf.printf "  typecheck: %d modules, %d items, %d errors (%d rounds)\n"
           graph.Module_graph.node_count !items (List.length !type_errors) !rounds;
         List.iter (fun e -> Printf.printf "    %s\n" e) (List.rev !type_errors);
         if !type_errors <> [] then begin
           Printf.printf "  RESULT: FAIL\n";
           1
         end
         else begin
           (* lower the whole closure into one Seed MIR program and verify *)
           let base = lowering_env_of !env in
           let mir_funcs = ref [] in
           List.iter
             (fun node ->
               let funcs =
                 List.filter_map
                   (fun i -> match i.Ast.kind with Ast.Function fd -> Some fd | _ -> None)
                   node.Module_graph.node_items
               in
               List.iter
                 (fun fd ->
                   let fn_ret, callable =
                     match List.assoc_opt fd.Ast.fn_sig.Ast.sig_name env.contents.Typecheck.functions with
                     | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     | None -> (Type_repr.Unit, 0)
                   in
                   let f =
                     Mir_lower.lower_function { base with Mir_lower.fn_ret }
                       fd.Ast.fn_sig.Ast.sig_name callable fd
                   in
                   mir_funcs := f :: !mir_funcs)
                 funcs;
               functions := !functions + List.length funcs)
             graph.Module_graph.nodes;
           let prog =
             { Seed_mir.functions = Array.of_list (List.rev !mir_funcs); statics = [||]; types = [||] }
           in
           (match Mir_verify.require_valid prog with
            | Error errs ->
                Printf.printf "  MIR verify: FAIL (%d functions)\n"
                  (Array.length prog.Seed_mir.functions);
                List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                Printf.printf "  RESULT: FAIL\n";
                1
            | Ok () ->
                Printf.printf "  MIR verify: PASS (%d functions)\n"
                  (Array.length prog.Seed_mir.functions);
                Printf.printf "  RESULT: PASS\n";
                0)
         end
       end)

let cmd_compile (_args : string list) : int =
  die "compile is not yet available: the seed VM must first interpret the bootstrap closure (audit §49)"

let cmd_version () : int =
  print_string (version_string ^ "\n");
  0

let main () : int =
  let args = Array.to_list Sys.argv in
  match args with
  | _ :: cmd :: rest -> (
      match cmd with
      | "lex" -> cmd_lex rest
      | "parse" -> cmd_parse rest
      | "check" -> cmd_check rest
      | "dump-ast" -> cmd_dump_ast rest
      | "lower" -> cmd_lower rest
      | "bootstrap-check" -> cmd_bootstrap_check rest
      | "compile" -> cmd_compile rest
      | "version" -> cmd_version ()
      | "help" ->
          print_string usage;
          0
      | other -> die "unknown command '%s'" other)
  | _ ->
      print_string usage;
      0
