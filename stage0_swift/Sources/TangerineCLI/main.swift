// main.swift — Entry point for the Tangerine Stage 0 Bootstrap Compiler
// Part of Tangerine Stage 0 Bootstrap Compiler

import TangerineCompiler
import Foundation

@main
struct TangerineCLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            return
        }

        let command = args[1]
        switch command {
        case "lex":
            guard args.count >= 3 else {
                fputs("error: 'lex' requires a file path\n", stderr)
                exit(1)
            }
            cmdLex(path: args[2])
        case "parse":
            guard args.count >= 3 else {
                fputs("error: 'parse' requires a file path\n", stderr)
                exit(1)
            }
            cmdParse(path: args[2])
        case "check":
            guard args.count >= 3 else {
                fputs("error: 'check' requires a file path\n", stderr)
                exit(1)
            }
            cmdCheck(path: args[2])
        case "scan":
            guard args.count >= 3 else {
                fputs("error: 'scan' requires a directory path\n", stderr)
                exit(1)
            }
            cmdScan(dirPath: args[2])
        case "dump":
            guard args.count >= 3 else {
                fputs("error: 'dump' requires a file path\n", stderr)
                exit(1)
            }
            cmdDump(path: args[2])
        case "hash":
            guard args.count >= 3 else {
                fputs("error: 'hash' requires a file path\n", stderr)
                exit(1)
            }
            cmdHash(path: args[2])
        case "lower":
            guard args.count >= 3 else {
                fputs("error: 'lower' requires a file path\n", stderr)
                exit(1)
            }
            cmdLower(path: args[2])
        case "interpret":
            let trace = args.contains("--trace")
            let interpArgs = args.dropFirst(2).filter { $0 != "--trace" }
            guard let interpPath = interpArgs.first else {
                fputs("error: 'interpret' requires a file path\n", stderr)
                exit(1)
            }
            cmdInterpret(path: interpPath, trace: trace)
        case "passes":
            cmdPasses()
        case "depmap":
            guard args.count >= 3 else {
                fputs("error: 'depmap' requires a stdlib directory path\n", stderr)
                exit(1)
            }
            cmdDepmap(dir: args[2])
        case "selfhost":
            let trace = args.contains("--trace")
            let dryRun = args.contains("--dry-run")
            cmdSelfHost(trace: trace, dryRun: dryRun)
        case "compile":
            let trace = args.contains("--trace")
            var outputPath = "build/a.out"
            var targetTriple: String? = nil
            var targetFiles: [String] = []
            var i = 2
            while i < args.count {
                let arg = args[i]
                if arg == "-o" && i + 1 < args.count {
                    outputPath = args[i + 1]
                    i += 2
                } else if arg == "--target" && i + 1 < args.count {
                    targetTriple = args[i + 1]
                    i += 2
                } else if arg == "--trace" {
                    i += 1
                } else {
                    targetFiles.append(arg)
                    i += 1
                }
            }
            guard !targetFiles.isEmpty else {
                fputs("error: 'compile' requires at least one .tg file\n", stderr)
                exit(1)
            }
            cmdCompile(targetFiles: targetFiles, outputPath: outputPath, trace: trace, targetTriple: targetTriple)
        case "version":
            print("tg_stage0 0.1.0 (Swift bootstrap)")
        case "help":
            printUsage()
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage: tg_stage0 <command> [args]

        Commands:
          lex <file>       Lex a .tg file and print tokens
          parse <file>     Parse a .tg file and print AST summary
          check <file>     Parse + subset check a .tg file
          scan <dir>       Scan a directory of .tg files (parse + subset check)
          dump <file>      Parse + dump deterministic AST tree
          hash <file>      Parse + print normalized AST hash
          lower <file>     Parse + lower to MIR and pretty-print
          interpret <file> [--trace]  Parse + lower + interpret via MIR
          passes           Print the compiler pass manifest
          depmap <dir>     Build stdlib dependency map from a directory of .tg files
          selfhost [--trace] [--dry-run]  Self-host: parse+lower+merge+interpret tg_compiler
          compile <file> [-o output] [--trace]  Compile .tg to native binary via self-hosted compiler
          version          Print version info
          help             Print this help message
        """)
    }

    static func cmdLex(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()

        for tok in tokens {
            if let loc = sourceMap.resolve(tok.span) {
                print("\(loc.line):\(loc.column)  \(tok.kind.displayName)")
            } else {
                print("?:?  \(tok.kind.displayName)")
            }
        }

        if diags.hasErrors {
            fputs("\n\(diags.render(sourceMap: sourceMap))\n", stderr)
            exit(1)
        }
        print("\n\(tokens.count) tokens, 0 errors")
    }

    static func cmdParse(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()
        let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
        let program = parser.parseProgram()

        if !diags.hasErrors {
            let verifier = ASTVerifier(diagnostics: diags)
            verifier.verify(program)
        }

        print("Parsed \(program.items.count) top-level items")
        for item in program.items {
            print("  \(item.kind.summary)")
        }

        if diags.hasErrors {
            fputs("\n\(diags.render(sourceMap: sourceMap))\n", stderr)
            exit(1)
        }
        print("\n0 errors")
    }

    static func cmdCheck(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()
        let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
        let program = parser.parseProgram()

        if !diags.hasErrors {
            let verifier = ASTVerifier(diagnostics: diags)
            verifier.verify(program)
        }

        if !diags.hasErrors {
            let checker = SubsetChecker(diagnostics: diags)
            checker.check(program)
        }

        print("Parsed \(program.items.count) top-level items")
        for item in program.items {
            print("  \(item.kind.summary)")
        }

        if diags.hasErrors {
            fputs("\n\(diags.render(sourceMap: sourceMap))\n", stderr)
            exit(1)
        }
        print("\n0 errors")
    }

    static func cmdScan(dirPath: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dirPath) else {
            fputs("error: cannot open directory '\(dirPath)'\n", stderr)
            exit(1)
        }
        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".tg") {
                files.append("\(dirPath)/\(file)")
            }
        }
        files.sort()

        var totalErrors = 0
        var totalFiles = 0
        for file in files {
            totalFiles += 1
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
                fputs("error: cannot read '\(file)'\n", stderr)
                totalErrors += 1
                continue
            }
            let sourceMap = SourceMap()
            let fileID = sourceMap.addFile(name: file, source: source)
            let diags = DiagnosticBag()
            let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
            let tokens = lexer.lex()
            let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
            let program = parser.parseProgram()

            if !diags.hasErrors {
                let verifier = ASTVerifier(diagnostics: diags)
                verifier.verify(program)
            }

            if !diags.hasErrors {
                let checker = SubsetChecker(diagnostics: diags)
                checker.check(program)
            }

            if diags.hasErrors {
                fputs("FAIL \(file): \(diags.errorCount) errors\n", stderr)
                fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
                totalErrors += diags.errorCount
            } else {
                print("OK   \(file)")
            }
        }
        print("\nScanned \(totalFiles) files, \(totalErrors) total errors")
        if totalErrors > 0 {
            exit(1)
        }
    }

    static func cmdDump(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()
        let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
        let program = parser.parseProgram()

        if diags.hasErrors {
            fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
            exit(1)
        }

        let dumper = ASTDumper()
        print(dumper.dump(program))
    }

    static func cmdHash(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()
        let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
        let program = parser.parseProgram()

        if diags.hasErrors {
            fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
            exit(1)
        }

        let dumper = ASTDumper()
        let hashHex = dumper.hashHex(program)
        print("parse:\(hashHex)  \(path)")
    }

    static func cmdLower(path: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("error: cannot read file '\(path)'\n", stderr)
            exit(1)
        }
        let sourceMap = SourceMap()
        let fileID = sourceMap.addFile(name: path, source: source)
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
        let tokens = lexer.lex()
        let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
        let program = parser.parseProgram()

        if diags.hasErrors {
            fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
            exit(1)
        }

        let lowering = MIRLowering(moduleName: moduleName(for: path))
        let mir = lowering.lower(program)
        if lowering.hasErrors {
            reportLoweringFailure(file: path, errors: lowering.errors)
            exit(1)
        }
        let printer = MIRPrettyPrinter()
        print(printer.print(mir))
    }

    static func cmdInterpret(path: String, trace: Bool) {
        let fm = FileManager.default

        func parseProgram(file: String) -> Program? {
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
                fputs("error: cannot read file '\(file)'\n", stderr)
                return nil
            }
            let sourceMap = SourceMap()
            let fileID = sourceMap.addFile(name: file, source: source)
            let diags = DiagnosticBag()
            let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
            let tokens = lexer.lex()
            let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
            let program = parser.parseProgram()
            if diags.hasErrors {
                fputs("\n[interpret] parse failed: \(file)\n", stderr)
                fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
                return nil
            }
            return program
        }

        // Use the bootstrap profile std files instead of loading ALL std files.
        // Some std files (e.g. blas.tg) use syntax not yet supported by the parser,
        // which would cause all interpret commands to fail.
        let profileFiles = BootstrapProfile.profileFiles
        var filesToLoad: [String] = []
        for file in profileFiles {
            let fullPath = ("std" as NSString).appendingPathComponent(file)
            if fm.fileExists(atPath: fullPath) {
                filesToLoad.append(fullPath)
            }
        }
        filesToLoad.sort()
        if !filesToLoad.contains(path) {
            filesToLoad.append(path)
        }

        var modules: [(name: String, program: Program)] = []
        for file in filesToLoad {
            guard let program = parseProgram(file: file) else {
                exit(1)
            }
            modules.append((name: moduleName(for: file), program: program))
        }

        var allTypes: [MirTypeDef] = []
        for module in modules {
            let collector = MIRLowering(moduleName: module.name)
            allTypes.append(contentsOf: collector.collectTypes(module.program))
        }

        var merged = MirProgram()
        for module in modules {
            let lowering = MIRLowering(moduleName: module.name)
            lowering.preloadTypes(allTypes)
            let mir = lowering.lower(module.program)
            if lowering.hasErrors {
                reportLoweringFailure(file: module.name, errors: lowering.errors,
                                      context: "error: interpret lowering failed")
                exit(1)
            }
            merged.functions.append(contentsOf: mir.functions)
            merged.statics.append(contentsOf: mir.statics)
            merged.typeDefs.append(contentsOf: mir.typeDefs)
        }

        let interp = MIRInterpreter(program: merged, enableTrace: trace)
        let result = interp.run()

        for line in result.output {
            print(line)
        }

        if trace {
            fputs("\n--- TRACE ---\n", stderr)
            for entry in result.trace {
                fputs("[\(entry.kind.rawValue)] \(entry.function) bb\(entry.block): \(entry.detail)\n", stderr)
            }
            fputs("--- END TRACE ---\n", stderr)
        }

        if result.exitCode != 0 {
            exit(Int32(result.exitCode))
        }
    }

    static func cmdPasses() {
        let pm = PassManager(mode: .correctness)
        print(pm.manifest)
    }

    static func cmdDepmap(dir: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            fputs("error: cannot open directory '\(dir)'\n", stderr)
            exit(1)
        }
        let tgFiles = entries.filter { $0.hasSuffix(".tg") }.sorted()
        if tgFiles.isEmpty {
            fputs("error: no .tg files found in '\(dir)'\n", stderr)
            exit(1)
        }
        var parsed: [(name: String, program: Program)] = []
        for file in tgFiles {
            let fullPath = (dir as NSString).appendingPathComponent(file)
            guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                fputs("warning: cannot read '\(fullPath)', skipping\n", stderr)
                continue
            }
            let sourceMap = SourceMap()
            let fileID = sourceMap.addFile(name: file, source: source)
            let diags = DiagnosticBag()
            let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
            let tokens = lexer.lex()
            let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
            let program = parser.parseProgram()
            parsed.append((name: file, program: program))
        }
        let depMap = StdlibDependencyMap.build(files: parsed)
        print(depMap.manifest)
        if !depMap.isAcyclic {
            print("\nWARNING: Dependency cycles detected:")
            for cycle in depMap.cycles {
                print("  \(cycle.joined(separator: " -> "))")
            }
        }
    }

    private struct ParsedBootstrapModule {
        let path: String
        let moduleName: String
        let program: Program
        let stageHash: UInt64
    }

    private struct BootstrapParseResult {
        let modules: [ParsedBootstrapModule]
        let errorCount: Int
        let stageHashes: [String: UInt64]
    }

    private struct BootstrapLoweringStats {
        let file: String
        let functionCount: Int
        let staticCount: Int
        let typeCount: Int
    }

    private struct BootstrapLoweringResult {
        let mir: MirProgram
        let moduleStats: [BootstrapLoweringStats]
    }

    private struct LoweringFailure: Error {
        let file: String
        let errors: [String]
    }

    private struct FunctionCatalog {
        let allQualifiedNames: Set<String>
        let localQualifiedFreeFunctions: [String: [String: String]]
        let uniqueQualifiedFreeFunctions: [String: String]
    }

    private static func moduleName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".tg") else { return name }
        return String(name.dropLast(3))
    }

    private static func collectTgFiles(in dir: String, fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
            fputs("error: cannot read directory '\(dir)'\n", stderr)
            exit(1)
        }
        return entries.filter { $0.hasSuffix(".tg") }.sorted().map {
            (dir as NSString).appendingPathComponent($0)
        }
    }

    private static func reportLoweringFailure(file: String, errors: [String], context: String = "error: lowering failed") {
        fputs("\(context): \(file)\n", stderr)
        for error in errors {
            fputs("  \(error)\n", stderr)
        }
    }

    /// Parse the compiler kernel manifest (bootstrap/compiler_kernel.manifest).
    /// Returns (stdFiles, compilerFiles) relative paths. Returns nil when the
    /// manifest is absent so callers can fall back to directory scanning.
    private static func readKernelManifest(fileManager: FileManager = .default) -> (stdFiles: [String], compilerFiles: [String])? {
        let manifestPath = "bootstrap/compiler_kernel.manifest"
        guard fileManager.fileExists(atPath: manifestPath),
              let text = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            return nil
        }

        var stdFiles: [String] = []
        var compilerFiles: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            switch key {
            case "std":
                stdFiles.append(value)
            case "compiler":
                compilerFiles.append(value)
            default:
                continue
            }
        }

        guard !stdFiles.isEmpty || !compilerFiles.isEmpty else { return nil }
        return (stdFiles.sorted(), compilerFiles.sorted())
    }

    private static func collectBootstrapCompilerFiles(fileManager: FileManager = .default) -> (stdFiles: [String], compilerFiles: [String]) {
        // Kernel is manifest-driven (single source of truth). The manifest
        // shrinks the bootstrap closure to the minimal self-hostable module
        // set instead of scanning every .tg under tg_compiler/.
        if let kernel = readKernelManifest(fileManager: fileManager) {
            let availableStd = Set(collectTgFiles(in: "std", fileManager: fileManager).map {
                ($0 as NSString).lastPathComponent
            })
            let missingProfileFiles = kernel.stdFiles.filter { !availableStd.contains($0) }
            if !missingProfileFiles.isEmpty {
                fputs("error: missing bootstrap profile stdlib files:\n", stderr)
                for missing in missingProfileFiles {
                    fputs("  \(missing)\n", stderr)
                }
                exit(1)
            }
            let stdFiles = kernel.stdFiles.map { ("std" as NSString).appendingPathComponent($0) }
            let compilerFiles = kernel.compilerFiles.map { ("tg_compiler" as NSString).appendingPathComponent($0) }
            return (stdFiles, compilerFiles)
        }

        // Fallback (no manifest): previous behavior — full directory scan.
        let availableStd = Set(collectTgFiles(in: "std", fileManager: fileManager).map {
            ($0 as NSString).lastPathComponent
        })
        let missingProfileFiles = BootstrapProfile.profileFiles.filter { !availableStd.contains($0) }
        if !missingProfileFiles.isEmpty {
            fputs("error: missing bootstrap profile stdlib files:\n", stderr)
            for missing in missingProfileFiles {
                fputs("  \(missing)\n", stderr)
            }
            exit(1)
        }

        let stdFiles = BootstrapProfile.profileFiles.map {
            ("std" as NSString).appendingPathComponent($0)
        }
        let compilerFiles = collectTgFiles(in: "tg_compiler", fileManager: fileManager)
        return (stdFiles, compilerFiles)
    }

    private static func parseValidatedModules(files: [String], enforceSubset: Bool) -> BootstrapParseResult {
        var parsedModules: [ParsedBootstrapModule] = []
        var errorCount = 0
        var stageHashes: [String: UInt64] = [:]

        for file in files {
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
                fputs("  SKIP \(file): cannot read\n", stderr)
                errorCount += 1
                continue
            }

            let sourceMap = SourceMap()
            let fileID = sourceMap.addFile(name: file, source: source)
            let diags = DiagnosticBag()
            let lexer = Lexer(source: source, fileID: fileID, diagnostics: diags)
            let tokens = lexer.lex()
            let parser = Parser(tokens: tokens, source: source, fileID: fileID, diagnostics: diags)
            let program = parser.parseProgram()

            if !diags.hasErrors {
                let verifier = ASTVerifier(diagnostics: diags)
                verifier.verify(program)
            }

            if enforceSubset && !diags.hasErrors {
                let checker = SubsetChecker(diagnostics: diags)
                checker.check(program)
            }

            if diags.hasErrors {
                fputs("  FAIL \(file): \(diags.errorCount) validation errors\n", stderr)
                fputs(diags.render(sourceMap: sourceMap) + "\n", stderr)
                errorCount += diags.errorCount
                continue
            }

            let stageHash = ASTDumper().hash(program)
            let parsed = ParsedBootstrapModule(
                path: file,
                moduleName: moduleName(for: file),
                program: program,
                stageHash: stageHash
            )
            parsedModules.append(parsed)
            stageHashes[(file as NSString).lastPathComponent] = stageHash
        }

        return BootstrapParseResult(modules: parsedModules, errorCount: errorCount, stageHashes: stageHashes)
    }

    private static func validateBootstrapProfile(_ modules: [ParsedBootstrapModule]) -> [String] {
        let stdModules = modules.filter { $0.path.hasPrefix("std/") }.map {
            (name: ($0.path as NSString).lastPathComponent, program: $0.program)
        }
        guard !stdModules.isEmpty else { return [] }

        let depMap = StdlibDependencyMap.build(files: stdModules)
        let violations = BootstrapProfile.auditExclusions(depMap: depMap)
            + BootstrapProfile.auditKernelDeps(depMap: depMap)
        return Array(Set(violations)).sorted()
    }

    private static func buildFunctionCatalog(from modules: [ParsedBootstrapModule]) -> FunctionCatalog {
        var allQualifiedNames = Set<String>()
        var localQualifiedFreeFunctions: [String: [String: String]] = [:]
        var globalFreeCandidates: [String: [String]] = [:]

        for module in modules {
            var localFreeCandidates: [String: [String]] = [:]
            collectFunctionSymbols(
                items: module.program.items,
                currentModule: module.moduleName,
                localFreeCandidates: &localFreeCandidates,
                globalFreeCandidates: &globalFreeCandidates,
                allQualifiedNames: &allQualifiedNames
            )
            localQualifiedFreeFunctions[module.moduleName] = localFreeCandidates.compactMapValues { candidates in
                let deduped = Array(Set(candidates)).sorted()
                return deduped.count == 1 ? deduped[0] : nil
            }
        }

        let uniqueQualifiedFreeFunctions = globalFreeCandidates.compactMapValues { candidates in
            let deduped = Array(Set(candidates)).sorted()
            return deduped.count == 1 ? deduped[0] : nil
        }

        return FunctionCatalog(
            allQualifiedNames: allQualifiedNames,
            localQualifiedFreeFunctions: localQualifiedFreeFunctions,
            uniqueQualifiedFreeFunctions: uniqueQualifiedFreeFunctions
        )
    }

    private static func collectFunctionSymbols(
        items: [Item],
        currentModule: String,
        localFreeCandidates: inout [String: [String]],
        globalFreeCandidates: inout [String: [String]],
        allQualifiedNames: inout Set<String>
    ) {
        for item in items {
            switch item.kind {
            case .function(let fn):
                let qualified = fn.sig.name.contains("::") ? fn.sig.name : "\(currentModule)::\(fn.sig.name)"
                allQualifiedNames.insert(qualified)
                localFreeCandidates[fn.sig.name, default: []].append(qualified)
                globalFreeCandidates[fn.sig.name, default: []].append(qualified)

            case .moduleDef(let d):
                if let children = d.items {
                    collectFunctionSymbols(
                        items: children,
                        currentModule: "\(currentModule)::\(d.name)",
                        localFreeCandidates: &localFreeCandidates,
                        globalFreeCandidates: &globalFreeCandidates,
                        allQualifiedNames: &allQualifiedNames
                    )
                }

            case .implBlock(let d):
                for method in d.methods {
                    let qualified = method.sig.name.contains("::") ? method.sig.name : "\(d.targetType)::\(method.sig.name)"
                    allQualifiedNames.insert(qualified)
                }

            default:
                break
            }
        }
    }

    private static func lowerAndMergeModules(_ modules: [ParsedBootstrapModule]) throws -> BootstrapLoweringResult {
        var allTypes: [MirTypeDef] = []
        var typeCounts: [String: Int] = [:]
        for module in modules {
            let collector = MIRLowering(moduleName: module.moduleName)
            let localTypes = collector.collectTypes(module.program)
            allTypes.append(contentsOf: localTypes)
            typeCounts[module.path] = localTypes.count
        }

        let functionCatalog = buildFunctionCatalog(from: modules)
        var merged = MirProgram(functions: [], statics: [], typeDefs: allTypes)
        var moduleStats: [BootstrapLoweringStats] = []

        for module in modules {
            print("  Lowering: \(module.path)...")
            fflush(stdout)
            let lowering = MIRLowering(moduleName: module.moduleName)
            lowering.preloadTypes(allTypes)
            let rawMIR = lowering.lower(module.program)
            if lowering.hasErrors {
                throw LoweringFailure(file: module.path, errors: lowering.errors)
            }
            let normalizedMIR = normalizeModuleMIR(rawMIR, moduleName: module.moduleName, catalog: functionCatalog)
            merged.functions.append(contentsOf: normalizedMIR.functions)
            merged.statics.append(contentsOf: normalizedMIR.statics)
            moduleStats.append(BootstrapLoweringStats(
                file: (module.path as NSString).lastPathComponent,
                functionCount: normalizedMIR.functions.count,
                staticCount: normalizedMIR.statics.count,
                typeCount: typeCounts[module.path] ?? 0
            ))
        }

        return BootstrapLoweringResult(mir: merged, moduleStats: moduleStats)
    }

    private static func normalizeModuleMIR(_ mir: MirProgram, moduleName: String, catalog: FunctionCatalog) -> MirProgram {
        let localFreeMap = catalog.localQualifiedFreeFunctions[moduleName] ?? [:]
        let functions = mir.functions.map { function -> MirFunction in
            let rewrittenBlocks = function.blocks.map { rewrite($0, moduleName: moduleName, catalog: catalog) }
            let rewrittenName = localFreeMap[function.name] ?? function.name
            return MirFunction(
                name: rewrittenName,
                params: function.params,
                returnType: function.returnType,
                locals: function.locals,
                blocks: rewrittenBlocks,
                entryBlock: function.entryBlock,
                isAsync: function.isAsync,
                isUnsafe: function.isUnsafe,
                isExtern: function.isExtern
            )
        }
        let statics = mir.statics.map { rewrite($0, moduleName: moduleName, catalog: catalog) }
        return MirProgram(functions: functions, statics: statics, typeDefs: mir.typeDefs)
    }

    private static func qualifiedAliases(for qualified: String) -> [String] {
        let parts = qualified.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return [] }

        let member = parts.last!
        let owner = parts.dropLast().joined(separator: "::")

        switch owner {
        case "Vec":
            return ["Array::\(member)"]
        case "Array":
            return ["Vec::\(member)"]
        case "HashMap":
            return ["Map::\(member)"]
        case "Map":
            return ["HashMap::\(member)"]
        case "HashSet":
            return ["Set::\(member)"]
        case "Set":
            return ["HashSet::\(member)"]
        default:
            return []
        }
    }

    private static func resolveNormalizedFunctionName(_ name: String, moduleName: String, catalog: FunctionCatalog) -> String {
        if name.contains("::") {
            if catalog.allQualifiedNames.contains(name) {
                return name
            }
            for alias in qualifiedAliases(for: name) where catalog.allQualifiedNames.contains(alias) {
                return alias
            }
            return name
        }

        if let local = catalog.localQualifiedFreeFunctions[moduleName]?[name] {
            return local
        }
        if let unique = catalog.uniqueQualifiedFreeFunctions[name] {
            return unique
        }
        return name
    }

    private static func rewrite(_ block: MirBlock, moduleName: String, catalog: FunctionCatalog) -> MirBlock {
        MirBlock(
            id: block.id,
            statements: block.statements.map { rewrite($0, moduleName: moduleName, catalog: catalog) },
            terminator: rewrite(block.terminator, moduleName: moduleName, catalog: catalog)
        )
    }

    private static func rewrite(_ statement: MirStatement, moduleName: String, catalog: FunctionCatalog) -> MirStatement {
        switch statement {
        case .assign(let place, let rvalue):
            return .assign(place, rewrite(rvalue, moduleName: moduleName, catalog: catalog))
        case .storageLive, .storageDead, .setDiscriminant, .nop:
            return statement
        }
    }

    private static func rewrite(_ terminator: MirTerminator, moduleName: String, catalog: FunctionCatalog) -> MirTerminator {
        switch terminator {
        case .goto, .ret, .unreachable, .abort:
            return terminator
        case .switchInt(let operand, let targets, let otherwise):
            return .switchInt(rewrite(operand, moduleName: moduleName, catalog: catalog), targets: targets, otherwise: otherwise)
        case .call(let dest, let callee, let args, let next, let unwind):
            return .call(
                dest: dest,
                callee: rewrite(callee, moduleName: moduleName, catalog: catalog),
                args: args.map { rewrite($0, moduleName: moduleName, catalog: catalog) },
                next: next,
                unwind: unwind
            )
        case .drop:
            return terminator
        case .`deinit`:
            return terminator
        case .assert(let operand, let expected, let message, let target):
            return .assert(rewrite(operand, moduleName: moduleName, catalog: catalog), expected: expected, message: message, target: target)
        case .yield(let operand, let resume):
            return .yield(rewrite(operand, moduleName: moduleName, catalog: catalog), resume: resume)
        }
    }

    private static func rewrite(_ rvalue: MirRvalue, moduleName: String, catalog: FunctionCatalog) -> MirRvalue {
        switch rvalue {
        case .use(let operand):
            return .use(rewrite(operand, moduleName: moduleName, catalog: catalog))
        case .mirRef, .mirRefMut, .discriminant, .len:
            return rvalue
        case .aggregate(let kind, let operands):
            return .aggregate(kind, operands.map { rewrite($0, moduleName: moduleName, catalog: catalog) })
        case .binaryOp(let op, let lhs, let rhs):
            return .binaryOp(op, rewrite(lhs, moduleName: moduleName, catalog: catalog), rewrite(rhs, moduleName: moduleName, catalog: catalog))
        case .unaryOp(let op, let operand):
            return .unaryOp(op, rewrite(operand, moduleName: moduleName, catalog: catalog))
        case .cast(let operand, let type):
            return .cast(rewrite(operand, moduleName: moduleName, catalog: catalog), type)
        }
    }

    private static func rewrite(_ operand: MirOperand, moduleName: String, catalog: FunctionCatalog) -> MirOperand {
        switch operand {
        case .mirCopy, .mirMovePlace, .mirRead, .mirConsume:
            return operand
        case .mirConstant(let constant):
            return .mirConstant(rewrite(constant, moduleName: moduleName, catalog: catalog))
        }
    }

    private static func rewrite(_ arg: MirCallArg, moduleName: String, catalog: FunctionCatalog) -> MirCallArg {
        let value: MirCallValue
        switch arg.value {
        case .value(let op):
            value = .value(rewrite(op, moduleName: moduleName, catalog: catalog))
        case .place(let p):
            value = .place(p)
        }
        return MirCallArg(effect: arg.effect, value: value)
    }

    private static func rewrite(_ constant: MirConstant, moduleName: String, catalog: FunctionCatalog) -> MirConstant {
        switch constant {
        case .fnItem(let name):
            return .fnItem(resolveNormalizedFunctionName(name, moduleName: moduleName, catalog: catalog))
        default:
            return constant
        }
    }

    private static func rewrite(_ staticValue: MirStatic, moduleName: String, catalog: FunctionCatalog) -> MirStatic {
        let initializer = staticValue.initializer.map {
            rewrite($0, moduleName: moduleName, catalog: catalog)
        }
        return MirStatic(name: staticValue.name, type: staticValue.type, initializer: initializer, isMutable: staticValue.isMutable)
    }

    // MARK: - Compile via Self-Hosted Compiler

    static func cmdCompile(targetFiles: [String], outputPath: String, trace: Bool, targetTriple: String? = nil) {
        print("=== Tangerine Compile (via self-hosted compiler) ===\n")

        let fm = FileManager.default

        // Step 1: Collect compiler source files (bootstrap std + tg_compiler)
        let kernelFiles = collectBootstrapCompilerFiles(fileManager: fm)
        let stdFiles = kernelFiles.stdFiles
        let compilerFiles = kernelFiles.compilerFiles
        let allFiles = stdFiles + compilerFiles

        print("Compiler: \(stdFiles.count) bootstrap std + \(compilerFiles.count) compiler = \(allFiles.count) files")
        print("Target: \(targetFiles.joined(separator: ", "))")
        print("Output: \(outputPath)")
        fflush(stdout)

        // Step 2: Parse all compiler files
        print("\n--- Phase 1: Parse compiler ---")
        fflush(stdout)
        let parseResult = parseValidatedModules(files: allFiles, enforceSubset: true)
        let parseErrors = parseResult.errorCount
        let parsedModules = parseResult.modules
        print("Parsed: \(parsedModules.count)/\(allFiles.count) OK (\(parseErrors) errors)")
        fflush(stdout)

        if parseErrors > 0 {
            fputs("error: bootstrap compiler kernel failed validation\n", stderr)
            exit(1)
        }

        let profileViolations = validateBootstrapProfile(parsedModules)
        if !profileViolations.isEmpty {
            fputs("error: bootstrap stdlib profile is not closed under its declared dependencies\n", stderr)
            for violation in profileViolations {
                fputs("  \(violation)\n", stderr)
            }
            exit(1)
        }
        print("Bootstrap profile audit: OK")
        fflush(stdout)

        // Step 3: Lower to MIR
        print("\n--- Phase 2: Lower to MIR ---")
        fflush(stdout)
        let loweringResult: BootstrapLoweringResult
        do {
            loweringResult = try lowerAndMergeModules(parsedModules)
        } catch let failure as LoweringFailure {
            reportLoweringFailure(file: failure.file, errors: failure.errors)
            exit(1)
        } catch {
            fputs("error: lowering failed with unexpected error: \(error)\n", stderr)
            exit(1)
        }
        let mergedMIR = loweringResult.mir

        print("Merged MIR: \(mergedMIR.functions.count) functions, \(mergedMIR.statics.count) statics, \(mergedMIR.typeDefs.count) types")
        fflush(stdout)

        guard mergedMIR.functions.contains(where: { $0.name == "driver::driver_main" })
              || mergedMIR.functions.contains(where: { $0.name == "bootstrap_main::main" })
              || mergedMIR.functions.contains(where: { $0.name == "main" }) else {
            fputs("error: no compiler entry point (driver::driver_main / bootstrap_main::main / main) found in merged MIR\n", stderr)
            exit(1)
        }

        // Step 4: Interpret — run the TG compiler to compile target files
        print("\n--- Phase 3: Compile via interpreted TG compiler ---")
        fflush(stdout)

        let interp = MIRInterpreter(program: mergedMIR, enableTrace: trace)
        // Determine target triple: explicit --target, or auto-detect host
        let hostTarget: String
        if let triple = targetTriple {
            hostTarget = triple
        } else {
            #if arch(arm64)
            let hostArch = "aarch64"
            #else
            let hostArch = "x86_64"
            #endif
            #if os(macOS)
            let hostOS = "macos"
            #elseif os(Linux)
            let hostOS = "linux"
            #elseif os(Windows)
            let hostOS = "windows"
            #else
            let hostOS = "unknown"
            #endif
            hostTarget = "\(hostArch)-\(hostOS)"
        }
        var compileArgs = ["tg", "compile", "-o", outputPath, "--target", hostTarget, "--verbose"]
        compileArgs.append(contentsOf: targetFiles)
        interp.runtimeArgs = compileArgs
        let outputAttrsBefore = try? fm.attributesOfItem(atPath: outputPath)

        print("Args: \(compileArgs.joined(separator: " "))")
        fflush(stdout)

        let result = interp.run(entryFunction: resolveEntryFunction(mergedMIR))
        let outputAttrsAfter = try? fm.attributesOfItem(atPath: outputPath)
        let outputSize = (outputAttrsAfter?[.size] as? NSNumber)?.int64Value ?? 0
        let hadPanic = result.output.contains(where: { $0.hasPrefix("PANIC:") })
        let outputUpdated: Bool = {
            guard let after = outputAttrsAfter else { return false }
            if outputAttrsBefore == nil {
                return true
            }
            let beforeMod = outputAttrsBefore?[.modificationDate] as? Date
            let afterMod = after[.modificationDate] as? Date
            let beforeSize = (outputAttrsBefore?[.size] as? NSNumber)?.int64Value
            let afterSize = (after[.size] as? NSNumber)?.int64Value
            return beforeMod != afterMod || beforeSize != afterSize
        }()

        for line in result.output {
            print(line)
        }

        if trace {
            fputs("\n--- TRACE ---\n", stderr)
            for entry in result.trace {
                fputs("[\(entry.kind.rawValue)] \(entry.function) bb\(entry.block): \(entry.detail)\n", stderr)
            }
            fputs("--- END TRACE ---\n", stderr)
        }

        if result.exitCode == 0 && !hadPanic && outputUpdated && outputSize > 0 {
            print("\n=== Compilation Successful ===")
            print("Output: \(outputPath)")
        } else {
            print("\n=== Compilation Failed ===")
            print("Exit code: \(result.exitCode)")
            if hadPanic {
                print("Reason: interpreted compiler panicked")
            }
            if !outputUpdated || outputSize == 0 {
                print("Reason: output binary was not produced or updated")
            }
            let failureCode = result.exitCode == 0 ? 1 : result.exitCode
            exit(Int32(failureCode))
        }
    }

    // MARK: - Self-Host Build

    static func cmdSelfHost(trace: Bool, dryRun: Bool) {
        print("=== Tangerine Self-Host Build (Stage 0 Swift) ===\n")

        let fm = FileManager.default
        let tracker = SelfHostBuildTracker()

        // Step 1: Collect all source files
        let kernelFiles = collectBootstrapCompilerFiles(fileManager: fm)
        let stdFiles = kernelFiles.stdFiles
        let compilerFiles = kernelFiles.compilerFiles
        let allFiles = stdFiles + compilerFiles

        print("Source files: \(stdFiles.count) std + \(compilerFiles.count) compiler = \(allFiles.count) total")
        fflush(stdout)

        // Step 2: Parse all files
        print("\n--- Phase 1: Parse ---")
        fflush(stdout)
        let parseResult = parseValidatedModules(files: allFiles, enforceSubset: true)
        let parseErrors = parseResult.errorCount
        let parsedModules = parseResult.modules
        let stageHashes = parseResult.stageHashes
        print("Parsed: \(parsedModules.count)/\(allFiles.count) OK (\(parseErrors) errors)")
        fflush(stdout)

        let profileViolations = parseErrors == 0 ? validateBootstrapProfile(parsedModules) : []
        let validationFailures = parseErrors + profileViolations.count
        if !profileViolations.isEmpty {
            fputs("error: bootstrap stdlib profile is not closed under its declared dependencies\n", stderr)
            for violation in profileViolations {
                fputs("  \(violation)\n", stderr)
            }
        }

        if validationFailures > 0 {
            let ts = iso8601Now()
            for mode in BuildMode.allCases {
                let buildResult = BuildResult(
                    mode: mode,
                    success: false,
                    stageHashes: stageHashes,
                    verifiersPassed: false,
                    interpreterSpotCheckPassed: false,
                    openP0P1: validationFailures,
                    timestamp: ts,
                    reproducible: false
                )
                tracker.record(buildResult)
            }
            print("\n" + tracker.report())
            if dryRun {
                return
            }
            exit(1)
        }

        print("Bootstrap profile audit: OK")
        fflush(stdout)

        // Step 3: Lower all modules to MIR
        print("\n--- Phase 2: Lower to MIR ---")
        fflush(stdout)
        let loweringResult: BootstrapLoweringResult
        do {
            loweringResult = try lowerAndMergeModules(parsedModules)
        } catch let failure as LoweringFailure {
            reportLoweringFailure(file: failure.file, errors: failure.errors)
            exit(1)
        } catch {
            fputs("error: lowering failed with unexpected error: \(error)\n", stderr)
            exit(1)
        }
        let mergedMIR = loweringResult.mir
        for stat in loweringResult.moduleStats {
            print("  \(stat.file): \(stat.functionCount) fns, \(stat.staticCount) statics, \(stat.typeCount) types")
        }

        print("\nMerged MIR: \(mergedMIR.functions.count) functions, \(mergedMIR.statics.count) statics, \(mergedMIR.typeDefs.count) types")
        fflush(stdout)

        // Step 4: Verify MIR has a main function
        let entryName = resolveEntryFunction(mergedMIR)
        let hasDriverMain = entryName != ""
        print("Entry point '\(entryName)': \(hasDriverMain ? "found" : "NOT FOUND")")
        fflush(stdout)

        if dryRun {
            print("\n--- Dry Run Complete ---")
            print("Would interpret merged MIR (\(mergedMIR.functions.count) functions) with entry '\(entryName)'")

            let drySuccess = hasDriverMain
            let ts = iso8601Now()
            for mode in BuildMode.allCases {
                let result = BuildResult(
                    mode: mode,
                    success: drySuccess,
                    stageHashes: stageHashes,
                    verifiersPassed: true,
                    interpreterSpotCheckPassed: false,
                    openP0P1: drySuccess ? 0 : 1,
                    timestamp: ts,
                    reproducible: false
                )
                tracker.record(result)
            }
            print("\n" + tracker.report())
            return
        }

        guard hasDriverMain else {
            fputs("error: no compiler entry point found in merged MIR\n", stderr)
            exit(1)
        }

        // Step 5: Interpret
        print("\n--- Phase 3: Interpret (self-host execution) ---")
        fflush(stdout)
        let interp = MIRInterpreter(program: mergedMIR, enableTrace: trace)
        // Self-host: interpreted compiler compiles ALL its own source files with --check --verbose
        var selfHostArgs = ["tg", "compile", "--check", "--verbose"]
        if let entries = try? fm.contentsOfDirectory(atPath: "tg_compiler") {
            for f in entries.filter({ $0.hasSuffix(".tg") }).sorted() {
                selfHostArgs.append("tg_compiler/\(f)")
            }
        }
        interp.runtimeArgs = selfHostArgs
        let result = interp.run(entryFunction: resolveEntryFunction(mergedMIR))

        for line in result.output {
            print(line)
        }

        if trace {
            fputs("\n--- TRACE ---\n", stderr)
            for entry in result.trace {
                fputs("[\(entry.kind.rawValue)] \(entry.function) bb\(entry.block): \(entry.detail)\n", stderr)
            }
            fputs("--- END TRACE ---\n", stderr)
        }

        let success = result.exitCode == 0
        print("\n--- Self-Host Result ---")
        print("Exit code: \(result.exitCode)")
        print("Output lines: \(result.output.count)")

        // Record build result for both modes (same pipeline, same hashes)
        // P0P1 only counts real failures: std parse errors are EXPECTED in bootstrap subset
        // Self-host success is determined by the interpreter exit code
        let ts = iso8601Now()
        for mode in BuildMode.allCases {
            let buildResult = BuildResult(
                mode: mode,
                success: success,
                stageHashes: stageHashes,
                verifiersPassed: true,
                interpreterSpotCheckPassed: success,
                openP0P1: success ? 0 : 1,
                timestamp: ts,
                reproducible: true
            )
            tracker.record(buildResult)
        }
        print("\n" + tracker.report())

        if !success {
            exit(Int32(result.exitCode))
        }
    }

    private static func iso8601Now() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }
}


func resolveEntryFunction(_ mir: MirProgram) -> String {
    for candidate in ["driver::driver_main", "bootstrap_main::main", "main"] {
        if mir.functions.contains(where: { $0.name == candidate }) {
            return candidate
        }
    }
    return ""
}
