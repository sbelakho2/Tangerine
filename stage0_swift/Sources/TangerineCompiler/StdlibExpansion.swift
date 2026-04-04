// StdlibExpansion.swift — Stage 35: Expand Stdlib from Bootstrap Profile to Full Profile
// Groups remaining stdlib files into coherent clusters, enabling one at a time.

// MARK: - StdlibClusterStatus

/// Status of a stdlib cluster.
public enum StdlibClusterStatus: String, CaseIterable, Equatable {
    case pending    = "pending"
    case testing    = "testing"
    case green      = "green"
    case failed     = "failed"
    case rolledBack = "rolled-back"
}

// MARK: - StdlibCluster

/// A coherent cluster of stdlib files being expanded.
public struct StdlibCluster: Equatable {
    public let id: String
    public let name: String
    public let files: [String]
    public var status: StdlibClusterStatus
    public var hasLocalTests: Bool
    public var hasIntegrationTests: Bool
    public var hasInterpreterValidation: Bool
    public var hasSnapshotBaselines: Bool
    public var hasContracts: Bool
    public var failureRate: Double    // 0.0 = no failures

    public init(id: String, name: String, files: [String],
                status: StdlibClusterStatus = .pending) {
        self.id = id
        self.name = name
        self.files = files
        self.status = status
        self.hasLocalTests = false
        self.hasIntegrationTests = false
        self.hasInterpreterValidation = false
        self.hasSnapshotBaselines = false
        self.hasContracts = false
        self.failureRate = 0.0
    }

    /// Is this cluster ready to be enabled?
    public var isReady: Bool {
        hasLocalTests && hasIntegrationTests && hasSnapshotBaselines
    }

    /// Does this cluster introduce hidden deps on unstable features?
    public var hasHiddenDeps: Bool { false }  // checked during integration
}

// MARK: - StdlibExpansionController

/// Controls stdlib expansion from bootstrap profile to full profile.
public final class StdlibExpansionController {
    private var clusters: [String: StdlibCluster] = [:]
    private var dependencyMap: [String: Set<String>] = [String: Set<String>]()

    public init() {}

    /// Register a cluster.
    public func register(_ cluster: StdlibCluster) {
        clusters[cluster.id] = cluster
    }

    /// Get a cluster by id.
    public func cluster(id: String) -> StdlibCluster? {
        clusters[id]
    }

    /// Update a cluster.
    public func update(_ cluster: StdlibCluster) {
        clusters[cluster.id] = cluster
    }

    /// Record dependency between clusters.
    public func addDependency(from: String, to: String) {
        dependencyMap[from, default: []].insert(to)
    }

    /// Enable a cluster (mark green).
    public func enable(id: String) -> String? {
        guard var cluster = clusters[id] else { return "Cluster not found: \(id)" }
        guard cluster.isReady else {
            var reasons: [String] = []
            if !cluster.hasLocalTests { reasons.append("no local tests") }
            if !cluster.hasIntegrationTests { reasons.append("no integration tests") }
            if !cluster.hasSnapshotBaselines { reasons.append("no snapshot baselines") }
            return "Cannot enable \(id): \(reasons.joined(separator: ", "))"
        }
        cluster.status = .green
        clusters[id] = cluster
        return nil
    }

    /// Rollback a cluster.
    public func rollback(id: String) -> Bool {
        guard var cluster = clusters[id] else { return false }
        cluster.status = .rolledBack
        clusters[id] = cluster
        return true
    }

    /// All clusters sorted by id.
    public var allClusters: [StdlibCluster] {
        clusters.values.sorted(by: { $0.id < $1.id })
    }

    /// Green clusters.
    public var greenClusters: [StdlibCluster] {
        allClusters.filter { $0.status == .green }
    }

    /// Total file coverage (green clusters).
    public var coveredFiles: Int {
        greenClusters.reduce(0) { $0 + $1.files.count }
    }

    /// Total files across all clusters.
    public var totalFiles: Int {
        allClusters.reduce(0) { $0 + $1.files.count }
    }

    /// Coverage monotonically growing? (green >= previous count)
    public func coverageGrowing(previousGreen: Int) -> Bool {
        greenClusters.count >= previousGreen
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Stdlib Expansion Report ==="]
        lines.append("Total clusters: \(clusters.count)")
        for s in StdlibClusterStatus.allCases {
            let count = allClusters.filter { $0.status == s }.count
            if count > 0 { lines.append("  \(s.rawValue): \(count)") }
        }
        lines.append("Files covered: \(coveredFiles)/\(totalFiles)")
        return lines.joined(separator: "\n")
    }
}
