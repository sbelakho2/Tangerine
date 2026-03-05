(* Tangerine Parser – stage0
   Full recursive-descent parser producing AST.
   Keeps backward-compat parse_structural for CLI. *)

open Token
open Ast

(* ── Backward-compat structural result ─────────────────────────────── *)

type result = {
  ok : bool;
  diagnostics : Diagnostics.t list;
}

(* ── AST parse result ──────────────────────────────────────────────── *)

type parse_result = {
  program : Ast.program;
  parse_diags : Diagnostics.t list;
}

(* ── Parser state ──────────────────────────────────────────────────── *)

type state = {
  toks : Token.t array;
  mutable pos : int;
  file : string;
  mutable diags : Diagnostics.t list;
}

(* ── Helpers ───────────────────────────────────────────────────────── *)

let mk ~file tokens =
  { toks = Array.of_list tokens; pos = 0; file; diags = [] }

let peek st =
  if st.pos < Array.length st.toks then st.toks.(st.pos)
  else Token.make Eof "" 0 0

let advance st =
  if st.pos < Array.length st.toks then st.pos <- st.pos + 1

let loc_of st =
  let t = peek st in
  { Ast.file = st.file; line = t.line; col = t.col }

let err st msg =
  let t = peek st in
  st.diags <- Diagnostics.make ~code:"E200" ~file:st.file
    ~line:t.line ~col:t.col msg :: st.diags

let at_kw st k = match (peek st).kind with Kw s -> s = k | _ -> false
let at_sym st s = match (peek st).kind with Symbol x -> x = s | _ -> false
let at_ident st = match (peek st).kind with Ident _ -> true | _ -> false
let at_nl st = match (peek st).kind with Newline -> true | _ -> false
let at_eof st = match (peek st).kind with Eof -> true | _ -> false

let eat_kw st k =
  if at_kw st k then (advance st; true)
  else (err st (Printf.sprintf "expected '%s'" k); false)

let eat_sym st s =
  if at_sym st s then (advance st; true)
  else (err st (Printf.sprintf "expected '%s'" s); false)

(* Check for duplicate field names in struct literal fields *)
let check_dup_fields st fields =
  let seen = Hashtbl.create 8 in
  List.iter (fun (name, _) ->
    if Hashtbl.mem seen name then
      err st (Printf.sprintf "duplicate field '%s' in struct literal" name)
    else
      Hashtbl.replace seen name true
  ) fields

(* Soft keywords: may be used as identifiers in non-keyword position.
   Single source of truth is in Token.is_soft_keyword. *)
let is_soft_keyword s = Token.is_soft_keyword s

(* Strip integer type suffix from a numeric literal string.
   Returns (digits_only, Some suffix) or (original, None). *)
let strip_int_suffix s =
  let len = String.length s in
  (* Check longer suffixes first: usize, isize, u16, i16, u32, i32, u64, i64 *)
  let try_suffix suf =
    let slen = String.length suf in
    if len > slen && String.sub s (len - slen) slen = suf then
      Some (String.sub s 0 (len - slen), Some suf)
    else None
  in
  let suffixes = ["usize"; "isize"; "u16"; "i16"; "u32"; "i32"; "u64"; "i64"; "u8"; "i8"; "f32"; "f64"] in
  match List.find_map try_suffix suffixes with
  | Some result -> result
  | None -> (s, None)

(* Keywords that can be used as binding names in patterns *)
let is_pattern_keyword = function
  | s when is_soft_keyword s -> true
  | "const" | "next" | "type" | "use" -> true
  | _ -> false

let eat_ident st =
  match (peek st).kind with
  | Ident s -> advance st; s
  | Kw "Self" -> advance st; "Self"
  | Kw s when is_soft_keyword s -> advance st; s
  | _ ->
    let t = peek st in
    err st (Printf.sprintf "expected identifier, got '%s'" t.lexeme);
    advance st; (* consume the bad token to avoid infinite loops *)
    "<error>"

let skip_nl st =
  while at_nl st do advance st done

let at_block_end st terms =
  at_eof st || List.exists (at_kw st) terms

(* ── Type parsing ──────────────────────────────────────────────────── *)

let rec parse_type st =
  let base = parse_type_primary st in
  if at_sym st "?" then (advance st; TyOption base) else base

and parse_type_primary st =
  let t = peek st in
  match t.kind with
  | Kw "Self" -> advance st; TySelf
  | Kw "fn" ->
    advance st;
    ignore (eat_sym st "(");
    let ps = if at_sym st ")" then [] else parse_type_list st in
    ignore (eat_sym st ")");
    if at_sym st "->" then (advance st; TyFn (ps, parse_type st))
    else TyFn (ps, TyTuple [])
  | Symbol "(" ->
    advance st; skip_nl st;
    if at_sym st ")" then (advance st; TyTuple [])
    else begin
      let ts = parse_type_list st in
      skip_nl st;
      ignore (eat_sym st ")");
      match ts with [t1] -> t1 | _ -> TyTuple ts
    end
  | Symbol "[" ->
    advance st; skip_nl st;
    if at_sym st "]" then (advance st; TyName ("Vec", [TyInfer]))
    else begin
      let inner = parse_type st in
      if at_sym st ";" then begin
        (* Fixed-size array: [Type; N] — read the size expression *)
        advance st; skip_nl st;
        let size_tok = peek st in
        let _size = match size_tok.kind with
          | IntLit s -> advance st; (try int_of_string s with _ -> 0)
          | Ident _ -> advance st; 0 (* named const — evaluated later *)
          | _ ->
            err st "expected array size after ';'";
            while not (at_sym st "]") && not (at_eof st) do advance st done;
            0
        in
        ignore (eat_sym st "]");
        TyName ("Array", [inner])
      end else begin
        ignore (eat_sym st "]");
        TyName ("Vec", [inner])
      end
    end
  | Symbol "&" ->
    advance st;
    let m = at_kw st "mut" in
    if m then advance st;
    TyRef (m, parse_type st)
  | Kw "dyn" ->
    (* dyn TraitName — parse the inner type and wrap with dyn marker *)
    advance st;
    let inner = parse_type st in
    (* Prefix "dyn " to the type name to preserve the dynamic dispatch marker *)
    (match inner with
     | TyName (n, args) -> TyName ("dyn " ^ n, args)
     | _ -> inner)
  | Symbol "*" ->
    (* Raw pointer: *mut T or *const T — preserve mutability *)
    advance st;
    let is_mut = at_kw st "mut" in
    if is_mut then advance st
    else if at_kw st "const" then advance st;
    let inner = parse_type st in
    TyName ((if is_mut then "*mut" else "*const"), [inner])
  | Ident name ->
    advance st;
    (* Handle qualified type names: ast::Param, Token::Kind — preserve full path *)
    let parts = ref [name] in
    while at_sym st "::" do
      advance st;
      parts := eat_ident st :: !parts
    done;
    let name = String.concat "::" (List.rev !parts) in
    if at_sym st "[" then begin
      advance st; skip_nl st;
      let args = parse_type_list st in
      skip_nl st;
      ignore (eat_sym st "]");
      TyName (name, args)
    end else
      TyName (name, [])
  | Kw name when String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' ->
    advance st; TyName (name, [])
  | _ -> err st "expected type"; advance st; TyInfer

and parse_type_list st =
  let ts = ref [parse_type st] in
  while at_sym st "," do
    advance st; skip_nl st;
    (* Handle trailing comma before closing delimiter *)
    if at_sym st ")" || at_sym st "]" || at_sym st "}" then ()
    else ts := parse_type st :: !ts
  done;
  List.rev !ts

(* ── Pattern parsing ───────────────────────────────────────────────── *)

let rec parse_pattern st =
  let l = loc_of st in
  let t = peek st in
  let base = match t.kind with
    | Kw "true" -> advance st; PatLit (EBool (true, l))
    | Kw "false" -> advance st; PatLit (EBool (false, l))
    | Kw "mut" ->
      advance st; let name = eat_ident st in PatMut (name, l)
    | Kw "ref" ->
      (* ref binding: ref x or ref mut x *)
      advance st;
      let _m = at_kw st "mut" in
      if _m then advance st;
      let name = eat_ident st in PatBind (name, l)
    | Kw s when is_pattern_keyword s ->
      advance st;
      (* Handle qualified paths: KeywordName::Variant *)
      let parts = ref [s] in
      while at_sym st "::" do
        advance st;
        if at_ident st then parts := eat_ident st :: !parts
        else match (peek st).kind with
          | Kw sk when is_pattern_keyword sk -> advance st; parts := sk :: !parts
          | _ -> ()
      done;
      let vname = String.concat "::" (List.rev !parts) in
      if at_sym st "(" then begin
        advance st; skip_nl st;
        let pats = ref [] in
        if not (at_sym st ")") then begin
          pats := parse_pattern st :: !pats;
          while at_sym st "," do
            advance st; skip_nl st;
            pats := parse_pattern st :: !pats
          done
        end;
        ignore (eat_sym st ")");
        PatVariant (vname, List.rev !pats, l)
      end else
        PatBind (vname, l)
    | IntLit s ->
      advance st;
      let (num_s, _suffix) = strip_int_suffix s in
      PatLit (EInt ((try int_of_string num_s with _ -> 0), l))
    | FloatLit s ->
      advance st; PatLit (EFloat (float_of_string s, l))
    | StringLit s ->
      advance st; PatLit (EStr (s, l))
    | CharLit s ->
      advance st; PatLit (EChar (s, l))
    | Ident name ->
      advance st;
      if name = "_" then PatWild l
      else begin
        (* Handle qualified names: TokenKind::Eof *)
        let parts = ref [name] in
        while at_sym st "::" do
          advance st;
          if at_ident st then
            parts := eat_ident st :: !parts
        done;
        let vname = String.concat "::" (List.rev !parts) in
        if at_sym st "(" then begin
          advance st; skip_nl st;
          let pats = ref [] in
          if not (at_sym st ")") then begin
            pats := parse_pattern st :: !pats;
            while at_sym st "," do
              advance st; skip_nl st;
              pats := parse_pattern st :: !pats
            done
          end;
          ignore (eat_sym st ")");
          PatVariant (vname, List.rev !pats, l)
        end else if at_sym st "{" then begin
          advance st; skip_nl st;
          let fields = ref [] in
          while not (at_sym st "}") && not (at_eof st) do
            let fname = eat_ident st in
            let pat = if at_sym st ":" then
              (advance st; Some (parse_pattern st))
            else None in
            fields := (fname, pat) :: !fields;
            if at_sym st "," then (advance st; skip_nl st)
            else skip_nl st
          done;
          ignore (eat_sym st "}");
          PatStruct (vname, List.rev !fields, l)
        end else
          PatBind (vname, l)
      end
    | Symbol "(" ->
      advance st; skip_nl st;
      let pats = ref [] in
      if not (at_sym st ")") then begin
        pats := parse_pattern st :: !pats;
        while at_sym st "," do
          advance st; skip_nl st;
          pats := parse_pattern st :: !pats
        done
      end;
      ignore (eat_sym st ")");
      PatTuple (List.rev !pats, l)
    | _ ->
      err st "expected pattern"; advance st; PatWild l
  in
  if at_sym st "|" && not (at_sym st "||") then begin
    advance st; skip_nl st;
    let right = parse_pattern st in
    PatOr (base, right, l)
  end else
    base

(* ── Expression parsing (precedence climbing) ─────────────────────── *)

let rec parse_expr st = parse_assignment st

and parse_assignment st =
  let e = parse_logical_or st in
  let t = peek st in
  match t.kind with
  | Symbol "=" ->
    let l = loc_of st in
    advance st;
    let rhs = parse_assignment st in
    EAssign (e, rhs, l)
  | _ -> e

and parse_logical_or st =
  let rec loop left =
    let saved = st.pos in
    skip_nl st;
    if at_sym st "||" then begin
      let l = loc_of st in advance st; skip_nl st;
      let right = parse_logical_and st in
      loop (EBinOp (Or, left, right, l))
    end else (st.pos <- saved; left)
  in loop (parse_logical_and st)

and parse_logical_and st =
  let rec loop left =
    let saved = st.pos in
    skip_nl st;
    if at_sym st "&&" then begin
      let l = loc_of st in advance st; skip_nl st;
      let right = parse_equality st in
      loop (EBinOp (And, left, right, l))
    end else (st.pos <- saved; left)
  in loop (parse_equality st)

and parse_equality st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "==" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Eq, left, parse_comparison st, l))
    | Symbol "!=" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Neq, left, parse_comparison st, l))
    | _ -> left
  in loop (parse_comparison st)

and parse_comparison st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "<=" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Le, left, parse_bitwise_or st, l))
    | Symbol ">=" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Ge, left, parse_bitwise_or st, l))
    | Symbol "<" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Lt, left, parse_bitwise_or st, l))
    | Symbol ">" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Gt, left, parse_bitwise_or st, l))
    | _ -> left
  in loop (parse_bitwise_or st)

and parse_bitwise_or st =
  let rec loop left =
    let saved = st.pos in
    skip_nl st;
    let t = peek st in
    match t.kind with
    | Symbol "|" ->
      let l = loc_of st in advance st; skip_nl st;
      loop (EBinOp (BitOr, left, parse_bitwise_xor st, l))
    | _ -> st.pos <- saved; left
  in loop (parse_bitwise_xor st)

and parse_bitwise_xor st =
  let rec loop left =
    if at_sym st "^" then begin
      let l = loc_of st in advance st;
      loop (EBinOp (BitXor, left, parse_bitwise_and st, l))
    end else left
  in loop (parse_bitwise_and st)

and parse_bitwise_and st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "&" ->
      let l = loc_of st in advance st;
      loop (EBinOp (BitAnd, left, parse_shift st, l))
    | _ -> left
  in loop (parse_shift st)

and parse_shift st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "<<" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Shl, left, parse_addition st, l))
    | Symbol ">>" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Shr, left, parse_addition st, l))
    | _ -> left
  in loop (parse_addition st)

and parse_addition st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "+" ->
      let l = loc_of st in advance st; skip_nl st;
      loop (EBinOp (Add, left, parse_multiplication st, l))
    | Symbol "++" ->
      let l = loc_of st in advance st; skip_nl st;
      loop (EBinOp (Add, left, parse_multiplication st, l))
    | Symbol "-" ->
      let l = loc_of st in advance st; skip_nl st;
      loop (EBinOp (Sub, left, parse_multiplication st, l))
    | Symbol ".." ->
      let l = loc_of st in advance st;
      let inclusive = at_sym st "=" in
      if inclusive then advance st;
      let right = parse_multiplication st in
      ERange (left, right, inclusive, l)
    | _ -> left
  in loop (parse_multiplication st)

and parse_multiplication st =
  let rec loop left =
    let t = peek st in
    match t.kind with
    | Symbol "*" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Mul, left, parse_unary st, l))
    | Symbol "/" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Div, left, parse_unary st, l))
    | Symbol "%" ->
      let l = loc_of st in advance st;
      loop (EBinOp (Mod, left, parse_unary st, l))
    | _ -> left
  in loop (parse_unary st)

and parse_unary st =
  let t = peek st in
  match t.kind with
  | Symbol "-" ->
    let l = loc_of st in advance st;
    EUnOp (Neg, parse_unary st, l)
  | Symbol "!" ->
    let l = loc_of st in advance st;
    EUnOp (Not, parse_unary st, l)
  | Symbol "&" ->
    let l = loc_of st in advance st;
    let m = at_kw st "mut" in
    if m then advance st;
    if m then EUnOp (AddrMut, parse_unary st, l)
    else EUnOp (AddrOf, parse_unary st, l)
  | Symbol "*" ->
    let l = loc_of st in advance st;
    EUnOp (Deref, parse_unary st, l)
  | Symbol "~" ->
    let l = loc_of st in advance st;
    EUnOp (Not, parse_unary st, l)  (* bitwise NOT *)
  | _ -> parse_postfix st

and parse_postfix st =
  let _is_block_expr = function
    | EWhile _ | EFor _ | ELoop _ | EIf _ | EMatch _ | EBlock _ -> true
    | _ -> false
  in
  let rec loop e =
    (* Skip newlines and check for method chain continuation *)
    let saved_pos = st.pos in
    let had_nl = at_nl st in
    skip_nl st;
    let t = peek st in
    match t.kind with
    | Symbol "." ->
      let l = loc_of st in advance st;
      (* Handle tuple field access: expr.0, expr.1 etc. *)
      let t2 = peek st in
      (match t2.kind with
      | IntLit s ->
        advance st;
        let idx = (try int_of_string s with _ -> 0) in
        loop (EFieldAccess (e, string_of_int idx, l))
      | _ ->
        let field = eat_ident st in
        if at_sym st "(" then begin
          advance st; skip_nl st;
          let args = if at_sym st ")" then [] else parse_arg_list st in
          ignore (eat_sym st ")");
          loop (EMethodCall (e, field, args, l))
        end else
          loop (EFieldAccess (e, field, l))
      )
    | Symbol "::" ->
      let l = loc_of st in advance st;
      if at_sym st "<" then begin
        (* Turbofish: ::<Type>(args) — skip type params, preserve method call *)
        advance st;
        let depth = ref 1 in
        while !depth > 0 && not (at_eof st) do
          if at_sym st "<" then (incr depth; advance st)
          else if at_sym st ">" then (decr depth; advance st)
          else if at_sym st ">>" then (depth := !depth - 2; advance st)
          else advance st
        done;
        if at_sym st "(" then begin
          advance st; skip_nl st;
          let args = if at_sym st ")" then [] else parse_arg_list st in
          ignore (eat_sym st ")");
          (* Extract method name from preceding expression if possible *)
          let method_name = match e with
            | EMethodCall (_, name, _, _) -> name
            | EFieldAccess (_, name, _) -> name
            | EIdent (name, _) -> name
            | _ -> "call"
          in
          loop (ECall (EIdent (method_name, l), args, l))
        end else
          loop e
      end else if at_sym st "[" then begin
        (* Square-bracket turbofish: ::[Type] — skip type params *)
        advance st;
        let depth = ref 1 in
        while !depth > 0 && not (at_eof st) do
          if at_sym st "[" then (incr depth; advance st)
          else if at_sym st "]" then (decr depth; advance st)
          else advance st
        done;
        loop e
      end else begin
      let field = eat_ident st in
      if at_sym st "(" then begin
        advance st; skip_nl st;
        let args = if at_sym st ")" then [] else parse_arg_list st in
        ignore (eat_sym st ")");
        loop (ECall (EFieldAccess (e, field, l), args, l))
      end else if at_sym st "{" then begin
        (* Path::Variant { field: val } *)
        let saved = st.pos in
        advance st; skip_nl st;
        let is_struct = match (peek st).kind with
          | Ident _ ->
            let saved2 = st.pos in
            advance st;
            let r = at_sym st ":" in
            st.pos <- saved2; r
          | Kw s when is_soft_keyword s ->
            let saved2 = st.pos in
            advance st;
            let r = at_sym st ":" in
            st.pos <- saved2; r
          | Symbol "}" -> true
          | _ -> false
        in
        st.pos <- saved;
        if is_struct then begin
          advance st; skip_nl st;
          let fields = ref [] in
          while not (at_sym st "}") && not (at_eof st) do
            skip_nl st;
            if at_sym st "}" then ()
            else begin
              let fname = eat_ident st in
              ignore (eat_sym st ":");
              let fval = parse_expr st in
              fields := (fname, fval) :: !fields;
              if at_sym st "," then (advance st; skip_nl st)
              else skip_nl st
            end
          done;
          ignore (eat_sym st "}");
          let flds = List.rev !fields in
          check_dup_fields st flds;
          loop (EStructLit (field, flds, l))
        end else
          loop (EFieldAccess (e, field, l))
      end else
        loop (EFieldAccess (e, field, l))
      end (* close turbofish begin *)
    | Symbol "(" when not had_nl ->
      (* Don't treat ( as function call across a newline —
         prevents the next line's parenthesised expression from being
         consumed as call arguments. *)
      let l = loc_of st in advance st; skip_nl st;
      let args = if at_sym st ")" then [] else parse_arg_list st in
      ignore (eat_sym st ")");
      loop (ECall (e, args, l))
    | Symbol "[" when not had_nl ->
      (* Same rationale as '(' above *)
      let l = loc_of st in advance st; skip_nl st;
      let idx = parse_expr st in
      ignore (eat_sym st "]");
      loop (EIndex (e, idx, l))
    | Kw "as" ->
      let l = loc_of st in advance st;
      let typ = parse_type st in
      loop (ECast (e, typ, l))
    | Symbol "?" ->
      (* Error propagation: expr? → match expr when Ok(v) then v when Err(e) then return Err(e) end *)
      let l = loc_of st in advance st;
      loop (EMethodCall (e, "unwrap", [], l))  (* simplified for bootstrap *)
    | _ -> st.pos <- saved_pos; e
  in loop (parse_primary st)

and parse_primary st =
  let t = peek st in
  let l = loc_of st in
  match t.kind with
  | IntLit s ->
    advance st;
    let (num_s, ty_suffix) = strip_int_suffix s in
    let v = try Int64.to_int (Int64.of_string num_s) with _ -> (try int_of_string num_s with _ -> 0) in
    let base = EInt (v, l) in
    (match ty_suffix with
     | Some suf -> ECast (base, TyName (suf, []), l)
     | None -> base)
  | FloatLit s ->
    advance st;
    (try EFloat (float_of_string s, l) with _ -> err st "invalid float"; EFloat (0.0, l))
  | StringLit s -> advance st; EStr (s, l)
  | CharLit s -> advance st; EChar (s, l)
  | Kw "true" -> advance st; EBool (true, l)
  | Kw "false" -> advance st; EBool (false, l)
  | Kw "nil" -> advance st; ENil l
  | Kw "self" -> advance st; EIdent ("self", l)
  | Kw "Self" -> advance st; EIdent ("Self", l)
  | Ident "null" -> advance st; ENil l
  | Ident "vec" when (let t2 = if st.pos + 1 < Array.length st.toks then st.toks.(st.pos + 1) else peek st in
                       t2.kind = Symbol "!") ->
    (* vec![...] macro → array literal *)
    advance st; advance st; (* skip 'vec' and '!' *)
    if at_sym st "[" then begin
      advance st; skip_nl st;
      let elts = ref [] in
      if not (at_sym st "]") then begin
        elts := parse_expr st :: !elts;
        while at_sym st "," do
          advance st; skip_nl st;
          if not (at_sym st "]") then
            elts := parse_expr st :: !elts
        done
      end;
      skip_nl st;
      ignore (eat_sym st "]");
      EArray (List.rev !elts, l)
    end else
      EArray ([], l)
  | Kw "unsafe" ->
    advance st;
    (* Skip optional reason string *)
    (match (peek st).kind with StringLit _ -> advance st | _ -> ());
    if at_kw st "do" then begin
      advance st; skip_nl st;
      let body = parse_block_until st ["end"] in
      ignore (eat_kw st "end");
      EBlock (body, l)
    end else
      parse_expr st
  | Kw "return" ->
    advance st;
    if at_nl st || at_eof st || at_kw st "end" then EReturn (None, l)
    else EReturn (Some (parse_expr st), l)
  | Kw "break" ->
    advance st;
    if at_nl st || at_eof st || at_kw st "end" then EBreak (None, l)
    else EBreak (Some (parse_expr st), l)
  | Kw "next" -> advance st; ENext l
  | Kw "if" -> parse_if_expr st
  | Kw "unless" -> parse_unless_expr st
  | Kw "match" -> parse_match_expr st
  | Kw "while" -> parse_while_expr st
  | Kw "until" -> parse_until_expr st
  | Kw "for" -> parse_for_expr st
  | Kw "loop" -> parse_loop_expr st
  | Kw "do" -> parse_block_expr st
  | Symbol "(" ->
    advance st; skip_nl st;
    if at_sym st ")" then (advance st; ETuple ([], l))
    else begin
      let e = parse_expr st in
      if at_sym st "," then begin
        advance st; skip_nl st;
        let rest = ref [e] in
        if not (at_sym st ")") then begin
          rest := parse_expr st :: !rest;
          while at_sym st "," do
            advance st; skip_nl st;
            if not (at_sym st ")") then
              rest := parse_expr st :: !rest
          done
        end;
        ignore (eat_sym st ")");
        ETuple (List.rev !rest, l)
      end else begin
        ignore (eat_sym st ")");
        e
      end
    end
  | Symbol "[" ->
    advance st; skip_nl st;
    let elts = ref [] in
    if not (at_sym st "]") then begin
      elts := parse_expr st :: !elts;
      while at_sym st "," do
        advance st; skip_nl st;
        if not (at_sym st "]") then
          elts := parse_expr st :: !elts
      done
    end;
    skip_nl st;
    ignore (eat_sym st "]");
    EArray (List.rev !elts, l)
  | Symbol "|" ->
    (* Closure: |params| expr or |params| do ... end *)
    advance st;
    let params = ref [] in
    if not (at_sym st "|") then begin
      let parse_cparam () =
        let m = at_kw st "mut" in
        if m then advance st;
        if at_sym st "(" then begin
          (* Tuple destructuring: |(a, b)| → desugar to single param *)
          advance st; skip_nl st;
          let names = ref [eat_ident st] in
          while at_sym st "," do
            advance st; skip_nl st;
            if not (at_sym st ")") then
              names := eat_ident st :: !names
          done;
          ignore (eat_sym st ")");
          let joined = "_destructure_" ^ String.concat "_" (List.rev !names) in
          { cp_name = joined; cp_typ = None; cp_mut = m }
        end else begin
          let name = eat_ident st in
          let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
          { cp_name = name; cp_typ = typ; cp_mut = m }
        end
      in
      params := [parse_cparam ()];
      while at_sym st "," do
        advance st; skip_nl st;
        params := parse_cparam () :: !params
      done
    end;
    ignore (eat_sym st "|");
    let ret = if at_sym st "->" then (advance st; Some (parse_type st)) else None in
    skip_nl st;
    let body =
      if at_kw st "do" then begin
        advance st; skip_nl st;
        let stmts = parse_block_until st ["end"] in
        ignore (eat_kw st "end");
        EBlock (stmts, l)
      end else if at_sym st "{" then begin
        advance st; skip_nl st;
        let stmts = ref [] in
        while not (at_sym st "}") && not (at_eof st) do
          stmts := parse_stmt st :: !stmts;
          while at_sym st ";" do advance st done;
          skip_nl st
        done;
        ignore (eat_sym st "}");
        EBlock (List.rev !stmts, l)
      end else begin
        (* Check for multi-line closure body (implicit block) *)
        let saved = st.pos in
        skip_nl st;
        if at_kw st "let" || at_kw st "mut" || at_kw st "var"
           || at_kw st "if" || at_kw st "for" || at_kw st "while"
           || at_kw st "match" || at_kw st "return" || at_kw st "break"
           || at_kw st "next" || at_kw st "loop" || at_kw st "do"
           || at_kw st "unsafe" || at_kw st "defer" || at_kw st "yield"
           || at_kw st "try" then begin
          st.pos <- saved; skip_nl st;
          let stmts = ref [] in
          while not (at_eof st) && not (at_sym st ")")
                && not (at_sym st "]") && not (at_sym st "}") do
            stmts := parse_stmt st :: !stmts;
            while at_sym st ";" do advance st done;
            skip_nl st
          done;
          EBlock (List.rev !stmts, l)
        end else begin
          st.pos <- saved;
          parse_expr st
        end
      end
    in
    EClosure (List.rev !params, ret, body, l)
  | Symbol "||" ->
    (* Empty-param closure: || expr or || -> T { body } *)
    advance st;
    let ret = if at_sym st "->" then (advance st; Some (parse_type st)) else None in
    skip_nl st;
    let body =
      if at_kw st "do" then begin
        advance st; skip_nl st;
        let stmts = parse_block_until st ["end"] in
        ignore (eat_kw st "end");
        EBlock (stmts, l)
      end else if at_sym st "{" then begin
        advance st; skip_nl st;
        let stmts = ref [] in
        while not (at_sym st "}") && not (at_eof st) do
          stmts := parse_stmt st :: !stmts;
          while at_sym st ";" do advance st done;
          skip_nl st
        done;
        ignore (eat_sym st "}");
        EBlock (List.rev !stmts, l)
      end else begin
        let saved = st.pos in
        skip_nl st;
        if at_kw st "let" || at_kw st "mut" || at_kw st "var" then begin
          st.pos <- saved; skip_nl st;
          let stmts = ref [] in
          while not (at_eof st) && not (at_sym st ")")
                && not (at_sym st "]") && not (at_sym st "}") do
            stmts := parse_stmt st :: !stmts;
            while at_sym st ";" do advance st done;
            skip_nl st
          done;
          EBlock (List.rev !stmts, l)
        end else begin
          st.pos <- saved;
          parse_expr st
        end
      end
    in
    EClosure ([], ret, body, l)
  | Ident name ->
    advance st;
    if at_sym st "{" then begin
      let saved = st.pos in
      advance st; skip_nl st;
      let is_struct = match (peek st).kind with
        | Ident _ ->
          let saved2 = st.pos in
          advance st;
          let r = at_sym st ":" in
          st.pos <- saved2; r
        | Kw s when is_soft_keyword s ->
          let saved2 = st.pos in
          advance st;
          let r = at_sym st ":" in
          st.pos <- saved2; r
        | Symbol "}" -> true
        | _ -> false
      in
      st.pos <- saved;
      if is_struct then begin
        advance st; skip_nl st;
        let fields = ref [] in
        while not (at_sym st "}") && not (at_eof st) do
          skip_nl st;
          if at_sym st "}" then ()
          else begin
            let fname = eat_ident st in
            ignore (eat_sym st ":");
            let fval = ref (parse_expr st) in
            (* Continue multi-line field value expressions starting with binary op on next line *)
            let cont = ref true in
            while !cont do
              let saved_nl = st.pos in
              skip_nl st;
              let continuation_op =
                if at_sym st "+" then Some Add
                else if at_sym st "-" then Some Sub
                else if at_sym st "||" then Some Or
                else if at_sym st "&&" then Some And
                else if at_sym st "|" then Some BitOr
                else if at_sym st "&" then Some BitAnd
                else None
              in
              match continuation_op with
              | Some op ->
                let l2 = loc_of st in advance st; skip_nl st;
                fval := EBinOp (op, !fval, parse_expr st, l2)
              | None ->
                st.pos <- saved_nl;
                cont := false
            done;
            fields := (fname, !fval) :: !fields;
            if at_sym st "," then (advance st; skip_nl st)
            else skip_nl st
          end
        done;
        ignore (eat_sym st "}");
        let flds = List.rev !fields in
        check_dup_fields st flds;
        EStructLit (name, flds, l)
      end else
        EIdent (name, l)
    end else if at_sym st "!" then begin
      (* Macro invocation: name![...] or name!(...) *)
      advance st;
      if at_sym st "[" then begin
        advance st; skip_nl st;
        let elts = ref [] in
        if not (at_sym st "]") then begin
          elts := parse_expr st :: !elts;
          while at_sym st "," do
            advance st; skip_nl st;
            if not (at_sym st "]") then
              elts := parse_expr st :: !elts
          done
        end;
        ignore (eat_sym st "]");
        EArray (List.rev !elts, l)
      end else if at_sym st "(" then begin
        advance st; skip_nl st;
        let args = if at_sym st ")" then [] else parse_arg_list st in
        ignore (eat_sym st ")");
        ECall (EIdent (name, l), args, l)
      end else
        EIdent (name, l)
    end else
      EIdent (name, l)
  | Kw s when is_soft_keyword s ->
    advance st;
    if at_sym st "{" then begin
      let saved = st.pos in
      advance st; skip_nl st;
      let is_struct = match (peek st).kind with
        | Ident _ ->
          let saved2 = st.pos in
          advance st;
          let r = at_sym st ":" in
          st.pos <- saved2; r
        | Kw sk when is_soft_keyword sk ->
          let saved2 = st.pos in
          advance st;
          let r = at_sym st ":" in
          st.pos <- saved2; r
        | Symbol "}" -> true
        | _ -> false
      in
      st.pos <- saved;
      if is_struct then begin
        advance st; skip_nl st;
        let fields = ref [] in
        while not (at_sym st "}") && not (at_eof st) do
          skip_nl st;
          if at_sym st "}" then ()
          else begin
            let fname = eat_ident st in
            ignore (eat_sym st ":");
            let fval = parse_expr st in
            fields := (fname, fval) :: !fields;
            if at_sym st "," then (advance st; skip_nl st)
            else skip_nl st
          end
        done;
        ignore (eat_sym st "}");
        let flds = List.rev !fields in
        check_dup_fields st flds;
        EStructLit (s, flds, l)
      end else
        EIdent (s, l)
    end else
      EIdent (s, l)
  | _ ->
    err st (Printf.sprintf "unexpected token '%s'" t.lexeme);
    advance st;
    EInt (0, l)

and parse_if_expr st =
  let l = loc_of st in
  advance st;
  (* Support 'if let Pat = expr' conditional pattern match *)
  if at_kw st "let" then begin
    advance st;
    let pat = parse_pattern st in
    ignore (eat_sym st "=");
    let scrutinee = parse_expr st in
    if at_kw st "then" then advance st;
    skip_nl st;
    let body = parse_block_until st ["elsif"; "else"; "end"] in
    let else_body =
      if at_kw st "else" then begin
        advance st; skip_nl st;
        Some (parse_block_until st ["end"])
      end else None
    in
    ignore (eat_kw st "end");
    (* Desugar: if let P = e then body else eb end → match e when P then body else eb end *)
    EMatch (scrutinee, [
      { pat; guard = None; arm_body = body };
    ] @ (match else_body with
      | Some eb -> [{ pat = PatWild l; guard = None; arm_body = eb }]
      | None -> []),
    l)
  end else begin
  let cond = parse_expr st in
  if at_kw st "then" then advance st;
  skip_nl st;
  let body = parse_block_until st ["elsif"; "else"; "end"] in
  let branches = ref [{ cond; body }] in
  while at_kw st "elsif" do
    advance st;
    let c = parse_expr st in
    if at_kw st "then" then advance st;
    skip_nl st;
    let b = parse_block_until st ["elsif"; "else"; "end"] in
    branches := { cond = c; body = b } :: !branches
  done;
  let else_body =
    if at_kw st "else" then begin
      advance st; skip_nl st;
      (* Treat 'else if' as 'elsif' — parse chained if as single expression *)
      if at_kw st "if" then
        Some [SExpr (parse_if_expr st)]
      else
        Some (parse_block_until st ["end"])
    end else None
  in
  if else_body = None || (match else_body with Some [SExpr (EIf _)] -> false | _ -> true) then
    ignore (eat_kw st "end");
  EIf (List.rev !branches, else_body, l)
  end (* close the else branch of 'if let' check *)

and parse_match_expr st =
  let l = loc_of st in
  advance st;
  let scrutinee = parse_expr st in
  skip_nl st;
  (* Support brace-delimited match: match expr { Pat => body, ... } *)
  if at_sym st "{" then begin
    advance st; skip_nl st;
    let arms = ref [] in
    while not (at_sym st "}") && not (at_kw st "end") && not (at_eof st) do
      skip_nl st;
      if at_sym st "}" || at_kw st "end" then ()
      else if at_kw st "when" then begin
        (* when Pat then body inside braces *)
        advance st;
        let pat = parse_pattern st in
        let g = if at_kw st "if" then (advance st; Some (parse_expr st)) else None in
        if at_kw st "then" then advance st;
        skip_nl st;
        let body = parse_block_until st ["when"; "else"; "end"] in
        arms := { pat; guard = g; arm_body = body } :: !arms
      end else begin
        let saved_pos = st.pos in
        let pat = parse_pattern st in
        let g = if at_kw st "if" then (advance st; Some (parse_expr st)) else None in
        if at_sym st "=>" then (advance st; skip_nl st;
          let body = [SExpr (parse_expr st)] in
          arms := { pat; guard = g; arm_body = body } :: !arms;
          if at_sym st "," then (advance st; skip_nl st)
          else skip_nl st)
        else if at_kw st "then" then (advance st; skip_nl st;
          let body = [SExpr (parse_expr st)] in
          arms := { pat; guard = g; arm_body = body } :: !arms;
          if at_sym st "," then (advance st; skip_nl st)
          else skip_nl st)
        else begin
          (* Recovery: skip token to avoid infinite loop *)
          st.pos <- saved_pos;
          advance st
        end
      end
    done;
    (* Consume closing — either 'end' then '}' or just '}' *)
    if at_kw st "end" then advance st;
    if at_sym st "}" then advance st
    else ignore (eat_sym st "}");
    EMatch (scrutinee, List.rev !arms, l)
  end else begin
    let arms = ref [] in
    while at_kw st "when" do
      advance st;
      let pat = parse_pattern st in
      let g = if at_kw st "if" then (advance st; Some (parse_expr st)) else None in
      if at_kw st "then" then advance st;
      skip_nl st;
      let body = parse_block_until st ["when"; "else"; "end"] in
      arms := { pat; guard = g; arm_body = body } :: !arms
    done;
    (* Handle 'else' as default arm *)
    if at_kw st "else" then begin
      advance st; skip_nl st;
      let body = parse_block_until st ["end"] in
      arms := { pat = PatWild l; guard = None; arm_body = body } :: !arms
    end;
    ignore (eat_kw st "end");
    EMatch (scrutinee, List.rev !arms, l)
  end

and parse_while_expr st =
  let l = loc_of st in
  advance st;
  let cond = parse_expr st in
  if at_kw st "do" then advance st;
  skip_nl st;
  let body = parse_block_until st ["end"] in
  ignore (eat_kw st "end");
  EWhile (cond, body, l)

and parse_unless_expr st =
  (* Desugar: unless cond then ... else ... end → if !(cond) then ... else ... end *)
  let l = loc_of st in
  advance st;
  let cond = parse_expr st in
  if at_kw st "then" then advance st;
  skip_nl st;
  let body = parse_block_until st ["else"; "end"] in
  let branches = [{ cond = EUnOp (Not, cond, l); body }] in
  let else_body =
    if at_kw st "else" then begin
      advance st; skip_nl st;
      Some (parse_block_until st ["end"])
    end else None
  in
  ignore (eat_kw st "end");
  EIf (branches, else_body, l)

and parse_until_expr st =
  (* Desugar: until cond do ... end → while !(cond) do ... end *)
  let l = loc_of st in
  advance st;
  let cond = parse_expr st in
  if at_kw st "do" then advance st;
  skip_nl st;
  let body = parse_block_until st ["end"] in
  ignore (eat_kw st "end");
  EWhile (EUnOp (Not, cond, l), body, l)

and parse_for_expr st =
  let l = loc_of st in
  advance st;
  (* Support tuple destructuring: for (a, b) in ... and for (a, (b, c)) in ... *)
  let rec read_destr () =
    if at_sym st "(" then begin
      advance st; skip_nl st;
      let parts = ref [read_destr ()] in
      while at_sym st "," do
        advance st; skip_nl st;
        parts := read_destr () :: !parts
      done;
      ignore (eat_sym st ")");
      String.concat "_" (List.rev !parts)
    end else
      eat_ident st
  in
  let var = if at_sym st "(" then begin
    advance st; skip_nl st;
    let names = ref [read_destr ()] in
    while at_sym st "," do
      advance st; skip_nl st;
      names := read_destr () :: !names
    done;
    ignore (eat_sym st ")");
    String.concat "_" (List.rev !names)
  end else
    eat_ident st
  in
  ignore (eat_kw st "in");
  let iter = parse_expr st in
  if at_kw st "do" then advance st;
  skip_nl st;
  let body = parse_block_until st ["end"] in
  ignore (eat_kw st "end");
  EFor (var, iter, body, l)

and parse_loop_expr st =
  let l = loc_of st in
  advance st;
  skip_nl st;
  let body = parse_block_until st ["end"] in
  ignore (eat_kw st "end");
  ELoop (body, l)

and parse_block_expr st =
  let l = loc_of st in
  advance st;
  skip_nl st;
  let body = parse_block_until st ["end"] in
  ignore (eat_kw st "end");
  EBlock (body, l)

and parse_arg_list st =
  let args = ref [parse_expr st] in
  while at_sym st "," do
    advance st; skip_nl st;
    if not (at_sym st ")") && not (at_sym st "]") then
      args := parse_expr st :: !args
  done;
  skip_nl st;
  List.rev !args

and parse_stmt st =
  let l = loc_of st in
  if at_kw st "let" then begin
    advance st;
    let m = at_kw st "mut" in
    if m then advance st;
    (* Support tuple destructuring: let (a, b) = expr *)
    if at_sym st "(" then begin
      advance st; skip_nl st;
      let names = ref [eat_ident st] in
      while at_sym st "," do
        advance st; skip_nl st;
        names := eat_ident st :: !names
      done;
      ignore (eat_sym st ")");
      let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let value = parse_expr st in
      (* Desugar: let (a, b) = expr → let _tup = expr; let a = _tup.0; ... *)
      let name = "_destructure_" ^ (String.concat "," (List.rev !names)) in
      ignore typ;
      SLet { mut = m; name; typ = None; value; loc = l }
    end else begin
      let name = eat_ident st in
      let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let value = parse_expr st in
      SLet { mut = m; name; typ; value; loc = l }
    end
  end else if at_kw st "mut" then begin
    advance st;
    (* Support tuple destructuring: mut (a, b) = expr *)
    if at_sym st "(" then begin
      advance st; skip_nl st;
      let names = ref [eat_ident st] in
      while at_sym st "," do
        advance st; skip_nl st;
        names := eat_ident st :: !names
      done;
      ignore (eat_sym st ")");
      let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let value = parse_expr st in
      let name = "_destructure_" ^ (String.concat "_" (List.rev !names)) in
      ignore typ;
      SLet { mut = true; name; typ = None; value; loc = l }
    end else begin
      let name = eat_ident st in
      let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let value = parse_expr st in
      SLet { mut = true; name; typ; value; loc = l }
    end
  end else if at_kw st "var" then begin
    (* var x = expr → mutable binding, but only if followed by ident + = *)
    let saved = st.pos in
    advance st;
    if at_ident st || (match (peek st).kind with Kw s when is_soft_keyword s -> true | _ -> false) then begin
      let _name = eat_ident st in
      (* Check: is it followed by ':', '=' or newline-then-something? *)
      if at_sym st ":" || at_sym st "=" then begin
        st.pos <- saved; advance st; (* consume 'var' again *)
        let name = eat_ident st in
        let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
        ignore (eat_sym st "=");
        let value = parse_expr st in
        SLet { mut = true; name; typ; value; loc = l }
      end else begin
        (* Not a declaration — treat 'var' as expression *)
        st.pos <- saved;
        SExpr (parse_expr st)
      end
    end else begin
      st.pos <- saved;
      SExpr (parse_expr st)
    end
  end else if at_sym st "@" then begin
    (* Skip annotations in function body context *)
    advance st;
    while not (at_nl st) && not (at_eof st) do advance st done;
    skip_nl st;
    parse_stmt st
  end else if at_kw st "use" then begin
    (* use declaration inside function body - skip it *)
    advance st;
    let depth = ref 0 in
    let cont = ref true in
    while !cont && not (at_eof st) do
      if at_sym st "{" then (incr depth; advance st)
      else if at_sym st "}" then begin
        decr depth; advance st;
        if !depth <= 0 then cont := false
      end
      else if at_nl st then begin
        if !depth > 0 then advance st
        else cont := false
      end
      else advance st
    done;
    SExpr (EInt (0, l))
  end else if at_kw st "extern" then begin
    (* extern def inside function body *)
    advance st;
    if at_kw st "def" then begin
      advance st;
      while not (at_nl st) && not (at_eof st) do advance st done
    end;
    SExpr (EInt (0, l))
  end else if at_kw st "def" then begin
    (* Nested function definition inside function body — desugar to closure *)
    advance st;
    let name = eat_ident st in
    (* Parse params *)
    let params = ref [] in
    if at_sym st "(" then begin
      advance st; skip_nl st;
      while not (at_sym st ")") && not (at_eof st) do
        (* Skip &, &mut, self modifiers *)
        if at_sym st "&" then advance st;
        if at_kw st "mut" then advance st;
        if at_kw st "self" then begin advance st end
        else begin
          let pname = eat_ident st in
          let ptyp = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
          params := { cp_name = pname; cp_typ = ptyp; cp_mut = false } :: !params
        end;
        if at_sym st "," then advance st;
        skip_nl st
      done;
      if at_sym st ")" then advance st
    end;
    let cparams = List.rev !params in
    (* Skip return type *)
    if at_sym st "->" then begin
      advance st; ignore (parse_type st)
    end;
    skip_nl st;
    (* Parse body until 'end' *)
    let body = parse_block_until st ["end"] in
    if at_kw st "end" then advance st;
    SLet { mut = false; name; typ = None;
           value = EClosure (cparams, None, EBlock (body, l), l);
           loc = l }
  end else
    SExpr (parse_expr st)

(* Skip semicolons as statement separators *)

and parse_block_until st terms =
  skip_nl st;
  let stmts = ref [] in
  while not (at_block_end st terms) do
    stmts := parse_stmt st :: !stmts;
    while at_sym st ";" do advance st done;
    skip_nl st
  done;
  List.rev !stmts

(* ── Item (declaration) parsing ────────────────────────────────────── *)

let parse_param st =
  let t = peek st in
  (* Handle &self and &mut self *)
  if (match t.kind with Symbol "&" -> true | _ -> false) then begin
    let saved = st.pos in
    advance st;
    let m = at_kw st "mut" in
    if m then advance st;
    if at_kw st "self" then begin
      advance st;
      { p_name = "self"; p_typ = if m then TyRef (true, TySelf) else TyRef (false, TySelf); p_mut = m; p_default = None }
    end else begin
      st.pos <- saved;
      let m2 = at_kw st "mut" in
      if m2 then advance st;
      let name = eat_ident st in
      ignore (eat_sym st ":");
      let typ = parse_type st in
      let default = if at_sym st "=" then (advance st; Some (parse_expr st)) else None in
      { p_name = name; p_typ = typ; p_mut = m2; p_default = default }
    end
  end else if at_kw st "self" then begin
    advance st;
    (* Handle self: &Self explicit type annotation *)
    if at_sym st ":" then begin
      advance st;
      let typ = parse_type st in
      { p_name = "self"; p_typ = typ; p_mut = false; p_default = None }
    end else
      { p_name = "self"; p_typ = TySelf; p_mut = false; p_default = None }
  end else if at_kw st "mut" then begin
    advance st;
    if at_kw st "self" then begin
      advance st;
      { p_name = "self"; p_typ = TySelf; p_mut = true; p_default = None }
    end else begin
      let name = eat_ident st in
      ignore (eat_sym st ":");
      let typ = parse_type st in
      let default = if at_sym st "=" then (advance st; Some (parse_expr st)) else None in
      { p_name = name; p_typ = typ; p_mut = true; p_default = default }
    end
  end else begin
    let name = eat_ident st in
    ignore (eat_sym st ":");
    let typ = parse_type st in
    let default = if at_sym st "=" then (advance st; Some (parse_expr st)) else None in
    { p_name = name; p_typ = typ; p_mut = false; p_default = default }
  end

let parse_param_list st =
  skip_nl st;
  if at_sym st ")" then []
  else begin
    let ps = ref [parse_param st] in
    while at_sym st "," do
      advance st; skip_nl st;
      if not (at_sym st ")") then
        ps := parse_param st :: !ps
    done;
    skip_nl st;
    List.rev !ps
  end

let parse_fn_def st ~pub =
  let l = loc_of st in
  ignore (eat_kw st "def");
  let name = eat_ident st in
  ignore (eat_sym st "(");
  let params = parse_param_list st in
  ignore (eat_sym st ")");
  (* Skip newlines to handle multi-line signatures *)
  let saved = st.pos in
  skip_nl st;
  let ret = if at_sym st "->" then (advance st; Some (parse_type st))
            else (st.pos <- saved; None) in
  skip_nl st;
  while at_kw st "requires" || at_kw st "effect" || at_kw st "budget"
        || at_kw st "pre" || at_kw st "post" || at_kw st "invariant"
        || at_kw st "guard" do
    advance st;
    while not (at_nl st) && not (at_eof st) && not (at_kw st "end") do advance st done
    ;
    skip_nl st
  done;
  skip_nl st;
  (* Support '= expr' shorthand function body *)
  if at_sym st "=" then begin
    advance st;
    let value = parse_expr st in
    let body = [SExpr (EReturn (Some value, l))] in
    IFn { pub; name; params; ret; body; loc = l }
  end else if at_sym st "{" then begin
    (* Brace-delimited function body: def foo() -> T { ... } *)
    advance st; skip_nl st;
    let stmts = ref [] in
    while not (at_sym st "}") && not (at_eof st) do
      stmts := parse_stmt st :: !stmts;
      while at_sym st ";" do advance st done;
      skip_nl st
    done;
    ignore (eat_sym st "}");
    IFn { pub; name; params; ret; body = List.rev !stmts; loc = l }
  end else begin
    let body = parse_block_until st ["end"] in
    ignore (eat_kw st "end");
    IFn { pub; name; params; ret; body; loc = l }
  end

let parse_struct_def st ~pub =
  let l = loc_of st in
  ignore (eat_kw st "struct");
  let name = eat_ident st in
  if at_sym st "[" then begin
    advance st;
    while not (at_sym st "]") && not (at_eof st) do advance st done;
    if at_sym st "]" then advance st
  end;
  skip_nl st;
  let fields = ref [] in
  while not (at_kw st "end") && not (at_eof st) do
    skip_nl st;
    if at_kw st "end" then ()
    else begin
      let p = at_kw st "pub" in
      if p then advance st;
      let saved_pos = st.pos in
      let fname = eat_ident st in
      ignore (eat_sym st ":");
      let ftyp = parse_type st in
      fields := { fd_name = fname; fd_typ = ftyp; fd_pub = p } :: !fields;
      (* Safety: if nothing was consumed, advance to prevent infinite loop *)
      if st.pos = saved_pos then advance st;
      skip_nl st
    end
  done;
  ignore (eat_kw st "end");
  IStruct { pub; name; fields = List.rev !fields; loc = l }

let parse_enum_def st ~pub =
  let l = loc_of st in
  ignore (eat_kw st "enum");
  let name = eat_ident st in
  if at_sym st "[" then begin
    advance st;
    while not (at_sym st "]") && not (at_eof st) do advance st done;
    if at_sym st "]" then advance st
  end;
  skip_nl st;
  let variants = ref [] in
  while not (at_kw st "end") && not (at_eof st) do
    skip_nl st;
    if at_kw st "end" then ()
    else if not (at_ident st) && not (match (peek st).kind with Kw s when is_soft_keyword s -> true | _ -> false) then
      (* Safety: skip any unexpected token to prevent infinite loop *)
      (advance st; skip_nl st)
    else begin
      let vname = eat_ident st in
      let vfields =
        if at_sym st "(" then begin
          advance st; skip_nl st;
          let ts = if at_sym st ")" then [] else parse_type_list st in
          skip_nl st;
          ignore (eat_sym st ")");
          ts
        end else if at_sym st "{" then begin
          (* Named-field enum variant: Variant { field: Type, ... } *)
          advance st; skip_nl st;
          let fs = ref [] in
          while not (at_sym st "}") && not (at_eof st) do
            skip_nl st;
            if at_sym st "}" then ()
            else begin
              let _fname = eat_ident st in
              if at_sym st ":" then begin
                advance st;
                fs := parse_type st :: !fs
              end;
              if at_sym st "," then (advance st; skip_nl st)
              else skip_nl st
            end
          done;
          ignore (eat_sym st "}");
          List.rev !fs
        end else []
      in
      variants := { vd_name = vname; vd_fields = vfields } :: !variants;
      skip_nl st
    end
  done;
  ignore (eat_kw st "end");
  IEnum { pub; name; variants = List.rev !variants; loc = l }

let parse_trait_def st ~pub =
  let l = loc_of st in
  ignore (eat_kw st "trait");
  let name = eat_ident st in
  (* Skip type params, supertraits, where clauses *)
  while not (at_nl st) && not (at_eof st) && not (at_kw st "end") do advance st done;
  skip_nl st;
  let items = ref [] in
  while not (at_kw st "end") && not (at_eof st) do
    skip_nl st;
    if at_kw st "end" then ()
    else if at_sym st "@" then begin
      advance st;
      while not (at_nl st) && not (at_eof st) do advance st done;
      skip_nl st
    end
    else if at_kw st "pub" || at_kw st "def" then begin
      let is_pub = at_kw st "pub" in
      if is_pub then advance st;
      if at_kw st "def" then begin
        let fl = loc_of st in
        ignore (eat_kw st "def");
        let fname = eat_ident st in
        ignore (eat_sym st "(");
        let params = parse_param_list st in
        ignore (eat_sym st ")");
        let ret = if at_sym st "->" then (advance st; Some (parse_type st)) else None in
        skip_nl st;
        (* Skip contract annotations *)
        while at_kw st "requires" || at_kw st "effect" || at_kw st "budget"
              || at_kw st "pre" || at_kw st "post" || at_kw st "invariant"
              || at_kw st "guard" do
          advance st;
          while not (at_nl st) && not (at_eof st) && not (at_kw st "end") do advance st done;
          skip_nl st
        done;
        skip_nl st;
        (* Detect signature-only vs default implementation *)
        if at_sym st "=" then begin
          advance st;
          let value = parse_expr st in
          items := IFn { pub = is_pub; name = fname; params; ret;
                         body = [SExpr (EReturn (Some value, fl))]; loc = fl } :: !items
        end else if at_sym st "{" then begin
          (* Brace-style method body: def name() -> T { expr } *)
          advance st; skip_nl st;
          let stmts = ref [] in
          while not (at_sym st "}") && not (at_eof st) do
            stmts := parse_stmt st :: !stmts;
            while at_sym st ";" do advance st done;
            skip_nl st
          done;
          ignore (eat_sym st "}");
          items := IFn { pub = is_pub; name = fname; params; ret;
                         body = List.rev !stmts; loc = fl } :: !items
        end else if at_kw st "def" || at_kw st "end" || at_kw st "pub"
                    || at_sym st "@" || at_eof st then
          (* Signature-only method: no body *)
          items := IFn { pub = is_pub; name = fname; params; ret;
                         body = []; loc = fl } :: !items
        else begin
          (* Default implementation with end *)
          let body = parse_block_until st ["end"] in
          ignore (eat_kw st "end");
          items := IFn { pub = is_pub; name = fname; params; ret;
                         body; loc = fl } :: !items
        end
      end else
        (advance st; skip_nl st)
    end
    else if at_kw st "type" then begin
      (* Associated type declaration in trait - skip it *)
      let tl = loc_of st in
      advance st;
      let tname = eat_ident st in
      if at_sym st "=" then begin
        advance st; ignore (parse_type st)
      end;
      items := IConst { name = tname; typ = None; value = ENil tl; loc = tl } :: !items
    end
    else
      (advance st; skip_nl st)
  done;
  ignore (eat_kw st "end");
  ITrait { pub; name; items = List.rev !items; loc = l }

let parse_impl_block st =
  let l = loc_of st in
  ignore (eat_kw st "impl");
  let first_name = eat_ident st in
  let (trait_name, target) =
    if at_kw st "for" then begin
      advance st;
      let tgt = parse_type st in
      (Some first_name, tgt)
    end else
      (None, TyName (first_name, []))
  in
  skip_nl st;
  let methods = ref [] in
  while not (at_kw st "end") && not (at_eof st) do
    skip_nl st;
    if at_kw st "def" then
      methods := parse_fn_def st ~pub:false :: !methods
    else if at_kw st "pub" then begin
      advance st;
      if at_kw st "def" then
        methods := parse_fn_def st ~pub:true :: !methods
      else (advance st; skip_nl st)
    end
    else if at_sym st "@" then begin
      advance st;
      while not (at_nl st) && not (at_eof st) do advance st done;
      skip_nl st
    end
    else if at_kw st "const" then begin
      (* const inside impl block - skip with inline parsing *)
      let cl = loc_of st in
      advance st;
      let cname = eat_ident st in
      let ctyp = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let cval = parse_expr st in
      methods := IConst { name = cname; typ = ctyp; value = cval; loc = cl } :: !methods
    end
    else if at_kw st "type" then begin
      (* type alias inside impl block *)
      let tl = loc_of st in
      advance st;
      let tname = eat_ident st in
      if at_sym st "=" then begin
        advance st;
        let typ = parse_type st in
        methods := ITypeAlias { name = tname; typ; loc = tl } :: !methods
      end else
        methods := IConst { name = tname; typ = None; value = ENil tl; loc = tl } :: !methods
    end
    else if not (at_kw st "end") then
      (advance st; skip_nl st)
  done;
  ignore (eat_kw st "end");
  IImpl { target; trait_ = trait_name; methods = List.rev !methods; loc = l }

let parse_use_decl st =
  let l = loc_of st in
  ignore (eat_kw st "use");
  let path = ref [eat_ident st] in
  while at_sym st "::" do
    advance st;
    if at_ident st then path := eat_ident st :: !path
    else if at_sym st "{" then begin
      while not (at_sym st "}") && not (at_eof st) do advance st done;
      if at_sym st "}" then advance st
    end else if at_sym st "*" then (advance st; path := "*" :: !path)
  done;
  let alias =
    if at_kw st "as" then begin
      advance st;
      if at_ident st then Some (eat_ident st)
      else (err st "expected identifier after 'as'"; None)
    end else None
  in
  IUse { path = List.rev !path; alias; loc = l }

let parse_const_decl st =
  let l = loc_of st in
  ignore (eat_kw st "const");
  let name = eat_ident st in
  let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
  ignore (eat_sym st "=");
  let value = parse_expr st in
  IConst { name; typ; value; loc = l }

let parse_type_alias_decl st =
  let l = loc_of st in
  ignore (eat_kw st "type");
  let name = eat_ident st in
  if Token.is_keyword name && not (Token.is_soft_keyword name) then
    err st (Printf.sprintf "type alias name '%s' shadows a keyword" name);
  ignore (eat_sym st "=");
  let typ = parse_type st in
  ITypeAlias { name; typ; loc = l }

let parse_extern_block st =
  let l = loc_of st in
  ignore (eat_kw st "extern");
  let abi = match (peek st).kind with
    | StringLit s -> advance st; Some s
    | _ -> None
  in
  let sigs = ref [] in
  if at_kw st "def" then begin
    advance st;
    let name = eat_ident st in
    ignore (eat_sym st "(");
    let ps = parse_param_list st in
    ignore (eat_sym st ")");
    let ret = if at_sym st "->" then (advance st; Some (parse_type st)) else None in
    sigs := [{ fs_name = name; fs_params = ps; fs_ret = ret }]
  end else begin
    if at_kw st "do" then advance st;
    skip_nl st;
    while not (at_kw st "end") && not (at_eof st) do
      if at_kw st "def" then begin
        advance st;
        let name = eat_ident st in
        ignore (eat_sym st "(");
        let ps = parse_param_list st in
        ignore (eat_sym st ")");
        let ret = if at_sym st "->" then (advance st; Some (parse_type st)) else None in
        sigs := { fs_name = name; fs_params = ps; fs_ret = ret } :: !sigs;
        skip_nl st
      end else (advance st; skip_nl st)
    done;
    if at_kw st "end" then advance st
  end;
  IExtern { abi; sigs = List.rev !sigs; loc = l }

let rec parse_module_def st ~pub =
  let l = loc_of st in
  if at_kw st "module" then advance st else ignore (eat_kw st "mod");
  let name = eat_ident st in
  (* Consume qualified path: module tg_compiler::foo *)
  while at_sym st "::" do
    advance st;
    if at_ident st then ignore (eat_ident st)
  done;
  (* Check for single-line 'pub mod X' / 'mod X' — no body *)
  let is_single_line =
    at_nl st || at_eof st ||
    (match (peek st).kind with
     | Kw "pub" | Kw "def" | Kw "struct" | Kw "enum" | Kw "trait"
     | Kw "impl" | Kw "use" | Kw "const" | Kw "type" | Kw "mod"
     | Kw "module" | Kw "extern" | Symbol "#" | Symbol "@" -> true
     | _ -> false)
  in
  if is_single_line then begin
    skip_nl st;
    IModule { pub; name; items = []; loc = l }
  end else begin
  skip_nl st;
  if at_kw st "end" || at_eof st then
    IModule { pub; name; items = []; loc = l }
  else begin
    let items = ref [] in
    while not (at_kw st "end") && not (at_eof st) do
      skip_nl st;
      if at_kw st "end" then ()
      else items := parse_one_item st :: !items
    done;
    if at_kw st "end" then (advance st);
    IModule { pub; name; items = List.rev !items; loc = l }
  end
  end (* close is_single_line else *)

and parse_one_item st =
  skip_nl st;
  let t = peek st in
  match t.kind with
  | Kw "pub" ->
    advance st;
    let t2 = peek st in
    (match t2.kind with
     | Kw "def" -> parse_fn_def st ~pub:true
     | Kw "struct" -> parse_struct_def st ~pub:true
     | Kw "enum" -> parse_enum_def st ~pub:true
     | Kw "trait" -> parse_trait_def st ~pub:true
     | Kw "const" -> parse_const_decl st
     | Kw "type" -> parse_type_alias_decl st
     | Kw "use" -> parse_use_decl st
     | Kw "module" | Kw "mod" -> parse_module_def st ~pub:true
     | _ ->
       err st "expected item after 'pub'"; advance st;
       IConst { name = "_"; typ = None;
                value = EInt (0, loc_of st); loc = loc_of st })
  | Kw "def" -> parse_fn_def st ~pub:false
  | Kw "async" ->
    advance st; parse_fn_def st ~pub:false
  | Kw "struct" -> parse_struct_def st ~pub:false
  | Kw "enum" -> parse_enum_def st ~pub:false
  | Kw "trait" -> parse_trait_def st ~pub:false
  | Kw "impl" -> parse_impl_block st
  | Kw "use" -> parse_use_decl st
  | Kw "const" -> parse_const_decl st
  | Kw "type" -> parse_type_alias_decl st
  | Kw "extern" -> parse_extern_block st
  | Kw "module" | Kw "mod" -> parse_module_def st ~pub:false
  | Kw "mut" ->
    (* Module-level mutable variable *)
    let l = loc_of st in
    advance st;
    let name = eat_ident st in
    let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
    ignore (eat_sym st "=");
    let value = parse_expr st in
    IConst { name; typ; value; loc = l }
  | Kw "let" ->
    (* Module-level let binding, with optional tuple destructuring *)
    let l = loc_of st in
    advance st;
    let _m = at_kw st "mut" in
    if _m then advance st;
    if at_sym st "(" then begin
      (* Tuple destructuring: let (a, b) = expr *)
      advance st; skip_nl st;
      let names = ref [eat_ident st] in
      while at_sym st "," do
        advance st; skip_nl st;
        names := eat_ident st :: !names
      done;
      ignore (eat_sym st ")");
      ignore (eat_sym st "=");
      let value = parse_expr st in
      let name = "_destructure_" ^ (String.concat "_" (List.rev !names)) in
      IConst { name; typ = None; value; loc = l }
    end else begin
      let name = eat_ident st in
      let typ = if at_sym st ":" then (advance st; Some (parse_type st)) else None in
      ignore (eat_sym st "=");
      let value = parse_expr st in
      IConst { name; typ; value; loc = l }
    end
  | Kw "macro" ->
    let l = loc_of st in advance st;
    while not (at_kw st "end") && not (at_eof st) do advance st done;
    if at_kw st "end" then advance st;
    IConst { name = "_macro"; typ = None; value = ENil l; loc = l }
  | Kw "edition" ->
    let l = loc_of st in advance st;
    while not (at_nl st) && not (at_eof st) do advance st done;
    IConst { name = "_edition"; typ = None; value = ENil l; loc = l }
  | Kw "cap" ->
    let l = loc_of st in advance st;
    while not (at_kw st "end") && not (at_eof st) do advance st done;
    if at_kw st "end" then advance st;
    IConst { name = "_cap"; typ = None; value = ENil l; loc = l }
  | Kw "effect" ->
    let l = loc_of st in advance st;
    while not (at_kw st "end") && not (at_eof st) do advance st done;
    if at_kw st "end" then advance st;
    IConst { name = "_effect"; typ = None; value = ENil l; loc = l }
  | Kw "rationale" ->
    let l = loc_of st in advance st;
    while not (at_kw st "end") && not (at_eof st) do advance st done;
    if at_kw st "end" then advance st;
    IConst { name = "_rationale"; typ = None; value = ENil l; loc = l }
  | Kw "test" ->
    let l = loc_of st in advance st;
    (* Skip test name string if present *)
    (match (peek st).kind with StringLit _ -> advance st | _ -> ());
    (* Skip to matching 'end' or 'do...end' block *)
    while not (at_kw st "end") && not (at_eof st) do advance st done;
    if at_kw st "end" then advance st;
    IConst { name = "_test"; typ = None; value = ENil l; loc = l }
  | Symbol "@" | Symbol "#" ->
    advance st;
    while not (at_nl st) && not (at_eof st) do advance st done;
    skip_nl st;
    parse_one_item st
  | Kw "end" ->
    (* Orphan 'end' at top level — skip silently (e.g. module-closing end) *)
    let l = loc_of st in
    advance st; skip_nl st;
    IConst { name = "_end"; typ = None; value = ENil l; loc = l }
  | _ ->
    err st (Printf.sprintf "unexpected token '%s' at top level" t.lexeme);
    advance st; skip_nl st;
    IConst { name = "_err"; typ = None;
             value = EInt (0, loc_of st); loc = loc_of st }

(* ── Program parsing ───────────────────────────────────────────────── *)

let parse_program_items st =
  let items = ref [] in
  skip_nl st;
  while not (at_eof st) do
    items := parse_one_item st :: !items;
    skip_nl st
  done;
  { items = List.rev !items }

(* ── Public API ────────────────────────────────────────────────────── *)

let parse ~file (tokens : Token.t list) : parse_result =
  let st = mk ~file tokens in
  let program = parse_program_items st in
  { program; parse_diags = List.rev st.diags }

(* Backward-compat structural parse *)

type stack_item = { name : string; line : int; col : int }

let parse_structural ~file (tokens : Token.t list) : result =
  let delims : stack_item list ref = ref [] in
  let diags = ref [] in

  let push_delim s line col = delims := { name = s; line; col } :: !delims in
  let expected_close = function
    | "(" -> ")"
    | "[" -> "]"
    | "{" -> "}"
    | _ -> ""
  in
  let pop_delim (close_tok : Token.t) =
    match !delims with
    | top :: tl when expected_close top.name = close_tok.lexeme -> delims := tl
    | top :: _ ->
        diags :=
          Diagnostics.make ~code:"E121" ~file ~line:close_tok.line ~col:close_tok.col
            (Printf.sprintf "mismatched delimiter: expected '%s' before '%s'" (expected_close top.name) close_tok.lexeme)
          :: !diags
    | [] ->
        diags := Diagnostics.make ~code:"E121" ~file ~line:close_tok.line ~col:close_tok.col "unexpected closing delimiter" :: !diags
  in

  let rec walk toks =
    match toks with
    | [] -> ()
    | tok :: rest ->
        (match tok.kind with
         | Symbol "(" | Symbol "[" | Symbol "{" -> push_delim tok.lexeme tok.line tok.col
         | Symbol ")" | Symbol "]" | Symbol "}" -> pop_delim tok
         | _ -> ());
          walk rest
  in

        walk tokens;

  List.iter
    (fun d ->
      diags := Diagnostics.make ~code:"E121" ~file ~line:d.line ~col:d.col
          (Printf.sprintf "unclosed delimiter '%s'" d.name)
        :: !diags)
    !delims;

  let diagnostics = List.rev !diags in
  { ok = Diagnostics.count_errors diagnostics = 0; diagnostics }
