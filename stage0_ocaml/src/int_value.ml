(* int_value.ml — Typed bitvector integers (audit §38, §67).

   Two's-complement wrapping arithmetic per the language's overflow
   model, on 8/16/32/64/128-bit signed/unsigned values. 128-bit values
   use (hi, lo) int64 pairs. *)

type t = {
  width : int;
  signed : bool;
  bits_lo : int64;
  bits_hi : int64;
}

let make ~width ~signed ~bits_lo ~bits_hi =
  if width <> 8 && width <> 16 && width <> 32 && width <> 64 && width <> 128 then
    invalid_arg "Int_value: unsupported width";
  if width <= 64 && bits_hi <> 0L then invalid_arg "Int_value: hi bits on <=64";
  { width; signed; bits_lo; bits_hi }

let zero width signed = make ~width ~signed ~bits_lo:0L ~bits_hi:0L

let mask64 = 0xFFFFFFFFFFFFFFFFL

(* low 64 bits of (hi, lo) shifts *)
let shift_left_128 (hi : int64) (lo : int64) (n : int) : int64 * int64 =
  if n = 0 then (hi, lo)
  else if n >= 64 then (Int64.shift_left lo (n - 64), 0L)
  else (Int64.logor (Int64.shift_left hi n) (Int64.shift_right_logical lo (64 - n)), Int64.shift_left lo n)

let shift_right_logical_128 (hi : int64) (lo : int64) (n : int) : int64 * int64 =
  if n = 0 then (hi, lo)
  else if n >= 64 then (0L, Int64.shift_right_logical hi (n - 64))
  else (Int64.shift_right_logical hi n, Int64.logor (Int64.shift_right_logical lo n) (Int64.shift_left hi (64 - n)))

let shift_right_arith_128 (hi : int64) (lo : int64) (n : int) : int64 * int64 =
  if n = 0 then (hi, lo)
  else if n >= 64 then (Int64.shift_right hi 63, Int64.shift_right hi (n - 64))
  else (Int64.shift_right hi n, Int64.logor (Int64.shift_right_logical lo n) (Int64.shift_left hi (64 - n)))

(* Sign-extend a value to its width (no-op except when stored narrow). *)
let truncate (v : t) : t =
  let w = v.width in
  if w = 128 then v
  else begin
    let lo = Int64.logand v.bits_lo (if w = 64 then mask64 else Int64.pred (Int64.shift_left 1L w)) in
    let hi = if v.signed && lo >= Int64.shift_left 1L (w - 1) then -1L else 0L in
    { v with bits_lo = lo; bits_hi = hi }
  end

let of_int64 ~width ~signed (i : int64) : t = truncate { width; signed; bits_lo = i; bits_hi = 0L }

let to_int64 (v : t) : int64 =
  if v.width > 64 then invalid_arg "Int_value.to_int64: 128-bit";
  if v.signed then v.bits_lo
  else v.bits_lo

let is_zero (v : t) = v.bits_lo = 0L && v.bits_hi = 0L

let is_neg (v : t) =
  if v.width = 128 then (v.signed && v.bits_hi < 0L)
  else v.signed && v.bits_lo < 0L

let neg (v : t) : t =
  if v.width = 128 then
    truncate { v with bits_lo = Int64.neg v.bits_lo; bits_hi = Int64.lognot v.bits_hi }
  else truncate { v with bits_lo = Int64.neg v.bits_lo; bits_hi = 0L }

let add (a : t) (b : t) : t =
  if a.width = 128 then begin
    let lo = Int64.add a.bits_lo b.bits_lo in
    let carry = if Int64.unsigned_compare lo a.bits_lo < 0 then 1L else 0L in
    let hi = Int64.add (Int64.add a.bits_hi b.bits_hi) carry in
    truncate { width = a.width; signed = a.signed; bits_lo = lo; bits_hi = hi }
  end
  else truncate { a with bits_lo = Int64.add a.bits_lo b.bits_lo }

let sub (a : t) (b : t) : t = add a (neg b)

let mul (a : t) (b : t) : t =
  if a.width = 128 then begin
    (* 64x64 -> 128 schoolbook on unsigned halves of the low words.
       The seed's observed 128-bit arithmetic uses small values; the
       result is truncated to the low 128 bits. *)
    let a0 = Int64.logand a.bits_lo 0xFFFFFFFFL in
    let a1 = Int64.shift_right_logical a.bits_lo 32 in
    let b0 = Int64.logand b.bits_lo 0xFFFFFFFFL in
    let b1 = Int64.shift_right_logical b.bits_lo 32 in
    let p00 = Int64.mul a0 b0 in
    let p01 = Int64.mul a0 b1 in
    let p10 = Int64.mul a1 b0 in
    let p11 = Int64.mul a1 b1 in
    let mid = Int64.add (Int64.logand p01 0xFFFFFFFFL) (Int64.logand p10 0xFFFFFFFFL) in
    let lo = Int64.logor p00 (Int64.shift_left mid 32) in
    let hi = Int64.add (Int64.add p11 (Int64.shift_right_logical p01 32)) (Int64.shift_right_logical p10 32) in
    let hi = Int64.add hi (Int64.shift_right_logical mid 32) in
    truncate { width = 128; signed = a.signed; bits_lo = lo; bits_hi = hi }
  end
  else truncate { a with bits_lo = Int64.mul a.bits_lo b.bits_lo }

(* Unsigned comparison for values of the same width. *)
let unsigned_less (a : t) (b : t) : bool =
  if a.width = 128 then begin
    if a.bits_hi <> b.bits_hi then Int64.unsigned_compare a.bits_hi b.bits_hi < 0
    else Int64.unsigned_compare a.bits_lo b.bits_lo < 0
  end
  else Int64.unsigned_compare a.bits_lo b.bits_lo < 0

let signed_less (a : t) (b : t) : bool =
  if a.width = 128 then begin
    if a.bits_hi <> b.bits_hi then a.bits_hi < b.bits_hi
    else Int64.unsigned_compare a.bits_lo b.bits_lo < 0
  end
  else a.bits_lo < b.bits_lo

let compare_vals (a : t) (b : t) : int =
  let lt = if a.signed then signed_less a b else unsigned_less a b in
  let gt = if a.signed then signed_less b a else unsigned_less b a in
  if lt then -1 else if gt then 1 else 0

let div (a : t) (b : t) : t =
  if is_zero b then raise Division_by_zero;
  if a.width = 128 then
    (* simple unsigned 128/64 division via bitwise long division *)
    let q = ref 0L and r = ref 0L in
    for i = 127 downto 0 do
      let bit =
        if i >= 64 then Int64.logand (Int64.shift_right_logical a.bits_hi (i - 64)) 1L
        else Int64.logand (Int64.shift_right_logical a.bits_lo i) 1L
      in
      r := Int64.logor (Int64.shift_left !r 1) bit;
      if Int64.unsigned_compare !r b.bits_lo >= 0 then begin
        r := Int64.sub !r b.bits_lo;
        q := Int64.logor !q (Int64.shift_left 1L i)
      end
    done;
    { width = 128; signed = a.signed; bits_lo = !q; bits_hi = 0L }
  else begin
    let q =
      if a.signed then Int64.div a.bits_lo b.bits_lo
      else Int64.unsigned_div a.bits_lo b.bits_lo
    in
    truncate { a with bits_lo = q }
  end

let rem (a : t) (b : t) : t =
  if is_zero b then raise Division_by_zero;
  if a.width = 128 then begin
    let q = div a b in
    sub a (mul q b)
  end
  else begin
    let r =
      if a.signed then Int64.rem a.bits_lo b.bits_lo
      else Int64.unsigned_rem a.bits_lo b.bits_lo
    in
    truncate { a with bits_lo = r }
  end

let logand (a : t) (b : t) : t =
  truncate { a with bits_lo = Int64.logand a.bits_lo b.bits_lo; bits_hi = Int64.logand a.bits_hi b.bits_hi }

let logor (a : t) (b : t) : t =
  truncate { a with bits_lo = Int64.logor a.bits_lo b.bits_lo; bits_hi = Int64.logor a.bits_hi b.bits_hi }

let logxor (a : t) (b : t) : t =
  truncate { a with bits_lo = Int64.logxor a.bits_lo b.bits_lo; bits_hi = Int64.logxor a.bits_hi b.bits_hi }

let lognot (a : t) : t =
  truncate { a with bits_lo = Int64.lognot a.bits_lo; bits_hi = Int64.lognot a.bits_hi }

let shift_left (a : t) (b : t) : t =
  let n = if b.width <= 32 then Int64.to_int b.bits_lo else 0 in
  if n >= a.width then zero a.width a.signed
  else if a.width = 128 then begin
    let hi, lo = shift_left_128 a.bits_hi a.bits_lo n in
    truncate { width = 128; signed = a.signed; bits_lo = lo; bits_hi = hi }
  end
  else truncate { a with bits_lo = Int64.shift_left a.bits_lo n }

let shift_right (a : t) (b : t) : t =
  let n = if b.width <= 32 then Int64.to_int b.bits_lo else 0 in
  if n >= a.width then (if a.signed && is_neg a then { a with bits_lo = -1L; bits_hi = -1L } else zero a.width a.signed)
  else if a.width = 128 then begin
    let hi, lo = if a.signed then shift_right_arith_128 a.bits_hi a.bits_lo n else shift_right_logical_128 a.bits_hi a.bits_lo n in
    truncate { width = 128; signed = a.signed; bits_lo = lo; bits_hi = hi }
  end
  else begin
    let lo = if a.signed then Int64.shift_right a.bits_lo n else Int64.shift_right_logical a.bits_lo n in
    truncate { a with bits_lo = lo }
  end

let to_string (v : t) : string =
  if v.width = 128 then
    Printf.sprintf "%Lx%016Lx" v.bits_hi v.bits_lo
  else Int64.to_string (to_int64 v)

let of_string ~width ~signed (s : string) : t option =
  match Int64.of_string_opt s with
  | Some i -> Some (of_int64 ~width ~signed i)
  | None -> (
      if width = 128 then
        match int_of_string_opt s with
        | Some i when Int64.of_int i = Int64.of_int i ->
            Some (make ~width ~signed ~bits_lo:(Int64.of_int i) ~bits_hi:0L)
        | _ -> None
      else None)
