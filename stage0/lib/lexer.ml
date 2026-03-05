open Token

type result = {
  tokens : Token.t list;
  diagnostics : Diagnostics.t list;
}

let is_digit c = c >= '0' && c <= '9'
let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_char c = is_ident_start c || is_digit c

let two_char_set = Hashtbl.create 32
let () = List.iter (fun op -> Hashtbl.replace two_char_set op true)
  [ "=="; "!="; "<="; ">="; "&&"; "||"; "->"; "=>"; "::"; ".."; "**";
    "+="; "-="; "*="; "/="; "%="; "&="; "|="; "^="; "<<"; ">>"; "++" ]

let three_char_set = Hashtbl.create 8
let () = List.iter (fun op -> Hashtbl.replace three_char_set op true)
  [ "..="; "<<="; ">>=" ]

let lex ~file (source : string) : result =
  let len = String.length source in
  let i = ref 0 in
  let line = ref 1 in
  let col = ref 1 in
  let toks = ref [] in
  let diags = ref [] in

  let push kind lexeme l c = toks := Token.make kind lexeme l c :: !toks in
  let bump () =
    if !i < len then begin
      if source.[!i] = '\n' then begin
        incr line;
        col := 1
      end else incr col;
      incr i
    end
  in
  let peek off =
    let j = !i + off in
    if j >= len then None else Some source.[j]
  in
  let starts_with s =
    let n = String.length s in
    if !i + n > len then false
    else
      let rec loop k =
        if k = n then true
        else if source.[!i + k] <> s.[k] then false
        else loop (k + 1)
      in
      loop 0
  in

  let rec skip_line () =
    match peek 0 with
    | None -> ()
    | Some '\n' -> ()
    | Some _ -> bump (); skip_line ()
  in

  let read_while pred =
    let start = !i in
    while !i < len && pred source.[!i] do
      bump ()
    done;
    String.sub source start (!i - start)
  in

  let read_string quote =
    let l0, c0 = (!line, !col) in
    bump ();
    let buf = Buffer.create 32 in
    let add_utf8 code =
      if code < 0x80 then
        Buffer.add_char buf (Char.chr code)
      else if code < 0x800 then begin
        Buffer.add_char buf (Char.chr (0xC0 lor (code lsr 6)));
        Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))
      end else if code < 0x10000 then begin
        Buffer.add_char buf (Char.chr (0xE0 lor (code lsr 12)));
        Buffer.add_char buf (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
        Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))
      end else if code <= 0x10FFFF then begin
        Buffer.add_char buf (Char.chr (0xF0 lor (code lsr 18)));
        Buffer.add_char buf (Char.chr (0x80 lor ((code lsr 12) land 0x3F)));
        Buffer.add_char buf (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
        Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))
      end else
        diags := Diagnostics.make ~code:"E111" ~file ~line:l0 ~col:c0
          (Printf.sprintf "invalid Unicode code point U+%X" code) :: !diags
    in
    let hex_val c =
      if c >= '0' && c <= '9' then Char.code c - Char.code '0'
      else if c >= 'a' && c <= 'f' then 10 + Char.code c - Char.code 'a'
      else if c >= 'A' && c <= 'F' then 10 + Char.code c - Char.code 'A'
      else -1
    in
    let read_hex_escape n =
      let v = ref 0 in
      let ok = ref true in
      for _ = 1 to n do
        match peek 0 with
        | Some c when hex_val c >= 0 ->
          v := !v * 16 + hex_val c; bump ()
        | _ -> ok := false
      done;
      if !ok then !v else -1
    in
    let rec loop () =
      match peek 0 with
      | None ->
          diags := Diagnostics.make ~code:"E110" ~file ~line:l0 ~col:c0 "unterminated string/char literal" :: !diags;
          None
      | Some ch when ch = quote ->
          bump ();
          Some (Buffer.contents buf)
      | Some '\\' ->
          bump ();
          (match peek 0 with
          | None ->
            diags := Diagnostics.make ~code:"E110" ~file ~line:l0 ~col:c0 "unterminated escape at end of input" :: !diags;
            None
          | Some 'n'  -> Buffer.add_char buf '\n'; bump (); loop ()
          | Some 't'  -> Buffer.add_char buf '\t'; bump (); loop ()
          | Some 'r'  -> Buffer.add_char buf '\r'; bump (); loop ()
          | Some '\\' -> Buffer.add_char buf '\\'; bump (); loop ()
          | Some '\'' -> Buffer.add_char buf '\''; bump (); loop ()
          | Some '"'  -> Buffer.add_char buf '"';  bump (); loop ()
          | Some '0'  -> Buffer.add_char buf '\000'; bump (); loop ()
          | Some 'a'  -> Buffer.add_char buf '\007'; bump (); loop ()
          | Some 'b'  -> Buffer.add_char buf '\008'; bump (); loop ()
          | Some 'f'  -> Buffer.add_char buf '\012'; bump (); loop ()
          | Some 'v'  -> Buffer.add_char buf '\011'; bump (); loop ()
          | Some 'x'  ->
            bump ();
            let v = read_hex_escape 2 in
            if v >= 0 then (Buffer.add_char buf (Char.chr v); loop ())
            else begin
              diags := Diagnostics.make ~code:"E112" ~file ~line:!line ~col:!col "invalid \\x hex escape" :: !diags;
              loop ()
            end
          | Some 'u' ->
            bump ();
            (match peek 0 with
            | Some '{' ->
              bump ();
              let v = ref 0 in
              let count = ref 0 in
              let rec read_braced_hex () =
                match peek 0 with
                | Some '}' -> bump ()
                | Some c when hex_val c >= 0 && !count < 6 ->
                  v := !v * 16 + hex_val c; incr count; bump (); read_braced_hex ()
                | _ ->
                  diags := Diagnostics.make ~code:"E113" ~file ~line:!line ~col:!col "invalid \\u{..} escape" :: !diags
              in
              read_braced_hex ();
              if !count > 0 then add_utf8 !v;
              loop ()
            | _ ->
              (* \uXXXX — exactly 4 hex digits *)
              let v = read_hex_escape 4 in
              if v >= 0 then (add_utf8 v; loop ())
              else begin
                diags := Diagnostics.make ~code:"E112" ~file ~line:!line ~col:!col "invalid \\u hex escape" :: !diags;
                loop ()
              end)
          | Some c ->
            diags := Diagnostics.make ~code:"E112" ~file ~line:!line ~col:!col
              (Printf.sprintf "unknown escape sequence '\\%c'" c) :: !diags;
            Buffer.add_char buf c; bump (); loop ()
          )
      | Some ch ->
          Buffer.add_char buf ch;
          bump ();
          loop ()
    in
    loop ()
  in

  while !i < len do
    match peek 0 with
    | None -> ()
    | Some (' ' | '\t' | '\r') -> bump ()
    | Some '\n' ->
        let l, c = (!line, !col) in
        bump ();
        push Newline "\\n" l c
    | Some '#' when starts_with "#|" ->
        (* Block comment: #| ... |# — supports nesting *)
        let l, c = (!line, !col) in
        bump (); bump (); (* skip opening #| *)
        let rec skip_block_comment depth =
          match peek 0 with
          | None ->
            let diag = Diagnostics.make ~code:"E120" ~file ~line:l ~col:c
              "Unterminated block comment" in
            diags := diag :: !diags
          | Some '#' when starts_with "#|" ->
            bump (); bump (); (* skip nested #| *)
            skip_block_comment (depth + 1)
          | Some '|' when starts_with "|#" ->
            bump (); bump (); (* skip |# *)
            if depth > 0 then skip_block_comment (depth - 1)
            (* else: done, outermost comment closed *)
          | _ -> bump (); skip_block_comment depth
        in
        skip_block_comment 0;
        push Newline "\\n" l c
    | Some '#' when starts_with "##" ->
        let l, c = (!line, !col) in
        skip_line ();
        push Newline "\\n" l c
    | Some '#' -> skip_line ()
    | Some '/' when starts_with "//" -> skip_line ()
    | Some '"' ->
        let l, c = (!line, !col) in
        (match read_string '"' with
         | Some s -> push (StringLit s) s l c
         | None -> ())
    | Some '\'' ->
        let l, c = (!line, !col) in
        (match read_string '\'' with
         | Some s -> push (CharLit s) s l c
         | None -> ())
    | Some ch when is_ident_start ch ->
        let l, c = (!line, !col) in
        let s = read_while is_ident_char in
        if Token.is_keyword s then push (Kw s) s l c else push (Ident s) s l c
    | Some ch when is_digit ch ->
        let l, c = (!line, !col) in
        (* Read numeric literal with full support:
           - Decimal, hex (0x), octal (0o), binary (0b) prefixes
           - Underscores as separators (e.g. 1_000_000)
           - Decimal dots (not range ops: .. and ..=)
           - Scientific notation (1e10, 3.14E-2, 2.5e+3)
           - Type suffixes: u8 u16 u32 u64 i8 i16 i32 i64 f32 f64 usize isize *)
        let buf2 = Buffer.create 32 in
        let has_dot = ref false in
        let has_exp = ref false in
        let is_hex c = (c >= '0' && c <= '9')
                       || (c >= 'a' && c <= 'f')
                       || (c >= 'A' && c <= 'F') in
        let safe_peek offset =
          let idx = !i + offset in
          if idx < len then Some source.[idx] else None in
        (* Detect base prefix *)
        let base = ref 10 in
        if ch = '0' then begin
          match safe_peek 1 with
          | Some 'x' | Some 'X' ->
            base := 16;
            Buffer.add_char buf2 '0'; bump ();
            Buffer.add_char buf2 (match peek 0 with Some c -> c | None -> 'x'); bump ()
          | Some 'o' | Some 'O' ->
            base := 8;
            Buffer.add_char buf2 '0'; bump ();
            Buffer.add_char buf2 (match peek 0 with Some c -> c | None -> 'o'); bump ()
          | Some 'b' | Some 'B' ->
            base := 2;
            Buffer.add_char buf2 '0'; bump ();
            Buffer.add_char buf2 (match peek 0 with Some c -> c | None -> 'b'); bump ()
          | _ -> ()
        end;
        let is_valid_digit c =
          match !base with
          | 16 -> is_hex c
          | 8  -> c >= '0' && c <= '7'
          | 2  -> c = '0' || c = '1'
          | _  -> is_digit c in
        let rec read_num () =
          match peek 0 with
          | Some '_' ->
            (* Underscore separator — consume but add to buffer for faithfulness *)
            Buffer.add_char buf2 '_'; bump (); read_num ()
          | Some '.' ->
            (* Stop if: range op '..' or '..=', already have dot, method call, or non-decimal *)
            if !base <> 10 then ()
            else begin match safe_peek 1 with
              | Some '.' -> () (* range operator .. or ..= *)
              | _ when !has_dot -> () (* already have a decimal point *)
              | Some c when is_ident_start c && not (is_digit c) -> ()
              (* dot followed by non-digit letter = method call *)
              | _ ->
                has_dot := true;
                Buffer.add_char buf2 '.'; bump (); read_num ()
            end
          | Some ('e' | 'E') when !base = 10 && not !has_exp ->
            (* Scientific notation *)
            has_exp := true;
            has_dot := true; (* exponent makes it a float *)
            Buffer.add_char buf2 (match peek 0 with Some c -> c | None -> 'e'); bump ();
            (* Optional + or - sign after exponent *)
            (match peek 0 with
             | Some ('+' | '-') as sign_opt ->
               Buffer.add_char buf2 (match sign_opt with Some c -> c | None -> '+'); bump ()
             | _ -> ());
            read_num ()
          | Some x when is_valid_digit x ->
            Buffer.add_char buf2 x; bump (); read_num ()
          | _ -> ()
        in
        read_num ();
        (* Now check for optional type suffix *)
        let suffix = Buffer.create 8 in
        let rec read_suffix () =
          match peek 0 with
          | Some c when is_ident_char c ->
            Buffer.add_char suffix c; bump (); read_suffix ()
          | _ -> ()
        in
        read_suffix ();
        let suf_str = Buffer.contents suffix in
        let whole = Buffer.contents buf2 in
        (* Validate suffix if present *)
        if suf_str <> "" then begin
          let valid_suffixes = [
            "u8"; "u16"; "u32"; "u64"; "usize";
            "i8"; "i16"; "i32"; "i64"; "isize";
            "f32"; "f64";
          ] in
          if not (List.mem suf_str valid_suffixes) then begin
            let diag = Diagnostics.make ~code:"E130" ~file ~line:l ~col:c
              ("Invalid numeric suffix `" ^ suf_str ^ "`") in
            diags := diag :: !diags
          end
        end;
        let full = whole ^ suf_str in
        if !has_dot then push (FloatLit full) full l c
        else push (IntLit full) full l c
    | Some _ ->
        let l, c = (!line, !col) in
        let emit_symbol s n =
          for _ = 1 to n do bump () done;
          push (Symbol s) s l c
        in
        (* Try 3-char operator, then 2-char, then single char — O(1) lookups *)
        let try_op len_n set =
          if !i + len_n <= len then
            let candidate = String.sub source !i len_n in
            if Hashtbl.mem set candidate then Some candidate else None
          else None
        in
        (match try_op 3 three_char_set with
         | Some op -> emit_symbol op 3
         | None ->
           match try_op 2 two_char_set with
           | Some op -> emit_symbol op 2
           | None ->
             match peek 0 with
             | Some ch2 ->
                 bump ();
                 push (Symbol (String.make 1 ch2)) (String.make 1 ch2) l c
             | None -> ())
  done;

  push Eof "" !line !col;
  { tokens = List.rev !toks; diagnostics = List.rev !diags }
