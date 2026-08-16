// MIR.swift — Mid-level Intermediate Representation data structures
// Matches the canonical IR spec in docs/canonical_ir_spec.md

// MARK: - IDs

public typealias BlockId = Int
public typealias LocalId = Int

// MARK: - Top-level

public struct MirProgram {
    public var functions: [MirFunction]
    public var statics: [MirStatic]
    public var typeDefs: [MirTypeDef]
    public init(functions: [MirFunction] = [], statics: [MirStatic] = [], typeDefs: [MirTypeDef] = []) {
        self.functions = functions; self.statics = statics; self.typeDefs = typeDefs
    }
}

public struct MirStatic {
    public let name: String
    public let type: MirType
    public let initializer: MirConstant?
    public let isMutable: Bool
    public init(name: String, type: MirType, initializer: MirConstant?, isMutable: Bool) {
        self.name = name; self.type = type; self.initializer = initializer; self.isMutable = isMutable
    }
}

public struct MirTypeDef {
    public let name: String
    public let kind: MirTypeDefKind
    public init(name: String, kind: MirTypeDefKind) {
        self.name = name; self.kind = kind
    }
}

public enum MirTypeDefKind {
    case structDef(fields: [(String, MirType)])
    case enumDef(variants: [(String, [MirType])])
}

// MARK: - Function

public struct MirFunction {
    public var name: String
    public var params: [MirLocal]
    public var returnType: MirType
    public var locals: [MirLocal]
    public var blocks: [MirBlock]
    public var entryBlock: BlockId
    public let isAsync: Bool
    public let isUnsafe: Bool
    public let isExtern: Bool

    public init(name: String, params: [MirLocal] = [], returnType: MirType = .unit,
                locals: [MirLocal] = [], blocks: [MirBlock] = [], entryBlock: BlockId = 0,
                isAsync: Bool = false, isUnsafe: Bool = false, isExtern: Bool = false) {
        self.name = name; self.params = params; self.returnType = returnType
        self.locals = locals; self.blocks = blocks; self.entryBlock = entryBlock
        self.isAsync = isAsync; self.isUnsafe = isUnsafe; self.isExtern = isExtern
    }
}

public struct MirLocal {
    public let id: LocalId
    public let name: String?
    public let type: MirType
    public let isMutable: Bool
    public init(id: LocalId, name: String? = nil, type: MirType = .unknown, isMutable: Bool = false) {
        self.id = id; self.name = name; self.type = type; self.isMutable = isMutable
    }
}

// MARK: - Basic Block

public struct MirBlock {
    public let id: BlockId
    public var statements: [MirStatement]
    public var terminator: MirTerminator
    public init(id: BlockId, statements: [MirStatement] = [], terminator: MirTerminator = .unreachable) {
        self.id = id; self.statements = statements; self.terminator = terminator
    }
}

// MARK: - Statement

public enum MirStatement {
    case assign(MirPlace, MirRvalue)
    case storageLive(LocalId)
    case storageDead(LocalId)
    case setDiscriminant(MirPlace, Int)
    case nop
}

// MARK: - Terminator

public enum MirTerminator {
    case goto(BlockId)
    case ret
    case switchInt(MirOperand, targets: [(Int, BlockId)], otherwise: BlockId)
    case call(dest: MirPlace, callee: MirOperand, args: [MirCallArg], next: BlockId, unwind: BlockId?)
    case drop(MirPlace, next: BlockId, unwind: BlockId?)
    case `deinit`(MirPlace, next: BlockId, unwind: BlockId?)
    case assert(MirOperand, expected: Bool, message: String, target: BlockId)
    case yield(MirOperand, resume: BlockId)
    case unreachable
    case abort
}

// MARK: - Access Effect

public enum AccessEffect {
    case read
    case modify
    case consume
    case initialize
}

// MARK: - Place & Projection

public struct MirPlace {
    public let local: LocalId
    public let projections: [MirProjection]
    public init(local: LocalId, projections: [MirProjection] = []) {
        self.local = local; self.projections = projections
    }
    public static func local(_ id: LocalId) -> MirPlace { MirPlace(local: id) }
}

public enum MirProjection {
    case deref
    case field(Int)
    case namedField(String)
    case index(LocalId)
    case constantIndex(Int)
    case downcast(Int)
}

// MARK: - Operand

public enum MirOperand {
    case copy(MirPlace)
    case move(MirPlace)
    case read(MirPlace)
    case consume(MirPlace)
    case constant(MirConstant)
}

// MARK: - Call Argument

public enum MirCallValue {
    case value(MirOperand)
    case place(MirPlace)
}

public struct MirCallArg {
    public var effect: AccessEffect
    public var value: MirCallValue
    public init(effect: AccessEffect, value: MirCallValue) {
        self.effect = effect
        self.value = value
    }
}

// MARK: - Constant

public enum MirConstant {
    case unit
    case bool(Bool)
    case int(Int)
    case float(Double)
    case char(Character)
    case str(String)
    case fnItem(String)
    case zeroSized
}

// MARK: - Rvalue

public enum MirRvalue {
    case use(MirOperand)
    case ref(BorrowKind, MirPlace)
    case aggregate(AggregateKind, [MirOperand])
    case binaryOp(MirBinOp, MirOperand, MirOperand)
    case unaryOp(MirUnOp, MirOperand)
    case discriminant(MirPlace)
    case len(MirPlace)
    case cast(MirOperand, MirType)
}

public enum BorrowKind { case shared, mutable }

public enum AggregateKind {
    case tuple
    case array
    case structCtor(String, [String]) // type name, field names
    case enumCtor(String, Int) // type name, variant index
    case closure(String)
}

public enum MirBinOp {
    case add, sub, mul, div, rem
    case eq, ne, lt, le, gt, ge
    case and, or
    case bitAnd, bitOr, bitXor, shl, shr
}

public enum MirUnOp {
    case neg, not
}

// MARK: - Type

public indirect enum MirType: Equatable {
    case unit
    case bool
    case int
    case float
    case char
    case string
    case named(String)
    case ref(MirType, mutable: Bool)
    case rawPtr(MirType)
    case array(MirType, Int?)
    case slice(MirType)
    case tuple([MirType])
    case fn([MirType], MirType)
    case unknown
}
