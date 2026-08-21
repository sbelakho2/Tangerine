// SemanticGates.swift — Bootstrap semantic gates
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// The machine-checkable assertion surface for the semantic invariants that
// the stage0 (Swift) front end enforces on the bootstrap subset. Each gate
// maps 1:1 to a registry row in invariants.toml:
//
//   E9029  INV-PARSE-002  String literals are UTF-8 validated
//   E9030  INV-PARSE-003  Numeric literals fit in host integer range
//   V0001  INV-PARSE-007  Spans are well-ordered (start <= end)
//   V0001  INV-PARSE-008  Inverted spans are detected and reported
//   E9032  INV-TYPE-010   Trait objects (dyn/impl type position) are not in
//                         the bootstrap subset (surface removed)
//
// The gates are pure (no side effects) so the differential harness, the
// CLI commands and the test runner share the same assertion code.

import Foundation

// MARK: - Source loader (E9029 — UTF-8 gate)

public enum SourceLoadError: Error, CustomStringConvertible {
    case unreadable(String)
    case notUTF8(String)

    public var description: String {
        switch self {
        case .unreadable(let path):
            return "error: cannot read file '\(path)'"
        case .notUTF8(let path):
            return "error: E9029: source file is not valid UTF-8: '\(path)'"
        }
    }
}

/// Loads a .tg source file with an explicit UTF-8 gate. The Tangerine
/// dialect is UTF-8; a file that fails the decode is rejected with the
/// E9029 diagnostic BEFORE any lexing happens (the lexer operates on the
/// decoded String, which is valid UTF-8 by construction — the byte-level
/// gate is this loader, and the invariant is asserted exactly here).
public enum SourceLoader {
    public static func load(path: String) -> Result<String, SourceLoadError> {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(.unreadable(path))
        }
        guard let source = String(data: data, encoding: .utf8) else {
            return .failure(.notUTF8(path))
        }
        return .success(source)
    }
}

// MARK: - Numeric literal guard (E9030 — host integer range)

/// Validates that an integer literal's magnitude fits in the host Int
/// range. The stage0 front end represents Int literals as strings until MIR
/// lowering; a literal that overflows Int64 would silently truncate at
/// lowering (Int("...") ?? 0). This gate rejects the literal at parse time
/// with E9030 so an out-of-range literal is a diagnostic, never a silent
/// value.
///
/// Accepted spellings (the bootstrap-subset integer grammar):
///   decimal           123
///   hexadecimal       0x1F / 0X1F
///   binary            0b1010 / 0B1010
///   octal             0o17 / 0O17
///   digit separators  1_000_000 and 8_u (separator before the suffix)
///   integer suffixes  u i u8 u16 u32 u64 i8 i16 i32 i64 (stripped before
///                     range evaluation — the suffix selects a narrower
///                     target width; the magnitude gate is the host range)
///
/// The gate is conservative on the signed edge: a literal is a MAGNITUDE
/// (a leading '-' is the unary-negation expression, not part of the
/// literal), and the allowed magnitude domain is the host UNSIGNED range
/// [0, UInt64.max] — the kernel's hash constants (the FNV-1a basis
/// 0xcbf29ce484222325) are unsigned 64-bit values. Values above
/// UInt64.max are rejected with E9030 at parse time, and
/// MIRLowering.parseInt preserves the bit pattern for the unsigned domain
/// (no silent `?? 0` truncation).
public enum NumericLiteralGuard {

    /// True when `literal` fits the host UInt64 magnitude range.
    public static func fitsHostRange(_ literal: String) -> Bool {
        guard let magnitude = magnitudeDigits(literal) else {
            // Unparseable literal — let the normal number parse handle it.
            return true
        }
        let (digits, radix) = magnitude
        guard let value = UInt64(digits, radix: radix) else {
            return false
        }
        return value <= UInt64.max
    }

    /// Returns (digits, radix) for the literal, or nil when the literal is
    /// not an integer spelling the gate understands.
    private static func magnitudeDigits(_ literal: String) -> (String, Int)? {
        var clean = literal
        // Suffix grammar: optional separator underscore, then u|i with an
        // optional width (u, i, u8..u64, i8..i64). The separator-before-
        // suffix spelling (8_u) is language-grade.
        if let r = clean.range(of: #"(?:_)?[ui](?:8|16|32|64)?$"#, options: .regularExpression) {
            clean = String(clean[clean.startIndex..<r.lowerBound])
        }
        clean = clean.replacingOccurrences(of: "_", with: "")
        if clean.hasPrefix("0x") || clean.hasPrefix("0X") {
            return (String(clean.dropFirst(2)), 16)
        }
        if clean.hasPrefix("0b") || clean.hasPrefix("0B") {
            return (String(clean.dropFirst(2)), 2)
        }
        if clean.hasPrefix("0o") || clean.hasPrefix("0O") {
            return (String(clean.dropFirst(2)), 8)
        }
        return (clean, 10)
    }
}

// MARK: - Span ordering gate (V0001 — INV-PARSE-007/008)

/// The span-ordering assertion is implemented in ASTVerifier.verifySpan
/// (diagnostic V0001: start > end is a hard error). This extension adds the
/// "well-ordered for non-synthetic nodes" property (INV-PARSE-007) to the
/// same walk so the registry rows INV-PARSE-007/008 share one assertion:
/// detection (008) and reporting (007) are the same code path.
public extension Span {
    /// True when the span is a real source span with an ordered range.
    /// Synthetic spans (fileID -1) are excluded from the gate.
    var isWellOrdered: Bool {
        if fileID == -1 { return true }
        return start >= 0 && end >= start
    }
}
