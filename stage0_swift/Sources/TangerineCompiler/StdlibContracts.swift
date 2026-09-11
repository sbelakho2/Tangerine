// StdlibContracts.swift — Stage 26: Semantic contracts for stdlib modules
// Documents invariants, allocation expectations, panic behavior per module.

// MARK: - StdlibContractKind

public enum StdlibContractKind: String, CaseIterable, Equatable, Hashable {
    case invariant    = "invariant"
    case allocation   = "allocation"
    case panicBehavior = "panic-behavior"
    case featureDep   = "feature-dependency"
    case noHiddenDep  = "no-hidden-dependency"
}

// MARK: - Contract

public struct StdlibContract: Equatable, CustomStringConvertible {
    public let module: String
    public let kind: StdlibContractKind
    public let statement: String
    public let hasCounterexampleTest: Bool

    public init(module: String, kind: StdlibContractKind, statement: String,
                hasCounterexampleTest: Bool = false) {
        self.module = module
        self.kind = kind
        self.statement = statement
        self.hasCounterexampleTest = hasCounterexampleTest
    }

    public var description: String {
        let tested = hasCounterexampleTest ? "TESTED" : "UNTESTED"
        return "[\(kind.rawValue)] \(module): \(statement) [\(tested)]"
    }
}

// MARK: - ContractRegistry

public final class ContractRegistry {
    private var contracts: [StdlibContract] = []

    public init() {}

    public func add(_ contract: StdlibContract) {
        contracts.append(contract)
    }

    public var all: [StdlibContract] { contracts }

    public func contracts(for module: String) -> [StdlibContract] {
        contracts.filter { $0.module == module }
    }

    public func contracts(kind: StdlibContractKind) -> [StdlibContract] {
        contracts.filter { $0.kind == kind }
    }

    public var untestedContracts: [StdlibContract] {
        contracts.filter { !$0.hasCounterexampleTest }
    }

    public var coveredModules: Set<String> {
        Set(contracts.map { $0.module })
    }

    /// Check no hidden dependencies on unstable features.
    public var hiddenDependencyViolations: [StdlibContract] {
        contracts.filter { $0.kind == .featureDep && $0.statement.contains("unstable") }
    }

    public func report() -> String {
        var lines = ["=== Stdlib Contract Report ==="]
        lines.append("Total contracts: \(contracts.count)")
        lines.append("Modules covered: \(coveredModules.count)")
        lines.append("Untested: \(untestedContracts.count)")
        for kind in StdlibContractKind.allCases {
            let kc = contracts(kind: kind)
            if !kc.isEmpty { lines.append("  \(kind.rawValue): \(kc.count)") }
        }
        return lines.joined(separator: "\n")
    }
}
