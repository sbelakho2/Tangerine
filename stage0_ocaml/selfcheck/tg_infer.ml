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
   component selfcheck stays inside the generic selfcheck time bound.

   The merged mode runs the corpus+std closure through the REAL compile
   path's canonical preparation (apply_cfg_elimination + prepare_parsed:
   macro expansion + node-id assignment) before the kernel checker — the
   impl-conformance rows (E0229/E0226/E0224/E0225) only reproduce after
   that preparation has rewritten the impl items, and the expectation is
   zero (the host typechecker reports 0 errors on the same closure; the
   pre-fix VM kernel reported 26 impl-conformance false positives).
   `--merged` therefore asserts IMPLCONF=0 in the probe's TOTALS row.

   Merged-probe calibration (2026-09-16, measured on the development
   host under concurrent-workstream load averages 8-17): `--merged`
   builds the same closure, then the Seed VM typechecks the merged
   corpus+std program (805 items) and the probe reports its family
   rows.  After the Seed VM Map/Set hash-index fix the whole invocation
   measured 256-466 s wall (VM merged phase 157-197 s of it) at
   errors=0; before the fix it measured 388-642 s (VM merged phase
   217-358 s).  The closure build is the rest and is shared with the
   standalone run.  check_ocaml_seed_health.sh owns the calibrated
   caps: TG_INFER_TIMEOUT_S=900 for the default component-lane
   standalone battery (the generic 420 s bound no longer covers the
   closure) and TG_INFER_MERGED_TIMEOUT_S=1200 for this opt-in mode
   (TG_INFER_MERGED=1) — re-measure when the closure or the probe grows
   materially.

   `--lower` (the MIR lowering freed-region regression) runs the REAL
   compile path — analyze_parsed then lower_to_mir TWICE over the same
   borrowed tree — over the lowering shape battery AND the merged
   corpus+std closure.  The kernel's lowering owns nothing it reads
   (mir.tg's lower_program contract); the pre-fix `into_inner()`
   extractions freed the borrowed tree's boxes and the second pass (or
   a re-read within the first, qualify_field_callee_name) trapped the
   VM with `host call __intrinsic_ptr_read: access to freed region`.
   The assertions: every shape row AND the merged rows report
   `functions=N errors=0` on BOTH passes.  Opt-in via TG_INFER_LOWER=1
   (it adds the second analysis+lowering of the merged closure to the
   --merged workload); check_ocaml_seed_health.sh caps it separately. *)

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
  let repo_root, merged, lower, lower_merged =
    match Array.to_list Sys.argv with
    | _ :: r :: "--lower" :: _ -> (r, true, true, true)
    | _ :: r :: "--lower-shapes" :: _ -> (r, false, true, false)
    | _ :: r :: "--merged" :: _ -> (r, true, false, false)
    | _ :: r :: _ -> (r, false, false, false)
    | _ -> ("..", false, false, false)
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let kernel_args = [ "infer"; "-o"; "infer_probe.out" ] in
  let merged_flag = Filename.concat repo_root "build/infer_merged.flag" in
  let lower_flag = Filename.concat repo_root "build/infer_lower.flag" in
  let lower_merged_flag =
    Filename.concat repo_root "build/infer_lower_merged.flag"
  in
  if merged then begin
    let oc = open_out merged_flag in
    output_string oc "1\n";
    close_out oc
  end;
  if lower then begin
    let oc = open_out lower_flag in
    output_string oc "1\n";
    close_out oc
  end;
  if lower_merged then begin
    let oc = open_out lower_merged_flag in
    output_string oc "1\n";
    close_out oc
  end;
  let restore () =
    if merged then (try Sys.remove merged_flag with Sys_error _ -> ());
    if lower then (try Sys.remove lower_flag with Sys_error _ -> ());
    if lower_merged then (try Sys.remove lower_merged_flag with Sys_error _ -> ())
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
          else if merged && not (contains report "IMPLCONF=0") then
            (* the merged mode runs the canonical preparation (macro
               expansion + node-id assignment) over the corpus+std
               closure: the in-VM kernel's impl-conformance verdicts
               (E0229/E0226/E0224/E0225) on that closure must agree with
               the host typechecker's 0 errors — the pre-fix kernel
               reported 26 false positives here. *)
            fail
              "the merged impl-conformance rows are nonzero (expected IMPLCONF=0)"
          else if merged && not (contains report "MERGED_RESOURCE errors=0") then
            (* the integrated resource/access pass (access_check +
               resource_check over the prepared merged closure — the
               in-VM mirror of the gate's [6/10] lane) must agree with the
               host lane's 0 findings: every resource class the kernel
               reported here (let-param read-only, the branch-join
               Maybe_live rows, discarded owned results, the loop-carried
               classes) is a kernel-vs-seed parity bug. *)
            fail
              "the kernel resource pass reports findings on the merged closure (expected MERGED_RESOURCE errors=0)"
          else if lower_merged && not (contains report "MIR_LOWER_BEGIN merged") then
            (* --lower: the MIR lowering stage must have run (flag read by
               the in-VM probe) and completed BOTH passes over the merged
               corpus+std closure. The pre-fix into_inner() extractions
               freed the borrowed tree's boxes; the second lowering pass
               (or a re-read inside the first) trapped the VM on the freed
               region — the exact bootstrap failure. A missing row means
               the VM trapped before the report write. *)
            fail
              "the MIR lowering stage did not complete over the merged closure (freed-region trap or missing build/infer_lower_merged.flag)"
          else if lower_merged && not (contains report "MIR_LOWER merged functions=") then
            fail
              "the merged lowering stage produced no MIR_LOWER row (see the report above)"
          else if lower_merged && not (contains report "MIR_RELOWER merged functions=") then
            fail
              "the second lowering pass over the same borrowed tree did not complete (the read-only AST contract is broken)"
          else if lower_merged && not (contains report "MIR_LOWER_END merged") then
            fail
              "the merged lowering stage did not finish (expected MIR_LOWER_END merged)"
          else if lower_merged && not (contains report "MIR_LOCALCHECK merged pass") then
            (* (table-persistence regression): every lowered MirFunction
               must carry its return-place local and its declaration's
               parameter table. The builder mutates match-bound COPIES of
               b.current_fn (`match b.current_fn when Option::Some(f) then
               f.locals.push(...)`) — a missing write-back leaves
               locals=0/params=0 and lookup_local_type answers Unit for
               every id (the missing-scrutinee-identity ICE). The MIR_LOCALS
               row above carries the counts. *)
            fail
              "the merged lowering left an empty function local/param table (expected MIR_LOCALCHECK merged pass; see the MIR_LOCALS row above)"
          else if
            (lower || lower_merged)
            && not
                 (List.for_all
                    (fun n ->
                      contains report ("MIR_LOWER " ^ n ^ " functions=")
                      && contains report ("MIR_RELOWER " ^ n ^ " functions=")
                      && contains report ("MIR_LOCALCHECK " ^ n ^ " pass"))
                    [
                      "lower_arith";
                      "lower_field_chain";
                      "lower_enum_payload";
                      "lower_enum_assoc_fn";
                      "lower_enum_assign";
                      "lower_match_field";
                      "lower_closure_capture";
                      "lower_for_range";
                      "lower_const_call_pattern";
                      "lower_array_index";
                      "lower_field_call_recv";
                      "lower_field_bitand";
                      "lower_field_shr_cast";
                      "lower_expr_body_field";
                    ])
          then
            fail
              "the lowering shape battery did not complete clean on BOTH passes with non-empty local/param tables (expected MIR_LOCALCHECK <shape> pass; see the report above)"
          else begin
            restore ();
            Printf.printf
              "tg_infer: PASS — the kernel checker solved the expected-type shape battery with zero inference-family diagnostics%s (VM exit 0)\n"
              (if lower_merged then
                 " and the kernel MIR lowering read the borrowed corpus+std tree twice with zero traps"
               else if merged then
                 " and zero impl-conformance/resource rows on the merged closure"
               else "")
            ;
            exit 0
          end
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          fail
            "the kernel VM run did not complete — an upstream closure stage failed")
