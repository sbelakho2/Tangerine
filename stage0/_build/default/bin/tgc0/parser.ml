open Token
open Ast

exception Error of string * Token.t

type state =
  { tokens : Token.t array
  ; mutable pos : int
  }

let current state =
  if state.pos >= Array.length state.tokens then
    state.tokens.(Array.length state.tokens - 1)
  else
    state.tokens.(state.pos)

let advance state =
  let tok = current state in
  state.pos <- state.pos + 1;
  tok

let rec skip_newlines state =
  match (current state).kind with
  | Newline ->
      ignore (advance state);
      skip_newlines state
  | _ -> ()

let expect_exact state expected message =
  let tok = current state in
  if tok.kind = expected then
    ignore (advance state)
  else
    raise (Error (message, tok))

let expect_ident state =
  match (current state).kind with
  | Ident name ->
      ignore (advance state);
      name
  | Next ->
      ignore (advance state);
      "next"
  | Break ->
      ignore (advance state);
      "break"
  | Loop ->
      ignore (advance state);
      "loop"
  | Until ->
      ignore (advance state);
      "until"
  | Unless ->
      ignore (advance state);
      "unless"
  | Async ->
      ignore (advance state);
      "async"
  | Await ->
      ignore (advance state);
      "await"
  | Yield ->
      ignore (advance state);
      "yield"
  | Defer ->
      ignore (advance state);
      "defer"
  | Try ->
      ignore (advance state);
      "try"
  | Catch ->
      ignore (advance state);
      "catch"
  | Finally ->
      ignore (advance state);
      "finally"
  | Guard ->
      ignore (advance state);
      "guard"
  | Handle ->
      ignore (advance state);
      "handle"
  | With ->
      ignore (advance state);
      "with"
  | Pure ->
      ignore (advance state);
      "pure"
  | Effect ->
      ignore (advance state);
      "effect"
  | Pre ->
      ignore (advance state);
      "pre"
  | Post ->
      ignore (advance state);
      "post"
  | Invariant ->
      ignore (advance state);
      "invariant"
  | Cap ->
      ignore (advance state);
      "cap"
  | Budget ->
      ignore (advance state);
      "budget"
  | Rationale ->
      ignore (advance state);
      "rationale"
  | Requires ->
      ignore (advance state);
      "requires"
  | Ensures ->
      ignore (advance state);
      "ensures"
  | _ -> raise (Error ("expected identifier", current state))

let rec parse_program state =
  skip_newlines state;
  let rec items acc =
    skip_newlines state;
    match (current state).kind with
    | Eof -> List.rev acc
    | _ -> items_append acc (parse_items state)
  and items_append acc = function
    | [] -> items acc
    | item :: rest -> items_append (item :: acc) rest
  in
  items []

and parse_items state =
  skip_newlines state;
  match (current state).kind with
  | End ->
      ignore (advance state);
      []
  | Module ->
      skip_module_item state;
      []
  | Use ->
      skip_use_item state;
      []
  | Struct -> [parse_struct state]
  | Impl -> parse_impl state
  | Enum -> [parse_enum state]
    | Trait -> [parse_trait state]
    | Const -> [parse_const state]
  | Mut -> [parse_global ~is_mutable:true state]
  | Pub ->
      ignore (advance state);
      parse_items state
  | Test ->
      skip_test_block state;
      []
  | Def -> [parse_function state]
  | _ -> raise (Error ("unsupported top-level item", current state))

and skip_module_item state =
  ignore (advance state);
  while
    match (current state).kind with
    | Newline | Eof | End -> false
    | _ -> true
  do
    ignore (advance state)
  done;
  skip_newlines state;
  begin match (current state).kind with
  | End -> ignore (advance state)
  | _ -> ()
  end

  and skip_use_item state =
    ignore (advance state);
    let rec loop paren_depth bracket_depth brace_depth =
    match (current state).kind with
    | Eof -> ()
    | Newline when paren_depth = 0 && bracket_depth = 0 && brace_depth = 0 -> ()
    | LParen ->
      ignore (advance state);
      loop (paren_depth + 1) bracket_depth brace_depth
    | RParen ->
      ignore (advance state);
      loop (max 0 (paren_depth - 1)) bracket_depth brace_depth
    | LBracket ->
      ignore (advance state);
      loop paren_depth (bracket_depth + 1) brace_depth
    | RBracket ->
      ignore (advance state);
      loop paren_depth (max 0 (bracket_depth - 1)) brace_depth
    | LBrace ->
      ignore (advance state);
      loop paren_depth bracket_depth (brace_depth + 1)
    | RBrace ->
      ignore (advance state);
      loop paren_depth bracket_depth (max 0 (brace_depth - 1))
    | _ ->
      ignore (advance state);
      loop paren_depth bracket_depth brace_depth
    in
    loop 0 0 0

and skip_test_block state =
  ignore (advance state);
  while (match (current state).kind with Do | Eof -> false | _ -> true) do
    ignore (advance state)
  done;
  begin match (current state).kind with
  | Do -> ignore (advance state)
  | _ -> ()
  end;
  skip_nested_block state 1

and skip_nested_block state depth =
  match (current state).kind with
  | Eof -> ()
  | If | Match | While | For | Test ->
      ignore (advance state);
      skip_nested_block state (depth + 1)
  | End ->
      ignore (advance state);
      if depth <= 1 then () else skip_nested_block state (depth - 1)
  | _ ->
      ignore (advance state);
      skip_nested_block state depth

and parse_enum state =
  expect_exact state Enum "expected enum";
  let name = expect_ident state in
  skip_newlines state;
  let rec variants acc =
    skip_newlines state;
    match (current state).kind with
    | End ->
        ignore (advance state);
        Enum { name; variants = List.rev acc }
    | Ident variant_name ->
        ignore (advance state);
        let payload =
          match (current state).kind with
          | LParen ->
              ignore (advance state);
              let payload = parse_type_list state in
              expect_exact state RParen "expected ')' after enum payload types";
              payload
          | _ -> []
        in
        variants ({ name = variant_name; payload } :: acc)
    | _ -> raise (Error ("expected enum variant or end", current state))
  in
  variants []

and parse_type_list state =
  let rec loop acc =
    match (current state).kind with
    | RParen -> List.rev acc
    | _ ->
        let ty = parse_type_expr state in
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (ty :: acc)
        | RParen -> List.rev (ty :: acc)
        | _ -> raise (Error ("expected ',' or ')' in type list", current state))
        end
  in
  loop []

and parse_struct state =
  expect_exact state Struct "expected struct";
  let name = expect_ident state in
  skip_newlines state;
  let rec fields acc =
    skip_newlines state;
    match (current state).kind with
    | End ->
        ignore (advance state);
        Struct { name; fields = List.rev acc }
    | Ident field_name ->
        ignore (advance state);
        expect_exact state Colon "expected ':' after field name";
        let ty = parse_type_expr state in
        let field : struct_field = { name = field_name; ty } in
        fields (field :: acc)
    | _ -> raise (Error ("expected struct field or end", current state))
  in
  fields []

  and parse_trait state =
    expect_exact state Trait "expected trait";
    let name = expect_ident state in
    skip_newlines state;
    let rec consume_body depth =
    match (current state).kind with
    | Eof -> ()
      | If | Match | While | For | Test ->
      ignore (advance state);
      consume_body (depth + 1)
    | End ->
      ignore (advance state);
      if depth <= 1 then () else consume_body (depth - 1)
    | _ ->
      ignore (advance state);
      consume_body depth
    in
    consume_body 1;
    Trait { name }

and parse_const state =
  expect_exact state Const "expected const";
  let name = expect_ident state in
  let ty =
    match (current state).kind with
    | Colon ->
        ignore (advance state);
        Some (parse_type_expr state)
    | _ -> None
  in
  expect_exact state Eq "expected '=' after const declaration";
  let value = parse_expr state in
  Const { name; ty; value }

and parse_global ~is_mutable state =
  if is_mutable then expect_exact state Mut "expected mut";
  let name = expect_ident state in
  let ty =
    match (current state).kind with
    | Colon ->
        ignore (advance state);
        Some (parse_type_expr state)
    | _ -> None
  in
  expect_exact state Eq "expected '=' after global declaration";
  let value = parse_expr state in
  Global { name; is_mutable; ty; value }

and parse_impl state =
  expect_exact state Impl "expected impl";
  let first_name = expect_ident state in
  let struct_name =
    match (current state).kind with
    | For ->
        ignore (advance state);
        expect_ident state
    | _ -> first_name
  in
  skip_newlines state;
  let rec methods acc =
    skip_newlines state;
    match (current state).kind with
    | End ->
        ignore (advance state);
        List.rev acc
    | Pub ->
        ignore (advance state);
        methods acc
    | Def ->
        let decl = parse_function_decl ~method_of:(Some struct_name) state in
        methods (Function decl :: acc)
    | _ -> raise (Error ("expected method or end in impl", current state))
  in
  methods []

and parse_function state =
  Function (parse_function_decl ~method_of:None state)

and parse_function_decl ~method_of state =
  expect_exact state Def "expected def";
  let name = expect_ident state in
  expect_exact state LParen "expected '('";
  let params = parse_params state in
  expect_exact state RParen "expected ')'";
  let ret_type =
    match (current state).kind with
    | Arrow ->
        ignore (advance state);
        Some (parse_type_expr state)
    | _ -> None
  in
  (* Handle inline body with = or block body *)
  let body =
    match (current state).kind with
    | Eq ->
        ignore (advance state);
        skip_newlines state;
        let expr = parse_expr state in
        [Expr.Expr expr]  (* Single expression body *)
    | _ ->
        skip_newlines state;
        parse_block_until_end state
  in
  { name; method_of; params; ret_type; body }

and parse_params state =
  let rec loop acc =
    skip_newlines state;  (* Allow newlines in parameter list *)
    match (current state).kind with
    | RParen -> List.rev acc
    | Amp ->
        ignore (advance state);
        begin match (current state).kind with
        | Mut -> ignore (advance state)
        | _ -> ()
        end;
        begin match (current state).kind with
        | Dyn -> ignore (advance state)
        | _ -> ()
        end;
        (* Check for self after &mut or & *)
        begin match (current state).kind with
        | Self_ ->
            ignore (advance state);
            let name = "self" in
            let ty = None in
            let param : param = { name; ty } in
            skip_newlines state;
            begin match (current state).kind with
            | Comma -> ignore (advance state); loop (param :: acc)
            | RParen -> List.rev (param :: acc)
            | _ -> raise (Error ("expected ',' or ')'", current state))
            end
        | _ ->
        let name = expect_ident state in
        let ty =
          match (current state).kind with
          | Colon ->
              ignore (advance state);
              Some (parse_type_expr state)
          | _ -> None
        in
        let param : param = { name; ty } in
        skip_newlines state;
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (param :: acc)
        | RParen -> List.rev (param :: acc)
        | _ -> raise (Error ("expected ',' or ')'", current state))
        end
        end
    | AmpMut ->
        (* &mut as single token *)
        ignore (advance state);
        begin match (current state).kind with
        | Dyn -> ignore (advance state)
        | _ -> ()
        end;
        (* Check for self after &mut *)
        begin match (current state).kind with
        | Self_ ->
            ignore (advance state);
            let name = "self" in
            let ty = None in
            let param : param = { name; ty } in
            skip_newlines state;
            begin match (current state).kind with
            | Comma -> ignore (advance state); loop (param :: acc)
            | RParen -> List.rev (param :: acc)
            | _ -> raise (Error ("expected ',' or ')'", current state))
            end
        | _ ->
        let name = expect_ident state in
        let ty =
          match (current state).kind with
          | Colon ->
              ignore (advance state);
              Some (parse_type_expr state)
          | _ -> None
        in
        let param : param = { name; ty } in
        skip_newlines state;
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (param :: acc)
        | RParen -> List.rev (param :: acc)
        | _ -> raise (Error ("expected ',' or ')'", current state))
        end
        end
    | Ident _ ->
        let name = expect_ident state in
        let ty =
          match (current state).kind with
          | Colon ->
              ignore (advance state);
              Some (parse_type_expr state)
          | _ -> None
        in
        let param : param = { name; ty } in
        skip_newlines state;  (* Allow newlines after type *)
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (param :: acc)
        | RParen -> List.rev (param :: acc)
        | _ -> raise (Error ("expected ',' or ')'", current state))
        end
    | Self_ ->
        ignore (advance state);
        let name = "self" in
        let ty =
          match (current state).kind with
          | Colon ->
              ignore (advance state);
              Some (parse_type_expr state)
          | _ -> None
        in
        let param : param = { name; ty } in
        skip_newlines state;  (* Allow newlines after type *)
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (param :: acc)
        | RParen -> List.rev (param :: acc)
        | _ -> raise (Error ("expected ',' or ')'", current state))
        end
    | _ -> raise (Error ("invalid parameter list", current state))
  in
  loop []

and parse_type_expr state =
  let is_terminator = function
    | Newline | Eq | Then | Else | Elsif | End | When | Do | RBrace | RBracket -> true
    | _ -> false
  in
  let buffer = Buffer.create 32 in
  (* Handle leading &mut or & in types *)
  let saw_ref = match (current state).kind with
  | Amp ->
      Buffer.add_string buffer (token_text (advance state).kind);
      begin match (current state).kind with
      | Mut -> Buffer.add_string buffer (token_text (advance state).kind); true
      | _ -> true
      end
  | AmpMut ->
      Buffer.add_string buffer (token_text (advance state).kind); true
  | _ -> false
  in
  let rec consume saw_any depth paren_depth =
    if is_terminator (current state).kind && depth = 0 && paren_depth = 0 then
      if saw_any then Buffer.contents buffer else raise (Error ("expected type", current state))
    else 
      let tok = current state in
      let new_depth = match tok.kind with
        | LBracket -> depth + 1
        | RBracket -> if depth > 0 then depth - 1 else depth
        | _ -> depth
      in
      let new_paren_depth = match tok.kind with
        | LParen -> paren_depth + 1
        | RParen -> if paren_depth > 0 then paren_depth - 1 else 0
        | _ -> paren_depth
      in
      (* Stop if we hit a comma at top level (not in brackets or parens) *)
      if tok.kind = Comma && depth = 0 && paren_depth = 0 then
        if saw_any then Buffer.contents buffer else raise (Error ("expected type", current state))
      else if tok.kind = RParen && depth = 0 && paren_depth = 0 then begin
        (* Closing paren of parameter list - don't consume it, just stop *)
        if saw_any then Buffer.contents buffer else raise (Error ("expected type", current state))
      end
      else if tok.kind = RParen && depth = 0 && paren_depth = 1 then begin
        (* Closing paren of tuple type - include it and stop *)
        Buffer.add_string buffer (token_text (advance state).kind);
        Buffer.contents buffer
      end
      else begin
        Buffer.add_string buffer (token_text (advance state).kind);
        consume true new_depth new_paren_depth
      end
  in
  match consume saw_ref 0 0 with
  | "Int" -> TInt
  | "UInt" -> TInt
  | "i8" | "i16" | "i32" | "i64" | "i128" -> TInt
  | "u8" | "u16" | "u32" | "u64" | "u128" -> TInt
  | "isize" | "usize" -> TInt
  | "Bool" -> TBool
  | "Unit" -> TUnit
  | "Float" | "f32" | "f64" -> TFloat
  | "String" -> TString
  | "Char" -> TChar
  | text -> TNamed text

and token_text = function
  | Ident name -> name
  | Int n -> string_of_int n
  | Int64 n -> Int64.to_string n
  | Float s -> s
  | String _ -> "String"
  | Char _ -> "Char"
  | True -> "true"
  | False -> "false"
  | Nil -> "nil"
  | Def -> "def"
  | End -> "end"
  | Let -> "let"
  | Mut -> "mut"
  | Return -> "return"
  | Break -> "break"
  | Next -> "next"
  | If -> "if"
  | Else -> "else"
  | Elsif -> "elsif"
  | Unless -> "unless"
  | Match -> "match"
  | When -> "when"
  | Then -> "then"
  | Do -> "do"
  | Loop -> "loop"
  | While -> "while"
  | For -> "for"
  | In -> "in"
  | Until -> "until"
  | Enum -> "enum"
  | Impl -> "impl"
  | Struct -> "struct"
  | Trait -> "trait"
  | Use -> "use"
  | Module -> "module"
  | Pub -> "pub"
  | Private -> "private"
  | Macro -> "macro"
  | Where -> "where"
  | As -> "as"
  | Is -> "is"
  | Question -> "?"
  | Test -> "test"
  | Dyn -> "dyn"
  | Self_ -> "self"
  | SelfType -> "Self"
  | Super -> "super"
  | Crate -> "crate"
  | TkMove -> "move"
  | TkCopy -> "copy"
  | TkDrop -> "drop"
  | TkOwn -> "own"
  | TkRef -> "ref"
  | TkRefMut -> "ref mut"
  | Pre -> "pre"
  | Post -> "post"
  | Invariant -> "invariant"
  | Cap -> "cap"
  | Unsafe -> "unsafe"
  | Rationale -> "rationale"
  | Budget -> "budget"
  | Edition -> "edition"
  | Requires -> "requires"
  | Ensures -> "ensures"
  | Effect -> "effect"
  | Pure -> "pure"
  | Async -> "async"
  | Await -> "await"
  | Yield -> "yield"
  | Defer -> "defer"
  | Try -> "try"
  | Catch -> "catch"
  | Finally -> "finally"
  | Guard -> "guard"
  | Handle -> "handle"
  | With -> "with"
  | Implies -> "implies"
  | Comptime -> "comptime"
  | Const -> "const"
  | Static -> "static"
  | Type -> "type"
  | Alias -> "alias"
  | Extern -> "extern"
  | Inline -> "inline"
  | LParen -> "("
  | RParen -> ")"
  | LBracket -> "["
  | RBracket -> "]"
  | LBrace -> "{"
  | RBrace -> "}"
  | Comma -> ","
  | Dot -> "."
  | DotDot -> ".."
  | DotDotEq -> "..="
  | Colon -> ":"
  | ColonColon -> "::"
  | Semicolon -> ";"
  | At -> "@"
  | Hash -> "#"
  | Arrow -> "->"
  | FatArrow -> "=>"
  | PipeArrow -> "|>"
  | Eq -> "="
  | PlusEq -> "+="
  | MinusEq -> "-="
  | StarEq -> "*="
  | SlashEq -> "/="
  | PercentEq -> "%="
  | Amp -> "&"
  | AmpMut -> "&mut"
  | Bang -> "!"
  | Plus -> "+"
  | Minus -> "-"
  | Star -> "*"
  | Slash -> "/"
  | Percent -> "%"
  | AndAnd -> "&&"
  | OrOr -> "||"
  | EqEq -> "=="
  | BangEq -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | LtEq -> "<="
  | GtEq -> ">="
  | Pipe -> "|"
  | Caret -> "^"
  | Tilde -> "~"
  | Shl -> "<<"
  | Shr -> ">>"
  | DoubleStar -> "**"
  | AmpEq -> "&="
  | PipeEq -> "|="
  | CaretEq -> "^="
  | ShlEq -> "<<="
  | ShrEq -> ">>="
  | Newline -> "\n"
  | Eof -> ""
  | Error msg -> "error(" ^ msg ^ ")"

and parse_block_until_end state =
  skip_newlines state;
  let rec stmts acc =
    skip_newlines state;
    match (current state).kind with
    | End ->
        ignore (advance state);
        List.rev acc
    | _ -> stmts (parse_stmt state :: acc)
  in
  stmts []

and parse_inline_block state terminators =
  let rec stmts acc =
    skip_newlines state;
    if List.exists (fun kind -> (current state).kind = kind) terminators then
      List.rev acc
    else
      stmts (parse_stmt state :: acc)
  in
  stmts []

and parse_stmt state =
  skip_newlines state;
  match (current state).kind with
  | Let ->
      ignore (advance state);
      let is_mutable =
        match (current state).kind with
        | Mut ->
            ignore (advance state);
            true
        | _ -> false
      in
      (* Handle tuple destructuring: let (a, b) = expr *)
      begin match (current state).kind with
      | LParen ->
          ignore (advance state);
          let names = parse_tuple_names state in
          expect_exact state RParen "expected ')' after tuple names";
          (* Skip optional type annotation *)
          begin match (current state).kind with
          | Colon ->
              ignore (advance state);
              let _ = parse_type_expr state in ()
          | _ -> ()
          end;
          expect_exact state Eq "expected '=' in let binding";
          let expr = parse_expr state in
            Expr.LetTuple (names, is_mutable, expr)
      | _ ->
          let name = expect_ident state in
          (* Skip optional type annotation: let x: Type = expr *)
          begin match (current state).kind with
          | Colon ->
              ignore (advance state);
              let _ = parse_type_expr state in ()
          | _ -> ()
          end;
          expect_exact state Eq "expected '=' in let binding";
          Expr.Let (name, is_mutable, parse_expr state)
      end
  | Mut ->
      (* `mut x = expr` is shorthand for `let mut x = expr` *)
      (* Also handles `mut x: Type = expr` *)
      ignore (advance state);
      let name = expect_ident state in
      (* Skip optional type annotation *)
      begin match (current state).kind with
      | Colon ->
          ignore (advance state);
          (* Consume the type expression *)
          let _ = parse_type_expr state in ()
      | _ -> ()
      end;
      expect_exact state Eq "expected '=' in mut binding";
      Expr.Let (name, true, parse_expr state)
  | Return ->
      ignore (advance state);
      begin match (current state).kind with
      | Newline | End | Elsif | Else | Eof -> Expr.Return None
      | _ -> Expr.Return (Some (parse_expr state))
      end
  | While -> parse_while_stmt state
  | For -> parse_for_stmt state
  | Loop ->
      (* Infinite loop: loop ... end *)
      ignore (advance state);
      let body = parse_block_until_end state in
      (* Represent as while true do body end *)
      Expr.While (Expr.Bool true, body)
  | _ ->
      let expr = parse_expr state in
      begin match (current state).kind with
      | Eq ->
          ignore (advance state);
          Expr.Assign (expr_to_target state expr, parse_expr state)
      | _ -> Expr.Expr expr
      end

and parse_while_stmt state =
  expect_exact state While "expected while";
  let cond = parse_expr state in
  begin match (current state).kind with
  | Do -> ignore (advance state)
  | _ -> ()
  end;
  Expr.While (cond, parse_block_until_end state)

and parse_for_stmt state =
  expect_exact state For "expected for";
  let binding =
  match (current state).kind with
  | LParen ->
    ignore (advance state);
    let names = parse_tuple_names state in
    expect_exact state RParen "expected ')' after tuple names in for binding";
    `Tuple names
  | _ ->
    `Single (ident_or_keyword_as_name state)
  in
  expect_exact state In "expected in after for variable";
  (* Check for range syntax: for x in start..stop do *)
  let start_expr = parse_expr state in
  begin match (current state).kind with
  | DotDot ->
      (* Range syntax: for x in start..stop do body end => for x = start to stop do body end *)
      ignore (advance state);
      let stop_expr = parse_expr state in
      begin match (current state).kind with
      | Do -> ignore (advance state)
      | _ -> ()
      end;
    begin match binding with
    | `Single name -> Expr.For (name, start_expr, stop_expr, parse_block_until_end state)
    | `Tuple _ -> raise (Error ("tuple destructuring is not supported in range for loops", current state))
    end
  | _ ->
      (* Iterator syntax: for x in items do body end *)
      begin match (current state).kind with
      | Do -> ignore (advance state)
      | _ -> ()
      end;
    let body = parse_block_until_end state in
    begin match binding with
    | `Single name -> Expr.For (name, start_expr, Expr.Unit, body)
    | `Tuple names ->
      let tuple_name = "__for_tuple_item" in
      Expr.For (tuple_name, start_expr, Expr.Unit, Expr.LetTuple (names, false, Expr.Var tuple_name) :: body)
    end
  end

and expr_to_target state = function
  | Expr.Var name -> Expr.TargetVar name
  | Expr.FieldAccess (receiver, field_name) -> Expr.TargetField (receiver, field_name)
  | _ -> raise (Error ("invalid assignment target", current state))

and parse_expr state = parse_logical_or state

and parse_logical_or state =
  let rec loop lhs =
    skip_newlines state;
    match (current state).kind with
    | OrOr ->
        ignore (advance state);
        skip_newlines state;
        loop (Expr.Binary ("||", lhs, parse_logical_and state))
    | _ -> lhs
  in
  loop (parse_logical_and state)

and parse_logical_and state =
  let rec loop lhs =
    skip_newlines state;
    match (current state).kind with
    | AndAnd ->
        ignore (advance state);
        skip_newlines state;
        loop (Expr.Binary ("&&", lhs, parse_comparison state))
    | _ -> lhs
  in
  loop (parse_comparison state)

and parse_comparison state =
  let lhs = parse_term state in
  skip_newlines state;
  match (current state).kind with
  | EqEq -> ignore (advance state); skip_newlines state; Expr.Binary ("==", lhs, parse_term state)
  | BangEq -> ignore (advance state); skip_newlines state; Expr.Binary ("<>", lhs, parse_term state)
  | Lt -> ignore (advance state); skip_newlines state; Expr.Binary ("<", lhs, parse_term state)
  | Gt -> ignore (advance state); skip_newlines state; Expr.Binary (">", lhs, parse_term state)
  | LtEq -> ignore (advance state); skip_newlines state; Expr.Binary ("<=", lhs, parse_term state)
  | GtEq -> ignore (advance state); skip_newlines state; Expr.Binary (">=", lhs, parse_term state)
  | _ -> lhs

and parse_term state =
  let rec loop lhs =
    skip_newlines state;  (* Allow newlines in middle of expression *)
    match (current state).kind with
    | Plus -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("+", lhs, parse_factor state))
    | Minus -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("-", lhs, parse_factor state))
    | _ -> lhs
  in
  loop (parse_factor state)

and parse_factor state =
  let rec loop lhs =
    skip_newlines state;
    match (current state).kind with
    | Star -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("*", lhs, parse_unary state))
    | Slash -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("/", lhs, parse_unary state))
    | Percent -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("mod", lhs, parse_unary state))
    | Caret -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("^", lhs, parse_unary state))  (* XOR *)
    | Amp -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("&", lhs, parse_unary state))
    | Pipe -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("|", lhs, parse_unary state))
    | Shl -> ignore (advance state); skip_newlines state; loop (Expr.Binary ("<<", lhs, parse_unary state))
    | Shr -> ignore (advance state); skip_newlines state; loop (Expr.Binary (">>", lhs, parse_unary state))
    | _ -> lhs
  in
  loop (parse_unary state)

and parse_unary state =
  match (current state).kind with
  | Amp ->
    ignore (advance state);
    begin match (current state).kind with
    | Mut -> ignore (advance state)
    | _ -> ()
    end;
    Expr.Unary ("&", parse_unary state)
  | AmpMut ->
    (* &mut as single token *)
    ignore (advance state);
    Expr.Unary ("&mut", parse_unary state)
  | Bang ->
      ignore (advance state);
      Expr.Unary ("not", parse_unary state)
  | Minus ->
      ignore (advance state);
      Expr.Unary ("-", parse_unary state)
  | Star ->
    ignore (advance state);
    Expr.Unary ("*", parse_unary state)
  | _ -> parse_postfix state

and parse_match_arms state =
  let rec arms acc =
    skip_newlines state;
    match (current state).kind with
    | When ->
        ignore (advance state);
        let pattern = parse_pattern state in
        begin match (current state).kind with
        | Then -> ignore (advance state)
        | _ -> ()
        end;
    let body = parse_inline_block state [When; Else; End] in
        arms ({ Expr.pattern; body } :: acc)
  | Else ->
    ignore (advance state);
    let body = parse_inline_block state [End] in
    arms ({ Expr.pattern = Expr.PWildcard; body } :: acc)
    | End ->
        ignore (advance state);
        List.rev acc
  | _ -> raise (Error ("expected when, else, or end in match", current state))
  in
  arms []

and parse_pattern state =
  let rec parse_pattern_alt first acc =
    (* Handle pattern alternation with |: A::B | A::C => just use first pattern *)
    (* For stage0, we simplify by ignoring alternative patterns *)
    match (current state).kind with
    | Pipe ->
        ignore (advance state);
        let _next = parse_single_pattern state in
        parse_pattern_alt first acc
    | _ -> first
  in
  let first = parse_single_pattern state in
  parse_pattern_alt first []

and parse_single_pattern state =
  match (current state).kind with
  | Mut ->
      ignore (advance state);
      parse_single_pattern state
  | TkRef ->
      (* ref keyword in patterns - bind by reference *)
      ignore (advance state);
      parse_single_pattern state
  | Int n ->
      ignore (advance state);
      Expr.PInt (Int64.of_int n)
  | Int64 n ->
      ignore (advance state);
      Expr.PInt n
  | True ->
      ignore (advance state);
      Expr.PBool true
  | False ->
      ignore (advance state);
      Expr.PBool false
  | String text ->
      ignore (advance state);
      Expr.PString text
  | Char ch ->
      ignore (advance state);
      Expr.PChar ch
  | LParen ->
      (* Tuple pattern: (a, b) or (Variant(a), Variant(b)) *)
      ignore (advance state);
      begin match (current state).kind with
      | RParen ->
          ignore (advance state);
          Expr.PWildcard  (* Unit pattern () *)
      | _ ->
          let patterns = parse_pattern_args state in
          expect_exact state RParen "expected ')' after tuple pattern";
          (* Represent tuple pattern as a nested variant pattern *)
          (* For stage0, we simplify by just using the first pattern *)
          (* A full implementation would create a proper tuple pattern AST node *)
          begin match patterns with
          | [] -> Expr.PWildcard
          | [single] -> single
          | first :: _ -> first  (* Simplification: just use first pattern *)
          end
      end
  | _ ->
      begin
        try
          let name, segments = parse_path_name_or_keyword state in
          match segments with
          | [single] when single = "_" -> Expr.PWildcard
          | _ when is_variant_path segments ->
              let enum_name, variant_name = split_variant_path segments in
              let payload =
                match (current state).kind with
                | LParen ->
                    ignore (advance state);
                    let payload = parse_pattern_args state in
                    expect_exact state RParen "expected ')' after variant pattern";
                    payload
                | _ -> []
              in
              Expr.PVariant (enum_name, variant_name, payload)
          | [single] -> Expr.PVar single
          | _ -> Expr.PVar name
        with
        | Error _ -> raise (Error ("expected pattern", current state))
      end

and parse_pattern_args state =
  let rec loop acc =
    match (current state).kind with
    | RParen -> List.rev acc
    | _ ->
        let pattern = parse_pattern state in
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (pattern :: acc)
        | RParen -> List.rev (pattern :: acc)
        | _ -> raise (Error ("expected ',' or ')' in variant pattern", current state))
        end
  in
  loop []

and parse_primary state =
  match (current state).kind with
  | Int n ->
      ignore (advance state);
      Expr.Int (Int64.of_int n)
  | Int64 n ->
      ignore (advance state);
      Expr.Int n
  | Float s ->
      ignore (advance state);
      Expr.Float s
  | String text ->
      ignore (advance state);
      Expr.String text
  | Char ch ->
      ignore (advance state);
      Expr.Char ch
  | True ->
      ignore (advance state);
      Expr.Bool true
  | False ->
      ignore (advance state);
      Expr.Bool false
  | Self_ ->
      ignore (advance state);
      Expr.Var "self"
  (* Handle keywords that can be used as variable names *)
  | Next ->
      ignore (advance state);
      Expr.Var "next"
  | Break ->
      ignore (advance state);
      Expr.Var "break"
  | Loop ->
      ignore (advance state);
      Expr.Var "loop"
  | Until ->
      ignore (advance state);
      Expr.Var "until"
  | Unless ->
      ignore (advance state);
      Expr.Var "unless"
  | Async ->
      ignore (advance state);
      Expr.Var "async"
  | Await ->
      ignore (advance state);
      Expr.Var "await"
  | Yield ->
      ignore (advance state);
      Expr.Var "yield"
  | Defer ->
      ignore (advance state);
      Expr.Var "defer"
  | Try ->
      ignore (advance state);
      Expr.Var "try"
  | Catch ->
      ignore (advance state);
      Expr.Var "catch"
  | Finally ->
      ignore (advance state);
      Expr.Var "finally"
  | Guard ->
      ignore (advance state);
      Expr.Var "guard"
  | Handle ->
      ignore (advance state);
      Expr.Var "handle"
  | With ->
      ignore (advance state);
      Expr.Var "with"
  | Pure ->
      ignore (advance state);
      Expr.Var "pure"
  | Effect ->
      ignore (advance state);
      Expr.Var "effect"
  | Pre ->
      ignore (advance state);
      Expr.Var "pre"
  | Post ->
      ignore (advance state);
      Expr.Var "post"
  | Invariant ->
      ignore (advance state);
      Expr.Var "invariant"
  | Cap ->
      ignore (advance state);
      Expr.Var "cap"
  | Budget ->
      ignore (advance state);
      Expr.Var "budget"
  | Rationale ->
      ignore (advance state);
      Expr.Var "rationale"
  | Requires ->
      ignore (advance state);
      Expr.Var "requires"
  | Ensures ->
      ignore (advance state);
      Expr.Var "ensures"
  | Unsafe ->
      (* unsafe "description" do body end or unsafe do body end *)
      ignore (advance state);
      (* Skip optional description string *)
      begin match (current state).kind with
      | String _ -> ignore (advance state)
      | _ -> ()
      end;
      begin match (current state).kind with
      | Do -> ignore (advance state)
      | _ -> ()
      end;
      let body = parse_block_until_end state in
      (* Return the last expression of the body, or unit if empty *)
      begin match List.rev body with
      | Expr.Expr last :: _ -> last
      | _ -> Expr.Unit
      end
  | If ->
      ignore (advance state);
      let cond = parse_expr state in
      begin match (current state).kind with
      | Then -> ignore (advance state)
      | _ -> ()
      end;
      let then_block = parse_inline_block state [Else; Elsif; End] in
      let rec parse_else_block () =
        match (current state).kind with
        | Else ->
            ignore (advance state);
            Some (parse_inline_block state [End])
        | Elsif ->
            ignore (advance state);
            let elsif_cond = parse_expr state in
            begin match (current state).kind with
            | Then -> ignore (advance state)
            | _ -> ()
            end;
            let elsif_then = parse_inline_block state [Else; Elsif; End] in
            Some [Expr.Expr (Expr.If (elsif_cond, elsif_then, parse_else_block ()))]
        | _ -> None
      in
      let else_block = parse_else_block () in
      expect_exact state End "expected end after if";
      Expr.If (cond, then_block, else_block)
  | Match ->
      ignore (advance state);
      let subject = parse_expr state in
      let arms = parse_match_arms state in
      Expr.Match (subject, arms)
    | Ident _
    | Def
    | End
    | Let
    | Mut
    | Return
    | Else
    | Elsif
    | When
    | Then
    | Do
    | While
    | For
    | In
    | Enum
    | Impl
    | Struct
    | Trait
    | Use
    | Module
    | Pub
    | Private
    | Macro
    | Where
    | As
    | Is
    | Test
    | Dyn
    | SelfType
    | Super
    | Crate
    | TkMove
    | TkCopy
    | TkDrop
    | TkOwn
    | TkRef
    | Edition
    | Comptime
    | Const
    | Static
    | Type
    | Alias
    | Extern
    | Inline ->
      let name, segments = parse_path_name_or_keyword state in
      begin match (current state).kind with
      | Bang ->
          (* Macro call syntax: name![args] or name!(args) *)
          ignore (advance state);
          begin match (current state).kind with
          | LBracket ->
              ignore (advance state);
              let args = parse_call_args ~terminators:[RBracket] state in
              (* Consume the closing ] *)
              if (current state).kind = RBracket then ignore (advance state);
              (* Represent macro call as a function call with macro_ prefix *)
              Expr.Call (Expr.Var ("macro_" ^ name), args)
          | LParen ->
              ignore (advance state);
              let args = parse_call_args state in
              expect_exact state RParen "expected ')' after macro arguments";
              Expr.Call (Expr.Var ("macro_" ^ name), args)
          | _ -> raise (Error ("expected '[' or '(' after macro name", current state))
          end
      | LBrace ->
          ignore (advance state);
          let fields = parse_struct_literal_fields state in
          expect_exact state RBrace "expected '}' after struct literal";
          Expr.StructLit (name, fields)
      | LParen ->
          ignore (advance state);
          let args = parse_call_args state in
          expect_exact state RParen "expected ')' after call arguments";
          if is_variant_path segments then
            let enum_name, variant_name = split_variant_path segments in
            Expr.Variant (enum_name, variant_name, args)
          else
            Expr.Call (Expr.Var name, args)
      | _ ->
          if is_variant_path segments then
            let enum_name, variant_name = split_variant_path segments in
            Expr.Variant (enum_name, variant_name, [])
          else
            Expr.Var name
      end
  | LParen ->
      ignore (advance state);
      begin match (current state).kind with
      | RParen ->
        ignore (advance state);
        Expr.Unit
      | _ ->
        let expr = parse_expr state in
        begin match (current state).kind with
        | Comma ->
            (* Tuple expression *)
            let rec loop acc =
              ignore (advance state);  (* consume comma *)
              let next_expr = parse_expr state in
              begin match (current state).kind with
              | Comma -> loop (next_expr :: acc)
              | RParen -> ignore (advance state); List.rev (expr :: acc)
              | _ -> raise (Error ("expected ',' or ')' in tuple", current state))
              end
            in
            let elements = loop [] in
            (* For now, represent tuples as a call to a tuple constructor *)
            Expr.Call (Expr.Var "tuple", elements)
        | RParen ->
            ignore (advance state);
            expr
        | _ -> raise (Error ("expected ')' at", current state))
        end
      end
  | LBracket ->
      (* Array literal *)
      ignore (advance state);
      let rec elements acc =
        skip_newlines state;
        match (current state).kind with
        | RBracket -> ignore (advance state); List.rev acc
        | _ ->
            let expr = parse_expr state in
            skip_newlines state;
            begin match (current state).kind with
            | Comma ->
                ignore (advance state);
                elements (expr :: acc)
            | RBracket -> ignore (advance state); List.rev (expr :: acc)
            | _ -> raise (Error ("expected ',' or ']' in array literal", current state))
            end
      in
      let items = elements [] in
      (* Represent array as a call to Vec::new or array constructor *)
      Expr.Call (Expr.Var "array", items)
  | Pipe ->
      (* Could be closure |args| body *)
      (* Look ahead to distinguish from pattern alternation *)
      (* Closure: |simple_ident| or |a, b| *)
      (* Pattern alt: |Enum::Variant which has :: after ident *)
      ignore (advance state);  (* consume first | *)
      let rec parse_closure_params acc =
        match (current state).kind with
        | Pipe -> 
            (* Empty params or end of params *)
            ignore (advance state); 
            List.rev acc
        | Ident name ->
          ignore (advance state);
            begin match (current state).kind with
            | Comma -> ignore (advance state); parse_closure_params (name :: acc)
            | Pipe -> ignore (advance state); List.rev (name :: acc)
          | _ -> List.rev (name :: acc)
            end
        | _ -> raise (Error ("expected closure parameter or '|'", current state))
      in
      let params = parse_closure_params [] in
      let body = parse_expr state in
      Expr.Lambda (params, body)
  | _ -> raise (Error ("expected expression", current state))

and parse_postfix state =
  let rec loop expr =
    skip_newlines state;
    match (current state).kind with
    | Dot ->
        ignore (advance state);
        (* Handle tuple field access like kv.0, kv.1 *)
        begin match (current state).kind with
        | Int n ->
            ignore (advance state);
            (* Convert tuple index to field access *)
            loop (Expr.FieldAccess (expr, string_of_int n))
        | _ ->
            let member_name = expect_ident state in
            begin match (current state).kind with
            | LParen ->
                ignore (advance state);
                let args = parse_call_args state in
                expect_exact state RParen "expected ')' after method arguments";
                loop (Expr.MethodCall (expr, member_name, args))
            | _ -> loop (Expr.FieldAccess (expr, member_name))
            end
        end
    | LBracket ->
        ignore (advance state);
        let index_expr = parse_expr state in
        expect_exact state RBracket "expected ']' after index expression";
        (* Convert expr[index] to expr.index(index) for method call semantics *)
        loop (Expr.MethodCall (expr, "index", [index_expr]))
    | As ->
        ignore (advance state);
        let ty = parse_type_expr state in
        loop (Expr.Cast (expr, ty))
    | Question ->
      ignore (advance state);
      loop (Expr.Try expr)
    | _ -> expr
  in
  loop (parse_primary state)

and parse_path_name state =
  let first = expect_ident state in
  let rec segments acc =
    match (current state).kind with
    | ColonColon ->
        ignore (advance state);
        let next = expect_ident state in
        segments (next :: acc)
    | _ -> List.rev acc
  in
  let segs = segments [first] in
  (String.concat "::" segs, segs)

and ident_or_keyword_as_name state =
  match (current state).kind with
  | Ident name -> ignore (advance state); name
  | Def -> ignore (advance state); "def"
  | End -> ignore (advance state); "end"
  | Let -> ignore (advance state); "let"
  | Mut -> ignore (advance state); "mut"
  | Return -> ignore (advance state); "return"
  | Next -> ignore (advance state); "next"
  | Break -> ignore (advance state); "break"
  | If -> ignore (advance state); "if"
  | Else -> ignore (advance state); "else"
  | Elsif -> ignore (advance state); "elsif"
  | Match -> ignore (advance state); "match"
  | When -> ignore (advance state); "when"
  | Then -> ignore (advance state); "then"
  | Do -> ignore (advance state); "do"
  | Loop -> ignore (advance state); "loop"
  | While -> ignore (advance state); "while"
  | For -> ignore (advance state); "for"
  | In -> ignore (advance state); "in"
  | Until -> ignore (advance state); "until"
  | Unless -> ignore (advance state); "unless"
  | Enum -> ignore (advance state); "enum"
  | Impl -> ignore (advance state); "impl"
  | Struct -> ignore (advance state); "struct"
  | Trait -> ignore (advance state); "trait"
  | Use -> ignore (advance state); "use"
  | Module -> ignore (advance state); "module"
  | Pub -> ignore (advance state); "pub"
  | Private -> ignore (advance state); "private"
  | Macro -> ignore (advance state); "macro"
  | Where -> ignore (advance state); "where"
  | As -> ignore (advance state); "as"
  | Is -> ignore (advance state); "is"
  | Test -> ignore (advance state); "test"
  | Dyn -> ignore (advance state); "dyn"
  | Self_ -> ignore (advance state); "self"
  | SelfType -> ignore (advance state); "Self"
  | Super -> ignore (advance state); "super"
  | Crate -> ignore (advance state); "crate"
  | Async -> ignore (advance state); "async"
  | Await -> ignore (advance state); "await"
  | Yield -> ignore (advance state); "yield"
  | Defer -> ignore (advance state); "defer"
  | Try -> ignore (advance state); "try"
  | Catch -> ignore (advance state); "catch"
  | Finally -> ignore (advance state); "finally"
  | Guard -> ignore (advance state); "guard"
  | Handle -> ignore (advance state); "handle"
  | With -> ignore (advance state); "with"
  | TkMove -> ignore (advance state); "move"
  | TkCopy -> ignore (advance state); "copy"
  | TkDrop -> ignore (advance state); "drop"
  | TkOwn -> ignore (advance state); "own"
  | TkRef -> ignore (advance state); "ref"
  | Pure -> ignore (advance state); "pure"
  | Effect -> ignore (advance state); "effect"
  | Pre -> ignore (advance state); "pre"
  | Post -> ignore (advance state); "post"
  | Invariant -> ignore (advance state); "invariant"
  | Cap -> ignore (advance state); "cap"
  | Unsafe -> ignore (advance state); "unsafe"
  | Budget -> ignore (advance state); "budget"
  | Edition -> ignore (advance state); "edition"
  | Rationale -> ignore (advance state); "rationale"
  | Requires -> ignore (advance state); "requires"
  | Ensures -> ignore (advance state); "ensures"
  | Comptime -> ignore (advance state); "comptime"
  | Const -> ignore (advance state); "const"
  | Static -> ignore (advance state); "static"
  | Type -> ignore (advance state); "type"
  | Alias -> ignore (advance state); "alias"
  | Extern -> ignore (advance state); "extern"
  | Inline -> ignore (advance state); "inline"
  | _ -> raise (Error ("expected identifier", current state))

and parse_path_name_or_keyword state =
  let first = ident_or_keyword_as_name state in
  let rec segments acc =
    match (current state).kind with
    | ColonColon ->
        ignore (advance state);
        let next = ident_or_keyword_as_name state in
        segments (next :: acc)
    | _ -> List.rev acc
  in
  let segs = segments [first] in
  (String.concat "::" segs, segs)

and is_variant_path segments =
  let starts_upper name =
    String.length name > 0 &&
    match name.[0] with
    | 'A' .. 'Z' -> true
    | _ -> false
  in
  match List.rev segments with
  | variant_name :: enum_segments_rev ->
      starts_upper variant_name
      && begin match enum_segments_rev with
         | enum_name :: _ -> starts_upper enum_name
         | [] -> false
         end
  | [] -> false

and split_variant_path segments =
  match List.rev segments with
  | variant_name :: rest_rev ->
      (String.concat "::" (List.rev rest_rev), variant_name)
  | [] -> failwith "expected variant path"

and parse_call_args ?(terminators = [RParen]) state =
  let is_terminator kind = List.exists (fun term -> term = kind) terminators in
  let rec args acc =
    skip_newlines state;
    if is_terminator (current state).kind then List.rev acc
    else
      let expr = parse_expr state in
      skip_newlines state;
      let curr_kind = (current state).kind in
      if curr_kind = Comma then begin
        ignore (advance state);
        args (expr :: acc)
      end
      else if is_terminator curr_kind then List.rev (expr :: acc)
      else raise (Error ("expected ',' or terminator in argument list", current state))
  in
  args []

and parse_struct_literal_fields state =
  let rec fields acc =
    skip_newlines state;
    match (current state).kind with
    | RBrace -> List.rev acc
    | _ ->
        let field_name = ident_or_keyword_as_name state in
        let field_value =
          match (current state).kind with
          | Colon | Eq ->
              ignore (advance state);
              parse_expr state
          | _ -> Expr.Var field_name
        in
        skip_newlines state;
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            fields ((field_name, field_value) :: acc)
        | RBrace -> List.rev ((field_name, field_value) :: acc)
        | _ -> raise (Error ("expected ',' or '}' in struct literal", current state))
        end
  in
  fields []

and parse_tuple_names state =
  let rec loop acc =
    match (current state).kind with
    | RParen -> List.rev acc
    | Ident name ->
        ignore (advance state);
        begin match (current state).kind with
        | Comma ->
            ignore (advance state);
            loop (name :: acc)
        | RParen -> List.rev (name :: acc)
        | _ -> raise (Error ("expected ',' or ')' in tuple names", current state))
        end
    | _ -> raise (Error ("expected identifier in tuple destructuring", current state))
  in
  loop []

let parse tokens =
  let state = { tokens = Array.of_list tokens; pos = 0 } in
  parse_program state
