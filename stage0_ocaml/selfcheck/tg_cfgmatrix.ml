(* tg_cfgmatrix.ml — the @cfg cross-target matrix (audit @cfg P0).

   OCaml Stage0 mirror of tests/run_cfg_matrix_tests.sh. The @cfg
   evaluation is a compile-time pass: Target.Cfg_context.of_target selects
   the SAME TargetSpec the driver's --target flag feeds
   apply_cfg_elimination (never the host process), and the matrix drives
   Target.eliminate_program with the explicit macos/linux targets,
   asserting the front-end semantics: parse -> @cfg elimination -> the
   kept program.

   Cases (mirroring the shell matrix):
     (a+) linux-positive:  the @cfg(target_os = "linux") member SURVIVES on linux
     (a-) macos-on-linux:  the macos member is PHYSICALLY GONE on linux
     (b+) macos-positive:  the @cfg(target_os = "macos") member SURVIVES on macos
     (b-) linux-on-macos:  the linux member is PHYSICALLY GONE on macos
     (c)  windows ungated: the windows member is gone on BOTH non-windows
          targets (a kept reference to it fails the standard
          unresolved-name resolution — nothing can resurrect it)
     (host) host-agnostic family: for every target exactly one member of
          the mutually exclusive macos/linux pair survives
     (not/any groups) the group predicates per the kernel's flattened
          semantics: not(target_os = "windows") holds on macos and linux;
          any(target_arch = "aarch64", target_arch = "x86_64") holds on
          both
   Fail-closed diagnostics (a bad gate never silently stays active):
     - @cfg()             -> E108 (empty predicate)
     - @cfg(target_os)    -> malformed (bare key, no value)
     - @cfg(debug = true) -> unknown target key
     - @cfg(a = "x", b = "y") -> malformed (multiple top-level conditions)

   Prints PASS per case and a final ALL CFG MATRIX PASS line. *)

let macos = Target.Cfg_context.of_target (Target.of_string "aarch64-apple-darwin")

let linux = Target.Cfg_context.of_target (Target.of_string "x86_64-unknown-linux-gnu")

let failures = ref 0

let total = ref 0

(* One PASS case; the case counter advances once per case. *)
let pass (name : string) =
  incr total;
  Printf.printf "PASS %s\n" name

let fail fmt = Printf.ksprintf (fun s -> incr failures; Printf.printf "FAIL %s\n" s) fmt

(* Parse a program text through the seed front end (lex -> parse ->
   structural verify). *)
let parse_text (name : string) (text : string) : Ast.program =
  let sm = Span.create () in
  let src = Source.of_bytes ~name ~bytes:text in
  let file_id = Span.add_file sm name src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src.Source.bytes file_id diags [] in
  if not (Diagnostic.has_errors diags) then Verify.verify diags program;
  if Diagnostic.has_errors diags then begin
    prerr_string (Diagnostic.render sm diags);
    prerr_newline ();
    failwith ("cfg matrix: parse failed for " ^ name)
  end;
  program

let names_of (p : Ast.program) : string list =
  List.filter_map
    (fun i ->
      match i.Ast.kind with
      | Ast.Function d -> Some d.Ast.fn_sig.Ast.sig_name
      | Ast.StructDef d -> Some d.Ast.s_name
      | _ -> None)
    p.Ast.items

(* The matrix sample: the positive symbol, the opposite-platform symbol,
   a windows symbol, and a cfg'd struct per platform — the canary shape
   from tests/cfg_matrix/. *)
let sample_program =
  "use std::core\n\
   \n\
   @cfg(target_os = \"macos\")\n\
   def cfg_macos_marker() -> Int = 0\n\
   \n\
   @cfg(target_os = \"linux\")\n\
   def cfg_linux_marker() -> Int = 0\n\
   \n\
   @cfg(target_os = \"windows\")\n\
   def cfg_windows_marker() -> Int = 0\n\
   \n\
   @cfg(target_os = \"macos\")\n\
   struct CfgMacosStruct\n\
     x: Int\n\
   end\n\
   \n\
   @cfg(target_os = \"linux\")\n\
   struct CfgLinuxStruct\n\
     x: Int\n\
   end\n\
   \n\
   def main() -> Int\n\
     cfg_macos_marker()\n\
   end\n"

(* The core matrix case: the target's members survive, the
   opposite-platform members are physically gone (name absence AND item
   count), and the removed count matches the span cut. *)
let check_sample (ctx : Target.Cfg_context.t) (ctx_name : string) (kept : string list)
    (gone : string list) : unit =
  let prog = parse_text "sample.tg" sample_program in
  let orig_count = List.length prog.Ast.items in
  let failures_before = !failures in
  match Target.eliminate_program ctx prog with
  | Error ds ->
      fail "eliminate_cfg unexpectedly failed (%s): %s" ctx_name
        (String.concat " | " (List.map (fun d -> d.Diagnostic.message) ds))
  | Ok r ->
      let n = names_of r.Target.elim_program in
      List.iter
        (fun k ->
          if not (List.mem k n) then fail "missing kept symbol '%s' (%s)" k ctx_name)
        kept;
      List.iter
        (fun k ->
          if List.mem k n then fail "eliminated symbol '%s' still present (%s)" k ctx_name)
        gone;
      (* The sample has 7 top-level items: use, macos fn, linux fn,
         windows fn, macos struct, linux struct, main. *)
      let expected_kept = 2 + List.length kept in
      if List.length r.Target.elim_program.Ast.items <> expected_kept then
        fail "item count %d, expected %d (%s)" (List.length r.Target.elim_program.Ast.items)
          expected_kept ctx_name;
      if r.Target.elim_removed <> orig_count - expected_kept then
        fail "eliminated count %d, expected %d (%s)" r.Target.elim_removed
          (orig_count - expected_kept) ctx_name;
      if !failures = failures_before then pass ("sample " ^ ctx_name ^ " positive/negative")

(* (a+) / (b+): the target keeps exactly its own member (symbol AND
   struct). (a-) / (b-): the opposite-platform members are gone. (c):
   the windows member is gone on both non-windows targets. *)
let () =
  check_sample macos "macos" [ "cfg_macos_marker"; "CfgMacosStruct" ]
    [ "cfg_linux_marker"; "CfgLinuxStruct"; "cfg_windows_marker" ];
  check_sample linux "linux" [ "cfg_linux_marker"; "CfgLinuxStruct" ]
    [ "cfg_macos_marker"; "CfgMacosStruct"; "cfg_windows_marker" ]

(* (host): the mutually exclusive family — for EVERY target exactly one
   member of the pair survives and an un-gated reference can only ever
   see the target's kept member (tests/cfg_matrix/
   canary_pos_cfg_host_family.tg). *)
let host_family =
  "use std::core\n\
   \n\
   @cfg(target_os = \"macos\")\n\
   def cfg_platform_marker() -> Int = 0\n\
   \n\
   @cfg(target_os = \"linux\")\n\
   def cfg_platform_marker() -> Int = 0\n\
   \n\
   def main() -> Int\n\
     cfg_platform_marker()\n\
   end\n"

let check_host_family (ctx : Target.Cfg_context.t) (ctx_name : string) : unit =
  let failures_before = !failures in
  let prog = parse_text "host_family.tg" host_family in
  match Target.eliminate_program ctx prog with
  | Error ds ->
      fail "host family elimination failed (%s): %s" ctx_name
        (String.concat " | " (List.map (fun d -> d.Diagnostic.message) ds))
  | Ok r ->
      let members =
        List.filter
          (fun i ->
            match i.Ast.kind with
            | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "cfg_platform_marker"
            | _ -> false)
          r.Target.elim_program.Ast.items
      in
      if List.length members <> 1 then
        fail "host family: expected exactly one cfg_platform_marker member on %s, found %d"
          ctx_name (List.length members)
      else if !failures = failures_before then pass ("host family " ^ ctx_name)

(* (not/any/all groups): the kernel's flattened group predicates.
   NOTE: @cfg(not(any(...))) cannot round-trip through this seed's
   parser (the nested 'any(' paren is consumed by the attribute
   collector and the closing ')' dangles, detaching the attribute from
   its item) — the kernel's flattened "not"+"any" list is only reachable
   as not(<pair>); the matrix covers the representable forms. *)
let group_program =
  "use std::core\n\
   \n\
   @cfg(not(target_os = \"windows\"))\n\
   def cfg_not_windows() -> Int = 0\n\
   \n\
   @cfg(any(target_arch = \"aarch64\", target_arch = \"x86_64\"))\n\
   def cfg_any_supported_arch() -> Int = 0\n\
   \n\
   @cfg(all(target_os = \"macos\", target_arch = \"aarch64\"))\n\
   def cfg_all_macos_aarch64() -> Int = 0\n\
   \n\
   @cfg(not(target_os = \"linux\"))\n\
   def cfg_not_linux() -> Int = 0\n\
   \n\
   def main() -> Int\n\
     cfg_not_windows()\n\
   end\n"

let check_groups (ctx : Target.Cfg_context.t) (ctx_name : string) (is_macos : bool) : unit =
  let failures_before = !failures in
  let prog = parse_text "groups.tg" group_program in
  match Target.eliminate_program ctx prog with
  | Error ds ->
      fail "group predicates failed (%s): %s" ctx_name
        (String.concat " | " (List.map (fun d -> d.Diagnostic.message) ds))
  | Ok r ->
      let n = names_of r.Target.elim_program in
      if not (List.mem "cfg_not_windows" n) then
        fail "not(target_os = \"windows\") did not hold on %s" ctx_name;
      if not (List.mem "cfg_any_supported_arch" n) then
        fail "any(target_arch = ...) did not hold on %s" ctx_name;
      let has_all_macos = List.mem "cfg_all_macos_aarch64" n in
      if has_all_macos <> is_macos then
        fail "all(target_os = \"macos\", target_arch = \"aarch64\") mismatch on %s (kept=%b)"
          ctx_name has_all_macos;
      let has_not_linux = List.mem "cfg_not_linux" n in
      if has_not_linux <> is_macos then
        fail "not(target_os = \"linux\") mismatch on %s (kept=%b)" ctx_name has_not_linux;
      if !failures = failures_before then pass ("groups " ^ ctx_name)

(* Fail-closed diagnostics: empty @cfg(), bare keys, unknown target keys,
   multiple top-level conditions, malformed groups. *)
let contains_substring (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  let rec go i = if i + nl > hl then false else if String.sub haystack i nl = needle then true else go (i + 1) in
  go 0

let expect_fail (name : string) (text : string) (markers : string list) : unit =
  let failures_before = !failures in
  let prog = parse_text (name ^ ".tg") text in
  match Target.eliminate_cfg macos prog with
  | Ok _ -> fail "expected fail-closed rejection for %s, got a filtered program" name
  | Error ds ->
      let all = String.concat " " (List.map (fun d -> d.Diagnostic.message) ds) in
      List.iter
        (fun m ->
          if not (contains_substring all m) then
            fail "diagnostic for %s lacks '%s': %s" name m all)
        markers;
      if !failures = failures_before then pass ("fail-closed " ^ name)

let () =
  check_host_family macos "macos";
  check_host_family linux "linux";
  check_groups macos "macos" true;
  check_groups linux "linux" false;
  expect_fail "empty" "@cfg()\ndef x() -> Int = 0\n" [ "E108" ];
  expect_fail "bare-key" "@cfg(target_os)\ndef x() -> Int = 0\n" [ "malformed" ];
  expect_fail "unknown-key" "@cfg(debug = true)\ndef x() -> Int = 0\n" [ "unknown target key" ];
  expect_fail "multi-condition"
    "@cfg(target_os = \"macos\", target_arch = \"aarch64\")\ndef x() -> Int = 0\n"
    [ "malformed" ];
  expect_fail "bad-group" "@cfg(any(target_os))\ndef x() -> Int = 0\n" [ "malformed" ];
  if !failures = 0 then begin
    Printf.printf "ALL CFG MATRIX PASS (%d cases)\n" !total;
    exit 0
  end
  else begin
    Printf.printf "CFG MATRIX FAILED: %d of %d cases failed\n" !failures !total;
    exit 1
  end
