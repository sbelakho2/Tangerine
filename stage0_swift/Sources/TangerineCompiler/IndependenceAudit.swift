// IndependenceAudit.swift — Stage 39: Independence Audit
// Verifies Tangerine is genuinely independent — no hidden host compiler dependency.

// MARK: - AuditDomain

/// Domain of the independence audit.
public enum AuditDomain: String, CaseIterable, Equatable {
    case buildPath      = "build-path"
    case stdlibPath     = "stdlib-path"
    case toolingPath    = "tooling-path"
    case reproducibility = "reproducibility"
}

// MARK: - AuditFinding

/// A single finding from the independence audit.
public struct AuditFinding: Equatable {
    public let domain: AuditDomain
    public let severity: FindingSeverity
    public let description: String
    public let resolution: String?

    public init(domain: AuditDomain, severity: FindingSeverity,
                description: String, resolution: String? = nil) {
        self.domain = domain
        self.severity = severity
        self.description = description
        self.resolution = resolution
    }
}

// MARK: - FindingSeverity

public enum FindingSeverity: String, CaseIterable, Equatable, Comparable {
    case blocker  = "blocker"
    case warning  = "warning"
    case info     = "info"

    public static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool {
        let order: [FindingSeverity] = [.blocker, .warning, .info]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - IndependenceAuditor

/// Performs and tracks the independence audit.
public final class IndependenceAuditor {
    private var findings: [AuditFinding] = []
    private var cleanRoomPassed: Bool = false
    private var reproducibilityPassed: Bool = false

    public init() {}

    /// Record a finding.
    public func addFinding(_ finding: AuditFinding) {
        findings.append(finding)
    }

    /// Record clean-room rebuild result.
    public func recordCleanRoom(passed: Bool) {
        cleanRoomPassed = passed
    }

    /// Record reproducibility result.
    public func recordReproducibility(passed: Bool) {
        reproducibilityPassed = passed
    }

    /// All findings.
    public var allFindings: [AuditFinding] { findings }

    /// Findings by domain.
    public func findings(for domain: AuditDomain) -> [AuditFinding] {
        findings.filter { $0.domain == domain }
    }

    /// Blocker findings.
    public var blockers: [AuditFinding] {
        findings.filter { $0.severity == .blocker }
    }

    /// Is the build path clean (no hidden host compiler deps)?
    public var buildPathClean: Bool {
        findings(for: .buildPath).filter { $0.severity == .blocker }.isEmpty
    }

    /// Is the stdlib path clean?
    public var stdlibPathClean: Bool {
        findings(for: .stdlibPath).filter { $0.severity == .blocker }.isEmpty
    }

    /// Is tooling clean?
    public var toolingClean: Bool {
        findings(for: .toolingPath).filter { $0.severity == .blocker }.isEmpty
    }

    /// Overall audit green?
    public var isGreen: Bool {
        blockers.isEmpty && cleanRoomPassed && reproducibilityPassed
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Independence Audit Report ==="]
        let status = isGreen ? "GREEN" : "RED"
        lines.append("Status: \(status)")
        lines.append("Findings: \(findings.count) (blockers: \(blockers.count))")
        lines.append("Clean-room rebuild: \(cleanRoomPassed ? "PASS" : "FAIL")")
        lines.append("Reproducibility: \(reproducibilityPassed ? "PASS" : "FAIL")")
        lines.append("Build path: \(buildPathClean ? "CLEAN" : "ISSUES")")
        lines.append("Stdlib path: \(stdlibPathClean ? "CLEAN" : "ISSUES")")
        lines.append("Tooling: \(toolingClean ? "CLEAN" : "ISSUES")")
        for domain in AuditDomain.allCases {
            let domainFindings = self.findings(for: domain)
            if !domainFindings.isEmpty {
                lines.append("  \(domain.rawValue): \(domainFindings.count) finding(s)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
