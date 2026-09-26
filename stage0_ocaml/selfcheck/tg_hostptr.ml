(* tg_hostptr.ml — focused regression for the address_of/address_of_mut
   inout-pointer boundary (the seed-side fix for the kernel self-run's
   `c_waitpid: argument mismatch: expected Ptr (found Struct, ...)`
   trap).

   The probe stage0_ocaml/selfcheck/addrprobe.tg imports the REAL
   std::ffi address_of_mut and std::process waitpid, takes the address of
   a local, and calls the host extern c_waitpid.  A broken lowering
   rebrands the deref-read VALUE of the callee's by-value inout copy
   (`Ptr { address: 0 }`), which the host boundary rejects as a
   null/foreign address; the fixed lowering passes a real Ref to the
   caller's place, which the boundary materializes as an arena pointer
   with copy-out.

   This harness runs the probe closure through the seed pipeline on
   bootstrap/addrprobe_mini.manifest with entry `main`; the probe returns
   0 exactly when the host call succeeded with the expected ECHILD (-10)
   result.  The VM run must exit 0 — a trap leaves bs_vm_code None and
   fails this lane with the trap text. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_hostptr: FAIL: %s\n" s;
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
      ~manifest_path:"bootstrap/addrprobe_mini.manifest" ~target
      ~entry:(Some "main") ~kernel_args:[ "addrprobe" ]
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          Printf.printf
            "tg_hostptr: PASS — address_of_mut(&mut st) crossed the host boundary as a real reference (c_waitpid returned ECHILD -10, VM exit 0)\n";
          exit 0
      | Some code ->
          fail
            "probe main returned %d — the host call did not report the expected ECHILD (-10)"
            code
      | None ->
          fail
            "the VM run did not complete (the trap text is printed above): the address_of_mut result was rejected at the host boundary")
