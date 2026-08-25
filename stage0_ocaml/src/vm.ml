(* vm.ml — The Seed VM interpreter loop (audit §37, §39, §41, §45, §46).

   Executes pre-indexed, monomorphized Seed MIR: functions/block ids/
   locals are arrays; calls go through callee = User InstanceId |
   Intrinsic id | Extern id — never name dispatch. Slot-state ownership
   is enforced on every local access.

   ── Kernel-closure primitives (the audit's remaining items) ─────────

   1. DYNAMIC INDEX PROJECTIONS.  The Seed MIR dynamic-index projection
      is `Seed_mir.Index local` (seed_mir.ml): the payload is a LOCAL
      whose value is the runtime index — the seed's dynamic-index
      convention (the "index operand" is read from the current frame's
      locals through the slot machine).  The index is bounds-checked
      deterministically (traps: "index out of bounds" for arrays,
      "tuple index out of bounds", "string index out of bounds"; a
      non-integer or 128-bit index traps).  Reads project the element
      and continue the remaining projections; writes update the element
      in place — the updated aggregate is written back to the slot
      (Array/Tuple elements; a String write replaces the byte at the
      index with the char's UTF-8 bytes — String indices are BYTE
      indices, consistent with Len's String.length and the
      ConstantIndex projection).
      NOTE: mir_lower.ml today emits ConstantIndex for literal `arr[i]`
      (already executed here) and unrolls for-loops with ConstantIndex
      reads; it never emits the dynamic Index form — the VM executes it
      for hand-written/kernel MIR.

   2. POINTER DEREFERENCE (`Seed_mir.Deref`).  A RawPtr (or a
      region-backed Ref) dereferences through the simulated memory: the
      region at (region, offset) holds a self-describing byte
      serialization (Vm_value.serialize/deserialize — see vm_value.ml
      for the exact format; integers little-endian by width, Bool 1
      byte, Char 4-byte utf-32, String 8-byte length prefix + utf-8,
      aggregates recursively; it round-trips).  Null pointers, dead
      regions, out-of-bounds offsets and invalid payloads are
      deterministic traps.  A deref WRITE serializes the value into the
      region (in place, never a copy).

   3. REF / REFMUT WRITEBACK.  `Ref p`/`RefMut p` with a place source
      (no Deref in p's projections) produces a REAL reference:
      `Vm_value.Ref (Place (frame, local, projections))` — the target
      frame RECORD is captured, so reads resolve to the target place
      and writes through the ref update the target IN PLACE, even when
      the ref crosses a call boundary.  `Ref p` whose source has a Deref
      projection (a computed value, e.g. `&*ptr`) keeps a serialized
      copy in a fresh region (`Ref (Region ptr)`): reads load the copy
      back, and WRITES THROUGH IT ARE A DETERMINISTIC TRAP (no silent
      divergence).

   4. RECURSIVE DROP.  `Drop`/`Deinit` run the recursive drop glue
      (Vm_value.drop_glue) over the place's value first: aggregates are
      visited depth-first and every region-backed ref inside is
      deterministically freed, then the outer slot transitions per the
      slot machine (Live -> Dropped; Moved/Uninitialized are no-ops; a
      second drop of a Dropped slot traps). *)

(* Frame identity — the type lives in vm_value.ml so that reference
   targets can record a frame; the equation re-declares it here so the
   record fields are in scope in this module. *)
type frame = Vm_value.frame = {
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
  fn_index : (Instance_id.t, int) Hashtbl.t;  (* lookup only; iteration is never semantic *)
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

let find_fn (vm : t) (inst : Instance_id.t) : int option =
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

(* Read a place: project through the value.  A Deref projection resolves
   through memory (RawPtr) or through the reference target (Ref). *)
and read_place (vm : t) (frame : frame) (p : Seed_mir.place) :
    (Vm_value.t, Vm_value.slot_error) result =
  step_limit vm;
  let base =
    match Vm_value.read_slot frame.locals.(p.Seed_mir.local) with
    | Ok v -> Ok v
    | Error e -> Error e
  in
  match base with
  | Ok b -> Ok (project_read vm frame b p.Seed_mir.projections)
  | Error e -> Error e

and project_read (vm : t) (frame : frame) (base : Vm_value.t)
    (projs : Seed_mir.projection list) : Vm_value.t =
  match projs with
  | [] -> base
  | proj :: rest ->
      let recurse v = project_read vm frame v rest in
      (match proj with
       | Seed_mir.Field fid -> (
           match base with
           | Vm_value.Struct fields | Vm_value.Tuple fields ->
               let i = Ids.Field_index.to_int fid in
               if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds"
               else recurse fields.(i)
           | Vm_value.Enum (_, fields) ->
               let i = Ids.Field_index.to_int fid in
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
       | Seed_mir.Index li -> (
           let i = index_of_local vm frame li in
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
       | Seed_mir.Downcast _ -> (
           match base with
           | Vm_value.Enum (_, fields) -> recurse (Vm_value.Struct fields)
           | _ -> err_trap vm "downcast on non-enum")
       | Seed_mir.Deref -> (
           match base with
           | Vm_value.Ref (Vm_value.Place (tf, l, projs)) ->
               (* a real reference: resolve the target place, then
                  continue the remaining projections on the target value *)
               let tv =
                 match read_place vm tf { Seed_mir.local = l; projections = projs } with
                 | Ok v -> v
                 | Error e -> err_trap vm (Vm_value.slot_error_string e)
               in
               recurse tv
           | Vm_value.Ref (Vm_value.Region ptr) -> recurse (memory_load vm ptr)
           | Vm_value.RawPtr ptr -> recurse (memory_load vm ptr)
           | _ -> err_trap vm "deref on non-pointer"))

(* The dynamic-index form: the payload is a LOCAL whose value is the
   runtime index (the seed's dynamic-index convention).  The local is
   read through the slot machine; a non-integer or 128-bit index is a
   deterministic trap. *)
and index_of_local (vm : t) (frame : frame) (li : int) : int =
  if li < 0 || li >= Array.length frame.locals then
    err_trap vm "dynamic index local out of range";
  match Vm_value.read_slot frame.locals.(li) with
  | Error e -> err_trap vm (Vm_value.slot_error_string e)
  | Ok (Vm_value.Int i) ->
      if i.Int_value.width > 64 then err_trap vm "dynamic index is a 128-bit value";
      let n =
        if i.Int_value.width > 64 then
          err_trap vm "128-bit value used as an index (not representable in the seed)"
        else Int_value.to_int64 i
      in
      if n < 0L then err_trap vm "index out of bounds (negative)";
      if Int64.compare n (Int64.of_int max_int) > 0 then err_trap vm "index out of bounds";
      Int64.to_int n
  | Ok _ -> err_trap vm "dynamic index is not an integer"

(* Deref read: the region at the pointer holds a self-describing
   serialized value (Vm_value.serialize).  Null pointers, dead regions,
   out-of-bounds offsets and invalid payloads are deterministic traps. *)
and memory_load (vm : t) (ptr : Vm_memory.pointer) : Vm_value.t =
  if ptr.Vm_memory.region < 0 then err_trap vm "deref of null pointer";
  match Vm_memory.region_of vm.memory ptr with
  | Error e -> err_trap vm ("deref read: " ^ Vm_memory.mem_error_string e)
  | Ok r ->
      let len = Bytes.length r.Vm_memory.bytes in
      if ptr.Vm_memory.offset < 0 || ptr.Vm_memory.offset > len then
        err_trap vm "deref read: out-of-bounds";
      let sub = Bytes.sub r.Vm_memory.bytes ptr.Vm_memory.offset (len - ptr.Vm_memory.offset) in
      Vm_value.deserialize sub

(* Deref write: serialize the value into the region (in place, never a
   copy). *)
and memory_store (vm : t) (ptr : Vm_memory.pointer) (v : Vm_value.t) : unit =
  if ptr.Vm_memory.region < 0 then err_trap vm "deref of null pointer";
  let bytes = Vm_value.serialize v in
  match Vm_memory.region_of vm.memory ptr with
  | Error e -> err_trap vm ("deref write: " ^ Vm_memory.mem_error_string e)
  | Ok r ->
      let blen = Bytes.length bytes in
      let rlen = Bytes.length r.Vm_memory.bytes in
      if ptr.Vm_memory.offset < 0 || ptr.Vm_memory.offset > rlen - blen then
        err_trap vm "deref write: out-of-bounds";
      Bytes.blit bytes 0 r.Vm_memory.bytes ptr.Vm_memory.offset blen

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
      let updated = update_place vm frame base projs v in
      match Vm_value.write_slot frame.locals.(p.Seed_mir.local) updated with
      | Ok s -> frame.locals.(p.Seed_mir.local) <- s
      | Error e -> err_trap vm (Vm_value.slot_error_string e))

and update_place (vm : t) (frame : frame) (base : Vm_value.t)
    (projs : Seed_mir.projection list) (v : Vm_value.t) : Vm_value.t =
  match projs with
  | [] -> v
  | proj :: rest -> (
      match proj with
      | Seed_mir.Field fid -> (
          match base with
          | Vm_value.Struct fields ->
              let i = Ids.Field_index.to_int fid in
              if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds";
              let copy = Array.copy fields in
              copy.(i) <- update_place vm frame fields.(i) rest v;
              Vm_value.Struct copy
          | Vm_value.Tuple fields ->
              let i = Ids.Field_index.to_int fid in
              if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds";
              let copy = Array.copy fields in
              copy.(i) <- update_place vm frame fields.(i) rest v;
              Vm_value.Tuple copy
          | _ -> err_trap vm "field write on non-aggregate")
      | Seed_mir.ConstantIndex i -> (
          match base with
          | Vm_value.Array elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) rest v;
              Vm_value.Array copy
          | Vm_value.Tuple elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) rest v;
              Vm_value.Tuple copy
          | Vm_value.String str ->
              if i < 0 || i >= String.length str then err_trap vm "string index out of bounds";
              let c =
                match update_place vm frame (Vm_value.Char (Uchar.of_char str.[i])) rest v with
                | Vm_value.Char c -> c
                | _ -> err_trap vm "string index write with non-char value"
              in
              Vm_value.String (string_with_char_at str i c)
          | _ -> err_trap vm "index write on non-array")
      | Seed_mir.Index li -> (
          let i = index_of_local vm frame li in
          match base with
          | Vm_value.Array elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) rest v;
              Vm_value.Array copy
          | Vm_value.Tuple elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) rest v;
              Vm_value.Tuple copy
          | Vm_value.String str ->
              if i < 0 || i >= String.length str then err_trap vm "string index out of bounds";
              let c =
                match update_place vm frame (Vm_value.Char (Uchar.of_char str.[i])) rest v with
                | Vm_value.Char c -> c
                | _ -> err_trap vm "string index write with non-char value"
              in
              Vm_value.String (string_with_char_at str i c)
          | _ -> err_trap vm "index write on non-array")
      | Seed_mir.Downcast _ -> base
      | Seed_mir.Deref -> (
          match base with
          | Vm_value.Ref (Vm_value.Place (tf, l, projs)) ->
              (* a real reference: write through to the target place; the
                 remaining projections extend the target path; the ref
                 value itself is unchanged *)
              write_place vm tf
                { Seed_mir.local = l; projections = projs @ rest }
                v;
              base
          | Vm_value.Ref (Vm_value.Region _) ->
              err_trap vm "write through a region-backed ref (computed-value ref) is a deterministic trap"
          | Vm_value.RawPtr ptr -> (
              match rest with
              | [] -> memory_store vm ptr v
              | _ ->
                  (* projected write through the pointee: load, update, store *)
                  let cur = memory_load vm ptr in
                  memory_store vm ptr (update_place vm frame cur rest v));
              base
          | _ -> err_trap vm "deref write on non-pointer"))

(* Replace the byte at index i with the char's UTF-8 encoding (the byte
   index is the seed String convention — see the header).  The char's
   encoding may be multi-byte, so the result string's length changes. *)
and string_with_char_at (str : string) (i : int) (c : Uchar.t) : string =
  let encoded = uchar_utf8_encode c in
  let prefix = String.sub str 0 i in
  let suffix = String.sub str (i + 1) (String.length str - i - 1) in
  prefix ^ encoded ^ suffix

(* UTF-8 encode a code point (deterministic; the input Uchar is always
   valid). *)
and uchar_utf8_encode (c : Uchar.t) : string =
  let cp = Uchar.to_int c in
  if cp <= 0x7F then String.make 1 (Char.chr cp)
  else if cp <= 0x7FF then
    String.init 2 (fun j ->
        if j = 0 then Char.chr (0xC0 lor (cp lsr 6))
        else Char.chr (0x80 lor (cp land 0x3F)))
  else if cp <= 0xFFFF then
    String.init 3 (fun j ->
        match j with
        | 0 -> Char.chr (0xE0 lor (cp lsr 12))
        | 1 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))
  else
    String.init 4 (fun j ->
        match j with
        | 0 -> Char.chr (0xF0 lor (cp lsr 18))
        | 1 -> Char.chr (0x80 lor ((cp lsr 12) land 0x3F))
        | 2 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))

let type_of_local (vm : t) (fn_idx : int) (local : int) : Type_repr.t =
  let fn = vm.program.Seed_mir.functions.(fn_idx) in
  if local < 0 || local >= Array.length fn.Seed_mir.locals then
    err_trap vm (Printf.sprintf "local _%d out of range" local)
  else fn.Seed_mir.locals.(local)

(* A needs_drop value requires a Drop terminator; the verifier has already
   checked the plan.  The drop is RECURSIVE: the value's contained
   components run their drop glue first (aggregates depth-first; every
   region-backed ref inside is freed), then the outer slot transitions.
   Moved/Uninitialized slots are no-ops and a second drop of a Dropped
   slot traps — exactly the slot machine in vm_value.ml. *)
let do_drop (vm : t) (frame : frame) (local : int) : unit =
  match frame.locals.(local) with
  | Vm_value.Live v ->
      Vm_value.drop_glue vm.memory v;
      frame.locals.(local) <- Vm_value.Dropped
  | Vm_value.Moved | Vm_value.Uninitialized -> ()
  | Vm_value.Dropped -> err_trap vm (Vm_value.slot_error_string Vm_value.DropDropped)

(* Frame-shape invariant, enforced at frame creation (the VM boundary):
   the block array must be indexed by block id — blocks.(i).id = i for
   every i — and the function must declare at least one local (local _0
   is the return slot).  Mis-shaped MIR traps deterministically instead
   of indexing out of bounds. *)
let check_fn_shape (vm : t) (fn_idx : int) : unit =
  let fn = vm.program.Seed_mir.functions.(fn_idx) in
  let nblocks = Array.length fn.Seed_mir.blocks in
  if nblocks > 0 then begin
    Array.iteri
      (fun i b ->
        if b.Seed_mir.id <> i then
          err_trap vm
            (Printf.sprintf
               "function %s: block array must be indexed by block id: blocks.(%d).id = %d (expected %d)"
               fn.Seed_mir.name i b.Seed_mir.id i))
      fn.Seed_mir.blocks;
    if fn.Seed_mir.entry < 0 || fn.Seed_mir.entry >= nblocks then
      err_trap vm
        (Printf.sprintf "function %s: entry block %d out of range 0..%d"
           fn.Seed_mir.name fn.Seed_mir.entry (nblocks - 1))
  end;
  if Array.length fn.Seed_mir.locals < 1 then
    err_trap vm
      (Printf.sprintf "function %s: must declare at least one local (local _0 is the return slot)"
         fn.Seed_mir.name)

(* True when v is the signed minimum of its width: the unique non-zero
   value whose two's-complement negation wraps to itself (the 128-bit
   pattern is explicit: hi = min_int, lo = 0).  Representation-robust:
   it does not depend on how Int_value stores sign-extended low words. *)
let is_signed_min (v : Int_value.t) : bool =
  let open Int_value in
  v.signed
  && if v.width = 128 then v.bits_hi = Int64.min_int && v.bits_lo = 0L
     else not (is_zero v) && compare_vals v (neg v) = 0

(* The signed value -1 of the value's width. *)
let is_neg_one (v : Int_value.t) : bool =
  let open Int_value in
  v.signed
  && if v.width = 128 then v.bits_lo = -1L && v.bits_hi = -1L else v.bits_lo = -1L

(* Signed division overflows exactly when min / -1 is evaluated: the true
   quotient 2^(w-1) does not fit the width, so no deterministic exact
   value exists. Trap instead of inventing one. *)
let int_div_overflow (a : Int_value.t) (b : Int_value.t) : bool =
  is_signed_min a && is_neg_one b

let binop_int (vm : t) (op : Seed_mir.bin_op) (a : Int_value.t) (b : Int_value.t) : Vm_value.t =
  let open Int_value in
  match op with
  | Seed_mir.Add -> Vm_value.Int (add a b)
  | Seed_mir.Sub -> Vm_value.Int (sub a b)
  | Seed_mir.Mul -> Vm_value.Int (mul a b)
  | Seed_mir.Div | Seed_mir.Rem ->
      if int_div_overflow a b then err_trap vm "signed division overflow"
      else
        (try
           Vm_value.Int (if op = Seed_mir.Div then div a b else rem a b)
         with Division_by_zero -> err_trap vm "division by zero")
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
      if p.Seed_mir.local < 0 || p.Seed_mir.local >= Array.length frame.locals then
        err_trap vm "ref of out-of-range local";
      if List.exists (function Seed_mir.Deref -> true | _ -> false) p.Seed_mir.projections then
        (* computed-value source (e.g. `&*ptr`): the target is not a
           local subplace; keep a serialized copy in a fresh region;
           writes through this ref are a deterministic trap *)
        (match read_place vm frame p with
         | Ok v -> Vm_value.Ref (Vm_value.Region (vm_alloc_scalar vm v))
         | Error e -> err_trap vm (Vm_value.slot_error_string e))
      else
        (* real reference: record the target (frame, local, projections) *)
        Vm_value.Ref (Vm_value.Place (frame, p.Seed_mir.local, p.Seed_mir.projections))
  | Seed_mir.Aggregate (kind, ops) ->
      let vals = Array.of_list (List.map (eval_operand vm frame) ops) in
      (match kind with
       | Seed_mir.TupleAgg -> Vm_value.Tuple vals
       | Seed_mir.ArrayAgg -> Vm_value.Array vals
       | Seed_mir.StructCtor _ -> Vm_value.Struct vals
       | Seed_mir.EnumCtor (_, vid) -> Vm_value.Enum (Ids.Variant_index.to_int vid, vals)
       | Seed_mir.ClosureAgg inst -> Vm_value.Closure (inst, vals))
  | Seed_mir.BinaryOp (op, l, r) ->
      let lv = eval_operand vm frame l in
      let rv = eval_operand vm frame r in
      (match lv, rv with
       | Vm_value.Int a, Vm_value.Int b -> binop_int vm op a b
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
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to f64 (not representable in the seed)"
              else Vm_value.Float64 (Int64.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float32 f -> Vm_value.Float64 (Int64.bits_of_float (Int32.float_of_bits f))
          | Vm_value.Float64 f -> Vm_value.Float64 f
          | _ -> err_trap vm "invalid cast to f64")
      | Type_repr.Float Type_repr.F32 -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to f32 (not representable in the seed)"
              else Vm_value.Float32 (Int32.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float64 f -> Vm_value.Float32 (Int32.bits_of_float (Int64.float_of_bits f))
          | _ -> err_trap vm "invalid cast to f32")
      | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to a pointer (not representable in the seed)"
              else Vm_value.RawPtr { Vm_memory.region = Int64.to_int (Int_value.to_int64 i); offset = 0 }
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
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to char (not representable in the seed)"
              else Vm_value.Char (Uchar.of_int (Int64.to_int (Int_value.to_int64 i)))
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

(* Allocate a region holding the serialized bytes of a value (the
   computed-value refs).  An allocation failure is a deterministic trap,
   never a silent fallback. *)
and vm_alloc_scalar (vm : t) (v : Vm_value.t) : Vm_memory.pointer =
  let bytes = Vm_value.serialize v in
  let size = Bytes.length bytes in
  vm.alloc_bytes <- vm.alloc_bytes + size;
  if vm.alloc_bytes > vm.limits.max_alloc_bytes then err_trap vm "allocation limit exceeded";
  match Vm_memory.alloc vm.memory size 8 with
  | Error e -> err_trap vm ("allocation failed: " ^ Vm_memory.mem_error_string e)
  | Ok ptr -> (
      match Vm_memory.region_of vm.memory ptr with
      | Error e -> err_trap vm ("allocation failed: " ^ Vm_memory.mem_error_string e)
      | Ok r -> Bytes.blit bytes 0 r.Vm_memory.bytes 0 size);
      ptr

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
        | Vm_value.Int i ->
            if i.Int_value.width > 64 then
              err_trap vm "128-bit switch value (not representable in the seed)"
            else Int_value.to_int64 i
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
           check_fn_shape vm fn_idx;
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
           (* The return slot is the callee's declared return value.  For a
              Unit-typed return it may legitimately be left Uninitialized
              (return Unit then); for any other declared return type an
              uninitialized or moved/dropped slot at return is an invariant
              failure and traps — the VM never fabricates a value. *)
           let ret =
             match callee_frame.locals.(0) with
             | Vm_value.Live v -> v
             | Vm_value.Uninitialized ->
                 if fn.Seed_mir.locals.(0) = Type_repr.Unit then Vm_value.Unit
                 else
                   err_trap vm
                     (Printf.sprintf
                        "callee %s returned with an uninitialized return slot (declared return type %s is not unit)"
                        fn.Seed_mir.name (Seed_mir.print_type fn.Seed_mir.locals.(0)))
             | Vm_value.Moved | Vm_value.Dropped ->
                 err_trap vm
                   (Printf.sprintf "callee %s returned with a non-live return slot"
                      fn.Seed_mir.name)
           in
           vm.frames <- List.tl vm.frames;
           write_place vm frame dest ret;
           frame.block <- next;
           frame.stmt <- 0
       | Seed_mir.Intrinsic _ | Seed_mir.Extern _ as host_callee ->
           vm.host_calls <- vm.host_calls + 1;
           if vm.host_calls > vm.limits.max_host_calls then
             err_trap vm "host call limit exceeded";
           let ret = call_host vm host_callee arg_vals in
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

(* Host boundary: the executable closure is the Host binding table
   (audit §70). Dispatch resolves the registry index to a binding id and
   invokes the binding's `invoke`; a declared symbol without a binding
   fails closed, and an invoke error becomes a deterministic trap. *)
and call_host (vm : t) (callee : Seed_mir.callee) (args : Vm_value.t array) : Vm_value.t =
  let id =
    match callee with
    | Seed_mir.Intrinsic i -> Host.Intrinsic (Intrinsic_registry.Id.make i)
    | Seed_mir.Extern i -> Host.Extern (Extern_registry.Id.make i)
    | Seed_mir.User _ -> err_trap vm "internal: user call routed to host dispatch"
  in
  match Host.lookup_binding vm.host id with
  | None ->
      let label =
        match Host.name_of_host_id vm.host id with
        | Some name -> name
        | None -> (
            match callee with
            | Seed_mir.Intrinsic i ->
                Printf.sprintf "intrinsic#%d" (Intrinsic_registry.Id.to_int i)
            | Seed_mir.Extern i -> Printf.sprintf "extern#%d" (Extern_registry.Id.to_int i)
            | Seed_mir.User _ -> "?")
      in
      err_trap vm (Printf.sprintf "host call %s has no binding (fail-closed)" label)
  | Some b ->
      if Array.length args <> List.length b.Host.signature.Host.param_types then
        err_trap vm
          (Printf.sprintf "host call %s: arity mismatch (binding arity %d, got %d)"
             b.Host.name (List.length b.Host.signature.Host.param_types) (Array.length args));
      (match b.Host.invoke vm.host args with
       | Ok v -> v
       | Error msg -> err_trap vm (Printf.sprintf "host call %s: %s" b.Host.name msg))

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
          write_place vm frame p (Vm_value.Enum (Ids.Variant_index.to_int vid, payload))
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
let entry_frame_of ~(program : Seed_mir.program) ~(entry : Instance_id.t) ~(argv : string array) :
    (t * frame, string) result =
  let fn_index = Hashtbl.create 64 in
  Array.iteri (fun i fn -> Hashtbl.replace fn_index fn.Seed_mir.instance i) program.Seed_mir.functions;
  match Hashtbl.find_opt fn_index entry with
  | None -> Error "entry instance not found"
  | Some fn_idx ->
      (try
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
         check_fn_shape vm fn_idx;
         let fn = program.Seed_mir.functions.(fn_idx) in
         let entry_frame =
           { fn = fn_idx; locals = Array.make (Array.length fn.Seed_mir.locals) Vm_value.Uninitialized; block = fn.Seed_mir.entry; stmt = 0 }
         in
         Array.iteri (fun i s -> entry_frame.locals.(i) <- Vm_value.Live (Vm_value.String s)) argv;
         Ok (vm, entry_frame)
       with
      | Failure msg -> Error msg)

let run ~(program : Seed_mir.program) ~(entry : Instance_id.t) ~(argv : string array)
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
