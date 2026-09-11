// LayerManifest.swift — Documents the compiler's layer partitioning (Stage 10).
// Each layer is independently testable. Dependencies are acyclic.

/// A compiler layer with its files and dependencies.
public struct CompilerLayer: Equatable {
    public let id: String
    public let name: String
    public let files: [String]
    public let dependencies: [String]  // IDs of layers this depends on

    public init(id: String, name: String, files: [String], dependencies: [String]) {
        self.id = id
        self.name = name
        self.files = files
        self.dependencies = dependencies
    }
}

/// The complete layer manifest for the stage0 bootstrap compiler.
public struct LayerManifest {
    public static let layers: [CompilerLayer] = [
        CompilerLayer(
            id: "L0-CORE",
            name: "Core Infrastructure",
            files: ["Span.swift", "Token.swift", "Diagnostic.swift"],
            dependencies: []  // No dependencies — leaf layer
        ),
        CompilerLayer(
            id: "L1-PARSE",
            name: "Lexical & Parsing",
            files: ["Lexer.swift", "AST.swift", "Parser.swift"],
            dependencies: ["L0-CORE"]
        ),
        CompilerLayer(
            id: "L2-VERIFY",
            name: "AST Verification & Subset Checking",
            files: ["ASTVerifier.swift", "SubsetChecker.swift"],
            dependencies: ["L0-CORE", "L1-PARSE"]
        ),
        CompilerLayer(
            id: "L3-IR",
            name: "Canonical IR & Lowering",
            files: ["MIR.swift", "MIRLowering.swift", "ASTDumper.swift"],
            dependencies: ["L0-CORE", "L1-PARSE"]
        ),
        CompilerLayer(
            id: "L4-EXEC",
            name: "Execution (Interpreter)",
            files: ["MIRInterpreter.swift"],
            dependencies: ["L3-IR"]
        ),
        CompilerLayer(
            id: "L5-DRIVER",
            name: "Driver & Pass Management",
            files: ["PassManager.swift", "StdlibDependencyMap.swift", "BootstrapProfile.swift", "FailureClassification.swift", "FailureClustering.swift", "Reducers.swift", "VerifiedForms.swift", "SilentFallbackGuard.swift", "StableIDs.swift", "GoldenPhaseTests.swift", "DifferentialTesting.swift", "MutationTesting.swift", "PassBisection.swift", "ResourceAccounting.swift", "CompilerCanary.swift", "StdlibStabilization.swift"],
            dependencies: ["L0-CORE"]
        ),
    ]

    /// Returns true if the dependency graph is acyclic.
    public static var isAcyclic: Bool {
        let layerMap = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        // Simple DFS cycle detection
        var visited = Set<String>()
        var inStack = Set<String>()

        func dfs(_ id: String) -> Bool {
            if inStack.contains(id) { return false } // cycle
            if visited.contains(id) { return true }
            visited.insert(id)
            inStack.insert(id)
            if let layer = layerMap[id] {
                for dep in layer.dependencies {
                    if !dfs(dep) { return false }
                }
            }
            inStack.remove(id)
            return true
        }

        for layer in layers {
            if !dfs(layer.id) { return false }
        }
        return true
    }

    /// Returns the topological order of layers (dependencies first).
    public static var topologicalOrder: [String] {
        let layerMap = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        var visited = Set<String>()
        var order: [String] = []

        func visit(_ id: String) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            if let layer = layerMap[id] {
                for dep in layer.dependencies {
                    visit(dep)
                }
            }
            order.append(id)
        }

        for layer in layers { visit(layer.id) }
        return order
    }

    /// All files across all layers.
    public static var allFiles: [String] {
        layers.flatMap(\.files)
    }

    /// Which layers are in the current stabilization ring (all of them in stage0).
    public static var stabilizationRing: [String] {
        layers.map(\.id)
    }

    /// Returns the layer manifest as a readable string.
    public static var manifest: String {
        var out = "Compiler Layer Manifest (stage0 bootstrap)\n"
        out += "============================================\n\n"
        for layer in layers {
            out += "\(layer.id): \(layer.name)\n"
            out += "  Files: \(layer.files.joined(separator: ", "))\n"
            if layer.dependencies.isEmpty {
                out += "  Dependencies: (none — leaf)\n"
            } else {
                out += "  Dependencies: \(layer.dependencies.joined(separator: ", "))\n"
            }
            out += "\n"
        }
        out += "Dependency graph is acyclic: \(isAcyclic)\n"
        out += "Topological order: \(topologicalOrder.joined(separator: " → "))\n"
        out += "Stabilization ring: \(stabilizationRing.joined(separator: ", "))\n"
        return out
    }
}
