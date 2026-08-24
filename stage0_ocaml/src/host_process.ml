(* host_process.ml — process spawning without /bin/sh (audit §44).

   Children are created with fork + execvpe (PATH search, explicit
   environment, no shell). spawn captures stdout/stderr through pipes that
   are drained concurrently with select, so a child writing a lot to both
   streams cannot deadlock the parent. A path-shaped executable that does
   not exist is rejected up front with an error result. *)

type status = {
  exit_code : int option;
  signal : int option;
  stdout : string;
  stderr : string;
}

(* Reject a path-shaped executable that is clearly absent; bare names are
   left to execvpe's PATH search. *)
let check_executable (executable : string) : (unit, string) result =
  if String.contains executable '/' && not (Sys.file_exists executable) then
    Error (Printf.sprintf "executable not found: %s" executable)
  else Ok ()

let rec waitpid (pid : int) : Unix.process_status =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

let rec wait_ready (fds : Unix.file_descr list) : Unix.file_descr list =
  try
    let ready, _, _ = Unix.select fds [] [] (-1.0) in
    ready
  with Unix.Unix_error (Unix.EINTR, _, _) -> wait_ready fds

let drain_pipes (out_r : Unix.file_descr) (err_r : Unix.file_descr) : string * string =
  let out_buf = Buffer.create 4096 in
  let err_buf = Buffer.create 4096 in
  let chunk = Bytes.create 65536 in
  let out_open = ref true in
  let err_open = ref true in
  let rec loop () =
    if !out_open || !err_open then begin
      let fds =
        (if !out_open then [ out_r ] else []) @ (if !err_open then [ err_r ] else [])
      in
      let ready = wait_ready fds in
      if !out_open && List.mem out_r ready then
        (match Unix.read out_r chunk 0 (Bytes.length chunk) with
        | 0 -> out_open := false
        | n -> Buffer.add_subbytes out_buf chunk 0 n
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
      if !err_open && List.mem err_r ready then
        (match Unix.read err_r chunk 0 (Bytes.length chunk) with
        | 0 -> err_open := false
        | n -> Buffer.add_subbytes err_buf chunk 0 n
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
      loop ()
    end
  in
  loop ();
  (Buffer.contents out_buf, Buffer.contents err_buf)

(* Child-side failure: write a diagnostic to the child's stderr (already
   dup2'd onto the pipe by the caller) and exit 127. *)
let child_fail (msg : string) : 'a =
  let line = "host_process: " ^ msg ^ "\n" in
  (try ignore (Unix.write_substring Unix.stderr line 0 (String.length line)) with _ -> ());
  Unix._exit 127

let spawn ~executable ~argv ~env ~cwd : (status, string) result =
  match check_executable executable with
  | Error e -> Error e
  | Ok () -> (
      try
        let null_dev = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
        let out_r, out_w = Unix.pipe () in
        let err_r, err_w = Unix.pipe () in
        match Unix.fork () with
        | 0 ->
            (* Child: /dev/null on stdin, pipes on stdout/stderr, then
               exec. The child never returns from this branch. *)
            Sys.set_signal Sys.sigpipe Sys.Signal_default;
            (try Unix.dup2 null_dev Unix.stdin with
            | Unix.Unix_error (e, f, _) ->
                child_fail (Printf.sprintf "%s: %s" f (Unix.error_message e)));
            (try Unix.close null_dev with _ -> ());
            (try Unix.close out_r with _ -> ());
            (try Unix.dup2 out_w Unix.stdout with
            | Unix.Unix_error (e, f, _) ->
                child_fail (Printf.sprintf "%s: %s" f (Unix.error_message e)));
            (try Unix.close out_w with _ -> ());
            (try Unix.close err_r with _ -> ());
            (try Unix.dup2 err_w Unix.stderr with
            | Unix.Unix_error (e, f, _) ->
                child_fail (Printf.sprintf "%s: %s" f (Unix.error_message e)));
            (try Unix.close err_w with _ -> ());
            (match cwd with
            | Some dir -> (
                try Unix.chdir dir
                with Unix.Unix_error (e, _, _) ->
                  child_fail (Printf.sprintf "chdir %s: %s" dir (Unix.error_message e)))
            | None -> ());
            ignore
              (try Unix.execvpe executable argv env
               with Unix.Unix_error (e, f, _) ->
                 child_fail
                   (Printf.sprintf "execvpe %s: %s: %s" executable f (Unix.error_message e)));
            assert false
        | pid ->
            Unix.close null_dev;
            Unix.close out_w;
            Unix.close err_w;
            let stdout, stderr = drain_pipes out_r err_r in
            Unix.close out_r;
            Unix.close err_r;
            let ps = waitpid pid in
            let st =
              match ps with
              | Unix.WEXITED n -> { exit_code = Some n; signal = None; stdout; stderr }
              | Unix.WSIGNALED s -> { exit_code = None; signal = Some s; stdout; stderr }
              | Unix.WSTOPPED s -> { exit_code = None; signal = Some s; stdout; stderr }
            in
            Ok st
      with
      | Unix.Unix_error (e, f, _) ->
          Error (Printf.sprintf "host_process.spawn: %s: %s" f (Unix.error_message e))
      | Sys_error msg -> Error ("host_process.spawn: " ^ msg)
      | Failure msg -> Error ("host_process.spawn: " ^ msg))

(* Direct exit status with inherited stdio: the shell convention of
   128 + signal for signaled children. *)
let spawn_nocapture ~executable ~argv ~env : (int, string) result =
  match check_executable executable with
  | Error e -> Error e
  | Ok () -> (
      try
        match Unix.fork () with
        | 0 ->
            Sys.set_signal Sys.sigpipe Sys.Signal_default;
            ignore
              (try Unix.execvpe executable argv env
               with Unix.Unix_error (e, f, _) ->
                 child_fail
                   (Printf.sprintf "execvpe %s: %s: %s" executable f (Unix.error_message e)));
            assert false
        | pid ->
            let ps = waitpid pid in
            (match ps with
            | Unix.WEXITED n -> Ok n
            | Unix.WSIGNALED s -> Ok (128 + s)
            | Unix.WSTOPPED s -> Ok (128 + s))
      with
      | Unix.Unix_error (e, f, _) ->
          Error
            (Printf.sprintf "host_process.spawn_nocapture: %s: %s" f (Unix.error_message e))
      | Failure msg -> Error ("host_process.spawn_nocapture: " ^ msg))
