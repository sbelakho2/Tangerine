// SubsetChecker.swift — Rejects parsed-but-unsupported constructs
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// Walks the AST after parsing and emits E9001–E9028 diagnostics for any
// construct classified as PARSED BUT REJECTED in docs/stabilized_subset.md.
// This enforces the bootstrap language subset at compile time.

/// Post-parse AST walker that rejects constructs outside the bootstrap subset.
public final class SubsetChecker {
    private let diagnostics: DiagnosticBag

    public init(diagnostics: DiagnosticBag) {
        self.diagnostics = diagnostics
    }

    // MARK: - Public entry point

    public func check(_ program: Program) {
        for item in program.items {
            checkItem(item)
        }
    }

    // MARK: - Items

    private func checkItem(_ item: Item) {
        checkAttributes(item.attributes)

        switch item.kind {
        case .capabilityDecl(let d):
            reject("E9001", "capability declarations are not available in the bootstrap subset", d.span)
        case .effectDecl(let d):
            reject("E9002", "effect declarations are not available in the bootstrap subset", d.span)
        case .rationaleBlock(let d):
            reject("E9003", "rationale blocks are not available in the bootstrap subset", d.span)
        case .macroDecl:
            break
        case .editionDecl(let d):
            reject("E9005", "edition declarations are not available in the bootstrap subset", d.span)

        case .function(let d):
            checkFunctionDecl(d)
        case .testDecl(let d):
            checkBlock(d.body)
        case .structDef(let d):
            checkStructDecl(d)
        case .enumDef(let d):
            checkEnumDecl(d)
        case .traitDef(let d):
            checkTraitDecl(d)
        case .implBlock(let d):
            checkImplDecl(d)
        case .constDecl(let d):
            checkExpr(d.value)
            checkTypeExpr(d.type)
        case .staticDecl(let d):
            checkExpr(d.value)
            checkTypeExpr(d.type)
        case .typeAlias(let d):
            checkTypeExpr(d.value)
        case .externBlock(let d):
            for sub in d.items { checkItem(sub) }
        case .moduleDef(let d):
            if let items = d.items {
                for sub in items {
                    checkItem(sub)
                }
            }
        case .useDecl:
            break
        }
    }

    // MARK: - Functions

    private func checkFunctionDecl(_ d: FunctionDecl) {
        checkFunctionSig(d.sig)
        checkFunctionClauses(d.clauses)
        switch d.body {
        case .block(let block):
            checkBlock(block)
        case .expr(let expr):
            checkExpr(expr)
        case .signatureOnly:
            break
        }
    }

    private func checkFunctionSig(_ sig: FunctionSig) {
        if sig.isAsync {
            reject("E9007", "async functions are not available in the bootstrap subset", sig.span)
        }
        if sig.isUnsafe {
            reject("E9020", "unsafe function modifier is not available in the bootstrap subset", sig.span)
        }
        if sig.isConst {
            reject("E9021", "const function modifier is not available in the bootstrap subset", sig.span)
        }
        if sig.isPure {
            reject("E9013", "pure function modifier is not available in the bootstrap subset", sig.span)
        }
        if sig.isInline {
            reject("E9014", "inline function modifier is not available in the bootstrap subset", sig.span)
        }
        for param in sig.params {
            checkTypeExpr(param.type)
            if let dv = param.defaultValue {
                checkExpr(dv)
            }
        }
        if let ret = sig.returnType {
            checkTypeExpr(ret)
        }
    }

    private func checkFunctionClauses(_ clauses: [FunctionClause]) {
        for clause in clauses {
            switch clause {
            case .requires(let c):
                reject("E9008", "requires clauses are not available in the bootstrap subset", c.span)
            case .effect(let c):
                reject("E9009", "effect clauses on functions are not available in the bootstrap subset", c.span)
            case .budget(let c):
                reject("E9010", "budget clauses are not available in the bootstrap subset", c.span)
            case .contract(let c):
                reject("E9011", "contract clauses (pre/post/invariant) are not available in the bootstrap subset", c.span)
            case .guardClause(let c):
                reject("E9012", "guard clauses are not available in the bootstrap subset", c.span)
            }
        }
    }

    // MARK: - Struct / Enum / Trait / Impl

    private func checkStructDecl(_ d: StructDecl) {
        for field in d.fields {
            checkTypeExpr(field.type)
        }
    }

    private func checkEnumDecl(_ d: EnumDecl) {
        for v in d.variants {
            for f in v.fields {
                checkTypeExpr(f.type)
            }
        }
    }

    private func checkTraitDecl(_ d: TraitDecl) {
        for m in d.methods {
            checkFunctionDecl(m)
        }
        for ta in d.associatedTypes {
            checkTypeExpr(ta.value)
        }
    }

    private func checkImplDecl(_ d: ImplDecl) {
        for m in d.methods {
            checkFunctionDecl(m)
        }
        for ta in d.associatedTypes {
            checkTypeExpr(ta.value)
        }
        for c in d.consts {
            checkExpr(c.value)
            checkTypeExpr(c.type)
        }
    }

    // MARK: - Attributes

    private static let rejectedAttributes: [String: String] = [
        "bench":      "E9021",
        "inline":     "E9022",
        "derive":     "E9023",
        "allow":      "E9024",
        "deny":       "E9024",
        "deprecated": "E9025",
        "stable":     "E9026",
        "feature":    "E9027",
        "capability": "E9028",
    ]

    private func checkAttributes(_ attrs: [Attribute]) {
        for attr in attrs {
            if let code = Self.rejectedAttributes[attr.name] {
                reject(code, "@\(attr.name) attribute is not available in the bootstrap subset", attr.span)
            }
        }
    }

    // MARK: - Type Expressions

    private func checkTypeExpr(_ ty: TypeExpr) {
        switch ty {
        case .constExpr(let expr, _):
            checkExpr(expr)
        case .ref(let inner, _, _):
            checkTypeExpr(inner)
        case .rawPtr(let inner, _, _):
            checkTypeExpr(inner)
        case .fnPtr(let params, let ret, _):
            for p in params { checkTypeExpr(p) }
            checkTypeExpr(ret)
        case .array(let elem, let len, _):
            checkTypeExpr(elem)
            if let l = len { checkExpr(l) }
        case .slice(let elem, _):
            checkTypeExpr(elem)
        case .option(let inner, _):
            checkTypeExpr(inner)
        case .never:
            break
        case .tuple(let elems, _):
            for e in elems { checkTypeExpr(e) }
        case .named(_, let typeArgs, _):
            for ta in typeArgs { checkTypeExpr(ta) }
        case .assocBinding(_, let value, _):
            checkTypeExpr(value)
        case .dynTrait(let inner, _), .implTrait(let inner, _):
            checkTypeExpr(inner)
        case .bounded(let base, let bounds, _):
            checkTypeExpr(base)
            for bound in bounds { checkTypeExpr(bound) }
        case .unit, .selfType, .inferred:
            break
        }
    }

    // MARK: - Expressions

    private func checkExpr(_ expr: Expr) {
        switch expr {
        case .awaitExpr(_, let s):
            reject("E9015", "await expressions are not available in the bootstrap subset", s)
        case .handleExpr(let h):
            reject("E9016", "handle/with expressions are not available in the bootstrap subset", h.span)
        case .unlessExpr(let u):
            reject("E9017", "unless expressions are not available in the bootstrap subset", u.span)
        case .untilExpr(let u):
            reject("E9018", "until expressions are not available in the bootstrap subset", u.span)
        case .tryBlock(let t):
            reject("E9019", "try/catch/finally blocks are not available in the bootstrap subset", t.span)
        case .comptimeBlock(_, let s):
            reject("E9006", "comptime blocks are not available in the bootstrap subset", s)

        // Recursively walk all other expression forms
        case .intLit, .floatLit, .stringLit, .charLit, .boolLit,
             .name, .path, .nextExpr:
            break
        case .array(let elems, _):
            for e in elems { checkExpr(e) }
        case .arrayRepeat(let val, let count, _):
            checkExpr(val)
            checkExpr(count)
        case .tuple(let elems, _):
            for e in elems { checkExpr(e) }
        case .structLit(_, _, let fields, let rest, _):
            for (_, v) in fields { checkExpr(v) }
            if let r = rest { checkExpr(r) }
        case .block(let b, _):
            checkBlock(b)
        case .unsafeBlock(_, let b, _):
            checkBlock(b)
        case .ifExpr(let e):
            checkExpr(e.condition)
            checkBlock(e.thenBlock)
            for clause in e.elsifClauses {
                checkExpr(clause.condition)
                checkBlock(clause.body)
            }
            if let el = e.elseBlock { checkBlock(el) }
            if let v = e.ifLetValue { checkExpr(v) }
        case .call(let callee, _, let args, _):
            checkExpr(callee)
            for arg in args { checkExpr(arg.value) }
        case .index(let base, let idx, _):
            checkExpr(base)
            checkExpr(idx)
        case .range(let start, let end, _, _):
            checkExpr(start)
            checkExpr(end)
        case .matchExpr(let m):
            checkExpr(m.subject)
            for arm in m.arms {
                if let g = arm.guardExpr { checkExpr(g) }
                checkExpr(arm.body)
            }
        case .cast(let e, let ty, _):
            checkExpr(e)
            checkTypeExpr(ty)
        case .tryOp(let e, _):
            checkExpr(e)
        case .closure(let c):
            for p in c.params {
                if let ty = p.type { checkTypeExpr(ty) }
            }
            if let ret = c.returnType { checkTypeExpr(ret) }
            checkExpr(c.body)
        case .unary(_, let e, _):
            checkExpr(e)
        case .field(let base, _, _):
            checkExpr(base)
        case .binary(let l, _, let r, _):
            checkExpr(l)
            checkExpr(r)
        case .macroCall(_, let args, _):
            for arg in args {
                if case .expr(let expr) = arg {
                    checkExpr(expr)
                }
            }
        case .assign(let target, let value, _):
            checkExpr(target)
            checkExpr(value)
        case .compoundAssign(let target, _, let value, _):
            checkExpr(target)
            checkExpr(value)
        case .returnExpr(let e, _):
            if let e = e { checkExpr(e) }
        case .breakExpr(let e, _):
            if let e = e { checkExpr(e) }
        case .forExpr(let f):
            checkExpr(f.iterable)
            checkBlock(f.body)
        case .whileExpr(let w):
            checkExpr(w.condition)
            checkBlock(w.body)
        case .loopExpr(let b, _):
            checkBlock(b)
        }
    }

    // MARK: - Blocks and Statements

    private func checkBlock(_ block: BlockBody) {
        for stmt in block.stmts {
            checkStmt(stmt)
        }
        if let tail = block.tailExpr {
            checkExpr(tail)
        }
    }

    private func checkStmt(_ stmt: Stmt) {
        switch stmt {
        case .letBinding(_, _, let ty, let value, _):
            if let ty = ty { checkTypeExpr(ty) }
            checkExpr(value)
        case .exprStmt(let e, _):
            checkExpr(e)
        case .attributeStmt:
            break
        case .attributed(_, let inner, _):
            checkStmt(inner)
        case .deferStmt(let body, _):
            checkBlock(body)
        case .item(let item):
            checkItem(item)
        }
    }

    // MARK: - Helpers

    private func reject(_ code: String, _ message: String, _ span: Span) {
        diagnostics.error(code: code, message: message, span: span, stage: .subsetChecker)
    }
}
