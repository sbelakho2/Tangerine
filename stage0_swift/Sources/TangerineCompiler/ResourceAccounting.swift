// ResourceAccounting.swift — Stage 23: Build graph observability and resource accounting
// Records time, memory, and rebuild churn for stages and passes.

import Foundation

// MARK: - StageMetrics

/// Metrics for a single compiler stage.
public struct StageMetrics: Equatable, CustomStringConvertible {
    public let name: String
    public var elapsedMs: Double
    public var peakMemoryBytes: Int
    public var allocationCount: Int

    public init(name: String, elapsedMs: Double = 0, peakMemoryBytes: Int = 0, allocationCount: Int = 0) {
        self.name = name
        self.elapsedMs = elapsedMs
        self.peakMemoryBytes = peakMemoryBytes
        self.allocationCount = allocationCount
    }

    public var description: String {
        "\(name): \(String(format: "%.2f", elapsedMs))ms, \(peakMemoryBytes)B peak, \(allocationCount) allocs"
    }
}

// MARK: - PassMetrics

/// Metrics for a single compiler pass.
public struct PassMetrics: Equatable, CustomStringConvertible {
    public let passId: String
    public var elapsedMs: Double
    public var allocationCount: Int

    public init(passId: String, elapsedMs: Double = 0, allocationCount: Int = 0) {
        self.passId = passId
        self.elapsedMs = elapsedMs
        self.allocationCount = allocationCount
    }

    public var description: String {
        "\(passId): \(String(format: "%.2f", elapsedMs))ms, \(allocationCount) allocs"
    }
}

// MARK: - InvalidationEvent

/// Records why a module was rebuilt.
public struct InvalidationEvent: Equatable, CustomStringConvertible {
    public let module: String
    public let cause: String
    public let timestamp: Double  // relative seconds

    public init(module: String, cause: String, timestamp: Double = 0) {
        self.module = module
        self.cause = cause
        self.timestamp = timestamp
    }

    public var description: String {
        "[\(String(format: "%.3f", timestamp))s] \(module): \(cause)"
    }
}

// MARK: - ResourceAccountant

/// Collects and reports resource usage metrics.
public final class ResourceAccountant {
    private var stageMetrics: [StageMetrics] = []
    private var passMetrics: [PassMetrics] = []
    private var invalidations: [InvalidationEvent] = []
    private var baselineMs: Double?
    public var explosiveThresholdMultiplier: Double = 3.0

    public init() {}

    /// Record stage timing.
    public func recordStage(_ metrics: StageMetrics) {
        stageMetrics.append(metrics)
    }

    /// Record pass timing.
    public func recordPass(_ metrics: PassMetrics) {
        passMetrics.append(metrics)
    }

    /// Record invalidation event.
    public func recordInvalidation(_ event: InvalidationEvent) {
        invalidations.append(event)
    }

    /// Set baseline for delta comparison.
    public func setBaseline(totalMs: Double) {
        baselineMs = totalMs
    }

    /// All stage metrics.
    public var allStageMetrics: [StageMetrics] { stageMetrics }

    /// All pass metrics.
    public var allPassMetrics: [PassMetrics] { passMetrics }

    /// All invalidation events.
    public var allInvalidations: [InvalidationEvent] { invalidations }

    /// Total elapsed time across all stages.
    public var totalElapsedMs: Double {
        stageMetrics.reduce(0) { $0 + $1.elapsedMs }
    }

    /// Total allocations across all passes.
    public var totalAllocations: Int {
        passMetrics.reduce(0) { $0 + $1.allocationCount }
    }

    /// Detect explosive deltas (>3x baseline).
    public var explosiveDeltas: [StageMetrics] {
        guard let baseline = baselineMs, baseline > 0 else { return [] }
        let threshold = baseline * explosiveThresholdMultiplier
        return stageMetrics.filter { $0.elapsedMs > threshold }
    }

    /// Hotspots: stages taking more than 30% of total.
    public var hotspots: [StageMetrics] {
        let total = totalElapsedMs
        guard total > 0 else { return [] }
        return stageMetrics.filter { $0.elapsedMs / total > 0.3 }
    }

    /// Report is stable across repeated runs on same data.
    public func report() -> String {
        var lines = ["=== Resource Accounting Report ==="]
        lines.append("Stages: \(stageMetrics.count)")
        for s in stageMetrics { lines.append("  \(s)") }
        lines.append("Passes: \(passMetrics.count)")
        for p in passMetrics { lines.append("  \(p)") }
        lines.append("Total time: \(String(format: "%.2f", totalElapsedMs))ms")
        lines.append("Total allocs: \(totalAllocations)")
        if !invalidations.isEmpty {
            lines.append("Invalidations: \(invalidations.count)")
            for inv in invalidations { lines.append("  \(inv)") }
        }
        if !explosiveDeltas.isEmpty {
            lines.append("WARNING: Explosive deltas detected:")
            for e in explosiveDeltas { lines.append("  \(e)") }
        }
        return lines.joined(separator: "\n")
    }
}
