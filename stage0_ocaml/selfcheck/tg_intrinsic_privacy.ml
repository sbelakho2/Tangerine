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

let check_source ?(module_path = [ "user" ]) ?(trusted = false) (source : string)
    (file : string) : (string list, string) result =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let src = Source.of_bytes ~name:file ~bytes:source in
  let file_id = Span.add_file sm file src in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src.Source.bytes file_id diags module_path in
  if Diagnostic.has_errors diags then Error ("parse: " ^ Diagnostic.render sm diags)
  else
    let env = Typecheck.initial_env ~trusted_compiler_origin:trusted () in
    match Typecheck.check_program env program with
    | Error m -> Error m
    | Ok (_, errors) -> Ok errors

let has_privacy_diag errors =
  List.exists (fun e -> contains_sub e "compiler-internal intrinsic") errors

let () =
  let decl_call =
    "extern def __intrinsic_map_clone(v: Int) -> Int\n\n\
     def main() -> Int\n\
    \  let w = __intrinsic_map_clone(1)\n\
    \  0\n\
     end\n"
  in
  (* A. ordinary extern declaration + call -> REJECTED *)
  (match check_source decl_call "privacy_decl_call.tg" with
  | Error m ->
      Printf.printf "FAIL: the privacy probe did not type-check: %s\n" m;
      exit 1
  | Ok errors ->
      if has_privacy_diag errors then
        Printf.printf
          "PASS A: ordinary declaration+call of the compiler-private intrinsic is rejected\n"
      else begin
        Printf.printf "FAIL A: no privacy diagnostic (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* B. declaration only -> REJECTED *)
  let decl_only =
    "extern def __intrinsic_map_clone(v: Int) -> Int\n\n\
     def main() -> Int\n\
    \  0\n\
     end\n"
  in
  (match check_source decl_only "privacy_decl_only.tg" with
  | Error m ->
      Printf.printf "FAIL: declaration-only probe did not type-check: %s\n" m;
      exit 1
  | Ok errors ->
      if has_privacy_diag errors then
        Printf.printf
          "PASS B: a declaration-only program is rejected at the declaration\n"
      else begin
        Printf.printf "FAIL B: declaration-only was not rejected (errors=%d)\n"
          (List.length errors);
        exit 1
      end);
  (* C. same-named ordinary FUNCTION -> ACCEPTED (seed/kernel parity) *)
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
        "FAIL C: a same-named ordinary function was rejected/hijacked: %s\n" m;
      exit 1
  | Ok errors ->
      if errors = [] then
        Printf.printf
          "PASS C: a same-named ordinary function is ordinary user semantics\n"
      else begin
        Printf.printf
          "FAIL C: a same-named ordinary function did not type-check clean (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* D. spoofed trusted module path, untrusted origin -> REJECTED *)
  (match
     check_source ~module_path:[ "tg_compiler"; "types" ] decl_call
       "privacy_spoofed.tg"
   with
  | Error m ->
      Printf.printf "FAIL: spoofed-module probe did not type-check: %s\n" m;
      exit 1
  | Ok errors ->
      if has_privacy_diag errors then
        Printf.printf
          "PASS D: a spoofed `tg_compiler::types` module cannot claim the private namespace\n"
      else begin
        Printf.printf
          "FAIL D: the spoofed module path was granted the private namespace (errors=%d)\n"
          (List.length errors);
        exit 1
      end);
  (* E. trusted closure origin + exact compiler module -> the privacy
     gate does NOT fire.  (The single-file recovery harness has its own
     registration quirk for synthetic module paths — the real closure
     pipeline resolves modules normally — so this asserts the
     authorization outcome: no privacy diagnostic.) *)
  (match
     check_source ~module_path:[ "tg_compiler"; "types" ] ~trusted:true
       decl_call "privacy_trusted.tg"
   with
  | Error m ->
      Printf.printf "FAIL E: the trusted closure origin was rejected: %s\n" m;
      exit 1
  | Ok errors ->
      if not (has_privacy_diag errors) then
        Printf.printf
          "PASS E: the trusted bootstrap-closure origin is authorized for the exact compiler module\n"
      else begin
        Printf.printf
          "FAIL E: the trusted origin was still privacy-rejected (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  Selfcheck_sentinel.emit_and_exit "tg_intrinsic_privacy"
