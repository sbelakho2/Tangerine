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
  (* G. NESTED default re-entrancy: lowering `Outer.n`'s default evaluates
     `Inner {}.v` (which lowers Inner.v's own default) and then `+ X`; the
     declaration context must SURVIVE the nested default (save/restore, not
     blind reset).  A non-re-entrant context reads the use-site local X and
     returns 101 instead of 3. *)
  let nested_src =
    "const X: Int = 1\n\n\
     struct Inner\n  v: Int = 2\nend\n\n\
     struct Outer\n  n: Int = Inner {}.v + X\nend\n\n\
     def main() -> Int\n\
    \  let X: Int = 99\n\
    \  let o = Outer {}\n\
    \  o.n\n\
     end\n"
  in
  let tmp2 = Filename.temp_file "tg_struct_nested" ".tg" in
  let oc2 = open_out_bin tmp2 in
  output_string oc2 nested_src;
  close_out oc2;
  let exe2 = Filename.concat (Sys.getcwd ()) "_build/default/bin/tg_stage0.exe" in
  let ic2 = Unix.open_process_in (Printf.sprintf "%s interpret %s" exe2 tmp2) in
  let out2 = In_channel.input_all ic2 in
  let status2 = Unix.close_process_in ic2 in
  let got2 = String.trim out2 in
  if status2 <> Unix.WEXITED 0 || got2 <> "3" then begin
    Printf.printf
      "FAIL G: nested default lost the declaration context (interpret output=%S, want \"3\" — 101 means the context was overwritten)\n"
      got2;
    exit 1
  end
  else
    Printf.printf
      "PASS G: a nested default keeps the declaration context end-to-end\n";
  (* H. a CALL inside a default: the callee identity is the checker's
     (the typed-call channel), not re-resolved text. *)
  let call_src =
    "def base() -> Int\n  3\nend\n\n\
     struct S\n  n: Int = base()\nend\n\n\
     def main() -> Int\n\
    \  let s = S { }\n\
    \  s.n\n\
     end\n"
  in
  let tmp3 = Filename.temp_file "tg_struct_calldefault" ".tg" in
  let oc3 = open_out_bin tmp3 in
  output_string oc3 call_src;
  close_out oc3;
  let exe3 = Filename.concat (Sys.getcwd ()) "_build/default/bin/tg_stage0.exe" in
  let ic3 = Unix.open_process_in (Printf.sprintf "%s interpret %s" exe3 tmp3) in
  let out3 = In_channel.input_all ic3 in
  let status3 = Unix.close_process_in ic3 in
  let got3 = String.trim out3 in
  if status3 <> Unix.WEXITED 0 || got3 <> "3" then begin
    Printf.printf
      "FAIL H: a call in a field default did not lower/execute correctly (output=%S)\n"
      got3;
    exit 1
  end
  else
    Printf.printf "PASS H: a call in a field default resolves semantically\n";
  (* I. an OWNING default (String coerced from a literal) must be
     constructed and owned correctly by the aggregate. *)
  let owned_src =
    "struct Owned\n  n: Int = 7\n  text: String = \"d\"\nend\n\n\
     def main() -> Int\n\
    \  let o = Owned { }\n\
    \  o.text.len() + o.n - 6\n\
     end\n"
  in
  let tmp4 = Filename.temp_file "tg_struct_owned" ".tg" in
  let oc4 = open_out_bin tmp4 in
  output_string oc4 owned_src;
  close_out oc4;
  let exe4 = Filename.concat (Sys.getcwd ()) "_build/default/bin/tg_stage0.exe" in
  let ic4 = Unix.open_process_in (Printf.sprintf "%s interpret %s" exe4 tmp4) in
  let out4 = In_channel.input_all ic4 in
  let status4 = Unix.close_process_in ic4 in
  let got4 = String.trim out4 in
  if status4 <> Unix.WEXITED 0 || got4 <> "2" then begin
    Printf.printf
      "FAIL I: an owning String default did not construct/own correctly (output=%S, want \"2\")\n"
      got4;
    exit 1
  end
  else
    Printf.printf "PASS I: an owning String default constructs and executes\n";
  Selfcheck_sentinel.emit_and_exit "tg_struct_literals"
