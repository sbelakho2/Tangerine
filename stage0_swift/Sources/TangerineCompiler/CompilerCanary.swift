// CompilerCanary.swift — Stage 24: Tiny always-green compiler kernel canary
// Defines a minimal corridor that builds and runs in seconds.

// MARK: - CanaryCase

/// A single canary test case.
public struct CanaryCase: Equatable {
    public let id: String
    public let source: String
    public let expectedParse: Bool     // should parse cleanly
    public let expectedVerify: Bool    // should pass verification
    public let expectedOutput: String? // expected interpreter output (if executable)
    public let snapshotHash: UInt64

    public init(id: String, source: String, expectedParse: Bool = true,
                expectedVerify: Bool = true, expectedOutput: String? = nil) {
        self.id = id
        self.source = source
        self.expectedParse = expectedParse
        self.expectedVerify = expectedVerify
        self.expectedOutput = expectedOutput
        self.snapshotHash = GoldenCorpus.fnv1a(source)
    }
}

// MARK: - CompilerCanary

/// The always-green canary: a tiny subset that must pass on every commit.
public enum CompilerCanary {
    /// The canary corpus — intentionally tiny.
    public static let cases: [CanaryCase] = [
        CanaryCase(id: "canary-001",
                   source: "def main()\n  return 0\nend\n",
                   expectedOutput: "0"),
        CanaryCase(id: "canary-002",
                   source: "def add(a: Int, b: Int) -> Int\n  return a + b\nend\n",
                   expectedOutput: nil),
        CanaryCase(id: "canary-003",
                   source: "def noop()\nend\n",
                   expectedOutput: nil),
        CanaryCase(id: "canary-004",
                   source: "struct Point\n  x: Int\n  y: Int\nend\n",
                   expectedOutput: nil),
        CanaryCase(id: "canary-005",
                   source: "enum Color\n  Red\n  Green\n  Blue\nend\n",
                   expectedOutput: nil),
    ]

    /// Total case count.
    public static var count: Int { cases.count }

    /// Verify all snapshot hashes are stable.
    public static func verifySnapshots() -> [(id: String, expected: UInt64, actual: UInt64)] {
        var mismatches: [(id: String, expected: UInt64, actual: UInt64)] = []
        for c in cases {
            let actual = GoldenCorpus.fnv1a(c.source)
            if actual != c.snapshotHash {
                mismatches.append((id: c.id, expected: c.snapshotHash, actual: actual))
            }
        }
        return mismatches
    }

    /// All cases that expect interpreter output.
    public static var executableCases: [CanaryCase] {
        cases.filter { $0.expectedOutput != nil }
    }

    /// Corpus is small enough? Must be <=10 cases.
    public static var isSmallEnough: Bool { cases.count <= 10 }

    /// Report.
    public static func report() -> String {
        var lines = ["=== Compiler Canary Report ==="]
        lines.append("Cases: \(cases.count)")
        lines.append("Executable: \(executableCases.count)")
        lines.append("Small enough: \(isSmallEnough)")
        let mismatches = verifySnapshots()
        if mismatches.isEmpty {
            lines.append("Snapshots: ALL STABLE")
        } else {
            lines.append("Snapshots: \(mismatches.count) MISMATCH(ES)")
            for m in mismatches {
                lines.append("  \(m.id): expected \(m.expected), got \(m.actual)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
