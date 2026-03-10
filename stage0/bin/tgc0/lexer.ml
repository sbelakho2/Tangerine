open Token

exception Error of string * int * int

let keyword_or_ident text =
  match text with
  | "def" -> Def
  | "fn" -> Def
  | "end" -> End
  | "let" -> Let
  | "mut" -> Mut
  | "return" -> Return
  | "break" -> Break
  | "next" -> Next
  | "if" -> If
  | "else" -> Else
  | "elsif" -> Elsif
  | "unless" -> Unless
  | "match" -> Match
  | "when" -> When
  | "then" -> Then
  | "do" -> Do
  | "loop" -> Loop
  | "while" -> While
  | "for" -> For
  | "in" -> In
  | "until" -> Until
  | "enum" -> Enum
  | "impl" -> Impl
  | "struct" -> Struct
  | "trait" -> Trait
  | "use" -> Use
  | "mod" -> Module
  | "module" -> Module
  | "pub" -> Pub
  | "private" -> Private
  | "macro" -> Macro
  | "where" -> Where
  | "as" -> As
  | "is" -> Is
  | "test" -> Test
  | "dyn" -> Dyn
  | "self" -> Self_
  | "Self" -> SelfType
  | "super" -> Super
  | "crate" -> Crate
  (* Memory safety *)
  | "move" -> TkMove
  | "copy" -> TkCopy
  | "drop" -> TkDrop
  | "own" -> TkOwn
  | "ref" -> TkRef
  (* Agentic *)
  | "pre" -> Pre
  | "post" -> Post
  | "invariant" -> Invariant
  | "cap" -> Cap
  | "unsafe" -> Unsafe
  | "rationale" -> Rationale
  | "budget" -> Budget
  | "edition" -> Edition
  | "requires" -> Requires
  | "ensures" -> Ensures
  | "effect" -> Effect
  | "pure" -> Pure
  (* Modern *)
  | "async" -> Async
  | "await" -> Await
  | "yield" -> Yield
  | "defer" -> Defer
  | "try" -> Try
  | "catch" -> Catch
  | "finally" -> Finally
  | "guard" -> Guard
  | "handle" -> Handle
  | "with" -> With
  | "implies" -> Implies
  | "comptime" -> Comptime
  | "const" -> Const
  | "static" -> Static
  | "type" -> Type
  | "alias" -> Alias
  | "extern" -> Extern
  | "inline" -> Inline
  (* Literals *)
  | "true" -> True
  | "false" -> False
  | "nil" -> Nil
  | _ -> Ident text

let unescape_string text =
  let buffer = Buffer.create (String.length text) in
  let len = String.length text in
  let rec loop index =
    if index >= len then
      Buffer.contents buffer
    else if text.[index] = '\\' && index + 1 < len then
      let ch = text.[index + 1] in
      begin match ch with
      | 'n' -> Buffer.add_char buffer '\n'; loop (index + 2)
      | 'r' -> Buffer.add_char buffer '\r'; loop (index + 2)
      | 't' -> Buffer.add_char buffer '\t'; loop (index + 2)
      | '\\' -> Buffer.add_char buffer '\\'; loop (index + 2)
      | '\'' -> Buffer.add_char buffer '\''; loop (index + 2)
      | '"' -> Buffer.add_char buffer '"'; loop (index + 2)
      | '0' -> Buffer.add_char buffer '\000'; loop (index + 2)
      | 'x' when index + 3 < len ->
          let hex = String.sub text (index + 2) 2 in
          let code = int_of_string ("0x" ^ hex) in
          Buffer.add_char buffer (Char.chr code);
          loop (index + 4)
      | 'u' when index + 5 < len && text.[index + 2] <> '{' ->
          let hex = String.sub text (index + 2) 4 in
          let code = try int_of_string ("0x" ^ hex) with _ -> 0 in
          if code < 128 then
            Buffer.add_char buffer (Char.chr code)
          else begin
            if code < 0x800 then begin
              Buffer.add_char buffer (Char.chr (0xC0 lor (code lsr 6)));
              Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
            end else if code < 0x10000 then begin
              Buffer.add_char buffer (Char.chr (0xE0 lor (code lsr 12)));
              Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
              Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
            end else begin
              Buffer.add_char buffer (Char.chr (0xF0 lor (code lsr 18)));
              Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 12) land 0x3F)));
              Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
              Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
            end
          end;
          loop (index + 6)
      | 'u' when index + 2 < len && text.[index + 2] = '{' ->
          let rec find_close i =
            if i >= len then -1
            else if text.[i] = '}' then i
            else find_close (i + 1)
          in
          let close_pos = find_close (index + 3) in
          if close_pos > 0 then begin
            let hex = String.sub text (index + 3) (close_pos - index - 3) in
            let code = try int_of_string ("0x" ^ hex) with _ -> 0 in
            if code < 128 then
              Buffer.add_char buffer (Char.chr code)
            else begin
              (* Encode as UTF-8 *)
              if code < 0x800 then begin
                Buffer.add_char buffer (Char.chr (0xC0 lor (code lsr 6)));
                Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
              end else if code < 0x10000 then begin
                Buffer.add_char buffer (Char.chr (0xE0 lor (code lsr 12)));
                Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
                Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
              end else begin
                Buffer.add_char buffer (Char.chr (0xF0 lor (code lsr 18)));
                Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 12) land 0x3F)));
                Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
                Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F)));
              end
            end;
            loop (close_pos + 1)
          end else
            (Buffer.add_char buffer '\\'; loop (index + 1))
      | _ -> Buffer.add_char buffer ch; loop (index + 2)
      end
    else (
      Buffer.add_char buffer text.[index];
      loop (index + 1))
  in
  loop 0

let is_ident_start = function
  | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
  | _ -> false

let is_ident_continue = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let is_single_utf8_scalar text =
  let len = String.length text in
  let byte index = Char.code text.[index] in
  if len = 0 then
    false
  else
    let first = byte 0 in
    let expected_len =
      if first land 0x80 = 0 then 1
      else if first land 0xE0 = 0xC0 then 2
      else if first land 0xF0 = 0xE0 then 3
      else if first land 0xF8 = 0xF0 then 4
      else 0
    in
    expected_len = len
    && expected_len > 0
    && let rec loop index =
         if index >= len then
           true
         else
           let b = byte index in
           (b land 0xC0 = 0x80) && loop (index + 1)
       in
       loop 1

let tokenize source =
  let len = String.length source in
  let rec loop index line column acc =
    if index >= len then
      List.rev ({ kind = Eof; line; column } :: acc)
    else
      match source.[index] with
      | ' ' | '\t' | '\r' -> loop (index + 1) line (column + 1) acc
      | '\n' ->
          loop (index + 1) (line + 1) 1 ({ kind = Newline; line; column } :: acc)
      | '#' ->
          if index + 1 < len then
            match source.[index + 1] with
            | '|' ->
                (* Nested block comment #| ... |# *)
                let rec skip_block_comment i depth current_line current_column =
                  if i + 1 >= len then
                    raise (Error ("unterminated block comment", line, column))
                  else if source.[i] = '#' && source.[i + 1] = '|' then
                    skip_block_comment (i + 2) (depth + 1) current_line (current_column + 2)
                  else if source.[i] = '|' && source.[i + 1] = '#' then
                    if depth <= 1 then
                      i + 2, current_line, current_column + 2
                    else
                      skip_block_comment (i + 2) (depth - 1) current_line (current_column + 2)
                  else if source.[i] = '\n' then
                    skip_block_comment (i + 1) depth (current_line + 1) 1
                  else
                    skip_block_comment (i + 1) depth current_line (current_column + 1)
                in
                let next_index, next_line, next_column = skip_block_comment (index + 2) 0 line (column + 2) in
                loop next_index next_line next_column acc
            | '#' ->
                (* Doc comment ## ... - skip like regular comment *)
                let rec consume_doc i =
                  if i >= len || source.[i] = '\n' then i
                  else consume_doc (i + 1)
                in
                let end_index = consume_doc (index + 2) in
                loop end_index line (column + end_index - index) acc
            | _ ->
                (* Line comment # ... *)
                let rec skip i c =
                  if i >= len || source.[i] = '\n' then i, c else skip (i + 1) (c + 1)
                in
                let next_index, next_column = skip (index + 1) (column + 1) in
                loop next_index line next_column acc
          else
            (* Just # at end *)
            loop (index + 1) line (column + 1) ({ kind = Hash; line; column } :: acc)
      | '(' -> loop (index + 1) line (column + 1) ({ kind = LParen; line; column } :: acc)
      | ')' -> loop (index + 1) line (column + 1) ({ kind = RParen; line; column } :: acc)
      | '[' -> loop (index + 1) line (column + 1) ({ kind = LBracket; line; column } :: acc)
      | ']' -> loop (index + 1) line (column + 1) ({ kind = RBracket; line; column } :: acc)
      | '{' -> loop (index + 1) line (column + 1) ({ kind = LBrace; line; column } :: acc)
      | '}' -> loop (index + 1) line (column + 1) ({ kind = RBrace; line; column } :: acc)
      | ',' -> loop (index + 1) line (column + 1) ({ kind = Comma; line; column } :: acc)
      | ';' -> loop (index + 1) line (column + 1) ({ kind = Semicolon; line; column } :: acc)
      | '@' -> loop (index + 1) line (column + 1) ({ kind = At; line; column } :: acc)
      | '.' ->
          if index + 2 < len && source.[index + 1] = '.' && source.[index + 2] = '=' then
            loop (index + 3) line (column + 3) ({ kind = DotDotEq; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '.' then
            loop (index + 2) line (column + 2) ({ kind = DotDot; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Dot; line; column } :: acc)
      | ':' ->
          if index + 1 < len && source.[index + 1] = ':' then
            loop (index + 2) line (column + 2) ({ kind = ColonColon; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Colon; line; column } :: acc)
      | '&' ->
          if index + 3 < len && source.[index + 1] = 'm' && source.[index + 2] = 'u' && source.[index + 3] = 't' then
            loop (index + 4) line (column + 4) ({ kind = AmpMut; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = AmpEq; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '&' then
            loop (index + 2) line (column + 2) ({ kind = AndAnd; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Amp; line; column } :: acc)
      | '|' ->
          if index + 1 < len then
            match source.[index + 1] with
            | '|' -> loop (index + 2) line (column + 2) ({ kind = OrOr; line; column } :: acc)
            | '>' -> loop (index + 2) line (column + 2) ({ kind = PipeArrow; line; column } :: acc)
            | '=' -> loop (index + 2) line (column + 2) ({ kind = PipeEq; line; column } :: acc)
            | _ -> loop (index + 1) line (column + 1) ({ kind = Pipe; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Pipe; line; column } :: acc)
      | '+' ->
          if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = PlusEq; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '+' then
            loop (index + 2) line (column + 2) ({ kind = Plus; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Plus; line; column } :: acc)
      | '*' ->
          if index + 1 < len && source.[index + 1] = '*' then
            loop (index + 2) line (column + 2) ({ kind = DoubleStar; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = StarEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Star; line; column } :: acc)
      | '/' ->
          if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = SlashEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Slash; line; column } :: acc)
      | '%' ->
          if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = PercentEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Percent; line; column } :: acc)
      | '^' ->
          if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = CaretEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Caret; line; column } :: acc)
      | '~' -> loop (index + 1) line (column + 1) ({ kind = Tilde; line; column } :: acc)
      | '?' -> loop (index + 1) line (column + 1) ({ kind = Question; line; column } :: acc)
      | '"' ->
          let rec consume_string i =
            if i >= len then
              raise (Error ("unterminated string literal", line, column))
            else if source.[i] = '\\' then
              consume_string (i + 2)
            else if source.[i] = '"' then
              i
            else
              consume_string (i + 1)
          in
          let close_index = consume_string (index + 1) in
          let raw = String.sub source (index + 1) (close_index - index - 1) in
          let text = unescape_string raw in
          loop (close_index + 1) line (column + close_index - index + 1)
            ({ kind = String text; line; column } :: acc)
      | '\'' ->
          let rec consume_char i =
            if i >= len then
              raise (Error ("unterminated character literal", line, column))
            else if source.[i] = '\\' then
              if i + 1 >= len then
                raise (Error ("unterminated character literal", line, column))
              else
                consume_char (i + 2)
            else if source.[i] = '\'' then
              i
            else
              consume_char (i + 1)
          in
          let close_index = consume_char (index + 1) in
          let raw = String.sub source (index + 1) (close_index - index - 1) in
          let text = unescape_string raw in
          if is_single_utf8_scalar text then
            loop (close_index + 1) line (column + close_index - index + 1)
              ({ kind = Char text; line; column } :: acc)
          else
            raise (Error ("unsupported character literal", line, column))
      | '=' ->
          if index + 1 < len then
            match source.[index + 1] with
            | '=' -> loop (index + 2) line (column + 2) ({ kind = EqEq; line; column } :: acc)
            | '>' -> loop (index + 2) line (column + 2) ({ kind = FatArrow; line; column } :: acc)
            | _ -> loop (index + 1) line (column + 1) ({ kind = Eq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Eq; line; column } :: acc)
      | '!' ->
          if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = BangEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Bang; line; column } :: acc)
      | '<' ->
          if index + 2 < len && source.[index + 1] = '<' && source.[index + 2] = '=' then
            loop (index + 3) line (column + 3) ({ kind = ShlEq; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '<' then
            loop (index + 2) line (column + 2) ({ kind = Shl; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = LtEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Lt; line; column } :: acc)
      | '>' ->
          if index + 2 < len && source.[index + 1] = '>' && source.[index + 2] = '=' then
            loop (index + 3) line (column + 3) ({ kind = ShrEq; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '>' then
            loop (index + 2) line (column + 2) ({ kind = Shr; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = GtEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Gt; line; column } :: acc)
      | '-' ->
          if index + 1 < len && source.[index + 1] = '>' then
            loop (index + 2) line (column + 2) ({ kind = Arrow; line; column } :: acc)
          else if index + 1 < len && source.[index + 1] = '=' then
            loop (index + 2) line (column + 2) ({ kind = MinusEq; line; column } :: acc)
          else
            loop (index + 1) line (column + 1) ({ kind = Minus; line; column } :: acc)
      | '0' .. '9' ->
          let rec consume_number i saw_dot saw_exp =
            if i < len then
              match source.[i] with
              | '0' .. '9' | '_' ->
                  consume_number (i + 1) saw_dot saw_exp
              | 'a' .. 'f' | 'A' .. 'F' | 'x' when not saw_dot && not saw_exp ->
                  consume_number (i + 1) saw_dot saw_exp
              | 'e' | 'E' ->
                  consume_number (i + 1) saw_dot true
              | '+' | '-' when saw_exp ->
                  consume_number (i + 1) saw_dot saw_exp
              | '.' when not saw_dot && (i + 1 < len) && (match source.[i + 1] with '0'..'9' -> true | _ -> false) ->
                  (* Only consume . if followed by a digit, not .. *)
                  consume_number (i + 1) true saw_exp
              | 'u' | 'i' when i + 2 < len && (match source.[i+1] with '0'..'9' | 's' -> true | _ -> false) ->
                  (* Type suffix like u64, i32, u8, isize, etc. - consume it *)
                  let rec consume_suffix j =
                    if j < len && match source.[j] with '0'..'9' | 'a'..'z' | 'A'..'Z' -> true | _ -> false
                    then consume_suffix (j + 1)
                    else j
                  in
                  consume_suffix (i + 1)
              | _ -> i
            else
              i
          in
          let next_index = consume_number (index + 1) false false in
          let raw_text = String.sub source index (next_index - index) in
          (* Strip type suffix like u64, i32, etc. *)
          let stripped_text = 
            let strip_suffix s = 
              (* Try to find a type suffix at the end *)
              let len_s = String.length s in
              (* Check for u64, i64, u32, i32, u8, i8, u16, i16, usize, isize, f32, f64 *)
              if len_s >= 3 && (match String.sub s (len_s - 3) 3 with "u64" | "i64" | "u32" | "i32" | "f32" | "f64" | "u16" | "i16" -> true | _ -> false) then
                String.sub s 0 (len_s - 3)
              else if len_s >= 4 && (match String.sub s (len_s - 4) 4 with "usize" | "isize" -> true | _ -> false) then
                String.sub s 0 (len_s - 4)
              else if len_s >= 2 && (match String.sub s (len_s - 2) 2 with "u8" | "i8" -> true | _ -> false) then
                String.sub s 0 (len_s - 2)
              else s
            in
            strip_suffix raw_text
          in
          let text = String.map (fun c -> if c = '_' then ' ' else c) stripped_text in
          let compact = String.concat "" (String.split_on_char ' ' text) in
          let kind =
            if String.length compact >= 2 && String.sub compact 0 2 = "0x" then
              let hex_val = String.sub compact 2 (String.length compact - 2) in
              (try 
                let n = Int64.of_string ("0x" ^ hex_val) in
                if n >= 0L && n <= 2147483647L then Int (Int64.to_int n) else Int64 n
               with _ -> Int64 (Int64.of_string ("0x" ^ hex_val)))
            else if String.length compact >= 2 && String.sub compact 0 2 = "0b" then
              let bin_val = String.sub compact 2 (String.length compact - 2) in
              (try
                let n = Int64.of_string ("0b" ^ bin_val) in
                if n >= 0L && n <= 2147483647L then Int (Int64.to_int n) else Int64 n
               with _ -> Int64 Int64.zero)
            else if String.length compact >= 2 && String.sub compact 0 2 = "0o" then
              let oct_val = String.sub compact 2 (String.length compact - 2) in
              (try
                let n = Int64.of_string ("0o" ^ oct_val) in
                if n >= 0L && n <= 2147483647L then Int (Int64.to_int n) else Int64 n
               with _ -> Int64 Int64.zero)
            else if String.contains compact '.' || String.contains compact 'e' || String.contains compact 'E' then
              Float compact
            else
              (try 
                (* For very large unsigned values that overflow Int64, use modular arithmetic *)
                let n = Int64.of_string compact in
                if n >= 0L && n <= 2147483647L then Int (Int64.to_int n) else Int64 n
               with _ -> 
                (* Handle unsigned 64-bit values that overflow Int64 by using Nativeint or float *)
                (* For now, just use 0 as placeholder for values we can't parse *)
                Int64 Int64.zero)
          in
          loop next_index line (column + next_index - index) ({ kind; line; column } :: acc)
      | ch when is_ident_start ch ->
          let rec consume_ident i =
            if i < len && is_ident_continue source.[i] then consume_ident (i + 1) else i
          in
          let next_index = consume_ident (index + 1) in
          let text = String.sub source index (next_index - index) in
          let kind = keyword_or_ident text in
          loop next_index line (column + next_index - index) ({ kind; line; column } :: acc)
      | ch -> raise (Error (Printf.sprintf "unexpected character '%c'" ch, line, column))
  in
  loop 0 1 1 []