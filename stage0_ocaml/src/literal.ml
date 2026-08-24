(* literal.ml — Parsed numeric literals.

   The lexer validates lexical syntax and preserves the full spelling; the
   type checker decides whether a magnitude fits the selected/inferred
   type. A literal like 256u8 is a valid parsed literal whose type
   materialization fails — never lexer garbage, never zero. *)

type int_suffix =
  | I8 | I16 | I32 | I64 | I128
  | U8 | U16 | U32 | U64 | U128
  | Int | UInt
  | No_int_suffix

let suffix_of_string (s : string) : int_suffix option =
  match s with
  | "i8" -> Some I8 | "i16" -> Some I16 | "i32" -> Some I32
  | "i64" -> Some I64 | "i128" -> Some I128
  | "u8" -> Some U8 | "u16" -> Some U16 | "u32" -> Some U32
  | "u64" -> Some U64 | "u128" -> Some U128
  | "int" -> Some Int | "uint" -> Some UInt
  | _ -> None

let suffix_string = function
  | I8 -> "i8" | I16 -> "i16" | I32 -> "i32" | I64 -> "i64" | I128 -> "i128"
  | U8 -> "u8" | U16 -> "u16" | U32 -> "u32" | U64 -> "u64" | U128 -> "u128"
  | Int -> "int" | UInt -> "uint" | No_int_suffix -> ""

type parsed_integer = {
  original : string;          (* full source spelling, e.g. "0xff_u8" *)
  radix : int;
  magnitude : Big_nat.t;      (* unsigned magnitude of the digit body *)
  suffix : int_suffix;
  span : Span.span;
}

(* Split the digit body from a numeric suffix (u8/i64/...). The suffix is
   the trailing [ui](8|16|32|64|128|nt)? component. *)
let split_suffix (text : string) : string * int_suffix =
  let n = String.length text in
  let rec find i =
    if i < 0 then None
    else
      match text.[i] with
      | 'u' | 'i' -> Some i
      | _ -> find (i - 1)
  in
  match find (n - 1) with
  | None -> (text, No_int_suffix)
  | Some ui ->
      let tail = String.sub text ui (n - ui) in
      let body = String.sub text 0 ui in
      let tail =
        if String.length tail > 1 && tail.[0] = '_' then
          String.sub tail 1 (String.length tail - 1)
        else tail
      in
      (match suffix_of_string tail with
       | Some s when ui > 0 -> (body, s)
       | _ -> (text, No_int_suffix))

(* Parse a full integer spelling (with optional 0x/0b/0o prefix, separators
   already validated by the lexer). *)
let parse_integer ~(span : Span.span) (text : string) : parsed_integer option =
  let body, suffix = split_suffix text in
  let body = String.concat "" (String.split_on_char '_' body) in
  let radix, digits =
    if String.length body >= 2 then
      match String.sub body 0 2 with
      | "0x" | "0X" -> (16, String.sub body 2 (String.length body - 2))
      | "0b" | "0B" -> (2, String.sub body 2 (String.length body - 2))
      | "0o" | "0O" -> (8, String.sub body 2 (String.length body - 2))
      | _ -> (10, body)
    else (10, body)
  in
  match Big_nat.of_digits radix digits with
  | None -> None
  | Some magnitude ->
      Some { original = text; radix; magnitude; suffix; span }

(* Range decision (the type checker's authority).
   `signed_ok width` is true when the magnitude fits the signed range. *)
let fits_signed (p : parsed_integer) (width : int) : bool =
  Big_nat.fits_signed_positive p.magnitude width

let fits_unsigned (p : parsed_integer) (width : int) : bool =
  Big_nat.fits_unsigned p.magnitude width

let range_error (p : parsed_integer) : string =
  Printf.sprintf "integer literal '%s' does not fit its type" p.original
