(* tg_linkprobe.ml — the kernel-native compile-to-executable fast lane.

   Runs the kernel closure (bootstrap/linkprobe_mini.manifest: the kernel
   modules + selfcheck/linkprobe.tg) with the probe entry `main`.  The
   probe has two modes, selected by the kernel argv:

     --mode linkobj (default, fast)
       The probe builds a minimal aarch64 object in the VM (mov x0,#42;
       ret + `main`) and runs the REAL link_executable path: Mach-O
       emission, in-memory validation, output.tmp write + chmod,
       codesign -s -, codesign --verify, rename.

     --mode full
       The probe runs the REAL kernel compile entry
       (compile_startup_entry -> generate_executable) over a tiny
       embedded source: the end-to-end compile-to-executable proof.

   Both modes pass only when:
     - the probe VM run exits 0;
     - the artifact exists with a nonzero size;
     - executing the artifact natively yields exit code 42.

   The prepared-VM program cache (--cache PATH) makes the loop fast: the
   seed front end + lowering + mono run once, every later run re-executes
   only the VM stage (see Driver.run_bootstrap_vm).

   Usage: tg_linkprobe.exe [repo-root] [--mode linkobj|full] [--no-cache]
                           [--cache PATH] *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_linkprobe: FAIL: %s\n" s;
      exit 1)
    fmt

let ensure_dir path =
  let rec go p =
    if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      | Unix.Unix_error (e, _, _) ->
          fail "cannot create the output directory %s: %s" p
            (Unix.error_message e)
    end
  in
  go path

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* The Mach-O LC_SYMTAB undefined-symbol scan (little-endian 64-bit):
   returns every undefined external symbol that must NEVER be handed to
   dyld: the unresolved `__intrinsic_*` imports (the linker's fail-closed
   contract) and the leftover `_size_of`/`_align_of` extern calls (the
   type-query fold's fail-closed contract — a source `size_of[T]()`
   must have been folded to its layout constant, never emitted as an
   extern symbol). A produced artifact must carry neither. *)
let macho_undefined_intrinsics path =
  let s = read_file path in
  let n = String.length s in
  let u32 off =
    if off < 0 || off + 4 > n then 0
    else
      Char.code s.[off]
      lor (Char.code s.[off + 1] lsl 8)
      lor (Char.code s.[off + 2] lsl 16)
      lor (Char.code s.[off + 3] lsl 24)
  in
  if u32 0 <> 0xFEEDFACF then []
  else
    let ncmds = u32 16 in
    let out = ref [] in
    let rec cmds off i =
      if i < ncmds && off + 8 <= n then begin
        let cmd = u32 off and cmdsize = u32 (off + 4) in
        if cmd = 0x2 (* LC_SYMTAB *) && off + 24 <= n then begin
          let symoff = u32 (off + 8) and nsyms = u32 (off + 12) in
          let stroff = u32 (off + 16) in
          for k = 0 to nsyms - 1 do
            let e = symoff + (k * 16) in
            if e + 16 <= n then begin
              let n_strx = u32 e in
              let n_type = Char.code s.[e + 4] in
              if n_type land 0x0e = 0 && n_type land 0x01 <> 0 then begin
                let p = stroff + n_strx in
                if p >= 0 && p < n then begin
                  let stop = try String.index_from s p '\000' with Not_found -> n in
                  let name = String.sub s p (stop - p) in
                  (* Mach-O string-table names carry the C '_' prefix on top
                     of the source symbol, so a Tangerine __intrinsic_foo
                     lands as ___intrinsic_foo: strip exactly one leading
                     underscore before the prefix test. *)
                  let name =
                    if String.length name > 0 && name.[0] = '_' then
                      String.sub name 1 (String.length name - 1)
                    else name
                  in
                  let banned =
                    let len = String.length name in
                    (len >= 12 && String.sub name 0 12 = "__intrinsic_")
                    || name = "size_of" || name = "align_of"
                  in
                  if banned then out := name :: !out
                end
              end
            end
          done
        end
        else if cmdsize > 0 then cmds (off + cmdsize) (i + 1)
      end
    in
    cmds 32 0;
    List.rev !out

let contains_substring haystack needle =
  let n = String.length haystack and m = String.length needle in
  if m = 0 then true
  else begin
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i + m <= n do
      if String.sub haystack !i m = needle then found := true;
      incr i
    done;
    !found
  end

let run_native path =
  let out_r, out_w = Unix.pipe () in
  let pid =
    Unix.create_process path [| path |] Unix.stdin out_w Unix.stderr
  in
  Unix.close out_w;
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec drain () =
    match Unix.read out_r chunk 0 4096 with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        drain ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
  in
  drain ();
  Unix.close out_r;
  let status =
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED c -> `Exited c
    | _, Unix.WSIGNALED s -> `Signaled s
    | _, Unix.WSTOPPED s -> `Stopped s
  in
  (status, Buffer.contents buf)

let () =
  let args = Array.to_list Sys.argv in
  let repo_root, rest =
    match args with _ :: r :: rest -> (r, rest) | _ -> ("..", [])
  in
  ensure_dir (Filename.concat repo_root "build");
  let mode, use_cache, cache_path, target_str =
    let rec go mode cache target = function
      | "--mode" :: m :: rest -> go m cache target rest
      | "--no-cache" :: rest -> go mode None target rest
      | "--cache" :: p :: rest -> go mode (Some p) target rest
      | "--target" :: t :: rest -> go mode cache t rest
      | _ :: rest -> go mode cache target rest
      | [] -> (mode, cache, target)
    in
    let mode, cache, target =
      go "linkobj"
        (Some (Filename.concat repo_root "build/linkprobe.vmcache"))
        (match Sys.getenv_opt "TG_BOOTSTRAP_TARGET" with
         | Some t -> t
         | None -> "aarch64-apple-darwin")
        rest
    in
    (mode, cache <> None, (match cache with Some p -> p | None -> ""), target)
  in
  if mode <> "linkobj" && mode <> "full" then
    fail "unknown --mode %s (expected linkobj or full)" mode;
  let target =
    match Target.unsupported_triple target_str with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let t0 = Unix.gettimeofday () in
  let vm_cache = if use_cache then Some cache_path else None in
  (* The seed's own closure fingerprint: the in-VM probe recomputes it
     over the manifest + source bytes it reads and must agree. *)
  let manifest_fingerprint =
    match
      Bootstrap_manifest.load ~repo_root
        ~manifest_path:"bootstrap/compiler_kernel.manifest"
    with
    | Ok m -> Bootstrap_manifest.fingerprint m
    | Error _ -> ""
  in
  match
    Driver.run_bootstrap_vm ~repo_root
      ~manifest_path:"bootstrap/linkprobe_mini.manifest" ~target
      ~entry:(Some "main")
      ~kernel_args:[ "linkprobe"; mode; target_str; manifest_fingerprint ]
      ?vm_cache ()
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok run ->
      let dt = Unix.gettimeofday () -. t0 in
      Printf.printf
        "tg_linkprobe: mode=%s target=%s vm_code=%s cache_hit=%b reachable=%d wall=%.1fs\n"
        mode target_str
        (match run.Driver.bvr_vm_code with
        | Some c -> string_of_int c
        | None -> "trap")
        run.Driver.bvr_cache_hit run.Driver.bvr_reachable dt;
      if run.Driver.bvr_stdout <> "" then
        Printf.printf "tg_linkprobe: kernel stdout:\n%s\n" run.Driver.bvr_stdout;
      if run.Driver.bvr_stderr <> "" then
        Printf.printf "tg_linkprobe: kernel stderr:\n%s\n" run.Driver.bvr_stderr;
      (match run.Driver.bvr_trap with
      | Some t -> Printf.printf "tg_linkprobe: trap: %s\n" t
      | None -> ());
      let report_path = Filename.concat repo_root "build/linkprobe_report.txt" in
      if Sys.file_exists report_path then
        Printf.printf "tg_linkprobe: probe report:\n%s" (read_file report_path);
      (match run.Driver.bvr_vm_code with
      | Some 0 ->
          if not (Sys.file_exists report_path) then
            fail
              "VM exit 0 but the expected probe report %s is missing — the probe's write_file failed silently (its parent directory must exist before the guest writes; the guest write error is discarded) or the probe did not reach the write"
              report_path
      | Some code ->
          fail
            "probe main returned %d — the kernel executable backend failed (see the report above)"
            code
      | None ->
          fail
            "the VM run did not complete (see the trap/report above): the kernel executable backend failed");
      let artifact =
        if mode = "linkobj" then "build/linkprobe_obj.out"
        else "build/linkprobe.out"
      in
      let out_path = Filename.concat repo_root artifact in
      if not (Sys.file_exists out_path) then
        fail "the kernel reported success but produced no artifact at %s" out_path;
      let st = Unix.stat out_path in
      if st.Unix.st_size <= 0 then
        fail "the produced artifact is empty (0 bytes)";
      (* RUNNABLE-EFFECTIVE: the artifact must carry no undefined
         __intrinsic_* / _size_of / _align_of symbol (the linker's and
         the type-query fold's fail-closed contracts). A leftover
         intrinsic import would abort the process at dyld load ("Symbol
         not found: __intrinsic_...") and a leftover size_of/align_of
         extern call would abort with "Symbol not found: _size_of" /
         "_align_of" — exactly the failure classes this fast lane exists
         to catch. *)
      let leftover = macho_undefined_intrinsics out_path in
      if leftover <> [] then
        fail
          "the artifact still carries forbidden undefined extern symbol(s): %s — the linker left them for dyld instead of failing closed, or size_of/align_of were not folded to layout constants"
          (String.concat ", " leftover);
      (* Execute the artifact natively: the probe's main returns 42 and,
         in full mode, prints the parse-boundary check marker — the
         in-artifact assertion for the literal / owned / as_str-derived
         parse cases. A non-42 exit names the first failing check. *)
      let exit_hint code =
        if mode = "full" && code >= 11 && code <= 24 then
          let what =
            match code with
            | 11 -> "parse literal Ok(42)"
            | 12 -> "parse literal Err(garbage)"
            | 13 -> "owned String parse Ok(43)"
            | 14 -> "owned String parse Err(12x)"
            | 15 -> "as_str-derived view parse Ok(43)"
            | 16 -> "as_str-derived view parse Err(12x)"
            | 17 -> "float_to_bits"
            | 18 -> "int_to_float"
            | 19 -> "float_to_int"
            | 20 -> "size_of/align_of u8"
            | 21 -> "size_of/align_of UInt"
            | 22 -> "size_of/align_of ProbePair[u8]"
            | 23 -> "generic size_of/align_of ProbePair[UInt]"
            | _ -> "generic size_of/align_of UInt"
          in
          Printf.sprintf " — the failing check is %s" what
        else ""
      in
      let execute ?(marker = "") label path =
        let status, output =
          try run_native path
          with Unix.Unix_error (e, _, _) ->
            fail "could not execute the %s artifact: %s" label
              (Unix.error_message e)
        in
        if output <> "" then
          Printf.printf "tg_linkprobe: %s artifact stdout:\n%s" label output;
        (match status with
        | `Exited 42 -> ()
        | `Exited c ->
            fail "the %s artifact ran but exited %d (expected 42)%s" label c
              (exit_hint c)
        | `Signaled s -> fail "the %s artifact was killed by signal %d" label s
        | `Stopped s -> fail "the %s artifact stopped by signal %d" label s);
        if marker <> "" && not (contains_substring output marker) then
          fail
            "the %s artifact did not print the expected marker %S — the embedded parse-boundary checks did not all hold"
            label marker
      in
      if mode = "full" then
        execute ~marker:"LINKPROBE_ARTIFACT_OK" "probe" out_path
      else execute "probe" out_path;
      (* linkobj mode also executes the libc-import artifact: a dyld
         import (libSystem `_exit`) must still link and run after the
         fail-closed intrinsic guard. *)
      if mode = "linkobj" then begin
        let libc_path = Filename.concat repo_root "build/linkprobe_libc.out" in
        if not (Sys.file_exists libc_path) then
          fail "the libc-import artifact build/linkprobe_libc.out is missing";
        let l_leftover = macho_undefined_intrinsics libc_path in
        if l_leftover <> [] then
          fail "the libc-import artifact carries forbidden undefined extern symbol(s): %s"
            (String.concat ", " l_leftover);
        execute "libc-import" libc_path
      end;
      Printf.printf
        "tg_linkprobe: PASS — kernel %s path produced a codesigned executable; no undefined __intrinsic_*/_size_of/_align_of symbols; the artifact ran natively with exit 42%s (cache_hit=%b, %.1fs)\n"
        (if mode = "linkobj" then "link_executable" else "compile-to-executable")
        (if mode = "linkobj" then " (libc-import artifact included)" else "")
        run.Driver.bvr_cache_hit dt;
      Selfcheck_sentinel.emit_and_exit "tg_linkprobe"
