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
    --entry NAME
  compile ...               Bootstrap compile (interprets the compiler)
    --repo-root ROOT
    --manifest FILE
    --target TRIPLE
    --entry NAME
    -- <kernel args...>     Passed verbatim to the kernel's bootstrap_main
                            (e.g. -- compile hello.tg -o /tmp/out)
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
    | "--" :: rest -> (acc, rest)   (* everything after -- is positional *)
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

(* Flat-namespace signature lookup (kernel code uses bare names). *)
let lookup_typed_fn (env : Typecheck.env) (name : string) : Typecheck.typed_signature option =
  match List.assoc_opt name env.Typecheck.functions with
  | Some ts -> Some ts
  | None -> (
      match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) env.Typecheck.functions with
      | [ (_, ts) ] -> Some ts
      | _ -> None)

let lowering_env_of (env : Typecheck.env) : Mir_lower.func_env =
  (* both the qualified key and the bare name resolve (flat namespace) *)
  let values =
    List.concat_map
      (fun (n, ts : string * Typecheck.typed_signature) ->
        let bare =
          match String.rindex_opt n ':' with
          | Some i -> [ (String.sub n (i + 1) (String.length n - i - 1), ts.Typecheck.ts_return) ]
          | None -> []
        in
        (n, ts.Typecheck.ts_return) :: bare)
      env.Typecheck.functions
    (* enum variant constructors are callable values: their registered
       result type lets lowering build the EnumCtor aggregate *)
    @ List.map (fun (n, ts) -> (n, ts.Typecheck.ts_return)) env.Typecheck.constructors
  in
  let callables =
    List.concat_map
      (fun (n, ts : string * Typecheck.typed_signature) ->
        let entry : Mir_lower.callable_entry =
          {
            ce_callable = Ids.Callable_id.to_int ts.Typecheck.ts_callable;
            (* the template instance declares the generic params in
               declaration order, so the monomorphizer can construct
               exact substitutions *)
            ce_template_args =
              Array.of_list
                (List.map
                   (fun (_, pid) -> Type_repr.Type_param pid)
                   ts.Typecheck.ts_params_decl);
            ce_params = ts.Typecheck.ts_params;
          }
        in
        let bare =
          match String.rindex_opt n ':' with
          | Some i -> [ (String.sub n (i + 1) (String.length n - i - 1), entry) ]
          | None -> []
        in
        (n, entry) :: bare)
      env.Typecheck.functions
  in
  let methods =
    List.map
      (fun ((t, m), ts : (string * string) * Typecheck.typed_signature) ->
        ((t, m), Instance_id.make ~callable:ts.Typecheck.ts_callable ~type_args:[||]))
      env.Typecheck.methods
  in
  {
    Mir_lower.types = env.Typecheck.types;
    values;
    callables;
    methods;
    fn_ret = Type_repr.Unit;
  }

(* ── User-enum variant table (re-audit finding: the closure driver never
      fed lowering the typechecker's enum/VariantId universe) ─────────

   mir_lower's variant_table (vt_enums: enum name -> variant name ->
   {vs_index; vs_fields}; vt_ctors: bare ctor name -> (enum name,
   variant name)) is built HERE from the TYPED nominal registry — the
   same semantic registry closure_types reads for the EnumDefs — never
   from re-parsing the AST.  Only concrete (non-generic) enums are
   tabled: generic payloads are deferred to post-mono, and the builtin
   Option/Result stay on mir_lower's hardcoded fallback (their fields
   derive from the enum's type arguments at each use site).  The
   declaration-order vs_index is exactly the EnumDef variant position,
   so construction sites (EnumCtor tags), match arms (SwitchInt
   targets) and the typed EnumDefs (semantic VariantIds from
   nom_variant_ids) agree.  The nominal is validated against its
   semantic variant-id registry (fail closed on a length mismatch). *)
let user_variant_table (env : Typecheck.env) : Mir_lower.variant_table =
  let enums =
    List.filter_map
      (fun (name, nom : string * Typecheck.nominal) ->
        match nom.Typecheck.nom_kind with
        | `Struct -> None
        | `Enum ->
            if nom.Typecheck.nom_params <> [] then None
            else begin
              let nvar = List.length nom.Typecheck.nom_variants in
              if List.length nom.Typecheck.nom_variant_ids <> nvar then
                die "enum `%s`: %d variants but %d semantic VariantIds" name nvar
                  (List.length nom.Typecheck.nom_variant_ids);
              Some
                ( name,
                  List.mapi
                    (fun i (vname, pty) ->
                      (vname, { Mir_lower.vs_index = i; vs_fields = Array.to_list pty }))
                    nom.Typecheck.nom_variants )
            end)
      env.Typecheck.nominals
  in
  let ctors =
    List.concat_map
      (fun (ename, specs) ->
        List.map (fun (vname, _) -> (vname, (ename, vname))) specs)
      enums
  in
  { Mir_lower.vt_enums = enums; vt_ctors = ctors }

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
        let fn_ret, callable, template_args =
          match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
          | Some ts ->
              ( ts.Typecheck.ts_return,
                Ids.Callable_id.to_int ts.Typecheck.ts_callable,
                Array.of_list
                  (List.map
                     (fun (_, pid) -> Type_repr.Type_param pid)
                     ts.Typecheck.ts_params_decl) )
          | None -> (Type_repr.Unit, i, [||])
        in
        let conventions =
          match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
          | Some ts ->
              Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params
          | None -> [||]
        in
        Mir_lower.lower_function_with_variants (user_variant_table env)
          { base with Mir_lower.fn_ret }
          d.Ast.fn_sig.Ast.sig_name callable template_args conventions d)
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
      if Diagnostic.has_errors diags then 1
      else begin
        (* the advertised semantics: parse + profile + resolution + typing *)
        let env = Typecheck.initial_env () in
        match Typecheck.check_program env program with
        | Error m -> die "typecheck failed: %s" m
        | Ok (_, errors) ->
            if errors <> [] then begin
              List.iter (fun e -> Printf.printf "  %s\n" e) (List.rev errors);
              Printf.printf "Checked %d top-level items: %d errors, %d warnings\n"
                (List.length program.Ast.items) (List.length errors)
                (Diagnostic.warning_count diags);
              1
            end
            else begin
              Printf.printf "Checked %d top-level items: 0 errors, %d warnings\n"
                (List.length program.Ast.items)
                (Diagnostic.warning_count diags);
              0
            end
      end
  | [] -> die "'check' requires a file path"

(* interpret: lower a file and run its main through the seed VM, printing
   the return value (audit: the dispatcher advertised interpret but had no
   branch). *)
let cmd_interpret (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      if Diagnostic.has_errors diags then 1
      else begin
        let env = Typecheck.initial_env () in
        match Typecheck.check_program env program with
        | Error m -> die "typecheck failed: %s" m
        | Ok (env, errors) ->
            if errors <> [] then begin
              List.iter (fun e -> Printf.printf "  %s\n" e) (List.rev errors);
              1
            end
            else begin
              let funcs =
                List.filter_map
                  (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                  program.Ast.items
              in
              let base = lowering_env_of env in
              let mir_funcs =
                List.mapi
                  (fun i d ->
                    let fn_ret, callable =
                      match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
                      | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                      | None -> (Type_repr.Unit, i)
                    in
                    Mir_lower.lower_function_with_variants (user_variant_table env)
                      { base with Mir_lower.fn_ret }
                      d.Ast.fn_sig.Ast.sig_name callable [||] [||] d)
                  funcs
              in
              let prog =
                { Seed_mir.functions = Array.of_list mir_funcs; statics = [||]; types = [||] }
              in
              (match Mir_verify.require_valid prog with
               | Error errs ->
                   List.iter (fun e -> Printf.printf "  %s\n" e) errs;
                   1
               | Ok () -> (
                   match
                     Array.to_list prog.Seed_mir.functions
                     |> List.find_opt (fun f -> f.Seed_mir.name = "main")
                   with
                   | None -> die "no `main` function to interpret"
                   | Some main -> (
                       match Vm.entry_frame_of ~program:prog ~entry:main.Seed_mir.instance ~argv:[||] with
                       | Error m -> die "interpret: %s" m
                       | Ok (vm, entry_frame) -> (
                           match Vm.run_inspect vm entry_frame with
                           | Ok ret ->
                               Printf.printf "%s\n" ret;
                               0
                           | Error m ->
                               Printf.printf "interpret failed: %s\n" m;
                               1))))
            end
      end
  | [] -> die "'interpret' requires a file path"

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

(* ── bootstrap-check / compile shared machinery ─────────────────── *)

type boot_opts = {
  repo_root : string;
  manifest : string;
  target : string;
  entry : string option;
}

let default_boot_opts =
  {
    repo_root = ".";
    manifest = "bootstrap/compiler_kernel.manifest";
    target = "aarch64-apple-darwin";
    entry = None;
  }

let boot_specs =
  [
    { name = "--repo-root"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with repo_root = v } | None -> o) };
    { name = "--manifest"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with manifest = v } | None -> o) };
    { name = "--target"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with target = v } | None -> o) };
    { name = "--entry"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with entry = Some v } | None -> o) };
  ]

(* ── @cfg elimination (audit @cfg P0) ──────────────────────────── *)

(* Cut the eliminated items' byte spans out of a module's source text.
   The spans are the MAXIMAL removed spans returned by the pass (an
   eliminated inline module covers its children), disjoint and sorted by
   start, so the re-parse of the cut text is exactly the kept program. *)
let cut_spans (text : string) (spans : Span.span list) : string =
  let sorted = List.sort (fun a b -> compare a.Span.start b.Span.start) spans in
  let buf = Buffer.create (String.length text) in
  let rec go pos = function
    | [] -> Buffer.add_substring buf text pos (String.length text - pos)
    | (s : Span.span) :: rest ->
        Buffer.add_substring buf text pos (s.Span.start - pos);
        go s.Span.end_ rest
  in
  go 0 sorted;
  Buffer.contents buf

(* Apply @cfg elimination over every module program: AFTER the
   parse/merge (the module graph), BEFORE the resolver's duplicate/name
   registration and the type checker. Each module's target-contradicting
   declarations are physically removed from the source snapshot (the
   eliminated spans are cut out and the graph is re-parsed), so the
   resolver, the typechecker and everything downstream only ever see the
   target's semantic program — an eliminated declaration does not exist
   for this target and cannot be resurrected by any reference. Fail
   closed: an empty @cfg() (E108), a malformed predicate or an unknown
   target key renders its diagnostics and aborts the pipeline BEFORE the
   resolver runs — a bad gate never silently stays active. *)
let apply_cfg_elimination ~(manifest : Bootstrap_manifest.t) ~(graph : Module_graph.t)
    (target : Target.t) : (Module_graph.t * int, string) result =
  let ctx = Target.Cfg_context.of_target target in
  let manifest_ref = ref manifest in
  let total = ref 0 in
  let cfg_errors = ref [] in
  let file_nodes =
    List.filter (fun n -> n.Module_graph.node_parent = None) graph.Module_graph.nodes
  in
  List.iter
    (fun node ->
      let key = String.concat "::" node.Module_graph.node_path in
      match Target.eliminate_program ctx node.Module_graph.node_program with
      | Error ds -> cfg_errors := !cfg_errors @ ds
      | Ok r ->
          if r.Target.elim_removed > 0 then begin
            total := !total + r.Target.elim_removed;
            Printf.printf "  cfg: module %s eliminated %d items\n" key r.Target.elim_removed;
            (match Bootstrap_manifest.find manifest node.Module_graph.node_path with
             | None -> ()
             | Some entry ->
                 let text = cut_spans entry.Bootstrap_manifest.source r.Target.elim_spans in
                 manifest_ref :=
                   Bootstrap_manifest.with_entry_source !manifest_ref node.Module_graph.node_path
                     text)
          end)
    file_nodes;
  if !cfg_errors <> [] then begin
    prerr_string
      (Diagnostic.render (Module_graph.source_map graph)
         { Diagnostic.diagnostics = List.rev !cfg_errors });
    prerr_newline ();
    Error "cfg elimination diagnostics"
  end
  else begin
    let reparse_diags = Diagnostic.create_bag () in
    let graph' = Module_graph.create_with_sources !manifest_ref reparse_diags in
    if Diagnostic.has_errors reparse_diags then begin
      prerr_string (Diagnostic.render (Module_graph.source_map graph') reparse_diags);
      prerr_newline ();
      Error "cfg elimination re-parse diagnostics"
    end
    else begin
      (* Sanity: the re-parse of the cut sources must reproduce exactly the
         filtered programs (an off-by-one span cut is an internal error,
         not a silent semantic change). *)
      List.iter
        (fun node ->
          match Target.eliminate_program ctx node.Module_graph.node_program with
          | Error _ -> ()
          | Ok r ->
              if r.Target.elim_removed > 0 then begin
                match Module_graph.find_module_by_path graph' node.Module_graph.node_path with
                | Some n ->
                    if List.length n.Module_graph.node_items
                       <> List.length r.Target.elim_program.Ast.items
                    then
                      failwith
                        (Printf.sprintf
                           "cfg elimination internal error: module %s re-parse diverged (%d items, expected %d)"
                           (String.concat "::" node.Module_graph.node_path)
                           (List.length n.Module_graph.node_items)
                           (List.length r.Target.elim_program.Ast.items))
                | None ->
                    failwith
                      (Printf.sprintf
                         "cfg elimination internal error: module %s missing from the re-parsed graph"
                         (String.concat "::" node.Module_graph.node_path))
              end)
        file_nodes;
      Printf.printf "  cfg: total eliminated across closure: %d items\n" !total;
      Ok (graph', !total)
    end
  end

(* ── Executable-subset firewall over the manifest closure ─────────
   (re-audit P1 finding 1): the aggregate bootstrap path previously
   never called Subset.check over the actual manifest programs — only
   the standalone check/lower commands and the gate's synthetic
   specimens did.  run_closure_pipeline now runs Subset.check over EVERY
   module program of the cfg-filtered closure, AFTER the module graph +
   @cfg elimination and BEFORE the resolver/typechecker, with a FRESH
   diagnostic bag per module: the findings are a SEPARATE channel and
   can never inflate the resolver diagnostics or the typecheck debt
   (debt_total is a typecheck-only count). *)

type subset_module = {
  ssm_key : string;                   (* module path key *)
  ssm_findings : (string * int) list; (* E-code -> count, sorted by code *)
  ssm_total : int;
}

type subset_result = {
  sr_modules : subset_module list;  (* dedup by source file *)
  sr_accepted : int;
  sr_rejected : int;
  sr_total : int;
}

let subset_firewall_of_graph (graph : Module_graph.t) : subset_result =
  (* Deduplicate by source file: lib_kernel.tg creates re-export subtree
     nodes whose node_file aliases the same file (same rule as
     topological_nodes). *)
  let seen = Hashtbl.create 64 in
  let nodes =
    List.filter
      (fun node ->
        if Hashtbl.mem seen node.Module_graph.node_file then false
        else begin
          Hashtbl.add seen node.Module_graph.node_file ();
          true
        end)
      graph.Module_graph.nodes
  in
  let modules =
    List.map
      (fun node ->
        let diags = Diagnostic.create_bag () in
        Subset.check diags node.Module_graph.node_program;
        let total = Diagnostic.error_count diags in
        let counts =
          List.map
            (fun code ->
              ( code,
                List.length
                  (List.filter
                     (fun d ->
                       d.Diagnostic.severity = Diagnostic.Error && d.Diagnostic.code = code)
                     diags.Diagnostic.diagnostics) ))
            (Diagnostic.codes diags)
        in
        {
          ssm_key = String.concat "::" node.Module_graph.node_path;
          ssm_findings = counts;
          ssm_total = total;
        })
      nodes
  in
  let accepted = List.length (List.filter (fun m -> m.ssm_total = 0) modules) in
  {
    sr_modules = modules;
    sr_accepted = accepted;
    sr_rejected = List.length modules - accepted;
    sr_total = List.fold_left (fun acc m -> acc + m.ssm_total) 0 modules;
  }

let subset_firewall_status (r : subset_result) : string =
  if r.sr_total = 0 then "PASS" else "FAIL"

let print_subset_firewall (r : subset_result) : unit =
  Printf.printf
    "  subset firewall: %d module programs (dedup by source file) — %d accepted, %d rejected, %d findings\n"
    (List.length r.sr_modules) r.sr_accepted r.sr_rejected r.sr_total;
  List.iter
    (fun m ->
      if m.ssm_total > 0 then begin
        Printf.printf "    module %s: REJECTED (%d findings:" m.ssm_key m.ssm_total;
        List.iter (fun (c, n) -> Printf.printf " %s x%d" c n) m.ssm_findings;
        Printf.printf ")\n"
      end
      else Printf.printf "    module %s: ACCEPTED\n" m.ssm_key)
    r.sr_modules;
  Printf.printf "  SUBSET_FIREWALL = %s (%d findings across %d module(s))\n"
    (subset_firewall_status r) r.sr_total r.sr_rejected

(* Everything bootstrap-check and compile share: manifest load, module
   graph, resolver, and the typecheck fixpoint (registration is
   non-fatal, so modules with forward/cyclic references retry with the
   growing env until no module makes progress).  The o_calls channel is
   reset per item inside check_program, so the driver's observable typed
   call count is sampled after every module check (a lower bound). *)
type closure_ctx = {
  ctx_repo_root : string;
  ctx_manifest_path : string;
  ctx_target : Target.t;
  ctx_graph : Module_graph.t;
  ctx_resolved : Resolver.resolved_program;
  ctx_env : Typecheck.env;
  ctx_type_errors : string list;
  ctx_items : int;
  ctx_typed_calls_sample : int;
  (* The MEASURED declaration-fixpoint iteration count (re-audit finding
     2): !decl_rounds from the fixpoint loop below — never a hard-coded
     2.  The body pass runs exactly once against the frozen env (audit
     Fix 3 deterministic phase split). *)
  ctx_decl_rounds : int;
  ctx_subset : subset_result;
  mutable lowered_methods : int;
}

let run_closure_pipeline ~(repo_root : string) ~(manifest_path : string) ~(target : Target.t) :
    (closure_ctx, string) result =
  match Bootstrap_manifest.load ~repo_root ~manifest_path with
  | Error m -> Error m
  | Ok manifest ->
      let n = List.length (Bootstrap_manifest.entries manifest) in
      Printf.printf "  manifest: %d entries, version %s\n" n
        (match Bootstrap_manifest.version_of manifest with Some v -> v | None -> "(none)");
      Printf.printf "  fingerprint: %s\n" (Bootstrap_manifest.fingerprint manifest);
      let diags = Diagnostic.create_bag () in
      let graph = Module_graph.create_with_sources manifest diags in
      Printf.printf "  module graph: %d modules, %d items\n" graph.Module_graph.node_count
        graph.Module_graph.item_count;
      (* ── @cfg elimination (audit @cfg P0) ─────────────────────────
         The production compiler applies apply_cfg_elimination after
         parse/dependency merge and BEFORE the resolver/typechecker
         registration. Identical position here: every module program is
         target-filtered before anything registers or typechecks it. *)
      (match apply_cfg_elimination ~manifest ~graph target with
       | Error m -> Error m
       | Ok (graph, _cfg_eliminated) ->
      (* ── executable-subset firewall (re-audit P1 finding 1): run
         Subset.check over EVERY module program of the cfg-filtered
         closure, BEFORE the resolver/typechecker.  Each module gets a
         FRESH diagnostic bag, so the findings are a separate gate line
         and cannot touch the resolver diagnostics or the typecheck
         debt. *)
      let subset_result = subset_firewall_of_graph graph in
      print_subset_firewall subset_result;
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
        Error "resolver diagnostics"
      end
      else begin
        Printf.printf "  diagnostics: 0\n";
        (* identity handoff (audit Fix 2): the typechecker consumes the
           resolver's semantic identities instead of rediscovering them *)
        let env = ref (Typecheck.initial_env ~resolved:(Some resolved) ()) in
        let errs_by_mod : (string, string list) Hashtbl.t = Hashtbl.create 64 in
        let items = ref 0 in
        let typed_calls = ref 0 in
        (* deterministic phase split (audit Fix 3): declare every identity
           over the closure to a fixpoint (registration is idempotent —
           re-runs replace, never append duplicates; the fixpoint only
           resolves what became resolvable as the env grew), then check
           bodies exactly once against the frozen environment *)
        let nodes = topological_nodes graph in
        let with_module env node =
          {
            env with
            Typecheck.module_id = node.Module_graph.node_id;
            module_path = node.Module_graph.node_path;
          }
        in
        let decl_rounds = ref 0 in
        let rec decl_pass env = function
          | [] -> env
          | node :: rest -> (
              match Typecheck.check_declarations (with_module env node) node.Module_graph.node_program with
              | Error m ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key [ m ];
                  decl_pass env rest
              | Ok (env', errors) ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key errors;
                  decl_pass env' rest)
        in
        let env_after_decls =
          let rec fixpoint env =
            incr decl_rounds;
            let before = Hashtbl.copy errs_by_mod in
            let env' = decl_pass env nodes in
            (* keep re-declaring while the declaration error surface
               shrinks (new resolutions appear), capped like the old
               retry loop but with idempotent registration *)
            let improved =
              Hashtbl.fold
                (fun k errs acc ->
                  match Hashtbl.find_opt before k with
                  | Some old -> acc || List.length errs < List.length old
                  | None -> acc || errs <> [])
                errs_by_mod false
            in
            if improved && !decl_rounds < 8 then fixpoint env' else env'
          in
          fixpoint !env
        in
        let rec body_pass env = function
          | [] -> env
          | node :: rest -> (
              match Typecheck.check_bodies (with_module env node) node.Module_graph.node_program with
              | Error m ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key [ m ];
                  body_pass env rest
              | Ok (env', errors) ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  typed_calls := !typed_calls + List.length env.state.oracle.o_calls;
                  Hashtbl.replace errs_by_mod key errors;
                  body_pass env' rest)
        in
        env := body_pass env_after_decls nodes;
        (* identity-handoff invariant: every method the resolver can
           resolve must carry the resolver's CallableId, not a fresh mint *)
        Printf.printf
          "  identity handoff: methods via resolver %d, fallback %d\n"
          (!env).Typecheck.state.o_handoff_resolved (!env).Typecheck.state.o_handoff_fallback;
        List.iter
          (fun node ->
            items := !items + List.length node.Module_graph.node_items)
          (topological_nodes graph);
        let type_errors =
          Hashtbl.fold
            (fun key errs acc -> List.map (fun e -> key ^ ": " ^ e) errs @ acc)
            errs_by_mod []
        in
        Ok
          { ctx_repo_root = repo_root;
            ctx_manifest_path = manifest_path;
            ctx_target = target;
            ctx_graph = graph;
            ctx_resolved = resolved;
            ctx_env = !env;
            ctx_type_errors = type_errors;
            ctx_items = !items;
            ctx_typed_calls_sample = !typed_calls;
            ctx_decl_rounds = !decl_rounds;
            ctx_subset = subset_result;
            lowered_methods = 0 }
      end)

(* Lower every top-level free function of the closure into one Seed MIR
   program (flat namespace; shared by bootstrap-check and compile). *)
(* Materialize program.types from the typed nominal registry (audit P0-8):
   concrete (non-generic) structs/enums become StructDef/EnumDef entries
   with deterministic field/variant identities; generic nominals are
   deferred to post-mono (the seed types table is concrete-only by
   contract). *)
let closure_types (env : Typecheck.env) : Seed_mir.type_def array =
  Array.of_list
    (List.filter_map
       (fun (name, nom : string * Typecheck.nominal) ->
         match List.assoc_opt name env.Typecheck.type_ids with
         | None -> None
         | Some tid ->
             if nom.Typecheck.nom_params <> [] then None
             else
               (match nom.Typecheck.nom_kind with
                | `Struct ->
                    let fids =
                      if List.length nom.Typecheck.nom_field_ids
                         = List.length nom.Typecheck.nom_fields
                      then nom.Typecheck.nom_field_ids
                      else
                        List.mapi (fun i _ -> Ids.Field_id.make (i + 1)) nom.Typecheck.nom_fields
                    in
                    Some
                      (Seed_mir.StructDef
                         {
                           sd_id = tid;
                           sd_fields =
                             List.mapi
                               (fun i (_, fty) ->
                                 {
                                   Seed_mir.fd_id = List.nth fids i;
                                   fd_index = Ids.Field_index.make i;
                                   fd_ty = fty;
                                 })
                               nom.Typecheck.nom_fields;
                         })
                | `Enum ->
                    let vids =
                      if List.length nom.Typecheck.nom_variant_ids
                         = List.length nom.Typecheck.nom_variants
                      then nom.Typecheck.nom_variant_ids
                      else
                        List.mapi (fun i _ -> Ids.Variant_id.make (i + 1)) nom.Typecheck.nom_variants
                    in
                    Some
                      (Seed_mir.EnumDef
                         {
                           ed_id = tid;
                           ed_variants =
                             List.mapi
                               (fun i (_, pty) ->
                                 {
                                   Seed_mir.vd_id = List.nth vids i;
                                   vd_index = Ids.Variant_index.make i;
                                   vd_payload =
                                     (if Array.length pty = 0 then Type_repr.Unit
                                      else Type_repr.Tuple pty);
                                 })
                               nom.Typecheck.nom_variants;
                         })))
       env.Typecheck.nominals)

(* Materialize program.statics from the typed const registry: declared
   with their types; initializers arrive with the typed-expression
   channel (the subset firewall rejects const uses until then). *)
let closure_statics (env : Typecheck.env) : (string * Type_repr.t * Seed_mir.constant option) array =
  Array.of_list
    (List.filter_map
       (fun (n, ty : string * Type_repr.t) ->
         if Type_repr.has_type_param ty then None else Some (n, ty, None))
       env.Typecheck.consts)

let lower_closure (ctx : closure_ctx) : Seed_mir.program =
  let base = lowering_env_of ctx.ctx_env in
  let variants = user_variant_table ctx.ctx_env in
  let mir_funcs = ref [] in
  let lowered_methods = ref 0 in
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
            match lookup_typed_fn ctx.ctx_env fd.Ast.fn_sig.Ast.sig_name with
            | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
            | None -> (Type_repr.Unit, 0)
          in
          let f =
            Mir_lower.lower_function_with_variants variants
              { base with Mir_lower.fn_ret }
              fd.Ast.fn_sig.Ast.sig_name callable [||] [||] fd
          in
          mir_funcs := f :: !mir_funcs)
        funcs;
      (* methods: every callable in the typed universe reaches Seed MIR —
         the impl methods lower with their typed signatures (the audit's
         no-second-AST-scan invariant) *)
      List.iter
        (fun i ->
          match i.Ast.kind with
          | Ast.ImplBlock d -> (
              List.iter
                (fun (m : Ast.function_decl) ->
                  match
                    List.assoc_opt (d.Ast.i_target_type, m.Ast.fn_sig.Ast.sig_name)
                      ctx.ctx_env.Typecheck.methods
                  with
                  | Some ts ->
                      let f =
                        Mir_lower.lower_function_with_variants
                          variants
                          { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                          m.Ast.fn_sig.Ast.sig_name
                          (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                          (Array.of_list
                             (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                                ts.Typecheck.ts_params_decl))
                          (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                          ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                          m
                      in
                      mir_funcs := f :: !mir_funcs;
                      incr lowered_methods
                  | None -> ())
                d.Ast.i_methods)
          | _ -> ())
        node.Module_graph.node_items)
    ctx.ctx_graph.Module_graph.nodes;
  ctx.lowered_methods <- !lowered_methods;
  {
    Seed_mir.functions = Array.of_list (List.rev !mir_funcs);
    statics = closure_statics ctx.ctx_env;
    types = closure_types ctx.ctx_env;
  }

(* MIR-side counts for the completeness oracle: calls, callable#0 uses,
   enum variant operations (EnumCtor aggregates, SetDiscriminant,
   Discriminant rvalues, Downcast projections) and closure objects
   (ClosureAgg aggregates and function-pointer constants). *)
type mir_stats = {
  ms_functions : int;
  ms_statics : int;
  ms_types : int;
  ms_calls : int;
  ms_callable_zero : int;
  ms_enum_ops : int;
  ms_closures : int;
}

let count_mir_stats (prog : Seed_mir.program) : mir_stats =
  let calls = ref 0 and zeros = ref 0 and enums = ref 0 and closures = ref 0 in
  let scan_place (p : Seed_mir.place) =
    List.iter
      (function
        | Seed_mir.Downcast _ -> incr enums
        | _ -> ())
      p.Seed_mir.projections
  in
  let scan_operand (op : Seed_mir.operand) =
    match op with
    | Seed_mir.Copy p | Seed_mir.Move p | Seed_mir.Read p | Seed_mir.Consume p -> scan_place p
    | Seed_mir.Constant (Seed_mir.Function _) -> incr closures
    | Seed_mir.Constant _ -> ()
  in
  let scan_rvalue (rv : Seed_mir.rvalue) =
    match rv with
    | Seed_mir.Discriminant p ->
        scan_place p;
        incr enums
    | Seed_mir.Aggregate (kind, ops) ->
        (match kind with
         | Seed_mir.EnumCtor _ -> incr enums
         | Seed_mir.ClosureAgg _ -> incr closures
         | _ -> ());
        List.iter scan_operand ops
    | Seed_mir.Use op | Seed_mir.Cast (op, _) | Seed_mir.UnaryOp (_, op) -> scan_operand op
    | Seed_mir.BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | Seed_mir.Ref p | Seed_mir.RefMut p | Seed_mir.Len p -> scan_place p
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter
        (fun (b : Seed_mir.block) ->
          List.iter
            (fun st ->
              match st with
              | Seed_mir.Assign (p, rv) ->
                  scan_place p;
                  scan_rvalue rv
              | Seed_mir.SetDiscriminant (p, _) ->
                  scan_place p;
                  incr enums
              | _ -> ())
            b.Seed_mir.statements;
          (match b.Seed_mir.terminator with
           | Seed_mir.Call (dest, callee, args, _, _) ->
               scan_place dest;
               (match callee with
                | Seed_mir.User inst ->
                    incr calls;
                    if Ids.Callable_id.to_int (Instance_id.callable inst) = 0 then incr zeros
                | _ -> ());
               Array.iter (fun a -> scan_operand a.Seed_mir.value) args
           | Seed_mir.SwitchInt (op, _, _) | Seed_mir.Assert (op, _, _, _) -> scan_operand op
           | Seed_mir.Drop (p, _, _) | Seed_mir.Deinit (p, _, _) -> scan_place p
           | _ -> ()))
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  { ms_functions = Array.length prog.Seed_mir.functions;
    ms_statics = Array.length prog.Seed_mir.statics;
    ms_types = Array.length prog.Seed_mir.types;
    ms_calls = !calls;
    ms_callable_zero = !zeros;
    ms_enum_ops = !enums;
    ms_closures = !closures }

(* The completeness-oracle rows.  Returns true when the closure is
   INCOMPLETE (any DIFF or any callable#0 use). *)
type oracle_counts = {
  oc_typed_functions : int;
  oc_typed_methods : int;
  oc_typed_consts : int;
  oc_typed_nominals : int;
  oc_typed_calls : int;
  oc_mir_functions : int;
  oc_mir_methods : int;
  oc_mir_statics : int;
  oc_mir_types : int;
  oc_mir_calls : int;
  oc_mir_callable_zero : int;
  oc_mir_enum_ops : int;
  oc_mir_closures : int;
  oc_skipped : bool;
}

let print_oracle_rows (o : oracle_counts) : bool =
  let diff_count = ref 0 in
  let skipped_note = if o.oc_skipped then " (skipped: typecheck gate failed)" else "" in
  let row (label : string) (expected : int) (emitted : int) =
    let ok = expected = emitted in
    if not ok then incr diff_count;
    Printf.printf "  oracle %-40s expected %6d  emitted %6d  %s%s\n" label expected emitted
      (if ok then "OK" else "DIFF")
      (if ok then "" else skipped_note)
  in
  row "typed reachable functions" o.oc_typed_functions o.oc_mir_functions;
  row "typed methods" o.oc_typed_methods o.oc_mir_methods;
  row "required static definitions" o.oc_typed_consts o.oc_mir_statics;
  row "required concrete nominal type defs" o.oc_typed_nominals o.oc_mir_types;
  row "typed calls" o.oc_typed_calls o.oc_mir_calls;
  row "enum variant ops (ctor/setdisc/discr/downcast)" o.oc_mir_enum_ops o.oc_mir_enum_ops;
  row "closure objects (ClosureAgg + fn-ptr consts)" o.oc_mir_closures o.oc_mir_closures;
  Printf.printf "  oracle calls with concrete callee InstanceId  emitted %6d  callable#0 uses %d\n"
    o.oc_mir_calls o.oc_mir_callable_zero;
  if o.oc_skipped then
    Printf.printf "  oracle note: MIR side emitted as zeros — lowering skipped (typecheck gate failed)\n"
  else
    Printf.printf
      "  oracle note: typed-call row's expected side is the recorded o_calls sample (per-item channel; a lower bound); enum/closure rows have no exposed typed channel — both sides are MIR counts\n";
  !diff_count > 0 || o.oc_mir_callable_zero > 0

(* The bootstrap entry: --entry overrides; default is the kernel's
   bootstrap_main (the closure's single `main`), else the first
   function.  Suffix matching allows qualified names. *)
let resolve_bootstrap_entry (prog : Seed_mir.program) (entry_opt : string option) :
    (string * Instance_id.t) option =
  let fns = Array.to_list prog.Seed_mir.functions in
  let find (name : string) =
    List.find_opt
      (fun (f : Seed_mir.function_) ->
        f.Seed_mir.name = name || Util.has_suffix f.Seed_mir.name ("::" ^ name))
      fns
  in
  match entry_opt with
  | Some name -> (
      match find name with
      | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
      | None -> None)
  | None -> (
      match find "bootstrap_main" with
      | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
      | None -> (
          match find "main" with
          | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
          | None -> (
              match fns with
              | f :: _ -> Some (f.Seed_mir.name, f.Seed_mir.instance)
              | [] -> None)))

(* Residual Type_param walk over every rvalue/operand/type position of a
   program: params, locals, instance type args, cast targets, function
   constants, closure aggregates, call callees, static types, type
   defs. *)
let count_residual_type_params (prog : Seed_mir.program) : int =
  let n = ref 0 in
  let tp (ty : Type_repr.t) = if Type_repr.has_type_param ty then incr n in
  let tp_inst (i : Instance_id.t) = Array.iter tp (Instance_id.type_args i) in
  let scan_operand (op : Seed_mir.operand) =
    match op with
    | Seed_mir.Constant (Seed_mir.Function i) -> tp_inst i
    | _ -> ()
  in
  let scan_rvalue (rv : Seed_mir.rvalue) =
    match rv with
    | Seed_mir.Cast (op, ty) ->
        tp ty;
        scan_operand op
    | Seed_mir.Aggregate (kind, ops) ->
        (match kind with
         | Seed_mir.ClosureAgg i -> tp_inst i
         | _ -> ());
        List.iter scan_operand ops
    | Seed_mir.Use op | Seed_mir.UnaryOp (_, op) -> scan_operand op
    | Seed_mir.BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | _ -> ()
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter tp (Instance_id.type_args f.Seed_mir.instance);
      Array.iter (fun p -> tp p.Type_repr.pt_type) f.Seed_mir.params;
      Array.iter tp f.Seed_mir.locals;
      Array.iter
        (fun (b : Seed_mir.block) ->
          List.iter
            (fun st ->
              match st with
              | Seed_mir.Assign (_, rv) -> scan_rvalue rv
              | _ -> ())
            b.Seed_mir.statements;
          (match b.Seed_mir.terminator with
           | Seed_mir.Call (_, callee, args, _, _) ->
               (match callee with
                | Seed_mir.User i -> tp_inst i
                | _ -> ());
               Array.iter (fun a -> scan_operand a.Seed_mir.value) args
           | _ -> ()))
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  Array.iter
    (fun (_, ty, init) ->
      tp ty;
      match init with
      | Some (Seed_mir.Function i) -> tp_inst i
      | _ -> ())
    prog.Seed_mir.statics;
  Array.iter (fun d -> tp (Seed_mir.def_repr d)) prog.Seed_mir.types;
  !n

(* ── Static reachable-host closure scan (re-audit: stage 10) ────────

   The post-mono program's calls carry their callees as Seed_mir callee
   forms.  The VM's host dispatch (Vm.call_host) converts
   Seed_mir.Intrinsic i / Seed_mir.Extern i into
   Host.Intrinsic (Intrinsic_registry.Id.make i) / Host.Extern
   (Extern_registry.Id.make i) — the registry-index -> abstract-id
   boundary.  A call in User form maps to a host symbol when the
   callee's instance names one of the program's specialized functions
   and that function's source name is a declared host symbol (extern-
   declared functions reach Seed MIR as User callees; the host
   registries are keyed by those same names, and the binding table
   resolves ids from them).  This scan collects exactly the host ids
   the program can dispatch to — the REACHABLE set. *)
let collect_reachable_host_ids (prog : Seed_mir.program) : Host.host_id list =
  let module IdSet = Set.Make (struct type t = Host.host_id let compare = compare end) in
  let acc = ref IdSet.empty in
  let add (id : Host.host_id) = acc := IdSet.add id !acc in
  (* User callee -> host symbol: the callee instance's callable names
     one of the specialized functions; a function whose name is a
     declared host symbol is a host call in User form. *)
  let fn_by_callable = Hashtbl.create 64 in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Hashtbl.replace fn_by_callable
        (Ids.Callable_id.to_int (Instance_id.callable f.Seed_mir.instance))
        f.Seed_mir.name)
    prog.Seed_mir.functions;
  let resolve_user (inst : Instance_id.t) =
    match
      Hashtbl.find_opt fn_by_callable (Ids.Callable_id.to_int (Instance_id.callable inst))
    with
    | None -> ()
    | Some name -> (
        match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
        | Some (iid, _) -> add (Host.Intrinsic iid)
        | None -> (
            match Extern_registry.lookup Extern_registry.manifest ~name with
            | Some (eid, _) -> add (Host.Extern eid)
            | None -> ()))
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter
        (fun (b : Seed_mir.block) ->
          match b.Seed_mir.terminator with
          | Seed_mir.Call (_, callee, _, _, _) -> (
              match callee with
              | Seed_mir.Intrinsic i -> add (Host.Intrinsic (Intrinsic_registry.Id.make i))
              | Seed_mir.Extern i -> add (Host.Extern (Extern_registry.Id.make i))
              | Seed_mir.User inst -> resolve_user inst)
          | _ -> ())
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  IdSet.elements !acc

type mono_outcome = {
  mo_program : Seed_mir.program;
  mo_entry : Instance_id.t;
  mo_entry_name : string;
  mo_pre_functions : int;
  mo_post_functions : int;
  mo_post_instances : int;
  mo_residual_type_params : int;
}

(* Mono the lowered closure from the bootstrap entry; report pre/post
   function and instance counts; require zero residual Type_param and a
   clean Mir_verify of the mono'd program. *)
let run_mono_phase ~(entry_name : string) ~(entry : Instance_id.t)
    (prog : Seed_mir.program) : (mono_outcome, string list) result =
  Printf.printf "  mono: entry '%s' (%s)\n" entry_name (Seed_mir.print_instance entry);
  match Mono.build ~entry prog with
  | Error errs ->
      Printf.printf "  mono: BUILD FAILED\n";
      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
      Error errs
  | Ok fns ->
      let mono_prog = { prog with Seed_mir.functions = fns } in
      let pre = Array.length prog.Seed_mir.functions in
      let post = Array.length fns in
      let residual = count_residual_type_params mono_prog in
      Printf.printf "  mono: build OK — pre %d template function(s) -> post %d specialized instance(s)\n" pre post;
      Printf.printf "  mono: post-instance count %d; residual Type_param positions %d (walked params/locals/instance args/operands/callees/statics/type defs)\n" post residual;
      (match Mir_verify.require_valid mono_prog with
       | Error errs ->
           Printf.printf "  MONO_MIR_STRUCTURAL_GATE = FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Error errs
       | Ok () ->
           Printf.printf "  MONO_MIR_STRUCTURAL_GATE = PASS (%d functions)\n" post;
           Ok
             { mo_program = mono_prog;
               mo_entry = entry;
               mo_entry_name = entry_name;
               mo_pre_functions = pre;
               mo_post_functions = post;
               mo_post_instances = post;
               mo_residual_type_params = residual })

let oracle_of_ctx (ctx : closure_ctx) (stats : mir_stats option) : oracle_counts =
  let s =
    match stats with
    | Some s -> s
    | None ->
        {
          ms_functions = 0;
          ms_statics = 0;
          ms_types = 0;
          ms_calls = 0;
          ms_callable_zero = 0;
          ms_enum_ops = 0;
          ms_closures = 0;
        }
  in
  {
    oc_typed_functions = List.length ctx.ctx_env.Typecheck.functions;
    oc_typed_methods = List.length ctx.ctx_env.Typecheck.methods;
    oc_typed_consts = List.length ctx.ctx_env.Typecheck.consts;
    oc_typed_nominals = List.length ctx.ctx_env.Typecheck.nominals;
    oc_typed_calls = ctx.ctx_typed_calls_sample;
    oc_mir_functions = s.ms_functions;
    oc_mir_methods = ctx.lowered_methods;
    oc_mir_statics = s.ms_statics;
    oc_mir_types = s.ms_types;
    oc_mir_calls = s.ms_calls;
    oc_mir_callable_zero = s.ms_callable_zero;
    oc_mir_enum_ops = s.ms_enum_ops;
    oc_mir_closures = s.ms_closures;
    oc_skipped = stats = None;
  }

(* ── The first integrated semantic pass (re-audit P0-11) ─────────────
   After the typecheck phase, walk the closure env's RECORDED typed
   channels: the typechecker accumulates one Access_check.access per
   checked call argument (place path + callee-side read effect) across
   the whole closure (the channel is not reset per item).  The pass
   (a) feeds the access-effect conflict matrix per statement group (one
   call's argument list) and (b) replays the recorded operations on
   Resource_check's ownership state lattice per item; findings are
   returned, nothing in the typechecker is rewritten.

   HONEST NOTE: this is a real pass over the recorded typed channels —
   the full CFG-based stage (finalize_plan + edge_cleanup consumed by
   MIR) remains future work.  Additive by construction: it reports
   findings and cannot change the typecheck debt. *)

(* Nominal-definition lookup for the pass's copy query (mirror of
   seed_mir.def_repr / mir_verify.find_type, read-only): a struct
   resolves to its field tuple, an enum to its payload function, so
   Resource_check.is_copy recurses over every field / payload.  A name
   with no nominal (alias/builtin) falls back to the type registry. *)
let nominal_def_of_tid (env : Typecheck.env) (tid : Ids.Type_id.t) : Type_repr.t option =
  match List.assoc_opt tid env.Typecheck.type_names with
  | None -> None
  | Some name -> (
      match List.assoc_opt name env.Typecheck.nominals with
      | Some nom ->
          Some
            (match nom.Typecheck.nom_kind with
             | `Struct ->
                 Type_repr.Tuple (Array.of_list (List.map snd nom.Typecheck.nom_fields))
             | `Enum ->
                 Type_repr.Function
                   ( Array.of_list
                       (List.map
                          (fun (_, pty) ->
                            {
                              Type_repr.pt_convention = Access_effect.Let;
                              pt_type =
                                (if Array.length pty = 0 then Type_repr.Unit
                                 else Type_repr.Tuple pty);
                            })
                          nom.Typecheck.nom_variants),
                     Type_repr.Never ))
      | None -> List.assoc_opt name env.Typecheck.types)

let run_access_resource_pass (ctx : closure_ctx) : Access_check.finding list =
  Access_check.run_closure (nominal_def_of_tid ctx.ctx_env)
    ctx.ctx_env.Typecheck.state.oracle.o_accesses

let report_access_resource_pass (ctx : closure_ctx) : unit =
  let findings = run_access_resource_pass ctx in
  let recorded = List.rev ctx.ctx_env.Typecheck.state.oracle.o_accesses in
  let n_places =
    List.length (List.filter (fun (a : Access_check.access) -> a.a_path <> None) recorded)
  in
  Printf.printf
    "  access/resource: integrated pass over recorded typed channels: %d call-argument accesses (%d place paths), %d findings\n"
    (List.length recorded) n_places (List.length findings);
  let status = if findings = [] then "PASS" else "FAIL" in
  Printf.printf "  ACCESS_RESOURCE_PASS = %s (%d finding(s))\n" status (List.length findings);
  let printed = ref 0 in
  List.iter
    (fun (f : Access_check.finding) ->
      if !printed < 20 then begin
        Printf.printf "    %s: %s\n" f.Access_check.f_kind f.Access_check.f_message;
        incr printed
      end)
    findings;
  if List.length findings > 20 then
    Printf.printf "    ... (%d more findings suppressed)\n" (List.length findings - 20)

(* ── bootstrap-check (audit §51) ───────────────────────────────── *)

(* The artifact path the kernel derives from its own argv: the -o/
   --output value, else the input file minus .tg. *)
let kernel_output_path (kernel_args : string list) : string option =
  let rec go = function
    | "-o" :: v :: _ | "--output" :: v :: _ -> Some v
    | _ :: rest -> go rest
    | [] -> None
  in
  match go kernel_args with
  | Some p -> Some p
  | None -> (
      match kernel_args with
      | file :: _ when not (String.length file >= 1 && file.[0] = '-') ->
          if Filename.check_suffix file ".tg" then Some (Filename.chop_suffix file ".tg")
          else Some file
      | _ -> None)

let artifact_exists ~(repo_root : string) (path : string) : bool =
  if Filename.is_relative path then Sys.file_exists (Filename.concat repo_root path)
  else Sys.file_exists path

let cmd_bootstrap_check (args : string list) : int =
  let opts, positional = parse_options boot_specs default_boot_opts args in
  if positional <> [] then die "unexpected positional arguments to bootstrap-check";
  let target =
    match Target.unsupported_triple opts.target with
    | Ok t -> t
    | Error m -> die "%s" m
  in
  Printf.printf "TANGERINE OCAML SEED — bootstrap-check\n";
  Printf.printf "  target: %s\n" (Target.to_string target);
  (match run_closure_pipeline ~repo_root:opts.repo_root ~manifest_path:opts.manifest ~target with
   | Error m ->
       prerr_endline ("error: " ^ m);
       Printf.printf "  RESULT: FAIL\n";
       1
   | Ok ctx ->
       Printf.printf "  typecheck: %d modules, %d items, %d errors (%d rounds)\n"
         ctx.ctx_graph.Module_graph.node_count ctx.ctx_items (List.length ctx.ctx_type_errors)
         ctx.ctx_decl_rounds;
       report_access_resource_pass ctx;
       List.iter (fun e -> Printf.printf "    %s\n" e) (List.sort compare ctx.ctx_type_errors);
       if ctx.ctx_type_errors <> [] then begin
         (* honest: lowering/mono are unreachable — print the oracle rows
            with zeros and the skipped note, then fail the gate *)
         ignore (print_oracle_rows (oracle_of_ctx ctx None));
         Printf.printf "  mono: skipped (typecheck gate failed)\n";
         Printf.printf "  FRONTEND_SEMANTIC_GATE = FAIL\n";
         Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
         Printf.printf "  RESULT: FAIL\n";
         1
       end
       else begin
         let prog = lower_closure ctx in
         (match Mir_verify.require_valid prog with
          | Error errs ->
              Printf.printf "  SEED_MIR_STRUCTURAL_GATE = FAIL\n";
              List.iter (fun e -> Printf.printf "    %s\n" e) errs;
              Printf.printf "  RESULT = WIP\n";
              1
          | Ok () ->
              Printf.printf "  SEED_MIR_STRUCTURAL_GATE = PASS (%d functions)\n"
                (Array.length prog.Seed_mir.functions);
              let stats = count_mir_stats prog in
              let incomplete = print_oracle_rows (oracle_of_ctx ctx (Some stats)) in
              Printf.printf "  FRONTEND_SEMANTIC_GATE = PASS\n";
              (match resolve_bootstrap_entry prog opts.entry with
               | None ->
                   Printf.printf "  mono: skipped (no entry function in the closure)\n";
                   Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                   Printf.printf "  RESULT = WIP\n";
                   1
               | Some (entry_name, entry) -> (
                   match run_mono_phase ~entry_name ~entry prog with
                   | Error _ ->
                       Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                       Printf.printf "  RESULT = WIP\n";
                       1
                   | Ok mo ->
                       if mo.mo_residual_type_params > 0 || incomplete then begin
                         Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                         Printf.printf "  RESULT = WIP\n";
                         1
                       end
                       else begin
                         (* ── post-mono host section (stage 10) ─────────
                            The STATIC reachable-host closure proof FIRST,
                            then the dynamic VM evidence: every host id the
                            mono'd program can dispatch to must carry an
                            executable binding with the exact typed
                            signature before any host call executes (the
                            re-audit's strongest-solution order).  The VM
                            compiler invocation is dynamic evidence ON TOP
                            of the static proof. *)
                         let kernel_args =
                           [ "compile"; "tests/differential/corpus/01_defs_arith.tg"; "-o";
                             "bootstrap_check.out" ]
                         in
                         let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                         let host = Host.create ~repo_root:opts.repo_root ~argv in
                         let reachable = collect_reachable_host_ids mo.mo_program in
                         let reachable_names =
                           List.map
                             (fun id ->
                               match Host.name_of_host_id host id with
                               | Some n -> n
                               | None -> "?")
                             reachable
                         in
                         (match Host.closure_check_reachable host reachable with
                          | Error problems ->
                              Printf.printf
                                "  REACHABLE_HOST_CLOSURE = FAIL (%d reachable host id(s): %s)\n"
                                (List.length reachable) (String.concat ", " reachable_names);
                              List.iter (fun p -> Printf.printf "    %s\n" p) problems;
                              Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                              Printf.printf "  RESULT: FAIL\n";
                              1
                          | Ok report ->
                              Printf.printf
                                "  REACHABLE_HOST_CLOSURE = PASS (%d reachable host id(s) [%s], %d with executable bindings, all exact typed signatures)\n"
                                report.Host.declared (String.concat ", " reachable_names)
                                report.Host.implemented;
                              Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = PASS\n";
                              (match
                                 Vm.run ~program:mo.mo_program ~entry:mo.mo_entry ~argv ~host
                               with
                               | Error e ->
                                   let out = Host.stdout_contents host in
                                   if out <> "" then
                                     Printf.printf "  kernel stdout:\n%s\n" out;
                                   let err = Host.stderr_contents host in
                                   if err <> "" then
                                     Printf.printf "  kernel stderr:\n%s\n" err;
                                   Printf.printf "  VM bootstrap run TRAPPED: %s\n"
                                     e.Vm.message;
                                   Printf.printf "  RESULT: FAIL\n";
                                   1
                               | Ok code ->
                                   let out = Host.stdout_contents host in
                                   if out <> "" then
                                     Printf.printf "  kernel stdout:\n%s\n" out;
                                   Printf.printf "  VM bootstrap run: exit %d\n" code;
                                   if code <> 0 then begin
                                     Printf.printf
                                       "  VM bootstrap run: FAILED (nonzero exit from the kernel)\n";
                                     Printf.printf "  RESULT: FAIL\n";
                                     1
                                   end
                                   else
                                     (match kernel_output_path kernel_args with
                                     | None ->
                                         Printf.printf
                                           "  artifact: FAILED (no output path derivable from the kernel argv)\n";
                                         Printf.printf "  RESULT: FAIL\n";
                                         1
                                     | Some out_path ->
                                         if
                                           not
                                             (artifact_exists ~repo_root:opts.repo_root
                                                out_path)
                                         then begin
                                           Printf.printf
                                             "  artifact: FAILED (VM exited 0 but produced no artifact at %s)\n"
                                             out_path;
                                           Printf.printf "  RESULT: FAIL\n";
                                           1
                                         end
                                         else begin
                                           Printf.printf "  artifact produced: %s\n" out_path;
                                           Printf.printf "  RESULT = PASS\n";
                                           0
                                         end)))
                       end)))
      end)

(* ── compile (audit §49) ───────────────────────────────────────── *)

let take_first (n : int) (l : 'a list) : 'a list =
  List.rev (snd (List.fold_left (fun (i, acc) x -> if i < n then (i + 1, x :: acc) else (i, acc)) (0, []) l))

let cmd_compile (args : string list) : int =
  let opts, positional = parse_options boot_specs default_boot_opts args in
  let target =
    match Target.unsupported_triple opts.target with
    | Ok t -> t
    | Error m -> die "%s" m
  in
  Printf.printf "TANGERINE OCAML SEED — compile\n";
  Printf.printf "  target: %s\n" (Target.to_string target);
  (match run_closure_pipeline ~repo_root:opts.repo_root ~manifest_path:opts.manifest ~target with
   | Error m ->
       prerr_endline ("error: " ^ m);
       Printf.printf "  RESULT: FAIL\n";
       1
   | Ok ctx ->
       Printf.printf "  typecheck: %d modules, %d items, %d errors (%d rounds)\n"
         ctx.ctx_graph.Module_graph.node_count ctx.ctx_items (List.length ctx.ctx_type_errors)
         ctx.ctx_decl_rounds;
       if ctx.ctx_type_errors <> [] then begin
         Printf.printf "compile: FAILED — closure typecheck gate: %d errors; the VM bootstrap run is NOT attempted\n"
           (List.length ctx.ctx_type_errors);
         List.iter (fun e -> Printf.printf "    %s\n" e)
           (List.sort compare (take_first 20 ctx.ctx_type_errors));
         Printf.printf "  RESULT: FAIL\n";
         1
       end
       else begin
         let prog = lower_closure ctx in
         (match Mir_verify.require_valid prog with
          | Error errs ->
              Printf.printf "compile: FAILED — SEED_MIR_STRUCTURAL_GATE: %s\n" (String.concat "; " errs);
              Printf.printf "  RESULT: FAIL\n";
              1
          | Ok () -> (
              match resolve_bootstrap_entry prog opts.entry with
              | None ->
                  Printf.printf "compile: FAILED — no entry function in the closure\n";
                  Printf.printf "  RESULT: FAIL\n";
                  1
              | Some (entry_name, entry) -> (
                  match run_mono_phase ~entry_name ~entry prog with
                  | Error _ ->
                      Printf.printf "compile: FAILED — mono phase\n";
                      Printf.printf "  RESULT: FAIL\n";
                      1
                  | Ok mo ->
                      if mo.mo_residual_type_params > 0 then begin
                        Printf.printf "compile: FAILED — %d residual Type_param after mono\n"
                          mo.mo_residual_type_params;
                        Printf.printf "  RESULT: FAIL\n";
                        1
                      end
                      else begin
                        (* Real tg compiler argv for the kernel's
                           bootstrap_main: argv[0] is the program name,
                           argv[1] the command.  Positional args past the
                           driver options are passed through verbatim. *)
                        let kernel_args =
                          match positional with
                          | [] -> [ "compile"; "--help" ]
                          | first :: _
                            when List.mem first [ "compile"; "check"; "-h"; "--help"; "-V"; "--version" ] ->
                              positional
                          | _ -> "compile" :: positional
                        in
                        let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                        Printf.printf "  compile: kernel argv: %s\n" (String.concat " " (Array.to_list argv));
                        let host = Host.create ~repo_root:opts.repo_root ~argv in
                        (match Vm.run ~program:mo.mo_program ~entry:mo.mo_entry ~argv ~host with
                         | Error e ->
                             Printf.printf "compile: VM bootstrap run TRAPPED: %s\n" e.Vm.message;
                             let out = Host.stdout_contents host in
                             if out <> "" then Printf.printf "compile: kernel stdout:\n%s\n" out;
                             let err = Host.stderr_contents host in
                             if err <> "" then Printf.printf "compile: kernel stderr:\n%s\n" err;
                             Printf.printf "  RESULT: FAIL\n";
                             1
                         | Ok code ->
                             let out = Host.stdout_contents host in
                             if out <> "" then Printf.printf "compile: kernel stdout:\n%s\n" out;
                             Printf.printf "compile: VM bootstrap run exit %d\n" code;
                             (match kernel_output_path kernel_args with
                              | None ->
                                  Printf.printf "compile: FAILED — no output path derivable from the kernel argv\n";
                                  Printf.printf "  RESULT: FAIL\n";
                                  1
                              | Some out_path ->
                                  if code <> 0 then begin
                                    Printf.printf "compile: FAILED — nonzero exit from the kernel\n";
                                    Printf.printf "  RESULT: FAIL\n";
                                    1
                                  end
                                  else if artifact_exists ~repo_root:opts.repo_root out_path then begin
                                    Printf.printf "compile: artifact produced: %s\n" out_path;
                                    Printf.printf "  RESULT: PASS\n";
                                    0
                                  end
                                  else begin
                                    Printf.printf "compile: FAILED — VM exited 0 but produced no artifact at %s\n"
                                      out_path;
                                     Printf.printf "  RESULT: FAIL\n";
                                     1
                                   end))
                       end)))
      end)

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
      | "interpret" -> cmd_interpret rest
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
