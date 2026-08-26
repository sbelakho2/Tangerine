(* tg_access_resource.ml — the FIRST INTEGRATED SEMANTIC PASS self-check
   (re-audit P0-11).

   Proves Access_check.run_closure over the typechecker's RECORDED typed
   channels — the integrated path is exactly what the driver's
   bootstrap-check runs after the typecheck phase:

     parse -> typecheck (the oracle accumulates one access record per
     checked call argument: place path + callee-side read effect) ->
     Access_check.run_closure env.state.oracle.o_accesses

   Each tiny inline program is typechecked FIRST (must be 0 type errors,
   so the recorded channel is the honest one), then the pass runs:

   (a) a program whose one statement group borrows the same local twice
       mutably (`f(&mut x, &mut x)`) must produce an access-conflict
       finding from the effect-pair matrix;
   (b) the same shape with reads only must produce NO finding;
   (c) a sink call on the same local twice (`take(x); take(x)`) must
       produce a state-conflict finding (double-move) from the
       Resource_check lattice replay;
   (d) a read after a sink on the same local must produce a
       use-after-consume state finding;
   (e) a single sink with no later use must produce NO finding;
   (f) the channel must ACCUMULATE across items (two call-bearing
       functions both present in the recorded channel). *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

(* Typecheck an inline program and return the env (its recorded channel
   is the pass's input).  Any parse or typecheck error fails the check:
   the selfcheck proves the pass on CLEAN typed channels. *)
let typecheck_program (name : string) (src : string) : Typecheck.env =
  match Source_loader.load_string name src with
  | Error m ->
      let msg =
        match m with
        | Source_loader.Unreadable s -> s
        | Source_loader.NotUTF8 (s, _) -> s
        | Source_loader.Security (s, _) -> s
      in
      failwith ("load failed: " ^ msg)
  | Ok source ->
      let sm = Span.create () in
      let file_id = Span.add_file sm source.Source.name source in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create source.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program =
        Parser.parse tokens source.Source.bytes file_id diags [ "tg_access_resource" ]
      in
      if Diagnostic.has_errors diags then
        failwith ("parse errors:\n" ^ Diagnostic.render sm diags);
      let env = Typecheck.initial_env () in
      (match Typecheck.check_program env program with
       | Error m -> failwith ("typecheck failed: " ^ m)
       | Ok (env, errors) ->
           if errors <> [] then
             failwith
               (Printf.sprintf "typecheck errors (%d):\n%s" (List.length errors)
                  (String.concat "\n" errors));
           env)

let findings_of (env : Typecheck.env) : Access_check.finding list =
  Access_check.run_closure env.Typecheck.state.oracle.o_accesses

let count_kind (kind : string) (fs : Access_check.finding list) : int =
  List.length (List.filter (fun f -> f.Access_check.f_kind = kind) fs)

let contains_sub (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else begin
    let found = ref false in
    (try
       for i = 0 to hl - nl do
         if not !found && String.sub haystack i nl = needle then found := true
       done
     with Invalid_argument _ -> ());
    !found
  end

let expect_findings (name : string) (env : Typecheck.env) (min_findings : int)
    (min_kind : string) (needle : string) : Access_check.finding list =
  let fs = findings_of env in
  let n_kind = count_kind min_kind fs in
  Printf.printf "  %s: %d finding(s), %d %s\n" name (List.length fs) n_kind min_kind;
  List.iter (fun f -> Printf.printf "    %s: %s\n" f.Access_check.f_kind f.Access_check.f_message) fs;
  check (name ^ ": at least one finding") (List.length fs >= min_findings);
  check (name ^ ": >=1 " ^ min_kind ^ " finding") (n_kind >= min_findings);
  let needle_hit = List.exists (fun f -> contains_sub f.Access_check.f_message needle) fs in
  check (name ^ ": a finding mentions " ^ needle) needle_hit;
  fs

let expect_clean (name : string) (env : Typecheck.env) : unit =
  let fs = findings_of env in
  List.iter (fun f -> Printf.printf "    %s: %s\n" f.Access_check.f_kind f.Access_check.f_message) fs;
  check (name ^ ": no findings") (fs = [])

let () =
  (* ── (a) access conflict: two mutable borrows of the same local in
         one statement group (one call's argument list) ─────────── *)
  let env_a =
    typecheck_program "ar_conflict"
      {|def f(inout a: Int, inout b: Int) -> Int
  a + b
end
def main() -> Int
  var x = 1
  let r = f(&mut x, &mut x)
  r
end
|}
  in
  let fs_a = expect_findings "a: two mutable borrows of x in one call" env_a 1 "access-conflict" "conflicts with" in
  check "a: no state-conflict findings (access-only program)" (count_kind "state-conflict" fs_a = 0);

  (* ── (b) clean access: reads only, no findings ─────────────────── *)
  let env_b =
    typecheck_program "ar_clean"
      {|def g(a: Int, b: Int) -> Int
  a + b
end
def h(a: Int, b: Int) -> Int
  a + b
end
def main() -> Int
  var x = 1
  let r1 = g(x, x)
  let r2 = h(&x, &x)
  r1 + r2
end
|}
  in
  expect_clean "b: reads-only program" env_b;

  (* ── (c) state conflict: double move through sink args ─────────── *)
  let env_c =
    typecheck_program "ar_double_move"
      {|def take(sink a: Int) -> Int
  a
end
def main() -> Int
  var x = 1
  let r1 = take(x)
  let r2 = take(x)
  r1 + r2
end
|}
  in
  let fs_c = expect_findings "c: sink x twice (double move)" env_c 1 "state-conflict" "double-move" in
  check "c: no access-conflict findings (one arg per call)" (count_kind "access-conflict" fs_c = 0);

  (* ── (d) state conflict: read after consume ────────────────────── *)
  let env_d =
    typecheck_program "ar_use_after_consume"
      {|def take(sink a: Int) -> Int
  a
end
def g(a: Int, b: Int) -> Int
  a + b
end
def main() -> Int
  var x = 1
  let r1 = take(x)
  let r2 = g(x, x)
  r1 + r2
end
|}
  in
  ignore (expect_findings "d: read after sink on x" env_d 1 "state-conflict" "use-after-consume");

  (* ── (e) clean move: one sink, no later use, no findings ───────── *)
  let env_e =
    typecheck_program "ar_clean_move"
      {|def take(sink a: Int) -> Int
  a
end
def main() -> Int
  var x = 1
  let r = take(x)
  0
end
|}
  in
  expect_clean "e: single sink with no later use" env_e;

  (* ── (f) the channel accumulates ACROSS items (closure walk) ───── *)
  let env_f =
    typecheck_program "ar_accumulate"
      {|def g(a: Int, b: Int) -> Int
  a + b
end
def h(a: Int, b: Int) -> Int
  a + b
end
def f1() -> Int
  var y = 1
  g(y, y)
end
def f2() -> Int
  var z = 1
  h(z, z)
end
def main() -> Int
  f1() + f2()
end
|}
  in
  let items =
    List.sort_uniq compare
      (List.map (fun (a : Access_check.access) -> a.Access_check.a_item)
         env_f.Typecheck.state.oracle.o_accesses)
  in
  Printf.printf "  f: recorded channel covers %d item(s): %s\n" (List.length items)
    (String.concat "; " items);
  check "f: recorded channel accumulates across items (>=2 call-bearing items)"
    (List.length items >= 2);

  if !failures = 0 then begin
    Printf.printf "tg_access_resource: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_access_resource: %d FAILURE(S)\n" !failures;
    exit 1
  end
