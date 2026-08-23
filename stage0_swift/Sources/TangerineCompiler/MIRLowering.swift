// MIRLowering.swift — AST → MIR lowering for the stabilized subset
// Converts parsed AST to MIR basic blocks for interpretation.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class MIRLowering {
    private var functions: [MirFunction] = []
    private var statics: [MirStatic] = []
    private var typeDefs: [MirTypeDef] = []
    private var typeDefByName: [String: MirTypeDef] = [:]
    private var variantCache: [String: (MirTypeDef, Int)] = [:]  // "TypeName::VariantName" → (def, idx)
    public private(set) var errors: [String] = []
    private var currentSelfType: String?
    private let rootModulePath: [String]
    private var modulePath: [String]

    // Per-function state
    private var blocks: [MirBlock] = []
    private var locals: [MirLocal] = []
    private var currentBlock: BlockId = 0
    private var nextLocal: LocalId = 0
    private var nextBlock: BlockId = 0
    private var returnLocal: LocalId = 0

    // Scope: name → LocalId
    private var scopes: [[String: LocalId]] = []

    // Loop break/continue target stacks
    private var loopBreakTargets: [BlockId] = []
    private var loopContinueTargets: [BlockId] = []

    // Registered defer bodies (as pre-lowered exit blocks), in registration
    // order; executed at the function's exit cleanup, LIFO (the kernel's
    // defer model, bounded to the function end).
    private var pendingDeferBlocks: [BlockId] = []

    // Function resolution cache: name → resolved name
    private var fnCache: [String: String] = [:]
    private var functionReturnTypes: [String: MirType] = [:]
    private var functionParamConventions: [String: [AccessConvention]] = [:]

    /// Set of qualified function names whose `self` parameter is by-value (no &/&mut).
    private var methodSelfByValue: Set<String> = []

    /// Creates a lowering context for one module.
    /// - Parameter modulePath: the owner module path (file-derived segments,
    ///   mirror of module_path_from_file). nil/empty = the root module; the
    ///   module-qualified identity for type/function names is the
    ///   (module path, name) registration the Tangerine resolver uses.
    public init(modulePath: [String]? = nil) {
        self.rootModulePath = modulePath ?? []
        self.modulePath = rootModulePath
    }

    /// Pre-load type definitions from other modules for cross-file enum resolution
    public func preloadTypes(_ types: [MirTypeDef]) {
        typeDefs.append(contentsOf: types)
        rebuildTypeCache()
    }

    /// Rebuild the type definition lookup caches for O(1) resolution.
    private func rebuildTypeCache() {
        typeDefByName.removeAll(keepingCapacity: true)
        variantCache.removeAll(keepingCapacity: true)
        for td in typeDefs {
            registerTypeDefInCaches(td)
        }
    }

    /// Register one type def in the lookup caches (the audit item 13 —
    /// decided deliberately):
    ///   - the QUALIFIED key (td.name / "Type::Variant") is the
    ///     registration authority — always exact, always the last
    ///     registration (the kernel's per-module tables +
    ///     module_qualified_key);
    ///   - the bare-name type slot and the "bareType::Variant" slot are
    ///     LAST-DEF-WINS mirrors (the later registration shadows the
    ///     earlier one, consistent with the flat per-module registration
    ///     order); they never shadow the qualified keys, which every
    ///     qualified lookup consults first;
    ///   - the variant-NAME-ALONE slot is QUALIFIED-ONLY where the hazard
    ///     matters: the slot exists only while the variant name is
    ///     globally unambiguous (the first registration); a same-named
    ///     variant in a second enum REMOVES the bare slot, so an
    ///     unqualified variant reference ("Some") never depends on the
    ///     registration order — it falls back to the exact-name scan with
    ///     the uniqueness requirement (the kernel's per-module tables
    ///     decide the bare reference).
    private func registerTypeDefInCaches(_ td: MirTypeDef) {
        typeDefByName[td.name] = td
        let bareName = typeNameParts(td.name).last ?? td.name
        typeDefByName[bareName] = td
        if case .enumDef(let variants) = td.kind {
            for (idx, variant) in variants.enumerated() {
                variantCache["\(td.name)::\(variant.0)"] = (td, idx)
                variantCache["\(bareName)::\(variant.0)"] = (td, idx)
                if let existing = variantCache[variant.0] {
                    if existing.0.name != td.name {
                        variantCache.removeValue(forKey: variant.0)
                    }
                } else {
                    variantCache[variant.0] = (td, idx)
                }
            }
        }
    }

    private func resetModulePath() {
        modulePath = rootModulePath
    }

    private func pushModule(_ name: String) {
        modulePath.append(name)
    }

    private func popModule() {
        if !modulePath.isEmpty {
            modulePath.removeLast()
        }
    }

    private func currentModuleName() -> String? {
        guard !modulePath.isEmpty else {
            return nil
        }
        return modulePath.joined(separator: "::")
    }

    private func qualifiedTypeName(_ name: String) -> String {
        guard !name.contains("::"), let moduleName = currentModuleName(), !moduleName.isEmpty else {
            return name
        }
        return "\(moduleName)::\(name)"
    }

    private func syntheticEnumPayloadTypeDef(enumName: String, variant: VariantDecl) -> MirTypeDef? {
        guard !variant.fields.isEmpty else {
            return nil
        }
        var fields: [(String, MirType)] = []
        fields.reserveCapacity(variant.fields.count)
        for field in variant.fields {
            guard let fieldName = field.name else {
                return nil
            }
            fields.append((fieldName, lowerTypeExpr(field.type)))
        }
        return MirTypeDef(name: "\(enumName)::\(variant.name)", kind: .structDef(fields: fields))
    }

    private func appendEnumTypeDefs(_ decl: EnumDecl, to sink: inout [MirTypeDef]) {
        let enumName = qualifiedTypeName(decl.name)
        let variants = decl.variants.map { variant in
            (variant.name, variant.fields.map { lowerTypeExpr($0.type) })
        }
        sink.append(MirTypeDef(name: enumName, kind: .enumDef(variants: variants)))
        for variant in decl.variants {
            if let payloadType = syntheticEnumPayloadTypeDef(enumName: enumName, variant: variant) {
                sink.append(payloadType)
            }
        }
    }

    private func moduleQualifiedTypeNames(for bareName: String) -> [String] {
        guard !bareName.contains("::"), !modulePath.isEmpty else {
            return []
        }
        var candidates: [String] = []
        for depth in stride(from: modulePath.count, through: 1, by: -1) {
            let prefix = modulePath.prefix(depth).joined(separator: "::")
            candidates.append("\(prefix)::\(bareName)")
        }
        return candidates
    }

    private func typeNameParts(_ name: String) -> [String] {
        name.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private func looksLikeConstFunctionPattern(_ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if (65...90).contains(value) || (48...57).contains(value) || value == 95 {
                continue
            }
            return false
        }
        return true
    }

    // MARK: - Public API

    /// Collect only type definitions (structs/enums) without lowering functions
    public func collectTypes(_ program: Program) -> [MirTypeDef] {
        resetModulePath()
        var types: [MirTypeDef] = []
        func collectFromItems(_ items: [Item]) {
            for item in items {
                switch item.kind {
                case .structDef(let d):
                    let fields = d.fields.map { ($0.name, lowerTypeExpr($0.type)) }
                    types.append(MirTypeDef(name: qualifiedTypeName(d.name), kind: .structDef(fields: fields)))
                case .enumDef(let d):
                    appendEnumTypeDefs(d, to: &types)
                case .moduleDef(let d):
                    pushModule(d.name)
                    if let children = d.items { collectFromItems(children) }
                    popModule()
                case .implBlock(let d):
                    // Impl blocks don't contain type defs directly.
                    _ = d
                default:
                    break
                }
            }
        }
        collectFromItems(program.items)
        return types
    }

    private func collectFunctionReturnTypes(_ items: [Item]) {
        for item in items {
            switch item.kind {
            case .function(let fn):
                // The MIR function identity is the module-qualified key
                // (the audit item 12): two `def foo()` in different
                // modules must NOT collide — the Item.modulePath is the
                // registration authority (the kernel's
                // module_qualified_key).
                let qualifiedName = Program.moduleQualifiedKey(path: item.modulePath, name: fn.sig.name)
                functionReturnTypes[qualifiedName] = fn.sig.returnType.map(lowerTypeExpr) ?? .unit
                functionParamConventions[qualifiedName] = fn.sig.params.map { $0.convention }
            case .moduleDef(let d):
                if let children = d.items {
                    collectFunctionReturnTypes(children)
                }
            case .implBlock(let d):
                let previousSelfType = currentSelfType
                currentSelfType = d.targetType
                for method in d.methods {
                    functionReturnTypes["\(d.targetType)::\(method.sig.name)"] = method.sig.returnType.map(lowerTypeExpr) ?? .unit
                    functionParamConventions["\(d.targetType)::\(method.sig.name)"] = method.sig.params.map { $0.convention }
                }
                currentSelfType = previousSelfType
            case .structDef(let d):
                if d.kind == .resource {
                    let typeName = qualifiedTypeName(d.name)
                    for method in d.methods {
                        functionReturnTypes["\(typeName)::\(method.sig.name)"] = method.sig.returnType.map(lowerTypeExpr) ?? .unit
                        functionParamConventions["\(typeName)::\(method.sig.name)"] = method.sig.params.map { $0.convention }
                    }
                }
            default:
                break
            }
        }
    }

    private func functionAliases(for qualified: String) -> [String] {
        let parts = qualified.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return [] }

        let member = parts.last!
        let owner = parts.dropLast().joined(separator: "::")

        switch owner {
        case "Vec":
            return ["Array::\(member)"]
        case "Array":
            return ["Vec::\(member)"]
        case "HashMap":
            return ["Map::\(member)"]
        case "Map":
            return ["HashMap::\(member)"]
        case "HashSet":
            return ["Set::\(member)"]
        case "Set":
            return ["HashSet::\(member)"]
        default:
            return []
        }
    }

    private func lookupFunctionReturnType(_ name: String) -> MirType? {
        if let ret = functionReturnTypes[name] {
            return ret
        }

        let resolvedName = resolveFunctionName(name)
        if let ret = functionReturnTypes[resolvedName] {
            return ret
        }

        for alias in functionAliases(for: name) {
            if let ret = functionReturnTypes[alias] {
                return ret
            }
        }

        return nil
    }

    private func lookupFunctionConventions(_ name: String) -> [AccessConvention]? {
        if let conventions = functionParamConventions[name] {
            return conventions
        }

        let resolvedName = resolveFunctionName(name)
        if let conventions = functionParamConventions[resolvedName] {
            return conventions
        }

        for alias in functionAliases(for: name) {
            if let conventions = functionParamConventions[alias] {
                return conventions
            }
        }

        return nil
    }

    private func effect(for convention: AccessConvention) -> AccessEffect {
        switch convention {
        case .letAccess: return .read
        case .inoutAccess: return .modify
        case .sink: return .consume
        case .set: return .initialize
        }
    }

    private func argEffects(forCallee name: String, argCount: Int) -> [AccessEffect] {
        let conventions = lookupFunctionConventions(name)
        if let conventions {
            var effects: [AccessEffect] = []
            effects.reserveCapacity(argCount)
            for i in 0..<argCount {
                if i < conventions.count {
                    effects.append(effect(for: conventions[i]))
                } else {
                    effects.append(.read)
                }
            }
            return effects
        }
        return Array(repeating: .read, count: argCount)
    }

    private func lowerCallArg(_ expr: Expr, effectFallback: AccessEffect) -> MirCallArg {
        if case .unary(let op, let inner, _) = expr, op == .borrow || op == .borrowMut {
            if let place = exprToPlace(inner) {
                return MirCallArg(effect: op == .borrowMut ? .modify : .read, value: .place(place))
            }
        }
        return MirCallArg(effect: effectFallback, value: .value(lowerExpr(expr)))
    }

    private func inferDirectCallResultType(_ callee: Expr, loweredCallee: MirOperand? = nil) -> MirType {
        switch callee {
        case .name(let name, _):
            if let id = lookupScope(name), case .fn(_, let retType) = locals[id].type {
                return retType
            }
            return lookupFunctionReturnType(name) ?? .unknown
        case .path(let lhs, let rhs, _):
            return lookupFunctionReturnType("\(lhs)::\(rhs)") ?? .unknown
        default:
            if let loweredCallee,
               let calleeType = operandType(loweredCallee),
               case .fn(_, let retType) = calleeType {
                return retType
            }
            return .unknown
        }
    }

    private func inferMethodCallResultType(receiverType: MirType?, methodName: String) -> MirType {
        if let typeName = extractTypeName(receiverType),
           let retType = lookupFunctionReturnType("\(typeName)::\(methodName)") {
            return retType
        }

        switch methodName {
        case "clone":
            return receiverType ?? .unknown
        case "len", "capacity":
            return .int
        case "is_empty", "contains", "contains_key", "is_some", "is_none", "is_ok", "is_err", "starts_with", "ends_with":
            return .bool
        case "to_string", "fmt":
            return .string
        default:
            return .unknown
        }
    }

    public func lower(_ program: Program) -> MirProgram {
        resetModulePath()
        functionReturnTypes.removeAll(keepingCapacity: true)
        functionParamConventions.removeAll(keepingCapacity: true)
        collectFunctionReturnTypes(program.items)
        resetModulePath()
        for item in program.items {
            lowerItem(item)
        }
        return MirProgram(functions: functions, statics: statics, typeDefs: typeDefs)
    }

    public var hasErrors: Bool {
        !errors.isEmpty
    }

    // MARK: - Item lowering

    private func lowerItem(_ item: Item) {
        switch item.kind {
        case .function(let fn):
            // The MIR function name carries the module qualification (the
            // audit item 12): the Item.modulePath stamp is the identity
            // authority, so two `def foo()` in different modules register
            // distinct "path::foo" names and never collide. The bare
            // spelling stays reachable through resolveFunctionName's
            // "::foo" suffix pass and the interpreter's candidate search.
            var qualifiedFn = fn
            qualifiedFn.sig.name = Program.moduleQualifiedKey(path: item.modulePath, name: fn.sig.name)
            lowerFunction(qualifiedFn)
        case .testDecl:
            break
        case .constDecl(let d):
            statics.append(MirStatic(name: d.name, type: lowerTypeExpr(d.type),
                                      initializer: evalConstant(d.value), isMutable: false))
        case .staticDecl(let d):
            statics.append(MirStatic(name: d.name, type: lowerTypeExpr(d.type),
                                      initializer: evalConstant(d.value), isMutable: d.isMutable))
        case .structDef(let d):
            let fields = d.fields.map { ($0.name, lowerTypeExpr($0.type)) }
            let td = MirTypeDef(name: qualifiedTypeName(d.name), kind: .structDef(fields: fields))
            typeDefs.append(td)
            typeDefByName[td.name] = td
            if d.kind == .resource {
                let typeName = qualifiedTypeName(d.name)
                for method in d.methods {
                    lowerImplMethod(method, targetType: typeName)
                }
            }
        case .enumDef(let d):
            let beforeCount = typeDefs.count
            appendEnumTypeDefs(d, to: &typeDefs)
            // Rebuild cache for new enum types (including variants)
            if typeDefs.count > beforeCount {
                for i in beforeCount..<typeDefs.count {
                    registerTypeDefInCaches(typeDefs[i])
                }
            }
        case .moduleDef(let d):
            pushModule(d.name)
            for child in d.items ?? [] { lowerItem(child) }
            popModule()
        case .implBlock(let d):
            for method in d.methods {
                lowerImplMethod(method, targetType: d.targetType)
            }
            for c in d.consts {
                statics.append(MirStatic(name: "\(d.targetType)::\(c.name)",
                                          type: lowerTypeExpr(c.type),
                                          initializer: evalConstant(c.value),
                                          isMutable: false))
            }
        case .externBlock(let d):
            // Extern declarations become EMPTY MIR functions with the
            // isExtern flag set (the kernel's ItemExternBlock lowering —
            // codegen emits relocations instead of bodies). The decl's
            // FunctionSig carries isExtern = true, so lowerFunction marks
            // the MirFunction; an extern function is never silently
            // dropped from the program.
            for fn in d.functions {
                lowerFunction(fn)
            }
        default:
            break // traits, impls, use, type alias, extern, etc. — skipped in MIR lowering
        }
    }

    private func lowerImplMethod(_ fn: FunctionDecl, targetType: String) {
        let previousSelfType = currentSelfType
        currentSelfType = targetType
        defer { currentSelfType = previousSelfType }

        var sig = fn.sig
        if !sig.name.contains("::") {
            sig.name = "\(targetType)::\(sig.name)"
        }

        // Record whether self is by-value (no &/&mut on the type).
        // Methods with &self/&mut self (or an inout receiver) are NOT by-value;
        // default to borrowing.
        if let firstParam = fn.sig.params.first, firstParam.name == "self" {
            if firstParam.convention == .inoutAccess
                || firstParam.modifier == .ref
                || firstParam.modifier == .refMut {
                // &self or &mut self → NOT by-value
            } else {
                methodSelfByValue.insert(sig.name)
            }
        }

        let lowered = FunctionDecl(sig: sig, clauses: fn.clauses, body: fn.body, span: fn.span)
        lowerFunction(lowered)
    }

    // MARK: - Function lowering

    private func lowerFunction(_ fn: FunctionDecl) {
        // A nested function declaration (a `def` statement inside a function
        // body) lowers THROUGH this path while the enclosing function's
        // lowering is in progress. resetFunctionState() would otherwise wipe
        // the enclosing function's scopes/blocks/locals — the same
        // save/restore discipline lowerClosure applies to nested closures —
        // so the enclosing lowering state is preserved across the nested
        // function's lowering (the nested MirFunction still accumulates
        // into the shared program-level `functions` list).
        let savedBlocks = blocks
        let savedLocals = locals
        let savedCurrentBlock = currentBlock
        let savedNextLocal = nextLocal
        let savedNextBlock = nextBlock
        let savedReturnLocal = returnLocal
        let savedScopes = scopes
        let savedDeferBlocks = pendingDeferBlocks

        resetFunctionState()
        pushScope()

        // _0 is the return place
        let retType = fn.sig.returnType.map(lowerTypeExpr) ?? .unit
        returnLocal = freshLocal(name: "_return", type: retType, mutable: true)

        // Create param locals
        var paramLocals: [MirLocal] = []
        for p in fn.sig.params {
            let base = lowerTypeExpr(p.type)
            let ty: MirType
            if p.convention == .inoutAccess {
                ty = .refInternal(base, true)
            } else if p.modifier == .ref {
                ty = .refInternal(base, false)
            } else if p.modifier == .refMut {
                // A .refMut-modifier param is a mutable internal reference —
                // the same refInternal form as .ref (the mutability flag
                // carried; the old asymmetry that dropped .refMut to the
                // by-value type is fixed).
                ty = .refInternal(base, true)
            } else {
                ty = base
            }
            let id = freshLocal(name: p.name, type: ty, mutable: p.isMutable)
            defineInScope(p.name, id)
            paramLocals.append(locals[id])
        }

        // Entry block
        let entry = freshBlock()
        currentBlock = entry

        switch fn.body {
        case .block(let body):
            lowerBlock(body, resultInto: returnLocal)
            terminateIfNeeded(exitTerminator())
        case .expr(let expr):
            let val = lowerExpr(expr)
            emit(.assign(.local(returnLocal), .use(val)))
            terminateIfNeeded(exitTerminator())
        case .signatureOnly:
            terminateIfNeeded(exitTerminator())
        }

        popScope()

        // Wire the function's exit cleanup (the registered defers, LIFO)
        // and build the MirFunction with the declaration's flags.
        buildDeferExitChain()

        let mirFn = MirFunction(name: fn.sig.name, params: paramLocals, returnType: retType,
                                 locals: locals, blocks: blocks, entryBlock: entry,
                                 isAsync: fn.sig.isAsync,
                                 isUnsafe: fn.sig.isUnsafe,
                                 isExtern: fn.sig.isExtern)
        functions.append(mirFn)
        fnCache.removeAll()  // Invalidate cache when functions are added

        // Restore the enclosing function's lowering state (the nested
        // function's MIR is complete and registered).
        blocks = savedBlocks; locals = savedLocals
        currentBlock = savedCurrentBlock; nextLocal = savedNextLocal
        nextBlock = savedNextBlock; returnLocal = savedReturnLocal
        scopes = savedScopes
        pendingDeferBlocks = savedDeferBlocks
    }

    // MARK: - Block lowering

    private func lowerBlock(_ body: BlockBody, resultInto dest: LocalId) {
        for stmt in body.stmts {
            lowerStmt(stmt)
        }
        if let tail = body.tailExpr {
            let val = lowerExpr(tail)
            emit(.assign(.local(dest), .use(val)))
        }
    }

    // MARK: - Statement lowering

    private func lowerStmt(_ stmt: Stmt) {
        switch stmt {
        case .letBinding(let pattern, let mutable, let declaredType, let value, _):
            let valOp = lowerExpr(value)
            let typeHint = declaredType.map(lowerTypeExpr) ?? operandType(valOp)
            lowerPatternBinding(pattern, value: valOp, mutable: mutable, typeHint: typeHint)
        case .exprStmt(let expr, _):
            _ = lowerExpr(expr)
        case .attributeStmt:
            break
        case .attributed(_, let inner, _):
            lowerStmt(inner)
        case .item(let item):
            lowerItem(item)
        case .deferStmt(let body, _):
            // `defer { ... }` REGISTERS a deferred action — the body does
            // NOT execute at registration. The body's statements are
            // lowered into a dedicated exit block, wired into the
            // function's exit cleanup at function end and executed there
            // LIFO (the last registered defer runs first) — the kernel's
            // defer model, bounded to the function-level exit.
            let deferBlock = freshBlock()
            let savedBlock = currentBlock
            currentBlock = deferBlock
            pushScope()
            for s in body.stmts {
                lowerStmt(s)
            }
            if let tail = body.tailExpr {
                _ = lowerExpr(tail)
            }
            popScope()
            currentBlock = savedBlock
            pendingDeferBlocks.append(deferBlock)
        }
    }

    private func lowerPatternBinding(_ pattern: Pattern, value: MirOperand, mutable: Bool, typeHint: MirType? = nil) {
        switch pattern {
        case .ident(let name, _, _):
            let id = freshLocal(name: name, type: typeHint ?? .unknown, mutable: mutable)
            defineInScope(name, id)
            emit(.assign(.local(id), .use(value)))
        case .wildcard:
            break // discard
        case .tuple(let pats, _):
            for (i, pat) in pats.enumerated() {
                let tmp = freshTemp()
                emit(.assign(.local(tmp), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.field(i)])))))
                let elementType: MirType?
                if case .tuple(let elems)? = typeHint, i < elems.count {
                    elementType = elems[i]
                } else {
                    elementType = nil
                }
                lowerPatternBinding(pat, value: .mirCopy(.local(tmp)), mutable: mutable, typeHint: elementType)
            }
        default:
            break // other patterns handled minimally
        }
    }

    // MARK: - Expression lowering

    private func lowerExpr(_ expr: Expr) -> MirOperand {
        switch expr {
        case .intLit(let s, let span):
            guard let v = MIRLowering.parseInt(s) else {
                recordLoweringError("MIRLowering: unparseable integer literal '\(s)' at span \(span.start)..<\(span.end) — the parse failure is reported at the literal's span (INV-PARSE-003 fail-closed), never a silent 0")
                return .mirConstant(.int(0))
            }
            return .mirConstant(.int(v))
        case .floatLit(let s, let span):
            guard let v = MIRLowering.parseFloatLiteral(s) else {
                recordLoweringError("MIRLowering: unparseable float literal '\(s)' at span \(span.start)..<\(span.end) — the parse failure is reported at the literal's span (INV-PARSE-003 fail-closed), never a silent 0.0")
                return .mirConstant(.float(0.0))
            }
            return .mirConstant(.float(v))
        case .stringLit(let s, _):
            return .mirConstant(.str(s))
        case .charLit(let c, _):
            return .mirConstant(.char(c))
        case .boolLit(let b, _):
            return .mirConstant(.bool(b))
        case .name(let n, _):
            if let id = lookupScope(n) {
                return .mirCopy(.local(id))
            }
            // A registered static (mut static / const / impl const) reads
            // as the MirStaticRef constant — the kernel's MirStaticRef(DefId)
            // form, name-keyed (the seed's MirStaticId is the MirStatic
            // name). Never the fnItem mis-lowering.
            if statics.contains(where: { $0.name == n }) {
                return .mirConstant(.staticRef(n))
            }
            // Check for A::B style enum variants encoded as name
            if n.contains("::") {
                let parts = typeNameParts(n)
                if parts.count >= 2 {
                    let enumName = parts.dropLast().joined(separator: "::")
                    let variantName = parts.last!
                    if let (td, idx) = resolveNamedVariant(enumName, variantName: variantName, expectedFieldCount: 0) {
                        if case .enumDef(let variants) = td.kind, variants[idx].1.isEmpty {
                            let tmp = freshTemp(type: .named(td.name, []))
                            // Zero-field variant: the enumCtor carries an
                            // EMPTY payload (no unit stub).
                            emit(.assign(.local(tmp), .aggregate(.enumCtor(td.name, idx), [])))
                            return .mirCopy(.local(tmp))
                        }
                        return .mirConstant(.fnItem(n))
                    }
                }
            }
            // Could be a function reference - try to resolve to fully qualified name
            let resolvedName = resolveFunctionName(n)
            return .mirConstant(.fnItem(resolvedName))
        case .path(let a, let b, _):
            // A qualified static (impl const "Type::NAME", module statics)
            // reads as the MirStaticRef constant before the fnItem fallback.
            let qualifiedStatic = "\(a)::\(b)"
            if statics.contains(where: { $0.name == qualifiedStatic }) {
                return .mirConstant(.staticRef(qualifiedStatic))
            }
            // Check if this is an enum variant (e.g., Option::None, Subcommand::Build)
            if let (td, idx) = resolveNamedVariant(a, variantName: b, expectedFieldCount: 0) {
                if case .enumDef(let variants) = td.kind, variants[idx].1.isEmpty {
                    // Unit-like variant: produce enum value directly with an
                    // EMPTY payload (no unit stub).
                    let tmp = freshTemp(type: .named(td.name, []))
                    emit(.assign(.local(tmp), .aggregate(.enumCtor(td.name, idx), [])))
                    return .mirCopy(.local(tmp))
                }
                // Variant with fields: return as a constructor function
                return .mirConstant(.fnItem("\(a)::\(b)"))
            }
            return .mirConstant(.fnItem("\(a)::\(b)"))
        case .binary(let left, let op, let right, _):
            let l = lowerExpr(left)
            let r = lowerExpr(right)
            // Comparison/logical operators produce Bool-typed values;
            // arithmetic/bitwise produce Int-typed values — the static
            // type rides on the temp so condition normalization
            // (normalizeCondition) can see bool-typed conditions.
            let tmp = freshTemp(type: binOpResultType(op))
            emit(.assign(.local(tmp), .binaryOp(lowerBinOp(op), l, r)))
            return .mirCopy(.local(tmp))

        case .unary(let op, let inner, _):
            switch op {
            case .neg:
                let val = lowerExpr(inner)
                let tmp = freshTemp(type: operandType(val) ?? .unknown)
                emit(.assign(.local(tmp), .unaryOp(.neg, val)))
                return .mirCopy(.local(tmp))
            case .not:
                let val = lowerExpr(inner)
                let tmp = freshTemp(type: .bool)
                emit(.assign(.local(tmp), .unaryOp(.not, val)))
                return .mirCopy(.local(tmp))
            case .bitNot:
                // `~x` — the bitwise-not rvalue (kernel MirUnOp::BitNot),
                // never a plain copy.
                let val = lowerExpr(inner)
                let tmp = freshTemp(type: operandType(val) ?? .unknown)
                emit(.assign(.local(tmp), .unaryOp(.bitNot, val)))
                return .mirCopy(.local(tmp))
            case .deref:
                // `*x` — the deref READ of the place: the place extended
                // with the ProjDeref projection (the kernel's
                // place_deref — ExprRawDeref is place-like), never the
                // plain copy of the operand.
                if let place = exprToPlace(inner) {
                    let derefPlace = MirPlace(local: place.local,
                                              projections: place.projections + [.projDeref])
                    let derefType = projectedType(operandType(.mirCopy(place)) ?? .unknown,
                                                  by: .projDeref) ?? .unknown
                    let tmp = freshTemp(type: derefType)
                    emit(.assign(.local(tmp), .use(.mirCopy(derefPlace))))
                    return .mirCopy(.local(tmp))
                }
                // Non-place inner: spill the operand, then deref through
                // the spilled local.
                let val = lowerExpr(inner)
                let valLocal = placeOf(val)
                let derefType = projectedType(operandType(val) ?? .unknown,
                                              by: .projDeref) ?? .unknown
                let tmp = freshTemp(type: derefType)
                emit(.assign(.local(tmp), .use(.mirCopy(MirPlace(local: valLocal,
                                                                 projections: [.projDeref])))))
                return .mirCopy(.local(tmp))
            case .borrowMut:
                if let place = exprToPlace(inner) {
                    let borrowedType = operandType(.mirCopy(place)) ?? .unknown
                    let tmp = freshTemp(type: .refInternal(borrowedType, true))
                    emit(.assign(.local(tmp), .mirRefMut(place)))
                    return .mirCopy(.local(tmp))
                } else {
                    let val = lowerExpr(inner)
                    let tmp = freshTemp(type: operandType(val) ?? .unknown)
                    emit(.assign(.local(tmp), .use(val)))
                    return .mirCopy(.local(tmp))
                }
            case .borrow:
                if let place = exprToPlace(inner) {
                    let borrowedType = operandType(.mirCopy(place)) ?? .unknown
                    let tmp = freshTemp(type: .refInternal(borrowedType, false))
                    emit(.assign(.local(tmp), .mirRef(place)))
                    return .mirCopy(.local(tmp))
                } else {
                    let val = lowerExpr(inner)
                    let tmp = freshTemp(type: operandType(val) ?? .unknown)
                    emit(.assign(.local(tmp), .use(val)))
                    return .mirCopy(.local(tmp))
                }
            }
            // The switch is exhaustive over UnaryOp (neg/not/bitNot/deref/
            // borrow/borrowMut) — a new operator becomes a compile error,
            // never a silent copy.

        case .assign(let target, let value, let span):
            let val = lowerExpr(value)
            if case .name(let n, _) = target, let id = lookupScope(n) {
                emit(.assign(.local(id), .use(val)))
            } else if case .name(let n, _) = target, statics.contains(where: { $0.name == n }) {
                // A write to a registered static: the static store — the
                // projStatic place (the kernel's MirStaticAddr-deref place),
                // never the non-scope rejection.
                emit(.assign(MirPlace(local: 0, projections: [.projStatic(n)]), .use(val)))
            } else {
                // Handle field/indexed/nested assignment: base.field = val,
                // base[idx] = val. lowerPlaceExpr inserts the ProjDeref when
                // the base local is a reference type (refInternal params).
                let (local, projs) = lowerPlaceExpr(target)
                if !projs.isEmpty {
                    emit(.assign(MirPlace(local: local, projections: projs), .use(val)))
                } else {
                    // A bare-name target that is NOT a scope local (or a
                    // place that failed to decompose) is an undeclared
                    // assign — the lowering error, never a silent drop
                    // (the audit item 8; the kernel's resolver rejects the
                    // undeclared assign target).
                    let rendered = renderExprBrief(target)
                    recordLoweringError("MIRLowering: assignment to non-scope bare name '\(rendered)' at span \(span.start)..<\(span.end) — the target does not resolve to a local or a field/index place (never silently dropped)")
                }
            }
            return .mirConstant(.unit)

        case .compoundAssign(let target, let op, let value, let span):
            let val = lowerExpr(value)
            let binOp = lowerBinOp(op)
            if case .name(let n, _) = target, let id = lookupScope(n) {
                let tmp = freshTemp()
                emit(.assign(.local(tmp), .binaryOp(binOp, .mirCopy(.local(id)), val)))
                emit(.assign(.local(id), .use(.mirCopy(.local(tmp)))))
            } else if case .name(let n, _) = target, statics.contains(where: { $0.name == n }) {
                // Compound-assign to a static: read the slot through the
                // projStatic place, apply the op, write the slot back.
                let place = MirPlace(local: 0, projections: [.projStatic(n)])
                let tmp = freshTemp()
                emit(.assign(.local(tmp), .binaryOp(binOp, .mirCopy(place), val)))
                emit(.assign(place, .use(.mirCopy(.local(tmp)))))
            } else {
                // The field/index place read-modify-write: base.field += v
                // and base[idx] += v lower to a place read, the binary op,
                // and the place write-back — NEVER silently dropped (the
                // audit item 8).
                let (local, projs) = lowerPlaceExpr(target)
                if !projs.isEmpty {
                    let place = MirPlace(local: local, projections: projs)
                    let tmp = freshTemp()
                    emit(.assign(.local(tmp), .binaryOp(binOp, .mirCopy(place), val)))
                    emit(.assign(place, .use(.mirCopy(.local(tmp)))))
                } else {
                    let rendered = renderExprBrief(target)
                    recordLoweringError("MIRLowering: compound-assign to non-scope bare name '\(rendered)' at span \(span.start)..<\(span.end) — the target does not resolve to a local or a field/index place (never silently dropped)")
                }
            }
            return .mirConstant(.unit)

        case .call(let callee, _, let args, _):
            // Detect method calls: expr.method(args) → .method(expr, args...)
            if case .field(let base, let methodName, _) = callee {
                let receiverPlace = exprToPlace(base)
                let receiverType: MirType? = receiverPlace.flatMap { operandType(.mirCopy($0)) }

                // Determine if the method's self parameter is by-value or by-reference.
                // By default, borrow the receiver (&self/&mut self convention).
                // Only pass by value if the method is explicitly recorded as by-value self.
                let shouldBorrow: Bool
                if let typeName = extractTypeName(receiverType) {
                    let qualifiedName = "\(typeName)::\(methodName)"
                    shouldBorrow = !methodSelfByValue.contains(qualifiedName)
                } else {
                    shouldBorrow = true
                }

                let baseOp: MirOperand
                if shouldBorrow, let place = receiverPlace {
                    let refTmp = freshTemp(type: .refInternal(receiverType ?? .unknown, true))
                    emit(.assign(.local(refTmp), .mirRefMut(place)))
                    baseOp = .mirCopy(.local(refTmp))
                } else {
                    baseOp = lowerExpr(base)
                }

                let resultType = inferMethodCallResultType(receiverType: operandType(baseOp), methodName: methodName)
                let result = freshTemp(type: resultType)
                let nextBB = freshBlock()
                let methodCalleeName: String
                if let typeName = extractTypeName(receiverType) {
                    methodCalleeName = "\(typeName)::\(methodName)"
                } else {
                    methodCalleeName = ".\(methodName)"
                }
                let effects = argEffects(forCallee: methodCalleeName, argCount: args.count + 1)
                var callArgs: [MirCallArg] = [MirCallArg(effect: effects.first ?? .read, value: .value(baseOp))]
                for (i, a) in args.enumerated() {
                    callArgs.append(lowerCallArg(a.value, effectFallback: i + 1 < effects.count ? effects[i + 1] : .read))
                }
                terminateWith(.call(dest: .local(result),
                                    callee: .mirConstant(.fnItem(".\(methodName)")),
                                    args: callArgs,
                                    next: nextBB, unwind: nil))
                currentBlock = nextBB
                return .mirCopy(.local(result))
            }
            if let ctor = resolveVariantConstructor(callee, argCount: args.count) {
                let argOps = args.map { lowerExpr($0.value) }
                let result = freshTemp(type: .named(ctor.typeName, []))
                // Check if this variant has a named payload struct (synthetic struct type).
                // Positional call syntax on a named-field variant (e.g. MirCall(a,b,c,d,e))
                // must be lowered by creating the struct payload first, then wrapping in the enum.
                // Otherwise enumCtor's hasNamedPayloadStruct check picks only vals.first (the
                // first field value) as the payload, discarding the rest.
                if let td = resolveTypeDef(ctor.typeName),
                   case .enumDef(let variants) = td.kind,
                   ctor.variantIdx >= 0, ctor.variantIdx < variants.count {
                    let payloadTypeName = "\(ctor.typeName)::\(variants[ctor.variantIdx].0)"
                    // IMPORTANT: only use the named-payload-struct path when an EXACT
                    // fully-qualified match exists in typeDefByName.  resolveTypeDef has a
                    // bare-name fallback that can mis-resolve "types::Type::Map" to an
                    // unrelated struct named just "Map" (e.g. collections::Map), corrupting
                    // the enum payload arity.  Synthetic payload structs are registered
                    // under their exact qualified name (see syntheticEnumPayloadTypeDef),
                    // so an exact lookup is the only safe check here.
                    if let payloadTD = typeDefByName[payloadTypeName],
                       case .structDef(let fields) = payloadTD.kind {
                        // Named-field variant: create struct payload, then wrap in enum ctor
                        let fieldNames = fields.map { $0.0 }
                        let payloadTmp = freshTemp(type: .named(payloadTD.name, []))
                        emit(.assign(.local(payloadTmp), .aggregate(.structCtor(payloadTD.name, fieldNames), argOps)))
                        emit(.assign(.local(result), .aggregate(.enumCtor(ctor.typeName, ctor.variantIdx), [.mirCopy(.local(payloadTmp))])))
                    } else {
                        // Tuple-like variant: pass args directly
                        emit(.assign(.local(result), .aggregate(.enumCtor(ctor.typeName, ctor.variantIdx), argOps)))
                    }
                } else {
                    emit(.assign(.local(result), .aggregate(.enumCtor(ctor.typeName, ctor.variantIdx), argOps)))
                }
                return .mirCopy(.local(result))
            }
            let calleeOp = lowerExpr(callee)
            let resultType = inferDirectCallResultType(callee, loweredCallee: calleeOp)
            let result = freshTemp(type: resultType)
            let nextBB = freshBlock()
            let directCalleeName: String?
            switch callee {
            case .name(let name, _):
                directCalleeName = name
            case .path(let lhs, let rhs, _):
                directCalleeName = "\(lhs)::\(rhs)"
            default:
                directCalleeName = nil
            }
            let directArgEffects: [AccessEffect]
            if let directCalleeName {
                directArgEffects = argEffects(forCallee: directCalleeName, argCount: args.count)
            } else {
                directArgEffects = Array(repeating: .read, count: args.count)
            }
            let directCallArgs = args.enumerated().map { i, a in
                lowerCallArg(a.value, effectFallback: i < directArgEffects.count ? directArgEffects[i] : .read)
            }
            terminateWith(.call(dest: .local(result), callee: calleeOp, args: directCallArgs,
                                next: nextBB, unwind: nil))
            currentBlock = nextBB
            return .mirCopy(.local(result))

        case .macroCall(let name, let args, _):
            let argOps = args.map {
                switch $0 {
                case .expr(let expr):
                    return lowerExpr(expr)
                case .tokens(let text, _):
                    return .mirConstant(.str(text))
                }
            }
            let result = freshTemp()
            let nextBB = freshBlock()
            let macroCallArgs = argOps.map { MirCallArg(effect: .read, value: .value($0)) }
            terminateWith(.call(dest: .local(result), callee: .mirConstant(.fnItem("__macro_\(name)")),
                                args: macroCallArgs,
                                next: nextBB, unwind: nil))
            currentBlock = nextBB
            return .mirCopy(.local(result))

        case .ifExpr(let ifE):
            return lowerIfExpr(ifE)

        case .matchExpr(let matchE):
            return lowerMatch(matchE)

        case .forExpr(let forE):
            return lowerFor(forE)

        case .whileExpr(let whileE):
            return lowerWhile(whileE)

        case .loopExpr(let body, _):
            return lowerLoop(body)

        case .block(let body, _):
            let tmp = freshTemp()
            pushScope()
            lowerBlock(body, resultInto: tmp)
            popScope()
            return .mirCopy(.local(tmp))

        case .unsafeBlock(_, let body, _):
            let tmp = freshTemp()
            pushScope()
            lowerBlock(body, resultInto: tmp)
            popScope()
            return .mirCopy(.local(tmp))

        case .returnExpr(let val, _):
            if let v = val {
                let op = lowerExpr(v)
                emit(.assign(.local(returnLocal), .use(op)))
            }
            // Route through the function's defer exit cleanup when defers
            // are registered (the chain entry is the last defer registered
            // BEFORE this return — later, unreachable registrations never
            // run on this path).
            terminateWith(exitTerminator())
            // Dead code after return — start a new unreachable block
            currentBlock = freshBlock()
            return .mirConstant(.unit)

        case .breakExpr(let val, _):
            // The break's VALUE expression is lowered (evaluated — its
            // side effects emitted) before the jump; it is never dropped
            // at the AST level. The kernel's MIR has no break-value
            // channel (StmtBreak lowers to the loop-exit goto), so the
            // value's evaluation is the faithful seed boundary.
            if let v = val {
                _ = lowerExpr(v)
            }
            if let target = loopBreakTargets.last {
                terminateWith(.goto(target))
                currentBlock = freshBlock() // unreachable after break
            }
            return .mirConstant(.unit)

        case .nextExpr:
            if let target = loopContinueTargets.last {
                terminateWith(.goto(target))
                currentBlock = freshBlock() // unreachable after next/continue
            }
            return .mirConstant(.unit)

        case .field(let base, let field, _):
            let baseOp = lowerExpr(base)
            let baseLocal = placeOf(baseOp)
            let inferredType = operandType(baseOp).flatMap { self.projectedType($0, by: MirProjection.namedField(field)) } ?? MirType.unknown
            let tmp = freshTemp(type: inferredType)
            emit(.assign(.local(tmp), .use(.mirCopy(MirPlace(local: baseLocal,
                                                            projections: [.namedField(field)])))))
            return .mirCopy(.local(tmp))

        case .index(let base, let idx, _):
            let baseOp = lowerExpr(base)
            let idxOp = lowerExpr(idx)
            let baseLocal = placeOf(baseOp)
            let idxLocal = placeOf(idxOp)
            let inferredType = operandType(baseOp).flatMap { self.projectedType($0, by: MirProjection.index(idxLocal)) } ?? MirType.unknown
            let tmp = freshTemp(type: inferredType)
            emit(.assign(.local(tmp), .use(.mirCopy(MirPlace(local: baseLocal,
                                                            projections: [.index(idxLocal)])))))
            return .mirCopy(.local(tmp))

        case .array(let elems, _):
            let ops = elems.map { lowerExpr($0) }
            let elementType = ops.compactMap(operandType).first ?? .unknown
            let tmp = freshTemp(type: .array(elementType, ops.count))
            emit(.assign(.local(tmp), .aggregate(.array, ops)))
            return .mirCopy(.local(tmp))

        case .tuple(let elems, _):
            let ops = elems.map { lowerExpr($0) }
            let tupleTypes = ops.map { operandType($0) ?? .unknown }
            let tmp = freshTemp(type: .tuple(tupleTypes))
            emit(.assign(.local(tmp), .aggregate(.tuple, ops)))
            return .mirCopy(.local(tmp))

        case .structLit(let name, _, let fields, _, _):
            let fieldNames = fields.map { $0.0 }
            let ops = fields.map { lowerExpr($0.1) }
            // Check if this is an enum variant with struct-like syntax: EnumType::Variant { ... }
            if name.contains("::") {
                let parts = typeNameParts(name)
                if parts.count >= 2 {
                    let enumName = parts.dropLast().joined(separator: "::")
                    let variantName = parts.last!
                    if let (td, idx) = resolveNamedVariant(enumName, variantName: variantName, expectedFieldCount: fieldNames.count) {
                        // Enum variant with named fields: create struct payload + enum ctor
                        let tmp = freshTemp(type: .named(td.name, []))
                        let payloadName = resolveTypeDef("\(td.name)::\(variantName)")?.name ?? name
                        let payloadTmp = freshTemp(type: .named(payloadName, []))
                        emit(.assign(.local(payloadTmp), .aggregate(.structCtor(payloadName, fieldNames), ops)))
                        emit(.assign(.local(tmp), .aggregate(.enumCtor(td.name, idx), [.mirCopy(.local(payloadTmp))])))
                        return .mirCopy(.local(tmp))
                    }
                }
            }
            let tmp = freshTemp(type: .named(name, []))
            emit(.assign(.local(tmp), .aggregate(.structCtor(name, fieldNames), ops)))
            return .mirCopy(.local(tmp))

        case .range(let start, let end, let inclusive, _):
            let s = lowerExpr(start)
            let e = lowerExpr(end)
            let kindName = inclusive ? "RangeInclusive" : "Range"
            let tmp = freshTemp(type: .named(kindName, []))
            emit(.assign(.local(tmp), .aggregate(.structCtor(kindName, ["start", "end"]), [s, e])))
            return .mirCopy(.local(tmp))

        case .closure(let closureE):
            return lowerClosure(closureE)

        case .cast(let inner, let targetType, _):
            let val = lowerExpr(inner)
            let targetMirType = lowerTypeExpr(targetType)
            let tmp = freshTemp(type: targetMirType)
            emit(.assign(.local(tmp), .cast(val, targetMirType)))
            return .mirCopy(.local(tmp))

        case .tryOp(let inner, _):
            // `expr?` — ERASURE (the kernel's ExprTry semantics: the
            // operand's value; never an exceptional construct — the
            // kernel's own compiler uses it).
            return lowerExpr(inner)

        case .unlessExpr(let unlessE):
            // `unless cond { body } else { other }` — the negated
            // condition branches (real semantics: unless == if !cond).
            return lowerUnless(unlessE)

        case .untilExpr(let untilE):
            // `until cond { body }` — the negated-condition loop
            // (real semantics: until == while !cond).
            return lowerUntil(untilE)

        case .tryBlock(let tryB):
            // The kernel REJECTS try/catch/finally blocks at the checker
            // (exceptions are not supported — no throwing path may bypass
            // teardown); the seed's lowering must fail CLOSED with the
            // explicit unsupported error, never silently produce unit.
            recordLoweringError("MIRLowering: exceptions are not supported — try/catch/finally block reached MIR lowering (span \(tryB.span))")
            return .mirConstant(.unit)

        case .handleExpr(let handleE):
            // Effect-handler blocks are outside the seed dialect; the
            // explicit unsupported error, never silent unit.
            recordLoweringError("MIRLowering: effect handlers are not supported — handle/with expression reached MIR lowering (span \(handleE.span))")
            return .mirConstant(.unit)

        case .awaitExpr(let inner, _):
            // The seed dialect has no async runtime; the explicit
            // unsupported error, never silent unit.
            recordLoweringError("MIRLowering: async/await is not supported — await expression reached MIR lowering (span \(inner.span))")
            return .mirConstant(.unit)

        case .comptimeBlock(let body, _):
            // The seed's REAL subset of comptime: the block's statements
            // and value are lowered in program order (the seed has no
            // compile-time evaluator; the kernel rejects comptime blocks
            // at the checker). Never the silent unit for the whole block.
            let tmp = freshTemp()
            pushScope()
            lowerBlock(body, resultInto: tmp)
            popScope()
            return .mirCopy(.local(tmp))

        case .arrayRepeat(let value, let count, _):
            // `[v; N]` — the MirRepeat rvalue (the kernel's
            // MirRepeat(MirOperand, Int): the element is repeated N
            // times), the real repetition — never the unit. The count
            // must be a compile-time constant (fail-closed: an explicit
            // error, never a silently guessed repetition).
            if let n = evalConstSize(count) {
                let valOp = lowerExpr(value)
                let elemType = operandType(valOp) ?? .unknown
                let tmp = freshTemp(type: .array(elemType, n))
                emit(.assign(.local(tmp), .repeat(valOp, n)))
                return .mirCopy(.local(tmp))
            }
            recordLoweringError("MIRLowering: arrayRepeat count is not a compile-time constant (span \(count.span))")
            return .mirConstant(.unit)
        }
        // The switch above is exhaustive over Expr — an unhandled Expr
        // kind becomes a compile error here, never a silent unit.
    }

    // MARK: - Control flow lowering

    /// Normalize a condition operand for switchInt.
    ///
    /// The seed's switchInt condition form is the EXPLICIT compare-to-1:
    /// the terminator jumps to the then-target exactly when the operand
    /// equals the int target 1 and to `otherwise` on every other value
    /// (mirroring the kernel's codegen, which emits `cmp operand, <target>`
    /// per target). Bool-typed operands (bool locals, bool constants and
    /// comparison results) feed the switchInt directly — the interpreter's
    /// int view maps true→1 / false→0. A condition whose lowered operand is
    /// NOT bool/int-shaped (a Unit from a void-valued expression, a string,
    /// etc. — the silent-loss class) is normalized to the explicit
    /// `(cond == 1)` comparison so the branch semantics are never implicit.
    ///
    /// PRINTING NOTE (item 20): a switchInt operand that is a bool
    /// CONSTANT prints as `true`/`false` (printConstant's bool form),
    /// while a comparison-result operand prints as its Int-valued temp
    /// (the interpreter's compare result view: 0/1). Both are valid
    /// switchInt operands in this dialect; the targets are always Int.
    private func normalizeCondition(_ operand: MirOperand) -> MirOperand {
        if let ty = operandType(operand) {
            switch ty {
            case .bool, .int:
                return operand
            default:
                break
            }
        }
        let tmp = freshTemp(type: .bool)
        emit(.assign(.local(tmp), .binaryOp(.eq, operand, .mirConstant(.int(1)))))
        return .mirCopy(.local(tmp))
    }

    private func lowerIfExpr(_ ifE: IfExpr) -> MirOperand {
        let result = freshTemp()
        let thenBB = freshBlock()
        let elseBB = freshBlock()
        let mergeBB = freshBlock()

        // if-let: `if let PATTERN = VALUE` — the pattern TEST is the
        // condition (the parser synthesizes condition = true); the VALUE
        // is evaluated ONCE (spilled to a temp) and the pattern is bound
        // from that same operand inside the then branch (single binding).
        let ifLetBinding: (pattern: Pattern, value: MirOperand, hint: String?)?
        if let pattern = ifE.ifLetPattern, let value = ifE.ifLetValue {
            let valOp = lowerExpr(value)
            let enumHint = inferEnumHint(from: valOp)
            ifLetBinding = (pattern, valOp, enumHint)
        } else {
            ifLetBinding = nil
        }
        let condOp: MirOperand
        if let binding = ifLetBinding {
            condOp = normalizeCondition(lowerPatternTest(binding.pattern, value: binding.value, enumHint: binding.hint))
        } else {
            condOp = normalizeCondition(lowerExpr(ifE.condition))
        }

        terminateWith(.switchInt(condOp, targets: [(1, thenBB)], otherwise: elseBB))

        // Then — the if-let pattern binding lives in this scope (single
        // binding; the pattern names resolve in the branch body).
        currentBlock = thenBB
        pushScope()
        if let binding = ifLetBinding {
            lowerPatternBind(binding.pattern, value: binding.value, enumHint: binding.hint)
        }
        lowerBlock(ifE.thenBlock, resultInto: result)
        popScope()
        terminateIfNeeded(.goto(mergeBB))

        // Elsif chain (each clause may carry its own if-let pattern/value)
        var currentElseBB = elseBB
        for (clauseIndex, clause) in ifE.elsifClauses.enumerated() {
            currentBlock = currentElseBB
            let clauseCondOp: MirOperand
            let clauseBinding: (pattern: Pattern, value: MirOperand, hint: String?)?
            if clauseIndex < ifE.elsifLet.count {
                let (pat, val) = ifE.elsifLet[clauseIndex]
                let valOp = lowerExpr(val)
                let enumHint = inferEnumHint(from: valOp)
                clauseBinding = (pat, valOp, enumHint)
                clauseCondOp = normalizeCondition(lowerPatternTest(pat, value: valOp, enumHint: enumHint))
            } else {
                clauseBinding = nil
                clauseCondOp = normalizeCondition(lowerExpr(clause.condition))
            }
            let clauseThenBB = freshBlock()
            let nextElseBB = freshBlock()
            terminateWith(.switchInt(clauseCondOp, targets: [(1, clauseThenBB)], otherwise: nextElseBB))

            currentBlock = clauseThenBB
            pushScope()
            if let binding = clauseBinding {
                lowerPatternBind(binding.pattern, value: binding.value, enumHint: binding.hint)
            }
            lowerBlock(clause.body, resultInto: result)
            popScope()
            terminateIfNeeded(.goto(mergeBB))

            currentElseBB = nextElseBB
        }

        // Final else
        currentBlock = currentElseBB
        if let elseBlock = ifE.elseBlock {
            pushScope()
            lowerBlock(elseBlock, resultInto: result)
            popScope()
        }
        terminateIfNeeded(.goto(mergeBB))

        currentBlock = mergeBB
        return .mirCopy(.local(result))
    }

    /// `unless cond { body } else { other }` — the negated-condition
    /// branches (unless == if !cond; the condition is negated once and the
    /// switchInt keeps the explicit compare-to-1 form).
    private func lowerUnless(_ unlessE: UnlessExpr) -> MirOperand {
        let result = freshTemp()
        let condOp = lowerExpr(unlessE.condition)
        let negTmp = freshTemp(type: .bool)
        emit(.assign(.local(negTmp), .unaryOp(.not, condOp)))
        let negCond = normalizeCondition(.mirCopy(.local(negTmp)))

        let thenBB = freshBlock()
        let elseBB = freshBlock()
        let mergeBB = freshBlock()
        terminateWith(.switchInt(negCond, targets: [(1, thenBB)], otherwise: elseBB))

        currentBlock = thenBB
        pushScope()
        lowerBlock(unlessE.body, resultInto: result)
        popScope()
        terminateIfNeeded(.goto(mergeBB))

        currentBlock = elseBB
        if let elseBlock = unlessE.elseBlock {
            pushScope()
            lowerBlock(elseBlock, resultInto: result)
            popScope()
        }
        terminateIfNeeded(.goto(mergeBB))

        currentBlock = mergeBB
        return .mirCopy(.local(result))
    }

    /// `until cond { body }` — the negated-condition loop
    /// (until == while !cond; the body runs while the condition is false).
    private func lowerUntil(_ untilE: UntilExpr) -> MirOperand {
        let condBB = freshBlock()
        let bodyBB = freshBlock()
        let exitBB = freshBlock()

        terminateWith(.goto(condBB))

        currentBlock = condBB
        let condOp = lowerExpr(untilE.condition)
        let negTmp = freshTemp(type: .bool)
        emit(.assign(.local(negTmp), .unaryOp(.not, condOp)))
        let negCond = normalizeCondition(.mirCopy(.local(negTmp)))
        terminateWith(.switchInt(negCond, targets: [(1, bodyBB)], otherwise: exitBB))

        currentBlock = bodyBB
        loopBreakTargets.append(exitBB)
        loopContinueTargets.append(condBB)
        pushScope()
        let tmp = freshTemp()
        lowerBlock(untilE.body, resultInto: tmp)
        popScope()
        loopBreakTargets.removeLast()
        loopContinueTargets.removeLast()
        terminateIfNeeded(.goto(condBB))

        currentBlock = exitBB
        return .mirConstant(.unit)
    }

    private func lowerMatch(_ matchE: MatchExpr) -> MirOperand {
        let result = freshTemp()
        let subject = lowerExpr(matchE.subject)
        let mergeBB = freshBlock()

        // Extract enum type hint from qualified variant patterns in any arm
        let patternEnumHint = extractEnumHintFromPatterns(matchE.arms.map { $0.pattern })
        let enumHint = patternEnumHint ?? inferEnumHint(from: subject)

        // For simplicity: chain of if-else blocks for each arm
        var nextCandidateBB = currentBlock
        for arm in matchE.arms {
            currentBlock = nextCandidateBB
            let armBB = freshBlock()
            let nextArmBB = freshBlock()

            // Test pattern (with enum type hint for disambiguation)
            let matches = normalizeCondition(lowerPatternTest(arm.pattern, value: subject, enumHint: enumHint))

            // If match succeeded and there's a guard, also test the guard.
            // The pattern is bound ONCE: the guard scope and the arm scope
            // are MERGED — the bindings made for the guard stay visible to
            // the arm body (no second binding, no double-defined names).
            if let guardExpr = arm.guardExpr {
                let guardBB = freshBlock()
                terminateWith(.switchInt(matches, targets: [(1, guardBB)], otherwise: nextArmBB))
                currentBlock = guardBB
                pushScope()
                lowerPatternBind(arm.pattern, value: subject, enumHint: enumHint)
                let guardVal = normalizeCondition(lowerExpr(guardExpr))
                // NOTE: the scope stays open through the arm (the guard
                // scope + the arm scope are one); it is popped after the
                // arm body, before the next arm's candidate block is
                // lowered, so no binding leaks across arms.
                terminateWith(.switchInt(guardVal, targets: [(1, armBB)], otherwise: nextArmBB))
            } else {
                terminateWith(.switchInt(matches, targets: [(1, armBB)], otherwise: nextArmBB))
            }

            currentBlock = armBB
            if arm.guardExpr == nil {
                pushScope()
                lowerPatternBind(arm.pattern, value: subject, enumHint: enumHint)
            }
            let bodyVal = lowerExpr(arm.body)
            emit(.assign(.local(result), .use(bodyVal)))
            popScope()
            terminateIfNeeded(.goto(mergeBB))

            nextCandidateBB = nextArmBB
        }
        // Default: fall to merge
        currentBlock = nextCandidateBB
        terminateIfNeeded(.goto(mergeBB))

        currentBlock = mergeBB
        return .mirCopy(.local(result))
    }

    /// Extract the literal expression from a literal pattern (for range bounds).
    private func patternToExpr(_ pattern: Pattern) -> Expr {
        switch pattern {
        case .literal(let expr, _):
            return expr
        default:
            return .intLit("0", pattern.span)
        }
    }

    // MARK: - Variant name canonicalization
    //
    // The kernel's ast.tg is the authority for variant names: ExprKind's
    // operator/member-access variants are spelled ExprUnaryOp / ExprBinaryOp
    // / ExprFieldAccess. Kernel sources that still spell the legacy names
    // (types.tg's wcet_cost_expr) resolve through this table — the payload
    // shapes are identical, so a legacy spelling lowers to the same variant
    // index as its current name. The canonicalized name is what every
    // variant resolution path (cache lookup + linear scan) sees, so the
    // seed's MIR lowering of the kernel closure aligns exactly with the
    // kernel's current AST names.
    private static let renamedVariantAliases: [String: String] = [
        "ExprUnary": "ExprUnaryOp",
        "ExprBinary": "ExprBinaryOp",
        "ExprField": "ExprFieldAccess",
    ]

    private func canonicalVariantName(_ name: String) -> String {
        Self.renamedVariantAliases[name] ?? name
    }

    /// Resolve a variant name in an enum definition. The matching is the
    /// EXACT-NAME matching (the audit item 16): the kernel's variant
    /// identity is the exact per-module name (resolver.tg's
    /// `variant_indices.get(name)`), so `Function` must NOT match
    /// `ItemFunction` — the field-count filter alone is unsafe (a suffix
    /// match filtered by arity still resolves the wrong variant). The only
    /// fallback is the curated renamed-variant alias table
    /// (canonicalVariantName — exact after canonicalization), which covers
    /// the kernel's renamed AST spellings without a raw suffix scan.
    private func resolveVariantIndex(_ shortName: String, in variants: [(String, [MirType])]) -> Int? {
        let shortName = canonicalVariantName(shortName)
        // Exact match only: "Function" resolves "Function" — never
        // "ItemFunction", "ExprFunction", or any other prefix-variant.
        return variants.firstIndex(where: { $0.0 == shortName })
    }

    /// Resolve a possibly module-qualified type name (e.g. "app::Event") against typeDefs.
    private func resolveTypeDef(_ typeName: String) -> MirTypeDef? {
        // Generic-instantiation-carrying names (any pre-rendered
        // "Name<Args>" form) resolve by their BASE Adt name: the
        // instantiation rides in MirType.named's args, never in the
        // registered-def identity.
        let typeName = bareTypeName(typeName)
        // Fast path: cache lookup (O(1))
        if let td = typeDefByName[typeName] { return td }

        let requestedParts = typeNameParts(typeName)
        let bareName = requestedParts.last ?? typeName

        // Try bare name in cache
        if bareName != typeName, let td = typeDefByName[bareName] { return td }

        // Try module-qualified candidates in cache
        for candidate in moduleQualifiedTypeNames(for: bareName) {
            if let td = typeDefByName[candidate] {
                return td
            }
        }

        // Slow path: linear scan with type name matching (only if cache misses)
        var matches = typeDefs.filter { typeNameMatches(typeName, actual: $0.name) }
        if matches.isEmpty {
            matches = typeDefs.filter {
                typeNameParts($0.name).last == bareName
            }
        }

        var uniqueByKey: [String: MirTypeDef] = [:]
        for td in matches {
            uniqueByKey[typeDefResolutionKey(td)] = td
        }
        let dedupedMatches = Array(uniqueByKey.values)
        return dedupedMatches.count == 1 ? dedupedMatches[0] : nil
    }

    private func resolveEnumTypeDef(_ typeName: String) -> MirTypeDef? {
        resolveTypeDef(typeName)
    }

    private func inferEnumHint(from subject: MirOperand) -> String? {
        guard let subjectType = operandType(subject) else {
            return nil
        }
        return enumHint(from: subjectType)
    }

    private func enumHint(from type: MirType) -> String? {
        switch type {
        case .named(let name, _):
            guard let td = resolveTypeDef(name), case .enumDef = td.kind else {
                return nil
            }
            return td.name
        case .refInternal(let inner, _):
            return enumHint(from: inner)
        case .rawPtr(let inner):
            return enumHint(from: inner)
        default:
            return nil
        }
    }

    /// Extract the base type name from a MIR type, unwrapping refs/ptrs.
    private func extractTypeName(_ type: MirType?) -> String? {
        guard let ty = type else { return nil }
        switch ty {
        case .named(let name, _):
            // The generic instantiation args are carried separately
            // (MirType.named's args — the kernel's Type::Adt(TypeId, args)
            // shape); a defensive "<" strip handles any pre-rendered name.
            if let idx = name.firstIndex(of: "<") {
                return String(name[name.startIndex..<idx])
            }
            return name
        case .refInternal(let inner, _):
            return extractTypeName(inner)
        case .rawPtr(let inner):
            return extractTypeName(inner)
        case .string:
            return "String"
        case .array(_, _):
            return "Vec"
        case .slice(_):
            return "Vec"
        default:
            return nil
        }
    }

    private func operandType(_ operand: MirOperand) -> MirType? {
        switch operand {
        case .mirCopy(let place), .mirMovePlace(let place), .mirRead(let place), .mirConsume(let place):
            // A projStatic-rooted place types as its static's declared
            // type (the root local is unused).
            if case .projStatic(let staticName) = place.projections.first {
                return statics.first(where: { $0.name == staticName })?.type
            }
            guard place.local < locals.count else {
                return nil
            }
            var currentType = locals[place.local].type
            for projection in place.projections {
                guard let projected = projectedType(currentType, by: projection) else {
                    return nil
                }
                currentType = projected
            }
            return currentType
        case .mirConstant(let constant):
            switch constant {
            case .unit, .zeroSized:
                return .unit
            case .bool:
                return .bool
            case .int:
                return .int
            case .float:
                return .float
            case .char:
                return .char
            case .str:
                return .string
            case .fnItem:
                return nil
            case .staticRef(let staticName):
                return statics.first(where: { $0.name == staticName })?.type
            }
        }
    }

    private func projectedType(_ baseType: MirType, by projection: MirProjection) -> MirType? {
        switch projection {
        case .projDeref:
            switch baseType {
            case .refInternal(let inner, _):
                return inner
            case .rawPtr(let inner):
                return inner
            default:
                return nil
            }
        case .field(let index), .constantIndex(let index):
            switch unwrapReferenceTypes(baseType) {
            case .tuple(let elems):
                return index < elems.count ? elems[index] : nil
            case .array(let inner, _), .slice(let inner):
                return inner
            case .named(let name, _):
                guard let td = resolveTypeDef(name) else {
                    return nil
                }
                switch td.kind {
                case .structDef(let fields):
                    return index < fields.count ? fields[index].1 : nil
                case .enumDef:
                    return nil
                }
            default:
                return nil
            }
        case .namedField(let fieldName):
            switch unwrapReferenceTypes(baseType) {
            case .tuple(let elems):
                guard let index = Int(fieldName), index >= 0, index < elems.count else {
                    return nil
                }
                return elems[index]
            case .named(let name, _):
                guard let td = resolveTypeDef(name), case .structDef(let fields) = td.kind else {
                    return nil
                }
                return fields.first(where: { $0.0 == fieldName })?.1
            default:
                return nil
            }
        case .index:
            switch unwrapReferenceTypes(baseType) {
            case .array(let inner, _), .slice(let inner):
                return inner
            case .string:
                return .string
            default:
                return nil
            }
        case .downcast(let variantIndex):
            guard case .named(let name, _) = unwrapReferenceTypes(baseType),
                  let td = resolveTypeDef(name),
                  case .enumDef(let variants) = td.kind,
                  variantIndex < variants.count else {
                return nil
            }
            let payloadTypeName = "\(td.name)::\(variants[variantIndex].0)"
            if let payloadTd = resolveTypeDef(payloadTypeName), case .structDef = payloadTd.kind {
                return .named(payloadTd.name, [])
            }
            let fields = variants[variantIndex].1
            return .tuple(fields)
        case .projStatic(let staticName):
            // The static-address place types as the static's declared type.
            return statics.first(where: { $0.name == staticName })?.type
        }
    }

    private func unwrapReferenceTypes(_ type: MirType) -> MirType {
        switch type {
        case .refInternal(let inner, _):
            return unwrapReferenceTypes(inner)
        case .rawPtr(let inner):
            return unwrapReferenceTypes(inner)
        default:
            return type
        }
    }

    /// Resolve an unqualified variant name (e.g. "Some", "Ok") by searching ALL enum type defs.
    /// Returns the (typeDef, variantIndex) if found.
    private func resolveVariantAcrossAllEnums(_ variantName: String, hintEnumType: String? = nil,
                                              expectedFieldCount: Int? = nil,
                                              allowExtraFields: Bool = false) -> (MirTypeDef, Int)? {
        let variantName = canonicalVariantName(variantName)
        // If we have a hint (from a qualified arm in the same match), prefer that enum
        if let hint = hintEnumType, !hint.isEmpty {
            if let match = resolveNamedVariant(hint, variantName: variantName,
                                               expectedFieldCount: expectedFieldCount,
                                               allowExtraFields: allowExtraFields) {
                return match
            }
        }
        // Fast path: check unqualified variant cache
        if let cached = variantCache[variantName] {
            if let expectedFieldCount {
                let actualFields = variantFieldCount(cached)
                if allowExtraFields ? actualFields >= expectedFieldCount : actualFields == expectedFieldCount {
                    return cached
                }
            } else {
                return cached
            }
        }
        // Fallback: only succeed if the variant resolves uniquely across all enums.
        var matchesByKey: [String: (MirTypeDef, Int)] = [:]
        for td in typeDefs {
            if case .enumDef(let variants) = td.kind {
                if let idx = resolveVariantIndex(variantName, in: variants) {
                    matchesByKey[typeDefResolutionKey(td)] = (td, idx)
                }
            }
        }
        let matches = filterVariantMatches(Array(matchesByKey.values), expectedFieldCount: expectedFieldCount,
                                           allowExtraFields: allowExtraFields)
        return matches.count == 1 ? matches[0] : nil
    }

    private func typeNameMatches(_ requested: String, actual: String) -> Bool {
        if requested == actual {
            return true
        }

        let requestedParts = typeNameParts(requested)
        let actualParts = typeNameParts(actual)
        guard !requestedParts.isEmpty, requestedParts.count <= actualParts.count else {
            return false
        }
        return Array(actualParts.suffix(requestedParts.count)) == requestedParts
    }

    private func typeDefResolutionKey(_ td: MirTypeDef) -> String {
        switch td.kind {
        case .structDef(let fields):
            let renderedFields = fields.map { name, ty in
                "\(name):\(String(describing: ty))"
            }.joined(separator: ",")
            return "struct|\(td.name)|\(renderedFields)"
        case .enumDef(let variants):
            let renderedVariants = variants.map { name, fields in
                let renderedFields = fields.map { String(describing: $0) }.joined(separator: ",")
                return "\(name)(\(renderedFields))"
            }.joined(separator: ";")
            return "enum|\(td.name)|\(renderedVariants)"
        }
    }

    private func variantFieldCount(_ match: (MirTypeDef, Int)) -> Int {
        guard case .enumDef(let variants) = match.0.kind else {
            return 0
        }
        return variants[match.1].1.count
    }

    private func filterVariantMatches(_ matches: [(MirTypeDef, Int)], expectedFieldCount: Int?,
                                      allowExtraFields: Bool) -> [(MirTypeDef, Int)] {
        guard let expectedFieldCount else {
            return matches
        }

        return matches.filter { match in
            let actualFieldCount = variantFieldCount(match)
            if allowExtraFields {
                return actualFieldCount >= expectedFieldCount
            }
            return actualFieldCount == expectedFieldCount
        }
    }

    private func resolveNamedVariant(_ typeName: String, variantName: String,
                                     expectedFieldCount: Int? = nil,
                                     allowExtraFields: Bool = false) -> (MirTypeDef, Int)? {
        let variantName = canonicalVariantName(variantName)
        // Fast path: cache lookup (O(1))
        let cacheKey = "\(typeName)::\(variantName)"
        if let cached = variantCache[cacheKey] {
            if let expectedFieldCount {
                let actualFields = variantFieldCount(cached)
                if allowExtraFields ? actualFields >= expectedFieldCount : actualFields == expectedFieldCount {
                    return cached
                }
            } else {
                return cached
            }
        }
        // Also try bare type name in cache
        let bareName = typeNameParts(typeName).last ?? typeName
        let bareKey = "\(bareName)::\(variantName)"
        if bareKey != cacheKey, let cached = variantCache[bareKey] {
            if let expectedFieldCount {
                let actualFields = variantFieldCount(cached)
                if allowExtraFields ? actualFields >= expectedFieldCount : actualFields == expectedFieldCount {
                    return cached
                }
            } else {
                return cached
            }
        }

        // Slow path: linear scan (only if cache misses)
        var matchesByKey: [String: (MirTypeDef, Int)] = [:]
        for td in typeDefs {
            guard typeNameMatches(typeName, actual: td.name),
                  case .enumDef(let variants) = td.kind,
                  let idx = resolveVariantIndex(variantName, in: variants) else {
                continue
            }
            matchesByKey[typeDefResolutionKey(td)] = (td, idx)
        }
        let matches = filterVariantMatches(Array(matchesByKey.values), expectedFieldCount: expectedFieldCount,
                                           allowExtraFields: allowExtraFields)

        for candidate in moduleQualifiedTypeNames(for: bareName) {
            if let match = matches.first(where: { $0.0.name == candidate }) {
                return match
            }
        }

        if matches.count > 1 {
            let distinctIndexes = Set(matches.map { $0.1 })
            if distinctIndexes.count == 1 {
                return matches[0]
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveVariantConstructor(_ expr: Expr, argCount: Int) -> (typeName: String, variantIdx: Int)? {
        switch expr {
        case .name(let name, _):
            guard name.contains("::") else { return nil }
            let parts = typeNameParts(name)
            guard parts.count >= 2 else { return nil }
            let enumName = parts.dropLast().joined(separator: "::")
            let variantName = parts.last!
            guard let match = resolveNamedVariant(enumName, variantName: variantName, expectedFieldCount: argCount) else {
                return nil
            }
            return (match.0.name, match.1)
        case .path(let typeName, let variantName, _):
            guard let match = resolveNamedVariant(typeName, variantName: variantName, expectedFieldCount: argCount) else {
                return nil
            }
            return (match.0.name, match.1)
        default:
            return nil
        }
    }

    /// Extract enum type hint from a list of patterns (scan for any qualified variant)
    private func extractEnumHintFromPatterns(_ patterns: [Pattern]) -> String? {
        for pat in patterns {
            if case .variant(let typeName, _, _, _) = pat, !typeName.isEmpty {
                return typeName
            }
        }
        return nil
    }

    private func recordLoweringError(_ message: String) {
        if !errors.contains(message) {
            errors.append(message)
        }
    }

    /// A brief single-line rendering of an expression for error messages
    /// (the assign/compound-assign target diagnostics).
    private func renderExprBrief(_ expr: Expr) -> String {
        switch expr {
        case .name(let n, _):
            return n
        case .path(let a, let b, _):
            return "\(a)::\(b)"
        case .field(let base, let f, _):
            return "\(renderExprBrief(base)).\(f)"
        case .index(let base, _, _):
            return "\(renderExprBrief(base))[...]"
        default:
            return "<expr>"
        }
    }

    private func unresolvedVariantFailure(typeName: String, variantName: String, enumHint: String?, context: String) -> String {
        let renderedType = typeName.isEmpty ? "<unqualified>" : typeName
        let hintText = enumHint.map { " (hint: \($0))" } ?? ""
        return "MIRLowering \(context): unresolved or ambiguous enum variant \(renderedType)::\(variantName)\(hintText)"
    }

    private func requireVariantMatch(typeName: String, variantName: String, enumHint: String?,
                                     expectedFieldCount: Int? = nil, allowExtraFields: Bool = false,
                                     context: String) -> (MirTypeDef, Int)? {
        if !typeName.isEmpty {
            guard let match = resolveNamedVariant(typeName, variantName: variantName,
                                                  expectedFieldCount: expectedFieldCount,
                                                  allowExtraFields: allowExtraFields) else {
                recordLoweringError(unresolvedVariantFailure(typeName: typeName, variantName: variantName,
                                                             enumHint: enumHint, context: context))
                return nil
            }
            return match
        }

        if let match = resolveVariantAcrossAllEnums(variantName, hintEnumType: enumHint,
                                                    expectedFieldCount: expectedFieldCount,
                                                    allowExtraFields: allowExtraFields) {
            return match
        }
        recordLoweringError(unresolvedVariantFailure(typeName: typeName, variantName: variantName,
                                                     enumHint: enumHint, context: context))
        return nil
    }

    private func requireVariantIndex(typeName: String, variantName: String, enumHint: String?,
                                     expectedFieldCount: Int? = nil, allowExtraFields: Bool = false,
                                     context: String) -> Int? {
        requireVariantMatch(typeName: typeName, variantName: variantName, enumHint: enumHint,
                            expectedFieldCount: expectedFieldCount, allowExtraFields: allowExtraFields,
                            context: context)?.1
    }

    private func lowerPatternTest(_ pattern: Pattern, value: MirOperand, enumHint: String? = nil) -> MirOperand {
        switch pattern {
        case .wildcard, .ident, .refPattern, .refMutPattern:
            return .mirConstant(.bool(true))
        case .literal(let expr, _):
            let tmp = freshTemp(type: .bool)
            let litVal = lowerExpr(expr)
            emit(.assign(.local(tmp), .binaryOp(.eq, value, litVal)))
            return .mirCopy(.local(tmp))
        case .variant(let typeName, let variantName, let subPats, let span):
            if typeName.isEmpty,
               subPats.isEmpty,
               looksLikeConstFunctionPattern(variantName),
               resolveVariantAcrossAllEnums(variantName, hintEnumType: enumHint, expectedFieldCount: 0) == nil {
                let tmp = freshTemp(type: .bool)
                let constValue = lowerExpr(.call(callee: .name(variantName, span), typeArgs: [], args: [], span))
                emit(.assign(.local(tmp), .binaryOp(.eq, value, constValue)))
                return .mirCopy(.local(tmp))
            }
            guard let variantMatch = requireVariantMatch(typeName: typeName, variantName: variantName,
                                                         enumHint: enumHint, expectedFieldCount: subPats.count,
                                                         allowExtraFields: true, context: "pattern test") else {
                return .mirConstant(.bool(false))
            }
            let idx = variantMatch.1
            let discTmp = freshTemp()
            emit(.assign(.local(discTmp), .discriminant(MirPlace(local: placeOf(value), projections: []))))
            let cmpTmp = freshTemp(type: .bool)
            emit(.assign(.local(cmpTmp), .binaryOp(.eq, .mirCopy(.local(discTmp)), .mirConstant(.int(idx)))))
            // Also check sub-patterns (e.g. literal payloads like Some('#'))
            if subPats.isEmpty {
                return .mirCopy(.local(cmpTmp))
            }
            let resultTmp = freshTemp(type: .bool)
            emit(.assign(.local(resultTmp), .use(.mirConstant(.bool(false)))))

            let payloadBB = freshBlock()
            let doneBB = freshBlock()
            terminateWith(.switchInt(.mirCopy(.local(cmpTmp)), targets: [(1, payloadBB)], otherwise: doneBB))

            currentBlock = payloadBB
            let inner = freshTemp()
            emit(.assign(.local(inner), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.downcast(idx)])))))
            var subResult: MirOperand = .mirConstant(.bool(true))
            if subPats.count == 1 {
                subResult = lowerPatternTest(subPats[0], value: .mirCopy(.local(inner)))
            } else {
                for (i, pat) in subPats.enumerated() {
                    let elem = freshTemp()
                    emit(.assign(.local(elem), .use(.mirCopy(MirPlace(local: inner, projections: [.field(i)])))))
                    let subTest = lowerPatternTest(pat, value: .mirCopy(.local(elem)))
                    let andTmp = freshTemp(type: .bool)
                    emit(.assign(.local(andTmp), .binaryOp(.and, subResult, subTest)))
                    subResult = .mirCopy(.local(andTmp))
                }
            }
            emit(.assign(.local(resultTmp), .use(subResult)))
            terminateWith(.goto(doneBB))

            currentBlock = doneBB
            return .mirCopy(.local(resultTmp))
        case .structPattern(let name, let sFields, _):
            // Struct-like enum variant: EnumType::Variant { field: pat, ... }
            if name.contains("::") {
                let parts = name.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let enumName = parts.dropLast().joined(separator: "::")
                    let variantName = parts.last!
                    guard let idx = requireVariantIndex(typeName: enumName, variantName: variantName,
                                                        enumHint: nil, expectedFieldCount: sFields.count,
                                                        allowExtraFields: true,
                                                        context: "struct pattern test") else {
                        return .mirConstant(.bool(false))
                    }
                    let discTmp = freshTemp()
                    emit(.assign(.local(discTmp), .discriminant(MirPlace(local: placeOf(value), projections: []))))
                    let cmpTmp = freshTemp(type: .bool)
                    emit(.assign(.local(cmpTmp), .binaryOp(.eq, .mirCopy(.local(discTmp)), .mirConstant(.int(idx)))))
                    return .mirCopy(.local(cmpTmp))
                }
            }
            return .mirConstant(.bool(true))
        case .tuple(let pats, _):
            // All sub-patterns must match
            var allMatch: MirOperand = .mirConstant(.bool(true))
            for (i, pat) in pats.enumerated() {
                let elem = freshTemp()
                emit(.assign(.local(elem), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.field(i)])))))
                let sub = lowerPatternTest(pat, value: .mirCopy(.local(elem)))
                let andTmp = freshTemp(type: .bool)
                emit(.assign(.local(andTmp), .binaryOp(.and, allMatch, sub)))
                allMatch = .mirCopy(.local(andTmp))
            }
            return allMatch
        case .orPattern(let lhs, let rhs, _):
            let l = lowerPatternTest(lhs, value: value)
            let r = lowerPatternTest(rhs, value: value)
            let tmp = freshTemp(type: .bool)
            emit(.assign(.local(tmp), .binaryOp(.or, l, r)))
            return .mirCopy(.local(tmp))
        case .rangePattern(let lo, let hi, _):
            // Compute: value >= lo_lit && value <= hi_lit
            let loLit = lowerExpr(patternToExpr(lo))
            let hiLit = lowerExpr(patternToExpr(hi))
            let geTmp = freshTemp(type: .bool)
            emit(.assign(.local(geTmp), .binaryOp(.ge, value, loLit)))
            let leTmp = freshTemp(type: .bool)
            emit(.assign(.local(leTmp), .binaryOp(.le, value, hiLit)))
            let andTmp = freshTemp(type: .bool)
            emit(.assign(.local(andTmp), .binaryOp(.and, .mirCopy(.local(geTmp)), .mirCopy(.local(leTmp)))))
            return .mirCopy(.local(andTmp))
        }
    }

    private func lowerPatternBind(_ pattern: Pattern, value: MirOperand, enumHint: String? = nil) {
        switch pattern {
        case .ident(let name, let mutable, _):
            let bindType = operandType(value) ?? .unknown
            let id = freshLocal(name: name, type: bindType, mutable: mutable)
            defineInScope(name, id)
            emit(.assign(.local(id), .use(value)))
        case .refPattern(let name, _):
            let bindType = operandType(value) ?? .unknown
            let id = freshLocal(name: name, type: bindType, mutable: false)
            defineInScope(name, id)
            emit(.assign(.local(id), .mirRef(MirPlace(local: placeOf(value), projections: []))))
        case .refMutPattern(let name, _):
            let bindType = operandType(value) ?? .unknown
            let id = freshLocal(name: name, type: bindType, mutable: true)
            defineInScope(name, id)
            emit(.assign(.local(id), .mirRefMut(MirPlace(local: placeOf(value), projections: []))))
        case .variant(let typeName, let variantName, let fields, _):
            // Bind payload: downcast to get inner value, then bind field patterns
            if !fields.isEmpty {
                guard let variantMatch = requireVariantMatch(typeName: typeName, variantName: variantName,
                                                             enumHint: enumHint, expectedFieldCount: fields.count,
                                                             allowExtraFields: true, context: "pattern bind") else {
                    return
                }
                let variantIdx = variantMatch.1
                let inner = freshTemp()
                emit(.assign(.local(inner), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.downcast(variantIdx)])))))
                if fields.count == 1 {
                    lowerPatternBind(fields[0], value: .mirCopy(.local(inner)), enumHint: enumHint)
                } else {
                    for (i, pat) in fields.enumerated() {
                        let elem = freshTemp()
                        emit(.assign(.local(elem), .use(.mirCopy(MirPlace(local: inner, projections: [.field(i)])))))
                        lowerPatternBind(pat, value: .mirCopy(.local(elem)), enumHint: enumHint)
                    }
                }
            }
        case .tuple(let pats, _):
            for (i, pat) in pats.enumerated() {
                let tmp = freshTemp()
                emit(.assign(.local(tmp), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.field(i)])))))
                lowerPatternBind(pat, value: .mirCopy(.local(tmp)))
            }
        case .structPattern(let name, let sFields, _):
            // Struct-like pattern: either plain struct or enum variant with struct syntax
            var baseLocal = placeOf(value)
            if name.contains("::") {
                let parts = name.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let enumName = parts.dropLast().joined(separator: "::")
                    let variantName = parts.last!
                    guard let variantIdx = requireVariantIndex(typeName: enumName, variantName: variantName,
                                                               enumHint: nil, expectedFieldCount: sFields.count,
                                                               allowExtraFields: true,
                                                               context: "struct pattern bind") else {
                        return
                    }
                    // Downcast to get the variant payload struct
                    let inner = freshTemp()
                    emit(.assign(.local(inner), .use(.mirCopy(MirPlace(local: placeOf(value), projections: [.downcast(variantIdx)])))))
                    baseLocal = inner
                }
            }
            // Bind each named field
            for (fieldName, subPat) in sFields {
                let fieldTmp = freshTemp()
                emit(.assign(.local(fieldTmp), .use(.mirCopy(MirPlace(local: baseLocal, projections: [.namedField(fieldName)])))))
                let pat = subPat ?? .ident(fieldName, mutable: false, Span.synthetic)
                lowerPatternBind(pat, value: .mirCopy(.local(fieldTmp)))
            }
        default:
            break
        }
    }

    private func tryLowerForProjected(_ forE: ForExpr) -> MirOperand? {
        guard case .ident(let varName, let patMut, _) = forE.pattern, varName != "_" else { return nil }
        guard let iterType = iterablePlaceType(forE.iterable) else { return nil }
        guard let elemTy = projectedCollectionElementType(iterType) else { return nil }
        guard forBodyIsReadOnly(varName: varName, body: forE.body) else { return nil }
        if indexMentionsLoopVar(varName: varName, expr: forE.iterable) {
            return nil
        }
        lowerProjectedFor(forE, varName: varName, patMut: patMut, iterType: iterType, elemTy: elemTy)
        return .mirConstant(.unit)
    }

    private func indexMentionsLoopVar(varName: String, expr: Expr) -> Bool {
        switch expr {
        case .index(let base, let idx, _):
            if !exprIsReadOnly(varName: varName, expr: idx) { return true }
            return indexMentionsLoopVar(varName: varName, expr: base)
        case .field(let base, _, _):
            return indexMentionsLoopVar(varName: varName, expr: base)
        default:
            return false
        }
    }

    private func iterablePlaceType(_ expr: Expr) -> MirType? {
        switch expr {
        case .name(let n, _):
            if n == "self" { return nil }
            guard let id = lookupScope(n) else { return nil }
            return locals[id].type
        case .field(let base, let field, _):
            guard let baseType = iterablePlaceType(base) else { return nil }
            return projectedType(baseType, by: .namedField(field))
        case .index(let base, _, _):
            guard let baseType = iterablePlaceType(base) else { return nil }
            return projectedType(baseType, by: .index(0))
        default:
            return nil
        }
    }

    private func projectedCollectionElementType(_ type: MirType) -> MirType? {
        switch type {
        case .slice(let inner), .array(let inner, _):
            return inner
        case .refInternal(let inner, _), .rawPtr(let inner):
            return projectedCollectionElementType(inner)
        case .named(let name, _):
            let bare = bareTypeName(name)
            if bare == "Vec" || bare == "Array" {
                return .unknown
            }
            return nil
        default:
            return nil
        }
    }

    private func bareTypeName(_ name: String) -> String {
        for separator in ["<", "[", "("] {
            if let idx = name.firstIndex(of: Character(separator)) {
                return String(name[name.startIndex..<idx])
            }
        }
        return name
    }

    private func forBodyIsReadOnly(varName: String, body: BlockBody) -> Bool {
        for stmt in body.stmts {
            if !stmtIsReadOnly(varName: varName, stmt: stmt) {
                return false
            }
        }
        if let tail = body.tailExpr, !exprIsReadOnly(varName: varName, expr: tail) {
            return false
        }
        return true
    }

    private func blockIsReadOnly(varName: String, body: BlockBody) -> Bool {
        for stmt in body.stmts {
            if !stmtIsReadOnly(varName: varName, stmt: stmt) {
                return false
            }
        }
        if let tail = body.tailExpr, !exprIsReadOnly(varName: varName, expr: tail) {
            return false
        }
        return true
    }

    private func stmtIsReadOnly(varName: String, stmt: Stmt) -> Bool {
        switch stmt {
        case .letBinding(_, _, _, let value, _):
            return exprIsReadOnly(varName: varName, expr: value)
        case .exprStmt(let expr, _):
            return exprIsReadOnly(varName: varName, expr: expr)
        case .attributeStmt:
            return true
        case .attributed(_, let inner, _):
            return stmtIsReadOnly(varName: varName, stmt: inner)
        case .deferStmt(let body, _):
            return blockIsReadOnly(varName: varName, body: body)
        case .item:
            return false
        }
    }

    private func exprsAreReadOnly(varName: String, exprs: [Expr]) -> Bool {
        for expr in exprs {
            if !exprIsReadOnly(varName: varName, expr: expr) {
                return false
            }
        }
        return true
    }

    private func exprRootIs(_ varName: String, expr: Expr) -> Bool {
        switch expr {
        case .name(let n, _):
            return n == varName
        case .field(let base, _, _):
            return exprRootIs(varName, expr: base)
        case .index(let base, _, _):
            return exprRootIs(varName, expr: base)
        default:
            return false
        }
    }

    private func exprIsReadOnly(varName: String, expr: Expr) -> Bool {
        switch expr {
        case .intLit, .floatLit, .stringLit, .charLit, .boolLit, .path:
            return true
        case .name(let n, _):
            return n != varName
        case .array(let elems, _), .tuple(let elems, _):
            return exprsAreReadOnly(varName: varName, exprs: elems)
        case .arrayRepeat(let value, let count, _):
            return exprIsReadOnly(varName: varName, expr: value)
                && exprIsReadOnly(varName: varName, expr: count)
        case .structLit(_, _, let fields, let rest, _):
            for field in fields {
                if !exprIsReadOnly(varName: varName, expr: field.1) {
                    return false
                }
            }
            if let rest, !exprIsReadOnly(varName: varName, expr: rest) {
                return false
            }
            return true
        case .block(let body, _), .unsafeBlock(_, let body, _):
            return blockIsReadOnly(varName: varName, body: body)
        case .ifExpr(let ifE):
            if !exprIsReadOnly(varName: varName, expr: ifE.condition) { return false }
            if !blockIsReadOnly(varName: varName, body: ifE.thenBlock) { return false }
            for clause in ifE.elsifClauses {
                if !exprIsReadOnly(varName: varName, expr: clause.condition) { return false }
                if !blockIsReadOnly(varName: varName, body: clause.body) { return false }
            }
            for (_, value) in ifE.elsifLet {
                if !exprIsReadOnly(varName: varName, expr: value) { return false }
            }
            if let elseBlock = ifE.elseBlock, !blockIsReadOnly(varName: varName, body: elseBlock) {
                return false
            }
            if let ifLetValue = ifE.ifLetValue, !exprIsReadOnly(varName: varName, expr: ifLetValue) {
                return false
            }
            return true
        case .call(let callee, _, let args, _):
            if case .field(let base, _, _) = callee {
                if exprRootIs(varName, expr: base) { return false }
                if !exprIsReadOnly(varName: varName, expr: base) { return false }
            } else {
                if exprRootIs(varName, expr: callee) { return false }
                if !exprIsReadOnly(varName: varName, expr: callee) { return false }
            }
            return callArgsAreReadOnly(varName: varName, callee: callee, args: args)
        case .index(let base, let idx, _):
            if case .name(let n, _) = base {
                if n == varName { return true }
                return exprIsReadOnly(varName: varName, expr: idx)
            }
            return exprIsReadOnly(varName: varName, expr: base)
                && exprIsReadOnly(varName: varName, expr: idx)
        case .range(let start, let end, _, _):
            return exprIsReadOnly(varName: varName, expr: start)
                && exprIsReadOnly(varName: varName, expr: end)
        case .matchExpr(let matchE):
            if !exprIsReadOnly(varName: varName, expr: matchE.subject) { return false }
            for arm in matchE.arms {
                if let guardExpr = arm.guardExpr, !exprIsReadOnly(varName: varName, expr: guardExpr) {
                    return false
                }
                if !exprIsReadOnly(varName: varName, expr: arm.body) { return false }
            }
            return true
        case .cast(let inner, _, _), .tryOp(let inner, _), .awaitExpr(let inner, _):
            return exprIsReadOnly(varName: varName, expr: inner)
        case .closure(let closureE):
            return !closureMentions(varName, expr: closureE.body)
        case .unary(let op, let inner, _):
            switch op {
            case .borrow, .borrowMut, .deref:
                if exprRootIs(varName, expr: inner) { return false }
                return exprIsReadOnly(varName: varName, expr: inner)
            default:
                return exprIsReadOnly(varName: varName, expr: inner)
            }
        case .field(let base, _, _):
            if case .name(let n, _) = base {
                return n != varName
            }
            return exprIsReadOnly(varName: varName, expr: base)
        case .binary(let left, _, let right, _):
            return exprIsReadOnly(varName: varName, expr: left)
                && exprIsReadOnly(varName: varName, expr: right)
        case .macroCall(_, let args, _):
            for arg in args {
                if case .expr(let e) = arg, !exprIsReadOnly(varName: varName, expr: e) {
                    return false
                }
            }
            return true
        case .assign(let target, let value, _), .compoundAssign(let target, _, let value, _):
            if exprRootIs(varName, expr: target) { return false }
            return exprIsReadOnly(varName: varName, expr: target)
                && exprIsReadOnly(varName: varName, expr: value)
        case .returnExpr(let v, _), .breakExpr(let v, _):
            if let v { return exprIsReadOnly(varName: varName, expr: v) }
            return true
        case .nextExpr:
            return true
        case .forExpr(let forE):
            if exprRootIs(varName, expr: forE.iterable) { return false }
            return exprIsReadOnly(varName: varName, expr: forE.iterable)
                && blockIsReadOnly(varName: varName, body: forE.body)
        case .whileExpr(let whileE):
            return exprIsReadOnly(varName: varName, expr: whileE.condition)
                && blockIsReadOnly(varName: varName, body: whileE.body)
        case .loopExpr(let body, _):
            return blockIsReadOnly(varName: varName, body: body)
        case .handleExpr(let handleE):
            if !exprIsReadOnly(varName: varName, expr: handleE.expr) { return false }
            for arm in handleE.arms {
                if !exprIsReadOnly(varName: varName, expr: arm.body) { return false }
            }
            return true
        case .unlessExpr(let unlessE):
            if !exprIsReadOnly(varName: varName, expr: unlessE.condition) { return false }
            if !blockIsReadOnly(varName: varName, body: unlessE.body) { return false }
            if let elseBlock = unlessE.elseBlock, !blockIsReadOnly(varName: varName, body: elseBlock) {
                return false
            }
            return true
        case .untilExpr(let untilE):
            return exprIsReadOnly(varName: varName, expr: untilE.condition)
                && blockIsReadOnly(varName: varName, body: untilE.body)
        case .tryBlock(let tryB):
            if !blockIsReadOnly(varName: varName, body: tryB.body) { return false }
            for clause in tryB.catchClauses {
                if !blockIsReadOnly(varName: varName, body: clause.body) { return false }
            }
            if let finally = tryB.finallyBlock, !blockIsReadOnly(varName: varName, body: finally) {
                return false
            }
            return true
        case .comptimeBlock(let body, _):
            return blockIsReadOnly(varName: varName, body: body)
        }
    }

    private func callArgsAreReadOnly(varName: String, callee: Expr, args: [CallArg]) -> Bool {
        for (index, arg) in args.enumerated() {
            if !callArgIsReadOnly(varName: varName, callee: callee, argIndex: index, arg: arg.value) {
                return false
            }
        }
        return true
    }

    private func callArgIsReadOnly(varName: String, callee: Expr, argIndex: Int, arg: Expr) -> Bool {
        if case .unary(.borrow, let inner, _) = arg {
            if exprRootIs(varName, expr: inner) {
                if case .name(let n, _) = inner {
                    return n != varName
                }
                return refParamIsLet(callee: callee, argIndex: argIndex)
            }
            return exprIsReadOnly(varName: varName, expr: inner)
        }
        return exprIsReadOnly(varName: varName, expr: arg)
    }

    private func refParamIsLet(callee: Expr, argIndex: Int) -> Bool {
        let calleeName: String?
        switch callee {
        case .name(let n, _):
            calleeName = n
        case .path(let a, let b, _):
            calleeName = "\(a)::\(b)"
        default:
            calleeName = nil
        }
        guard let name = calleeName,
              let conventions = lookupFunctionConventions(name),
              argIndex < conventions.count else {
            return false
        }
        if case .letAccess = conventions[argIndex] {
            return true
        }
        return false
    }

    private func closureMentions(_ varName: String, expr: Expr) -> Bool {
        switch expr {
        case .name(let n, _):
            return n == varName
        case .intLit, .floatLit, .stringLit, .charLit, .boolLit, .path:
            return false
        case .array(let elems, _), .tuple(let elems, _):
            return elems.contains { closureMentions(varName, expr: $0) }
        case .arrayRepeat(let value, let count, _):
            return closureMentions(varName, expr: value) || closureMentions(varName, expr: count)
        case .structLit(_, _, let fields, let rest, _):
            if fields.contains(where: { closureMentions(varName, expr: $0.1) }) { return true }
            if let rest { return closureMentions(varName, expr: rest) }
            return false
        case .block(let body, _), .unsafeBlock(_, let body, _), .comptimeBlock(let body, _):
            return closureBlockMentions(varName, body: body)
        case .ifExpr(let ifE):
            if closureMentions(varName, expr: ifE.condition) { return true }
            if closureBlockMentions(varName, body: ifE.thenBlock) { return true }
            for clause in ifE.elsifClauses {
                if closureMentions(varName, expr: clause.condition) { return true }
                if closureBlockMentions(varName, body: clause.body) { return true }
            }
            for (_, value) in ifE.elsifLet {
                if closureMentions(varName, expr: value) { return true }
            }
            if let elseBlock = ifE.elseBlock, closureBlockMentions(varName, body: elseBlock) { return true }
            if let ifLetValue = ifE.ifLetValue, closureMentions(varName, expr: ifLetValue) { return true }
            return false
        case .call(let callee, _, let args, _):
            if closureMentions(varName, expr: callee) { return true }
            return args.contains { closureMentions(varName, expr: $0.value) }
        case .index(let base, let idx, _):
            return closureMentions(varName, expr: base) || closureMentions(varName, expr: idx)
        case .range(let start, let end, _, _):
            return closureMentions(varName, expr: start) || closureMentions(varName, expr: end)
        case .matchExpr(let matchE):
            if closureMentions(varName, expr: matchE.subject) { return true }
            for arm in matchE.arms {
                if let guardExpr = arm.guardExpr, closureMentions(varName, expr: guardExpr) { return true }
                if closureMentions(varName, expr: arm.body) { return true }
            }
            return false
        case .cast(let inner, _, _), .tryOp(let inner, _), .awaitExpr(let inner, _):
            return closureMentions(varName, expr: inner)
        case .closure(let closureE):
            return closureMentions(varName, expr: closureE.body)
        case .unary(_, let inner, _):
            return closureMentions(varName, expr: inner)
        case .field(let base, _, _):
            return closureMentions(varName, expr: base)
        case .binary(let left, _, let right, _):
            return closureMentions(varName, expr: left) || closureMentions(varName, expr: right)
        case .macroCall(_, let args, _):
            for arg in args {
                if case .expr(let e) = arg, closureMentions(varName, expr: e) { return true }
            }
            return false
        case .assign(let target, let value, _), .compoundAssign(let target, _, let value, _):
            return closureMentions(varName, expr: target) || closureMentions(varName, expr: value)
        case .returnExpr(let v, _), .breakExpr(let v, _):
            if let v { return closureMentions(varName, expr: v) }
            return false
        case .nextExpr:
            return false
        case .forExpr(let forE):
            return closureMentions(varName, expr: forE.iterable)
                || closureBlockMentions(varName, body: forE.body)
        case .whileExpr(let whileE):
            return closureMentions(varName, expr: whileE.condition)
                || closureBlockMentions(varName, body: whileE.body)
        case .loopExpr(let body, _):
            return closureBlockMentions(varName, body: body)
        case .handleExpr(let handleE):
            if closureMentions(varName, expr: handleE.expr) { return true }
            return handleE.arms.contains { closureMentions(varName, expr: $0.body) }
        case .unlessExpr(let unlessE):
            if closureMentions(varName, expr: unlessE.condition) { return true }
            if closureBlockMentions(varName, body: unlessE.body) { return true }
            if let elseBlock = unlessE.elseBlock { return closureBlockMentions(varName, body: elseBlock) }
            return false
        case .untilExpr(let untilE):
            return closureMentions(varName, expr: untilE.condition)
                || closureBlockMentions(varName, body: untilE.body)
        case .tryBlock(let tryB):
            if closureBlockMentions(varName, body: tryB.body) { return true }
            for clause in tryB.catchClauses {
                if closureBlockMentions(varName, body: clause.body) { return true }
            }
            if let finally = tryB.finallyBlock { return closureBlockMentions(varName, body: finally) }
            return false
        }
    }

    private func closureBlockMentions(_ varName: String, body: BlockBody) -> Bool {
        for stmt in body.stmts {
            if closureStmtMentions(varName, stmt: stmt) { return true }
        }
        if let tail = body.tailExpr, closureMentions(varName, expr: tail) { return true }
        return false
    }

    private func closureStmtMentions(_ varName: String, stmt: Stmt) -> Bool {
        switch stmt {
        case .letBinding(_, _, _, let value, _):
            return closureMentions(varName, expr: value)
        case .exprStmt(let expr, _):
            return closureMentions(varName, expr: expr)
        case .attributeStmt:
            return false
        case .attributed(_, let inner, _):
            return closureStmtMentions(varName, stmt: inner)
        case .deferStmt(let body, _):
            return closureBlockMentions(varName, body: body)
        case .item:
            return false
        }
    }

    private func lowerProjectedFor(_ forE: ForExpr, varName: String, patMut: Bool,
                                   iterType: MirType, elemTy: MirType) {
        guard let iterPlace = exprToPlace(forE.iterable) else { return }
        let iterLocal = freshTemp(type: iterType)
        emit(.assign(.local(iterLocal), .use(.mirCopy(iterPlace))))

        // Index variable: _idx = 0
        let idxLocal = freshTemp()
        emit(.assign(.local(idxLocal), .use(.mirConstant(.int(0)))))

        // Length of collection, evaluated once at entry
        let lenLocal = freshTemp()
        emit(.assign(.local(lenLocal), .len(.local(iterLocal))))

        let condBB = freshBlock()
        let bodyBB = freshBlock()
        let incrBB = freshBlock()
        let exitBB = freshBlock()

        terminateWith(.goto(condBB))

        // Condition: idx < len
        currentBlock = condBB
        let cmpTmp = freshTemp(type: .bool)
        emit(.assign(.local(cmpTmp), .binaryOp(.lt, .mirCopy(.local(idxLocal)), .mirCopy(.local(lenLocal)))))
        terminateWith(.switchInt(.mirCopy(.local(cmpTmp)), targets: [(1, bodyBB)], otherwise: exitBB))

        // Body: let x = &iter[idx]; execute body
        currentBlock = bodyBB
        loopBreakTargets.append(exitBB)
        loopContinueTargets.append(incrBB)
        pushScope()
        let xLocal = freshLocal(name: varName, type: .refInternal(elemTy, false), mutable: patMut)
        defineInScope(varName, xLocal)
        emit(.assign(.local(xLocal), .mirRef(MirPlace(local: iterLocal, projections: [.index(idxLocal)]))))
        let tmp = freshTemp()
        lowerBlock(forE.body, resultInto: tmp)
        popScope()
        loopBreakTargets.removeLast()
        loopContinueTargets.removeLast()
        terminateIfNeeded(.goto(incrBB))

        // Increment: idx = idx + 1, then back to condition
        currentBlock = incrBB
        let incTmp = freshTemp()
        emit(.assign(.local(incTmp), .binaryOp(.add, .mirCopy(.local(idxLocal)), .mirConstant(.int(1)))))
        emit(.assign(.local(idxLocal), .use(.mirCopy(.local(incTmp)))))
        terminateWith(.goto(condBB))

        currentBlock = exitBB
    }

    private func lowerFor(_ forE: ForExpr) -> MirOperand {
        if let projected = tryLowerForProjected(forE) {
            return projected
        }
        let iterableOp = lowerExpr(forE.iterable)
        let iterableLocal = placeOf(iterableOp)

        // Copy the iterable directly into the iterator local (identity .iter()).
        // Using a direct assignment avoids a function-call stub that would lose
        // the multi-word Vec/Map header (only 8 bytes survive a register return).
        let iterType = operandType(.mirCopy(.local(iterableLocal))) ?? .unknown
        let iterLocal = freshTemp(type: iterType)
        emit(.assign(.local(iterLocal), .use(.mirCopy(.local(iterableLocal)))))

        // Index variable: mut _idx = 0
        let idxLocal = freshTemp()
        emit(.assign(.local(idxLocal), .use(.mirConstant(.int(0)))))

        // Length of collection — use MirLen rvalue so codegen reads the len
        // field directly from the collection header without an extra deref.
        let lenLocal = freshTemp()
        emit(.assign(.local(lenLocal), .len(.local(iterLocal))))

        let condBB = freshBlock()
        let bodyBB = freshBlock()
        let incrBB = freshBlock()
        let exitBB = freshBlock()

        terminateWith(.goto(condBB))

        // Condition: idx < len
        currentBlock = condBB
        let cmpTmp = freshTemp(type: .bool)
        emit(.assign(.local(cmpTmp), .binaryOp(.lt, .mirCopy(.local(idxLocal)), .mirCopy(.local(lenLocal)))))
        terminateWith(.switchInt(.mirCopy(.local(cmpTmp)), targets: [(1, bodyBB)], otherwise: exitBB))

        // Body: let elem = iter[idx]; execute body
        currentBlock = bodyBB
        loopBreakTargets.append(exitBB)
        loopContinueTargets.append(incrBB)
        pushScope()
        let elemLocal = freshTemp()
        emit(.assign(.local(elemLocal), .use(.mirCopy(MirPlace(local: iterLocal, projections: [.index(idxLocal)])))))
        lowerPatternBind(forE.pattern, value: .mirCopy(.local(elemLocal)))
        let tmp = freshTemp()
        lowerBlock(forE.body, resultInto: tmp)
        popScope()
        loopBreakTargets.removeLast()
        loopContinueTargets.removeLast()
        terminateIfNeeded(.goto(incrBB))

        // Increment: idx = idx + 1, then back to condition
        currentBlock = incrBB
        let incTmp = freshTemp()
        emit(.assign(.local(incTmp), .binaryOp(.add, .mirCopy(.local(idxLocal)), .mirConstant(.int(1)))))
        emit(.assign(.local(idxLocal), .use(.mirCopy(.local(incTmp)))))
        terminateWith(.goto(condBB))

        currentBlock = exitBB
        return .mirConstant(.unit)
    }

    private func lowerWhile(_ whileE: WhileExpr) -> MirOperand {
        let condBB = freshBlock()
        let bodyBB = freshBlock()
        let exitBB = freshBlock()

        terminateWith(.goto(condBB))

        currentBlock = condBB
        let condOp = normalizeCondition(lowerExpr(whileE.condition))
        terminateWith(.switchInt(condOp, targets: [(1, bodyBB)], otherwise: exitBB))

        currentBlock = bodyBB
        loopBreakTargets.append(exitBB)
        loopContinueTargets.append(condBB)
        pushScope()
        let tmp = freshTemp()
        lowerBlock(whileE.body, resultInto: tmp)
        popScope()
        loopBreakTargets.removeLast()
        loopContinueTargets.removeLast()
        terminateIfNeeded(.goto(condBB))

        currentBlock = exitBB
        return .mirConstant(.unit)
    }

    private func lowerLoop(_ body: BlockBody) -> MirOperand {
        let loopBB = freshBlock()
        let exitBB = freshBlock()

        terminateWith(.goto(loopBB))

        currentBlock = loopBB
        loopBreakTargets.append(exitBB)
        loopContinueTargets.append(loopBB)
        pushScope()
        let tmp = freshTemp()
        lowerBlock(body, resultInto: tmp)
        popScope()
        loopBreakTargets.removeLast()
        loopContinueTargets.removeLast()
        terminateIfNeeded(.goto(loopBB))

        currentBlock = exitBB
        return .mirConstant(.unit)
    }

    private func lowerClosure(_ closureE: ClosureExpr) -> MirOperand {
        // Lower closure as a separate anonymous function with capture support
        let closureName = "__closure_\(functions.count)"

        // ── 1. Collect outer scope bindings for capture ──
        // Shadowing-aware: iterate the scopes INNERMOST-FIRST and keep only
        // the NEAREST binding per name — an inner binding shadows the outer
        // one, so the outermost must never win (and duplicates would
        // otherwise create duplicate capture params).
        var outerBindings: [(String, LocalId)] = []
        var seenOuterNames = Set<String>()
        for scope in scopes.reversed() {
            for (name, id) in scope {
                if !seenOuterNames.contains(name) {
                    seenOuterNames.insert(name)
                    outerBindings.append((name, id))
                }
            }
        }
        let savedBlocks = blocks
        let savedLocals = locals
        let savedCurrentBlock = currentBlock
        let savedNextLocal = nextLocal
        let savedNextBlock = nextBlock
        let savedReturnLocal = returnLocal
        let savedScopes = scopes
        let savedDeferBlocks = pendingDeferBlocks

        resetFunctionState()
        pushScope()
        let retType: MirType = closureE.returnType.map(lowerTypeExpr) ?? .unknown
        returnLocal = freshLocal(name: "_return", type: retType, mutable: true)

        // ── 2. Create declared params ──
        var paramLocals: [MirLocal] = []
        for p in closureE.params {
            let pType = p.type.map(lowerTypeExpr) ?? .unknown
            let id = freshLocal(name: p.name, type: pType, mutable: p.isMutable)
            defineInScope(p.name, id)
            paramLocals.append(locals[id])
        }

        // ── 3. Create capture params (outer bindings not shadowed by declared params) ──
        var captureParamLocals: [MirLocal] = []
        var captureOuterIds: [LocalId] = []
        var seenNames = Set(closureE.params.map(\.name))
        for (name, outerId) in outerBindings {
            if !seenNames.contains(name) {
                seenNames.insert(name)
                // Propagate the actual type from the outer scope's local, not .unknown.
                // savedLocals was captured before resetFunctionState() cleared self.locals,
                // so savedLocals[outerId] refers to the original outer-scope local.
                let captureType = savedLocals[outerId].type
                let captureId = freshLocal(name: name, type: captureType, mutable: false)
                defineInScope(name, captureId)
                captureParamLocals.append(locals[captureId])
                captureOuterIds.append(outerId)
            }
        }

        // ── 4. Lower closure body (captures are in scope) ──
        let entry = freshBlock()
        currentBlock = entry
        let bodyVal = lowerExpr(closureE.body)
        emit(.assign(.local(returnLocal), .use(bodyVal)))
        terminateIfNeeded(exitTerminator())
        popScope()

        // Wire the closure's own exit cleanup (defers registered inside
        // the closure body, LIFO).
        buildDeferExitChain()

        // ── 5. Create MIR function with all params (declared + captures) ──
        let allParams = paramLocals + captureParamLocals
        let mirFn = MirFunction(name: closureName, params: allParams, returnType: retType,
                                 locals: locals, blocks: blocks, entryBlock: entry)
        functions.append(mirFn)
        fnCache.removeAll()  // Invalidate cache when functions are added

        // Restore state
        blocks = savedBlocks; locals = savedLocals
        currentBlock = savedCurrentBlock; nextLocal = savedNextLocal
        nextBlock = savedNextBlock; returnLocal = savedReturnLocal
        scopes = savedScopes
        pendingDeferBlocks = savedDeferBlocks

        // ── 6. Emit closure value in parent function ──
        if captureOuterIds.isEmpty {
            return .mirConstant(.fnItem(closureName))
        }
        // Build aggregate with captured values from outer scope
        var captureOps: [MirOperand] = []
        for outerId in captureOuterIds {
            captureOps.append(.mirCopy(.local(outerId)))
        }
        let closureTmp = freshTemp()
        emit(.assign(.local(closureTmp), .aggregate(.closure(closureName), captureOps)))
        return .mirCopy(.local(closureTmp))
    }

    // MARK: - Type lowering
    //
    // lowerTypeExpr carries EVERYTHING the source type annotation carries
    // (the kernel's resolve_type_expr parity — TypeExpr → Type is
    // lossless):
    //   - [T; N]       → .array(inner, N)  — the FIXED length carried (the
    //                     kernel's Type::FixedArray(elem, count); a
    //                     non-constant size is an explicit lowering error,
    //                     never a silently dropped length);
    //   - T<A1, ...>   → .named(name, args) — the generic instantiation
    //                     carried (the kernel's Type::Adt(TypeId, args));
    //   - T?           → .named("Option", [T]) — the arg carried;
    //   - Self         → the current impl target (deliberately kept).

    private func lowerTypeExpr(_ typeExpr: TypeExpr) -> MirType {
        switch typeExpr {
        case .named(let name, let typeArgs, _):
            switch name {
            case "Int": return .int
            case "Float", "f64": return .float
            case "Bool": return .bool
            case "String": return .string
            case "Char": return .char
            case "Unit", "()": return .unit
            default: return .named(name, typeArgs.map(lowerTypeExpr))
            }
        case .assocBinding:
            return .unknown
        case .constExpr:
            return .unknown
        case .never:
            return .unknown
        case .tuple(let elems, _):
            return .tuple(elems.map(lowerTypeExpr))
        case .ref(let inner, let mutable, _):
            return .refInternal(lowerTypeExpr(inner), mutable)
        case .rawPtr(let inner, _, _):
            return .rawPtr(lowerTypeExpr(inner))
        case .array(let inner, let lenExpr, _):
            // The [T; N] length is carried in the type (the kernel's
            // FixedArray count); a length that is not a compile-time
            // constant is an explicit error — the length is never
            // silently dropped.
            let len: Int?
            if let lenExpr {
                len = evalConstSize(lenExpr)
                if len == nil {
                    recordLoweringError("MIRLowering lowerTypeExpr: array type [T; N] length is not a compile-time constant (span \(lenExpr.span))")
                }
            } else {
                len = nil
            }
            return .array(lowerTypeExpr(inner), len)
        case .slice(let inner, _):
            return .slice(lowerTypeExpr(inner))
        case .option(let inner, _):
            // `T?` — the Option Adt WITH its type argument (never the
            // bare "Option" name with the instantiation dropped).
            return .named("Option", [lowerTypeExpr(inner)])
        case .fnPtr(let params, let ret, _):
            return .fn(params.map(lowerTypeExpr), lowerTypeExpr(ret))
        case .unit(_):
            return .unit
        case .dynTrait(_, _), .implTrait(_, _), .bounded(_, _, _):
            return .unknown
        case .selfType(_):
            if let currentSelfType {
                return .named(currentSelfType, [])
            }
            return .unknown
        case .inferred(_):
            return .unknown
        }
    }

    /// The bounded const-size evaluator for `[T; N]` lengths and repeat
    /// counts — the kernel's eval_const_size_expr subset (int literals,
    /// const-ident/path references, + - * / % arithmetic, unary neg),
    /// fail-closed: any other form returns nil (the caller reports the
    /// explicit error — never a silently guessed size).
    private func evalConstSize(_ expr: Expr) -> Int? {
        switch expr {
        case .intLit(let s, _):
            return MIRLowering.parseInt(s)
        case .name(let n, _):
            return statics.first(where: { $0.name == n })?.initializer.flatMap { c in
                if case .int(let i) = c { return i } else { return nil }
            }
        case .path(let a, let b, _):
            let qualified = "\(a)::\(b)"
            return statics.first(where: { $0.name == qualified })?.initializer.flatMap { c in
                if case .int(let i) = c { return i } else { return nil }
            }
        case .binary(let l, let op, let r, _):
            guard let a = evalConstSize(l), let b = evalConstSize(r) else { return nil }
            switch op {
            case .add:
                if a >= 0 && b >= 0 && a <= Int.max - b { return a + b } else { return nil }
            case .sub:
                return a >= b ? a - b : nil
            case .mul:
                if a >= 0 && b >= 0 && (a == 0 || b <= Int.max / a) { return a * b } else { return nil }
            case .div:
                return b != 0 ? a / b : nil
            case .mod:
                return b != 0 ? a % b : nil
            default:
                return nil
            }
        case .unary(let op, let inner, _):
            if case .neg = op {
                if let n = evalConstSize(inner) { return -n }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Constant evaluation (for const/static initializers)

    private func evalConstant(_ expr: Expr) -> MirConstant? {
        switch expr {
        case .intLit(let s, let span):
            guard let v = MIRLowering.parseInt(s) else {
                recordLoweringError("MIRLowering: unparseable integer literal '\(s)' at span \(span.start)..<\(span.end) — the parse failure is reported at the literal's span (INV-PARSE-003 fail-closed), never a silent 0")
                return nil
            }
            return .int(v)
        case .floatLit(let s, let span):
            guard let v = MIRLowering.parseFloatLiteral(s) else {
                recordLoweringError("MIRLowering: unparseable float literal '\(s)' at span \(span.start)..<\(span.end) — the parse failure is reported at the literal's span (INV-PARSE-003 fail-closed), never a silent 0.0")
                return nil
            }
            return .float(v)
        case .stringLit(let s, _): return .str(s)
        case .charLit(let c, _): return .char(c)
        case .boolLit(let b, _): return .bool(b)
        default: return nil
        }
    }

    // MARK: - BinOp mapping

    private func lowerBinOp(_ op: BinaryOp) -> MirBinOp {
        switch op {
        case .add: return .add
        case .sub: return .sub
        case .mul: return .mul
        case .div: return .div
        case .mod: return .rem
        case .eq: return .eq
        case .notEq: return .ne
        case .lt: return .lt
        case .ltEq: return .le
        case .gt: return .gt
        case .gtEq: return .ge
        case .and: return .and
        case .or: return .or
        case .bitAnd: return .bitAnd
        case .bitOr: return .bitOr
        case .bitXor: return .bitXor
        case .shl: return .shl
        case .shr: return .shr
        }
    }

    /// The static result type of a binary operator: comparisons and the
    /// logical and/or produce Bool; arithmetic and bitwise produce Int.
    private func binOpResultType(_ op: BinaryOp) -> MirType {
        switch op {
        case .eq, .notEq, .lt, .ltEq, .gt, .gtEq, .and, .or:
            return .bool
        case .add, .sub, .mul, .div, .mod, .bitAnd, .bitOr, .bitXor, .shl, .shr:
            return .int
        }
    }

    // MARK: - Builder helpers

    private func resetFunctionState() {
        blocks = []
        locals = []
        currentBlock = 0
        nextLocal = 0
        nextBlock = 0
        returnLocal = 0
        scopes = []
        pendingDeferBlocks = []
    }

    /// The function-exit terminator: with registered defers, every exit
    /// (fallthrough and explicit return) routes through the LIFO defer
    /// chain (the last registered defer block); without defers the exit
    /// is the direct .ret.
    private func exitTerminator() -> MirTerminator {
        guard let lastDefer = pendingDeferBlocks.last else {
            return .ret
        }
        return .goto(lastDefer)
    }

    /// Wire the registered defer blocks into the function's exit cleanup:
    /// execution enters the LAST registered defer's block first (LIFO),
    /// each block chains to the previously registered one, and the first
    /// registered block chains to a fresh block terminated with .ret.
    /// Called once at function end, after every exit site has been
    /// lowered (its terminator already captured the chain entry).
    private func buildDeferExitChain() {
        guard !pendingDeferBlocks.isEmpty else { return }
        let retBlock = freshBlock()
        let savedBlock = currentBlock
        for (i, deferBlock) in pendingDeferBlocks.enumerated().reversed() {
            let next = i == 0 ? retBlock : pendingDeferBlocks[i - 1]
            currentBlock = deferBlock
            terminateIfNeeded(.goto(next))
        }
        currentBlock = retBlock
        terminateWith(.ret)
        currentBlock = savedBlock
    }

    @discardableResult
    private func freshLocal(name: String? = nil, type: MirType = .unknown, mutable: Bool = false) -> LocalId {
        let id = nextLocal
        nextLocal += 1
        locals.append(MirLocal(id: id, name: name, type: type, isMutable: mutable))
        return id
    }

    private func freshTemp(type: MirType = .unknown) -> LocalId {
        return freshLocal(name: nil, type: type, mutable: true)
    }

    private func freshBlock() -> BlockId {
        let id = nextBlock
        nextBlock += 1
        blocks.append(MirBlock(id: id))
        return id
    }

    private func emit(_ stmt: MirStatement) {
        guard currentBlock < blocks.count else { return }
        blocks[currentBlock].statements.append(stmt)
    }

    private func terminateWith(_ term: MirTerminator) {
        guard currentBlock < blocks.count else { return }
        blocks[currentBlock].terminator = term
    }

    private func terminateIfNeeded(_ term: MirTerminator) {
        guard currentBlock < blocks.count else { return }
        if case .unreachable = blocks[currentBlock].terminator {
            blocks[currentBlock].terminator = term
        }
    }

    // MARK: - Scope

    private func pushScope() { scopes.append([:]) }
    private func popScope() { if !scopes.isEmpty { scopes.removeLast() } }

    private func defineInScope(_ name: String, _ id: LocalId) {
        if !scopes.isEmpty { scopes[scopes.count - 1][name] = id }
    }

    private func lookupScope(_ name: String) -> LocalId? {
        for scope in scopes.reversed() {
            if let id = scope[name] { return id }
        }
        return nil
    }

    // MARK: - Utility

    private func placeOf(_ op: MirOperand) -> LocalId {
        switch op {
        case .mirCopy(let p), .mirMovePlace(let p), .mirRead(let p), .mirConsume(let p): return p.local
        case .mirConstant:
            let tmp = freshTemp()
            emit(.assign(.local(tmp), .use(op)))
            return tmp
        }
    }

    // DEAD CODE — do not port (the audit item 6): the hash-based field
    // index (abs(name.hashValue) % 256) is never called — field access is
    // resolved by NAME through MirPlace namedField projections, and the
    // kernel's layout resolves fields structurally. Kept only as the
    // audit marker; no caller exists.
    private func fieldIndex(_ name: String) -> Int {
        // Without type info, use name hash for deterministic field index
        // In a real compiler this would resolve via type definitions
        return abs(name.hashValue) % 256
    }

    /// Convert an expression directly to a MirPlace (for &/&mut lowering).
    /// Returns nil if the expression can't be represented as a place.
    /// `*x` (ExprRawDeref) is place-like (ast.tg expr_is_place_like): the
    /// deref is the ProjDeref projection on the inner place.
    private func exprToPlace(_ expr: Expr) -> MirPlace? {
        switch expr {
        case .name(let n, _):
            if let id = lookupScope(n) {
                return MirPlace(local: id)
            }
            // &static: the static-address place — the projStatic form
            // (the kernel's MirStaticAddr + place_deref). The root local
            // is unused; the projection carries the MirStatic name.
            if statics.contains(where: { $0.name == n }) {
                return MirPlace(local: 0, projections: [.projStatic(n)])
            }
            return nil
        case .field(let base, let field, _):
            if let basePlace = exprToPlace(base) {
                return MirPlace(local: basePlace.local,
                                projections: basePlace.projections + [.namedField(field)])
            }
            return nil
        case .index(let base, let idx, _):
            if let basePlace = exprToPlace(base) {
                let idxOp = lowerExpr(idx)
                let idxLocal = placeOf(idxOp)
                return MirPlace(local: basePlace.local,
                                projections: basePlace.projections + [.index(idxLocal)])
            }
            return nil
        case .unary(let op, let inner, _):
            if case .deref = op {
                if let basePlace = exprToPlace(inner) {
                    return MirPlace(local: basePlace.local,
                                    projections: basePlace.projections + [.projDeref])
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Decompose an expression into a (local, projections) pair for assignment LHS.
    /// Evaluates subexpressions as needed (e.g., index expressions).
    private func lowerPlaceExpr(_ expr: Expr) -> (LocalId, [MirProjection]) {
        switch expr {
        case .name(let n, _):
            if let id = lookupScope(n) {
                return (id, [])
            }
            let op = lowerExpr(expr)
            return (placeOf(op), [])
        case .field(let base, let field, _):
            let (local, projs) = lowerPlaceExpr(base)
            var fieldProjs = projs
            // Auto-insert ProjDeref when the base local is a reference type and no
            // projections have been applied yet (mirrors native mir.tg behavior).
            if projs.isEmpty, isRefInternal(local) {
                fieldProjs.append(.projDeref)
            }
            return (local, fieldProjs + [.namedField(field)])
        case .index(let base, let idx, _):
            let (local, projs) = lowerPlaceExpr(base)
            var idxProjs = projs
            if projs.isEmpty, isRefInternal(local) {
                idxProjs.append(.projDeref)
            }
            let idxOp = lowerExpr(idx)
            let idxLocal = placeOf(idxOp)
            return (local, idxProjs + [.index(idxLocal)])
        case .unary(.deref, let inner, _):
            // `*p = v` — the LHS is the deref place (the ProjDeref
            // projection on the inner place; the kernel's place_deref),
            // never an assignment into a spill temp.
            let (local, projs) = lowerPlaceExpr(inner)
            return (local, projs + [.projDeref])
        default:
            let op = lowerExpr(expr)
            return (placeOf(op), [])
        }
    }

    private func isRefInternal(_ local: LocalId) -> Bool {
        guard let ty = locals.first(where: { $0.id == local })?.type else { return false }
        if case .refInternal(_, _) = ty { return true }
        return false
    }

    /// Resolve a bare function name to its fully qualified name.
    /// Uses caching for performance - scans functions only once per unique name.
    private func resolveFunctionName(_ name: String) -> String {
        // Check cache first
        if let cached = fnCache[name] {
            return cached
        }

        let result: String

        func hasFunction(named candidate: String) -> Bool {
            for fn in functions {
                if fn.name == candidate {
                    return true
                }
            }
            return false
        }

        func qualifiedAliases(for qualified: String) -> [String] {
            let parts = qualified.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return [] }

            let member = parts.last!
            let owner = parts.dropLast().joined(separator: "::")

            switch owner {
            case "Vec":
                return ["Array::\(member)"]
            case "Array":
                return ["Vec::\(member)"]
            case "HashMap":
                return ["Map::\(member)"]
            case "Map":
                return ["HashMap::\(member)"]
            case "HashSet":
                return ["Set::\(member)"]
            case "Set":
                return ["HashSet::\(member)"]
            default:
                return []
            }
        }

        // Qualified references still need resolution because std collection
        // impls are defined on Array/Map while source frequently calls Vec/HashMap.
        if name.contains("::") {
            if hasFunction(named: name) {
                result = name
            } else {
                result = qualifiedAliases(for: name).first { hasFunction(named: $0) } ?? name
            }
        } else {
            // Search existing functions for a matching bare name. The
            // current module's qualified registration is preferred FIRST
            // (the kernel's per-module tables decide the bare reference —
            // the audit item 12): "m::foo" for the current module path,
            // then the module-qualified ancestors, before the bare
            // exact/suffix scan. This keeps two same-named `def foo()` in
            // different modules resolved to the CALLER's module, not the
            // first registration.
            var resolved: String? = nil
            if !modulePath.isEmpty {
                resolved = moduleQualifiedTypeNames(for: name).first { hasFunction(named: $0) }
            }
            if let resolved {
                result = resolved
            } else if let exactMatch = functions.first(where: { $0.name == name }) {
                result = exactMatch.name
            } else {
                // Second pass: try qualified suffix matches
                let suffix = "::" + name
                let mangleSuffix = "__" + name
                if let suffixMatch = functions.first(where: { $0.name.hasSuffix(suffix) || $0.name.hasSuffix(mangleSuffix) }) {
                    result = suffixMatch.name
                } else {
                    // Search type definitions for methods
                    result = typeDefs.first { td in
                        functions.contains { $0.name == td.name + "::" + name }
                    }.map { $0.name + "::" + name } ?? name
                }
            }
        }

        // Cache the result
        fnCache[name] = result
        return result
    }

    /// Parse an integer literal string, supporting hex (0x), binary (0b), octal (0o),
    /// decimal, and underscore separators. Returns nil when the literal cannot be
    /// parsed — the parse FAILURE is the caller's to report at the literal's span
    /// (the kernel's fail-closed numeric handling: never the silent 0).
    static func parseInt(_ s: String) -> Int? {
        let clean = s.replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Strip type suffixes like u8, u16, u32, u64, i32, i64, u128, i128,
        // usize, isize, and the bare u/i spellings (u, i, 8_u). The set is
        // the kernel's `integer_suffix_valid` plus the stage0's documented
        // separator-before-suffix spelling.
        let stripped: String
        if let r = clean.range(of: #"(?:_)?(?:[ui](?:8|16|32|64|128)?|usize|isize)$"#, options: .regularExpression) {
            stripped = String(clean[clean.startIndex..<r.lowerBound])
        } else {
            stripped = clean
        }
        let parsed: Int?
        let radix: Int
        if stripped.hasPrefix("0x") || stripped.hasPrefix("0X") {
            parsed = Int(stripped.dropFirst(2), radix: 16)
            radix = 16
        } else if stripped.hasPrefix("0b") || stripped.hasPrefix("0B") {
            parsed = Int(stripped.dropFirst(2), radix: 2)
            radix = 2
        } else if stripped.hasPrefix("0o") || stripped.hasPrefix("0O") {
            parsed = Int(stripped.dropFirst(2), radix: 8)
            radix = 8
        } else {
            parsed = Int(stripped)
            radix = 10
        }
        if let parsed = parsed {
            return parsed
        }
        // The unsigned domain (the kernel's u64 hash constants exceed
        // Int64.max): preserve the bit pattern instead of silently
        // truncating to 0 (INV-PARSE-003 — the E9030 gate admits exactly
        // the magnitudes that fit UInt64). The wrap is DELIBERATE and
        // documented; only a literal the lexer/E9030 could not validate
        // reaches the nil below, which the caller reports as the parse
        // failure (never a silent 0).
        let digits = stripped.hasPrefix("0x") || stripped.hasPrefix("0X")
            ? String(stripped.dropFirst(2))
            : (stripped.hasPrefix("0b") || stripped.hasPrefix("0B")
                ? String(stripped.dropFirst(2))
                : (stripped.hasPrefix("0o") || stripped.hasPrefix("0O")
                    ? String(stripped.dropFirst(2))
                    : stripped))
        if let unsigned = UInt64(digits, radix: radix) {
            return Int(bitPattern: UInt(truncatingIfNeeded: unsigned))
        }
        return nil
    }

    /// Parse a float literal spelling to a Double. The grammar is the
    /// Swift-compatible float grammar (the audit item 3): Swift's Double()
    /// accepts the hex floats (`0x1.8p3`), inf/infinity/nan, and the
    /// decimal significand/exponent forms; the kernel's fail-closed
    /// validations — the malformed `1e`/`1.` shapes and the invalid
    /// suffixes — are rejected at the LEXER (E1010/E1014), so an
    /// unparseable float reaching the lowering is a parse failure the
    /// caller reports at the literal's span (never a fabricated 0.0).
    static func parseFloatLiteral(_ s: String) -> Double? {
        let clean = s.replacingOccurrences(of: "_", with: "")
        return Double(clean)
    }
}
