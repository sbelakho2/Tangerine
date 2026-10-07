(* tg_identity_collision.ml — identity-collision separation, end to end.

   Two modules declare the SAME BARE names (X, STATE, Config, State,
   Ready, make, value) with deliberately DIFFERENT shapes, defaults and
   ownership, in ONE closure:

     module a: Config { n: Int = 111; only_a: Int },  State { count: Int },
               enum Ready { Ready(Int), Idle },      X = 1,  STATE = 10
     module b: Config { text: String; flag: Bool = false },
               State { label: String },
               enum Ready { Ready(Bool), Done },     X = 2,  STATE = 20

   Before the module-scoped identity fix the checker merged same-named
   nominals into one bare-keyed nominal (fields/variants accumulated
   across modules) and the driver's lowering tables were bare-keyed, so
   `a::Config { n, only_a }` and `b::Config { text, flag }` could not be
   separated.  This selfcheck drives the whole pipeline and requires the
   separation to hold at every stage:

     CHECK:    one check_program fixpoint, zero errors; the two modules'
               nominal TypeIds are DISTINCT and their fields/variants
               are NOT merged;
     LOWER:    each module's make/value lowered through the driver's own
               builders (Driver.lowering_env_of / typed channels /
               user_variant_table / closure_types / closure_statics);
     VERIFY:   Mir_verify.require_valid_template accepts the program;
     VM:       a::make == 12, b::make == 1, a::value == 11, b::value == 22.

   The manifest is a single in-memory source snapshot holding both
   inline `module a` / `module b` declarations (the seed graph gives the
   inline subtrees the bare paths [a]/[b], so the typed keys are exactly
   `a::make` / `b::make`; the manifest API has no add-entry surface, so
   a single snapshot with two top-level module declarations is the
   supported two-module construction). *)

let src = {|
module a
  const X: Int = 1
  const STATE: Int = 10

  struct Config
    n: Int = 111
    only_a: Int
  end

  struct State
    count: Int
  end

  enum Ready
    Ready(Int)
    Idle
  end

  def make() -> Int
    let c = Config { n: 1, only_a: 2 }
    c.n * 10 + c.only_a
  end

  def value() -> Int = X + STATE
end

module b
  const X: Int = 2
  const STATE: Int = 20

  struct Config
    text: String
    flag: Bool = false
  end

  struct State
    label: String
  end

  enum Ready
    Ready(Bool)
    Done
  end

  def make() -> Int
    let c = Config { text: "b" }
    let base = c.text.len()
    if c.flag then base + 100 else base end
  end

  def value() -> Int = X + STATE
end
|}

let fail (msg : string) : 'a =
  Printf.printf "FAIL: identity collision: %s\n" msg;
  exit 1

(* ── parse -> graph -> resolver -> checker fixpoint over the closure ── *)

let build () :
    Typecheck.env * Ast.program * Module_graph.t * Bootstrap_manifest.t =
  let file = Filename.temp_file "tg_identity_collision" ".tg" in
  let oc = open_out_bin file in
  output_string oc src;
  close_out oc;
  let manifest =
    match Bootstrap_manifest.single ~file ~path:[] () with
    | Ok m -> m
    | Error e -> fail ("manifest: " ^ e)
  in
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
  let root =
    match
      List.find_opt (fun n -> n.Module_graph.node_path = []) graph.Module_graph.nodes
    with
    | Some n -> n
    | None -> fail "no root module node in the graph"
  in
  let prog_ast = root.Module_graph.node_program in
  let rec fix env n =
    match Typecheck.check_program env prog_ast with
    | Error m -> fail ("typecheck: " ^ m)
    | Ok (env', errors) ->
        if errors = [] then env'
        else if n = 0 then begin
          Printf.printf "check errors:\n";
          List.iter (fun e -> Printf.printf "  %s\n" e) errors;
          fail (Printf.sprintf "%d checker error(s)" (List.length errors))
        end
        else fix env' (n - 1)
  in
  let env = fix (Typecheck.initial_env ~resolved:(Some resolved) ()) 6 in
  Sys.remove file;
  (env, prog_ast, graph, manifest)

(* ── semantic-separation assertions on the typed env ────────────────── *)

let type_id_of (env : Typecheck.env) (qk : string) : Ids.Type_id.t =
  match Typecheck.type_id_by_name env qk with
  | Some t -> t
  | None -> fail ("no TypeId registered for `" ^ qk ^ "`")

let nominal_of (env : Typecheck.env) (qk : string) : Typecheck.nominal =
  match Typecheck.nominal_by_name env qk with
  | Some n -> n
  | None -> fail ("no nominal registered for `" ^ qk ^ "`")

let field_names (nom : Typecheck.nominal) : string list =
  List.map fst nom.Typecheck.nom_fields

let variant_names (nom : Typecheck.nominal) : string list =
  List.map fst nom.Typecheck.nom_variants

let assert_separation (env : Typecheck.env) : unit =
  List.iter
    (fun k ->
      if not (List.mem_assoc k env.Typecheck.functions) then
        fail ("missing typed function `" ^ k ^ "`"))
    [ "a::make"; "b::make"; "a::value"; "b::value" ];
  let ca = type_id_of env "a::Config" and cb = type_id_of env "b::Config" in
  if Ids.Type_id.compare ca cb = 0 then
    fail "a::Config and b::Config share ONE TypeId (nominal identity not separated)";
  if not (Ids.Type_id.compare (type_id_of env "a::State") (type_id_of env "b::State") <> 0)
  then fail "a::State and b::State share ONE TypeId";
  if not (Ids.Type_id.compare (type_id_of env "a::Ready") (type_id_of env "b::Ready") <> 0)
  then fail "a::Ready and b::Ready share ONE TypeId";
  let na = nominal_of env "a::Config" and nb = nominal_of env "b::Config" in
  if field_names na <> [ "n"; "only_a" ] then
    fail
      (Printf.sprintf "a::Config fields = [%s], expected [n; only_a]"
         (String.concat "; " (field_names na)));
  if field_names nb <> [ "text"; "flag" ] then
    fail
      (Printf.sprintf "b::Config fields = [%s], expected [text; flag]"
         (String.concat "; " (field_names nb)));
  if List.mem "text" (field_names na) || List.mem "only_a" (field_names nb) then
    fail "the two Config shapes leaked into each other (cross-module field merge)";
  let sa = nominal_of env "a::State" and sb = nominal_of env "b::State" in
  if field_names sa <> [ "count" ] || field_names sb <> [ "label" ] then
    fail "State shapes are not separated";
  let ra = nominal_of env "a::Ready" and rb = nominal_of env "b::Ready" in
  if variant_names ra <> [ "Ready"; "Idle" ] || variant_names rb <> [ "Ready"; "Done" ]
  then fail
         (Printf.sprintf "Ready variants = [%s] / [%s], expected [Ready; Idle] / [Ready; Done]"
            (String.concat "; " (variant_names ra))
            (String.concat "; " (variant_names rb)));
  let ta = List.assoc "a::make" env.Typecheck.functions in
  let tb = List.assoc "b::make" env.Typecheck.functions in
  (match ta.Typecheck.ts_return, tb.Typecheck.ts_return with
   | Type_repr.Int _, Type_repr.Int _ -> ()
   | _ -> fail "make does not return Int in both modules")

(* ── lowering + MIR verify + VM execution ──────────────────────────── *)

let lower_and_run (env : Typecheck.env) (graph : Module_graph.t) : unit =
  (* every declaration item of the closure (the root file node carries
     the module wrappers; the inline child nodes carry the inner items) *)
  let all_items =
    List.concat_map (fun (n : Module_graph.module_node) -> n.Module_graph.node_items)
      graph.Module_graph.nodes
  in
  let base = Driver.lowering_env_of ~items:all_items env in
  let typed_nodes_tbl = Driver.typed_nodes_table_of env in
  let typed_patterns_tbl = Driver.typed_patterns_table_of env in
  let typed_for_patterns_tbl = Driver.typed_for_patterns_table_of env in
  let typed_let_patterns_tbl = Driver.typed_let_patterns_table_of env in
  let variants = Driver.user_variant_table env in
  let targets = [ "a::make"; "b::make"; "a::value"; "b::value" ] in
  let decl_of (qname : string) : Ast.function_decl =
    let rec find = function
      | [] -> fail ("no AST declaration for `" ^ qname ^ "`")
      | (n : Module_graph.module_node) :: rest ->
          let rec find_item = function
            | [] -> find rest
            | (it : Ast.item) :: more -> (
                match it.Ast.kind with
                | Ast.Function d
                  when Typecheck.qualified_name n.Module_graph.node_path
                         d.Ast.fn_sig.Ast.sig_name
                       = qname ->
                    d
                | _ -> find_item more)
          in
          find_item n.Module_graph.node_items
    in
    find graph.Module_graph.nodes
  in
  let lowered =
    List.map
      (fun qname ->
        let ts =
          match List.assoc_opt qname env.Typecheck.functions with
          | Some ts -> ts
          | None -> fail ("no typed signature for `" ^ qname ^ "`")
        in
        let d = decl_of qname in
        let fn =
          Mir_lower.lower_function_with_variants ~typed_nodes_tbl
            ~typed_patterns_tbl ~typed_for_patterns_tbl ~typed_let_patterns_tbl
            variants
            { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
            qname
            (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
            [||] [||] d
        in
        (* requirement: the function instance is the typed signature's
           callable (+ its declaration-order type args) *)
        let expected =
          Instance_id.make ~callable:ts.Typecheck.ts_callable
            ~type_args:
              (Array.of_list
                 (List.map
                    (fun (_, pid) -> Type_repr.Type_param pid)
                    ts.Typecheck.ts_params_decl))
        in
        if
          Ids.Callable_id.compare (Instance_id.callable fn.Seed_mir.instance)
            (Instance_id.callable expected)
          <> 0
        then fail ("lowered instance of `" ^ qname ^ "` does not match its typed signature");
        (qname, ts.Typecheck.ts_return, fn))
      targets
  in
  let prog =
    {
      Seed_mir.functions = Array.of_list (List.map (fun (_, _, f) -> f) lowered);
      statics = Driver.closure_statics env all_items;
      types = Driver.closure_types env;
    }
  in
  (match
     Mir_verify.require_valid_template
       ~generic_types:(Driver.closure_generic_types env)
       ~lang_items:(Typecheck.lang_items_of_env env)
       ~query_sigs:(Driver.closure_query_sigs ~lowered:(Some prog) env)
       prog
   with
   | Ok () -> ()
   | Error errs ->
       Printf.printf "MIR template verify errors:\n";
       List.iter (fun e -> Printf.printf "  %s\n" e) errs;
       fail "Mir_verify.require_valid_template rejected the program");
  let expect =
    [ ("a::make", "12"); ("b::make", "1"); ("a::value", "11"); ("b::value", "22") ]
  in
  List.iter
    (fun qname ->
      match List.assoc_opt qname expect with
      | None -> fail ("no expected value for `" ^ qname ^ "`")
      | Some expected ->
          let _, ret_ty, fn = List.find (fun (n, _, _) -> n = qname) lowered in
          (match ret_ty with
           | Type_repr.Int Type_repr.Int -> ()
           | _ -> fail ("`" ^ qname ^ "` does not return Int"));
          match
            Vm.entry_frame_of_li ~limits:Vm.default_limits
              ~lang_items:(Typecheck.lang_items_of_env env) ~program:prog
              ~entry:fn.Seed_mir.instance ~argv:[||]
          with
          | Error m -> fail (Printf.sprintf "VM entry for `%s`: %s" qname m)
          | Ok (vm, entry_frame) -> (
              match Vm.run_inspect vm entry_frame with
              | Error m -> fail (Printf.sprintf "VM run for `%s`: %s" qname m)
              | Ok got ->
                  if got <> expected then
                    fail
                      (Printf.sprintf "`%s` returned %s, expected %s" qname got expected)))
    targets

let () =
  let env, _prog_ast, graph, _manifest = build () in
  assert_separation env;
  lower_and_run env graph;
  Printf.printf
    "PASS: identity collision modules a/b are semantically separated (check+lower+verify+VM)\n";
  Selfcheck_sentinel.emit_and_exit "tg_identity_collision"
