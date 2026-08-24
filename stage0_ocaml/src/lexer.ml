(* lexer.ml — Tokenizer for the Tangerine language (Edition-2026 grammar).

   Byte-based cursor over the UTF-8 source. Trivia (whitespace, newlines,
   comments, doc comments) is produced but stripped by the public `lex`.

   Deliberate clean-rewrite divergences from the Swift stage0 lexer (all
   grammar-conformant):
   - String/char contents decode proper UTF-8 (the Swift lexer appended raw
     bytes as latin-1 scalars).
   - A bare-exponent float (e.g. 1e5, 2e-10) lexes as a FLOAT token per
     grammar.md §1.4 (the Swift lexer mis-lexed it as an integer and the
     range gate rejected it).
*)

type lexer = {
  bytes : Bytes.t;
  length : int;
  mutable pos : int;
  file_id : int;
  diags : Diagnostic.bag;
  mutable pending : Token.t list;  (* keyword-boundary split tokens *)
}

let create source file_id diags =
  let b = Bytes.create (String.length source) in
  Bytes.blit_string source 0 b 0 (String.length source);
  (* A single leading BOM (EF BB BF) is ignored semantically; byte offsets
     in spans stay absolute (audit §5). *)
  let bom_len =
    if String.length source >= 3 && source.[0] = '\xEF' && source.[1] = '\xBB'
       && source.[2] = '\xBF'
    then 3
    else 0
  in
  { bytes = b; length = String.length source; pos = bom_len; file_id; diags; pending = [] }

let peek_byte (lx : lexer) offset =
  let idx = lx.pos + offset in
  if idx < 0 || idx >= lx.length then None else Some (Bytes.get lx.bytes idx)

let byte_at (lx : lexer) i =
  if i < 0 || i >= lx.length then None else Some (Bytes.get lx.bytes i)

let make_span (lx : lexer) start end_ = Span.make start end_ lx.file_id

let is_ident_start (c : char) =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_ident_continue (c : char) = is_ident_start c || (c >= '0' && c <= '9')

let is_digit (c : char) = c >= '0' && c <= '9'

let is_hex_digit (c : char) =
  is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

let sub (lx : lexer) start end_ =
  Bytes.sub_string lx.bytes start (end_ - start)

(* Decode one UTF-8 scalar at pos; advances pos past it. Returns the scalar
   string, or None on invalid encoding (advances 1). *)
(* Strict single-scalar decode (audit §5): uses the Utf8 authority. Source
   bytes are validated by the loader; a failure here is a hard error. *)
let decode_utf8 (lx : lexer) : string option =
  match Utf8.decode_at lx.bytes lx.pos with
  | Ok (u, next) ->
      let buf = Buffer.create 4 in
      Buffer.add_utf_8_uchar buf u;
      lx.pos <- next;
      Some (Buffer.contents buf)
  | Error e ->
      Diagnostic.error lx.diags "E1015"
        (Printf.sprintf "invalid UTF-8 in source: %s at byte %d"
           (Utf8.error_string e.Utf8.kind) e.Utf8.offset)
        (make_span lx lx.pos (min lx.length (lx.pos + 1)));
      lx.pos <- lx.pos + 1;
      None

let is_valid_utf8 (s : string) : bool =
  let b = Bytes.of_string s and n = String.length s in
  let i = ref 0 in
  let ok = ref true in
  while !i < n && !ok do
    let c = Char.code (Bytes.get b !i) in
    let len =
      if c < 0x80 then 1
      else if c land 0xE0 = 0xC0 then 2
      else if c land 0xF0 = 0xE0 then 3
      else if c land 0xF8 = 0xF0 then 4
      else 0
    in
    if len = 0 || !i + len > n then ok := false
    else begin
      for k = 1 to len - 1 do
        if Char.code (Bytes.get b (!i + k)) land 0xC0 <> 0x80 then ok := false
      done;
      i := !i + len
    end
  done;
  !ok

(* ── Whitespace ─────────────────────────────────────────────── *)

let lex_whitespace (lx : lexer) =
  let start = lx.pos in
  let rec go () =
    match peek_byte lx 0 with
    | Some c when c = ' ' || c = '\t' || c = '\r' ->
        lx.pos <- lx.pos + 1;
        go ()
    | _ -> ()
  in
  go ();
  Token.make Token.Whitespace (make_span lx start lx.pos)

(* ── Comments ───────────────────────────────────────────────── *)

let lex_block_comment (lx : lexer) =
  let start = lx.pos in
  lx.pos <- lx.pos + 2;
  let depth = ref 1 in
  while lx.pos < lx.length && !depth > 0 do
    let a = byte_at lx lx.pos and b = byte_at lx (lx.pos + 1) in
    if a = Some '#' && b = Some '|' then begin
      depth := !depth + 1;
      lx.pos <- lx.pos + 2
    end
    else if a = Some '|' && b = Some '#' then begin
      depth := !depth - 1;
      lx.pos <- lx.pos + 2
    end
    else lx.pos <- lx.pos + 1
  done;
  if !depth > 0 then
    Diagnostic.error lx.diags "E1001" "unterminated block comment"
      (make_span lx start lx.pos);
  Token.make Token.Comment (make_span lx start lx.pos)

let trim_leading_ws s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (s.[!i] = ' ' || s.[!i] = '\t') do incr i done;
  String.sub s !i (n - !i)

let lex_comment_or_hash (lx : lexer) =
  let start = lx.pos in
  match peek_byte lx 1 with
  | Some '|' -> lex_block_comment lx
  | Some '#' ->
      lx.pos <- lx.pos + 2;
      let doc_start = lx.pos in
      while lx.pos < lx.length && Bytes.get lx.bytes lx.pos <> '\n' do
        lx.pos <- lx.pos + 1
      done;
      let text = trim_leading_ws (sub lx doc_start lx.pos) in
      Token.make (Token.DocComment text) (make_span lx start lx.pos)
  | _ ->
      lx.pos <- lx.pos + 1;
      while lx.pos < lx.length && Bytes.get lx.bytes lx.pos <> '\n' do
        lx.pos <- lx.pos + 1
      done;
      Token.make Token.Comment (make_span lx start lx.pos)

(* ── Identifiers and keywords ───────────────────────────────── *)

let lex_ident_or_keyword (lx : lexer) =
  let start = lx.pos in
  while lx.pos < lx.length && is_ident_continue (Bytes.get lx.bytes lx.pos) do
    lx.pos <- lx.pos + 1
  done;
  let text = sub lx start lx.pos in
  match Token.keyword_of_string text with
  | Some k -> Token.make k (make_span lx start lx.pos)
  | None ->
      (* Keyword-boundary rule: a block-terminator keyword glued to a
         following keyword (e.g. `enddef`) splits into two keywords. *)
      if String.length text > 3 && Util.has_prefix text "end" then begin
        let rest = String.sub text 3 (String.length text - 3) in
        match Token.keyword_of_string rest with
        | Some k ->
            lx.pending <- Token.make k (make_span lx (start + 3) lx.pos) :: lx.pending;
            Token.make Token.KwEnd (make_span lx start (start + 3))
        | None ->
            Token.make
              (Token.Ident { Token.spelling = text; normalized = Unicode.identifier_nfc text })
              (make_span lx start lx.pos)
      end
      else
        Token.make
          (Token.Ident { Token.spelling = text; normalized = Unicode.identifier_nfc text })
          (make_span lx start lx.pos)

(* ── Numbers ────────────────────────────────────────────────── *)

let consume_numeric_suffix (lx : lexer) =
  while lx.pos < lx.length && is_ident_continue (Bytes.get lx.bytes lx.pos) do
    lx.pos <- lx.pos + 1
  done

(* Scan a digit body with strict separator validation (audit §8):
   no leading underscore, no trailing underscore, no consecutive
   underscores, at least one real digit. `is_radix_digit` defines the
   digit set. Returns the body end position. *)
let scan_digit_body (lx : lexer) (is_radix_digit : char -> bool) (start : int) : int =
  let saw_digit = ref false in
  let prev_underscore = ref false in
  let bad = ref None in
  let continue_ = ref true in
  while !continue_ && lx.pos < lx.length do
    let c = Bytes.get lx.bytes lx.pos in
    if is_radix_digit c then begin
      saw_digit := true;
      prev_underscore := false;
      lx.pos <- lx.pos + 1
    end
    else if c = '_' then begin
      if !prev_underscore then bad := Some "consecutive underscores in numeric literal";
      if not !saw_digit then bad := Some "underscore before first digit in numeric literal";
      if !saw_digit && lx.pos + 1 < lx.length
         && not (is_radix_digit (Bytes.get lx.bytes (lx.pos + 1)))
         && Bytes.get lx.bytes (lx.pos + 1) <> '_'
      then bad := Some "trailing underscore in numeric literal";
      prev_underscore := true;
      lx.pos <- lx.pos + 1
    end
    else continue_ := false
  done;
  if !prev_underscore then bad := Some "trailing underscore in numeric literal";
  if not !saw_digit then bad := Some "numeric literal must contain at least one digit";
  (match !bad with
   | Some msg -> Diagnostic.error lx.diags "E1014" msg (make_span lx start lx.pos)
   | None -> ());
  lx.pos

let is_decimal_digit c = is_digit c
let is_hex_digit2 c = is_hex_digit c
let is_binary_digit c = c = '0' || c = '1'
let is_octal_digit c = c >= '0' && c <= '7'

(* Illegal radix digit after the digit body: e.g. `0b2`, `0o89` — the digit
   must not split into a separate token or an identifier suffix. *)
let check_illegal_radix_digit (lx : lexer) (start : int) (is_radix_digit : char -> bool) =
  if lx.pos < lx.length then begin
    let c = Bytes.get lx.bytes lx.pos in
    if is_digit c && not (is_radix_digit c) then begin
      Diagnostic.error lx.diags "E1014"
        (Printf.sprintf "illegal digit '%c' in radix literal" c)
        (make_span lx start lx.pos);
      lx.pos <- lx.pos + 1
    end
  end

let lex_hex_number (lx : lexer) start =
  lx.pos <- lx.pos + 2;
  let digit_start = lx.pos in
  ignore (scan_digit_body lx is_hex_digit2 digit_start);
  check_illegal_radix_digit lx start is_hex_digit2;
  consume_numeric_suffix lx;
  Token.make (Token.Integer (sub lx start lx.pos)) (make_span lx start lx.pos)

let lex_binary_number (lx : lexer) start =
  lx.pos <- lx.pos + 2;
  let digit_start = lx.pos in
  ignore (scan_digit_body lx is_binary_digit digit_start);
  check_illegal_radix_digit lx start is_binary_digit;
  consume_numeric_suffix lx;
  Token.make (Token.Integer (sub lx start lx.pos)) (make_span lx start lx.pos)

let lex_octal_number (lx : lexer) start =
  lx.pos <- lx.pos + 2;
  let digit_start = lx.pos in
  ignore (scan_digit_body lx is_octal_digit digit_start);
  check_illegal_radix_digit lx start is_octal_digit;
  consume_numeric_suffix lx;
  Token.make (Token.Integer (sub lx start lx.pos)) (make_span lx start lx.pos)

let return_float lx start text = Token.make (Token.Float text) (make_span lx start lx.pos)

let rec lex_number (lx : lexer) =
  let start = lx.pos in
  if Bytes.get lx.bytes lx.pos = '0' && lx.pos + 1 < lx.length then begin
    match peek_byte lx 1 with
    | Some ('x' | 'X') -> lex_hex_number lx start
    | Some ('b' | 'B') -> lex_binary_number lx start
    | Some ('o' | 'O') -> lex_octal_number lx start
    | _ -> lex_decimal lx start
  end
  else lex_decimal lx start

and lex_decimal (lx : lexer) (start : int) =
  ignore (scan_digit_body lx is_decimal_digit start);
  if lx.pos < lx.length && Bytes.get lx.bytes lx.pos = '.' then begin
    match peek_byte lx 1 with
    | Some '.' ->
        consume_numeric_suffix lx;
        let text = sub lx start lx.pos in
        Token.make (Token.Integer text) (make_span lx start lx.pos)
    | Some c when is_digit c ->
        lx.pos <- lx.pos + 1;
        ignore (scan_digit_body lx is_decimal_digit start);
        if lx.pos < lx.length
           && (Bytes.get lx.bytes lx.pos = 'e' || Bytes.get lx.bytes lx.pos = 'E')
        then begin
          lx.pos <- lx.pos + 1;
          if lx.pos < lx.length
             && (Bytes.get lx.bytes lx.pos = '+' || Bytes.get lx.bytes lx.pos = '-')
          then lx.pos <- lx.pos + 1;
          if lx.pos >= lx.length || not (is_digit (Bytes.get lx.bytes lx.pos)) then
            Diagnostic.error lx.diags "E1010" "float exponent must contain digits"
              (make_span lx start lx.pos)
          else ignore (scan_digit_body lx is_decimal_digit start)
        end;
        consume_numeric_suffix lx;
        let text = sub lx start lx.pos in
        return_float lx start text
    | _ ->
        consume_numeric_suffix lx;
        let text = sub lx start lx.pos in
        Token.make (Token.Integer text) (make_span lx start lx.pos)
  end
  else if lx.pos < lx.length
          && (Bytes.get lx.bytes lx.pos = 'e' || Bytes.get lx.bytes lx.pos = 'E')
  then begin
    (* Bare-exponent float: 1e5, 2e-10 (grammar.md §1.4). *)
    lx.pos <- lx.pos + 1;
    if lx.pos < lx.length && (Bytes.get lx.bytes lx.pos = '+' || Bytes.get lx.bytes lx.pos = '-')
    then lx.pos <- lx.pos + 1;
    if lx.pos < lx.length && is_digit (Bytes.get lx.bytes lx.pos) then begin
      ignore (scan_digit_body lx is_decimal_digit start);
      consume_numeric_suffix lx;
      let text = sub lx start lx.pos in
      return_float lx start text
    end
    else begin
      (* Malformed exponent: the token stays a float; never rewound to an
         integer (audit §8). *)
      Diagnostic.error lx.diags "E1010" "float exponent must contain digits"
        (make_span lx start lx.pos);
      consume_numeric_suffix lx;
      let text = sub lx start lx.pos in
      return_float lx start text
    end
  end
  else begin
    consume_numeric_suffix lx;
    let text = sub lx start lx.pos in
    Token.make (Token.Integer text) (make_span lx start lx.pos)
  end

(* ── Strings ────────────────────────────────────────────────── *)

let hex_val_of_char c = Util.hex_val c

let lex_escape_char (lx : lexer) (value : Buffer.t) : unit =
  lx.pos <- lx.pos + 1;
  if lx.pos >= lx.length then begin
    Diagnostic.error lx.diags "E1005" "unterminated escape sequence"
      (make_span lx (lx.pos - 1) lx.pos)
  end
  else begin
    let ch = Bytes.get lx.bytes lx.pos in
    lx.pos <- lx.pos + 1;
    if ch = '\n' then ()
    else if ch = '\r' && lx.pos < lx.length && Bytes.get lx.bytes lx.pos = '\n' then begin
      lx.pos <- lx.pos + 1;
      ()
    end
    else
      match ch with
      | 'n' -> Buffer.add_char value '\n'
      | 'r' -> Buffer.add_char value '\r'
      | 't' -> Buffer.add_char value '\t'
      | '0' -> Buffer.add_char value '\000'
      | '"' -> Buffer.add_char value '"'
      | '\'' -> Buffer.add_char value '\''
      | '\\' -> Buffer.add_char value '\\'
      | 'x' ->
          if
            lx.pos + 1 < lx.length
            && is_hex_digit (Bytes.get lx.bytes lx.pos)
            && is_hex_digit (Bytes.get lx.bytes (lx.pos + 1))
          then begin
            let hi = hex_val_of_char (Bytes.get lx.bytes lx.pos) in
            let lo = hex_val_of_char (Bytes.get lx.bytes (lx.pos + 1)) in
            lx.pos <- lx.pos + 2;
            Buffer.add_char value (Char.chr (hi * 16 + lo))
          end
          else begin
            Diagnostic.error lx.diags "E1006" "hex escape must use two hex digits"
              (make_span lx (lx.pos - 2) lx.pos)
          end
      | 'u' ->
          if lx.pos < lx.length && Bytes.get lx.bytes lx.pos = '{' then begin
            (* \u{...}: 1-6 hex digits, mandatory '}', scalar range. *)
            lx.pos <- lx.pos + 1;
            let cp = ref 0 in
            let digits = ref 0 in
            let bad = ref false in
            let bad_kind = ref "" in
            while lx.pos < lx.length && Bytes.get lx.bytes lx.pos <> '}' && not !bad do
              if is_hex_digit (Bytes.get lx.bytes lx.pos) then begin
                cp := !cp * 16 + hex_val_of_char (Bytes.get lx.bytes lx.pos);
                incr digits;
                lx.pos <- lx.pos + 1
              end
              else begin
                bad := true;
                bad_kind := "unicode escape must use hex digits"
              end
            done;
            if !digits < 1 then bad := true;
            if !digits > 6 then begin
              bad := true;
              bad_kind := "unicode escape has more than 6 hex digits"
            end;
            if lx.pos >= lx.length || Bytes.get lx.bytes lx.pos <> '}' then begin
              bad := true;
              bad_kind := "unicode escape must end with '}'"
            end;
            if !bad then
              Diagnostic.error lx.diags "E1007"
                (if !bad_kind = "" then "unicode escape must have between 1 and 6 hex digits"
                 else !bad_kind)
                (make_span lx (lx.pos - 2) lx.pos)
            else begin
              lx.pos <- lx.pos + 1;
              if !cp > 0x10FFFF then
                Diagnostic.error lx.diags "E1007" "unicode escape is above U+10FFFF"
                  (make_span lx (lx.pos - 2) lx.pos)
              else if !cp >= 0xD800 && !cp <= 0xDFFF then
                Diagnostic.error lx.diags "E1007" "unicode escape is a surrogate code point"
                  (make_span lx (lx.pos - 2) lx.pos)
              else Buffer.add_utf_8_uchar value (Uchar.of_int !cp)
            end
          end
          else if lx.pos + 3 < lx.length then begin
            (* \uHHHH (4-digit form) *)
            let cp = ref 0 in
            let ok = ref true in
            for _ = 0 to 3 do
              if is_hex_digit (Bytes.get lx.bytes lx.pos) then begin
                cp := !cp * 16 + hex_val_of_char (Bytes.get lx.bytes lx.pos);
                lx.pos <- lx.pos + 1
              end
              else ok := false
            done;
            if not !ok then
              Diagnostic.error lx.diags "E1007" "unicode escape must use hex digits"
                (make_span lx (lx.pos - 2) lx.pos)
            else if !cp >= 0xD800 && !cp <= 0xDFFF then
              Diagnostic.error lx.diags "E1007" "unicode escape is a surrogate code point"
                (make_span lx (lx.pos - 2) lx.pos)
            else Buffer.add_utf_8_uchar value (Uchar.of_int !cp)
          end
          else
            Diagnostic.error lx.diags "E1007" "unicode escape must use hex digits"
              (make_span lx (lx.pos - 2) lx.pos)
      | _ ->
          Diagnostic.error lx.diags "E1008"
            (Printf.sprintf "unsupported escape sequence '\\\\%c'" ch)
            (make_span lx (lx.pos - 2) lx.pos)
  end

let lex_string (lx : lexer) =
  let start = lx.pos in
  lx.pos <- lx.pos + 1;
  let value = Buffer.create 16 in
  while lx.pos < lx.length && Bytes.get lx.bytes lx.pos <> '"' do
    if Bytes.get lx.bytes lx.pos = '\\' then lex_escape_char lx value
    else begin
      match decode_utf8 lx with
      | Some s -> Buffer.add_string value s
      | None -> Buffer.add_char value (Bytes.get lx.bytes (lx.pos - 1))
    end
  done;
  if lx.pos >= lx.length then
    Diagnostic.error lx.diags "E1002" "unterminated string literal"
      (make_span lx start lx.pos)
  else lx.pos <- lx.pos + 1;
  Token.make (Token.String (Buffer.contents value)) (make_span lx start lx.pos)

(* ── Chars ──────────────────────────────────────────────────── *)

let looks_like_char_literal_start (lx : lexer) : bool =
  let content_start = lx.pos + 1 in
  if content_start >= lx.length then false
  else
    match byte_at lx content_start with
    | Some '\\' ->
        if content_start + 1 >= lx.length then false
        else if Bytes.get lx.bytes (content_start + 1) = 'x' then
          content_start + 4 < lx.length && Bytes.get lx.bytes (content_start + 4) = '\''
        else content_start + 2 < lx.length && Bytes.get lx.bytes (content_start + 2) = '\''
    | Some first ->
        let b = Char.code first in
        let byte_len =
          if b < 0x80 then 1
          else if b land 0xE0 = 0xC0 then 2
          else if b land 0xF0 = 0xE0 then 3
          else if b land 0xF8 = 0xF0 then 4
          else 1
        in
        let close_quote = content_start + byte_len in
        close_quote < lx.length && Bytes.get lx.bytes close_quote = '\''
    | None -> false

let lex_lifetime_ident (lx : lexer) =
  let start = lx.pos in
  lx.pos <- lx.pos + 1;
  let name_start = lx.pos in
  while lx.pos < lx.length && is_ident_continue (Bytes.get lx.bytes lx.pos) do
    lx.pos <- lx.pos + 1
  done;
  let text = sub lx name_start lx.pos in
  Token.make
    (Token.Ident { Token.spelling = text; normalized = Unicode.identifier_nfc text })
    (make_span lx start lx.pos)

let lex_char (lx : lexer) =
  let start = lx.pos in
  lx.pos <- lx.pos + 1;
  let value = ref "" in
  if lx.pos < lx.length then begin
    if Bytes.get lx.bytes lx.pos = '\\' then begin
      let buf = Buffer.create 4 in
      lex_escape_char lx buf;
      value := Buffer.contents buf
    end
    else if Bytes.get lx.bytes lx.pos = '\n' then
      Diagnostic.error lx.diags "E1004" "char literal cannot span multiple lines"
        (make_span lx start lx.pos)
    else begin
      match decode_utf8 lx with
      | Some s -> value := s
      | None -> value := "?"
    end
  end;
  if lx.pos >= lx.length || Bytes.get lx.bytes lx.pos <> '\'' then
    Diagnostic.error lx.diags "E1003" "unterminated char literal"
      (make_span lx start lx.pos)
  else lx.pos <- lx.pos + 1;
  Token.make (Token.Char !value) (make_span lx start lx.pos)

(* ── Operators ──────────────────────────────────────────────── *)

let peek_is lx offset c =
  match byte_at lx (lx.pos + offset) with Some x -> x = c | None -> false

let tok2 lx start kind len = Token.make kind (make_span lx start (lx.pos + len))

let lex_operator (lx : lexer) =
  let start = lx.pos in
  let c = Bytes.get lx.bytes lx.pos in
  let single kind = lx.pos <- lx.pos + 1; Token.make kind (make_span lx start lx.pos) in
  let two kind =
    lx.pos <- lx.pos + 2; Token.make kind (make_span lx start lx.pos)
  in
  let three kind =
    lx.pos <- lx.pos + 3; Token.make kind (make_span lx start lx.pos)
  in
  match c with
  | '(' -> single Token.LParen
  | ')' -> single Token.RParen
  | '[' -> single Token.LBracket
  | ']' -> single Token.RBracket
  | '{' -> single Token.LBrace
  | '}' -> single Token.RBrace
  | ',' -> single Token.Comma
  | ';' -> single Token.Semi
  | '~' -> single Token.Tilde
  | '$' -> single Token.Dollar
  | '@' -> single Token.At
  | '?' -> single Token.Question
  | '^' -> if peek_is lx 1 '=' then two Token.CaretEq else single Token.Caret
  | ':' ->
      if peek_is lx 1 ':' then two Token.ColonColon else single Token.Colon
  | '.' ->
      if peek_is lx 1 '.' && peek_is lx 2 '.' then three Token.DotDotDot
      else if peek_is lx 1 '.' && peek_is lx 2 '=' then three Token.DotDotEq
      else if peek_is lx 1 '.' then two Token.DotDot
      else single Token.Dot
  | '=' ->
      if peek_is lx 1 '=' then two Token.EqEq
      else if peek_is lx 1 '>' then two Token.FatArrow
      else single Token.Eq
  | '!' ->
      if peek_is lx 1 '=' then two Token.BangEq else single Token.Bang
  | '<' ->
      if peek_is lx 1 '=' then two Token.LtEq
      else if peek_is lx 1 '<' then begin
        if peek_is lx 2 '=' then three Token.ShlEq else two Token.Shl
      end
      else single Token.Lt
  | '>' ->
      if peek_is lx 1 '=' then two Token.GtEq
      else if peek_is lx 1 '>' then begin
        if peek_is lx 2 '=' then three Token.ShrEq else two Token.Shr
      end
      else single Token.Gt
  | '&' ->
      if peek_is lx 1 '&' then two Token.AmpAmp
      else if peek_is lx 1 '=' then two Token.AmpEq
      else single Token.Amp
  | '|' ->
      if peek_is lx 1 '|' then two Token.PipePipe
      else if peek_is lx 1 '=' then two Token.PipeEq
      else single Token.Pipe
  | '-' ->
      if peek_is lx 1 '>' then two Token.Arrow
      else if peek_is lx 1 '=' then two Token.MinusEq
      else single Token.Minus
  | '+' -> if peek_is lx 1 '=' then two Token.PlusEq else single Token.Plus
  | '*' -> if peek_is lx 1 '=' then two Token.StarEq else single Token.Star
  | '/' ->
      (* // and /// are line comments *)
      if peek_is lx 1 '/' then begin
        while lx.pos < lx.length && Bytes.get lx.bytes lx.pos <> '\n' do
          lx.pos <- lx.pos + 1
        done;
        Token.make Token.Comment (make_span lx start lx.pos)
      end
      else if peek_is lx 1 '=' then two Token.SlashEq
      else single Token.Slash
  | '%' ->
      if peek_is lx 1 '=' then two Token.PercentEq else single Token.Percent
  | _ ->
      lx.pos <- lx.pos + 1;
      Diagnostic.error lx.diags "E1000"
        (Printf.sprintf "unexpected character '%c'" c)
        (make_span lx start lx.pos);
      Token.make Token.Whitespace (make_span lx start lx.pos)

(* ── Core loop ──────────────────────────────────────────────── *)

let lex_token (lx : lexer) : Token.t =
  let c = Bytes.get lx.bytes lx.pos in
  if c = '\n' then begin
    let start = lx.pos in
    lx.pos <- lx.pos + 1;
    Token.make Token.Newline (make_span lx start lx.pos)
  end
  else if c = ' ' || c = '\t' || c = '\r' then lex_whitespace lx
  else if c = '#' then lex_comment_or_hash lx
  else if is_ident_start c then lex_ident_or_keyword lx
  else if is_digit c then lex_number lx
  else if c = '"' then lex_string lx
  else if c = '\'' then begin
    if looks_like_char_literal_start lx then lex_char lx
    else if lx.pos + 1 < lx.length && is_ident_start (Bytes.get lx.bytes (lx.pos + 1))
    then lex_lifetime_ident lx
    else lex_char lx
  end
  else lex_operator lx

let lex_all (lx : lexer) : Token.t list =
  let tokens = ref [] in
  while lx.pos < lx.length || lx.pending <> [] do
    match lx.pending with
    | t :: rest ->
        lx.pending <- rest;
        tokens := t :: !tokens
    | [] ->
        let t = lex_token lx in
        tokens := t :: !tokens
  done;
  let eof = Token.make Token.Eof (make_span lx lx.pos lx.pos) in
  List.rev (eof :: !tokens)

(* Public API: lex into non-trivia tokens. *)
let lex (lx : lexer) : Token.t list =
  List.filter (fun t -> not (Token.is_trivia t.Token.kind)) (lex_all lx)
