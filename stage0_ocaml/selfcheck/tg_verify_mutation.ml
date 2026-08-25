(* tg_verify_mutation.ml — mutation tests for the Seed MIR verifier
   (Mir_verify.require_valid, audit §36).

   For every verifier class — local convention, block ids,
   definite-initialization dataflow, assign typing, call argument counts
   and callee resolution, switch and terminator targets, aggregate and
   rvalue typing, terminator constraints — a VALID hand-built base
   program is mutated by a SINGLE defect and must be rejected with a
   message from the expected class.  The four base programs are also
   asserted valid (Ok) unchanged.

   Two audit-listed mutations are not literally expressible in the
   record MIR (a Goto or a Ret is only ever the block's `terminator`,
   never a member of `statements`), so their closest representable
   single-defect form is used: "Goto that is not the last statement"
   becomes a reachable block ending in the Unreachable lowering
   fallback (the structural terminator-constraint check), and "Return in
   a non-final position" becomes a Ret fired from a non-final block with
   the return slot uninitialized (the return-slot rule). *)

let failures = ref 0
let total_mutations = ref 0

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

let i64 = Type_repr.Int Type_repr.Int

let int_const (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

let inst (n : int) : Ids.Instance_id.t =
  Ids.Instance_id.make ~callable:(Ids.Callable_id.make n) ~type_args:[||]

let place (l : int) : Seed_mir.place = { Seed_mir.local = l; projections = [] }

let copy (l : int) : Seed_mir.operand = Seed_mir.Copy (place l)
let move (l : int) : Seed_mir.operand = Seed_mir.Move (place l)

let const_op (c : Seed_mir.constant) : Seed_mir.operand = Seed_mir.Constant c
let use_op (op : Seed_mir.operand) : Seed_mir.rvalue = Seed_mir.Use op

let assign (l : int) (rv : Seed_mir.rvalue) : Seed_mir.statement =
  Seed_mir.Assign (place l, rv)

let call_arg (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Read; value = copy l }

let prog_of (fns : Seed_mir.function_ array) : Seed_mir.program =
  { Seed_mir.functions = fns; statics = [||]; types = [||] }

let expect_valid (name : string) (prog : Seed_mir.program) : unit =
  match Mir_verify.require_valid prog with
  | Ok () -> check name true
  | Error errs ->
      Printf.printf "    unexpected errors:\n%s\n" (String.concat "\n    " errs);
      check name false

let expect_error (name : string) (needle : string) (prog : Seed_mir.program) : unit =
  incr total_mutations;
  match Mir_verify.require_valid prog with
  | Ok () ->
      Printf.printf "    not rejected (expected an error containing %S)\n" needle;
      check name false
  | Error errs ->
      let hit = List.exists (fun e -> contains_sub e needle) errs in
      if not hit then
        Printf.printf "    errors (none contains %S):\n%s\n" needle
          (String.concat "\n    " errs);
      check name hit

(* ── Valid base programs ─────────────────────────────────────────────── *)

(* Base 1: params + arithmetic + a call + a switch + a return.  entry
   (2 params, locals _0.._3) calls add1 (1 param) with its sum, then
   switches on the incremented result and returns. *)
let base_arith () : Seed_mir.program =
  let entry =
    {
      Seed_mir.name = "entry";
      instance = inst 0;
      params = [| (None, i64); (None, i64) |];
      locals = [| i64; i64; i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [ assign 3 (Seed_mir.BinaryOp (Seed_mir.Add, copy 1, copy 2)) ];
            terminator =
              Seed_mir.Call (place 0, Seed_mir.User (inst 1), [| call_arg 3 |], 1, None);
          };
          {
            Seed_mir.id = 1;
            statements =
              [ assign 3 (Seed_mir.BinaryOp (Seed_mir.Add, copy 0, const_op (int_const 1L))) ];
            terminator = Seed_mir.SwitchInt (copy 3, [ (42L, 2) ], 2);
          };
          { Seed_mir.id = 2; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  let add1 =
    {
      Seed_mir.name = "add1";
      instance = inst 1;
      params = [| (None, i64) |];
      locals = [| i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [ assign 0 (Seed_mir.BinaryOp (Seed_mir.Add, copy 1, const_op (int_const 1L))) ];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  prog_of [| entry; add1 |]

(* Base 2: an if/else-shaped block structure — bb0 switches on a Bool
   param, then-block bb1 and else-block bb2 each initialize the return
   slot and join at bb3 for the return. *)
let base_if_else () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "branch";
      instance = inst 2;
      params = [| (None, Type_repr.Bool) |];
      locals = [| i64; Type_repr.Bool; i64 |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [];
            terminator = Seed_mir.SwitchInt (copy 1, [ (0L, 2) ], 1) };
          { Seed_mir.id = 1; statements = [ assign 0 (use_op (const_op (int_const 1L))) ];
            terminator = Seed_mir.Goto 3 };
          { Seed_mir.id = 2; statements = [ assign 0 (use_op (const_op (int_const 2L))) ];
            terminator = Seed_mir.Goto 3 };
          { Seed_mir.id = 3; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* Base 3: an aggregate/tuple — a 2-param function building a (Int, Int)
   tuple into the return slot. *)
let base_tuple () : Seed_mir.program =
  let pair_ty = Type_repr.Tuple [| i64; i64 |] in
  let fn =
    {
      Seed_mir.name = "mk_pair";
      instance = inst 3;
      params = [| (None, i64); (None, i64) |];
      locals = [| pair_ty; i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [ assign 0 (Seed_mir.Aggregate (Seed_mir.TupleAgg, [ copy 1; copy 2 ])) ];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* Base 4: a function with a String param — the param slot _1 is
   String; the return slot _0 is filled with a Move of the param. *)
let base_string () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "echo";
      instance = inst 4;
      params = [| (None, Type_repr.String) |];
      locals = [| Type_repr.String; Type_repr.String |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (move 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (a) local convention mutations ─────────────────────────────────── *)

(* a1: locals array too small — |locals| = |params| instead of
   >= 1 + |params| (no return slot, missing param slots). *)
let mut_a1 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  prog.Seed_mir.functions.(0) <- { entry with Seed_mir.locals = [| i64; i64 |] };
  prog

(* a2: param 0's slot typed as the RETURN type (the param-offset bug
   class) — param 0 is String but local _1 is the return type Int. *)
let mut_a2 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "f";
      instance = inst 5;
      params = [| (None, Type_repr.String) |];
      locals = [| i64; i64 |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (const_op (int_const 42L))) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (b) block-id mutations ─────────────────────────────────────────── *)

(* b1: two blocks with the same id (one identity, two terminators). *)
let mut_b1 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "dup";
      instance = inst 6;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Goto 1 };
          { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* b2: a block with id N where the array has length < N+1 — ids {0, 2}
   in a 2-element array (the array position != id). *)
let mut_b2 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "gapped";
      instance = inst 7;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Ret };
          { Seed_mir.id = 2; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (c) initialized-before-use mutations ───────────────────────────── *)

(* c1: a statement reading a local that is never written on the entry
   path (local _1 is read, never assigned anywhere). *)
let mut_c1 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "read_uninit";
      instance = inst 8;
      params = [||];
      locals = [| i64; i64 |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (copy 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* c2: a return with the return slot _0 never initialized. *)
let mut_c2 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "uninit_ret";
      instance = inst 9;
      params = [||];
      locals = [| i64 |];
      blocks = [| { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Ret } |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (d) assign typing mutations ────────────────────────────────────── *)

(* d1: an Int operand assigned into a String-typed local. *)
let mut_d1 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "bad_assign1";
      instance = inst 10;
      params = [||];
      locals = [| Type_repr.Unit; Type_repr.String |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 1 (use_op (const_op (int_const 7L))) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* d2: an operand whose type disagrees with the local — a String
   constant assigned into an Int-typed local. *)
let mut_d2 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "bad_assign2";
      instance = inst 11;
      params = [||];
      locals = [| Type_repr.Unit; i64 |];
      blocks =
        [|
          { Seed_mir.id = 0;
            statements = [ assign 1 (use_op (const_op (Seed_mir.String "x"))) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (e) call argument mutations ────────────────────────────────────── *)

(* e1: a call with the wrong argument count for the callee's params —
   2 args for the 1-param add1. *)
let mut_e1 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.terminator =
        Seed_mir.Call (place 0, Seed_mir.User (inst 1), [| call_arg 3; call_arg 1 |], 1, None) };
  prog

(* e2: a call to an instance id that is not in the program's instance
   table (unknown callee). *)
let mut_e2 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.terminator =
        Seed_mir.Call (place 0, Seed_mir.User (inst 99), [| call_arg 3 |], 1, None) };
  prog

(* ── (f) switch / target mutations ──────────────────────────────────── *)

(* f1: a SwitchInt whose default target block does not exist (bb3 is
   not among the ids 0..2). *)
let mut_f1 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb1 = entry.Seed_mir.blocks.(1) in
  entry.Seed_mir.blocks.(1) <-
    { bb1 with Seed_mir.terminator = Seed_mir.SwitchInt (copy 3, [ (42L, 2) ], 3) };
  prog

(* f2: a Goto to a nonexistent block (bb9). *)
let mut_f2 () : Seed_mir.program =
  let prog = base_if_else () in
  let fn = prog.Seed_mir.functions.(0) in
  let bb1 = fn.Seed_mir.blocks.(1) in
  fn.Seed_mir.blocks.(1) <- { bb1 with Seed_mir.terminator = Seed_mir.Goto 9 };
  prog

(* f3: a Call whose next block does not exist (bb9). *)
let mut_f3 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.terminator =
        Seed_mir.Call (place 0, Seed_mir.User (inst 1), [| call_arg 3 |], 9, None) };
  prog

(* ── (g) aggregate / operand typing mutations ───────────────────────── *)

(* g1: an aggregate with an operand count that disagrees with the
   destination tuple arity (1 operand for a 2-tuple). *)
let mut_g1 () : Seed_mir.program =
  let prog = base_tuple () in
  let fn = prog.Seed_mir.functions.(0) in
  let bb0 = fn.Seed_mir.blocks.(0) in
  fn.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [ assign 0 (Seed_mir.Aggregate (Seed_mir.TupleAgg, [ copy 1 ])) ] };
  prog

(* g2: a BinaryOp whose operand types are incompatible with the
   operator — Int + String. *)
let mut_g2 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [ assign 3
            (Seed_mir.BinaryOp (Seed_mir.Add, copy 1, const_op (Seed_mir.String "x"))) ] };
  prog

(* ── (h) terminator constraint mutations ────────────────────────────── *)

(* h1: a function with no terminator in its entry block — the entry
   block's only transfer is a Goto to a nonexistent id (bb5). *)
let mut_h1 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "no_term";
      instance = inst 12;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks = [| { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Goto 5 } |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* h2: a reachable block ends in the Unreachable lowering fallback
   (the structural terminator constraint — a reachable block must end
   in a real transfer; the record MIR cannot express a Goto inside the
   statements list, so this is the closest representable form of a
   control-flow statement in a non-final position). *)
let mut_h2 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "unreachable_entry";
      instance = inst 13;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks = [| { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Unreachable } |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* h3: a Return in a non-final position — the Ret fires from the
   non-final block bb1, reached by a Goto, with the return slot _0
   never initialized (the return-slot rule rejects it). *)
let mut_h3 () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "ret_mid";
      instance = inst 14;
      params = [||];
      locals = [| i64 |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = []; terminator = Seed_mir.Goto 1 };
          { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

let () =
  Printf.printf "Seed MIR verifier mutation self-check\n";
  expect_valid "base1: params + arithmetic + call + switch + return accepted"
    (base_arith ());
  expect_valid "base2: if/else-shaped blocks accepted" (base_if_else ());
  expect_valid "base3: tuple aggregate accepted" (base_tuple ());
  expect_valid "base4: string param accepted" (base_string ());

  expect_error "a1: locals too small (|locals| = |params|) rejected"
    "parameters require" (mut_a1 ());
  expect_error "a2: param 0 slot typed as the return type (param-offset bug) rejected"
    "does not match its local slot" (mut_a2 ());

  expect_error "b1: duplicate block id rejected"
    "duplicate block id" (mut_b1 ());
  expect_error "b2: out-of-order ids {0,2} in a 2-element array rejected"
    "out of range" (mut_b2 ());

  expect_error "c1: read of a never-initialized local rejected"
    "use of possibly-uninitialized local _1" (mut_c1 ());
  expect_error "c2: return with the return slot never initialized rejected"
    "return with the return slot _0 not definitely initialized" (mut_c2 ());

  expect_error "d1: Int operand assigned into a String local rejected"
    "assign type mismatch" (mut_d1 ());
  expect_error "d2: String operand assigned into an Int local rejected"
    "assign type mismatch" (mut_d2 ());

  expect_error "e1: call with 2 args for a 1-param callee rejected"
    "call argument count mismatch" (mut_e1 ());
  expect_error "e2: call to an unknown callee instance rejected"
    "call to unknown function instance" (mut_e2 ());

  expect_error "f1: SwitchInt default target does not exist rejected"
    "references invalid block bb3" (mut_f1 ());
  expect_error "f2: Goto to a nonexistent block rejected"
    "references invalid block bb9" (mut_f2 ());
  expect_error "f3: Call next block does not exist rejected"
    "references invalid block bb9" (mut_f3 ());

  expect_error "g1: tuple aggregate operand count mismatch rejected"
    "aggregate count mismatch" (mut_g1 ());
  expect_error "g2: BinaryOp with incompatible operand types (Int + String) rejected"
    "binary op operands have different types" (mut_g2 ());

  expect_error "h1: entry block terminator Goto to a nonexistent id rejected"
    "references invalid block bb5" (mut_h1 ());
  expect_error "h2: reachable block ends in Unreachable rejected"
    "reachable block ends in Unreachable" (mut_h2 ());
  expect_error "h3: Ret from a non-final block with the return slot uninitialized rejected"
    "return with the return slot _0 not definitely initialized" (mut_h3 ());

  if !failures = 0 then begin
    Printf.printf "ALL MUTATION TESTS PASS (%d)\n" !total_mutations;
    exit 0
  end
  else begin
    Printf.printf "%d MUTATION TEST FAILURE(S)\n" !failures;
    exit 1
  end
