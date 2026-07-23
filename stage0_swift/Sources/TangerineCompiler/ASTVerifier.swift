// ASTVerifier.swift — Post-parse AST structural verifier
// Validates INV-PARSE-006 through INV-PARSE-008
// Fails hard in stabilization mode; emits structured diagnostics.

public final class ASTVerifier {
    private let diagnostics: DiagnosticBag

    public init(diagnostics: DiagnosticBag) {
        self.diagnostics = diagnostics
    }

    public func verify(_ program: Program) {
        for item in program.items {
            verifyItem(item)
        }
    }

    private func verifyItem(_ item: Item) {
        verifySpan(item.span, context: "item \(item.kind.summary)")
        for attr in item.attributes {
            verifySpan(attr.span, context: "attribute @\(attr.name)")
        }

        switch item.kind {
        case .function(let d):
            verifySpan(d.span, context: "function \(d.sig.name)")
            verifyFunctionSig(d.sig)
            verifyFunctionBody(d.body)
            for clause in d.clauses { verifyClause(clause) }
        case .testDecl(let d):
            verifySpan(d.span, context: "test \(d.name)")
            verifyBlock(d.body)
        case .structDef(let d):
            verifySpan(d.span, context: "struct \(d.name)")
            for field in d.fields {
                verifySpan(field.span, context: "field \(field.name)")
                verifyTypeExpr(field.type)
            }
        case .enumDef(let d):
            verifySpan(d.span, context: "enum \(d.name)")
            for v in d.variants { verifySpan(v.span, context: "variant \(v.name)") }
        case .traitDef(let d):
            verifySpan(d.span, context: "trait \(d.name)")
            for m in d.methods { verifyFunctionDecl(m) }
        case .implBlock(let d):
            verifySpan(d.span, context: "impl block")
            for m in d.methods { verifyFunctionDecl(m) }
        case .useDecl(let d):
            verifySpan(d.span, context: "use \(d.pathString)")
        case .constDecl(let d):
            verifySpan(d.span, context: "const \(d.name)")
            verifyTypeExpr(d.type)
            verifyExpr(d.value)
        case .staticDecl(let d):
            verifySpan(d.span, context: "static \(d.name)")
            verifyTypeExpr(d.type)
            verifyExpr(d.value)
        case .typeAlias(let d):
            verifySpan(d.span, context: "type \(d.name)")
        case .externBlock(let d):
            verifySpan(d.span, context: "extern block")
            for sub in d.items { verifyItem(sub) }
        case .moduleDef(let d):
            verifySpan(d.span, context: "module \(d.name)")
            if let items = d.items { for sub in items { verifyItem(sub) } }
        case .capabilityDecl(let d): verifySpan(d.span, context: "cap \(d.name)")
        case .effectDecl(let d): verifySpan(d.span, context: "effect \(d.name)")
        case .rationaleBlock(let d): verifySpan(d.span, context: "rationale")
        case .macroDecl(let d): verifySpan(d.span, context: "macro \(d.name)")
        case .editionDecl(let d): verifySpan(d.span, context: "edition \(d.version)")
        }
    }

    private func verifyFunctionSig(_ sig: FunctionSig) {
        verifySpan(sig.span, context: "function sig \(sig.name)")
        for param in sig.params {
            verifySpan(param.span, context: "param \(param.name)")
            verifyTypeExpr(param.type)
        }
        if let ret = sig.returnType { verifyTypeExpr(ret) }
    }

    private func verifyFunctionDecl(_ decl: FunctionDecl) {
        verifySpan(decl.span, context: "function \(decl.sig.name)")
        verifyFunctionSig(decl.sig)
        verifyFunctionBody(decl.body)
        for clause in decl.clauses { verifyClause(clause) }
    }

    private func verifyFunctionBody(_ body: FunctionBody) {
        switch body {
        case .block(let b): verifyBlock(b)
        case .expr(let expr): verifyExpr(expr)
        case .signatureOnly: break
        }
    }

    private func verifyBlock(_ block: BlockBody) {
        verifySpan(block.span, context: "block body")
        for stmt in block.stmts { verifyStmt(stmt) }
        if let tail = block.tailExpr { verifyExpr(tail) }
    }

    private func verifyClause(_ clause: FunctionClause) {
        switch clause {
        case .requires(let c): verifySpan(c.span, context: "requires clause")
        case .effect(let c):
            verifySpan(c.span, context: "effect clause")
            for ta in c.typeArgs { verifyTypeExpr(ta) }
        case .budget(let c): verifySpan(c.span, context: "budget clause")
        case .contract(let c):
            verifySpan(c.span, context: "contract clause")
            verifyExpr(c.condition)
        case .guardClause(let c):
            verifySpan(c.span, context: "guard clause")
            if let cond = c.condition { verifyExpr(cond) }
            if let pat = c.pattern { verifyPattern(pat) }
            if let val = c.value { verifyExpr(val) }
        }
    }

    private func verifyStmt(_ stmt: Stmt) {
        verifySpan(stmt.span, context: "statement")
        switch stmt {
        case .letBinding(let pat, _, let type, let value, _):
            verifyPattern(pat)
            if let t = type { verifyTypeExpr(t) }
            verifyExpr(value)
        case .exprStmt(let e, _):
            verifyExpr(e)
        case .attributeStmt(let attrs, _):
            for attr in attrs {
                verifySpan(attr.span, context: "attribute @\(attr.name)")
            }
        case .attributed(let attrs, let inner, _):
            for attr in attrs {
                verifySpan(attr.span, context: "attribute @\(attr.name)")
            }
            verifyStmt(inner)
        case .deferStmt(let body, _):
            verifyBlock(body)
        case .item(let item):
            verifyItem(item)
        }
    }

    private func verifyExpr(_ expr: Expr) {
        verifySpan(expr.span, context: "expression")
        switch expr {
        case .intLit, .floatLit, .stringLit, .charLit, .boolLit,
             .name, .path, .nextExpr:
            break
        case .array(let elems, _):
            for e in elems { verifyExpr(e) }
        case .arrayRepeat(let v, let c, _):
            verifyExpr(v); verifyExpr(c)
        case .tuple(let elems, _):
            for e in elems { verifyExpr(e) }
        case .structLit(_, _, let fields, let rest, _):
            for (_, v) in fields { verifyExpr(v) }
            if let r = rest { verifyExpr(r) }
        case .block(let b, _):
            verifyBlock(b)
        case .unsafeBlock(_, let b, _):
            verifyBlock(b)
        case .ifExpr(let e):
            verifySpan(e.span, context: "if expr")
            verifyExpr(e.condition)
            verifyBlock(e.thenBlock)
            for clause in e.elsifClauses {
                verifyExpr(clause.condition)
                verifyBlock(clause.body)
            }
            if let el = e.elseBlock { verifyBlock(el) }
            if let pat = e.ifLetPattern { verifyPattern(pat) }
            if let v = e.ifLetValue { verifyExpr(v) }
        case .call(let callee, _, let args, _):
            verifyExpr(callee)
            for arg in args { verifyExpr(arg.value) }
        case .index(let base, let idx, _):
            verifyExpr(base); verifyExpr(idx)
        case .range(let s, let e, _, _):
            verifyExpr(s); verifyExpr(e)
        case .matchExpr(let m):
            verifySpan(m.span, context: "match expr")
            verifyExpr(m.subject)
            for arm in m.arms {
                verifySpan(arm.span, context: "match arm")
                verifyPattern(arm.pattern)
                if let g = arm.guardExpr { verifyExpr(g) }
                verifyExpr(arm.body)
            }
        case .cast(let e, let t, _):
            verifyExpr(e); verifyTypeExpr(t)
        case .tryOp(let e, _):
            verifyExpr(e)
        case .closure(let c):
            verifySpan(c.span, context: "closure")
            verifyExpr(c.body)
        case .unary(_, let e, _):
            verifyExpr(e)
        case .field(let base, _, _):
            verifyExpr(base)
        case .binary(let l, _, let r, _):
            verifyExpr(l); verifyExpr(r)
        case .awaitExpr(let e, _):
            verifyExpr(e)
        case .macroCall(_, let args, _):
            for arg in args {
                switch arg {
                case .expr(let expr):
                    verifyExpr(expr)
                case .tokens(_, let span):
                    verifySpan(span, context: "macro token tree")
                }
            }
        case .assign(let t, let v, _):
            verifyExpr(t); verifyExpr(v)
        case .compoundAssign(let t, _, let v, _):
            verifyExpr(t); verifyExpr(v)
        case .returnExpr(let e, _):
            if let e = e { verifyExpr(e) }
        case .breakExpr(let e, _):
            if let e = e { verifyExpr(e) }
        case .forExpr(let f):
            verifySpan(f.span, context: "for expr")
            verifyPattern(f.pattern)
            verifyExpr(f.iterable)
            verifyBlock(f.body)
        case .whileExpr(let w):
            verifySpan(w.span, context: "while expr")
            verifyExpr(w.condition)
            verifyBlock(w.body)
        case .loopExpr(let b, _):
            verifyBlock(b)
        case .handleExpr(let h):
            verifySpan(h.span, context: "handle expr")
            verifyExpr(h.expr)
            for arm in h.arms {
                for p in arm.params { verifyPattern(p) }
                verifyExpr(arm.body)
            }
        case .unlessExpr(let u):
            verifySpan(u.span, context: "unless expr")
            verifyExpr(u.condition)
            verifyBlock(u.body)
        case .untilExpr(let u):
            verifySpan(u.span, context: "until expr")
            verifyExpr(u.condition)
            verifyBlock(u.body)
        case .tryBlock(let t):
            verifySpan(t.span, context: "try block")
            verifyBlock(t.body)
            for c in t.catchClauses {
                verifyPattern(c.pattern)
                verifyBlock(c.body)
            }
            if let f = t.finallyBlock { verifyBlock(f) }
        case .comptimeBlock(let b, _):
            verifyBlock(b)
        }
    }

    private func verifyTypeExpr(_ type: TypeExpr) {
        verifySpan(type.span, context: "type expression")
        switch type {
        case .named(_, let args, _):
            for a in args { verifyTypeExpr(a) }
        case .assocBinding(_, let value, _):
            verifyTypeExpr(value)
        case .constExpr(let expr, _):
            verifyExpr(expr)
        case .never:
            break
        case .tuple(let elems, _):
            for e in elems { verifyTypeExpr(e) }
        case .ref(let t, _, _), .rawPtr(let t, _, _), .slice(let t, _), .option(let t, _):
            verifyTypeExpr(t)
        case .dynTrait(let t, _), .implTrait(let t, _):
            verifyTypeExpr(t)
        case .bounded(let base, let bounds, _):
            verifyTypeExpr(base)
            for bound in bounds { verifyTypeExpr(bound) }
        case .fnPtr(let params, let ret, _):
            for p in params { verifyTypeExpr(p) }
            verifyTypeExpr(ret)
        case .array(let t, let len, _):
            verifyTypeExpr(t)
            if let l = len { verifyExpr(l) }
        case .unit, .selfType, .inferred:
            break
        }
    }

    private func verifyPattern(_ pattern: Pattern) {
        verifySpan(pattern.span, context: "pattern")
        switch pattern {
        case .wildcard, .ident, .refPattern, .refMutPattern:
            break
        case .literal(let e, _):
            verifyExpr(e)
        case .variant(_, _, let fields, _):
            for f in fields { verifyPattern(f) }
        case .structPattern(_, let fields, _):
            for (_, optPat) in fields {
                if let p = optPat { verifyPattern(p) }
            }
        case .tuple(let pats, _):
            for p in pats { verifyPattern(p) }
        case .orPattern(let a, let b, _):
            verifyPattern(a); verifyPattern(b)
        case .rangePattern(let a, let b, _):
            verifyPattern(a); verifyPattern(b)
        }
    }

    private func verifySpan(_ span: Span, context: String) {
        if span.fileID == -1 { return } // synthetic spans allowed
        if span.start > span.end {
            diagnostics.error(
                code: "V0001",
                message: "INV-PARSE-008 violated: span start (\(span.start)) > end (\(span.end)) in \(context)",
                span: span,
                stage: .parser
            )
        }
    }
}
