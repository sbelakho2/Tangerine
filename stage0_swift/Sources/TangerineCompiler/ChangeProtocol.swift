// ChangeProtocol.swift — Stage 28: Strict Change Protocol for Internals
// Enforces that risky internal changes carry full stabilization burden.
// IR changes need invariant+verifier+snapshot+test updates.
// Pass changes need pass-specific tests+pass-id+diff example.
// Stdlib changes need dependency impact review.

// MARK: - ChangeCategory

/// The category of internal change being proposed.
public enum ChangeCategory: String, CaseIterable, Equatable {
    case irChange       = "ir-change"
    case passChange     = "pass-change"
    case stdlibChange   = "stdlib-change"
    case driverChange   = "driver-change"
    case testChange     = "test-change"
}

// MARK: - RequiredCompanion

/// A required companion artifact for a change.
public struct RequiredCompanion: Equatable, CustomStringConvertible {
    public let kind: String       // e.g. "invariant-update", "verifier-update", etc.
    public let present: Bool
    public let path: String?      // file path if present

    public init(kind: String, present: Bool, path: String? = nil) {
        self.kind = kind
        self.present = present
        self.path = path
    }

    public var description: String {
        let status = present ? "OK" : "MISSING"
        let p = path.map { " (\($0))" } ?? ""
        return "[\(status)] \(kind)\(p)"
    }
}

// MARK: - ChangeProposal

/// A proposed internal change with its companion artifacts.
public struct ChangeProposal: Equatable {
    public let id: String
    public let category: ChangeCategory
    public let summary: String
    public let author: String
    public let companions: [RequiredCompanion]
    public let dependencyReview: String?  // for stdlib changes

    public init(id: String, category: ChangeCategory, summary: String,
                author: String, companions: [RequiredCompanion] = [],
                dependencyReview: String? = nil) {
        self.id = id
        self.category = category
        self.summary = summary
        self.author = author
        self.companions = companions
        self.dependencyReview = dependencyReview
    }

    /// Is this proposal complete (all required companions present)?
    public var isComplete: Bool {
        let required = ChangeProtocol.requiredCompanions(for: category)
        for kind in required {
            if !companions.contains(where: { $0.kind == kind && $0.present }) {
                return false
            }
        }
        // stdlib changes also need dependency review
        if category == .stdlibChange && (dependencyReview ?? "").isEmpty {
            return false
        }
        return true
    }

    /// Missing companion kinds.
    public var missingCompanions: [String] {
        let required = ChangeProtocol.requiredCompanions(for: category)
        return required.filter { kind in
            !companions.contains(where: { $0.kind == kind && $0.present })
        }
    }
}

// MARK: - AuditEntry

/// A record in the audit log for risky internal changes.
public struct AuditEntry: Equatable {
    public let proposalId: String
    public let category: ChangeCategory
    public let author: String
    public let timestamp: String
    public let approved: Bool
    public let reason: String

    public init(proposalId: String, category: ChangeCategory, author: String,
                timestamp: String, approved: Bool, reason: String) {
        self.proposalId = proposalId
        self.category = category
        self.author = author
        self.timestamp = timestamp
        self.approved = approved
        self.reason = reason
    }
}

// MARK: - ChangeProtocol

/// Enforces the strict change protocol for risky internal changes.
public enum ChangeProtocol {

    /// Required companion artifact kinds for each change category.
    public static func requiredCompanions(for category: ChangeCategory) -> [String] {
        switch category {
        case .irChange:
            return ["invariant-update", "verifier-update", "golden-snapshot-update", "regression-tests"]
        case .passChange:
            return ["pass-specific-tests", "pass-id-reference", "pre-post-diff-example"]
        case .stdlibChange:
            return ["dependency-impact-review"]
        case .driverChange:
            return ["regression-tests"]
        case .testChange:
            return []  // test changes are self-documenting
        }
    }

    /// Validate a proposal — returns list of blocking issues.
    public static func validate(_ proposal: ChangeProposal) -> [String] {
        var issues: [String] = []
        if proposal.id.isEmpty {
            issues.append("Proposal ID must not be empty")
        }
        if proposal.summary.isEmpty {
            issues.append("Summary must not be empty")
        }
        if proposal.author.isEmpty {
            issues.append("Author must not be empty")
        }
        let missing = proposal.missingCompanions
        for m in missing {
            issues.append("Missing required companion: \(m)")
        }
        if proposal.category == .stdlibChange && (proposal.dependencyReview ?? "").isEmpty {
            issues.append("Stdlib change requires dependency impact review")
        }
        return issues
    }

    /// Would CI block this proposal?
    public static func wouldBlock(_ proposal: ChangeProposal) -> Bool {
        !validate(proposal).isEmpty
    }
}

// MARK: - ChangeAuditLog

/// Maintains an audit log of all risky internal changes.
public final class ChangeAuditLog {
    private var entries: [AuditEntry] = []

    public init() {}

    /// Record an audit entry.
    public func record(_ entry: AuditEntry) {
        entries.append(entry)
    }

    /// All entries.
    public var allEntries: [AuditEntry] { entries }

    /// Entries by category.
    public func entries(for category: ChangeCategory) -> [AuditEntry] {
        entries.filter { $0.category == category }
    }

    /// Approved entries.
    public var approved: [AuditEntry] {
        entries.filter { $0.approved }
    }

    /// Rejected entries.
    public var rejected: [AuditEntry] {
        entries.filter { !$0.approved }
    }

    /// Spot check: pick a random subset for review.
    public func spotCheck(count: Int) -> [AuditEntry] {
        let shuffled = entries.enumerated().sorted { a, b in
            // Deterministic "shuffle" based on index XOR hash
            let aHash = a.element.proposalId.hashValue ^ a.offset
            let bHash = b.element.proposalId.hashValue ^ b.offset
            return aHash < bHash
        }
        return Array(shuffled.prefix(count).map(\.element))
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Change Audit Log ==="]
        lines.append("Total entries: \(entries.count)")
        lines.append("Approved: \(approved.count)")
        lines.append("Rejected: \(rejected.count)")
        for cat in ChangeCategory.allCases {
            let catEntries = self.entries(for: cat)
            if !catEntries.isEmpty {
                lines.append("  \(cat.rawValue): \(catEntries.count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
