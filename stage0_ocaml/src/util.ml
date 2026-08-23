(* util.ml — small shared helpers. *)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let find_opt_assoc k l = List.find_opt (fun (k', _) -> k' = k) l

let drop_prefix n s =
  if n <= 0 then s
  else if n >= String.length s then ""
  else String.sub s n (String.length s - n)

let has_prefix s p =
  let lp = String.length p and ls = String.length s in
  lp <= ls && String.sub s 0 lp = p

let has_suffix s p =
  let lp = String.length p and ls = String.length s in
  lp <= ls && String.sub s (ls - lp) lp = p

let hex_val c =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
  | _ -> -1

(* Parse a digit string (no prefix, no separators) in the given radix as an
   unsigned 64-bit integer. Returns None on invalid digits or overflow.
   UINT64_MAX == 0xFFFF_FFFF_FFFF_FFFF == Int64.minus_one in OCaml. *)
let parse_uint64_digits radix digits =
  if String.length digits = 0 then None
  else begin
    let max_u = Int64.minus_one in
    let rad = Int64.of_int radix in
    let max_div_rad = Int64.unsigned_div max_u rad in
    let v = ref 0L and ok = ref true in
    String.iter
      (fun c ->
        let d = hex_val c in
        if d < 0 || d >= radix then ok := false
        else if Int64.unsigned_compare !v max_div_rad > 0 then ok := false
        else begin
          let nv = Int64.add (Int64.mul !v rad) (Int64.of_int d) in
          if Int64.unsigned_compare nv !v < 0 then ok := false
          else v := nv
        end)
      digits;
    if !ok then Some !v else None
  end

(* Parse an int64 from a digit string in the given radix (signed domain).
   Values >= 2^63 are reinterpreted as their two's-complement bit pattern
   (the unsigned magnitude domain of the kernel's hash constants). *)
let parse_int64_digits radix digits =
  match parse_uint64_digits radix digits with
  | None -> None
  | Some u -> Some (Int64.of_string (Int64.to_string u))
