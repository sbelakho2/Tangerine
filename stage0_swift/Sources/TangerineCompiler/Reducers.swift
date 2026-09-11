// Reducers.swift — Stage 15: Source and IR reducers for failure minimization

public struct Reducers {

    // MARK: - Source Reducer

    /// Minimizes a Tangerine source file while preserving a failure condition.
    public struct SourceReducer {
        public let original: String

        public init(source: String) {
            self.original = source
        }

        /// Attempt to reduce source by removing lines one at a time.
        /// `predicate` returns true if the failure still reproduces on the given source.
        public func reduce(predicate: (String) -> Bool) -> String {
            var lines = original.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var i = 0
            while i < lines.count {
                var candidate = lines
                candidate.remove(at: i)
                let candidateStr = candidate.joined(separator: "\n")
                if predicate(candidateStr) {
                    lines = candidate
                } else {
                    i += 1
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Module Reducer

    /// Minimizes a set of modules/files while preserving a failure condition.
    public struct ModuleReducer {
        public let files: [String]

        public init(files: [String]) {
            self.files = files
        }

        /// Remove files one at a time; keep the removal if predicate still holds.
        public func reduce(predicate: ([String]) -> Bool) -> [String] {
            var current = files
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }

    // MARK: - Symbol Reducer

    /// Minimizes top-level items in a program while preserving a failure.
    public struct SymbolReducer {
        public let items: [Item]

        public init(items: [Item]) {
            self.items = items
        }

        /// Remove items one at a time; keep the removal if predicate still holds.
        public func reduce(predicate: ([Item]) -> Bool) -> [Item] {
            var current = items
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }

    // MARK: - IR Reducer

    /// Minimizes MIR functions while preserving a failure.
    public struct IRReducer {
        public let functions: [MirFunction]

        public init(functions: [MirFunction]) {
            self.functions = functions
        }

        /// Remove functions one at a time; keep the removal if predicate still holds.
        public func reduce(predicate: ([MirFunction]) -> Bool) -> [MirFunction] {
            var current = functions
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }

    // MARK: - Pass Sequence Reducer

    /// Minimizes a pass sequence while preserving a failure.
    public struct PassSequenceReducer {
        public let passes: [String]

        public init(passes: [String]) {
            self.passes = passes
        }

        public func reduce(predicate: ([String]) -> Bool) -> [String] {
            var current = passes
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }

    // MARK: - Trace Reducer

    /// Minimizes a runtime trace while preserving a failure.
    public struct TraceReducer {
        public let entries: [String]

        public init(entries: [String]) {
            self.entries = entries
        }

        public func reduce(predicate: ([String]) -> Bool) -> [String] {
            var current = entries
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }

    // MARK: - Stdlib Dependency Reducer

    /// Minimizes stdlib dependencies while preserving a failure.
    public struct DependencyReducer {
        public let deps: [String]

        public init(deps: [String]) {
            self.deps = deps
        }

        public func reduce(predicate: ([String]) -> Bool) -> [String] {
            var current = deps
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if predicate(candidate) {
                    current = candidate
                } else {
                    i += 1
                }
            }
            return current
        }
    }
}
