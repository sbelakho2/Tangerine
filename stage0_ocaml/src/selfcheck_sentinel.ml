(* selfcheck_sentinel.ml — the ONE machine-readable selfcheck success
   sentinel (audit P0-4).

   The health harness verifies every selfcheck executable by EXACT line,
   never by a loose `grep PASS` (error descriptions legitimately contain
   the word "PASS"): an executable that exits 0 must print exactly one
   line

     TANGERINE_SELFCHECK_PASS name=<selfcheck-name> version=1

   on its stdout/stderr.  A broken selfcheck that exits early with 0 but
   prints nothing therefore fails closed instead of counting as green.
   scripts/check_selfcheck_sentinel.sh is the verifier; its own
   meta-test (scripts/test_selfcheck_sentinel.sh) proves the reject/pass
   behaviour against synthetic outputs. *)

let marker_prefix = "TANGERINE_SELFCHECK_PASS"

let marker (name : string) : string =
  Printf.sprintf "%s name=%s version=1" marker_prefix name

let emit (name : string) : unit = print_endline (marker name)

(* Success exit with the sentinel: every exit-0 path of a selfcheck goes
   through this so exit code and evidence can never drift apart. *)
let emit_and_exit (name : string) : 'a =
  emit name;
  exit 0
