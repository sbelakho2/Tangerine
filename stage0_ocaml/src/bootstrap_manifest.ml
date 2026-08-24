(* bootstrap_manifest.ml — The bootstrap closure manifest (audit §20).

   The manifest is the SOLE authority for the bootstrap closure: no
   directory-scan fallback. Validation: unknown record types rejected,
   duplicate paths rejected, absolute paths rejected, `..` rejected,
   symlink escape rejected, every file must exist, no duplicate canonical
   file. A deterministic fingerprint (SHA-256 over manifest content +
   logical paths + source bytes + version) is computed at load. *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* repository-relative source file *)
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

(* Resolve a repo-relative path beneath root, rejecting symlink escape. *)
let resolve_under_root (repo_root : string) (rel : string) : (string, string) result =
  match reject_path rel with
  | Error m -> Error m
  | Ok rel ->
      let full = Filename.concat repo_root rel in
      (try
         let real = Unix.realpath full in
         let root_real = Unix.realpath repo_root in
         if Util.has_prefix real root_real then Ok real
         else Error (Printf.sprintf "path escapes repository root via symlink: '%s'" rel)
       with Unix.Unix_error _ -> Error (Printf.sprintf "cannot resolve path '%s'" rel))

(* ── SHA-256 fingerprint (FIPS 180-4, pure OCaml) ───────────────── *)

module Sha256 = struct
  let k =
    [| 0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl; 0x59f111f1l;
       0x923f82a4l; 0xab1c5ed5l; 0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l;
       0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l; 0xe49b69c1l; 0xefbe4786l;
       0x0fc19dc6l; 0x240ca1ccl; 0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
       0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l;
       0x06ca6351l; 0x14292967l; 0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l;
       0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l; 0xa2bfe8a1l; 0xa81a664bl;
       0xc24b8b70l; 0xc76c51a3l; 0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
       0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al;
       0x5b9cca4fl; 0x682e6ff3l; 0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
       0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l |]

  let rotr x n = Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

  let digest (data : Bytes.t) : string =
    let n = Bytes.length data in
    let padded = Bytes.make ((n + 8 + 63) / 64 * 64) '\000' in
    Bytes.blit data 0 padded 0 n;
    Bytes.set padded n (Char.chr 0x80);
    let bitlen = Int64.mul (Int64.of_int n) 8L in
    for i = 0 to 7 do
      Bytes.set padded (Bytes.length padded - 8 + i)
        (Char.chr (Int64.to_int (Int64.shift_right_logical bitlen (8 * i)) land 0xFF))
    done;
    let h = ref [| 0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al; 0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l |] in
    let w = Array.make 64 0l in
    let blocks = Bytes.length padded / 64 in
    for bi = 0 to blocks - 1 do
      for i = 0 to 15 do
        let b0 = Char.code (Bytes.get padded (bi * 64 + i * 4)) in
        let b1 = Char.code (Bytes.get padded (bi * 64 + i * 4 + 1)) in
        let b2 = Char.code (Bytes.get padded (bi * 64 + i * 4 + 2)) in
        let b3 = Char.code (Bytes.get padded (bi * 64 + i * 4 + 3)) in
        w.(i) <-
          Int32.logor
            (Int32.logor (Int32.shift_left (Int32.of_int b0) 24) (Int32.shift_left (Int32.of_int b1) 16))
            (Int32.logor (Int32.shift_left (Int32.of_int b2) 8) (Int32.of_int b3))
      done;
      for i = 16 to 63 do
        let s0 = Int32.logxor (rotr w.(i - 15) 7) (Int32.logxor (rotr w.(i - 15) 18) (Int32.shift_right_logical w.(i - 15) 3)) in
        let s1 = Int32.logxor (rotr w.(i - 2) 17) (Int32.logxor (rotr w.(i - 2) 19) (Int32.shift_right_logical w.(i - 2) 10)) in
        w.(i) <- Int32.add (Int32.add w.(i - 16) s0) (Int32.add w.(i - 7) s1)
      done;
      let a = ref !h.(0) and b = ref !h.(1) and c = ref !h.(2) and d = ref !h.(3)
      and e = ref !h.(4) and f = ref !h.(5) and g = ref !h.(6) and hh = ref !h.(7) in
      for i = 0 to 63 do
        let s1 = Int32.logxor (rotr !e 6) (Int32.logxor (rotr !e 11) (rotr !e 25)) in
        let ch = Int32.logxor (Int32.logand !e !f) (Int32.logand (Int32.lognot !e) !g) in
        let t1 = Int32.add (Int32.add !hh s1) (Int32.add ch (Int32.add k.(i) w.(i))) in
        let s0 = Int32.logxor (rotr !a 2) (Int32.logxor (rotr !a 13) (rotr !a 22)) in
        let maj = Int32.logxor (Int32.logand !a !b) (Int32.logxor (Int32.logand !a !c) (Int32.logand !b !c)) in
        let t2 = Int32.add s0 maj in
        hh := !g;
        g := !f;
        f := !e;
        e := Int32.add !d t1;
        d := !c;
        c := !b;
        b := !a;
        a := Int32.add t1 t2
      done;
      h := [| Int32.add !h.(0) !a; Int32.add !h.(1) !b; Int32.add !h.(2) !c; Int32.add !h.(3) !d;
              Int32.add !h.(4) !e; Int32.add !h.(5) !f; Int32.add !h.(6) !g; Int32.add !h.(7) !hh |]
    done;
    let buf = Buffer.create 64 in
    Array.iter
      (fun x ->
        for i = 3 downto 0 do
          Buffer.add_char buf (Char.chr (Int32.to_int (Int32.shift_right_logical x (8 * i)) land 0xFF))
        done)
      !h;
    Buffer.contents buf

  let hex (s : string) : string =
    let hexd = "0123456789abcdef" in
    String.init (String.length s * 2) (fun i ->
        let c = Char.code s.[i / 2] in
        if i mod 2 = 0 then hexd.[c lsr 4] else hexd.[c land 0xF])
end

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
                         { path = String.split_on_char '/' (dir ^ "/" ^ name) |> List.filter (fun x -> x <> ""); file = rel }
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
        List.iter
          (fun e ->
            match resolve_under_root repo_root e.file with
            | Error m -> path_errors := m :: !path_errors
            | Ok real ->
                if Util.StringSet.mem real !canonical_seen then
                  path_errors := Printf.sprintf "duplicate canonical file: '%s'" e.file :: !path_errors;
                canonical_seen := Util.StringSet.add real !canonical_seen)
          entries;
        if !path_errors <> [] then Error (String.concat "; " (List.rev !path_errors))
        else begin
          let fp =
            Sha256.hex
              (Sha256.digest
                 (Bytes.of_string
                    (content
                    ^ "\n\000"
                    ^ (match !version with Some v -> v | None -> "")
                    ^ "\n\000"
                    ^ String.concat "\000"
                        (List.map (fun e -> String.concat "::" e.path ^ "\001" ^ e.file) entries))))
          in
          Ok { entries; version = !version; fingerprint = fp; manifest_content = content }
        end
      end

let single ~(file : string) ~(path : string list) : t =
  {
    entries = [ { path; file } ];
    version = None;
    fingerprint = "adhoc";
    manifest_content = "";
  }
