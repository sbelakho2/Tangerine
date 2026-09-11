// Token.swift — Token definitions for the Tangerine lexer
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// Mirrors the Rust stage0 TokenKind enum exactly.

/// A single token produced by the lexer.
public struct Token: Equatable, Sendable {
    public let kind: TokenKind
    public let span: Span

    public init(kind: TokenKind, span: Span) {
        self.kind = kind
        self.span = span
    }
}

/// All token kinds recognized by the Tangerine lexer.
public enum TokenKind: Equatable, Hashable, Sendable {
    // ── Literals ──────────────────────────────────────────────────────
    case ident(String)
    case integer(String)
    case float(String)
    case string(String)
    case char(Character)

    // ── Trivia ────────────────────────────────────────────────────────
    case newline
    case whitespace
    case comment
    case docComment(String)

    // ── Special ───────────────────────────────────────────────────────
    case at           // @

    // ── Keywords ──────────────────────────────────────────────────────
    case kwDef
    case kwEnd
    case kwIf
    case kwThen
    case kwElse
    case kwElsif
    case kwWhile
    case kwFor
    case kwIn
    case kwDo
    case kwLet
    case kwMut
    case kwReturn
    case kwBreak
    case kwNext
    case kwMatch
    case kwWhen
    case kwStruct
    case kwEnum
    case kwTrait
    case kwImpl
    case kwUse
    case kwPub
    case kwModule
    case kwMod
    case kwConst
    case kwStatic
    case kwType
    case kwExtern
    case kwWhere
    case kwAs
    case kwSuper
    case kwCrate
    case kwSelfValue   // self
    case kwSelfTy      // Self
    case kwFn
    case kwTrue
    case kwFalse
    case kwUnsafe
    case kwAsync
    case kwAwait
    case kwCap
    case kwEffect
    case kwRequires
    case kwImplies
    case kwHandle
    case kwWith
    case kwRationale
    case kwBudget
    case kwPre
    case kwPost
    case kwInvariant
    case kwGuard
    case kwDefer
    case kwTry
    case kwCatch
    case kwFinally
    case kwMacro
    case kwComptime
    case kwLoop
    case kwPure
    case kwInline
    case kwUnless
    case kwUntil
    case kwEdition
    case kwTest
    case kwDyn
    case kwTypealias
    case kwInout
    case kwSink
    case kwSet
    case kwResource
    case kwDeinit

    // ── Delimiters ────────────────────────────────────────────────────
    case lParen        // (
    case rParen        // )
    case lBracket      // [
    case rBracket      // ]
    case lBrace        // {
    case rBrace        // }

    // ── Operators & Punctuation ───────────────────────────────────────
    case colonColon    // ::
    case colon         // :
    case comma         // ,
    case dot           // .
    case dotDot        // ..
    case dotDotDot     // ...
    case dotDotEq      // ..=
    case semi          // ;
    case arrow         // ->
    case fatArrow      // =>
    case eqEq          // ==
    case bang          // !
    case bangEq        // !=
    case lt            // <
    case ltEq          // <=
    case gt            // >
    case gtEq          // >=
    case amp           // &
    case ampAmp        // &&
    case pipe          // |
    case pipePipe      // ||
    case caret         // ^
    case tilde         // ~
    case dollar        // $
    case shl           // <<
    case shr           // >>
    case plus          // +
    case minus         // -
    case slash         // /
    case percent       // %
    case star          // *
    case plusEq        // +=
    case minusEq       // -=
    case starEq        // *=
    case slashEq       // /=
    case percentEq     // %=
    case caretEq       // ^=
    case ampEq         // &=
    case pipeEq        // |=
    case shlEq         // <<=
    case shrEq         // >>=
    case eq            // =
    case question      // ?

    // ── Sentinel ──────────────────────────────────────────────────────
    case eof
}

// MARK: - Keyword Lookup

extension TokenKind {
    /// Map a string to its keyword token kind, or nil if it's an identifier.
    public static func keyword(for text: String) -> TokenKind? {
        switch text {
        case "def":       return .kwDef
        case "end":       return .kwEnd
        case "if":        return .kwIf
        case "then":      return .kwThen
        case "else":      return .kwElse
        case "elsif":     return .kwElsif
        case "while":     return .kwWhile
        case "for":       return .kwFor
        case "in":        return .kwIn
        case "do":        return .kwDo
        case "let":       return .kwLet
        case "mut":       return .kwMut
        case "var":       return .kwMut
        case "inout":     return .kwInout
        case "sink":      return .kwSink
        case "set":       return .kwSet
        case "resource":  return .kwResource
        case "deinit":    return .kwDeinit
        case "return":    return .kwReturn
        case "break":     return .kwBreak
        case "next":      return .kwNext
        case "match":     return .kwMatch
        case "when":      return .kwWhen
        case "struct":    return .kwStruct
        case "enum":      return .kwEnum
        case "trait":     return .kwTrait
        case "impl":      return .kwImpl
        case "use":       return .kwUse
        case "pub":       return .kwPub
        case "module":    return .kwModule
        case "mod":       return .kwMod
        case "const":     return .kwConst
        case "static":    return .kwStatic
        case "type":      return .kwType
        case "extern":    return .kwExtern
        case "where":     return .kwWhere
        case "as":        return .kwAs
        case "super":     return .kwSuper
        case "crate":     return .kwCrate
        case "self":      return .kwSelfValue
        case "Self":      return .kwSelfTy
        case "fn":        return .kwFn
        case "true":      return .kwTrue
        case "false":     return .kwFalse
        case "unsafe":    return .kwUnsafe
        case "async":     return .kwAsync
        case "await":     return .kwAwait
        case "cap":       return .kwCap
        case "effect":    return .kwEffect
        case "requires":  return .kwRequires
        case "implies":   return .kwImplies
        case "handle":    return .kwHandle
        case "with":      return .kwWith
        case "rationale": return .kwRationale
        case "budget":    return .kwBudget
        case "pre":       return .kwPre
        case "post":      return .kwPost
        case "invariant": return .kwInvariant
        case "guard":     return .kwGuard
        case "defer":     return .kwDefer
        case "try":       return .kwTry
        case "catch":     return .kwCatch
        case "finally":   return .kwFinally
        case "macro":     return .kwMacro
        case "comptime":  return .kwComptime
        case "loop":      return .kwLoop
        case "pure":      return .kwPure
        case "inline":    return .kwInline
        case "unless":    return .kwUnless
        case "until":     return .kwUntil
        case "edition":   return .kwEdition
        case "test":      return .kwTest
        case "dyn":       return .kwDyn
        case "typealias": return .kwTypealias
        default:          return nil
        }
    }

    /// Human-readable name for diagnostics.
    public var displayName: String {
        switch self {
        case .ident(let s):    return "identifier '\(s)'"
        case .integer(let s):  return "integer '\(s)'"
        case .float(let s):    return "float '\(s)'"
        case .string:          return "string literal"
        case .char:            return "char literal"
        case .newline:         return "newline"
        case .whitespace:      return "whitespace"
        case .comment:         return "comment"
        case .docComment:      return "doc comment"
        case .at:              return "'@'"
        case .kwDef:           return "'def'"
        case .kwEnd:           return "'end'"
        case .kwIf:            return "'if'"
        case .kwThen:          return "'then'"
        case .kwElse:          return "'else'"
        case .kwElsif:         return "'elsif'"
        case .kwWhile:         return "'while'"
        case .kwFor:           return "'for'"
        case .kwIn:            return "'in'"
        case .kwDo:            return "'do'"
        case .kwLet:           return "'let'"
        case .kwMut:           return "'mut'"
        case .kwReturn:        return "'return'"
        case .kwBreak:         return "'break'"
        case .kwNext:          return "'next'"
        case .kwMatch:         return "'match'"
        case .kwWhen:          return "'when'"
        case .kwStruct:        return "'struct'"
        case .kwEnum:          return "'enum'"
        case .kwTrait:         return "'trait'"
        case .kwImpl:          return "'impl'"
        case .kwUse:           return "'use'"
        case .kwPub:           return "'pub'"
        case .kwModule:        return "'module'"
        case .kwMod:           return "'mod'"
        case .kwConst:         return "'const'"
        case .kwStatic:        return "'static'"
        case .kwType:          return "'type'"
        case .kwExtern:        return "'extern'"
        case .kwWhere:         return "'where'"
        case .kwAs:            return "'as'"
        case .kwSuper:         return "'super'"
        case .kwCrate:         return "'crate'"
        case .kwSelfValue:     return "'self'"
        case .kwSelfTy:        return "'Self'"
        case .kwFn:            return "'fn'"
        case .kwTrue:          return "'true'"
        case .kwFalse:         return "'false'"
        case .kwUnsafe:        return "'unsafe'"
        case .kwAsync:         return "'async'"
        case .kwAwait:         return "'await'"
        case .kwCap:           return "'cap'"
        case .kwEffect:        return "'effect'"
        case .kwRequires:      return "'requires'"
        case .kwImplies:       return "'implies'"
        case .kwHandle:        return "'handle'"
        case .kwWith:          return "'with'"
        case .kwRationale:     return "'rationale'"
        case .kwBudget:        return "'budget'"
        case .kwPre:           return "'pre'"
        case .kwPost:          return "'post'"
        case .kwInvariant:     return "'invariant'"
        case .kwGuard:         return "'guard'"
        case .kwDefer:         return "'defer'"
        case .kwTry:           return "'try'"
        case .kwCatch:         return "'catch'"
        case .kwFinally:       return "'finally'"
        case .kwMacro:         return "'macro'"
        case .kwComptime:      return "'comptime'"
        case .kwLoop:          return "'loop'"
        case .kwPure:          return "'pure'"
        case .kwInline:        return "'inline'"
        case .kwUnless:        return "'unless'"
        case .kwUntil:         return "'until'"
        case .kwEdition:       return "'edition'"
        case .kwTest:          return "'test'"
        case .kwDyn:           return "'dyn'"
        case .kwTypealias:     return "'typealias'"
        case .kwInout:         return "'inout'"
        case .kwSink:          return "'sink'"
        case .kwSet:           return "'set'"
        case .kwResource:      return "'resource'"
        case .kwDeinit:        return "'deinit'"
        case .lParen:          return "'('"
        case .rParen:          return "')'"
        case .lBracket:        return "'['"
        case .rBracket:        return "']'"
        case .lBrace:          return "'{'"
        case .rBrace:          return "'}'"
        case .colonColon:      return "'::'"
        case .colon:           return "':'"
        case .comma:           return "','"
        case .dot:             return "'.'"
        case .dotDot:          return "'..'"
        case .dotDotDot:       return "'...'"
        case .dotDotEq:        return "'..='"
        case .semi:            return "';'"
        case .arrow:           return "'->'"
        case .fatArrow:        return "'=>'"
        case .eqEq:            return "'=='"
        case .bang:            return "'!'"
        case .bangEq:          return "'!='"
        case .lt:              return "'<'"
        case .ltEq:            return "'<='"
        case .gt:              return "'>'"
        case .gtEq:            return "'>='"
        case .amp:             return "'&'"
        case .ampAmp:          return "'&&'"
        case .pipe:            return "'|'"
        case .pipePipe:        return "'||'"
        case .caret:           return "'^'"
        case .tilde:           return "'~'"
        case .dollar:          return "'$'"
        case .shl:             return "'<<'"
        case .shr:             return "'>>'"
        case .plus:            return "'+'"
        case .minus:           return "'-'"
        case .slash:           return "'/'"
        case .percent:         return "'%'"
        case .star:            return "'*'"
        case .plusEq:          return "'+='"
        case .minusEq:         return "'-='"
        case .starEq:          return "'*='"
        case .slashEq:         return "'/='"
        case .percentEq:       return "'%='"
        case .caretEq:         return "'^='"
        case .ampEq:           return "'&='"
        case .pipeEq:          return "'|='"
        case .shlEq:           return "'<<='"
        case .shrEq:           return "'>>='"
        case .eq:              return "'='"
        case .question:        return "'?'"
        case .eof:             return "end of file"
        }
    }
}
