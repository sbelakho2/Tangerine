open Token

type result = {
  tokens : Token.t list;
  diagnostics : Diagnostics.t list;
}

let is_digit c = c >= '0' && c <= '9'
let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_char c = is_ident_start c || is_digit c

let two_char_ops =
  [ "=="; "!="; "<="; ">="; "&&"; "||"; "->"; "=>"; "::"; ".."; "**";
    "+="; "-="; "*="; "/="; "%="; "&="; "|="; "^="; "<<"; ">>"; "++" ]

let three_char_ops = [ "..="; "<<="; ">>=" ]

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
    let rec loop escaped =
      match peek 0 with
      | None ->
          diags := Diagnostics.make ~code:"E110" ~file ~line:l0 ~col:c0 "unterminated string/char literal" :: !diags;
          None
      | Some ch ->
          if escaped then begin
            Buffer.add_char buf ch;
            bump ();
            loop false
          end else if ch = '\\' then begin
            Buffer.add_char buf ch;
            bump ();
            loop true
          end else if ch = quote then begin
            bump ();
            Some (Buffer.contents buf)
          end else begin
            Buffer.add_char buf ch;
            bump ();
            loop false
          end
    in
    loop false
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
        (* Block comment: #| ... |# *)
        let l, c = (!line, !col) in
        bump (); bump (); (* skip #| *)
        let rec skip_block_comment () =
          match peek 0 with
          | None -> ()
          | Some '|' when starts_with "|#" ->
            bump (); bump () (* skip |# *)
          | _ -> bump (); skip_block_comment ()
        in
        skip_block_comment ();
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
        (* Read numeric literal, but stop at '..' range operator *)
        let buf2 = Buffer.create 32 in
        let has_dot = ref false in
        let rec read_num () =
          match peek 0 with
          | Some '.' ->
            (* Check if next char is also '.', if so it's a range op, stop *)
            if !i + 1 < len && source.[!i + 1] = '.' then ()
            else if !has_dot then () (* Already have a dot, stop *)
            else if !i + 1 < len && is_ident_start source.[!i + 1] then ()
            (* Dot followed by letter = method call, stop *)
            else begin
              has_dot := true;
              Buffer.add_char buf2 '.'; bump (); read_num ()
            end
          | Some x when is_ident_char x || x = '_' ->
            Buffer.add_char buf2 x; bump (); read_num ()
          | _ -> ()
        in
        read_num ();
        let whole = Buffer.contents buf2 in
        if !has_dot then push (FloatLit whole) whole l c
        else push (IntLit whole) whole l c
    | Some _ ->
        let l, c = (!line, !col) in
        let emit_symbol s n =
          for _ = 1 to n do bump () done;
          push (Symbol s) s l c
        in
        if List.exists starts_with three_char_ops then
          let op = List.find starts_with three_char_ops in emit_symbol op 3
        else if List.exists starts_with two_char_ops then
          let op = List.find starts_with two_char_ops in emit_symbol op 2
        else begin
          match peek 0 with
          | Some ch2 ->
              bump ();
              push (Symbol (String.make 1 ch2)) (String.make 1 ch2) l c
          | None -> ()
        end
  done;

  push Eof "" !line !col;
  { tokens = List.rev !toks; diagnostics = List.rev !diags }
