// FailureClustering.swift — Stage 14: Cluster failures by root signature

public struct FailureClustering {

    // MARK: - Root signature

    public struct RootSignature: Equatable, Hashable {
        public let category: FailureClassification.Category
        public let stage: Int?
        public let passId: String?
        public let topFrame: String?
        public let firstBadHash: String?
        public let symbolPattern: String?

        public init(category: FailureClassification.Category,
                    stage: Int? = nil, passId: String? = nil,
                    topFrame: String? = nil, firstBadHash: String? = nil,
                    symbolPattern: String? = nil) {
            self.category = category
            self.stage = stage
            self.passId = passId
            self.topFrame = topFrame
            self.firstBadHash = firstBadHash
            self.symbolPattern = symbolPattern
        }

        public var key: String {
            var parts: [String] = [category.rawValue]
            if let s = stage { parts.append("s\(s)") }
            if let p = passId { parts.append(p) }
            if let f = topFrame { parts.append(f) }
            if let h = firstBadHash { parts.append(h) }
            if let sp = symbolPattern { parts.append(sp) }
            return parts.joined(separator: "|")
        }
    }

    // MARK: - Cluster

    public struct Cluster: Equatable {
        public let signature: RootSignature
        public var failures: [FailureClassification.FailureRecord]
        public var representative: FailureClassification.FailureRecord?
        public var isResolved: Bool

        public init(signature: RootSignature,
                    failures: [FailureClassification.FailureRecord] = [],
                    representative: FailureClassification.FailureRecord? = nil,
                    isResolved: Bool = false) {
            self.signature = signature
            self.failures = failures
            self.representative = representative
            self.isResolved = isResolved
        }

        public var size: Int { failures.count }
    }

    // MARK: - Engine

    public final class Engine {
        public private(set) var clusters: [String: Cluster] = [:]
        private var resolvedSignatures: Set<String> = []

        public init() {}

        /// Derive signature from a failure record.
        public func deriveSignature(from record: FailureClassification.FailureRecord) -> RootSignature {
            RootSignature(
                category: record.category,
                stage: record.stage,
                passId: record.passId)
        }

        /// Assign a failure to a cluster. Creates the cluster if new.
        public func assign(_ record: FailureClassification.FailureRecord) {
            let sig = deriveSignature(from: record)
            let key = sig.key
            if clusters[key] == nil {
                clusters[key] = Cluster(signature: sig)
            }
            clusters[key]!.failures.append(record)
            if clusters[key]!.representative == nil {
                clusters[key]!.representative = record
            }
            // Check for recurrence of previously fixed cluster
            if resolvedSignatures.contains(key) {
                clusters[key]!.isResolved = false
            }
        }

        /// Mark a cluster as resolved.
        public func resolve(key: String) {
            clusters[key]?.isResolved = true
            resolvedSignatures.insert(key)
        }

        /// Check if a new failure recurs in a previously resolved cluster.
        public func isRecurrence(_ record: FailureClassification.FailureRecord) -> Bool {
            let key = deriveSignature(from: record).key
            return resolvedSignatures.contains(key)
        }

        public func sizeReport() -> [(key: String, size: Int)] {
            clusters.map { ($0.key, $0.value.size) }
                .sorted { $0.size > $1.size }
        }

        public func report() -> String {
            var lines: [String] = []
            lines.append("Failure Cluster Report")
            lines.append("======================")
            lines.append("Total clusters: \(clusters.count)")
            lines.append("Resolved: \(clusters.values.filter(\.isResolved).count)")
            lines.append("")
            for (key, cluster) in clusters.sorted(by: { $0.value.size > $1.value.size }) {
                let status = cluster.isResolved ? "RESOLVED" : "OPEN"
                lines.append("[\(status)] \(key) — \(cluster.size) failure(s)")
                if let rep = cluster.representative {
                    lines.append("  Representative: \(rep.id) — \(rep.summary)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}
