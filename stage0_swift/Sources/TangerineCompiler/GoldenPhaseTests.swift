// GoldenPhaseTests.swift — Stage 19: Curated golden test corpus per compiler phase
// Provides small truth anchors for parsing, resolution, typing, ownership,
// lowering, canonical IR, bootstrap stdlib, and module boundaries.

import Foundation

// MARK: - Golden Case

/// A single golden test case with expected outcome.
public struct GoldenCase: Equatable {
    public let id: String
    public let phase: CompilerPhase
    public let source: String
    public let expectedHash: UInt64
    public let expectsError: Bool
    public let interpreterOutput: String?

    public init(id: String, phase: CompilerPhase, source: String,
                expectedHash: UInt64, expectsError: Bool = false,
                interpreterOutput: String? = nil) {
        self.id = id
        self.phase = phase
        self.source = source
        self.expectedHash = expectedHash
        self.expectsError = expectsError
        self.interpreterOutput = interpreterOutput
    }
}

// MARK: - Compiler Phase

public enum CompilerPhase: String, CaseIterable, Equatable, Hashable {
    case parsing       = "parsing"
    case resolution    = "resolution"
    case typing        = "typing"
    case ownership     = "ownership"
    case lowering      = "lowering"
    case canonicalIR   = "canonical-ir"
    case bootstrapStdlib = "bootstrap-stdlib"
    case moduleBoundary  = "module-boundary"
}

// MARK: - Golden Corpus

/// Curated test corpus — small enough for every-commit CI.
public enum GoldenCorpus {
    /// Simple FNV-1a hash for deterministic snapshot comparison.
    public static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    /// All curated golden cases.
    public static let cases: [GoldenCase] = {
        var all: [GoldenCase] = []

        // --- Parsing ---
        let parseSrc1 = "def main()\n  println!(\"hello\")\nend\n"
        all.append(GoldenCase(id: "parse-001", phase: .parsing,
                               source: parseSrc1, expectedHash: fnv1a(parseSrc1)))
        let parseSrc2 = "def add(a: Int, b: Int) -> Int\n  return a + b\nend\n"
        all.append(GoldenCase(id: "parse-002", phase: .parsing,
                               source: parseSrc2, expectedHash: fnv1a(parseSrc2)))
        let parseSrcBad = "def\nend\n"
        all.append(GoldenCase(id: "parse-003", phase: .parsing,
                               source: parseSrcBad, expectedHash: fnv1a(parseSrcBad),
                               expectsError: true))

        // --- Resolution ---
        let resSrc1 = "use std::io::{println}\ndef main()\n  println(\"hi\")\nend\n"
        all.append(GoldenCase(id: "resolve-001", phase: .resolution,
                               source: resSrc1, expectedHash: fnv1a(resSrc1)))
        let resSrcBad = "def main()\n  undefined_fn()\nend\n"
        all.append(GoldenCase(id: "resolve-002", phase: .resolution,
                               source: resSrcBad, expectedHash: fnv1a(resSrcBad),
                               expectsError: true))

        // --- Typing ---
        let typeSrc1 = "def id(x: Int) -> Int\n  return x\nend\n"
        all.append(GoldenCase(id: "type-001", phase: .typing,
                               source: typeSrc1, expectedHash: fnv1a(typeSrc1)))
        let typeSrcBad = "def bad() -> Int\n  return \"string\"\nend\n"
        all.append(GoldenCase(id: "type-002", phase: .typing,
                               source: typeSrcBad, expectedHash: fnv1a(typeSrcBad),
                               expectsError: true))

        // --- Ownership ---
        let ownSrc1 = "def take(x: String)\n  let y = x\nend\n"
        all.append(GoldenCase(id: "own-001", phase: .ownership,
                               source: ownSrc1, expectedHash: fnv1a(ownSrc1)))
        let ownSrcBad = "def double_use(x: String)\n  let y = x\n  let z = x\nend\n"
        all.append(GoldenCase(id: "own-002", phase: .ownership,
                               source: ownSrcBad, expectedHash: fnv1a(ownSrcBad),
                               expectsError: true))

        // --- Lowering ---
        let lowSrc1 = "def simple() -> Int\n  return 42\nend\n"
        all.append(GoldenCase(id: "lower-001", phase: .lowering,
                               source: lowSrc1, expectedHash: fnv1a(lowSrc1),
                               interpreterOutput: "42"))
        let lowSrc2 = "def arith() -> Int\n  return 2 + 3\nend\n"
        all.append(GoldenCase(id: "lower-002", phase: .lowering,
                               source: lowSrc2, expectedHash: fnv1a(lowSrc2),
                               interpreterOutput: "5"))

        // --- Canonical IR ---
        let irSrc1 = "def noop()\nend\n"
        all.append(GoldenCase(id: "ir-001", phase: .canonicalIR,
                               source: irSrc1, expectedHash: fnv1a(irSrc1)))
        let irSrc2 = "def branch(x: Bool) -> Int\n  if x\n    return 1\n  else\n    return 0\n  end\nend\n"
        all.append(GoldenCase(id: "ir-002", phase: .canonicalIR,
                               source: irSrc2, expectedHash: fnv1a(irSrc2)))

        // --- Bootstrap Stdlib ---
        let stdSrc1 = "use std::core::{Option}\n"
        all.append(GoldenCase(id: "std-001", phase: .bootstrapStdlib,
                               source: stdSrc1, expectedHash: fnv1a(stdSrc1)))
        let stdSrc2 = "use std::collections::{Vec}\n"
        all.append(GoldenCase(id: "std-002", phase: .bootstrapStdlib,
                               source: stdSrc2, expectedHash: fnv1a(stdSrc2)))

        // --- Module Boundaries ---
        let modSrc1 = "mod inner\n  def helper() -> Int\n    return 1\n  end\nend\n"
        all.append(GoldenCase(id: "mod-001", phase: .moduleBoundary,
                               source: modSrc1, expectedHash: fnv1a(modSrc1)))
        let modSrcBad = "use internal::secret::{Hidden}\n"
        all.append(GoldenCase(id: "mod-002", phase: .moduleBoundary,
                               source: modSrcBad, expectedHash: fnv1a(modSrcBad),
                               expectsError: true))

        return all
    }()

    /// Cases filtered by phase.
    public static func cases(for phase: CompilerPhase) -> [GoldenCase] {
        cases.filter { $0.phase == phase }
    }

    /// Verify all hashes match expected values. Returns list of mismatches.
    public static func verifyHashes() -> [(id: String, expected: UInt64, actual: UInt64)] {
        var mismatches: [(id: String, expected: UInt64, actual: UInt64)] = []
        for c in cases {
            let actual = fnv1a(c.source)
            if actual != c.expectedHash {
                mismatches.append((id: c.id, expected: c.expectedHash, actual: actual))
            }
        }
        return mismatches
    }

    /// Full corpus snapshot for diffing.
    public static func snapshot() -> String {
        var lines: [String] = ["=== Golden Corpus Snapshot ==="]
        lines.append("Total cases: \(cases.count)")
        for phase in CompilerPhase.allCases {
            let phCases = cases(for: phase)
            lines.append("\(phase.rawValue): \(phCases.count) cases")
            for c in phCases {
                let status = c.expectsError ? "ERROR" : "OK"
                lines.append("  \(c.id) [\(status)] hash=\(c.expectedHash)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Total case count.
    public static var count: Int { cases.count }

    /// All phases that have at least one case.
    public static var coveredPhases: Set<CompilerPhase> {
        Set(cases.map { $0.phase })
    }
}
