(* tg_bootstrap_accepted.ml — accepted bootstrap-evidence loader self-check
   (audit items 18-20).

   Exercises Bootstrap_accepted.load on synthetic repos:
     (a) a valid record (nonzero debt) is accepted with its own facts;
     (b) a valid 0/0/0 record (the intended final accepted baseline) is
         accepted — the old `total <= 0` malformed rule is gone;
     (c) a SHA-256 hash mismatch is rejected (fail-closed);
     (d) the historical 32-hex MD5-shaped pointer is rejected;
     (e) a missing accepted.json is rejected (fail-closed);
     (f) a malformed pointer (missing evidence_sha256) is rejected;
     (g) a pointer to a missing record is rejected;
     (h) total <> primary + secondary is rejected;
     (i) missing / non-numeric debt facts are rejected;
     (j) negative debt facts are rejected;
     (k) TG_BOOTSTRAP_ACCEPTED_OVERRIDE=1 restores the hardcoded
         fallback for development (and only "1" enables it);
     (l) the override never bypasses a valid accepted record. *)

let failures = ref 0

let fail fmt =
  Printf.ksprintf
    (fun s ->
      incr failures;
      Printf.printf "  FAIL: %s\n" s)
    fmt

let pass fmt = Printf.ksprintf (fun s -> Printf.printf "  PASS: %s\n" s) fmt

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let rec mkdir_p (path : string) : unit =
  if path <> "" && path <> "/" && not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let dirs : string list ref = ref []

let tmp_repo () : string =
  let d = Filename.temp_file "tg_bootstrap_accepted" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  let repo = Filename.concat d "repo" in
  mkdir_p (Filename.concat repo "bootstrap/evidence/ocaml");
  dirs := d :: !dirs;
  repo

let write_pointer (repo : string) (record_name : string) (sha : string) : unit =
  write_file
    (Filename.concat repo "bootstrap/evidence/ocaml/accepted.json")
    (Printf.sprintf
       "{ \"evidence_record\": \"%s\", \"evidence_sha256\": \"%s\", \"approved_by\": \"test\", \
        \"approval_reason\": \"test\" }\n"
       record_name sha)

let write_record (repo : string) (record_name : string) (content : string) : unit =
  write_file (Filename.concat repo ("bootstrap/evidence/ocaml/" ^ record_name)) content

(* A distinctive fallback marker: the loader must return exactly the
   hardcoded report it was given. *)
let hardcoded : Debt_report.t =
  Debt_report.{ buckets = List.map (fun c -> (c, 0)) Debt_report.categories; total = 123; primaries = 45; secondaries = 78 }

let load (repo : string) : (Bootstrap_accepted.t, string) result =
  Bootstrap_accepted.load ~repo_root:repo ~hardcoded

let expects_error (name : string) (result : (Bootstrap_accepted.t, string) result)
    (needle : string) : unit =
  match result with
  | Ok _ -> fail "%s: accepted (expected rejection)" name
  | Error m ->
      if needle = "" || Util.find_key_value_pos m needle <> None then
        pass "%s: rejected — %s" name m
      else fail "%s: rejected with unexpected message: %s" name m

let expect_record (name : string) (result : (Bootstrap_accepted.t, string) result)
    ~(record : string) ~(total : int) ~(primaries : int) ~(secondaries : int)
    ~(bytes : string) : unit =
  match result with
  | Error m -> fail "%s: rejected: %s" name m
  | Ok t -> (
      match t.Bootstrap_accepted.source with
      | Bootstrap_accepted.Accepted_record r when r = record ->
          if
            t.Bootstrap_accepted.baseline.Debt_report.total = total
            && t.Bootstrap_accepted.baseline.Debt_report.primaries = primaries
            && t.Bootstrap_accepted.baseline.Debt_report.secondaries = secondaries
          then pass "%s: accepted %s (%s)" name record bytes
          else
            fail "%s: accepted %s with wrong facts total %d primary %d secondary %d" name record
              t.Bootstrap_accepted.baseline.Debt_report.total
              t.Bootstrap_accepted.baseline.Debt_report.primaries
              t.Bootstrap_accepted.baseline.Debt_report.secondaries
      | _ -> fail "%s: accepted but not from the record" name)

let unchanged_baseline (_name : string) (t : Bootstrap_accepted.t) : bool =
  t.Bootstrap_accepted.baseline.Debt_report.total = hardcoded.Debt_report.total
  && t.Bootstrap_accepted.baseline.Debt_report.primaries = hardcoded.Debt_report.primaries
  && t.Bootstrap_accepted.baseline.Debt_report.secondaries = hardcoded.Debt_report.secondaries

let () =
  Printf.printf "TG BOOTSTRAP ACCEPTED-EVIDENCE SELF-CHECK\n";
  (* The override must be off for the fail-closed cases, regardless of
     the ambient environment. *)
  let saved_override = Sys.getenv_opt Bootstrap_accepted.override_env in
  Unix.putenv Bootstrap_accepted.override_env "";
  (* (a) valid nonzero record *)
  let repo_a = tmp_repo () in
  let rec_a = "aaaaaaa_1.json" in
  let content_a = {|{ "bootstrap_check": { "debt_total": 12, "debt_primary": 5, "debt_secondary": 7 } }|}
  in
  let sha_a = Sha256.digest content_a in
  write_record repo_a rec_a content_a;
  write_pointer repo_a rec_a sha_a;
  expect_record "valid nonzero record" (load repo_a) ~record:rec_a ~total:12 ~primaries:5
    ~secondaries:7 ~bytes:sha_a;
  (* (b) valid zero-debt record — the intended final baseline *)
  let repo_b = tmp_repo () in
  let rec_b = "bbbbbbb_2.json" in
  let content_b = {|{ "debt_total": 0, "debt_primary": 0, "debt_secondary": 0 }|} in
  let sha_b = Sha256.digest content_b in
  write_record repo_b rec_b content_b;
  write_pointer repo_b rec_b sha_b;
  expect_record "zero-debt record accepted" (load repo_b) ~record:rec_b ~total:0 ~primaries:0
    ~secondaries:0 ~bytes:sha_b;
  (* (c) SHA-256 mismatch *)
  let repo_c = tmp_repo () in
  let rec_c = "ccccccc_3.json" in
  write_record repo_c rec_c content_a;
  write_pointer repo_c rec_c (Sha256.digest "tampered");
  expects_error "SHA-256 mismatch" (load repo_c) "mismatch";
  (* (d) the historical MD5-shaped pointer *)
  let repo_d = tmp_repo () in
  write_record repo_d "ddddddd_4.json" content_a;
  write_pointer repo_d "ddddddd_4.json" "7c4d1f1adbea5c735f621c22a5e47118";
  expects_error "32-hex MD5-shaped pointer" (load repo_d) "64-character";
  (* (e) missing accepted.json *)
  let repo_e = tmp_repo () in
  expects_error "missing accepted.json" (load repo_e) "missing or unreadable";
  (* (f) malformed pointer: evidence_sha256 absent *)
  let repo_f = tmp_repo () in
  write_file
    (Filename.concat repo_f "bootstrap/evidence/ocaml/accepted.json")
    "{ \"evidence_record\": \"fffffff_5.json\" }\n";
  expects_error "malformed pointer" (load repo_f) "evidence_sha256";
  (* (g) pointer to a missing record *)
  let repo_g = tmp_repo () in
  write_pointer repo_g "missing_record.json" (Sha256.digest "nothing");
  expects_error "pointer to missing record" (load repo_g) "missing or unreadable";
  (* (h) total <> primary + secondary *)
  let repo_h = tmp_repo () in
  let rec_h = "hhhhhhh_6.json" in
  let content_h = {|{ "debt_total": 10, "debt_primary": 3, "debt_secondary": 3 }|} in
  write_record repo_h rec_h content_h;
  write_pointer repo_h rec_h (Sha256.digest content_h);
  expects_error "total <> primary + secondary" (load repo_h) "<>";
  (* (i) non-numeric and missing debt facts *)
  let repo_i = tmp_repo () in
  let rec_i = "iiiiiii_7.json" in
  let content_i = {|{ "debt_total": "many", "debt_primary": 3, "debt_secondary": 3 }|} in
  write_record repo_i rec_i content_i;
  write_pointer repo_i rec_i (Sha256.digest content_i);
  expects_error "non-numeric debt fact" (load repo_i) "numeric";
  let repo_i2 = tmp_repo () in
  let rec_i2 = "iiiiiii_8.json" in
  let content_i2 = {|{ "debt_total": 6, "debt_primary": 3 }|} in
  write_record repo_i2 rec_i2 content_i2;
  write_pointer repo_i2 rec_i2 (Sha256.digest content_i2);
  expects_error "missing debt fact" (load repo_i2) "debt_secondary";
  (* (j) negative debt facts (consistent but negative) *)
  let repo_j = tmp_repo () in
  let rec_j = "jjjjjjj_9.json" in
  let content_j = {|{ "debt_total": -1, "debt_primary": 0, "debt_secondary": -1 }|} in
  write_record repo_j rec_j content_j;
  write_pointer repo_j rec_j (Sha256.digest content_j);
  expects_error "negative debt fact" (load repo_j) "non-negative";
  (* (k) the documented override restores the hardcoded fallback *)
  Unix.putenv Bootstrap_accepted.override_env "1";
  (match load repo_e with
  | Ok t -> (
      match t.Bootstrap_accepted.source with
      | Bootstrap_accepted.Hardcoded_fallback reason ->
          if unchanged_baseline "override fallback" t && reason <> "" then
            pass "override=1: fallback to the hardcoded baseline (%s)" reason
          else fail "override=1: fallback baseline differs from the hardcoded report"
      | Bootstrap_accepted.Accepted_record _ ->
          fail "override=1: loaded a record where none exists")
  | Error m -> fail "override=1: still rejected: %s" m);
  (* the override accepts only the literal "1" *)
  Unix.putenv Bootstrap_accepted.override_env "0";
  expects_error "override=0 does not enable" (load repo_e) "fail-closed";
  Unix.putenv Bootstrap_accepted.override_env "true";
  expects_error "override=true does not enable" (load repo_e) "fail-closed";
  (* (l) the override never bypasses a valid accepted record *)
  Unix.putenv Bootstrap_accepted.override_env "1";
  (match load repo_b with
  | Ok { Bootstrap_accepted.source = Bootstrap_accepted.Accepted_record _; _ } ->
      pass "override=1 does not bypass a valid zero-debt record"
  | Ok _ -> fail "override=1: used the fallback despite a valid record"
  | Error m -> fail "override=1: valid record rejected: %s" m);
  Unix.putenv Bootstrap_accepted.override_env "";
  (* (m) the REAL accepted pointer in the checked-out repo must verify
     (the same invariant the gate and the health lane rely on). *)
  (match load ".." with
  | Ok
      {
        Bootstrap_accepted.baseline = b;
        source = Bootstrap_accepted.Accepted_record r;
      } ->
      pass "real accepted pointer verifies: %s total %d primary %d secondary %d" r
        b.Debt_report.total b.Debt_report.primaries b.Debt_report.secondaries
  | Ok _ -> fail "real accepted pointer fell back to the hardcoded baseline"
  | Error m -> fail "real accepted pointer rejected: %s" m);
  (match saved_override with
  | Some v -> Unix.putenv Bootstrap_accepted.override_env v
  | None -> ());
  List.iter
    (fun d ->
      ignore (Sys.command ("rm -rf " ^ Filename.quote d)))
    !dirs;
  if !failures > 0 then begin
    Printf.printf "TG BOOTSTRAP ACCEPTED-EVIDENCE SELF-CHECK: FAIL (%d)\n" !failures;
    exit 1
  end;
  Printf.printf "TG BOOTSTRAP ACCEPTED-EVIDENCE SELF-CHECK: PASS\n"
