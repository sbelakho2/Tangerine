(* tg_a4.ml — focused regression for the kernel checker's typed-channel
   internal errors (the A4 class).

   The kernel front end (tg_compiler/types.tg record_typed_hir and its
   call-node assembly) must record the same typed shapes the seed records:
   a missing typed call target / argument access effect, a missing typed
   HIR child and a finalizer without a resolver DefId are internal errors,
   not user diagnostics. The pre-fix kernel run over the differential
   corpus recorded these by the dozen and produced no artifact.

   This harness runs the REAL kernel closure through the seed pipeline on
   bootstrap/a4_mini.manifest (whose tg_compiler/a4_probe.tg entry runs the
   kernel lexer/parser/resolver/type_check_typed over the corpus entry and
   writes the ICE-class rows to build/a4_probe.txt). The VM run must exit
   0 with every A4 counter at zero. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      (try Sys.remove (Filename.concat (if Array.length Sys.argv > 1 then Sys.argv.(1) else "..") "build/a4_merged.flag") with Sys_error _ -> ());
      Printf.printf "tg_a4: FAIL: %s\n" s;
      exit 1)
    fmt

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

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
  let kernel_args = [ "a4-merged"; "-o"; "a4_probe.out" ] in
  let merged_flag = Filename.concat repo_root "build/a4_merged.flag" in
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
      ~manifest_path:"bootstrap/a4_mini.manifest" ~target ~entry:None
      ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_path = Filename.concat repo_root "build/a4_probe.txt" in
      let report =
        if Sys.file_exists report_path then read_file report_path
        else "(no build/a4_probe.txt — the probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          let rec contains_totals_zero_lines acc = function
            | [] -> acc
            | line :: rest ->
                let has_zero needle =
                  let l = String.length line and n = String.length needle in
                  let rec go i =
                    if i + n > l then false
                    else if String.sub line i n = needle then true
                    else go (i + 1)
                  in
                  go 0
                in
                contains_totals_zero_lines
                  (acc
                  && has_zero "call_target=0" && has_zero "effect_perform=0"
                  && has_zero "missing_child=0" && has_zero "finalizer=0")
                  rest
          in
          let totals_lines =
            List.filter
              (fun line ->
                let needle = "TOTALS " in
                let l = String.length line and n = String.length needle in
                let rec go i =
                  if i + n > l then false
                  else if String.sub line i n = needle then true
                  else go (i + 1)
                in
                go 0)
              (String.split_on_char '\n' report)
          in
          if totals_lines = [] then
            fail "the A4 probe produced no TOTALS row"
          else if contains_totals_zero_lines true totals_lines then begin
            restore ();
            Printf.printf
              "tg_a4: PASS — the kernel typed channels recorded the corpus with zero internal errors (VM exit 0)\n";
            exit 0
          end
          else
            fail
              "the kernel typed channels recorded A4-class internal errors over the corpus (see the report above)"
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          fail
            "the kernel VM run did not complete — an upstream closure stage failed")
