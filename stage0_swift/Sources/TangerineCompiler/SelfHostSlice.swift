// SelfHostSlice.swift — Stage 34: Extend Self-Hosting Slice by Slice
// Self-hosting scope grows only from stable ground.
// Each slice is compiled, validated, and tracked independently.

// MARK: - SliceStatus

/// Status of a self-hosting slice.
public enum SliceStatus: String, CaseIterable, Equatable {
    case pending     = "pending"
    case building    = "building"
    case validating  = "validating"
    case green       = "green"
    case failed      = "failed"
}

// MARK: - SelfHostSlice

/// A single slice of the compiler being self-hosted.
public struct SelfHostSlice: Equatable {
    public let id: String
    public let layerName: String
    public let files: [String]
    public var status: SliceStatus
    public var stageHashes: [String: UInt64]
    public var verifiersPassed: Bool
    public var interpreterNativeAgreed: Bool
    public var hasRegressionSuite: Bool
    public var openClusters: Int

    public init(id: String, layerName: String, files: [String],
                status: SliceStatus = .pending) {
        self.id = id
        self.layerName = layerName
        self.files = files
        self.status = status
        self.stageHashes = [String: UInt64]()
        self.verifiersPassed = false
        self.interpreterNativeAgreed = false
        self.hasRegressionSuite = false
        self.openClusters = 0
    }

    /// Can this slice be marked green?
    public var canMarkGreen: Bool {
        verifiersPassed && interpreterNativeAgreed &&
        hasRegressionSuite && openClusters == 0
    }
}

// MARK: - SelfHostController

/// Controls the slice-by-slice self-hosting extension.
public final class SelfHostController {
    private var slices: [String: SelfHostSlice] = [:]

    public init() {}

    /// Register a slice.
    public func register(_ slice: SelfHostSlice) {
        slices[slice.id] = slice
    }

    /// Get a slice by id.
    public func slice(id: String) -> SelfHostSlice? {
        slices[id]
    }

    /// Update a slice.
    public func update(_ slice: SelfHostSlice) {
        slices[slice.id] = slice
    }

    /// Attempt to mark green.
    public func markGreen(id: String) -> String? {
        guard var s = slices[id] else { return "Slice not found: \(id)" }
        guard s.canMarkGreen else {
            var reasons: [String] = []
            if !s.verifiersPassed { reasons.append("verifiers not passed") }
            if !s.interpreterNativeAgreed { reasons.append("interpreter/native disagreement") }
            if !s.hasRegressionSuite { reasons.append("no regression suite") }
            if s.openClusters > 0 { reasons.append("\(s.openClusters) open clusters") }
            return "Cannot mark green: \(reasons.joined(separator: ", "))"
        }
        s.status = .green
        slices[id] = s
        return nil
    }

    /// All slices sorted by id.
    public var allSlices: [SelfHostSlice] {
        slices.values.sorted(by: { $0.id < $1.id })
    }

    /// Green slices.
    public var greenSlices: [SelfHostSlice] {
        allSlices.filter { $0.status == .green }
    }

    /// Do all existing green slices remain green?
    public var greenSlicesStable: Bool {
        greenSlices.allSatisfy(\.canMarkGreen)
    }

    /// Any new uncategorized clusters?
    public var totalOpenClusters: Int {
        allSlices.reduce(0) { $0 + $1.openClusters }
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Self-Host Slice Report ==="]
        lines.append("Total slices: \(slices.count)")
        for s in SliceStatus.allCases {
            let count = allSlices.filter { $0.status == s }.count
            if count > 0 { lines.append("  \(s.rawValue): \(count)") }
        }
        lines.append("Green stable: \(greenSlicesStable)")
        lines.append("Open clusters: \(totalOpenClusters)")
        return lines.joined(separator: "\n")
    }
}
