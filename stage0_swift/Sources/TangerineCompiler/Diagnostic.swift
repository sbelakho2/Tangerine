// Diagnostic.swift — Compiler diagnostics
// Part of Tangerine Stage 0 Bootstrap Compiler

/// Severity level of a diagnostic.
public enum Severity: String, Sendable {
    case error
    case warning
    case note
}

/// The compiler stage that produced a diagnostic.
public enum CompilerStage: String, Sendable {
    case lexer
    case parser
    case subsetChecker
    case resolver
    case typeChecker
    case borrowChecker
    case lowering
    case verifier
    case optimizer
    case codegen
    case linker
    case driver
}

/// A single compiler diagnostic with stable error code.
public struct Diagnostic: Sendable {
    public let severity: Severity
    public let code: String
    public let message: String
    public let span: Span
    public let stage: CompilerStage

    public init(
        severity: Severity,
        code: String,
        message: String,
        span: Span,
        stage: CompilerStage
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.span = span
        self.stage = stage
    }
}

/// Collects diagnostics and supports rendering them.
public final class DiagnosticBag {
    public private(set) var diagnostics: [Diagnostic] = []

    public init() {}

    public func emit(_ diag: Diagnostic) {
        diagnostics.append(diag)
    }

    public func error(code: String, message: String, span: Span, stage: CompilerStage) {
        emit(Diagnostic(severity: .error, code: code, message: message, span: span, stage: stage))
    }

    public func warning(code: String, message: String, span: Span, stage: CompilerStage) {
        emit(Diagnostic(severity: .warning, code: code, message: message, span: span, stage: stage))
    }

    public func note(code: String, message: String, span: Span, stage: CompilerStage) {
        emit(Diagnostic(severity: .note, code: code, message: message, span: span, stage: stage))
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    public var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    public var hasWarnings: Bool {
        diagnostics.contains { $0.severity == .warning }
    }

    public var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    /// Render all diagnostics to a human-readable string.
    public func render(sourceMap: SourceMap) -> String {
        var lines: [String] = []
        for diag in diagnostics {
            let loc: String
            if let resolved = sourceMap.resolve(diag.span) {
                loc = "\(resolved.file):\(resolved.line):\(resolved.column)"
            } else {
                loc = "<unknown>"
            }
            lines.append("\(diag.severity.rawValue)[\(diag.code)]: \(diag.message)")
            lines.append("  --> \(loc)")
        }
        return lines.joined(separator: "\n")
    }
}
