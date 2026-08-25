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
  check_normal_operation fs;
  check_cwd_participation fs;
  (try rm_rf tmp
   with Sys_error e -> Printf.printf "  (cleanup warning: %s)\n" e);
  Printf.printf "ALL HOST FS PASS\n";
  exit 0
