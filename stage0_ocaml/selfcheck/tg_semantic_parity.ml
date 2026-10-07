(* tg_semantic_parity.ml — seed-vs-kernel SEMANTIC parity, end to end.

   The bootstrap contract is that the OCaml seed and the in-VM kernel
   checker agree on the language's semantics.  This selfcheck measures
   that agreement on a focused corpus of tiny standalone programs:

     SEED side:  parse -> resolver -> check-to-fixpoint -> lower (the
                 driver's own env/typed-channel builders) -> MIR verify
                 -> seed VM (for programs with a main), all in-process
                 (the tg_identity_collision harness pattern);
     KERNEL side: the REAL kernel closure is compiled by the seed and run
                 in the seed VM; tg_compiler/infer_probe.tg's PARITY
                 battery reads build/parity_cases.txt (written by THIS
                 executable, so both sides see byte-identical sources)
                 and reports, per case, the kernel checker's verdict row
                 (verdict, error count, main's resolved return type, first
                 error) into build/infer_probe.txt.

   The comparison is strict on the comparable observables:
     * verdict (accept vs reject) MUST match every compared case;
     * for accepted cases the seed's resolved main return type MUST match
       the kernel's resolved main return type when both spellings are
       comparable (builtin scalar spellings);
     * for rejected cases the first diagnostic is mapped to a coarse
       class (missing-required-field / unknown-field / unknown-name /
       type-mismatch / compiler-private / ownership) and MUST match when
       both sides produce a recognized class.
   Anything the current harness cannot observe on both sides is reported
   as NOT-COMPARABLE with its exact reason — never as agreement.

   Mutation witnesses (plan step 6, fail-closed property): this executable
   also deletes one checker-recorded typed record for one node from a real
   checked env and requires the seed lowering to raise its immediate
   internal error naming that node — not a silent name-based fallback and
   not a wrong value.  Each witness runs a CONTROL lowering of the
   unmutated program first (it must succeed), then the mutated lowering
   (it must fail naming the node).  The analogous kernel-side mutations
   run inside the in-VM PARITY battery (PARITY_MUTATION rows, asserted by
   tg_infer's PARITY_BATTERY fails=0).

   Development aid: TG_PARITY_SEED_ONLY=1 prints only the seed rows and
   exits 2 without a sentinel (no kernel comparison, no pass claim). *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_semantic_parity: FAIL: %s\n" s;
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
          fail "cannot create the output directory %s: %s" p
            (Unix.error_message e)
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

(* Normalize id-bearing text: every digit run of length >= 2 becomes "N"
   (the kernel probe's own normalization; single digits are type spellings
   such as u8). Capped like the probe's residual class. *)
let norm_ids (s : string) : string =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c >= '0' && c <= '9' then begin
      let j = ref !i in
      while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do
        incr j
      done;
      if !j - !i >= 2 then Buffer.add_char b 'N' else Buffer.add_char b c;
      i := !j
    end
    else begin
      Buffer.add_char b c;
      incr i
    end
  done;
  let out = Buffer.contents b in
  if String.length out > 140 then String.sub out 0 140 else out

(* The coarse reject-class: the shared vocabulary both checkers were ported
   from. "" = the message is not classifiable by this harness (the row is
   then NOT-COMPARABLE, reported explicitly). *)
let coarse_class (msg : string) : string =
  if contains_sub msg "missing required field" then "missing-required-field"
  else if contains_sub msg "unknown field" then "unknown-field"
  else if
    contains_sub msg "unknown name" || contains_sub msg "unknown function"
    || contains_sub msg "unknown value" || contains_sub msg "unresolved name"
  then "unknown-name"
  else if contains_sub msg "type mismatch" || contains_sub msg "cannot unify"
  then "type-mismatch"
  else if
    contains_sub msg "compiler-internal intrinsic"
    || contains_sub msg "compiler-private"
  then "compiler-private"
  else if contains_sub msg "moved" || contains_sub msg "consumed" then
    "ownership"
  else ""

(* ── the corpus ─────────────────────────────────────────────────────── *)

type vm_expect = Vm_required | Vm_optional | Vm_no

type case_ = {
  label : string;
  src : string;
  vm : vm_expect;
  (* Some reason = excluded from the verdict/class comparison (the
     observable is not expressible on both sides with the current
     harness); the seed and kernel rows are still printed as evidence. *)
  not_comparable : string option;
}

let cases : case_ list =
  [
    (* duplicate names across modules (check-only: no main) *)
    {
      label = "dup_names_across_modules";
      src =
        {|module a
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
|};
      vm = Vm_no;
      not_comparable = None;
    };
    (* semantic field defaults *)
    {
      label = "default_local_shadow";
      src =
        "const X: Int = 1\n\nstruct S\n  n: Int = X\nend\n\ndef main() -> Int\n  let X: Int = 99\n  let s = S {}\n  s.n\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "default_nested";
      src =
        "const X: Int = 1\n\nstruct Inner\n  v: Int = 2\nend\n\nstruct Outer\n  n: Int = Inner {}.v + X\nend\n\ndef main() -> Int\n  let X: Int = 99\n  let o = Outer {}\n  o.n\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "default_call_in_default";
      src =
        "def base() -> Int\n  3\nend\n\nstruct S\n  n: Int = base()\nend\n\ndef main() -> Int\n  let s = S {}\n  s.n\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "default_owning_string";
      src =
        "struct Owned\n  n: Int = 7\n  text: String = \"d\"\nend\n\ndef main() -> Int\n  let o = Owned {}\n  o.text.len() + o.n - 6\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "default_owning_vec";
      src =
        "struct V\n  items: Vec[Int] = Vec::new()\nend\n\ndef main() -> Int\n  let v = V {}\n  v.items.len()\nend\n";
      vm = Vm_optional;
      not_comparable =
        Some
          "the standalone seed closure has no std prelude, so Vec::new() does not resolve on the seed side while the kernel's builtin registrations accept it";
    };
    (* field-default negatives *)
    {
      label = "field_default_missing_required";
      src =
        "struct Strict\n  value: Int\n  other: Int\nend\n\ndef main() -> Int\n  let s = Strict { value: 3 }\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "field_default_unknown_field";
      src =
        "struct Strict2\n  value: Int\nend\n\ndef main() -> Int\n  let s = Strict2 { value: 3, nope: 4 }\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "field_default_wrong_typed";
      src =
        "struct Bad\n  x: Int = \"abc\"\nend\n\ndef main() -> Int\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    (* generic constructor inference: expected-type solving on enums *)
    {
      label = "generic_option_none_expected";
      src =
        "def main() -> Int\n  let o: Option[Int] = Option::None\n  0\nend\n";
      vm = Vm_optional;
      not_comparable = None;
    };
    {
      label = "generic_option_some_match";
      src =
        "def main() -> Int\n  let o: Option[Int] = Option::Some(4)\n  match o\n  when Option::Some(v) then v\n  when Option::None then 0\n  end\nend\n";
      vm = Vm_optional;
      not_comparable = None;
    };
    {
      label = "generic_result_ok_call";
      src =
        "def inc(x: Int) -> Int\n  x + 1\nend\n\ndef main() -> Int\n  let r: Result[Int, String] = Result::Ok(inc(1))\n  match r\n  when Result::Ok(v) then v\n  when Result::Err(_m) then 0\n  end\nend\n";
      vm = Vm_optional;
      not_comparable = None;
    };
    {
      label = "generic_pending_vec_annotation";
      src =
        "def a() -> Int\n  var xs: Vec[Int] = Vec::new()\n  xs.len()\nend\n\ndef main() -> Int\n  a()\nend\n";
      vm = Vm_optional;
      not_comparable =
        Some
          "pending Vec constructor inference needs Vec::new(), which the standalone seed closure does not resolve (no std prelude); the kernel builtin channel accepts it";
    };
    (* imported/aliased defaults: NOT expressible with the current
       single-file harness — documented as a global NOT-COMPARABLE
       imported_aliased_defaults row at the end.  A `use a::{X}` case is
       deliberately NOT put in the kernel battery: it makes the in-VM
       kernel resolver trap inside its own Option::expect path before any
       checker verdict (observed: host call __intrinsic_option_expect:
       Option::expect: module not found in add_item_to_symbols), and the
       standalone seed closure has no multi-module import graph.  No case
       is faked for the dimension. *)
    (* methods *)
    {
      label = "method_inherent";
      src =
        "struct Point\n  x: Int\n  y: Int\nend\n\nimpl Point\n  def sum(self: Self) -> Int\n    self.x + self.y\n  end\nend\n\ndef main() -> Int\n  let p = Point { x: 1, y: 2 }\n  p.sum()\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "method_static_assoc";
      src =
        "struct Pair\n  a: Int\n  b: Int\nend\n\nimpl Pair\n  def make(a: Int, b: Int) -> Pair\n    Pair { a: a, b: b }\n  end\nend\n\ndef main() -> Int\n  let p = Pair::make(2, 5)\n  p.a + p.b\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    (* enums / patterns *)
    {
      label = "enum_payload_match";
      src =
        "enum E\n  A(Int)\n  B\nend\n\ndef main() -> Int\n  let e = E::A(4)\n  match e\n  when E::A(v) then v\n  when E::B then 0\n  end\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "enum_two_payloads";
      src =
        "enum Pair\n  Both(Int, Int)\n  Neither\nend\n\ndef pick(p: Pair) -> Int\n  match p\n  when Pair::Both(a, b) then a * 10 + b\n  when Pair::Neither then 0\n  end\nend\n\ndef main() -> Int\n  pick(Pair::Both(3, 4))\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "enum_nullary_value";
      src =
        "enum EC\n  A\n  B\nend\n\ndef pick(x: Int) -> EC\n  match x\n  when 1 then EC::A\n  when _ then EC::B\n  end\nend\n\ndef main() -> Int\n  match pick(1)\n  when EC::A then 5\n  when EC::B then 6\n  end\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    (* Map/Set/Vec at the checker level (receiver reads; construction needs
       the std prelude, see the NOT-COMPARABLE rows) *)
    {
      label = "vec_methods_read";
      src =
        "def use_vec(v: Vec[Int]) -> Int\n  v.len()\nend\n\ndef main() -> Int\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "map_methods_read";
      src =
        "def use_map(m: Map[String, Int]) -> Int\n  m.len()\nend\n\ndef main() -> Int\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "set_methods_read";
      src =
        "def use_set(s: Set[Int]) -> Bool\n  s.contains(1)\nend\n\ndef main() -> Int\n  0\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    (* moves / drops *)
    {
      label = "move_string";
      src =
        "def main() -> Int\n  let s = \"ab\"\n  let t = s\n  t.len()\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "drop_owned_local";
      src =
        "def main() -> Int\n  let s = \"xyz\".to_string()\n  let n = s.len()\n  n - 3\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    (* the private-intrinsic same-name function case (kernel battery C):
       an ordinary user function with the compiler-private spelling is a
       normal callable and must be ACCEPTED by both checkers. *)
    {
      label = "private_intrinsic_same_name";
      src =
        "def __intrinsic_map_clone(v: Int) -> Int\n  v + 6\nend\n\ndef main() -> Int\n  __intrinsic_map_clone(1)\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    (* control flow / literals / aggregates *)
    {
      label = "while_loop_sum";
      src =
        "def main() -> Int\n  var i = 0\n  var acc = 0\n  while i < 5 do\n    acc = acc + i\n    i = i + 1\n  end\n  acc\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "for_range_sum";
      src =
        "def main() -> Int\n  var acc = 0\n  for i in 0..5 do\n    acc = acc + i\n  end\n  acc\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "array_index";
      src =
        "def main() -> Int\n  let arr: [Int; 3] = [1, 2, 3]\n  let i = 1\n  arr[i] + arr[0]\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "tuple_projection";
      src = "def main() -> Int\n  let t = (1, 2)\n  t.0 + t.1\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "cast_int_widths";
      src =
        "def main() -> Int\n  let a = 1 as u8\n  let b = (a as Int) + 300\n  b\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "struct_field_chain";
      src =
        "struct Inner\n  a: Int\n  b: Int\nend\n\nstruct Outer\n  inner: Inner\nend\n\ndef mk() -> Outer\n  Outer { inner: Inner { a: 3, b: 4 } }\nend\n\ndef main() -> Int\n  let o = mk()\n  o.inner.a + o.inner.b\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "const_and_call";
      src =
        "const X: Int = 1\n\ndef add(a: Int, b: Int) -> Int\n  a + b\nend\n\ndef main() -> Int\n  add(X, 2)\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    {
      label = "const_call_pattern";
      src =
        "def four() -> Int = 4\n\ndef classify(x: Int) -> Int\n  match x\n  when four() then 1\n  when _ then 0\n  end\nend\n\ndef main() -> Int\n  classify(4) + classify(5) * 10\nend\n";
      vm = Vm_required;
      not_comparable = None;
    };
    (* negatives *)
    {
      label = "negative_unknown_name";
      src = "def main() -> Int\n  nope\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "negative_type_mismatch";
      src = "def main() -> Int\n  \"not an int\"\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
    {
      label = "negative_unknown_function";
      src = "def main() -> Int\n  no_such_fn(1)\nend\n";
      vm = Vm_no;
      not_comparable = None;
    };
  ]

let comparable_cases () =
  List.filter (fun c -> c.not_comparable = None) cases

(* ── the seed side ──────────────────────────────────────────────────── *)

type build_failure = F_parse of string | F_resolve of string | F_check of string

type seed_env = {
  se_env : Typecheck.env;
  se_prog : Ast.program;
  se_graph : Module_graph.t;
  se_errors : string list;
}

let seed_build (label : string) (src : string) : (seed_env, build_failure) result =
  let file = Filename.temp_file ("tg_sp_" ^ label) ".tg" in
  let cleanup () = try Sys.remove file with Sys_error _ -> () in
  write_file file src;
  let result =
    match Bootstrap_manifest.single ~file ~path:[] () with
    | Error m -> Error (F_parse m)
    | Ok manifest ->
        let diags = Diagnostic.create_bag () in
        let graph = Module_graph.create_with_sources manifest diags in
        if Diagnostic.has_errors diags then
          Error (F_parse ("parse: " ^ Diagnostic.render (Module_graph.source_map graph) diags))
        else
          let sm = Module_graph.source_map graph in
          let resolved = Resolver.resolve manifest graph diags in
          if Diagnostic.has_errors diags then
            Error (F_resolve ("resolve: " ^ Diagnostic.render sm diags))
          else
            let root =
              match
                List.find_opt
                  (fun (n : Module_graph.module_node) ->
                    n.Module_graph.node_path = [])
                  graph.Module_graph.nodes
              with
              | Some n -> n
              | None -> fail "case %s: no root module node" label
            in
            let prog = root.Module_graph.node_program in
            let rec fix env n =
              match Typecheck.check_program env prog with
              | Error m -> Error (F_check m)
              | Ok (env', errors) ->
                  if errors = [] || n = 0 then Ok (env', List.rev errors)
                  else fix env' (n - 1)
            in
            (match fix (Typecheck.initial_env ~resolved:(Some resolved) ()) 6 with
            | Error f -> Error f
            | Ok (env, errors) -> Ok { se_env = env; se_prog = prog; se_graph = graph; se_errors = errors })
  in
  cleanup ();
  result

(* Lower every free function + every impl method of the checked graph (the
   driver's own builder pattern: typed channels, user variant table,
   closure statics/types).  Raises Seed_bug like the driver path. *)
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

type seed_verdict = S_accept | S_reject | S_parse_reject

type seed_result = {
  sr_verdict : seed_verdict;
  sr_errors : int;
  sr_first : string;
  sr_main_ret : string option;
  sr_vm : string option;
  sr_note : string option;
}

let main_ts_of (env : Typecheck.env) : Typecheck.typed_signature option =
  match List.assoc_opt "main" env.Typecheck.functions with
  | Some ts -> Some ts
  | None ->
      List.find_map
        (fun (k, ts) ->
          if Util.has_suffix k "::main" then Some ts else None)
        env.Typecheck.functions

let find_main (prog : Seed_mir.program) : Seed_mir.function_ option =
  Array.to_list prog.Seed_mir.functions
  |> List.find_opt (fun (f : Seed_mir.function_) ->
         f.Seed_mir.name = "main" || Util.has_suffix f.Seed_mir.name "::main")

let seed_run (c : case_) : seed_result =
  match seed_build c.label c.src with
  | Error (F_parse m) ->
      { sr_verdict = S_parse_reject; sr_errors = 1; sr_first = m;
        sr_main_ret = None; sr_vm = None; sr_note = None }
  | Error (F_resolve m) ->
      { sr_verdict = S_reject; sr_errors = 1; sr_first = m;
        sr_main_ret = None; sr_vm = None; sr_note = None }
  | Error (F_check m) ->
      { sr_verdict = S_reject; sr_errors = 1; sr_first = m;
        sr_main_ret = None; sr_vm = None; sr_note = None }
  | Ok se ->
      if se.se_errors <> [] then
        {
          sr_verdict = S_reject;
          sr_errors = List.length se.se_errors;
          sr_first = (match se.se_errors with e :: _ -> e | [] -> "");
          sr_main_ret = None;
          sr_vm = None;
          sr_note = None;
        }
      else begin
        let main_ts = main_ts_of se.se_env in
        let main_ret =
          Option.map
            (fun (ts : Typecheck.typed_signature) ->
              Seed_mir.print_type ts.Typecheck.ts_return)
            main_ts
        in
        if c.vm = Vm_no then
          { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
            sr_main_ret = main_ret; sr_vm = None;
            sr_note = Some "check-only case (no VM demand)" }
        else
          match main_ts with
          | None ->
              { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                sr_main_ret = None; sr_vm = None;
                sr_note = Some "no main to lower" }
          | Some main_ts -> (
              try
                let prog = lower_all se.se_env se.se_graph in
                (match
                   Mir_verify.require_valid_template
                     ~generic_types:(Driver.closure_generic_types se.se_env)
                     ~lang_items:(Typecheck.lang_items_of_env se.se_env)
                     ~query_sigs:(Driver.closure_query_sigs ~lowered:(Some prog) se.se_env)
                     prog
                 with
                | Error errs ->
                    { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                      sr_main_ret = main_ret; sr_vm = None;
                      sr_note =
                        Some
                          ("verify: "
                          ^ String.concat "; "
                              (List.filteri (fun i _ -> i < 2) errs)) }
                | Ok () -> (
                    match find_main prog with
                    | None ->
                        { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                          sr_main_ret = main_ret; sr_vm = None;
                          sr_note = Some "no lowered main" }
                    | Some main_fn ->
                        if
                          match main_ts.Typecheck.ts_return with
                          | Type_repr.Int _ -> false
                          | _ -> true
                        then
                          { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                            sr_main_ret = main_ret; sr_vm = None;
                            sr_note = Some "main does not return an integer" }
                        else (
                          match
                            Vm.entry_frame_of_li ~limits:Vm.default_limits
                              ~lang_items:(Typecheck.lang_items_of_env se.se_env)
                              ~program:prog ~entry:main_fn.Seed_mir.instance
                              ~argv:[||]
                          with
                          | Error m ->
                              { sr_verdict = S_accept; sr_errors = 0;
                                sr_first = ""; sr_main_ret = main_ret;
                                sr_vm = None; sr_note = Some ("vm entry: " ^ m) }
                          | Ok (vm, entry_frame) -> (
                              match Vm.run_inspect vm entry_frame with
                              | Error m ->
                                  { sr_verdict = S_accept; sr_errors = 0;
                                    sr_first = ""; sr_main_ret = main_ret;
                                    sr_vm = None; sr_note = Some ("vm run: " ^ m) }
                              | Ok got ->
                                  { sr_verdict = S_accept; sr_errors = 0;
                                    sr_first = ""; sr_main_ret = main_ret;
                                    sr_vm = Some got; sr_note = None }))))
              with
              | Mir_lower.Seed_bug m ->
                  { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                    sr_main_ret = main_ret; sr_vm = None;
                    sr_note = Some ("seed lowering bug: " ^ m) }
              | e ->
                  { sr_verdict = S_accept; sr_errors = 0; sr_first = "";
                    sr_main_ret = main_ret; sr_vm = None;
                    sr_note = Some ("exception: " ^ Printexc.to_string e) })
      end

(* ── the seed-side mutation witnesses (plan step 6) ─────────────────── *)

let seed_mutation_witness () : int =
  (* witness 1: the const-read global binding *)
  let src =
    "const X: Int = 1\n\ndef add(a: Int, b: Int) -> Int\n  a + b\nend\n\ndef main() -> Int\n  add(X, 2)\nend\n"
  in
  match seed_build "mutation_global" src with
  | Error _ ->
      Printf.printf
        "MUTATION seed_global_deleted: FAIL (cannot build the checked env)\n";
      1
  | Ok se ->
      if se.se_errors <> [] then begin
        Printf.printf
          "MUTATION seed_global_deleted: FAIL (%d checker errors)\n"
          (List.length se.se_errors);
        1
      end
      else begin
        let const_node =
          Hashtbl.fold
            (fun nid b acc ->
              match b with
              | Typecheck.NB_const _ -> (
                  match acc with None -> Some nid | Some _ -> acc)
              | _ -> acc)
            se.se_env.Typecheck.typed_name_bindings None
        in
        match const_node with
        | None ->
            Printf.printf
              "MUTATION seed_global_deleted: FAIL (no NB_const record to delete)\n";
            1
        | Some nid ->
            (* CONTROL: the unmutated lowering succeeds and the VM result is
               the expected 3 (the value that a name fallback would also
               produce, so the mutation must fail for a DIFFERENT reason:
               the missing typed record). *)
            let control =
              try
                let prog = lower_all se.se_env se.se_graph in
                (match find_main prog with
                | Some main_fn -> (
                    match
                      Vm.entry_frame_of_li ~limits:Vm.default_limits
                        ~lang_items:(Typecheck.lang_items_of_env se.se_env)
                        ~program:prog ~entry:main_fn.Seed_mir.instance ~argv:[||]
                    with
                    | Ok (vm, frame) -> Vm.run_inspect vm frame
                    | Error m -> Error m)
                | None -> Error "no main")
              with e -> Error (Printexc.to_string e)
            in
            (match control with
            | Ok "3" -> ()
            | Ok got ->
                Printf.printf
                  "MUTATION seed_global_deleted: FAIL (control result %s, want 3)\n"
                  got;
                exit 1
            | Error m ->
                Printf.printf
                  "MUTATION seed_global_deleted: FAIL (control lowering/vm: %s)\n"
                  m;
                exit 1);
            Hashtbl.remove se.se_env.Typecheck.typed_name_bindings nid;
            (match
               (try Ok (ignore (lower_all se.se_env se.se_graph))
                with Mir_lower.Seed_bug m -> Error m)
             with
            | Ok () ->
                Printf.printf
                  "MUTATION seed_global_deleted: FAIL (lowering silently accepted the deleted record of node %s — a name-based fallback or a wrong value)\n"
                  (string_of_int (Ids.Node_id.to_int nid));
                1
            | Error m ->
                let nid_s = string_of_int (Ids.Node_id.to_int nid) in
                if contains_sub m nid_s
                   && contains_sub m "checker-recorded name binding"
                then begin
                  Printf.printf
                    "MUTATION seed_global_deleted: PASS node=%s error=%s\n" nid_s
                    m;
                  0
                end
                else begin
                  Printf.printf
                    "MUTATION seed_global_deleted: FAIL (error does not name node %s via the binding channel: %s)\n"
                    nid_s m;
                  1
                end)
      end

let seed_mutation_local_witness () : int =
  let src = "def main() -> Int\n  let a = 3\n  a + 1\nend\n" in
  match seed_build "mutation_local" src with
  | Error _ ->
      Printf.printf
        "MUTATION seed_local_deleted: FAIL (cannot build the checked env)\n";
      1
  | Ok se ->
      if se.se_errors <> [] then begin
        Printf.printf "MUTATION seed_local_deleted: FAIL (%d checker errors)\n"
          (List.length se.se_errors);
        1
      end
      else begin
        let local_node =
          Hashtbl.fold
            (fun nid b acc ->
              match b with
              | Typecheck.NB_local -> (
                  match acc with None -> Some nid | Some _ -> acc)
              | _ -> acc)
            se.se_env.Typecheck.typed_name_bindings None
        in
        match local_node with
        | None ->
            Printf.printf
              "MUTATION seed_local_deleted: FAIL (no NB_local record to delete)\n";
            1
        | Some nid ->
            (try ignore (lower_all se.se_env se.se_graph)
             with e ->
               Printf.printf
                 "MUTATION seed_local_deleted: FAIL (control lowering raised %s)\n"
                 (Printexc.to_string e);
               exit 1);
            Hashtbl.remove se.se_env.Typecheck.typed_name_bindings nid;
            (match
               (try Ok (ignore (lower_all se.se_env se.se_graph))
                with Mir_lower.Seed_bug m -> Error m)
             with
            | Ok () ->
                Printf.printf
                  "MUTATION seed_local_deleted: FAIL (lowering silently accepted the deleted local record of node %s)\n"
                  (string_of_int (Ids.Node_id.to_int nid));
                1
            | Error m ->
                let nid_s = string_of_int (Ids.Node_id.to_int nid) in
                if contains_sub m nid_s
                   && contains_sub m "checker-recorded name binding"
                then begin
                  Printf.printf "MUTATION seed_local_deleted: PASS node=%s error=%s\n"
                    nid_s m;
                  0
                end
                else begin
                  Printf.printf
                    "MUTATION seed_local_deleted: FAIL (error does not name node %s via the binding channel: %s)\n"
                    nid_s m;
                  1
                end)
      end

(* ── the kernel side ────────────────────────────────────────────────── *)

type kernel_row = {
  k_label : string;
  k_verdict : string;
  k_errors : int;
  k_main_ret : string;
  k_first : string;
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

let field_rest (line : string) (key : string) : string option =
  let k = key ^ "=" in
  let kl = String.length k in
  let n = String.length line in
  let rec find i =
    if i + kl > n then None
    else if String.sub line i kl = k then
      Some (String.sub line (i + kl) (n - i - kl))
    else find (i + 1)
  in
  find 0

let parse_kernel_rows (report : string) : kernel_row list =
  String.split_on_char '\n' report
  |> List.filter_map (fun line ->
         if String.length line > 7 && String.sub line 0 7 = "PARITY " then
           let rest = String.sub line 7 (String.length line - 7) in
           match String.index_opt rest ' ' with
           | None -> None
           | Some i ->
               let label = String.sub rest 0 i in
               let verdict =
                 match field_upto line "verdict" with Some v -> v | None -> "?"
               in
               let errors =
                 match field_upto line "errors" with
                 | Some v -> (try int_of_string v with _ -> -1)
                 | None -> -1
               in
               let main_ret =
                 match field_upto line "main_ret" with Some v -> v | None -> "-"
               in
               let first =
                 match field_rest line "first" with Some v -> v | None -> "-"
               in
               Some { k_label = label; k_verdict = verdict; k_errors = errors;
                      k_main_ret = main_ret; k_first = first }
         else None)

let is_accept (v : string) = v = "accept"

let known_scalar_ret (s : string) : bool =
  List.mem s
    [ "Int"; "UInt"; "Bool"; "String"; "Char"; "u8"; "u16"; "u32"; "u64";
      "u128"; "i8"; "i16"; "i32"; "i64"; "i128"; "()" ]

(* ── wiring ─────────────────────────────────────────────────────────── *)

let cases_file_format (cs : case_ list) : string =
  let b = Buffer.create 4096 in
  (* dup_names_across_modules is NOT shipped in the cases file: the
     single-program kernel probe cannot resolve inline `module ... end`
     blocks (its resolver's get_current_module Option::expect traps), so
     the kernel battery builds the two-module program with the
     resolution-probe crate scaffolding itself and emits that case's
     PARITY row directly.  Every other case is byte-identical on both
     sides. *)
  let shipped =
    List.filter (fun c -> c.label <> "dup_names_across_modules") cs
  in
  Buffer.add_string b (Printf.sprintf "PARITY_CASES %d\n" (List.length shipped));
  List.iter
    (fun c ->
      Buffer.add_string b
        (Printf.sprintf "CASE %s %d\n" c.label (String.length c.src));
      Buffer.add_string b c.src)
    shipped;
  Buffer.contents b

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  ensure_dir (Filename.concat repo_root "build");
  let seed_only = Sys.getenv_opt "TG_PARITY_SEED_ONLY" = Some "1" in

  (* seed-side mutation witnesses first (their rows are the fail-closed
     proof and must precede the corpus rows) *)
  let mutation_fails =
    seed_mutation_witness () + seed_mutation_local_witness ()
  in

  (* seed rows *)
  let seed_rows = List.map (fun c -> (c, seed_run c)) cases in
  List.iter
    (fun ((c : case_), (r : seed_result)) ->
      Printf.printf
        "SEED %s verdict=%s errors=%d main_ret=%s vm=%s note=%s%s\n"
        c.label
        (match r.sr_verdict with
        | S_accept -> "accept"
        | S_reject -> "reject"
        | S_parse_reject -> "parse-reject")
        r.sr_errors
        (match r.sr_main_ret with Some t -> t | None -> "-")
        (match r.sr_vm with Some v -> v | None -> "-")
        (match r.sr_note with Some n -> n | None -> "-")
        (if c.not_comparable <> None then " NOT_COMPARABLE" else ""))
    seed_rows;

  if seed_only then begin
    Printf.printf
      "tg_semantic_parity: DEV MODE (TG_PARITY_SEED_ONLY=1) — kernel comparison skipped; no pass claim\n";
    exit 2
  end;

  (* write the shared cases file, then run the kernel probe *)
  let parity_cases_path = Filename.concat repo_root "build/parity_cases.txt" in
  write_file parity_cases_path (cases_file_format cases);
  let report_path = Filename.concat repo_root "build/infer_probe.txt" in
  (try Sys.remove report_path with Sys_error _ -> ());
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let stages =
    match
      Driver.run_bootstrap_closure ~repo_root
        ~manifest_path:"bootstrap/infer_mini.manifest" ~target ~entry:None
        ~kernel_args:[ "infer"; "-o"; "infer_probe.out" ]
    with
    | Error m -> fail "kernel closure pipeline: %s" m
    | Ok s -> s
  in
  (match stages.Driver.bs_vm_code with
  | Some 0 -> ()
  | Some code ->
      if stages.Driver.bs_stdout <> "" then
        Printf.printf "kernel stdout:\n%s\n" stages.Driver.bs_stdout;
      fail "kernel probe VM exit %d (expected 0)" code
  | None ->
      (* surface the upstream closure diagnostics: the seed-side closure
         typecheck records its errors in ctx_type_errors, and a lower/mono
         failure leaves bs_vm_code=None with no other channel *)
      let errs = stages.Driver.bs_ctx.Driver.ctx_type_errors in
      List.iter
        (fun e -> Printf.printf "closure type error: %s\n" e)
        (List.filteri (fun i _ -> i < 12) errs);
      if stages.Driver.bs_stdout <> "" then
        Printf.printf "kernel stdout:\n%s\n" stages.Driver.bs_stdout;
      if stages.Driver.bs_stderr <> "" then
        Printf.printf "kernel stderr:\n%s\n" stages.Driver.bs_stderr;
      fail
        "the kernel VM run did not complete (upstream stage failed; %d closure typecheck error(s) listed above)"
        (List.length errs));
  if not (Sys.file_exists report_path) then
    fail "kernel probe report %s missing" report_path;
  let report = read_file report_path in
  print_string report;
  if not (contains_sub report "PARITY_BATTERY fails=0") then
    fail "the kernel PARITY battery reported failures (see the report above)";
  let kernel_rows = parse_kernel_rows report in
  (* duplicate-label guard: the kernel row set must carry exactly one row
     per corpus label (a duplicated row could mask a missing one while the
     row count still matches) *)
  List.iter
    (fun (k : kernel_row) ->
      if
        List.length
          (List.filter (fun (k2 : kernel_row) -> k2.k_label = k.k_label)
             kernel_rows)
        <> 1
      then fail "duplicate PARITY row for case %s" k.k_label)
    kernel_rows;

  (* comparison *)
  let compared = comparable_cases () in
  let mismatches = ref 0 in
  let nc_rows = ref 0 in
  List.iter
    (fun ((c : case_), (r : seed_result)) ->
      let k =
        List.find_opt (fun (k : kernel_row) -> k.k_label = c.label) kernel_rows
      in
      match k with
      | None ->
          Printf.printf
            "COMPARE %s MISMATCH: the kernel probe emitted no PARITY row for this case\n"
            c.label;
          incr mismatches
      | Some k -> (
          let seed_accept = r.sr_verdict = S_accept in
          let kernel_accept = is_accept k.k_verdict in
          (match c.not_comparable with
          | Some reason ->
              incr nc_rows;
              Printf.printf
                "NOT-COMPARABLE %s: %s (seed=%s kernel=%s)\n"
                c.label reason
                (if seed_accept then "accept" else "reject")
                (if kernel_accept then "accept" else "reject")
          | None ->
              let verdict_match = seed_accept = kernel_accept in
              if not verdict_match then incr mismatches;
              let ret_check =
                if not (seed_accept && kernel_accept) then "n/a"
                else
                  match (r.sr_main_ret, k.k_main_ret) with
                  | Some _, ("-" | "") -> "n/a"
                  | Some s, ks ->
                      if s = ks then "match"
                      else if known_scalar_ret s && known_scalar_ret ks then "MISMATCH"
                      else "n/a"
                  | None, _ -> "n/a"
              in
              if ret_check = "MISMATCH" then incr mismatches;
              let class_check =
                if seed_accept || kernel_accept then "n/a"
                else
                  let sc = coarse_class r.sr_first in
                  let kc = coarse_class k.k_first in
                  if sc = "" || kc = "" then "n/a"
                  else if sc = kc then "match"
                  else "MISMATCH"
              in
              if class_check = "MISMATCH" then incr mismatches;
              Printf.printf
                "COMPARE %s verdict=%s seed_accept=%b kernel_accept=%b kernel_verdict=%s main_ret=%s seed_main_ret=%s kernel_main_ret=%s first_class=%s seed_class=%s kernel_class=%s\n"
                c.label
                (if verdict_match then "match" else "MISMATCH")
                seed_accept kernel_accept k.k_verdict ret_check
                (match r.sr_main_ret with Some t -> t | None -> "-")
                k.k_main_ret class_check
                (if seed_accept then "-" else coarse_class r.sr_first)
                (if kernel_accept then "-" else coarse_class k.k_first);
              if
                c.vm = Vm_required && seed_accept && r.sr_vm = None
              then begin
                Printf.printf
                  "COMPARE %s MISMATCH: the seed did not produce the required VM result (%s)\n"
                  c.label
                  (match r.sr_note with Some n -> n | None -> "?");
                incr mismatches
              end;
              if c.vm = Vm_optional && seed_accept && r.sr_vm = None then begin
                incr nc_rows;
                Printf.printf
                  "NOT-COMPARABLE %s seed_vm: the seed produced no VM value (%s); the kernel checker has no evaluator, so the value observable is not comparable for this case\n"
                  c.label
                  (match r.sr_note with Some n -> n | None -> "?")
              end;
              if ret_check = "n/a" && seed_accept && kernel_accept
                 && r.sr_main_ret <> None && k.k_main_ret <> "-"
              then begin
                incr nc_rows;
                Printf.printf
                  "NOT-COMPARABLE %s main_ret: the two checkers spell the resolved return type differently (%s vs %s); only builtin scalars are compared\n"
                  c.label
                  (match r.sr_main_ret with Some t -> t | None -> "-")
                  k.k_main_ret
              end;
              if class_check = "n/a" && not seed_accept && not kernel_accept
              then begin
                incr nc_rows;
                Printf.printf
                  "NOT-COMPARABLE %s first_class: at least one checker's first diagnostic is outside the shared coarse vocabulary (seed=%s kernel=%s)\n"
                  c.label (norm_ids r.sr_first) (norm_ids k.k_first)
              end)))
    seed_rows;

  (* the harness-level NOT-COMPARABLE dimensions *)
  Printf.printf
    "NOT-COMPARABLE evaluator_values: the kernel probe typechecks inside the VM and has no nested evaluator, so the seed VM value has no kernel counterpart; verdict + resolved main return type are compared instead\n";
  Printf.printf
    "NOT-COMPARABLE container_constructors: the standalone seed closure has no std prelude (Vec::new/Map::new/Set::new unresolved) while the kernel's builtin registrations accept them; container construction and the pending Vec/Map constructor-inference cases are excluded from the compared corpus\n";
  Printf.printf
    "NOT-COMPARABLE imported_aliased_defaults: a `use a::{X}` default needs a multi-module import graph; in the single-file harness the in-VM kernel resolver traps inside its own Option::expect path (observed: host call __intrinsic_option_expect: Option::expect: module not found in add_item_to_symbols) before producing a checker verdict, and the standalone seed closure has no such graph — the dimension is documented, never faked\n";
  Printf.printf
    "NOT-COMPARABLE reject_diagnostic_text: the two checkers' full message texts are not identical; the coarse class comparison above is applied where both sides produce a recognized class\n";

  let n_compared = List.length compared in
  let n_kernel = List.length kernel_rows in
  Printf.printf
    "PARITY_SUMMARY compared=%d kernel_rows=%d mismatches=%d not_comparable_rows=%d mutation_fails=%d\n"
    n_compared n_kernel !mismatches !nc_rows mutation_fails;
  if n_kernel <> List.length cases then
    fail "kernel probe emitted %d PARITY rows for %d cases" n_kernel
      (List.length cases);
  if mutation_fails <> 0 then
    fail "%d seed mutation witness(es) failed (the lowering is not fail-closed)"
      mutation_fails;
  if !mismatches <> 0 then
    fail "%d seed-vs-kernel semantic mismatch(es)" !mismatches;
  Printf.printf
    "PASS: seed and kernel agree on %d comparable semantic cases (verdict + resolved main return type + coarse reject class where available); 2/2 seed mutation witnesses verified fail-closed (failures=%d); NOT-COMPARABLE rows documented above\n"
    n_compared mutation_fails;
  Selfcheck_sentinel.emit_and_exit "tg_semantic_parity"
