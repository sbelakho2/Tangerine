(* host_fs.ml — virtual-repo-root filesystem (audit §43).

   Logical paths are root-relative string lists; the virtual root "/"
   maps to repo_root. Escapes (".." above the root, and any segment
   containing a directory separator) are rejected lexically — no logical
   path can address anything outside repo_root. *)

type t = {
  repo_root : string;
  mutable cwd : string list;
}

let create ~repo_root : t = { repo_root; cwd = [] }

let sep_char : char = Filename.dir_sep.[0]

let resolve (t : t) (path : string list) : (string, string) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | ".." :: rest -> (
        match acc with
        | [] -> Error "path escapes the virtual root"
        | _ :: tl -> go tl rest)
    | "." :: rest -> go acc rest
    | seg :: rest ->
        if String.contains seg sep_char then
          Error ("path segment contains a directory separator: " ^ seg)
        else if seg = "" then Error "empty path segment"
        else go (seg :: acc) rest
  in
  match go [] path with
  | Error e -> Error e
  | Ok [] -> Ok t.repo_root
  | Ok segs -> Ok (List.fold_left Filename.concat t.repo_root segs)

let read_file (t : t) (path : string list) : (string, string) result =
  match resolve t path with
  | Error e -> Error e
  | Ok real -> (
      try Ok (In_channel.with_open_bin real In_channel.input_all) with
      | Sys_error msg -> Error msg)

let write_file (t : t) (path : string list) (content : string) : (unit, string) result =
  match resolve t path with
  | Error e -> Error e
  | Ok real -> (
      try
        let oc = open_out_bin real in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
            output_string oc content;
            Ok ())
      with Sys_error msg -> Error msg)

let list_dir (t : t) (path : string list) : (string list, string) result =
  match resolve t path with
  | Error e -> Error e
  | Ok real -> (
      try Ok (List.sort compare (Array.to_list (Sys.readdir real))) with
      | Sys_error msg -> Error msg)

let create_dir (t : t) (path : string list) : (unit, string) result =
  match resolve t path with
  | Error e -> Error e
  | Ok real -> (
      try
        Unix.mkdir real 0o755;
        Ok ()
      with Unix.Unix_error (e, _, _) -> Error (Unix.error_message e))

let exists (t : t) (path : string list) : bool =
  match resolve t path with
  | Error _ -> false
  | Ok real -> Sys.file_exists real

let remove_file (t : t) (path : string list) : (unit, string) result =
  match resolve t path with
  | Error e -> Error e
  | Ok real -> (
      try
        Unix.unlink real;
        Ok ()
      with Unix.Unix_error (e, _, _) -> Error (Unix.error_message e))
