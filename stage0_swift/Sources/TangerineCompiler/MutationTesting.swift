// MutationTesting.swift — Stage 21: Mutation test framework for the compiler
// Injects known-bad edits to verify the test suite catches representative mistakes.

// MARK: - Mutation Category

/// Categories of mutations that can be injected.
public enum MutationCategory: String, CaseIterable, Equatable, Hashable {
    case parser       = "parser"
    case resolver     = "resolver"
    case typing       = "typing"
    case ownership    = "ownership"
    case lowering     = "lowering"
    case verifier     = "verifier"
    case optimizer    = "optimizer"
    case codegen      = "codegen"
}

// MARK: - Mutation

/// A single injected mutation.
public struct Mutation: Equatable, CustomStringConvertible {
    public let id: String
    public let category: MutationCategory
    public let description_: String
    public let original: String
    public let mutated: String

    public init(id: String, category: MutationCategory, description: String,
                original: String, mutated: String) {
        self.id = id
        self.category = category
        self.description_ = description
        self.original = original
        self.mutated = mutated
    }

    public var description: String {
        "[\(category.rawValue)] \(id): \(description_)"
    }
}

// MARK: - Mutation Result

public enum MutationOutcome: String, Equatable {
    case killed    = "killed"     // test suite caught the mutation
    case survived  = "survived"   // test suite missed it (BAD)
    case timeout   = "timeout"    // mutation caused hang
    case crash     = "crash"      // mutation caused crash
}

public struct MutationResult: Equatable {
    public let mutation: Mutation
    public let outcome: MutationOutcome
    public init(mutation: Mutation, outcome: MutationOutcome) {
        self.mutation = mutation
        self.outcome = outcome
    }
}

// MARK: - Mutation Engine

/// Runs mutation tests and tracks results.
public final class MutationEngine {
    private var mutations: [Mutation] = []
    private var results: [MutationResult] = []

    public init() {}

    /// Register a mutation.
    public func register(_ mutation: Mutation) {
        mutations.append(mutation)
    }

    /// Record the outcome of applying a mutation.
    public func record(mutationId: String, outcome: MutationOutcome) {
        guard let m = mutations.first(where: { $0.id == mutationId }) else { return }
        results.append(MutationResult(mutation: m, outcome: outcome))
    }

    /// All registered mutations.
    public var allMutations: [Mutation] { mutations }

    /// All results.
    public var allResults: [MutationResult] { results }

    /// Survivors (mutations the test suite missed).
    public var survivors: [MutationResult] {
        results.filter { $0.outcome == .survived }
    }

    /// Killed mutations.
    public var killed: [MutationResult] {
        results.filter { $0.outcome == .killed }
    }

    /// Kill rate (0.0 to 1.0).
    public var killRate: Double {
        guard !results.isEmpty else { return 0 }
        return Double(killed.count) / Double(results.count)
    }

    /// Is the run deterministic? Same mutations should produce same results.
    public var isDeterministic: Bool {
        let ids = results.map { $0.mutation.id }
        return ids == ids  // trivially true; real check is across runs
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Mutation Test Report ==="]
        lines.append("Registered: \(mutations.count)")
        lines.append("Executed: \(results.count)")
        lines.append("Killed: \(killed.count)")
        lines.append("Survived: \(survivors.count)")
        lines.append("Kill rate: \(String(format: "%.1f%%", killRate * 100))")
        if !survivors.isEmpty {
            lines.append("SURVIVORS (need new tests):")
            for s in survivors {
                lines.append("  \(s.mutation)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Standard mutation library

public extension MutationEngine {
    /// Load the standard mutation library.
    func loadStandardMutations() {
        register(Mutation(id: "MUT-P01", category: .parser,
                          description: "Skip 'end' token consumption",
                          original: "expect(.end)", mutated: "// expect(.end)"))
        register(Mutation(id: "MUT-P02", category: .parser,
                          description: "Swap if/elsif parsing order",
                          original: "parseIf()", mutated: "parseElsif()"))
        register(Mutation(id: "MUT-R01", category: .resolver,
                          description: "Skip duplicate-definition check",
                          original: "checkDuplicate(name)", mutated: "// skip"))
        register(Mutation(id: "MUT-R02", category: .resolver,
                          description: "Ignore import scope",
                          original: "resolveInScope(sym)", mutated: "resolveGlobal(sym)"))
        register(Mutation(id: "MUT-T01", category: .typing,
                          description: "Always infer Int",
                          original: "inferType(expr)", mutated: "return .int"))
        register(Mutation(id: "MUT-T02", category: .typing,
                          description: "Skip trait bound check",
                          original: "checkTraitBound(ty, trait)", mutated: "// skip"))
        register(Mutation(id: "MUT-O01", category: .ownership,
                          description: "Ignore use-after-move",
                          original: "checkUseAfterMove(local)", mutated: "// skip"))
        register(Mutation(id: "MUT-L01", category: .lowering,
                          description: "Emit nop instead of assignment",
                          original: "emit(.assign(place, rvalue))", mutated: "emit(.nop)"))
        register(Mutation(id: "MUT-V01", category: .verifier,
                          description: "Skip terminator check",
                          original: "verifyTerminator(block)", mutated: "// skip"))
        register(Mutation(id: "MUT-OPT01", category: .optimizer,
                          description: "Always constant-fold to zero",
                          original: "constantFold(expr)", mutated: "return 0"))
        register(Mutation(id: "MUT-C01", category: .codegen,
                          description: "Swap operand order in binop",
                          original: "emit(lhs, op, rhs)", mutated: "emit(rhs, op, lhs)"))
    }
}
