(* big_nat.ml — Small unsigned arbitrary-precision integer (no GMP).

   Little-endian 32-bit limbs. The seed is dependency-free; this is enough
   for literal magnitude parsing and range decisions. *)

type t = int array  (* each limb in [0, 0xFFFFFFFF], least significant first *)

let zero : t = [| 0 |]

let is_zero (a : t) =
  Array.for_all (fun l -> l = 0) a

let normalize (a : int array) : t =
  let n = Array.length a in
  let rec last_nonzero i =
    if i < 0 then 0
    else if a.(i) <> 0 then i + 1
    else last_nonzero (i - 1)
  in
  let last = last_nonzero (n - 1) in
  if last = 0 then zero else Array.sub a 0 last

(* value = value * radix + digit (radix <= 16, digit < radix). *)
let mul_small_add (a : t) (radix : int) (digit : int) : t =
  let out = Array.make (Array.length a + 1) 0 in
  let carry = ref 0 in
  for i = 0 to Array.length a - 1 do
    let v = a.(i) * radix + !carry in
    out.(i) <- v land 0xFFFFFFFF;
    carry := v lsr 32
  done;
  out.(Array.length a) <- !carry;
  (* add digit *)
  let c = ref digit in
  let i = ref 0 in
  while !c <> 0 && !i < Array.length out do
    let s = out.(!i) + !c in
    out.(!i) <- s land 0xFFFFFFFF;
    c := s lsr 32;
    incr i
  done;
  if !c <> 0 then begin
    let bigger = Array.make (Array.length out + 1) 0 in
    Array.blit out 0 bigger 0 (Array.length out);
    bigger.(Array.length out) <- !c;
    normalize bigger
  end
  else normalize out

(* Parse digit string (no prefix, no separators) in radix 2..16. *)
let of_digits (radix : int) (digits : string) : t option =
  if String.length digits = 0 then None
  else begin
    let v = ref zero in
    let ok = ref true in
    String.iter
      (fun c ->
        let d =
          match c with
          | '0' .. '9' -> Char.code c - Char.code '0'
          | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
          | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
          | _ -> -1
        in
        if d < 0 || d >= radix then ok := false
        else v := mul_small_add !v radix d)
      digits;
    if !ok then Some !v else None
  end

let compare (a : t) (b : t) : int =
  let na = Array.length a and nb = Array.length b in
  if na <> nb then compare na nb
  else begin
    let r = ref 0 in
    for i = na - 1 downto 0 do
      if !r = 0 && a.(i) <> b.(i) then r := compare a.(i) b.(i)
    done;
    !r
  end

let bit_length (a : t) : int =
  let n = Array.length a in
  if n = 1 && a.(0) = 0 then 0
  else begin
    let top = a.(n - 1) in
    let bits = ref 0 in
    let v = ref top in
    while !v <> 0 do
      v := !v lsr 1;
      incr bits
    done;
    (n - 1) * 32 + !bits
  end

(* Fits in an unsigned `width`-bit integer. *)
let fits_unsigned (a : t) (width : int) : bool =
  bit_length a <= width

(* Fits in a signed `width`-bit integer as a positive magnitude
   (i.e. <= 2^(width-1) - 1). *)
let fits_signed_positive (a : t) (width : int) : bool =
  bit_length a < width

let to_bits (a : t) : string =
  let bl = bit_length a in
  if bl = 0 then "0"
  else begin
    let b = Buffer.create bl in
    for i = bl - 1 downto 0 do
      let limb = i / 32 and bit = i mod 32 in
      let v = (a.(limb) lsr bit) land 1 in
      Buffer.add_char b (if v = 1 then '1' else '0')
    done;
    Buffer.contents b
  end

(* Fits in OCaml's native 63-bit int (positive domain). *)
let fits_ocaml_int (a : t) : bool =
  bit_length a <= 62

let to_ocaml_int (a : t) : int =
  if not (fits_ocaml_int a) then invalid_arg "Big_nat.to_ocaml_int: overflow";
  let v = ref 0 in
  for i = Array.length a - 1 downto 0 do
    v := (!v lsl 32) lor a.(i)
  done;
  !v

(* Exact conversion to an unsigned 128-bit word pair (low 64 bits,
   high 64 bits), with no decimal-to-OCaml-int intermediate.
   Raises Invalid_argument if the value needs more than 128 bits. *)
let to_words_128 (a : t) : int64 * int64 =
  if bit_length a > 128 then invalid_arg "Big_nat.to_words_128: more than 128 bits"
  else begin
    let lo = ref 0L and hi = ref 0L in
    let n = Array.length a in
    for i = 0 to n - 1 do
      let limb = Int64.of_int a.(i) in
      let word = if i < 2 then lo else hi in
      let sh = (i mod 2) * 32 in
      word := Int64.logor !word (Int64.shift_left limb sh)
    done;
    (!lo, !hi)
  end
