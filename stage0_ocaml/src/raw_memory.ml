(* raw_memory.ml — the raw little-endian scalar layout shared by the
   host arena (Host) and the VM's typed raw-pointer deref (Vm).

   A `Raw` region (vm_memory.ml) holds the raw byte image of the values
   stored through C-ABI pointers: string/array as_ptr views, mem_alloc
   blocks, environment entries and libc buffers.  The layout of a scalar
   is its natural little-endian machine image:

     Int  w bits   ceil(w/8) bytes LE (w = 8/16/32/64/128)
     Bool          1 byte (0/1)
     Char          4 bytes LE (the UTF-32 code point)
     Float32       4 bytes LE
     Float64       8 bytes LE
     Ptr/PtrMut    8 bytes LE (the Vm_memory address codec)

   Non-scalar pointees (aggregates, String, collections) have no flat
   machine layout in the seed value model: the VM's raw deref falls back
   to the self-describing Vm_value.serialize image for those (the same
   image every computed-value region holds), and the host adapters copy
   them as opaque bytes.  A write and a read of the same pointee always
   use the same encoding, so the round-trip is exact. *)

type scalar =
  | SInt of int * bool  (* width in bits, signedness *)
  | SBool
  | SChar
  | SF32
  | SF64
  | SPtr

let int_width = function
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

let int_signed = function
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128
  | Type_repr.Int ->
      true
  | _ -> false

let classify (ty : Type_repr.t) : scalar option =
  match ty with
  | Type_repr.Int k -> Some (SInt (int_width k, int_signed k))
  | Type_repr.Bool -> Some SBool
  | Type_repr.Char -> Some SChar
  | Type_repr.Float Type_repr.F32 -> Some SF32
  | Type_repr.Float Type_repr.F64 -> Some SF64
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> Some SPtr
  | _ -> None

(* The byte size of a classified scalar. *)
let scalar_size = function
  | SInt (w, _) -> (w + 7) / 8
  | SBool -> 1
  | SChar -> 4
  | SF32 -> 4
  | SF64 -> 8
  | SPtr -> 8

(* The byte size of the raw image of `ty` (None when the value has no
   flat scalar layout). *)
let raw_size (ty : Type_repr.t) : int option =
  match classify ty with Some s -> Some (scalar_size s) | None -> None

let get_u8 (b : Bytes.t) (pos : int) : int = Char.code (Bytes.get b pos)

let put_u8 (b : Bytes.t) (pos : int) (v : int) : unit =
  Bytes.set b pos (Char.chr (v land 0xFF))

let u64_le (b : Bytes.t) (pos : int) (n : int) : int64 =
  let v = ref 0L in
  for i = 0 to n - 1 do
    v :=
      Int64.logor !v
        (Int64.shift_left (Int64.of_int (get_u8 b (pos + i))) (8 * i))
  done;
  !v

let put_u64_le (b : Bytes.t) (pos : int) (n : int) (v : int64) : unit =
  for i = 0 to n - 1 do
    put_u8 b (pos + i)
      (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * i)) 0xFFL))
  done

(* Encode a scalar value into its raw image.  None when the value does
   not inhabit the scalar. *)
let encode_with (s : scalar) (v : Vm_value.t) : Bytes.t option =
  match (s, v) with
  | SInt (w, _signed), Vm_value.Int i ->
      let n = (w + 7) / 8 in
      if i.Int_value.width > w then None
      else
        let b = Bytes.make n '\000' in
        put_u64_le b 0 (min n 8) i.Int_value.bits_lo;
        if w = 128 then put_u64_le b 8 8 i.Int_value.bits_hi;
        Some b
  | SBool, Vm_value.Bool bool ->
      Some (Bytes.make 1 (if bool then '\001' else '\000'))
  | SChar, Vm_value.Char c ->
      let b = Bytes.make 4 '\000' in
      put_u64_le b 0 4 (Int64.of_int (Uchar.to_int c));
      Some b
  | SF32, Vm_value.Float32 f ->
      let b = Bytes.make 4 '\000' in
      put_u64_le b 0 4 (Int64.logand (Int64.of_int32 f) 0xFFFFFFFFL);
      Some b
  | SF64, Vm_value.Float64 f ->
      let b = Bytes.make 8 '\000' in
      put_u64_le b 0 8 f;
      Some b
  | SPtr, Vm_value.RawPtr p ->
      let b = Bytes.make 8 '\000' in
      put_u64_le b 0 8 (Vm_memory.pointer_to_int64 p);
      Some b
  | SPtr, Vm_value.Null ->
      let b = Bytes.make 8 '\000' in
      put_u64_le b 0 8 0L;
      Some b
  | _ -> None

(* Decode the scalar `s` starting at `pos` in `bytes`.  Returns the value
   and the number of bytes consumed, or None when the buffer is
   truncated. *)
let decode_with (s : scalar) (bytes : Bytes.t) (pos : int) :
    (Vm_value.t * int) option =
  let len = Bytes.length bytes in
  let fits n = pos >= 0 && n >= 0 && pos <= len - n in
  match s with
  | SInt (w, signed) ->
      let n = (w + 7) / 8 in
      if not (fits n) then None
      else if w = 128 then
        let lo = u64_le bytes pos 8 in
        let hi = u64_le bytes (pos + 8) 8 in
        Some
          ( Vm_value.Int
              (Int_value.make ~width:128 ~signed ~bits_lo:lo ~bits_hi:hi),
            n )
      else
        Some
          ( Vm_value.Int
              (Int_value.of_int64 ~width:w ~signed (u64_le bytes pos n)),
            n )
  | SBool ->
      if not (fits 1) then None
      else Some (Vm_value.Bool (get_u8 bytes pos <> 0), 1)
  | SChar ->
      if not (fits 4) then None
      else
        let cp = Int64.to_int (u64_le bytes pos 4) in
        if cp < 0 || cp > 0x10FFFF then None
        else Some (Vm_value.Char (Uchar.of_int cp), 4)
  | SF32 ->
      if not (fits 4) then None
      else Some (Vm_value.Float32 (Int64.to_int32 (u64_le bytes pos 4)), 4)
  | SF64 ->
      if not (fits 8) then None
      else Some (Vm_value.Float64 (u64_le bytes pos 8), 8)
  | SPtr ->
      if not (fits 8) then None
      else Some (Vm_value.RawPtr (Vm_memory.pointer_of_int64 (u64_le bytes pos 8)), 8)

(* The typed entry points: classify the pointee type, then encode/decode
   its scalar image (None when the type has no flat scalar layout — the
   caller falls back to Vm_value.serialize/deserialize). *)
let encode (ty : Type_repr.t) (v : Vm_value.t) : Bytes.t option =
  match classify ty with Some s -> encode_with s v | None -> None

let decode (ty : Type_repr.t) (bytes : Bytes.t) (pos : int) :
    (Vm_value.t * int) option =
  match classify ty with Some s -> decode_with s bytes pos | None -> None
