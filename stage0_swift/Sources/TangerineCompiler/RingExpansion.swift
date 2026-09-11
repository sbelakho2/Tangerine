// RingExpansion.swift — Stage 32: Controlled Ring Expansion
// Enables features/files/layers one ring at a time from the green corridor.
// Each expansion item must have full stabilization metadata before enablement.

// MARK: - ExpansionKind

/// The kind of item being expanded into a new ring.
public enum ExpansionKind: String, CaseIterable, Equatable {
    case languageFeature = "language-feature"
    case stdlibCluster   = "stdlib-cluster"
    case passFamily      = "pass-family"
    case compilerLayer   = "compiler-layer"
}

// MARK: - StabilizationMetadata

/// Required metadata for any expansion item.
public struct StabilizationMetadata: Equatable {
    public let hasInvariants: Bool
    public let hasLocalTests: Bool
    public let hasReductionSupport: Bool
    public let hasPhaseSnapshots: Bool
    public let hasRegressionCases: Bool

    public init(hasInvariants: Bool = false, hasLocalTests: Bool = false,
                hasReductionSupport: Bool = false, hasPhaseSnapshots: Bool = false,
                hasRegressionCases: Bool = false) {
        self.hasInvariants = hasInvariants
        self.hasLocalTests = hasLocalTests
        self.hasReductionSupport = hasReductionSupport
        self.hasPhaseSnapshots = hasPhaseSnapshots
        self.hasRegressionCases = hasRegressionCases
    }

    /// Is this metadata complete for enablement?
    public var isComplete: Bool {
        hasInvariants && hasLocalTests && hasReductionSupport &&
        hasPhaseSnapshots && hasRegressionCases
    }

    /// What's missing?
    public var missingItems: [String] {
        var missing: [String] = []
        if !hasInvariants { missing.append("invariants") }
        if !hasLocalTests { missing.append("local-tests") }
        if !hasReductionSupport { missing.append("reduction-support") }
        if !hasPhaseSnapshots { missing.append("phase-snapshots") }
        if !hasRegressionCases { missing.append("regression-cases") }
        return missing
    }
}

// MARK: - ExpansionItem

/// A single item proposed for ring expansion.
public struct ExpansionItem: Equatable {
    public let id: String
    public let kind: ExpansionKind
    public let name: String
    public let ring: Int          // target ring number
    public let metadata: StabilizationMetadata
    public var enabled: Bool
    public var regressionDetected: Bool

    public init(id: String, kind: ExpansionKind, name: String, ring: Int,
                metadata: StabilizationMetadata = StabilizationMetadata(),
                enabled: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.ring = ring
        self.metadata = metadata
        self.enabled = enabled
        self.regressionDetected = false
    }

    /// Can this item be enabled?
    public var canEnable: Bool {
        metadata.isComplete && !regressionDetected
    }
}

// MARK: - RingExpansionController

/// Controls the ring-by-ring expansion of the compiler system.
public final class RingExpansionController {
    private var items: [String: ExpansionItem] = [:]  // id -> item
    private var currentRing: Int = 0

    public init() {}

    /// Register an expansion item.
    public func register(_ item: ExpansionItem) {
        items[item.id] = item
    }

    /// Get item by id.
    public func item(id: String) -> ExpansionItem? {
        items[id]
    }

    /// Attempt to enable an item. Returns error message if blocked.
    public func enable(id: String) -> String? {
        guard var item = items[id] else { return "Item not found: \(id)" }
        if !item.metadata.isComplete {
            return "Cannot enable \(id): missing \(item.metadata.missingItems.joined(separator: ", "))"
        }
        if item.regressionDetected {
            return "Cannot enable \(id): regression detected, must rollback first"
        }
        item.enabled = true
        items[id] = item
        return nil
    }

    /// Record a regression for an item and roll it back.
    public func rollback(id: String, reason: String) -> Bool {
        guard var item = items[id] else { return false }
        item.enabled = false
        item.regressionDetected = true
        items[id] = item
        return true
    }

    /// Set current ring.
    public func advanceRing(to ring: Int) {
        currentRing = ring
    }

    /// Current ring number.
    public var ring: Int { currentRing }

    /// All items sorted by ring then id.
    public var allItems: [ExpansionItem] {
        items.values.sorted { a, b in
            if a.ring != b.ring { return a.ring < b.ring }
            return a.id < b.id
        }
    }

    /// Items in the current ring.
    public var currentRingItems: [ExpansionItem] {
        allItems.filter { $0.ring == currentRing }
    }

    /// Enabled items.
    public var enabledItems: [ExpansionItem] {
        allItems.filter(\.enabled)
    }

    /// Items blocked by incomplete metadata.
    public var blockedItems: [ExpansionItem] {
        allItems.filter { !$0.metadata.isComplete && !$0.enabled }
    }

    /// Items with regressions.
    public var regressedItems: [ExpansionItem] {
        allItems.filter(\.regressionDetected)
    }

    /// Expansion progress by ring.
    public func progress(ring: Int) -> (total: Int, enabled: Int) {
        let ringItems = allItems.filter { $0.ring == ring }
        let enabled = ringItems.filter(\.enabled).count
        return (ringItems.count, enabled)
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Ring Expansion Report ==="]
        lines.append("Current ring: \(currentRing)")
        lines.append("Total items: \(items.count)")
        lines.append("Enabled: \(enabledItems.count)")
        lines.append("Blocked: \(blockedItems.count)")
        lines.append("Regressed: \(regressedItems.count)")
        let rings = Set(allItems.map(\.ring)).sorted()
        for r in rings {
            let p = progress(ring: r)
            lines.append("  Ring \(r): \(p.enabled)/\(p.total) enabled")
        }
        return lines.joined(separator: "\n")
    }
}
