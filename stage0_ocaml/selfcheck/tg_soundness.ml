(* tg_soundness.ml — the re-audit's type-soundness negative proofs.

   The checker previously SILENTLY accepted failed unifications
   (`ignore (return_unify_err ...)` — a pure constructor), annotated-let
   mismatches, and nested-function signature/body failures.  These
   proofs assert that each of those invalid programs is now REJECTED,
   i.e. the checker propagates the error and no MIR reaches the lowerer. *)

let check_src (name : string) (src : string) : bool =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let module_path = [] in
  let src0 = Source.of_bytes ~name:"soundness_probe.tg" ~bytes:src in
  let file_id = Span.add_file sm "soundness_probe.tg" src0 in
  let lx = Lexer.create src0.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src0.Source.bytes file_id diags module_path in
  let env = Typecheck.initial_env () in
  match Typecheck.check_program env program with
  | Error m ->
      Printf.printf "  [%s] checker rejected: %s\n" name m;
      true
  | Ok (_, errors) ->
      if errors <> [] then begin
        Printf.printf "  [%s] rejected with %d error(s)\n" name (List.length errors);
        true
      end
      else begin
        Printf.printf "  [%s] FAIL: accepted an unsound program\n" name;
        false
      end

let () =
  Printf.printf "SOUNDNESS NEGATIVE PROOFS\n";
  let ok1 =
    check_src "annotated-let-mismatch" {|
def f() -> Int
  let x: Int = "hello"
  x
end
|}
  in
  let ok2 =
    check_src "if-branch-clash" {|
def f(c: Bool) -> Int
  if c then
    1
  else
    "hello"
  end
end
|}
  in
  let ok3 =
    check_src "nested-fn-bad-body" {|
def f() -> Int
  def helper() -> Int
    let x: Int = "nope"
    x
  end
  1
end
|}
  in
  let ok4 =
    check_src "tuple-vs-expected" {|
def g() -> (Int, Int)
  (1, 2)
end

def f() -> Int
  let t: Int = g()
  t
end
|}
  in
  (* re-audit P0 (the swallowed call-return failures): a normal-call
     tail whose resolved return type fails the expected-type
     reconciliation MUST be rejected — previously `ignore
     (same_named_ret ret exp)` discarded the fallback failure *)
  let ok5 =
    check_src "free-call-return-mismatch" {|
def gives_string() -> String
  "s"
end

def wants_int() -> Int
  gives_string()
end
|}
  in
  (* the method-call equivalent: previously `match unify ... with
     | Ok () -> () | Error _ -> ()` swallowed the method return *)
  let ok6 =
    check_src "method-return-mismatch" {|
enum E
  A(Int)
end

impl E
  def get(self: Self) -> String
    "s"
  end
end

def wants_int(e: E) -> Int
  e.get()
end
|}
  in
  (* index/range expected-type failures: a typed element position
     that contradicts the container element type must be rejected *)
  let ok7 =
    check_src "index-return-mismatch" {|
def f(v: Vec[Int]) -> String
  v[0]
end
|}
  in
  let ok8 =
    check_src "tuple-index-return-mismatch" {|
def f(t: (Int, Int)) -> String
  t.0
end
|}
  in
  if ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 then begin
    Printf.printf "SOUNDNESS = ALL PASS (8 negative proofs)\n";
    exit 0
  end
  else begin
    Printf.printf "SOUNDNESS = FAIL\n";
    exit 1
  end
