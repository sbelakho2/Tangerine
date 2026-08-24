(* test_util.ml — Tiny internal assertion module for the stage0 front-end
   test tree.

   run prints one line per test ("name: PASS" / "name: FAIL: reason"),
   counts the outcomes, and exits nonzero when any test fails. *)

let passes = ref 0
let failures = ref 0

let counts () : int * int = (!passes, !failures)

let fail (msg : string) = failwith msg

let assert_true (b : bool) (msg : string) : unit =
  if not b then fail ("assert_true failed: " ^ msg)

let assert_equal (label : string) (expected : string) (actual : string) : unit =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let assert_result_ok (r : ('a, string) result) (msg : string) : 'a =
  match r with
  | Ok v -> v
  | Error e -> fail (msg ^ ": unexpected error: " ^ e)

let assert_result_err (r : ('a, string) result) (msg : string) : string =
  match r with
  | Ok _ -> fail (msg ^ ": expected an error, got Ok")
  | Error e -> e

let run (tests : (string * (unit -> unit)) list) : unit =
  List.iter
    (fun (name, f) ->
      try
        f ();
        incr passes;
        Printf.printf "%s: PASS\n" name
      with exn ->
        incr failures;
        Printf.printf "%s: FAIL: %s\n" name (Printexc.to_string exn))
    tests;
  if !failures > 0 then exit 1
