// InterpreterStdlibValidation.swift — Stage 27: Interpreter-First Stdlib Validation
// Runs bootstrap stdlib modules under interpreter first, then compares vs native.
// Ensures stdlib behavior is known correct before trusting native execution.

// MARK: - InterpreterResult

/// Captures the result of running a module under the interpreter.
public struct InterpreterResult: Equatable, CustomStringConvertible {
    public let module: String
    public let output: String
    public let trace: [String]
    public let exitCode: Int
    public let divergence: DivergencePoint?

    public init(module: String, output: String, trace: [String] = [],
                exitCode: Int = 0, divergence: DivergencePoint? = nil) {
        self.module = module
        self.output = output
        self.trace = trace
        self.exitCode = exitCode
        self.divergence = divergence
    }

    public var description: String {
        let div = divergence.map { " DIVERGED at \($0)" } ?? ""
        return "[\(module)] exit=\(exitCode) output=\(output.prefix(80))\(div)"
    }
}

// MARK: - DivergencePoint

/// Identifies where interpreter and native execution diverge.
public struct DivergencePoint: Equatable, CustomStringConvertible {
    public let module: String
    public let symbol: String
    public let interpreterOutput: String
    public let nativeOutput: String
    public let traceIndex: Int?

    public init(module: String, symbol: String,
                interpreterOutput: String, nativeOutput: String,
                traceIndex: Int? = nil) {
        self.module = module
        self.symbol = symbol
        self.interpreterOutput = interpreterOutput
        self.nativeOutput = nativeOutput
        self.traceIndex = traceIndex
    }

    public var description: String {
        let idx = traceIndex.map { " (trace[\($0)])" } ?? ""
        return "\(module)::\(symbol)\(idx) interp='\(interpreterOutput)' native='\(nativeOutput)'"
    }

    /// Classify as likely downstream (native codegen) issue.
    public var isLikelyDownstream: Bool {
        // If interpreter produces output but native doesn't, likely codegen/lowering issue
        !interpreterOutput.isEmpty && nativeOutput.isEmpty
    }
}

// MARK: - StdlibValidationStatus

/// Per-module validation status.
public enum StdlibValidationStatus: String, Equatable, CaseIterable {
    case notRun         = "not-run"
    case interpreterPass = "interpreter-pass"
    case interpreterFail = "interpreter-fail"
    case nativePass     = "native-pass"
    case nativeFail     = "native-fail"
    case bothPass       = "both-pass"
    case diverged       = "diverged"
}

// MARK: - ModuleValidationRecord

/// Records validation results for a single stdlib module.
public struct ModuleValidationRecord: Equatable {
    public let module: String
    public var status: StdlibValidationStatus
    public var interpreterResult: InterpreterResult?
    public var nativeResult: InterpreterResult?
    public var divergence: DivergencePoint?

    public init(module: String, status: StdlibValidationStatus = .notRun) {
        self.module = module
        self.status = status
        self.interpreterResult = nil
        self.nativeResult = nil
        self.divergence = nil
    }
}

// MARK: - InterpreterStdlibValidator

/// Orchestrates interpreter-first validation for bootstrap stdlib modules.
public final class InterpreterStdlibValidator {
    private var records: [String: ModuleValidationRecord] = [:]

    public init() {}

    /// Register a module for validation.
    public func register(module: String) {
        if records[module] == nil {
            records[module] = ModuleValidationRecord(module: module)
        }
    }

    /// Record interpreter result for a module.
    public func recordInterpreterResult(_ result: InterpreterResult) {
        register(module: result.module)
        records[result.module]?.interpreterResult = result
        if result.exitCode == 0 {
            records[result.module]?.status = .interpreterPass
        } else {
            records[result.module]?.status = .interpreterFail
        }
    }

    /// Record native result for a module.
    public func recordNativeResult(_ result: InterpreterResult) {
        register(module: result.module)
        records[result.module]?.nativeResult = result
        // Update status based on comparison
        guard let interp = records[result.module]?.interpreterResult else {
            if result.exitCode == 0 {
                records[result.module]?.status = .nativePass
            } else {
                records[result.module]?.status = .nativeFail
            }
            return
        }
        if interp.exitCode == 0 && result.exitCode == 0 {
            if interp.output == result.output {
                records[result.module]?.status = .bothPass
            } else {
                let div = DivergencePoint(
                    module: result.module, symbol: "main",
                    interpreterOutput: interp.output,
                    nativeOutput: result.output)
                records[result.module]?.divergence = div
                records[result.module]?.status = .diverged
            }
        } else if interp.exitCode == 0 {
            records[result.module]?.status = .nativeFail
        } else {
            records[result.module]?.status = .interpreterFail
        }
    }

    /// Record a divergence.
    public func recordDivergence(_ divergence: DivergencePoint) {
        register(module: divergence.module)
        records[divergence.module]?.divergence = divergence
        records[divergence.module]?.status = .diverged
    }

    /// All records sorted by module name.
    public var allRecords: [ModuleValidationRecord] {
        records.values.sorted(by: { $0.module < $1.module })
    }

    /// Get record for a module.
    public func record(for module: String) -> ModuleValidationRecord? {
        records[module]
    }

    /// Modules that passed both interpreter and native.
    public var greenModules: [String] {
        allRecords.filter { $0.status == .bothPass }.map(\.module)
    }

    /// Modules that diverged.
    public var divergedModules: [String] {
        allRecords.filter { $0.status == .diverged }.map(\.module)
    }

    /// Modules not yet run.
    public var notRunModules: [String] {
        allRecords.filter { $0.status == .notRun }.map(\.module)
    }

    /// Modules that passed interpreter but not yet native.
    public var interpreterOnlyPass: [String] {
        allRecords.filter { $0.status == .interpreterPass }.map(\.module)
    }

    /// Can a module be marked green? Only if bothPass.
    public func canMarkGreen(_ module: String) -> Bool {
        records[module]?.status == .bothPass
    }

    /// All divergence points.
    public var allDivergences: [DivergencePoint] {
        allRecords.compactMap(\.divergence)
    }

    /// Minimize divergence — creates a reduced divergence focusing on first difference.
    public func minimizeDivergence(for module: String) -> DivergencePoint? {
        guard let div = records[module]?.divergence else { return nil }
        // Find first character where outputs differ
        let interp = Array(div.interpreterOutput)
        let native = Array(div.nativeOutput)
        var firstDiffIdx = 0
        while firstDiffIdx < min(interp.count, native.count) &&
              interp[firstDiffIdx] == native[firstDiffIdx] {
            firstDiffIdx += 1
        }
        let contextStart = max(0, firstDiffIdx - 10)
        let contextEnd = min(max(interp.count, native.count), firstDiffIdx + 10)
        let interpSlice = String(interp[contextStart..<min(contextEnd, interp.count)])
        let nativeSlice = String(native[contextStart..<min(contextEnd, native.count)])
        return DivergencePoint(
            module: div.module, symbol: div.symbol,
            interpreterOutput: interpSlice,
            nativeOutput: nativeSlice,
            traceIndex: firstDiffIdx)
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Interpreter Stdlib Validation Report ==="]
        lines.append("Total modules: \(records.count)")
        for s in StdlibValidationStatus.allCases {
            let count = allRecords.filter { $0.status == s }.count
            if count > 0 { lines.append("  \(s.rawValue): \(count)") }
        }
        lines.append("Green (both-pass): \(greenModules.count)")
        lines.append("Diverged: \(divergedModules.count)")
        if !allDivergences.isEmpty {
            lines.append("Divergence details:")
            for d in allDivergences {
                lines.append("  \(d)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
