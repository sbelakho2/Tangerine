(* tg_cfg_scaling — realized cfg-elimination scaling regression.

   The kernel battery `CFG_SCALING_BATTERY` pins the STRUCTURAL operation
   count (cfg predicate evaluations grow exactly linearly).  This harness
   pins the REALIZED work: it runs the same synthetic item-list sizes
   (256/512/1024/2048, each with an inline nested module) through the seed
   VM and records actual VM steps.  A hidden quadratic scan, a pathological
   clone loop or a persistent-map replacement blow-up that does not touch
   the predicate counter is still visible here.

   Warm lane: the first run populates the kernel VM cache, every measured
   run is VM-only; kernel argv and the flag files are runtime data and are
   never part of the cache key.

   Output: one machine-readable row per size plus an aggregate verdict.
   Exit 0 requires every run green, exact linear predicate growth
   (3n + 2), and realized steps within a generous linear envelope:
   8x the items must stay under 10x the steps, and each doubling under 3x.
   Never a wall-clock assertion. *)

let fail fmt = Printf.ksprintf (fun s -> prerr_string ("tg_cfg_scaling: " ^ s ^ "\n"); exit 1) fmt

let () =
  let repo_root = if Array.length Sys.argv > 1 then Sys.argv.(1) else ".." in
  let build_dir = Filename.concat repo_root "build" in
  if not (Sys.file_exists build_dir) then fail "missing build dir %s" build_dir;
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let manifest_path = "bootstrap/infer_mini.manifest" in
  let flag = Filename.concat build_dir "cfg_scaling.flag" in
  let n_file = Filename.concat build_dir "cfg_scaling_n.txt" in
  let evals_file = Filename.concat build_dir "cfg_scaling_evals.txt" in
  let cache = Filename.concat build_dir "cfg_scaling_vm.cache" in
  let kernel_args = [ "infer"; "-o"; "cfg_scaling.out" ] in
  let write_file path text =
    let oc = open_out path in
    output_string oc text;
    close_out oc
  in
  let read_file path =
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  in
  let remove_if path = if Sys.file_exists path then Sys.remove path in
  let run_size ?(require_steps = true) n =
    write_file n_file (string_of_int n);
    write_file flag "1\n";
    let result =
      Driver.run_bootstrap_vm ~repo_root ~manifest_path ~target ~entry:None
        ~kernel_args ~vm_cache:cache ()
    in
    remove_if flag;
    match result with
    | Error m -> fail "size %d: closure run failed: %s" n m
    | Ok run -> (
        match run.Driver.bvr_vm_code with
        | Some 0 -> (
            if not (Sys.file_exists evals_file) then
              fail "size %d: kernel wrote no %s" n evals_file;
            let evals = int_of_string (String.trim (read_file evals_file)) in
            let steps =
              match run.Driver.bvr_vm_steps with
              | Some s -> s
              | None ->
                  if require_steps then
                    fail "size %d: warm run exposed no VM step count" n
                  else -1
            in
            let expected_evals = 3 * n + 2 in
            if evals <> expected_evals then
              fail "size %d: evals=%d want exactly %d" n evals expected_evals;
            if require_steps then
              Printf.printf "CFG_VM_SCALING n=%d steps=%d evals=%d cache_hit=%b\n%!"
                n steps evals run.Driver.bvr_cache_hit;
            (n, steps))
        | Some code -> fail "size %d: kernel exit %d" n code
        | None ->
            fail "size %d: kernel trapped: %s" n
              (match run.Driver.bvr_trap with Some t -> t | None -> "?"))

  in
  (* warmup: populate the VM cache (the cold pipeline run exposes no VM
     steps; that is expected and its row is not compared) *)
  let warm_n = 64 in
  ignore (run_size ~require_steps:false warm_n);
  let sizes = [ 256; 512; 1024; 2048 ] in
  let rows = List.map run_size sizes in
  let steps_of n = List.assoc n rows in
  let first = steps_of 256 and last = steps_of 2048 in
  let ok = ref true in
  let check label cond =
    if not cond then begin
      ok := false;
      Printf.printf "CFG_VM_SCALING_FAIL %s\n%!" label
    end
  in
  check "8x-items-under-10x-steps"
    (last <= 10 * max first 1);
  List.iter
    (fun (a, b) -> check (Printf.sprintf "doubling-%d->%d-under-3x" a b)
        (steps_of b <= 3 * max (steps_of a) 1))
    [ (256, 512); (512, 1024); (1024, 2048) ];
  if !ok then begin
    Printf.printf "CFG_VM_SCALING_BATTERY fails=0 cases=%d steps_first=%d steps_last=%d\n%!"
      (List.length sizes) first last;
    Selfcheck_sentinel.emit_and_exit "tg_cfg_scaling"
  end
  else begin
    Printf.printf "CFG_VM_SCALING_BATTERY fails=1 cases=%d steps_first=%d steps_last=%d\n%!"
      (List.length sizes) first last;
    exit 1
  end
