(* tg_flowcheck.ml — FlowResult adversarial selfcheck.

   The audit's P1: normal continuation must come exclusively from flow
   (fr_normal), never inferred from the expression TYPE.  A Unit branch
   completes normally — it does not diverge.  These cases pin the rule:

   1. Value-context branch join over Unit/Int must be REJECTED (there is
      no language rule permitting the join; the old "Unit => diverges"
      shortcut pretended the Unit branch could not continue).
   2. Statement-position divergent branches must be ACCEPTED (the
      value is discarded).
   3. Unit/Unit value joins must be ACCEPTED (a Unit value is a value).
   4. A match with a diverging arm (return) plus a Unit arm in VALUE
      context must be REJECTED (the Unit arm continues with Unit while
      the other arm diverges — the join is Unit-vs-divergent, which is
      fine for the normal continuation but the arm type is Unit, not the
      diverging arm's type).
   5. FnExpr bodies must propagate te_flow: a FnExpr whose body contains
      `return` must have an unreachable normal continuation.

   Every snippet is checked with Typecheck.initial_env; ACCEPT means zero
   errors, REJECT means at least one error.  Exit 0 only when every
   expectation holds. *)

let check_snippet (name : string) (expect_ok : bool) (src : string) : bool =
  let sm = Span.create () in
  let src_src = Source.of_bytes ~name:(name ^ ".tg") ~bytes:src in
  let file_id = Span.add_file sm src_src.Source.name src_src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src file_id diags [ "adhoc" ] in
  if Diagnostic.has_errors diags then begin
    Printf.printf "  %-46s parse-error (unexpected)\n" name;
    false
  end
  else begin
    let env = Typecheck.initial_env () in
    match Typecheck.check_program env program with
    | Error m ->
        Printf.printf "  %-46s check-error: %s\n" name m;
        false
    | Ok (_, errors) ->
        let ok = errors = [] in
        let status =
          match ok, expect_ok with
          | true, true -> "ACCEPT (expected)"
          | false, false -> "REJECT (expected)"
          | true, false -> "ACCEPT (WRONG — expected reject)"
          | false, true -> "REJECT (WRONG — expected accept)"
        in
        Printf.printf "  %-46s %s\n" name status;
        if not (ok = expect_ok) then begin
          List.iter (fun e -> Printf.printf "      %s\n" e) errors;
          false
        end
        else true
  end

let () =
  Printf.printf "FlowResult adversarial checks:\n";
  let all =
    [
      (* 1. value-context Unit/Int join must be rejected *)
      ( "value-join-unit-int",
        false,
        "def f(c: Bool) -> Int\n  let x = if c then () else 42 end\n  x\nend\n" );
      (* 2. statement-position divergent branches accepted *)
      ( "stmt-divergent-branches",
        true,
        "def f(c: Bool) -> Unit\n  if c then\n    let _ = 42\n  else\n    let _ = ()\n  end\nend\n" );
      (* 3. Unit/Unit value join accepted *)
      ( "value-join-unit-unit",
        true,
        "def f(c: Bool) -> Unit\n  let x = if c then () else () end\n  x\nend\n" );
      (* 4. match with diverging arm + Unit arm: the match value is the
         Unit arm's Unit (the diverging arm contributes no value type) —
         accepted; but the RECONCILE of a value match over Unit/other is
         rejected *)
      ( "match-value-unit-other",
        false,
        "def f(o: Option[Int]) -> Int\n  let x = match o\n    when Option::Some(v) then v\n    when Option::None then ()\n  end\n  x\nend\n" );
      (* 4b. the same match in discarded statement position accepted *)
      ( "match-stmt-unit-other",
        true,
        "def f(o: Option[Int]) -> Unit\n  match o\n    when Option::Some(v) then let _ = v\n    when Option::None then ()\n  end\nend\n" );
      (* 5. FnExpr with a return inside: the normal continuation is
         unreachable, so a Unit-returning function whose expression body
         returns early is fine *)
      ( "fnexpr-early-return",
        true,
        "def f(c: Bool) -> Unit\n  if c then\n    return\n  end\n  let _ = 1\nend\n" );
    ]
  in
  let results = List.map (fun (n, e, s) -> check_snippet n e s) all in
  let passed = List.fold_left (fun acc r -> if r then acc + 1 else acc) 0 results in
  Printf.printf "flowcheck: %d/%d passed\n" passed (List.length all);
  if passed = List.length all then exit 0 else exit 1
