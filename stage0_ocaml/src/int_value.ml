(* int_value.ml — Typed bitvector integers (audit §38, §67).

   Two's-complement wrapping arithmetic per the language's overflow
   model, on 8/16/32/64/128-bit signed/unsigned values. 128-bit values
   use (hi, lo) int64 pairs.

   Storage invariant for width <= 64: bits_hi = 0 and bits_lo is the
   w-bit value sign-extended to 64 bits when the value is signed and
   negative, and zero-extended (masked) otherwise.  Mir_verify's
   range check enforces this representation for MIR constants. *)

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

(* Reduce a value to its width: for width < 64 the low word is masked to
   the width's bits and then sign-extended (signed values) or left
   zero-extended; bits_hi is cleared for every width <= 64. *)
let truncate (v : t) : t =
  let w = v.width in
  if w = 128 then v
  else if w = 64 then { v with bits_hi = 0L }
  else begin
    let mask = Int64.pred (Int64.shift_left 1L w) in
    let lo = Int64.logand v.bits_lo mask in
    let hi = 0L in
    if v.signed && lo >= Int64.shift_left 1L (w - 1) then
      { v with bits_lo = Int64.logor lo (Int64.lognot mask); bits_hi = hi }
    else { v with bits_lo = lo; bits_hi = hi }
  end

(* Build a value from unsigned 64-bit words; the value is truncated
   deterministically to the width (wrapping semantics). *)
let of_words ~width ~signed ~bits_lo ~bits_hi : t =
  truncate { width; signed; bits_lo; bits_hi }

let of_int64 ~width ~signed (i : int64) : t = truncate { width; signed; bits_lo = i; bits_hi = 0L }

let to_int64 (v : t) : int64 =
  if v.width > 64 then invalid_arg "Int_value.to_int64: 128-bit";
  v.bits_lo

let is_zero (v : t) = v.bits_lo = 0L && v.bits_hi = 0L

let is_neg (v : t) =
  if v.width = 128 then (v.signed && v.bits_hi < 0L)
  else v.signed && v.bits_lo < 0L

let neg (v : t) : t =
  if v.width = 128 then begin
    (* two's complement: -x = ~x + 1, with the increment carry from the
       low word propagated into the high word *)
    let lo = Int64.add (Int64.lognot v.bits_lo) 1L in
    let carry = if v.bits_lo = 0L then 1L else 0L in
    let hi = Int64.add (Int64.lognot v.bits_hi) carry in
    truncate { v with bits_lo = lo; bits_hi = hi }
  end
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

(* High 64 bits of the unsigned 128-bit product of two 64-bit words
   (Hacker's Delight mulhu with 32-bit halves). *)
let mul_hi (a : int64) (b : int64) : int64 =
  let a0 = Int64.logand a 0xFFFFFFFFL in
  let a1 = Int64.shift_right_logical a 32 in
  let b0 = Int64.logand b 0xFFFFFFFFL in
  let b1 = Int64.shift_right_logical b 32 in
  let w0 = Int64.mul a0 b0 in
  let t = Int64.add (Int64.mul a1 b0) (Int64.shift_right_logical w0 32) in
  let w1 = Int64.add (Int64.mul a0 b1) (Int64.logand t 0xFFFFFFFFL) in
  Int64.add (Int64.mul a1 b1)
    (Int64.add (Int64.shift_right_logical t 32) (Int64.shift_right_logical w1 32))

let mul (a : t) (b : t) : t =
  if a.width = 128 then begin
    (* full 128x128 -> 128 (mod 2^128): lo*lo contributes both words,
       lo*hi and hi*lo contribute the high word *)
    let alo = a.bits_lo and ahi = a.bits_hi in
    let blo = b.bits_lo and bhi = b.bits_hi in
    let lo = Int64.mul alo blo in
    let hi = Int64.add (mul_hi alo blo) (Int64.add (Int64.mul alo bhi) (Int64.mul ahi blo)) in
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

(* Unsigned 128-bit long division (binary, MSB first): returns
   (q_hi, q_lo, r_hi, r_lo) with a = q*b + r and 0 <= r < b.
   b must be nonzero. *)
let divmod_unsigned_128 (a_hi : int64) (a_lo : int64) (b_hi : int64) (b_lo : int64) :
    int64 * int64 * int64 * int64 =
  let q_hi = ref 0L and q_lo = ref 0L in
  let r_hi = ref 0L and r_lo = ref 0L in
  for i = 127 downto 0 do
    let bit =
      if i >= 64 then Int64.logand (Int64.shift_right_logical a_hi (i - 64)) 1L
      else Int64.logand (Int64.shift_right_logical a_lo i) 1L
    in
    let rl = Int64.logor (Int64.shift_left !r_lo 1) bit in
    r_hi := Int64.logor (Int64.shift_left !r_hi 1) (Int64.shift_right_logical !r_lo 63);
    r_lo := rl;
    let ge =
      if !r_hi <> b_hi then Int64.unsigned_compare !r_hi b_hi > 0
      else Int64.unsigned_compare !r_lo b_lo >= 0
    in
    if ge then begin
      let borrow = if Int64.unsigned_compare !r_lo b_lo < 0 then 1L else 0L in
      r_lo := Int64.sub !r_lo b_lo;
      r_hi := Int64.sub (Int64.sub !r_hi b_hi) borrow;
      if i >= 64 then q_hi := Int64.logor !q_hi (Int64.shift_left 1L (i - 64))
      else q_lo := Int64.logor !q_lo (Int64.shift_left 1L i)
    end
  done;
  (!q_hi, !q_lo, !r_hi, !r_lo)

(* Magnitude (unsigned) words of a 128-bit value. *)
let magnitude_words (v : t) : int64 * int64 =
  if is_neg v then
    let m = neg v in
    (m.bits_hi, m.bits_lo)
  else (v.bits_hi, v.bits_lo)

let div (a : t) (b : t) : t =
  if is_zero b then raise Division_by_zero;
  if a.width = 128 then begin
    if a.signed then begin
      (* sign-magnitude division: divide the magnitudes, apply the sign;
         -2^127 / -1 = -2^127 (wraps, matching two's complement) *)
      let a_neg = is_neg a in
      let am_hi, am_lo = magnitude_words a in
      let bm_hi, bm_lo = magnitude_words b in
      let q_hi, q_lo, _, _ = divmod_unsigned_128 am_hi am_lo bm_hi bm_lo in
      let q = { width = 128; signed = true; bits_lo = q_lo; bits_hi = q_hi } in
      if a_neg <> is_neg b then neg q else q
    end
    else begin
      let q_hi, q_lo, _, _ = divmod_unsigned_128 a.bits_hi a.bits_lo b.bits_hi b.bits_lo in
      { width = 128; signed = false; bits_lo = q_lo; bits_hi = q_hi }
    end
  end
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
    if a.signed then begin
      (* sign-magnitude remainder, taking the dividend's sign *)
      let a_neg = is_neg a in
      let am_hi, am_lo = magnitude_words a in
      let bm_hi, bm_lo = magnitude_words b in
      let _, _, r_hi, r_lo = divmod_unsigned_128 am_hi am_lo bm_hi bm_lo in
      let r = { width = 128; signed = true; bits_lo = r_lo; bits_hi = r_hi } in
      if a_neg then neg r else r
    end
    else begin
      let _, _, r_hi, r_lo = divmod_unsigned_128 a.bits_hi a.bits_lo b.bits_hi b.bits_lo in
      { width = 128; signed = false; bits_lo = r_lo; bits_hi = r_hi }
    end
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

(* The shift count is the operand's actual mathematical value read as an
   unsigned 128-bit integer; counts >= 128 saturate at 128. *)
let shift_count (b : t) : int =
  if b.bits_hi <> 0L then 128
  else if Int64.unsigned_compare b.bits_lo 128L >= 0 then 128
  else Int64.to_int b.bits_lo

let shift_left (a : t) (b : t) : t =
  let n = shift_count b in
  if n >= a.width then zero a.width a.signed
  else if a.width = 128 then begin
    let hi, lo = shift_left_128 a.bits_hi a.bits_lo n in
    truncate { width = 128; signed = a.signed; bits_lo = lo; bits_hi = hi }
  end
  else truncate { a with bits_lo = Int64.shift_left a.bits_lo n }

let shift_right (a : t) (b : t) : t =
  let n = shift_count b in
  if n >= a.width then
    (* arithmetic shift by >= width sign-fills (all ones for negatives),
       logical shifts and non-negatives yield zero *)
    if a.signed && is_neg a then truncate { a with bits_lo = -1L; bits_hi = -1L }
    else zero a.width a.signed
  else if a.width = 128 then begin
    let hi, lo =
      if a.signed then shift_right_arith_128 a.bits_hi a.bits_lo n
      else shift_right_logical_128 a.bits_hi a.bits_lo n
    in
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
