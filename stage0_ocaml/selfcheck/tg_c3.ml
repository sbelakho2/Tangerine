(* tg_c3.ml — focused regression for the kernel checker's method-resolution
   (C3 class) and the obligation-solver loop.

   Two properties are asserted by running the REAL kernel closure through
   the seed pipeline on bootstrap/c3_mini.manifest (whose
   tg_compiler/c3_probe.tg entry checks a battery of trivial sources with
   the kernel front end and writes build/c3_probe.txt):

   1. THE LOOP REGRESSION: a trivial struct + method source (and the
      struct/enum clone shapes) must type-check to completion — before the
      fix, type_properties_of -> is_send -> derive_transferable(Adt) ->
      pointer_gate_holds -> solve_obligation re-entered
      derive_transferable for the SAME type forever (the VM call-depth
      trap). The VM run must exit 0 and every loop-regression case must
      report 0 diagnostics.

   2. THE C3 VERDICT: the standalone battery's clean cases (struct_clone,
      struct_clone_impl_later, int_clone, string_clone, option_clone,
      enum_clone, nested_struct, vec_resize, string_index_upper,
      ptr_cast_write) must stay clean — the method-resolution fixes
      (primitive/builtin for-type indexing, the Vec/Array alias fold, the
      Param bound contract, the pointer Adt/primitives surface, the
      String::char_at/ptr + Char::to_uppercase surfaces, the derived-mint
      fallback) are what makes them resolve.

   The merged-corpus C3 count is measured separately (the probe's merged
   mode, flag build/c3_merged.flag) so the component selfcheck stays
   inside the generic selfcheck time bound. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_c3: FAIL: %s\n" s;
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
  let kernel_args = [ "c3"; "-o"; "c3_probe.out" ] in
  let merged_flag = Filename.concat repo_root "build/c3_merged.flag" in
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
      ~manifest_path:"bootstrap/c3_mini.manifest" ~target ~entry:None
      ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_path = Filename.concat repo_root "build/c3_probe.txt" in
      let report =
        if Sys.file_exists report_path then read_file report_path
        else "(no build/c3_probe.txt — the probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          let clean_case name =
            contains report ("CASE " ^ name ^ ": errors=0 no_method=0")
          in
          let required =
            [
              "struct_method";
              "struct_clone";
              "struct_clone_impl_later";
              "int_clone";
              "string_clone";
              "option_clone";
              "enum_clone";
              "nested_struct";
              "generic_impl_method";
              "vec_resize";
              "string_index_upper";
              "ptr_cast_write";
            ]
          in
          let missing = List.filter (fun n -> not (clean_case n)) required in
          if missing <> [] then
            fail
              "the loop/method regression cases are not clean: %s (see the report above)"
              (String.concat ", " missing)
          else if not (contains report "TOTALS cases=") then
            fail "the probe produced no TOTALS row"
          else begin
            restore ();
            Printf.printf
              "tg_c3: PASS — the kernel checker completed the trivial struct/method battery with the loop regression and the C3 method-resolution cases clean (VM exit 0)\n";
            exit 0
          end
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          fail
            "the kernel VM run did not complete — an upstream closure stage failed (a hang here is the obligation-solver loop)")
