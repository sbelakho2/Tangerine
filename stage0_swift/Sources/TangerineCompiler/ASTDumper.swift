// ASTDumper.swift — Deterministic, diffable AST text representation
// Used by Stage 6 (hash every stage output) and Stage 7 (phase snapshot infrastructure).
// Produces a stable, human-readable, span-free tree dump suitable for diffing and hashing.

import Foundation

public final class ASTDumper {
    private var lines: [String] = []
    private var indent: Int = 0

    public init() {}

    public func dump(_ program: Program) -> String {
        lines = []
        indent = 0
        emit("Program")
        push()
        for item in program.items {
            dumpItem(item)
        }
        pop()
        return lines.joined(separator: "\n")
    }

    // MARK: - Hash

    /// FNV-1a 64-bit hash of the dump output.
    public func hash(_ program: Program) -> UInt64 {
        let text = dump(program)
        return fnv1a64(text)
    }

    /// Hex string of the hash.
    public func hashHex(_ program: Program) -> String {
        let h = hash(program)
        return String(format: "%016llx", h)
    }

    // MARK: - FNV-1a 64-bit

    private func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    // MARK: - Indentation helpers

    private func emit(_ text: String) {
        lines.append(String(repeating: "  ", count: indent) + text)
    }

    private func push() { indent += 1 }
    private func pop() { indent -= 1 }

    // MARK: - Items

    private func dumpItem(_ item: Item) {
        if !item.attributes.isEmpty {
            for attr in item.attributes {
                emit("@\(attr.name)\(attr.args.isEmpty ? "" : "(...)")")
            }
        }
        switch item.kind {
        case .function(let d):
            dumpFunctionDecl(d)
        case .testDecl(let d):
            emit("Test \(d.name)")
            push(); dumpBlock(d.body); pop()
        case .structDef(let d):
            emit("Struct \(d.name)\(d.isPublic ? " [pub]" : "")\(typeParamsStr(d.typeParams))")
            push()
            for f in d.fields {
                emit("Field \(f.name)")
                push(); dumpTypeExpr(f.type); pop()
            }
            pop()
        case .enumDef(let d):
            emit("Enum \(d.name)\(d.isPublic ? " [pub]" : "")\(typeParamsStr(d.typeParams))")
            push()
            for v in d.variants {
                emit("Variant \(v.name)")
            }
            pop()
        case .traitDef(let d):
            emit("Trait \(d.name)\(d.isPublic ? " [pub]" : "")\(typeParamsStr(d.typeParams))")
            push()
            for m in d.methods { dumpFunctionDecl(m) }
            for a in d.associatedTypes { emit("AssocType \(a.name)") }
            pop()
        case .implBlock(let d):
            emit("Impl\(d.traitName.map { " \($0) for" } ?? "") \(d.targetType)\(typeParamsStr(d.typeParams))")
            push()
            for m in d.methods { dumpFunctionDecl(m) }
            pop()
        case .useDecl(let d):
            emit("Use \(d.pathString)")
        case .constDecl(let d):
            emit("Const \(d.name)\(d.isPublic ? " [pub]" : "")")
            push()
            emit("Type:"); push(); dumpTypeExpr(d.type); pop()
            emit("Value:"); push(); dumpExpr(d.value); pop()
            pop()
        case .staticDecl(let d):
            emit("Static \(d.name)\(d.isPublic ? " [pub]" : "")\(d.isMutable ? " [mut]" : "")")
            push()
            emit("Type:"); push(); dumpTypeExpr(d.type); pop()
            emit("Value:"); push(); dumpExpr(d.value); pop()
            pop()
        case .typeAlias(let d):
            emit("TypeAlias \(d.name)\(d.isPublic ? " [pub]" : "")")
        case .externBlock(let d):
            emit("Extern\(d.abi.map { " \"\($0)\"" } ?? "")")
            push()
            for item in d.items { dumpItem(item) }
            pop()
        case .moduleDef(let d):
            emit("Module \(d.name)\(d.isPublic ? " [pub]" : "")")
            if let items = d.items {
                push()
                for sub in items { dumpItem(sub) }
                pop()
            }
        case .capabilityDecl(let d):
            emit("Cap \(d.name)")
        case .effectDecl(let d):
            emit("Effect \(d.name)")
        case .rationaleBlock:
            emit("Rationale")
        case .macroDecl(let d):
            emit("Macro \(d.name)")
        case .editionDecl(let d):
            emit("Edition \(d.version)")
        }
    }

    private func dumpFunctionDecl(_ d: FunctionDecl) {
        var mods = ""
        if d.sig.isPublic { mods += " [pub]" }
        if d.sig.isAsync { mods += " [async]" }
        if d.sig.isUnsafe { mods += " [unsafe]" }
        if d.sig.isConst { mods += " [const]" }
        if d.sig.isPure { mods += " [pure]" }
        if d.sig.isInline { mods += " [inline]" }
        if d.sig.isExtern { mods += " [extern]" }
        emit("Fn \(d.sig.name)\(mods)\(typeParamsStr(d.sig.typeParams))")
        push()
        if !d.sig.params.isEmpty {
            emit("Params:")
            push()
            for p in d.sig.params {
                emit("\(p.name)\(p.isMutable ? " [mut]" : "")")
                push(); dumpTypeExpr(p.type); pop()
            }
            pop()
        }
        if let ret = d.sig.returnType {
            emit("Returns:")
            push(); dumpTypeExpr(ret); pop()
        }
        dumpFunctionBody(d.body)
        pop()
    }

    private func dumpFunctionBody(_ body: FunctionBody) {
        switch body {
        case .block(let b):
            emit("Body:")
            push(); dumpBlock(b); pop()
        case .expr(let e):
            emit("Body =")
            push(); dumpExpr(e); pop()
        case .signatureOnly:
            emit("Body: (none)")
        }
    }

    private func dumpBlock(_ block: BlockBody) {
        for stmt in block.stmts { dumpStmt(stmt) }
        if let tail = block.tailExpr {
            emit("TailExpr:")
            push(); dumpExpr(tail); pop()
        }
    }

    // MARK: - Statements

    private func dumpStmt(_ stmt: Stmt) {
        switch stmt {
        case .letBinding(let pat, let mutable, let type, let value, _):
            emit("Let\(mutable ? " mut" : "")")
            push()
            emit("Pattern:"); push(); dumpPattern(pat); pop()
            if let t = type {
                emit("Type:"); push(); dumpTypeExpr(t); pop()
            }
            emit("Value:"); push(); dumpExpr(value); pop()
            pop()
        case .exprStmt(let e, _):
            dumpExpr(e)
        case .attributeStmt(let attrs, _):
            emit("StmtAttrs")
            push()
            for attr in attrs {
                emit("@\(attr.name)")
            }
            pop()
        case .attributed(let attrs, let inner, _):
            emit("StmtAttrs")
            push()
            for attr in attrs {
                emit("@\(attr.name)")
            }
            dumpStmt(inner)
            pop()
        case .item(let item):
            dumpItem(item)
        }
    }

    // MARK: - Expressions

    private func dumpExpr(_ expr: Expr) {
        switch expr {
        case .intLit(let v, _): emit("Int(\(v))")
        case .floatLit(let v, _): emit("Float(\(v))")
        case .stringLit(let v, _): emit("String(\"\(v)\")")
        case .charLit(let v, _): emit("Char('\(v)')")
        case .boolLit(let v, _): emit("Bool(\(v))")
        case .name(let n, _): emit("Name(\(n))")
        case .path(let a, let b, _): emit("Path(\(a)::\(b))")
        case .array(let elems, _):
            emit("Array")
            push(); for e in elems { dumpExpr(e) }; pop()
        case .arrayRepeat(let v, let c, _):
            emit("ArrayRepeat")
            push(); dumpExpr(v); dumpExpr(c); pop()
        case .tuple(let elems, _):
            emit("Tuple")
            push(); for e in elems { dumpExpr(e) }; pop()
        case .structLit(let name, _, let fields, let rest, _):
            emit("StructLit(\(name))")
            push()
            for (k, v) in fields {
                emit("\(k):"); push(); dumpExpr(v); pop()
            }
            if let r = rest { emit("..rest:"); push(); dumpExpr(r); pop() }
            pop()
        case .block(let b, _):
            emit("Block")
            push(); dumpBlock(b); pop()
        case .unsafeBlock(let reason, let b, _):
            emit("UnsafeBlock(\(reason))")
            push(); dumpBlock(b); pop()
        case .ifExpr(let e):
            emit("If")
            push()
            emit("Cond:"); push(); dumpExpr(e.condition); pop()
            emit("Then:"); push(); dumpBlock(e.thenBlock); pop()
            for clause in e.elsifClauses {
                emit("ElsIf:"); push(); dumpExpr(clause.condition); dumpBlock(clause.body); pop()
            }
            if let el = e.elseBlock {
                emit("Else:"); push(); dumpBlock(el); pop()
            }
            pop()
        case .call(let callee, _, let args, _):
            emit("Call")
            push()
            emit("Callee:"); push(); dumpExpr(callee); pop()
            if !args.isEmpty {
                emit("Args:")
                push()
                for a in args {
                    if let lbl = a.label { emit("\(lbl):") }
                    push(); dumpExpr(a.value); pop()
                }
                pop()
            }
            pop()
        case .index(let base, let idx, _):
            emit("Index")
            push(); dumpExpr(base); dumpExpr(idx); pop()
        case .range(let s, let e, let incl, _):
            emit("Range\(incl ? "Inclusive" : "")")
            push(); dumpExpr(s); dumpExpr(e); pop()
        case .matchExpr(let m):
            emit("Match")
            push()
            emit("Subject:"); push(); dumpExpr(m.subject); pop()
            for arm in m.arms {
                emit("Arm:")
                push()
                dumpPattern(arm.pattern)
                if let g = arm.guardExpr { emit("Guard:"); push(); dumpExpr(g); pop() }
                emit("Body:"); push(); dumpExpr(arm.body); pop()
                pop()
            }
            pop()
        case .cast(let e, let t, _):
            emit("Cast")
            push(); dumpExpr(e); dumpTypeExpr(t); pop()
        case .tryOp(let e, _):
            emit("TryOp")
            push(); dumpExpr(e); pop()
        case .closure(let c):
            emit("Closure")
            push()
            if !c.params.isEmpty {
                emit("Params:")
                push()
                for p in c.params { emit(p.name) }
                pop()
            }
            emit("Body:"); push(); dumpExpr(c.body); pop()
            pop()
        case .unary(let op, let e, _):
            emit("Unary(\(op))")
            push(); dumpExpr(e); pop()
        case .field(let base, let f, _):
            emit("Field(.\(f))")
            push(); dumpExpr(base); pop()
        case .binary(let l, let op, let r, _):
            emit("Binary(\(op.rawValue))")
            push(); dumpExpr(l); dumpExpr(r); pop()
        case .awaitExpr(let e, _):
            emit("Await")
            push(); dumpExpr(e); pop()
        case .macroCall(let name, let args, _):
            emit("MacroCall(\(name))")
            push()
            for arg in args {
                switch arg {
                case .expr(let expr):
                    dumpExpr(expr)
                case .tokens(let text, _):
                    emit("MacroTokens(\(text))")
                }
            }
            pop()
        case .assign(let t, let v, _):
            emit("Assign")
            push(); dumpExpr(t); dumpExpr(v); pop()
        case .compoundAssign(let t, let op, let v, _):
            emit("CompoundAssign(\(op.rawValue))")
            push(); dumpExpr(t); dumpExpr(v); pop()
        case .returnExpr(let e, _):
            emit("Return")
            if let e = e { push(); dumpExpr(e); pop() }
        case .breakExpr(let e, _):
            emit("Break")
            if let e = e { push(); dumpExpr(e); pop() }
        case .nextExpr:
            emit("Next")
        case .forExpr(let f):
            emit("For")
            push()
            dumpPattern(f.pattern)
            emit("In:"); push(); dumpExpr(f.iterable); pop()
            emit("Body:"); push(); dumpBlock(f.body); pop()
            pop()
        case .whileExpr(let w):
            emit("While")
            push()
            emit("Cond:"); push(); dumpExpr(w.condition); pop()
            emit("Body:"); push(); dumpBlock(w.body); pop()
            pop()
        case .loopExpr(let b, _):
            emit("Loop")
            push(); dumpBlock(b); pop()
        case .handleExpr(let h):
            emit("Handle(\(h.effectName))")
            push()
            dumpExpr(h.expr)
            for arm in h.arms { emit("Op(\(arm.op)):"); push(); dumpExpr(arm.body); pop() }
            pop()
        case .unlessExpr(let u):
            emit("Unless")
            push()
            emit("Cond:"); push(); dumpExpr(u.condition); pop()
            emit("Body:"); push(); dumpBlock(u.body); pop()
            pop()
        case .untilExpr(let u):
            emit("Until")
            push()
            emit("Cond:"); push(); dumpExpr(u.condition); pop()
            emit("Body:"); push(); dumpBlock(u.body); pop()
            pop()
        case .tryBlock(let t):
            emit("TryBlock")
            push()
            emit("Body:"); push(); dumpBlock(t.body); pop()
            for c in t.catchClauses {
                emit("Catch:"); push(); dumpBlock(c.body); pop()
            }
            if let f = t.finallyBlock {
                emit("Finally:"); push(); dumpBlock(f); pop()
            }
            pop()
        case .comptimeBlock(let b, _):
            emit("Comptime")
            push(); dumpBlock(b); pop()
        }
    }

    // MARK: - Types

    private func dumpTypeExpr(_ type: TypeExpr) {
        switch type {
        case .named(let n, let args, _):
            if args.isEmpty { emit("Type(\(n))") }
            else {
                emit("Type(\(n))")
                push(); for a in args { dumpTypeExpr(a) }; pop()
            }
        case .assocBinding(let name, let value, _):
            emit("AssocBinding(\(name))")
            push(); dumpTypeExpr(value); pop()
        case .constExpr(let expr, _):
            emit("ConstTypeArg")
            push(); dumpExpr(expr); pop()
        case .never:
            emit("Never")
        case .tuple(let elems, _):
            emit("TupleType")
            push(); for e in elems { dumpTypeExpr(e) }; pop()
        case .unit: emit("Unit")
        case .ref(let t, let mutable, _):
            emit("Ref\(mutable ? "Mut" : "")")
            push(); dumpTypeExpr(t); pop()
        case .rawPtr(let t, let mutable, _):
            emit("RawPtr\(mutable ? "Mut" : "")")
            push(); dumpTypeExpr(t); pop()
        case .fnPtr(let params, let ret, _):
            emit("FnPtr")
            push()
            for p in params { dumpTypeExpr(p) }
            emit("->"); dumpTypeExpr(ret)
            pop()
        case .array(let t, let len, _):
            emit("ArrayType\(len != nil ? "[fixed]" : "")")
            push(); dumpTypeExpr(t); pop()
        case .slice(let t, _):
            emit("Slice")
            push(); dumpTypeExpr(t); pop()
        case .selfType: emit("Self")
        case .dynTrait(let inner, _):
            emit("dyn")
            push(); dumpTypeExpr(inner); pop()
        case .implTrait(let inner, _):
            emit("impl")
            push(); dumpTypeExpr(inner); pop()
        case .bounded(let base, let bounds, _):
            emit("Bounds")
            push()
            dumpTypeExpr(base)
            for bound in bounds { dumpTypeExpr(bound) }
            pop()
        case .option(let t, _):
            emit("Option")
            push(); dumpTypeExpr(t); pop()
        case .inferred: emit("_")
        }
    }

    // MARK: - Patterns

    private func dumpPattern(_ pattern: Pattern) {
        switch pattern {
        case .wildcard: emit("_")
        case .ident(let n, let mutable, _): emit("Pat(\(mutable ? "mut " : "")\(n))")
        case .refPattern(let n, _): emit("Pat(&\(n))")
        case .refMutPattern(let n, _): emit("Pat(&mut \(n))")
        case .literal(let e, _): dumpExpr(e)
        case .variant(let t, let v, let fields, _):
            emit("Pat(\(t)::\(v))")
            if !fields.isEmpty { push(); for f in fields { dumpPattern(f) }; pop() }
        case .structPattern(let n, let fields, _):
            emit("StructPat(\(n))")
            if !fields.isEmpty {
                push()
                for (fieldName, optPat) in fields {
                    if let p = optPat { emit("\(fieldName):"); push(); dumpPattern(p); pop() }
                    else { emit("\(fieldName)") }
                }
                pop()
            }
        case .tuple(let pats, _):
            emit("Pat()")
            push(); for p in pats { dumpPattern(p) }; pop()
        case .orPattern(let a, let b, _):
            emit("Pat(|)")
            push(); dumpPattern(a); dumpPattern(b); pop()
        case .rangePattern(let a, let b, _):
            emit("Pat(..)")
            push(); dumpPattern(a); dumpPattern(b); pop()
        }
    }

    // MARK: - Helpers

    private func typeParamsStr(_ params: [TypeParam]) -> String {
        guard !params.isEmpty else { return "" }
        return "[\(params.map(\.name).joined(separator: ", "))]"
    }
}
