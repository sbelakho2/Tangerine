// VerifiedForms.swift — Stage 16: Verified form wrappers and builders
// Separates unverified from verified IR, enforces construction via builders,
// and makes invalid states harder to represent.

// MARK: - Verified/Unverified wrappers

/// Wrapper for IR that has not yet been verified. Must go through FormVerifier.
public struct Unverified<T> {
    public let inner: T
    public init(_ value: T) { self.inner = value }
}

/// Wrapper for IR that has passed verification. Cannot be constructed directly
/// outside this module — only FormVerifier can produce Verified values.
public struct Verified<T> {
    public let inner: T
    internal init(_ value: T) { self.inner = value }
}

// MARK: - Builder errors

public enum BuilderError: Error, CustomStringConvertible, Equatable {
    case missingEntryBlock
    case missingTerminator(blockId: Int)
    case duplicateBlockId(Int)
    case duplicateLocalId(Int)
    case emptyFunction(name: String)
    case invalidReturnType
    case missingReturnLocal
    case orphanBlock(blockId: Int)
    case blockNotFound(Int)
    case noBlocksDefined

    public var description: String {
        switch self {
        case .missingEntryBlock: return "E16001: function has no entry block"
        case .missingTerminator(let id): return "E16002: block \(id) has no terminator"
        case .duplicateBlockId(let id): return "E16003: duplicate block id \(id)"
        case .duplicateLocalId(let id): return "E16004: duplicate local id \(id)"
        case .emptyFunction(let n): return "E16005: function '\(n)' has no blocks"
        case .invalidReturnType: return "E16006: return type mismatch"
        case .missingReturnLocal: return "E16007: no return local (_return) defined"
        case .orphanBlock(let id): return "E16008: block \(id) is unreachable from entry"
        case .blockNotFound(let id): return "E16009: block \(id) not found"
        case .noBlocksDefined: return "E16010: no blocks defined in function"
        }
    }
}

// MARK: - MirFunctionBuilder

public final class MirFunctionBuilder {
    public let name: String
    public let returnType: MirType
    private var params: [MirLocal] = []
    private var locals: [MirLocal] = []
    private var blocks: [Int: (statements: [MirStatement], terminator: MirTerminator?)] = [:]
    private var blockOrder: [Int] = []
    private var nextLocalId: Int = 0
    private var nextBlockId: Int = 0
    private var entryBlock: Int = -1

    public init(name: String, returnType: MirType) {
        self.name = name
        self.returnType = returnType
        // Automatically create return local
        let retLocal = MirLocal(id: nextLocalId, name: "_return", type: returnType, isMutable: true)
        locals.append(retLocal)
        nextLocalId += 1
    }

    @discardableResult
    public func addParam(name: String, type: MirType) -> Int {
        let id = nextLocalId
        params.append(MirLocal(id: id, name: name, type: type, isMutable: false))
        nextLocalId += 1
        return id
    }

    @discardableResult
    public func addLocal(name: String? = nil, type: MirType, mutable: Bool = false) -> Int {
        let id = nextLocalId
        locals.append(MirLocal(id: id, name: name, type: type, isMutable: mutable))
        nextLocalId += 1
        return id
    }

    @discardableResult
    public func addBlock() -> Int {
        let id = nextBlockId
        blocks[id] = (statements: [], terminator: nil)
        blockOrder.append(id)
        if entryBlock == -1 { entryBlock = id }
        nextBlockId += 1
        return id
    }

    public func emit(in blockId: Int, _ stmt: MirStatement) {
        guard blocks[blockId] != nil else { return }
        blocks[blockId]!.statements.append(stmt)
    }

    public func terminate(_ blockId: Int, _ term: MirTerminator) {
        guard blocks[blockId] != nil else { return }
        blocks[blockId]!.terminator = term
    }

    public func build() -> Result<Unverified<MirFunction>, VerificationErrors> {
        var errors: [BuilderError] = []

        if blocks.isEmpty {
            errors.append(.emptyFunction(name: name))
            return .failure(VerificationErrors(errors))
        }

        if entryBlock < 0 || blocks[entryBlock] == nil {
            errors.append(.missingEntryBlock)
        }

        // Check all blocks have terminators
        for id in blockOrder {
            if blocks[id]?.terminator == nil {
                errors.append(.missingTerminator(blockId: id))
            }
        }

        if !errors.isEmpty { return .failure(VerificationErrors(errors)) }

        let mirBlocks = blockOrder.map { id -> MirBlock in
            let b = blocks[id]!
            return MirBlock(id: id, statements: b.statements, terminator: b.terminator ?? .unreachable)
        }

        let fn = MirFunction(
            name: name,
            params: params,
            returnType: returnType,
            locals: locals,
            blocks: mirBlocks,
            entryBlock: entryBlock
        )
        return .success(Unverified(fn))
    }
}

// MARK: - MirProgramBuilder

public final class MirProgramBuilder {
    private var functions: [MirFunction] = []
    private var statics: [MirStatic] = []
    private var typeDefs: [MirTypeDef] = []

    public init() {}

    public func addFunction(_ fn: MirFunction) {
        functions.append(fn)
    }

    public func addStatic(_ s: MirStatic) {
        statics.append(s)
    }

    public func addTypeDef(_ td: MirTypeDef) {
        typeDefs.append(td)
    }

    public func build() -> Unverified<MirProgram> {
        Unverified(MirProgram(functions: functions, statics: statics, typeDefs: typeDefs))
    }
}

// MARK: - VerificationErrors

public struct VerificationErrors: Error, CustomStringConvertible {
    public let errors: [BuilderError]
    public init(_ errors: [BuilderError]) { self.errors = errors }
    public var description: String { errors.map { $0.description }.joined(separator: "; ") }
}

// MARK: - FormVerifier

public enum FormVerifier {
    /// Verify a function: check structural invariants.
    public static func verify(_ fn: Unverified<MirFunction>) -> Result<Verified<MirFunction>, VerificationErrors> {
        var errors: [BuilderError] = []
        let f = fn.inner

        if f.blocks.isEmpty {
            errors.append(.emptyFunction(name: f.name))
            return .failure(VerificationErrors(errors))
        }

        // Check entry block exists
        let blockIds = Set(f.blocks.map { $0.id })
        if !blockIds.contains(f.entryBlock) {
            errors.append(.missingEntryBlock)
        }

        // Check for duplicate block ids
        var seenBlocks = Set<Int>()
        for b in f.blocks {
            if !seenBlocks.insert(b.id).inserted {
                errors.append(.duplicateBlockId(b.id))
            }
        }

        // Check for duplicate local ids
        var seenLocals = Set<Int>()
        for l in f.locals {
            if !seenLocals.insert(l.id).inserted {
                errors.append(.duplicateLocalId(l.id))
            }
        }
        for p in f.params {
            if !seenLocals.insert(p.id).inserted {
                errors.append(.duplicateLocalId(p.id))
            }
        }

        // Check return local exists (local 0 named _return by convention)
        let hasReturn = f.locals.contains(where: { $0.name == "_return" })
        if !hasReturn {
            errors.append(.missingReturnLocal)
        }

        // Check reachability from entry block
        if blockIds.contains(f.entryBlock) {
            var reachable = Set<Int>()
            var worklist = [f.entryBlock]
            while let current = worklist.popLast() {
                guard reachable.insert(current).inserted else { continue }
                // Find successors
                if let block = f.blocks.first(where: { $0.id == current }) {
                    for succ in terminatorSuccessors(block.terminator) {
                        if blockIds.contains(succ) {
                            worklist.append(succ)
                        }
                    }
                }
            }
            for b in f.blocks where !reachable.contains(b.id) {
                errors.append(.orphanBlock(blockId: b.id))
            }
        }

        if errors.isEmpty {
            return .success(Verified(f))
        }
        return .failure(VerificationErrors(errors))
    }

    /// Verify a whole program: verify each function.
    public static func verify(_ prog: Unverified<MirProgram>) -> Result<Verified<MirProgram>, VerificationErrors> {
        var errors: [BuilderError] = []
        for fn in prog.inner.functions {
            let result = verify(Unverified(fn))
            if case .failure(let fnErrors) = result {
                errors.append(contentsOf: fnErrors.errors)
            }
        }
        if errors.isEmpty {
            return .success(Verified(prog.inner))
        }
        return .failure(VerificationErrors(errors))
    }

    /// Extract successor block ids from a terminator.
    private static func terminatorSuccessors(_ term: MirTerminator) -> [Int] {
        switch term {
        case .goto(let b): return [b]
        case .ret: return []
        case .switchInt(_, let targets, let otherwise):
            return targets.map { $0.1 } + [otherwise]
        case .call(_, _, _, _, let next, let unwind):
            var s = [next]
            if let u = unwind { s.append(u) }
            return s
        case .drop(_, let next, let unwind):
            var s = [next]
            if let u = unwind { s.append(u) }
            return s
        case .`deinit`(_, let next, let unwind):
            var s = [next]
            if let u = unwind { s.append(u) }
            return s
        case .assert(_, _, _, let target): return [target]
        case .yield(_, let resume): return [resume]
        case .unreachable, .abort: return []
        }
    }

    /// Audit: check that no raw MirFunction constructors are used outside builders.
    /// Returns a list of violation descriptions for reporting.
    public static func auditRawConstruction(fileContents: [(name: String, content: String)]) -> [String] {
        var violations: [String] = []
        let approved = Set(["MirFunctionBuilder", "MirProgramBuilder",
                            "VerifiedForms.swift", "MIRLowering.swift", "MIR.swift",
                            "TangerineTestRunner"])
        for (name, content) in fileContents {
            let isApproved = approved.contains(where: { name.contains($0) })
            if isApproved { continue }
            // Check for raw MirFunction(...) construction
            if content.contains("MirFunction(") {
                violations.append("\(name): raw MirFunction construction outside builder")
            }
            if content.contains("MirBlock(") {
                violations.append("\(name): raw MirBlock construction outside builder")
            }
        }
        return violations
    }
}
