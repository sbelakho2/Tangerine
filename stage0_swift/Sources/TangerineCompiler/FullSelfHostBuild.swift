// FullSelfHostBuild.swift — Stage 36: Full Self-Hosted Compiler Build in Correctness Mode
// Tracks full self-build with full stabilized stdlib.

// MARK: - BuildMode

/// Compiler build mode.
public enum BuildMode: String, CaseIterable, Equatable {
    case correctness  = "correctness"
    case performance  = "performance"
}

// MARK: - BuildResult

/// Result of a full self-hosted build.
public struct BuildResult: Equatable {
    public let mode: BuildMode
    public let success: Bool
    public let stageHashes: [String: UInt64]
    public let verifiersPassed: Bool
    public let interpreterSpotCheckPassed: Bool
    public let openP0P1: Int
    public let timestamp: String
    public let reproducible: Bool

    public init(mode: BuildMode, success: Bool, stageHashes: [String: UInt64] = [:],
                verifiersPassed: Bool = false, interpreterSpotCheckPassed: Bool = false,
                openP0P1: Int = 0, timestamp: String = "", reproducible: Bool = false) {
        self.mode = mode
        self.success = success
        self.stageHashes = stageHashes
        self.verifiersPassed = verifiersPassed
        self.interpreterSpotCheckPassed = interpreterSpotCheckPassed
        self.openP0P1 = openP0P1
        self.timestamp = timestamp
        self.reproducible = reproducible
    }

    /// Is this result fully green?
    public var isGreen: Bool {
        success && verifiersPassed && interpreterSpotCheckPassed &&
        openP0P1 == 0 && reproducible
    }
}

// MARK: - SelfHostBuildTracker

/// Tracks self-hosted build results.
public final class SelfHostBuildTracker {
    private var builds: [BuildResult] = []

    public init() {}

    /// Record a build result.
    public func record(_ result: BuildResult) {
        builds.append(result)
    }

    /// All results.
    public var allResults: [BuildResult] { builds }

    /// Latest result for a given mode.
    public func latest(mode: BuildMode) -> BuildResult? {
        builds.last(where: { $0.mode == mode })
    }

    /// Is correctness mode green?
    public var correctnessGreen: Bool {
        latest(mode: .correctness)?.isGreen ?? false
    }

    /// Is performance mode green?
    public var performanceGreen: Bool {
        latest(mode: .performance)?.isGreen ?? false
    }

    /// Do correctness and performance mode agree on stage hashes?
    public var modesAgree: Bool {
        guard let c = latest(mode: .correctness),
              let p = latest(mode: .performance) else { return false }
        return c.stageHashes == p.stageHashes
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Self-Host Build Report ==="]
        lines.append("Total builds: \(builds.count)")
        lines.append("Correctness green: \(correctnessGreen)")
        lines.append("Performance green: \(performanceGreen)")
        lines.append("Modes agree: \(modesAgree)")
        for mode in BuildMode.allCases {
            if let r = latest(mode: mode) {
                let status = r.isGreen ? "GREEN" : "RED"
                lines.append("  \(mode.rawValue): \(status) repro=\(r.reproducible) P0P1=\(r.openP0P1)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
