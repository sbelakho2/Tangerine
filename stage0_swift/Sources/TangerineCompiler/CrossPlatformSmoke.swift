// CrossPlatformSmoke.swift — Stage 30: Cross-Platform Smoke Matrix
// Ensures reduced corridor is no longer platform-fragile.
// Normalizes paths/locale/timezone across CI environments.

// MARK: - Platform

/// Represents a target platform in the smoke matrix.
public struct Platform: Equatable, Hashable, CustomStringConvertible {
    public let os: String      // "linux", "macos", "windows"
    public let arch: String    // "x86_64", "arm64"

    public init(os: String, arch: String) {
        self.os = os
        self.arch = arch
    }

    public var fingerprint: String { "\(os)-\(arch)" }

    public var description: String { fingerprint }

    public static let linuxX86 = Platform(os: "linux", arch: "x86_64")
    public static let linuxArm = Platform(os: "linux", arch: "arm64")
    public static let macosX86 = Platform(os: "macos", arch: "x86_64")
    public static let macosArm = Platform(os: "macos", arch: "arm64")
    public static let windowsX86 = Platform(os: "windows", arch: "x86_64")
    public static let windowsArm = Platform(os: "windows", arch: "arm64")

    public static let all: [Platform] = [
        .linuxX86, .linuxArm, .macosX86, .macosArm, .windowsX86, .windowsArm
    ]
}

// MARK: - SmokeResult

/// Result of running the smoke matrix on a single platform.
public struct SmokeResult: Equatable {
    public let platform: Platform
    public let canaryPassed: Bool
    public let corridorPassed: Bool
    public let stageHashes: [String: UInt64]     // stage -> hash
    public let diagnosticCodes: [String]
    public let divergences: [String]             // platform-specific issues

    public init(platform: Platform, canaryPassed: Bool, corridorPassed: Bool,
                stageHashes: [String: UInt64] = [:], diagnosticCodes: [String] = [],
                divergences: [String] = []) {
        self.platform = platform
        self.canaryPassed = canaryPassed
        self.corridorPassed = corridorPassed
        self.stageHashes = stageHashes
        self.diagnosticCodes = diagnosticCodes
        self.divergences = divergences
    }

    public var isGreen: Bool { canaryPassed && corridorPassed && divergences.isEmpty }
}

// MARK: - PathNormalizer

/// Normalizes platform-specific paths, locale, and timezone from compiler outputs.
public enum PathNormalizer {
    /// Normalize a path by removing platform-specific prefixes.
    public static func normalize(_ path: String) -> String {
        var result = path
        // Remove common platform-specific prefixes
        let prefixes = ["/home/", "/Users/", "C:\\Users\\", "/tmp/", "C:\\temp\\"]
        for prefix in prefixes {
            if let range = result.range(of: prefix) {
                // Replace up to next separator after prefix
                let afterPrefix = result[range.upperBound...]
                if let sepIdx = afterPrefix.firstIndex(where: { $0 == "/" || $0 == "\\" }) {
                    result = String(result[result.startIndex..<range.lowerBound])
                        + "<user>"
                        + String(result[sepIdx...])
                } else {
                    result = String(result[result.startIndex..<range.lowerBound]) + "<user>"
                }
            }
        }
        // Normalize separators to /
        result = result.replacingOccurrences(of: "\\", with: "/")
        return result
    }

    /// Normalize a diagnostic string (remove timestamps, paths).
    public static func normalizeDiagnostic(_ diag: String) -> String {
        let result = diag
        // Strip ISO-like timestamps (YYYY-MM-DDTHH:MM:SS pattern)
        // Manual approach to avoid Foundation dependency
        var cleaned = ""
        var i = result.startIndex
        while i < result.endIndex {
            // Check if we're at a timestamp-like pattern
            let remaining = result[i...]
            if remaining.count >= 19,
               remaining.prefix(4).allSatisfy({ $0.isNumber }),
               remaining.dropFirst(4).first == "-",
               remaining.dropFirst(5).prefix(2).allSatisfy({ $0.isNumber }),
               remaining.dropFirst(7).first == "-",
               remaining.dropFirst(8).prefix(2).allSatisfy({ $0.isNumber }),
               remaining.dropFirst(10).first == "T",
               remaining.dropFirst(11).prefix(2).allSatisfy({ $0.isNumber }),
               remaining.dropFirst(13).first == ":",
               remaining.dropFirst(14).prefix(2).allSatisfy({ $0.isNumber }),
               remaining.dropFirst(16).first == ":",
               remaining.dropFirst(17).prefix(2).allSatisfy({ $0.isNumber }) {
                cleaned += "<timestamp>"
                i = result.index(i, offsetBy: 19)
            } else {
                cleaned.append(result[i])
                i = result.index(after: i)
            }
        }
        return normalize(cleaned)
    }
}

// MARK: - CrossPlatformSmokeMatrix

/// Orchestrates running the reduced corridor across platforms.
public final class CrossPlatformSmokeMatrix {
    private var results: [String: SmokeResult] = [:]  // fingerprint -> result

    public init() {}

    /// Record a platform result.
    public func record(_ result: SmokeResult) {
        results[result.platform.fingerprint] = result
    }

    /// Get result for platform.
    public func result(for platform: Platform) -> SmokeResult? {
        results[platform.fingerprint]
    }

    /// All results sorted by platform fingerprint.
    public var allResults: [SmokeResult] {
        results.values.sorted(by: { $0.platform.fingerprint < $1.platform.fingerprint })
    }

    /// Platforms that are green.
    public var greenPlatforms: [Platform] {
        allResults.filter(\.isGreen).map(\.platform)
    }

    /// Platforms with divergences.
    public var divergedPlatforms: [Platform] {
        allResults.filter { !$0.divergences.isEmpty }.map(\.platform)
    }

    /// Are stage hashes stable across all recorded platforms?
    public var hashesStable: Bool {
        let allHashes = allResults.map(\.stageHashes)
        guard let first = allHashes.first else { return true }
        return allHashes.allSatisfy { $0 == first }
    }

    /// Stage hashes that differ across platforms.
    public var unstableHashes: [String] {
        var unstable: Set<String> = []
        let allHashes = allResults.map(\.stageHashes)
        guard let first = allHashes.first else { return [] }
        for hashes in allHashes.dropFirst() {
            for (stage, hash) in hashes {
                if first[stage] != hash { unstable.insert(stage) }
            }
            for stage in first.keys where hashes[stage] == nil {
                unstable.insert(stage)
            }
        }
        return unstable.sorted()
    }

    /// All uncategorized divergences across all platforms.
    public var uncategorizedDivergences: [String] {
        allResults.flatMap(\.divergences)
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Cross-Platform Smoke Matrix ==="]
        lines.append("Platforms tested: \(results.count)")
        lines.append("Green: \(greenPlatforms.count)")
        lines.append("Diverged: \(divergedPlatforms.count)")
        lines.append("Hashes stable: \(hashesStable)")
        for r in allResults {
            let status = r.isGreen ? "GREEN" : "ISSUES"
            lines.append("  \(r.platform.fingerprint): \(status) canary=\(r.canaryPassed) corridor=\(r.corridorPassed) divergences=\(r.divergences.count)")
        }
        return lines.joined(separator: "\n")
    }
}
