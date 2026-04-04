// CorrectnessModeCorridor.swift — Stage 31: Correctness Mode Green Corridor
// Ensures reduced compiler kernel and bootstrap stdlib are stable with minimal optimization.
// Aggregates all verification gates into a single green/red corridor status.

// MARK: - CorridorGate

/// A single gate in the green corridor.
public struct CorridorGate: Equatable, CustomStringConvertible {
    public let name: String
    public let category: GateCategory
    public var passed: Bool
    public var detail: String

    public init(name: String, category: GateCategory, passed: Bool = false,
                detail: String = "") {
        self.name = name
        self.category = category
        self.passed = passed
        self.detail = detail
    }

    public var description: String {
        let status = passed ? "PASS" : "FAIL"
        let d = detail.isEmpty ? "" : " — \(detail)"
        return "[\(status)] \(category.rawValue)/\(name)\(d)"
    }
}

// MARK: - GateCategory

/// Categories of corridor verification gates.
public enum GateCategory: String, CaseIterable, Equatable {
    case stageVerifier    = "stage-verifier"
    case goldenPhase      = "golden-phase"
    case differential     = "differential"
    case stdlibFile       = "stdlib-file"
    case clusterStatus    = "cluster-status"
}

// MARK: - ClusterSeverity

/// Severity level for tracking open clusters.
public enum ClusterSeverity: String, CaseIterable, Equatable, Comparable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    public static func < (lhs: ClusterSeverity, rhs: ClusterSeverity) -> Bool {
        let order: [ClusterSeverity] = [.p0, .p1, .p2, .p3]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - OpenCluster

/// Tracks an open failure cluster in the corridor.
public struct OpenCluster: Equatable {
    public let id: String
    public let severity: ClusterSeverity
    public let ring: String   // which ring this cluster belongs to

    public init(id: String, severity: ClusterSeverity, ring: String) {
        self.id = id
        self.severity = severity
        self.ring = ring
    }
}

// MARK: - CorrectnessCorridor

/// Aggregates all verification gates for the green corridor.
public final class CorrectnessCorridor {
    private var gates: [CorridorGate] = []
    private var clusters: [OpenCluster] = []

    public init() {}

    /// Add a gate.
    public func addGate(_ gate: CorridorGate) {
        gates.append(gate)
    }

    /// Record an open cluster.
    public func addCluster(_ cluster: OpenCluster) {
        clusters.append(cluster)
    }

    /// Resolve (remove) a cluster.
    public func resolveCluster(id: String) {
        clusters.removeAll { $0.id == id }
    }

    /// All gates.
    public var allGates: [CorridorGate] { gates }

    /// Gates by category.
    public func gates(category: GateCategory) -> [CorridorGate] {
        gates.filter { $0.category == category }
    }

    /// All failing gates.
    public var failingGates: [CorridorGate] {
        gates.filter { !$0.passed }
    }

    /// All passing gates.
    public var passingGates: [CorridorGate] {
        gates.filter { $0.passed }
    }

    /// Is the corridor green? All gates pass AND no P0/P1 clusters open.
    public var isGreen: Bool {
        failingGates.isEmpty && openP0P1Clusters.isEmpty
    }

    /// Open P0/P1 clusters in the current ring.
    public var openP0P1Clusters: [OpenCluster] {
        clusters.filter { $0.severity <= .p1 }
    }

    /// All open clusters.
    public var allOpenClusters: [OpenCluster] { clusters }

    /// Summary stats.
    public var passRate: Double {
        guard !gates.isEmpty else { return 1.0 }
        return Double(passingGates.count) / Double(gates.count)
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Correctness Mode Green Corridor ==="]
        let status = isGreen ? "GREEN" : "RED"
        lines.append("Status: \(status)")
        lines.append("Gates: \(gates.count) total, \(passingGates.count) pass, \(failingGates.count) fail")
        lines.append("Pass rate: \(String(format: "%.1f%%", passRate * 100))")
        lines.append("Open clusters: \(clusters.count) (P0/P1: \(openP0P1Clusters.count))")
        for cat in GateCategory.allCases {
            let catGates = self.gates(category: cat)
            if !catGates.isEmpty {
                let catPass = catGates.filter(\.passed).count
                lines.append("  \(cat.rawValue): \(catPass)/\(catGates.count)")
            }
        }
        if !failingGates.isEmpty {
            lines.append("Failing gates:")
            for g in failingGates {
                lines.append("  \(g)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
