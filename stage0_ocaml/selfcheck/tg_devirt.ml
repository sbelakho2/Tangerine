(* tg_devirt.ml — focused regression for kernel MONO devirtualization.

   The probe tg_compiler/devirtprobe.tg runs the kernel front end
   (parse -> resolve -> typecheck -> the integrated access/resource passes
   -> lower) over a SMALL self-contained program that reproduces the
   trait-bound-receiver call shape (`I: Adder` receiver, `it.bump()`),
   dumps every MirCall callee + instance payload before and after mono,
   runs verify_mir BEFORE and AFTER monomorphize_program, and writes
   build/devirt_probe.txt.

   This harness runs the REAL kernel closure through the seed pipeline on
   bootstrap/devirtprobe_mini.manifest (whose tg_compiler/devirtprobe.tg
   entry always runs the probe). The VM run must exit 0, the probe must
   report `DEV_MONO ok` (the monomorphizer specialized the call sites
   without error) and `DEV_VERIFY_POST rows=0` (the mono'd program still
   verifies); anything else fails this lane. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_devirt: FAIL: %s\n" s;
      exit 1)
    fmt

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let contains (haystack : string) (needle : string) =
  let l = String.length haystack and n = String.length needle in
  let rec go i =
    if i + n > l then false
    else if String.sub haystack i n = needle then true
    else go (i + 1)
  in
  go 0

let () =
  let repo_root =
    match Array.to_list Sys.argv with _ :: r :: _ -> r | _ -> ".."
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let kernel_args = [ "devirt"; "-o"; "devirt_probe.out" ] in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/devirtprobe_mini.manifest" ~target ~entry:None
      ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_path = Filename.concat repo_root "build/devirt_probe.txt" in
      let report =
        if Sys.file_exists report_path then read_file report_path
        else
          "(no build/devirt_probe.txt — the probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          if not (contains report "DEV_MONO ok") then
            fail
              "the probe did not report DEV_MONO ok — monomorphize_program did not complete (see the report above)"
          else if not (contains report "DEV_VERIFY_POST rows=0") then
            fail
              "the mono'd program does not verify (expected DEV_VERIFY_POST rows=0; see the report above)"
          else begin
            Printf.printf
              "tg_devirt: PASS — monomorphize_program completed and the mono'd program verifies with zero rows (VM exit 0)\n";
            exit 0
          end
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          List.iter
            (fun e -> Printf.printf "  closure typecheck error: %s\n" e)
            stages.Driver.bs_ctx.Driver.ctx_type_errors;
          fail
            "the kernel VM run did not complete — an upstream closure stage failed (e.g. a probe typecheck error) or the kernel trapped")
