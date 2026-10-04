(* host_fs.ml — virtual-repo-root filesystem (audit §43, host P1).

   Logical paths are root-relative string lists; the virtual root "/"
   maps to repo_root. The root is CANONICALIZED once (Unix.realpath) at
   construction, so all containment comparisons operate on physical
   paths.

   Containment is enforced at a path-segment boundary, the same rule
   Bootstrap_manifest.resolve_under_root uses: a resolved real path is
   contained iff it equals the canonical root or starts with
   (canonical root ^ "/") — so `/repo` can never prefix-match a sibling
   `/repo_evil`. Escapes are rejected in two layers:

     - lexical (no ".." above the root, no segment containing a
       directory separator, no empty segment), and
     - physical: for READS/LISTS/REMOVES of existing paths the final
       real path (symlinks resolved) is checked against the canonical
       root; for WRITES/NEW DIRECTORIES the canonicalized parent is
       validated before creation, and an already-existing final
       component is itself resolved and checked (a symlink as the last
       segment cannot point outside the root).

   The cwd field participates in resolution: a logical path is the
   virtual path (cwd @ path) joined, then resolved as above. *)

type t = {
  repo_root : string;
  mutable cwd : string list;
}

(* Structured resolution failures: callers map these to errno / display
   without parsing diagnostic strings. *)
type resolve_error =
  | Not_found
  | Escape  (* lexical ".." above the root *)
  | Escaped of string  (* physical path outside the canonical root *)
  | Invalid_path of string
  | Io of Unix.error

let resolve_error_message (e : resolve_error) : string =
  match e with
  | Not_found -> "path not found"
  | Escape -> "path escapes the virtual root"
  | Escaped real ->
      Printf.sprintf "path escapes the virtual root (resolved to %s)" real
  | Invalid_path detail -> detail
  | Io e -> Unix.error_message e

let create ~repo_root : t =
  let root =
    try Unix.realpath repo_root
    with Unix.Unix_error (e, _, _) ->
      failwith
        (Printf.sprintf "Host_fs.create: cannot canonicalize repo root '%s': %s"
           repo_root (Unix.error_message e))
  in
  { repo_root = root; cwd = [] }

let cwd (t : t) : string list = t.cwd

let set_cwd (t : t) (cwd : string list) : unit = t.cwd <- cwd

let sep_char : char = Filename.dir_sep.[0]

(* Lexical resolution: cwd joins the virtual path; ".." cannot climb
   above the root; "." is dropped; a segment containing a directory
   separator or an empty segment is rejected. Returns the root-relative
   segment list (the empty list is the root itself). *)
let lexical_resolve_from (base : string list) (path : string list) :
    (string list, resolve_error) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | ".." :: rest -> (
        match acc with
        | [] -> Error Escape
        | _ :: tl -> go tl rest)
    | "." :: rest -> go acc rest
    | seg :: rest ->
        if String.contains seg sep_char then
          Error
            (Invalid_path
               ("path segment contains a directory separator: " ^ seg))
        else if seg = "" then Error (Invalid_path "empty path segment")
        else go (seg :: acc) rest
  in
  go [] (base @ path)

let lexical_resolve (t : t) (path : string list) :
    (string list, resolve_error) result =
  lexical_resolve_from t.cwd path

(* Virtual-ABSOLUTE paths resolve from the virtual root, never the cwd;
   ".." still cannot climb above the root. *)
let lexical_resolve_abs (_t : t) (path : string list) :
    (string list, resolve_error) result =
  lexical_resolve_from [] path

let join_root (t : t) (segs : string list) : string =
  List.fold_left Filename.concat t.repo_root segs

(* Segment-boundary containment against the canonical root (the same
   rule Bootstrap_manifest uses: equal to the root, or under root ^ "/"). *)
let contained (t : t) (real : string) : bool =
  real = t.repo_root || Util.has_prefix real (t.repo_root ^ "/")

(* Physical resolution of an EXISTING path: lexical resolve, realpath
   the joined path, enforce segment-boundary containment. *)
let resolve_existing_via
    (resolve : string list -> (string list, resolve_error) result) (t : t)
    (path : string list) : (string, resolve_error) result =
  match resolve path with
  | Error e -> Error e
  | Ok segs ->
      let joined = join_root t segs in
      (try
         let real = Unix.realpath joined in
         if contained t real then Ok real else Error (Escaped real)
       with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Not_found
      | Unix.Unix_error (e, _, _) -> Error (Io e))

let resolve_existing_e (t : t) (path : string list) :
    (string, resolve_error) result =
  resolve_existing_via (lexical_resolve t) t path

let resolve_existing_abs_e (t : t) (path : string list) :
    (string, resolve_error) result =
  resolve_existing_via (lexical_resolve_abs t) t path

let resolve_existing (t : t) (path : string list) : (string, string) result =
  Result.map_error resolve_error_message (resolve_existing_e t path)

let resolve_existing_abs (t : t) (path : string list) :
    (string, string) result =
  Result.map_error resolve_error_message (resolve_existing_abs_e t path)

(* Parent resolution for WRITES/NEW DIRECTORIES: the parent path is
   canonicalized (realpath) and containment-checked before anything is
   created beneath it. The final segment must be a single clean name. *)
let resolve_parent_via
    (resolve_existing_fn : string list -> (string, resolve_error) result)
    (path : string list) : (string * string, resolve_error) result =
  let parent_segs, last =
    match List.rev path with
    | [] -> ([], None)
    | last :: rest -> (List.rev rest, Some last)
  in
  match last with
  | None -> Error (Invalid_path "cannot write the virtual root itself")
  | Some name ->
      if String.contains name sep_char then
        Error
          (Invalid_path
             ("path segment contains a directory separator: " ^ name))
      else if name = "" then Error (Invalid_path "empty path segment")
      else (
        match resolve_existing_fn parent_segs with
        | Error e -> Error e
        | Ok parent_real -> Ok (parent_real, name))

let resolve_parent_e (t : t) (path : string list) :
    (string * string, resolve_error) result =
  resolve_parent_via (resolve_existing_e t) path

let resolve_parent_abs_e (t : t) (path : string list) :
    (string * string, resolve_error) result =
  resolve_parent_via (resolve_existing_abs_e t) path

let resolve_parent (t : t) (path : string list) :
    (string * string, string) result =
  Result.map_error resolve_error_message (resolve_parent_e t path)

let resolve_parent_abs (t : t) (path : string list) :
    (string * string, string) result =
  Result.map_error resolve_error_message (resolve_parent_abs_e t path)

(* Final write target: the canonicalized parent is validated by
   resolve_parent; an already-existing final component is itself
   resolved and containment-checked, so a symlink as the last segment
   cannot redirect the write outside the root. A not-yet-existing
   target is created directly under the validated parent. *)
let resolve_write_target_via
    (resolve_parent_fn : string list -> (string * string, resolve_error) result)
    (t : t) (path : string list) : (string, resolve_error) result =
  match resolve_parent_fn path with
  | Error e -> Error e
  | Ok (parent_real, name) ->
      let full = Filename.concat parent_real name in
      (match Unix.lstat full with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok full
      | exception Unix.Unix_error (e, _, _) -> Error (Io e)
      | st ->
          if st.Unix.st_kind = Unix.S_LNK then Error (Escaped full)
          else (
            try
              let real = Unix.realpath full in
              if contained t real then Ok real else Error (Escaped real)
            with Unix.Unix_error (e, _, _) -> Error (Io e)))

let resolve_write_target_e (t : t) (path : string list) :
    (string, resolve_error) result =
  resolve_write_target_via (resolve_parent_e t) t path

let resolve_write_target_abs_e (t : t) (path : string list) :
    (string, resolve_error) result =
  resolve_write_target_via (resolve_parent_abs_e t) t path

let resolve_write_target (t : t) (path : string list) : (string, string) result =
  Result.map_error resolve_error_message (resolve_write_target_e t path)

let resolve_write_target_abs (t : t) (path : string list) :
    (string, string) result =
  Result.map_error resolve_error_message (resolve_write_target_abs_e t path)

let read_file (t : t) (path : string list) : (string, string) result =
  match resolve_existing_e t path with
  | Error e -> Error (resolve_error_message e)
  | Ok real -> (
      try Ok (In_channel.with_open_bin real In_channel.input_all) with
      | Sys_error msg -> Error msg)

let write_file (t : t) (path : string list) (content : string) : (unit, string) result =
  match resolve_write_target_e t path with
  | Error e -> Error (resolve_error_message e)
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
  match resolve_existing_e t path with
  | Error e -> Error (resolve_error_message e)
  | Ok real -> (
      try Ok (List.sort compare (Array.to_list (Sys.readdir real))) with
      | Sys_error msg -> Error msg)

let create_dir (t : t) (path : string list) : (unit, string) result =
  match resolve_write_target_e t path with
  | Error e -> Error (resolve_error_message e)
  | Ok real -> (
      try
        Unix.mkdir real 0o755;
        Ok ()
      with Unix.Unix_error (e, _, _) -> Error (Unix.error_message e))

let exists (t : t) (path : string list) : bool =
  match resolve_existing_e t path with
  | Error _ -> false
  | Ok real -> Sys.file_exists real

let remove_file (t : t) (path : string list) : (unit, string) result =
  (* The containment check runs on the resolved real path: removing
     through an escaping symlink is rejected. unlink never follows the
     final symlink, so the operation itself removes the named path
     (which lexically lives under the canonical root). *)
  match resolve_existing_e t path with
  | Error e -> Error (resolve_error_message e)
  | Ok _ -> (
      match lexical_resolve t path with
      | Error e -> Error (resolve_error_message e)
      | Ok segs ->
          let joined = join_root t segs in
          try
            Unix.unlink joined;
            Ok ()
          with Unix.Unix_error (e, _, _) -> Error (Unix.error_message e))

(* Public resolution: the final real path of an existing path, with
   containment enforced. Used by Host_process for a Tangerine-supplied
   cwd (a virtual path must resolve inside the root before a child is
   chdir'd onto it). *)
let resolve (t : t) (path : string list) : (string, string) result =
  resolve_existing t path
