// FailureClassification.swift — Stage 13: Structured failure taxonomy

public struct FailureClassification {

    // MARK: - Categories

    public enum Category: String, CaseIterable, Equatable, Hashable {
        case specAmbiguity = "spec-ambiguity"
        case parser = "parser"
        case resolver = "resolver"
        case typing = "typing"
        case ownershipLifetime = "ownership-lifetime"
        case lowering = "lowering"
        case verifier = "verifier"
        case optimizer = "optimizer"
        case codegen = "codegen"
        case abiRuntime = "abi-runtime"
        case stdlibMisuse = "stdlib-misuse"
        case testHarnessBug = "test-harness-bug"
    }

    public enum Tag: String, CaseIterable, Equatable, Hashable {
        case crasher = "crasher"
        case hang = "hang"
        case silentWrongResult = "silent-wrong-result"
        case diagnosticMissing = "diagnostic-missing"
        case diagnosticWrong = "diagnostic-wrong"
        case performanceRegression = "performance-regression"
        case nondeterministic = "nondeterministic"
    }

    // MARK: - Failure record

    public struct FailureRecord: Equatable {
        public let id: String
        public let summary: String
        public let category: Category
        public let tags: [Tag]
        public let stage: Int?
        public let passId: String?
        public let invariantId: String?

        public init(id: String, summary: String, category: Category,
                    tags: [Tag] = [], stage: Int? = nil,
                    passId: String? = nil, invariantId: String? = nil) {
            self.id = id
            self.summary = summary
            self.category = category
            self.tags = tags
            self.stage = stage
            self.passId = passId
            self.invariantId = invariantId
        }
    }

    // MARK: - Registry

    public final class Registry {
        public private(set) var failures: [FailureRecord] = []

        public init() {}

        /// File a new failure. Returns error string if validation fails.
        public func file(_ record: FailureRecord) -> String? {
            if record.id.isEmpty { return "Failure ID must not be empty" }
            if record.summary.isEmpty { return "Summary must not be empty" }
            if failures.contains(where: { $0.id == record.id }) {
                return "Duplicate failure ID: \(record.id)"
            }
            failures.append(record)
            return nil
        }

        public var uncategorized: [FailureRecord] {
            // Every failure must have a category — by design this is always empty
            // because the category field is required in FailureRecord
            []
        }

        public func byCategory() -> [Category: [FailureRecord]] {
            var result: [Category: [FailureRecord]] = [:]
            for cat in Category.allCases { result[cat] = [] }
            for f in failures { result[f.category, default: []].append(f) }
            return result
        }

        public func histogram() -> [(Category, Int)] {
            let grouped = byCategory()
            return Category.allCases.map { ($0, grouped[$0]?.count ?? 0) }
        }

        public func report() -> String {
            var lines: [String] = []
            lines.append("Failure Classification Report")
            lines.append("==============================")
            lines.append("Total failures: \(failures.count)")
            lines.append("Uncategorized: \(uncategorized.count)")
            lines.append("")
            lines.append("Category Histogram:")
            for (cat, count) in histogram() {
                if count > 0 {
                    lines.append("  \(cat.rawValue): \(count)")
                }
            }
            lines.append("")
            for f in failures {
                var line = "[\(f.category.rawValue)] \(f.id): \(f.summary)"
                if let stage = f.stage { line += " (stage \(stage))" }
                if let pass = f.passId { line += " [pass: \(pass)]" }
                if !f.tags.isEmpty {
                    line += " tags: \(f.tags.map(\.rawValue).joined(separator: ", "))"
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
    }
}
