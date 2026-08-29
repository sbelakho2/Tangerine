(* vm_value.ml — VM values with the slot-state ownership checker
   (audit §31, §37, §39).

   Values are immutable trees.  The seed's only heap-like objects are
   region-backed references (`Ref (Region p)` — the computed-value refs);
   their regions are freed by the recursive drop glue (see drop_glue). *)

type t =
  | Unit
  | Bool of bool
  | Int of Int_value.t
  | Float32 of int32
  | Float64 of int64
  | Char of Uchar.t
  | String of string
  | Tuple of t array
  | Struct of t array
  | Enum of int * t array          (* variant index, payload *)
  | Array of t array
  | Function of Instance_id.t
  | Closure of Instance_id.t * t array
  | RawPtr of Vm_memory.pointer
  | Ref of ref_target
  | Null

(* Reference targets (the audit's real-references rule):
   - `Place (frame, local, projections)` — a REAL reference: the target
     is a live place in an execution frame; reads resolve to the target
     place and writes through a RefMut resolve to it and write there;
   - `Region p` — a computed-value reference (the source had no place,
     e.g. `&*ptr`): the value is kept as a copy in a fresh region; reads
     load the serialized copy back, and WRITES THROUGH IT ARE A
     DETERMINISTIC TRAP (no silent divergence). *)
and ref_target =
  | Place of frame * int * Seed_mir.projection list
  | Region of Vm_memory.pointer

(* An execution frame identity.  A real reference records the target
   frame RECORD (not a name): the record lives as long as any value
   references it, so reads/writes through the ref always reach the exact
   frame that created it — including refs passed down into callees. *)
and frame = {
  fn : int;
  locals : slot array;
  statics : slot array;  (* the GLOBAL storage: index = -1 - place.local *)
  mutable block : int;
  mutable stmt : int;
}

(* ── Slot-state ownership (audit §31) ──────────────────────────── *)

and slot =
  | Uninitialized
  | Live of t
  | Moved
  | Dropped

type slot_error =
  | ReadMoved
  | ReadUninitialized
  | MoveMoved
  | SlotOob of int
  | DropDropped
  | InitializeLive
  | InitializeDropped

let slot_error_string = function
  | ReadMoved -> "read of a moved slot"
  | ReadUninitialized -> "read of an uninitialized slot"
  | SlotOob i -> "static slot out of bounds: " ^ string_of_int i
  | MoveMoved -> "move of a moved slot"
  | DropDropped -> "drop of a dropped slot"
  | InitializeLive -> "initialization of a live slot"
  | InitializeDropped -> "initialization of a dropped slot"

(* Read: requires Live (or Uninitialized for non-owned scalars — the
   caller decides; this checker is strict for owned values). *)
let read_slot (s : slot) : (t, slot_error) result =
  match s with
  | Live v -> Ok v
  | Moved -> Error ReadMoved
  | Dropped -> Error ReadMoved
  | Uninitialized -> Error ReadUninitialized

let move_slot (s : slot) : (t * slot, slot_error) result =
  match s with
  | Live v -> Ok (v, Moved)
  | Moved -> Error MoveMoved
  | Dropped -> Error MoveMoved
  | Uninitialized -> Error ReadUninitialized

let drop_slot (s : slot) : (slot, slot_error) result =
  match s with
  | Live _ -> Ok Dropped
  | Dropped -> Error DropDropped
  | Moved -> Ok Moved
  | Uninitialized -> Ok Uninitialized

let init_slot (s : slot) (v : t) : (slot, slot_error) result =
  match s with
  | Live _ -> Error InitializeLive
  | Dropped -> Error InitializeDropped
  | Uninitialized | Moved -> Ok (Live v)

(* Assign semantics: overwrite a live slot, initialize an empty one. *)
let write_slot (s : slot) (v : t) : (slot, slot_error) result =
  match s with
  | Live _ | Uninitialized | Moved -> Ok (Live v)
  | Dropped -> Error InitializeDropped

(* Machine-readable slot state (self-check helper). *)
let slot_state (s : slot) : string =
  match s with
  | Uninitialized -> "uninitialized"
  | Live _ -> "live"
  | Moved -> "moved"
  | Dropped -> "dropped"

(* ── Structural helpers ─────────────────────────────────────────── *)

let rec equal (a : t) (b : t) : bool =
  match a, b with
  | Unit, Unit -> true
  | Bool x, Bool y -> x = y
  | Int x, Int y -> Int_value.compare_vals x y = 0
  | Float32 x, Float32 y -> Int32.compare x y = 0
  | Float64 x, Float64 y -> Int64.compare x y = 0
  | Char x, Char y -> Uchar.equal x y
  | String x, String y -> x = y
  | Tuple x, Tuple y | Struct x, Struct y | Array x, Array y ->
      Array.length x = Array.length y && Array.for_all2 equal x y
  | Enum (i, x), Enum (j, y) -> i = j && Array.length x = Array.length y && Array.for_all2 equal x y
  | Function a, Function b -> Instance_id.compare a b = 0
  | Closure (a, ca), Closure (b, cb) ->
      Instance_id.compare a b = 0 && Array.length ca = Array.length cb && Array.for_all2 equal ca cb
  | RawPtr a, RawPtr b ->
      a.Vm_memory.region = b.Vm_memory.region && a.Vm_memory.offset = b.Vm_memory.offset
  | Ref a, Ref b -> (
      match a, b with
      | Place (f1, l1, p1), Place (f2, l2, p2) ->
          f1 == f2 && l1 = l2 && p1 = p2
      | Region p1, Region p2 ->
          p1.Vm_memory.region = p2.Vm_memory.region && p1.Vm_memory.offset = p2.Vm_memory.offset
      | _ -> false)
  | Null, Null -> true
  | _ -> false

(* ── Deterministic byte serialization (audit: pointer deref) ─────────

   Self-describing little-endian format; every serializable value
   round-trips (serialize; deserialize = the value):

     Unit               01
     Bool               02 + 1 byte (0/1)
     Char               03 + 4 bytes LE (utf-32 code point)
     Int                04 + width byte + signed byte (0/1)
                            + 8 bytes LE (bits_lo)
                            + 8 bytes LE (bits_hi; width 128 only)
     Float32            05 + 4 bytes LE
     Float64            06 + 8 bytes LE
     String             07 + 8-byte LE length + utf-8 bytes
     Tuple              08 + 8-byte LE count + elements
     Struct             09 + 8-byte LE count + elements
     Array              0A + 8-byte LE count + elements
     Enum               0B + 8-byte LE variant tag + 8-byte LE count
                            + elements
     RawPtr             0C + 8-byte LE region + 8-byte LE offset
     Ref (Region p)     0D + 8-byte LE region + 8-byte LE offset

   Function / Closure / Ref (Place _) / Null are not serializable (a
   deterministic trap; they are execution-context values). *)

let put_u32 (buf : Buffer.t) (v : int32) : unit =
  for i = 0 to 3 do
    Buffer.add_char buf
      (Char.chr (Int32.to_int (Int32.shift_right_logical v (8 * i)) land 0xFF))
  done

let put_u64 (buf : Buffer.t) (v : int64) : unit =
  for i = 0 to 7 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.shift_right_logical v (8 * i)) land 0xFF))
  done

let rec serialize_value (buf : Buffer.t) (v : t) : unit =
  match v with
  | Unit -> Buffer.add_char buf (Char.chr 0x01)
  | Bool b ->
      Buffer.add_char buf (Char.chr 0x02);
      Buffer.add_char buf (if b then Char.chr 1 else Char.chr 0)
  | Char c ->
      Buffer.add_char buf (Char.chr 0x03);
      put_u32 buf (Int32.of_int (Uchar.to_int c))
  | Int i ->
      Buffer.add_char buf (Char.chr 0x04);
      Buffer.add_char buf (Char.chr i.Int_value.width);
      Buffer.add_char buf (if i.Int_value.signed then Char.chr 1 else Char.chr 0);
      put_u64 buf i.Int_value.bits_lo;
      if i.Int_value.width = 128 then put_u64 buf i.Int_value.bits_hi
  | Float32 f ->
      Buffer.add_char buf (Char.chr 0x05);
      put_u32 buf f
  | Float64 f ->
      Buffer.add_char buf (Char.chr 0x06);
      put_u64 buf f
  | String s ->
      Buffer.add_char buf (Char.chr 0x07);
      put_u64 buf (Int64.of_int (String.length s));
      Buffer.add_string buf s
  | Tuple elems ->
      Buffer.add_char buf (Char.chr 0x08);
      put_u64 buf (Int64.of_int (Array.length elems));
      Array.iter (serialize_value buf) elems
  | Struct elems ->
      Buffer.add_char buf (Char.chr 0x09);
      put_u64 buf (Int64.of_int (Array.length elems));
      Array.iter (serialize_value buf) elems
  | Array elems ->
      Buffer.add_char buf (Char.chr 0x0A);
      put_u64 buf (Int64.of_int (Array.length elems));
      Array.iter (serialize_value buf) elems
  | Enum (tag, payload) ->
      Buffer.add_char buf (Char.chr 0x0B);
      put_u64 buf (Int64.of_int tag);
      put_u64 buf (Int64.of_int (Array.length payload));
      Array.iter (serialize_value buf) payload
  | RawPtr p ->
      Buffer.add_char buf (Char.chr 0x0C);
      put_u64 buf (Int64.of_int p.Vm_memory.region);
      put_u64 buf (Int64.of_int p.Vm_memory.offset)
  | Ref (Region p) ->
      Buffer.add_char buf (Char.chr 0x0D);
      put_u64 buf (Int64.of_int p.Vm_memory.region);
      put_u64 buf (Int64.of_int p.Vm_memory.offset)
  | Ref (Place _) | Function _ | Closure _ | Null ->
      failwith
        "vm serialization: value is not serializable (ref to a place / function / closure / null)"

let serialize (v : t) : Bytes.t =
  let buf = Buffer.create 32 in
  serialize_value buf v;
  Bytes.of_string (Buffer.contents buf)

(* ── Deserialization ─────────────────────────────────────────────── *)

type cursor = { bytes : Bytes.t; mutable pos : int }

let cursor_take (c : cursor) (n : int) : Bytes.t =
  if n < 0 || c.pos < 0 || c.pos > Bytes.length c.bytes - n then
    failwith "vm serialization: truncated value";
  let b = Bytes.sub c.bytes c.pos n in
  c.pos <- c.pos + n;
  b

let cursor_u8 (c : cursor) : int =
  if c.pos >= Bytes.length c.bytes then failwith "vm serialization: truncated value";
  let b = Char.code (Bytes.get c.bytes c.pos) in
  c.pos <- c.pos + 1;
  b

let cursor_u32 (c : cursor) : int32 =
  let b = cursor_take c 4 in
  let v = ref 0l in
  for i = 0 to 3 do
    v := Int32.logor !v (Int32.shift_left (Int32.of_int (Char.code (Bytes.get b i))) (8 * i))
  done;
  !v

let cursor_u64 (c : cursor) : int64 =
  let b = cursor_take c 8 in
  let v = ref 0L in
  for i = 0 to 7 do
    v := Int64.logor !v (Int64.shift_left (Int64.of_int (Char.code (Bytes.get b i))) (8 * i))
  done;
  !v

let cursor_count (c : cursor) : int =
  let n = cursor_u64 c in
  if n < 0L || Int64.compare n (Int64.of_int max_int) > 0 then
    failwith "vm serialization: invalid element count";
  Int64.to_int n

let rec deserialize_value (c : cursor) : t =
  match cursor_u8 c with
  | 0x01 -> Unit
  | 0x02 -> Bool (cursor_u8 c <> 0)
  | 0x03 ->
      let cp = Int32.to_int (cursor_u32 c) in
      if cp < 0 || cp > 0x10FFFF then failwith "vm serialization: invalid char code point";
      Char (Uchar.of_int cp)
  | 0x04 ->
      let width = cursor_u8 c in
      let signed = cursor_u8 c <> 0 in
      let lo = cursor_u64 c in
      let hi = if width = 128 then cursor_u64 c else 0L in
      (try Int (Int_value.make ~width ~signed ~bits_lo:lo ~bits_hi:hi)
       with Invalid_argument _ -> failwith "vm serialization: invalid int width")
  | 0x05 -> Float32 (cursor_u32 c)
  | 0x06 -> Float64 (cursor_u64 c)
  | 0x07 ->
      let len = cursor_count c in
      String (Bytes.to_string (cursor_take c len))
  | 0x08 -> Tuple (cursor_elems c)
  | 0x09 -> Struct (cursor_elems c)
  | 0x0A -> Array (cursor_elems c)
  | 0x0B ->
      let tag = cursor_count c in
      Enum (tag, cursor_elems c)
  | 0x0C ->
      let region = cursor_count c in
      let offset = cursor_count c in
      RawPtr { Vm_memory.region; offset }
  | 0x0D ->
      let region = cursor_count c in
      let offset = cursor_count c in
      Ref (Region { Vm_memory.region; offset })
  | tag -> failwith (Printf.sprintf "vm serialization: unknown tag 0x%02x" tag)

and cursor_elems (c : cursor) : t array =
  let n = cursor_count c in
  Array.init n (fun _ -> deserialize_value c)

let deserialize (bytes : Bytes.t) : t =
  deserialize_value { bytes; pos = 0 }

(* ── Recursive drop glue (audit: recursive drop) ────────────────────

   The drop transition applied to a value's CONTAINED components before
   the owning slot transitions (vm.ml do_drop): aggregates are visited
   depth-first (a contained value's own glue runs before the next
   sibling).  The seed's only owned heap object is a region-backed
   reference (a computed-value ref); dropping one frees its region
   deterministically — a second free (a double-drop through copied
   refs) traps.  Raw pointers and place-backed references are not owned
   and are left untouched. *)
let rec drop_glue (m : Vm_memory.t) (v : t) : unit =
  match v with
  | Tuple elems | Struct elems | Array elems -> Array.iter (drop_glue m) elems
  | Enum (_, payload) -> Array.iter (drop_glue m) payload
  | Ref (Region p) -> (
      match Vm_memory.free m p with
      | Ok () -> ()
      | Error e -> failwith ("vm drop glue: " ^ Vm_memory.mem_error_string e))
  | Unit | Bool _ | Int _ | Float32 _ | Float64 _ | Char _ | String _
  | Function _ | Closure _ | RawPtr _ | Ref (Place _) | Null ->
      ()
