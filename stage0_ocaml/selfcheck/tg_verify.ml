let let_param (ty : Type_repr.t) : Type_repr.param_type = { Type_repr.pt_convention = Access_effect.Let; pt_type = ty }
(* tg_verify.ml — mir_verify param-offset mutation self-check (audit §36).

   The local convention (seed_mir.ml): local _0 is the return slot;
   parameter i occupies local _(i+1).  These focused checks prove the
   verifier's param-slot offset check is live:

   m1: a function with a param of type String and return Int must PASS
       when the param slot is local _1 typed String (the old code
       compared param 0 against the return slot _0 and rejected it);
   m2: the same function must FAIL (with the param-offset error) when
       the param slot _1 is typed Int;
   m3: a param Int / slot _1 Int / return Int function must PASS (the
       check compares against slot i+1, not slot i). *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

let contains_sub (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else begin
    let found = ref false in
    (try
       for i = 0 to hl - nl do
         if not !found && String.sub haystack i nl = needle then found := true
       done
     with Invalid_argument _ -> ());
    !found
  end

let i64_int = Type_repr.Int Type_repr.Int

(* One-parameter function returning Int: locals.(0) is the return slot
   (Int), locals.(1) is parameter 0's slot. *)
let mk_fn (param_ty : Type_repr.t) (slot1_ty : Type_repr.t) : Seed_mir.function_ =
  {
    Seed_mir.name = "f";
    instance = Instance_id.make ~callable:(Ids.Callable_id.make 0) ~type_args:[||];
    params = [| let_param(param_ty) |];
    locals = [| i64_int; slot1_ty |];
    blocks =
      [|
        {
          Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign
                ( { Seed_mir.root = Seed_mir.Local 0; projections = [] },
                  Seed_mir.Use
                    (Seed_mir.Constant
                       (Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true 42L))) );
            ];
          terminator = Seed_mir.Ret;
        };
      |];
    entry = 0;
  }

let prog_of (f : Seed_mir.function_) : Seed_mir.program =
  { Seed_mir.functions = [| f |]; statics = [||]; types = [||] }

(* A function whose blocks array violates the id invariant: ids {0, 2}
   in a 2-element array (gap — the array position != id). *)
let mk_bad_blocks_fn () : Seed_mir.function_ =
  {
    Seed_mir.name = "bad_blocks";
    instance = Instance_id.make ~callable:(Ids.Callable_id.make 1) ~type_args:[||];
    params = [||];
    locals = [| Type_repr.Unit |];
    blocks =
      [|
        { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Ret };
        { Seed_mir.id = 2; statements = []; terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

let () =
  (* m1: param String / slot _1 String / return Int -> PASS *)
  (match Mir_verify.require_valid (prog_of (mk_fn Type_repr.String Type_repr.String)) with
   | Ok () -> check "m1: param String, slot _1 String, return Int passes" true
   | Error errs ->
       Printf.printf "    %s\n" (String.concat "\n    " errs);
       check "m1: param String, slot _1 String, return Int passes" false);

  (* m2: param String / slot _1 Int / return Int -> FAIL with the
     param-offset error (param 0's slot is _1, typed Int, not String) *)
  (match Mir_verify.require_valid (prog_of (mk_fn Type_repr.String i64_int)) with
   | Ok () ->
       check "m2: param String, slot _1 Int is rejected (param-offset check live)" false
   | Error errs ->
       let has_offset_err =
         List.exists (fun e -> contains_sub e "does not match its local slot") errs
       in
       Printf.printf "    errors:\n%s\n" (String.concat "\n    " errs);
       check "m2: rejected with the param-offset error" has_offset_err);

  (* m3: param Int / slot _1 Int / return Int -> PASS *)
  (match Mir_verify.require_valid (prog_of (mk_fn i64_int i64_int)) with
   | Ok () -> check "m3: param Int, slot _1 Int, return Int passes" true
   | Error errs ->
       Printf.printf "    %s\n" (String.concat "\n    " errs);
       check "m3: param Int, slot _1 Int, return Int passes" false);

  (* m4: the block-id array invariant is enforced — ids {0, 2} in a
     2-element blocks array (gap: the array position != id) must be
     rejected with the out-of-range / missing-id errors *)
  (match Mir_verify.require_valid (prog_of (mk_bad_blocks_fn ())) with
   | Ok () ->
       check "m4: block-id array invariant enforced (gapped ids {0,2} rejected)" false
   | Error errs ->
       let has_gap_err =
         List.exists
           (fun e -> contains_sub e "out of range" || contains_sub e "missing block id")
           errs
       in
       Printf.printf "    errors:\n%s\n" (String.concat "\n    " errs);
       check "m4: block-id array invariant enforced (gapped ids {0,2} rejected)"
         has_gap_err);

  if !failures = 0 then begin
    Printf.printf "tg_verify: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_verify: %d FAILURE(S)\n" !failures;
    exit 1
  end
