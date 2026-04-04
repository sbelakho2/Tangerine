// BootstrapProfile.swift — Stage 12: Minimal bootstrap stdlib profile

public struct BootstrapProfile {

    // MARK: - Types

    public struct ProfileEntry: Equatable {
        public let file: String
        public let reason: String
    }

    public struct PromotionRequest: Equatable {
        public let file: String
        public let reason: String
        public let reviewer: String

        public init(file: String, reason: String, reviewer: String) {
            self.file = file
            self.reason = reason
            self.reviewer = reviewer
        }
    }

    // MARK: - Minimal bootstrap profile

    /// The minimal set of stdlib files required for the compiler kernel.
    /// Each entry documents why it is included.
    public static let profileEntries: [ProfileEntry] = [
        ProfileEntry(file: "core.tg",
            reason: "Foundational types: Option, Result, Bool, Int, String, fundamental traits"),
        ProfileEntry(file: "alloc.tg",
            reason: "Memory allocation primitives needed by collections and compiler runtime"),
        ProfileEntry(file: "args.tg",
            reason: "Command-line argument access for the compiler driver entrypoint"),
        ProfileEntry(file: "bench.tg",
            reason: "Benchmark subcommand support used by the compiler driver"),
        ProfileEntry(file: "collections.tg",
            reason: "Vec, Map, Set — compiler data structures for AST, symbol tables, IR"),
        ProfileEntry(file: "ffi.tg",
            reason: "C string and pointer interop needed by filesystem access during bootstrap"),
        ProfileEntry(file: "fmt.tg",
            reason: "Display/Debug traits, formatting — compiler diagnostic rendering"),
        ProfileEntry(file: "fs.tg",
            reason: "Source loading and file output used by compiler commands and tooling modules"),
        ProfileEntry(file: "gfx_errors.tg",
            reason: "Shared error model required by filesystem helpers in the bootstrap profile"),
        ProfileEntry(file: "io.tg",
            reason: "File reading, stdout/stderr — compiler I/O for source loading and output"),
        ProfileEntry(file: "process.tg",
            reason: "Process control, exit codes — compiler driver exit handling"),
        ProfileEntry(file: "env.tg",
            reason: "Environment variables — compiler configuration via env"),
        ProfileEntry(file: "time.tg",
            reason: "Timing primitives required by benchmarking and build metadata paths"),
    ]

    /// File names in the minimal bootstrap profile.
    public static var profileFiles: [String] {
        profileEntries.map(\.file).sorted()
    }

    /// Set of profile file names for fast lookup.
    public static var profileFileSet: Set<String> {
        Set(profileFiles)
    }

    // MARK: - Validation

    /// Check that a dependency map's compiler kernel only uses profile files.
    /// Returns list of violations (files imported that are outside the profile).
    public static func auditKernelDeps(depMap: StdlibDependencyMap) -> [String] {
        let profile = profileFileSet
        var violations: [String] = []
        // For each bootstrap-critical file, check that all its deps are in the profile
        for file in depMap.bootstrapCriticalFiles {
            let deps = depMap.fileDeps[file] ?? []
            for dep in deps.sorted() {
                if !profile.contains(dep) {
                    violations.append("\(file) imports \(dep) which is outside the bootstrap profile")
                }
            }
        }
        return violations
    }

    /// Check that profile files do not import files outside the profile.
    /// Returns list of violations.
    public static func auditExclusions(depMap: StdlibDependencyMap) -> [String] {
        let profile = profileFileSet
        var violations: [String] = []
        for file in profile {
            let deps = depMap.fileDeps[file] ?? []
            for dep in deps.sorted() {
                if !profile.contains(dep) {
                    violations.append("\(file) imports \(dep) which is outside the bootstrap profile")
                }
            }
        }
        return violations
    }

    // MARK: - Promotion policy

    /// Validate a promotion request. Returns nil if valid, or an error string.
    public static func validatePromotion(_ request: PromotionRequest) -> String? {
        if request.file.isEmpty { return "File name must not be empty" }
        if !request.file.hasSuffix(".tg") { return "File must be a .tg file" }
        if request.reason.isEmpty { return "Promotion reason must not be empty" }
        if request.reviewer.isEmpty { return "Reviewer must not be empty" }
        if profileFileSet.contains(request.file) {
            return "\(request.file) is already in the bootstrap profile"
        }
        return nil
    }

    // MARK: - Manifest

    public static var manifest: String {
        var lines: [String] = []
        lines.append("Bootstrap Stdlib Profile")
        lines.append("========================")
        lines.append("Files: \(profileEntries.count)")
        lines.append("")
        for entry in profileEntries {
            lines.append("\(entry.file)")
            lines.append("  Reason: \(entry.reason)")
        }
        lines.append("")
        lines.append("Promotion policy: new files require a PromotionRequest with file, reason, and reviewer.")
        return lines.joined(separator: "\n")
    }
}
