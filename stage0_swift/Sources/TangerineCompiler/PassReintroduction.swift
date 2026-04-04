// PassReintroduction.swift — Stage 33: Reintroduce Optimization Pass Families One by One
// Controls the gradual re-enablement of optimization passes with full verification.

// MARK: - PassFamilyStatus

/// Status of a pass family in the reintroduction process.
public enum PassFamilyStatus: String, CaseIterable, Equatable {
    case disabled       = "disabled"
    case localGreen     = "local-green"      // pass-local tests green
    case reducedGreen   = "reduced-green"    // green on reduced corpus
    case fullGreen      = "full-green"       // green on full corpus
    case enabled        = "enabled"          // production-enabled
}

// MARK: - PassFamilyRecord

/// Record tracking a pass family through the reintroduction process.
public struct PassFamilyRecord: Equatable {
    public let familyId: String
    public let name: String
    public var status: PassFamilyStatus
    public var hasLocalInvariants: Bool
    public var hasRegressionCorpus: Bool
    public var hasDifferentialTests: Bool
    public var hasBisectionCoverage: Bool
    public var mutationTestsPass: Bool

    public init(familyId: String, name: String, status: PassFamilyStatus = .disabled,
                hasLocalInvariants: Bool = false, hasRegressionCorpus: Bool = false,
                hasDifferentialTests: Bool = false, hasBisectionCoverage: Bool = false,
                mutationTestsPass: Bool = false) {
        self.familyId = familyId
        self.name = name
        self.status = status
        self.hasLocalInvariants = hasLocalInvariants
        self.hasRegressionCorpus = hasRegressionCorpus
        self.hasDifferentialTests = hasDifferentialTests
        self.hasBisectionCoverage = hasBisectionCoverage
        self.mutationTestsPass = mutationTestsPass
    }

    /// Can this pass family advance to the next status?
    public var canAdvance: Bool {
        switch status {
        case .disabled:
            return hasLocalInvariants && hasRegressionCorpus
        case .localGreen:
            return hasDifferentialTests
        case .reducedGreen:
            return hasBisectionCoverage && mutationTestsPass
        case .fullGreen:
            return true
        case .enabled:
            return false // already at the end
        }
    }

    /// What's needed to advance?
    public var advanceRequirements: [String] {
        switch status {
        case .disabled:
            var reqs: [String] = []
            if !hasLocalInvariants { reqs.append("local-invariants") }
            if !hasRegressionCorpus { reqs.append("regression-corpus") }
            return reqs
        case .localGreen:
            return hasDifferentialTests ? [] : ["differential-tests"]
        case .reducedGreen:
            var reqs: [String] = []
            if !hasBisectionCoverage { reqs.append("bisection-coverage") }
            if !mutationTestsPass { reqs.append("mutation-tests-pass") }
            return reqs
        case .fullGreen, .enabled:
            return []
        }
    }
}

// MARK: - PassReintroductionController

/// Controls the gradual re-enablement of optimization pass families.
public final class PassReintroductionController {
    private var families: [String: PassFamilyRecord] = [:]  // familyId -> record

    public init() {}

    /// Register a pass family.
    public func register(_ record: PassFamilyRecord) {
        families[record.familyId] = record
    }

    /// Get record by family id.
    public func record(for familyId: String) -> PassFamilyRecord? {
        families[familyId]
    }

    /// Attempt to advance a pass family to next status.
    public func advance(familyId: String) -> String? {
        guard var record = families[familyId] else { return "Family not found: \(familyId)" }
        guard record.canAdvance else {
            return "Cannot advance \(familyId): need \(record.advanceRequirements.joined(separator: ", "))"
        }
        switch record.status {
        case .disabled: record.status = .localGreen
        case .localGreen: record.status = .reducedGreen
        case .reducedGreen: record.status = .fullGreen
        case .fullGreen: record.status = .enabled
        case .enabled: return "Already enabled"
        }
        families[familyId] = record
        return nil
    }

    /// Roll back a pass family to disabled.
    public func disable(familyId: String) -> Bool {
        guard var record = families[familyId] else { return false }
        record.status = .disabled
        families[familyId] = record
        return true
    }

    /// All records sorted by family id.
    public var allRecords: [PassFamilyRecord] {
        families.values.sorted(by: { $0.familyId < $1.familyId })
    }

    /// Enabled pass families.
    public var enabledFamilies: [PassFamilyRecord] {
        allRecords.filter { $0.status == .enabled }
    }

    /// Disabled pass families.
    public var disabledFamilies: [PassFamilyRecord] {
        allRecords.filter { $0.status == .disabled }
    }

    /// Pass manifest — the versioned list of enabled passes.
    public var manifest: String {
        let enabled = enabledFamilies.map(\.familyId).sorted()
        return "Pass Manifest v1: [\(enabled.joined(separator: ", "))]"
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Pass Reintroduction Report ==="]
        lines.append("Total families: \(families.count)")
        for s in PassFamilyStatus.allCases {
            let count = allRecords.filter { $0.status == s }.count
            if count > 0 { lines.append("  \(s.rawValue): \(count)") }
        }
        lines.append("Manifest: \(manifest)")
        return lines.joined(separator: "\n")
    }
}
