// StdlibFeatureValidation.swift — Stage 38: Full Stdlib Feature Support Validation
// Confirms every stdlib feature cluster is enabled with tests, docs, contracts, integration.

// MARK: - FeatureValidationStatus

/// Validation status for a stdlib feature.
public enum FeatureValidationStatus: String, CaseIterable, Equatable {
    case notValidated   = "not-validated"
    case partial        = "partial"
    case fullyValidated = "fully-validated"
}

// MARK: - StdlibFeatureRecord

/// Records validation status for a stdlib module's features.
public struct StdlibFeatureRecord: Equatable {
    public let module: String
    public var status: FeatureValidationStatus
    public var hasTests: Bool
    public var hasDocs: Bool
    public var hasContracts: Bool
    public var hasIntegrationCoverage: Bool
    public var bootstrapRestrictions: [String]  // should be empty for release

    public init(module: String, status: FeatureValidationStatus = .notValidated,
                hasTests: Bool = false, hasDocs: Bool = false,
                hasContracts: Bool = false, hasIntegrationCoverage: Bool = false,
                bootstrapRestrictions: [String] = []) {
        self.module = module
        self.status = status
        self.hasTests = hasTests
        self.hasDocs = hasDocs
        self.hasContracts = hasContracts
        self.hasIntegrationCoverage = hasIntegrationCoverage
        self.bootstrapRestrictions = bootstrapRestrictions
    }

    /// Is this module fully validated for release?
    public var isReleaseReady: Bool {
        hasTests && hasDocs && hasIntegrationCoverage && bootstrapRestrictions.isEmpty
    }
}

// MARK: - StdlibFeatureValidator

/// Validates full stdlib feature support.
public final class StdlibFeatureValidator {
    private var records: [String: StdlibFeatureRecord] = [:]

    public init() {}

    /// Register a module.
    public func register(_ record: StdlibFeatureRecord) {
        records[record.module] = record
    }

    /// Get record for a module.
    public func record(for module: String) -> StdlibFeatureRecord? {
        records[module]
    }

    /// Update a record.
    public func update(_ record: StdlibFeatureRecord) {
        records[record.module] = record
    }

    /// All records sorted by module name.
    public var allRecords: [StdlibFeatureRecord] {
        records.values.sorted(by: { $0.module < $1.module })
    }

    /// Modules that are green (fully validated).
    public var greenModules: [String] {
        allRecords.filter { $0.status == .fullyValidated }.map(\.module)
    }

    /// Modules with remaining bootstrap restrictions.
    public var restrictedModules: [String] {
        allRecords.filter { !$0.bootstrapRestrictions.isEmpty }.map(\.module)
    }

    /// Modules missing documentation.
    public var missingDocs: [String] {
        allRecords.filter { !$0.hasDocs }.map(\.module)
    }

    /// Are all modules release-ready?
    public var allReleaseReady: Bool {
        allRecords.allSatisfy(\.isReleaseReady)
    }

    /// Feature support matrix as text.
    public var featureMatrix: String {
        var lines = ["Module | Tests | Docs | Contracts | Integration | Restrictions"]
        lines.append(String(repeating: "-", count: 70))
        for r in allRecords {
            let t = r.hasTests ? "YES" : "NO"
            let d = r.hasDocs ? "YES" : "NO"
            let c = r.hasContracts ? "YES" : "NO"
            let i = r.hasIntegrationCoverage ? "YES" : "NO"
            let restr = r.bootstrapRestrictions.isEmpty ? "none" : r.bootstrapRestrictions.joined(separator: ",")
            lines.append("\(r.module) | \(t) | \(d) | \(c) | \(i) | \(restr)")
        }
        return lines.joined(separator: "\n")
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Stdlib Feature Validation Report ==="]
        lines.append("Total modules: \(records.count)")
        lines.append("Green: \(greenModules.count)")
        lines.append("Restricted: \(restrictedModules.count)")
        lines.append("Missing docs: \(missingDocs.count)")
        lines.append("Release ready: \(allReleaseReady)")
        return lines.joined(separator: "\n")
    }
}
