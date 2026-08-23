(* token.ml — Token kinds for the Tangerine lexer.

   The kind set mirrors the stage0 Swift front end exactly (the
   `lex` output contract and the differential token vocabulary depend on
   it), extended where the Edition-2026 grammar requires it. *)

type kind =
  (* Literals *)
  | Ident of string
  | Integer of string
  | Float of string
  | String of string
  | Char of string
  (* Trivia *)
  | Newline
  | Whitespace
  | Comment
  | DocComment of string
  (* Special *)
  | At
  (* Keywords *)
  | KwDef | KwEnd | KwIf | KwThen | KwElse | KwElsif | KwWhile | KwFor
  | KwIn | KwDo | KwLet | KwMut | KwReturn | KwBreak | KwNext | KwMatch
  | KwWhen | KwStruct | KwEnum | KwTrait | KwImpl | KwUse | KwPub | KwModule
  | KwMod | KwConst | KwStatic | KwType | KwExtern | KwWhere | KwAs | KwSuper
  | KwCrate | KwSelfValue | KwSelfTy | KwFn | KwTrue | KwFalse | KwUnsafe
  | KwAsync | KwAwait | KwCap | KwEffect | KwRequires | KwImplies | KwHandle
  | KwWith | KwRationale | KwBudget | KwPre | KwPost | KwInvariant | KwGuard
  | KwDefer | KwTry | KwCatch | KwFinally | KwMacro | KwComptime | KwLoop
  | KwPure | KwInline | KwUnless | KwUntil | KwEdition | KwTest | KwDyn
  | KwTypealias | KwInout | KwSink | KwSet | KwResource | KwDeinit
  (* Delimiters *)
  | LParen | RParen | LBracket | RBracket | LBrace | RBrace
  (* Operators & punctuation *)
  | ColonColon | Colon | Comma | Dot | DotDot | DotDotDot | DotDotEq | Semi
  | Arrow | FatArrow | EqEq | Bang | BangEq | Lt | LtEq | Gt | GtEq | Amp
  | AmpAmp | Pipe | PipePipe | Caret | Tilde | Dollar | Shl | Shr | Plus
  | Minus | Slash | Percent | Star | PlusEq | MinusEq | StarEq | SlashEq
  | PercentEq | CaretEq | AmpEq | PipeEq | ShlEq | ShrEq | Eq | Question
  (* Sentinel *)
  | Eof

type t = {
  kind : kind;
  span : Span.span;
}

let make kind span = { kind; span }

(* Keyword lookup; returns None for identifiers. Canonical spellings and
   aliases per grammar.md §1.3. *)
let keyword_of_string (text : string) : kind option =
  match text with
  | "def" -> Some KwDef
  | "fn" -> Some KwFn
  | "end" -> Some KwEnd
  | "if" -> Some KwIf
  | "then" -> Some KwThen
  | "else" -> Some KwElse
  | "elsif" -> Some KwElsif
  | "while" -> Some KwWhile
  | "for" -> Some KwFor
  | "in" -> Some KwIn
  | "do" -> Some KwDo
  | "let" -> Some KwLet
  | "mut" | "var" -> Some KwMut
  | "inout" -> Some KwInout
  | "sink" -> Some KwSink
  | "set" -> Some KwSet
  | "resource" -> Some KwResource
  | "deinit" -> Some KwDeinit
  | "return" -> Some KwReturn
  | "break" -> Some KwBreak
  | "next" | "continue" -> Some KwNext
  | "match" -> Some KwMatch
  | "when" -> Some KwWhen
  | "struct" -> Some KwStruct
  | "enum" -> Some KwEnum
  | "trait" -> Some KwTrait
  | "impl" -> Some KwImpl
  | "use" -> Some KwUse
  | "pub" -> Some KwPub
  | "module" -> Some KwModule
  | "mod" -> Some KwMod
  | "const" -> Some KwConst
  | "static" -> Some KwStatic
  | "type" -> Some KwType
  | "typealias" | "alias" -> Some KwTypealias
  | "extern" -> Some KwExtern
  | "where" -> Some KwWhere
  | "as" -> Some KwAs
  | "super" -> Some KwSuper
  | "crate" -> Some KwCrate
  | "self" -> Some KwSelfValue
  | "Self" -> Some KwSelfTy
  | "true" -> Some KwTrue
  | "false" -> Some KwFalse
  | "unsafe" -> Some KwUnsafe
  | "async" -> Some KwAsync
  | "await" -> Some KwAwait
  | "cap" -> Some KwCap
  | "effect" -> Some KwEffect
  | "requires" -> Some KwRequires
  | "implies" -> Some KwImplies
  | "handle" -> Some KwHandle
  | "with" -> Some KwWith
  | "rationale" -> Some KwRationale
  | "budget" -> Some KwBudget
  | "pre" -> Some KwPre
  | "post" -> Some KwPost
  | "invariant" -> Some KwInvariant
  | "guard" -> Some KwGuard
  | "defer" -> Some KwDefer
  | "try" -> Some KwTry
  | "catch" -> Some KwCatch
  | "finally" -> Some KwFinally
  | "macro" -> Some KwMacro
  | "comptime" -> Some KwComptime
  | "loop" -> Some KwLoop
  | "pure" -> Some KwPure
  | "inline" -> Some KwInline
  | "unless" -> Some KwUnless
  | "until" -> Some KwUntil
  | "edition" -> Some KwEdition
  | "test" -> Some KwTest
  | "dyn" -> Some KwDyn
  | _ -> None

(* Human-readable name for diagnostics and the `lex` output. *)
let display_name (k : kind) : string =
  match k with
  | Ident s -> "identifier '" ^ s ^ "'"
  | Integer s -> "integer '" ^ s ^ "'"
  | Float s -> "float '" ^ s ^ "'"
  | String _ -> "string literal"
  | Char _ -> "char literal"
  | Newline -> "newline"
  | Whitespace -> "whitespace"
  | Comment -> "comment"
  | DocComment _ -> "doc comment"
  | At -> "'@'"
  | KwDef -> "'def'"
  | KwEnd -> "'end'"
  | KwIf -> "'if'"
  | KwThen -> "'then'"
  | KwElse -> "'else'"
  | KwElsif -> "'elsif'"
  | KwWhile -> "'while'"
  | KwFor -> "'for'"
  | KwIn -> "'in'"
  | KwDo -> "'do'"
  | KwLet -> "'let'"
  | KwMut -> "'mut'"
  | KwReturn -> "'return'"
  | KwBreak -> "'break'"
  | KwNext -> "'next'"
  | KwMatch -> "'match'"
  | KwWhen -> "'when'"
  | KwStruct -> "'struct'"
  | KwEnum -> "'enum'"
  | KwTrait -> "'trait'"
  | KwImpl -> "'impl'"
  | KwUse -> "'use'"
  | KwPub -> "'pub'"
  | KwModule -> "'module'"
  | KwMod -> "'mod'"
  | KwConst -> "'const'"
  | KwStatic -> "'static'"
  | KwType -> "'type'"
  | KwExtern -> "'extern'"
  | KwWhere -> "'where'"
  | KwAs -> "'as'"
  | KwSuper -> "'super'"
  | KwCrate -> "'crate'"
  | KwSelfValue -> "'self'"
  | KwSelfTy -> "'Self'"
  | KwFn -> "'fn'"
  | KwTrue -> "'true'"
  | KwFalse -> "'false'"
  | KwUnsafe -> "'unsafe'"
  | KwAsync -> "'async'"
  | KwAwait -> "'await'"
  | KwCap -> "'cap'"
  | KwEffect -> "'effect'"
  | KwRequires -> "'requires'"
  | KwImplies -> "'implies'"
  | KwHandle -> "'handle'"
  | KwWith -> "'with'"
  | KwRationale -> "'rationale'"
  | KwBudget -> "'budget'"
  | KwPre -> "'pre'"
  | KwPost -> "'post'"
  | KwInvariant -> "'invariant'"
  | KwGuard -> "'guard'"
  | KwDefer -> "'defer'"
  | KwTry -> "'try'"
  | KwCatch -> "'catch'"
  | KwFinally -> "'finally'"
  | KwMacro -> "'macro'"
  | KwComptime -> "'comptime'"
  | KwLoop -> "'loop'"
  | KwPure -> "'pure'"
  | KwInline -> "'inline'"
  | KwUnless -> "'unless'"
  | KwUntil -> "'until'"
  | KwEdition -> "'edition'"
  | KwTest -> "'test'"
  | KwDyn -> "'dyn'"
  | KwTypealias -> "'typealias'"
  | KwInout -> "'inout'"
  | KwSink -> "'sink'"
  | KwSet -> "'set'"
  | KwResource -> "'resource'"
  | KwDeinit -> "'deinit'"
  | LParen -> "'('"
  | RParen -> "')'"
  | LBracket -> "'['"
  | RBracket -> "']'"
  | LBrace -> "'{'"
  | RBrace -> "'}'"
  | ColonColon -> "'::'"
  | Colon -> "':'"
  | Comma -> "','"
  | Dot -> "'.'"
  | DotDot -> "'..'"
  | DotDotDot -> "'...'"
  | DotDotEq -> "'..='"
  | Semi -> "';'"
  | Arrow -> "'->'"
  | FatArrow -> "'=>'"
  | EqEq -> "'=='"
  | Bang -> "'!'"
  | BangEq -> "'!='"
  | Lt -> "'<'"
  | LtEq -> "'<='"
  | Gt -> "'>'"
  | GtEq -> "'>='"
  | Amp -> "'&'"
  | AmpAmp -> "'&&'"
  | Pipe -> "'|'"
  | PipePipe -> "'||'"
  | Caret -> "'^'"
  | Tilde -> "'~'"
  | Dollar -> "'$'"
  | Shl -> "'<<'"
  | Shr -> "'>>'"
  | Plus -> "'+'"
  | Minus -> "'-'"
  | Slash -> "'/'"
  | Percent -> "'%'"
  | Star -> "'*'"
  | PlusEq -> "'+='"
  | MinusEq -> "'-='"
  | StarEq -> "'*='"
  | SlashEq -> "'/='"
  | PercentEq -> "'%='"
  | CaretEq -> "'^='"
  | AmpEq -> "'&='"
  | PipeEq -> "'|='"
  | ShlEq -> "'<<='"
  | ShrEq -> "'>>='"
  | Eq -> "'='"
  | Question -> "'?'"
  | Eof -> "end of file"

let is_trivia (k : kind) : bool =
  match k with
  | Newline | Whitespace | Comment | DocComment _ -> true
  | _ -> false
