// AST.swift — Abstract Syntax Tree for the Tangerine language
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// Mirrors the Rust stage0 AST types.
//
// PRIVATE BOOTSTRAP DIALECT NOTE (reviewer item U parity batch):
// The seed's SEMANTIC approximations — the interpreter's value/layout model,
// the absence of real type checking, and the normalization of `&T`/`&mut T`
// access markers down to their inner type — describe the stage0's PRIVATE
// bootstrap dialect, NOT the stabilized user language semantics. The seed is
// a minimal parser+lowerer for the SAME stabilized syntax (access
// conventions, no first-class safe references, module-qualified identity,
// fixed-array vs Vec distinction, public ABI/layout contracts); it does not
// (yet) implement the Tangerine type checker's semantics. Structural parity
// lives here; semantic parity is tracked separately and is out of scope for
// the seed.

// MARK: - Program

/// A parsed source file.
public struct Program {
    public var items: [Item]
    public var span: Span
    /// The file-derived owner module path of this program — the mirror of the
    /// Tangerine compiler's `module_path_from_file` ("std/core.tg" →
    /// ["std", "core"]; the main program / unnamed source → []).
    public var modulePath: [String]
    /// The module table — the mirror of the Tangerine side's `ModuleInfo`
    /// transition (Program.crate.modules: one Module per distinct module,
    /// each indexing the contiguous [start, end) range of its items in the
    /// flat items vector). The seed parses one file per Program, so the
    /// table holds exactly one entry per file module; inline `module`
    /// blocks are represented by the items' stamped modulePath (the file
    /// path plus inline segments), exactly as the Tangerine resolver's
    /// `current_module` stack extends the owner Module's path.
    public var modules: [ModuleInfo]

    public init(items: [Item], span: Span, modulePath: [String] = [], modules: [ModuleInfo] = []) {
        self.items = items
        self.span = span
        self.modulePath = modulePath
        self.modules = modules
    }

    /// Mirror of the Tangerine resolver's `module_path_of_item_resolver`:
    /// the owner module path of the flat item at `index`, looked up in the
    /// module table. The root/empty fallback mirrors ModuleId { id: 0 }
    /// (empty path).
    public func modulePath(ofItem index: Int) -> [String] {
        for info in modules where info.itemRange.contains(index) {
            return info.path
        }
        return []
    }

    /// Mirror of the Tangerine resolver's `module_qualified_key`: the
    /// module-qualified symbol key "path::name". An empty path degenerates
    /// to the bare name, so qualified entries are exact supersets of the
    /// bare-name registration.
    public static func moduleQualifiedKey(path: [String], name: String) -> String {
        let joined = path.joined(separator: "::")
        if joined.isEmpty { return name }
        return joined + "::" + name
    }
}

/// A module entry in the Program's module table — the mirror of the
/// Tangerine side's `Module { id, path, item_indices, imports }` (the seed
/// keeps path + item range; id is implicit in array order, imports are the
/// use declarations already carried by the items).
public struct ModuleInfo {
    public var path: [String]
    public var itemRange: Range<Int>

    public init(path: [String], itemRange: Range<Int>) {
        self.path = path
        self.itemRange = itemRange
    }
}

// MARK: - Items (Top-Level Declarations)

public struct Item {
    public var kind: ItemKind
    public var attributes: [Attribute]
    public var span: Span
    /// The owner module path stamp — the module-qualified identity of this
    /// item (the (module, name) registration the Tangerine resolver now
    /// uses): the file module's path plus any inline `module` segments.
    /// Populated by the parser; empty for root-module items.
    public var modulePath: [String]

    public init(kind: ItemKind, attributes: [Attribute] = [], span: Span, modulePath: [String] = []) {
        self.kind = kind
        self.attributes = attributes
        self.span = span
        self.modulePath = modulePath
    }

    /// The module-qualified key of this item under the given bare name —
    /// the (module, name) registration key.
    public func qualifiedKey(name: String) -> String {
        Program.moduleQualifiedKey(path: modulePath, name: name)
    }
}

public enum ItemKind {
    case function(FunctionDecl)
    case testDecl(TestDecl)
    case structDef(StructDecl)
    case enumDef(EnumDecl)
    case traitDef(TraitDecl)
    case implBlock(ImplDecl)
    case useDecl(UseDecl)
    case constDecl(ConstDecl)
    case staticDecl(StaticDecl)
    case typeAlias(TypeAliasDecl)
    case externBlock(ExternBlockDecl)
    case moduleDef(ModuleDecl)
    case capabilityDecl(CapabilityDecl)
    case effectDecl(EffectDecl)
    case rationaleBlock(RationaleDecl)
    case macroDecl(MacroDecl)
    case editionDecl(EditionDecl)

    /// One-line summary for diagnostics.
    public var summary: String {
        switch self {
        case .function(let d):      return "def \(d.sig.name)"
        case .testDecl(let d):      return "test \"\(d.name)\""
        case .structDef(let d):     return "struct \(d.name)"
        case .enumDef(let d):       return "enum \(d.name)"
        case .traitDef(let d):      return "trait \(d.name)"
        case .implBlock(let d):
            if let trait = d.traitName {
                return "impl \(trait) for \(d.targetType)"
            }
            return "impl \(d.targetType)"
        case .useDecl(let d):       return "use \(d.pathString)"
        case .constDecl(let d):     return "const \(d.name)"
        case .staticDecl(let d):    return "static \(d.name)"
        case .typeAlias(let d):     return "type \(d.name)"
        case .externBlock:          return "extern block"
        case .moduleDef(let d):     return "module \(d.name)"
        case .capabilityDecl(let d):return "cap \(d.name)"
        case .effectDecl(let d):    return "effect \(d.name)"
        case .rationaleBlock:       return "rationale"
        case .macroDecl(let d):     return "macro \(d.name)"
        case .editionDecl(let d):   return "edition \(d.version)"
        }
    }
}

// MARK: - Functions

public struct TestDecl {
    public var name: String
    public var body: BlockBody
    public var span: Span

    public init(name: String, body: BlockBody, span: Span) {
        self.name = name
        self.body = body
        self.span = span
    }
}

public struct FunctionDecl {
    public var sig: FunctionSig
    public var clauses: [FunctionClause]
    public var body: FunctionBody
    public var span: Span

    public init(sig: FunctionSig, clauses: [FunctionClause] = [], body: FunctionBody, span: Span) {
        self.sig = sig
        self.clauses = clauses
        self.body = body
        self.span = span
    }
}

public struct FunctionSig {
    public var name: String
    public var isPublic: Bool
    public var isAsync: Bool
    public var isUnsafe: Bool
    public var isConst: Bool
    public var isPure: Bool
    public var isInline: Bool
    public var isExtern: Bool
    public var typeParams: [TypeParam]
    public var params: [Param]
    public var returnType: TypeExpr?
    public var whereClause: [WherePredicate]
    public var span: Span

    public init(
        name: String,
        isPublic: Bool = false,
        isAsync: Bool = false,
        isUnsafe: Bool = false,
        isConst: Bool = false,
        isPure: Bool = false,
        isInline: Bool = false,
        isExtern: Bool = false,
        typeParams: [TypeParam] = [],
        params: [Param] = [],
        returnType: TypeExpr? = nil,
        whereClause: [WherePredicate] = [],
        span: Span
    ) {
        self.name = name
        self.isPublic = isPublic
        self.isAsync = isAsync
        self.isUnsafe = isUnsafe
        self.isConst = isConst
        self.isPure = isPure
        self.isInline = isInline
        self.isExtern = isExtern
        self.typeParams = typeParams
        self.params = params
        self.returnType = returnType
        self.whereClause = whereClause
        self.span = span
    }
}

public struct Param {
    public var name: String
    public var isMutable: Bool
    public var convention: AccessConvention
    public var modifier: ParamModifier?
    public var type: TypeExpr
    public var defaultValue: Expr?
    public var span: Span

    public init(name: String, isMutable: Bool = false, convention: AccessConvention, modifier: ParamModifier? = nil, type: TypeExpr, defaultValue: Expr? = nil, span: Span) {
        self.name = name
        self.isMutable = isMutable
        self.convention = convention
        self.modifier = modifier
        self.type = type
        self.defaultValue = defaultValue
        self.span = span
    }
}

public enum ParamModifier {
    case mut
    case ref
    case refMut
    case move
    case own
}

public enum AccessConvention {
    case letAccess
    case inoutAccess
    case sink
    case set
}

public enum NominalKind {
    case value
    case resource
}

public struct TypeParam {
    public var name: String
    public var bounds: [String]
    public var span: Span

    public init(name: String, bounds: [String] = [], span: Span) {
        self.name = name
        self.bounds = bounds
        self.span = span
    }
}

public struct WherePredicate {
    public var type: TypeExpr
    public var bounds: [String]
    public var span: Span

    public init(type: TypeExpr, bounds: [String], span: Span) {
        self.type = type
        self.bounds = bounds
        self.span = span
    }
}

public enum FunctionBody {
    case block(BlockBody)
    case expr(Expr)
    case signatureOnly
}

public enum FunctionClause {
    case requires(RequiresClause)
    case effect(EffectClause)
    case budget(BudgetClause)
    case contract(ContractClause)
    case guardClause(GuardClause)
}

public struct RequiresClause {
    public var capabilities: [(name: String, negated: Bool)]
    public var span: Span
}

public struct EffectClause {
    public var effectName: String
    public var typeArgs: [TypeExpr]
    public var span: Span
}

public struct BudgetClause {
    public var entries: [(metric: String, amount: String)]
    public var span: Span
}

public struct ContractClause {
    public var kind: ContractKind
    public var condition: Expr
    public var message: String?
    public var span: Span

    public init(kind: ContractKind, condition: Expr, message: String? = nil, span: Span) {
        self.kind = kind
        self.condition = condition
        self.message = message
        self.span = span
    }
}

public enum ContractKind {
    case pre
    case post
    case invariant
}

public struct GuardClause {
    public var condition: Expr?
    public var pattern: Pattern?
    public var value: Expr?
    public var action: GuardAction
    public var span: Span
}

public enum GuardAction {
    case returnExpr(Expr?)
    case breakLabel(String?)
    case next(String?)
    case panicExpr(Expr)
}

// MARK: - Structs

public struct StructDecl {
    public var name: String
    public var isPublic: Bool
    public var typeParams: [TypeParam]
    public var whereClause: [WherePredicate]
    public var fields: [FieldDecl]
    public var methods: [FunctionDecl]
    public var kind: NominalKind
    public var span: Span

    public init(name: String, isPublic: Bool = false, typeParams: [TypeParam] = [],
                whereClause: [WherePredicate] = [], fields: [FieldDecl] = [],
                methods: [FunctionDecl] = [],
                kind: NominalKind = .value, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.typeParams = typeParams
        self.whereClause = whereClause
        self.fields = fields
        self.methods = methods
        self.kind = kind
        self.span = span
    }
}

public struct FieldDecl {
    public var name: String
    public var isPublic: Bool
    public var type: TypeExpr
    /// Default value expression (`field: T = expr`) — mirror of the
    /// Tangerine side's FieldDecl.default.
    public var defaultValue: Expr?
    public var span: Span

    public init(name: String, isPublic: Bool = false, type: TypeExpr, defaultValue: Expr? = nil, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.type = type
        self.defaultValue = defaultValue
        self.span = span
    }
}

// MARK: - Enums

public struct EnumDecl {
    public var name: String
    public var isPublic: Bool
    public var typeParams: [TypeParam]
    public var whereClause: [WherePredicate]
    public var variants: [VariantDecl]
    public var span: Span

    public init(name: String, isPublic: Bool = false, typeParams: [TypeParam] = [],
                whereClause: [WherePredicate] = [], variants: [VariantDecl] = [], span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.typeParams = typeParams
        self.whereClause = whereClause
        self.variants = variants
        self.span = span
    }
}

public struct VariantDecl {
    public var name: String
    public var fields: [VariantField]
    public var span: Span

    public init(name: String, fields: [VariantField] = [], span: Span) {
        self.name = name
        self.fields = fields
        self.span = span
    }
}

public struct VariantField {
    public var name: String?
    public var type: TypeExpr
    public var span: Span

    public init(name: String? = nil, type: TypeExpr, span: Span) {
        self.name = name
        self.type = type
        self.span = span
    }
}

// MARK: - Traits

public struct TraitDecl {
    public var name: String
    public var isPublic: Bool
    public var typeParams: [TypeParam]
    public var supertraits: [String]
    public var whereClause: [WherePredicate]
    public var methods: [FunctionDecl]
    public var associatedTypes: [TypeAliasDecl]
    public var span: Span

    public init(name: String, isPublic: Bool = false, typeParams: [TypeParam] = [],
                supertraits: [String] = [], whereClause: [WherePredicate] = [],
                methods: [FunctionDecl] = [], associatedTypes: [TypeAliasDecl] = [], span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.typeParams = typeParams
        self.supertraits = supertraits
        self.whereClause = whereClause
        self.methods = methods
        self.associatedTypes = associatedTypes
        self.span = span
    }
}

// MARK: - Impl Blocks

public struct ImplDecl {
    public var typeParams: [TypeParam]
    public var traitName: String?
    public var targetType: String
    public var forType: TypeExpr?
    public var whereClause: [WherePredicate]
    public var methods: [FunctionDecl]
    public var associatedTypes: [TypeAliasDecl]
    public var consts: [ConstDecl]
    public var span: Span

    public init(typeParams: [TypeParam] = [], traitName: String? = nil, targetType: String,
                forType: TypeExpr? = nil, whereClause: [WherePredicate] = [],
                methods: [FunctionDecl] = [], associatedTypes: [TypeAliasDecl] = [],
                consts: [ConstDecl] = [], span: Span) {
        self.typeParams = typeParams
        self.traitName = traitName
        self.targetType = targetType
        self.forType = forType
        self.whereClause = whereClause
        self.methods = methods
        self.associatedTypes = associatedTypes
        self.consts = consts
        self.span = span
    }
}

// MARK: - Use Declarations

public struct UseDecl {
    public var path: UsePath
    public var span: Span

    public init(path: UsePath, span: Span) {
        self.path = path
        self.span = span
    }

    public var pathString: String {
        path.description
    }
}

public enum UsePath: CustomStringConvertible {
    case simple([String])
    case aliased([String], String)
    case glob([String])
    case group([String], [UseItem])

    public var description: String {
        switch self {
        case .simple(let segs):     return segs.joined(separator: "::")
        case .aliased(let segs, let alias): return "\(segs.joined(separator: "::")) as \(alias)"
        case .glob(let segs):       return "\(segs.joined(separator: "::"))::*"
        case .group(let segs, let items):
            let itemsStr = items.map(\.description).joined(separator: ", ")
            return "\(segs.joined(separator: "::"))::\(itemsStr)"
        }
    }
}

public struct UseItem: CustomStringConvertible {
    public var name: String
    public var alias: String?
    public var span: Span

    public init(name: String, alias: String? = nil, span: Span) {
        self.name = name
        self.alias = alias
        self.span = span
    }

    public var description: String {
        if let alias = alias { return "\(name) as \(alias)" }
        return name
    }
}

// MARK: - Constants, Statics, Type Aliases

public struct ConstDecl {
    public var name: String
    public var isPublic: Bool
    public var type: TypeExpr
    public var value: Expr
    public var span: Span

    public init(name: String, isPublic: Bool = false, type: TypeExpr, value: Expr, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.type = type
        self.value = value
        self.span = span
    }
}

public struct StaticDecl {
    public var name: String
    public var isPublic: Bool
    public var isMutable: Bool
    public var type: TypeExpr
    public var value: Expr
    public var span: Span

    public init(name: String, isPublic: Bool = false, isMutable: Bool = false,
                type: TypeExpr, value: Expr, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.isMutable = isMutable
        self.type = type
        self.value = value
        self.span = span
    }
}

public struct TypeAliasDecl {
    public var name: String
    public var isPublic: Bool
    public var typeParams: [TypeParam]
    public var value: TypeExpr
    public var span: Span

    public init(name: String, isPublic: Bool = false, typeParams: [TypeParam] = [],
                value: TypeExpr, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.typeParams = typeParams
        self.value = value
        self.span = span
    }
}

// MARK: - Extern Blocks

public struct ExternBlockDecl {
    public var abi: String?
    public var items: [Item]
    public var span: Span

    public init(abi: String? = nil, items: [Item] = [], span: Span) {
        self.abi = abi
        self.items = items
        self.span = span
    }

    public init(abi: String? = nil, functions: [FunctionDecl], span: Span) {
        self.abi = abi
        self.items = functions.map { fn in
            Item(kind: .function(fn), span: fn.span)
        }
        self.span = span
    }

    public var functions: [FunctionDecl] {
        items.compactMap { item in
            if case .function(let fn) = item.kind { return fn }
            return nil
        }
    }
}

// MARK: - Modules

public struct ModuleDecl {
    public var name: String
    public var isPublic: Bool
    public var items: [Item]?  // nil means file-based module
    public var span: Span

    public init(name: String, isPublic: Bool = false, items: [Item]? = nil, span: Span) {
        self.name = name
        self.isPublic = isPublic
        self.items = items
        self.span = span
    }
}

// MARK: - Agentic Declarations (parsed but rejected)

public struct CapabilityDecl {
    public var name: String
    public var implies: [String]
    public var span: Span
}

public struct EffectDecl {
    public var name: String
    public var typeParams: [TypeParam]
    public var operations: [FunctionSig]
    public var span: Span
}

public struct RationaleDecl {
    public var fields: [(key: String, value: String)]
    public var span: Span
}

public struct MacroDecl {
    public var name: String
    public var params: [(name: String, type: String)]
    public var body: BlockBody
    public var span: Span
}

public struct EditionDecl {
    public var version: String
    public var items: [Item]?  // nil means bare edition decl
    public var span: Span
}

// MARK: - Attributes

public struct Attribute {
    public var name: String
    public var args: [AttributeArg]
    public var span: Span

    public init(name: String, args: [AttributeArg] = [], span: Span) {
        self.name = name
        self.args = args
        self.span = span
    }
}

public enum AttributeArg {
    case ident(String)
    case string(String)
    case int(String)
    case keyValue(String, String)
    case nested(String, [AttributeArg])
}

// MARK: - Type Expressions

public indirect enum TypeExpr {
    case named(String, typeArgs: [TypeExpr], Span)
    case assocBinding(String, TypeExpr, Span)
    case constExpr(Expr, Span)
    case never(Span)
    case tuple([TypeExpr], Span)
    case unit(Span)
    // NOTE (no first-class safe references): the parser NEVER produces this
    // case from general type positions anymore — `&T`/`&mut T` in parameter
    // position normalizes to the access convention, and `&T` in any other
    // type position fires the E106 migration diagnostic and recovers with
    // the inner type (the Tangerine parse mirror). The case is retained as
    // part of the seed's PRIVATE bootstrap dialect (the MIR refInternal
    // lowering path), not as user-language type syntax.
    case ref(TypeExpr, mutable: Bool, Span)
    case rawPtr(TypeExpr, mutable: Bool, Span)
    case fnPtr(params: [TypeExpr], ret: TypeExpr, Span)
    case array(TypeExpr, len: Expr?, Span)
    case slice(TypeExpr, Span)
    case selfType(Span)
    case dynTrait(TypeExpr, Span)
    case implTrait(TypeExpr, Span)
    case bounded(TypeExpr, bounds: [TypeExpr], Span)
    case option(TypeExpr, Span)  // T? sugar
    case inferred(Span)

    public var span: Span {
        switch self {
        case .named(_, _, let s), .assocBinding(_, _, let s), .constExpr(_, let s), .never(let s), .tuple(_, let s), .unit(let s),
             .ref(_, _, let s), .rawPtr(_, _, let s), .fnPtr(_, _, let s),
             .array(_, _, let s), .slice(_, let s), .selfType(let s),
             .dynTrait(_, let s), .implTrait(_, let s), .bounded(_, _, let s), .option(_, let s), .inferred(let s):
            return s
        }
    }
}

// MARK: - Expressions

public indirect enum MacroArg {
    case expr(Expr)
    case tokens(String, Span)

    public var span: Span {
        switch self {
        case .expr(let expr):
            return expr.span
        case .tokens(_, let span):
            return span
        }
    }
}

public indirect enum Expr {
    case intLit(String, Span)
    case floatLit(String, Span)
    case stringLit(String, Span)
    case charLit(Character, Span)
    case boolLit(Bool, Span)
    case name(String, Span)
    case path(String, String, Span)  // A::B
    case array([Expr], Span)
    case arrayRepeat(value: Expr, count: Expr, Span)
    case tuple([Expr], Span)
    case structLit(name: String, typeArgs: [TypeExpr], fields: [(String, Expr)], rest: Expr?, Span)
    case block(BlockBody, Span)
    case unsafeBlock(reason: String, body: BlockBody, Span)
    case ifExpr(IfExpr)
    case call(callee: Expr, typeArgs: [TypeExpr], args: [CallArg], Span)
    case index(base: Expr, index: Expr, Span)
    case range(start: Expr, end: Expr, inclusive: Bool, Span)
    case matchExpr(MatchExpr)
    case cast(expr: Expr, type: TypeExpr, Span)
    case tryOp(Expr, Span)  // expr?
    case closure(ClosureExpr)
    case unary(op: UnaryOp, expr: Expr, Span)
    case field(base: Expr, field: String, Span)
    case binary(left: Expr, op: BinaryOp, right: Expr, Span)
    case awaitExpr(Expr, Span)
    case macroCall(name: String, args: [MacroArg], Span)
    case assign(target: Expr, value: Expr, Span)
    case compoundAssign(target: Expr, op: BinaryOp, value: Expr, Span)
    case returnExpr(Expr?, Span)
    case breakExpr(Expr?, Span)
    case nextExpr(Span)
    case forExpr(ForExpr)
    case whileExpr(WhileExpr)
    case loopExpr(BlockBody, Span)
    case handleExpr(HandleExpr)
    case unlessExpr(UnlessExpr)
    case untilExpr(UntilExpr)
    case tryBlock(TryBlock)
    case comptimeBlock(BlockBody, Span)

    public var span: Span {
        switch self {
        case .intLit(_, let s), .floatLit(_, let s), .stringLit(_, let s),
             .charLit(_, let s), .boolLit(_, let s), .name(_, let s),
             .path(_, _, let s), .array(_, let s), .arrayRepeat(_, _, let s),
             .tuple(_, let s), .structLit(_, _, _, _, let s),
             .block(_, let s), .unsafeBlock(_, _, let s),
             .call(_, _, _, let s), .index(_, _, let s),
             .range(_, _, _, let s), .cast(_, _, let s),
             .tryOp(_, let s), .unary(_, _, let s),
             .field(_, _, let s), .binary(_, _, _, let s),
             .awaitExpr(_, let s), .macroCall(_, _, let s),
             .assign(_, _, let s), .compoundAssign(_, _, _, let s),
             .returnExpr(_, let s), .breakExpr(_, let s), .nextExpr(let s),
             .loopExpr(_, let s), .comptimeBlock(_, let s):
            return s
        case .ifExpr(let e):     return e.span
        case .matchExpr(let e):  return e.span
        case .closure(let e):    return e.span
        case .forExpr(let e):    return e.span
        case .whileExpr(let e):  return e.span
        case .handleExpr(let e): return e.span
        case .unlessExpr(let e): return e.span
        case .untilExpr(let e):  return e.span
        case .tryBlock(let e):   return e.span
        }
    }
}

public struct CallArg {
    public var label: String?
    public var value: Expr
    public var span: Span

    public init(label: String? = nil, value: Expr, span: Span) {
        self.label = label
        self.value = value
        self.span = span
    }
}

public enum BinaryOp: String {
    case or = "||"
    case and = "&&"
    case bitOr = "|"
    case bitXor = "^"
    case bitAnd = "&"
    case shl = "<<"
    case shr = ">>"
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
    case mod = "%"
    case eq = "=="
    case notEq = "!="
    case lt = "<"
    case ltEq = "<="
    case gt = ">"
    case gtEq = ">="
}

public enum UnaryOp {
    case not       // !
    case bitNot    // ~
    case neg       // -
    case deref     // *
    case borrow    // &
    case borrowMut // &mut
}

// MARK: - Block

public struct BlockBody {
    public var stmts: [Stmt]
    public var tailExpr: Expr?
    public var span: Span

    public init(stmts: [Stmt] = [], tailExpr: Expr? = nil, span: Span) {
        self.stmts = stmts
        self.tailExpr = tailExpr
        self.span = span
    }
}

// MARK: - Statements

public indirect enum Stmt {
    case letBinding(pattern: Pattern, mutable: Bool, type: TypeExpr?, value: Expr, Span)
    case exprStmt(Expr, Span)
    case attributeStmt([Attribute], Span)
    case attributed([Attribute], Stmt, Span)
    case deferStmt(BlockBody, Span)
    case item(Item)

    public var span: Span {
        switch self {
        case .letBinding(_, _, _, _, let s), .exprStmt(_, let s), .attributeStmt(_, let s), .attributed(_, _, let s), .deferStmt(_, let s):
            return s
        case .item(let item):
            return item.span
        }
    }
}

// MARK: - Control Flow Expressions

public struct IfExpr {
    public var condition: Expr
    public var thenBlock: BlockBody
    public var elsifClauses: [(condition: Expr, body: BlockBody)]
    public var elseBlock: BlockBody?
    public var ifLetPattern: Pattern?
    public var ifLetValue: Expr?
    /// if-let bindings carried by the elsif clauses (parallel to
    /// elsifClauses; a clause with an entry here is `elsif let P = V` —
    /// its synthesized condition is `true` and the pattern test IS the
    /// branch condition). Never dropped at the AST level.
    public var elsifLet: [(pattern: Pattern, value: Expr)]
    public var span: Span

    public init(condition: Expr, thenBlock: BlockBody,
                elsifClauses: [(condition: Expr, body: BlockBody)] = [],
                elseBlock: BlockBody? = nil,
                ifLetPattern: Pattern? = nil, ifLetValue: Expr? = nil,
                elsifLet: [(pattern: Pattern, value: Expr)] = [],
                span: Span) {
        self.condition = condition
        self.thenBlock = thenBlock
        self.elsifClauses = elsifClauses
        self.elseBlock = elseBlock
        self.ifLetPattern = ifLetPattern
        self.ifLetValue = ifLetValue
        self.elsifLet = elsifLet
        self.span = span
    }
}

public struct MatchExpr {
    public var subject: Expr
    public var arms: [MatchArm]
    public var span: Span

    public init(subject: Expr, arms: [MatchArm], span: Span) {
        self.subject = subject
        self.arms = arms
        self.span = span
    }
}

public struct MatchArm {
    public var pattern: Pattern
    public var guardExpr: Expr?
    public var body: Expr
    public var span: Span

    public init(pattern: Pattern, guardExpr: Expr? = nil, body: Expr, span: Span) {
        self.pattern = pattern
        self.guardExpr = guardExpr
        self.body = body
        self.span = span
    }
}

public struct ForExpr {
    public var pattern: Pattern
    public var iterable: Expr
    public var body: BlockBody
    public var span: Span

    public init(pattern: Pattern, iterable: Expr, body: BlockBody, span: Span) {
        self.pattern = pattern
        self.iterable = iterable
        self.body = body
        self.span = span
    }
}

public struct WhileExpr {
    public var condition: Expr
    public var body: BlockBody
    public var span: Span

    public init(condition: Expr, body: BlockBody, span: Span) {
        self.condition = condition
        self.body = body
        self.span = span
    }
}

public struct ClosureExpr {
    public var params: [ClosureParam]
    public var returnType: TypeExpr?
    public var body: Expr
    public var span: Span

    public init(params: [ClosureParam] = [], returnType: TypeExpr? = nil, body: Expr, span: Span) {
        self.params = params
        self.returnType = returnType
        self.body = body
        self.span = span
    }
}

public struct ClosureParam {
    public var name: String
    public var isMutable: Bool
    public var type: TypeExpr?
    public var span: Span
}

public struct HandleExpr {
    public var expr: Expr
    public var effectName: String
    public var arms: [(op: String, params: [Pattern], body: Expr)]
    public var span: Span
}

public struct UnlessExpr {
    public var condition: Expr
    public var body: BlockBody
    public var elseBlock: BlockBody?
    public var span: Span
}

public struct UntilExpr {
    public var condition: Expr
    public var body: BlockBody
    public var span: Span
}

public struct TryBlock {
    public var body: BlockBody
    public var catchClauses: [(pattern: Pattern, body: BlockBody)]
    public var finallyBlock: BlockBody?
    public var span: Span
}

// MARK: - Patterns

public indirect enum Pattern {
    case wildcard(Span)
    case ident(String, mutable: Bool, Span)
    case refPattern(String, Span)
    case refMutPattern(String, Span)
    case literal(Expr, Span)
    case variant(typeName: String, variantName: String, fields: [Pattern], Span)
    case structPattern(name: String, fields: [(String, Pattern?)], Span)
    case tuple([Pattern], Span)
    case orPattern(Pattern, Pattern, Span)
    case rangePattern(Pattern, Pattern, Span)

    public var span: Span {
        switch self {
        case .wildcard(let s), .ident(_, _, let s), .refPattern(_, let s),
             .refMutPattern(_, let s), .literal(_, let s), .variant(_, _, _, let s),
             .structPattern(_, _, let s), .tuple(_, let s),
             .orPattern(_, _, let s), .rangePattern(_, _, let s):
            return s
        }
    }
}
