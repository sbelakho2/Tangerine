(* tg_intrinsic_privacy.ml — the compiler-private intrinsic boundary
   (the seed side).

   `__intrinsic_map_clone` is the persistent-map SNAPSHOT (the
   compiler-internal Clone-performance facility), NOT generic Clone
   semantics: it shares the immutable store subject only to the runtime
   owned-region refusal.  Ordinary source must not be able to bypass
   K::clone/V::clone/drop by declaring and calling it.

   This self-check proves the SEED typechecker enforces the boundary:
     1. an ordinary module declaring the extern and calling it is
        REJECTED with the compiler-private diagnostic;
     2. a same-named ordinary FUNCTION is not hijacked by the intrinsic
        registry (the call stays a user call and type-checks clean) —
        proving ordinary source can never reach the host snapshot
        through the name.

   The kernel checker's paired gate (record_intrinsic_classification,
   keyed by env.current_module_path) is behaviorally tested by
   infer_probe's RESTRICTED_INTRINSIC_BATTERY through tg_infer. *)

let contains_sub (hay : string) (needle : string) : bool =
  let n = String.length hay and m = String.length needle in
  if m = 0 then true
  else
    let rec go i =
      if i + m > n then false
      else if String.sub hay i m = needle then true
      else go (i + 1)
    in
    go 0

let check_source (source : string) (file : string) :
    (string list, string) result =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let src = Source.of_bytes ~name:file ~bytes:source in
  let file_id = Span.add_file sm file src in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src.Source.bytes file_id diags [ "user" ] in
  if Diagnostic.has_errors diags then Error ("parse: " ^ Diagnostic.render sm diags)
  else
    let env = Typecheck.initial_env () in
    match Typecheck.check_program env program with
    | Error m -> Error m
    | Ok (_, errors) -> Ok errors

let () =
  let decl_call =
    "extern def __intrinsic_map_clone(v: Int) -> Int\n\n\
     def main() -> Int\n\
    \  let w = __intrinsic_map_clone(1)\n\
    \  0\n\
     end\n"
  in
  (match check_source decl_call "privacy_decl_call.tg" with
  | Error m ->
      Printf.printf "FAIL: the privacy probe did not type-check: %s\n" m;
      exit 1
  | Ok errors ->
      let rejected =
        List.exists
          (fun e -> contains_sub e "compiler-internal intrinsic")
          errors
      in
      if rejected then
        Printf.printf
          "PASS: ordinary source declaring/calling the compiler-private intrinsic is rejected\n"
      else begin
        Printf.printf
          "FAIL: rejected without the privacy diagnostic (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  let user_fn =
    "def __intrinsic_map_clone(v: Int) -> Int\n\
    \  v\n\
     end\n\n\
     def main() -> Int\n\
    \  let w = __intrinsic_map_clone(1)\n\
    \  0\n\
     end\n"
  in
  (match check_source user_fn "privacy_user_fn.tg" with
  | Error m ->
      Printf.printf
        "FAIL: a same-named ordinary function was rejected/hijacked: %s\n" m;
      exit 1
  | Ok errors ->
      if errors = [] then
        Printf.printf
          "PASS: a same-named ordinary function is called as a user function (no intrinsic hijack)\n"
      else begin
        Printf.printf
          "FAIL: a same-named ordinary function did not type-check clean (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  Selfcheck_sentinel.emit_and_exit "tg_intrinsic_privacy"
