(* tg_copy_authority.ml — the P0 Copy-authority gate (task: the compiler
   must respect its own Copy authority).

   The std declares its raw-element APIs ONLY under Copy-gated impls:
     * `impl[T: Copy] Array[T]`          — slice / extend
     * `impl[K: Hash + Eq + Copy, V: Copy] Map[K, V]` — entries
   A call whose receiver cannot discharge the impl's Copy bound must be
   REJECTED by the checker's method selection — never accepted because a
   builtin name matches (the parity-work kernel arms) or because the seed
   selected a method by name (the seed defect this gate pins).

   SEED lane (the REAL pipeline, check -> lower -> verify -> VM):
     * NEGATIVE: Vec[String].slice / Vec[String].extend /
       Map[String, Owning].entries() typecheck with the unsatisfied-Copy
       bound diagnostics and never reach lowering/VM.
     * POSITIVE: Vec[Int].slice / Vec[Int].extend /
       Map[Int, Int].entries() run through check -> lower -> MIR verify ->
       VM with the expected runtime value.

   KERNEL lane (the in-VM kernel checker via infer_mini's infer mode):
     * COPY_AUTHORITY_BATTERY fails=0, with all six CA rows PASS: the
       three negatives rejected on the impl bounds and the three
       positives through the FULL oracle (parse + resolve + errors=0 +
       typed-channel readiness + MIR lowering + MIR verify). *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_copy_authority: FAIL: %s\n" s;
      exit 1)
    fmt

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m = 0 || go 0

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun e -> rm_rf (Filename.concat p e)) (Sys.readdir p);
      (try Unix.rmdir p with Unix.Unix_error _ -> ())
    end
    else (try Sys.remove p with Sys_error _ -> ())

let rec ensure_dir p =
  if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
  else begin
    ensure_dir (Filename.dirname p);
    try Unix.mkdir p 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Materialize a throwaway closure root: the REAL std sources copied from
   the repository + the case file written under stage0_ocaml/selfcheck. *)
let materialize_case (repo_root : string) (label : string) (body : string) :
    string * string =
  let root = Filename.temp_file ("tg_ca_" ^ label ^ "_") "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let std_files =
    [
      "alloc.tg";
      "core.tg";
      "collections.tg";
      "taint.tg";
      "ffi.tg";
      "gfx_errors.tg";
      "fmt.tg";
      "args.tg";
      "env.tg";
      "io.tg";
      "time.tg";
      "fs.tg";
      "process.tg";
      "bench.tg";
    ]
  in
  List.iter
    (fun name ->
      let rel = "std/" ^ name in
      let dst = Filename.concat root rel in
      ensure_dir (Filename.dirname dst);
      write_file dst (read_file (Filename.concat repo_root rel)))
    std_files;
  let case_rel = "stage0_ocaml/selfcheck/copyauth_case.tg" in
  let case_dst = Filename.concat root case_rel in
  ensure_dir (Filename.dirname case_dst);
  write_file case_dst body;
  let manifest =
    "version: 1\n\
     std: alloc.tg\n\
     std: core.tg\n\
     std: collections.tg\n\
     std: taint.tg\n\
     std: ffi.tg\n\
     std: gfx_errors.tg\n\
     std: fmt.tg\n\
     std: args.tg\n\
     std: env.tg\n\
     std: io.tg\n\
     std: time.tg\n\
     std: fs.tg\n\
     std: process.tg\n\
     std: bench.tg\n\
     selfcheck: copyauth_case.tg\n"
  in
  let mp = Filename.concat root "copyauth.manifest" in
  write_file mp manifest;
  (root, mp)

let target () =
  match Target.unsupported_triple "aarch64-apple-darwin" with
  | Error m -> fail "target: %s" m
  | Ok t -> t

(* ── SEED lane ──────────────────────────────────────────────────────── *)

let seed_negative (repo_root : string) : unit =
  let body =
    "struct Owning\n  s: String\nend\n\n\
     def neg_slice(v: Vec[String]) -> Int\n  let s = v.slice(0, 1)\n  s.len()\nend\n\n\
     def neg_extend(v: Vec[String]) -> Int\n  var o: Vec[String] = Vec::new()\n  v.extend(o)\n  v.len()\nend\n\n\
     def neg_entries(m: Map[String, Owning]) -> Int\n  let es = m.entries()\n  es.len()\nend\n\n\
     def main() -> Int\n  0\nend\n"
  in
  let root, mp = materialize_case repo_root "neg" body in
  let stages =
    match
      Driver.run_bootstrap_closure ~repo_root:root ~manifest_path:mp
        ~target:(target ()) ~entry:None ~kernel_args:[]
    with
    | Error m ->
        rm_rf root;
        fail "seed negative closure pipeline errored: %s" m
    | Ok s -> s
  in
  let errs = stages.Driver.bs_ctx.Driver.ctx_type_errors in
  let want label meth =
    if
      not
        (List.exists
           (fun e ->
             contains_sub e ("`" ^ meth ^ "`") && contains_sub e "Copy")
           errs)
    then begin
      List.iter (fun e -> Printf.printf "  seed type error: %s\n" e) errs;
      rm_rf root;
      fail
        "seed negative %s: no Copy-bound diagnostic for method `%s` (%d type error(s))"
        label meth (List.length errs)
    end
  in
  want "Vec[String].slice" "slice";
  want "Vec[String].extend" "extend";
  want "Map[String, Owning].entries" "entries";
  (match stages.Driver.bs_vm_code with
  | None -> ()
  | Some code ->
      rm_rf root;
      fail
        "seed negative closure reached the VM (exit %d) — a Copy-gated call was accepted"
        code);
  Printf.printf
    "SEED NEGATIVE: Vec[String].slice / Vec[String].extend / Map[String, Owning].entries() rejected with Copy-bound diagnostics (%d checker error(s), no VM)\n"
    (List.length errs);
  rm_rf root

let seed_positive (repo_root : string) : unit =
  let body =
    "def ca_slice_int(v: Vec[Int]) -> Int\n  let s = v.slice(1, v.len())\n  s.len()\nend\n\n\
     def ca_entries_int(m: Map[Int, Int]) -> Int\n  let es = m.entries()\n  es.len()\nend\n\n\
     def ca_extend_int(v: Vec[Int]) -> Int\n  var o: Vec[Int] = Vec::new()\n  o.push(7)\n  v.extend(o)\n  v.len()\nend\n\n\
     def main() -> Int\n  var v: Vec[Int] = Vec::new()\n  v.push(10)\n  v.push(20)\n  v.push(30)\n  var m: Map[Int, Int] = Map::new()\n  let _ = m.insert(1, 7)\n  let _ = m.insert(2, 8)\n  var w: Vec[Int] = Vec::new()\n  w.push(1)\n  ca_slice_int(v) * 100 + ca_entries_int(m) * 10 + ca_extend_int(w)\nend\n"
  in
  let root, mp = materialize_case repo_root "pos" body in
  let stages =
    match
      Driver.run_bootstrap_closure ~repo_root:root ~manifest_path:mp
        ~target:(target ()) ~entry:None ~kernel_args:[]
    with
    | Error m ->
        rm_rf root;
        fail "seed positive closure pipeline errored: %s" m
    | Ok s -> s
  in
  let errs = stages.Driver.bs_ctx.Driver.ctx_type_errors in
  if errs <> [] then begin
    List.iter (fun e -> Printf.printf "  seed type error: %s\n" e) errs;
    rm_rf root;
    fail "seed positive: %d type error(s) — the Int variants must be accepted"
      (List.length errs)
  end;
  if not stages.Driver.bs_mir_verify_ok then begin
    rm_rf root;
    fail "seed positive: MIR verify rejected the closure"
  end;
  (match stages.Driver.bs_vm_code with
  | Some 222 -> ()
  | Some code ->
      rm_rf root;
      fail "seed positive: VM exit %d, expected 222 (2*100 + 2*10 + 2)" code
  | None ->
      rm_rf root;
      fail "seed positive: the closure produced no VM exit value");
  Printf.printf
    "SEED POSITIVE: Vec[Int].slice / Vec[Int].extend / Map[Int, Int].entries() accepted; check -> lower -> MIR verify -> VM exit 222\n";
  rm_rf root

(* ── KERNEL lane ───────────────────────────────────────────────────── *)

let kernel_lane (repo_root : string) : unit =
  ensure_dir (Filename.concat repo_root "build");
  let kernel_args = [ "infer"; "-o"; "infer_probe.out" ] in
  let stages =
    match
      Driver.run_bootstrap_closure ~repo_root
        ~manifest_path:"bootstrap/infer_mini.manifest" ~target:(target ())
        ~entry:None ~kernel_args
    with
    | Error m -> fail "kernel closure pipeline: %s" m
    | Ok s -> s
  in
  (match stages.Driver.bs_vm_code with
  | Some 0 -> ()
  | Some code -> fail "kernel probe VM exit %d (expected 0)" code
  | None -> fail "kernel probe produced no VM exit value");
  let report_path = Filename.concat repo_root "build/infer_probe.txt" in
  if not (Sys.file_exists report_path) then
    fail "kernel probe report %s is missing" report_path;
  let report = read_file report_path in
  if not (contains_sub report "COPY_AUTHORITY_BATTERY fails=0 cases=6") then begin
    let rows =
      String.split_on_char '\n' report
      |> List.filter (fun l -> contains_sub l "COPY_AUTHORITY_BATTERY")
    in
    List.iter (fun l -> Printf.printf "  %s\n" l) rows;
    fail
      "kernel copy-authority battery did not report fails=0 cases=6 (see %s)"
      report_path
  end;
  let rows =
    [
      "KERNEL_PARITY CA-neg-vec-string-slice: PASS";
      "KERNEL_PARITY CA-neg-vec-string-extend: PASS";
      "KERNEL_PARITY CA-neg-map-string-owning-entries: PASS";
      "KERNEL_PARITY CA-pos-vec-int-slice: PASS";
      "KERNEL_PARITY CA-pos-vec-int-extend: PASS";
      "KERNEL_PARITY CA-pos-map-int-int-entries: PASS";
    ]
  in
  List.iter
    (fun row ->
      if not (contains_sub report row) then begin
        let ca_rows =
          String.split_on_char '\n' report
          |> List.filter (fun l -> contains_sub l "KERNEL_PARITY CA-")
        in
        List.iter (fun l -> Printf.printf "  %s\n" l) ca_rows;
        fail "kernel copy-authority row missing or failing: %s" row
      end)
    rows;
  Printf.printf
    "KERNEL: COPY_AUTHORITY_BATTERY fails=0 cases=6 (3 negatives rejected on the impl bounds, 3 positives full-oracle)\n"

let () =
  let repo_root =
    if Array.length Sys.argv > 1 then Sys.argv.(1) else ".."
  in
  seed_negative repo_root;
  seed_positive repo_root;
  kernel_lane repo_root;
  Printf.printf
    "PASS: seed + kernel Copy authority (slice/extend/entries) agree on the negative and positive verdicts\n";
  Selfcheck_sentinel.emit_and_exit "tg_copy_authority"
