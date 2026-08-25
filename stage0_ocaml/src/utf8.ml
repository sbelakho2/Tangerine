(* utf8.ml — Strict UTF-8 decoding for the seed.

   Exact lead-byte cases (RFC 3629):
     00..7F                      one byte
     C2..DF 80..BF               two bytes
     E0 A0..BF 80..BF            three bytes
     E1..EC 80..BF 80..BF
     ED 80..9F 80..BF            (surrogates ED A0..BF rejected)
     EE..EF 80..BF 80..BF
     F0 90..BF 80..BF 80..BF     (overlong F0 80..8F rejected)
     F1..F3 80..BF 80..BF 80..BF
     F4 80..8F 80..BF 80..BF     (> U+10FFFF rejected)
   Anything else is invalid.

   The seed never substitutes U+FFFD and never "recovers as Latin-1" in
   compiler source: invalid bytes are a hard error with the exact failing
   offset. *)

type error_kind =
  | Invalid_lead
  | Unexpected_continuation
  | Truncated_sequence
  | Overlong_encoding
  | Surrogate
  | Above_unicode_max

type error = {
  offset : int;
  kind : error_kind;
}

let error_string = function
  | Invalid_lead -> "invalid lead byte"
  | Unexpected_continuation -> "unexpected continuation byte"
  | Truncated_sequence -> "truncated sequence"
  | Overlong_encoding -> "overlong encoding"
  | Surrogate -> "surrogate code point"
  | Above_unicode_max -> "code point above U+10FFFF"

let is_continuation b = b land 0xC0 = 0x80

(* Validate the whole byte string. Returns the first error position. *)
let validate (bytes : Bytes.t) : (unit, error) result =
  let n = Bytes.length bytes in
  let i = ref 0 in
  let err k = Error { offset = !i; kind = k } in
  let rec go () =
    if !i >= n then Ok ()
    else begin
      let b = Char.code (Bytes.get bytes !i) in
      if b < 0x80 then begin
        incr i;
        go ()
      end
      else if b >= 0xC2 && b <= 0xDF then begin
        (* two bytes *)
        if !i + 1 >= n then err Truncated_sequence
        else if not (is_continuation (Char.code (Bytes.get bytes (!i + 1)))) then
          err Unexpected_continuation
        else begin
          i := !i + 2;
          go ()
        end
      end
      else if b >= 0xE0 && b <= 0xEF then begin
        (* three bytes *)
        if !i + 2 >= n then err Truncated_sequence
        else begin
          let b1 = Char.code (Bytes.get bytes (!i + 1)) in
          let b2 = Char.code (Bytes.get bytes (!i + 2)) in
          if not (is_continuation b1 && is_continuation b2) then
            err Unexpected_continuation
          else if b = 0xE0 && b1 < 0xA0 then err Overlong_encoding
          else if b = 0xED && b1 >= 0xA0 then err Surrogate
          else begin
            i := !i + 3;
            go ()
          end
        end
      end
      else if b >= 0xF0 && b <= 0xF4 then begin
        (* four bytes *)
        if !i + 3 >= n then err Truncated_sequence
        else begin
          let b1 = Char.code (Bytes.get bytes (!i + 1)) in
          let b2 = Char.code (Bytes.get bytes (!i + 2)) in
          let b3 = Char.code (Bytes.get bytes (!i + 3)) in
          if not (is_continuation b1 && is_continuation b2 && is_continuation b3) then
            err Unexpected_continuation
          else if b = 0xF0 && b1 < 0x90 then err Overlong_encoding
          else if b = 0xF4 && b1 >= 0x90 then err Above_unicode_max
          else begin
            i := !i + 4;
            go ()
          end
        end
      end
      else err Invalid_lead
    end
  in
  go ()

(* Decode the scalar at byte offset i. Returns (scalar, next_byte_offset),
   or the precise error. *)
let decode_at (bytes : Bytes.t) (i : int) : ((Uchar.t * int), error) result =
  let n = Bytes.length bytes in
  if i < 0 || i >= n then Error { offset = i; kind = Truncated_sequence }
  else begin
    let b = Char.code (Bytes.get bytes i) in
    if b < 0x80 then Ok (Uchar.of_int b, i + 1)
    else if b >= 0xC2 && b <= 0xDF then begin
      if i + 1 >= n then Error { offset = i; kind = Truncated_sequence }
      else begin
        let b1 = Char.code (Bytes.get bytes (i + 1)) in
        if not (is_continuation b1) then
          Error { offset = i + 1; kind = Unexpected_continuation }
        else
          let cp = ((b land 0x1F) lsl 6) lor (b1 land 0x3F) in
          Ok (Uchar.of_int cp, i + 2)
      end
    end
    else if b >= 0xE0 && b <= 0xEF then begin
      if i + 2 >= n then Error { offset = i; kind = Truncated_sequence }
      else begin
        let b1 = Char.code (Bytes.get bytes (i + 1)) in
        let b2 = Char.code (Bytes.get bytes (i + 2)) in
        if not (is_continuation b1 && is_continuation b2) then
          Error { offset = i + 1; kind = Unexpected_continuation }
        else if b = 0xE0 && b1 < 0xA0 then Error { offset = i; kind = Overlong_encoding }
        else if b = 0xED && b1 >= 0xA0 then Error { offset = i; kind = Surrogate }
        else begin
          let cp = ((b land 0x0F) lsl 12) lor ((b1 land 0x3F) lsl 6) lor (b2 land 0x3F) in
          Ok (Uchar.of_int cp, i + 3)
        end
      end
    end
    else if b >= 0xF0 && b <= 0xF4 then begin
      if i + 3 >= n then Error { offset = i; kind = Truncated_sequence }
      else begin
        let b1 = Char.code (Bytes.get bytes (i + 1)) in
        let b2 = Char.code (Bytes.get bytes (i + 2)) in
        let b3 = Char.code (Bytes.get bytes (i + 3)) in
        if not (is_continuation b1 && is_continuation b2 && is_continuation b3) then
          Error { offset = i + 1; kind = Unexpected_continuation }
        else if b = 0xF0 && b1 < 0x90 then Error { offset = i; kind = Overlong_encoding }
        else if b = 0xF4 && b1 >= 0x90 then Error { offset = i; kind = Above_unicode_max }
        else begin
          let cp =
            ((b land 0x07) lsl 18) lor ((b1 land 0x3F) lsl 12)
            lor ((b2 land 0x3F) lsl 6)
            lor (b3 land 0x3F)
          in
          Ok (Uchar.of_int cp, i + 4)
        end
      end
    end
    else Error { offset = i; kind = Invalid_lead }
  end

(* Validate a string (the parser/lexer receive strings). *)
let validate_string (s : string) : (unit, error) result =
  validate (Bytes.of_string s)

let is_valid_utf8 (s : string) : bool =
  match validate_string s with Ok () -> true | Error _ -> false

(* Encode one Unicode scalar as strict UTF-8 (the inverse of decode_at).
   Uchar.t is by construction a scalar (0..U+10FFFF, no surrogates), so
   the emitted sequence always passes `validate`. Used by the host's
   __intrinsic_char_to_string so non-ASCII Chars produce valid UTF-8
   instead of the truncated String.make 1 (Uchar.to_char c). *)
let encode_scalar (u : Uchar.t) : Bytes.t =
  let cp = Uchar.to_int u in
  let n =
    if cp < 0x80 then 1
    else if cp < 0x800 then 2
    else if cp < 0x10000 then 3
    else 4
  in
  let b = Bytes.create n in
  (match n with
  | 1 -> Bytes.set b 0 (Char.chr cp)
  | 2 ->
      Bytes.set b 0 (Char.chr (0xC0 lor (cp lsr 6)));
      Bytes.set b 1 (Char.chr (0x80 lor (cp land 0x3F)))
  | 3 ->
      Bytes.set b 0 (Char.chr (0xE0 lor (cp lsr 12)));
      Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Bytes.set b 2 (Char.chr (0x80 lor (cp land 0x3F)))
  | _ ->
      Bytes.set b 0 (Char.chr (0xF0 lor (cp lsr 18)));
      Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
      Bytes.set b 2 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Bytes.set b 3 (Char.chr (0x80 lor (cp land 0x3F))));
  b
