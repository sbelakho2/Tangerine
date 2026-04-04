// SilentFallbackGuard.swift — Stage 17: Detect and ban silent fallbacks
// Ensures the compiler either knows what it's doing or stops.
// Replaces silent fallbacks with explicit diagnostics or hard failures.

// MARK: - Fallback categories

/// Each category of silent fallback that must be eliminated.
public enum FallbackCategory: String, CaseIterable, Equatable {
    case defaultTyping        = "default-typing"
    case symbolInvention      = "symbol-invention"
    case placeholderIR        = "placeholder-ir"
    case ownershipWeakening   = "ownership-weakening"
    case silentRecovery       = "silent-recovery"
}

// MARK: - Fallback violation

/// A detected silent fallback in the compiler pipeline.
public struct FallbackViolation: Equatable, CustomStringConvertible {
    public let category: FallbackCategory
    public let location: String      // file:line or pass name
    public let summary: String
    public let suggestedFix: String

    public init(category: FallbackCategory, location: String, summary: String, suggestedFix: String) {
        self.category = category
        self.location = location
        self.summary = summary
        self.suggestedFix = suggestedFix
    }

    public var description: String {
        "[\(category.rawValue)] \(location): \(summary) — fix: \(suggestedFix)"
    }
}

// MARK: - FallbackGuard

/// Enforces the ban on silent fallbacks.
/// Scans IR, type annotations, and diagnostics for signs of silent recovery.
public final class FallbackGuard {
    private var violations: [FallbackViolation] = []
    private var waivers: Set<String> = []  // location-based waivers

    public init() {}

    /// Grant a waiver for a specific location (rare, requires justification).
    public func grantWaiver(location: String) {
        waivers.insert(location)
    }

    /// Record a violation. Waivered locations are skipped.
    public func record(_ v: FallbackViolation) {
        guard !waivers.contains(v.location) else { return }
        violations.append(v)
    }

    /// All recorded violations.
    public var allViolations: [FallbackViolation] { violations }

    /// True if no unwaivered violations exist.
    public var isClean: Bool { violations.isEmpty }

    /// Violations grouped by category.
    public func byCategory() -> [FallbackCategory: [FallbackViolation]] {
        Dictionary(grouping: violations, by: { $0.category })
    }

    /// Scan a MIR program for placeholder IR (unknown types, unreachable-only blocks).
    public func scanMIR(_ program: MirProgram) {
        for fn in program.functions {
            for local in fn.locals {
                if local.type == .unknown {
                    record(FallbackViolation(
                        category: .defaultTyping,
                        location: "\(fn.name)/local_\(local.id)",
                        summary: "local has .unknown type (silent typing fallback)",
                        suggestedFix: "emit a type error diagnostic instead of defaulting to .unknown"
                    ))
                }
            }
            for block in fn.blocks {
                // Detect placeholder blocks: empty statements + unreachable terminator
                let isUnreachable: Bool
                if case .unreachable = block.terminator { isUnreachable = true } else { isUnreachable = false }
                if block.statements.isEmpty && isUnreachable && block.id != fn.entryBlock {
                    record(FallbackViolation(
                        category: .placeholderIR,
                        location: "\(fn.name)/block_\(block.id)",
                        summary: "empty unreachable block (placeholder IR)",
                        suggestedFix: "remove placeholder block or emit a diagnostic"
                    ))
                }
                // Detect nop-only blocks (silent stubs)
                let nonNopStmts = block.statements.filter { if case .nop = $0 { return false }; return true }
                if nonNopStmts.isEmpty && !block.statements.isEmpty {
                    record(FallbackViolation(
                        category: .placeholderIR,
                        location: "\(fn.name)/block_\(block.id)",
                        summary: "block contains only .nop statements (silent stub)",
                        suggestedFix: "remove nop-only block or emit a diagnostic"
                    ))
                }
            }
        }
    }

    /// Scan for symbol invention: items whose names start with "__tg_placeholder"
    /// which indicates the compiler invented a symbol to continue.
    public func scanSymbolInvention(_ items: [Item]) {
        for item in items {
            let name: String?
            switch item.kind {
            case .function(let f): name = f.sig.name
            case .structDef(let s): name = s.name
            case .enumDef(let e): name = e.name
            case .traitDef(let t): name = t.name
            case .typeAlias(let ta): name = ta.name
            default: name = nil
            }
            if let n = name, n.hasPrefix("__tg_placeholder") {
                record(FallbackViolation(
                    category: .symbolInvention,
                    location: "item:\(n)",
                    summary: "invented symbol '\(n)' to continue compilation",
                    suggestedFix: "emit unresolved symbol diagnostic instead"
                ))
            }
        }
    }

    /// Scan for ownership weakening: functions marked unsafe that shouldn't be.
    public func scanOwnershipWeakening(_ program: MirProgram) {
        for fn in program.functions {
            if fn.isUnsafe && !fn.name.hasPrefix("unsafe_") && !fn.isExtern {
                record(FallbackViolation(
                    category: .ownershipWeakening,
                    location: "\(fn.name)",
                    summary: "function marked unsafe without naming convention (silent weakening)",
                    suggestedFix: "verify ownership or rename with unsafe_ prefix"
                ))
            }
        }
    }

    /// Full scan: run all checks on a MIR program and AST items.
    public func fullScan(mir: MirProgram, items: [Item]) {
        scanMIR(mir)
        scanSymbolInvention(items)
        scanOwnershipWeakening(mir)
    }

    /// Generate a report.
    public func report() -> String {
        var lines: [String] = ["=== Fallback Guard Report ==="]
        if isClean {
            lines.append("Status: CLEAN (no silent fallbacks detected)")
        } else {
            lines.append("Status: \(violations.count) violation(s)")
            let grouped = byCategory()
            for cat in FallbackCategory.allCases {
                let vs = grouped[cat] ?? []
                if !vs.isEmpty {
                    lines.append("  \(cat.rawValue): \(vs.count)")
                    for v in vs {
                        lines.append("    - \(v)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
