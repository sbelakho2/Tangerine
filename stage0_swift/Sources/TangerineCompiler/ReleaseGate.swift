// ReleaseGate.swift — Stage 40: Release Candidate Gate + Final Release + Permanent Rules
// Aggregates all gates into a final release readiness assessment.
// Also defines permanent rules that must hold after release.

// MARK: - ReleaseGateStatus

/// Status of a release gate.
public enum ReleaseGateStatus: String, CaseIterable, Equatable {
    case notChecked = "not-checked"
    case green      = "green"
    case red        = "red"
}

// MARK: - ReleaseGateItem

/// A single gate in the release readiness check.
public struct ReleaseGateItem: Equatable, CustomStringConvertible {
    public let name: String
    public var status: ReleaseGateStatus
    public var detail: String

    public init(name: String, status: ReleaseGateStatus = .notChecked,
                detail: String = "") {
        self.name = name
        self.status = status
        self.detail = detail
    }

    public var description: String {
        let s = status.rawValue.uppercased()
        let d = detail.isEmpty ? "" : " — \(detail)"
        return "[\(s)] \(name)\(d)"
    }
}

// MARK: - PermanentRule

/// A permanent rule that must hold post-release.
public struct PermanentRule: Equatable {
    public let id: String
    public let description: String
    public var enforced: Bool

    public init(id: String, description: String, enforced: Bool = false) {
        self.id = id
        self.description = description
        self.enforced = enforced
    }
}

// MARK: - ReleaseGateController

/// Controls the release candidate gate assessment.
public final class ReleaseGateController {
    private var gates: [ReleaseGateItem] = []
    private var permanentRules: [PermanentRule] = []
    private var releaseArtifacts: [String: UInt64] = [:]  // name -> hash

    public init() {
        // Initialize standard release gates
        gates = [
            ReleaseGateItem(name: "Zero open P0 clusters"),
            ReleaseGateItem(name: "Zero open P1 clusters"),
            ReleaseGateItem(name: "Canary green"),
            ReleaseGateItem(name: "Reduced corridor green"),
            ReleaseGateItem(name: "Full correctness-mode self-build green"),
            ReleaseGateItem(name: "Full performance-mode self-build green"),
            ReleaseGateItem(name: "Full stdlib green"),
            ReleaseGateItem(name: "Reproducibility green"),
            ReleaseGateItem(name: "Cross-platform smoke matrix green"),
            ReleaseGateItem(name: "Independence audit green"),
        ]

        // Initialize permanent rules
        permanentRules = [
            PermanentRule(id: "PERM-001", description: "Keep stage verifiers permanent"),
            PermanentRule(id: "PERM-002", description: "Keep canary permanent"),
            PermanentRule(id: "PERM-003", description: "Keep reduced corridor permanent"),
            PermanentRule(id: "PERM-004", description: "Keep cluster recurrence tracking permanent"),
            PermanentRule(id: "PERM-005", description: "Keep regression repros permanent"),
            PermanentRule(id: "PERM-006", description: "Keep bootstrap/profile dependency maps current"),
            PermanentRule(id: "PERM-007", description: "Never re-enable silent fallback behavior"),
            PermanentRule(id: "PERM-008", description: "Never remove reduction/minimization from failure handling"),
        ]
    }

    /// Set a gate's status.
    public func setGate(name: String, status: ReleaseGateStatus, detail: String = "") {
        if let idx = gates.firstIndex(where: { $0.name == name }) {
            gates[idx].status = status
            if !detail.isEmpty { gates[idx].detail = detail }
        }
    }

    /// All gates.
    public var allGates: [ReleaseGateItem] { gates }

    /// Passing gates.
    public var passingGates: [ReleaseGateItem] {
        gates.filter { $0.status == .green }
    }

    /// Failing gates.
    public var failingGates: [ReleaseGateItem] {
        gates.filter { $0.status == .red }
    }

    /// Not-checked gates.
    public var uncheckedGates: [ReleaseGateItem] {
        gates.filter { $0.status == .notChecked }
    }

    /// Is the release candidate ready?
    public var isReady: Bool {
        gates.allSatisfy { $0.status == .green }
    }

    /// Mark a permanent rule as enforced.
    public func enforceRule(id: String) {
        if let idx = permanentRules.firstIndex(where: { $0.id == id }) {
            permanentRules[idx].enforced = true
        }
    }

    /// All permanent rules.
    public var allPermanentRules: [PermanentRule] { permanentRules }

    /// Unenforced permanent rules.
    public var unenforcedRules: [PermanentRule] {
        permanentRules.filter { !$0.enforced }
    }

    /// Are all permanent rules enforced?
    public var allRulesEnforced: Bool {
        permanentRules.allSatisfy(\.enforced)
    }

    /// Record a release artifact hash.
    public func recordArtifact(name: String, hash: UInt64) {
        releaseArtifacts[name] = hash
    }

    /// All recorded artifact hashes.
    public var artifacts: [String: UInt64] { releaseArtifacts }

    /// Verify artifact hashes match expected.
    public func verifyArtifact(name: String, expectedHash: UInt64) -> Bool {
        releaseArtifacts[name] == expectedHash
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Release Candidate Gate ==="]
        let status = isReady ? "READY" : "NOT READY"
        lines.append("Status: \(status)")
        lines.append("Gates: \(gates.count) total, \(passingGates.count) green, \(failingGates.count) red, \(uncheckedGates.count) unchecked")
        for g in gates {
            lines.append("  \(g)")
        }
        lines.append("Permanent rules: \(permanentRules.count) total, \(permanentRules.filter(\.enforced).count) enforced")
        for r in permanentRules {
            let mark = r.enforced ? "ENFORCED" : "PENDING"
            lines.append("  [\(mark)] \(r.id): \(r.description)")
        }
        lines.append("Artifacts: \(releaseArtifacts.count)")
        return lines.joined(separator: "\n")
    }
}
