// CrashCaptureHardening.swift — Stage 29: Build/Hang/Crash Capture Hardening
// Ensures failures are not lost; hangs are diagnosable.
// Captures last completed stage, verified hash, good dump, watchdog info.

// MARK: - CapturedStage

/// Captures the last completed compiler stage before a failure.
public struct CapturedStage: Equatable, CustomStringConvertible {
    public let name: String
    public let index: Int
    public let verifiedHash: UInt64?
    public let artifactDump: String?

    public init(name: String, index: Int, verifiedHash: UInt64? = nil,
                artifactDump: String? = nil) {
        self.name = name
        self.index = index
        self.verifiedHash = verifiedHash
        self.artifactDump = artifactDump
    }

    public var description: String {
        let hash = verifiedHash.map { String(format: " hash=%016llx", $0) } ?? ""
        let dump = artifactDump != nil ? " [dump available]" : ""
        return "stage[\(index)]=\(name)\(hash)\(dump)"
    }
}

// MARK: - HangInfo

/// Captures information about a compiler hang.
public struct HangInfo: Equatable, CustomStringConvertible {
    public let stage: String
    public let passName: String?
    public let symbol: String?
    public let progressMarker: String
    public let sampledStacks: [String]
    public let elapsedSeconds: Double

    public init(stage: String, passName: String? = nil, symbol: String? = nil,
                progressMarker: String = "", sampledStacks: [String] = [],
                elapsedSeconds: Double = 0) {
        self.stage = stage
        self.passName = passName
        self.symbol = symbol
        self.progressMarker = progressMarker
        self.sampledStacks = sampledStacks
        self.elapsedSeconds = elapsedSeconds
    }

    public var description: String {
        var parts = ["HANG in \(stage)"]
        if let p = passName { parts.append("pass=\(p)") }
        if let s = symbol { parts.append("symbol=\(s)") }
        if !progressMarker.isEmpty { parts.append("progress=\(progressMarker)") }
        parts.append("elapsed=\(String(format: "%.1f", elapsedSeconds))s")
        parts.append("stacks=\(sampledStacks.count)")
        return parts.joined(separator: " ")
    }
}

// MARK: - CrashBundle

/// A complete crash/failure capture bundle for P0/P1 failures.
public struct CrashBundle: Equatable {
    public let id: String
    public let timestamp: String
    public let lastCompletedStage: CapturedStage?
    public let lastVerifiedHash: UInt64?
    public let lastGoodDump: String?
    public let hangInfo: HangInfo?
    public let failureMessage: String
    public let reproCommand: String?

    public init(id: String, timestamp: String,
                lastCompletedStage: CapturedStage? = nil,
                lastVerifiedHash: UInt64? = nil,
                lastGoodDump: String? = nil,
                hangInfo: HangInfo? = nil,
                failureMessage: String,
                reproCommand: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.lastCompletedStage = lastCompletedStage
        self.lastVerifiedHash = lastVerifiedHash
        self.lastGoodDump = lastGoodDump
        self.hangInfo = hangInfo
        self.failureMessage = failureMessage
        self.reproCommand = reproCommand
    }

    /// Does this bundle contain stage/pass metadata?
    public var hasStageMetadata: Bool {
        lastCompletedStage != nil || hangInfo != nil
    }

    /// Is size bounded? Bundle text must be < 1MB.
    public var isBounded: Bool {
        bundleText.utf8.count < 1_048_576
    }

    /// Generate the full bundle text.
    public var bundleText: String {
        var lines = ["=== Crash/Failure Bundle ==="]
        lines.append("ID: \(id)")
        lines.append("Timestamp: \(timestamp)")
        lines.append("Failure: \(failureMessage)")
        if let stage = lastCompletedStage {
            lines.append("Last completed stage: \(stage)")
        }
        if let hash = lastVerifiedHash {
            lines.append("Last verified hash: \(String(format: "%016llx", hash))")
        }
        if let dump = lastGoodDump {
            let truncated = dump.count > 4096 ? String(dump.prefix(4096)) + "\n[truncated]" : dump
            lines.append("Last good dump:\n\(truncated)")
        }
        if let hang = hangInfo {
            lines.append("Hang info: \(hang)")
            if !hang.sampledStacks.isEmpty {
                lines.append("Sampled stacks:")
                for (i, stack) in hang.sampledStacks.enumerated() {
                    lines.append("  [\(i)] \(stack)")
                }
            }
        }
        if let repro = reproCommand {
            lines.append("Repro command: \(repro)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - CrashCaptureEngine

/// Engine for capturing and managing crash/failure bundles.
public final class CrashCaptureEngine {
    private var bundles: [CrashBundle] = []
    private var progressStack: [CapturedStage] = []

    public init() {}

    /// Push a completed stage onto the progress stack.
    public func pushStage(_ stage: CapturedStage) {
        progressStack.append(stage)
    }

    /// Current last completed stage.
    public var lastCompletedStage: CapturedStage? {
        progressStack.last
    }

    /// Capture a crash bundle.
    public func captureCrash(id: String, timestamp: String, message: String,
                             reproCommand: String? = nil) -> CrashBundle {
        let bundle = CrashBundle(
            id: id, timestamp: timestamp,
            lastCompletedStage: lastCompletedStage,
            lastVerifiedHash: lastCompletedStage?.verifiedHash,
            lastGoodDump: lastCompletedStage?.artifactDump,
            failureMessage: message,
            reproCommand: reproCommand)
        bundles.append(bundle)
        return bundle
    }

    /// Capture a hang bundle.
    public func captureHang(id: String, timestamp: String,
                            hangInfo: HangInfo, reproCommand: String? = nil) -> CrashBundle {
        let bundle = CrashBundle(
            id: id, timestamp: timestamp,
            lastCompletedStage: lastCompletedStage,
            lastVerifiedHash: lastCompletedStage?.verifiedHash,
            lastGoodDump: lastCompletedStage?.artifactDump,
            hangInfo: hangInfo,
            failureMessage: "Hang detected: \(hangInfo.stage)",
            reproCommand: reproCommand)
        bundles.append(bundle)
        return bundle
    }

    /// All captured bundles.
    public var allBundles: [CrashBundle] { bundles }

    /// Reset progress stack (e.g. for new compilation).
    public func resetProgress() {
        progressStack = []
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Crash Capture Report ==="]
        lines.append("Total bundles: \(bundles.count)")
        lines.append("Progress stack depth: \(progressStack.count)")
        let crashes = bundles.filter { $0.hangInfo == nil }.count
        let hangs = bundles.filter { $0.hangInfo != nil }.count
        lines.append("Crashes: \(crashes)")
        lines.append("Hangs: \(hangs)")
        let withMetadata = bundles.filter { $0.hasStageMetadata }.count
        lines.append("With stage metadata: \(withMetadata)")
        return lines.joined(separator: "\n")
    }
}
