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

   Containment (P1-4): evidence_record must name ONE file directly in
   bootstrap/evidence/ocaml.  It must be a bare file name (no directory
   component, so "../x.json", "/tmp/x.json" and "foo/x.json" are all
   rejected), not empty, not "." or "..", must end in ".json" and must
   contain no control bytes.  The final path is canonicalized with
   Unix.realpath and its parent compared with the canonical evidence
   directory, so a symlink planted in the evidence directory cannot
   redirect the read outside it.  Every failure is a precise
   fail-closed error.

   Canonical pointer JSON (P1-4): the pointer is parsed by a
   deliberately narrow recursive-descent reader (no substring
   scanning): exactly the four expected keys, each exactly once
   (duplicate keys rejected, so "evidence_record" appearing twice is
   never ambiguous), unknown keys rejected, string values literal (no
   escape sequences, no control bytes) and no content after the closing
   object.  The accepted grammar is documented at parse_pointer.

   The generated EVIDENCE RECORD is not the trust pointer: its
   integrity is pinned by evidence_sha256 and its debt facts keep the
   minimal scalar reader (hardened to reject a duplicated debt key).
   Records are produced by the in-repo tooling; a full canonical parse
   of the large measurement document is out of scope here.

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

(* ── canonical JSON reader for the trust pointer ────────────────── *)

let is_space = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let skip_ws (s : string) (i : int) : int =
  let n = String.length s in
  let j = ref i in
  while !j < n && is_space s.[!j] do
    incr j
  done;
  !j

(* A canonical JSON string: '"' literal '"' where literal is any byte
   except '"', '\\' and the C0 control bytes.  The literal is returned
   verbatim; no escape sequence is decoded or accepted, so the bytes
   between the quotes are the value. *)
let parse_canonical_string (s : string) (i : int) : (string * int, string) result =
  let n = String.length s in
  if i >= n || s.[i] <> '"' then Error "expected a quoted string"
  else begin
    let j = ref (i + 1) in
    let start = !j in
    let err = ref None in
    while !err = None && !j < n && s.[!j] <> '"' do
      let c = s.[!j] in
      if c = '\\' then
        err := Some "escape sequences are not permitted (the pointer format is literal-only)"
      else if Char.code c < 0x20 then
        err := Some "control bytes are not permitted in a canonical string"
      else incr j
    done;
    match !err with
    | Some e -> Error e
    | None ->
        if !j >= n then Error "unterminated string"
        else Ok (String.sub s start (!j - start), !j + 1)
  end

let pointer_keys =
  [ "evidence_record"; "evidence_sha256"; "approved_by"; "approval_reason" ]

(* ACCEPTED POINTER GRAMMAR — the only syntax this module accepts:
     document := ws '{' ws members? ws '}' ws EOF
     members  := pair (ws ',' ws pair)*
     pair     := string ws ':' ws string
     string   := '"' literal '"', literal has no '"', no '\\', no C0 byte
     keys     := exactly pointer_keys, each exactly once
   Single interpretation: keys are unique (duplicates are rejected, so
   no key can shadow or silently override another), the key set is
   exactly the expected one (unknown keys are rejected), string values
   carry no escape sequences (so a value has no alternative decoding —
   in particular "\u0061" or "\"" cannot be smuggled in), and the
   document is exactly one object followed by whitespace only (so
   trailing content cannot add or change fields).  Every accepted byte
   string therefore has exactly one parse tree and one (record name,
   sha, approval) interpretation. *)
let parse_pointer (content : string) : ((string * string) list, string) result =
  let n = String.length content in
  let rec finish (i : int) (acc : (string * string) list) :
      ((string * string) list, string) result =
    match List.find_opt (fun k -> not (List.mem_assoc k acc)) pointer_keys with
    | Some k -> Error (Printf.sprintf "missing required key %S" k)
    | None ->
        let i = skip_ws content i in
        if i < n then Error "trailing garbage after the JSON object"
        else Ok (List.rev acc)
  and members (after_comma : bool) (i : int) (acc : (string * string) list) :
      ((string * string) list, string) result =
    let i = skip_ws content i in
    if i < n && content.[i] = '}' then
      if after_comma then Error "trailing comma before '}'"
      else finish (i + 1) acc
    else if i >= n then Error "unterminated JSON object (expected a key)"
    else
      match parse_canonical_string content i with
      | Error e -> Error (Printf.sprintf "object key: %s" e)
      | Ok (key, i) -> (
          let i = skip_ws content i in
          if i >= n || content.[i] <> ':' then
            Error (Printf.sprintf "key %S is not followed by ':'" key)
          else
            let i = skip_ws content (i + 1) in
            match parse_canonical_string content i with
            | Error e -> Error (Printf.sprintf "value of key %S: %s" key e)
            | Ok (value, i) ->
                if List.mem_assoc key acc then
                  Error (Printf.sprintf "duplicate key %S (ambiguous pointer)" key)
                else if not (List.mem key pointer_keys) then
                  Error (Printf.sprintf "unknown key %S" key)
                else
                  let acc = (key, value) :: acc in
                  let i = skip_ws content i in
                  if i >= n then Error "unterminated JSON object (expected ',' or '}')"
                  else if content.[i] = ',' then members true (i + 1) acc
                  else if content.[i] = '}' then finish (i + 1) acc
                  else
                    Error
                      (Printf.sprintf "expected ',' or '}' after the value of key %S" key))
  in
  let i = skip_ws content 0 in
  if i >= n || content.[i] <> '{' then Error "pointer is not a JSON object"
  else members false (i + 1) []

(* ── minimal scalar reader for the EVIDENCE RECORD's debt facts ───
   The record is a large generated document; its integrity is pinned by
   evidence_sha256 above.  A duplicated debt key is rejected so a
   crafted record cannot present two different facts. *)

(* All positions just after the ':' of `"key":`.  The key must be a
   quoted string followed (after whitespace) by a colon. *)
let key_colon_positions (s : string) (key : string) : int list =
  let pat = "\"" ^ key ^ "\"" in
  let lp = String.length pat and n = String.length s in
  let rec go i acc =
    if i + lp > n then List.rev acc
    else if String.sub s i lp = pat then begin
      let j = ref (i + lp) in
      while !j < n && is_space s.[!j] do
        incr j
      done;
      if !j < n && s.[!j] = ':' then go (i + lp) (!j + 1 :: acc) else go (i + 1) acc
    end
    else go (i + 1) acc
  in
  go 0 []

let json_int (s : string) (key : string) : (int, string) result =
  match key_colon_positions s key with
  | [] -> Error (Printf.sprintf "missing integer field \"%s\"" key)
  | _ :: _ :: _ ->
      Error (Printf.sprintf "duplicate integer field \"%s\" (ambiguous record)" key)
  | [ pos ] ->
      let n = String.length s in
      let i = ref (skip_ws s pos) in
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

(* Containment rule: evidence_record names ONE file directly in
   bootstrap/evidence/ocaml.  Empty names, "." / "..", any name with a
   directory component ("../x.json", "/tmp/x.json", "foo/x.json"), any
   name without the .json suffix and any control byte are rejected
   before the filesystem is touched. *)
let check_record_name (record_name : string) : (unit, string) result =
  if record_name = "" then Error "evidence_record is empty"
  else if record_name = "." || record_name = ".." then
    Error (Printf.sprintf "evidence_record %S is a path traversal component" record_name)
  else if Filename.basename record_name <> record_name then
    Error
      (Printf.sprintf
         "evidence_record %S must be a bare file name with no directory components (path \
          traversal rejected)"
         record_name)
  else if record_name = ".json" || not (Filename.check_suffix record_name ".json") then
    Error (Printf.sprintf "evidence_record %S must be a file name ending in .json" record_name)
  else if String.exists (fun c -> Char.code c < 0x20 || Char.code c = 0x7f) record_name then
    Error (Printf.sprintf "evidence_record %S contains a control byte (rejected)" record_name)
  else Ok ()

(* The canonical bootstrap/evidence/ocaml directory.  Unix.realpath
   resolves every symlink in the checkout path (e.g. /tmp is
   /private/tmp on macOS), so the containment comparison below is
   between two canonical paths. *)
let canonical_evidence_dir ~(repo_root : string) : (string, string) result =
  match Unix.realpath (Filename.concat repo_root record_dir_rel) with
  | canon -> Ok canon
  | exception _ ->
      Error
        (Printf.sprintf "evidence directory %s is missing or unreadable" record_dir_rel)

(* Load and fully verify the pointer + record.  Returns the debt
   baseline and the accepted record's file name, or a precise
   infrastructure error. *)
let load_pointer (repo_root : string) : (Debt_report.t * string, string) result =
  let pointer_path = Filename.concat repo_root pointer_rel in
  match read_file pointer_path with
  | Error _ ->
      Error (Printf.sprintf "accepted bootstrap pointer %s is missing or unreadable" pointer_rel)
  | Ok content -> (
      match parse_pointer content with
      | Error e -> Error (Printf.sprintf "accepted bootstrap pointer %s: %s" pointer_rel e)
      | Ok fields ->
          let record_name = List.assoc "evidence_record" fields in
          let expected_sha = List.assoc "evidence_sha256" fields in
          let fail e = Error (Printf.sprintf "accepted bootstrap pointer %s: %s" pointer_rel e) in
          (match check_record_name record_name with
          | Error e -> fail e
          | Ok () ->
              if not (is_sha256_hex expected_sha) then
                fail
                  (Printf.sprintf
                     "evidence_sha256 %S is not a 64-character lowercase hex SHA-256 (an OCaml \
                      stdlib Digest/MD5 32-hex value is not a valid evidence hash)"
                     expected_sha)
              else
                match canonical_evidence_dir ~repo_root with
                | Error e -> fail e
                | Ok canon_dir -> (
                    let record_path =
                      Filename.concat repo_root (Filename.concat record_dir_rel record_name)
                    in
                    match Unix.realpath record_path with
                    | exception _ ->
                        fail
                          (Printf.sprintf
                             "evidence record %s is missing or unreadable" record_name)
                    | canon_record ->
                        if Filename.dirname canon_record <> canon_dir then
                          fail
                            (Printf.sprintf
                               "evidence record %s resolves to %s, outside the canonical \
                                evidence directory %s (path escape rejected)"
                               record_name canon_record canon_dir)
                        else
                          match read_file canon_record with
                          | Error _ ->
                              fail
                                (Printf.sprintf
                                   "evidence record %s is missing or unreadable" record_name)
                          | Ok rec_content -> (
                              let actual_sha = Sha256.digest rec_content in
                              if actual_sha <> expected_sha then
                                fail
                                  (Printf.sprintf
                                     "evidence record %s SHA-256 mismatch (record %s, pointer \
                                      %s)"
                                     record_name actual_sha expected_sha)
                              else
                                match
                                  ( json_int rec_content "debt_total",
                                    json_int rec_content "debt_primary",
                                    json_int rec_content "debt_secondary" )
                                with
                                | Error e, _, _ | _, Error e, _ | _, _, Error e ->
                                    Error
                                      (Printf.sprintf
                                         "evidence record %s: malformed debt facts: %s"
                                         record_name e)
                                | Ok total, Ok primaries, Ok secondaries ->
                                    if total < 0 || primaries < 0 || secondaries < 0 then
                                      Error
                                        (Printf.sprintf
                                           "evidence record %s: debt facts must be non-negative \
                                            (total %d, primary %d, secondary %d)"
                                           record_name total primaries secondaries)
                                    else if total <> primaries + secondaries then
                                      Error
                                        (Printf.sprintf
                                           "evidence record %s: debt_total %d <> debt_primary %d \
                                            + debt_secondary %d (inconsistent record)"
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
                                          record_name )))))

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
