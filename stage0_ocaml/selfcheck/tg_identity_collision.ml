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
  static mut CELL: Int = 10

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

  def set() -> Int
    CELL = 11
    CELL
  end

  def cell() -> Int = CELL
end

module b
  const X: Int = 2
  const STATE: Int = 20
  static mut CELL: Int = 20

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

  def set() -> Int
    CELL = 22
    CELL
  end

  def cell() -> Int = CELL

  # (patch 3 item F): sequence BOTH modules' writes and reads inside ONE
  # VM entry — `a::set`/`a::cell` are spelled module-qualified (module `a`
  # has no parser ambiguity), while the bare `set`/`cell` resolve to THIS
  # module's own items (module b). The seed parser reserves the bare
  # prefix `b` for byte-string literals, so `b::set()` cannot be spelled
  # at the root; the module-local spelling is the exact same semantic
  # call. The combined value encodes xa=11, xb=22, read_a=11, read_b=22.
  def run_both() -> Int
    let xa = a::set()
    let xb = set()
    let read_a = a::cell()
    let read_b = cell()
    xa * 1000000 + xb * 10000 + read_a * 100 + read_b
  end
end
|}

(* (patch 3 item D — imported / aliased values): a two-FILE in-memory
   closure. The manifest is built over a throwaway repo root containing
   `stage0_ocaml/selfcheck/values.tg` and `stage0_ocaml/selfcheck/main.tg`
   (the manifest loader's `selfcheck:` record kind), so module `main`
   imports the sibling `values` with an exact group import and an ALIASED
   group import, and two struct-field DEFAULTS consume them. The whole
   chain check -> lower -> verify -> VM is exercised (compute must return
   X*100 + W = 705). *)
let import_values_src = {|
const X: Int = 7
const W: Int = 5
|}

let import_main_src = {|
use stage0_ocaml::selfcheck::values::{X}
use stage0_ocaml::selfcheck::values::{W as Y}

struct S
  base: Int = X
end

struct T
  extra: Int = Y
end

def compute() -> Int
  let s = S {}
  let t = T {}
  s.base * 100 + t.extra
end
|}

let fail (msg : string) : 'a =
  Printf.printf "FAIL: identity collision: %s\n" msg;
  exit 1

(* ── parse -> graph -> resolver -> checker fixpoint over the closure ── *)

let build_snapshot (source : string) :
    Typecheck.env * Ast.program * Module_graph.t * Bootstrap_manifest.t =
  let file = Filename.temp_file "tg_identity_collision" ".tg" in
  let oc = open_out_bin file in
  output_string oc source;
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

let build () = build_snapshot src

(* Two-file in-memory closure behind a throwaway repo root. The merged
   program concatenates both file modules' items (each item keeps its
   graph-stamped module_path), and the checker fixpoint runs over it. *)
let build_imports () :
    Typecheck.env * Ast.program * Module_graph.t * Bootstrap_manifest.t =
  let root = Filename.temp_file "tg_identity_imports" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let rec ensure p =
    if not (Sys.file_exists p) then begin
      ensure (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  let dir = Filename.concat root "stage0_ocaml/selfcheck" in
  ensure dir;
  let write path s =
    let oc = open_out_bin path in
    output_string oc s;
    close_out oc
  in
  write (Filename.concat dir "values.tg") import_values_src;
  write (Filename.concat dir "main.tg") import_main_src;
  let manifest_path = Filename.concat root "manifest.txt" in
  write manifest_path "version: 1\nselfcheck: values.tg\nselfcheck: main.tg\n";
  let manifest =
    match Bootstrap_manifest.load ~repo_root:root ~manifest_path with
    | Ok m -> m
    | Error e -> fail ("imports manifest: " ^ e)
  in
  let diags = Diagnostic.create_bag () in
  let graph = Module_graph.create_with_sources manifest diags in
  if Diagnostic.has_errors diags then begin
    Printf.printf "%s\n" (Diagnostic.render (Module_graph.source_map graph) diags);
    fail "imports parse errors"
  end;
  let resolved = Resolver.resolve manifest graph diags in
  if Diagnostic.has_errors diags then begin
    Printf.printf "%s\n" (Diagnostic.render (Module_graph.source_map graph) diags);
    fail "imports resolution errors"
  end;
  let values_node =
    match Module_graph.find_module_by_path graph [ "stage0_ocaml"; "selfcheck"; "values" ] with
    | Some n -> n
    | None -> fail "no values module node"
  in
  let main_node =
    match Module_graph.find_module_by_path graph [ "stage0_ocaml"; "selfcheck"; "main" ] with
    | Some n -> n
    | None -> fail "no main module node"
  in
  let merged =
    {
      (values_node.Module_graph.node_program) with
      Ast.items =
        values_node.Module_graph.node_program.Ast.items
        @ main_node.Module_graph.node_program.Ast.items;
    }
  in
  let rec fix env n =
    match Typecheck.check_program env merged with
    | Error m -> fail ("imports typecheck: " ^ m)
    | Ok (env', errors) ->
        if errors = [] then env'
        else if n = 0 then begin
          Printf.printf "imports check errors:\n";
          List.iter (fun e -> Printf.printf "  %s\n" e) errors;
          fail (Printf.sprintf "%d imports checker error(s)" (List.length errors))
        end
        else fix env' (n - 1)
  in
  let env = fix (Typecheck.initial_env ~resolved:(Some resolved) ()) 6 in
  (env, merged, graph, manifest)

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
   | _ -> fail "make does not return Int in both modules");
  (* (patch 3 item F): the two mutable statics are DISTINCT registry
     entries under their module-qualified keys — the lowering must never
     alias them. *)
  if not (List.mem_assoc "a::CELL" env.Typecheck.statics) then
    fail "a::CELL is not registered under its qualified static key";
  if not (List.mem_assoc "b::CELL" env.Typecheck.statics) then
    fail "b::CELL is not registered under its qualified static key";
  let a_cell_idx =
    List.find_index (fun (k, _) -> k = "a::CELL") env.Typecheck.statics
  and b_cell_idx =
    List.find_index (fun (k, _) -> k = "b::CELL") env.Typecheck.statics
  in
  if a_cell_idx = b_cell_idx then fail "a::CELL and b::CELL share one registry row"

(* ── lowering + MIR verify + VM execution ──────────────────────────── *)

let lower_and_run (env : Typecheck.env) (graph : Module_graph.t)
    (targets_expect : (string * string) list) :
    (string * Type_repr.t * Seed_mir.function_) list =
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
  let targets = List.map fst targets_expect in
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
  let expect = targets_expect in
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
    targets;
  lowered

(* (patch 3 item F): after lowering, the two same-named mutable statics
   must address DISTINCT static slots — if the lowering had aliased them
   to one slot, b::set would clobber a::CELL and the VM reads below would
   report 22/22. *)
let assert_static_slot_separation (lowered : (string * Type_repr.t * Seed_mir.function_) list) : unit =
  let static_write_index (fn : Seed_mir.function_) : int =
    let rec scan_stmts = function
      | [] -> None
      | (st : Seed_mir.statement) :: rest -> (
          match st with
          | Seed_mir.Assign ({ Seed_mir.root = Seed_mir.Static idx; _ }, _) -> Some idx
          | _ -> scan_stmts rest)
    in
    let rec scan_blocks i =
      if i >= Array.length fn.Seed_mir.blocks then None
      else
        match scan_stmts fn.Seed_mir.blocks.(i).Seed_mir.statements with
        | Some idx -> Some idx
        | None -> scan_blocks (i + 1)
    in
    match scan_blocks 0 with
    | Some idx -> idx
    | None -> fail ("no static Assign found in `" ^ fn.Seed_mir.name ^ "`")
  in
  let fn_of qname =
    let _, _, f = List.find (fun (n, _, _) -> n = qname) lowered in
    f
  in
  let idx_a = static_write_index (fn_of "a::set") in
  let idx_b = static_write_index (fn_of "b::set") in
  if idx_a = idx_b then
    fail
      (Printf.sprintf
         "a::set and b::set write the SAME static slot %d (mutable-static aliasing)"
         idx_a);
  Printf.printf "static slots: a::CELL=%d b::CELL=%d (distinct) PASS\n" idx_a idx_b

let () =
  let env, _prog_ast, graph, _manifest = build () in
  assert_separation env;
  let collision_targets =
    [
      ("a::make", "12");
      ("b::make", "1");
      ("a::value", "11");
      ("b::value", "22");
      (* item F: each module's set() returns its OWN cell value ... *)
      ("a::set", "11");
      ("b::set", "22");
      (* ... cell() in a fresh VM reads the INITIAL value of its OWN
         module's static (10 / 20), and b::run_both's single VM observes
         the write sequence: xa=11, xb=22, read_a=11, read_b=22 ->
         11221122. *)
      ("a::cell", "10");
      ("b::cell", "20");
      ("b::run_both", "11221122");
    ]
  in
  let lowered = lower_and_run env graph collision_targets in
  assert_static_slot_separation lowered;
  (* item D: imported + aliased defaults resolve/typecheck/lower/execute. *)
  let ienv, _iprog, igraph, _imanifest = build_imports () in
  let _ =
    lower_and_run ienv igraph
      [ ("stage0_ocaml::selfcheck::main::compute", "705") ]
  in
  Printf.printf
    "PASS: identity collision modules a/b are semantically separated (check+lower+verify+VM)\n";
  Printf.printf
    "PASS: mutable statics a::CELL/b::CELL stay distinct through both writes\n";
  Printf.printf
    "PASS: imported/aliased defaults (use values::{X}, use values::{W as Y}) execute (705)\n";
  Selfcheck_sentinel.emit_and_exit "tg_identity_collision"
