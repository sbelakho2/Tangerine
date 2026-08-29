(* tg_subset.ml — executable-subset firewall machine check (re-audit
   finding 2).

   The re-audit's machine check: `Subset-accepted AST variants ⊆
   Mir_lower-lowerable AST variants` — every AST variant is either fully
   typechecked + fully lowered + verified + executable, or Subset.check
   rejects it BEFORE semantic execution.  This selfcheck:

   (a) builds the ACCEPTED-VARIANT table from Subset's rules
       (Subset.expr_form_status — the firewall's form-level rules as
       data) and VERIFIES that table against the checker itself by
       parsing and running Subset.check on one specimen per form (a
       Rejected form must fire its E-code, an Accepted form must fire
       none, a Conditional form must fire a listed code on its
       reject-path specimen and none on its accept-path specimen);
   (b) builds the ACTUALLY-LOWERABLE table from mir_lower's cases — a
       curated table encoding which AST variants have working lowering
       branches (read from lower_expr, 2026-08-26);
   (c) asserts accepted ⊆ lowerable for every AST variant, printing any
       violation;
   (d) runs the manifest-wide subset firewall — the SAME pass the
       driver's bootstrap-check runs (module graph + @cfg elimination +
       Subset.check per module with fresh diagnostic bags) over
       bootstrap/compiler_kernel.manifest — asserting it completes,
       covers every manifest module, and that the SUBSET_FIREWALL
       status line is consistent with the findings (PASS iff zero).

   The subset findings are a SEPARATE channel from the typecheck debt:
   the driver uses a fresh diagnostic bag per module, so the firewall
   can never inflate debt_total (the bootstrap-check's debt counts
   typecheck errors only). *)

let failures = ref 0

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; incr failures) fmt

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

(* ── Specimen machinery ───────────────────────────────────────────
   Each specimen must PARSE cleanly (a parse error is a selfcheck
   failure — the specimen is broken, not the checker). *)

let parse_program (name : string) (src : string) : Ast.program =
  match Source_loader.load_string name src with
  | Error _ ->
      fail "specimen `%s`: source load failed" name;
      { Ast.items = []; prog_span = Span.synthetic; prog_module_path = [ "tg-subset" ] }
  | Ok source ->
      let sm = Span.create () in
      let file_id = Span.add_file sm source.Source.name source in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create source.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens source.Source.bytes file_id diags [ "tg-subset" ] in
      if Diagnostic.has_errors diags then begin
        fail "specimen `%s`: parse errors:\n%s" name (Diagnostic.render sm diags);
        { Ast.items = []; prog_span = Span.synthetic; prog_module_path = [ "tg-subset" ] }
      end
      else program

let subset_of (name : string) (src : string) : Diagnostic.bag =
  let program = parse_program name src in
  let diags = Diagnostic.create_bag () in
  Subset.check diags program;
  diags

let codes_of (diags : Diagnostic.bag) : string list = Diagnostic.codes diags

(* ── (a) the accepted-variant table, verified against the checker ──

   One specimen per form of Subset.expr_form_status.  `expect` is the
   set of E-codes the specimen must fire (empty = must fire none; the
   specimen must be constructible without tripping ANY other rule). *)

let check_specimen (form : string) (expect : string list) (src : string) : unit =
  let got = codes_of (subset_of ("form:" ^ form) src) in
  let missing = List.filter (fun c -> not (List.mem c got)) expect in
  let unexpected = List.filter (fun c -> not (List.mem c expect)) got in
  if missing <> [] || unexpected <> [] then
    fail "specimen for form `%s`: expected codes [%s], got [%s]" form
      (String.concat "; " expect) (String.concat "; " got)
  else check ("specimen for form `" ^ form ^ "` -> [" ^ String.concat "; " expect ^ "]") true

(* Accepted forms: fire nothing. *)
let accepted_specimens : (string * string) list =
  [
    ("IntLit", {|def f() -> Int
  1
end
|});
    ("FloatLit", {|def f() -> Float
  1.5
end
|});
    ("StringLit", {|def f() -> String
  "a"
end
|});
    ("CharLit", {|def f() -> Char
  'a'
end
|});
    ("BoolLit", {|def f() -> Bool
  true
end
|});
    ("Array", {|def f() -> Int
  let a = [1, 2]
  a[0]
end
|});
    ("Tuple", {|def f() -> Int
  (1, 2)
end
|});
    ("Block", {|def f() -> Int
  do
    1
  end
end
|});
    ("Index", {|def f(a: [Int; 3]) -> Int
  a[1]
end
|});
    ("Cast", {|def f() -> Int
  (1 as Int)
end
|});
    ("TryOp", {|def f() -> Option[Int]
  f()?
end
|});
    ("Unary", {|def f(x: Int) -> Int
  -x
end
|});
    ("Binary", {|def f() -> Int
  1 + 2
end
|});
    ("Return", {|def f() -> Int
  return 1
end
|});
    ("Break", {|def f() -> Int
  loop
    break
  end
end
|});
    ("Next", {|def f() -> Int
  loop
    next
  end
end
|});
    ("While", {|def f() -> Int
  var x = 0
  while x < 3 do
    x = x + 1
  end
  x
end
|});
    ("Loop", {|def f() -> Int
  loop
    break
  end
end
|});
    ("StructLit", {|struct P
  x: Int
end
def f() -> Int
  P { x: 1 }
end
|});
    ("Field", {|struct P
  x: Int
end
def f(p: P) -> Int
  p.x
end
|});
  ]

(* Rejected forms: the listed E-code must fire. *)
let rejected_specimens : (string * string * string) list =
  [
    ("ArrayRepeat", "E9038",
     {|def f() -> Int
  let a = [0; 3]
  a[0]
end
|});

    ("Closure", "E9040",
     {|def f() -> Int
  |x| x + 1
end
|});
    ("Await", "E9015",
     {|def f() -> Int
  await g()
end
|});
    ("MacroCall", "E9049",
     {|def f() -> Int
  panic!("boom")
end
|});
    ("CompoundAssign", "E9042",
     {|def f() -> Int
  var x = 1
  x += 1
  x
end
|});
    ("Handle", "E9016",
     {|def f() -> Int
  handle x end
end
|});
    ("Unless", "E9017",
     {|def f() -> Int
  unless false then
    1
  end
end
|});
    ("Until", "E9018",
     {|def f() -> Int
  var x = 0
  until x > 10 do
    x = x + 1
  end
  x
end
|});
    ("Try", "E9019",
     {|def f() -> Int
  try
    1
  end
end
|});
    ("Comptime", "E9006",
     {|def f() -> Int
  comptime
    1
  end
end
|});
  ]

(* Conditional forms: the accept-path specimen fires nothing; the
   reject-path specimen fires a listed code. *)
let conditional_accept_specimens : (string * string) list =
  [
    ("Name", {|def f(x: Int) -> Int
  x
end
|});
    ("UnsafeBlock", {|def f() -> Int
  unsafe "r" do
    1
  end
end
|});
    ("Range", {|def f() -> Int
  var t = 0
  for x in 0..5 do
    t = t + x
  end
  t
end
|});
    (* E9048 retired 2026-08-28: the lowerer's qualified static-call
       path serves the checker's full static-method dispatch (the
       (owner, method) methods-registry pair with the Vec<->Array /
       String<->str alias convention, the mangled free function, and
       the qualified user-enum ctors through the variant table), so the
       former E9048 rejection specimens are now positive subset
       accepts — a qualified user-enum variant in VALUE position, a
       qualified user-enum ctor CALL, and a nominal-qualified static
       method call *)
    ("Name (qualified user-enum variant)", {|enum Color
  Red,
  Green(Int)
end
def f() -> Color
  Color::Red
end
|});
    ("Name (qualified builtin ctor)", {|def f(o: Option[Int], r: Result[Int, Int]) -> Int
  let a = Option::Some(1)
  let b = Result::Ok(2)
  match a {
    Some(v) => v,
    None() => 0
  }
end
|});
    ("If", {|def f() -> Int
  if true then
    1
  else
    2
  end
end
|});
    ("Call", {|def g() -> Int
  0
end
def f() -> Int
  g()
end
|});
    ("Call (qualified user-enum ctor)", {|enum Color
  Red,
  Green(Int)
end
def f() -> Int
  match Color::Green(7) {
    Green(v) => v,
    _ => 0
  }
end
|});
    ("Call (qualified static method)", {|struct Vec
  data: Int
end
def f() -> Int
  Vec::new()
end
|});
    ("Match", {|def f(x: Int, o: Option[Int]) -> Int
  let a = match x {
    0 => 1,
    _ => 2
  }
  match o {
    Some(v) => v,
    None() => 0
  }
end
|});
    (* E9049 retired for the vec!/debug_assert! forms (2026-08-28 — the
       array-aggregate and condition-check lowering branches landed in
       mir_lower); the vec! accept-path specimen is the former E9049
       rejection specimen, now a positive subset accept *)
    ("MacroCall", {|def f() -> Int
  let a = vec![1, 2, 3]
  a[1]
end
|});
    ("Assign", {|def f() -> Int
  var x = 1
  x = 2
  x
end
|});
    (* E9036 retired for the Name/Field/Index writeback targets
       (2026-08-28 — the typed-place writeback rule landed in
       mir_lower's Assign branch); the index writeback accept-path
       specimen is the former E9036 rejection specimen, now a positive
       subset accept *)
    ("Assign (index writeback)", {|def f() -> Int
  var a = [1, 2, 3]
  a[1] = 9
  a[1]
end
|});
    ("Assign (field writeback)", {|struct P
  x: Int
end
def f(p: P) -> Int
  p.x = 9
  p.x
end
|});
    ("For", {|def f() -> Int
  var t = 0
  for x in [1, 2] do
    t = t + x
  end
  t
end
|});
  ]

let conditional_reject_specimens : (string * string * string) list =
  [
    ("If", "E9046",
     {|def f(o: Option[Int]) -> Int
  if let Some(x) = o then
    x
  else
    0
  end
end
|});
    ("Match", "E9044",
     {|def f(x: Int) -> Int
  match x {
    1..=5 => 1,
    _ => 0
  }
end
|});
    ("Assign", "E9036",
     {|def f(p: Ptr[Int]) -> Int
  *p + 1 = 2
  0
end
|});
    ("For", "E9045",
     {|def f() -> Int
  var t = 0
  for (k, (v, w)) in m do
    t = t + 1
  end
  t
end
|});
  ]

(* Match-arm sub-forms (E9043/E9044): arm guards and the arm patterns
   the lowerer cannot serve must fire E9043/E9044; the serveable arm
   forms (variant arms against the builtin table with name/underscore
   payloads, integer-literal arms, wildcard arms) must fire nothing. *)
let arm_specimens : (string * string list * string) list =
  [
    ("arm guard (E9043)", [ "E9043" ],
     {|def f(x: Int) -> Int
  match x {
    0 if x > 0 => 1,
    _ => 2
  }
end
|});
    ("arm binding pattern (accepted — the E9044 binding form retired)", [],
     {|def f(x: Int) -> Int
  match x {
    y => 1,
    _ => 2
  }
end
|});
    ("arm tuple pattern (accepted — the E9044 tuple-arm form retired)", [],
     {|def f(x: (Int, Int)) -> Int
  match x {
    (a, b) => a + b,
    _ => 0
  }
end
|});
    ("variant payload tuple pattern (accepted — the E9044 tuple form retired)", [],
     {|def f(o: Option[(Int, Int)]) -> Int
  match o {
    Some((a, b)) => a + b,
    _ => 0
  }
end
|});
    ("string literal arm (accepted — the E9044 string form retired)", [],
     {|def f(s: String) -> Int
  match s {
    "a" => 1,
    _ => 2
  }
end
|});
    ("integer literal arm (accepted)", [],
     {|def f(x: Int) -> Int
  match x {
    0 => 1,
    _ => 2
  }
end
|});
    ("wildcard arm (accepted)", [],
     {|def f(x: Int) -> Int
  match x {
    _ => 2
  }
end
|});
    ("builtin variant arms (accepted)", [],
     {|def f(o: Option[Int]) -> Int
  match o {
    Some(v) => v,
    None() => 0
  }
end
|});
    ("bare nullary-variant arm (accepted — the semantic TypedPattern resolution dispatches on the tag; the E9044 bare-identifier re-gate is retired)", [],
     {|def f(o: Option[Int]) -> Int
  match o {
    Some(v) => v,
    None => 0
  }
end
|});
    ("or-pattern arm (accepted — the semantic TypedPattern alternative interface lowers it; the E9044 or-pattern re-gate is retired)", [],
     {|def f(o: Option[Int]) -> Int
  match o {
    Some(x) | Some(y) => x + y,
    _ => 0
  }
end
|});
  ]

(* Let/for pattern sub-forms (E9045): a non-name let pattern or a
   non-name/non-wildcard for-loop pattern must fire E9045; name and
   wildcard forms must fire nothing. *)
let pattern_specimens : (string * string list * string) list =
  [
    ("destructuring let (accepted — E9045 tuple form retired)", [],
     {|def f() -> Int
  let (a, b) = (1, 2)
  a + b
end
|});
    ("plain let (accepted)", [],
     {|def f() -> Int
  let x = 1
  x
end
|});
    ("destructuring for pattern (accepted — E9045 tuple form retired)", [],
     {|def f() -> Int
  var t = 0
  for (k, v) in m do
    t = t + 1
  end
  t
end
|});
    ("wildcard for pattern (accepted)", [],
     {|def f() -> Int
  var t = 0
  for _ in [1, 2] do
    t = t + 1
  end
  t
end
|});
  ]

(* ── (b) the actually-lowerable table, curated from mir_lower ─────
   Read from mir_lower.lower_expr (2026-08-27 — the StructCtor
   aggregate rule and the typed-place FieldId projection rule landed;
   both are VM-proven in tg_lowersurface).  `Lowerable` = a working
   branch emits Seed MIR for the form; `Partial` = the branch lowers
   but specific sub-forms fail closed (called out in the comment);
   `Unlowerable` = the form falls to the expression-name diagnostic
   table ("unhandled supported expression form") or a dedicated
   always-failing branch. *)

type lower_status = Lowerable | Partial | Unlowerable

let lower_status_name = function
  | Lowerable -> "Lowerable"
  | Partial -> "Partial"
  | Unlowerable -> "Unlowerable"

let expr_lower_status : (string * lower_status) list =
  [
    ("IntLit", Lowerable);
    ("FloatLit", Lowerable);
    ("StringLit", Lowerable);
    ("CharLit", Lowerable);
    ("BoolLit", Lowerable);
    (* locals and builtin enum ctors lower; a function reference in
       value position fails closed ("function value ... without a
       resolved callable identity") *)
    ("Name", Partial);
    (* the parser folds qualified names into Name; a Path value would
       fail closed at lowering *)
    ("Path", Unlowerable);
    ("Array", Lowerable);
    (* no ArrayRepeat branch — the expression-name diagnostic table *)
    ("ArrayRepeat", Unlowerable);
    ("Tuple", Lowerable);
    (* the StructCtor aggregate rule: the literal lowers with the typed
       registry's declaration-order positions (the same order
       closure_types materializes into the StructDefs); the `..` spread
       sub-form fails closed ("no spread channel") *)
    ("StructLit", Partial);
    ("Block", Lowerable);
    (* unsafe blocks lower their body like a plain block *)
    ("UnsafeBlock", Lowerable);
    (* lower_if ignores the if-let pattern entirely *)
    ("If", Partial);
    (* Name callees lower (functions + builtin/user-enum ctors through
       the variant table); Field callees (method calls) lower through
       the receiver-typed method rule when the methods table carries
       the instance; nominal-qualified "Type::method" names and
       unresolved receivers fail closed *)
    ("Call", Partial);
    ("Index", Lowerable);
    (* `a..b` counts with <, `a..=b` with <= — the counter-loop branch *)
    ("Range", Lowerable);
    (* variant arms (builtin table only), integer-literal arms and
       wildcard arms lower; guards, bindings, tuple/struct/or/range and
       non-integer literal arms fail closed *)
    ("Match", Partial);
    ("Cast", Lowerable);
    (* `?` lowers for Option/Result subjects with a matching enclosing
       return type *)
    ("TryOp", Lowerable);
    (* dedicated always-failing branch: closure expressions fail closed
       ("closure expressions are not lowerable: ... no closure-CALL path"),
       and Subset rejects the form (E9040) — the closure disposition
       (re-audit lowering-surface item) *)
    ("Closure", Unlowerable);
    (* Neg/Not/BitNot lower; Deref/Borrow/BorrowMut pass through *)
    ("Unary", Partial);
    (* the typed-place (FieldId) rule: a projected read resolves the
       base's type against the typed nominal registry and emits the
       semantic FieldId projection (tuples project positionally with
       ConstantIndex); every unresolvable field fails closed — never a
       silent Unit *)
    ("Field", Lowerable);
    ("Binary", Lowerable);
    ("Await", Unlowerable);
    (* `vec![...]` lowers to the array aggregate and `debug_assert!(...)`
       evaluates the condition (the E9049 forms are retired); every
       other macro fails closed *)
    ("MacroCall", Partial);
    (* Name/Field/Index targets lower through the typed-place writeback
       rule (2026-08-28: the Assign branch resolves the field through
       the typed nominal registry and emits the constant/dynamic index
       projections); other target forms fail closed *)
    ("Assign", Lowerable);
    (* dedicated always-failing branch ("CompoundAssign reached MIR
       lowering without a typed-place writeback rule") *)
    ("CompoundAssign", Unlowerable);
    ("Return", Lowerable);
    (* the break VALUE is dropped by the lowering (never lowered) *)
    ("Break", Partial);
    ("Next", Lowerable);
    (* Array-literal iterables unroll; Fixed_array iterables lower to a
       runtime counter loop; other iterables fail closed *)
    ("For", Partial);
    ("While", Lowerable);
    ("Loop", Lowerable);
    ("Handle", Unlowerable);
    ("Unless", Unlowerable);
    ("Until", Unlowerable);
    ("Try", Unlowerable);
    ("Comptime", Unlowerable);
  ]

(* ── (c) accepted ⊆ lowerable ──────────────────────────────────── *)

let check_accepted_subset_lowerable () : unit =
  let lowerable_of = Hashtbl.create 64 in
  List.iter (fun (form, s) -> Hashtbl.replace lowerable_of form s) expr_lower_status;
  let violations = ref [] in
  List.iter
    (fun (form, status) ->
      match Hashtbl.find_opt lowerable_of form with
      | None ->
          violations :=
            Printf.sprintf "%s: Subset has a rule but the lowerable table does not" form
            :: !violations
      | Some ls -> (
          match status, ls with
          | (Subset.Accepted | Subset.Conditional _), (Lowerable | Partial) -> ()
          | Subset.Rejected _, _ | Subset.Unreachable, _ -> ()
          | (Subset.Accepted | Subset.Conditional _), Unlowerable ->
              violations :=
                Printf.sprintf "%s: Subset accepts it but mir_lower is %s"
                  form (lower_status_name ls)
                :: !violations))
    Subset.expr_form_status;
  List.iter
    (fun (form, _) ->
      if not (List.mem_assoc form Subset.expr_form_status) then
        violations :=
          Printf.sprintf "%s: the lowerable table has it but Subset has no rule" form
          :: !violations)
    expr_lower_status;
  match List.rev !violations with
  | [] -> check "accepted ⊆ lowerable for every AST variant" true
  | vs ->
      List.iter (fun v -> Printf.printf "    violation: %s\n" v) vs;
      check "accepted ⊆ lowerable for every AST variant" false

(* ── (d) the manifest-wide firewall run ────────────────────────── *)

let manifest_subset_firewall ~(repo_root : string) : (Driver.subset_result, string) result =
  match Bootstrap_manifest.load ~repo_root ~manifest_path:"bootstrap/compiler_kernel.manifest" with
  | Error m -> Error m
  | Ok manifest ->
      let diags = Diagnostic.create_bag () in
      let graph = Module_graph.create_with_sources manifest diags in
      if Diagnostic.has_errors diags then Error "module graph diagnostics"
      else
        (match Target.unsupported_triple "aarch64-apple-darwin" with
         | Error m -> Error m
         | Ok target -> (
             match Driver.apply_cfg_elimination ~manifest ~graph target with
             | Error m -> Error m
             | Ok (graph', _) -> Ok (Driver.subset_firewall_of_graph graph')))

let run_manifest_firewall () : unit =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: "--repo-root" :: r :: _ -> r
    | _ -> ".."
  in
  match manifest_subset_firewall ~repo_root with
  | Error m -> fail "manifest-wide subset firewall: %s" m
  | Ok r ->
      Driver.print_subset_firewall r;
      let n = List.length r.Driver.sr_modules in
      let module SSet = Set.Make (String) in
      let keys = List.fold_left (fun s m -> SSet.add m.Driver.ssm_key s) SSet.empty r.Driver.sr_modules in
      check "manifest-wide subset firewall completes" true;
      check "manifest-wide subset firewall covers every module (dedup by source file)"
        (n > 0 && SSet.cardinal keys = n);
      let status = Driver.subset_firewall_status r in
      let consistent =
        (status = "PASS" && r.Driver.sr_total = 0)
        || (status = "FAIL" && r.Driver.sr_total > 0)
      in
      check
        (Printf.sprintf "SUBSET_FIREWALL status line consistent (status = %s, %d findings)" status
           r.Driver.sr_total)
        consistent

(* ── the check ─────────────────────────────────────────────────── *)

let () =
  Printf.printf "TANGERINE OCAML SEED — executable-subset firewall machine check (tg_subset)\n";
  Printf.printf "  [a] accepted-variant table from Subset.expr_form_status, verified by specimens\n";
  List.iter (fun (form, src) -> check_specimen form [] src) accepted_specimens;
  List.iter (fun (form, code, src) -> check_specimen form [ code ] src) rejected_specimens;
  List.iter (fun (form, src) -> check_specimen (form ^ " (accept path)") [] src)
    conditional_accept_specimens;
  List.iter (fun (form, code, src) -> check_specimen (form ^ " (reject path)") [ code ] src)
    conditional_reject_specimens;
  List.iter (fun (name, expect, src) -> check_specimen name expect src) arm_specimens;
  List.iter (fun (name, expect, src) -> check_specimen name expect src) pattern_specimens;
  Printf.printf "  [b] actually-lowerable table from mir_lower's cases (curated)\n";
  List.iter (fun (form, s) -> Printf.printf "    %-18s %s\n" form (lower_status_name s))
    expr_lower_status;
  Printf.printf "  [c] accepted ⊆ lowerable\n";
  check_accepted_subset_lowerable ();
  Printf.printf "  [d] manifest-wide subset firewall over bootstrap/compiler_kernel.manifest\n";
  run_manifest_firewall ();
  if !failures = 0 then begin
    Printf.printf "tg_subset: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_subset: %d FAILURE(S)\n" !failures;
    exit 1
  end
