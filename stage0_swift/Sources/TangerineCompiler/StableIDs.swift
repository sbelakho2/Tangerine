// StableIDs.swift — Stage 18: Stable error codes, invariant IDs, and pass IDs
// Ensures failures are addressable and comparable across time.

// MARK: - Diagnostic Code Registry

/// Stable diagnostic codes for the compiler.
/// Format: E{layer}{3-digit-number} where layer determines category.
public enum DiagnosticCode: String, CaseIterable, Equatable, Hashable {
    // L0: Lexer errors (E0xxx)
    case E0001 = "E0001"  // unexpected character
    case E0002 = "E0002"  // unterminated string literal
    case E0003 = "E0003"  // unterminated block comment
    case E0004 = "E0004"  // invalid numeric literal
    case E0005 = "E0005"  // invalid escape sequence

    // L1: Parser errors (E1xxx)
    case E1001 = "E1001"  // unexpected token
    case E1002 = "E1002"  // expected 'end' keyword
    case E1003 = "E1003"  // expected expression
    case E1004 = "E1004"  // expected type
    case E1005 = "E1005"  // expected identifier
    case E1006 = "E1006"  // expected parameter list
    case E1007 = "E1007"  // duplicate modifier
    case E1008 = "E1008"  // invalid pattern

    // L2: Resolution errors (E2xxx)
    case E2001 = "E2001"  // unresolved symbol
    case E2002 = "E2002"  // duplicate definition
    case E2003 = "E2003"  // import not found
    case E2004 = "E2004"  // circular dependency
    case E2005 = "E2005"  // ambiguous reference

    // L3: Type errors (E3xxx)
    case E3001 = "E3001"  // type mismatch
    case E3002 = "E3002"  // missing return type
    case E3003 = "E3003"  // cannot infer type
    case E3004 = "E3004"  // invalid cast
    case E3005 = "E3005"  // trait not satisfied

    // L4: Ownership/lifetime errors (E4xxx)
    case E4001 = "E4001"  // use after move
    case E4002 = "E4002"  // double free
    case E4003 = "E4003"  // dangling reference
    case E4004 = "E4004"  // mutable borrow conflict

    // L5: Lowering/codegen errors (E5xxx)
    case E5001 = "E5001"  // unlowerable construct
    case E5002 = "E5002"  // ABI incompatibility
    case E5003 = "E5003"  // unsupported target

    // L6: Verifier errors (E6xxx)
    case E6001 = "E6001"  // invariant violation
    case E6002 = "E6002"  // invalid IR structure

    public var layer: String {
        let prefix = rawValue.prefix(2)
        switch prefix {
        case "E0": return "lexer"
        case "E1": return "parser"
        case "E2": return "resolution"
        case "E3": return "typing"
        case "E4": return "ownership"
        case "E5": return "lowering"
        case "E6": return "verifier"
        default: return "unknown"
        }
    }
}

// MARK: - Invariant ID Registry

/// Stable invariant IDs. Each invariant checked by the verifier has a fixed ID.
public enum InvariantID: String, CaseIterable, Equatable, Hashable {
    case INV001 = "INV-001"  // every block has a terminator
    case INV002 = "INV-002"  // no duplicate block IDs
    case INV003 = "INV-003"  // no duplicate local IDs
    case INV004 = "INV-004"  // entry block exists
    case INV005 = "INV-005"  // return local exists
    case INV006 = "INV-006"  // all blocks reachable from entry
    case INV007 = "INV-007"  // all referenced locals exist
    case INV008 = "INV-008"  // terminator targets valid blocks
    case INV009 = "INV-009"  // no use of moved value
    case INV010 = "INV-010"  // type consistency in assignments
    case INV011 = "INV-011"  // function signature matches body
    case INV012 = "INV-012"  // no orphan blocks
}

// MARK: - Pass ID Registry

/// Stable pass IDs for compiler passes.
public enum PassID: String, CaseIterable, Equatable, Hashable {
    case PASS_LEX       = "PASS-LEX"
    case PASS_PARSE     = "PASS-PARSE"
    case PASS_RESOLVE   = "PASS-RESOLVE"
    case PASS_TYPECHECK = "PASS-TYPECHECK"
    case PASS_OWNERSHIP = "PASS-OWNERSHIP"
    case PASS_LOWER     = "PASS-LOWER"
    case PASS_VERIFY    = "PASS-VERIFY"
    case PASS_OPTIMIZE  = "PASS-OPTIMIZE"
    case PASS_CODEGEN   = "PASS-CODEGEN"
    case PASS_LINK      = "PASS-LINK"
}

// MARK: - Structured Failure Bundle

/// A failure that carries all required stable IDs.
public struct FailureBundle: Equatable, CustomStringConvertible {
    public let diagnosticCode: DiagnosticCode
    public let invariantID: InvariantID?
    public let passID: PassID
    public let message: String
    public let location: String?

    public init(diagnosticCode: DiagnosticCode, invariantID: InvariantID? = nil,
                passID: PassID, message: String, location: String? = nil) {
        self.diagnosticCode = diagnosticCode
        self.invariantID = invariantID
        self.passID = passID
        self.message = message
        self.location = location
    }

    public var description: String {
        var parts = [diagnosticCode.rawValue]
        if let inv = invariantID { parts.append(inv.rawValue) }
        parts.append(passID.rawValue)
        parts.append(message)
        if let loc = location { parts.append("at \(loc)") }
        return parts.joined(separator: " | ")
    }

    /// Validate: ensures required IDs are present and well-formed.
    public var isValid: Bool {
        !diagnosticCode.rawValue.isEmpty && !passID.rawValue.isEmpty && !message.isEmpty
    }
}

// MARK: - ID Policy

/// Frozen naming policy for IDs.
public enum IDPolicy {
    /// Diagnostic codes match E{digit}{3digits} pattern.
    public static func isValidDiagnosticCode(_ code: String) -> Bool {
        code.count == 5 && code.hasPrefix("E") &&
            code.dropFirst().allSatisfy { $0.isNumber }
    }

    /// Invariant IDs match INV-{3digits} pattern.
    public static func isValidInvariantID(_ id: String) -> Bool {
        id.count == 7 && id.hasPrefix("INV-") &&
            id.dropFirst(4).allSatisfy { $0.isNumber }
    }

    /// Pass IDs match PASS-{UPPERCASE} pattern.
    public static func isValidPassID(_ id: String) -> Bool {
        id.hasPrefix("PASS-") && id.count > 5 &&
            id.dropFirst(5).allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// Full snapshot of all registered IDs for diffing.
    public static func snapshot() -> String {
        var lines: [String] = ["=== StableID Snapshot ==="]
        lines.append("Diagnostic Codes (\(DiagnosticCode.allCases.count)):")
        for code in DiagnosticCode.allCases {
            lines.append("  \(code.rawValue) [\(code.layer)]")
        }
        lines.append("Invariant IDs (\(InvariantID.allCases.count)):")
        for inv in InvariantID.allCases {
            lines.append("  \(inv.rawValue)")
        }
        lines.append("Pass IDs (\(PassID.allCases.count)):")
        for pass in PassID.allCases {
            lines.append("  \(pass.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}
