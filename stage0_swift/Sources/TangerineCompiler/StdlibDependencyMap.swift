// StdlibDependencyMap.swift — Stage 11: Stdlib file-to-file and symbol dependency map

public struct StdlibDependencyMap {

    // MARK: - Types

    public struct ImportEdge: Equatable {
        public let targetModule: String
        public let symbols: [String]
    }

    public struct FileEntry: Equatable {
        public let name: String
        public let moduleName: String
        public let imports: [ImportEdge]
        public let definedSymbols: [String]
        public let category: FileCategory
    }

    public enum FileCategory: String, CaseIterable, Equatable {
        case bootstrapCritical = "bootstrap-critical"
        case compilerSupport = "compiler-support"
        case generalPurpose = "general-purpose"
        case noncritical = "noncritical"
    }

    // MARK: - Graph data

    public let entries: [String: FileEntry]
    public let fileDeps: [String: Set<String>]
    public let reverseDeps: [String: Set<String>]
    public let cycles: [[String]]

    // MARK: - Computed category lists

    public var bootstrapCriticalFiles: [String] {
        entries.values.filter { $0.category == .bootstrapCritical }.map(\.name).sorted()
    }

    public var compilerSupportFiles: [String] {
        entries.values.filter { $0.category == .compilerSupport }.map(\.name).sorted()
    }

    public var generalPurposeFiles: [String] {
        entries.values.filter { $0.category == .generalPurpose }.map(\.name).sorted()
    }

    public var noncriticalFiles: [String] {
        entries.values.filter { $0.category == .noncritical }.map(\.name).sorted()
    }

    public var highFanOutFiles: [String] {
        entries.values
            .filter { (fileDeps[$0.name]?.count ?? 0) >= 5 }
            .map(\.name).sorted()
    }

    public var unstableFiles: [String] {
        entries.values.filter {
            (fileDeps[$0.name]?.count ?? 0) >= 4 &&
            (reverseDeps[$0.name]?.count ?? 0) >= 3
        }.map(\.name).sorted()
    }

    public var isAcyclic: Bool { cycles.isEmpty }

    // MARK: - Manifest

    public var manifest: String {
        var lines: [String] = []
        lines.append("Stdlib Dependency Map")
        lines.append("=====================")
        lines.append("Files: \(entries.count)")
        lines.append("Bootstrap-critical: \(bootstrapCriticalFiles.count)")
        lines.append("Compiler-support: \(compilerSupportFiles.count)")
        lines.append("General-purpose: \(generalPurposeFiles.count)")
        lines.append("Noncritical: \(noncriticalFiles.count)")
        lines.append("High-fan-out: \(highFanOutFiles.count)")
        lines.append("Unstable/high-risk: \(unstableFiles.count)")
        lines.append("Cycles: \(cycles.count)")
        lines.append("")
        for name in entries.keys.sorted() {
            let entry = entries[name]!
            let deps = fileDeps[name] ?? []
            let revDeps = reverseDeps[name] ?? []
            lines.append("\(name) [\(entry.category.rawValue)] fan-out=\(deps.count) fan-in=\(revDeps.count)")
            if !deps.isEmpty {
                lines.append("  depends on: \(deps.sorted().joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Build

    public static func build(files: [(name: String, program: Program)]) -> StdlibDependencyMap {
        let bootstrapCriticalModules: Set<String> = [
            "core", "alloc", "collections", "fmt", "io", "process", "env"
        ]
        let compilerSupportModules: Set<String> = [
            "diagnostics", "debug", "backtrace", "test", "log"
        ]

        let knownFiles = Set(files.map(\.name))
        var allEntries: [String: FileEntry] = [:]
        var allFileDeps: [String: Set<String>] = [:]
        var allReverseDeps: [String: Set<String>] = [:]

        for (name, program) in files {
            let moduleName = String(name.dropLast(3)) // remove ".tg"

            let imports = extractImports(from: program)
            let definedSymbols = extractDefinedSymbols(from: program)

            var deps = Set<String>()
            for imp in imports {
                let targetFile = imp.targetModule + ".tg"
                if knownFiles.contains(targetFile) && targetFile != name {
                    deps.insert(targetFile)
                }
            }
            allFileDeps[name] = deps

            for dep in deps {
                allReverseDeps[dep, default: []].insert(name)
            }

            let category: FileCategory
            if bootstrapCriticalModules.contains(moduleName) {
                category = .bootstrapCritical
            } else if compilerSupportModules.contains(moduleName) {
                category = .compilerSupport
            } else {
                category = .generalPurpose
            }

            allEntries[name] = FileEntry(
                name: name, moduleName: moduleName,
                imports: imports, definedSymbols: definedSymbols,
                category: category)
        }

        // Refine: general-purpose files with zero fan-in become noncritical
        for (name, entry) in allEntries {
            if entry.category == .generalPurpose {
                let fanIn = allReverseDeps[name]?.count ?? 0
                if fanIn == 0 {
                    allEntries[name] = FileEntry(
                        name: name, moduleName: entry.moduleName,
                        imports: entry.imports, definedSymbols: entry.definedSymbols,
                        category: .noncritical)
                }
            }
        }

        let cycles = detectCycles(fileDeps: allFileDeps)

        return StdlibDependencyMap(
            entries: allEntries,
            fileDeps: allFileDeps,
            reverseDeps: allReverseDeps,
            cycles: cycles)
    }

    // MARK: - Extraction

    private static func extractImports(from program: Program) -> [ImportEdge] {
        var imports: [ImportEdge] = []
        for item in program.items {
            if case .useDecl(let useDecl) = item.kind {
                if let edge = extractImportEdge(from: useDecl.path) {
                    imports.append(edge)
                }
            }
        }
        return imports
    }

    private static func extractImportEdge(from path: UsePath) -> ImportEdge? {
        switch path {
        case .simple(let segments):
            guard segments.count >= 2, segments[0] == "std" else { return nil }
            return ImportEdge(targetModule: segments[1], symbols: [])
        case .aliased(let segments, _):
            guard segments.count >= 2, segments[0] == "std" else { return nil }
            return ImportEdge(targetModule: segments[1], symbols: [])
        case .glob(let segments):
            guard segments.count >= 2, segments[0] == "std" else { return nil }
            return ImportEdge(targetModule: segments[1], symbols: [])
        case .group(let segments, let items):
            guard segments.count >= 2, segments[0] == "std" else { return nil }
            return ImportEdge(targetModule: segments[1], symbols: items.map(\.name))
        }
    }

    private static func extractDefinedSymbols(from program: Program) -> [String] {
        var symbols: [String] = []
        for item in program.items {
            switch item.kind {
            case .function(let f):   symbols.append(f.sig.name)
            case .structDef(let s):  symbols.append(s.name)
            case .enumDef(let e):    symbols.append(e.name)
            case .traitDef(let t):   symbols.append(t.name)
            case .typeAlias(let t):  symbols.append(t.name)
            case .constDecl(let c):  symbols.append(c.name)
            case .staticDecl(let s): symbols.append(s.name)
            case .macroDecl(let m):  symbols.append(m.name)
            default: break
            }
        }
        return symbols
    }

    // MARK: - Cycle detection (DFS)

    private static func detectCycles(fileDeps: [String: Set<String>]) -> [[String]] {
        enum Color { case white, gray, black }
        var color: [String: Color] = [:]
        var cycles: [[String]] = []
        var path: [String] = []

        for file in fileDeps.keys { color[file] = .white }

        func dfs(_ node: String) {
            color[node] = .gray
            path.append(node)
            for dep in (fileDeps[node] ?? []).sorted() {
                switch color[dep] ?? .white {
                case .white: dfs(dep)
                case .gray:
                    if let idx = path.firstIndex(of: dep) {
                        cycles.append(Array(path[idx...]))
                    }
                case .black: break
                }
            }
            path.removeLast()
            color[node] = .black
        }

        for file in fileDeps.keys.sorted() {
            if color[file] == .white { dfs(file) }
        }
        return cycles
    }
}
