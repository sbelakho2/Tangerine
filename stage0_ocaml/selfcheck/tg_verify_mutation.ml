let let_param (ty : Type_repr.t) : Type_repr.param_type = { Type_repr.pt_convention = Access_effect.Let; pt_type = ty }
(* tg_verify_mutation.ml — mutation tests for the Seed MIR verifier
   (Mir_verify.require_valid, audit §36).

   For every verifier class — local convention, block ids,
   definite-initialization dataflow, assign typing, call argument counts
   and callee resolution, switch and terminator targets, aggregate and
   rvalue typing, terminator constraints, nominal identity, recursive
   enum copyability — a VALID hand-built base program is mutated by a
   SINGLE defect and must be rejected with a message from the expected
   class.  The base programs are also asserted valid (Ok) unchanged.

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

let inst (n : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make n) ~type_args:[||]

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
      params = [| let_param(i64); let_param(i64) |];
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
      params = [| let_param(i64) |];
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
      params = [| let_param(Type_repr.Bool) |];
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
      params = [| let_param(i64); let_param(i64) |];
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
      params = [| let_param(Type_repr.String) |];
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
      params = [| let_param(Type_repr.String) |];
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

(* ── (e2) access-effect exactness mutations (audit) ─────────────────── *)
(* callee `con` declares Sink/Inout/Set params; the call's Read args
   must not match those conventions (Read is the read-side of Let only). *)
let base_conventions () : Seed_mir.program =
  let entry =
    {
      Seed_mir.name = "entry";
      instance = inst 0;
      params = [||];
      locals = [| i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements = [ assign 1 (Seed_mir.Use (const_op (int_const 5L))) ];
            terminator =
              Seed_mir.Call (place 0, Seed_mir.User (inst 7), [| call_arg 1; call_arg 1; call_arg 1 |], 1, None);
          };
          { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  let con =
    {
      Seed_mir.name = "con";
      instance = inst 7;
      params =
        [|
          { Type_repr.pt_convention = Access_effect.Sink; pt_type = i64 };
          { Type_repr.pt_convention = Access_effect.Inout; pt_type = i64 };
          { Type_repr.pt_convention = Access_effect.Set; pt_type = i64 };
        |];
      locals = [| i64; i64; i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements = [];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  prog_of [| entry; con |]

(* e3: Read arg against the callee's Sink (Consume) convention. *)
let mut_e3 () : Seed_mir.program = base_conventions ()
(* e4: Read arg against the callee's Inout (Modify) convention. *)
let mut_e4 () : Seed_mir.program = base_conventions ()
(* e5: Read arg against the callee's Set (Initialize) convention. *)
let mut_e5 () : Seed_mir.program = base_conventions ()
(* e6: Consume arg against a Let callee param (Read convention). *)
let mut_e6 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.terminator =
        Seed_mir.Call
          ( place 0,
            Seed_mir.User (inst 1),
            [| { Seed_mir.effect_ = Access_effect.Consume; value = copy 3 } |],
            1,
            None ) };
  prog
(* e7: Modify on a constant operand (that effect requires a place). *)
let mut_e7 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.terminator =
        Seed_mir.Call
          ( place 0,
            Seed_mir.User (inst 1),
            [| { Seed_mir.effect_ = Access_effect.Modify; value = const_op (int_const 1L) } |],
            1,
            None ) };
  prog
(* e8: Consume of a place already consumed (double-use of local _3). *)
let mut_e8 () : Seed_mir.program =
  let prog = base_arith () in
  let entry = prog.Seed_mir.functions.(0) in
  let bb0 = entry.Seed_mir.blocks.(0) in
  entry.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [ assign 2 (Seed_mir.Use (move 3)) ];
      terminator =
        Seed_mir.Call
          ( place 0,
            Seed_mir.User (inst 1),
            [| { Seed_mir.effect_ = Access_effect.Consume; value = move 3 } |],
            1,
            None ) };
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

(* ── (i) dynamic Index projection mutations ───────────────────────────

   The dynamic-index form is `Seed_mir.Index li`: the payload is the
   LOCAL whose runtime integer value is the index.  The verifier must
   check that li names an existing local, that the local is definitely
   initialized at the program point, and that its type is an allowed
   integer index type — but must NEVER compare li against the container
   length (the runtime value is bounds-checked by the VM at execution). *)

(* valid base: a 3-element array aggregate into _1, the index local _2
   initialized to the runtime value Int 1, an element read through
   `Index 2` into _3, returned via _0. *)
let base_runtime_index () : Seed_mir.program =
  let arr_ty = Type_repr.Fixed_array (i64, 3) in
  let fn =
    {
      Seed_mir.name = "dynidx";
      instance = inst 15;
      params = [||];
      locals = [| i64; arr_ty; i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [
                assign 1
                  (Seed_mir.Aggregate
                     (Seed_mir.ArrayAgg,
                       [ const_op (int_const 10L); const_op (int_const 20L); const_op (int_const 30L) ]));
                assign 2 (use_op (const_op (int_const 1L)));
                assign 3
                  (use_op (Seed_mir.Copy { Seed_mir.local = 1; projections = [ Seed_mir.Index 2 ] }));
                assign 0 (use_op (copy 3));
              ];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* i1: the Index payload names a local that does not exist — li = 9 is
   >= |locals| = 4. *)
let mut_i1 () : Seed_mir.program =
  let prog = base_runtime_index () in
  let fn = prog.Seed_mir.functions.(0) in
  let bb0 = fn.Seed_mir.blocks.(0) in
  fn.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [
          assign 1
            (Seed_mir.Aggregate
               (Seed_mir.ArrayAgg,
                 [ const_op (int_const 10L); const_op (int_const 20L); const_op (int_const 30L) ]));
          assign 2 (use_op (const_op (int_const 1L)));
          assign 3
            (use_op (Seed_mir.Copy { Seed_mir.local = 1; projections = [ Seed_mir.Index 9 ] }));
          assign 0 (use_op (copy 3));
        ] };
  prog

(* i2: the Index payload local is never initialized on the entry path —
   the `assign 2` statement is deleted, so _2 is not in the
   definite-initialization running set at the read. *)
let mut_i2 () : Seed_mir.program =
  let prog = base_runtime_index () in
  let fn = prog.Seed_mir.functions.(0) in
  let bb0 = fn.Seed_mir.blocks.(0) in
  fn.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [
          assign 1
            (Seed_mir.Aggregate
               (Seed_mir.ArrayAgg,
                 [ const_op (int_const 10L); const_op (int_const 20L); const_op (int_const 30L) ]));
          assign 3
            (use_op (Seed_mir.Copy { Seed_mir.local = 1; projections = [ Seed_mir.Index 2 ] }));
          assign 0 (use_op (copy 3));
        ] };
  prog

(* i3: the Index payload local's type is a String — _2 is initialized
   (with a String value) but its type is not an allowed integer index
   type. *)
let mut_i3 () : Seed_mir.program =
  let prog = base_runtime_index () in
  let fn = prog.Seed_mir.functions.(0) in
  let bb0 = fn.Seed_mir.blocks.(0) in
  fn.Seed_mir.locals.(2) <- Type_repr.String;
  fn.Seed_mir.blocks.(0) <-
    { bb0 with
      Seed_mir.statements =
        [
          assign 1
            (Seed_mir.Aggregate
               (Seed_mir.ArrayAgg,
                 [ const_op (int_const 10L); const_op (int_const 20L); const_op (int_const 30L) ]));
          assign 2 (use_op (const_op (Seed_mir.String "x")));
          assign 3
            (use_op (Seed_mir.Copy { Seed_mir.local = 1; projections = [ Seed_mir.Index 2 ] }));
          assign 0 (use_op (copy 3));
        ] };
  prog

(* i5: the runtime out-of-bounds case — the same valid runtime-index
   shape with a 1-element base and the index local's runtime value 2.
   The verifier ACCEPTS it (Index is never compared against the
   container length at compile time) and Vm.run traps on the runtime
   out-of-bounds read. *)
let runtime_oob_prog () : Seed_mir.program =
  let arr_ty = Type_repr.Fixed_array (i64, 1) in
  let fn =
    {
      Seed_mir.name = "dynidx_oob";
      instance = inst 16;
      params = [||];
      locals = [| i64; arr_ty; i64; i64 |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [
                assign 1 (Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ const_op (int_const 10L) ]));
                assign 2 (use_op (const_op (int_const 2L)));
                assign 3
                  (use_op (Seed_mir.Copy { Seed_mir.local = 1; projections = [ Seed_mir.Index 2 ] }));
                assign 0 (use_op (copy 3));
              ];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  prog_of [| fn |]

(* ── (j) nominal identity + recursive enum copy proofs (re-audit) ────

   Two distinct structs with the same physical shape must NOT be
   interchangeable (types_compatible compares Named types by TypeId +
   concrete args BEFORE any structural resolution — the verifier must
   never replace a nominal value's identity with its reconstructed
   shape for ordinary type equality), and enum copyability is recursive
   over the variant payloads (an enum with an owning payload — a
   Result[Int, String]-shaped def — is NOT Copy; an enum with all-Copy
   payloads — Option[Int]-shaped — is). *)

let shape_tid_user = Ids.Type_id.make 200
let shape_tid_socket = Ids.Type_id.make 201
let shape_tid_result = Ids.Type_id.make 202
let shape_tid_option = Ids.Type_id.make 203

let user_id_ty = Type_repr.Named (shape_tid_user, [||])
let socket_fd_ty = Type_repr.Named (shape_tid_socket, [||])
let result_like_ty = Type_repr.Named (shape_tid_result, [||])
let option_like_ty = Type_repr.Named (shape_tid_option, [||])

(* UserId { value: Int } and SocketFd { value: Int } share the EXACT
   shape (Tuple [Int]); Result-like has an owning (String) payload,
   Option-like is all-Copy. *)
let shape_defs : Seed_mir.type_def array =
  [|
    Seed_mir.StructDef
      { sd_id = shape_tid_user;
        sd_fields =
          [ { Seed_mir.fd_id = Ids.Field_id.make 0; fd_index = Ids.Field_index.make 0; fd_ty = i64 } ] };
    Seed_mir.StructDef
      { sd_id = shape_tid_socket;
        sd_fields =
          [ { Seed_mir.fd_id = Ids.Field_id.make 1; fd_index = Ids.Field_index.make 0; fd_ty = i64 } ] };
    Seed_mir.EnumDef
      { ed_id = shape_tid_result;
        ed_variants =
          [ { Seed_mir.vd_id = Ids.Variant_id.make 0; vd_index = Ids.Variant_index.make 0;
              vd_payload = Type_repr.Tuple [| i64 |] };
            { Seed_mir.vd_id = Ids.Variant_id.make 1; vd_index = Ids.Variant_index.make 1;
              vd_payload = Type_repr.Tuple [| Type_repr.String |] } ] };
    Seed_mir.EnumDef
      { ed_id = shape_tid_option;
        ed_variants =
          [ { Seed_mir.vd_id = Ids.Variant_id.make 2; vd_index = Ids.Variant_index.make 0;
              vd_payload = Type_repr.Tuple [| i64 |] };
            { Seed_mir.vd_id = Ids.Variant_id.make 3; vd_index = Ids.Variant_index.make 1;
              vd_payload = Type_repr.Unit } ] };
  |]

let prog_with_types (fn : Seed_mir.function_) : Seed_mir.program =
  { Seed_mir.functions = [| fn |]; statics = [||]; types = shape_defs }

(* j1: a UserId-typed param slot is moved into a SocketFd-typed return
   slot — both defs are Tuple [Int] (the SAME shape), so a structural
   comparison would accept it; the nominal rule must reject it. *)
let mut_j1_nominal_shape () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "nominal_shape";
      instance = inst 20;
      params = [| let_param(user_id_ty) |];
      locals = [| socket_fd_ty; user_id_ty |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (move 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_with_types fn

(* j2 (positive control): UserId into a UserId return slot is accepted
   (the identity rule also admits the SAME nominal). *)
let valid_j2_nominal_same () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "nominal_same";
      instance = inst 21;
      params = [| let_param(user_id_ty) |];
      locals = [| user_id_ty; user_id_ty |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (move 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_with_types fn

(* j3: a bitwise copy of a Result[Int, String]-shaped enum (a variant
   payload is String — an owning payload) must fail the verifier's
   recursive Copy check. *)
let mut_j3_owning_enum_copy () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "owning_enum_copy";
      instance = inst 22;
      params = [| let_param(result_like_ty) |];
      locals = [| result_like_ty; result_like_ty |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (copy 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_with_types fn

(* j4 (positive control): a bitwise copy of an Option[Int]-shaped enum
   (all-Copy payloads) is accepted. *)
let valid_j4_copyable_enum_copy () : Seed_mir.program =
  let fn =
    {
      Seed_mir.name = "copyable_enum_copy";
      instance = inst 23;
      params = [| let_param(option_like_ty) |];
      locals = [| option_like_ty; option_like_ty |];
      blocks =
        [|
          { Seed_mir.id = 0; statements = [ assign 0 (use_op (copy 1)) ];
            terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  prog_with_types fn

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

  expect_error "e3: Read arg against the callee's Sink (Consume) convention rejected"
    "does not match the callee's sink convention" (mut_e3 ());
  expect_error "e4: Read arg against the callee's Inout (Modify) convention rejected"
    "does not match the callee's inout convention" (mut_e4 ());
  expect_error "e5: Read arg against the callee's Set (Initialize) convention rejected"
    "does not match the callee's set convention" (mut_e5 ());
  expect_error "e6: Consume arg against a Let callee param rejected"
    "does not match the callee's let convention" (mut_e6 ());
  expect_error "e7: Modify on a constant operand rejected"
    "requires a place operand" (mut_e7 ());
  expect_error "e8: Consume of an already-consumed place rejected"
    "use-after-move" (mut_e8 ());

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

  expect_valid
    "i4: runtime dynamic-index program accepted (index local _2 initialized to Int 1)"
    (base_runtime_index ());
  expect_error "i1: Index payload names a nonexistent local (li >= |locals|) rejected"
    "dynamic index local _9 does not exist" (mut_i1 ());
  expect_error
    "i2: Index payload local never initialized on the entry path rejected"
    "dynamic index local _2 is not definitely initialized" (mut_i2 ());
  expect_error
    "i3: Index payload local typed String (non-integer index type) rejected"
    "dynamic index local _2 has non-integer index type String" (mut_i3 ());

  (* (j) nominal identity + recursive enum copy proofs *)
  expect_error
    "j1: UserId value moved into a SocketFd slot rejected (same {value: Int} shape, distinct TypeIds — nominal identity is enforced, never degraded to Tuple[Int] == Tuple[Int])"
    "assign type mismatch" (mut_j1_nominal_shape ());
  expect_valid
    "j2: UserId value moved into a UserId slot accepted (the SAME nominal is admitted)"
    (valid_j2_nominal_same ());
  expect_error
    "j3: copy of a Result[Int, String]-shaped enum (String payload is owning) rejected by the recursive enum Copy rule"
    "copy of non-Copy value" (mut_j3_owning_enum_copy ());
  expect_valid
    "j4: copy of an Option[Int]-shaped enum (all-Copy payloads) accepted by the recursive enum Copy rule"
    (valid_j4_copyable_enum_copy ());
  (* i5: the runtime out-of-bounds case through the VM — the verifier
     must accept the program (Index li is never compared against the
     container length; the value 2 is only known at runtime) and
     Vm.run must trap with a message mentioning the index/bounds. *)
  (match Mir_verify.require_valid (runtime_oob_prog ()) with
   | Ok () ->
       check
         "i5a: runtime-OOB program passes the verifier (Index li is never compile-time bounds-checked)"
         true
   | Error errs ->
       Printf.printf "    unexpected verifier errors:\n%s\n" (String.concat "\n    " errs);
       check
         "i5a: runtime-OOB program passes the verifier (Index li is never compile-time bounds-checked)"
         false);
  (let prog = runtime_oob_prog () in
   let host = Host.create ~repo_root:"." ~argv:[||] in
   match
     Vm.run ~program:prog ~entry:prog.Seed_mir.functions.(0).Seed_mir.instance ~argv:[||] ~host
   with
   | Error e when contains_sub e.Vm.message "index" || contains_sub e.Vm.message "bounds" ->
       check
         (Printf.sprintf
            "i5b: runtime out-of-bounds dynamic index (base length 1, index value 2) traps in the VM (%s)"
            e.Vm.message)
         true
   | Error e ->
       check
         (Printf.sprintf "i5b: runtime OOB trapped with a message lacking index/bounds: %s"
            e.Vm.message)
         false
   | Ok _ ->
       check "i5b: runtime out-of-bounds dynamic index (base length 1, index value 2) did not trap"
         false);

  if !failures = 0 then begin
    Printf.printf "ALL MUTATION TESTS PASS (%d)\n" !total_mutations;
    exit 0
  end
  else begin
    Printf.printf "%d MUTATION TEST FAILURE(S)\n" !failures;
    exit 1
  end

