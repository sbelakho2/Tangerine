(* tg_identity.ml — focused regression for the persistent identity
   integration (mono declaration identity + P0-4 member lineage).

   The probe tg_compiler/identity_probe.tg runs the store-backed identity
   lane the mono cache binds from: a rename/move with an explicit
   DeclContinuation keeps the StructuralInstanceId byte-identical, the
   index-free registration-scope structural records of the old/new
   spelling re-key (the ephemeral behavior), an unchanged member keeps its
   persistent lineage, an explicit member-rename continuation keeps it,
   and an unrelated new member is fresh.

   This harness runs the probe closure through the seed pipeline on
   bootstrap/identity_probe_mini.manifest with entry `main`; the VM run
   must exit 0 (identity_probe.tg's main returns the first failing check
   number, 0 on success). *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_identity: FAIL: %s\n" s;
      exit 1)
    fmt

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/identity_probe_mini.manifest" ~target
      ~entry:(Some "main") ~kernel_args:[ "identity-probe" ]
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          Printf.printf
            "tg_identity: PASS — persistent rename keeps the StructuralInstanceId, ephemeral re-keys, member lineage survives insertion + continuation, persistent HIR lineage keeps StableSemanticNodeId across an unrelated insertion (VM exit 0)\n";
          exit 0
      | Some code ->
          fail
            "probe check %d failed (persistent rename must keep the StructuralInstanceId, ephemeral must re-key, member lineage must survive insertion + continuation, persistent HIR lineage must keep StableSemanticNodeId across an unrelated insertion)"
            code
      | None ->
          fail
            "the kernel VM run did not complete — an upstream closure stage failed")
