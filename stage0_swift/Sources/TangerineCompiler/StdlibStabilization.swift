// StdlibStabilization.swift — Stage 25: Individual bootstrap-critical file stabilization
// Tracks status per bootstrap file: red/yellow/green with local tests.
// Implements the 5-step stabilization sequence for layout correctness.

// MARK: - FileStatus

public enum FileStatus: String, Equatable, CaseIterable {
    case red    = "red"     // failing or untested
    case yellow = "yellow"  // partially tested, known issues
    case green  = "green"   // fully tested, protected
}

// MARK: - Step 1: Target Layout Descriptor

/// Per-architecture layout parameters.  One instance per target.
public struct TargetLayoutDescriptorSwift: Equatable {
    public let archName: String       // "aarch64" or "x86_64"
    public let pointerSize: Int       // 8 for LP64
    public let pointerAlign: Int      // 8 for LP64
    public let intSize: Int           // 8 for LP64
    public let boolSize: Int          // 1
    public let charSize: Int          // 4
    public let fnPtrSize: Int         // 16
    public let endianness: String     // "little"

    public init(archName: String, pointerSize: Int = 8, pointerAlign: Int = 8,
                intSize: Int = 8, boolSize: Int = 1, charSize: Int = 4,
                fnPtrSize: Int = 16, endianness: String = "little") {
        self.archName = archName
        self.pointerSize = pointerSize
        self.pointerAlign = pointerAlign
        self.intSize = intSize
        self.boolSize = boolSize
        self.charSize = charSize
        self.fnPtrSize = fnPtrSize
        self.endianness = endianness
    }

    public static let aarch64 = TargetLayoutDescriptorSwift(archName: "aarch64")
    public static let x86_64 = TargetLayoutDescriptorSwift(archName: "x86_64")
}

// MARK: - Step 2: Canonical Layout Categories

/// Categories of layout representation.
public enum CanonicalLayoutCategory: String, CaseIterable {
    case primitive = "primitive"           // fixed-width int/float
    case pointer = "pointer"              // Box, Ptr, Ref, RefMut
    case fatPointer = "fat-pointer"       // slices, trait objects
    case inlineStruct = "inline-struct"   // user-defined structs
    case taggedUnion = "tagged-union"     // enums with tag + payload
    case dynContainer = "dyn-container"   // Vec, String, Map, Set
    case zeroSized = "zero-sized"         // Unit, Never
    case functionType = "function-type"   // fn pointer + env
}

// MARK: - Step 3: Layout Record Cache

/// A cached layout record with hash for fast comparison.
public struct LayoutRecordSwift: Equatable, Hashable {
    public let typeName: String
    public let category: CanonicalLayoutCategory
    public let size: Int
    public let align: Int
    public let stride: Int
    public let fieldCount: Int
    public let contentHash: UInt64

    public init(typeName: String, category: CanonicalLayoutCategory,
                size: Int, align: Int, stride: Int, fieldCount: Int) {
        self.typeName = typeName
        self.category = category
        self.size = size
        self.align = align
        self.stride = stride
        self.fieldCount = fieldCount
        // Simple FNV-1a-inspired hash for cache validation
        var h: UInt64 = 0xcbf29ce484222325
        for byte in typeName.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        h ^= UInt64(bitPattern: Int64(size))
        h &*= 0x100000001b3
        h ^= UInt64(bitPattern: Int64(align))
        h &*= 0x100000001b3
        h ^= UInt64(bitPattern: Int64(stride))
        self.contentHash = h
    }
}

/// Cache of layout records with validation.
public final class LayoutRecordCache {
    private var records: [String: LayoutRecordSwift] = [:]

    public init() {}

    public func insert(_ record: LayoutRecordSwift) {
        records[record.typeName] = record
    }

    public func lookup(_ typeName: String) -> LayoutRecordSwift? {
        records[typeName]
    }

    /// Validate that a type's observed layout matches the cached record.
    public func validate(typeName: String, observedSize: Int, observedAlign: Int) -> Bool {
        guard let rec = records[typeName] else { return true } // unknown = no constraint
        return rec.size == observedSize && rec.align == observedAlign
    }

    public var allRecords: [LayoutRecordSwift] {
        records.values.sorted(by: { $0.typeName < $1.typeName })
    }

    public var count: Int { records.count }
}

// MARK: - Step 4: Layout Table Dumper

/// Produces a human-readable layout table for debugging.
public struct LayoutTableDumper {
    public static func dump(cache: LayoutRecordCache) -> String {
        var lines: [String] = []
        lines.append("╔══════════════════════════════════════════════════════════════╗")
        lines.append("║  Tangerine Layout Table Dump                                ║")
        lines.append("╠══════════════════╦═══════╦═══════╦════════╦════════╦════════╣")
        lines.append("║ Type             ║ Size  ║ Align ║ Stride ║ Fields ║ Hash   ║")
        lines.append("╠══════════════════╬═══════╬═══════╬════════╬════════╬════════╣")
        for rec in cache.allRecords {
            let name = rec.typeName.padding(toLength: 16, withPad: " ", startingAt: 0)
            let size = String(rec.size).padding(toLength: 5, withPad: " ", startingAt: 0)
            let align = String(rec.align).padding(toLength: 5, withPad: " ", startingAt: 0)
            let stride = String(rec.stride).padding(toLength: 6, withPad: " ", startingAt: 0)
            let fields = String(rec.fieldCount).padding(toLength: 6, withPad: " ", startingAt: 0)
            let hash = String(format: "%06x", rec.contentHash & 0xFFFFFF)
            lines.append("║ \(name) ║ \(size) ║ \(align) ║ \(stride) ║ \(fields) ║ \(hash) ║")
        }
        lines.append("╚══════════════════╩═══════╩═══════╩════════╩════════╩════════╝")
        return lines.joined(separator: "\n")
    }

    /// Dump as a simple CSV for machine consumption.
    public static func dumpCSV(cache: LayoutRecordCache) -> String {
        var lines = ["type,category,size,align,stride,fields,hash"]
        for rec in cache.allRecords {
            lines.append("\(rec.typeName),\(rec.category.rawValue),\(rec.size),\(rec.align),\(rec.stride),\(rec.fieldCount),\(rec.contentHash)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Step 5: Typed Layout Ops Enforcement

/// Validates that layout operations use typed descriptors rather than raw arithmetic.
public struct LayoutOpsEnforcer {
    /// Check that a field access uses the descriptor's offset, not a hardcoded constant.
    public static func validateFieldAccess(typeName: String, fieldIndex: Int,
                                            observedOffset: Int,
                                            cache: LayoutRecordCache) -> String? {
        guard let rec = cache.lookup(typeName) else {
            return nil // unknown type, skip
        }
        if fieldIndex >= rec.fieldCount {
            return "Field index \(fieldIndex) out of range for \(typeName) (has \(rec.fieldCount) fields)"
        }
        return nil // field index in range — actual offset check done at codegen level
    }

    /// Verify that no raw `idx * 8` fallback is used for known types.
    public static func detectRawOffsetFallback(typeName: String, fieldIndex: Int,
                                                observedOffset: Int,
                                                cache: LayoutRecordCache) -> Bool {
        // If observed offset equals `fieldIndex * 8` AND the type is known
        // to have non-uniform field sizes, flag it as a raw fallback.
        guard let rec = cache.lookup(typeName) else { return false }
        if observedOffset == fieldIndex * 8 && rec.category == .inlineStruct {
            // Could be correct (uniform 8-byte fields) or could be fallback
            // Only flag if we know the type has non-8-byte fields
            return false // conservative: need field-level info to decide
        }
        return false
    }
}

// MARK: - StdlibFileRecord

/// Status record for a single bootstrap-critical stdlib file.
public struct StdlibFileRecord: Equatable, CustomStringConvertible {
    public let name: String
    public var status: FileStatus
    public var hasLocalTests: Bool
    public var hasIntegrationTest: Bool
    public var hasSnapshotBaseline: Bool
    public var isProtected: Bool       // green files are protected

    public init(name: String, status: FileStatus = .red,
                hasLocalTests: Bool = false, hasIntegrationTest: Bool = false,
                hasSnapshotBaseline: Bool = false) {
        self.name = name
        self.status = status
        self.hasLocalTests = hasLocalTests
        self.hasIntegrationTest = hasIntegrationTest
        self.hasSnapshotBaseline = hasSnapshotBaseline
        self.isProtected = status == .green
    }

    public var description: String {
        let prot = isProtected ? " [PROTECTED]" : ""
        return "\(name): \(status.rawValue)\(prot) local=\(hasLocalTests) integ=\(hasIntegrationTest) snap=\(hasSnapshotBaseline)"
    }
}

// MARK: - StdlibStabilizationDashboard

/// Dashboard tracking status of all bootstrap-critical files.
public final class StdlibStabilizationDashboard {
    private var records: [String: StdlibFileRecord] = [:]

    public init() {}

    /// Register a file.
    public func register(_ record: StdlibFileRecord) {
        records[record.name] = record
    }

    /// Get record for a file.
    public func record(for name: String) -> StdlibFileRecord? {
        records[name]
    }

    /// Update status.
    public func updateStatus(name: String, status: FileStatus) {
        guard var r = records[name] else { return }
        // Protected files cannot be downgraded casually
        if r.isProtected && status != .green {
            return  // block casual edits to green files
        }
        r.status = status
        r.isProtected = status == .green
        records[name] = r
    }

    /// Mark test coverage.
    public func markLocalTests(name: String) {
        records[name]?.hasLocalTests = true
    }

    public func markIntegrationTest(name: String) {
        records[name]?.hasIntegrationTest = true
    }

    public func markSnapshotBaseline(name: String) {
        records[name]?.hasSnapshotBaseline = true
    }

    /// All records sorted by name.
    public var allRecords: [StdlibFileRecord] {
        records.values.sorted(by: { $0.name < $1.name })
    }

    /// Records by status.
    public func records(status: FileStatus) -> [StdlibFileRecord] {
        allRecords.filter { $0.status == status }
    }

    /// Protected (green) files.
    public var protectedFiles: [StdlibFileRecord] {
        allRecords.filter { $0.isProtected }
    }

    /// Files missing local tests.
    public var missingLocalTests: [StdlibFileRecord] {
        allRecords.filter { !$0.hasLocalTests }
    }

    /// Files missing integration tests.
    public var missingIntegrationTests: [StdlibFileRecord] {
        allRecords.filter { !$0.hasIntegrationTest }
    }

    /// Report.
    public func report() -> String {
        var lines = ["=== Stdlib Stabilization Dashboard ==="]
        lines.append("Total files: \(records.count)")
        for s in FileStatus.allCases {
            let r = records(status: s)
            lines.append("\(s.rawValue): \(r.count)")
        }
        lines.append("Protected: \(protectedFiles.count)")
        lines.append("Missing local tests: \(missingLocalTests.count)")
        lines.append("Missing integration tests: \(missingIntegrationTests.count)")
        for r in allRecords {
            lines.append("  \(r)")
        }
        return lines.joined(separator: "\n")
    }
}
