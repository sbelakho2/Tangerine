(* tg_hostfs.ml — Host_fs virtual-root containment self-check (host P1).

   Proves the physical (not just lexical) containment of the virtual
   filesystem: a symlink inside the root that points OUTSIDE the root
   must be rejected by every operation — read, write, list, mkdir and
   remove — with a containment error, while normal in-root operation
   (read/write/list/mkdir/remove), the lexical ".." rejection, the cwd
   participation, and the outside world's integrity all keep working. *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt
let pass fmt = Printf.ksprintf (fun s -> Printf.printf "PASS: %s\n" s) fmt

let contains (haystack : string) (needle : string) : bool =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else begin
    let rec go i =
      i + n <= h && (String.sub haystack i n = needle || go (i + 1))
    in
    go 0
  end

(* A rejection is a containment rejection iff the error names the
   escape (the Host_fs containment messages all contain "escapes"). *)
let expect_containment_error (op : string) (r : ('a, string) result) : unit =
  match r with
  | Ok _ -> fail "%s through the escaping symlink was NOT rejected" op
  | Error e ->
      if not (contains e "escapes") then
        fail "%s through the escaping symlink was rejected for the wrong reason: %s" op e;
      Printf.printf "    (%s) %s\n" op e;
      pass "%s through an escaping symlink is rejected (containment error)" op

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

(* Recursive cleanup: unlink files and symlinks, rmdir directories. *)
let rec rm_rf (path : string) : unit =
  let st = Unix.lstat path in
  if st.Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end
  else Unix.unlink path

(* Temp tree:
     tmp/root/            the virtual root (repo_root)
     tmp/root/safe.txt    in-root file
     tmp/root/sub/        in-root directory
     tmp/root/link        SYMLINK -> tmp/secret.txt (escapes the root)
     tmp/secret.txt       outside the root
*)
let build_tree () : string * Host_fs.t =
  let tmp = Filename.temp_file "tg_hostfs" ".d" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let root = Filename.concat tmp "root" in
  Unix.mkdir root 0o755;
  write_file (Filename.concat root "safe.txt") "ok";
  Unix.mkdir (Filename.concat root "sub") 0o755;
  let secret = Filename.concat tmp "secret.txt" in
  write_file secret "TOP SECRET";
  Unix.symlink secret (Filename.concat root "link");
  (* contained symlink/entry fixtures for the no-follow sysop checks *)
  Unix.symlink "safe.txt" (Filename.concat root "ilink");
  Unix.symlink "safe.txt" (Filename.concat root "ilink2");
  Unix.symlink "safe.txt" (Filename.concat root "ilink3");
  Unix.mkdir (Filename.concat root "dir") 0o755;
  Unix.symlink "dir" (Filename.concat root "dlink");
  Unix.symlink secret (Filename.concat root "link_unlink");
  Unix.mkdir (Filename.concat root "x") 0o755;
  Unix.mkdir (Filename.concat root "y") 0o755;
  let fs = Host_fs.create ~repo_root:root in
  (tmp, fs)

let check_symlink_escape (fs : Host_fs.t) (secret : string) : unit =
  (* Every operation through the escaping symlink is REJECTED. *)
  expect_containment_error "read" (Host_fs.read_file fs [ "link" ]);
  expect_containment_error "write" (Host_fs.write_file fs [ "link" ] "pwned");
  expect_containment_error "list" (Host_fs.list_dir fs [ "link" ]);
  expect_containment_error "mkdir" (Host_fs.create_dir fs [ "link" ]);
  expect_containment_error "remove" (Host_fs.remove_file fs [ "link" ]);
  (* Lexical escape (".." above the root) is still rejected. *)
  (match Host_fs.read_file fs [ ".."; "secret.txt" ] with
  | Ok _ -> fail "read through a lexical '..' escape was NOT rejected"
  | Error e ->
      if not (contains e "escapes") then
        fail "'..' escape rejected for the wrong reason: %s" e;
      pass "lexical '..' escape is rejected");
  (* Physical integrity: the rejected write never reached the outside. *)
  if In_channel.with_open_bin secret In_channel.input_all <> "TOP SECRET" then
    fail "the outside file was modified by a rejected write through the symlink";
  pass "the outside target was NOT modified by the rejected write"

(* NoFollowFinal syscall semantics: open/stat follow a contained symlink;
   lstat/readlink/unlink/rename-source/rmdir act on the named entry; an
   escaping symlink is refused by every no-follow operation. *)
let check_raw_symlink_semantics (fs : Host_fs.t) : unit =
  let host = Host.create ~repo_root:fs.Host_fs.repo_root ~argv:[||] () in
  (match Host.host_open host "ilink" 0 0 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      pass "raw open follows a contained symlink"
  | e -> fail "raw open of a contained symlink returned %d" e);
  (match Host.host_stat host "ilink" `Stat with
  | Ok st when st.Unix.LargeFile.st_kind = Unix.S_REG ->
      pass "raw stat follows a contained symlink (regular target)"
  | Ok _ -> fail "raw stat of a contained symlink did not report the target kind"
  | Error e -> fail "raw stat of a contained symlink returned %d" e);
  (match Host.host_stat host "ilink" `Lstat with
  | Ok st when st.Unix.LargeFile.st_kind = Unix.S_LNK ->
      pass "raw lstat does NOT follow a contained symlink"
  | Ok _ -> fail "raw lstat did not report the symlink itself"
  | Error e -> fail "raw lstat of a contained symlink returned %d" e);
  (match Host.host_readlink host "ilink" with
  | Ok "safe.txt" -> pass "raw readlink returns the link target string"
  | Ok other -> fail "raw readlink returned %S" other
  | Error e -> fail "raw readlink returned errno %d" e);
  (match Host.host_unlink host "ilink2" with
  | 0 -> pass "raw unlink removes a contained symlink entry"
  | e -> fail "raw unlink of a contained symlink returned %d" e);
  (match Host.host_stat host "ilink2" `Lstat with
  | Error -2 -> pass "raw unlink removed only the directory entry"
  | _ -> fail "raw unlink did not remove the symlink entry");
  (match Host.host_stat host "safe.txt" `Stat with
  | Ok st when st.Unix.LargeFile.st_kind = Unix.S_REG ->
      pass "raw unlink left the symlink target intact"
  | _ -> fail "raw unlink destroyed the symlink target");
  (match Host.host_rename host "ilink3" "moved" with
  | 0 -> pass "raw rename moves a contained symlink entry"
  | e -> fail "raw rename of a contained symlink returned %d" e);
  (match Host.host_stat host "moved" `Lstat with
  | Ok st when st.Unix.LargeFile.st_kind = Unix.S_LNK ->
      pass "raw rename moved the symlink itself"
  | _ -> fail "raw rename did not leave a symlink at the destination");
  (match Host.host_stat host "safe.txt" `Stat with
  | Ok _ -> pass "raw rename left the symlink target intact"
  | _ -> fail "raw rename destroyed the symlink target");
  (match Host.host_rmdir host "dlink" with
  | 0 -> fail "raw rmdir REMOVED a symlink to a directory"
  | _ -> ());
  (match Host.host_stat host "dir" `Lstat with
  | Ok st when st.Unix.LargeFile.st_kind = Unix.S_DIR ->
      pass "raw rmdir on a symlink-to-dir does not remove the target"
  | _ -> fail "raw rmdir on a symlink-to-dir removed or damaged the target");
  match Host.host_unlink host "link_unlink" with
  | -13 -> pass "raw unlink refuses an escaping symlink (fail-closed)"
  | e -> fail "raw unlink of an escaping symlink returned %d (want -13 EACCES)" e

(* One namespace: absolute guest paths are VIRTUAL-ROOT absolute (the
   same spelling getcwd returns); /dev/* is an explicit capability; the
   host /etc is unreachable. *)
let check_absolute_namespace (fs : Host_fs.t) : unit =
  let host = Host.create ~repo_root:fs.Host_fs.repo_root ~argv:[||] () in
  (match Host.host_open host "/etc/passwd" 0 0 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      fail "absolute /etc/passwd escaped the virtual root"
  | e -> pass "absolute /etc/passwd cannot escape the virtual root (errno %d)" e);
  let create_bit = if Host.host_is_darwin then 0x200 else 0x40 in
  (match Host.host_open host "/dir/abs.txt" (1 lor create_bit) 0o644 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      pass "absolute virtual path opens/writes under the virtual root"
  | e -> fail "absolute virtual open returned %d" e);
  if
    not
      (Sys.file_exists
         (Filename.concat fs.Host_fs.repo_root "dir/abs.txt"))
  then fail "absolute virtual path did not land under the repo root"
  else pass "absolute virtual path resolved to <repo>/dir/abs.txt";
  (match Host.host_open host "/dev/null" 0 0 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      pass "/dev/null remains an explicit host capability"
  | e -> fail "/dev/null open returned %d" e);
  Host_fs.set_cwd host.Host.fs [ "x" ];
  (match Host.host_chdir host "/y" with
  | 0 -> pass "absolute chdir resolves from the virtual root"
  | e -> fail "absolute chdir returned %d" e);
  if Host_fs.cwd host.Host.fs <> [ "y" ] then
    fail "absolute chdir produced cwd [%s]"
      (String.concat "/" (Host_fs.cwd host.Host.fs))
  else pass "absolute chdir sets the virtual cwd to /y (not /x/y)";
  Host_fs.set_cwd host.Host.fs []

let check_normal_operation (fs : Host_fs.t) : unit =
  (match Host_fs.read_file fs [ "safe.txt" ] with
  | Ok "ok" -> pass "read of an in-root file works"
  | Ok other -> fail "read of safe.txt returned %S" other
  | Error e -> fail "read of safe.txt failed: %s" e);
  (match Host_fs.write_file fs [ "sub"; "new.txt" ] "hello" with
  | Ok () ->
      (match Host_fs.read_file fs [ "sub"; "new.txt" ] with
      | Ok "hello" -> pass "write + read of an in-root file works"
      | Ok other -> fail "read back of sub/new.txt returned %S" other
      | Error e -> fail "read back of sub/new.txt failed: %s" e)
  | Error e -> fail "write of sub/new.txt failed: %s" e);
  (match Host_fs.create_dir fs [ "sub"; "d" ] with
  | Ok () ->
      if not (Host_fs.exists fs [ "sub"; "d" ]) then
        fail "create_dir succeeded but exists is false";
      pass "create_dir of an in-root directory works"
  | Error e -> fail "create_dir of sub/d failed: %s" e);
  (match Host_fs.list_dir fs [ "sub" ] with
  | Ok entries ->
      let want = List.sort compare [ "d"; "new.txt" ] in
      if entries <> want then fail "list_dir sub returned [%s]" (String.concat ", " entries);
      pass "list_dir of an in-root directory works"
  | Error e -> fail "list_dir of sub failed: %s" e);
  (match Host_fs.remove_file fs [ "sub"; "new.txt" ] with
  | Ok () ->
      if Host_fs.exists fs [ "sub"; "new.txt" ] then
        fail "remove_file succeeded but exists is still true";
      pass "remove_file of an in-root file works"
  | Error e -> fail "remove_file of sub/new.txt failed: %s" e)

(* The RAW syscall-backed route (Host.host_open, the layer every
   std::fs/raw-open path reaches): a resolver refusal must become an
   errno, never a lexical repo-root join that the OS would follow through
   the escaping symlink.  This is exactly the layer above Host_fs where
   the previous fallback defeated containment. *)
let check_raw_syscall_route (fs : Host_fs.t) : unit =
  let host = Host.create ~repo_root:fs.Host_fs.repo_root ~argv:[||] () in
  (match Host.host_open host "link" 0 0 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      fail "raw host_open through the escaping symlink was NOT rejected (fd %d)" fd
  | -13 ->
      pass "raw host_open through the escaping symlink returns EACCES (no lexical fallback)"
  | e ->
      fail "raw host_open through the escaping symlink returned errno %d (want -13 EACCES)" e);
  (match Host.host_open host "../secret.txt" 0 0 with
  | fd when fd >= 0 ->
      ignore (Host.host_close_fd fd);
      fail "raw host_open through a lexical '..' escape was NOT rejected (fd %d)" fd
  | -13 -> pass "raw host_open through a lexical '..' escape returns EACCES"
  | e -> fail "raw '..' open returned errno %d (want -13 EACCES)" e);
  (match Host.host_open host "missing.txt" 0 0 with
  | -2 -> pass "raw host_open of a missing path returns ENOENT (errno distinction kept)"
  | e -> fail "raw host_open of a missing path returned %d (want -2 ENOENT)" e);
  match Host.host_open host "safe.txt" 0 0 with
  | fd when fd >= 0 -> (
      match Host.host_close_fd fd with
      | 0 -> pass "raw host_open of an in-root file still succeeds"
      | _ -> fail "raw in-root open succeeded but close failed")
  | e -> fail "raw host_open of an in-root file failed with errno %d" e

let check_cwd_participation (fs : Host_fs.t) : unit =
  (match Host_fs.write_file fs [ "sub"; "cwd_file.txt" ] "cwd-ok" with
  | Error e -> fail "cwd test setup write failed: %s" e
  | Ok () -> ());
  Host_fs.set_cwd fs [ "sub" ];
  (match Host_fs.read_file fs [ "cwd_file.txt" ] with
  | Ok "cwd-ok" -> pass "cwd participates in resolution (path joins cwd)"
  | Ok other -> fail "cwd read returned %S" other
  | Error e -> fail "cwd participation: read under cwd ['sub'] failed: %s" e);
  (match Host_fs.read_file fs [ ".."; ".."; "safe.txt" ] with
  | Ok _ -> fail "cwd '..' escape was NOT rejected"
  | Error e ->
      if not (contains e "escapes") then
        fail "cwd '..' escape rejected for the wrong reason: %s" e);
  pass "cwd cannot climb above the root (lexical containment)";
  Host_fs.set_cwd fs [];
  (match Host_fs.read_file fs [ "sub"; "cwd_file.txt" ] with
  | Ok "cwd-ok" -> ()
  | Ok other -> fail "cwd reset: read returned %S" other
  | Error e -> fail "cwd reset failed: %s" e);
  pass "cwd reset to the root works"

let () =
  Printf.printf "host fs containment self-check\n";
  let tmp, fs = build_tree () in
  let secret = Filename.concat tmp "secret.txt" in
  check_symlink_escape fs secret;
  check_raw_syscall_route fs;
  check_raw_symlink_semantics fs;
  check_absolute_namespace fs;
  check_normal_operation fs;
  check_cwd_participation fs;
  (try rm_rf tmp
   with Sys_error e -> Printf.printf "  (cleanup warning: %s)\n" e);
  Printf.printf "ALL HOST FS PASS\n";
  Selfcheck_sentinel.emit_and_exit "tg_hostfs"
