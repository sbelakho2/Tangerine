(* vm_memory.ml — Simulated raw memory (audit §40, §69).

   Raw Tangerine pointers are (region id, offset) pairs into a region
   table; every load/store checks liveness, bounds and alignment.
   Access after free is a deterministic VM error — never an OCaml
   segfault. *)

type pointer = {
  region : int;
  offset : int;
}

type region = {
  mutable live : bool;
  bytes : Bytes.t;
  alignment : int;
}

type t = {
  mutable regions : region array;
  mutable next_region : int;
}

let create () = { regions = [||]; next_region = 0 }

type mem_error =
  | DeadRegion of pointer
  | OutOfBounds of pointer * int  (* pointer, access size *)
  | Misaligned of pointer * int
  | BadRegion of int
  | Overflow of string

let mem_error_string = function
  | DeadRegion p -> Printf.sprintf "access to freed region %d at offset %d" p.region p.offset
  | OutOfBounds (p, sz) -> Printf.sprintf "out-of-bounds access region %d offset %d size %d" p.region p.offset sz
  | Misaligned (p, al) -> Printf.sprintf "misaligned access region %d offset %d (alignment %d)" p.region p.offset al
  | BadRegion r -> Printf.sprintf "invalid region id %d" r
  | Overflow m -> Printf.sprintf "pointer arithmetic overflow: %s" m

let alloc (m : t) (size : int) (alignment : int) : (pointer, mem_error) result =
  let region_id = m.next_region in
  m.next_region <- m.next_region + 1;
  let region = { live = true; bytes = Bytes.make (max 0 size) '\000'; alignment = max 1 alignment } in
  m.regions <- Array.append m.regions [| region |];
  Ok { region = region_id; offset = 0 }

let alloc_bytes (m : t) (size : int) : (pointer, mem_error) result = alloc m size 1

let free (m : t) (p : pointer) : unit =
  if p.region >= 0 && p.region < Array.length m.regions then
    m.regions.(p.region).live <- false

let region_of (m : t) (p : pointer) : (region, mem_error) result =
  if p.region < 0 || p.region >= Array.length m.regions then Error (BadRegion p.region)
  else
    let r = m.regions.(p.region) in
    if not r.live then Error (DeadRegion p) else Ok r

let check_bounds (r : region) (p : pointer) (size : int) (alignment : int) :
    (unit, mem_error) result =
  if size < 0 then Error (Overflow "negative size")
  else if p.offset < 0 || p.offset > Bytes.length r.bytes - size then
    Error (OutOfBounds (p, size))
  else if alignment > 1 && p.offset mod alignment <> 0 then
    Error (Misaligned (p, alignment))
  else Ok ()

let load_u8 (m : t) (p : pointer) : (int, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 1 1 with
      | Error e -> Error e
      | Ok () -> Ok (Char.code (Bytes.get r.bytes p.offset)))

let load_u16 (m : t) (p : pointer) : (int, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 2 2 with
      | Error e -> Error e
      | Ok () ->
          let b0 = Char.code (Bytes.get r.bytes p.offset) in
          let b1 = Char.code (Bytes.get r.bytes (p.offset + 1)) in
          Ok (b0 lor (b1 lsl 8)))

let load_u32 (m : t) (p : pointer) : (int32, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 4 4 with
      | Error e -> Error e
      | Ok () ->
          let b0 = Char.code (Bytes.get r.bytes p.offset) in
          let b1 = Char.code (Bytes.get r.bytes (p.offset + 1)) in
          let b2 = Char.code (Bytes.get r.bytes (p.offset + 2)) in
          let b3 = Char.code (Bytes.get r.bytes (p.offset + 3)) in
          Ok
            (Int32.logor
               (Int32.logor (Int32.of_int b0) (Int32.shift_left (Int32.of_int b1) 8))
               (Int32.logor (Int32.shift_left (Int32.of_int b2) 16) (Int32.shift_left (Int32.of_int b3) 24))))

let load_u64 (m : t) (p : pointer) : (int64, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 8 8 with
      | Error e -> Error e
      | Ok () ->
          let v = ref 0L in
          for i = 0 to 7 do
            let b = Char.code (Bytes.get r.bytes (p.offset + i)) in
            v := Int64.logor !v (Int64.shift_left (Int64.of_int b) (8 * i))
          done;
          Ok !v)

let load_i8 (m : t) (p : pointer) : (int, mem_error) result =
  match load_u8 m p with
  | Error e -> Error e
  | Ok b -> if b >= 0x80 then Ok (b - 0x100) else Ok b

let load_i16 (m : t) (p : pointer) : (int, mem_error) result =
  match load_u16 m p with
  | Error e -> Error e
  | Ok b -> if b >= 0x8000 then Ok (b - 0x10000) else Ok b

let load_i32 (m : t) (p : pointer) : (int32, mem_error) result = load_u32 m p
let load_i64 (m : t) (p : pointer) : (int64, mem_error) result = load_u64 m p

let load_f32 (m : t) (p : pointer) : (int32, mem_error) result = load_u32 m p
let load_f64 (m : t) (p : pointer) : (int64, mem_error) result = load_u64 m p

let store_u8 (m : t) (p : pointer) (v : int) : (unit, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 1 1 with
      | Error e -> Error e
      | Ok () ->
          Bytes.set r.bytes p.offset (Char.chr (v land 0xFF));
          Ok ())

let store_u16 (m : t) (p : pointer) (v : int) : (unit, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 2 2 with
      | Error e -> Error e
      | Ok () ->
          Bytes.set r.bytes p.offset (Char.chr (v land 0xFF));
          Bytes.set r.bytes (p.offset + 1) (Char.chr ((v lsr 8) land 0xFF));
          Ok ())

let store_u32 (m : t) (p : pointer) (v : int32) : (unit, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 4 4 with
      | Error e -> Error e
      | Ok () ->
          for i = 0 to 3 do
            Bytes.set r.bytes (p.offset + i) (Char.chr (Int32.to_int (Int32.shift_right_logical v (8 * i)) land 0xFF))
          done;
          Ok ())

let store_u64 (m : t) (p : pointer) (v : int64) : (unit, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> (
      match check_bounds r p 8 8 with
      | Error e -> Error e
      | Ok () ->
          for i = 0 to 7 do
            Bytes.set r.bytes (p.offset + i) (Char.chr (Int64.to_int (Int64.shift_right_logical v (8 * i)) land 0xFF))
          done;
          Ok ())

let store_i8 = store_u8
let store_i16 = store_u16
let store_i32 = store_u32
let store_i64 = store_u64
let store_f32 = store_u32
let store_f64 = store_u64

(* memcpy with overlap handling. *)
let memcpy (m : t) (dst : pointer) (src : pointer) (len : int) : (unit, mem_error) result =
  match region_of m src with
  | Error e -> Error e
  | Ok rs -> (
      match region_of m dst with
      | Error e -> Error e
      | Ok rd -> (
          match check_bounds rs src len 1 with
          | Error e -> Error e
          | Ok () -> (
              match check_bounds rd dst len 1 with
              | Error e -> Error e
              | Ok () ->
                  let same = dst.region = src.region in
                  let overlap = same && abs (dst.offset - src.offset) < len in
                  if not overlap then
                    Bytes.blit rs.bytes src.offset rd.bytes dst.offset len
                  else if dst.offset > src.offset then
                    for i = len - 1 downto 0 do
                      Bytes.set rd.bytes (dst.offset + i) (Bytes.get rs.bytes (src.offset + i))
                    done
                  else
                    for i = 0 to len - 1 do
                      Bytes.set rd.bytes (dst.offset + i) (Bytes.get rs.bytes (src.offset + i))
                    done;
                  Ok ())))

(* Pointer arithmetic with overflow checks. *)
let offset (m : t) (p : pointer) (delta : int) : (pointer, mem_error) result =
  ignore m;
  let off = Int64.add (Int64.of_int p.offset) (Int64.of_int delta) in
  if Int64.compare off (Int64.of_int max_int) > 0 || Int64.compare off (Int64.of_int min_int) < 0 then
    Error (Overflow "offset")
  else Ok { p with offset = Int64.to_int off }

let bytes_of_region (m : t) (p : pointer) : (Bytes.t, mem_error) result =
  match region_of m p with
  | Error e -> Error e
  | Ok r -> Ok r.bytes
