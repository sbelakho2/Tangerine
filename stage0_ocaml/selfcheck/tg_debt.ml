(* tg_debt.ml — diagnostic-debt accounting self-check (audit P1-1).

   Runs the bootstrap type checker over a small inline program that
   deliberately exercises several error classes, then asserts the debt
   report invariants:
     1. every category name comes from the fixed category list;
     2. the bucket counts sum exactly to the report total;
     3. the distribution is STABLE: the same program produces the same
        report on independent check runs;
     4. the classifier maps representative diagnostics into every
        category of the fixed list.
   Prints the report and exits 0 only when all invariants hold. *)

let src_text = {|
struct Pair
  a: Int
  b: Int
end

def use_unknown_type(x: NopeType) -> Int
  x
end

def call_missing()
  no_such_function(1)
end

def ret_mismatch(a: Int) -> String
  a
end

def no_infer()
  let v = []
  v
end

def closure_no_infer()
  let f = |x| x
  f(1)
end

def needs_bound[T](x: T) -> T where T: MissingTrait
  x
end

def uses_pair()
  let p = Pair { a: 1, b: 2 }
  ret_mismatch(p.a)
end
|}

let () =
  let file, content =
    match Array.to_list Sys.argv with
    | _ :: f :: _ ->
        let ic = open_in f in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        (f, s)
    | _ -> ("<debt-self-check>", src_text)
  in
  match Source_loader.load_string file content with
  | Error _ -> Printf.printf "FAIL: load\n"; exit 1
  | Ok src ->
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags [ "debtcheck" ] in
      if Diagnostic.has_errors diags then begin
        Printf.printf "parse errors:\n%s\n" (Diagnostic.render sm diags);
        exit 1
      end;
      let check_once () =
        let env = Typecheck.initial_env () in
        match Typecheck.check_program env program with
        | Error m -> Printf.printf "  typecheck: FAIL %s\n" m; exit 1
        | Ok (_, errors) -> (errors, Typecheck.debt_report errors)
      in
      let errors1, rep1 = check_once () in
      let _errors2, rep2 = check_once () in
      Printf.printf "debt self-check: %s\n" file;
      Printf.printf "  errors: %d\n" (List.length errors1);
      (* 1. every category name from the fixed list, in fixed order *)
      let bad_names =
        List.filter (fun (c, _) -> not (List.mem c Debt_report.categories)) rep1.Debt_report.buckets
      in
      if bad_names <> [] then begin
        Printf.printf "FAIL: unknown category names: %s\n"
          (String.concat ", " (List.map fst bad_names));
        exit 1
      end;
      if List.map fst rep1.Debt_report.buckets <> Debt_report.categories then begin
        Printf.printf "FAIL: bucket order does not match the fixed category list\n";
        exit 1
      end;
      (* 2. bucket counts sum to the total *)
      if not (Debt_report.sum_ok rep1) then begin
        Printf.printf "FAIL: bucket counts do not sum to the total (%d)\n" rep1.Debt_report.total;
        exit 1
      end;
      (* 3. distribution is stable across independent runs *)
      if String.concat "\n" (Debt_report.to_lines rep1)
         <> String.concat "\n" (Debt_report.to_lines rep2)
      then begin
        Printf.printf "FAIL: report is not stable across identical runs\n";
        exit 1
      end;
      (* 4. representative diagnostics map to every category *)
      let spot =
        [
          ("unresolved_type", "def f: unknown type `Foo` at file#0[1..2)");
          ("unresolved_callable", "def f: unknown function `bar` at file#0[1..2)");
          ("unresolved_module", "def f: internal: not a module at file#0[1..2)");
          ("cannot_infer_generic", "def f: cannot infer type parameter `T` of `Option::None` at file#0[1..2)");
          ("type_mismatch", "def f: type mismatch: expected Int, found String (type mismatch) at file#0[1..2)");
          ("obligation", "def f: where-clause `Int: Eq` of method `contains` is unsatisfied (no matching impl) at file#0[1..2)");
          ("duplicate_decl", "def f: duplicate function `f` at file#0[1..2)");
          ("other", "def f: break outside a loop at file#0[1..2)");
        ]
      in
      let bad_spot =
        List.filter (fun (cat, msg) -> Debt_report.classify msg <> cat) spot
      in
      if bad_spot <> [] then begin
        Printf.printf "FAIL: classifier misclassifies:\n";
        List.iter
          (fun (cat, msg) ->
            Printf.printf "  expected %s, got %s: %s\n" cat (Debt_report.classify msg) msg)
          bad_spot;
        exit 1
      end;
      (* the report, machine-readable, then the gate verdict *)
      List.iter print_endline (Debt_report.to_lines rep1);
      Printf.printf "DEBT REPORT PASS\n";
      exit 0
