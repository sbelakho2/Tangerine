type kind =
  | Ident of string
  | Int of int
  | Int64 of int64
  | Float of string
  | String of string
  | Char of string
  | True
  | False
  | Nil
  | Def
  | End
  | Let
  | Mut
  | Return
  | Break
  | Next
  | If
  | Else
  | Elsif
  | Unless
  | Match
  | When
  | Then
  | Do
  | Loop
  | While
  | For
  | In
  | Until
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
  | Self_
  | SelfType
  | Super
  | Crate
  (* Memory safety *)
  | TkMove
  | TkCopy
  | TkDrop
  | TkOwn
  | TkRef
  | TkRefMut
  (* Agentic features *)
  | Pre
  | Post
  | Invariant
  | Cap
  | Unsafe
  | Rationale
  | Budget
  | Edition
  | Requires
  | Ensures
  | Effect
  | Pure
  (* Modern features *)
  | Async
  | Await
  | Yield
  | Defer
  | Try
  | Catch
  | Finally
  | Guard
  | Handle
  | With
  | Implies
  | Comptime
  | Const
  | Static
  | Type
  | Alias
  | Extern
  | Inline
  (* Delimiters *)
  | LParen
  | RParen
  | LBracket
  | RBracket
  | LBrace
  | RBrace
  (* Punctuation *)
  | Comma
  | Dot
  | DotDot
  | DotDotEq
  | Colon
  | ColonColon
  | Semicolon
  | At
  | Hash
  (* Arrows *)
  | Arrow
  | FatArrow
  | PipeArrow
  (* Assignment *)
  | Eq
  | PlusEq
  | MinusEq
  | StarEq
  | SlashEq
  | PercentEq
  (* Comparison *)
  | EqEq
  | BangEq
  | Lt
  | Gt
  | LtEq
  | GtEq
  (* Logical *)
  | AndAnd
  | OrOr
  (* Bitwise *)
  | Amp
  | AmpMut
  | Pipe
  | Caret
  | Tilde
  | Shl
  | Shr
  | DoubleStar
  (* Unary *)
  | Bang
  | Question
  (* Arithmetic *)
  | Plus
  | Minus
  | Star
  | Slash
  | Percent
  (* Compound bitwise assignment *)
  | AmpEq
  | PipeEq
  | CaretEq
  | ShlEq
  | ShrEq
  (* Special *)
  | Newline
  | Eof
  | Error of string

let string_of_kind = function
  | Ident s -> "identifier(" ^ s ^ ")"
  | Int n -> "int(" ^ string_of_int n ^ ")"
  | Int64 n -> "int64(" ^ Int64.to_string n ^ ")"
  | Float s -> "float(" ^ s ^ ")"
  | String s -> "string(" ^ String.escaped s ^ ")"
  | Char ch -> "char(" ^ String.escaped ch ^ ")"
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
  | EqEq -> "=="
  | BangEq -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | LtEq -> "<="
  | GtEq -> ">="
  | AndAnd -> "&&"
  | OrOr -> "||"
  | Amp -> "&"
  | AmpMut -> "&mut"
  | Pipe -> "|"
  | Caret -> "^"
  | Tilde -> "~"
  | Shl -> "<<"
  | Shr -> ">>"
  | DoubleStar -> "**"
  | Bang -> "!"
  | Question -> "?"
  | Plus -> "+"
  | Minus -> "-"
  | Star -> "*"
  | Slash -> "/"
  | Percent -> "%"
  | AmpEq -> "&="
  | PipeEq -> "|="
  | CaretEq -> "^="
  | ShlEq -> "<<="
  | ShrEq -> ">>="
  | Newline -> "newline"
  | Eof -> "eof"
  | Error msg -> "error(" ^ msg ^ ")"

type t =
  { kind : kind
  ; line : int
  ; column : int
  }

let is_expr_start = function
  | Int _ | Int64 _ | Float _ | String _ | Char _ -> true
  | True | False | Nil | Self_ | Ident _ -> true
  | LParen | LBracket | LBrace -> true
  | Bang | Minus | Amp | AmpMut -> true
  | If | Unless | Match | Do | Try | Loop -> true
  | Await | Yield | TkMove | TkCopy | Comptime -> true
  | Handle | Unsafe | Pipe | OrOr | Star | Async -> true
  | _ -> false

let is_stmt_start kind =
  is_expr_start kind ||
  match kind with
  | Let | Mut | Return | Break | Next -> true
  | While | Until | For | Defer | Guard -> true
  | Const | Static | Type | At -> true
  | _ -> false

let is_item_start = function
  | Def | Struct | Enum | Trait | Impl -> true
  | Module | Use | Macro | Cap | Rationale -> true
  | Edition | Const | Static | Type | Extern -> true
  | Pub | Private | Async | Unsafe | Pure | Inline -> true
  | _ -> false