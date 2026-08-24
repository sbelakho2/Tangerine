(* test_literals.ml — Numeric literal syntax and magnitude authority
   (audit §59).

   Lexically legal spellings lex with zero diagnostics; lexically illegal
   spellings each produce a lexer diagnostic. 256u8 is a valid parsed
   literal whose magnitude is 256 with suffix U8; the range rejection is a
   type-stage decision pinned via Literal.fits_unsigned. *)

open Test_util

let lex_legal (text : string) : string =
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create text 0 diags in
  let tokens = Lexer.lex lx in
  assert_true (not (Diagnostic.has_errors diags))
    (Printf.sprintf "%s: unexpected lexer diagnostic" text);
  match tokens with
  | [ t; eof ] ->
      (match (t.Token.kind, eof.Token.kind) with
       | Token.Integer spelling, Token.Eof ->
           assert_equal (text ^ " spelling") text spelling;
           spelling
       | (Token.Integer _, _) -> fail (text ^ ": expected Eof after integer")
       | _ -> fail (text ^ ": expected a single Integer token"))
  | _ -> fail (text ^ ": expected exactly one Integer token plus Eof")

let lex_illegal (text : string) : unit =
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create text 0 diags in
  ignore (Lexer.lex lx);
  assert_true (Diagnostic.has_errors diags)
    (Printf.sprintf "%s: expected a lexer diagnostic" text)

let parse (text : string) : Literal.parsed_integer =
  match Literal.parse_integer ~span:Span.synthetic text with
  | Some p -> p
  | None -> fail (text ^ ": parse_integer returned None")

let parse_bits (text : string) : string = Big_nat.to_bits (parse text).Literal.magnitude

let legal_literals =
  [ "0"; "1"; "1_000"; "0xff"; "0xFF"; "0b1010"; "0o777"; "255u8"; "256u8";
    "127i8"; "128i8"; "18446744073709551615u64"; "18446744073709551616u64" ]

let illegal_literals = [ "1__0"; "1_"; "0x_1"; "0x"; "0b2"; "1e"; "1e+" ]

let suite () =
  run
    (List.map (fun text -> ("literal legal " ^ text, fun () -> ignore (lex_legal text)))
       legal_literals
    @ List.map
        (fun text -> ("literal illegal " ^ text, fun () -> lex_illegal text))
        illegal_literals
    @ [
        ("literal 256u8 parses to magnitude 256 with suffix U8", fun () ->
            let p = parse "256u8" in
            assert_equal "256u8 magnitude" "256"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude));
            assert_equal "256u8 suffix" "u8" (Literal.suffix_string p.Literal.suffix);
            assert_equal "256u8 original" "256u8" p.Literal.original;
            assert_equal "256u8 radix" "10" (string_of_int p.Literal.radix));
        ("literal 0xff parses to 255 radix 16", fun () ->
            let p = parse "0xff" in
            assert_equal "0xff magnitude" "255"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude));
            assert_equal "0xff radix" "16" (string_of_int p.Literal.radix));
        ("literal 0b1010 parses to 10 radix 2", fun () ->
            let p = parse "0b1010" in
            assert_equal "0b1010 magnitude" "10"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude));
            assert_equal "0b1010 radix" "2" (string_of_int p.Literal.radix));
        ("literal 0o777 parses to 511 radix 8", fun () ->
            let p = parse "0o777" in
            assert_equal "0o777 magnitude" "511"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude));
            assert_equal "0o777 radix" "8" (string_of_int p.Literal.radix));
        ("literal 1_000 parses to 1000", fun () ->
            let p = parse "1_000" in
            assert_equal "1_000 magnitude" "1000"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude)));
        ("literal fits_unsigned 255u8 8 = true", fun () ->
            assert_true (Literal.fits_unsigned (parse "255u8") 8)
              "255u8 must fit u8");
        ("literal fits_unsigned 256u8 8 = false", fun () ->
            assert_true (not (Literal.fits_unsigned (parse "256u8") 8))
              "256u8 must not fit u8");
        ("literal fits_signed 127i8 8 = true", fun () ->
            assert_true (Literal.fits_signed (parse "127i8") 8)
              "127i8 must fit i8");
        ("literal fits_signed 128i8 8 = false", fun () ->
            assert_true (not (Literal.fits_signed (parse "128i8") 8))
              "128i8 must not fit i8");
        ("literal 2^64-1 u64 fits u64, 2^64 does not", fun () ->
            let p_max = parse "18446744073709551615u64" in
            let p_ovf = parse "18446744073709551616u64" in
            assert_equal "u64 max bits" (String.make 64 '1')
              (Big_nat.to_bits p_max.Literal.magnitude);
            assert_equal "u64 overflow bits" ("1" ^ String.make 64 '0')
              (Big_nat.to_bits p_ovf.Literal.magnitude);
            assert_true (Literal.fits_unsigned p_max 64) "2^64-1 must fit u64";
            assert_true (not (Literal.fits_unsigned p_ovf 64))
              "2^64 must not fit u64";
            assert_equal "u64 max suffix" "u64"
              (Literal.suffix_string p_max.Literal.suffix));
        ("literal 0xffu8 suffix split", fun () ->
            let p = parse "0xffu8" in
            assert_equal "0xffu8 suffix" "u8"
              (Literal.suffix_string p.Literal.suffix);
            assert_equal "0xffu8 magnitude" "255"
              (string_of_int (Big_nat.to_ocaml_int p.Literal.magnitude)));
      ])
