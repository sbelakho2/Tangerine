(* tg_oracle_deinit.ml — focused regression for the semantic completeness
   oracle's deinit-plan walk.

   oracle_scan_deinit_plan (tg_compiler/types.tg) must handle EVERY
   DeinitPlan shape the semantic plan builder produces: the structural
   containers (Aggregate/Enum/Array/Set/Box/Map/Tuple/Option/Result),
   the String leaf, and the PlanLimit/SelfRecursive/Deferred markers. A
   non-exhaustive match lowers to a silent abort block in the Seed MIR;
   the pre-fix bootstrap VM run trapped there (vm: abort at the
   deinit-plan walk).

   This harness runs the REAL kernel closure through the seed pipeline on
   bootstrap/oracle_mini.manifest (whose tg_compiler/oracle_deinit_probe.tg
   entry typechecks an embedded program carrying exactly those plan
   shapes). The VM run must exit 0; a non-exhaustive arm still traps and
   leaves bs_vm_code = None. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_oracle_deinit: FAIL: %s\n" s;
      exit 1)
    fmt

let () =
  let repo_root =
    match Array.to_list Sys.argv with _ :: r :: _ -> r | _ -> ".."
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let kernel_args = [ "compile"; "-o"; "oracle_deinit_probe.out" ] in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/oracle_mini.manifest" ~target ~entry:None
      ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          Printf.printf
            "tg_oracle_deinit: PASS — the kernel oracle deinit-plan walk completed (VM exit 0)\n";
          exit 0
      | Some code -> fail "kernel VM exit %d (expected 0)" code
      | None ->
          fail
            "the kernel VM run did not complete — oracle_scan_deinit_plan aborted on a DeinitPlan shape (non-exhaustive match) or an upstream closure stage failed")
