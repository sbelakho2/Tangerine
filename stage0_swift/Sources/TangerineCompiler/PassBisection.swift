// PassBisection.swift — Stage 22: Explicit pass management and pass bisection
// Enables isolation of optimizer failures via pass-order control and bisection.

// MARK: - PassEntry

/// A single pass in the ordered pass pipeline.
public struct PassEntry: Equatable, CustomStringConvertible {
    public let id: String
    public let name: String
    public var enabled: Bool

    public init(id: String, name: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }

    public var description: String {
        "\(id) [\(name)] \(enabled ? "ON" : "OFF")"
    }
}

// MARK: - PassPipeline

/// Manages the ordered pass pipeline with enable/disable and bisection support.
public final class PassPipeline {
    private var passes: [PassEntry]

    public init(passes: [PassEntry]) {
        self.passes = passes
    }

    /// Full pass list.
    public var allPasses: [PassEntry] { passes }

    /// Enabled passes only.
    public var enabledPasses: [PassEntry] { passes.filter { $0.enabled } }

    /// Hash of the current pass order (enabled only).
    public var orderHash: UInt64 {
        let content = enabledPasses.map { $0.id }.joined(separator: ",")
        return GoldenCorpus.fnv1a(content)
    }

    /// Debug-mode pass list string.
    public func debugList() -> String {
        passes.enumerated().map { (i, p) in
            "[\(i)] \(p)"
        }.joined(separator: "\n")
    }

    /// Enable/disable a specific pass by ID.
    public func setEnabled(passId: String, enabled: Bool) {
        if let idx = passes.firstIndex(where: { $0.id == passId }) {
            passes[idx].enabled = enabled
        }
    }

    /// Disable all passes.
    public func disableAll() {
        for i in passes.indices { passes[i].enabled = false }
    }

    /// Enable all passes.
    public func enableAll() {
        for i in passes.indices { passes[i].enabled = true }
    }

    /// Bisect: find the first pass that causes a predicate to become true.
    /// Returns the pass ID and index, or nil if no single pass is responsible.
    public func bisect(predicate: ([PassEntry]) -> Bool) -> (passId: String, index: Int)? {
        let enabled = enabledPasses
        guard !enabled.isEmpty else { return nil }

        // Binary search over prefix lengths
        var lo = 0
        var hi = enabled.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let prefix = Array(enabled.prefix(mid + 1))
            if predicate(prefix) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        if lo < enabled.count {
            let prefix = Array(enabled.prefix(lo + 1))
            if predicate(prefix) {
                return (passId: enabled[lo].id, index: lo)
            }
        }
        return nil
    }

    /// Generate pre/post-pass IR diff markers.
    public func diffMarkers(passId: String, preIR: String, postIR: String) -> String {
        var lines = ["=== Pass Diff: \(passId) ==="]
        lines.append("--- PRE ---")
        lines.append(preIR)
        lines.append("--- POST ---")
        lines.append(postIR)
        let preHash = GoldenCorpus.fnv1a(preIR)
        let postHash = GoldenCorpus.fnv1a(postIR)
        lines.append("Pre hash: \(preHash)")
        lines.append("Post hash: \(postHash)")
        lines.append("Changed: \(preHash != postHash)")
        return lines.joined(separator: "\n")
    }

    /// Generate a reduced reproducer: only the passes up to and including the failing one.
    public func reducedReproducer(upTo passId: String) -> [PassEntry] {
        var result: [PassEntry] = []
        for p in enabledPasses {
            result.append(p)
            if p.id == passId { break }
        }
        return result
    }
}
