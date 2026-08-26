(* parser.ml — Recursive-descent parser for the Tangerine language,
   conformant to docs/current/grammar.md v2.0.0 (Edition 2026).

   Diagnostics:
   - E100/E106: legacy parameter spellings / safe-reference type positions
     (hard errors per grammar.md §2.3/§3 — the Swift stage0 treated E106 as
     a warning; the grammar is the spec here).
   - E1100: expected-token parse errors. *)

type parser = {
  tokens : Token.t array;
  source : string;
  source_obj : Source.source;
  file_id : int;
  diags : Diagnostic.bag;
  mutable pos : int;
  mutable prev_end : int;
  mutable inline_module_path : string list;
  mutable extern_abi_context : bool;
  mutable match_arm_cols : int list;
  mutable type_arg_depth : int;
}

let make tokens source file_id diags =
  {
    tokens;
    source;
    source_obj = Source.of_bytes ~name:"<parser>" ~bytes:source;
    file_id;
    diags;
    pos = 0;
    prev_end = 0;
    inline_module_path = [];
    extern_abi_context = false;
    match_arm_cols = [];
    type_arg_depth = 0;
  }

(* Module identity is provided by the manifest loader, never derived from
   OS paths (audit §11). This helper remains only for standalone/adhoc
   parsing of a single file with a logical path derived from the argument;
   the bootstrap pipeline passes explicit logical paths. *)
let module_path_of_file (path : string) : string list =
  String.split_on_char '/' path
  |> List.map (fun seg ->
         if Util.has_suffix seg ".tg" then
           String.sub seg 0 (String.length seg - 3)
         else seg)
  |> List.filter (fun s -> s <> "")

let peek (p : parser) : Token.t =
  if p.pos < Array.length p.tokens then p.tokens.(p.pos)
  else Token.make Token.Eof Span.synthetic

let peek_at (p : parser) (n : int) : Token.t =
  if p.pos + n < Array.length p.tokens then p.tokens.(p.pos + n)
  else Token.make Token.Eof Span.synthetic

let kind (p : parser) : Token.kind = (peek p).Token.kind

let kind_at (p : parser) (n : int) : Token.kind = (peek_at p n).Token.kind

let advance (p : parser) : Token.t =
  let t = peek p in
  if p.pos < Array.length p.tokens then p.pos <- p.pos + 1;
  p.prev_end <- t.Token.span.Span.end_;
  t

let at p k = kind p = k

let at_ident (p : parser) =
  match kind p with Token.Ident _ -> true | _ -> false

let at_ident_str p s = kind p = Token.Ident s

let eat p k =
  if at p k then begin
    ignore (advance p);
    true
  end
  else false

let cur_span (p : parser) : Span.span = (peek p).Token.span

let err p code msg span =
  Diagnostic.error p.diags code msg span

let expected p what =
  let got = Token.display_name (kind p) in
  err p "E1100" (Printf.sprintf "expected %s, found %s" what got) (cur_span p)

(* Span from a start span to the last consumed token's end. *)
let span_end (p : parser) (start : Span.span) : Span.span =
  Span.make start.Span.start p.prev_end p.file_id

(* The parser is single-file: every span shares one file id, so merges
   cannot cross files and the total merge is safe. *)
let span_merged (p : parser) a b = ignore p; Span.merge_exn (Span.merged a b)

let src_text (p : parser) (s : Span.span) =
  if s.Span.file_id <> p.file_id || s.Span.start < 0 || s.Span.end_ > String.length p.source
  then ""
  else String.sub p.source s.Span.start (s.Span.end_ - s.Span.start)

(* Newline between two token spans in the source (lenient array-element
   separation, mirroring the reference parser). *)
let source_has_newline (p : parser) (a : Span.span) (b : Span.span) : bool =
  if a.Span.file_id <> b.Span.file_id || a.Span.file_id <> p.file_id then false
  else begin
    let s = max 0 a.Span.end_ in
    let e = min (String.length p.source) b.Span.start in
    let rec has i = i < e && (p.source.[i] = '\n' || has (i + 1)) in
    has s
  end

(* ────────────────────────────────────────────────────────────────
   Soft keywords usable as identifiers. *)
let soft_ident_kind = function
  | Token.Ident i -> Some i.Token.spelling
  | Token.KwBudget -> Some "budget"
  | Token.KwDef -> Some "def"
  | Token.KwExtern -> Some "extern"
  | Token.KwFinally -> Some "finally"
  | Token.KwLoop -> Some "loop"
  | Token.KwSelfValue -> Some "self"
  | Token.KwNext -> Some "next"
  | Token.KwModule -> Some "module"
  | Token.KwMod -> Some "mod"
  | Token.KwType -> Some "type"
  | Token.KwTypealias -> Some "typealias"
  | Token.KwCap -> Some "cap"
  | Token.KwConst -> Some "const"
  | Token.KwEffect -> Some "effect"
  | Token.KwEdition -> Some "edition"
  | Token.KwGuard -> Some "guard"
  | Token.KwDefer -> Some "defer"
  | Token.KwHandle -> Some "handle"
  | Token.KwImplies -> Some "implies"
  | Token.KwInline -> Some "inline"
  | Token.KwMut -> Some "mut"
  | Token.KwAsync -> Some "async"
  | Token.KwEnd -> Some "end"
  | Token.KwDo -> Some "do"
  | Token.KwPre -> Some "pre"
  | Token.KwPost -> Some "post"
  | Token.KwPub -> Some "pub"
  | Token.KwInout -> Some "inout"
  | Token.KwSink -> Some "sink"
  | Token.KwSet -> Some "set"
  | Token.KwResource -> Some "resource"
  | Token.KwDeinit -> Some "deinit"
  | Token.KwReturn -> Some "return"
  | Token.KwBreak -> Some "break"
  | Token.KwMatch -> Some "match"
  | Token.KwWhen -> Some "when"
  | Token.KwStruct -> Some "struct"
  | Token.KwEnum -> Some "enum"
  | Token.KwTrait -> Some "trait"
  | Token.KwImpl -> Some "impl"
  | Token.KwUse -> Some "use"
  | Token.KwStatic -> Some "static"
  | Token.KwWhere -> Some "where"
  | Token.KwAs -> Some "as"
  | Token.KwSuper -> Some "super"
  | Token.KwCrate -> Some "crate"
  | Token.KwSelfTy -> Some "Self"
  | Token.KwFn -> Some "fn"
  | Token.KwTrue -> Some "true"
  | Token.KwFalse -> Some "false"
  | Token.KwUnsafe -> Some "unsafe"
  | Token.KwAwait -> Some "await"
  | Token.KwRequires -> Some "requires"
  | Token.KwWith -> Some "with"
  | Token.KwRationale -> Some "rationale"
  | Token.KwInvariant -> Some "invariant"
  | Token.KwTry -> Some "try"
  | Token.KwCatch -> Some "catch"
  | Token.KwMacro -> Some "macro"
  | Token.KwComptime -> Some "comptime"
  | Token.KwPure -> Some "pure"
  | Token.KwUnless -> Some "unless"
  | Token.KwUntil -> Some "until"
  | Token.KwTest -> Some "test"
  | Token.KwDyn -> Some "dyn"
  | Token.KwIn -> Some "in"
  | Token.KwIf -> Some "if"
  | Token.KwThen -> Some "then"
  | Token.KwElse -> Some "else"
  | Token.KwElsif -> Some "elsif"
  | Token.KwWhile -> Some "while"
  | Token.KwFor -> Some "for"
  | Token.KwLet -> Some "let"
  | _ -> None

let expect_ident (p : parser) : string =
  match soft_ident_kind (kind p) with
  | Some s ->
      ignore (advance p);
      s
  | None ->
      expected p "identifier";
      ignore (advance p);
      ""

let expect p k what =
  if at p k then ignore (advance p)
  else expected p what

let eat_optional_semi (p : parser) = eat p Token.Semi

let at_eof p = at p Token.Eof

(* Single position authority: line/column via Source.position
   (LF/CR/CRLF semantics, precomputed line starts). *)
let line_of (p : parser) (offset : int) : int =
  fst (Source.position p.source_obj offset)

let column_of (p : parser) (offset : int) : int =
  snd (Source.position p.source_obj offset)

(* `end` as a block terminator vs an identifier use: when followed (on the
   SAME line) by identifier-continuation tokens (=, +=, (, ., ::, :, [, ?),
   `end` is a field/name; otherwise it terminates the enclosing block. *)
let at_kw_end_as_terminator (p : parser) : bool =
  if not (at p Token.KwEnd) then false
  else begin
    match kind_at p 1 with
    | Token.Eq | Token.PlusEq | Token.MinusEq | Token.StarEq | Token.SlashEq
    | Token.PercentEq | Token.CaretEq | Token.AmpEq | Token.PipeEq | Token.ShlEq
    | Token.ShrEq | Token.LParen | Token.Dot | Token.ColonColon | Token.Colon
    | Token.LBracket | Token.Question ->
        source_has_newline p (cur_span p) (peek_at p 1).Token.span
    | _ -> true
  end

let is_uppercase_initial (s : string) =
  if String.length s = 0 then false
  else
    let c = s.[0] in
    c >= 'A' && c <= 'Z' 

(* ────────────────────────────────────────────────────────────────
   Mutual recursion spine. *)
let rec parse_program (p : parser) (program_module_path : string list) : Ast.program =
  (* top-level items belong to the program's module; nested `module`
     blocks extend this path *)
  p.inline_module_path <- program_module_path;
  let items = ref [] in
  let start = cur_span p in
  while not (at_eof p) do
    (match parse_item p with
     | Some item -> items := item :: !items
     | None -> ignore (advance p));
    ignore (eat_optional_semi p)
  done;
  {
    Ast.items = List.rev !items;
    prog_span = span_end p start;
    prog_module_path = program_module_path;
  }

and item_of p attrs vis kind start =
  let (_, is_pub) = vis in
  ignore is_pub;
  {
    Ast.kind;
    attributes = attrs;
    span = span_end p start;
    module_path = p.inline_module_path;
  }

and parse_vis (p : parser) : (unit * bool) =
  match kind p with
  | Token.KwPub -> ignore (advance p); ((), true)
  | _ -> ((), false)

and parse_attributes (p : parser) : Ast.attribute list =
  let attrs = ref [] in
  while at p Token.At do
    let start = cur_span p in
    ignore (advance p);
    let name = expect_ident p in
    let args = ref [] in
    if eat p Token.LParen then begin
      while not (at p Token.RParen) && not (at_eof p) do
        (match kind p with
         | Token.Ident i ->
             ignore (advance p);
             let s = i.Token.spelling in
             if at p Token.Eq then begin
               ignore (advance p);
               let v =
                 match kind p with
                 | Token.Ident i2 -> ignore (advance p); i2.Token.spelling
                 | Token.String s2 -> ignore (advance p); s2
                 | Token.Integer s2 -> ignore (advance p); s2
                 | _ -> ""
               in
               args := Ast.AttrKeyValue (s, v) :: !args
             end
             else if at p Token.LParen then begin
               ignore (advance p);
               let inner = ref [] in
               while not (at p Token.RParen) && not (at_eof p) do
                 (match kind p with
                  | Token.Ident si -> ignore (advance p); inner := Ast.AttrIdent si.Token.spelling :: !inner
                  | Token.String si -> ignore (advance p); inner := Ast.AttrString si :: !inner
                  | Token.Integer si -> ignore (advance p); inner := Ast.AttrInt si :: !inner
                  | _ -> ignore (advance p));
                 ignore (eat p Token.Comma)
               done;
               expect p Token.RParen "')' in attribute arguments";
               args := Ast.AttrNested (s, List.rev !inner) :: !args
             end
             else args := Ast.AttrIdent s :: !args
         | Token.String s ->
             ignore (advance p);
             args := Ast.AttrString s :: !args
         | Token.Integer s ->
             ignore (advance p);
             args := Ast.AttrInt s :: !args
         | _ -> ignore (advance p));
        ignore (eat p Token.Comma)
      done;
      expect p Token.RParen "')' in attribute arguments"
    end;
    attrs :=
      { Ast.a_name = name; a_args = List.rev !args; a_span = span_end p start }
      :: !attrs
  done;
  List.rev !attrs

and parse_function (p : parser) (_attrs : Ast.attribute list) (_vis : unit * bool) (is_pub : bool) :
    Ast.item_kind option =
  let is_async = eat p Token.KwAsync in
  let is_unsafe = eat p Token.KwUnsafe in
  let is_pure = eat p Token.KwPure in
  let is_inline = eat p Token.KwInline in
  if not (at p Token.KwDef || at p Token.KwFn) then None
  else begin
    ignore (advance p);
    let (name, type_params) = parse_function_name_and_type_params p in
    let params = parse_param_list p in
    let ret = parse_optional_return_type p in
    let where_clause = parse_optional_where_clause p in
    consume_trailing_receiver_convention p params;
    let sig_start = cur_span p in
    let s =
      {
        Ast.sig_name = name;
        sig_public = is_pub;
        sig_async = is_async;
        sig_unsafe = is_unsafe;
        sig_const = false;
        sig_pure = is_pure;
        sig_inline = is_inline;
        sig_extern = false;
        sig_type_params = type_params;
        sig_params = params;
        sig_return = ret;
        sig_where = where_clause;
        sig_span = sig_start;
      }
    in
    if signature_only_next p then begin
      Some
        (Ast.Function
           {
             Ast.fn_sig = s;
             fn_clauses = [];
             fn_body = Ast.FnSignatureOnly;
             fn_span = span_merged p sig_start (cur_span p);
           })
    end
    else begin
      let clauses = parse_fn_clauses p in
      let body = parse_function_body p in
      Some
        (Ast.Function
           {
             Ast.fn_sig = s;
             fn_clauses = clauses;
             fn_body = body;
             fn_span = span_merged p sig_start (cur_span p);
           })
    end
  end

(* Signature-only decision: after the signature, `def`/`fn`/`type`/`@`/
   `end`/EOF mean no body (trait method signatures, impl-item boundaries). *)
and signature_only_next (p : parser) : bool =
  match kind p with
  | Token.KwDef | Token.KwFn | Token.KwType | Token.KwTypealias | Token.At
  | Token.Eof ->
      true
  | _ -> at_kw_end_as_terminator p

and parse_function_name_and_type_params (p : parser) : string * Ast.type_param list =
  let name = ref (expect_ident p) in
  while eat p Token.ColonColon do
    name := !name ^ "::" ^ expect_ident p
  done;
  let tps = parse_optional_type_params p in
  (!name, tps)

(* A bound name, optionally with type arguments (e.g. `Iterator[T]`). *)
and parse_bound_name (p : parser) : string =
  let name = expect_ident p in
  if at p Token.LBracket || at p Token.Lt then ignore (parse_optional_type_args p);
  name

and parse_optional_type_params (p : parser) : Ast.type_param list =
  if not (at p Token.LBracket) && not (at p Token.Lt) then []
  else begin
    let close = if at p Token.LBracket then Token.RBracket else Token.Gt in
    let alt_close = if close = Token.RBracket then Token.Gt else Token.RBracket in
    ignore (advance p);
    let tps = ref [] in
    while not (at p close) && not (at p alt_close) && not (at_eof p) do
      let start = cur_span p in
      let name = expect_ident p in
      let bounds = ref [] in
      if eat p Token.Colon then begin
        bounds := [ parse_bound_name p ];
        while eat p Token.Plus do
          bounds := parse_bound_name p :: !bounds
        done;
        bounds := List.rev !bounds
      end;
      let default = ref None in
      if eat p Token.Eq then default := Some (parse_type p);
      tps :=
        { Ast.tp_name = name; tp_bounds = !bounds; tp_span = span_end p start }
        :: !tps;
      if not (at p close) && not (at p alt_close) then ignore (eat p Token.Comma)
    done;
    if at p close then ignore (advance p)
    else if at p alt_close then ignore (advance p)
    else expected p (if close = Token.RBracket then "']' in type parameters" else "'>' in type parameters");
    List.rev !tps
  end

and parse_param_list (p : parser) : Ast.param list =
  expect p Token.LParen "'(' in parameter list";
  let params = ref [] in
  while not (at p Token.RParen) && not (at_eof p) do
    params := parse_param p :: !params;
    if not (eat p Token.Comma) then ()
  done;
  expect p Token.RParen "')' in parameter list";
  List.rev !params

(* Parameter conventions: [inout|sink|set] name [: type] [= default].
   Legacy spellings (mut/&/&mut/move/own prefixes and &T/&mut T markers,
   &self / &mut self receivers) are rejected with E100 and recovered. *)
and parse_param (p : parser) : Ast.param =
  let start = cur_span p in
  let convention = ref Ast.LetAccess in
  let prefix () =
    match kind p with
    | Token.KwInout ->
        ignore (advance p);
        convention := Ast.InoutAccess
    | Token.KwSink ->
        ignore (advance p);
        convention := Ast.Sink
    | Token.KwSet ->
        ignore (advance p);
        convention := Ast.Set
    | Token.KwMut ->
        err p "E100"
          "legacy parameter spelling 'mut' is removed; use the explicit access convention 'inout'"
          (cur_span p);
        ignore (advance p);
        convention := Ast.InoutAccess
    | Token.Amp ->
        let amp_span = cur_span p in
        ignore (advance p);
        if at p Token.KwMut then begin
          ignore (advance p);
          err p "E100"
            "legacy parameter spelling '&mut' is removed; use the explicit access convention 'inout'"
            amp_span;
          convention := Ast.InoutAccess
        end
        else begin
          err p "E100"
            "legacy parameter spelling '&' is removed; use the default 'let' convention" amp_span
        end
    | Token.Ident i when i.Token.spelling = "move" || i.Token.spelling = "own" ->
        err p "E100"
          "legacy parameter spelling 'move'/'own' is removed; use the explicit access convention 'sink'"
          (cur_span p);
        ignore (advance p);
        convention := Ast.Sink
    | _ -> ()
  in
  prefix ();
  let name = expect_ident p in
  let self_implicit =
    name = "self" && (at p Token.Comma || at p Token.RParen || at p Token.Eq)
  in
  let ty =
    if self_implicit then Ast.SelfType start
    else if at p Token.Colon then begin
      ignore (advance p);
      match kind p with
      | Token.Amp when not p.extern_abi_context ->
          let amp_span = cur_span p in
          ignore (advance p);
          let _mut = eat p Token.KwMut in
          err p "E100"
            (if _mut then
               "legacy parameter type marker '&mut T' is removed; use the explicit access convention 'inout'"
             else "legacy parameter type marker '&T' is removed; use the default 'let' convention")
            amp_span;
          parse_type p
      | _ -> parse_type p
    end
    else Ast.SelfType start
  in
  let default = if eat p Token.Eq then Some (parse_expr p) else None in
  {
    Ast.p_name = name;
    p_convention = !convention;
    p_type = ty;
    p_default = default;
    p_span = span_end p start;
  }

and consume_trailing_receiver_convention (p : parser) (params : Ast.param list) =
  ignore params;
  ignore (eat p Token.KwInout)

and parse_optional_return_type (p : parser) : Ast.type_expr option =
  if eat p Token.Arrow then Some (parse_type p) else None

and parse_optional_where_clause (p : parser) : Ast.where_predicate list =
  if not (eat p Token.KwWhere) then []
  else begin
    let preds = ref [] in
    while not (at_eof p) && not (at p Token.KwInout)
          && not (at p Token.KwPre) && not (at p Token.KwPost)
          && not (at p Token.KwInvariant) && not (at p Token.KwRequires)
          && not (at p Token.KwEffect) && not (at p Token.KwBudget)
          && not (at p Token.KwEnd) && not (at p Token.Eq) do
      let start = cur_span p in
      let ty = parse_type p in
      if eat p Token.Colon then begin
        let bounds = ref [ expect_ident p ] in
        while eat p Token.Plus do
          bounds := expect_ident p :: !bounds
        done;
        preds :=
          { Ast.wp_type = ty; wp_bounds = List.rev !bounds; wp_span = span_end p start }
          :: !preds
      end
      else preds := { Ast.wp_type = ty; wp_bounds = []; wp_span = span_end p start } :: !preds;
      if not (eat p Token.Comma) then ()
    done;
    List.rev !preds
  end

and parse_fn_clauses (p : parser) : Ast.function_clause list =
  let clauses = ref [] in
  let rec loop () =
    let start = cur_span p in
    match kind p with
    | Token.KwPre | Token.KwPost | Token.KwInvariant ->
        let k =
          if at p Token.KwPre then Ast.CPre
          else if at p Token.KwPost then Ast.CPost
          else Ast.CInvariant
        in
        ignore (advance p);
        let cond = parse_expr p in
        let msg =
          if eat p Token.Comma then
            match kind p with
            | Token.String s -> ignore (advance p); Some s
            | _ -> None
          else None
        in
        clauses :=
          Ast.Contract { Ast.con_kind = k; con_condition = cond; con_message = msg; con_span = span_end p start }
          :: !clauses;
        loop ()
    | Token.KwRequires ->
        ignore (advance p);
        let caps = ref [] in
        caps := (expect_ident p, false) :: !caps;
        while eat p Token.Comma do
          caps := (expect_ident p, false) :: !caps
        done;
        clauses :=
          Ast.Requires { Ast.req_capabilities = List.rev !caps; req_span = span_end p start }
          :: !clauses;
        loop ()
    | Token.KwEffect ->
        ignore (advance p);
        let name = expect_ident p in
        let targs = ref [] in
        while eat p Token.Comma do
          targs := parse_type p :: !targs
        done;
        clauses :=
          Ast.Effect { Ast.eff_name = name; eff_type_args = List.rev !targs; eff_span = span_end p start }
          :: !clauses;
        loop ()
    | Token.KwBudget ->
        ignore (advance p);
        let entries = ref [] in
        let parse_entry () =
          let metric = expect_ident p in
          expect p Token.Colon "':' in budget clause";
          let amount =
            match kind p with
            | Token.String s -> ignore (advance p); s
            | _ -> ""
          in
          entries := (metric, amount) :: !entries
        in
        parse_entry ();
        while eat p Token.Comma do
          parse_entry ()
        done;
        clauses :=
          Ast.Budget { Ast.bud_entries = List.rev !entries; bud_span = span_end p start }
          :: !clauses;
        loop ()
    | _ -> ()
  in
  loop ();
  List.rev !clauses

and parse_function_body (p : parser) : Ast.function_body =
  if eat p Token.Eq then Ast.FnExpr (parse_expr p)
  else if at_kw_end_as_terminator p then begin
    ignore (advance p);
    Ast.FnSignatureOnly
  end
  else if at p Token.LBrace then begin
    ignore (advance p);
    let body = parse_block_body p [ Token.RBrace ] in
    expect p Token.RBrace "'}' in function body";
    Ast.FnBlock body
  end
  else begin
    let body = parse_block_body p [ Token.KwEnd ] in
    expect p Token.KwEnd "'end' in function body";
    Ast.FnBlock body
  end

and parse_block_body (p : parser) (terminators : Token.kind list) : Ast.block_body =
  let start = cur_span p in
  let stmts = ref [] in
  let tail = ref None in
  let is_term k =
    if k = Token.KwEnd then at_kw_end_as_terminator p
    else List.exists (fun t -> t = k) terminators
  in
  let continue_ = ref true in
  while !continue_ do
    if at_eof p then continue_ := false
    else if is_term (kind p) then continue_ := false
    else if at p Token.Semi then ignore (advance p)
    else begin
      let s = parse_stmt p terminators in
      if is_term (kind p) && !tail = None then begin
        match s with
        | Ast.ExprStmt (e, _) -> tail := Some e
        | _ -> stmts := s :: !stmts
      end
      else stmts := s :: !stmts
    end
  done;
  { Ast.b_stmts = List.rev !stmts; b_tail = !tail; b_span = span_merged p start (cur_span p) }

and parse_stmt (p : parser) (_terminators : Token.kind list) : Ast.stmt =
  let start = cur_span p in
  match kind p with
  | Token.KwLet ->
      ignore (advance p);
      let mutable_ = eat p Token.KwMut in
      let pat = parse_pattern p in
      let ty = if eat p Token.Colon then Some (parse_type p) else None in
      expect p Token.Eq "'=' in let binding";
      let value = parse_expr p in
      Ast.LetBinding (pat, mutable_, ty, value, span_end p start)
  | Token.KwMut ->
      ignore (advance p);
      let name = expect_ident p in
      let ty = if eat p Token.Colon then Some (parse_type p) else None in
      expect p Token.Eq "'=' in var binding";
      let value = parse_expr p in
      Ast.LetBinding (Ast.PatIdent (name, true, start), true, ty, value, span_end p start)
  | Token.KwUse | Token.KwDef | Token.KwFn | Token.KwStruct | Token.KwResource
  | Token.KwEnum | Token.KwImpl | Token.KwConst | Token.KwStatic | Token.KwPub ->
      (match parse_item p with
       | Some item -> Ast.Item item
       | None ->
           err p "E1100" "expected item" (cur_span p);
           ignore (advance p);
           Ast.ExprStmt (Ast.Name ("", start), start))
  | Token.At ->
      let attrs = parse_attributes p in
      (match parse_item_with_attrs p attrs with
       | Some item -> Ast.Item item
       | None -> Ast.AttributeStmt (attrs, span_end p start))
  | Token.KwDefer ->
      ignore (advance p);
      let body = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in defer statement";
      Ast.DeferStmt (body, span_end p start)
  | Token.KwNext ->
      (* the Swift seed's statement-boundary rule: `next` followed by a
         value-position token is the contextual identifier "next"
         (`next = ...`, `next - 1`, `foo(next)`, `next.field`); a bare
         `next` at a statement boundary is the loop continue *)
      (match kind_at p 1 with
       | Token.Dot | Token.ColonColon | Token.LParen | Token.Eq
       | Token.PlusEq | Token.MinusEq | Token.StarEq | Token.SlashEq
       | Token.PercentEq | Token.CaretEq | Token.AmpEq | Token.PipeEq
       | Token.ShlEq | Token.ShrEq | Token.Minus | Token.Plus | Token.Star
       | Token.Slash | Token.Percent | Token.Tilde | Token.Lt | Token.LtEq
       | Token.Gt | Token.GtEq | Token.EqEq | Token.BangEq | Token.AmpAmp
       | Token.PipePipe | Token.Amp | Token.Pipe | Token.Caret | Token.Shl
       | Token.Shr | Token.RParen | Token.RBracket | Token.Comma
       | Token.Colon | Token.Question | Token.Arrow | Token.DotDot
       | Token.DotDotEq | Token.KwAs ->
           parse_expr_stmt p start
       | _ ->
           ignore (advance p);
           Ast.ExprStmt (Ast.NextExpr (span_end p start), span_end p start))
  | _ -> parse_expr_stmt p start

and parse_expr_stmt (p : parser) (start : Span.span) : Ast.stmt =
  let e = parse_expr p in
  let k = kind p in
  match k with
  | Token.Eq ->
      ignore (advance p);
      let v = parse_expr p in
      Ast.ExprStmt (Ast.Assign (e, v, span_end p start), span_end p start)
  | Token.PlusEq | Token.MinusEq | Token.StarEq | Token.SlashEq | Token.PercentEq ->
      let op =
        match k with
        | Token.PlusEq -> Ast.Add
        | Token.MinusEq -> Ast.Sub
        | Token.StarEq -> Ast.Mul
        | Token.SlashEq -> Ast.Div
        | _ -> Ast.Mod
      in
      ignore (advance p);
      let v = parse_expr p in
      Ast.ExprStmt
        (Ast.CompoundAssign (e, op, v, span_end p start),
         span_end p start)
  | _ -> Ast.ExprStmt (e, span_end p start)

(* ────────────────────────────────────────────────────────────────
   Types *)

and parse_type (p : parser) : Ast.type_expr =
  let t = parse_type_primary p in
  if eat p Token.Question then Ast.Option (t, Ast.type_span t)
  else t

and parse_type_primary (p : parser) : Ast.type_expr =
  let start = cur_span p in
  match kind p with
  | Token.KwFn | Token.KwDef ->
      ignore (advance p);
      parse_fn_type p start
  | Token.Ident i when i.Token.spelling = "Fn" || i.Token.spelling = "FnOnce" || i.Token.spelling = "FnMut" ->
      ignore (advance p);
      parse_fn_type p start
  | Token.Ident i when i.Token.spelling = "_" ->
      ignore (advance p);
      Ast.Inferred (span_end p start)
  | Token.Ident _ | Token.KwSuper | Token.KwCrate ->
      let name = parse_type_name p in
      let args = parse_optional_type_args p in
      Ast.Named (name, args, span_end p start)
  | Token.KwSelfTy ->
      ignore (advance p);
      if eat p Token.ColonColon then begin
        (* Self::Assoc *)
        let full = ref "Self" in
        if at_ident p || kind p = Token.KwSelfTy then begin
          full := !full ^ "::" ^ expect_ident p;
          while eat p Token.ColonColon do
            if at_ident p || kind p = Token.KwSelfTy then full := !full ^ "::" ^ expect_ident p
            else ()
          done
        end;
        Ast.Named (!full, [], span_end p start)
      end
      else Ast.SelfType (span_end p start)
  | Token.LParen ->
      ignore (advance p);
      if at p Token.RParen then begin
        ignore (advance p);
        if eat p Token.Arrow then begin
          let ret = parse_type p in
          Ast.FnPtr ([], ret, span_end p start)
        end
        else Ast.Unit (span_end p start)
      end
      else begin
        let first = parse_type p in
        if eat p Token.Comma then begin
          let rest = ref [ first ] in
          while not (at p Token.RParen) && not (at_eof p) do
            rest := parse_type p :: !rest;
            if not (eat p Token.Comma) then ()
          done;
          expect p Token.RParen "')' in tuple type";
          if eat p Token.Arrow then begin
            let ret = parse_type p in
            Ast.FnPtr (List.rev !rest, ret, span_end p start)
          end
          else Ast.TTuple (List.rev !rest, span_end p start)
        end
        else begin
          expect p Token.RParen "')' in grouped type";
          if eat p Token.Arrow then begin
            let ret = parse_type p in
            Ast.FnPtr ([ first ], ret, span_end p start)
          end
          else first
        end
      end
  | Token.LBracket ->
      ignore (advance p);
      let elem = parse_type p in
      if eat p Token.Semi then begin
        let len = parse_expr p in
        expect p Token.RBracket "']' in array type";
        Ast.TArray (elem, Some len, span_end p start)
      end
      else begin
        expect p Token.RBracket "']' in slice type";
        Ast.Slice (elem, span_end p start)
      end
  | Token.Amp ->
      let amp_span = cur_span p in
      ignore (advance p);
      let mutable_ = eat p Token.KwMut in
      (* E106 is a hard error in ordinary type position. The manifest
         closure (bootstrap profile) contains exactly two exceptions:
         (a) __intrinsic_* extern signatures — the internal ABI;
         (b) `&T` nested inside type arguments (e.g.
             `Map[String, &MirFunction]` in tg_compiler/mir.tg) — the
             internal reference type in annotation position.
         Both are recorded as SUPPORTED profile constructs; everything
         else stops before semantics. *)
      if not p.extern_abi_context && p.type_arg_depth = 0 then
        err p "E106"
          "safe reference types are not first-class; use a parameter access convention / access operation"
          amp_span;
      let inner = parse_type_primary p in
      Ast.Ref (inner, mutable_, span_end p start)
  | Token.Star ->
      ignore (advance p);
      let mutable_ = eat p Token.KwMut in
      let inner = parse_type_primary p in
      Ast.RawPtr (inner, mutable_, span_end p start)
  | Token.KwImpl ->
      ignore (advance p);
      let inner = parse_type_primary p in
      Ast.ImplTrait (inner, span_end p start)
  | Token.KwDyn ->
      ignore (advance p);
      let inner = parse_type_primary p in
      Ast.DynTrait (inner, span_end p start)
  | Token.KwAsync ->
      ignore (advance p);
      parse_type_primary p
  | _ ->
      expected p "type";
      ignore (advance p);
      Ast.Named ("", [], span_end p start)

and parse_type_name (p : parser) : string =
  let name = ref (expect_ident p) in
  while eat p Token.ColonColon do
    name := !name ^ "::" ^ expect_ident p
  done;
  !name

and parse_optional_type_args (p : parser) : Ast.type_expr list =
  if not (at p Token.LBracket) then []
  else begin
    p.type_arg_depth <- p.type_arg_depth + 1;
    ignore (advance p);
    let args = ref [] in
    while not (at p Token.RBracket) && not (at_eof p) do
      let start = cur_span p in
      if at_ident p && kind_at p 1 = Token.Eq then begin
        let name = expect_ident p in
        ignore (advance p);
        let value = parse_type p in
        args := Ast.AssocBinding (name, value, span_merged p start (cur_span p)) :: !args
      end
      else
        match kind p with
        | Token.Integer lit ->
            ignore (advance p);
            args :=
              Ast.ConstExpr (Ast.IntLit (lit, span_merged p start (cur_span p)), span_merged p start (cur_span p))
              :: !args
        | _ -> args := parse_type p :: !args;
      if not (at p Token.RBracket) then ignore (eat p Token.Comma)
    done;
    if at p Token.RBracket then ignore (advance p)
    else expected p "']' in type arguments";
    p.type_arg_depth <- p.type_arg_depth - 1;
    List.rev !args
  end

and parse_fn_type (p : parser) (start : Span.span) : Ast.type_expr =
  expect p Token.LParen "'(' in function type";
  let params = ref [] in
  while not (at p Token.RParen) && not (at_eof p) do
    params := parse_fn_type_param p :: !params;
    if not (eat p Token.Comma) then ()
  done;
  expect p Token.RParen "')' in function type";
  let ret =
    if eat p Token.Arrow then parse_type p
    else Ast.Named ("Unit", [], span_end p start)
  in
  Ast.FnPtr (List.rev !params, ret, span_end p start)

and parse_fn_type_param (p : parser) : Ast.type_expr =
  match kind p with
  | Token.KwInout | Token.KwSink | Token.KwSet ->
      ignore (advance p);
      parse_type p
  | Token.KwMut ->
      err p "E100"
        "legacy parameter spelling 'mut' is removed; use the explicit access convention 'inout'"
        (cur_span p);
      ignore (advance p);
      parse_type p
  | Token.Amp ->
      let amp_span = cur_span p in
      ignore (advance p);
      ignore (eat p Token.KwMut);
      err p "E100"
        "legacy parameter spelling '&' is removed; use the explicit access convention"
        amp_span;
      parse_type p
  | Token.Ident i when i.Token.spelling = "move" || i.Token.spelling = "own" ->
      err p "E100"
        "legacy parameter spelling 'move'/'own' is removed; use the explicit access convention 'sink'"
        (cur_span p);
      ignore (advance p);
      parse_type p
  | _ -> parse_type p

(* ────────────────────────────────────────────────────────────────
   Items *)

and parse_test_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name =
    match kind p with
    | Token.String s -> ignore (advance p); s
    | _ -> expect_ident p
  in
  ignore (eat p Token.KwDo);
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in test declaration";
  Ast.TestDecl { Ast.test_name = name; test_body = body; test_span = span_end p start }

and parse_struct_decl (p : parser) (is_resource : bool) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let tps = parse_optional_type_params p in
  let where_clause = parse_optional_where_clause p in
  let fields = ref [] in
  let methods = ref [] in
  while not (at_kw_end_as_terminator p) && not (at_eof p) do
    if (at p Token.KwDef || at p Token.KwFn) && kind_at p 1 <> Token.Colon then begin
      match parse_function p [] ((), false) false with
      | Some (Ast.Function fn) -> methods := fn :: !methods
      | _ -> ignore (advance p)
    end
    else begin
      let fstart = cur_span p in
      let (_, fpub) = parse_vis p in
      let fname = expect_ident p in
      expect p Token.Colon "':' in struct field";
      let ftype = parse_type p in
      let fdefault = if eat p Token.Eq then Some (parse_expr p) else None in
      fields :=
        { Ast.f_name = fname; f_public = fpub; f_type = ftype; f_default = fdefault; f_span = span_merged p fstart (cur_span p) }
        :: !fields;
      ignore (eat p Token.Comma)
    end
  done;
  expect p Token.KwEnd "'end' in struct declaration";
  Ast.StructDef
    {
      Ast.s_name = name;
      s_public = false;
      s_type_params = tps;
      s_where = where_clause;
      s_fields = List.rev !fields;
      s_methods = List.rev !methods;
      s_kind = if is_resource then Ast.NominalResource else Ast.NominalValue;
      s_span = span_end p start;
    }

and parse_enum_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let tps = parse_optional_type_params p in
  let where_clause = parse_optional_where_clause p in
  let variants = ref [] in
  while not (at_kw_end_as_terminator p) && not (at_eof p) do
    let vstart = cur_span p in
    let vname = expect_ident p in
    let fields = ref [] in
    if eat p Token.LParen then begin
      while not (at p Token.RParen) && not (at_eof p) do
        let fstart = cur_span p in
        let fname =
          if at_ident p && kind_at p 1 = Token.Colon then begin
            let n = expect_ident p in
            ignore (advance p);
            Some n
          end
          else None
        in
        let ftype = parse_type p in
        fields := { Ast.vf_name = fname; vf_type = ftype; vf_span = span_merged p fstart (cur_span p) } :: !fields;
        if not (eat p Token.Comma) then ()
      done;
      expect p Token.RParen "')' in enum variant"
    end
    else if eat p Token.LBrace then begin
      (* named-field variant: Variant { f: T, ... } *)
      while not (at p Token.RBrace) && not (at_eof p) do
        let fstart = cur_span p in
        let fname = expect_ident p in
        expect p Token.Colon "':' in enum variant field";
        let ftype = parse_type p in
        fields := { Ast.vf_name = Some fname; vf_type = ftype; vf_span = span_merged p fstart (cur_span p) } :: !fields;
        if not (eat p Token.Comma) then ()
      done;
      expect p Token.RBrace "'}' in enum variant"
    end;
    variants :=
      { Ast.v_name = vname; v_fields = List.rev !fields; v_span = span_merged p vstart (cur_span p) }
      :: !variants;
    if not (eat p Token.Comma) then ignore (eat p Token.Semi)
  done;
  expect p Token.KwEnd "'end' in enum declaration";
  Ast.EnumDef
    {
      Ast.e_name = name;
      e_public = false;
      e_type_params = tps;
      e_where = where_clause;
      e_variants = List.rev !variants;
      e_span = span_end p start;
    }

and parse_trait_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let tps = parse_optional_type_params p in
  let supertraits = ref [] in
  if eat p Token.Colon then begin
    supertraits := [ expect_ident p ];
    while eat p Token.Plus do
      supertraits := expect_ident p :: !supertraits
    done
  end;
  let where_clause = parse_optional_where_clause p in
  let methods = ref [] in
  let assoc = ref [] in
  (* trait bodies may open with `do`, `{`, or bare newline-separated
     methods terminated by `end` *)
  let brace =
    if at p Token.LBrace then begin
      ignore (advance p);
      true
    end
    else false
  in
  ignore (eat p Token.KwDo);
  if brace || true then begin
    let rec loop () =
      if at_eof p then ()
      else if (not brace && at_kw_end_as_terminator p) || (brace && at p Token.RBrace) then ()
      else begin
        match kind p with
        | Token.KwType | Token.KwTypealias ->
            ignore (advance p);
            let aname = expect_ident p in
            let abounds = ref [] in
            if eat p Token.Colon then begin
              abounds := [ expect_ident p ];
              while eat p Token.Plus do
                abounds := expect_ident p :: !abounds
              done
            end;
            let avalue = if eat p Token.Eq then parse_type p else Ast.Named ("", [], Span.synthetic) in
            assoc :=
              { Ast.ta_name = aname; ta_public = false; ta_type_params = []; ta_value = avalue; ta_span = span_end p start }
              :: !assoc;
            loop ()
        | Token.KwDef | Token.KwFn ->
            (match parse_function p [] ((), false) false with
             | Some (Ast.Function fn) -> methods := fn :: !methods
             | _ -> ());
            loop ()
        | _ ->
            ignore (advance p);
            loop ()
      end
    in
    loop ();
    if brace then expect p Token.RBrace "'}' in trait body"
    else expect p Token.KwEnd "'end' in trait body"
  end;
  Ast.TraitDef
    {
      Ast.t_name = name;
      t_public = false;
      t_type_params = tps;
      t_supertraits = List.rev !supertraits;
      t_where = where_clause;
      t_methods = List.rev !methods;
      t_associated_types = List.rev !assoc;
      t_span = span_end p start;
    }

and parse_impl_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let tps = parse_optional_type_params p in
  let first = parse_type p in
  let first_name = type_base_name first in
  let trait_name = ref None in
  let for_type = ref None in
  let target = ref first_name in
  let has_for = eat p Token.KwFor in
  if has_for then begin
    trait_name := Some first_name;
    for_type := Some first;
    let target_ty = parse_type p in
    target := type_base_name target_ty
  end;
  (* `impl NonNull[T]` (args on the target, no impl-level params) is the
     Tangerine inherent-impl form: promote the target's type-arg names to
     the impl's own type parameters. The trait form `impl Validator[A, B]
     for X` keeps the trait's args as trait arguments, not impl params. *)
  let tps =
    if tps <> [] then tps
    else if has_for then []
    else
      match first with
      | Ast.Named (_, args, _) ->
          List.filter_map
            (fun a ->
              match a with
              | Ast.Named (n, [], sp) -> Some { Ast.tp_name = n; tp_bounds = []; tp_span = sp }
              | _ -> None)
            args
      | _ -> []
  in
  let where_clause = parse_optional_where_clause p in
  let methods = ref [] in
  let assoc = ref [] in
  let consts = ref [] in
  let brace = eat p Token.LBrace in
  let rec loop () =
    if at_eof p then ()
    else if (not brace && at_kw_end_as_terminator p) || (brace && at p Token.RBrace) then ()
    else begin
      match kind p with
      | Token.KwDef | Token.KwFn ->
          (match parse_function p [] ((), false) false with
           | Some (Ast.Function fn) -> methods := fn :: !methods
           | _ -> ());
          loop ()
      | Token.KwType | Token.KwTypealias ->
          ignore (advance p);
          let aname = expect_ident p in
          expect p Token.Eq "'=' in impl associated type";
          let avalue = parse_type p in
          assoc :=
            { Ast.ta_name = aname; ta_public = false; ta_type_params = []; ta_value = avalue; ta_span = span_end p start }
            :: !assoc;
          loop ()
      | Token.KwConst ->
          (match parse_const_decl p false with
           | Ast.ConstDecl c -> consts := c :: !consts
           | _ -> ());
          loop ()
      | _ ->
          ignore (advance p);
          loop ()
    end
  in
  if not brace then ignore (eat p Token.KwDo);
  loop ();
  if brace then expect p Token.RBrace "'}' in impl block"
  else expect p Token.KwEnd "'end' in impl block";
  Ast.ImplBlock
    {
      Ast.i_type_params = tps;
      i_trait_name = !trait_name;
      i_target_type = !target;
      i_for_type = !for_type;
      i_where = where_clause;
      i_methods = List.rev !methods;
      i_associated_types = List.rev !assoc;
      i_consts = List.rev !consts;
      i_span = span_end p start;
    }

and type_base_name (t : Ast.type_expr) : string =
  match t with
  | Ast.Named (n, _, _) -> n
  | Ast.AssocBinding (n, _, _) -> n
  | _ -> ""

and parse_use_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let segs = ref [] in
  let seg () =
    match kind p with
    | Token.KwSuper -> ignore (advance p); "super"
    | Token.KwCrate -> ignore (advance p); "crate"
    | _ -> expect_ident p
  in
  segs := [ seg () ];
  let result = ref None in
  while eat p Token.ColonColon && !result = None do
    if at p Token.Star then begin
      ignore (advance p);
      result := Some (Ast.UseGlob (List.rev !segs))
    end
    else if at p Token.LBrace then begin
      ignore (advance p);
      let items = ref [] in
      while not (at p Token.RBrace) && not (at_eof p) do
        let name = expect_ident p in
        let alias = if eat p Token.KwAs then Some (expect_ident p) else None in
        items := { Ast.ui_name = name; ui_alias = alias; ui_span = cur_span p } :: !items;
        if not (eat p Token.Comma) then ()
      done;
      expect p Token.RBrace "'}' in use group";
      result := Some (Ast.UseGroup (List.rev !segs, List.rev !items))
    end
    else segs := seg () :: !segs
  done;
  match !result with
  | Some path -> return_use p start path
  | None ->
      let alias = if eat p Token.KwAs then Some (expect_ident p) else None in
      (match alias with
       | Some a -> return_use p start (Ast.UseAliased (List.rev !segs, a))
       | None -> return_use p start (Ast.UseSimple (List.rev !segs)))

and return_use p start path =
  Ast.UseDecl { Ast.u_path = path; u_span = span_end p start }

and parse_const_decl (p : parser) (is_let : bool) : Ast.item_kind =
  ignore is_let;
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let ty =
    if eat p Token.Colon then parse_type p else Ast.Named ("", [], Span.synthetic)
  in
  expect p Token.Eq "'=' in constant declaration";
  let value = parse_expr p in
  Ast.ConstDecl
    {
      Ast.c_name = name;
      c_public = false;
      c_type = ty;
      c_value = value;
      c_span = span_end p start;
    }

and parse_static_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let mutable_ = eat p Token.KwMut in
  let name = expect_ident p in
  expect p Token.Colon "':' in static declaration";
  let ty = parse_type p in
  expect p Token.Eq "'=' in static declaration";
  let value = parse_expr p in
  Ast.StaticDecl
    {
      Ast.st_name = name;
      st_public = false;
      st_mutable = mutable_;
      st_type = ty;
      st_value = value;
      st_span = span_end p start;
    }

and parse_type_alias_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let tps = parse_optional_type_params p in
  expect p Token.Eq "'=' in type alias";
  let value = parse_type p in
  Ast.TypeAlias
    {
      Ast.ta_name = name;
      ta_public = false;
      ta_type_params = tps;
      ta_value = value;
      ta_span = span_end p start;
    }

and parse_extern_item (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let header_end = (peek_at p (-1)).Token.span.Span.end_ in
  let abi =
    match kind p with
    | Token.String s -> ignore (advance p); Some s
    | _ -> None
  in
  let abi_end = (peek_at p (-1)).Token.span.Span.end_ in
  let items = ref [] in
  let looks_like_fn () =
    match kind p with
    | Token.KwDef | Token.KwFn -> true
    | Token.KwUnsafe -> (match kind_at p 1 with Token.KwDef | Token.KwFn -> true | _ -> false)
    | Token.KwAsync | Token.KwPure | Token.KwInline ->
        (match kind_at p 1 with Token.KwDef | Token.KwFn -> true | _ -> false)
    | _ -> false
  in
  if looks_like_fn ()
     && not
          (source_has_newline p
             (Span.make (if abi = None then header_end else abi_end) abi_end p.file_id)
             (cur_span p))
  then begin
    (* single extern function on the same line as the header *)
    (match parse_extern_function p with
     | Some item -> items := [ item ]
     | None -> ());
    ignore (eat p Token.KwEnd);
    Ast.ExternBlock
      { Ast.ex_abi = abi; ex_items = !items; ex_span = span_end p start }
  end
  else begin
    ignore (eat p Token.KwDo);
    let rec loop () =
      if at_kw_end_as_terminator p || at_eof p then ()
      else begin
        match kind p with
        | Token.KwDef | Token.KwFn ->
            (match parse_extern_function p with
             | Some item -> items := item :: !items
             | None -> ());
            loop ()
        | Token.KwUnsafe ->
            ignore (advance p);
            (match parse_extern_function p with
             | Some item -> items := item :: !items
             | None -> ());
            loop ()
        | Token.KwStatic ->
            items := parse_extern_static p :: !items;
            loop ()
        | Token.KwStruct ->
            (match parse_struct_decl p false with
             | Ast.StructDef d ->
                 items :=
                   { Ast.kind = Ast.StructDef d; attributes = []; span = d.Ast.s_span; module_path = p.inline_module_path }
                   :: !items
             | _ -> ());
            loop ()
        | Token.KwEnum ->
            (match parse_enum_decl p with
             | Ast.EnumDef d ->
                 items :=
                   { Ast.kind = Ast.EnumDef d; attributes = []; span = d.Ast.e_span; module_path = p.inline_module_path }
                   :: !items
             | _ -> ());
            loop ()
        | _ -> ignore (advance p); loop ()
      end
    in
    loop ();
    if at p Token.KwEnd then ignore (advance p)
    else if List.length !items <> 1 then expect p Token.KwEnd "'end' in extern block";
    Ast.ExternBlock
      { Ast.ex_abi = abi; ex_items = List.rev !items; ex_span = span_end p start }
  end

and parse_extern_function (p : parser) : Ast.item option =
  let start = cur_span p in
  let is_unsafe = eat p Token.KwUnsafe in
  if not (at p Token.KwDef || at p Token.KwFn) then None
  else begin
    ignore (advance p);
    let name = expect_ident p in
    let was_intrinsic = p.extern_abi_context in
    p.extern_abi_context <- Util.has_prefix name "__intrinsic_";
    let tps = parse_optional_type_params p in
    let params = parse_param_list p in
    let ret = parse_optional_return_type p in
    p.extern_abi_context <- was_intrinsic;
    (* An extern def's trailing `end` is only its own when it sits on the
       SAME line (single-line form); inside an extern `do ... end` block
       the block's closing `end` must not be consumed here. *)
    if at p Token.KwEnd
       && not
            (source_has_newline p
               (Span.make p.prev_end p.prev_end p.file_id)
               (cur_span p))
    then ignore (advance p);
    let sig_rec =
      {
        Ast.sig_name = name;
        sig_public = false;
        sig_async = false;
        sig_unsafe = is_unsafe;
        sig_const = false;
        sig_pure = false;
        sig_inline = false;
        sig_extern = true;
        sig_type_params = tps;
        sig_params = params;
        sig_return = ret;
        sig_where = [];
        sig_span = span_end p start;
      }
    in
    let fn =
      {
        Ast.fn_sig = sig_rec;
        fn_clauses = [];
        fn_body = Ast.FnSignatureOnly;
        fn_span = span_end p start;
      }
    in
    Some
      {
        Ast.kind = Ast.Function fn;
        attributes = [];
        span = span_end p start;
        module_path = p.inline_module_path;
      }
  end

and parse_extern_static (p : parser) : Ast.item =
  let start = cur_span p in
  ignore (advance p);
  let mutable_ = eat p Token.KwMut in
  let name = expect_ident p in
  expect p Token.Colon "':' in extern static";
  let ty = parse_type p in
  {
    Ast.kind =
      Ast.StaticDecl
        {
          Ast.st_name = name;
          st_public = false;
          st_mutable = mutable_;
          st_type = ty;
          st_value = Ast.Name ("", Span.synthetic);
          st_span = span_end p start;
        };
    attributes = [];
    span = span_end p start;
    module_path = p.inline_module_path;
  }

and parse_module_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = ref (expect_ident p) in
  while eat p Token.ColonColon do
    name := !name ^ "::" ^ expect_ident p
  done;
  let inline_segments =
    String.split_on_char ':' !name |> List.filter (fun s -> s <> "")
  in
  if at_eof p then
    Ast.ModuleDef
      { Ast.m_name = !name; m_public = false; m_items = None; md_span = span_end p start }
  else begin
    p.inline_module_path <- p.inline_module_path @ inline_segments;
    let items = ref [] in
    while not (at_kw_end_as_terminator p) && not (at_eof p) do
      match parse_item p with
      | Some item -> items := item :: !items
      | None -> ignore (advance p)
    done;
    expect p Token.KwEnd "'end' in module declaration";
    let n = List.length inline_segments in
    p.inline_module_path <-
      List.filteri (fun i _ -> i < List.length p.inline_module_path - n) p.inline_module_path;
    Ast.ModuleDef
      {
        Ast.m_name = !name;
        m_public = false;
        m_items = Some (List.rev !items);
        md_span = span_end p start;
      }
  end

and parse_capability_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let implies = ref [] in
  if eat p Token.KwImplies then begin
    implies := [ expect_ident p ];
    while eat p Token.Comma do
      implies := expect_ident p :: !implies
    done
  end;
  ignore (eat p Token.KwEnd);
  Ast.CapabilityDecl
    {
      Ast.cap_name = name;
      cap_implies = List.rev !implies;
      cap_span = span_end p start;
    }

and parse_effect_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  let tps = parse_optional_type_params p in
  let ops = ref [] in
  while not (at_kw_end_as_terminator p) && not (at_eof p) do
    if at_ident p || at p Token.KwDef then begin
      if at p Token.KwDef then ignore (advance p);
      let opname = expect_ident p in
      let op_params = ref [] in
      if eat p Token.LParen then begin
        while not (at p Token.RParen) && not (at_eof p) do
          op_params := expect_ident p :: !op_params;
          if not (eat p Token.Comma) then ()
        done;
        expect p Token.RParen "')' in effect operation"
      end;
      let ret = parse_optional_return_type p in
      ops :=
        {
          Ast.sig_name = opname;
          sig_public = false;
          sig_async = false;
          sig_unsafe = false;
          sig_const = false;
          sig_pure = false;
          sig_inline = false;
          sig_extern = false;
          sig_type_params = [];
          sig_params = List.map (fun n -> { Ast.p_name = n; p_convention = Ast.LetAccess; p_type = Ast.Named ("", [], Span.synthetic); p_default = None; p_span = Span.synthetic }) (List.rev !op_params);
          sig_return = ret;
          sig_where = [];
          sig_span = span_end p start;
        }
        :: !ops
    end
    else ignore (advance p)
  done;
  ignore (eat p Token.KwEnd);
  Ast.EffectDecl
    {
      Ast.ef_name = name;
      ef_type_params = tps;
      ef_operations = List.rev !ops;
      ef_span = span_end p start;
    }

and parse_rationale_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let fields = ref [] in
  while not (at_kw_end_as_terminator p) && not (at_eof p) do
    let fname = expect_ident p in
    if eat p Token.Colon then begin
      let value =
        match kind p with
        | Token.String s ->
            ignore (advance p);
            s
        | _ ->
            let s = cur_span p in
            ignore (parse_expr p);
            src_text p s
      in
      fields := (fname, value) :: !fields
    end
    else fields := (fname, "") :: !fields;
    ignore (eat p Token.Comma)
  done;
  ignore (eat p Token.KwEnd);
  Ast.RationaleBlock
    { Ast.r_fields = List.rev !fields; r_span = span_end p start }

and parse_macro_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  ignore (eat p Token.Bang);
  let params = ref [] in
  if eat p Token.LParen then begin
    while not (at p Token.RParen) && not (at_eof p) do
      let pname = expect_ident p in
      expect p Token.Colon "':' in macro parameter";
      let ptype = expect_ident p in
      params := (pname, ptype) :: !params;
      if not (eat p Token.Comma) then ()
    done;
    expect p Token.RParen "')' in macro parameters"
  end;
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in macro declaration";
  Ast.MacroDecl
    {
      Ast.mac_name = name;
      mac_params = List.rev !params;
      mac_body = body;
      mac_span = span_end p start;
    }

and parse_edition_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let version =
    match kind p with
    | Token.String s -> ignore (advance p); s
    | Token.Integer s -> ignore (advance p); s
    | _ -> ""
  in
  Ast.EditionDecl
    {
      Ast.ed_version = version;
      ed_items = None;
      ed_span = span_end p start;
    }

(* ────────────────────────────────────────────────────────────────
   Expressions — precedence climbing per grammar.md §4.1 *)

and parse_expr (p : parser) : Ast.expr = parse_logical_or p

and parse_logical_or (p : parser) : Ast.expr =
  let left = ref (parse_logical_and p) in
  while at p Token.PipePipe do
    let start = cur_span p in
    ignore (advance p);
    let right = parse_logical_and p in
    left := Ast.Binary (!left, Ast.BOr, right, span_end p start)
  done;
  !left

and parse_logical_and (p : parser) : Ast.expr =
  let left = ref (parse_range p) in
  while at p Token.AmpAmp do
    let start = cur_span p in
    ignore (advance p);
    let right = parse_range p in
    left := Ast.Binary (!left, Ast.BAnd, right, span_end p start)
  done;
  !left

and parse_range (p : parser) : Ast.expr =
  let left = parse_equality p in
  if at p Token.DotDot || at p Token.DotDotEq then begin
    let start = cur_span p in
    let inclusive = at p Token.DotDotEq in
    ignore (advance p);
    let right =
      match kind p with
      | Token.Comma | Token.RParen | Token.RBracket | Token.RBrace | Token.KwEnd
      | Token.KwThen | Token.KwDo | Token.KwElse | Token.KwElsif | Token.KwWhen
      | Token.Eof | Token.Semi ->
          Ast.Name ("", Span.synthetic)
      | _ -> parse_equality p
    in
    Ast.Range (left, right, inclusive, span_end p start)
  end
  else left

and parse_equality (p : parser) : Ast.expr =
  let left = ref (parse_comparison p) in
  while at p Token.EqEq || at p Token.BangEq do
    let start = cur_span p in
    let op = if at p Token.EqEq then Ast.Eq else Ast.NotEq in
    ignore (advance p);
    let right = parse_comparison p in
    left := Ast.Binary (!left, op, right, span_end p start)
  done;
  !left

and parse_comparison (p : parser) : Ast.expr =
  let left = ref (parse_bitwise_or p) in
  while at p Token.Lt || at p Token.Gt || at p Token.LtEq || at p Token.GtEq do
    let start = cur_span p in
    let op =
      match kind p with
      | Token.Lt -> Ast.Lt
      | Token.Gt -> Ast.Gt
      | Token.LtEq -> Ast.LtEq
      | _ -> Ast.GtEq
    in
    ignore (advance p);
    let right = parse_bitwise_or p in
    left := Ast.Binary (!left, op, right, span_end p start)
  done;
  !left

and parse_bitwise_or (p : parser) : Ast.expr =
  let left = ref (parse_bitwise_xor p) in
  while at p Token.Pipe do
    let start = cur_span p in
    ignore (advance p);
    let right = parse_bitwise_xor p in
    left := Ast.Binary (!left, Ast.BitOr, right, span_end p start)
  done;
  !left

and parse_bitwise_xor (p : parser) : Ast.expr =
  let left = ref (parse_bitwise_and p) in
  while at p Token.Caret do
    let start = cur_span p in
    ignore (advance p);
    let right = parse_bitwise_and p in
    left := Ast.Binary (!left, Ast.BitXor, right, span_end p start)
  done;
  !left

and parse_bitwise_and (p : parser) : Ast.expr =
  let left = ref (parse_shift p) in
  while at p Token.Amp do
    let start = cur_span p in
    ignore (advance p);
    let right = parse_shift p in
    left := Ast.Binary (!left, Ast.BitAnd, right, span_end p start)
  done;
  !left

and parse_shift (p : parser) : Ast.expr =
  let left = ref (parse_term p) in
  while at p Token.Shl || at p Token.Shr do
    let start = cur_span p in
    let op = if at p Token.Shl then Ast.Shl else Ast.Shr in
    ignore (advance p);
    let right = parse_term p in
    left := Ast.Binary (!left, op, right, span_end p start)
  done;
  !left

and parse_term (p : parser) : Ast.expr =
  let left = ref (parse_factor p) in
  (* a statement-form expression (`while ... end`, `match ... end`,
     `if ... end`, a block) yields no value; a `+`/`-` at the start of a
     new line after one begins a NEW statement (a negative literal or a
     fresh term), NOT an additive continuation — mirrors the production
     parser's documented statement-boundary semantics, so `while ... end`
     followed by `-1` parses as two statements. After a value expression
     (call/name/index) the leading-operator style still continues. *)
  let statement_form e =
    match e with
    | Ast.WhileExpr _ | Ast.ForExpr _ | Ast.MatchExpr _ | Ast.IfExpr _
    | Ast.Block _ | Ast.UnsafeBlock _ | Ast.NextExpr _ | Ast.BreakExpr _
    | Ast.ReturnExpr _ | Ast.Assign _ | Ast.CompoundAssign _ ->
        true
    | _ -> false
  in
  let newline_before = source_has_newline p (Ast.expr_span !left) (cur_span p) in
  while (at p Token.Plus && not (statement_form !left && newline_before))
        || (at p Token.Minus && not newline_before)
  do
    let start = cur_span p in
    let op = if at p Token.Plus then Ast.Add else Ast.Sub in
    ignore (advance p);
    let right = parse_factor p in
    left := Ast.Binary (!left, op, right, span_end p start)
  done;
  !left

and parse_factor (p : parser) : Ast.expr =
  let left = ref (parse_unary p) in
  let rec loop () =
    if (at p Token.Star || at p Token.Slash || at p Token.Percent)
       && not (source_has_newline p (Ast.expr_span !left) (cur_span p))
    then begin
      let start = cur_span p in
      let double_star =
        at p Token.Star && kind_at p 1 = Token.Star
        && (peek p).Token.span.Span.end_ = (peek_at p 1).Token.span.Span.start
      in
      let op =
        if double_star then begin
          ignore (advance p);
          ignore (advance p);
          Ast.Mul
        end
        else begin
          let op =
            match kind p with
            | Token.Star -> Ast.Mul
            | Token.Slash -> Ast.Div
            | _ -> Ast.Mod
          in
          ignore (advance p);
          op
        end
      in
      let right = parse_unary p in
      left := Ast.Binary (!left, op, right, span_end p start);
      loop ()
    end
  in
  loop ();
  !left

and parse_unary (p : parser) : Ast.expr =
  let start = cur_span p in
  match kind p with
  | Token.Minus ->
      ignore (advance p);
      let inner = parse_unary p in
      Ast.Unary (Ast.Neg, inner, span_end p start)
  | Token.Bang ->
      ignore (advance p);
      let inner = parse_unary p in
      Ast.Unary (Ast.Not, inner, span_end p start)
  | Token.Tilde ->
      ignore (advance p);
      let inner = parse_unary p in
      Ast.Unary (Ast.BitNot, inner, span_end p start)
  | Token.Amp ->
      let amp_span = cur_span p in
      ignore (advance p);
      if at p Token.KwMut && (peek p).Token.span.Span.start = amp_span.Span.end_ then begin
        ignore (advance p);
        let inner = parse_unary p in
        Ast.Unary (Ast.BorrowMut, inner, span_end p start)
      end
      else begin
        let inner = parse_unary p in
        Ast.Unary (Ast.Borrow, inner, span_end p start)
      end
  | Token.Star ->
      ignore (advance p);
      if at p Token.Star then ignore (advance p);
      let inner = parse_unary p in
      Ast.Unary (Ast.Deref, inner, span_end p start)
  | Token.KwAwait ->
      ignore (advance p);
      let inner = parse_unary p in
      Ast.AwaitExpr (inner, span_end p start)
  | _ -> parse_postfix p

and parse_postfix (p : parser) : Ast.expr =
  let e = ref (parse_primary p) in
  let rec loop () =
    match kind p with
    | Token.Question ->
        let start = cur_span p in
        ignore (advance p);
        e := Ast.TryOp (!e, span_end p start);
        loop ()
    | Token.Dot ->
        let start = cur_span p in
        ignore (advance p);
        (match kind p with
         | Token.Integer idx ->
             ignore (advance p);
             e := Ast.Field (!e, idx, span_end p start);
             loop ()
         | _ -> (
             match soft_ident_kind (kind p) with
             | Some name ->
                 ignore (advance p);
                 let type_args =
                   if looks_like_bracket_method_type_args p then parse_optional_type_args p
                   else []
                 in
                 if at p Token.LParen then begin
                   let args = parse_call_args p in
                   e :=
                     Ast.Call
                       (Ast.Field (!e, name, span_end p start), type_args, args,
                        span_end p start);
                   if at p Token.LBrace then begin
                     let cl = parse_trailing_closure p in
                     e :=
                       Ast.Call
                         (Ast.Field (!e, name, span_end p start), type_args, cl,
                          span_end p start)
                   end
                 end
                 else if at p Token.LBrace then begin
                   let cl = parse_trailing_closure p in
                   e :=
                     Ast.Call
                       (Ast.Field (!e, name, span_end p start), type_args, cl,
                        span_end p start)
                 end
                 else e := Ast.Field (!e, name, span_end p start);
                 loop ()
             | None ->
                 expected p "field name after '.'";
                 loop ()))
    | Token.LParen ->
        (* a `(` at the start of a new line after a statement-form
           expression begins a NEW statement (a parenthesized value), not
           a call application: `if ... end` followed by `()` parses as
           two statements (the statement-boundary semantics) *)
        let statement_form e =
          match e with
          | Ast.WhileExpr _ | Ast.ForExpr _ | Ast.LoopExpr _ | Ast.MatchExpr _
          | Ast.IfExpr _ | Ast.Block _ | Ast.UnsafeBlock _ | Ast.NextExpr _
          | Ast.BreakExpr _ | Ast.ReturnExpr _ | Ast.Assign _
          | Ast.CompoundAssign _ ->
              true
          | _ -> false
        in
        (* the statement-form's span can extend into the following
           token (the if-expr span merges the next token); the
           statement boundary is the last CONSUMED token's end *)
        let boundary = Span.make p.prev_end p.prev_end p.file_id in
        if statement_form !e && source_has_newline p boundary (cur_span p)
        then ()
        else begin
          let start = cur_span p in
          let args = parse_call_args p in
          e := Ast.Call (!e, [], args, span_end p start);
          loop ()
        end
    | Token.LBracket ->
        let start = cur_span p in
        ignore (advance p);
        let idx = parse_expr p in
        expect p Token.RBracket "']' in index";
        e := Ast.Index (!e, idx, span_end p start);
        loop ()
    | Token.KwAs ->
        let start = cur_span p in
        ignore (advance p);
        let ty = parse_type p in
        e := Ast.Cast (!e, ty, span_end p start);
        loop ()
    | Token.Ident i when i.Token.spelling = "is" ->
        let start = cur_span p in
        ignore (advance p);
        let ty = parse_type p in
        e := Ast.Cast (!e, ty, span_end p start);
        loop ()
    | Token.Pipe when (peek_at p 1).Token.kind = Token.Gt
                      && (peek p).Token.span.Span.end_ = (peek_at p 1).Token.span.Span.start ->
        let start = cur_span p in
        ignore (advance p);
        ignore (advance p);
        let rhs = parse_postfix p in
        e :=
          Ast.Call
            (rhs, [],
             [ { Ast.ca_label = None; ca_value = !e; ca_span = start } ],
             span_end p start);
        loop ()
    | _ -> ()
  in
  loop ();
  !e

and looks_like_bracket_method_type_args (p : parser) : bool =
  (* `.name[...](...)` is a method call with type args; anything else after
     the matching `]` means `[...]` is an index. *)
  if not (at p Token.LBracket) then false
  else begin
    let n = Array.length p.tokens in
    let rec scan idx depth =
      if idx >= n then false
      else
        match (peek_at p (idx - p.pos)).Token.kind with
        | Token.LBracket -> scan (idx + 1) (depth + 1)
        | Token.RBracket ->
            if depth = 1 then kind_at p (idx - p.pos + 1) = Token.LParen
            else scan (idx + 1) (depth - 1)
        | Token.Eof -> false
        | _ -> scan (idx + 1) depth
    in
    scan p.pos 0
  end

and parse_call_args (p : parser) : Ast.call_arg list =
  expect p Token.LParen "'(' in call";
  let args = ref [] in
  while not (at p Token.RParen) && not (at_eof p) do
    let start = cur_span p in
    let label = ref None in
    if at_ident p && kind_at p 1 = Token.Colon then begin
      label := Some (expect_ident p);
      ignore (advance p)
    end;
    let value = parse_expr p in
    args := { Ast.ca_label = !label; ca_value = value; ca_span = span_end p start } :: !args;
    if not (eat p Token.Comma) then ()
  done;
  expect p Token.RParen "')' in call";
  List.rev !args

and parse_trailing_closure (p : parser) : Ast.call_arg list =
  let start = cur_span p in
  expect p Token.LBrace "'{' in trailing closure";
  let params =
    if at p Token.Pipe then begin
      ignore (advance p);
      let ps = parse_closure_params p in
      expect p Token.Pipe "'|' in trailing closure";
      ps
    end
    else []
  in
  let body =
    if at p Token.KwEnd then begin
      let b = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in trailing closure";
      block_to_expr b
    end
    else parse_expr p
  in
  expect p Token.RBrace "'}' in trailing closure";
  let cl =
    {
      Ast.cl_params = params;
      cl_return = None;
      cl_body = body;
      cl_span = span_end p start;
    }
  in
  [ { Ast.ca_label = None; ca_value = Ast.Closure cl; ca_span = span_end p start } ]

and block_to_expr (b : Ast.block_body) : Ast.expr =
  match b.Ast.b_tail with
  | Some e -> e
  | None -> Ast.Name ("", Span.synthetic)

and parse_primary (p : parser) : Ast.expr =
  let start = cur_span p in
  match kind p with
  | Token.Integer lit ->
      ignore (advance p);
      Ast.IntLit (lit, start)
  | Token.Float lit ->
      ignore (advance p);
      Ast.FloatLit (lit, start)
  | Token.String s ->
      ignore (advance p);
      Ast.StringLit (s, start)
  | Token.Char c ->
      ignore (advance p);
      Ast.CharLit (c, start)
  | Token.KwTrue ->
      ignore (advance p);
      Ast.BoolLit (true, start)
  | Token.KwFalse ->
      ignore (advance p);
      Ast.BoolLit (false, start)
  | Token.KwSelfValue ->
      let start = cur_span p in
      ignore (advance p);
      if eat p Token.ColonColon then begin
        let full = ref "self" in
        if at_ident p || kind p = Token.KwSelfTy then begin
          full := !full ^ "::" ^ expect_ident p;
          while eat p Token.ColonColon do
            if at_ident p || kind p = Token.KwSelfTy then full := !full ^ "::" ^ expect_ident p
            else ()
          done
        end;
        if at p Token.LParen then begin
          let args = parse_call_args p in
          Ast.Call (Ast.Name (!full, span_end p start), [], args, span_end p start)
        end
        else Ast.Name (!full, span_end p start)
      end
      else Ast.Name ("self", span_end p start)
  | Token.KwSelfTy ->
      let start = cur_span p in
      ignore (advance p);
      if eat p Token.ColonColon then begin
        let full = ref "Self" in
        if at_ident p || kind p = Token.KwSelfTy then begin
          full := !full ^ "::" ^ expect_ident p;
          while eat p Token.ColonColon do
            if at_ident p || kind p = Token.KwSelfTy then full := !full ^ "::" ^ expect_ident p
            else ()
          done
        end;
        if at p Token.LBrace && is_struct_literal_context p then
          parse_struct_literal p !full [] start
        else if looks_like_end_struct_literal p !full then
          parse_end_struct_literal p !full [] start
        else if at p Token.LParen then begin
          let args = parse_call_args p in
          Ast.Call (Ast.Name (!full, span_end p start), [], args, span_end p start)
        end
        else Ast.Name (!full, span_end p start)
      end
      else Ast.Name ("Self", span_end p start)
  | Token.Ident _ | Token.KwSuper | Token.KwCrate ->
      parse_ident_expr p start
  | Token.LParen ->
      ignore (advance p);
      if at p Token.RParen then begin
        ignore (advance p);
        Ast.Tuple ([], span_end p start)
      end
      else begin
        let first = parse_expr p in
        if at p Token.Comma then begin
          let elems = ref [ first ] in
          while eat p Token.Comma do
            if at p Token.RParen then ()
            else elems := parse_expr p :: !elems
          done;
          expect p Token.RParen "')' in tuple";
          Ast.Tuple (List.rev !elems, span_end p start)
        end
        else begin
          expect p Token.RParen "')' in group";
          first
        end
      end
  | Token.LBracket ->
      ignore (advance p);
      if at p Token.RBracket then begin
        ignore (advance p);
        Ast.Array ([], span_end p start)
      end
      else begin
        let first = parse_expr p in
        if eat p Token.Semi then begin
          let count = parse_expr p in
          expect p Token.RBracket "']' in array repeat";
          Ast.ArrayRepeat (first, count, span_end p start)
        end
        else begin
          let elems = ref [ first ] in
          let last_span = ref (Ast.expr_span first) in
          let rec more () =
            if at p Token.RBracket then ()
            else if eat p Token.Comma then begin
              if at p Token.RBracket then ()
              else begin
                let e = parse_expr p in
                elems := e :: !elems;
                last_span := Ast.expr_span e;
                more ()
              end
            end
            else if is_expr_start p
                    && source_has_newline p !last_span (cur_span p) then begin
              let e = parse_expr p in
              elems := e :: !elems;
              last_span := Ast.expr_span e;
              more ()
            end
          in
          more ();
          expect p Token.RBracket "']' in array literal";
          Ast.Array (List.rev !elems, span_end p start)
        end
      end
  | Token.LBrace ->
      if looks_like_map_literal p then parse_map_literal p start
      else if kind_at p 1 = Token.Pipe then parse_brace_closure p start
      else begin
        ignore (advance p);
        let body = parse_block_body p [ Token.RBrace ] in
        expect p Token.RBrace "'}' in block";
        Ast.Block (body, span_end p start)
      end
  | Token.Pipe -> parse_pipe_closure p start
  | Token.KwDo ->
      ignore (advance p);
      let params =
        if at p Token.Pipe then begin
          ignore (advance p);
          let ps = parse_closure_params p in
          expect p Token.Pipe "'|' in do-block closure";
          ps
        end
        else []
      in
      let body = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in do-block";
      if params = [] then Ast.Block (body, span_end p start)
      else
        Ast.Closure
          {
            Ast.cl_params = params;
            cl_return = None;
            cl_body = block_to_expr body;
            cl_span = span_end p start;
          }
  | Token.KwIf -> parse_if_expr p start
  | Token.KwUnless -> parse_unless_expr p start
  | Token.KwMatch -> parse_match_expr p start
  | Token.KwFor -> parse_for_expr p start
  | Token.KwWhile -> parse_while_expr p start
  | Token.KwUntil -> parse_until_expr p start
  | Token.KwLoop -> parse_loop_expr p start
  | Token.KwTry -> parse_try_expr p start
  | Token.KwHandle ->
      (* `handle` is a soft keyword: a name in value position, the
         effect-handling construct only when followed by a payload. *)
      let next_is_name_ctx =
        match kind_at p 1 with
        | Token.RParen | Token.Comma | Token.Dot | Token.ColonColon | Token.Eq
        | Token.Semi | Token.KwEnd | Token.KwThen | Token.KwWhen | Token.KwElse
        | Token.KwElsif | Token.RBracket | Token.RBrace | Token.LParen | Token.Lt
        | Token.Gt | Token.LtEq | Token.GtEq | Token.EqEq | Token.BangEq
        | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent
        | Token.AmpAmp | Token.PipePipe | Token.Amp | Token.Pipe | Token.Caret
        | Token.Shl | Token.Shr | Token.DotDot | Token.DotDotEq | Token.Question
        | Token.Eof ->
            true
        | _ -> false
      in
      if next_is_name_ctx then begin
        ignore (advance p);
        Ast.Name ("handle", span_end p start)
      end
      else parse_handle_expr p start
  | Token.KwUnsafe -> parse_unsafe_block p start
  | Token.KwDefer ->
      ignore (advance p);
      let body = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in defer block";
      Ast.Block (body, span_end p start)
  | Token.KwAsync ->
      ignore (advance p);
      let body = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in async block";
      Ast.Block (body, span_end p start)
  | Token.KwComptime ->
      ignore (advance p);
      let body = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in comptime block";
      Ast.ComptimeBlock (body, span_end p start)
  | Token.KwReturn ->
      ignore (advance p);
      if is_expr_start p then
        Ast.ReturnExpr (Some (parse_expr p), span_end p start)
      else Ast.ReturnExpr (None, span_end p start)
  | Token.KwBreak ->
      ignore (advance p);
      if is_expr_start p then
        Ast.BreakExpr (Some (parse_expr p), span_end p start)
      else Ast.BreakExpr (None, span_end p start)
  | _ -> (
      (* Soft keywords usable as expressions (e.g. `mod(17, 5)`, and
         `next` as an identifier — the production parser's
         TokenKind::Next -> ExprIdent("next") rule) *)
      match soft_ident_kind (kind p) with
      | Some _ -> parse_ident_expr p start
      | None ->
          expected p "expression";
          ignore (advance p);
          Ast.Name ("", span_end p start))

and parse_ident_expr (p : parser) (start : Span.span) : Ast.expr =
  let first = expect_ident p in
  (* b"..." string literal *)
  if first = "b" then
    match kind p with
    | Token.String s ->
        ignore (advance p);
        Ast.StringLit (s, span_end p start)
    | _ -> Ast.Name ("b", span_end p start)
  else if first = "asm" then begin
    (* asm!(...) / asm(...) inline assembly *)
    if at p Token.Bang then ignore (advance p);
    match kind p with
    | Token.LParen ->
        let payload_start = cur_span p in
        let (text, close_span) = collect_raw_until_rparen p in
        let text =
          if Util.has_prefix text "(" then String.sub text 1 (String.length text - 1)
          else text
        in
        let text =
          if String.length text > 0 && text.[String.length text - 1] = ')' then
            String.sub text 0 (String.length text - 1)
          else text
        in
        let _ = payload_start and _ = close_span in
        Ast.MacroCall ("asm", [ Ast.MacroTokens (text, start) ], span_end p start)
    | _ -> Ast.Name ("asm", start)
  end
  else if eat p Token.ColonColon then begin
    (* multi-segment path: A::B::C *)
    let full = ref (first ^ "::" ^ expect_ident p) in
    while eat p Token.ColonColon do
      if at_ident p || kind p = Token.KwSelfTy then full := !full ^ "::" ^ expect_ident p
      else ()
    done;
    let type_args = parse_optional_expr_type_args p (Some first) in
    if at p Token.LBrace && is_struct_literal_context p then
      parse_struct_literal p !full type_args start
    else if at p Token.LParen then begin
      let args = parse_call_args p in
      Ast.Call (Ast.Name (!full, span_end p start), type_args, args, span_end p start)
    end
    else Ast.Name (!full, span_end p start)
  end
  else begin
    let type_args = parse_optional_expr_type_args p (Some first) in
    if eat p Token.ColonColon then begin
      let full = ref (first ^ "::" ^ expect_ident p) in
      while eat p Token.ColonColon do
        if at_ident p || kind p = Token.KwSelfTy then full := !full ^ "::" ^ expect_ident p
        else ()
      done;
      if at p Token.LBrace && is_struct_literal_context p then
        parse_struct_literal p !full type_args start
      else if looks_like_end_struct_literal p !full then
        parse_end_struct_literal p !full type_args start
      else if at p Token.LParen then begin
        let args = parse_call_args p in
        Ast.Call (Ast.Name (!full, span_end p start), type_args, args, span_end p start)
      end
      else Ast.Name (!full, span_end p start)
    end
    else if at p Token.LBrace && is_struct_literal_context p then
      parse_struct_literal p first type_args start
    else if looks_like_end_struct_literal p first then
      parse_end_struct_literal p first type_args start
    else if at p Token.Bang && (kind_at p 1 = Token.LParen || kind_at p 1 = Token.LBracket) then begin
      ignore (advance p);
      let close = if at p Token.LParen then Token.RParen else Token.RBracket in
      ignore (advance p);
      let args = parse_macro_args p close in
      expect p close (if close = Token.RParen then "')' in macro call" else "']' in macro call");
      Ast.MacroCall (first, args, span_end p start)
    end
    else Ast.Name (first, span_end p start)
  end

and collect_raw_until_rparen (p : parser) : string * Span.span =
  let start = cur_span p in
  let depth = ref 0 in
  while not (at_eof p) do
    (match kind p with
     | Token.LParen -> incr depth
     | Token.RParen ->
         decr depth;
         if !depth = 0 then ()
     | _ -> ());
    if !depth = 0 then () else ignore (advance p)
  done;
  let text = src_text p (span_end p start) in
  let close_span = cur_span p in
  (text, close_span)

and parse_macro_args (p : parser) (close : Token.kind) : Ast.macro_arg list =
  (* Opaque syntax: if a depth-0 ':' or '::' appears before the closer,
     collect the raw token text as a single MacroTokens arg. *)
  if top_level_opaque_macro_syntax p close then begin
    let start = cur_span p in
    let depth_paren = ref 0 and depth_bracket = ref 0 and depth_brace = ref 0 in
    (* Collect raw tokens up to (not including) the depth-0 closer. *)
    let continue_ = ref true in
    while !continue_ && not (at_eof p) do
      let k = kind p in
      let at_close =
        !depth_paren = 0 && !depth_bracket = 0 && !depth_brace = 0 && k = close
      in
      if at_close then continue_ := false
      else begin
        (match k with
         | Token.LParen -> incr depth_paren
         | Token.RParen -> if !depth_paren > 0 then decr depth_paren
         | Token.LBracket -> incr depth_bracket
         | Token.RBracket -> if !depth_bracket > 0 then decr depth_bracket
         | Token.LBrace -> incr depth_brace
         | Token.RBrace -> if !depth_brace > 0 then decr depth_brace
         | _ -> ());
        ignore (advance p)
      end
    done;
    let text = src_text p (span_end p start) in
    [ Ast.MacroTokens (text, span_end p start) ]
  end
  else begin
    let args = ref [] in
    while not (at p close) && not (at_eof p) do
      args := Ast.MacroExpr (parse_expr p) :: !args;
      if not (at p close) then begin
        if not (eat p Token.Comma) then ignore (eat p Token.Semi)
      end
    done;
    List.rev !args
  end

and top_level_opaque_macro_syntax (p : parser) (close : Token.kind) : bool =
  let n = Array.length p.tokens in
  let rec scan idx paren bracket brace =
    if idx >= n then false
    else
      match (peek_at p (idx - p.pos)).Token.kind with
      | Token.LParen -> scan (idx + 1) (paren + 1) bracket brace
      | Token.RParen ->
          if paren = 0 && bracket = 0 && brace = 0 && close = Token.RParen then false
          else scan (idx + 1) (max 0 (paren - 1)) bracket brace
      | Token.LBracket -> scan (idx + 1) paren (bracket + 1) brace
      | Token.RBracket ->
          if bracket = 0 && paren = 0 && brace = 0 && close = Token.RBracket then false
          else scan (idx + 1) paren (max 0 (bracket - 1)) brace
      | Token.LBrace -> scan (idx + 1) paren bracket (brace + 1)
      | Token.RBrace -> scan (idx + 1) paren bracket (max 0 (brace - 1))
      | Token.Colon | Token.ColonColon ->
          if paren = 0 && bracket = 0 && brace = 0 then true
          else scan (idx + 1) paren bracket brace
      | _ -> scan (idx + 1) paren bracket brace
  in
  scan p.pos 0 0 0

and parse_optional_expr_type_args (p : parser) (preceding : string option) : Ast.type_expr list =
  if not (looks_like_expr_type_args p preceding) then []
  else parse_optional_type_args p

and looks_like_expr_type_args (p : parser) (preceding : string option) : bool =
  if not (at p Token.LBracket) then false
  else begin
    let n = Array.length p.tokens in
    let rec scan idx depth =
      if idx >= n then false
      else
        match (peek_at p (idx - p.pos)).Token.kind with
        | Token.LBracket -> scan (idx + 1) (depth + 1)
        | Token.RBracket ->
            if depth = 1 then begin
              match kind_at p (idx - p.pos + 1) with
              | Token.Dot -> (
                  match preceding with
                  | Some name ->
                      if String.length name = 0 then true
                      else
                        let c = name.[0] in
                        not ((c >= 'a' && c <= 'z') || c = '_')
                  | None -> true)
              | Token.LParen | Token.LBrace | Token.ColonColon -> true
              | _ -> false
            end
            else scan (idx + 1) (depth - 1)
        | Token.Eof -> false
        | k when depth > 0 && is_definitely_expr_only_token k -> false
        | _ -> scan (idx + 1) depth
    in
    scan p.pos 0
  end

and is_definitely_expr_only_token (k : Token.kind) : bool =
  match k with
  | Token.Plus | Token.Minus | Token.Slash | Token.Percent | Token.PlusEq
  | Token.MinusEq | Token.SlashEq | Token.PercentEq | Token.Eq | Token.EqEq
  | Token.BangEq | Token.Dot | Token.DotDot | Token.DotDotEq | Token.AmpAmp
  | Token.PipePipe | Token.Caret | Token.KwIn | Token.KwAs | Token.KwTrue
  | Token.KwFalse | Token.String _ | Token.Char _ | Token.Float _ -> true
  | Token.Integer _ -> true
  | _ -> false

and looks_like_map_literal (p : parser) : bool =
  if not (at p Token.LBrace) then false
  else begin
    let n = Array.length p.tokens in
    let rec scan idx depth =
      if idx >= n then false
      else
        match (peek_at p (idx - p.pos)).Token.kind with
        | Token.LBrace | Token.LBracket | Token.LParen -> scan (idx + 1) (depth + 1)
        | Token.RBrace | Token.RBracket | Token.RParen ->
            if depth = 0 then false else scan (idx + 1) (depth - 1)
        | Token.Colon | Token.FatArrow -> if depth = 0 then true else scan (idx + 1) depth
        | Token.KwEnd | Token.KwWhen | Token.KwElse | Token.KwElsif | Token.Semi
        | Token.Eof ->
            false
        | _ -> scan (idx + 1) depth
    in
    scan (p.pos + 1) 0
  end

and is_struct_literal_context (p : parser) : bool =
  if not (at p Token.LBrace) then false
  else begin
    match kind_at p 1 with
    | Token.RBrace -> true
    | Token.Ident _ when kind_at p 2 = Token.Colon -> true
    | Token.Ident _ when kind_at p 2 = Token.Comma -> true
    | Token.Ident _ when kind_at p 2 = Token.RBrace -> true
    | Token.DotDot -> true
    | _ ->
        (* soft keywords as field names *)
        (match soft_ident_kind (kind_at p 1) with
         | Some _ when kind_at p 2 = Token.Colon -> true
         | Some _ when kind_at p 2 = Token.Comma -> true
         | Some _ when kind_at p 2 = Token.RBrace -> true
         | _ -> false)
  end

and looks_like_end_struct_literal (p : parser) (name : string) : bool =
  if not (is_uppercase_initial name) then false
  else if at_ident p && kind_at p 1 = Token.Colon then true
  else
    match soft_ident_kind (kind p) with
    | Some _ when kind_at p 1 = Token.Colon -> true
    | _ -> false

and parse_struct_literal (p : parser) (name : string) (targs : Ast.type_expr list) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let fields = ref [] in
  let rest = ref None in
  while not (at p Token.RBrace) && not (at_kw_end_as_terminator p) && not (at_eof p) do
    if eat p Token.DotDot then begin
      rest := Some (parse_expr p);
      ignore (eat p Token.Comma)
    end
    else begin
      let fstart = cur_span p in
      let fname = expect_ident p in
      if eat p Token.Colon then begin
        let value = parse_expr p in
        fields := (fname, value) :: !fields
      end
      else fields := (fname, Ast.Name (fname, fstart)) :: !fields;
      if not (at p Token.RBrace) && not (at_kw_end_as_terminator p) then ignore (eat p Token.Comma)
    end
  done;
  if at p Token.KwEnd then ignore (advance p)
  else expect p Token.RBrace "'}' in struct literal";
  Ast.StructLit (name, targs, List.rev !fields, !rest, span_end p start)

and parse_end_struct_literal (p : parser) (name : string) (targs : Ast.type_expr list) (start : Span.span) : Ast.expr =
  let fields = ref [] in
  while not (at_kw_end_as_terminator p) && not (at_eof p) do
    let fname = expect_ident p in
    expect p Token.Colon "':' in struct literal field";
    let value = parse_expr p in
    fields := (fname, value) :: !fields
  done;
  expect p Token.KwEnd "'end' in struct literal";
  Ast.StructLit (name, targs, List.rev !fields, None, span_end p start)

and parse_map_literal (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let entries = ref [] in
  while not (at p Token.RBrace) && not (at_eof p) do
    let key = parse_expr p in
    let value =
      if eat p Token.Colon || eat p Token.FatArrow then parse_expr p
      else key
    in
    let entry_span = span_merged p (Ast.expr_span key) (Ast.expr_span value) in
    entries := Ast.Tuple ([ key; value ], entry_span) :: !entries;
    if not (at p Token.RBrace) then ignore (eat p Token.Comma)
  done;
  expect p Token.RBrace "'}' in map literal";
  Ast.Array (List.rev !entries, span_end p start)

and parse_brace_closure (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  ignore (advance p);
  let params = parse_closure_params p in
  expect p Token.Pipe "'|' in closure";
  let body = parse_expr p in
  expect p Token.RBrace "'}' in closure";
  Ast.Closure
    {
      Ast.cl_params = params;
      cl_return = None;
      cl_body = body;
      cl_span = span_end p start;
    }

and parse_closure_params (p : parser) : Ast.closure_param list =
  let params = ref [] in
  while not (at p Token.Pipe) && not (at_eof p) do
    let pstart = cur_span p in
    if at p Token.LParen then begin
      (* grouped params: |(a, b)| *)
      ignore (advance p);
      while not (at p Token.RParen) && not (at_eof p) do
        let inner_start = cur_span p in
        let is_mut = eat p Token.KwMut in
        if at p Token.Amp then begin
          ignore (advance p);
          ignore (eat p Token.KwMut)
        end;
        let name = expect_ident p in
        let ptype = if eat p Token.Colon then Some (parse_type p) else None in
        params :=
          { Ast.cp_name = name; cp_mutable = is_mut; cp_type = ptype; cp_span = span_merged p inner_start (cur_span p) }
          :: !params;
        if not (at p Token.RParen) then ignore (eat p Token.Comma)
      done;
      expect p Token.RParen "')' in closure parameters";
      if not (at p Token.Pipe) then ignore (eat p Token.Comma)
    end
    else begin
      let is_mut = eat p Token.KwMut in
      if at p Token.Amp then begin
        ignore (advance p);
        ignore (eat p Token.KwMut)
      end;
      let name = expect_ident p in
      let ptype = if eat p Token.Colon then Some (parse_type p) else None in
      params :=
        { Ast.cp_name = name; cp_mutable = is_mut; cp_type = ptype; cp_span = span_merged p pstart (cur_span p) }
        :: !params;
      if not (at p Token.Pipe) then ignore (eat p Token.Comma)
    end
  done;
  List.rev !params

and parse_pipe_closure (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let params = parse_closure_params p in
  expect p Token.Pipe "'|' in closure";
  let ret = if eat p Token.Arrow then Some (parse_type p) else None in
  let body = parse_expr p in
  Ast.Closure
    {
      Ast.cl_params = params;
      cl_return = ret;
      cl_body = body;
      cl_span = span_end p start;
    }

and parse_if_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let let_pat = ref None in
  let let_val = ref None in
  if eat p Token.KwLet then begin
    let_pat := Some (parse_pattern p);
    expect p Token.Eq "'=' in if-let";
    let_val := Some (parse_expr p)
  end;
  let cond =
    match !let_val with
    | Some e -> e
    | None -> parse_expr p
  in
  ignore (eat p Token.KwThen);
  let then_block = parse_block_body p [ Token.KwElsif; Token.KwElse; Token.KwEnd ] in
  let elsif = ref [] in
  let else_block = ref None in
  let inline_else_if () =
    at p Token.KwElse && kind_at p 1 = Token.KwIf
    && not (source_has_newline p (cur_span p) (peek_at p 1).Token.span)
  in
  let rec elsif_loop () =
    if at p Token.KwElsif then begin
      ignore (advance p);
      let econd = parse_expr p in
      ignore (eat p Token.KwThen);
      let ebody = parse_block_body p [ Token.KwElsif; Token.KwElse; Token.KwEnd ] in
      elsif := (econd, ebody) :: !elsif;
      elsif_loop ()
    end
    else if inline_else_if () then begin
      ignore (advance p);
      ignore (advance p);
      let econd = parse_expr p in
      ignore (eat p Token.KwThen);
      let ebody = parse_block_body p [ Token.KwElsif; Token.KwElse; Token.KwEnd ] in
      elsif := (econd, ebody) :: !elsif;
      elsif_loop ()
    end
  in
  elsif_loop ();
  if at p Token.KwElse then begin
    let else_span = cur_span p in
    ignore (advance p);
    (* Value-position short-form else: a single-expression branch when the
       following statement sits at a SHALLOWER column than the branch's own
       first statement (the reference's else heuristic). *)
    if at_eof p || at_kw_end_as_terminator p then ()
    else if is_expr_start p then begin
      let first_col = column_of p (cur_span p).Span.start in
      let s = parse_stmt p [ Token.KwEnd ] in
      (* `;` after the first else expression means the branch continues on
         the same line (else expr; expr) — the if's `end` closes the whole
         construct, so the single-branch determination excludes `;`. *)
      let single =
        at_eof p || at_kw_end_as_terminator p
        || at p Token.RParen || at p Token.RBracket || at p Token.Comma
        || at p Token.RBrace
        || ((is_expr_start p || at p Token.KwMut || at p Token.KwLet)
           && column_of p (cur_span p).Span.start < first_col)
      in
      if single then begin
        let tail =
          match s with
          | Ast.ExprStmt (e, _) -> Some e
          | _ -> None
        in
        else_block :=
          Some
            {
              Ast.b_stmts = [];
              b_tail = tail;
              b_span = span_merged p else_span (cur_span p);
            }
      end
      else begin
        (* multi-statement else block *)
        let stmts = ref [ s ] in
        let tail = ref None in
        let cont = ref true in
        while !cont do
          if at_eof p || at_kw_end_as_terminator p then cont := false
          else if at p Token.Semi then ignore (advance p)
          else begin
            let s2 = parse_stmt p [ Token.KwEnd ] in
            if at_kw_end_as_terminator p then begin
              match s2 with
              | Ast.ExprStmt (e, _) -> tail := Some e
              | _ -> stmts := s2 :: !stmts
            end
            else stmts := s2 :: !stmts
          end
        done;
        else_block :=
          Some
            {
              Ast.b_stmts = List.rev !stmts;
              b_tail = !tail;
              b_span = span_merged p else_span (cur_span p);
            }
      end
    end
    else else_block := Some (parse_block_body p [ Token.KwEnd ])
  end;
  ignore (eat p Token.KwEnd);
  Ast.IfExpr
    {
      Ast.if_condition = cond;
      if_then = then_block;
      if_elsif = List.rev !elsif;
      if_else = !else_block;
      if_let_pattern = !let_pat;
      if_let_value = !let_val;
      if_span = span_merged p start (cur_span p);
    }

and parse_unless_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let cond = parse_expr p in
  ignore (eat p Token.KwThen);
  let body = parse_block_body p [ Token.KwElse; Token.KwEnd ] in
  let else_block =
    if at p Token.KwElse then begin
      ignore (advance p);
      Some (parse_block_body p [ Token.KwEnd ])
    end
    else None
  in
  ignore (eat p Token.KwEnd);
  Ast.UnlessExpr
    {
      Ast.un_condition = cond;
      un_body = body;
      un_else = else_block;
      un_span = span_end p start;
    }

and parse_match_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let subject = parse_expr p in
  let subj_sp = Ast.expr_span subject in
  let line = column_of p subj_sp.Span.start in
  ignore line;
  let arms = ref [] in
  let brace_style = at p Token.LBrace in
  if brace_style then begin
    ignore (advance p);
    while not (at p Token.RBrace) && not (at_eof p) do
      if at p Token.KwWhen then ignore (advance p);
      let pat = parse_pattern p in
      let guard = if eat p Token.KwIf then Some (parse_expr p) else None in
      let body =
        if eat p Token.FatArrow then parse_expr p
        else begin
          ignore (eat p Token.KwThen);
          parse_expr p
        end
      in
      arms :=
        { Ast.ma_pattern = pat; ma_guard = guard; ma_body = body; ma_span = span_end p start }
        :: !arms;
      if not (at p Token.RBrace) then ignore (eat p Token.Comma)
    done;
    expect p Token.RBrace "'}' in match expression"
  end
  else begin
    let pushed = ref false in
    let per_arm_end () =
      if not (at p Token.KwEnd) then false
      else if kind_at p 1 <> Token.KwWhen then false
      else begin
        let end_col = column_of p (cur_span p).Span.start in
        let next_when_col = column_of p (peek_at p 1).Token.span.Span.start in
        if next_when_col < end_col then false
        else begin
          (* The nested-match pattern: the inner `end` sits at the inner
             arms' column and the following `when` continues the enclosing
             match's arms (at the enclosing arm column). *)
          match p.match_arm_cols with
          | _ :: enclosing :: _ -> next_when_col <> enclosing
          | _ -> true
        end
      end
    in
    while
      (at p Token.KwWhen || at p Token.Semi || at p Token.KwElse
      || looks_like_arrow_arm_start p)
      && not (at_eof p)
    do
      let arm_start = cur_span p in
      if not !pushed then begin
        p.match_arm_cols <- column_of p arm_start.Span.start :: p.match_arm_cols;
        pushed := true
      end;
      let used_when = eat p Token.KwWhen in
      let from_else = at p Token.KwElse in
      let pat =
        if from_else then begin
          ignore (advance p);
          Ast.Wildcard (Span.synthetic)
        end
        else parse_pattern p
      in
      let guard = if eat p Token.KwIf then Some (parse_expr p) else None in
      let used_fat_arrow =
        if eat p Token.FatArrow then true
        else if used_when && at p Token.Eq then begin
          ignore (advance p);
          ignore (eat p Token.RBracket);
          true
        end
        else begin
          ignore (eat p Token.KwThen);
          false
        end
      in
      ignore used_fat_arrow;
      let body = parse_match_arm_body p arm_start in
      arms :=
        { Ast.ma_pattern = pat; ma_guard = guard; ma_body = body; ma_span = span_merged p arm_start (cur_span p) }
        :: !arms;
      (* Per-arm `end` (arm-terminated match style): `when P then ... end`
         followed by the next `when` — the `end` closes the arm's block
         body rather than the whole match. *)
      if per_arm_end () then ignore (advance p)
    done;
    if !pushed then p.match_arm_cols <- List.tl p.match_arm_cols;
    expect p Token.KwEnd "'end' in match expression"
  end;
  Ast.MatchExpr
    {
      Ast.m_subject = subject;
      m_arms = List.rev !arms;
      m_span = span_end p start;
    }

(* Arm body: a single expression, or a block when statements follow.
   Mirrors the reference parser's multi-expression arm wrapping. *)
and parse_match_arm_body (p : parser) (arm_start : Span.span) : Ast.expr =
  let at_arm_terminator () =
    at p Token.KwWhen || at_kw_end_as_terminator p || at p Token.KwElse || at_eof p
  in
  if at_arm_terminator () then Ast.Tuple ([], arm_start)
  else if at p Token.KwLet || at p Token.KwMut || at p Token.At then begin
    let block = parse_block_body p [ Token.KwWhen; Token.KwElse; Token.KwEnd ] in
    Ast.Block (block, span_merged p arm_start (cur_span p))
  end
  else begin
    let expr0 = parse_expr p in
    let expr =
      match kind p with
      | Token.Eq ->
          let start = cur_span p in
          ignore (advance p);
          let v = parse_expr p in
          Ast.Assign (expr0, v, span_end p start)
      | Token.PlusEq | Token.MinusEq | Token.StarEq | Token.SlashEq | Token.PercentEq ->
          let start = cur_span p in
          let op =
            match kind p with
            | Token.PlusEq -> Ast.Add
            | Token.MinusEq -> Ast.Sub
            | Token.StarEq -> Ast.Mul
            | Token.SlashEq -> Ast.Div
            | _ -> Ast.Mod
          in
          ignore (advance p);
          let v = parse_expr p in
          Ast.CompoundAssign (expr0, op, v, span_end p start)
      | _ -> expr0
    in
    while eat p Token.Semi do () done;
    let more =
      at p Token.KwLet || at p Token.KwMut || at p Token.At
      || (is_expr_start p && not (at_arm_terminator ()) && not (looks_like_arrow_arm_start p))
    in
    if not more then expr
    else begin
      let stmts = ref [ Ast.ExprStmt (expr, Ast.expr_span expr) ] in
      let tail = ref None in
      let rec loop () =
        if at_arm_terminator () || looks_like_arrow_arm_start p || at_eof p then ()
        else if eat p Token.Semi then loop ()
        else begin
          let s = parse_stmt p [ Token.KwWhen; Token.KwElse; Token.KwEnd ] in
          if at_arm_terminator () then begin
            match s with
            | Ast.ExprStmt (e, _) -> tail := Some e
            | _ -> stmts := s :: !stmts
          end
          else stmts := s :: !stmts;
          loop ()
        end
      in
      loop ();
      let block =
        {
          Ast.b_stmts = List.rev !stmts;
          b_tail = !tail;
          b_span = span_merged p arm_start (cur_span p);
        }
      in
      Ast.Block (block, span_merged p arm_start (cur_span p))
    end
  end

and looks_like_arrow_arm_start (p : parser) : bool =
  (is_expr_start p && (kind_at p 1 = Token.FatArrow))
  || (is_expr_start p && kind_at p 1 = Token.Eq && kind_at p 2 = Token.RBracket)

and parse_for_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let pat = parse_pattern p in
  expect p Token.KwIn "'in' in for loop";
  let iterable = parse_expr p in
  ignore (eat p Token.KwDo);
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in for loop";
  Ast.ForExpr
    {
      Ast.for_pattern = pat;
      for_iterable = iterable;
      for_body = body;
      for_span = span_end p start;
    }

and parse_while_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let cond = parse_expr p in
  ignore (eat p Token.KwDo);
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in while loop";
  Ast.WhileExpr
    {
      Ast.wh_condition = cond;
      wh_body = body;
      wh_span = span_end p start;
    }

and parse_until_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let cond = parse_expr p in
  ignore (eat p Token.KwDo);
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in until loop";
  Ast.UntilExpr
    {
      Ast.ut_condition = cond;
      ut_body = body;
      ut_span = span_end p start;
    }

and parse_loop_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  ignore (eat p Token.KwDo);
  let body = parse_block_body p [ Token.KwEnd ] in
  expect p Token.KwEnd "'end' in loop";
  Ast.LoopExpr (body, span_end p start)

and parse_try_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let body = parse_block_body p [ Token.KwCatch; Token.KwFinally; Token.KwEnd ] in
  let catches = ref [] in
  while at p Token.KwCatch do
    ignore (advance p);
    let pat = parse_pattern p in
    let cbody = parse_block_body p [ Token.KwCatch; Token.KwFinally; Token.KwEnd ] in
    catches := (pat, cbody) :: !catches
  done;
  let finally =
    if at p Token.KwFinally then begin
      ignore (advance p);
      Some (parse_block_body p [ Token.KwEnd ])
    end
    else None
  in
  ignore (eat p Token.KwEnd);
  Ast.TryBlock
    {
      Ast.tr_body = body;
      tr_catches = List.rev !catches;
      tr_finally = finally;
      tr_span = span_end p start;
    }

and parse_handle_expr (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let e = parse_expr p in
  let effect_name = ref "" in
  let arms = ref [] in
  if eat p Token.KwWith then effect_name := expect_ident p;
  while not (at p Token.KwEnd) && not (at_eof p) do
    let op = expect_ident p in
    let params = ref [] in
    if eat p Token.LParen then begin
      while not (at p Token.RParen) && not (at_eof p) do
        params := Ast.PatIdent (expect_ident p, false, cur_span p) :: !params;
        if not (eat p Token.Comma) then ()
      done;
      expect p Token.RParen "')' in handle operation"
    end;
    let body =
      if eat p Token.FatArrow then parse_expr p
      else block_to_expr (parse_block_body p [ Token.KwEnd ])
    in
    arms := (op, List.rev !params, body) :: !arms
  done;
  ignore (eat p Token.KwEnd);
  Ast.HandleExpr
    {
      Ast.h_expr = e;
      h_effect_name = !effect_name;
      h_arms = List.rev !arms;
      h_span = span_end p start;
    }

and parse_unsafe_block (p : parser) (start : Span.span) : Ast.expr =
  ignore (advance p);
  let reason =
    match kind p with
    | Token.String s -> ignore (advance p); s
    | _ -> ""
  in
  let body =
    if eat p Token.KwDo then begin
      let b = parse_block_body p [ Token.KwEnd ] in
      expect p Token.KwEnd "'end' in unsafe block";
      b
    end
    else if at p Token.LBrace then begin
      ignore (advance p);
      let b = parse_block_body p [ Token.RBrace ] in
      expect p Token.RBrace "'}' in unsafe block";
      b
    end
    else parse_block_body p [ Token.KwEnd ]
  in
  Ast.UnsafeBlock (reason, body, span_end p start)

(* ────────────────────────────────────────────────────────────────
   Patterns *)

and parse_pattern (p : parser) : Ast.pattern =
  let first = parse_single_pattern p in
  if at p Token.Pipe && kind_at p 1 <> Token.Pipe then begin
    let left = ref first in
    while at p Token.Pipe && kind_at p 1 <> Token.Pipe do
      let start = cur_span p in
      ignore (advance p);
      let right = parse_single_pattern p in
      left := Ast.OrPattern (!left, right, span_end p start)
    done;
    !left
  end
  else first

and parse_single_pattern (p : parser) : Ast.pattern =
  let start = cur_span p in
  match kind p with
  | Token.Ident i0 when i0.Token.spelling = "_" ->
      ignore (advance p);
      Ast.Wildcard (span_end p start)
  | Token.Ident i when i.Token.spelling = "ref" ->
      err p "E106" "ref patterns are not supported; bind by value" (cur_span p);
      ignore (advance p);
      let name = expect_ident p in
      Ast.RefPattern (name, span_end p start)
  | Token.Ident i when i.Token.spelling = "mut" -> (
      (* handled below as KwMut; unreachable *)
      ignore i;
      ignore (advance p);
      let name = expect_ident p in
      Ast.PatIdent (name, true, span_end p start))
  | Token.KwMut ->
      ignore (advance p);
      let name = expect_ident p in
      Ast.PatIdent (name, true, span_end p start)
  | Token.Amp ->
      let amp_span = cur_span p in
      ignore (advance p);
      let _ = eat p Token.KwMut in
      err p "E106" "ref patterns are not supported; bind by value" amp_span;
      let name = expect_ident p in
      Ast.RefMutPattern (name, span_end p start)
  | Token.Ident _ | Token.KwSuper | Token.KwCrate | Token.KwSelfTy -> (
      if at_ident p && kind_at p 1 = Token.ColonColon then begin
        let seg1 = expect_ident p in
        ignore (advance p);
        let seg2 = expect_ident p in
        let fields = ref [] in
        if eat p Token.LParen then begin
          while not (at p Token.RParen) && not (at_eof p) do
            fields := parse_pattern p :: !fields;
            if not (eat p Token.Comma) then ()
          done;
          expect p Token.RParen "')' in variant pattern";
          Ast.PatVariant (seg1, seg2, List.rev !fields, span_end p start)
        end
        else if at p Token.LBrace then begin
          (* qualified struct pattern: a::B { f: pat, g } *)
          ignore (advance p);
          let sfields = ref [] in
          while not (at p Token.RBrace) && not (at_kw_end_as_terminator p) && not (at_eof p) do
            if at p Token.DotDot then begin
              ignore (advance p);
              if not (at p Token.RBrace) then ignore (eat p Token.Comma)
            end
            else begin
              let fname = expect_ident p in
              let sub = if eat p Token.Colon then Some (parse_pattern p) else None in
              sfields := (fname, sub) :: !sfields;
              if not (at p Token.RBrace) && not (at_kw_end_as_terminator p) then
                ignore (eat p Token.Comma)
            end
          done;
          if at p Token.KwEnd then ignore (advance p)
          else expect p Token.RBrace "'}' in struct pattern";
          Ast.StructPattern (seg1 ^ "::" ^ seg2, List.rev !sfields, span_end p start)
        end
        else Ast.PatVariant (seg1, seg2, List.rev !fields, span_end p start)
      end
      else begin
        let name = expect_ident p in
        if at p Token.LParen then begin
          ignore (advance p);
          let fields = ref [] in
          while not (at p Token.RParen) && not (at_eof p) do
            fields := parse_pattern p :: !fields;
            if not (eat p Token.Comma) then ()
          done;
          expect p Token.RParen "')' in variant pattern";
          Ast.PatVariant ("", name, List.rev !fields, span_end p start)
        end
        else if at p Token.LBrace then begin
          ignore (advance p);
          let fields = ref [] in
          while not (at p Token.RBrace) && not (at_kw_end_as_terminator p) && not (at_eof p) do
            if at p Token.DotDot then begin
              ignore (advance p);
              if not (at p Token.RBrace) then ignore (eat p Token.Comma)
            end
            else begin
              let fname = expect_ident p in
              let sub = if eat p Token.Colon then Some (parse_pattern p) else None in
              fields := (fname, sub) :: !fields;
              if not (at p Token.RBrace) && not (at_kw_end_as_terminator p) then ignore (eat p Token.Comma)
            end
          done;
          if at p Token.KwEnd then ignore (advance p)
          else expect p Token.RBrace "'}' in struct pattern";
          Ast.StructPattern (name, List.rev !fields, span_end p start)
        end
        else Ast.PatIdent (name, false, span_end p start)
      end)
  | Token.Integer lit ->
      ignore (advance p);
      if at p Token.DotDot || at p Token.DotDotEq then begin
        ignore (advance p);
        (match kind p with
         | Token.Integer hi ->
             ignore (advance p);
             Ast.RangePattern
               (Ast.PatLiteral (Ast.IntLit (lit, start), start),
                Ast.PatLiteral (Ast.IntLit (hi, span_end p start), span_end p start),
                span_end p start)
         | Token.Char hi ->
             ignore (advance p);
             Ast.RangePattern
               (Ast.PatLiteral (Ast.IntLit (lit, start), start),
                Ast.PatLiteral (Ast.CharLit (hi, span_end p start), span_end p start),
                span_end p start)
         | _ ->
             Ast.RangePattern
               (Ast.PatLiteral (Ast.IntLit (lit, start), start),
                Ast.Wildcard (Span.synthetic), span_end p start))
      end
      else Ast.PatLiteral (Ast.IntLit (lit, span_end p start), span_end p start)
  | Token.Float lit ->
      ignore (advance p);
      Ast.PatLiteral (Ast.FloatLit (lit, span_end p start), span_end p start)
  | Token.String s ->
      ignore (advance p);
      Ast.PatLiteral (Ast.StringLit (s, span_end p start), span_end p start)
  | Token.Char c ->
      ignore (advance p);
      if at p Token.DotDot || at p Token.DotDotEq then begin
        ignore (advance p);
        match kind p with
        | Token.Char hi ->
            ignore (advance p);
            Ast.RangePattern
              (Ast.PatLiteral (Ast.CharLit (c, start), start),
               Ast.PatLiteral (Ast.CharLit (hi, span_end p start), span_end p start),
               span_end p start)
        | _ ->
            Ast.PatLiteral (Ast.CharLit (c, span_end p start), span_end p start)
      end
      else Ast.PatLiteral (Ast.CharLit (c, span_end p start), span_end p start)
  | Token.KwTrue | Token.KwFalse ->
      let b = at p Token.KwTrue in
      ignore (advance p);
      Ast.PatLiteral (Ast.BoolLit (b, span_end p start), span_end p start)
  | Token.KwSelfValue ->
      ignore (advance p);
      Ast.PatIdent ("self", false, span_end p start)
  | Token.LParen ->
      ignore (advance p);
      if at p Token.RParen then begin
        ignore (advance p);
        Ast.PatTuple ([], span_end p start)
      end
      else begin
        let first = parse_pattern p in
        if at p Token.Comma then begin
          let pats = ref [ first ] in
          while eat p Token.Comma do
            if at p Token.RParen then ()
            else pats := parse_pattern p :: !pats
          done;
          expect p Token.RParen "')' in tuple pattern";
          Ast.PatTuple (List.rev !pats, span_end p start)
        end
        else begin
          expect p Token.RParen "')' in pattern";
          first
        end
      end
  | Token.LBracket ->
      ignore (advance p);
      let pats = ref [] in
      while not (at p Token.RBracket) && not (at_eof p) do
        pats := parse_pattern p :: !pats;
        if not (eat p Token.Comma) then ()
      done;
      expect p Token.RBracket "']' in array pattern";
      Ast.PatTuple (List.rev !pats, span_end p start)
  | _ -> (
      (* Soft keywords usable as pattern bindings (e.g. `let next = ...`) *)
      match soft_ident_kind (kind p) with
      | Some name ->
          ignore (advance p);
          Ast.PatIdent (name, false, span_end p start)
      | None ->
          expected p "pattern";
          ignore (advance p);
          Ast.Wildcard (span_end p start))

(* ── Item dispatch ────────────────────────────────────────────── *)

and parse_item (p : parser) : Ast.item option =
  let attrs = parse_attributes p in
  parse_item_with_attrs p attrs

and parse_item_with_attrs (p : parser) (attrs : Ast.attribute list) : Ast.item option =
    let (_, is_pub) = parse_vis p in
  let start = cur_span p in
  match kind p with
  | Token.KwDef | Token.KwFn | Token.KwAsync | Token.KwUnsafe | Token.KwPure
  | Token.KwInline -> (
      match parse_function p attrs ((), is_pub) is_pub with
      | Some kind -> (
          Some (item_of p attrs ((), is_pub) kind start))
      | None -> None)
  | Token.KwTest -> Some (item_of p attrs ((), is_pub) (parse_test_decl p) start)
  | Token.KwStruct | Token.KwResource ->
      Some (item_of p attrs ((), is_pub) (parse_struct_decl p (kind p = Token.KwResource)) start)
  | Token.KwEnum -> Some (item_of p attrs ((), is_pub) (parse_enum_decl p) start)
  | Token.KwTrait -> Some (item_of p attrs ((), is_pub) (parse_trait_decl p) start)
  | Token.KwImpl -> Some (item_of p attrs ((), is_pub) (parse_impl_decl p) start)
  | Token.KwUse -> Some (item_of p attrs ((), is_pub) (parse_use_decl p) start)
  | Token.KwConst -> Some (item_of p attrs ((), is_pub) (parse_const_decl p false) start)
  | Token.KwStatic -> Some (item_of p attrs ((), is_pub) (parse_static_decl p) start)
  | Token.KwLet -> Some (item_of p attrs ((), is_pub) (parse_const_decl p true) start)
  | Token.KwMut -> Some (item_of p attrs ((), is_pub) (parse_mut_static_decl p) start)
  | Token.KwType | Token.KwTypealias -> Some (item_of p attrs ((), is_pub) (parse_type_alias_decl p) start)
  | Token.KwExtern -> Some (item_of p attrs ((), is_pub) (parse_extern_item p) start)
  | Token.KwModule | Token.KwMod -> Some (item_of p attrs ((), is_pub) (parse_module_decl p) start)
  | Token.KwCap -> Some (item_of p attrs ((), is_pub) (parse_capability_decl p) start)
  | Token.KwEffect -> Some (item_of p attrs ((), is_pub) (parse_effect_decl p) start)
  | Token.KwRationale -> Some (item_of p attrs ((), is_pub) (parse_rationale_decl p) start)
  | Token.KwMacro -> Some (item_of p attrs ((), is_pub) (parse_macro_decl p) start)
  | Token.KwEdition -> Some (item_of p attrs ((), is_pub) (parse_edition_decl p) start)
  | _ -> None

and parse_mut_static_decl (p : parser) : Ast.item_kind =
  let start = cur_span p in
  ignore (advance p);
  let name = expect_ident p in
  expect p Token.Colon "':' in static declaration";
  let ty = parse_type p in
  expect p Token.Eq "'=' in static declaration";
  let value = parse_expr p in
  Ast.StaticDecl
    {
      Ast.st_name = name;
      st_public = false;
      st_mutable = true;
      st_type = ty;
      st_value = value;
      st_span = span_end p start;
    }

and is_expr_start (p : parser) : bool =
  match kind p with
  | Token.Integer _ | Token.Float _ | Token.String _ | Token.Char _ | Token.KwTrue
  | Token.KwFalse | Token.KwSelfValue | Token.KwIf | Token.KwMatch | Token.KwWhile
  | Token.KwFor | Token.KwLoop | Token.KwReturn | Token.KwBreak | Token.KwNext
  | Token.KwUnsafe | Token.KwDefer | Token.KwTry | Token.KwHandle | Token.KwUnless
  | Token.KwUntil | Token.KwComptime | Token.KwAsync | Token.LParen | Token.LBracket
  | Token.LBrace | Token.Pipe | Token.KwDo | Token.KwSelfTy | Token.Minus | Token.Bang
  | Token.Tilde | Token.Amp | Token.Star | Token.KwAwait ->
      true
  | Token.Ident _ | Token.KwSuper | Token.KwCrate -> true
  | _ -> false

(* ── Entry ────────────────────────────────────────────────────── *)

let parse (tokens : Token.t list) source file_id diags module_path : Ast.program =
  let p = make (Array.of_list tokens) source file_id diags in
  parse_program p module_path
