(* tg_struct_literals.ml — the struct-literal completeness contract
   (E0203) on the seed side.

   The ONE rule:
     - a supplied field        -> the expression is checked;
     - an omitted field WITH a declaration default (`= <expr>`) -> legal,
       the declaration-typed default is used;
     - an omitted field with NO declaration default -> E0203
       "missing required field", never a silent type-default;
     - a `..rest` spread supplies the remaining fields.

   The default expression itself is checked IN THE DECLARATION'S SCOPE
   against the declared field type, so a wrong-typed default fails even
   when no literal ever omits the field, and a declaration-local name in
   a default binds at the declaration. *)

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
    (* the driver's declaration fixpoint: transient first-round ordering
       errors clear as registrations settle (tg_derived_clone's
       check_to_fixpoint pattern); a genuine diagnostic survives every
       round. *)
    let rec fix env n =
      match Typecheck.check_program env program with
      | Error m -> Error m
      | Ok (env', errors) -> if errors = [] || n = 0 then Ok errors else fix env' (n - 1)
    in
    fix (Typecheck.initial_env ()) 6

let has errors needle = List.exists (fun e -> contains_sub e needle) errors

let fail fmt = Printf.ksprintf (fun m -> Printf.printf "FAIL: %s\n" m; exit 1) fmt

let () =
  (* A. omitted REQUIRED field -> E0203 *)
  (match
     check_source
       "struct S\n  a: Int\n  b: Int\nend\n\n\
        def main() -> Int\n\
       \  let s = S { a: 1 }\n\
       \  0\n\
        end\n"
       "struct_required.tg"
   with
  | Error m -> fail "required-omission probe: %s" m
  | Ok errors ->
      if has errors "missing required field" then
        Printf.printf "PASS A: omitting a required field reports E0203\n"
      else begin
        Printf.printf "FAIL A: no missing-required-field diagnostic (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* B. omitted DEFAULTED field -> accepted *)
  (match
     check_source
       "struct S\n  a: Int\n  b: Int = 7\nend\n\n\
        def main() -> Int\n\
       \  let s = S { a: 1 }\n\
       \  0\n\
        end\n"
       "struct_defaulted.tg"
   with
  | Error m -> fail "defaulted-omission probe: %s" m
  | Ok errors ->
      if errors = [] then
        Printf.printf "PASS B: omitting a defaulted field is accepted\n"
      else begin
        Printf.printf "FAIL B: defaulted omission produced errors (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* C. wrong-typed default -> error at the DECLARATION, no literal needed *)
  (match
     check_source
       "struct S\n  x: Int = \"abc\"\nend\n\n\
        def main() -> Int\n\
       \  0\n\
        end\n"
       "struct_bad_default.tg"
   with
  | Error m -> fail "bad-default probe: %s" m
  | Ok errors ->
      if errors <> [] then
        Printf.printf "PASS C: a wrong-typed default fails at the declaration\n"
      else begin
        Printf.printf "FAIL C: a wrong-typed default was accepted\n";
        exit 1
      end);
  (* D. declaration-local name in a default resolves at the declaration *)
  (match
     check_source
       "const X: Int = 1\n\n\
        struct S\n  n: Int = X\nend\n\n\
        def main() -> Int\n\
       \  let s = S { }\n\
       \  0\n\
        end\n"
       "struct_local_default.tg"
   with
  | Error m -> fail "local-default probe: %s" m
  | Ok errors ->
      if errors = [] then
        Printf.printf "PASS D: a declaration-local name in a default is accepted\n"
      else begin
        Printf.printf "FAIL D: declaration-local default produced errors (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* E. `..rest` spread is REJECTED before lowering (no false green) *)
  (match
     check_source
       "struct S\n  a: Int\n  b: Int\nend\n\n\
        def main() -> Int\n\
       \  let base = S { a: 1, b: 2 }\n\
       \  let s = S { a: 3, ..base }\n\
       \  0\n\
        end\n"
       "struct_spread.tg"
   with
  | Error m -> fail "spread probe: %s" m
  | Ok errors ->
      if has errors "spread is not supported" then
        Printf.printf "PASS E: a `..` spread is rejected before lowering\n"
      else begin
        Printf.printf
          "FAIL E: spread literal was not rejected (errors=%d)\n"
          (List.length errors);
        List.iter (Printf.printf "    %s\n") errors;
        exit 1
      end);
  (* F. DECLARATION-BOUND default end-to-end (typecheck -> lower -> VM):
     a use-site local shadowing the declaration's const must NOT capture
     the default. *)
  let shadow_src =
    "const X: Int = 1\n\n\
     struct S\n  n: Int = X\nend\n\n\
     def main() -> Int\n\
    \  let X: Int = 99\n\
    \  let s = S { }\n\
    \  s.n\n\
     end\n"
  in
  let tmp = Filename.temp_file "tg_struct_shadow" ".tg" in
  let oc = open_out_bin tmp in
  output_string oc shadow_src;
  close_out oc;
  let exe = Filename.concat (Sys.getcwd ()) "_build/default/bin/tg_stage0.exe" in
  let ic = Unix.open_process_in (Printf.sprintf "%s interpret %s" exe tmp) in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let got = String.trim out in
  if status <> Unix.WEXITED 0 || got <> "1" then begin
    Printf.printf
      "FAIL F: declaration-bound default captured the use-site local (interpret output=%S status=%s)\n"
      got
      (match status with
      | Unix.WEXITED c -> string_of_int c
      | Unix.WSIGNALED s -> "sig" ^ string_of_int s
      | Unix.WSTOPPED s -> "stop" ^ string_of_int s);
    exit 1
  end
  else
    Printf.printf
      "PASS F: a field default is declaration-bound end-to-end (local shadow ignored)\n";
  Selfcheck_sentinel.emit_and_exit "tg_struct_literals"
