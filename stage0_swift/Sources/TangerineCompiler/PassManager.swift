// PassManager.swift — Manages the compiler pass pipeline and modes (Stage 9).
// In the bootstrap stage0, there are zero optimization passes.
// This module explicitly documents the pass set and provides a correctness mode.

/// Describes a single compiler pass.
public struct PassInfo: Equatable {
    public let id: String          // Stable pass identifier
    public let name: String        // Human-readable name
    public let stage: CompilerStage
    public let isOptimization: Bool
    public let isRequired: Bool    // Required even in correctness mode

    public init(id: String, name: String, stage: CompilerStage,
                isOptimization: Bool, isRequired: Bool) {
        self.id = id
        self.name = name
        self.stage = stage
        self.isOptimization = isOptimization
        self.isRequired = isRequired
    }
}

/// Compiler execution mode.
public enum CompilerMode: String {
    case correctness  // Maximal checks, zero optimizations, all verifiers enabled
    case normal       // Standard pipeline (currently same as correctness in stage0)
    case performance  // Optimizations enabled (future — currently same as correctness)
}

/// Manages the set of compiler passes, their ordering, and mode-dependent filtering.
public final class PassManager {
    /// The full manifest of all known passes.
    public static let allPasses: [PassInfo] = [
        // Required pipeline passes (non-optimization)
        PassInfo(id: "PASS-LEX-001", name: "Lexical Analysis",
                 stage: .lexer, isOptimization: false, isRequired: true),
        PassInfo(id: "PASS-PARSE-001", name: "Parsing",
                 stage: .parser, isOptimization: false, isRequired: true),
        PassInfo(id: "PASS-VERIFY-001", name: "AST Verification",
                 stage: .verifier, isOptimization: false, isRequired: true),
        PassInfo(id: "PASS-SUBSET-001", name: "Subset Checking",
                 stage: .subsetChecker, isOptimization: false, isRequired: true),
        PassInfo(id: "PASS-LOWER-001", name: "AST to MIR Lowering",
                 stage: .lowering, isOptimization: false, isRequired: true),
        PassInfo(id: "PASS-INTERP-001", name: "MIR Interpretation",
                 stage: .codegen, isOptimization: false, isRequired: false),
    ]

    /// The current compiler mode.
    public let mode: CompilerMode

    public init(mode: CompilerMode = .correctness) {
        self.mode = mode
    }

    /// Returns the passes enabled for the current mode.
    public var enabledPasses: [PassInfo] {
        switch mode {
        case .correctness:
            // All required passes, zero optimization passes
            return Self.allPasses.filter { $0.isRequired || !$0.isOptimization }
        case .normal:
            // In stage0, same as correctness
            return Self.allPasses.filter { $0.isRequired || !$0.isOptimization }
        case .performance:
            // In stage0, same as correctness (no optimizer exists)
            return Self.allPasses.filter { $0.isRequired || !$0.isOptimization }
        }
    }

    /// Returns optimization passes (should be empty in stage0).
    public var optimizationPasses: [PassInfo] {
        return Self.allPasses.filter { $0.isOptimization }
    }

    /// Returns the pass manifest as a stable, deterministic string.
    public var manifest: String {
        var out = "Pass Manifest (mode: \(mode.rawValue))\n"
        out += "================================================\n"
        for pass in enabledPasses {
            let reqStr = pass.isRequired ? "[REQUIRED]" : "[OPTIONAL]"
            let optStr = pass.isOptimization ? "[OPT]" : "[CORE]"
            out += "\(pass.id)  \(pass.name)  \(optStr) \(reqStr)\n"
        }
        out += "================================================\n"
        out += "Total: \(enabledPasses.count) enabled, "
        out += "\(optimizationPasses.count) optimization (disabled in stage0)\n"
        return out
    }

    /// FNV-1a hash of the pass manifest for change detection.
    public var manifestHash: UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in manifest.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}
