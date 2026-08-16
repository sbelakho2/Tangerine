// Parser.swift — Recursive-descent parser for the Tangerine language
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// Implements the full grammar from docs/grammar.md with subset enforcement.
// All constructs are parsed; PARSED-BUT-REJECTED ones produce AST nodes that
// are flagged by the SubsetChecker pass.

public final class Parser {
    private let tokens: [Token]
    private let source: String
    private let fileID: Int
    private let diagnostics: DiagnosticBag
    private var cursor: Int = 0
    private var previousTokenEnd: Int = 0

    public init(tokens: [Token], source: String, fileID: Int = 0, diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.source = source
        self.fileID = fileID
        self.diagnostics = diagnostics
    }

    // MARK: - Token Stream

    private func peek() -> Token {
        if cursor < tokens.count { return tokens[cursor] }
        return Token(kind: .eof, span: Span.synthetic)
    }

    private func peekKind() -> TokenKind {
        peek().kind
    }

    @discardableResult
    private func advance() -> Token {
        let tok = peek()
        previousTokenEnd = tok.span.end
        if cursor < tokens.count { cursor += 1 }
        return tok
    }

    private func at(_ kind: TokenKind) -> Bool {
        peekKind() == kind
    }

    private func atAny(_ kinds: [TokenKind]) -> Bool {
        kinds.contains(peekKind())
    }

    private func atEof() -> Bool {
        peekKind() == .eof
    }

    @discardableResult
    private func expect(_ kind: TokenKind) -> Token {
        if at(kind) {
            return advance()
        }
        let tok = peek()
        diagnostics.error(
            code: "E1100",
            message: "expected \(kind.displayName), found \(tok.kind.displayName)",
            span: tok.span,
            stage: .parser
        )
        return tok
    }

    private func expectIdent() -> String {
        // Many keywords are soft — they can be used as identifiers in some contexts
        // (field names, method calls, use paths etc.), matching the Rust stage0 behavior.
        switch peekKind() {
        case .ident(let name): advance(); return name
        case .kwBudget:   advance(); return "budget"
        case .kwDef:      advance(); return "def"
        case .kwExtern:   advance(); return "extern"
        case .kwFinally:  advance(); return "finally"
        case .kwLoop:     advance(); return "loop"
        case .kwSelfValue:advance(); return "self"
        case .kwNext:     advance(); return "next"
        case .kwModule:   advance(); return "module"
        case .kwType:     advance(); return "type"
        case .kwTypealias:advance(); return "typealias"
        case .kwCap:      advance(); return "cap"
        case .kwConst:    advance(); return "const"
        case .kwEffect:   advance(); return "effect"
        case .kwEdition:  advance(); return "edition"
        case .kwGuard:    advance(); return "guard"
        case .kwDefer:    advance(); return "defer"
        case .kwHandle:   advance(); return "handle"
        case .kwImplies:  advance(); return "implies"
        case .kwInline:   advance(); return "inline"
        case .kwMut:      advance(); return "mut"
        case .kwAsync:    advance(); return "async"
        case .kwEnd:      advance(); return "end"
        case .kwDo:       advance(); return "do"
        case .kwPre:      advance(); return "pre"
        case .kwPost:     advance(); return "post"
        case .kwPub:      advance(); return "pub"
        case .kwTest:     advance(); return "test"
        case .kwPure:     advance(); return "pure"
        case .kwStatic:   advance(); return "static"
        case .kwAwait:    advance(); return "await"
        case .kwWhen:     advance(); return "when"
        case .kwMod:      advance(); return "mod"
        case .kwRequires: advance(); return "requires"
        case .kwInvariant:advance(); return "invariant"
        case .kwWith:     advance(); return "with"
        case .kwIn:       advance(); return "in"
        case .kwCatch:    advance(); return "catch"
        case .kwTry:      advance(); return "try"
        case .kwYield:    advance(); return "yield"
        case .kwDyn:      advance(); return "dyn"
        case .kwFn:       advance(); return "fn"
        case .kwCrate:    advance(); return "crate"
        case .kwSuper:    advance(); return "super"
        case .kwMacro:    advance(); return "macro"
        case .kwComptime: advance(); return "comptime"
        case .kwUnless:   advance(); return "unless"
        case .kwUntil:    advance(); return "until"
        case .kwRationale:advance(); return "rationale"
        case .kwUse:      advance(); return "use"
        case .kwWhere:    advance(); return "where"
        case .kwAs:       advance(); return "as"
        case .kwInout:    advance(); return "inout"
        case .kwSink:     advance(); return "sink"
        case .kwSet:      advance(); return "set"
        case .kwResource: advance(); return "resource"
        case .kwDeinit:   advance(); return "deinit"
        default:
            let tok = peek()
            diagnostics.error(
                code: "E1101",
                message: "expected identifier, found \(tok.kind.displayName)",
                span: tok.span,
                stage: .parser
            )
            advance() // skip the unexpected token to avoid infinite loops
            return "<error>"
        }
    }

    /// Check if current token is an identifier or a soft keyword.
    private func atIdent() -> Bool {
        switch peekKind() {
        case .ident: return true
        case .kwBudget, .kwDef, .kwExtern, .kwFinally, .kwLoop, .kwSelfValue,
             .kwNext, .kwModule, .kwType, .kwCap, .kwConst, .kwEffect, .kwEdition,
             .kwGuard, .kwDefer, .kwHandle, .kwImplies, .kwInline, .kwMut, .kwAsync,
             .kwEnd, .kwDo, .kwPre, .kwPost, .kwPub, .kwTest, .kwPure,
             .kwStatic, .kwAwait, .kwWhen, .kwMod,
             .kwRequires, .kwInvariant, .kwWith, .kwCatch, .kwTry, .kwYield,
             .kwIn, .kwDyn, .kwFn, .kwCrate, .kwSuper, .kwMacro, .kwComptime,
             .kwUnless, .kwUntil, .kwRationale, .kwUse, .kwWhere, .kwAs,
             .kwInout, .kwSink, .kwSet, .kwResource, .kwDeinit:
            return true
        default:
            return false
        }
    }

    private func atString() -> Bool {
        if case .string = peekKind() { return true }
        return false
    }

    /// Check if we're at a `var` binding start (soft keyword: ident "var" NOT followed by `(`).
    private func atVarBinding() -> Bool {
        if case .ident(let name) = peekKind(), name == "var" {
            return peekAhead(1) != .lParen
        }
        return false
    }

    /// Try to consume a token if it matches. Returns true if consumed.
    @discardableResult
    private func eat(_ kind: TokenKind) -> Bool {
        if at(kind) {
            advance()
            return true
        }
        return false
    }

    private var currentSpan: Span {
        peek().span
    }

    // MARK: - Program

    public func parseProgram() -> Program {
        let start = currentSpan
        var items: [Item] = []

        while !atEof() {
            // Silently skip bare `end` at top level (may close an implicit module)
            if at(.kwEnd) {
                advance()
                continue
            }
            if let item = parseItem() {
                items.append(item)
            } else {
                // Skip unrecognized token
                let tok = advance()
                diagnostics.error(
                    code: "E1102",
                    message: "unexpected \(tok.kind.displayName) at top level",
                    span: tok.span,
                    stage: .parser
                )
            }
        }

        let endSpan = currentSpan
        return Program(items: items, span: start.merged(with: endSpan))
    }

    // MARK: - Items

    private func parseItem() -> Item? {
        let attrs = parseAttributes()
        let start = currentSpan

        // Check for pub modifier
        var isPublic = false
        if at(.kwPub) {
            isPublic = true
            advance()
        }

        let kind: ItemKind?
        switch peekKind() {
        case .kwDef, .kwFn, .kwAsync, .kwUnsafe, .kwPure, .kwInline:
            kind = parseModifiedFunctionItem(initialPublic: isPublic)
        case .kwStruct:
            kind = parseStructItem(isPublic: isPublic)
        case .kwResource:
            kind = parseResourceItem(isPublic: isPublic)
        case .kwEnum:
            kind = parseEnumItem(isPublic: isPublic)
        case .kwTrait:
            kind = parseTraitItem(isPublic: isPublic)
        case .kwImpl:
            kind = parseImplItem()
        case .kwUse:
            kind = parseUseItem()
        case .kwConst:
            if looksLikeFunctionDeclAfterModifiers(from: cursor) {
                kind = parseModifiedFunctionItem(initialPublic: isPublic)
            } else {
                kind = parseConstItem(isPublic: isPublic)
            }
        case .kwStatic:
            kind = parseStaticItem(isPublic: isPublic)
        case .kwType, .kwTypealias:
            kind = parseTypeAliasItem(isPublic: isPublic)
        case .kwExtern:
            kind = parseExternItem()
        case .kwModule, .kwMod:
            kind = parseModuleItem(isPublic: isPublic)
        case .kwCap:
            kind = parseCapabilityItem()
        case .kwEffect:
            kind = parseEffectItem()
        case .kwRationale:
            kind = parseRationaleItem()
        case .kwMacro:
            kind = parseMacroItem()
        case .kwEdition:
            kind = parseEditionItem()
        case .kwTest:
            kind = parseTestItem()
        case .kwLet:
            // Top-level let binding — treat like static
            let letKind = parseTopLevelLet(isPublic: isPublic, isMutable: false)
            kind = letKind
        case .kwMut:
            // Top-level mut binding — treat like static mut
            let mutKind = parseTopLevelLet(isPublic: isPublic, isMutable: true)
            kind = mutKind
        default:
            if atVarBinding() {
                // var x: T = value — treat as mutable binding (same as mut)
                let varKind = parseTopLevelLet(isPublic: isPublic, isMutable: true)
                kind = varKind
            } else if isPublic {
                diagnostics.error(code: "E1104", message: "expected item after 'pub'", span: currentSpan, stage: .parser)
                return nil
            } else {
                return nil
            }
        }

        guard let itemKind = kind else { return nil }
        return Item(kind: itemKind, attributes: attrs, span: start.merged(with: currentSpan))
    }

    // MARK: - Attributes

    private func parseAttributes() -> [Attribute] {
        var attrs: [Attribute] = []
        while at(.at) {
            let start = currentSpan
            advance() // skip @
            let isBracketed = eat(.lBracket)
            let name = expectIdent()
            var args: [AttributeArg] = []
            if eat(.lParen) {
                args = parseAttributeArgs()
                expect(.rParen)
            } else if isBracketed && (eat(.eq) || eat(.colon)) {
                if case .string(let s) = peekKind() {
                    advance()
                    args = [.string(s)]
                } else if case .integer(let s) = peekKind() {
                    advance()
                    args = [.int(s)]
                } else if atIdent() {
                    args = [.ident(expectIdent())]
                }
            }
            if isBracketed {
                expect(.rBracket)
            }
            attrs.append(Attribute(name: name, args: args, span: start.merged(with: currentSpan)))
        }
        return attrs
    }

    private func parseAttributeArgs() -> [AttributeArg] {
        var args: [AttributeArg] = []
        while !at(.rParen) && !atEof() {
            if atIdent() {
                let name = expectIdent()
                if eat(.eq) || eat(.colon) {
                    // key = value
                    if case .string(let s) = peekKind() {
                        advance()
                        args.append(.keyValue(name, s))
                    } else if case .integer(let s) = peekKind() {
                        advance()
                        args.append(.keyValue(name, s))
                    } else if atIdent() {
                        let v = expectIdent()
                        args.append(.keyValue(name, v))
                    } else {
                        args.append(.ident(name))
                    }
                } else if eat(.lParen) {
                    // Nested call: name(args...) e.g. all(target_arch = "x86_64", ...)
                    let nested = parseAttributeArgs()
                    expect(.rParen)
                    args.append(.nested(name, nested))
                } else {
                    args.append(.ident(name))
                }
            } else if case .string(let s) = peekKind() {
                advance()
                args.append(.string(s))
            } else if case .integer(let s) = peekKind() {
                advance()
                args.append(.int(s))
            } else {
                advance() // skip unexpected
            }
            if !at(.rParen) { eat(.comma) }
        }
        return args
    }

    // MARK: - Function

    private struct FunctionModifiers {
        var isPublic: Bool = false
        var isAsync: Bool = false
        var isUnsafe: Bool = false
        var isConst: Bool = false
        var isPure: Bool = false
        var isInline: Bool = false
        var isExtern: Bool = false
    }

    private func looksLikeFunctionDeclAfterModifiers(from index: Int) -> Bool {
        var i = index
        while i < tokens.count {
            switch tokens[i].kind {
            case .kwPub, .kwAsync, .kwUnsafe, .kwConst, .kwPure, .kwInline:
                i += 1
            case .kwDef, .kwFn:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func tokenKind(at index: Int) -> TokenKind {
        if index < tokens.count {
            return tokens[index].kind
        }
        return .eof
    }

    private func skipDelimitedTokens(from index: Int, open: TokenKind, close: TokenKind) -> Int {
        guard tokenKind(at: index) == open else { return index }
        var depth = 0
        var i = index
        while i < tokens.count {
            let kind = tokenKind(at: i)
            if kind == open {
                depth += 1
            } else if kind == close {
                depth -= 1
                if depth == 0 {
                    return i + 1
                }
            }
            i += 1
        }
        return i
    }

    private func skipAttributes(from index: Int) -> Int {
        var i = index
        while tokenKind(at: i) == .at {
            i += 1
            if tokenKind(at: i) == .lBracket {
                i = skipDelimitedTokens(from: i, open: .lBracket, close: .rBracket)
                continue
            }
            if tokenKind(at: i) != .eof {
                i += 1
            }
            if tokenKind(at: i) == .lParen {
                i = skipDelimitedTokens(from: i, open: .lParen, close: .rParen)
            }
        }
        return i
    }

    private func looksLikeBlockItemStart(from index: Int) -> Bool {
        let i = skipAttributes(from: index)
        switch tokenKind(at: i) {
        case .kwDef, .kwFn, .kwStruct, .kwResource, .kwImpl, .kwUse, .kwConst, .kwStatic:
            return true
        case .kwPub, .kwAsync, .kwUnsafe, .kwPure, .kwInline:
            return looksLikeFunctionDeclAfterModifiers(from: i)
        default:
            return false
        }
    }

    private func looksLikeAttributeOnlyBody(from index: Int, terminator: TokenKind) -> Bool {
        guard tokenKind(at: index) == .at else { return false }
        let next = skipAttributes(from: index)
        return next > index && (tokenKind(at: next) == terminator || tokenKind(at: next) == .eof)
    }

    private func parseAttributeOnlyBlock(terminator: TokenKind?) -> BlockBody {
        let start = currentSpan
        var stmts: [Stmt] = []
        while at(.at) {
            let stmtStart = currentSpan
            let attrs = parseAttributes()
            stmts.append(.attributeStmt(attrs, stmtStart.merged(with: currentSpan)))
        }
        return BlockBody(stmts: stmts, tailExpr: nil, span: start.merged(with: currentSpan))
    }

    private func parseFunctionModifiers(initialPublic: Bool = false, initialExtern: Bool = false) -> FunctionModifiers {
        var mods = FunctionModifiers(isPublic: initialPublic, isExtern: initialExtern)
        while true {
            switch peekKind() {
            case .kwPub where !mods.isPublic:
                advance()
                mods.isPublic = true
            case .kwAsync where !mods.isAsync:
                advance()
                mods.isAsync = true
            case .kwUnsafe where !mods.isUnsafe:
                advance()
                mods.isUnsafe = true
            case .kwConst where !mods.isConst:
                advance()
                mods.isConst = true
            case .kwPure where !mods.isPure:
                advance()
                mods.isPure = true
            case .kwInline where !mods.isInline:
                advance()
                mods.isInline = true
            default:
                return mods
            }
        }
    }

    private func parseModifiedFunctionItem(initialPublic: Bool = false, initialExtern: Bool = false) -> ItemKind? {
        let mods = parseFunctionModifiers(initialPublic: initialPublic, initialExtern: initialExtern)
        guard at(.kwDef) || at(.kwFn) else {
            diagnostics.error(code: "E1103", message: "expected 'def' or 'fn' after function modifiers", span: currentSpan, stage: .parser)
            return nil
        }
        return parseFunctionItem(isPublic: mods.isPublic, isAsync: mods.isAsync,
                                 isUnsafe: mods.isUnsafe, isConst: mods.isConst,
                                 isPure: mods.isPure, isInline: mods.isInline,
                                 isExtern: mods.isExtern)
    }

    private func parseExternFunctionDecl() -> FunctionDecl? {
        let mods = parseFunctionModifiers(initialExtern: true)
        guard at(.kwDef) || at(.kwFn) else {
            diagnostics.error(code: "E1103", message: "expected 'def' or 'fn' after extern modifiers", span: currentSpan, stage: .parser)
            return nil
        }
        _ = advance()
        let sig = parseFunctionSig(isPublic: mods.isPublic, isAsync: mods.isAsync,
                                   isUnsafe: mods.isUnsafe, isConst: mods.isConst,
                                   isPure: mods.isPure, isInline: mods.isInline,
                                   isExtern: true)
        return FunctionDecl(sig: sig, body: .signatureOnly, span: sig.span)
    }

    private func parseFunctionItem(isPublic: Bool, isAsync: Bool, isUnsafe: Bool, isConst: Bool, isPure: Bool, isInline: Bool, isExtern: Bool) -> ItemKind {
        if at(.kwDef) || at(.kwFn) {
            _ = advance()
        } else {
            expect(.kwDef)
        }
        let start = currentSpan
        let (name, typeParams) = parseFunctionNameAndTypeParams()
        expect(.lParen)
        var params = parseParamList()
        expect(.rParen)
        let retType = parseOptionalReturnType()
        let whereClause = parseOptionalWhereClause()
        consumeTrailingReceiverConvention(&params)

        let sig = FunctionSig(
            name: name, isPublic: isPublic, isAsync: isAsync,
            isUnsafe: isUnsafe, isConst: isConst,
            isPure: isPure, isInline: isInline, isExtern: isExtern,
            typeParams: typeParams, params: params,
            returnType: retType, whereClause: whereClause,
            span: start.merged(with: currentSpan)
        )

        // Parse function clauses
        let clauses = parseFunctionClauses()

        // Parse body
        let body: FunctionBody
        if eat(.eq) {
            // Expression body: def f(x) = expr
            let expr = parseExpr()
            body = .expr(expr)
        } else if at(.lBrace) {
            // Brace body: def f(x) { ... }
            advance()
            let block = parseBlock(terminator: .rBrace)
            expect(.rBrace)
            body = .block(block)
        } else if looksLikeAttributeOnlyBody(from: cursor, terminator: .kwEnd) {
            let block = parseAttributeOnlyBlock(terminator: .kwEnd)
            expect(.kwEnd)
            body = .block(block)
        } else {
            // Block body: def f(x) ... end
            let block = parseBlock()
            expect(.kwEnd)
            body = .block(block)
        }

        return .function(FunctionDecl(sig: sig, clauses: clauses, body: body,
                                       span: start.merged(with: currentSpan)))
    }

    private func parseFunctionClauses() -> [FunctionClause] {
        var clauses: [FunctionClause] = []
        while true {
            switch peekKind() {
            case .kwRequires:
                clauses.append(parseRequiresClause())
            case .kwEffect:
                clauses.append(parseEffectClauseOnFn())
            case .kwBudget:
                clauses.append(parseBudgetClause())
            case .kwPre:
                clauses.append(parseContractClause(kind: .pre))
            case .kwPost:
                clauses.append(parseContractClause(kind: .post))
            case .kwInvariant:
                clauses.append(parseContractClause(kind: .invariant))
            case .kwGuard:
                clauses.append(parseGuardClauseOnFn())
            default:
                return clauses
            }
        }
    }

    private func parseRequiresClause() -> FunctionClause {
        let start = currentSpan
        advance() // skip 'requires'
        var caps: [(name: String, negated: Bool)] = []
        repeat {
            let negated = eat(.bang)
            let name = expectIdent()
            caps.append((name: name, negated: negated))
        } while eat(.comma)
        return .requires(RequiresClause(capabilities: caps, span: start.merged(with: currentSpan)))
    }

    private func parseEffectClauseOnFn() -> FunctionClause {
        let start = currentSpan
        advance() // skip 'effect'
        let name = expectIdent()
        let typeArgs = parseOptionalTypeArgs()
        return .effect(EffectClause(effectName: name, typeArgs: typeArgs, span: start.merged(with: currentSpan)))
    }

    private func parseBudgetClause() -> FunctionClause {
        let start = currentSpan
        advance() // skip 'budget'
        var entries: [(metric: String, amount: String)] = []
        repeat {
            let metric = expectIdent()
            // Budget clause: metric <op> limit
            // Operators: <, <=, >, >=
            let op: String
            switch peekKind() {
            case .lt:   advance(); op = "<"
            case .ltEq: advance(); op = "<="
            case .gt:   advance(); op = ">"
            case .gtEq: advance(); op = ">="
            case .colon:
                // Also accept metric: value (legacy syntax)
                advance(); op = ":"
            default:
                op = "<"
                diagnostics.error(code: "E1106", message: "expected budget comparison operator (<, <=, >, >=)",
                                  span: currentSpan, stage: .parser)
            }
            let amount: String
            if case .string(let s) = peekKind() {
                advance()
                amount = s
            } else if case .integer(let s) = peekKind() {
                advance()
                // Optional unit suffix
                if atIdent() {
                    let unit = expectIdent()
                    amount = s + " " + unit
                } else {
                    amount = s
                }
            } else if case .float(let s) = peekKind() {
                advance()
                amount = s
            } else {
                amount = expectIdent()
            }
            _ = op // stored in amount for simplicity; budget is parsed-but-rejected anyway
            entries.append((metric: metric, amount: amount))
        } while eat(.comma)
        return .budget(BudgetClause(entries: entries, span: start.merged(with: currentSpan)))
    }

    private func parseContractClause(kind: ContractKind) -> FunctionClause {
        let start = currentSpan
        advance() // skip pre/post/invariant
        let cond = parseExpr()
        var msg: String? = nil
        if eat(.comma) {
            if case .string(let s) = peekKind() {
                advance()
                msg = s
            }
        }
        return .contract(ContractClause(kind: kind, condition: cond, message: msg,
                                         span: start.merged(with: currentSpan)))
    }

    private func parseGuardClauseOnFn() -> FunctionClause {
        let start = currentSpan
        advance() // skip 'guard'

        var condition: Expr? = nil
        var pattern: Pattern? = nil
        var value: Expr? = nil

        if eat(.kwLet) {
            pattern = parsePattern()
            expect(.eq)
            value = parseExpr()
        } else {
            condition = parseExpr()
        }

        expect(.kwElse)
        let action = parseGuardAction()

        return .guardClause(GuardClause(condition: condition, pattern: pattern,
                                         value: value, action: action,
                                         span: start.merged(with: currentSpan)))
    }

    private func parseGuardAction() -> GuardAction {
        switch peekKind() {
        case .kwReturn:
            advance()
            if atExprStart() {
                return .returnExpr(parseExpr())
            }
            return .returnExpr(nil)
        case .kwBreak:
            advance()
            if atIdent() {
                return .breakLabel(expectIdent())
            }
            return .breakLabel(nil)
        case .kwNext:
            advance()
            if atIdent() {
                return .next(expectIdent())
            }
            return .next(nil)
        default:
            // panic!(expr)
            let name = expectIdent() // "panic"
            _ = name
            expect(.lParen)
            let expr = parseExpr()
            expect(.rParen)
            return .panicExpr(expr)
        }
    }

    // MARK: - Parameters

    private func isFunctionTypeStart() -> Bool {
        // Check for () -> T pattern (function type in parameter position)
        guard at(.lParen) else { return false }
        // Look ahead to find matching ) and then ->
        var idx = cursor + 1
        var depth = 1
        while idx < tokens.count && depth > 0 {
            if tokens[idx].kind == .lParen {
                depth += 1
            } else if tokens[idx].kind == .rParen {
                depth -= 1
            }
            // Check for -> at depth 1 (after closing the param list)
            if depth == 1 && tokens[idx].kind == .arrow {
                return true
            }
            idx += 1
        }
        return false
    }

    private func parseFunctionTypeParamList() -> (params: [TypeExpr], ret: TypeExpr) {
        // We're at ( already, parse as () -> T
        expect(.lParen)

        var params: [TypeExpr] = []
        
        // Check for empty params () - if we're at ), it's empty
        if !at(.rParen) {
            // Has parameters like (x: T) or just (T)
            while !at(.rParen) && !atEof() {
                // Skip optional parameter name: x: T -> just parse the type
                if atIdent() && peekAhead(1) == .colon {
                    _ = expectIdent()
                    expect(.colon)
                }
                params.append(parseTypeExpr())
                if !at(.rParen) { eat(.comma) }
            }
        }
        expect(.rParen)

        // Now we should have ->
        expect(.arrow)
        let ret = parseTypeExpr()

        return (params: params, ret: ret)
    }

    private func parseParamList() -> [Param] {
        var params: [Param] = []
        while !at(.rParen) && !atEof() {
            let start = currentSpan

            // Check for variadic parameter: ...
            if at(.dotDotDot) {
                advance() // consume ...
                // Create a variadic param with special name
                params.append(Param(
                    name: "...", isMutable: false, convention: .letAccess,
                    type: .named("VarArgs", typeArgs: [], start.merged(with: currentSpan)),
                    span: start.merged(with: currentSpan)
                ))
                if !at(.rParen) { eat(.comma) }
                continue
            }

            if at(.lParen) && isFunctionTypeStart() {
                // Function type parameter: f: () -> T
                // First parse the parameter name and colon, then parse the function type
                let paramName = expectIdent()
                expect(.colon)
                let (funcParams, retType) = parseFunctionTypeParamList()
                let funcType = TypeExpr.fnPtr(params: funcParams, ret: retType, start.merged(with: currentSpan))
                var defaultVal: Expr? = nil
                if eat(.eq) {
                    defaultVal = parseExpr()
                }
                params.append(Param(
                    name: paramName,
                    isMutable: false,
                    convention: .letAccess,
                    type: funcType,
                    defaultValue: defaultVal,
                    span: start.merged(with: currentSpan)
                ))
                if !at(.rParen) { eat(.comma) }
                continue
            }

            // Access convention (new syntax) and legacy modifiers, normalized immediately.
            var convention = AccessConvention.letAccess
            var modifier: ParamModifier? = nil
            if at(.kwInout), peekAhead(1) != .colon {
                advance()
                convention = .inoutAccess
            } else if at(.kwSink), peekAhead(1) != .colon {
                advance()
                convention = .sink
            } else if at(.kwSet), peekAhead(1) != .colon {
                advance()
                convention = .set
            } else if at(.kwMut) {
                advance()
                convention = .inoutAccess
                modifier = .mut
            } else if at(.amp) {
                advance()
                if at(.kwMut) {
                    advance()
                    convention = .inoutAccess
                    modifier = .refMut
                } else {
                    convention = .letAccess
                    modifier = .ref
                }
            } else if case .ident("move") = peekKind(), peekAhead(1) != .colon {
                advance()
                convention = .sink
                modifier = .move
            } else if case .ident("own") = peekKind(), peekAhead(1) != .colon {
                advance()
                convention = .sink
                modifier = .own
            }

            let isSelf = at(.kwSelfValue)
            let name = expectIdent()
            let isMutable = convention != .letAccess

            var type: TypeExpr
            if eat(.colon) {
                type = parseTypeExpr()
                switch type {
                case .ref(let inner, let mutable, _):
                    if modifier == nil {
                        modifier = mutable ? .refMut : .ref
                        convention = mutable ? .inoutAccess : .letAccess
                    }
                    type = inner
                default:
                    break
                }
            } else if isSelf {
                // bare self (implicit Self type)
                type = .selfType(start.merged(with: currentSpan))
            } else {
                type = .inferred(currentSpan)
            }

            var defaultVal: Expr? = nil
            if eat(.eq) {
                defaultVal = parseExpr()
            }
            params.append(Param(name: name, isMutable: isMutable, convention: convention,
                                modifier: modifier, type: type, defaultValue: defaultVal,
                                span: start.merged(with: currentSpan)))
            if !at(.rParen) { eat(.comma) }
        }
        return params
    }

    private func peekAhead(_ offset: Int) -> TokenKind {
        let idx = cursor + offset
        if idx < tokens.count { return tokens[idx].kind }
        return .eof
    }

    /// Trailing `inout` after a method signature sets the receiver convention:
    /// `def foo(...) -> T inout` makes the implicit self inout.
    private func consumeTrailingReceiverConvention(_ params: inout [Param]) {
        if at(.kwInout) {
            advance()
            if let idx = params.firstIndex(where: { $0.name == "self" }) {
                params[idx].convention = .inoutAccess
                params[idx].isMutable = true
            }
        }
    }

    // MARK: - Type Parameters

    private func parseOptionalTypeParams() -> [TypeParam] {
        // Support both [T] and <T> syntax for type parameters
        guard at(.lBracket) || at(.lt) else { return [] }
        let openBracket = at(.lBracket)
        let closeKind: TokenKind = openBracket ? .rBracket : .gt
        
        advance() // skip [ or <
        var params: [TypeParam] = []
        while !at(closeKind) && !atEof() {
            let start = currentSpan
            let name = expectIdent()
            var bounds: [String] = []
            if eat(.colon) {
                bounds.append(parseBoundName())
                while eat(.plus) {
                    bounds.append(parseBoundName())
                }
            }
            params.append(TypeParam(name: name, bounds: bounds, span: start.merged(with: currentSpan)))
            if !at(closeKind) { eat(.comma) }
        }
        expect(closeKind)
        return params
    }

    private func looksLikeQualifiedNameTypeParams() -> Bool {
        guard at(.lBracket) || at(.lt) else { return false }
        let openKind = peekKind()
        let closeKind: TokenKind = openKind == .lt ? .gt : .rBracket
        var i = cursor
        var depth = 0
        while i < tokens.count {
            let kind = tokens[i].kind
            if kind == openKind {
                depth += 1
            } else if kind == closeKind {
                depth -= 1
                if depth == 0 {
                    return i + 1 < tokens.count && tokens[i + 1].kind == .colonColon
                }
            }
            i += 1
        }
        return false
    }

    private func parseFunctionNameAndTypeParams() -> (String, [TypeParam]) {
        var name = expectIdent()
        var typeParams: [TypeParam] = []
        if looksLikeQualifiedNameTypeParams() {
            typeParams.append(contentsOf: parseOptionalTypeParams())
        }
        while eat(.colonColon) {
            name += "::" + expectIdent()
        }
        typeParams.append(contentsOf: parseOptionalTypeParams())
        return (name, typeParams)
    }

    private func parseBoundName() -> String {
        var name = expectIdent()
        while eat(.colonColon) {
            name += "::" + expectIdent()
        }
        // Handle function trait bounds: Fn(T) -> R, FnMut(T) -> R, FnOnce(T) -> R
        // Also handle lowercase fn() -> R syntax used in type bounds
        if (name == "Fn" || name == "FnMut" || name == "FnOnce" || name == "fn") {
            if at(.lBracket) {
                _ = parseOptionalTypeArgs()
            }
            if at(.lParen) {
                advance()
                while !at(.rParen) && !atEof() {
                    _ = parseTypeExpr()
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
                if eat(.arrow) {
                    _ = parseTypeExpr()
                }
                return name
            }
        }
        if at(.lBracket) {
            _ = parseOptionalTypeArgs() // consume generic args in bounds (e.g., Iterator[T])
        }
        return name
    }

    private func parseOptionalTypeArgs() -> [TypeExpr] {
        // Support both [T] and <T> syntax for type arguments
        guard at(.lBracket) || at(.lt) else { return [] }
        let useAngleBrackets = at(.lt)

        if useAngleBrackets && !looksLikeTypeArgList() {
            return []
        }

        let closeKind: TokenKind = useAngleBrackets ? .gt : .rBracket
        
        advance() // skip [ or <
        var args: [TypeExpr] = []
        while !at(closeKind) && !atEof() {
            let start = currentSpan
            if atIdent() && peekAhead(1) == .eq {
                let name = expectIdent()
                expect(.eq)
                let value = parseTypeExpr()
                args.append(.assocBinding(name, value, start.merged(with: currentSpan)))
            } else if case .integer(let value) = peekKind() {
                let span = currentSpan
                advance()
                args.append(.constExpr(.intLit(value, span), span))
            } else {
                args.append(parseTypeExpr())
            }
            if !at(closeKind) { eat(.comma) }
        }
        expect(closeKind)
        return args
    }

    private func parseOptionalExprTypeArgs(precedingName: String? = nil) -> [TypeExpr] {
        guard looksLikeExprTypeArgList(precedingName: precedingName) else { return [] }
        return parseOptionalTypeArgs()
    }

    private func sourceText(from start: Int, to end: Int) -> String {
        let bytes = Array(source.utf8)
        let safeStart = max(0, min(start, bytes.count))
        let safeEnd = max(safeStart, min(end, bytes.count))
        return String(decoding: bytes[safeStart..<safeEnd], as: UTF8.self)
    }

    private func topLevelOpaqueMacroArgSyntax(from index: Int, close: TokenKind) -> Bool {
        var i = index
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while i < tokens.count {
            let kind = tokens[i].kind
            switch kind {
            case .lParen:
                parenDepth += 1
            case .rParen:
                if parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 && close == .rParen {
                    return false
                }
                if parenDepth > 0 { parenDepth -= 1 }
            case .lBracket:
                bracketDepth += 1
            case .rBracket:
                if bracketDepth == 0 && parenDepth == 0 && braceDepth == 0 && close == .rBracket {
                    return false
                }
                if bracketDepth > 0 { bracketDepth -= 1 }
            case .lBrace:
                braceDepth += 1
            case .rBrace:
                if braceDepth > 0 { braceDepth -= 1 }
            case .colon, .colonColon:
                if parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 {
                    return true
                }
            default:
                break
            }
            i += 1
        }
        return false
    }

    private func findMacroClosingDelimiter(from index: Int, close: TokenKind) -> Int? {
        var i = index
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while i < tokens.count {
            let kind = tokens[i].kind
            switch kind {
            case .lParen:
                parenDepth += 1
            case .rParen:
                if parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 && close == .rParen {
                    return i
                }
                if parenDepth > 0 { parenDepth -= 1 }
            case .lBracket:
                bracketDepth += 1
            case .rBracket:
                if bracketDepth == 0 && parenDepth == 0 && braceDepth == 0 && close == .rBracket {
                    return i
                }
                if bracketDepth > 0 { bracketDepth -= 1 }
            case .lBrace:
                braceDepth += 1
            case .rBrace:
                if braceDepth > 0 { braceDepth -= 1 }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    private func parseMacroArgs(until close: TokenKind) -> [MacroArg] {
        if topLevelOpaqueMacroArgSyntax(from: cursor, close: close), let closeIndex = findMacroClosingDelimiter(from: cursor, close: close) {
            let start = currentSpan
            let text = sourceText(from: start.start, to: tokens[closeIndex].span.start)
            cursor = closeIndex
            return [.tokens(text, start.merged(with: tokens[closeIndex].span))]
        }

        var args: [MacroArg] = []
        while !at(close) && !atEof() {
            args.append(.expr(parseExpr()))
            if !at(close) {
                if !eat(.comma) {
                    _ = eat(.semi)
                }
            }
        }
        return args
    }

    private func parseInlineAsmExpr(start: Span) -> Expr? {
        let payloadStartSpan = currentSpan
        if case .ident(let modifier) = peekKind(), modifier == "volatile" {
            advance()
        }

        guard at(.lParen) else {
            return nil
        }

        advance()
        guard let closeIndex = findMacroClosingDelimiter(from: cursor, close: .rParen) else {
            diagnostics.error(code: "E1100", message: "expected ')' to close inline asm", span: currentSpan, stage: .parser)
            return .macroCall(name: "asm", args: [], start.merged(with: currentSpan))
        }

        let closeSpan = tokens[closeIndex].span
        let text = sourceText(from: payloadStartSpan.start, to: closeSpan.end)
        let argSpan = Span(start: payloadStartSpan.start, end: closeSpan.end, fileID: payloadStartSpan.fileID)
        cursor = closeIndex + 1
        return .macroCall(name: "asm", args: [.tokens(text, argSpan)], start.merged(with: closeSpan))
    }

    private func looksLikeExprTypeArgList(precedingName: String? = nil) -> Bool {
        guard at(.lBracket) else { return false }
        var i = cursor
        var depth = 0
        while i < tokens.count {
            let k = tokens[i].kind
            if k == .lBracket {
                depth += 1
            } else if k == .rBracket {
                depth -= 1
                if depth == 0 {
                    let next = i + 1 < tokens.count ? tokens[i + 1].kind : .eof
                    if next == .dot {
                        // name[...].field is ambiguous: Vec[Int].new() vs v[0].field
                        // Treat as type args only if the preceding name starts uppercase (type name).
                        if let name = precedingName, let first = name.first,
                           first.isLowercase || first == "_" {
                            return false
                        }
                        return true
                    }
                    return next == .lParen || next == .lBrace || next == .colonColon
                }
            } else if depth > 0 && isDefinitelyExprOnlyTokenInTypeArgs(k) {
                return false
            }
            i += 1
        }
        return false
    }

    private func isDefinitelyExprOnlyTokenInTypeArgs(_ kind: TokenKind) -> Bool {
        switch kind {
        case .plus, .minus, .slash, .percent,
             .plusEq, .minusEq, .slashEq, .percentEq,
             .eq, .eqEq, .bangEq,
             .dot, .dotDot, .dotDotEq,
             .ampAmp, .pipePipe, .caret,
             .kwIn, .kwAs:
            return true
        case .kwTrue, .kwFalse, .string, .char, .float:
            return true
        default:
            if case .integer(_) = kind { return true }
            return false
        }
    }

    /// Check if `<` starts a type argument list in a type context.
    /// Allows the generic to terminate before common delimiters or a newline.
    private func looksLikeTypeArgList() -> Bool {
        guard at(.lt) else { return false }
        var i = cursor
        var depth = 0
        while i < tokens.count {
            let k = tokens[i].kind
            if k == .lt {
                depth += 1
            } else if k == .gt {
                depth -= 1
                if depth == 0 {
                    let nextIndex = i + 1
                    let next = nextIndex < tokens.count ? tokens[nextIndex].kind : .eof
                    if next == .lParen || next == .lBrace || next == .colonColon || next == .rParen
                        || next == .comma || next == .gt || next == .eof || next == .rBracket
                        || next == .rBrace || next == .semi || next == .arrow || next == .colon
                        || next == .eq || next == .kwWhere || next == .kwThen || next == .kwElse
                        || next == .kwElsif || next == .kwWhen || next == .kwDo || next == .kwEnd {
                        return true
                    }
                    if nextIndex < tokens.count,
                       sourceRangeContainsNewline(from: tokens[i].span.end, to: tokens[nextIndex].span.start) {
                        return true
                    }
                    return false
                }
            } else if depth > 0 && isDefinitelyExprOnlyTokenInTypeArgs(k) {
                // If we see expression-only tokens inside, it's likely a comparison
                return false
            }
            i += 1
        }
        return false
    }

    private func parseOptionalReturnType() -> TypeExpr? {
        guard eat(.arrow) || eat(.colon) else { return nil }
        return parseTypeExpr()
    }

    private func parseOptionalWhereClause() -> [WherePredicate] {
        guard eat(.kwWhere) else { return [] }
        var preds: [WherePredicate] = []
        repeat {
            let start = currentSpan
            let ty = parseTypeExpr()
            expect(.colon)
            var bounds: [String] = []
            bounds.append(parseBoundName())
            while eat(.plus) {
                bounds.append(parseBoundName())
            }
            preds.append(WherePredicate(type: ty, bounds: bounds, span: start.merged(with: currentSpan)))
        } while eat(.comma)
        return preds
    }

    // MARK: - Struct

    private func parseStructItem(isPublic: Bool, kind: NominalKind = .value) -> ItemKind {
        let start = currentSpan
        advance() // skip 'struct'
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()
        let whereClause = parseOptionalWhereClause()

        if eat(.lBrace) {
            var fields: [FieldDecl] = []
            while !at(.rBrace) && !atEof() {
                let fStart = currentSpan
                let fPub = eat(.kwPub)
                let fName = expectIdent()
                expect(.colon)
                let fType = parseTypeExpr()
                fields.append(FieldDecl(name: fName, isPublic: fPub, type: fType,
                                        span: fStart.merged(with: currentSpan)))
                if !at(.rBrace) { eat(.comma) }
            }
            expect(.rBrace)
            return .structDef(StructDecl(name: name, isPublic: isPublic,
                                         typeParams: typeParams, whereClause: whereClause,
                                         fields: fields, kind: kind,
                                         span: start.merged(with: currentSpan)))
        }

        var fields: [FieldDecl] = []
        while !at(.kwEnd) && !atEof() {
            let fStart = currentSpan
            let fPub = eat(.kwPub)
            let fName = expectIdent()
            expect(.colon)
            let fType = parseTypeExpr()
            eat(.comma)
            fields.append(FieldDecl(name: fName, isPublic: fPub, type: fType,
                                    span: fStart.merged(with: currentSpan)))
        }
        expect(.kwEnd)

        return .structDef(StructDecl(name: name, isPublic: isPublic,
                                     typeParams: typeParams, whereClause: whereClause,
                                     fields: fields, kind: kind,
                                     span: start.merged(with: currentSpan)))
    }

    // MARK: - Resource

    private func parseResourceItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'resource'
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()
        let whereClause = parseOptionalWhereClause()

        var fields: [FieldDecl] = []
        while !at(.kwEnd) && !atEof() {
            if looksLikeFunctionDeclAfterModifiers(from: cursor) {
                _ = parseModifiedFunctionItem()
                continue
            }
            let fStart = currentSpan
            let fPub = eat(.kwPub)
            let fName = expectIdent()
            expect(.colon)
            let fType = parseTypeExpr()
            eat(.comma)
            fields.append(FieldDecl(name: fName, isPublic: fPub, type: fType,
                                    span: fStart.merged(with: currentSpan)))
        }
        expect(.kwEnd)

        return .structDef(StructDecl(name: name, isPublic: isPublic,
                                     typeParams: typeParams, whereClause: whereClause,
                                     fields: fields, kind: .resource,
                                     span: start.merged(with: currentSpan)))
    }

    // MARK: - Enum

    private func parseEnumItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'enum'
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()
        let whereClause = parseOptionalWhereClause()

        var variants: [VariantDecl] = []
        while !at(.kwEnd) && !atEof() {
            if eat(.semi) { continue } // semicolons separate variants
            let vStart = currentSpan
            let vName = expectIdent()
            var fields: [VariantField] = []
            if eat(.lParen) {
                while !at(.rParen) && !atEof() {
                    let fStart = currentSpan
                    // Check for named field: name: Type
                    var fieldName: String? = nil
                    if atIdent() && peekAhead(1) == .colon {
                        fieldName = expectIdent()
                        advance() // skip :
                    }
                    let fType = parseTypeExpr()
                    fields.append(VariantField(name: fieldName, type: fType,
                                               span: fStart.merged(with: currentSpan)))
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
            } else if eat(.lBrace) {
                // Struct-like variant: Variant { name: Type, ... }
                while !at(.rBrace) && !atEof() {
                    let fStart = currentSpan
                    let fieldName = expectIdent()
                    expect(.colon)
                    let fType = parseTypeExpr()
                    fields.append(VariantField(name: fieldName, type: fType,
                                               span: fStart.merged(with: currentSpan)))
                    if !at(.rBrace) { eat(.comma) }
                }
                expect(.rBrace)
            }
            variants.append(VariantDecl(name: vName, fields: fields,
                                        span: vStart.merged(with: currentSpan)))
        }
        expect(.kwEnd)

        return .enumDef(EnumDecl(name: name, isPublic: isPublic,
                                 typeParams: typeParams, whereClause: whereClause,
                                 variants: variants,
                                 span: start.merged(with: currentSpan)))
    }

    // MARK: - Trait

    private func parseTraitItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'trait'
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()

        var supertraits: [String] = []
        if eat(.colon) {
            supertraits.append(expectIdent())
            while eat(.plus) {
                supertraits.append(expectIdent())
            }
        }

        let whereClause = parseOptionalWhereClause()

        var methods: [FunctionDecl] = []
        var assocTypes: [TypeAliasDecl] = []
        while !at(.kwEnd) && !atEof() {
            if at(.kwType) {
                let tStart = currentSpan
                advance()
                let tName = expectIdent()
                let tParams = parseOptionalTypeParams()
                if eat(.eq) {
                    let value = parseTypeExpr()
                    assocTypes.append(TypeAliasDecl(name: tName, typeParams: tParams,
                                                    value: value, span: tStart.merged(with: currentSpan)))
                } else {
                    assocTypes.append(TypeAliasDecl(name: tName, typeParams: tParams,
                                                    value: .inferred(currentSpan),
                                                    span: tStart.merged(with: currentSpan)))
                }
            } else if looksLikeFunctionDeclAfterModifiers(from: cursor) {
                if let f = parseTraitMethod() {
                    methods.append(f)
                }
            } else {
                advance() // skip unrecognized
            }
        }
        expect(.kwEnd)

        return .traitDef(TraitDecl(name: name, isPublic: isPublic,
                                   typeParams: typeParams, supertraits: supertraits,
                                   whereClause: whereClause, methods: methods,
                                   associatedTypes: assocTypes,
                                   span: start.merged(with: currentSpan)))
    }

    /// Parse a method in a trait — may be signature-only or have a body.
    private func parseTraitMethod() -> FunctionDecl? {
        let mods = parseFunctionModifiers()
        guard at(.kwDef) else {
            diagnostics.error(code: "E1103", message: "expected 'def' after function modifiers", span: currentSpan, stage: .parser)
            return nil
        }
        expect(.kwDef)
        let start = currentSpan
        var name = expectIdent()
        while eat(.colonColon) { name += "::" + expectIdent() }
        let typeParams = parseOptionalTypeParams()
        expect(.lParen)
        var params = parseParamList()
        expect(.rParen)
        let retType = parseOptionalReturnType()
        let whereClause = parseOptionalWhereClause()
        consumeTrailingReceiverConvention(&params)

        let sig = FunctionSig(
            name: name, isPublic: mods.isPublic,
            isAsync: mods.isAsync, isUnsafe: mods.isUnsafe, isConst: mods.isConst,
            isPure: mods.isPure, isInline: mods.isInline, isExtern: mods.isExtern,
            typeParams: typeParams, params: params,
            returnType: retType, whereClause: whereClause,
            span: start.merged(with: currentSpan)
        )

        // Check if this is signature-only:
        // If the next token is def, type, end, or an attribute, then no body.
        if looksLikeFunctionDeclAfterModifiers(from: cursor) || at(.kwType) || at(.kwEnd) || at(.at) || atEof() {
            return FunctionDecl(sig: sig, body: .signatureOnly,
                                span: start.merged(with: currentSpan))
        }

        // Parse body
        let clauses = parseFunctionClauses()
        let body: FunctionBody
        if eat(.eq) {
            let expr = parseExpr()
            body = .expr(expr)
        } else if looksLikeAttributeOnlyBody(from: cursor, terminator: .kwEnd) {
            let block = parseAttributeOnlyBlock(terminator: .kwEnd)
            expect(.kwEnd)
            body = .block(block)
        } else {
            let block = parseBlock()
            expect(.kwEnd)
            body = .block(block)
        }

        return FunctionDecl(sig: sig, clauses: clauses, body: body,
                    span: start.merged(with: currentSpan))
    }

    // MARK: - Impl

    private func parseImplItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'impl'
        let typeParams = parseOptionalTypeParams()

        var traitName: String? = nil
        var targetType: String
        var forType: TypeExpr? = nil

        // Parse header — could be "TraitType for TargetType" or just "TargetType"
        let firstType = parseTypeExpr()
        if eat(.kwFor) {
            traitName = baseTypeName(firstType)
            let targetExpr = parseTypeExpr()
            targetType = baseTypeName(targetExpr)
            forType = targetExpr
        } else {
            targetType = baseTypeName(firstType)
        }

        let whereClause = parseOptionalWhereClause()
        let isBraceBody = eat(.lBrace)

        var methods: [FunctionDecl] = []
        var assocTypes: [TypeAliasDecl] = []
        var consts: [ConstDecl] = []

        while !(isBraceBody ? at(.rBrace) : at(.kwEnd)) && !atEof() {
            if looksLikeFunctionDeclAfterModifiers(from: cursor) || at(.at) {
                let attrs = parseAttributes()
                if looksLikeFunctionDeclAfterModifiers(from: cursor),
                   let item = parseModifiedFunctionItem(),
                   case .function(let f) = item {
                    _ = attrs
                    methods.append(f)
                }
            } else if at(.kwType) {
                let tStart = currentSpan
                advance()
                let tName = expectIdent()
                expect(.eq)
                let value = parseTypeExpr()
                assocTypes.append(TypeAliasDecl(name: tName, value: value,
                                                span: tStart.merged(with: currentSpan)))
            } else if at(.kwConst) {
                if case .constDecl(let c) = parseConstItem(isPublic: false) {
                    consts.append(c)
                }
            } else if at(.at) {
                // Skip attributes on methods — they'll be read when we re-enter the loop
                let _ = parseAttributes()
            } else {
                advance()
            }
        }
        if isBraceBody {
            expect(.rBrace)
        } else {
            expect(.kwEnd)
        }

        return .implBlock(ImplDecl(typeParams: typeParams, traitName: traitName,
                                   targetType: targetType, forType: forType,
                                   whereClause: whereClause, methods: methods,
                                   associatedTypes: assocTypes, consts: consts,
                                   span: start.merged(with: currentSpan)))
    }

    private func baseTypeName(_ ty: TypeExpr) -> String {
        switch ty {
        case .named(let name, _, _):
            return name
        case .selfType:
            return "Self"
        case .ref(let inner, _, _):
            return baseTypeName(inner)
        case .rawPtr(let inner, _, _):
            return baseTypeName(inner)
        case .slice(let inner, _):
            return baseTypeName(inner)
        case .array(let inner, _, _):
            return baseTypeName(inner)
        case .option(let inner, _):
            return baseTypeName(inner)
        default:
            return "_"
        }
    }

    // MARK: - Use

    private func parseUseItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'use'
        let path = parseUsePath()
        return .useDecl(UseDecl(path: path, span: start.merged(with: currentSpan)))
    }

    private func parseUsePath() -> UsePath {
        var segments: [String] = []

        // First segment: crate, super, self, or ident
        switch peekKind() {
        case .kwCrate:  advance(); segments.append("crate")
        case .kwSuper:  advance(); segments.append("super")
        case .kwSelfValue: advance(); segments.append("self")
        default:        segments.append(expectIdent())
        }

        while eat(.colonColon) {
            // Check for glob: use a::b::*
            if eat(.star) {
                return .glob(segments)
            }
            // Check for group: use a::b::{c, d}
            if eat(.lBrace) {
                var items: [UseItem] = []
                while !at(.rBrace) && !atEof() {
                    let iStart = currentSpan
                    let name = expectIdent()
                    var alias: String? = nil
                    if eat(.kwAs) {
                        alias = expectIdent()
                    }
                    items.append(UseItem(name: name, alias: alias, span: iStart.merged(with: currentSpan)))
                    if !at(.rBrace) { eat(.comma) }
                }
                expect(.rBrace)
                return .group(segments, items)
            }
            // Normal segment
            segments.append(expectIdent())
        }

        // Check for alias: use a::b as c
        if eat(.kwAs) {
            let alias = expectIdent()
            return .aliased(segments, alias)
        }

        return .simple(segments)
    }

    // MARK: - Const

    private func parseConstItem(isPublic: Bool) -> ItemKind? {
        let start = currentSpan
        advance() // skip 'const'
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeExpr()
        expect(.eq)
        let value = parseExpr()
        return .constDecl(ConstDecl(name: name, isPublic: isPublic, type: type, value: value,
                                    span: start.merged(with: currentSpan)))
    }

    // MARK: - Static

    private func parseStaticItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'static'
        let isMut = eat(.kwMut)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeExpr()
        expect(.eq)
        let value = parseExpr()
        return .staticDecl(StaticDecl(name: name, isPublic: isPublic, isMutable: isMut,
                                      type: type, value: value,
                                      span: start.merged(with: currentSpan)))
    }

    /// Parse top-level let/mut binding (desugars to staticDecl)
    private func parseTopLevelLet(isPublic: Bool, isMutable: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'let' or 'mut'
        let isMut = isMutable || eat(.kwMut)
        let name = expectIdent()
        var type: TypeExpr? = nil
        if eat(.colon) {
            type = parseTypeExpr()
        }
        expect(.eq)
        let value = parseExpr()
        let typeExpr = type ?? .inferred(currentSpan)
        return .staticDecl(StaticDecl(name: name, isPublic: isPublic, isMutable: isMut,
                                      type: typeExpr, value: value,
                                      span: start.merged(with: currentSpan)))
    }

    // MARK: - Type Alias

    private func parseTypeAliasItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        // Skip 'type' or 'typealias' keyword
        if at(.kwType) {
            advance()
        } else if at(.kwTypealias) {
            advance()
        }
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()
        expect(.eq)
        let value = parseTypeExpr()
        return .typeAlias(TypeAliasDecl(name: name, isPublic: isPublic,
                                        typeParams: typeParams, value: value,
                                        span: start.merged(with: currentSpan)))
    }

    // MARK: - Extern

    private func parseExternItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'extern'
        let externHeaderEnd = tokens[max(0, cursor - 1)].span.end

        var abi: String? = nil
        if case .string(let s) = peekKind() {
            advance()
            abi = s
        }

        let abiHeaderEnd = tokens[max(0, cursor - 1)].span.end

        if looksLikeFunctionDeclAfterModifiers(from: cursor)
            && !sourceRangeContainsNewline(from: abi == nil ? externHeaderEnd : abiHeaderEnd,
                                           to: peek().span.start) {
            let items: [Item]
            if let fn = parseExternFunctionDecl() {
                items = [Item(kind: .function(fn), span: fn.span)]
            } else {
                items = []
            }
            eat(.kwEnd)
            return .externBlock(ExternBlockDecl(abi: abi, items: items,
                                                span: start.merged(with: currentSpan)))
        }

        // Block form (with optional `do`).
        // `extern "C"` blocks in std often omit `do`, and single-signature externs
        // also exist without a trailing `end`, so we parse one-or-more signatures
        // first and only require `end` when the block form is actually present.
        eat(.kwDo) // optional 'do'

        var items: [Item] = []
        while !at(.kwEnd) && !atEof() {
            let attrs = at(.at) ? parseAttributes() : []
            if looksLikeFunctionDeclAfterModifiers(from: cursor) {
                if let fn = parseExternFunctionDecl() {
                    items.append(Item(kind: .function(fn), attributes: attrs, span: fn.span))
                }
            } else if at(.kwFn) {
                advance()
                let sig = parseFunctionSig(isPublic: false, isExtern: true)
                let fn = FunctionDecl(sig: sig, body: .signatureOnly, span: sig.span)
                items.append(Item(kind: .function(fn), attributes: attrs, span: sig.span))
            } else if at(.kwStruct) {
                let kind = parseStructItem(isPublic: false)
                if case .structDef(let decl) = kind {
                    items.append(Item(kind: .structDef(decl), attributes: attrs, span: decl.span))
                }
            } else if at(.kwEnum) {
                let kind = parseEnumItem(isPublic: false)
                if case .enumDef(let decl) = kind {
                    items.append(Item(kind: .enumDef(decl), attributes: attrs, span: decl.span))
                }
            } else if !attrs.isEmpty {
                diagnostics.error(code: "E1102", message: "unexpected \(peek().kind.displayName) in extern block", span: currentSpan, stage: .parser)
                break
            } else {
                break
            }
        }
        if at(.kwEnd) {
            expect(.kwEnd)
        } else if items.count != 1 {
            expect(.kwEnd)
        }

        return .externBlock(ExternBlockDecl(abi: abi, items: items,
                                            span: start.merged(with: currentSpan)))
    }

    private func parseFunctionSig(isPublic: Bool, isAsync: Bool = false, isUnsafe: Bool = false,
                                  isConst: Bool = false, isPure: Bool = false,
                                  isInline: Bool = false, isExtern: Bool = false) -> FunctionSig {
        let start = currentSpan
        let (name, typeParams) = parseFunctionNameAndTypeParams()
        expect(.lParen)
        var params = parseParamList()
        expect(.rParen)
        let retType = parseOptionalReturnType()
        let whereClause = parseOptionalWhereClause()
        consumeTrailingReceiverConvention(&params)
        return FunctionSig(name: name, isPublic: isPublic, isAsync: isAsync,
                   isUnsafe: isUnsafe, isConst: isConst,
                   isPure: isPure, isInline: isInline, isExtern: isExtern,
                           typeParams: typeParams, params: params,
                           returnType: retType, whereClause: whereClause,
                           span: start.merged(with: currentSpan))
    }

    // MARK: - Module

    private func parseModuleItem(isPublic: Bool) -> ItemKind {
        let start = currentSpan
        advance() // skip 'module' or 'mod'
        var name = expectIdent()
        // Module names can be qualified: tg_compiler::registry
        while eat(.colonColon) {
            name += "::" + expectIdent()
        }

        // File-based module: just `mod name` with no body
        // Only treat as file-based if immediately at EOF or a different top-level item
        // starts on the SAME indentation level. Since our parser is simple and doesn't
        // track indentation, we use a simpler heuristic: if next token is NOT end and
        // we have any content, parse as inline module body until end.
        if atEof() {
            return .moduleDef(ModuleDecl(name: name, isPublic: isPublic,
                                         span: start.merged(with: currentSpan)))
        }

        // Inline module with body
        var items: [Item] = []
        while !at(.kwEnd) && !atEof() {
            if let item = parseItem() {
                items.append(item)
            } else {
                advance()
            }
        }
        expect(.kwEnd)

        return .moduleDef(ModuleDecl(name: name, isPublic: isPublic, items: items,
                                     span: start.merged(with: currentSpan)))
    }

    // MARK: - Capability (parsed but rejected by subset checker)

    private func parseCapabilityItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'cap'
        let name = expectIdent()
        var implies: [String] = []
        if eat(.kwImplies) {
            repeat {
                implies.append(expectIdent())
            } while eat(.comma)
        }
        eat(.kwEnd)
        return .capabilityDecl(CapabilityDecl(name: name, implies: implies,
                                              span: start.merged(with: currentSpan)))
    }

    // MARK: - Effect (parsed but rejected)

    private func parseEffectItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'effect'
        let name = expectIdent()
        let typeParams = parseOptionalTypeParams()
        var ops: [FunctionSig] = []
        while !at(.kwEnd) && !atEof() {
            if atIdent() {
                let sig = parseFunctionSig(isPublic: false)
                ops.append(sig)
            } else if at(.kwDef) {
                advance()
                let sig = parseFunctionSig(isPublic: false)
                ops.append(sig)
            } else {
                advance()
            }
        }
        expect(.kwEnd)
        return .effectDecl(EffectDecl(name: name, typeParams: typeParams, operations: ops,
                                      span: start.merged(with: currentSpan)))
    }

    // MARK: - Rationale (parsed but rejected)

    private func parseRationaleItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'rationale'
        var fields: [(key: String, value: String)] = []
        while !at(.kwEnd) && !atEof() {
            if atIdent() {
                let key = expectIdent()
                expect(.colon)
                if case .string(let s) = peekKind() {
                    advance()
                    fields.append((key: key, value: s))
                } else {
                    // Consume until end of line or next field
                    var text = ""
                    while !at(.kwEnd) && !atEof() && !atIdent() {
                        let tok = advance()
                        text += tok.kind.displayName + " "
                    }
                    // Trim trailing spaces manually (no Foundation dependency)
                    var trimmed = text
                    while trimmed.hasSuffix(" ") { trimmed = String(trimmed.dropLast()) }
                    while trimmed.hasPrefix(" ") { trimmed = String(trimmed.dropFirst()) }
                    fields.append((key: key, value: trimmed))
                }
            } else {
                advance()
            }
        }
        expect(.kwEnd)
        return .rationaleBlock(RationaleDecl(fields: fields, span: start.merged(with: currentSpan)))
    }

    // MARK: - Macro (parsed but rejected)

    private func parseMacroItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'macro'
        let name = expectIdent()
        _ = eat(.bang)
        expect(.lParen)
        var params: [(name: String, type: String)] = []
        while !at(.rParen) && !atEof() {
            let pName = expectIdent()
            expect(.colon)
            _ = parseTypeExpr()
            params.append((name: pName, type: "type"))
            if !at(.rParen) { eat(.comma) }
        }
        expect(.rParen)
        if eat(.arrow) {
            _ = parseTypeExpr()
        }
        let bodyStart = currentSpan
        var depth = 0
        while !atEof() {
            if at(.kwEnd) {
                if depth == 0 { break }
                depth -= 1
                _ = advance()
                continue
            }
            if isOpaqueMacroBodyBlockOpener(peekKind()) {
                depth += 1
            }
            _ = advance()
        }
        let body = BlockBody(stmts: [], tailExpr: nil, span: bodyStart.merged(with: currentSpan))
        expect(.kwEnd)
        return .macroDecl(MacroDecl(name: name, params: params, body: body,
                                    span: start.merged(with: currentSpan)))
    }

    private func isOpaqueMacroBodyBlockOpener(_ kind: TokenKind) -> Bool {
        switch kind {
        case .kwDo, .kwIf, .kwMatch, .kwFor, .kwWhile, .kwLoop,
             .kwHandle, .kwTry, .kwComptime, .kwUnsafe,
             .kwStruct, .kwResource, .kwEnum, .kwTrait, .kwImpl, .kwModule, .kwMod,
             .kwExtern:
            return true
        default:
            return false
        }
    }

    // MARK: - Edition (parsed but rejected)

    private func parseEditionItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'edition'
        let version: String
        if case .string(let v) = peekKind() {
            advance()
            version = v
        } else if case .integer(let v) = peekKind() {
            advance()
            version = v
        } else {
            version = "0"
            diagnostics.error(code: "E1105", message: "expected edition string or integer", span: currentSpan, stage: .parser)
        }
        // Check for edition block (edition YEAR ... end)
        if at(.kwEnd) || atEof() || atItemStart() {
            return .editionDecl(EditionDecl(version: version, span: start.merged(with: currentSpan)))
        }
        // Edition block with items
        var items: [Item] = []
        while !at(.kwEnd) && !atEof() {
            if let item = parseItem() {
                items.append(item)
            } else {
                advance()
            }
        }
        expect(.kwEnd)
        return .editionDecl(EditionDecl(version: version, items: items,
                                        span: start.merged(with: currentSpan)))
    }

    private func parseTestItem() -> ItemKind {
        let start = currentSpan
        advance() // skip 'test'
        let name: String
        if case .string(let s) = peekKind() {
            advance()
            name = s
        } else {
            diagnostics.error(code: "E1100", message: "expected string literal, found \(peek().kind.displayName)", span: currentSpan, stage: .parser)
            name = "<error>"
        }
        _ = eat(.kwDo)
        let body = parseBlock()
        expect(.kwEnd)
        return .testDecl(TestDecl(name: name, body: body, span: start.merged(with: currentSpan)))
    }

    // MARK: - Type Expressions

    private func parseTypeExpr() -> TypeExpr {
        var ty = parseTypePrimary()
        if allowsTrailingTypeBounds(ty) && eat(.plus) {
            var bounds: [TypeExpr] = [parseTypePrimary()]
            while eat(.plus) {
                bounds.append(parseTypePrimary())
            }
            ty = .bounded(ty, bounds: bounds, ty.span.merged(with: currentSpan))
        }
        // Option shorthand: T?
        if eat(.question) {
            return .option(ty, ty.span.merged(with: currentSpan))
        }
        return ty
    }

    private func allowsTrailingTypeBounds(_ ty: TypeExpr) -> Bool {
        switch ty {
        case .dynTrait, .implTrait, .bounded:
            return true
        default:
            return false
        }
    }

    private func parseTraitTypeReference() -> TypeExpr {
        let start = currentSpan
        var name = expectIdent()
        while eat(.colonColon) {
            name += "::" + expectIdent()
        }
        let typeArgs = parseOptionalTypeArgs()
        return .named(name, typeArgs: typeArgs, start.merged(with: currentSpan))
    }

    private func parseTypePrimary() -> TypeExpr {
        let start = currentSpan

        switch peekKind() {
        case .kwSelfTy:
            advance()
            // Self::AssocType
            if eat(.colonColon) {
                var name = "Self::" + expectIdent()
                while eat(.colonColon) {
                    name += "::" + expectIdent()
                }
                let typeArgs = parseOptionalTypeArgs()
                return .named(name, typeArgs: typeArgs, start.merged(with: currentSpan))
            }
            return .selfType(start.merged(with: currentSpan))

        case .kwFn, .kwDef:
            // fn(T, U) -> R or def(T, U) -> R
            advance()
            expect(.lParen)
            var params: [TypeExpr] = []
            while !at(.rParen) && !atEof() {
                if atIdent() && peekAhead(1) == .colon {
                    _ = expectIdent()
                    expect(.colon)
                }
                params.append(parseTypeExpr())
                if !at(.rParen) { eat(.comma) }
            }
            expect(.rParen)
            expect(.arrow)
            let ret = parseTypeExpr()
            return .fnPtr(params: params, ret: ret, start.merged(with: currentSpan))

        case .pipePipe:
            // Closure-style function type: || -> T
            advance()
            expect(.arrow)
            let ret = parseTypeExpr()
            return .fnPtr(params: [], ret: ret, start.merged(with: currentSpan))

        case .bang:
            advance()
            return .never(start.merged(with: currentSpan))

        case .ampAmp:
            advance()
            let inner = parseTypeExpr()
            let nested = TypeExpr.ref(inner, mutable: false, inner.span)
            return .ref(nested, mutable: false, start.merged(with: currentSpan))

        case .lParen:
            // Tuple, Unit, or function type: (), (T), () -> T
            advance()
            if eat(.rParen) {
                // Empty parens: could be Unit or function type () -> T
                // Check for ->
                if eat(.arrow) {
                    let ret = parseTypeExpr()
                    return .fnPtr(params: [], ret: ret, start.merged(with: currentSpan))
                }
                return .unit(start.merged(with: currentSpan))
            }
            var types: [TypeExpr] = [parseTypeExpr()]
            while eat(.comma) {
                if at(.rParen) { break }
                types.append(parseTypeExpr())
            }
            expect(.rParen)
            
            // Check for -> after tuple: (T, U) -> R
            if eat(.arrow) {
                let ret = parseTypeExpr()
                return .fnPtr(params: types, ret: ret, start.merged(with: currentSpan))
            }
            
            if types.count == 1 {
                return types[0] // (T) is just T
            }
            return .tuple(types, start.merged(with: currentSpan))

        case .amp:
            // &T or &mut T
            advance()
            let isMut = eat(.kwMut)
            let inner = parseTypeExpr()
            return .ref(inner, mutable: isMut, start.merged(with: currentSpan))

        case .star:
            // *T, *mut T, or *const T
            advance()
            let isMut: Bool
            if eat(.kwMut) {
                isMut = true
            } else {
                _ = eat(.kwConst)
                isMut = false
            }
            let inner = parseTypeExpr()
            return .rawPtr(inner, mutable: isMut, start.merged(with: currentSpan))

        case .lBracket:
            // [T] or [T; N]
            advance()
            let elem = parseTypeExpr()
            if eat(.semi) {
                let len = parseExpr()
                expect(.rBracket)
                return .array(elem, len: len, start.merged(with: currentSpan))
            }
            expect(.rBracket)
            return .slice(elem, start.merged(with: currentSpan))

        case .kwDyn:
            advance()
            let trait = parseTraitTypeReference()
            return .dynTrait(trait, start.merged(with: currentSpan))

        case .kwImpl:
            advance()
            let trait = parseTraitTypeReference()
            return .implTrait(trait, start.merged(with: currentSpan))

        case .ident:
            var name = expectIdent()
            // Multi-segment path: std::io::Result
            while eat(.colonColon) {
                name += "::" + expectIdent()
            }

            // Lowercase function pointer syntax: fn(T, U) -> R / def(T, U) -> R
            if (name == "fn" || name == "def") && at(.lParen) {
                advance()
                var params: [TypeExpr] = []
                while !at(.rParen) && !atEof() {
                    params.append(parseTypeExpr())
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
                expect(.arrow)
                let ret = parseTypeExpr()
                return .fnPtr(params: params, ret: ret, start.merged(with: currentSpan))
            }

// Fn(T, U) -> R / FnMut(...) / FnOnce(...)
            if (name == "Fn" || name == "FnMut" || name == "FnOnce") {
                if at(.lBracket) {
                    _ = parseOptionalTypeArgs()
                }
                if at(.lParen) {
                    advance() // '('
                    var params: [TypeExpr] = []
                    while !at(.rParen) && !atEof() {
                        params.append(parseTypeExpr())
                        if !at(.rParen) { eat(.comma) }
                    }
                    expect(.rParen)
                    expect(.arrow)
                    let ret = parseTypeExpr()
                    return .fnPtr(params: params, ret: ret, start.merged(with: currentSpan))
                }
            }

            let typeArgs = parseOptionalTypeArgs()
            return .named(name, typeArgs: typeArgs, start.merged(with: currentSpan))

        default:
            // Handle soft keywords that can be type names (e.g., mod::Type paths)
            if atIdent() {
                var name = expectIdent()
                while eat(.colonColon) {
                    name += "::" + expectIdent()
                }
                let typeArgs = parseOptionalTypeArgs()
                return .named(name, typeArgs: typeArgs, start.merged(with: currentSpan))
            }
            diagnostics.error(
                code: "E1110",
                message: "expected type expression, found \(peek().kind.displayName)",
                span: currentSpan,
                stage: .parser
            )
            advance()
            return .inferred(start)
        }
    }

    // MARK: - Blocks

    private func parseBlock() -> BlockBody {
        return parseBlock(terminator: nil)
    }

    private func parseBlock(terminator: TokenKind?) -> BlockBody {
        let start = currentSpan
        eat(.kwDo) // optional 'do'
        var stmts: [Stmt] = []
        var tailExpr: Expr? = nil

        func atBlockEnd() -> Bool {
            if let term = terminator, at(term) { return true }
            return at(.kwEnd) || at(.kwElse) || at(.kwElsif) || at(.kwWhen) || at(.kwCatch) || at(.kwFinally) || atEof()
        }

        while !atBlockEnd() {
            // Skip semicolons (statement separators)
            if eat(.semi) { continue }
            if let stmt = parseStatement() {
                stmts.append(stmt)
            } else {
                break
            }
        }

        // Check if last statement could be a tail expression
        if let last = stmts.last, case .exprStmt(let expr, _) = last {
            if atBlockEnd() {
                tailExpr = expr
                stmts.removeLast()
            }
        }

        return BlockBody(stmts: stmts, tailExpr: tailExpr, span: start.merged(with: currentSpan))
    }

    // MARK: - Statements

    private func parseAttributedStatement() -> Stmt? {
        let start = currentSpan
        let attrs = parseAttributes()

        if looksLikeBlockItemStart(from: cursor), var item = parseItem() {
            item.attributes = attrs + item.attributes
            return .item(item)
        }

        if at(.kwLet) {
            let stmt = parseLetStatement()
            return .attributed(attrs, stmt, start.merged(with: currentSpan))
        }

        if at(.kwMut) && peekAhead(1) != .kwSelfValue {
            let stmt = parseMutStatement()
            return .attributed(attrs, stmt, start.merged(with: currentSpan))
        }

        if atVarBinding() {
            let stmt = parseMutStatement()
            return .attributed(attrs, stmt, start.merged(with: currentSpan))
        }

        if atExprStart() {
            let expr = parseExpr()
            let inner = Stmt.exprStmt(expr, start.merged(with: currentSpan))
            return .attributed(attrs, inner, start.merged(with: currentSpan))
        }

        return .attributeStmt(attrs, start.merged(with: currentSpan))
    }

    private func parseStatement() -> Stmt? {
        let start = currentSpan

        if at(.at) {
            return parseAttributedStatement()
        }

        // Let binding
        if at(.kwLet) {
            return parseLetStatement()
        }

        // Mut shorthand for let mut
        if at(.kwMut) && peekAhead(1) != .kwSelfValue {
            return parseMutStatement()
        }

        // var x: T = value — sugar for let mut
        if atVarBinding() {
            return parseMutStatement()
        }

        // defer statement
        if at(.kwDefer) {
            return parseDeferStmt()
        }

        // Items inside blocks (limited set — not module, enum, trait, extern, etc.)
        if atBlockItemStart() {
            if let item = parseItem() {
                return .item(item)
            }
        }

        // Expression statement
        if atExprStart() {
            let expr = parseExpr()
            return .exprStmt(expr, start.merged(with: currentSpan))
        }

        return nil
    }

    private func parseDeferStmt() -> Stmt {
        let start = currentSpan
        advance() // skip 'defer'
        let body = parseBlock()
        expect(.kwEnd)
        return .deferStmt(body, start.merged(with: currentSpan))
    }

    private func parseLetStatement() -> Stmt {
        let start = currentSpan
        advance() // skip 'let'
        let isMut = eat(.kwMut)
        let pat = parsePattern()
        var typeAnn: TypeExpr? = nil
        if eat(.colon) {
            typeAnn = parseTypeExpr()
        }
        expect(.eq)
        let value = parseExpr()
        return .letBinding(pattern: pat, mutable: isMut, type: typeAnn, value: value,
                           start.merged(with: currentSpan))
    }

    private func parseMutStatement() -> Stmt {
        let start = currentSpan
        advance() // skip 'mut'
        let pat = parsePattern()
        var typeAnn: TypeExpr? = nil
        if eat(.colon) {
            typeAnn = parseTypeExpr()
        }
        expect(.eq)
        let value = parseExpr()
        return .letBinding(pattern: pat, mutable: true, type: typeAnn, value: value,
                           start.merged(with: currentSpan))
    }

    // MARK: - Expressions

    public func parseExpr() -> Expr {
        return parseAssignment()
    }

    private func parseAssignment() -> Expr {
        let expr = parseRange()

        // Check for assignment
        if at(.eq) {
            let start = expr.span
            advance()
            let value = parseAssignment()
            return .assign(target: expr, value: value, start.merged(with: currentSpan))
        }
        // Compound assignment
        if let op = compoundAssignOp() {
            let start = expr.span
            advance()
            let value = parseAssignment()
            return .compoundAssign(target: expr, op: op, value: value, start.merged(with: currentSpan))
        }

        return expr
    }

    private func compoundAssignOp() -> BinaryOp? {
        switch peekKind() {
        case .plusEq:    return .add
        case .minusEq:  return .sub
        case .starEq:   return .mul
        case .slashEq:  return .div
        case .percentEq: return .mod
        case .caretEq:  return .bitXor
        default:        return nil
        }
    }

    private func parseRange() -> Expr {
        let expr = parseLogicalOr()

        if at(.dotDot) || at(.dotDotEq) {
            let inclusive = peekKind() == .dotDotEq
            let start = expr.span
            advance()
            let end: Expr
            if at(.rBracket) || at(.rParen) || at(.comma) || at(.semi)
                || at(.kwDo) || at(.kwThen) || at(.kwEnd) || atEof() {
                end = .name("__range_end__", currentSpan)
            } else {
                end = parseLogicalOr()
            }
            return .range(start: expr, end: end, inclusive: inclusive, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseLogicalOr() -> Expr {
        var expr = parseLogicalAnd()
        while at(.pipePipe) {
            let start = expr.span
            advance()
            let right = parseLogicalAnd()
            expr = .binary(left: expr, op: .or, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseLogicalAnd() -> Expr {
        var expr = parseEquality()
        while at(.ampAmp) {
            let start = expr.span
            advance()
            let right = parseEquality()
            expr = .binary(left: expr, op: .and, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseEquality() -> Expr {
        var expr = parseComparison()
        while at(.eqEq) || at(.bangEq) {
            let op: BinaryOp = peekKind() == .eqEq ? .eq : .notEq
            let start = expr.span
            advance()
            let right = parseComparison()
            expr = .binary(left: expr, op: op, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseComparison() -> Expr {
        var expr = parseBitwiseOr()
        while at(.lt) || at(.gt) || at(.ltEq) || at(.gtEq) {
            let op: BinaryOp
            switch peekKind() {
            case .lt:   op = .lt
            case .gt:   op = .gt
            case .ltEq: op = .ltEq
            case .gtEq: op = .gtEq
            default:    op = .lt  // unreachable: while guard ensures one of the above
            }
            let start = expr.span
            advance()
            let right = parseBitwiseOr()
            expr = .binary(left: expr, op: op, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseBitwiseOr() -> Expr {
        var expr = parseBitwiseXor()
        while at(.pipe) {
            let start = expr.span
            advance()
            let right = parseBitwiseXor()
            expr = .binary(left: expr, op: .bitOr, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseBitwiseXor() -> Expr {
        var expr = parseBitwiseAnd()
        while at(.caret) {
            let start = expr.span
            advance()
            let right = parseBitwiseAnd()
            expr = .binary(left: expr, op: .bitXor, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseBitwiseAnd() -> Expr {
        var expr = parseShift()
        while at(.amp) && peekAhead(1) != .kwMut {
            let start = expr.span
            advance()
            let right = parseShift()
            expr = .binary(left: expr, op: .bitAnd, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseShift() -> Expr {
        var expr = parseAddition()
        while at(.shl) || at(.shr) {
            let op: BinaryOp = peekKind() == .shl ? .shl : .shr
            let start = expr.span
            advance()
            let right = parseAddition()
            expr = .binary(left: expr, op: op, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseAddition() -> Expr {
        var expr = parseMultiplication()
        while at(.plus) || at(.minus) {
            let op: BinaryOp = peekKind() == .plus ? .add : .sub
            let start = expr.span
            advance()
            let right = parseMultiplication()
            expr = .binary(left: expr, op: op, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseMultiplication() -> Expr {
        var expr = parseUnary()
        while at(.star) || at(.slash) || at(.percent) {
            let op: BinaryOp
            switch peekKind() {
            case .star:    op = .mul
            case .slash:   op = .div
            case .percent: op = .mod
            default:       op = .mul  // unreachable: while guard ensures one of the above
            }
            let start = expr.span
            advance()
            let right = parseUnary()
            expr = .binary(left: expr, op: op, right: right, start.merged(with: currentSpan))
        }
        return expr
    }

    private func parseUnary() -> Expr {
        let start = currentSpan

        switch peekKind() {
        case .minus:
            advance()
            let expr = parseUnary()
            return .unary(op: .neg, expr: expr, start.merged(with: currentSpan))
        case .bang:
            advance()
            let expr = parseUnary()
            return .unary(op: .not, expr: expr, start.merged(with: currentSpan))
        case .tilde:
            advance()
            let expr = parseUnary()
            return .unary(op: .bitNot, expr: expr, start.merged(with: currentSpan))
        case .star:
            advance()
            let expr = parseUnary()
            return .unary(op: .deref, expr: expr, start.merged(with: currentSpan))
        case .amp:
            advance()
            if eat(.kwMut) {
                let expr = parseUnary()
                return .unary(op: .borrowMut, expr: expr, start.merged(with: currentSpan))
            }
            let expr = parseUnary()
            return .unary(op: .borrow, expr: expr, start.merged(with: currentSpan))
        default:
            return parsePostfix()
        }
    }

    private func parsePostfix() -> Expr {
        var expr = parsePrimary()

        while true {
            if at(.dot) {
                let start = expr.span
                advance()
                // Await: expr.await (reserved, parsed but rejected)
                if at(.kwAwait) {
                    advance()
                    expr = .awaitExpr(expr, start.merged(with: currentSpan))
                    continue
                }
                // Numeric tuple field: expr.0, expr.1
                if case .integer(let n) = peekKind() {
                    advance()
                    expr = .field(base: expr, field: n, start.merged(with: currentSpan))
                    continue
                }
                let field = expectIdent()
                // Method turbofish: expr.method::<T, U>(...)
                if eat(.colonColon) {
                    if at(.lt) {
                        _ = parseTurbofishTypeArgs()
                    } else {
                        diagnostics.error(code: "E1100", message: "expected '<' after '::' in method type arguments", span: currentSpan, stage: .parser)
                    }
                }
                if looksLikeBracketMethodTypeArgsStart() {
                    _ = parseOptionalTypeArgs()
                }
                // Method call: expr.method(args)
                if at(.lParen) {
                    advance()
                    let args = parseArgList()
                    expect(.rParen)
                    let callExpr = Expr.field(base: expr, field: field, start.merged(with: currentSpan))
                    expr = .call(callee: callExpr, typeArgs: [], args: args, start.merged(with: currentSpan))
                } else {
                    expr = .field(base: expr, field: field, start.merged(with: currentSpan))
                }
            } else if at(.lParen) {
                // Don't treat ( as a call if there's a newline between
                // the previous token and the opening paren — it's a new expression.
                if sourceRangeContainsNewline(from: previousTokenEnd, to: currentSpan.start) {
                    break
                }
                let start = expr.span
                advance()
                let args = parseArgList()
                expect(.rParen)
                expr = .call(callee: expr, typeArgs: [], args: args, start.merged(with: currentSpan))
            } else if at(.lBracket) {
                // Same newline check for index expressions
                if sourceRangeContainsNewline(from: previousTokenEnd, to: currentSpan.start) {
                    break
                }
                let start = expr.span
                advance()
                let index: Expr
                if at(.dotDot) || at(.dotDotEq) {
                    let inclusive = peekKind() == .dotDotEq
                    advance()
                    let endExpr: Expr
                    if at(.rBracket) {
                        endExpr = .name("__range_end__", currentSpan)
                    } else {
                        endExpr = parseExpr()
                    }
                    let startExpr = Expr.name("__range_start__", currentSpan)
                    index = .range(start: startExpr, end: endExpr, inclusive: inclusive,
                                   start.merged(with: currentSpan))
                } else {
                    index = parseExpr()
                }
                expect(.rBracket)
                expr = .index(base: expr, index: index, start.merged(with: currentSpan))
            } else if at(.question) {
                let start = expr.span
                advance()
                expr = .tryOp(expr, start.merged(with: currentSpan))
            } else if at(.kwAs) {
                let start = expr.span
                advance()
                let type = parseTypeExpr()
                expr = .cast(expr: expr, type: type, start.merged(with: currentSpan))
            } else {
                break
            }
        }
        return expr
    }

    // MARK: - Primary Expressions

    private func parsePrimary() -> Expr {
        let start = currentSpan

        switch peekKind() {
        case .integer(let s):
            advance()
            return .intLit(s, start)

        case .float(let s):
            advance()
            return .floatLit(s, start)

        case .string(let s):
            advance()
            return .stringLit(s, start)

        case .char(let c):
            advance()
            return .charLit(c, start)

        case .kwTrue:
            advance()
            return .boolLit(true, start)

        case .kwFalse:
            advance()
            return .boolLit(false, start)

        case .kwSelfValue:
            advance()
            if eat(.colonColon) {
                var fullName = "self"
                if atIdent() {
                    fullName += "::" + expectIdent()
                    while eat(.colonColon) {
                        if atIdent() { fullName += "::" + expectIdent() } else { break }
                    }
                }
                if at(.lParen) {
                    advance()
                    let args = parseArgList()
                    expect(.rParen)
                    return .call(callee: .name(fullName, start.merged(with: currentSpan)),
                                 typeArgs: [], args: args, start.merged(with: currentSpan))
                }
                return .name(fullName, start.merged(with: currentSpan))
            }
            return .name("self", start)

        case .kwSelfTy:
            advance()
            if eat(.colonColon) {
                var fullName = "Self"
                if atIdent() {
                    fullName += "::" + expectIdent()
                    while eat(.colonColon) {
                        if atIdent() { fullName += "::" + expectIdent() } else { break }
                    }
                }
                if at(.lBrace) && isStructLiteralContext(fullName) {
                    return parseStructLiteral(name: fullName, start: start)
                }
                if looksLikeEndStructLiteral(fullName) {
                    return parseEndStructLiteral(name: fullName, start: start)
                }
                if at(.lParen) {
                    advance()
                    let args = parseArgList()
                    expect(.rParen)
                    return .call(callee: .name(fullName, start.merged(with: currentSpan)),
                                 typeArgs: [], args: args, start.merged(with: currentSpan))
                }
                return .name(fullName, start.merged(with: currentSpan))
            }
            return .name("Self", start)

        case .ident(let name):
            advance()
            if name == "b", case .string(let s) = peekKind() {
                _ = advance()
                return .stringLit(s, start.merged(with: currentSpan))
            }
            if name == "asm", let inlineAsm = parseInlineAsmExpr(start: start) {
                return inlineAsm
            }
            // Multi-segment path: A::B::C
            if eat(.colonColon) {
                var fullName = name
                if atIdent() {
                    fullName += "::" + expectIdent()
                    while eat(.colonColon) {
                        if atIdent() {
                            fullName += "::" + expectIdent()
                        } else {
                            break
                        }
                    }
                }
                let typeArgs = parseOptionalExprTypeArgs(precedingName: fullName)
                // Check for struct literal: Name::Path { ... }
                if at(.lBrace) && isStructLiteralContext(fullName) {
                    return parseStructLiteral(name: fullName, typeArgs: typeArgs, start: start)
                }
                // Check for end-block struct literal: Name::Path\n  field: value\nend
                if looksLikeEndStructLiteral(fullName) {
                    return parseEndStructLiteral(name: fullName, typeArgs: typeArgs, start: start)
                }
                // Check for call: Path(args)
                if at(.lParen) {
                    advance()
                    let args = parseArgList()
                    expect(.rParen)
                    return .call(callee: .name(fullName, start.merged(with: currentSpan)),
                                 typeArgs: typeArgs, args: args, start.merged(with: currentSpan))
                }
                return .name(fullName, start.merged(with: currentSpan))
            }
            let typeArgs = parseOptionalExprTypeArgs(precedingName: name)
            if eat(.colonColon) {
                var fullName = name
                if atIdent() {
                    fullName += "::" + expectIdent()
                    while eat(.colonColon) {
                        if atIdent() {
                            fullName += "::" + expectIdent()
                        } else {
                            break
                        }
                    }
                }
                if at(.lBrace) && isStructLiteralContext(fullName) {
                    return parseStructLiteral(name: fullName, typeArgs: typeArgs, start: start)
                }
                if looksLikeEndStructLiteral(fullName) {
                    return parseEndStructLiteral(name: fullName, typeArgs: typeArgs, start: start)
                }
                if at(.lParen) {
                    advance()
                    let args = parseArgList()
                    expect(.rParen)
                    return .call(callee: .name(fullName, start.merged(with: currentSpan)),
                                 typeArgs: typeArgs, args: args, start.merged(with: currentSpan))
                }
                return .name(fullName, start.merged(with: currentSpan))
            }
            // Check for struct literal: Name { ... }
            if at(.lBrace) {
                if isStructLiteralContext(name) {
                    return parseStructLiteral(name: name, typeArgs: typeArgs, start: start)
                }
            }
            // Check for end-block struct literal: Name\n  field: value\nend
            if looksLikeEndStructLiteral(name) {
                return parseEndStructLiteral(name: name, typeArgs: typeArgs, start: start)
            }
            // Check for macro call: name!(args)
            if at(.bang) && peekAhead(1) == .lParen {
                advance() // skip !
                advance() // skip (
                let args = parseMacroArgs(until: .rParen)
                expect(.rParen)
                return .macroCall(name: name, args: args, start.merged(with: currentSpan))
            }
            // Check for macro call: name![...]
            if at(.bang) && peekAhead(1) == .lBracket {
                advance() // skip !
                advance() // skip [
                let args = parseMacroArgs(until: .rBracket)
                expect(.rBracket)
                return .macroCall(name: name, args: args, start.merged(with: currentSpan))
            }
            return .name(name, start)

        case .lParen:
            // Tuple or grouping
            advance()
            if eat(.rParen) {
                return .tuple([], start.merged(with: currentSpan))
            }
            let first = parseExpr()
            if eat(.comma) {
                // Tuple
                var elements = [first]
                while !at(.rParen) && !atEof() {
                    elements.append(parseExpr())
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
                return .tuple(elements, start.merged(with: currentSpan))
            }
            expect(.rParen)
            return first // grouping parens

        case .lBracket:
            // Array literal or array repeat
            advance()
            if eat(.rBracket) {
                return .array([], start.merged(with: currentSpan))
            }
            let first = parseExpr()
            if eat(.semi) {
                let count = parseExpr()
                expect(.rBracket)
                return .arrayRepeat(value: first, count: count, start.merged(with: currentSpan))
            }
            var elements = [first]
            while eat(.comma) {
                if at(.rBracket) { break }
                elements.append(parseExpr())
            }
            expect(.rBracket)
            return .array(elements, start.merged(with: currentSpan))

        case .lBrace:
            // Brace block expression: { stmt; stmt; tail_expr }
            advance() // skip {
            let block = parseBlock(terminator: .rBrace)
            expect(.rBrace)
            return .block(block, start.merged(with: currentSpan))

        case .kwIf:
            return parseIfExpr()

        case .kwUnless:
            return parseUnlessExpr()

        case .kwMatch:
            return parseMatchExpr()

        case .kwFor:
            return parseForExpr()

        case .kwWhile:
            return parseWhileExpr()

        case .kwUntil:
            return parseUntilExpr()

        case .kwLoop:
            return parseLoopExpr()

        case .kwDo:
            return parseDoBlock()

        case .kwReturn:
            advance()
            if atExprStart() && !at(.kwEnd) && !at(.kwWhen) && !at(.kwElse) && !at(.kwElsif) {
                let val = parseExpr()
                return .returnExpr(val, start.merged(with: currentSpan))
            }
            return .returnExpr(nil, start)

        case .kwBreak:
            advance()
            return .breakExpr(nil, start)

        case .kwNext:
            // Only treat as control flow if not followed by ., ::, or (
            if peekAhead(1) == .dot || peekAhead(1) == .colonColon || peekAhead(1) == .lParen {
                advance()
                return .name("next", start)
            }
            advance()
            return .nextExpr(start)

        case .kwUnsafe:
            return parseUnsafeBlock()

        case .pipe:
            return parseClosureExpr()

        case .pipePipe:
            // Zero-parameter closure: || expr
            return parseZeroParamClosure()

        case .kwHandle:
            // `handle` is a soft keyword; allow it as an identifier in value position
            // (e.g. `&mut handle`, `handle()`, `foo(handle)`), and only parse the
            // effect-handling construct when followed by an expression payload.
            switch peekAhead(1) {
            case .rParen, .comma, .dot, .colonColon, .eq, .semi, .kwEnd, .kwThen,
                 .kwWhen, .kwElse, .kwElsif, .rBracket, .rBrace, .lParen,
                 .lt, .gt, .ltEq, .gtEq, .eqEq, .bangEq,
                 .plus, .minus, .star, .slash, .percent,
                 .ampAmp, .pipePipe, .amp, .pipe, .caret,
                 .shl, .shr, .dotDot, .dotDotEq:
                advance()
                return .name("handle", start)
            default:
                return parseHandleExpr()
            }

        case .kwTry:
            return parseTryExpr()

        case .kwComptime:
            advance()
            let block = parseBlock()
            expect(.kwEnd)
            return .comptimeBlock(block, start.merged(with: currentSpan))

        default:
            // Handle soft keywords used as expressions (method/function names)
            if atIdent() {
                let name = expectIdent()
                // Byte-string literal prefix: b"..."
                if name == "b", case .string(let s) = peekKind() {
                    _ = advance()
                    return .stringLit(s, start.merged(with: currentSpan))
                }
                // Check for :: path
                if eat(.colonColon) {
                    var fullName = name
                    if atIdent() {
                        fullName += "::" + expectIdent()
                        while eat(.colonColon) {
                            if atIdent() { fullName += "::" + expectIdent() } else { break }
                        }
                    }
                    if at(.lParen) {
                        advance()
                        let args = parseArgList()
                        expect(.rParen)
                        return .call(callee: .name(fullName, start.merged(with: currentSpan)),
                                     typeArgs: [], args: args, start.merged(with: currentSpan))
                    }
                    return .name(fullName, start.merged(with: currentSpan))
                }
                return .name(name, start.merged(with: currentSpan))
            }
            diagnostics.error(
                code: "E1120",
                message: "expected expression, found \(peek().kind.displayName)",
                span: currentSpan,
                stage: .parser
            )
            advance()
            return .boolLit(false, start) // error recovery
        }
    }

    // MARK: - Control Flow Expressions

    private func parseIfExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'if'
        let branch = parseIfBranch()
        var elsifClauses: [(condition: Expr, body: BlockBody, pattern: Pattern?, value: Expr?)] = []
        while at(.kwElsif) || isAtInlineElseIf() {
            if at(.kwElsif) {
                advance()
            } else {
                advance() // else
                advance() // if
            }
            let eBranch = parseIfBranch()
            elsifClauses.append((condition: eBranch.guard, body: eBranch.body,
                                 pattern: eBranch.pattern, value: eBranch.value))
        }
        var elseBlock: BlockBody? = nil
        if eat(.kwElse) {
            elseBlock = parseBlock()
        }
        expect(.kwEnd)
        return .ifExpr(IfExpr(condition: branch.guard, thenBlock: branch.body,
                              elsifClauses: elsifClauses.map { ($0.condition, $0.body) },
                              elseBlock: elseBlock,
                              ifLetPattern: branch.pattern, ifLetValue: branch.value,
                              span: start.merged(with: currentSpan)))
    }

    private struct IfBranchResult {
        var `guard`: Expr
        var body: BlockBody
        var pattern: Pattern?
        var value: Expr?
    }

    private func parseIfBranch() -> IfBranchResult {
        if eat(.kwLet) {
            // if let Pattern = expr
            let pat = parsePattern()
            expect(.eq)
            let val = parseExpr()
            eat(.kwThen)
            let body = parseBlock()
            // For the guard condition, we synthesize a placeholder true — the real
            // semantics come from pattern + value.
            return IfBranchResult(guard: .boolLit(true, currentSpan),
                                  body: body, pattern: pat, value: val)
        }
        let cond = parseExpr()
        eat(.kwThen)
        let body = parseBlock()
        return IfBranchResult(guard: cond, body: body)
    }

    private func parseUnlessExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'unless'
        let cond = parseExpr()
        eat(.kwThen)
        let body = parseBlock()
        var elseBlock: BlockBody? = nil
        if eat(.kwElse) {
            elseBlock = parseBlock()
        }
        expect(.kwEnd)
        return .unlessExpr(UnlessExpr(condition: cond, body: body, elseBlock: elseBlock,
                                      span: start.merged(with: currentSpan)))
    }

    private func parseMatchExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'match'
        let subject = parseExpr()

        // Brace-style match: match expr { P => body, ... }
        if at(.lBrace) {
            return parseBraceMatch(subject: subject, start: start)
        }

        var arms: [MatchArm] = []
        while at(.kwWhen) || at(.semi) || looksLikeArrowMatchArmStart() {
            if eat(.semi) { continue } // skip semicolons between arms
            let aStart = currentSpan

            let pat: Pattern
            let fromWhen = eat(.kwWhen)
            if fromWhen {
                pat = parsePattern()
            } else {
                pat = parsePattern()
            }

            var guard_: Expr? = nil
            if shouldParseInlineMatchGuard() {
                _ = eat(.kwIf)
                guard_ = parseExpr()
            }

            let usedFatArrow: Bool
            if fromWhen {
                usedFatArrow = eat(.fatArrow)
                if !usedFatArrow {
                    _ = eat(.kwThen)
                }
            } else if eat(.fatArrow) {
                usedFatArrow = true
            } else {
                diagnostics.error(code: "E1100", message: "expected '=>' in match arm", span: currentSpan, stage: .parser)
                break
            }

            // Arm body: can be a single expression or a block (with statements).
            // If the next token starts a statement (let, etc.) or multiple expressions,
            // parse as a block body until next `when` or `end`.
            let body: Expr
            if usedFatArrow {
                if isAtEmptyMatchArmBodyTerminator() {
                    body = .tuple([], currentSpan)
                } else if at(.kwLet) || at(.kwMut) || atVarBinding() || at(.at) {
                    let block = parseMatchArmBlock()
                    body = .block(block, aStart.merged(with: currentSpan))
                } else {
                    body = parseExpr()
                }
            } else if isAtEmptyMatchArmBodyTerminator() {
                body = .tuple([], currentSpan)
            } else if at(.kwLet) || at(.kwMut) || atVarBinding() || at(.at) {
                // Block body with statements
                let block = parseMatchArmBlock()
                body = .block(block, aStart.merged(with: currentSpan))
            } else {
                let expr = parseExpr()
                // Check if there are more statements following (skip semicolons first)
                while eat(.semi) {}
                if at(.kwLet) || at(.kwMut) || atVarBinding() || at(.at) || (atExprStart() && !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse)) {
                    // Multi-expression arm: wrap as block
                    var stmts: [Stmt] = [.exprStmt(expr, expr.span)]
                    while !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse) && !atEof() {
                        if eat(.semi) { continue }
                        if let stmt = parseStatement() {
                            stmts.append(stmt)
                        } else {
                            break
                        }
                    }
                    let tailExpr: Expr?
                    if let last = stmts.last, case .exprStmt(let e, _) = last {
                        tailExpr = e
                        stmts.removeLast()
                    } else {
                        tailExpr = nil
                    }
                    let block = BlockBody(stmts: stmts, tailExpr: tailExpr,
                                          span: aStart.merged(with: currentSpan))
                    body = .block(block, aStart.merged(with: currentSpan))
                } else {
                    body = expr
                }
            }
            arms.append(MatchArm(pattern: pat, guardExpr: guard_, body: body,
                                 span: aStart.merged(with: currentSpan)))
        }
        // Optional else clause (desugared to wildcard arm)
        if eat(.kwElse) {
            let eStart = currentSpan
            let body: Expr
            if isAtEmptyMatchArmBodyTerminator() {
                body = .tuple([], currentSpan)
            } else if at(.kwLet) || at(.kwMut) || atVarBinding() || at(.at) {
                let block = parseMatchArmBlock()
                body = .block(block, eStart.merged(with: currentSpan))
            } else {
                let expr = parseExpr()
                while eat(.semi) {}
                if at(.kwLet) || at(.kwMut) || atVarBinding() || at(.at) || (atExprStart() && !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse)) {
                    var stmts: [Stmt] = [.exprStmt(expr, expr.span)]
                    while !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse) && !atEof() {
                        if eat(.semi) { continue }
                        if let stmt = parseStatement() {
                            stmts.append(stmt)
                        } else {
                            break
                        }
                    }
                    let tailExpr: Expr?
                    if let last = stmts.last, case .exprStmt(let e, _) = last {
                        tailExpr = e
                        stmts.removeLast()
                    } else {
                        tailExpr = nil
                    }
                    let block = BlockBody(stmts: stmts, tailExpr: tailExpr,
                                          span: eStart.merged(with: currentSpan))
                    body = .block(block, eStart.merged(with: currentSpan))
                } else {
                    body = expr
                }
            }
            arms.append(MatchArm(pattern: .wildcard(eStart), guardExpr: nil, body: body,
                                 span: eStart.merged(with: currentSpan)))
        }
        expect(.kwEnd)
        return .matchExpr(MatchExpr(subject: subject, arms: arms,
                                    span: start.merged(with: currentSpan)))
    }

    private func isAtEmptyMatchArmBodyTerminator() -> Bool {
        return at(.kwWhen) || at(.kwElse) || at(.kwEnd) || at(.rBrace) || atEof()
    }

    private func looksLikeArrowMatchArmStart() -> Bool {
        if at(.kwWhen) || at(.kwElse) || at(.kwEnd) || atEof() {
            return false
        }

        var offset = 0
        while true {
            let kind = tokenKind(at: cursor + offset)
            switch kind {
            case .fatArrow:
                return true
            case .kwThen, .kwWhen, .kwElse, .kwEnd, .semi, .eof:
                return false
            default:
                break
            }

            if offset > 0,
               cursor + offset < tokens.count,
               sourceRangeContainsNewline(from: tokens[cursor + offset - 1].span.end,
                                          to: tokens[cursor + offset].span.start) {
                return false
            }

            offset += 1
            if offset > 48 { return false }
        }
    }

    private func sourceRangeContainsNewline(from start: Int, to end: Int) -> Bool {
        guard start < end else { return false }
        let bytes = Array(source.utf8)
        let upperBound = min(end, bytes.count)
        let lowerBound = min(start, upperBound)
        for index in lowerBound..<upperBound {
            if bytes[index] == UInt8(ascii: "\n") {
                return true
            }
        }
        return false
    }

    private func isAtInlineElseIf() -> Bool {
        guard at(.kwElse), peekAhead(1) == .kwIf, cursor + 1 < tokens.count else {
            return false
        }
        return !sourceRangeContainsNewline(from: currentSpan.end,
                                           to: tokens[cursor + 1].span.start)
    }

    private func shouldParseInlineMatchGuard() -> Bool {
        guard at(.kwIf) else { return false }
        guard cursor > 0 else { return true }
        let prev = tokens[cursor - 1].span
        return !sourceRangeContainsNewline(from: prev.end, to: currentSpan.start)
    }

    /// Parse a match arm block body (until next `when` or `end`).
    private func parseMatchArmBlock() -> BlockBody {
        let start = currentSpan
        var stmts: [Stmt] = []
        while !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse) && !atEof() {
            // Skip semicolons (statement separators)
            if eat(.semi) { continue }
            if let stmt = parseStatement() {
                stmts.append(stmt)
            } else {
                break
            }
        }
        var tailExpr: Expr? = nil
        if let last = stmts.last, case .exprStmt(let e, _) = last {
            tailExpr = e
            stmts.removeLast()
        }
        return BlockBody(stmts: stmts, tailExpr: tailExpr, span: start.merged(with: currentSpan))
    }

    /// Parse brace-style match: match expr { Pattern => body, ... } or { when Pattern then body ... }
    private func parseBraceMatch(subject: Expr, start: Span) -> Expr {
        advance() // skip {
        var arms: [MatchArm] = []
        while !at(.rBrace) && !at(.kwEnd) && !atEof() {
            if eat(.semi) { continue }
            let aStart = currentSpan

            // else arm (default/wildcard)
            if eat(.kwElse) {
                let body: Expr
                if eat(.fatArrow) {
                    body = parseExpr()
                } else {
                    eat(.kwThen)
                    body = parseBraceMatchArmBody()
                }
                arms.append(MatchArm(pattern: .wildcard(aStart), guardExpr: nil, body: body,
                                     span: aStart.merged(with: currentSpan)))
            } else if eat(.kwWhen) {
                // when-style arm inside braces
                let pat = parsePattern()
                var guard_: Expr? = nil
                if shouldParseInlineMatchGuard() {
                    _ = eat(.kwIf)
                    guard_ = parseExpr()
                }
                eat(.kwThen)
                let body = parseBraceMatchArmBody()
                arms.append(MatchArm(pattern: pat, guardExpr: guard_, body: body,
                                     span: aStart.merged(with: currentSpan)))
            } else {
                // arrow-style arm
                let pat = parsePattern()
                var guard_: Expr? = nil
                if eat(.kwIf) {
                    guard_ = parseExpr()
                }
                expect(.fatArrow)
                let body = parseExpr()
                arms.append(MatchArm(pattern: pat, guardExpr: guard_, body: body,
                                     span: aStart.merged(with: currentSpan)))
            }
            if !at(.rBrace) { eat(.comma) }
        }
        eat(.kwEnd) // optional end before }
        expect(.rBrace)
        return .matchExpr(MatchExpr(subject: subject, arms: arms,
                                    span: start.merged(with: currentSpan)))
    }

    /// Parse the body of a when-style arm inside braces — terminated by `,`, `when`, `else`, `end`, `}`.
    private func parseBraceMatchArmBody() -> Expr {
        let bodyStart = currentSpan
        if isAtEmptyMatchArmBodyTerminator() {
            return .tuple([], currentSpan)
        }
        let first = parseExpr()
        while eat(.semi) {}
        // Check if there are more statements (multi-statement arm body)
        if at(.kwLet) || at(.kwMut) || atVarBinding() || (atExprStart() && !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse) && !at(.rBrace)) {
            var stmts: [Stmt] = [.exprStmt(first, first.span)]
            while !at(.kwWhen) && !at(.kwEnd) && !at(.kwElse) && !at(.rBrace) && !atEof() {
                if eat(.semi) { continue }
                if let stmt = parseStatement() {
                    stmts.append(stmt)
                } else {
                    break
                }
            }
            let tail = stmts.last.flatMap { stmt -> Expr? in
                if case .exprStmt(let e, _) = stmt { return e }
                return nil
            }
            if tail != nil { stmts.removeLast() }
            return .block(BlockBody(stmts: stmts, tailExpr: tail,
                                    span: bodyStart.merged(with: currentSpan)),
                          bodyStart.merged(with: currentSpan))
        }
        return first
    }

    private func parseForExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'for'
        let pat = parsePattern()
        expect(.kwIn)
        let iterable = parseExpr()
        eat(.kwDo)
        let body = parseBlock()
        expect(.kwEnd)
        return .forExpr(ForExpr(pattern: pat, iterable: iterable, body: body,
                                span: start.merged(with: currentSpan)))
    }

    private func parseWhileExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'while'
        let cond = parseExpr()
        eat(.kwDo)
        let body = parseBlock()
        expect(.kwEnd)
        return .whileExpr(WhileExpr(condition: cond, body: body,
                                    span: start.merged(with: currentSpan)))
    }

    private func parseUntilExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'until'
        let cond = parseExpr()
        eat(.kwDo)
        let body = parseBlock()
        expect(.kwEnd)
        return .untilExpr(UntilExpr(condition: cond, body: body,
                                    span: start.merged(with: currentSpan)))
    }

    private func parseLoopExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'loop'
        eat(.kwDo)
        let body = parseBlock()
        expect(.kwEnd)
        return .loopExpr(body, start.merged(with: currentSpan))
    }

    private func parseDoBlock() -> Expr {
        let start = currentSpan
        advance() // skip 'do'
        let block = parseBlock()
        expect(.kwEnd)
        return .block(block, start.merged(with: currentSpan))
    }

    private func parseUnsafeBlock() -> Expr {
        let start = currentSpan
        advance() // skip 'unsafe'
        var reason = ""
        if case .string(let s) = peekKind() {
            advance()
            reason = s
        }
        let block: BlockBody
        if eat(.lBrace) {
            block = parseBlock(terminator: .rBrace)
            expect(.rBrace)
        } else {
            block = parseBlock()
            expect(.kwEnd)
        }
        return .unsafeBlock(reason: reason, body: block, start.merged(with: currentSpan))
    }

    private func parseClosureExpr() -> Expr {
        let start = currentSpan
        advance() // skip opening |

        var params: [ClosureParam] = []
        while !at(.pipe) && !atEof() {
            let pStart = currentSpan
            if at(.lParen) {
                advance() // skip (
                while !at(.rParen) && !atEof() {
                    let innerStart = currentSpan
                    let isMut = eat(.kwMut)
                    let name = expectIdent()
                    var paramType: TypeExpr? = nil
                    if eat(.colon) {
                        paramType = parseTypeExpr()
                    }
                    params.append(ClosureParam(name: name, isMutable: isMut, type: paramType,
                                               span: innerStart.merged(with: currentSpan)))
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
                if !at(.pipe) { eat(.comma) }
                continue
            }
            let isMut = eat(.kwMut)
            let name = expectIdent()
            var type: TypeExpr? = nil
            if eat(.colon) {
                type = parseTypeExpr()
            }
            params.append(ClosureParam(name: name, isMutable: isMut, type: type,
                                       span: pStart.merged(with: currentSpan)))
            if !at(.pipe) { eat(.comma) }
        }
        expect(.pipe)

        var retType: TypeExpr? = nil
        if eat(.arrow) {
            retType = parseTypeExpr()
        }

        let body: Expr
        if at(.kwDo) || at(.kwEnd) {
            // Block closure: |params| do ... end
            if at(.kwDo) { advance() }
            let block = parseBlock()
            expect(.kwEnd)
            body = .block(block, start.merged(with: currentSpan))
        } else if at(.lBrace) {
            // Brace closure: |params| { ... }
            advance()
            let block = parseBlock(terminator: .rBrace)
            expect(.rBrace)
            body = .block(block, start.merged(with: currentSpan))
        } else if at(.kwLet) || at(.kwMut) || atVarBinding() {
            // Multi-line implicit block: |params| let x = ...; ...
            // Parse block body until ), comma, or ]
            let block = parseClosureBlockBody()
            body = .block(block, start.merged(with: currentSpan))
        } else {
            let expr = parseExpr()
            // After single expression, check if there's more (let/mut statements follow)
            if at(.kwLet) || at(.kwMut) || atVarBinding() {
                var stmts: [Stmt] = [.exprStmt(expr, expr.span)]
                let restBlock = parseClosureBlockBody()
                stmts.append(contentsOf: restBlock.stmts)
                let block = BlockBody(stmts: stmts, tailExpr: restBlock.tailExpr,
                                      span: start.merged(with: currentSpan))
                body = .block(block, start.merged(with: currentSpan))
            } else {
                body = expr
            }
        }

        return .closure(ClosureExpr(params: params, returnType: retType, body: body,
                                    span: start.merged(with: currentSpan)))
    }

    /// Parse a closure block body until ), comma, or ] is reached.
    private func parseClosureBlockBody() -> BlockBody {
        let start = currentSpan
        var stmts: [Stmt] = []

        func atClosureEnd() -> Bool {
            return at(.rParen) || at(.comma) || at(.rBracket) || at(.kwEnd) || atEof()
        }

        while !atClosureEnd() {
            if eat(.semi) { continue }
            if let stmt = parseStatement() {
                stmts.append(stmt)
            } else {
                break
            }
        }

        var tailExpr: Expr? = nil
        if let last = stmts.last, case .exprStmt(let e, _) = last {
            tailExpr = e
            stmts.removeLast()
        }
        return BlockBody(stmts: stmts, tailExpr: tailExpr, span: start.merged(with: currentSpan))
    }

    /// Parse a zero-parameter closure: || body
    private func parseZeroParamClosure() -> Expr {
        let start = currentSpan
        // Check for `move ||` syntax (move-ness not yet threaded into ClosureExpr)
        _ = eat(.kwMut)
        if case .ident("move") = peekKind() {
            advance()
        }
        advance() // skip ||
        let body: Expr
        if at(.kwDo) {
            advance()
            let block = parseBlock()
            expect(.kwEnd)
            body = .block(block, start.merged(with: currentSpan))
        } else if at(.lBrace) {
            advance()
            let block = parseBlock(terminator: .rBrace)
            expect(.rBrace)
            body = .block(block, start.merged(with: currentSpan))
        } else if at(.kwLet) || at(.kwMut) || atVarBinding() {
            let block = parseClosureBlockBody()
            body = .block(block, start.merged(with: currentSpan))
        } else {
            body = parseExpr()
        }
        return .closure(ClosureExpr(params: [], returnType: nil, body: body,
                                    span: start.merged(with: currentSpan)))
    }

    private func parseHandleExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'handle'
        let expr = parseExpr()
        expect(.kwWith)
        let effectName = expectIdent()
        var arms: [(op: String, params: [Pattern], body: Expr)] = []
        while atIdent() && !at(.kwEnd) {
            let op = expectIdent()
            expect(.lParen)
            var params: [Pattern] = []
            while !at(.rParen) && !atEof() {
                params.append(parsePattern())
                if !at(.rParen) { eat(.comma) }
            }
            expect(.rParen)
            expect(.fatArrow)
            let body = parseExpr()
            arms.append((op: op, params: params, body: body))
        }
        expect(.kwEnd)
        return .handleExpr(HandleExpr(expr: expr, effectName: effectName, arms: arms,
                                      span: start.merged(with: currentSpan)))
    }

    private func parseTryExpr() -> Expr {
        let start = currentSpan
        advance() // skip 'try'
        let body = parseBlock()
        var catches: [(pattern: Pattern, body: BlockBody)] = []
        while at(.kwCatch) {
            advance()
            let pat = parsePattern()
            eat(.kwThen)
            let catchBody = parseBlock()
            catches.append((pattern: pat, body: catchBody))
        }
        var finallyBlock: BlockBody? = nil
        if eat(.kwFinally) {
            finallyBlock = parseBlock()
        }
        expect(.kwEnd)
        return .tryBlock(TryBlock(body: body, catchClauses: catches, finallyBlock: finallyBlock,
                                  span: start.merged(with: currentSpan)))
    }

    private func parseStructLiteral(name: String, typeArgs: [TypeExpr] = [], start: Span) -> Expr {
        advance() // skip {
        var fields: [(String, Expr)] = []
        var rest: Expr? = nil
        while !at(.rBrace) && !at(.kwEnd) && !atEof() {
            if eat(.dotDot) {
                rest = parseExpr()
                break
            }
            let fName = expectIdent()
            if eat(.colon) {
                let value = parseExpr()
                fields.append((fName, value))
            } else {
                // Shorthand: field name same as variable
                fields.append((fName, .name(fName, currentSpan)))
            }
            if !at(.rBrace) && !at(.kwEnd) { eat(.comma) }
        }
        if at(.kwEnd) {
            advance() // brace-style can also end with `end`
        } else {
            expect(.rBrace)
        }
        return .structLit(name: name, typeArgs: typeArgs, fields: fields, rest: rest,
                          start.merged(with: currentSpan))
    }

    /// Detect end-block struct literal: Name starts with uppercase, followed by ident then colon.
    private func looksLikeEndStructLiteral(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        // Next token must be ident followed by colon
        if case .ident = peekKind(), peekAhead(1) == .colon {
            return true
        }
        // Also allow soft keyword ident followed by colon
        if atIdent() && peekAhead(1) == .colon {
            return true
        }
        return false
    }

    /// Parse end-block struct literal: Name\n  field: value\n  ...\nend
    private func parseEndStructLiteral(name: String, typeArgs: [TypeExpr] = [], start: Span) -> Expr {
        var fields: [(String, Expr)] = []
        while !at(.kwEnd) && !atEof() {
            let fName = expectIdent()
            expect(.colon)
            let value = parseExpr()
            fields.append((fName, value))
        }
        expect(.kwEnd)
        return .structLit(name: name, typeArgs: typeArgs, fields: fields, rest: nil,
                          start.merged(with: currentSpan))
    }

    // MARK: - Argument Lists

    private func parseArgList() -> [CallArg] {
        var args: [CallArg] = []
        while !at(.rParen) && !atEof() {
            let start = currentSpan
            // Check for labeled argument: ident: expr
            if atIdent() && peekAhead(1) == .colon {
                let label = expectIdent()
                advance() // skip ':'
                let value = parseExpr()
                args.append(CallArg(label: label, value: value, span: start.merged(with: currentSpan)))
            } else {
                let expr = parseExpr()
                args.append(CallArg(value: expr, span: start.merged(with: currentSpan)))
            }
            if !at(.rParen) { eat(.comma) }
        }
        return args
    }

    private func parseTurbofishTypeArgs() -> [TypeExpr] {
        var args: [TypeExpr] = []
        expect(.lt)
        while !at(.gt) && !atEof() {
            args.append(parseTypeExpr())
            if !at(.gt) {
                _ = eat(.comma)
            }
        }
        expect(.gt)
        return args
    }

    private func looksLikeBracketMethodTypeArgsStart() -> Bool {
        guard at(.lBracket) else { return false }
        var index = cursor
        var depth = 0
        while index < tokens.count {
            let kind = tokenKind(at: index)
            switch kind {
            case .lBracket:
                depth += 1
            case .rBracket:
                depth -= 1
                if depth == 0 {
                    return tokenKind(at: index + 1) == .lParen
                }
            case .eof:
                return false
            default:
                break
            }
            index += 1
        }
        return false
    }

    // MARK: - Patterns

    private func parsePattern() -> Pattern {
        let start = currentSpan

        // `let` in pattern positions (e.g. `when let x then ...`)
        if eat(.kwLet) {
            return parsePattern()
        }

        // Wildcard: _
        if case .ident("_") = peekKind() {
            advance()
            return .wildcard(start)
        }

        // Mutable binding: mut x
        if at(.kwMut) {
            advance()
            let name = expectIdent()
            return .ident(name, mutable: true, start.merged(with: currentSpan))
        }

        // Ref binding: ref x, ref mut x — `ref` is just an ident, skip it
        if case .ident("ref") = peekKind() {
            advance() // skip 'ref'
            return parsePattern() // re-parse (possibly with mut next)
        }

        // Literal patterns
        if case .integer(let s) = peekKind() {
            advance()
            let litExpr = Expr.intLit(s, start)
            return checkOrPattern(.literal(litExpr, start.merged(with: currentSpan)), start: start)
        }
        if case .float(let s) = peekKind() {
            advance()
            let litExpr = Expr.floatLit(s, start)
            return checkOrPattern(.literal(litExpr, start.merged(with: currentSpan)), start: start)
        }
        if case .string(let s) = peekKind() {
            advance()
            let litExpr = Expr.stringLit(s, start)
            return checkOrPattern(.literal(litExpr, start.merged(with: currentSpan)), start: start)
        }
        if case .char(let c) = peekKind() {
            advance()
            let litExpr = Expr.charLit(c, start)
            return checkOrPattern(.literal(litExpr, start.merged(with: currentSpan)), start: start)
        }
        if at(.kwTrue) {
            advance()
            return checkOrPattern(.literal(.boolLit(true, start), start), start: start)
        }
        if at(.kwFalse) {
            advance()
            return checkOrPattern(.literal(.boolLit(false, start), start), start: start)
        }

        // Tuple pattern
        if at(.lParen) {
            advance()
            var pats: [Pattern] = []
            while !at(.rParen) && !atEof() {
                pats.append(parsePattern())
                if !at(.rParen) { eat(.comma) }
            }
            expect(.rParen)
            return checkOrPattern(.tuple(pats, start.merged(with: currentSpan)), start: start)
        }

        // Identifier pattern (or enum variant)
        if atIdent() {
            let name = expectIdent()

            // Enum variant: Name::Variant or Name::Submod::Variant or Name.Variant
            // Support both :: and . as separators (matching Rust stage0)
            if eat(.colonColon) || eat(.dot) {
                var enumName = name
                var variantName = expectIdent()
                // Support multi-level: A::B::C
                if eat(.colonColon) || eat(.dot) {
                    enumName = enumName + "::" + variantName
                    variantName = expectIdent()
                }
                var fields: [Pattern] = []
                if eat(.lParen) {
                    while !at(.rParen) && !atEof() {
                        fields.append(parsePattern())
                        if !at(.rParen) { eat(.comma) }
                    }
                    expect(.rParen)
                } else if at(.lBrace) {
                    // Struct-like variant pattern: Enum::Variant { field, field: pat }
                    advance()
                    var sFields: [(String, Pattern?)] = []
                    while !at(.rBrace) && !atEof() {
                        let fName = expectIdent()
                        var fPat: Pattern? = nil
                        if eat(.colon) {
                            fPat = parsePattern()
                        }
                        sFields.append((fName, fPat))
                        if !at(.rBrace) { eat(.comma) }
                    }
                    expect(.rBrace)
                    return checkOrPattern(.structPattern(name: enumName + "::" + variantName, fields: sFields,
                                                         start.merged(with: currentSpan)), start: start)
                }
                return checkOrPattern(.variant(typeName: enumName, variantName: variantName, fields: fields,
                                               start.merged(with: currentSpan)), start: start)
            }

            // Struct destructure: Name { ... }
            if at(.lBrace) {
                advance()
                var fields: [(String, Pattern?)] = []
                while !at(.rBrace) && !atEof() {
                    let fName = expectIdent()
                    var fPat: Pattern? = nil
                    if eat(.colon) {
                        fPat = parsePattern()
                    }
                    fields.append((fName, fPat))
                    if !at(.rBrace) { eat(.comma) }
                }
                expect(.rBrace)
                return checkOrPattern(.structPattern(name: name, fields: fields,
                                                     start.merged(with: currentSpan)), start: start)
            }

            // Check for special "ref" identifier
            if name == "ref" {
                if eat(.kwMut) {
                    let refName = expectIdent()
                    return .refMutPattern(refName, start.merged(with: currentSpan))
                }
                if atIdent() {
                    let refName = expectIdent()
                    return .refPattern(refName, start.merged(with: currentSpan))
                }
            }

            // Simple identifier binding (and check for enum variant without type prefix)
            if eat(.lParen) {
                // Could be Variant(fields) without type prefix
                var fields: [Pattern] = []
                while !at(.rParen) && !atEof() {
                    fields.append(parsePattern())
                    if !at(.rParen) { eat(.comma) }
                }
                expect(.rParen)
                return checkOrPattern(.variant(typeName: "", variantName: name, fields: fields,
                                               start.merged(with: currentSpan)), start: start)
            }

            return checkOrPattern(.ident(name, mutable: false, start.merged(with: currentSpan)), start: start)
        }

        diagnostics.error(
            code: "E1130",
            message: "expected pattern, found \(peek().kind.displayName)",
            span: currentSpan,
            stage: .parser
        )
        advance()
        return .wildcard(start)
    }

    /// Check for or-pattern: pat | pat
    private func checkOrPattern(_ left: Pattern, start: Span) -> Pattern {
        if eat(.pipe) {
            let right = parsePattern()
            return .orPattern(left, right, start.merged(with: currentSpan))
        }
        // Check for range pattern: pat .. pat
        if eat(.dotDot) {
            let right = parsePattern()
            return .rangePattern(left, right, start.merged(with: currentSpan))
        }
        return left
    }

    // MARK: - Context Helpers

    private func atItemStart() -> Bool {
        switch peekKind() {
                case .kwDef, .kwFn, .kwStruct, .kwResource, .kwEnum, .kwTrait, .kwImpl, .kwUse,
               .kwConst, .kwStatic, .kwType, .kwTypealias, .kwExtern, .kwModule, .kwMod,
             .kwCap, .kwEffect, .kwRationale, .kwMacro, .kwEdition,
               .kwPub, .kwAsync, .kwUnsafe, .kwPure, .kwInline, .kwLet, .kwMut, .kwTest:
            return true
        case .at: // attributes precede items
            return true
        default:
            return false
        }
    }

    /// Items allowed inside block bodies (function bodies, match arms, etc.)
    /// Top-level-only items (module, trait, enum, extern, cap, effect, etc.) fall through to expression parsing.
    private func atBlockItemStart() -> Bool {
        return looksLikeBlockItemStart(from: cursor)
    }

    private func atExprStart() -> Bool {
        switch peekKind() {
        case .ident, .integer, .float, .string, .char,
             .kwTrue, .kwFalse, .kwSelfValue, .kwSelfTy,
             .lParen, .lBracket,
             .kwIf, .kwMatch, .kwFor, .kwWhile, .kwLoop, .kwDo,
             .kwReturn, .kwBreak, .kwNext, .kwUnsafe,
             .minus, .bang, .tilde, .star, .amp, .pipe, .pipePipe, .lBrace,
             .kwHandle, .kwTry, .kwUnless, .kwUntil, .kwComptime, .at:
            return true
        default:
            // Soft keywords that can be expression names
            return atIdent()
        }
    }

    private func isStructLiteralContext(_ name: String) -> Bool {
        // Heuristic: Name { ident : ... } is a struct literal
        // But Name { stmt; ... } is a block expression (unlikely after ident)
        // Look ahead: { followed by ident (or soft keyword) followed by : or , or }
        guard at(.lBrace) else { return false }
        let saved = cursor
        cursor += 1 // skip {
        let result: Bool
        if at(.rBrace) {
            result = true // empty struct literal
        } else if atIdent() && peekAhead(1) == .colon {
            result = true
        } else if atIdent() && peekAhead(1) == .comma {
            result = true // shorthand
        } else if atIdent() && peekAhead(1) == .rBrace {
            result = true // shorthand single field
        } else if at(.dotDot) {
            result = true // struct rest syntax
        } else {
            result = false
        }
        cursor = saved
        return result
    }
}
