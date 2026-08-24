(* bootstrap_manifest.ml — The bootstrap closure manifest (audit §20).

   The manifest is the SOLE authority for the bootstrap closure: no
   directory-scan fallback. Validation: unknown record types rejected,
   duplicate paths rejected, absolute paths rejected, `..` rejected,
   symlink escape rejected, every file must exist and be readable, no
   duplicate canonical file. A deterministic fingerprint (SHA-256 over
   manifest content + version + per-entry canonical sequence of logical
   module path, relative source path, source byte length and SHA-256 of
   the source bytes) is computed at load.

   Each entry retains its validated source snapshot (bytes + SHA-256),
   so nothing re-reads the source files after load (TOCTOU closure). *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* repository-relative source file *)
  real : string;        (* canonical resolved absolute path *)
  source : string;      (* validated source bytes (UTF-8, security-scanned) *)
  source_hash : string; (* SHA-256 (hex) of source bytes *)
}

type t = {
  entries : module_entry list;
  version : string option;
  fingerprint : string;
  manifest_content : string;
}

let entries (m : t) : module_entry list = m.entries
let version_of (m : t) : string option = m.version
let fingerprint (m : t) : string = m.fingerprint

let find (m : t) (path : string list) : module_entry option =
  List.find_opt (fun e -> e.path = path) m.entries

(* ── Validation helpers ────────────────────────────────────────── *)

let reject_path (rel : string) : (string, string) result =
  if String.length rel = 0 then Error "empty path"
  else if rel.[0] = '/' then Error (Printf.sprintf "absolute path '%s'" rel)
  else begin
    let segs = String.split_on_char '/' rel in
    if List.exists (fun s -> s = "..") segs then
      Error (Printf.sprintf "path escapes repository root ('..' in '%s')" rel)
    else if List.exists (fun s -> s = ".") segs then
      Error (Printf.sprintf "path contains '.' segment: '%s'" rel)
    else if List.exists (fun s -> s = "") segs then
      Error (Printf.sprintf "path contains empty segment: '%s'" rel)
    else Ok rel
  end

(* Resolve a repo-relative path beneath root, rejecting symlink escape.
   Containment is checked at a path-segment boundary: the resolved path
   must equal the root itself or start with root ^ "/", so a root
   `/repo` can never prefix-match a sibling `/repo_evil/...`. *)
let resolve_under_root (repo_root : string) (rel : string) : (string, string) result =
  match reject_path rel with
  | Error m -> Error m
  | Ok rel ->
      let full = Filename.concat repo_root rel in
      (try
         let real = Unix.realpath full in
         let root_real = Unix.realpath repo_root in
         if real = root_real || Util.has_prefix real (root_real ^ "/") then Ok real
         else Error (Printf.sprintf "path escapes repository root via symlink: '%s'" rel)
       with Unix.Unix_error _ -> Error (Printf.sprintf "cannot resolve path '%s'" rel))

(* ── Fingerprint ────────────────────────────────────────────────── *)

(* Fingerprint input (deterministic, no absolute paths or timestamps):

   content ^ "\n\000" ^ version ^ "\n\000"
   ^ for each entry in manifest order, separated by "\000":
       String.concat "::" path ^ "\001" ^ file ^ "\001"
       ^ string_of_int (String.length source) ^ "\001" ^ source_hash

   The per-entry canonical sequence — logical module path, relative
   source path, source byte length, SHA-256(source bytes) — means the
   fingerprint changes whenever any source file's bytes change, even
   when the manifest itself is untouched. *)
let fingerprint_of (content : string) (version : string option)
    (entries : module_entry list) : string =
  let buf = Buffer.create (String.length content + 64) in
  Buffer.add_string buf content;
  Buffer.add_string buf "\n\000";
  Buffer.add_string buf (match version with Some v -> v | None -> "");
  Buffer.add_string buf "\n\000";
  List.iteri
    (fun i e ->
      if i > 0 then Buffer.add_char buf '\000';
      Buffer.add_string buf (String.concat "::" e.path);
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.file;
      Buffer.add_char buf '\001';
      Buffer.add_string buf (string_of_int (String.length e.source));
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.source_hash)
    entries;
  Sha256.digest (Buffer.contents buf)

(* ── Loader ────────────────────────────────────────────────────── *)

let load ~(repo_root : string) ~(manifest_path : string) : (t, string) result =
  let open Result in
  let manifest_path =
    if Filename.is_relative manifest_path then Filename.concat repo_root manifest_path
    else manifest_path
  in
  match Source_loader.load manifest_path with
  | Error _ -> Error (Printf.sprintf "cannot read manifest '%s'" manifest_path)
  | Ok manifest_src ->
      let content = manifest_src.Source.bytes in
      let lines = String.split_on_char '\n' content in
      let entries = ref [] in
      let version = ref None in
      let seen = ref Util.StringSet.empty in
      let errors = ref [] in
      List.iteri
        (fun lineno line ->
          let line = String.trim line in
          if line <> "" && not (Util.has_prefix line "#") then begin
            match String.index_opt line ':' with
            | None ->
                errors := Printf.sprintf "line %d: malformed record '%s'" (lineno + 1) line :: !errors
            | Some ci ->
                let kind = String.trim (String.sub line 0 ci) in
                let value = String.trim (String.sub line (ci + 1) (String.length line - ci - 1)) in
                (match kind with
                 | "version" ->
                     if !version <> None then
                       errors := Printf.sprintf "line %d: duplicate version record" (lineno + 1) :: !errors;
                     version := Some value
                 | "std" | "compiler" ->
                     if value = "" then
                       errors := Printf.sprintf "line %d: empty filename" (lineno + 1) :: !errors
                     else begin
                       (* The record kind names the source directory:
                          `std:` -> std/, `compiler:` -> tg_compiler/. *)
                       let dir = if kind = "std" then "std" else "tg_compiler" in
                       let rel = dir ^ "/" ^ value in
                       if Util.StringSet.mem rel !seen then
                         errors := Printf.sprintf "line %d: duplicate path '%s'" (lineno + 1) rel :: !errors;
                       seen := Util.StringSet.add rel !seen;
                       let name =
                         if Util.has_suffix value ".tg" then
                           String.sub value 0 (String.length value - 3)
                         else value
                       in
                       entries :=
                         { path = String.split_on_char '/' (dir ^ "/" ^ name) |> List.filter (fun x -> x <> ""); file = rel;
                           real = ""; source = ""; source_hash = "" }
                         :: !entries
                     end
                 | other ->
                     errors := Printf.sprintf "line %d: unknown record type '%s'" (lineno + 1) other :: !errors)
          end)
        lines;
      if !errors <> [] then Error (String.concat "; " (List.rev !errors))
      else begin
        let entries = List.rev !entries in
        let canonical_seen = ref Util.StringSet.empty in
        let path_errors = ref [] in
        (* Each entry is resolved, read exactly once, hashed, and the
           validated snapshot (bytes + hash) is retained in the entry. *)
        let loaded : (module_entry * string * string * string) list ref = ref [] in
        List.iter
          (fun e ->
            match resolve_under_root repo_root e.file with
            | Error m -> path_errors := m :: !path_errors
            | Ok real ->
                if Util.StringSet.mem real !canonical_seen then
                  path_errors := Printf.sprintf "duplicate canonical file: '%s'" e.file :: !path_errors
                else begin
                  canonical_seen := Util.StringSet.add real !canonical_seen;
                  match Source_loader.load real with
                  | Error _ ->
                      path_errors := Printf.sprintf "cannot read source file '%s'" e.file :: !path_errors
                  | Ok src ->
                      let bytes = src.Source.bytes in
                      loaded := (e, real, bytes, Sha256.digest bytes) :: !loaded
                end)
          entries;
        if !path_errors <> [] then Error (String.concat "; " (List.rev !path_errors))
        else begin
          let loaded = List.rev !loaded in
          let entries =
            List.map
              (fun (e, real, bytes, hash) ->
                { e with real; source = bytes; source_hash = hash })
              loaded
          in
          let fp = fingerprint_of content !version entries in
          Ok { entries; version = !version; fingerprint = fp; manifest_content = content }
        end
      end

(* Return a copy of the manifest in which the entry with the given logical
   path has its source bytes replaced; the source hash and fingerprint are
   recomputed over the new bytes. Used by the fingerprint self-check. *)
let with_entry_source (m : t) (path : string list) (bytes : string) : t =
  let entries =
    List.map
      (fun e -> if e.path = path then { e with source = bytes; source_hash = Sha256.digest bytes } else e)
      m.entries
  in
  { m with entries; fingerprint = fingerprint_of m.manifest_content m.version entries }

let single ~(file : string) ~(path : string list) : t =
  let source, source_hash =
    match Source_loader.load file with
    | Ok s -> (s.Source.bytes, Sha256.digest s.Source.bytes)
    | Error _ -> ("", "")
  in
  {
    entries = [ { path; file; real = file; source; source_hash } ];
    version = None;
    fingerprint = "adhoc";
    manifest_content = "";
  }
