(* bootstrap_accepted.ml — accepted bootstrap-evidence pointer loader.

   bootstrap/evidence/ocaml/accepted.json is the SINGLE accepted
   baseline pointer (re-audit item 30): evidence_record + evidence_sha256
   + approval, with NO copied measurement fields.  This module loads the
   pointer, verifies the record's REAL SHA-256 (64 lowercase hex chars,
   FIPS 180-4, via the in-repo Sha256 module — the OCaml stdlib Digest
   module is MD5 and must never be used for evidence integrity), loads
   the generated evidence record and reads the debt facts FROM THAT
   RECORD.  The class of error where the pointer and the record describe
   different builds is impossible.

   Debt facts are valid when:
     total >= 0, primary >= 0, secondary >= 0,
     total = primary + secondary
   so an accepted 0/0/0 record (the intended final baseline) is valid
   and promotable.  Missing, negative, non-numeric or inconsistent
   facts are malformed.

   Fail-closed policy (audit items 18-20): a missing or malformed
   pointer, a pointer whose record is missing, a hash mismatch, and
   malformed/inconsistent debt facts are HARD bootstrap-infrastructure
   errors.  The ONLY escape is the explicitly documented developer
   override TG_BOOTSTRAP_ACCEPTED_OVERRIDE=1, which restores the old
   warning + hardcoded-baseline fallback for development. *)

let override_env = "TG_BOOTSTRAP_ACCEPTED_OVERRIDE"

type source =
  | Accepted_record of string  (* record file name *)
  | Hardcoded_fallback of string  (* the infrastructure error that forced it *)

type t = { baseline : Debt_report.t; source : source }

(* ── minimal JSON scalar reader (the pinned pointer/record only) ─── *)

let is_space = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

(* Position just after the ':' of `"key":`, or None.  The key must be a
   quoted string followed (after whitespace) by a colon, so an
   occurrence of the key text inside an unrelated string value cannot
   match. *)
let key_colon_pos (s : string) (key : string) : int option =
  let pat = "\"" ^ key ^ "\"" in
  let lp = String.length pat and n = String.length s in
  let rec go i =
    if i + lp > n then None
    else if String.sub s i lp = pat then begin
      let j = ref (i + lp) in
      while !j < n && is_space s.[!j] do
        incr j
      done;
      if !j < n && s.[!j] = ':' then Some (!j + 1) else go (i + 1)
    end
    else go (i + 1)
  in
  go 0

let json_string (s : string) (key : string) : (string, string) result =
  match key_colon_pos s key with
  | None -> Error (Printf.sprintf "missing string field \"%s\"" key)
  | Some pos ->
      let n = String.length s in
      let i = ref pos in
      while !i < n && is_space s.[!i] do
        incr i
      done;
      if !i >= n || s.[!i] <> '"' then
        Error (Printf.sprintf "field \"%s\" is not a JSON string" key)
      else begin
        let start = !i + 1 in
        match String.index_from_opt s start '"' with
        | None -> Error (Printf.sprintf "field \"%s\" has an unterminated JSON string" key)
        | Some stop -> Ok (String.sub s start (stop - start))
      end

let json_int (s : string) (key : string) : (int, string) result =
  match key_colon_pos s key with
  | None -> Error (Printf.sprintf "missing integer field \"%s\"" key)
  | Some pos ->
      let n = String.length s in
      let i = ref pos in
      while !i < n && is_space s.[!i] do
        incr i
      done;
      let start = !i in
      if !i < n && s.[!i] = '-' then incr i;
      let digits_start = !i in
      while !i < n && s.[!i] >= '0' && s.[!i] <= '9' do
        incr i
      done;
      if !i = digits_start then
        Error (Printf.sprintf "field \"%s\" is missing a numeric value" key)
      else if !i < n && (not (is_space s.[!i])) && s.[!i] <> ',' && s.[!i] <> '}' then
        Error (Printf.sprintf "field \"%s\" has a non-numeric value" key)
      else
        match int_of_string_opt (String.sub s start (!i - start)) with
        | None -> Error (Printf.sprintf "field \"%s\" is out of range" key)
        | Some v -> Ok v

let is_lower_hex (c : char) : bool =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

(* The pointer's evidence_sha256 must be a canonical 64-character
   lowercase hex SHA-256 (the old MD5-shaped 32-hex pointer is
   rejected). *)
let is_sha256_hex (s : string) : bool =
  String.length s = 64 && String.for_all is_lower_hex s

let read_file (path : string) : (string, string) result =
  match In_channel.open_bin path with
  | exception _ -> Error (Printf.sprintf "cannot read %s" path)
  | ic ->
      let content = In_channel.input_all ic in
      close_in ic;
      Ok content

let pointer_rel = "bootstrap/evidence/ocaml/accepted.json"
let record_dir_rel = "bootstrap/evidence/ocaml"

(* Load and fully verify the pointer + record.  Returns the debt
   baseline and the accepted record's file name, or a precise
   infrastructure error. *)
let load_pointer (repo_root : string) : (Debt_report.t * string, string) result =
  let pointer_path = Filename.concat repo_root pointer_rel in
  match read_file pointer_path with
  | Error _ ->
      Error (Printf.sprintf "accepted bootstrap pointer %s is missing or unreadable" pointer_rel)
  | Ok content -> (
      match (json_string content "evidence_record", json_string content "evidence_sha256") with
      | Error e, _ | _, Error e ->
          Error (Printf.sprintf "accepted bootstrap pointer %s: %s" pointer_rel e)
      | Ok record_name, Ok expected_sha ->
          if record_name = "" then
            Error (Printf.sprintf "accepted bootstrap pointer %s: evidence_record is empty" pointer_rel)
          else if not (is_sha256_hex expected_sha) then
            Error
              (Printf.sprintf
                 "accepted bootstrap pointer %s: evidence_sha256 %S is not a 64-character \
                  lowercase hex SHA-256 (an OCaml stdlib Digest/MD5 32-hex value is not a \
                  valid evidence hash)"
                 pointer_rel expected_sha)
          else
            let record_path =
              Filename.concat repo_root (Filename.concat record_dir_rel record_name)
            in
            match read_file record_path with
            | Error _ ->
                Error
                  (Printf.sprintf
                     "accepted bootstrap pointer %s: evidence record %s is missing or unreadable"
                     pointer_rel record_name)
            | Ok rec_content -> (
                let actual_sha = Sha256.digest rec_content in
                if actual_sha <> expected_sha then
                  Error
                    (Printf.sprintf
                       "accepted bootstrap pointer %s: evidence record %s SHA-256 mismatch \
                        (record %s, pointer %s)"
                       pointer_rel record_name actual_sha expected_sha)
                else
                  match
                    ( json_int rec_content "debt_total",
                      json_int rec_content "debt_primary",
                      json_int rec_content "debt_secondary" )
                  with
                  | Error e, _, _ | _, Error e, _ | _, _, Error e ->
                      Error
                        (Printf.sprintf "evidence record %s: malformed debt facts: %s" record_name e)
                  | Ok total, Ok primaries, Ok secondaries ->
                      if total < 0 || primaries < 0 || secondaries < 0 then
                        Error
                          (Printf.sprintf
                             "evidence record %s: debt facts must be non-negative (total %d, \
                              primary %d, secondary %d)"
                             record_name total primaries secondaries)
                      else if total <> primaries + secondaries then
                        Error
                          (Printf.sprintf
                             "evidence record %s: debt_total %d <> debt_primary %d + \
                              debt_secondary %d (inconsistent record)"
                             record_name total primaries secondaries)
                      else
                        Ok
                          ( {
                              Debt_report.buckets =
                                List.map (fun c -> (c, 0)) Debt_report.categories;
                              total;
                              primaries;
                              secondaries;
                            },
                            record_name )))

let override_enabled () : bool =
  match Sys.getenv_opt override_env with Some v -> v = "1" | None -> false

(* The gate-facing entry: fail-closed on any infrastructure error, with
   the single documented development override restoring the hardcoded
   fallback (the returned source records which path was taken). *)
let load ~(repo_root : string) ~(hardcoded : Debt_report.t) : (t, string) result =
  match load_pointer repo_root with
  | Ok (baseline, record_name) -> Ok { baseline; source = Accepted_record record_name }
  | Error reason ->
      if override_enabled () then
        Ok { baseline = hardcoded; source = Hardcoded_fallback reason }
      else
        Error
          (Printf.sprintf
             "%s (fail-closed: refusing to fall back to the hardcoded baseline; set %s=1 to \
              restore the documented development fallback)"
             reason override_env)
