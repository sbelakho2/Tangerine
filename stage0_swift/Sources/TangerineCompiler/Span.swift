// Span.swift — Source location tracking
// Part of Tangerine Stage 0 Bootstrap Compiler

/// A half-open range in a source file: [start, end).
public struct Span: Equatable, Hashable, Sendable {
    /// Byte offset of the first character.
    public let start: Int
    /// Byte offset one past the last character.
    public let end: Int
    /// Index of the source file in the SourceMap.
    public let fileID: Int

    public init(start: Int, end: Int, fileID: Int = 0) {
        self.start = start
        self.end = end
        self.fileID = fileID
    }

    /// A synthetic span for compiler-generated nodes.
    public static let synthetic = Span(start: 0, end: 0, fileID: -1)

    /// Merge two spans into one covering both.
    public func merged(with other: Span) -> Span {
        Span(
            start: min(self.start, other.start),
            end: max(self.end, other.end),
            fileID: self.fileID
        )
    }
}

/// A simple source map that resolves spans to file names and line/column info.
public final class SourceMap {
    public struct FileEntry {
        public let name: String
        public let source: String
        /// Byte offsets marking the start of each line.
        public let lineStarts: [Int]
    }

    public private(set) var files: [FileEntry] = []

    public init() {}

    /// Register a source file. Returns its fileID.
    @discardableResult
    public func addFile(name: String, source: String) -> Int {
        let id = files.count
        let lineStarts = computeLineStarts(source)
        files.append(FileEntry(name: name, source: source, lineStarts: lineStarts))
        return id
    }

    /// Resolve a span to (fileName, line, column). Line and column are 1-based.
    public func resolve(_ span: Span) -> (file: String, line: Int, column: Int)? {
        guard span.fileID >= 0, span.fileID < files.count else { return nil }
        let entry = files[span.fileID]
        let line = findLine(offset: span.start, lineStarts: entry.lineStarts)
        let column = span.start - entry.lineStarts[line - 1] + 1
        return (entry.name, line, column)
    }

    private func findLine(offset: Int, lineStarts: [Int]) -> Int {
        // Binary search for the line containing offset.
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo  // 1-based line number
    }

    private func computeLineStarts(_ source: String) -> [Int] {
        var starts = [0]
        for (i, ch) in source.utf8.enumerated() {
            if ch == UInt8(ascii: "\n") {
                starts.append(i + 1)
            }
        }
        return starts
    }
}
