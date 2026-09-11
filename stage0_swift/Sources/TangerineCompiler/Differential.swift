// Differential.swift — Stage 20b: stage0-vs-stage3 differential harness
// Part of Tangerine Stage 0 Bootstrap Compiler
//
// The reviewer's item 6: the stage0 fixed-point needs semantic-parity proof
// against the self-host front end. This file implements the differential
// corpus machinery:
//
//   corpus  tests/differential/corpus/*.tg — programs exercising every
//           construct the bootstrap needs (defs, structs, enums, matches,
//           loops, generics, closures, collections, strings, ...).
//   harness compare the NORMALIZED tokens/AST:
//           stage0  : `tg_stage0 lex` / `tg_stage0 dump`
//           stage3  : `<stage3> check <file> --dump-tokens` / `--dump-ast`
//           normalization strips ids and spans (positions, offsets, node
//           ids) and projects each side onto ONE canonical vocabulary.
//
// The normalization is PER-SIDE and isolated: the stage0 side consumes the
// stage0 CLI dump formats; the stage3 side consumes the stage3 dump
// formats. When the stage3 dumps grow richer, only the stage3 normalizer
// changes.
//
// Canonical vocabularies (documented in tests/differential/README.md):
//   tokens:  kw/punct by spelling (def, +, ( ), operators (&&, &mut), and
//            payload-bearing idents (ident:name); literals are kind-only
//            (int, float, str, char) because the two dumps render literal
//            payloads differently; trivia (newline/whitespace/comments) is
//            dropped by BOTH projections (stage0's lex() strips trivia,
//            the stage3 lexer skips whitespace/comments and its normalizer
//            drops Newline tokens).
//   ast:     ordered top-level item-kind sequence (fn, struct, enum, ...) —
//            the granularity the stage3 --dump-ast exposes ("Item: ..."
//            lines). Deeper structure is beyond the stage3 dump's
//            granularity today (documented limit).
//
// A canonical token that no vocabulary entry covers is a NORMALIZATION GAP
// (a distinct verdict): the comparison cannot claim parity over it, and
// the gap is reported, never silently skipped.

import Foundation

// MARK: - Verdicts

public enum DifferentialPhase: String, Equatable, Sendable {
    case tokens
    case ast
}

public enum DifferentialVerdict: Equatable, CustomStringConvertible {
    /// The normalized projections are identical.
    case match
    /// The normalized projections differ; `detail` names the first
    /// divergent line pair (or the count mismatch).
    case divergent(detail: String)
    /// A canonical projection hit a vocabulary gap; `detail` names the
    /// unmapped token/line.
    case normalizationGap(detail: String)

    public var description: String {
        switch self {
        case .match: return "MATCH"
        case .divergent(let d): return "DIVERGENT (\(d))"
        case .normalizationGap(let d): return "NORMALIZATION-GAP (\(d))"
        }
    }
}

public struct DifferentialCaseResult: Equatable, CustomStringConvertible {
    public let file: String
    public let phase: DifferentialPhase
    public let verdict: DifferentialVerdict

    public init(file: String, phase: DifferentialPhase, verdict: DifferentialVerdict) {
        self.file = file
        self.phase = phase
        self.verdict = verdict
    }

    public var description: String {
        "\(file) [\(phase.rawValue)]: \(verdict)"
    }
}

// MARK: - Corpus manifest

/// One corpus case: a file plus its construct-coverage tags and the parity
/// phases it participates in. Negative cases carry `expect` — the exact
/// gate diagnostic code the file MUST produce (E9xxx subset rejection,
/// E9029 UTF-8, E9030 literal range); positive cases carry nil.
public struct CorpusCase: Equatable, Sendable {
    public let file: String
    public let coverage: [String]
    public let parity: [DifferentialPhase]
    public let expect: String?

    public init(file: String, coverage: [String], parity: [DifferentialPhase], expect: String? = nil) {
        self.file = file
        self.coverage = coverage
        self.parity = parity
        self.expect = expect
    }
}

public enum CorpusManifestError: Error, CustomStringConvertible {
    case malformed(line: Int, detail: String)
    case missingField(file: String)

    public var description: String {
        switch self {
        case .malformed(let line, let detail):
            return "corpus manifest malformed at line \(line): \(detail)"
        case .missingField(let file):
            return "corpus case '\(file)' is missing a required field (file/coverage/parity)"
        }
    }
}

/// Parser for the constrained corpus manifest format:
///
///   # comment
///   [case]
///   file = corpus/01_defs_arith.tg
///   coverage = "defs, arith, params"
///   parity = "tokens, ast"
///   expect = "E9030"        # optional: negative cases only
///
/// The format is deliberately line-based and trivial to parse so both the
/// Swift harness and shell tooling share it without a TOML dependency.
public enum CorpusManifest {
    public static func parse(contents: String) throws -> [CorpusCase] {
        var cases: [CorpusCase] = []
        var currentFile: String?
        var coverage: [String] = []
        var parity: [String] = []
        var expect: String?

        func flush() throws {
            guard let file = currentFile else { return }
            guard !coverage.isEmpty else {
                throw CorpusManifestError.missingField(file: file)
            }
            var phases: [DifferentialPhase] = []
            for p in parity {
                guard let phase = DifferentialPhase(rawValue: p) else {
                    throw CorpusManifestError.malformed(
                        line: 0,
                        detail: "unknown parity phase '\(p)' for \(file) (expected tokens|ast)")
                }
                phases.append(phase)
            }
            cases.append(CorpusCase(file: file, coverage: coverage, parity: phases, expect: expect))
            currentFile = nil
            coverage = []
            parity = []
            expect = nil
        }

        for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[case]" {
                try flush()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw CorpusManifestError.malformed(line: index + 1, detail: "expected 'key = value'")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "file":
                try flush()
                currentFile = value
            case "coverage":
                coverage = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            case "parity":
                parity = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            case "expect":
                expect = value.isEmpty ? nil : value
            default:
                throw CorpusManifestError.malformed(
                    line: index + 1,
                    detail: "unknown key '\(key)' (expected file|coverage|parity|expect)")
            }
        }
        try flush()
        return cases
    }
}

// MARK: - Stage0 normalizer (consumes `tg_stage0 lex` / `tg_stage0 dump`)

/// Stage0-side canonical projections. The stage0 CLI formats are the
/// contract: `lex` prints `line:column  <displayName>` per token and a
/// trailing summary line; `dump` prints the ASTDumper indentation tree.
public enum Stage0Normalizer {

    // MARK: Tokens

    /// `lex` output -> canonical token stream (positions stripped).
    public static func tokens(lexOutput: String) -> [String] {
        var out: [String] = []
        for line in lexOutput.components(separatedBy: "\n") {
            guard let canonical = canonicalToken(line: line) else { continue }
            out.append(canonical)
        }
        return fuseAmpMut(out)
    }

    private static func canonicalToken(line: String) -> String? {
        let stripped = stripPositionPrefix(line)
        if stripped.isEmpty { return nil }
        if stripped.hasPrefix("identifier '") && stripped.hasSuffix("'") {
            let name = String(stripped.dropFirst("identifier '".count).dropLast())
            return "ident:\(name)"
        }
        if stripped.hasPrefix("integer '") {
            return "int"
        }
        if stripped.hasPrefix("float '") {
            return "float"
        }
        if stripped == "string literal" { return "str" }
        if stripped == "char literal" { return "char" }
        if stripped == "end of file" { return "eof" }
        if stripped.hasPrefix("'") && stripped.hasSuffix("'") && stripped.count >= 3 {
            let text = String(stripped.dropFirst().dropLast())
            // Keywords are all-letters spellings; operators/punctuation are
            // not. Both map to the bare spelling in the canonical stream.
            return text
        }
        if stripped == "newline" || stripped == "whitespace" || stripped == "comment" || stripped == "doc comment" {
            return nil
        }
        // Unresolvable rendering: normalization gap.
        return "??:\(stripped)"
    }

    /// Removes the `line:col` position prefix (and the `?:?` form) from a
    /// stage0 lex line.
    private static func stripPositionPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"^(\d+|\?):(\d+|\?)\s+"#, options: .regularExpression) {
            return String(trimmed[r.upperBound...])
        }
        return trimmed
    }

    /// `&` `mut` adjacency fusion: the stage0 lexer emits `&` and `mut` as
    /// two tokens; the stage3 lexer emits the fused `AmpMut`. Stream
    /// adjacency implies source adjacency (trivia was already stripped), so
    /// the stage0 projection fuses the pair into `&mut`.
    private static func fuseAmpMut(_ stream: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < stream.count {
            if stream[i] == "&", i + 1 < stream.count, stream[i + 1] == "mut" {
                out.append("&mut")
                i += 2
            } else {
                out.append(stream[i])
                i += 1
            }
        }
        return out
    }

    // MARK: AST

    /// `dump` output -> canonical top-level item-kind sequence.
    /// The dump tree's top level is `Program` (depth 0); items are depth 1
    /// (plus the optional ModulePath marker). Only depth-1 item headers are
    /// projected — the granularity the stage3 --dump-ast exposes.
    public static func astItemKinds(dumpOutput: String) -> [String] {
        var kinds: [String] = []
        for line in dumpOutput.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent)
            guard indent == 2 else { continue }
            guard let kind = canonicalItemKind(line: String(content)) else { continue }
            kinds.append(kind)
        }
        return kinds
    }

    /// Maps a depth-1 ASTDumper item header to the canonical item kind.
    private static func canonicalItemKind(line: String) -> String? {
        if line == "Rationale" { return "rationale" }
        guard let firstWord = line.split(separator: " ", maxSplits: 1).first else { return nil }
        switch firstWord {
        case "Fn": return "fn"
        case "Struct": return "struct"
        case "Enum": return "enum"
        case "Trait": return "trait"
        case "Impl": return "impl"
        case "Use": return "use"
        case "Macro": return "macro"
        case "TypeAlias": return "type-alias"
        case "Const": return "const"
        case "Static": return "static"
        case "Cap": return "capability"
        case "Effect": return "effect"
        case "Edition": return "edition"
        case "Extern": return "extern"
        case "Test": return "test"
        case "Module": return "module"
        default: return nil
        }
    }
}

// MARK: - Stage3 normalizer (consumes `--dump-tokens` / `--dump-ast`)

/// Stage3-side canonical projections. The stage3 CLI formats are the
/// contract:
///   --dump-tokens prints `  <TokenKind rendering> @ <start>..<end>` per
///   token (token_debug in compiler_core.tg); the ` @ ...` suffix is the
///   span and is stripped. Newline tokens are dropped (the stage0 side
///   strips trivia before dumping).
///   --dump-ast prints `  Item: <ItemKind rendering>` per top-level item
///   (print_ast in compiler_core.tg); only the rendering is projected.
///
/// TokenKind renderings are mapped via the vocabulary table below. An
/// unmapped rendering produces a `??:` gap token so the verdict is honest.
public enum Stage3Normalizer {

    // MARK: Tokens

    /// `--dump-tokens` output -> canonical token stream.
    public static func tokens(dumpOutput: String) -> [String] {
        var out: [String] = []
        for line in dumpOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Tokens:" || trimmed.isEmpty { continue }
            guard let render = stripSpanSuffix(trimmed) else { continue }
            guard let canonical = canonicalToken(render: render) else {
                // nil = trivia the stage0 projection also drops (Newline).
                continue
            }
            out.append(canonical)
        }
        return out
    }

    /// Removes the trailing ` @ <start>..<end>` span suffix (token_debug).
    private static func stripSpanSuffix(_ line: String) -> String? {
        guard let r = line.range(of: #" @ -?\d+\.\.-?\d+$"#, options: .regularExpression) else {
            return line.isEmpty ? nil : line
        }
        return String(line[..<r.lowerBound])
    }

    private static func payloadIdent(_ render: String) -> String? {
        guard render.hasPrefix("Ident("), render.hasSuffix(")") else { return nil }
        let inner = String(render.dropFirst("Ident(".count).dropLast())
        if inner.hasPrefix("\""), inner.hasSuffix("\""), inner.count >= 2 {
            return String(inner.dropFirst().dropLast())
        }
        return inner
    }

    private static func canonicalToken(render: String) -> String? {
        if let name = payloadIdent(render) {
            return "ident:\(name)"
        }
        if render.hasPrefix("IntLit(") { return "int" }
        if render.hasPrefix("FloatLit(") { return "float" }
        if render.hasPrefix("StringLit(") { return "str" }
        if render.hasPrefix("CharLit(") { return "char" }
        if render.hasPrefix("Error(") { return "??:\(render)" }
        switch render {
        // Literals / idents are handled above.
        // Keywords
        case "Def": return "def"
        case "End": return "end"
        case "Do": return "do"
        case "If": return "if"
        case "Elsif": return "elsif"
        case "Else": return "else"
        case "While": return "while"
        case "For": return "for"
        case "In": return "in"
        case "Loop": return "loop"
        case "Match": return "match"
        case "When": return "when"
        case "Then": return "then"
        case "Unless": return "unless"
        case "Until": return "until"
        case "Let": return "let"
        case "Mut": return "mut"
        case "Return": return "return"
        case "Break": return "break"
        case "Next": return "next"
        case "Struct": return "struct"
        case "Enum": return "enum"
        case "Trait": return "trait"
        case "Impl": return "impl"
        case "Module": return "module"
        case "Use": return "use"
        case "As": return "as"
        case "Pub": return "pub"
        case "Private": return "private"
        case "Macro": return "macro"
        case "Where": return "where"
        case "True": return "true"
        case "False": return "false"
        case "Nil": return "nil"
        case "Self_": return "self"
        case "SelfType": return "Self"
        case "TkMove": return "move"
        case "TkCopy": return "copy"
        case "TkDrop": return "drop"
        case "TkOwn": return "own"
        case "TkRef": return "&"
        case "TkRefMut": return "&mut"
        case "Inout": return "inout"
        case "Sink": return "sink"
        case "Set": return "set"
        case "Resource": return "resource"
        case "Deinit": return "deinit"
        case "Pre": return "pre"
        case "Post": return "post"
        case "Invariant": return "invariant"
        case "Cap": return "cap"
        case "Unsafe": return "unsafe"
        case "Rationale": return "rationale"
        case "Budget": return "budget"
        case "Edition": return "edition"
        case "Requires": return "requires"
        case "Ensures": return "ensures"
        case "Effect": return "effect"
        case "Pure": return "pure"
        case "Async": return "async"
        case "Await": return "await"
        case "Defer": return "defer"
        case "Try": return "try"
        case "Catch": return "catch"
        case "Finally": return "finally"
        case "Guard": return "guard"
        case "Handle": return "handle"
        case "With": return "with"
        case "Is": return "is"
        case "Implies": return "implies"
        case "Comptime": return "comptime"
        case "Const": return "const"
        case "Static": return "static"
        case "Type": return "type"
        case "Alias": return "alias"
        case "Extern": return "extern"
        case "Inline": return "inline"
        // Operators
        case "Plus": return "+"
        case "Minus": return "-"
        case "Star": return "*"
        case "Slash": return "/"
        case "Percent": return "%"
        case "Eq": return "="
        case "EqEq": return "=="
        case "BangEq": return "!="
        case "Lt": return "<"
        case "Gt": return ">"
        case "LtEq": return "<="
        case "GtEq": return ">="
        case "And": return "&&"
        case "Or": return "||"
        case "Bang": return "!"
        case "Amp": return "&"
        case "AmpMut": return "&mut"
        case "Pipe": return "|"
        case "PipeArrow": return "|>"
        case "Arrow": return "->"
        case "FatArrow": return "=>"
        case "Question": return "?"
        case "ColonColon": return "::"
        case "Dot": return "."
        case "DotDot": return ".."
        case "DotDotEq": return "..="
        case "Tilde": return "~"
        case "Caret": return "^"
        case "DoubleStar": return "**"
        case "Shl": return "<<"
        case "Shr": return ">>"
        case "PlusEq": return "+="
        case "MinusEq": return "-="
        case "StarEq": return "*="
        case "SlashEq": return "/="
        case "PercentEq": return "%="
        case "AmpEq": return "&="
        case "PipeEq": return "|="
        case "CaretEq": return "^="
        case "ShlEq": return "<<="
        case "ShrEq": return ">>="
        // Delimiters / punctuation
        case "LParen": return "("
        case "RParen": return ")"
        case "LBracket": return "["
        case "RBracket": return "]"
        case "LBrace": return "{"
        case "RBrace": return "}"
        case "Colon": return ":"
        case "Semicolon": return ";"
        case "Comma": return ","
        case "At": return "@"
        case "Hash": return "#"
        // Trivia: the stage0 projection drops these; drop them here too.
        case "Newline": return nil
        case "Eof": return "eof"
        default: return "??:\(render)"
        }
    }

    // MARK: AST

    /// `--dump-ast` output -> canonical top-level item-kind sequence.
    public static func astItemKinds(dumpOutput: String) -> [String] {
        var kinds: [String] = []
        for line in dumpOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Item:") else { continue }
            let render = trimmed.dropFirst("Item:".count).trimmingCharacters(in: .whitespaces)
            kinds.append(canonicalItemKind(render: render))
        }
        return kinds
    }

    /// Maps an ItemKind rendering to the canonical item kind. The rendering
    /// shape (variant name with or without payload) is accepted defensively
    /// — the mapping is prefix/contains based so both `ItemFunction` and
    /// `ItemFunction(main)` project to `fn`.
    private static func canonicalItemKind(render: String) -> String {
        if render.hasPrefix("ItemFunction") { return "fn" }
        if render.hasPrefix("ItemStruct") { return "struct" }
        if render.hasPrefix("ItemEnum") { return "enum" }
        if render.hasPrefix("ItemTrait") { return "trait" }
        if render.hasPrefix("ItemImpl") { return "impl" }
        if render.hasPrefix("ItemModule") { return "module" }
        if render.hasPrefix("ItemUse") { return "use" }
        if render.hasPrefix("ItemMacro") { return "macro" }
        if render.hasPrefix("ItemTypeAlias") { return "type-alias" }
        if render.hasPrefix("ItemConst") { return "const" }
        if render.hasPrefix("ItemStatic") { return "static" }
        if render.hasPrefix("ItemCapabilityDecl") { return "capability" }
        if render.hasPrefix("ItemEffectDecl") { return "effect" }
        if render.hasPrefix("ItemRationaleBlock") { return "rationale" }
        if render.hasPrefix("ItemEditionDecl") { return "edition" }
        if render.hasPrefix("ItemExternBlock") { return "extern" }
        // Defensive fallbacks for alternate renderings (e.g. a derived
        // Display printing the payload type instead of the variant name).
        if render.contains("Function") { return "fn" }
        if render.contains("Struct") { return "struct" }
        if render.contains("Enum") { return "enum" }
        if render.contains("Trait") { return "trait" }
        if render.contains("Impl") { return "impl" }
        if render.contains("Module") { return "module" }
        if render.contains("Use") { return "use" }
        if render.contains("Macro") { return "macro" }
        if render.contains("TypeAlias") { return "type-alias" }
        if render.contains("Const") { return "const" }
        if render.contains("Static") { return "static" }
        if render.contains("Capability") { return "capability" }
        if render.contains("Effect") { return "effect" }
        if render.contains("Rationale") { return "rationale" }
        if render.contains("Edition") { return "edition" }
        if render.contains("Extern") { return "extern" }
        if render.contains("Test") { return "test" }
        return "??:\(render)"
    }
}

// MARK: - Comparison

/// Compares two canonical streams and returns the verdict.
public enum DifferentialCompare {
    public static func streams(_ a: [String], _ b: [String], phase: DifferentialPhase) -> DifferentialVerdict {
        if a.contains(where: { $0.hasPrefix("??:") }) {
            return .normalizationGap(detail: a.first { $0.hasPrefix("??:") } ?? "??")
        }
        if b.contains(where: { $0.hasPrefix("??:") }) {
            return .normalizationGap(detail: b.first { $0.hasPrefix("??:") } ?? "??")
        }
        if a == b { return .match }
        if a.count != b.count {
            return .divergent(detail: "count \(a.count) (stage0) vs \(b.count) (stage3)")
        }
        for i in 0..<a.count where a[i] != b[i] {
            return .divergent(detail: "first diff at index \(i): '\(a[i])' (stage0) vs '\(b[i])' (stage3)")
        }
        return .match
    }
}

// MARK: - Report

public struct DifferentialReport: CustomStringConvertible {
    public let results: [DifferentialCaseResult]
    public let corpusGateFailures: [String]
    public let stage3Probe: Stage3ProbeResult?

    public init(results: [DifferentialCaseResult],
                corpusGateFailures: [String],
                stage3Probe: Stage3ProbeResult?) {
        self.results = results
        self.corpusGateFailures = corpusGateFailures
        self.stage3Probe = stage3Probe
    }

    public var matches: [DifferentialCaseResult] {
        results.filter { $0.verdict == .match }
    }

    public var divergent: [DifferentialCaseResult] {
        results.filter {
            if case .divergent = $0.verdict { return true }
            return false
        }
    }

    public var gaps: [DifferentialCaseResult] {
        results.filter {
            if case .normalizationGap = $0.verdict { return true }
            return false
        }
    }

    public var description: String {
        var lines: [String] = ["=== Differential Report (stage0 vs stage3) ==="]
        if let probe = stage3Probe {
            lines.append("Stage3 probe: \(probe)")
        }
        lines.append("Comparisons: \(results.count), MATCH: \(matches.count), DIVERGENT: \(divergent.count), GAP: \(gaps.count)")
        for r in results {
            lines.append("  \(r)")
        }
        if !corpusGateFailures.isEmpty {
            lines.append("Corpus gate failures (stage0-side checks):")
            for f in corpusGateFailures {
                lines.append("  FAIL \(f)")
            }
        }
        if results.isEmpty && corpusGateFailures.isEmpty {
            lines.append("(no cases compared)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Stage3 probe

public enum Stage3ProbeResult: Equatable, CustomStringConvertible {
    case ok(tokens: Bool, ast: Bool)
    case failure(reason: String)

    public var description: String {
        switch self {
        case .ok(let tokens, let ast):
            var parts: [String] = []
            if tokens { parts.append("--dump-tokens") }
            if ast { parts.append("--dump-ast") }
            return "OK (\(parts.joined(separator: ", ")))"
        case .failure(let reason):
            return "FAIL (\(reason))"
        }
    }
}

// MARK: - Stage0 dump formatter

/// Renders the stage0 `lex` token lines. cmdLex and the differential engine
/// share this formatter so the engine consumes exactly the same text the
/// CLI command produces (single source of truth for the dump contract).
public enum Stage0DumpFormatter {
    public static func lexLines(tokens: [Token], sourceMap: SourceMap) -> String {
        var lines: [String] = []
        for tok in tokens {
            if let loc = sourceMap.resolve(tok.span) {
                lines.append("\(loc.line):\(loc.column)  \(tok.kind.displayName)")
            } else {
                lines.append("?:?  \(tok.kind.displayName)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
