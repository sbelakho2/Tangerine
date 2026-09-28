(* tg_parse_parity.ml — kernel-grammar parse-parity gate.

   The bootstrap authority is the KERNEL parser (tg_compiler/parser.tg) as
   produced by the OCaml seed; the closure it must parse is
   bootstrap/compiler_kernel.manifest. A seed/kernel grammar divergence (the
   std/bench.tg match-tail `end  end  end` class) surfaces today only after
   the full stage1 build — tens of minutes into the ladder.

   This harness runs the REAL kernel lexer + parser over every closure source
   inside the seed VM (bootstrap/parse_parity_mini.manifest, whose
   tg_compiler/parse_parity_probe.tg entry parses the manifest's std:/compiler:
   entries and then enforces the grammar-conformance corpus). The manifest
   paths are resolved from the same single-source manifest the bootstrap
   resolves, so the gate cannot drift from the closure.

   The DELIBERATE corpus (tests/grammar_conformance/manifest.txt) is enforced
   on BOTH parsers: this harness checks it with the OCaml seed parser in
   process (fast) and the probe checks the same registry with the kernel
   parser in the seed VM. Seed<->kernel parity alone cannot decide whether a
   lenient form is intended language, so the corpus encodes the decisions
   (anchors in each specimen and in tests/grammar_conformance/README.md) and
   fails when either parser accepts what must be rejected or rejects what
   must be accepted.

   The VM run must exit 0 with a report that records every file parsed clean
   and the corpus agreed; any grammar diagnostic (e.g. "expected item")
   fails the lane. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_parse_parity: FAIL: %s\n" s;
      exit 1)
    fmt

let ensure_dir path =
  let rec go p =
    if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      | Unix.Unix_error (e, _, _) ->
          fail "cannot create the output directory %s: %s" p
            (Unix.error_message e)
    end
  in
  go path

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* The closure authority: the same std:/compiler: entries the bootstrap
   resolves from bootstrap/compiler_kernel.manifest, in manifest order. *)
let manifest_closure repo_root =
  let path = Filename.concat repo_root "bootstrap/compiler_kernel.manifest" in
  if not (Sys.file_exists path) then
    fail "missing kernel manifest: %s" path;
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let acc = ref [] in
      (try
         while true do
           let line = String.trim (input_line ic) in
           if line <> "" && line.[0] <> '#' then begin
             let words =
               List.filter (fun s -> s <> "") (String.split_on_char ' ' line)
             in
             match words with
             | "std:" :: rel :: _ -> acc := ("std/" ^ rel) :: !acc
             | "compiler:" :: rel :: _ -> acc := ("tg_compiler/" ^ rel) :: !acc
             | _ -> ()
           end
         done
       with End_of_file -> ());
      List.rev !acc)

(* The grammar-conformance corpus registry: tests/grammar_conformance/
   manifest.txt, one `accept <rel>` / `reject <rel>` directive per specimen.
   The corpus is deliberate (see tests/grammar_conformance/README.md); this
   seed-side check enforces it with the OCaml parser while the kernel probe
   enforces the SAME registry with the kernel parser in the seed VM. *)
let corpus_cases repo_root =
  let path =
    Filename.concat repo_root "tests/grammar_conformance/manifest.txt"
  in
  if not (Sys.file_exists path) then
    fail "missing grammar-conformance manifest: %s" path;
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let acc = ref [] in
      (try
         while true do
           let line = String.trim (input_line ic) in
           if line <> "" && line.[0] <> '#' then begin
             let words =
               List.filter (fun s -> s <> "") (String.split_on_char ' ' line)
             in
             match words with
             | ("accept" | "reject") as verb :: rel :: _ ->
                 acc := (verb, rel) :: !acc
             | _ -> fail "malformed corpus directive: %S" line
           end
         done
       with End_of_file -> ());
      List.rev !acc)

(* Seed parse of one corpus specimen; true when it records an error. *)
let seed_parse_has_errors label src =
  let diags = Diagnostic.create_bag () in
  let file_id = 0 in
  let lx = Lexer.create src file_id diags in
  let tokens = Lexer.lex lx in
  let module_path = Parser.module_path_of_file label in
  let _program = Parser.parse tokens src file_id diags module_path in
  Diagnostic.has_errors diags

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m = 0 || go 0

let seed_corpus_check repo_root =
  let cases = corpus_cases repo_root in
  if cases = [] then
    fail "tests/grammar_conformance/manifest.txt lists no cases";
  let accepts = ref 0 and rejects = ref 0 and failures = ref 0 in
  List.iter
    (fun (verb, rel) ->
      let path =
        Filename.concat repo_root ("tests/grammar_conformance/" ^ rel)
      in
      if not (Sys.file_exists path) then begin
        incr failures;
        Printf.printf
          "tg_parse_parity: seed corpus FAIL %s %s (file missing)\n%!" verb rel
      end
      else begin
        let has_errors = seed_parse_has_errors path (read_file path) in
        match verb with
        | "accept" ->
            incr accepts;
            if has_errors then begin
              incr failures;
              Printf.printf
                "tg_parse_parity: seed corpus FAIL accept %s (error diagnostics)\n%!"
                rel
            end
        | "reject" ->
            incr rejects;
            if not has_errors then begin
              incr failures;
              Printf.printf
                "tg_parse_parity: seed corpus FAIL reject %s (parsed with zero diagnostics)\n%!"
                rel
            end
        | _ -> assert false
      end)
    cases;
  Printf.printf
    "tg_parse_parity: seed parser corpus: %d accept / %d reject case(s), %d failure(s)\n%!"
    !accepts !rejects !failures;
  if !failures > 0 then
    fail "seed parser disagrees with the grammar-conformance corpus (%d failure(s))"
      !failures

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  ensure_dir (Filename.concat repo_root "build");
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let closure = manifest_closure repo_root in
  if closure = [] then
    fail "bootstrap/compiler_kernel.manifest lists no std:/compiler: closure files";
  Printf.printf
    "tg_parse_parity: %d closure file(s) from bootstrap/compiler_kernel.manifest\n%!"
    (List.length closure);
  (* Seed side of the grammar-conformance corpus — fast, in process, and it
     fails before the VM build when a specimen's decision is violated. *)
  seed_corpus_check repo_root;
  let report_path = Filename.concat repo_root "build/parse_parity_report.txt" in
  (try Sys.remove report_path with Sys_error _ -> ());
  let kernel_args = "parse-parity" :: closure in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/parse_parity_mini.manifest" ~target
      ~entry:(Some "main") ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_exists = Sys.file_exists report_path in
      let report =
        if report_exists then read_file report_path
        else
          "(no build/parse_parity_report.txt — the kernel probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          if not report_exists then
            fail
              "VM exit 0 but the expected probe report %s is missing — the probe did not reach the write"
              report_path;
          (* A stale pre-corpus probe binary would also exit 0; require the
             report to prove the corpus check ran. *)
          if not (contains_sub report "corpus") then
            fail
              "VM exit 0 but the probe report %s does not record the grammar-conformance corpus — stale probe binary? rebuild the lane"
              report_path;
          Printf.printf
            "tg_parse_parity: PASS — every bootstrap/compiler_kernel.manifest source parsed clean by the kernel parser and the kernel parser agreed with the grammar-conformance corpus (VM exit 0)\n";
          exit 0
      | Some code ->
          fail
            "kernel grammar parse-parity FAILED: %d closure file(s) produced error diagnostics or a corpus specimen disagreed under the kernel parser (VM exit %d)"
            (List.length closure) code
      | None -> fail "the kernel VM run did not complete — an upstream closure stage failed")
