(* tg_infer.ml — focused regression for the kernel checker's inference /
   expected-type propagation families.

   The kernel front end must solve call results from the use-site's
   declared type (the seed's expected-threading rule): a call whose
   generic parameter appears only in the return type is solved by the
   enclosing annotation/return slot, enum-path values adopt the expected
   type, and a generic call's instantiation binds parameters from the
   expected type before parking. The pre-fix kernel reported these as
   residual Type::Var gate rows and "cannot infer type parameter" rows.

   This harness runs the REAL kernel closure through the seed pipeline on
   bootstrap/infer_mini.manifest (whose tg_compiler/infer_probe.tg entry
   checks a battery of expected-type shapes with the kernel front end and
   writes build/infer_probe.txt). The standalone battery cases must all
   report zero diagnostics of the four interference families; the VM run
   must exit 0. The merged-corpus family counts are measured separately
   (the probe's merged mode, flag build/infer_merged.flag) so the
   component selfcheck stays inside the generic selfcheck time bound. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_infer: FAIL: %s\n" s;
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
  let repo_root, merged =
    match Array.to_list Sys.argv with
    | _ :: r :: "--merged" :: _ -> (r, true)
    | _ :: r :: _ -> (r, false)
    | _ -> ("..", false)
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let kernel_args = [ "infer"; "-o"; "infer_probe.out" ] in
  let merged_flag = Filename.concat repo_root "build/infer_merged.flag" in
  if merged then begin
    let oc = open_out merged_flag in
    output_string oc "1\n";
    close_out oc
  end;
  let restore () =
    if merged then (try Sys.remove merged_flag with Sys_error _ -> ())
  in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/infer_mini.manifest" ~target ~entry:None
      ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_path = Filename.concat repo_root "build/infer_probe.txt" in
      let report =
        if Sys.file_exists report_path then read_file report_path
        else "(no build/infer_probe.txt — the probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          let clean_case name =
            contains report ("CASE " ^ name ^ ": errors=0 VAR=0 PARAM=0 INFER=0 UNIFY=0")
          in
          let required =
            [
              "result_ok_call_expected";
              "call_expected_annotation";
              "enum_none_expected";
              "size_of_cast";
              "vec_new_annotation";
              "arg_expected_tuple";
            ]
          in
          let missing = List.filter (fun n -> not (clean_case n)) required in
          if missing <> [] then
            fail
              "the expected-type shapes are not clean: %s (see the report above)"
              (String.concat ", " missing)
          else if not (contains report "TOTALS errors=") then
            fail "the probe produced no TOTALS row"
          else begin
            restore ();
            Printf.printf
              "tg_infer: PASS — the kernel checker solved the expected-type shape battery with zero inference-family diagnostics (VM exit 0)\n";
            exit 0
          end
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          fail
            "the kernel VM run did not complete — an upstream closure stage failed")
