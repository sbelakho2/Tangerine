// DifferentialTesting.swift — Stage 20: Differential stage testing
// Compares multiple independent views to agree on the stabilized subset.

// MARK: - Differential Result

/// Outcome of comparing two execution modes.
public struct DifferentialResult: Equatable, CustomStringConvertible {
    public let caseId: String
    public let mode1: String
    public let mode2: String
    public let mode1Output: String
    public let mode2Output: String
    public let divergent: Bool
    public let firstDivergentStage: String?
    public let artifactHash1: UInt64
    public let artifactHash2: UInt64

    public init(caseId: String, mode1: String, mode2: String,
                mode1Output: String, mode2Output: String,
                firstDivergentStage: String? = nil) {
        self.caseId = caseId
        self.mode1 = mode1
        self.mode2 = mode2
        self.mode1Output = mode1Output
        self.mode2Output = mode2Output
        self.divergent = mode1Output != mode2Output
        self.firstDivergentStage = divergent ? firstDivergentStage : nil
        self.artifactHash1 = GoldenCorpus.fnv1a(mode1Output)
        self.artifactHash2 = GoldenCorpus.fnv1a(mode2Output)
    }

    public var description: String {
        if divergent {
            return "\(caseId): DIVERGENT (\(mode1) vs \(mode2)) at \(firstDivergentStage ?? "unknown")"
        }
        return "\(caseId): MATCH (\(mode1) vs \(mode2))"
    }
}

// MARK: - Metamorphic Transforms

/// Semantic-preserving source transformations.
public enum MetamorphicTransform: String, CaseIterable {
    case addComments     = "add-comments"
    case reformat        = "reformat"
    case renameLocals    = "rename-locals"
    case reorderFunctions = "reorder-functions"

    /// Apply the transform to source. Returns transformed source.
    public func apply(to source: String) -> String {
        switch self {
        case .addComments:
            return source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "# comment\n\($0)" }
                .joined(separator: "\n")
        case .reformat:
            // Normalize whitespace: collapse multiple spaces, trim lines
            return source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        case .renameLocals:
            // Prefix all single-letter variables with _r_
            var result = source
            for c in "abcdefghijklmnopqrstuvwxyz" {
                result = result.replacingOccurrences(of: " \(c):", with: " _r_\(c):")
                result = result.replacingOccurrences(of: " \(c) ", with: " _r_\(c) ")
            }
            return result
        case .reorderFunctions:
            // Reverse top-level blocks (simplified)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.reversed().joined(separator: "\n")
        }
    }
}

// MARK: - DifferentialEngine

/// Runs differential comparisons across modes.
public final class DifferentialEngine {
    private var results: [DifferentialResult] = []

    public init() {}

    /// Compare two mode outputs for a test case.
    public func compare(caseId: String, mode1: String, mode1Output: String,
                        mode2: String, mode2Output: String,
                        firstDivergentStage: String? = nil) {
        let result = DifferentialResult(
            caseId: caseId, mode1: mode1, mode2: mode2,
            mode1Output: mode1Output, mode2Output: mode2Output,
            firstDivergentStage: firstDivergentStage)
        results.append(result)
    }

    /// All divergent results.
    public var divergences: [DifferentialResult] {
        results.filter { $0.divergent }
    }

    /// All matching results.
    public var matches: [DifferentialResult] {
        results.filter { !$0.divergent }
    }

    /// True if no divergences.
    public var allMatch: Bool { divergences.isEmpty }

    /// Total comparisons.
    public var totalComparisons: Int { results.count }

    /// Report.
    public func report() -> String {
        var lines = ["=== Differential Test Report ==="]
        lines.append("Total: \(results.count), Matches: \(matches.count), Divergent: \(divergences.count)")
        for d in divergences {
            lines.append("  DIVERGENT: \(d)")
        }
        if allMatch {
            lines.append("Status: ALL MATCH")
        }
        return lines.joined(separator: "\n")
    }
}
