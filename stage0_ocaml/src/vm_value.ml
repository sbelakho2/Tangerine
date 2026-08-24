(* vm_value.ml — VM values with the slot-state ownership checker
   (audit §31, §37, §39). *)

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
  | Function of Ids.Instance_id.t
  | Closure of Ids.Instance_id.t * t array
  | RawPtr of Vm_memory.pointer
  | Ref of Vm_memory.pointer
  | Null

(* ── Slot-state ownership (audit §31) ──────────────────────────── *)

type slot =
  | Uninitialized
  | Live of t
  | Moved
  | Dropped

type slot_error =
  | ReadMoved
  | ReadUninitialized
  | MoveMoved
  | DropDropped
  | InitializeLive
  | InitializeDropped

let slot_error_string = function
  | ReadMoved -> "read of a moved slot"
  | ReadUninitialized -> "read of an uninitialized slot"
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
  | Function a, Function b -> Ids.Instance_id.compare a b = 0
  | Closure (a, ca), Closure (b, cb) ->
      Ids.Instance_id.compare a b = 0 && Array.length ca = Array.length cb && Array.for_all2 equal ca cb
  | RawPtr a, RawPtr b | Ref a, Ref b -> a.Vm_memory.region = b.Vm_memory.region && a.Vm_memory.offset = b.Vm_memory.offset
  | Null, Null -> true
  | _ -> false
