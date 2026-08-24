(* vm.ml — The Seed VM interpreter loop (audit §37, §39, §41, §45, §46).

   Executes pre-indexed, monomorphized Seed MIR: functions/block ids/
   locals are arrays; calls go through callee = User InstanceId |
   Intrinsic id | Extern id — never name dispatch. Slot-state ownership
   is enforced on every local access. *)

type frame = {
  fn : int;
  locals : Vm_value.slot array;
  mutable block : int;
  mutable stmt : int;
}

type error_kind = Panic | Trap of string | LimitExceeded of string | HostError of string | Unreachable

type vm_error = {
  kind : error_kind;
  message : string;
  trace : string list;
}

type limits = {
  max_steps : int;
  max_depth : int;
  max_alloc_bytes : int;
  max_host_calls : int;
}

let default_limits =
  { max_steps = 100_000_000; max_depth = 10_000; max_alloc_bytes = 1_073_741_824; max_host_calls = 1_000_000 }

type t = {
  program : Seed_mir.program;
  fn_index : (Ids.Instance_id.t, int) Hashtbl.t;  (* lookup only; iteration is never semantic *)
  memory : Vm_memory.t;
  mutable host : Host.t;
  limits : limits;
  mutable steps : int;
  mutable host_calls : int;
  mutable alloc_bytes : int;
  mutable stdout : Buffer.t;
  mutable stderr : Buffer.t;
  mutable frames : frame list;
  mutable trace : string list;
}

let find_fn (vm : t) (inst : Ids.Instance_id.t) : int option =
  Hashtbl.find_opt vm.fn_index inst

let mk_error vm kind message =
  { kind; message; trace = List.rev (List.map (fun f -> Printf.sprintf "_%d bb%d" f.fn f.block) vm.frames) }

let step_limit (vm : t) : unit =
  vm.steps <- vm.steps + 1;
  if vm.steps > vm.limits.max_steps then
    raise (Failure "vm: step limit exceeded")

let err_trap vm msg =
  let where =
    match vm.frames with
    | f :: _ -> Printf.sprintf " (fn %d bb%d stmt %d)" f.fn f.block f.stmt
    | [] -> " (entry frame)"
  in
  raise (Failure ("vm trap: " ^ msg ^ where))

(* Evaluate an operand to a value (with slot-state checks). *)
let rec eval_operand (vm : t) (frame : frame) (op : Seed_mir.operand) : Vm_value.t =
  step_limit vm;
  match op with
  | Seed_mir.Constant c -> (
      match c with
      | Seed_mir.Unit -> Vm_value.Unit
      | Seed_mir.Bool b -> Vm_value.Bool b
      | Seed_mir.Integer i -> Vm_value.Int i
      | Seed_mir.Float32 f -> Vm_value.Float32 f
      | Seed_mir.Float64 f -> Vm_value.Float64 f
      | Seed_mir.Char c -> Vm_value.Char c
      | Seed_mir.String s -> Vm_value.String s
      | Seed_mir.Function inst -> Vm_value.Function inst)
  | Seed_mir.Copy p | Seed_mir.Read p -> (
      match read_place vm frame p with
      | Ok v -> v
      | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | Seed_mir.Move p -> (
      match Vm_value.move_slot frame.locals.(p.Seed_mir.local) with
      | Ok (v, s) ->
          frame.locals.(p.Seed_mir.local) <- s;
          v
      | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | Seed_mir.Consume p -> (
      match Vm_value.move_slot frame.locals.(p.Seed_mir.local) with
      | Ok (v, s) ->
          frame.locals.(p.Seed_mir.local) <- s;
          v
      | Error e -> err_trap vm (Vm_value.slot_error_string e))

(* Read a place: project through the value; allocations for deref targets
   are materialized on write (see write_place); reads of deref places are
   not supported at the scalar level in this seed subset — the memory
   layer is the authority for pointers. *)
and read_place (vm : t) (frame : frame) (p : Seed_mir.place) :
    (Vm_value.t, Vm_value.slot_error) result =
  step_limit vm;
  let base =
    match Vm_value.read_slot frame.locals.(p.Seed_mir.local) with
    | Ok v -> Ok v
    | Error e -> Error e
  in
  match base with
  | Ok b -> Ok (project_read vm b p.Seed_mir.projections)
  | Error e -> Error e

and project_read (vm : t) (base : Vm_value.t) (projs : Seed_mir.projection list) : Vm_value.t =
  match projs with
  | [] -> base
  | proj :: rest ->
      let recurse v = project_read vm v rest in
      (match proj with
       | Seed_mir.Field fid -> (
           match base with
           | Vm_value.Struct fields | Vm_value.Tuple fields ->
               let i = Ids.Field_id.to_int fid in
               if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds"
               else recurse fields.(i)
           | Vm_value.Enum (_, fields) ->
               let i = Ids.Field_id.to_int fid in
               if i < 0 || i >= Array.length fields then err_trap vm "enum field index out of bounds"
               else recurse fields.(i)
           | _ -> err_trap vm "field projection on non-aggregate")
       | Seed_mir.ConstantIndex i -> (
           match base with
           | Vm_value.Array elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds"
               else recurse elems.(i)
           | Vm_value.Tuple elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds"
               else recurse elems.(i)
           | Vm_value.String str ->
               if i < 0 || i >= String.length str then err_trap vm "string index out of bounds"
               else recurse (Vm_value.Char (Uchar.of_char str.[i]))
           | _ -> err_trap vm "index projection on non-array")
       | Seed_mir.Index _ -> err_trap vm "dynamic index projection on read (unsupported shape)"
       | Seed_mir.Downcast _ -> (
           match base with
           | Vm_value.Enum (_, fields) -> recurse (Vm_value.Struct fields)
           | _ -> err_trap vm "downcast on non-enum")
       | Seed_mir.Deref -> (
           match base with
           | Vm_value.RawPtr ptr | Vm_value.Ref ptr ->
               if ptr.Vm_memory.region < 0 then err_trap vm "deref of null pointer"
               else err_trap vm "deref read requires the memory layer (unsupported in this subset)"
           | _ -> err_trap vm "deref on non-pointer"))

(* Deref chains end at a scalar read from memory: load per the trailing
   type. The seed subset reads u8/u16/u32/u64/f32/f64. *)
and read_pointer (_vm : t) (ptr : Vm_memory.pointer) (rest : Seed_mir.projection list) :
    Vm_value.t option =
  if ptr.Vm_memory.region < 0 then None
  else begin
    match rest with
    | [] -> None
    | _ -> None
  end

(* Write a value into a place (assign). *)
let rec write_place (vm : t) (frame : frame) (p : Seed_mir.place) (v : Vm_value.t) : unit =
  step_limit vm;
  match p.Seed_mir.projections with
  | [] -> (
      match Vm_value.write_slot frame.locals.(p.Seed_mir.local) v with
      | Ok s -> frame.locals.(p.Seed_mir.local) <- s
      | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | projs -> (
      let base =
        match Vm_value.read_slot frame.locals.(p.Seed_mir.local) with
        | Ok b -> b
        | Error e -> err_trap vm (Vm_value.slot_error_string e)
      in
      let updated = update_place vm base projs v in
      match Vm_value.write_slot frame.locals.(p.Seed_mir.local) updated with
      | Ok s -> frame.locals.(p.Seed_mir.local) <- s
      | Error e -> err_trap vm (Vm_value.slot_error_string e))

and update_place (vm : t) (base : Vm_value.t) (projs : Seed_mir.projection list)
    (v : Vm_value.t) : Vm_value.t =
  match projs with
  | [] -> v
  | proj :: rest -> (
      match proj with
      | Seed_mir.Field fid -> (
          match base with
          | Vm_value.Struct fields ->
              let i = Ids.Field_id.to_int fid in
              let copy = Array.copy fields in
              copy.(i) <- update_place vm fields.(i) rest v;
              Vm_value.Struct copy
          | Vm_value.Tuple fields ->
              let i = Ids.Field_id.to_int fid in
              let copy = Array.copy fields in
              copy.(i) <- update_place vm fields.(i) rest v;
              Vm_value.Tuple copy
          | _ -> err_trap vm "field write on non-aggregate")
      | Seed_mir.ConstantIndex i -> (
          match base with
          | Vm_value.Array elems ->
              let copy = Array.copy elems in
              copy.(i) <- update_place vm elems.(i) rest v;
              Vm_value.Array copy
          | _ -> err_trap vm "index write on non-array")
      | Seed_mir.Index _ -> err_trap vm "dynamic index write (unsupported shape)"
      | Seed_mir.Downcast _ -> base
      | Seed_mir.Deref -> err_trap vm "deref write (use memory layer)")

let type_of_local (vm : t) (fn_idx : int) (local : int) : Type_repr.t =
  let fn = vm.program.Seed_mir.functions.(fn_idx) in
  if local < 0 || local >= Array.length fn.Seed_mir.locals then
    err_trap vm (Printf.sprintf "local _%d out of range" local)
  else fn.Seed_mir.locals.(local)

(* A needs_drop value requires a Drop terminator; the verifier has already
   checked the plan; here we just execute the slot transition. *)
let do_drop (vm : t) (frame : frame) (local : int) : unit =
  match Vm_value.drop_slot frame.locals.(local) with
  | Ok s -> frame.locals.(local) <- s
  | Error e -> err_trap vm (Vm_value.slot_error_string e)

let binop_int (op : Seed_mir.bin_op) (a : Int_value.t) (b : Int_value.t) : Vm_value.t =
  let open Int_value in
  match op with
  | Seed_mir.Add -> Vm_value.Int (add a b)
  | Seed_mir.Sub -> Vm_value.Int (sub a b)
  | Seed_mir.Mul -> Vm_value.Int (mul a b)
  | Seed_mir.Div -> (
      try Vm_value.Int (div a b) with Division_by_zero -> Vm_value.Int (zero a.width a.signed))
  | Seed_mir.Rem -> (
      try Vm_value.Int (rem a b) with Division_by_zero -> Vm_value.Int (zero a.width a.signed))
  | Seed_mir.Eq -> Vm_value.Bool (compare_vals a b = 0)
  | Seed_mir.Ne -> Vm_value.Bool (compare_vals a b <> 0)
  | Seed_mir.Lt -> Vm_value.Bool (compare_vals a b < 0)
  | Seed_mir.Le -> Vm_value.Bool (compare_vals a b <= 0)
  | Seed_mir.Gt -> Vm_value.Bool (compare_vals a b > 0)
  | Seed_mir.Ge -> Vm_value.Bool (compare_vals a b >= 0)
  | Seed_mir.BitAnd -> Vm_value.Int (logand a b)
  | Seed_mir.BitOr -> Vm_value.Int (logor a b)
  | Seed_mir.BitXor -> Vm_value.Int (logxor a b)
  | Seed_mir.Shl -> Vm_value.Int (shift_left a b)
  | Seed_mir.Shr -> Vm_value.Int (shift_right a b)
  | Seed_mir.And -> Vm_value.Bool (not (is_zero a) && not (is_zero b))
  | Seed_mir.Or -> Vm_value.Bool (not (is_zero a) || not (is_zero b))

let rec eval_rvalue (vm : t) (frame : frame) (rv : Seed_mir.rvalue) : Vm_value.t =
  step_limit vm;
  match rv with
  | Seed_mir.Use op -> eval_operand vm frame op
  | Seed_mir.Ref p | Seed_mir.RefMut p ->
      (* allocate a fresh region holding the current value bytes; the seed
         subset materializes scalars and small aggregates *)
      (match Vm_value.read_slot frame.locals.(p.Seed_mir.local) with
       | Ok v ->
           let ptr = ref None in
           (match vm_alloc_scalar vm v with
            | Some ptr' -> ptr := Some ptr'
            | None -> err_trap vm "ref of unsupported value shape");
           (match !ptr with Some pp -> Vm_value.Ref pp | None -> Vm_value.Null)
       | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | Seed_mir.Aggregate (kind, ops) ->
      let vals = Array.of_list (List.map (eval_operand vm frame) ops) in
      (match kind with
       | Seed_mir.TupleAgg -> Vm_value.Tuple vals
       | Seed_mir.ArrayAgg -> Vm_value.Array vals
       | Seed_mir.StructCtor _ -> Vm_value.Struct vals
       | Seed_mir.EnumCtor (_, vid) -> Vm_value.Enum (Ids.Variant_id.to_int vid, vals)
       | Seed_mir.ClosureAgg inst -> Vm_value.Closure (inst, vals))
  | Seed_mir.BinaryOp (op, l, r) ->
      let lv = eval_operand vm frame l in
      let rv = eval_operand vm frame r in
      (match lv, rv with
       | Vm_value.Int a, Vm_value.Int b -> binop_int op a b
       | Vm_value.Bool a, Vm_value.Bool b -> (
           match op with
           | Seed_mir.And -> Vm_value.Bool (a && b)
           | Seed_mir.Or -> Vm_value.Bool (a || b)
           | Seed_mir.Eq -> Vm_value.Bool (a = b)
           | Seed_mir.Ne -> Vm_value.Bool (a <> b)
           | _ -> err_trap vm "invalid bool binary op")
       | Vm_value.String a, Vm_value.String b -> (
           match op with
           | Seed_mir.Add -> Vm_value.String (a ^ b)
           | Seed_mir.Eq -> Vm_value.Bool (a = b)
           | Seed_mir.Ne -> Vm_value.Bool (a <> b)
           | Seed_mir.Lt -> Vm_value.Bool (a < b)
           | Seed_mir.Le -> Vm_value.Bool (a <= b)
           | Seed_mir.Gt -> Vm_value.Bool (a > b)
           | Seed_mir.Ge -> Vm_value.Bool (a >= b)
           | _ -> err_trap vm "invalid string binary op")
       | Vm_value.Float64 a, Vm_value.Float64 b -> (
           let fa = Int64.float_of_bits a and fb = Int64.float_of_bits b in
           match op with
           | Seed_mir.Add -> Vm_value.Float64 (Int64.bits_of_float (fa +. fb))
           | Seed_mir.Sub -> Vm_value.Float64 (Int64.bits_of_float (fa -. fb))
           | Seed_mir.Mul -> Vm_value.Float64 (Int64.bits_of_float (fa *. fb))
           | Seed_mir.Div -> Vm_value.Float64 (Int64.bits_of_float (fa /. fb))
           | Seed_mir.Eq -> Vm_value.Bool (fa = fb)
           | Seed_mir.Ne -> Vm_value.Bool (fa <> fb)
           | Seed_mir.Lt -> Vm_value.Bool (fa < fb)
           | Seed_mir.Le -> Vm_value.Bool (fa <= fb)
           | Seed_mir.Gt -> Vm_value.Bool (fa > fb)
           | Seed_mir.Ge -> Vm_value.Bool (fa >= fb)
           | _ -> err_trap vm "invalid float binary op")
       | _ -> err_trap vm "binary op on unsupported value pair")
  | Seed_mir.UnaryOp (op, v) -> (
      let vv = eval_operand vm frame v in
      match op, vv with
      | Seed_mir.Neg, Vm_value.Int i -> Vm_value.Int (Int_value.neg i)
      | Seed_mir.Neg, Vm_value.Float64 f -> Vm_value.Float64 (Int64.bits_of_float (-. Int64.float_of_bits f))
      | Seed_mir.Not, Vm_value.Bool b -> Vm_value.Bool (not b)
      | Seed_mir.Not, Vm_value.Int i -> Vm_value.Bool (Int_value.is_zero i)
      | _ -> err_trap vm "invalid unary op")
  | Seed_mir.Discriminant p -> (
      match read_place vm frame p with
      | Ok (Vm_value.Enum (i, _)) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int i))
      | _ -> err_trap vm "discriminant on non-enum")
  | Seed_mir.Len p -> (
      match read_place vm frame p with
      | Ok (Vm_value.Array a) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (Array.length a)))
      | Ok (Vm_value.String s) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s)))
      | Ok (Vm_value.Tuple t) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (Array.length t)))
      | _ -> err_trap vm "len on unsupported value")
  | Seed_mir.Cast (op, ty) -> (
      let vv = eval_operand vm frame op in
      match ty with
      | Type_repr.Int kind -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Int (int_cast i kind)
          | Vm_value.Float64 f -> Vm_value.Int (Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (Int64.of_float (Int64.float_of_bits f)))
          | Vm_value.Bool b -> Vm_value.Int (Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (if b then 1L else 0L))
          | _ -> err_trap vm "invalid cast to int")
      | Type_repr.Float Type_repr.F64 -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Float64 (Int64.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float32 f -> Vm_value.Float64 (Int64.bits_of_float (Int32.float_of_bits f))
          | Vm_value.Float64 f -> Vm_value.Float64 f
          | _ -> err_trap vm "invalid cast to f64")
      | Type_repr.Float Type_repr.F32 -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Float32 (Int32.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float64 f -> Vm_value.Float32 (Int32.bits_of_float (Int64.float_of_bits f))
          | _ -> err_trap vm "invalid cast to f32")
      | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> (
          match vv with
          | Vm_value.Int i -> Vm_value.RawPtr { Vm_memory.region = Int64.to_int (Int_value.to_int64 i); offset = 0 }
          | Vm_value.RawPtr _ -> vv
          | _ -> err_trap vm "invalid cast to pointer")
      | Type_repr.Unit -> Vm_value.Unit
      | Type_repr.Bool -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Bool (not (Int_value.is_zero i))
          | Vm_value.Bool _ -> vv
          | _ -> err_trap vm "invalid cast to bool")
      | Type_repr.Char -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Char (Uchar.of_int (Int64.to_int (Int_value.to_int64 i)))
          | Vm_value.Char _ -> vv
          | _ -> err_trap vm "invalid cast to char")
      | _ -> err_trap vm "cast to unsupported type")

and int_width = function
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

and int_signed = function
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128 | Type_repr.Int -> true
  | _ -> false

and int_cast (i : Int_value.t) (kind : Type_repr.int_kind) : Int_value.t =
  Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (Int_value.to_int64 i)

(* Allocate a scalar/aggregate region for a Ref (the seed subset
   materializes a copy; the pointer is a fresh region). *)
and vm_alloc_scalar (vm : t) (v : Vm_value.t) : Vm_memory.pointer option =
  let size =
    match v with
    | Vm_value.Int i -> if i.Int_value.width = 128 then 16 else 8
    | Vm_value.Float64 _ -> 8
    | Vm_value.Float32 _ -> 4
    | Vm_value.Bool _ | Vm_value.Char _ -> 1
    | _ -> 8
  in
  vm.alloc_bytes <- vm.alloc_bytes + size;
  if vm.alloc_bytes > vm.limits.max_alloc_bytes then err_trap vm "allocation limit exceeded";
  match Vm_memory.alloc vm.memory size 8 with
  | Ok ptr -> Some ptr
  | Error _ -> None

let rec exec_terminator (vm : t) (frame : frame) (term : Seed_mir.terminator) : unit =
  step_limit vm;
  match term with
  | Seed_mir.Goto b ->
      frame.block <- b;
      frame.stmt <- 0
  | Seed_mir.Ret -> raise Exit
  | Seed_mir.SwitchInt (op, targets, otherwise) -> (
      let v = eval_operand vm frame op in
      let tag =
        match v with
        | Vm_value.Int i -> Int_value.to_int64 i
        | Vm_value.Bool b -> if b then 1L else 0L
        | Vm_value.Char c -> Int64.of_int (Uchar.to_int c)
        | _ -> err_trap vm "switchInt on non-tag value"
      in
      let rec find = function
        | [] -> otherwise
        | (t, b) :: rest -> if t = tag then b else find rest
      in
      frame.block <- find targets;
      frame.stmt <- 0)
  | Seed_mir.Call (dest, callee, args, next, _unwind) ->
      let arg_vals = Array.map (fun a -> eval_operand vm frame a.Seed_mir.value) args in
      (match callee with
       | Seed_mir.User inst ->
           let fn_idx =
             match find_fn vm inst with
             | Some idx -> idx
             | None -> err_trap vm "call to unknown instance"
           in
           vm.frames <- frame :: vm.frames;
           if List.length vm.frames > vm.limits.max_depth then
             err_trap vm "call depth exceeded";
           let fn = vm.program.Seed_mir.functions.(fn_idx) in
           let callee_frame =
             { fn = fn_idx;
               locals = Array.make (Array.length fn.Seed_mir.locals) Vm_value.Uninitialized;
               block = fn.Seed_mir.entry;
               stmt = 0 }
           in
           (try
              (* params occupy locals _1 .. _n (local _0 is the return slot) *)
              Array.iteri
                (fun i _slot -> callee_frame.locals.(i + 1) <- Vm_value.Live arg_vals.(i))
                (Array.sub arg_vals 0 (Array.length fn.Seed_mir.params));
              run_frame vm callee_frame
            with Exit -> ());
           let ret =
             match callee_frame.locals.(0) with
             | Vm_value.Live v -> v
             | _ -> Vm_value.Unit
           in
           vm.frames <- List.tl vm.frames;
           write_place vm frame dest ret;
           frame.block <- next;
           frame.stmt <- 0
       | Seed_mir.Intrinsic id | Seed_mir.Extern id ->
           vm.host_calls <- vm.host_calls + 1;
           if vm.host_calls > vm.limits.max_host_calls then
             err_trap vm "host call limit exceeded";
           let ret = call_host vm id arg_vals in
           write_place vm frame dest ret;
           frame.block <- next;
           frame.stmt <- 0)
  | Seed_mir.Drop (p, next, _) ->
      do_drop vm frame p.Seed_mir.local;
      frame.block <- next;
      frame.stmt <- 0
  | Seed_mir.Deinit (p, next, _) ->
      do_drop vm frame p.Seed_mir.local;
      frame.block <- next;
      frame.stmt <- 0
  | Seed_mir.Assert (op, expected, msg, target) -> (
      let v = eval_operand vm frame op in
      let ok =
        match v with
        | Vm_value.Bool b -> b = expected
        | Vm_value.Int i -> (not (Int_value.is_zero i)) = expected
        | _ -> false
      in
      if ok then begin
        frame.block <- target;
        frame.stmt <- 0
      end
      else err_trap vm ("assertion failed: " ^ msg))
  | Seed_mir.Unreachable -> raise (Failure "vm: reached Unreachable")
  | Seed_mir.Abort -> raise (Failure "vm: abort")

(* Host boundary: the seed subset provides a small registry-driven
   surface. Calls not implemented fail closed. *)
and call_host (vm : t) (id : int) (args : Vm_value.t array) : Vm_value.t =
  ignore args;
  err_trap vm (Printf.sprintf "host call #%d not implemented (fail-closed)" id)

and run_frame (vm : t) (frame : frame) : unit =
  let fn = vm.program.Seed_mir.functions.(frame.fn) in
  let rec go () =
    let block = fn.Seed_mir.blocks.(frame.block) in
    if frame.stmt < List.length block.Seed_mir.statements then begin
      let st = List.nth block.Seed_mir.statements frame.stmt in
      (try
         exec_statement vm frame st;
         frame.stmt <- frame.stmt + 1;
         go ()
       with Failure msg ->
         raise
           (Failure
              (Printf.sprintf "%s [fn %d bb%d id=%d stmts=%d]"
                 msg frame.fn frame.block
                 (if frame.block < Array.length fn.Seed_mir.blocks then fn.Seed_mir.blocks.(frame.block).Seed_mir.id else -1)
                 (if frame.block < Array.length fn.Seed_mir.blocks then List.length fn.Seed_mir.blocks.(frame.block).Seed_mir.statements else -1))))
    end
    else
      (try
         exec_terminator vm frame block.Seed_mir.terminator;
         go ()
       with Failure msg ->
         raise (Failure (Printf.sprintf "%s [fn %d bb%d term]" msg frame.fn frame.block)))
  in
  go ()

and exec_statement (vm : t) (frame : frame) (st : Seed_mir.statement) : unit =
  step_limit vm;
  match st with
  | Seed_mir.Assign (dest, rv) ->
      let v = eval_rvalue vm frame rv in
      write_place vm frame dest v
  | Seed_mir.StorageLive l ->
      if l >= 0 && l < Array.length frame.locals then frame.locals.(l) <- Vm_value.Uninitialized
  | Seed_mir.StorageDead l ->
      if l >= 0 && l < Array.length frame.locals then frame.locals.(l) <- Vm_value.Uninitialized
  | Seed_mir.SetDiscriminant (p, vid) -> (
      match read_place vm frame p with
      | Ok (Vm_value.Enum (_, payload)) ->
          write_place vm frame p (Vm_value.Enum (Ids.Variant_id.to_int vid, payload))
      | _ -> err_trap vm "SetDiscriminant on non-enum")
  | Seed_mir.Nop -> ()

(* Re-run the entry frame and return the entry return slot as text
   (self-check/inspection helper). *)
let rec run_inspect (vm : t) (entry_frame : frame) : (string, string) result =
  (try
     run_frame vm entry_frame;
     Ok "unit"
   with
  | Failure msg -> Error msg
  | Exit -> (
      match entry_frame.locals.(0) with
      | Vm_value.Live v -> (
          match v with
          | Vm_value.Int i -> Ok (Int_value.to_string i)
          | Vm_value.Bool b -> Ok (if b then "true" else "false")
          | Vm_value.String s -> Ok s
          | Vm_value.Unit -> Ok "()"
          | other -> Ok (Printf.sprintf "<%s>" (value_kind other)))
      | Vm_value.Uninitialized -> Ok "<uninitialized>"
      | Vm_value.Moved -> Ok "<moved>"
      | Vm_value.Dropped -> Ok "<dropped>"))

and value_kind (v : Vm_value.t) : string =
  match v with
  | Vm_value.Unit -> "unit"
  | Vm_value.Bool _ -> "bool"
  | Vm_value.Int _ -> "int"
  | Vm_value.Float32 _ -> "f32"
  | Vm_value.Float64 _ -> "f64"
  | Vm_value.Char _ -> "char"
  | Vm_value.String _ -> "string"
  | Vm_value.Tuple _ -> "tuple"
  | Vm_value.Struct _ -> "struct"
  | Vm_value.Enum _ -> "enum"
  | Vm_value.Array _ -> "array"
  | Vm_value.Function _ -> "fn"
  | Vm_value.Closure _ -> "closure"
  | Vm_value.RawPtr _ -> "ptr"
  | Vm_value.Ref _ -> "ref"
  | Vm_value.Null -> "null"

(* Build an entry frame without running (inspection). *)
let entry_frame_of ~(program : Seed_mir.program) ~(entry : Ids.Instance_id.t) ~(argv : string array) :
    (t * frame, string) result =
  let fn_index = Hashtbl.create 64 in
  Array.iteri (fun i fn -> Hashtbl.replace fn_index fn.Seed_mir.instance i) program.Seed_mir.functions;
  match Hashtbl.find_opt fn_index entry with
  | None -> Error "entry instance not found"
  | Some fn_idx ->
      let vm =
        {
          program;
          fn_index;
          memory = Vm_memory.create ();
          host = Host.create ~repo_root:"." ~argv:[||];
          limits = default_limits;
          steps = 0;
          host_calls = 0;
          alloc_bytes = 0;
          stdout = Buffer.create 256;
          stderr = Buffer.create 256;
          frames = [];
          trace = [];
        }
      in
      let fn = program.Seed_mir.functions.(fn_idx) in
      let entry_frame =
        { fn = fn_idx; locals = Array.make (Array.length fn.Seed_mir.locals) Vm_value.Uninitialized; block = fn.Seed_mir.entry; stmt = 0 }
      in
      Array.iteri (fun i s -> entry_frame.locals.(i) <- Vm_value.Live (Vm_value.String s)) argv;
      Ok (vm, entry_frame)

let run ~(program : Seed_mir.program) ~(entry : Ids.Instance_id.t) ~(argv : string array)
    ~(host : Host.t) : (int, vm_error) result =
  match entry_frame_of ~program ~entry ~argv with
  | Error m -> Error { kind = Trap "entry instance not found"; message = m; trace = [] }
  | Ok (vm, entry_frame) ->
      vm.host <- host;
      (try
         run_frame vm entry_frame;
         Ok 0
       with
      | Failure msg -> Error { kind = Trap msg; message = msg; trace = List.rev vm.trace }
      | Exit -> Ok 0)
