// MIRInterpreter.swift — Interprets MIR programs independently of codegen
// Provides an execution oracle for differential testing (Stage 8).

import Foundation
#if os(macOS)
import AppKit
#endif

public final class MIRInterpreter {
    private let program: MirProgram
    private var output: [String] = []
    private var trace: [TraceEntry] = []
    private let enableTrace: Bool
    public var runtimeArgs: [String] = ["tg", "compile", "--help"]
    public var maxSteps: Int = {
        if let raw = ProcessInfo.processInfo.environment["TG_INTERPRETER_MAX_STEPS"],
           let val = Int(raw), val > 0 {
            return val
        }
        return 80_000_000_000
    }()
    private var stepCount: Int = 0
    private let progressReportInterval: Int
    private var nextProgressReportStep: Int = .max
    private var startTime: Date = .distantPast

    private var halted: Bool = false
    private var runtimeError: String?

    // Registry of struct field orders for positional access on structVals
    private var structFieldOrders: [String: [String]] = [:]

    // Call stack
    private var callStack: [Frame] = []

    public struct TraceEntry {
        public let function: String
        public let block: BlockId
        public let kind: TraceKind
        public let detail: String
    }

    public enum TraceKind: String {
        case enterFunction = "ENTER"
        case exitFunction = "EXIT"
        case enterBlock = "BLOCK"
        case statement = "STMT"
        case terminator = "TERM"
    }

    private struct Frame {
        let functionIdx: Int
        let localsBase: Int
        let localsCount: Int
        var currentBlock: BlockId
        var stmtIndex: Int
        var mutBorrows: [LocalId: MirPlace] = [:]
        var mapMutOptions: [LocalId: (mapPlace: MirPlace, key: MirValue)] = [:]
        var mapMutPayloads: [LocalId: (mapPlace: MirPlace, key: MirValue)] = [:]
        var fieldCopyTracker: [LocalId: MirPlace] = [:]
        var downcastTracker: [LocalId: (enumLocal: LocalId, variantIdx: Int)] = [:]
        // Continuation for deferred user-function calls (iterative trampoline)
        var pendingDest: Int = -1
        var pendingNext: BlockId = -1
        var pendingCalleeName: String = ""
        var pendingCallOperands: [MirOperand] = []
        var pendingArgVals: [MirValue] = []
        var hasPending: Bool = false
    }

    private struct CallSiteKey: Hashable {
        let functionIdx: Int
        let blockId: BlockId
        let stmtIndex: Int
    }

    private struct StaticMethodCallSiteKey: Hashable {
        let site: CallSiteKey
        let receiverType: String
    }

    private enum EnumPayloadShape {
        case unit
        case namedStruct
        case unnamed(Int)
    }

    // Deferred user-function call state (set by dispatchCall, consumed by trampoline)
    private var hasDeferredCall = false
    private var deferredFnIdx: Int = -1
    private var deferredArgs: [MirValue] = []

    public init(program: MirProgram, enableTrace: Bool = false) {
        self.program = program
        self.enableTrace = enableTrace
        if let rawInterval = ProcessInfo.processInfo.environment["TG_INTERPRETER_PROGRESS_INTERVAL"],
           let interval = Int(rawInterval), interval > 0 {
            self.progressReportInterval = interval
        } else {
            self.progressReportInterval = 0
        }
        // Build function name → array index for O(1) lookups
        var idx: [String: Int] = [:]
        idx.reserveCapacity(program.functions.count)
        for (i, fn) in program.functions.enumerated() {
            idx[fn.name] = i
        }
        self.functionIndex = idx
        // Pre-build block indices per function for O(1) block lookup
        var bIdx: [[BlockId: MirBlock]] = []
        bIdx.reserveCapacity(program.functions.count)
        for fn in program.functions {
            var bi: [BlockId: MirBlock] = [:]
            bi.reserveCapacity(fn.blocks.count)
            for block in fn.blocks {
                bi[block.id] = block
            }
            bIdx.append(bi)
        }
        self.blockIndices = bIdx
        // Pre-compute maxLocal per function (avoids .reduce() on every call).
        // MUST consider BOTH fn.locals AND fn.params: params and locals share the
        // single LocalId id-space, and a parameter's id can exceed the maximum id
        // in fn.locals (e.g. a function with high-id params but few/no body
        // locals). When maxLocal was computed from fn.locals only, pushCallFrame's
        // `param.id < maxLocal` guard at the parameter-write loop silently skipped
        // those high-id parameters, leaving them as .unit. The interpreted codegen
        // then read .unit (NULL) for those params and emitted NULL stores into
        // enum/struct payloads — the bootstrap "NULL payload" crash that only
        // surfaced for large compiler functions.
        self.maxLocals = program.functions.map { fn in
            let maxLocalId = fn.locals.reduce(0) { max($0, $1.id) }
            let maxParamId = fn.params.reduce(0) { max($0, $1.id) }
            return Swift.max(maxLocalId, maxParamId) + 1
        }
        // Pre-compute return local per function
        self.retLocals = program.functions.map { fn in
            fn.locals.first?.id ?? 0
        }
        // Pre-allocate flat locals stack (grows as needed)
        self.localsStack = [MirValue](repeating: .unit, count: 8192)
        // Pre-build type name → indices for O(1) enum construction (handles duplicate names)
        var tdi: [String: [Int]] = [:]
        tdi.reserveCapacity(program.typeDefs.count)
        for (i, td) in program.typeDefs.enumerated() {
            tdi[td.name, default: []].append(i)
        }
        self.typeDefIndex = tdi
        var payloadShapes: [String: [EnumPayloadShape]] = [:]
        payloadShapes.reserveCapacity(program.typeDefs.count)
        for td in program.typeDefs {
            guard case .enumDef(let variants) = td.kind else { continue }
            var shapes: [EnumPayloadShape] = []
            shapes.reserveCapacity(variants.count)
            for (variantName, fields) in variants {
                if fields.isEmpty {
                    shapes.append(.unit)
                    continue
                }
                let payloadTypeName = "\(td.name)::\(variantName)"
                if let payloadIndices = tdi[payloadTypeName] {
                    var hasNamedPayloadStruct = false
                    for payloadIdx in payloadIndices {
                        if case .structDef = program.typeDefs[payloadIdx].kind {
                            hasNamedPayloadStruct = true
                            break
                        }
                    }
                    shapes.append(hasNamedPayloadStruct ? .namedStruct : .unnamed(fields.count))
                } else {
                    shapes.append(.unnamed(fields.count))
                }
            }
            payloadShapes[td.name] = shapes
        }
        self.enumPayloadShapes = payloadShapes
        // Pre-allocate array-based call profile
        self.callProfileArray = [Int](repeating: 0, count: program.functions.count)
        self.methodDispatchCache.reserveCapacity(512)
        self.nativeFastPathAliasCache.reserveCapacity(1024)
        self.nativeFastPathSiteCache.reserveCapacity(program.functions.count * 2)
        self.directCallSiteCache.reserveCapacity(program.functions.count * 4)
        self.methodCallSiteCache.reserveCapacity(program.functions.count)
    }
    private let functionIndex: [String: Int]
    private let blockIndices: [[BlockId: MirBlock]]
    private let maxLocals: [Int]
    private let retLocals: [Int]
    private var localsStack: [MirValue]
    private var localsStackTop: Int = 0
    // Cached from current frame to avoid copying Frame struct on every getLocal/setLocal
    private var currentLocalsBase: Int = 0
    private var currentLocalsCount: Int = 0
    private var lastCallFinalParams: [MirValue] = []
    private var lastCallMutRefMask: [Bool] = []
    private var dispatchCache: [String: Int] = [:]
    private var methodDispatchCache: [String: [String: Int]] = [:]
    private var nativeFastPathAliasCache: [String: String] = [:]
    private var nativeFastPathSiteCache: [CallSiteKey: String] = [:]
    private var directCallSiteCache: [CallSiteKey: Int] = [:]
    private var methodCallSiteCache: [StaticMethodCallSiteKey: Int] = [:]
    private var typeDefIndex: [String: [Int]]  // typeName → indices for enum construction (handles dupes)
    private let enumPayloadShapes: [String: [EnumPayloadShape]]
    private var callProfileArray: [Int]  // array-based call profile (indexed by fnIdx)
    // Native Map/Set cache: maps a unique ID to a native Swift dictionary
    private var nativeMapStore: [Int: MirNativeMap] = [:]
    private var nativeMapRefCount: [Int: Int] = [:]  // reference counting for native maps
    private var nextNativeMapId: Int = 1
    private var nativeMapGcCounter: Int = 0  // counter for periodic GC

    // DBG: tracks the current lookup_var name and checking context across entry/exit
    private var lastLookupVarName: String = ""
    // DBG: tracks the current bind_var name
    private var lastBindVarName: String = ""
    // DBG: tracks the current function being type-checked for context in lookup failure traces
    private var currentCheckFnName: String = ""
    // Static set for mutating method check — avoids allocating array on every call
    private static let mutatingMethods: Set<String> = [
        ".push", ".pop", ".insert", ".remove", ".extend",
        ".clear", ".truncate", ".reverse", ".sort", ".resize", ".set"
    ]
    private static let eofTokenKindValue: MirValue = .enumVal("TokenKind", 132, .unit)
    private static let emptySpanValue: MirValue = .structVal("Span", ["file": .string(""), "start": .int(0), "end_pos": .int(0)])
    private static let eofTokenValue: MirValue = .structVal("Token", ["kind": eofTokenKindValue, "span": emptySpanValue])
    /// Create a Span value with the given file, start, and end positions
    private static func spanValue(file: String, start: Int, end: Int) -> MirValue {
        .structVal("Span", ["file": .string(file), "start": .int(start), "end_pos": .int(end)])
    }

    /// Get or upgrade a CodeBuffer's "bytes" field to a MirByteBuffer.
    /// If already a .byteBuffer, returns it directly.
    /// If it's an .array, converts to .byteBuffer and stores back.
    /// If missing, creates a new empty .byteBuffer.
    private func getOrUpgradeByteBuffer(_ bf: inout [String: MirValue]) -> MirByteBuffer {
        if case .byteBuffer(let bb) = bf["bytes"] {
            return bb
        }
        let bb: MirByteBuffer
        if case .array(let arr) = bf["bytes"] {
            bb = MirByteBuffer(data: arr.map { UInt8(truncatingIfNeeded: $0.asInt ?? 0) })
        } else {
            bb = MirByteBuffer()
        }
        bf["bytes"] = .byteBuffer(bb)
        return bb
    }

    @inline(__always)
    private func makeArray<S: Sequence>(_ elements: S) -> MirValue where S.Element == MirValue {
        .array(MirArrayBuffer(elements))
    }



    /// Optimized cloneValue with fast-path for immutable types.
    /// Immutable types (unit, bool, int, float, char, string, fn) return the same reference (COW).
    /// Only mutable types (array, tuple, struct, enum, byteBuffer) are deep cloned.
    private func cloneValue(_ value: MirValue) -> MirValue {
        // Fast path: immutable types - return same reference (copy-on-write)
        if case .unit = value { return value }
        if case .bool = value { return value }
        if case .int = value { return value }
        if case .float = value { return value }
        if case .char = value { return value }
        if case .string = value { return value }
        if case .fn = value { return value }

        // Slow path: mutable types require deep clone
        if case .array(let elements) = value {
            return makeArray(elements.map(cloneValue))
        }
        if case .byteBuffer(let byteBuffer) = value {
            return .byteBuffer(MirByteBuffer(data: byteBuffer.data))
        }
        if case .tuple(let elements) = value {
            return .tuple(elements.map(cloneValue))
        }
        if case .structVal("Map", let fields) = value {
            var clonedFields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, cloneValue($0.value)) })
            if let nativeMap = getNativeMap(value) {
                let newId = nextNativeMapId
                nextNativeMapId += 1
                let clonedMap = MirNativeMap()
                clonedMap.dict.reserveCapacity(nativeMap.count)
                for entry in nativeMap.dict.values {
                    clonedMap.insert(cloneValue(entry.key), cloneValue(entry.value))
                }
                nativeMapStore[newId] = clonedMap
                nativeMapRefCount[newId] = 1
                clonedFields["_nid"] = .int(newId)
            }
            return .structVal("Map", clonedFields)
        }
        if case .structVal(let name, let fields) = value {
            return .structVal(name, Dictionary(uniqueKeysWithValues: fields.map { ($0.key, cloneValue($0.value)) }))
        }
        if case .enumVal(let name, let tag, let payload) = value {
            return .enumVal(name, tag, cloneValue(payload))
        }
        return value
    }


    private func valueKindName(_ value: MirValue) -> String {
        switch value {
        case .unit:
            return "unit"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .float:
            return "float"
        case .char:
            return "char"
        case .string:
            return "string"
        case .fn:
            return "fn"
        case .tuple:
            return "tuple"
        case .array:
            return "array"
        case .byteBuffer:
            return "byteBuffer"
        case .structVal(let name, _):
            return "struct:\(name)"
        case .enumVal(let name, let tag, _):
            return "enum:\(name)#\(tag)"
        }
    }

    /// Check if an MIR operand's referenced local is in the valid_locals set.
    /// Returns true for constants or valid locals, false for invalid/unrecognized.
    @inline(__always)
    private func operandLocalValid(_ op: MirValue, _ validLocals: MirNativeMap) -> Bool {
        guard case .structVal(_, let opFields) = op,
              case .enumVal(_, let kindIdx, let payload) = opFields["kind"] else { return false }
        if kindIdx == 2 { return true } // MirConstant — always valid
        guard kindIdx == 0 || kindIdx == 1, // MirCopy or MirMovePlace
              case .structVal(_, let placeFields) = payload,
              case .structVal(_, let lidFields) = placeFields["local"],
              let localId = lidFields["id"]?.asInt else { return false }
        return validLocals.contains(.int(localId))
    }

    /// Check if an MIR rvalue passes verification (all referenced locals are valid).
    private func rvalueValid(_ rvalue: MirValue, _ validLocals: MirNativeMap) -> Bool {
        guard case .structVal(_, let rvFields) = rvalue,
              case .enumVal(_, let kindIdx, let payload) = rvFields["kind"] else { return false }
        switch kindIdx {
        case 0: // MirMove(operand)
            return operandLocalValid(payload, validLocals)
        case 1: // MirRef(Place)
            guard case .structVal(_, let pf) = payload,
                  case .structVal(_, let lf) = pf["local"],
                  let lid = lf["id"]?.asInt else { return false }
            return validLocals.contains(.int(lid))
        case 3: // MirAggregate(kind, operands)
            guard case .tuple(let parts) = payload, parts.count >= 2,
                  case .array(let ops) = parts[1] else { return false }
            for op in ops { if !operandLocalValid(op, validLocals) { return false } }
            return true
        case 4: // MirBinOp(op, lhs, rhs)
            guard case .tuple(let parts) = payload, parts.count >= 3 else { return false }
            return operandLocalValid(parts[1], validLocals) && operandLocalValid(parts[2], validLocals)
        case 5: // MirUnOp(op, operand)
            guard case .tuple(let parts) = payload, parts.count >= 2 else { return false }
            return operandLocalValid(parts[1], validLocals)
        case 8: // MirCast(kind, operand, type)
            guard case .tuple(let parts) = payload, parts.count >= 2 else { return false }
            return operandLocalValid(parts[1], validLocals)
        case 10: // MirPhi(entries)
            guard case .array(let entries) = payload else { return false }
            for entry in entries {
                guard case .tuple(let pair) = entry, pair.count >= 2,
                      case .structVal(_, let lf) = pair[1],
                      let lid = lf["id"]?.asInt else { return false }
                if !validLocals.contains(.int(lid)) { return false }
            }
            return true
        default: // MirRefMut, MirDiscriminant, MirLen, MirRepeat — no validation
            return true
        }
    }

    /// Emit a 32-bit LE instruction word into the CodeBuffer structVal.
    /// Extracts the byte buffer from the struct, appends the word, and sets lastCallFinalParams.
    @inline(__always)
    private func emitWordToCodeBuf(_ bufArg: MirValue, _ word: UInt32) -> MirValue? {
        guard case .structVal(let sn, var bf) = bufArg else { return nil }
        let bb = getOrUpgradeByteBuffer(&bf)
        bb.data.append(UInt8(truncatingIfNeeded: word))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 8))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 16))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 24))
        recordMutatedFirstArg(.structVal(sn, bf))
        return .unit
    }

    @inline(__always)
    private func recordMutatedFirstArg(_ value: MirValue) {
        lastCallFinalParams = [value]
        lastCallMutRefMask = [true]
    }

    // MARK: - Public API

    public func run(entryFunction: String = "main") -> InterpreterResult {
        output = []
        trace = []
        callStack = []
        localsStackTop = 0
        dispatchCache = [:]
        halted = false
        runtimeError = nil
        startTime = Date()
        nextProgressReportStep = progressReportInterval > 0 ? progressReportInterval : .max

        guard let fn = findFunction(entryFunction) else {
            return InterpreterResult(exitCode: 1, output: ["Error: function '\(entryFunction)' not found"],
                                     trace: trace)
        }

        let result = callFunction(fn, args: [])
        dumpCallProfileIfRequested()
        if let runtimeError {
            var finalOutput = output
            if finalOutput.last != runtimeError {
                finalOutput.append(runtimeError)
            }
            return InterpreterResult(exitCode: 1, output: finalOutput, trace: trace, returnValue: result)
        }
        if halted {
            var finalOutput = output
            let haltMessage = finalOutput.last ?? "Error: interpreter halted"
            if finalOutput.last != haltMessage {
                finalOutput.append(haltMessage)
            }
            return InterpreterResult(exitCode: 1, output: finalOutput, trace: trace, returnValue: result)
        }
        return InterpreterResult(exitCode: 0, output: output, trace: trace, returnValue: result)
    }

    private func dumpCallProfileIfRequested() {
        guard ProcessInfo.processInfo.environment["TG_INTERPRETER_CALL_PROFILE"] != nil else { return }
        var entries: [(idx: Int, name: String, count: Int)] = []
        for (i, fn) in program.functions.enumerated() {
            let count = callProfileArray[i]
            if count > 0 {
                entries.append((i, fn.name, count))
            }
        }
        entries.sort { $0.count > $1.count }
        var lines = ["=== TG_INTERPRETER_CALL_PROFILE ==="]
        for e in entries.prefix(60) {
            lines.append(String(format: "%10d %@", e.count, e.name))
        }
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    public struct InterpreterResult {
        public let exitCode: Int
        public let output: [String]
        public let trace: [TraceEntry]
        public var returnValue: MirValue?
    }

    // MARK: - Function dispatch

    /// Push a new call frame for function at `fnIdx` with given arguments.
    private func pushCallFrame(_ fnIdx: Int, args: [MirValue]) {
        let fn = program.functions[fnIdx]
        callProfileArray[fnIdx] += 1
        let maxLocal = maxLocals[fnIdx]
        let localsBase = localsStackTop
        let needed = localsBase + maxLocal
        if needed > localsStack.count {
            let growth = max(maxLocal, localsStack.count)
            localsStack.append(contentsOf: repeatElement(.unit, count: growth))
        }
        for i in localsBase..<needed {
            localsStack[i] = .unit
        }
        localsStackTop = needed
        for (i, param) in fn.params.enumerated() {
            if i < args.count && param.id < maxLocal {
                localsStack[localsBase + param.id] = args[i]
            }
        }
        var frame = Frame(functionIdx: fnIdx, localsBase: localsBase, localsCount: maxLocal,
                          currentBlock: fn.entryBlock, stmtIndex: 0)
        for param in fn.params {
            if case .ref(_, mutable: true) = param.type {
                frame.mutBorrows[param.id] = MirPlace(local: param.id)
            }
        }
        callStack.append(frame)
        currentLocalsBase = localsBase
        currentLocalsCount = maxLocal
    }

    /// Clean up current frame: capture &mut write-back params, release maps, pop frame.
    private func popCallFrame() {
        let calleeFrame = callStack.removeLast()
        let calleeFn = program.functions[calleeFrame.functionIdx]
        // Capture mut write-back params
        var hasMutRef = false
        for param in calleeFn.params {
            if case .ref(_, mutable: true) = param.type { hasMutRef = true; break }
        }
        if hasMutRef {
            lastCallMutRefMask = calleeFn.params.map { p in
                if case .ref(_, mutable: true) = p.type { return true }
                return false
            }
            lastCallFinalParams = calleeFn.params.map { p in
                p.id < calleeFrame.localsCount ? localsStack[calleeFrame.localsBase + p.id] : .unit
            }
        } else {
            lastCallMutRefMask = []
            lastCallFinalParams = []
        }
        let localsBase = calleeFrame.localsBase
        // Slots are reinitialized in pushCallFrame, so avoid eager per-return clears.
        localsStackTop = localsBase
        // Update cached locals base/count for the caller frame
        if let callerFrame = callStack.last {
            currentLocalsBase = callerFrame.localsBase
            currentLocalsCount = callerFrame.localsCount
        }
    }

    /// Apply call result to the caller frame using saved continuation.
    private func applyCallContinuation(_ result: MirValue) {
        let frameIdx = callStack.count - 1
        var caller = callStack[frameIdx]
        let dest = caller.pendingDest
        let next = caller.pendingNext
        let calleeName = caller.pendingCalleeName
        let callArgs = caller.pendingCallOperands
        let argVals = caller.pendingArgVals
        caller.hasPending = false

        // Handle mutating method write-back
        if calleeName.hasPrefix("."), !argVals.isEmpty {
            if Self.mutatingMethods.contains(calleeName) {
                let writeBackValue: MirValue
                switch calleeName {
                case ".pop", ".remove": writeBackValue = argVals.first ?? .unit
                default: writeBackValue = result
                }
                if let receiverPlace = { () -> MirPlace? in
                    switch callArgs[0] {
                    case .copy(let p), .move(let p): return p
                    default: return nil
                    }
                }() {
                    if receiverPlace.projections.isEmpty {
                        setLocal(receiverPlace.local, writeBackValue)
                    } else {
                        var base = getLocal(receiverPlace.local)
                        base = setProjected(base, projections: receiverPlace.projections, value: writeBackValue)
                        setLocal(receiverPlace.local, base)
                    }
                    if let tracking = callStack[callStack.count - 1].mapMutPayloads[receiverPlace.local] {
                        let modifiedVal = getLocal(receiverPlace.local)
                        updateMapEntry(mapPlace: tracking.mapPlace, key: tracking.key, value: modifiedVal)
                    }
                    propagateFieldCopy(receiverPlace.local)
                }
            }
        }

        // Handle &mut argument write-back
        if !lastCallFinalParams.isEmpty {
            for (i, arg) in callArgs.enumerated() {
                guard i < lastCallFinalParams.count else { break }
                guard i < lastCallMutRefMask.count, lastCallMutRefMask[i] else { continue }
                let argPlace: MirPlace?
                switch arg {
                case .copy(let p), .move(let p): argPlace = p
                default: argPlace = nil
                }
                if let ap = argPlace {
                    let borrowedPlace = caller.mutBorrows[ap.local] ?? ap
                    let modifiedVal = lastCallFinalParams[i]
                    if borrowedPlace.projections.isEmpty {
                        setLocal(borrowedPlace.local, modifiedVal)
                        propagateFieldCopy(borrowedPlace.local)
                    } else {
                        var base = getLocal(borrowedPlace.local)
                        base = setProjected(base, projections: borrowedPlace.projections, value: modifiedVal)
                        setLocal(borrowedPlace.local, base)
                        propagateFieldCopy(borrowedPlace.local)
                    }
                }
            }
        }

        setLocal(dest, result)

        // Track .get_mut / .get results for Map mutation write-back
        if (calleeName == ".get_mut" || calleeName == ".get") && callArgs.count >= 2 {
            let receiverPlace: MirPlace?
            switch callArgs[0] {
            case .copy(let p), .move(let p): receiverPlace = p
            default: receiverPlace = nil
            }
            if let receiverPlace {
                caller.mapMutOptions[dest] = (mapPlace: receiverPlace, key: argVals[1])
            }
        }

        caller.currentBlock = next
        callStack[frameIdx] = caller
    }

    private func callFunction(_ fn: MirFunction, args: [MirValue]) -> MirValue {
        if enableTrace { addTrace(fn.name, fn.entryBlock, .enterFunction, "args=\(args.map(\.description))") }

        guard let fnIdx = functionIndex[fn.name] else {
            let msg = "INTERPRETER: function '\(fn.name)' not found in program"
            output.append(msg)
            runtimeError = msg
            halted = true
            return .unit
        }

        // Push initial frame
        pushCallFrame(fnIdx, args: args)

        var lastResult: MirValue = .unit

        // Iterative trampoline: instead of recursive callFunction calls,
        // we loop here and push/pop frames as needed.
        while !callStack.isEmpty && !halted {
            let currentFnIdx = callStack[callStack.count - 1].functionIdx
            hasDeferredCall = false
            lastResult = executeBlocksFast(currentFnIdx)

            if hasDeferredCall {
                // A user function call was deferred by dispatchCall.
                // The current frame saved its continuation already.
                hasDeferredCall = false
                if enableTrace {
                    let calleeFn = program.functions[deferredFnIdx]
                    addTrace(calleeFn.name, calleeFn.entryBlock, .enterFunction, "deferred")
                }
                pushCallFrame(deferredFnIdx, args: deferredArgs)
                continue
            }

            // Normal return — clean up and deliver to caller
            let calleeFnName = program.functions[callStack[callStack.count - 1].functionIdx].name
            popCallFrame()
            if enableTrace { addTrace(calleeFnName, -1, .exitFunction, "result=\(lastResult.description)") }

            if callStack.isEmpty {
                return lastResult
            }

            // Apply result to caller's continuation
            if callStack[callStack.count - 1].hasPending {
                applyCallContinuation(lastResult)
            } else {
                // No pending continuation — this callFunction was invoked from
                // within a native fast-path (e.g., .map closure).
                // Return through the stack to the native code.
                return lastResult
            }
        }

        return lastResult
    }

    // MARK: - Block execution loop

    private func executeBlocksFast(_ fnIdx: Int) -> MirValue {
        let fn = program.functions[fnIdx]
        var steps = 0
        let blockIndex = blockIndices[fnIdx]
        let retLocal = retLocals[fnIdx]

        while steps < maxSteps && !halted {
            steps += 1
            stepCount += 1
            let frameIdx = callStack.count - 1
            let blockId = callStack[frameIdx].currentBlock

            if stepCount >= nextProgressReportStep {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate: String
                if elapsed > 0 {
                    let stepsPerSec = Int(Double(stepCount) / elapsed)
                    rate = " \(stepsPerSec) steps/s"
                } else {
                    rate = ""
                }
                let message = "INTERPRETER_PROGRESS step=\(stepCount) elapsed=\(String(format: "%.1f", elapsed))s\(rate) fn=\(fn.name) block=\(blockId)"
                if let data = (message + "\n").data(using: .utf8) {
                    FileHandle.standardOutput.write(data)
                }
                nextProgressReportStep += progressReportInterval
            }

            guard let block = blockIndex[blockId] else {
                return .unit
            }

            if enableTrace { addTrace(fn.name, blockId, .enterBlock, "stmts=\(block.statements.count)") }

            // Execute statements
            var stmtIndex = 0
            let stmtCount = block.statements.count
            while stmtIndex < stmtCount {
                callStack[frameIdx].stmtIndex = stmtIndex
                executeStatement(block.statements[stmtIndex], fn: fn)
                stmtIndex += 1
            }

            // Execute terminator
            callStack[frameIdx].stmtIndex = stmtCount
            switch block.terminator {
            case .ret:
                if enableTrace { addTrace(fn.name, blockId, .terminator, "return") }
                return getLocal(retLocal)

            case .goto(let target):
                if enableTrace { addTrace(fn.name, blockId, .terminator, "goto bb\(target)") }
                callStack[frameIdx].currentBlock = target

            case .switchInt(let operand, let targets, let otherwise):
                let val = evalOperand(operand)
                var jumped = false
                if let intVal = val.asInt {
                    for (targetVal, targetBB) in targets {
                        if intVal == targetVal {
                            if enableTrace { addTrace(fn.name, blockId, .terminator, "switch \(intVal) -> bb\(targetBB)") }
                            callStack[frameIdx].currentBlock = targetBB
                            jumped = true
                            break
                        }
                    }
                }
                if !jumped {
                    if enableTrace { addTrace(fn.name, blockId, .terminator, "switch otherwise -> bb\(otherwise)") }
                    callStack[frameIdx].currentBlock = otherwise
                }

            case .call(let dest, let callee, let callArgs, let next, _):
                let calleeVal = evalOperand(callee)
                let argVals = callArgs.map { evalOperand($0) }

                let result: MirValue
                if case .fn(let name) = calleeVal {
                    let staticSiteKey: CallSiteKey?
                    if case .constant(.fnItem(let staticName)) = callee, staticName == name {
                        staticSiteKey = currentCallSiteKey()
                    } else {
                        staticSiteKey = nil
                    }
                    lastCallFinalParams = []
                    lastCallMutRefMask = []
                    result = dispatchCall(name, args: argVals, staticSite: staticSiteKey)
                    // Check if dispatchCall deferred a user-function call
                    if hasDeferredCall {
                        // Save continuation on current frame and return to trampoline
                        callStack[frameIdx].pendingDest = dest.local
                        callStack[frameIdx].pendingNext = next
                        callStack[frameIdx].pendingCalleeName = name
                        callStack[frameIdx].pendingCallOperands = callArgs
                        callStack[frameIdx].pendingArgVals = argVals
                        callStack[frameIdx].hasPending = true
                        return .unit
                    }
                    // For mutating method calls, write result back to receiver
                    if name.hasPrefix("."), !argVals.isEmpty {
                        if Self.mutatingMethods.contains(name) {
                            // For methods that return an extracted element (not the modified collection),
                            // compute the modified collection separately for write-back.
                            let writeBackValue: MirValue
                            switch name {
                            case ".pop":
                                writeBackValue = argVals.first ?? .unit
                            case ".remove":
                                writeBackValue = argVals.first ?? .unit
                            default:
                                writeBackValue = result
                            }
                            // The first arg operand is the receiver — update its local.
                            // With borrow synthesis, callArgs[0] is a borrow ref temp;
                            // follow mutBorrows back to the original place.
                            if let receiverPlace = { () -> MirPlace? in
                                switch callArgs[0] {
                                case .copy(let p), .move(let p): return p
                                default: return nil
                                }
                            }() {
                                let curFrame = callStack[callStack.count - 1]
                                let borrowedPlace = curFrame.mutBorrows[receiverPlace.local] ?? receiverPlace
                                if borrowedPlace.projections.isEmpty {
                                    setLocal(borrowedPlace.local, writeBackValue)
                                    propagateFieldCopy(borrowedPlace.local)
                                } else {
                                    var base = getLocal(borrowedPlace.local)
                                    base = setProjected(base, projections: borrowedPlace.projections, value: writeBackValue)
                                    setLocal(borrowedPlace.local, base)
                                    propagateFieldCopy(borrowedPlace.local)
                                }
                                // Map-mut write-back for mutating methods on tracked payloads
                                if let tracking = callStack[callStack.count - 1].mapMutPayloads[receiverPlace.local] {
                                    let modifiedVal = getLocal(receiverPlace.local)
                                    updateMapEntry(mapPlace: tracking.mapPlace, key: tracking.key, value: modifiedVal)
                                }
                                // Also propagate field copy changes
                                propagateFieldCopy(receiverPlace.local)
                            }
                        }
                    }
                    // Write back &mut arguments for user-defined function calls
                    if !lastCallFinalParams.isEmpty {
                        let curFrame = callStack[callStack.count - 1]
                        for (i, arg) in callArgs.enumerated() {
                            guard i < lastCallFinalParams.count else { break }
                            guard i < lastCallMutRefMask.count, lastCallMutRefMask[i] else { continue }
                            let argPlace: MirPlace?
                            switch arg {
                            case .copy(let p), .move(let p): argPlace = p
                            default: argPlace = nil
                            }
                            if let ap = argPlace {
                                let borrowedPlace = curFrame.mutBorrows[ap.local] ?? ap
                                let modifiedVal = lastCallFinalParams[i]
                                if borrowedPlace.projections.isEmpty {
                                    setLocal(borrowedPlace.local, modifiedVal)
                                    propagateFieldCopy(borrowedPlace.local)
                                } else {
                                    var base = getLocal(borrowedPlace.local)
                                    base = setProjected(base, projections: borrowedPlace.projections, value: modifiedVal)
                                    setLocal(borrowedPlace.local, base)
                                    propagateFieldCopy(borrowedPlace.local)
                                }
                            }
                        }
                    }
                } else if case .tuple(let parts) = calleeVal, !parts.isEmpty, case .fn(let name) = parts[0] {
                    // Closure with captures: extract fn name and append captures to args
                    let captures = Array(parts.dropFirst())
                    lastCallFinalParams = []
                    lastCallMutRefMask = []
                    result = dispatchCall(name, args: argVals + captures)
                    // Check if dispatchCall deferred a user-function call
                    if hasDeferredCall {
                        callStack[callStack.count - 1].pendingDest = dest.local
                        callStack[callStack.count - 1].pendingNext = next
                        callStack[callStack.count - 1].pendingCalleeName = name
                        callStack[callStack.count - 1].pendingCallOperands = callArgs
                        callStack[callStack.count - 1].pendingArgVals = argVals + captures
                        callStack[callStack.count - 1].hasPending = true
                        return .unit
                    }
                } else if calleeVal == .unit && !argVals.isEmpty {
                    // Tuple construction: callee is () with args → produce tuple
                    result = .tuple(argVals)
                } else {
                    result = .unit
                }

                setLocal(dest.local, result)
                
                // Track .get_mut / .get results for map mutation write-back
                if case .fn(let name) = calleeVal, name == ".get_mut" || name == ".get" {
                    if callArgs.count >= 2 {
                        let receiverPlace: MirPlace?
                        switch callArgs[0] {
                        case .copy(let p), .move(let p): receiverPlace = p
                        default: receiverPlace = nil
                        }
                        if let receiverPlace {
                            let keyVal = argVals[1]
                            callStack[callStack.count - 1].mapMutOptions[dest.local] = (mapPlace: receiverPlace, key: keyVal)
                        }
                    }
                }

                callStack[callStack.count - 1].currentBlock = next

            case .assert(let cond, let expected, let message, let target):
                let val = evalOperand(cond)
                let boolVal = val.asBool ?? false
                if boolVal != expected {
                    output.append("ASSERTION FAILED: \(message)")
                    return .unit
                }
                callStack[callStack.count - 1].currentBlock = target

            case .drop(_, let next, _):
                callStack[callStack.count - 1].currentBlock = next

            case .unreachable:
                output.append("UNREACHABLE reached!")
                return .unit

            case .abort:
                output.append("ABORT!")
                return .unit

            case .yield:
                return .unit
            }
        }

        if steps >= maxSteps {
            runtimeError = "Error: interpreter step limit exceeded (maxSteps=\(maxSteps))"
            halted = true
            output.append("INTERPRETER: max steps (\(maxSteps)) exceeded in \(fn.name) at block \(callStack.last?.currentBlock ?? -1), total steps=\(stepCount)")
        }
        return .unit
    }

    // MARK: - Statement execution

    @inline(__always)
    private func executeStatement(_ stmt: MirStatement, fn: MirFunction) {
        switch stmt {
        case .assign(let place, let rvalue):
            let val = evalRvalue(rvalue)
            if place.projections.isEmpty {
                setLocal(place.local, val)
                if case .ref(.mutable, let borrowedPlace) = rvalue {
                    let frameIdx = callStack.count - 1
                    callStack[frameIdx].mutBorrows[place.local] = borrowedPlace
                }
                // Track field copies and downcast extractions for mutation propagation
                if case .use(let operand) = rvalue {
                    let srcPlace: MirPlace?
                    switch operand {
                    case .copy(let p), .move(let p): srcPlace = p
                    default: srcPlace = nil
                    }
                    if let sp = srcPlace {
                        let frameIdx = callStack.count - 1
                        // Direct subscript access — avoids copying the entire Frame struct
                        // (which contains 5 dictionaries) on every assignment.
                        // Track downcast projections (e.g., Option::Some payload extraction)
                        if let lastProj = sp.projections.last,
                           case .downcast(let variantIdx) = lastProj {
                            callStack[frameIdx].downcastTracker[place.local] = (enumLocal: sp.local, variantIdx: variantIdx)
                            // Also propagate get_mut tracking through downcast
                            if let tracking = callStack[frameIdx].mapMutOptions[sp.local] {
                                callStack[frameIdx].mapMutPayloads[place.local] = tracking
                            }
                        }
                        // Track lvalue copies so mutating method results can write back through
                        // field and index projections such as env.scopes[idx].insert(...).
                        else if !sp.projections.isEmpty,
                           sp.projections.allSatisfy({ projection in
                               switch projection {
                               case .field(_), .namedField(_), .index(_), .constantIndex(_):
                                   return true
                               default:
                                   return false
                               }
                           }) {
                            callStack[frameIdx].fieldCopyTracker[place.local] = sp
                        }
                        // Propagate if source is already a tracked payload (copy/alias)
                        if sp.projections.isEmpty {
                            if let tracking = callStack[frameIdx].mapMutPayloads[sp.local] {
                                callStack[frameIdx].mapMutPayloads[place.local] = tracking
                            }
                            if let tracking = callStack[frameIdx].downcastTracker[sp.local] {
                                callStack[frameIdx].downcastTracker[place.local] = tracking
                            }
                            if let tracking = callStack[frameIdx].fieldCopyTracker[sp.local] {
                                callStack[frameIdx].fieldCopyTracker[place.local] = tracking
                            }
                        }
                    }
                }
                if enableTrace { addTrace(fn.name, callStack.last!.currentBlock, .statement,
                         "_\(place.local) = \(val.description)") }
            } else {
                var base = getLocal(place.local)
                base = setProjected(base, projections: place.projections, value: val)
                setLocal(place.local, base)
                
                // Map-mut write-back: if this local is a tracked get_mut payload, update the map
                if let tracking = callStack[callStack.count - 1].mapMutPayloads[place.local] {
                    let modifiedVal = getLocal(place.local)
                    updateMapEntry(mapPlace: tracking.mapPlace, key: tracking.key, value: modifiedVal)
                }
                // Also propagate field copy changes
                propagateFieldCopy(place.local)
                
                if enableTrace { addTrace(fn.name, callStack.last!.currentBlock, .statement,
                         "_\(place.local).\(place.projections) = \(val.description)") }
            }

        case .storageLive(let id):
            if enableTrace { addTrace(fn.name, callStack.last!.currentBlock, .statement, "StorageLive(_\(id))") }

        case .storageDead(let id):
            // Free native maps held by this local to prevent unbounded nativeMapStore growth
            let deadIdx = callStack[callStack.count - 1].localsBase + id
            let val = localsStack[deadIdx]
            if case .structVal("Map", _) = val {
                releaseNativeMaps(val)
            }
            localsStack[deadIdx] = .unit
            // Keep per-frame tracking maps bounded by removing dead locals.
            callStack[callStack.count - 1].mapMutPayloads.removeValue(forKey: id)
            callStack[callStack.count - 1].fieldCopyTracker.removeValue(forKey: id)
            callStack[callStack.count - 1].downcastTracker.removeValue(forKey: id)
            callStack[callStack.count - 1].mutBorrows.removeValue(forKey: id)
            if enableTrace { addTrace(fn.name, callStack.last!.currentBlock, .statement, "StorageDead(_\(id))") }

        case .setDiscriminant(let place, let disc):
            setLocal(place.local, .int(disc))

        case .nop:
            break
        }
    }

    // MARK: - Rvalue evaluation

    @inline(__always)
    private func evalRvalue(_ rvalue: MirRvalue) -> MirValue {
        switch rvalue {
        case .use(let op):
            return evalOperand(op)

        case .binaryOp(let op, let l, let r):
            let lv = evalOperand(l)
            let rv = evalOperand(r)
            return evalBinaryOp(op, lv, rv)

        case .unaryOp(let op, let operand):
            let v = evalOperand(operand)
            return evalUnaryOp(op, v)

        case .aggregate(let kind, let operands):
            let vals = operands.map { evalOperand($0) }
            switch kind {
            case .tuple:
                return .tuple(vals)
            case .array:
                return makeArray(vals)
             case .structCtor(let name, let fieldNames):
                 var dict: [String: MirValue] = [:]
                 for (i, fname) in fieldNames.enumerated() {
                     dict[fname] = i < vals.count ? vals[i] : .unit
                 }
                 structFieldOrders[name] = fieldNames
                 // Store by variant index if tagged struct, so downcast
                 // can find the correct field order for each variant.
                 if fieldNames.first == "_tag",
                    let tagIdx = vals.first?.asInt {
                     structFieldOrders["\(name)::v\(tagIdx)"] = Array(fieldNames.dropFirst())
                 }
                 return .structVal(name, dict)
             case .enumCtor(let name, let idx):
                let payload: MirValue
                if let tdIndices = typeDefIndex[name] {
                    var resolvedPayload: MirValue? = nil
                    for tdIdx in tdIndices {
                        guard tdIdx < program.typeDefs.count else { continue }
                        let td = program.typeDefs[tdIdx]
                        guard case .enumDef(let variants) = td.kind, idx < variants.count else { continue }

                        let payloadTypeName = "\(td.name)::\(variants[idx].0)"
                        let hasNamedPayloadStruct: Bool
                        if let payloadIndices = typeDefIndex[payloadTypeName] {
                            var foundStruct = false
                            for payloadIdx in payloadIndices {
                                guard payloadIdx < program.typeDefs.count else { continue }
                                if case .structDef = program.typeDefs[payloadIdx].kind {
                                    foundStruct = true
                                    break
                                }
                            }
                            hasNamedPayloadStruct = foundStruct
                        } else {
                            hasNamedPayloadStruct = false
                        }

                        if hasNamedPayloadStruct {
                            let payloadStruct = vals.first ?? .unit
                            // structFieldOrders is already populated at struct
                            // construction (line 1032) with declaration-ordered
                            // field names. Do NOT overwrite with Dictionary keys
                            // which are hash-ordered and nondeterministic.
                            resolvedPayload = payloadStruct
                        } else {
                            let fieldCount = variants[idx].1.count
                            if fieldCount == 0 {
                                resolvedPayload = .unit
                            } else if fieldCount == 1 {
                                resolvedPayload = vals.first ?? .unit
                            } else {
                                resolvedPayload = .tuple(vals)
                            }
                        }
                        break
                    }
                    payload = resolvedPayload ?? (vals.isEmpty ? .unit : .tuple(vals))
                } else if vals.isEmpty {
                    payload = .unit
                } else {
                    payload = .tuple(vals)
                }
                return .enumVal(name, idx, payload)
            case .closure(let name):
                if vals.isEmpty {
                    return .fn(name)
                } else {
                    // Bundle captured values with function reference
                    return .tuple([.fn(name)] + vals)
                }
            }

        case .ref(_, let place):
            return loadPlaceValue(place)

        case .discriminant(let place):
            let val = getLocal(place.local)
            if case .enumVal(_, let idx, _) = val {
                return .int(idx)
            }
            // Handle structVal-based enum: _tag field holds the discriminant
            if case .structVal(_, let fields) = val, let tagVal = fields["_tag"] {
                return tagVal
            }
            // Handle unit-only enum variants represented as bare integers
            // (MIR lowers ExprPath for unit-only enums to MirInt(discriminant))
            if case .int(let v) = val {
                return .int(v)
            }
            return .int(0)

        case .len(let place):
            let val = getLocal(place.local)
            if case .array(let elems) = val {
                return .int(elems.count)
            }
            if case .string(let s) = val {
                return .int(stringLength(s))
            }
            // Range { start, end } → end - start (exclusive)
            if case .structVal("Range", let f) = val,
               let s = f["start"]?.asInt, let e = f["end"]?.asInt {
                return .int(max(0, e - s))
            }
            // RangeInclusive { start, end } → end - start + 1
            if case .structVal("RangeInclusive", let f) = val,
               let s = f["start"]?.asInt, let e = f["end"]?.asInt {
                return .int(max(0, e - s + 1))
            }
            return .int(0)

        case .cast(let op, let targetType):
            let val = evalOperand(op)
            // Integer-like types (Int, I8-U128, ISize, U8-U128, USize)
            let intLikeNames: Set<String> = [
                "I8", "I16", "I32", "I64", "I128", "ISize",
                "U8", "U16", "U32", "U64", "U128", "USize"
            ]
            switch targetType {
            case .int:
                return convertToInt(val)
            case .named(let n) where intLikeNames.contains(n):
                return convertToInt(val)
            case .float:
                if let f = val.asFloat { return .float(f) }
                if let i = val.asInt { return .float(Double(i)) }
                if case .unit = val { return .float(0) }
                return .float(0)
            case .bool:
                if let b = val.asBool { return .bool(b) }
                if let i = val.asInt { return .bool(i != 0) }
                if case .unit = val { return .bool(false) }
                return .bool(false)
            case .char:
                if case .char(let c) = val { return .char(c) }
                if let i = val.asInt, let u = UInt32(exactly: i),
                   let scalar = UnicodeScalar(u) {
                    return .char(Character(scalar))
                }
                if case .string(let s) = val, let first = s.first { return .char(first) }
                return .char("\0")
            case .string:
                if case .string(let s) = val { return .string(s) }
                return .string(val.displayString)
            case .unit:
                return .unit
            default:
                // For .named (non-integer type constructors), .ref, .rawPtr,
                // .array, .slice, .tuple, .fn, .unknown — identity (no conversion)
                return val
            }
        }
    }

    /// Convert any value to an integer representation (.int).
    @inline(__always)
    private func convertToInt(_ val: MirValue) -> MirValue {
        if let i = val.asInt { return .int(i) }
        if case .unit = val { return .int(0) }
        if case .float(let f) = val { return .int(Int(f)) }
        if case .string(let s) = val { return .int(Int(s) ?? 0) }
        if case .bool(let b) = val { return .int(b ? 1 : 0) }
        return .int(0)
    }

    // MARK: - Operand evaluation

    @inline(__always)
    private func evalOperand(_ op: MirOperand) -> MirValue {
        switch op {
        case .copy(let place), .move(let place):
            return loadPlaceValue(place)
        case .constant(let c):
            return evalConstant(c)
        }
    }

    @inline(__always)
    private func loadPlaceValue(_ place: MirPlace) -> MirValue {
        var val = getLocal(place.local)
        let projections = place.projections
        let count = projections.count
        var i = 0
        while i < count {
            if halted { return .unit }
            val = projectValue(val, projections[i])
            i += 1
        }
        return val
    }

    @inline(__always)
    private func evalConstant(_ c: MirConstant) -> MirValue {
        switch c {
        case .unit: return .unit
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .float(let f): return .float(f)
        case .char(let c): return .char(c)
        case .str(let s): return .string(s)
        case .fnItem(let name): return .fn(name)
        case .zeroSized: return .unit
        }
    }

    // MARK: - Binary/Unary ops

    private func evalBinaryOp(_ op: MirBinOp, _ l: MirValue, _ r: MirValue) -> MirValue {
        // Integer ops
        if let li = l.asInt, let ri = r.asInt {
            switch op {
            case .add: return .int(li &+ ri)
            case .sub: return .int(li &- ri)
            case .mul: return .int(li &* ri)
            case .div:
                guard ri != 0 else { return .int(0) }
                if li == Int.min && ri == -1 {
                    return .int(Int.min)
                }
                return .int(li / ri)
            case .rem:
                guard ri != 0 else { return .int(0) }
                if li == Int.min && ri == -1 {
                    return .int(0)
                }
                return .int(li % ri)
            case .eq: return .bool(li == ri)
            case .ne: return .bool(li != ri)
            case .lt: return .bool(li < ri)
            case .le: return .bool(li <= ri)
            case .gt: return .bool(li > ri)
            case .ge: return .bool(li >= ri)
            case .bitAnd: return .int(li & ri)
            case .bitOr: return .int(li | ri)
            case .bitXor: return .int(li ^ ri)
            case .shl: return .int(li &<< ri)
            case .shr: return .int(li &>> ri)
            case .and: return .bool(li != 0 && ri != 0)
            case .or: return .bool(li != 0 || ri != 0)
            }
        }

        // Float ops
        if let lf = l.asFloat, let rf = r.asFloat {
            switch op {
            case .add: return .float(lf + rf)
            case .sub: return .float(lf - rf)
            case .mul: return .float(lf * rf)
            case .div: return rf != 0 ? .float(lf / rf) : .float(0)
            case .eq: return .bool(lf == rf)
            case .ne: return .bool(lf != rf)
            case .lt: return .bool(lf < rf)
            case .le: return .bool(lf <= rf)
            case .gt: return .bool(lf > rf)
            case .ge: return .bool(lf >= rf)
            default: return .float(0)
            }
        }

        // Bool ops
        if let lb = l.asBool, let rb = r.asBool {
            switch op {
            case .and: return .bool(lb && rb)
            case .or: return .bool(lb || rb)
            case .eq: return .bool(lb == rb)
            case .ne: return .bool(lb != rb)
            default: return .bool(false)
            }
        }

        // String ops
        if case .string(let ls) = l, case .string(let rs) = r {
            switch op {
            case .add: return .string(ls + rs)
            case .eq: return .bool(ls == rs)
            case .ne: return .bool(ls != rs)
            default: return .string("")
            }
        }

        // Coercing string+non-string: treat unit as "" for string operations
        do {
            let ls: String?
            let rs: String?
            switch l {
            case .string(let s): ls = s
            case .unit: ls = ""
            default: ls = nil
            }
            switch r {
            case .string(let s): rs = s
            case .unit: rs = ""
            default: rs = nil
            }
            if let ls = ls, let rs = rs {
                switch op {
                case .add: return .string(ls + rs)
                case .eq: return .bool(ls == rs)
                case .ne: return .bool(ls != rs)
                default: return .string("")
                }
            }
        }

        // Generic equality for enum/struct/tuple/array/unit values
        switch op {
        case .eq: return .bool(l == r)
        case .ne: return .bool(l != r)
        default: return .unit
        }
    }

    private func evalUnaryOp(_ op: MirUnOp, _ v: MirValue) -> MirValue {
        switch op {
        case .neg:
            if let i = v.asInt { return .int(0 &- i) }
            if let f = v.asFloat { return .float(-f) }
            return v
        case .not:
            if let b = v.asBool { return .bool(!b) }
            if let i = v.asInt { return .int(~i) }
            return v
        }
    }

    // MARK: - Projection

    private var fieldOnRawCount = 0
    private var structFieldMissCount = 0
    private var namedFieldOnUnitCount = 0
    private var indexUnitFromArrayCount = 0
    private var pushUnitIntoArrayCount = 0
    private func failProjection<T>(_ proj: MirProjection, on value: MirValue, detail: String, fallback: T) -> T {
        if !halted {
            let functionName = callStack.last.map { program.functions[$0.functionIdx].name } ?? "<no-frame>"
            let stmtInfo: String = {
                guard let frame = callStack.last else { return "<no-frame>" }
                let fn = program.functions[frame.functionIdx]
                let blockIdx = frame.currentBlock
                let block = fn.blocks[blockIdx]
                let stmtIdx = frame.stmtIndex
                let stmtDesc: String
                if stmtIdx >= 0 && stmtIdx < block.statements.count {
                    stmtDesc = "\(block.statements[stmtIdx])"
                } else {
                    stmtDesc = "\(block.terminator)"
                }
                return "fn=\(fn.name) block=\(blockIdx) stmt#\(stmtIdx): \(stmtDesc)"
            }()
            let stackTrace: String = {
                var result = ""
                for (i, frame) in callStack.enumerated() {
                    let fn = program.functions[frame.functionIdx]
                    result += "\n    #\(i) \(fn.name) block=\(frame.currentBlock) stmt=\(frame.stmtIndex)"
                }
                return result
            }()
            let valDesc = "\(valueKindName(value))"
            // Dump the full failing block so we can locate it in source.
            let blockDump: String = {
                guard let frame = callStack.last else { return "" }
                let fn = program.functions[frame.functionIdx]
                let blockIdx = frame.currentBlock
                let block = fn.blocks[blockIdx]
                var s = "block=\(blockIdx) total_blocks=\(fn.blocks.count)"
                for (i, st) in block.statements.enumerated() {
                    let marker = (i == frame.stmtIndex) ? ">>>" : "   "
                    s += "\n    \(marker) [\(i)] \(st)"
                }
                s += "\n        term: \(block.terminator)"
                return s
            }()
            // Dump value contents (for tuple/struct).
            let valDump: String = {
                switch value {
                case .tuple(let elems):
                    var inner = "["
                    for (i, e) in elems.enumerated() {
                        if i > 0 { inner += ", " }
                        inner += valueKindName(e)
                    }
                    inner += "]"
                    return " elems=\(inner) count=\(elems.count)"
                case .structVal(let n, let fs): return " struct=\(n) fields=\(fs.keys.sorted())"
                case .enumVal(let n, let v, let inner): return " enum=\(n) variant=\(v) inner=\(valueKindName(inner))"
                case .fn(let n): return " fn=\(n)"
                default: return ""
                }
            }()
            // Dump locals at the moment of failure (last 8 locals + scrutinee).
            let localsDump: String = {
                guard let frame = callStack.last else { return "" }
                let fn = program.functions[frame.functionIdx]
                var s = ""
                // Dump key locals around the failing area
                let ranges: [(Int, Int)] = [(0, 20), (310, 400), (480, 520), (745, 760)]
                for (lo, hi) in ranges {
                    let lo2 = max(0, lo)
                    let hi2 = min(fn.locals.count, hi)
                    if lo2 >= hi2 { continue }
                    s += "\n      --- range [\(lo2)..\(hi2)) ---"
                    for li in lo2..<hi2 {
                        let lv = getLocal(li)
                        var desc = valueKindName(lv)
                        if case .enumVal(let n, let v, let inner) = lv {
                            desc = "enum(\(n)#\(v) inner=\(valueKindName(inner)))"
                        } else if case .tuple(let elems) = lv {
                            desc = "tuple(count=\(elems.count) elems=\(elems.prefix(4).map { valueKindName($0) }))"
                        } else if case .structVal(let n, let fs) = lv {
                            desc = "struct(\(n)) fields=\(fs.keys.sorted())"
                        }
                        s += "\n      _\(li): \(desc)"
                    }
                }
                // Dump caller frame locals too for context
                if callStack.count >= 2 {
                    let callerFrame = callStack[callStack.count - 2]
                    let callerFn = program.functions[callerFrame.functionIdx]
                    let callerBlock = callerFrame.currentBlock
                    s += "\n    [caller frame: \(callerFn.name) block=\(callerBlock)]"
                    let callerRanges: [(Int, Int)] = [(0, 20), (310, 400)]
                    for (lo, hi) in callerRanges {
                        let lo2 = max(0, lo)
                        let hi2 = min(callerFn.locals.count, hi)
                        if lo2 >= hi2 { continue }
                        s += "\n      --- caller range [\(lo2)..\(hi2)) ---"
                        for li in lo2..<hi2 {
                            let lv = getLocal(li)
                            var desc = valueKindName(lv)
                            if case .enumVal(let n, let v, let inner) = lv {
                                desc = "enum(\(n)#\(v) inner=\(valueKindName(inner)))"
                            } else if case .tuple(let elems) = lv {
                                desc = "tuple(count=\(elems.count) elems=\(elems.prefix(4).map { valueKindName($0) }))"
                            } else if case .structVal(let n, let fs) = lv {
                                desc = "struct(\(n)) fields=\(fs.keys.sorted())"
                            }
                            s += "\n      _\(li): \(desc)"
                        }
                    }
                }
                return s
            }()
            let msg = "INTERPRETER: invalid projection \(String(describing: proj)) on \(valDesc)\(valDump) in \(functionName): \(detail)\n  [context] \(stmtInfo)\n  [block dump]\(blockDump)\n  [locals tail]\(localsDump)\n  [stack]\(stackTrace)"
            output.append(msg)
            runtimeError = msg
            halted = true
        }
        return fallback
    }

    private func projectValue(_ val: MirValue, _ proj: MirProjection) -> MirValue {
        switch proj {
        case .field(let idx):
            switch val {
            case .tuple(let elems):
                return idx < elems.count
                    ? elems[idx]
                    : failProjection(proj, on: val, detail: "tuple index \(idx) out of range (count=\(elems.count))", fallback: .unit)
            case .array(let elems):
                return idx < elems.count
                    ? elems[idx]
                    : failProjection(proj, on: val, detail: "array index \(idx) out of range (count=\(elems.count))", fallback: .unit)
            case .structVal(let name, let fields):
                // Positional access on struct: use recorded field order
                if let order = structFieldOrders[name], idx < order.count {
                    return fields[order[idx]]
                        ?? failProjection(proj, on: val, detail: "struct \(name) is missing recorded field '\(order[idx])'", fallback: .unit)
                }
                structFieldMissCount += 1
                return failProjection(proj, on: val, detail: "struct \(name) has no positional field \(idx)", fallback: .unit)
            case .enumVal(let name, let variantIdx, let inner):
                let payload = normalizedEnumPayload(enumTypeName: name, variantIdx: variantIdx, inner: inner)
                switch payload {
                case .tuple(let elems):
                    return idx < elems.count
                        ? elems[idx]
                        : failProjection(proj, on: val, detail: "enum payload field \(idx) out of range (count=\(elems.count))", fallback: .unit)
                default:
                    if idx == 0 { return payload }
                    return failProjection(proj, on: val, detail: "enum payload only exposes field 0", fallback: .unit)
                }
            default:
                // field(0) on a scalar value (string, int, bool, etc.) after enum
                // downcast: treat as identity — the scalar IS the single payload.
                if idx == 0 { return val }
                fieldOnRawCount += 1
                return failProjection(proj, on: val, detail: "raw value has no field \(idx)", fallback: .unit)
            }
        case .namedField(let name):
            if case .structVal(let sname, let fields) = val {
                if let fieldVal = fields[name] {
                    return fieldVal
                }
                // Single-field "ptr" structs (Box, Owned, Rc, Ptr) are transparent
                // wrappers. Auto-deref through "ptr" when the field doesn't match.
                if fields.count == 1, let inner = fields["ptr"] {
                    return projectValue(inner, proj)
                }
                return failProjection(proj, on: val, detail: "struct \(sname) has no field '\(name)'", fallback: .unit)
            }
            // Handle tuple indexing via numeric field names ("0", "1", ...)
            if case .tuple(let elems) = val, let idx = Int(name), idx >= 0 && idx < elems.count {
                return elems[idx]
            }
            namedFieldOnUnitCount += 1
            return failProjection(proj, on: val, detail: "value has no named field '\(name)'", fallback: .unit)
        case .index(let localId):
            let idxVal = getLocal(localId)
            // Map string-key indexing: map["key"] → lookup in native map
            if case .string(let key) = idxVal,
               case .structVal("Map", let fields) = val,
               let nid = fields["_nid"]?.asInt,
               let nativeMap = nativeMapStore[nid] {
                if let result = nativeMap.get(.string(key)) {
                    return result
                }
                return failProjection(proj, on: val, detail: "map key '\(key)' not found", fallback: .unit)
            }
            // Map integer-key indexing: map[int_key] → lookup in native map
            if case .int(let intKey) = idxVal,
               case .structVal("Map", let fields) = val,
               let nid = fields["_nid"]?.asInt,
               let nativeMap = nativeMapStore[nid] {
                if let result = nativeMap.get(.int(intKey)) {
                    return result
                }
                return failProjection(proj, on: val, detail: "map key \(intKey) not found", fallback: .unit)
            }
            if let idx = idxVal.asInt {
                if case .array(let elems) = val, idx >= 0 && idx < elems.count {
                    let result = elems[idx]
                    if case .unit = result, elems.count > 20 {
                        indexUnitFromArrayCount += 1
                    }
                    return result
                }
                if case .byteBuffer(let bb) = val, idx >= 0 && idx < bb.data.count {
                    return .int(Int(bb.data[idx]))
                }
                if case .string(let s) = val,
                   let ch = stringCharacter(s, at: idx) {
                    return .string(String(ch))
                }
                // Range { start, end } → start + idx
                if case .structVal("Range", let f) = val,
                   let start = f["start"]?.asInt {
                    return .int(start + idx)
                }
                // RangeInclusive { start, end } → start + idx
                if case .structVal("RangeInclusive", let f) = val,
                   let start = f["start"]?.asInt {
                    return .int(start + idx)
                }
                return failProjection(proj, on: val, detail: "index \(idx) is invalid for \(valueKindName(val))", fallback: .unit)
            }
            return failProjection(proj, on: val, detail: "index operand local _\(localId) was \(valueKindName(idxVal)), expected int or string", fallback: .unit)
        case .constantIndex(let idx):
            if case .array(let elems) = val, idx < elems.count {
                return elems[idx]
            }
            return failProjection(proj, on: val, detail: "constant index \(idx) out of range", fallback: .unit)
        case .downcast(let variantIdx):
            if case .enumVal(let name, let idx, let inner) = val, idx == variantIdx {
                return normalizedEnumPayload(enumTypeName: name, variantIdx: idx, inner: inner)
            }
            // If the value is an enum but wrong variant, that's a genuine mismatch
            if case .enumVal(_, let idx, _) = val {
                return failProjection(proj, on: val, detail: "downcast expected variant \(variantIdx), found \(idx)", fallback: .unit)
            }
            // Handle structVal-based enum (from structCtor with _tag field):
            // strip _tag field and return the payload fields only.
            // IMPORTANT: structFieldOrders is SHARED across all variants of an enum type
            // and may be overwritten by a different variant's construction.  We therefore
            // determine payload fields from the ACTUAL dict keys (minus "_tag") rather
            // than relying solely on structFieldOrders.
            if case .structVal(let name, let fields) = val,
               let tagVal = fields["_tag"],
               tagVal.asInt == variantIdx {
                // Compute payload field names from actual dict keys minus "_tag"
                let payloadKeys = Set(fields.keys).subtracting(["_tag"])
                if payloadKeys.isEmpty {
                    return .unit
                }
                // Determine ordering: prefer structFieldOrders keyed by
                // variant index (stable per-variant), falling back to
                // the per-enum entry (shared/overwritten).
                let payloadFieldNames: [String]
                let variantKey = "\(name)::v\(variantIdx)"
                if let order = structFieldOrders[variantKey],
                   Set(order) == payloadKeys {
                    payloadFieldNames = order
                } else if let order = structFieldOrders[name],
                   order.first == "_tag",
                   Set(order.dropFirst()) == payloadKeys {
                    payloadFieldNames = Array(order.dropFirst())
                } else {
                    // Type-def fallback: try to get declaration order from variant fields.
                    // Since field names aren't stored, use alphabetical as last resort.
                    payloadFieldNames = payloadKeys.sorted()
                }
                if payloadFieldNames.count == 1 {
                    // Single-field payload: unwrap and return the value directly,
                    // matching normalizedEnumPayload behavior for single-field variants.
                    return fields[payloadFieldNames[0]] ?? .unit
                }
                // Multi-field payload: return as structVal with payload fields
                var payloadFields: [String: MirValue] = [:]
                for fname in payloadFieldNames {
                    payloadFields[fname] = fields[fname] ?? .unit
                }
                let payloadName = "\(name)::payload_\(variantIdx)"
                structFieldOrders[payloadName] = payloadFieldNames
                return .structVal(payloadName, payloadFields)
            }
            // Non-enum value: likely already unwrapped — return as-is instead of losing data
            return val
        case .deref:
            // Dereference through single-ptr-field wrappers (Box, Owned, Rc, etc.)
            // and Ptr values to get the inner value.
            if case .structVal(_, let fields) = val, fields.count == 1, let inner = fields["ptr"] {
                return inner
            }
            return val // no-op for ref/rawPtr (transparent in interpreter)
        }
    }

    private func setProjected(_ base: MirValue, projections: [MirProjection], value: MirValue) -> MirValue {
        if halted { return base }
        guard let first = projections.first else { return value }
        if projections.count == 1 {
            switch first {
            case .field(let idx):
                switch base {
                case .tuple(var elems):
                    if idx < elems.count {
                        elems[idx] = value
                    } else {
                        return failProjection(first, on: base, detail: "tuple index \(idx) out of range for write", fallback: base)
                    }
                    return .tuple(elems)
                default:
                    return failProjection(first, on: base, detail: "value does not support field write", fallback: base)
                }
            case .namedField(let name):
                if case .structVal(let sName, var fields) = base {
                    guard fields[name] != nil else {
                        return failProjection(first, on: base, detail: "struct \(sName) has no field '\(name)' for write", fallback: base)
                    }
                    fields[name] = value
                    return .structVal(sName, fields)
                }
                // Handle tuple indexing via numeric field names ("0", "1", ...)
                if case .tuple(var elems) = base, let idx = Int(name) {
                    if idx >= 0 && idx < elems.count {
                        elems[idx] = value
                        return .tuple(elems)
                    }
                    return failProjection(first, on: base, detail: "tuple field '\(name)' is out of range for write", fallback: base)
                }
                return failProjection(first, on: base, detail: "value has no named field '\(name)' for write", fallback: base)
            case .index(let localId):
                let idxVal = getLocal(localId)
                // Map string-key write: map["key"] = value → insert into native map
                if case .string(let key) = idxVal,
                   case .structVal("Map", let fields) = base,
                   let nid = fields["_nid"]?.asInt,
                   let nativeMap = nativeMapStore[nid] {
                    nativeMap.insert(.string(key), value)
                    return base  // Map is a reference type via nativeMapStore, already mutated
                }
                // Map integer-key write: map[int_key] = value → insert into native map
                if case .int(let intKey) = idxVal,
                   case .structVal("Map", let fields) = base,
                   let nid = fields["_nid"]?.asInt,
                   let nativeMap = nativeMapStore[nid] {
                    nativeMap.insert(.int(intKey), value)
                    return base
                }
                if let idx = idxVal.asInt {
                    if case .array(let elems) = base, idx >= 0 && idx < elems.count {
                        elems[idx] = value
                        return .array(elems)
                    }
                    if case .byteBuffer(let bb) = base, idx >= 0 && idx < bb.data.count {
                        if let v = value.asInt {
                            bb.data[idx] = UInt8(truncatingIfNeeded: v)
                        }
                        return base  // byteBuffer is a reference type, already mutated
                    }
                    return failProjection(first, on: base, detail: "index \(idx) is invalid for write", fallback: base)
                }
                return failProjection(first, on: base, detail: "index operand local _\(localId) was \(valueKindName(idxVal)), expected int or string for write", fallback: base)
            case .constantIndex(let idx):
                if case .array(let elems) = base, idx >= 0 && idx < elems.count {
                    elems[idx] = value
                    return .array(elems)
                }
                return failProjection(first, on: base, detail: "constant index \(idx) out of range for write", fallback: base)
            case .deref:
                return value  // deref is identity in interpreter (no real pointers)
            default:
                return base
            }
        }
        // Recursive: project one level, then set deeper
        let remaining = Array(projections.dropFirst())
        let inner = projectValue(base, first)
        if halted { return base }
        let newInner = setProjected(inner, projections: remaining, value: value)
        if halted { return base }
        return setProjected(base, projections: [first], value: newInner)
    }

    // MARK: - Built-in dispatch

    // Names that have native fast-path implementations — check these BEFORE dispatch cache
    private static let nativeFastPathNames: Set<String> = [
        // Parser
        "peek", "at", "advance", "skip_newlines",
        // Lexer
        "lexer::char_at", "lexer::is_whitespace", "lexer::is_newline", "lexer::is_digit",
        "lexer::is_alpha", "lexer::is_ident_start", "lexer::is_ident_char",
        "lexer::lex_peek", "lexer::lex_peek_next", "lexer::lex_advance", "lexer::at_end",
        "tg_compiler::lexer::char_at", "tg_compiler::lexer::is_whitespace", "tg_compiler::lexer::is_newline",
        "tg_compiler::lexer::is_digit", "tg_compiler::lexer::is_alpha", "tg_compiler::lexer::is_ident_start",
        "tg_compiler::lexer::is_ident_char", "tg_compiler::lexer::lex_peek", "tg_compiler::lexer::lex_peek_next",
        "tg_compiler::lexer::lex_advance", "tg_compiler::lexer::at_end",
        // lexer_char_at is the renamed form of char_at (avoids collision with String.char_at method)
        "lexer_char_at", "lexer::lexer_char_at", "tg_compiler::lexer::lexer_char_at",
        // Codegen byte emission
        "emit8", "emit16_le", "emit32_le", "emit64_le", "emit_zeros",
        "buf_pos", "patch32_le", "align_to", "rex", "modrm", "sib", "span_new",
        "tg_compiler::asm::emit8", "tg_compiler::asm::emit16_le", "tg_compiler::asm::emit32_le",
        "tg_compiler::asm::emit64_le", "tg_compiler::asm::emit_zeros", "tg_compiler::asm::buf_pos",
        "tg_compiler::asm::patch32_le", "tg_compiler::asm::read32_le", "tg_compiler::asm::align_to",
        "patch32_le_native", "read32_le_native",
        // Linker byte patching
        "read32_at", "write32_at", "write64_at",
        // String/intrinsic fast-paths
        "is_intrinsic", "bare_intrinsic_name", "canonical_fn_ref", "bare_name_from_qualified",
         // Array helpers used by std::collections wrappers
         "array_get", "collections::array_get", "std::collections::array_get", "__intrinsic_array_get",
        // Startup argv helpers
        "raw_arg_count", "raw_arg", "raw_arg_unchecked", "raw_arg_copy",
        "std::args::raw_arg_count", "std::args::raw_arg", "std::args::raw_arg_unchecked", "std::args::raw_arg_copy",
        "std::env::raw_arg_count", "std::env::raw_arg", "std::env::raw_arg_unchecked", "std::env::raw_arg_copy",
        "tg_get_argc", "tg_get_argv", "_tg_arg", "_tg_arg_copy",
        // Stdlib I/O / FS / process helpers
        "print", "println", "eprint", "eprintln",
        "io::print", "io::println", "io::eprint", "io::eprintln",
        "std::io::print", "std::io::println", "std::io::eprint", "std::io::eprintln",
        "from_cstr", "String::from_cstr", "String__from_cstr", "string_from_cstr",
        "read_file_text_direct", "driver::read_file_text_direct",
        "read_to_vec", "read_file", "write_file", "write_file_bytes", "write_file_bytes_owned",
        "file_exists", "path_exists", "mkdir_p", "create_dir_all",
        "list_directory", "list_dir", "read_dir", "delete_file", "remove_file",
        "run_command",
        "fs::read_to_vec", "fs::read_file", "fs::read_to_string",
        "fs::write_file", "fs::write_string", "fs::write_file_string", "fs::write_file_bytes", "fs::write_file_bytes_owned",
        "fs::file_exists", "fs::path_exists", "fs::create_dir_all", "fs::mkdir_p",
        "fs::list_directory", "fs::list_dir", "fs::read_dir",
        "fs::delete_file", "fs::remove_file", "fs::path_join",
        "std::fs::read_to_vec", "std::fs::read_file", "std::fs::read_to_string",
        "std::fs::write_file", "std::fs::write_string", "std::fs::write_file_string", "std::fs::write_file_bytes", "std::fs::write_file_bytes_owned",
        "std::fs::file_exists", "std::fs::path_exists", "std::fs::create_dir_all", "std::fs::mkdir_p",
        "std::fs::list_directory", "std::fs::list_dir", "std::fs::read_dir",
        "std::fs::delete_file", "std::fs::remove_file", "std::fs::path_join",
        "process::run_command", "std::process::run_command",
        // Register encoding
        "a64_code", "a64v_code", "x64_code", "x64_lo3", "x64_hi", "phys_reg_id",
        // Codegen helpers
        "ret_reg", "fp_reg", "place_local", "get_block", "terminator_successors",
        // MIR builder
        "operand_copy_local", "operand_copy", "push_assign", "push_stmt",
        // Codegen load/store and simple register/immediate helpers
        "emit_load_mem", "emit_store_mem", "emit_mov_rr", "load_constant",
        "emit_zero_reg", "emit_mov_ri", "emit_cmp_rr", "emit_cmp_ri",
        "emit_setcc", "emit_add_ri", "emit_sub_ri",
        // Register allocator
        "alloc_reg",
        // MIR verification
        "verify_operand", "verify_rvalue", "verify_statement", "verify_terminator",
        // ARM64 instruction encoding
        "a64_movz", "a64_movk", "a64_mov_ri", "a64_add_rrr", "a64_sub_rrr",
        "a64_ldr", "a64_str", "a64_ldur", "a64_stur",
        "a64_cmp_rr", "a64_cmp_ri", "a64_cset", "a64_mov_rr",
        "a64_and_rrr", "a64_orr_rrr", "a64_eor_rrr", "a64_mul_rrr", "a64_sdiv_rrr",
        "a64_sub_rri", "a64_blr", "a64_ret",
        "a64_stp_pre", "a64_ldp_post", "a64_mov_w", "a64_sxtw", "a64_sub_sp_sp_r",
        "__intrinsic_syscall1", "__intrinsic_syscall2", "__intrinsic_syscall3",
        "__intrinsic_syscall4", "__intrinsic_syscall5", "__intrinsic_syscall6",
    ]

    private static let nativeFastPathPrefixes = [
        "asm::", "tg_compiler::asm::", "codegen::", "tg_compiler::codegen::"
    ]

    @inline(__always)
    private static func resolveNativeFastPathAlias(_ name: String) -> String? {
        if nativeFastPathNames.contains(name) {
            return name
        }
        for prefix in nativeFastPathPrefixes {
            if name.hasPrefix(prefix) {
                let candidate = String(name.dropFirst(prefix.count))
                if nativeFastPathNames.contains(candidate) {
                    return candidate
                }
                return nil
            }
        }
        return nil
    }

    @inline(__always)
    private func cachedNativeFastPathAlias(_ name: String) -> String? {
        if let cached = nativeFastPathAliasCache[name] {
            return cached.isEmpty ? nil : cached
        }
        let resolved = Self.resolveNativeFastPathAlias(name)
        nativeFastPathAliasCache[name] = resolved ?? ""
        return resolved
    }

    @inline(__always)
    private func currentCallSiteKey() -> CallSiteKey? {
        guard !callStack.isEmpty else { return nil }
        let frameIdx = callStack.count - 1
        return CallSiteKey(
            functionIdx: callStack[frameIdx].functionIdx,
            blockId: callStack[frameIdx].currentBlock,
            stmtIndex: callStack[frameIdx].stmtIndex
        )
    }

    @inline(__always)
    private func isMethodName(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard !utf8.isEmpty else { return false }
        return utf8[utf8.startIndex] == 46
    }

    @inline(__always)
    private func methodCallSiteKey(receiverType: String, site: CallSiteKey?) -> StaticMethodCallSiteKey? {
        guard let site else { return nil }
        return StaticMethodCallSiteKey(site: site, receiverType: receiverType)
    }

    @inline(__always)
    private func cachedNativeFastPathAliasForCurrentSite(_ name: String, site: CallSiteKey?) -> String? {
        guard let site else {
            return cachedNativeFastPathAlias(name)
        }
        if let cached = nativeFastPathSiteCache[site] {
            return cached.isEmpty ? nil : cached
        }
        let resolved = cachedNativeFastPathAlias(name)
        nativeFastPathSiteCache[site] = resolved ?? ""
        return resolved
    }

    @inline(__always)
    private func receiverTypeName(_ value: MirValue) -> String? {
        switch value {
        case .structVal(let typeName, _):
            return typeName
        case .enumVal(let typeName, _, _):
            return typeName
        default:
            return nil
        }
    }

    @inline(__always)
    private func deferResolvedUserCall(_ fnIdx: Int, args: [MirValue]) -> MirValue {
        hasDeferredCall = true
        deferredFnIdx = fnIdx
        deferredArgs = args
        return .unit
    }

    @inline(__always)
    private func recordCallSiteResolution(_ name: String, args: [MirValue], fnIdx: Int, site: CallSiteKey?) {
        if isMethodName(name) {
            guard !args.isEmpty, let typeName = receiverTypeName(args[0]) else {
                return
            }
            guard let siteKey = methodCallSiteKey(receiverType: typeName, site: site) else {
                return
            }
            methodCallSiteCache[siteKey] = fnIdx
            return
        }

        guard let site else { return }
        directCallSiteCache[site] = fnIdx
    }

    @inline(__always)
    private func resolveCachedUserCall(_ name: String, args: [MirValue], site: CallSiteKey?) -> MirValue? {
        if isMethodName(name) {
            guard !args.isEmpty, let typeName = receiverTypeName(args[0]) else {
                return nil
            }
            guard let siteKey = methodCallSiteKey(receiverType: typeName, site: site) else {
                return nil
            }
            if let fnIdx = methodCallSiteCache[siteKey] {
                return deferResolvedUserCall(fnIdx, args: args)
            }
            return nil
        }

        guard let site else { return nil }
        if let fnIdx = directCallSiteCache[site] {
            return deferResolvedUserCall(fnIdx, args: args)
        }
        return nil
    }

    @inline(__always)
    private static func enumTag(_ value: MirValue, named expected: String) -> Int? {
        if case .enumVal(let name, let idx, _) = value {
            return nativeBareNameFromQualified(name) == expected ? idx : nil
        }
        // Handle structVal-based enum (Swift MIRLowering uses structCtor with _tag for enum constants)
        if case .structVal(let name, let fields) = value, let tagVal = fields["_tag"], let idx = tagVal.asInt {
            return nativeBareNameFromQualified(name) == expected ? idx : nil
        }
        return nil
    }

    @inline(__always)
    private static func enumCase(_ value: MirValue, named expected: String) -> (Int, MirValue)? {
        if case .enumVal(let name, let idx, let payload) = value {
            guard nativeBareNameFromQualified(name) == expected else { return nil }
            return (idx, payload)
        }
        // Handle structVal-based enum (Swift MIRLowering uses structCtor with _tag for enum constants)
        if case .structVal(let name, let fields) = value, let tagVal = fields["_tag"], let idx = tagVal.asInt {
            guard nativeBareNameFromQualified(name) == expected else { return nil }
            return (idx, value)
        }
        return nil
    }

    @inline(__always)
    private static func physRegDecompose(_ value: MirValue) -> (isA64: Bool, innerEnum: MirValue)? {
        // Decompose a PhysReg value into (isA64, innerEnumValue).
        // Handles both native .enumVal and structVal-based enum representations.
        // The MIRLowering lowers enum variants WITH fields to structCtor with _tag,
        // while unit variants use enumCtor — so PhysReg (which wraps X64/A64) is
        // always structVal-based, but we handle both for robustness.
        // Native enumVal representation
        if case .enumVal(let name, let idx, let payload) = value,
           nativeBareNameFromQualified(name) == "PhysReg" {
            return (idx == 1, payload)
        }
        // StructVal-based enum representation (MIRLowering structCtor with _tag)
        if case .structVal(let name, let fields) = value,
           nativeBareNameFromQualified(name) == "PhysReg",
           let tagVal = fields["_tag"], let tag = tagVal.asInt {
            let inner = fields["0"] ?? .unit
            return (tag == 1, inner)
        }
        return nil
    }

    @inline(__always)
    private static func physRegA64Index(_ value: MirValue) -> Int? {
        guard let (isA64, inner) = physRegDecompose(value), isA64 else { return nil }
        return enumTag(inner, named: "A64")
    }

    @inline(__always)
    private static func a64CondCode(_ value: MirValue) -> UInt32? {
        guard let idx = enumTag(value, named: "CondKind") else { return nil }
        switch idx {
        case 0: return 0   // Eq
        case 1: return 1   // Ne
        case 2: return 11  // Lt
        case 3: return 13  // Le
        case 4: return 12  // Gt
        case 5: return 10  // Ge
        default: return nil
        }
    }

    @inline(__always)
    private static func optionSomePayload(_ value: MirValue) -> MirValue? {
        guard case .enumVal(let name, 0, let payload) = value,
              nativeBareNameFromQualified(name) == "Option" else {
            return nil
        }
        return payload
    }

    @inline(__always)
    private static func scalarIntValue(_ value: MirValue) -> Int? {
        if let direct = value.asInt { return direct }
        if let payload = optionSomePayload(value) { return payload.asInt }
        return nil
    }

    @inline(__always)
    private static func scalarBoolValue(_ value: MirValue) -> Bool? {
        if let direct = value.asBool { return direct }
        if let payload = optionSomePayload(value) { return payload.asBool }
        return nil
    }

    @inline(__always)
    private static func defaultAsmArchTag() -> Int {
        #if arch(arm64)
        return 1
        #else
        return 0
        #endif
    }

    @inline(__always)
    private static func appendAlignmentPadding(_ bb: MirByteBuffer, alignment: Int, archValue: MirValue?) {
        let remainder = bb.data.count % alignment
        guard remainder != 0 else { return }

        let padding = alignment - remainder
        let archTag = archValue.flatMap { enumTag($0, named: "Arch") } ?? defaultAsmArchTag()
        switch archTag {
        case 0:
            bb.data.append(contentsOf: repeatElement(UInt8(0x90), count: padding))
        default:
            let nopBytes: [UInt8] = [0x1F, 0x20, 0x03, 0xD5]
            for i in 0..<padding {
                bb.data.append(nopBytes[i % nopBytes.count])
            }
        }
    }

    @inline(__always)
    private func appendWord(_ bb: MirByteBuffer, _ word: UInt32) {
        bb.data.append(UInt8(truncatingIfNeeded: word))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 8))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 16))
        bb.data.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    @inline(__always)
    private func withCodegenTextBuffer(_ ctxArg: MirValue, _ body: (MirByteBuffer) -> Void) -> MirValue? {
        guard case .structVal(let ctxName, var ctxFields) = ctxArg,
              case .structVal(let textName, var textFields) = ctxFields["text"] else {
            return nil
        }
        let bb = getOrUpgradeByteBuffer(&textFields)
        body(bb)
        ctxFields["text"] = .structVal(textName, textFields)
        recordMutatedFirstArg(.structVal(ctxName, ctxFields))
        return .unit
    }

    @inline(__always)
    private func emitA64MoveImmediate(_ bb: MirByteBuffer, dstIndex: Int, imm: Int) {
        let u = UInt64(bitPattern: Int64(imm))
        let rd = UInt32(min(dstIndex, 31))
        let lane0 = UInt32(u & 0xFFFF)
        let lane1 = UInt32((u >> 16) & 0xFFFF)
        let lane2 = UInt32((u >> 32) & 0xFFFF)
        let lane3 = UInt32((u >> 48) & 0xFFFF)

        appendWord(bb, 0xD280_0000 | (lane0 << 5) | rd)
        if lane1 != 0 {
            appendWord(bb, 0xF280_0000 | (1 << 21) | (lane1 << 5) | rd)
        }
        if lane2 != 0 {
            appendWord(bb, 0xF280_0000 | (2 << 21) | (lane2 << 5) | rd)
        }
        if lane3 != 0 {
            appendWord(bb, 0xF280_0000 | (3 << 21) | (lane3 << 5) | rd)
        }
    }

    private func byteSlice(from value: MirValue, limit: Int? = nil) -> [UInt8] {
        let bytes: [UInt8]
        switch value {
        case .array(let elems):
            bytes = elems.compactMap { element in
                element.asInt.map { UInt8(truncatingIfNeeded: $0) }
            }
        case .byteBuffer(let buffer):
            bytes = Array(buffer.data)
        case .string(let string):
            bytes = Array(string.utf8)
        default:
            bytes = []
        }
        guard let limit else { return bytes }
        return Array(bytes.prefix(max(0, limit)))
    }

    private func cString(from value: MirValue) -> String? {
        switch value {
        case .int(let raw) where raw == 0:
            return nil
        case .string(let string):
            if let nul = string.firstIndex(of: "\0") {
                return String(string[..<nul])
            }
            return string
        case .array(let elems):
            let bytes = elems.prefix { ($0.asInt ?? 0) != 0 }.compactMap { element in
                element.asInt.map { UInt8(truncatingIfNeeded: $0) }
            }
            return String(decoding: bytes, as: UTF8.self)
        case .byteBuffer(let buffer):
            let bytes = buffer.data.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        default:
            return nil
        }
    }

    @inline(__always)
    private func stringLength(_ string: String) -> Int {
        (string as NSString).length
    }

    @inline(__always)
    private func stringCharacter(_ string: String, at index: Int) -> Character? {
        let nsString = string as NSString
        guard index >= 0 && index < nsString.length else { return nil }
        let codeUnit = nsString.character(at: index)
        if codeUnit < 0xD800 || codeUnit > 0xDFFF,
           let scalar = UnicodeScalar(Int(codeUnit)) {
            return Character(scalar)
        }
        return nsString.substring(with: NSRange(location: index, length: 1)).first
    }

    @inline(__always)
    private func stringSlice(_ string: String, start: Int, end: Int) -> String {
        let nsString = string as NSString
        let lowerBound = max(0, min(start, nsString.length))
        let upperBound = max(lowerBound, min(end, nsString.length))
        return nsString.substring(with: NSRange(location: lowerBound, length: upperBound - lowerBound))
    }

    @inline(__always)
    private func stringFind(_ string: String, needle: String, backwards: Bool = false) -> Int? {
        let nsString = string as NSString
        let options: NSString.CompareOptions = backwards ? .backwards : []
        let range = nsString.range(of: needle, options: options)
        guard range.location != NSNotFound else { return nil }
        return range.location
    }

    @inline(__always)
    private func optionCharValue(_ char: Character?) -> MirValue {
        if let char {
            return .enumVal("Option", 0, .char(char))
        }
        return .enumVal("Option", 1, .unit)
    }

    private func dispatchCall(_ name: String, args: [MirValue], staticSite: CallSiteKey? = nil) -> MirValue {
        // If name has a native fast-path, skip the dispatch cache and go straight to the switch.
        // Cache alias resolution because interpreted compilation revisits the same call names
        // millions of times and repeated prefix/set lookups become dominant.
        let siteKey = staticSite
        let isMethod = isMethodName(name)
        let nativeFastPathName = cachedNativeFastPathAliasForCurrentSite(name, site: siteKey)
        let fastPathName = nativeFastPathName ?? name
        if nativeFastPathName == nil {
            if let resolved = resolveCachedUserCall(name, args: args, site: siteKey) {
                return resolved
            }
            // Fast path: check dispatch cache (skips 200+ case comparisons)
            if !isMethod, let cachedIdx = dispatchCache[name] {
                recordCallSiteResolution(name, args: args, fnIdx: cachedIdx, site: siteKey)
                return deferResolvedUserCall(cachedIdx, args: args)
            }
            // For method calls, check type-qualified cache
            if isMethod, !args.isEmpty {
                let typeName = receiverTypeName(args[0])
                if let t = typeName,
                   let cachedIdx = methodDispatchCache[name]?[t] {
                        recordCallSiteResolution(name, args: args, fnIdx: cachedIdx, site: siteKey)
                        return deferResolvedUserCall(cachedIdx, args: args)
                }
            }
        }

        // ── Remaining fast-path switch (non-cache-intercepted builtins) ──
        switch fastPathName {
        case "peek":
            // peek(p: &TgcParser) -> TokenKind = p.tokens[p.pos].kind or Eof
            if !args.isEmpty,
               case .structVal(_, let pf) = args[0],
               case .int(let pos) = pf["pos"],
               case .array(let tokens) = pf["tokens"] {
                if pos >= 0 && pos < tokens.count,
                   case .structVal(_, let tf) = tokens[pos] {
                    return tf["kind"] ?? Self.eofTokenKindValue
                }
                return Self.eofTokenKindValue
            }
        case "at":
            // at(p: &TgcParser, kind: TokenKind) -> Bool = peek(p) == kind
            if args.count >= 2,
               case .structVal(_, let pf) = args[0],
               case .int(let pos) = pf["pos"],
               case .array(let tokens) = pf["tokens"] {
                let currentKind: MirValue
                if pos >= 0 && pos < tokens.count,
                   case .structVal(_, let tf) = tokens[pos] {
                    currentKind = tf["kind"] ?? Self.eofTokenKindValue
                } else {
                    currentKind = Self.eofTokenKindValue
                }
                return .bool(currentKind == args[1])
            }
        case "advance":
            // advance(p: &mut TgcParser) -> Token (reads token, increments pos)
            if !args.isEmpty,
               case .structVal(let sn, var pf) = args[0],
               case .int(let pos) = pf["pos"],
               case .array(let tokens) = pf["tokens"] {
                let tok: MirValue
                if pos >= 0 && pos < tokens.count {
                    tok = tokens[pos]
                    pf["pos"] = .int(pos + 1)
                } else {
                    tok = Self.eofTokenValue
                }
                // Write back mutated parser to receiver
                let mutatedParser = MirValue.structVal(sn, pf)
                // The receiver is args[0], need to write it back via mut borrow
                recordMutatedFirstArg(mutatedParser)
                return tok
            }
        case "peek_span":
            // peek_span(p: &TgcParser) -> Span = p.tokens[p.pos].span or span_new(0,0)
            if !args.isEmpty,
               case .structVal(_, let pf) = args[0],
               case .int(let pos) = pf["pos"],
               case .array(let tokens) = pf["tokens"] {
                if pos >= 0 && pos < tokens.count,
                   case .structVal(_, let tf) = tokens[pos] {
                    return tf["span"] ?? Self.emptySpanValue
                }
                return Self.emptySpanValue
            }
        case "skip_newlines":
            // skip_newlines(p: &mut TgcParser) — advance past all Newline tokens
            if !args.isEmpty,
               case .structVal(let sn, var pf) = args[0],
               case .int(var pos) = pf["pos"],
               case .array(let tokens) = pf["tokens"] {
                // Newline variant index — find it by checking Token at pos
                while pos >= 0 && pos < tokens.count {
                    if case .structVal(_, let tf) = tokens[pos],
                       let kind = tf["kind"],
                       case .enumVal("TokenKind", let idx, _) = kind,
                       idx == 131 {  // Newline
                        pos += 1
                    } else {
                        break
                    }
                }
                pf["pos"] = .int(pos)
                recordMutatedFirstArg(MirValue.structVal(sn, pf))
                return .unit
            }
        case "lexer::char_at", "tg_compiler::lexer::char_at":
            if args.count >= 2,
               case .string(let source) = args[0],
               let idx = args[1].asInt {
                return optionCharValue(stringCharacter(source, at: idx))
            }
            return .enumVal("Option", 1, .unit)
        case "lexer::is_whitespace", "tg_compiler::lexer::is_whitespace":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool(code == 32 || code == 9 || code == 13)
            }
            return .bool(false)
        case "lexer::is_newline", "tg_compiler::lexer::is_newline":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool(code == 10)
            }
            return .bool(false)
        case "lexer::is_digit", "tg_compiler::lexer::is_digit":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool(code >= 48 && code <= 57)
            }
            return .bool(false)
        case "lexer::is_alpha", "tg_compiler::lexer::is_alpha":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool((code >= 97 && code <= 122) || (code >= 65 && code <= 90))
            }
            return .bool(false)
        case "lexer::is_ident_start", "tg_compiler::lexer::is_ident_start":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool((code >= 97 && code <= 122) || (code >= 65 && code <= 90) || code == 95)
            }
            return .bool(false)
        case "lexer::is_ident_char", "tg_compiler::lexer::is_ident_char":
            if !args.isEmpty, let code = args[0].asInt {
                return .bool((code >= 97 && code <= 122) || (code >= 65 && code <= 90) || (code >= 48 && code <= 57) || code == 95)
            }
            return .bool(false)
        case "lexer::lex_peek", "tg_compiler::lexer::lex_peek":
            if !args.isEmpty,
               case .structVal(_, let fields) = args[0],
               case .string(let source) = fields["source"],
               case .int(let pos) = fields["pos"] {
                return optionCharValue(stringCharacter(source, at: pos))
            }
            return .enumVal("Option", 1, .unit)
        case "lexer::lex_peek_next", "tg_compiler::lexer::lex_peek_next":
            if !args.isEmpty,
               case .structVal(_, let fields) = args[0],
               case .string(let source) = fields["source"],
               case .int(let pos) = fields["pos"] {
                return optionCharValue(stringCharacter(source, at: pos + 1))
            }
            return .enumVal("Option", 1, .unit)
        case "lexer::lex_advance", "tg_compiler::lexer::lex_advance":
            if !args.isEmpty,
               case .structVal(let name, var fields) = args[0],
               case .string(let source) = fields["source"],
               case .int(let pos) = fields["pos"] {
                let char = stringCharacter(source, at: pos)
                if char != nil {
                    fields["pos"] = .int(pos + 1)
                    recordMutatedFirstArg(.structVal(name, fields))
                }
                return optionCharValue(char)
            }
            return .enumVal("Option", 1, .unit)
        case "lexer::at_end", "tg_compiler::lexer::at_end":
            if !args.isEmpty,
               case .structVal(_, let fields) = args[0],
               case .string(let source) = fields["source"],
               case .int(let pos) = fields["pos"] {
                return .bool(pos >= stringLength(source))
            }
            return .bool(true)
        case "is_doc_comment":
            // is_doc_comment(kind: TokenKind) -> Bool
            if let kind = args.first, case .enumVal("TokenKind", let idx, _) = kind {
                return .bool(idx == 5)  // DocComment variant index
            }
            return .bool(false)
        case "make_expr":
            // make_expr(kind: ExprKind, span: Span) -> Expr
            if args.count >= 2 {
                return .structVal("Expr", ["kind": args[0], "span": args[1]])
            }
        case "span_merge":
            // span_merge(a: Span, b: Span) -> Span = Span(file: a.file, start: a.start, end_pos: b.end_pos)
            if args.count >= 2,
               case .structVal(_, let af) = args[0],
               case .structVal(_, let bf) = args[1] {
                return .structVal("Span", [
                    "file": af["file"] ?? .string(""),
                    "start": af["start"] ?? .int(0),
                    "end_pos": bf["end_pos"] ?? .int(0)
                ])
            }
        case "array_push", "__intrinsic_array_push":
            // Emit: ldr x0, [x0] + bl _tg_array_push
            fputs("[NATIVE] array_push handler called!\n", stderr)
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let bb = getOrUpgradeByteBuffer(&bf)
                appendWord(bb, 0xF9400000) // ldr x0, [x0]
                appendWord(bb, 0x94000000) // bl _tg_array_push
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        default:
            break  // Fall through to codegen shortcuts
        }

        // ── Native fast-path for codegen hot functions ─────────
        // These eliminate deep call chains (emit32_le calls emit8 4x each)
        // Use MirByteBuffer (reference type) to avoid O(n) COW copies on every emit.
        switch fastPathName {
        case "array_push", "__intrinsic_array_push":
            // Emit: ldr x0, [x0] + bl _tg_array_push
            fputs("[NATIVE] array_push handler called!\n", stderr)
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let bb = getOrUpgradeByteBuffer(&bf)
                // ldr x0, [x0]  = 0xF9400000
                appendWord(bb, 0xF9400000)
                // bl _tg_array_push — emit BL with relocation fixup
                appendWord(bb, 0x94000000)
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit8", "tg_compiler::asm::emit8":
            // emit8(b: &mut CodeBuffer, v: u8) → b.bytes.push(v)
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let v = args[1].asInt ?? 0
                let bb = getOrUpgradeByteBuffer(&bf)
                bb.data.append(UInt8(truncatingIfNeeded: v & 0xFF))
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit16_le", "tg_compiler::asm::emit16_le":
            // emit16_le(b: &mut CodeBuffer, v: u16) → 2 bytes LE
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let v = args[1].asInt ?? 0
                let bb = getOrUpgradeByteBuffer(&bf)
                bb.data.append(UInt8(truncatingIfNeeded: v & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 8) & 0xFF))
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit32_le", "tg_compiler::asm::emit32_le":
            // emit32_le(b: &mut CodeBuffer, v: u32) → 4 bytes LE
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let v = args[1].asInt ?? 0
                let bb = getOrUpgradeByteBuffer(&bf)
                bb.data.append(UInt8(truncatingIfNeeded: v & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 8) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 16) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 24) & 0xFF))
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit64_le", "tg_compiler::asm::emit64_le":
            // emit64_le(b: &mut CodeBuffer, v: u64) → 8 bytes LE
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let v = args[1].asInt ?? 0
                let bb = getOrUpgradeByteBuffer(&bf)
                bb.data.append(UInt8(truncatingIfNeeded: v & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 8) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 16) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 24) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 32) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 40) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 48) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (v >> 56) & 0xFF))
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit_i32":
            // emit_i32(b: &mut CodeBuffer, v: i32) → emit32_le(b, v as u32)
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let v = args[1].asInt ?? 0
                let u = v >= 0 ? v : v + (1 << 32)  // i32 → u32
                let bb = getOrUpgradeByteBuffer(&bf)
                bb.data.append(UInt8(truncatingIfNeeded: u & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (u >> 8) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (u >> 16) & 0xFF))
                bb.data.append(UInt8(truncatingIfNeeded: (u >> 24) & 0xFF))
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "emit_zeros", "tg_compiler::asm::emit_zeros":
            // emit_zeros(b: &mut CodeBuffer, n: Int) → n zero bytes
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0] {
                let n = args[1].asInt ?? 0
                let bb = getOrUpgradeByteBuffer(&bf)
                if n > 0 {
                    bb.data.append(contentsOf: repeatElement(UInt8(0), count: n))
                }
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "buf_pos", "tg_compiler::asm::buf_pos":
            // buf_pos(b: &CodeBuffer) -> Int = b.bytes.len()
            if let buf = args.first,
               case .structVal(_, let bf) = buf {
                if case .byteBuffer(let bb) = bf["bytes"] {
                    return .int(bb.data.count)
                }
                if case .array(let bytes) = bf["bytes"] {
                    return .int(bytes.count)
                }
            }
        case "patch32_le", "tg_compiler::asm::patch32_le", "patch32_le_native":
            // patch32_le(b: &mut CodeBuffer, offset: Int, v: u32)
            if args.count >= 3,
               case .structVal(let sn, let bf) = args[0],
               let offset = args[1].asInt {
                let v = args[2].asInt ?? 0
                if case .array(let bytes) = bf["bytes"], offset >= 0 && offset + 3 < bytes.count {
                    bytes[offset] = .int(v & 0xFF)
                    bytes[offset + 1] = .int((v >> 8) & 0xFF)
                    bytes[offset + 2] = .int((v >> 16) & 0xFF)
                    bytes[offset + 3] = .int((v >> 24) & 0xFF)
                    return .unit
                }
                if case .byteBuffer(let bb) = bf["bytes"], offset >= 0 && offset + 3 < bb.data.count {
                    bb.data[offset] = UInt8(truncatingIfNeeded: v & 0xFF)
                    bb.data[offset + 1] = UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)
                    bb.data[offset + 2] = UInt8(truncatingIfNeeded: (v >> 16) & 0xFF)
                    bb.data[offset + 3] = UInt8(truncatingIfNeeded: (v >> 24) & 0xFF)
                    return .unit
                }
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "read32_at":
            if args.count >= 2,
               let offset = args[1].asInt {
                switch args[0] {
                case .array(let data):
                    if offset >= 0 && offset + 3 < data.count {
                        let b0 = data[offset].asInt ?? 0
                        let b1 = data[offset + 1].asInt ?? 0
                        let b2 = data[offset + 2].asInt ?? 0
                        let b3 = data[offset + 3].asInt ?? 0
                        return .int((b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16) | ((b3 & 0xFF) << 24))
                    }
                case .byteBuffer(let bb):
                    if offset >= 0 && offset + 3 < bb.data.count {
                        let b0 = Int(bb.data[offset])
                        let b1 = Int(bb.data[offset + 1])
                        let b2 = Int(bb.data[offset + 2])
                        let b3 = Int(bb.data[offset + 3])
                        return .int((b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16) | ((b3 & 0xFF) << 24))
                    }
                default:
                    break
                }
            }
            return .int(0)
        case "write32_at":
            if args.count >= 3,
               let offset = args[1].asInt {
                let value = args[2].asInt ?? 0
                switch args[0] {
                case .array(let data):
                    if offset >= 0 && offset + 3 < data.count {
                        data[offset] = .int(value & 0xFF)
                        data[offset + 1] = .int((value >> 8) & 0xFF)
                        data[offset + 2] = .int((value >> 16) & 0xFF)
                        data[offset + 3] = .int((value >> 24) & 0xFF)
                    }
                    return .unit
                case .byteBuffer(let bb):
                    if offset >= 0 && offset + 3 < bb.data.count {
                        bb.data[offset] = UInt8(truncatingIfNeeded: value & 0xFF)
                        bb.data[offset + 1] = UInt8(truncatingIfNeeded: (value >> 8) & 0xFF)
                        bb.data[offset + 2] = UInt8(truncatingIfNeeded: (value >> 16) & 0xFF)
                        bb.data[offset + 3] = UInt8(truncatingIfNeeded: (value >> 24) & 0xFF)
                    }
                    return .unit
                default:
                    break
                }
            }
            return .unit
        case "write64_at":
            if args.count >= 3,
               let offset = args[1].asInt {
                let value = args[2].asInt ?? 0
                switch args[0] {
                case .array(let data):
                    if offset >= 0 && offset + 7 < data.count {
                        var shift = 0
                        while shift < 8 {
                            data[offset + shift] = .int((value >> (shift * 8)) & 0xFF)
                            shift += 1
                        }
                    }
                    return .unit
                case .byteBuffer(let bb):
                    if offset >= 0 && offset + 7 < bb.data.count {
                        var shift = 0
                        while shift < 8 {
                            bb.data[offset + shift] = UInt8(truncatingIfNeeded: (value >> (shift * 8)) & 0xFF)
                            shift += 1
                        }
                    }
                    return .unit
                default:
                    break
                }
            }
            return .unit
        case "read32_le", "tg_compiler::asm::read32_le", "read32_le_native":
            if args.count >= 2,
               case .structVal(_, let bf) = args[0],
               let offset = args[1].asInt {
                if case .byteBuffer(let bb) = bf["bytes"], offset >= 0 && offset + 3 < bb.data.count {
                    let b0 = Int(bb.data[offset])
                    let b1 = Int(bb.data[offset + 1])
                    let b2 = Int(bb.data[offset + 2])
                    let b3 = Int(bb.data[offset + 3])
                    return .int((b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16) | ((b3 & 0xFF) << 24))
                }
                if case .array(let bytes) = bf["bytes"], offset >= 0 && offset + 3 < bytes.count {
                    let b0 = bytes[offset].asInt ?? 0
                    let b1 = bytes[offset + 1].asInt ?? 0
                    let b2 = bytes[offset + 2].asInt ?? 0
                    let b3 = bytes[offset + 3].asInt ?? 0
                    return .int((b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16) | ((b3 & 0xFF) << 24))
                }
            }
            return .int(0)
        case "align_to", "tg_compiler::asm::align_to":
            // align_to(b: &mut CodeBuffer, alignment: Int, arch?: Arch) → executable-safe padding
            if args.count >= 2,
               case .structVal(let sn, var bf) = args[0],
               let alignment = args[1].asInt, alignment > 0 {
                let bb = getOrUpgradeByteBuffer(&bf)
                let archValue = args.count >= 3 ? args[2] : nil
                Self.appendAlignmentPadding(bb, alignment: alignment, archValue: archValue)
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "rex":
            // rex(w,r,x,b: Bool) -> u8 = 0x40 | flags
            if args.count >= 4 {
                var v = 0x40
                if args[0].asBool == true { v |= 0x08 }
                if args[1].asBool == true { v |= 0x04 }
                if args[2].asBool == true { v |= 0x02 }
                if args[3].asBool == true { v |= 0x01 }
                return .int(v)
            }
        case "modrm":
            // modrm(mod_: u8, reg: u8, rm: u8) -> u8
            if args.count >= 3,
               let mod_ = args[0].asInt, let reg = args[1].asInt, let rm = args[2].asInt {
                return .int(((mod_ & 3) << 6) | ((reg & 7) << 3) | (rm & 7))
            }
        case "sib":
            // sib(scale: u8, idx: u8, base: u8) -> u8
            if args.count >= 3,
               let scale = args[0].asInt, let idx = args[1].asInt, let base = args[2].asInt {
                return .int(((scale & 3) << 6) | ((idx & 7) << 3) | (base & 7))
            }
        case "span_new":
            // span_new(start: Int, end_pos: Int, path: String = "") -> Span
            if args.count >= 3, case .string(let file) = args[2] {
                return .structVal("Span", ["file": .string(file), "start": args[0], "end_pos": args[1]])
            } else if args.count >= 2 {
                return .structVal("Span", ["file": .string(""), "start": args[0], "end_pos": args[1]])
            }
        case "is_intrinsic":
            // Native fast-path matching codegen.tg's current exclusions and lookup behavior.
            if case .string(let s) = args.first {
                return .bool(Self.nativeIsIntrinsic(s))
            }
            return .bool(false)
        case "bare_intrinsic_name":
            // Native fast-path: avoids interpreting extensive string slicing/matching
            if case .string(let name) = args.first {
                return .string(Self.nativeBareIntrinsicName(name))
            }
            return args.first ?? .string("")
        case "canonical_fn_ref":
            // Native fast-path: avoids interpreting string slicing/matching
            if case .string(let name) = args.first {
                return .string(Self.nativeCanonicalFnRef(name))
            }
            return args.first ?? .string("")
        case "bare_name_from_qualified":
            // Native fast-path: avoids interpreting string slicing/matching
            if case .string(let name) = args.first {
                return .string(Self.nativeBareNameFromQualified(name))
            }
            return args.first ?? .string("")
        // ── ARM64/x86 codegen hot-path fast-paths ──────────────
        case "a64_code":
            // A64 enum variant idx → register hardware code (0-31)
            if let idx = Self.enumTag(args.first ?? .unit, named: "A64") {
                return .int(min(idx, 31))
            }
            return .int(0)
        case "a64v_code":
            // A64V enum variant idx → SIMD register code (0-31)
            if let idx = Self.enumTag(args.first ?? .unit, named: "A64V") {
                return .int(idx)
            }
            return .int(0)
        case "x64_code":
            // X64 enum variant idx → register code (0-15)
            if let idx = Self.enumTag(args.first ?? .unit, named: "X64") {
                return .int(idx)
            }
            return .int(0)
        case "x64_lo3":
            if let idx = Self.enumTag(args.first ?? .unit, named: "X64") {
                return .int(idx & 0x07)
            }
            return .int(0)
        case "x64_hi":
            if let idx = Self.enumTag(args.first ?? .unit, named: "X64") {
                return .bool(idx >= 8)
            }
            return .bool(false)
        case "phys_reg_id":
            if let (isA64, inner) = Self.physRegDecompose(args.first ?? .unit) {
                if isA64 {
                    if let idx = Self.enumTag(inner, named: "A64") { return .int(min(idx, 31)) }
                } else {
                    if let idx = Self.enumTag(inner, named: "X64") { return .int(idx) }
                }
            }
            return .int(0)
        // ── ARM64 instruction encoding (inline emit32_le via CodeBuffer structVal) ──
        case "a64_movz":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let imm = args[2].asInt, let shift = args[3].asInt {
                let hw = UInt32(shift / 16), rd = UInt32(min(dIdx, 31))
                if let r = emitWordToCodeBuf(args[0], 0xD280_0000 | (hw << 21) | (UInt32(imm & 0xFFFF) << 5) | rd) { return r }
            }
        case "a64_movk":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let imm = args[2].asInt, let shift = args[3].asInt {
                let hw = UInt32(shift / 16), rd = UInt32(min(dIdx, 31))
                if let r = emitWordToCodeBuf(args[0], 0xF280_0000 | (hw << 21) | (UInt32(imm & 0xFFFF) << 5) | rd) { return r }
            }
        case "a64_mov_ri":
            // movz + up to 3 movk — emits multiple words, handled manually
            if case .structVal(let sn, var bf) = args[0],
               let dIdx = Self.enumTag(args[1], named: "A64"),
               let imm = args[2].asInt {
                let bb = getOrUpgradeByteBuffer(&bf)
                let u = UInt64(bitPattern: Int64(imm))
                let rd = UInt32(min(dIdx, 31))
                let lane0 = UInt32(u & 0xFFFF)
                let lane1 = UInt32((u >> 16) & 0xFFFF)
                let lane2 = UInt32((u >> 32) & 0xFFFF)
                let lane3 = UInt32((u >> 48) & 0xFFFF)
                var w: UInt32 = 0xD280_0000 | (lane0 << 5) | rd
                bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                if lane1 != 0 {
                    w = 0xF280_0000 | (1 << 21) | (lane1 << 5) | rd
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                }
                if lane2 != 0 {
                    w = 0xF280_0000 | (2 << 21) | (lane2 << 5) | rd
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                }
                if lane3 != 0 {
                    w = 0xF280_0000 | (3 << 21) | (lane3 << 5) | rd
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                }
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "a64_add_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x8B00_0000 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_ldr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let bIdx = Self.enumTag(args[2], named: "A64"),
               let offset = args[3].asInt {
                let imm12 = UInt32((offset / 8) & 0xFFF)
                if let r = emitWordToCodeBuf(args[0], 0xF940_0000 | (imm12 << 10) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_str":
            if let sIdx = Self.enumTag(args[1], named: "A64"),
               let bIdx = Self.enumTag(args[2], named: "A64"),
               let offset = args[3].asInt {
                let imm12 = UInt32((offset / 8) & 0xFFF)
                if let r = emitWordToCodeBuf(args[0], 0xF900_0000 | (imm12 << 10) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(sIdx,31))) { return r }
            }
        case "a64_ldur":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let bIdx = Self.enumTag(args[2], named: "A64"),
               let offset = args[3].asInt {
                let imm9 = UInt32(offset & 0x1FF)
                if let r = emitWordToCodeBuf(args[0], 0xF840_0000 | (imm9 << 12) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_stur":
            if let sIdx = Self.enumTag(args[1], named: "A64"),
               let bIdx = Self.enumTag(args[2], named: "A64"),
               let offset = args[3].asInt {
                let imm9 = UInt32(offset & 0x1FF)
                if let r = emitWordToCodeBuf(args[0], 0xF800_0000 | (imm9 << 12) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(sIdx,31))) { return r }
            }
        case "a64_sub_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xCB00_0000 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_cmp_rr":
            if let nIdx = Self.enumTag(args[1], named: "A64"),
               let mIdx = Self.enumTag(args[2], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xEB00_001F | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5)) { return r }
            }
        case "a64_cmp_ri":
            if case .structVal(let sn, var bf) = args[0],
               let nIdx = Self.enumTag(args[1], named: "A64"),
               let imm = args[2].asInt {
                let bb = getOrUpgradeByteBuffer(&bf)
                let uimm = UInt32(imm & 0xFFFFFFFF)
                let n = UInt32(min(nIdx, 31))
                if uimm <= 0xFFF {
                    appendWord(bb, 0xF100_001F | (uimm << 10) | (n << 5))
                } else if (uimm & 0xFFF) == 0 && (uimm >> 12) <= 0xFFF {
                    appendWord(bb, 0xF140_001F | ((uimm >> 12) << 10) | (n << 5))
                } else {
                    let scratch = (nIdx == 16) ? 17 : 16
                    emitA64MoveImmediate(bb, dstIndex: scratch, imm: Int(uimm))
                    appendWord(bb, 0xEB00_001F | (UInt32(scratch) << 16) | (n << 5))
                }
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "a64_cset":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let cond = args[2].asInt {
                let inv = UInt32(cond ^ 1)
                if let r = emitWordToCodeBuf(args[0], 0x9A9F_07E0 | (inv << 12) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_mov_rr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64") {
                let rd = UInt32(min(dIdx, 31)), rn = UInt32(min(nIdx, 31))
                let w: UInt32 = (nIdx == 31 || dIdx == 31) ? (0x9100_0000 | (rn << 5) | rd) : (0xAA00_03E0 | (rn << 16) | rd)
                if let r = emitWordToCodeBuf(args[0], w) { return r }
            }
        case "a64_and_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x8A00_0000 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_orr_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xAA00_0000 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_eor_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xCA00_0000 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_mul_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x9B00_7C00 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_sdiv_rrr":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let mIdx = Self.enumTag(args[3], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x9AC0_0C00 | (UInt32(min(mIdx,31)) << 16) | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_sub_rri":
            if case .structVal(let sn, var bf) = args[0],
               let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64"),
               let imm = args[3].asInt {
                let bb = getOrUpgradeByteBuffer(&bf)
                let uimm = UInt32(imm & 0xFFFFFFFF)
                let n = UInt32(min(nIdx, 31))
                let d = UInt32(min(dIdx, 31))
                if uimm <= 0xFFF {
                    appendWord(bb, 0xD100_0000 | (uimm << 10) | (n << 5) | d)
                } else if (uimm & 0xFFF) == 0 && (uimm >> 12) <= 0xFFF {
                    appendWord(bb, 0xD140_0000 | ((uimm >> 12) << 10) | (n << 5) | d)
                } else {
                    let scratch = (nIdx == 16 || dIdx == 16) ? 17 : 16
                    emitA64MoveImmediate(bb, dstIndex: scratch, imm: Int(uimm))
                    appendWord(bb, 0xCB00_0000 | (UInt32(scratch) << 16) | (n << 5) | d)
                }
                recordMutatedFirstArg(.structVal(sn, bf))
                return .unit
            }
        case "a64_blr":
            if let nIdx = Self.enumTag(args[1], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xD63F_0000 | (UInt32(min(nIdx,31)) << 5)) { return r }
            }
        case "a64_ret":
            if let r = emitWordToCodeBuf(args[0], 0xD65F_03C0) { return r }
        case "a64_stp_pre":
            if let r1Idx = Self.enumTag(args[1], named: "A64"),
               let r2Idx = Self.enumTag(args[2], named: "A64"),
               let bIdx = Self.enumTag(args[3], named: "A64"),
               let offset = args[4].asInt {
                let imm7 = UInt32((offset / 8) & 0x7F)
                if let r = emitWordToCodeBuf(args[0], 0xA980_0000 | (imm7 << 15) | (UInt32(min(r2Idx,31)) << 10) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(r1Idx,31))) { return r }
            }
        case "a64_ldp_post":
            if let r1Idx = Self.enumTag(args[1], named: "A64"),
               let r2Idx = Self.enumTag(args[2], named: "A64"),
               let bIdx = Self.enumTag(args[3], named: "A64"),
               let offset = args[4].asInt {
                let imm7 = UInt32((offset / 8) & 0x7F)
                if let r = emitWordToCodeBuf(args[0], 0xA8C0_0000 | (imm7 << 15) | (UInt32(min(r2Idx,31)) << 10) | (UInt32(min(bIdx,31)) << 5) | UInt32(min(r1Idx,31))) { return r }
            }
        case "a64_mov_w":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x2A00_03E0 | (UInt32(min(nIdx,31)) << 16) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_sxtw":
            if let dIdx = Self.enumTag(args[1], named: "A64"),
               let nIdx = Self.enumTag(args[2], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0x9340_7C00 | (UInt32(min(nIdx,31)) << 5) | UInt32(min(dIdx,31))) { return r }
            }
        case "a64_sub_sp_sp_r":
            if let mIdx = Self.enumTag(args[1], named: "A64") {
                if let r = emitWordToCodeBuf(args[0], 0xCB20_63FF | (UInt32(min(mIdx,31)) << 16)) { return r }
            }
        case "ret_reg":
            // ret_reg(arch) → PhysReg for return value
            if let idx = Self.enumTag(args.first ?? .unit, named: "Arch") {
                if idx == 0 { // X86_64
                    return .enumVal("PhysReg", 0, .enumVal("X64", 0, .unit)) // X64Reg(RAX)
                } else { // AArch64
                    return .enumVal("PhysReg", 1, .enumVal("A64", 0, .unit)) // A64Reg(X0)
                }
            }
            return .enumVal("PhysReg", 1, .enumVal("A64", 0, .unit))
        case "fp_reg":
            // fp_reg(arch) → PhysReg for frame pointer
            if let idx = Self.enumTag(args.first ?? .unit, named: "Arch") {
                if idx == 0 { // X86_64 → RBP
                    return .enumVal("PhysReg", 0, .enumVal("X64", 5, .unit)) // X64Reg(RBP)
                } else { // AArch64 → FP (X29, variant 29)
                    return .enumVal("PhysReg", 1, .enumVal("A64", 29, .unit)) // A64Reg(FP)
                }
            }
            return .enumVal("PhysReg", 1, .enumVal("A64", 29, .unit))
        case "place_local":
            // place_local(id) → Place { local: LocalId { id }, projections: [] }
            if case .structVal("LocalId", let fields) = args.first {
                return .structVal("Place", [
                    "local": .structVal("LocalId", ["id": fields["id"] ?? .int(0)]),
                    "projections": .array([])
                ])
            }
            if let id = args.first {
                return .structVal("Place", ["local": id, "projections": .array([])])
            }
            return .structVal("Place", ["local": .structVal("LocalId", ["id": .int(0)]), "projections": .array([])])
        case "get_block":
            // get_block(&MirFunction, BlockId) → Option[MirBlock]: O(n) scan in native Swift
            if case .structVal(_, let funcFields) = args.first,
               case .array(let blocks)? = funcFields["blocks"],
               case .structVal("BlockId", let idFields) = args.dropFirst().first,
               let targetId = idFields["id"]?.asInt {
                for block in blocks {
                    if case .structVal(_, let bFields) = block,
                       case .structVal("BlockId", let bIdFields) = bFields["id"],
                       bIdFields["id"]?.asInt == targetId {
                        return .enumVal("Option", 0, block)
                    }
                }
                return .enumVal("Option", 1, .unit)
            }
            return .enumVal("Option", 1, .unit)
        case "terminator_successors":
            // Extract successor block IDs from a terminator
            if case .structVal(_, let termFields) = args.first,
               case .enumVal(_, let kindIdx, let kindPayload) = termFields["kind"] {
                var result: [MirValue] = []
                switch kindIdx {
                case 0: // MirGoto(BlockId)
                    result.append(kindPayload)
                case 1, 2, 8: // MirReturn, MirUnreachable, MirAbort — no successors
                    break
                case 3: // MirSwitchInt { op, targets, default_target }
                    if case .structVal(_, let switchFields) = kindPayload {
                        if case .array(let targets) = switchFields["targets"] {
                            for t in targets {
                                if case .structVal(_, let tf) = t, let target = tf["target"] {
                                    result.append(target)
                                }
                            }
                        }
                        if let defaultTarget = switchFields["default_target"] {
                            result.append(defaultTarget)
                        }
                    }
                case 4: // MirCall { dest, func, args, success, unwind }
                    if case .structVal(_, let callFields) = kindPayload {
                        if let succ = callFields["success"] { result.append(succ) }
                        if case .enumVal(_, 0, let uw) = callFields["unwind"] { result.append(uw) }
                    }
                case 5: // MirDrop { place, target, unwind }
                    if case .structVal(_, let dropFields) = kindPayload {
                        if let target = dropFields["target"] { result.append(target) }
                        if case .enumVal(_, 0, let uw) = dropFields["unwind"] { result.append(uw) }
                    }
                case 6: // MirAssert { cond, expected, msg, target, unwind }
                    if case .structVal(_, let assertFields) = kindPayload {
                        if let target = assertFields["target"] { result.append(target) }
                        if case .enumVal(_, 0, let uw) = assertFields["unwind"] { result.append(uw) }
                    }
                case 7: // MirYield(MirOperand, BlockId)
                    if case .tuple(let parts) = kindPayload, parts.count >= 2 {
                        result.append(parts[1])
                    }
                default:
                    break
                }
                return makeArray(result)
            }
            return .array([])
        // ── MIR builder fast-paths ──────────────────────────────
        case "operand_copy_local":
            // operand_copy_local(id: LocalId) → MirOperand { kind: MirCopy(Place { local: id, projections: [] }) }
            return .structVal("MirOperand", [
                "kind": .enumVal("MirOperandKind", 0, .structVal("Place", [
                    "local": args[0],
                    "projections": .array([])
                ]))
            ])
        case "operand_copy":
            // operand_copy(place: Place) → MirOperand { kind: MirCopy(place) }
            return .structVal("MirOperand", ["kind": .enumVal("MirOperandKind", 0, args[0])])
        case "push_assign":
            // push_assign(b: &mut MirBuilder, place, rvalue, span) — inlined push_stmt
            // blocks is a Map[Int, MirBlock], backed by native MirNativeMap
                if case .structVal(let bn, let bfields) = args[0],
               case .enumVal(_, 0, let blockIdVal) = bfields["current_block"],
               case .structVal(_, let bidFields) = blockIdVal,
               let blockIdx = bidFields["id"]?.asInt,
               let blocksMap = getNativeMap(bfields["blocks"] ?? .unit),
                    let blockVal = blocksMap.get(.int(blockIdx)),
               case .structVal(let blockName, var blockFields) = blockVal,
               case .array(var stmts) = blockFields["statements"] {
                let stmt: MirValue = .structVal("MirStatement", [
                    "kind": .enumVal("MirStatementKind", 0, .tuple([args[1], args[2]])),
                    "span": args[3]
                ])
                stmts.append(stmt)
                blockFields["statements"] = .array(stmts)
                blocksMap.insert(.int(blockIdx), .structVal(blockName, blockFields))
                recordMutatedFirstArg(.structVal(bn, bfields))
                return .unit
            }
        case "push_stmt":
            // push_stmt(b: &mut MirBuilder, kind: MirStatementKind, span: Span)
                if case .structVal(let bn, let bfields) = args[0],
               case .enumVal(_, 0, let blockIdVal) = bfields["current_block"],
               case .structVal(_, let bidFields) = blockIdVal,
               let blockIdx = bidFields["id"]?.asInt,
               let blocksMap = getNativeMap(bfields["blocks"] ?? .unit),
                    let blockVal = blocksMap.get(.int(blockIdx)),
               case .structVal(let blockName, var blockFields) = blockVal,
               case .array(var stmts) = blockFields["statements"] {
                stmts.append(.structVal("MirStatement", ["kind": args[1], "span": args[2]]))
                blockFields["statements"] = .array(stmts)
                blocksMap.insert(.int(blockIdx), .structVal(blockName, blockFields))
                recordMutatedFirstArg(.structVal(bn, bfields))
                return .unit
            }
        // ── Codegen emit_load_mem / emit_store_mem (inline instruction encoding) ──
        case "emit_load_mem":
            // emit_load_mem(ctx: &mut CodegenCtx, dst: PhysReg, base: PhysReg, offset: i32)
            if case .structVal(let ctxName, var ctxFields) = args[0],
               case .structVal(let textName, var textFields) = ctxFields["text"],
               let offset = args[3].asInt,
               let dIdx = Self.physRegA64Index(args[1]),
               let bIdx = Self.physRegA64Index(args[2]) {
                let bb = getOrUpgradeByteBuffer(&textFields)
                let d = UInt32(min(dIdx, 31)), b = UInt32(min(bIdx, 31))
                if offset >= 0 && (offset % 8) == 0 && offset < 32768 {
                    let imm12 = UInt32((offset / 8) & 0xFFF)
                    let w: UInt32 = 0xF940_0000 | (imm12 << 10) | (b << 5) | d
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else if offset >= -256 && offset <= 255 {
                    let imm9 = UInt32(offset & 0x1FF)
                    let w: UInt32 = 0xF840_0000 | (imm9 << 12) | (b << 5) | d
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else if offset < 0 {
                    // Negative large offset: load abs value into X13, SUB from base, LDUR
                    let x13: UInt32 = 13
                    let absOff = UInt64(Int64(-offset))
                    var w: UInt32 = 0xD280_0000 | (UInt32(absOff & 0xFFFF) << 5) | x13 // MOVZ
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    let lane1 = UInt32((absOff >> 16) & 0xFFFF)
                    if lane1 != 0 {
                        w = 0xF280_0000 | (1 << 21) | (lane1 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane2 = UInt32((absOff >> 32) & 0xFFFF)
                    if lane2 != 0 {
                        w = 0xF280_0000 | (2 << 21) | (lane2 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane3 = UInt32((absOff >> 48) & 0xFFFF)
                    if lane3 != 0 {
                        w = 0xF280_0000 | (3 << 21) | (lane3 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    // SUB X13, base, X13
                    w = 0xCB00_0000 | (x13 << 16) | (b << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    // LDUR d, [X13, #0]
                    w = 0xF840_0000 | (x13 << 5) | d
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else {
                    // Positive large offset: load value into X13, ADD to base, LDUR
                    let x13: UInt32 = 13
                    let u = UInt64(bitPattern: Int64(offset))
                    var w: UInt32 = 0xD280_0000 | (UInt32(u & 0xFFFF) << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    let lane1 = UInt32((u >> 16) & 0xFFFF)
                    if lane1 != 0 {
                        w = 0xF280_0000 | (1 << 21) | (lane1 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane2 = UInt32((u >> 32) & 0xFFFF)
                    if lane2 != 0 {
                        w = 0xF280_0000 | (2 << 21) | (lane2 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane3 = UInt32((u >> 48) & 0xFFFF)
                    if lane3 != 0 {
                        w = 0xF280_0000 | (3 << 21) | (lane3 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    // ADD X13, base, X13
                    w = 0x8B00_0000 | (x13 << 16) | (b << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    // LDUR d, [X13, #0]
                    w = 0xF840_0000 | (x13 << 5) | d
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                }
                ctxFields["text"] = .structVal(textName, textFields)
                recordMutatedFirstArg(.structVal(ctxName, ctxFields))
                return .unit
            }
        case "emit_store_mem":
            // emit_store_mem(ctx: &mut CodegenCtx, base: PhysReg, offset: i32, src: PhysReg)
            if case .structVal(let ctxName, var ctxFields) = args[0],
               case .structVal(let textName, var textFields) = ctxFields["text"],
               let offset = args[2].asInt,
               let bIdx = Self.physRegA64Index(args[1]),
               let sIdx = Self.physRegA64Index(args[3]) {
                let bb = getOrUpgradeByteBuffer(&textFields)
                let b = UInt32(min(bIdx, 31)), s = UInt32(min(sIdx, 31))
                if offset >= 0 && (offset % 8) == 0 && offset < 32768 {
                    let imm12 = UInt32((offset / 8) & 0xFFF)
                    let w: UInt32 = 0xF900_0000 | (imm12 << 10) | (b << 5) | s
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else if offset >= -256 && offset <= 255 {
                    let imm9 = UInt32(offset & 0x1FF)
                    let w: UInt32 = 0xF800_0000 | (imm9 << 12) | (b << 5) | s
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else if offset < 0 {
                    // Negative large offset: load abs value into X13, SUB from base, STUR
                    let x13: UInt32 = 13
                    let absOff = UInt64(Int64(-offset))
                    var w: UInt32 = 0xD280_0000 | (UInt32(absOff & 0xFFFF) << 5) | x13 // MOVZ
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    let lane1 = UInt32((absOff >> 16) & 0xFFFF)
                    if lane1 != 0 {
                        w = 0xF280_0000 | (1 << 21) | (lane1 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane2 = UInt32((absOff >> 32) & 0xFFFF)
                    if lane2 != 0 {
                        w = 0xF280_0000 | (2 << 21) | (lane2 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane3 = UInt32((absOff >> 48) & 0xFFFF)
                    if lane3 != 0 {
                        w = 0xF280_0000 | (3 << 21) | (lane3 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    // SUB X13, base, X13
                    w = 0xCB00_0000 | (x13 << 16) | (b << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    // STUR s, [X13, #0]
                    w = 0xF800_0000 | (x13 << 5) | s
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                } else {
                    // Positive large offset: load value into X13, ADD to base, STUR
                    let x13: UInt32 = 13
                    let u = UInt64(bitPattern: Int64(offset))
                    var w: UInt32 = 0xD280_0000 | (UInt32(u & 0xFFFF) << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    let lane1 = UInt32((u >> 16) & 0xFFFF)
                    if lane1 != 0 {
                        w = 0xF280_0000 | (1 << 21) | (lane1 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane2 = UInt32((u >> 32) & 0xFFFF)
                    if lane2 != 0 {
                        w = 0xF280_0000 | (2 << 21) | (lane2 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    let lane3 = UInt32((u >> 48) & 0xFFFF)
                    if lane3 != 0 {
                        w = 0xF280_0000 | (3 << 21) | (lane3 << 5) | x13
                        bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                        bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    }
                    // ADD X13, base, X13
                    w = 0x8B00_0000 | (x13 << 16) | (b << 5) | x13
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                    // STUR s, [X13, #0]
                    w = 0xF800_0000 | (x13 << 5) | s
                    bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                    bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                }
                ctxFields["text"] = .structVal(textName, textFields)
                recordMutatedFirstArg(.structVal(ctxName, ctxFields))
                return .unit
            }
        // ── MIR verification fast-paths (happy path — no errors) ──
        case "verify_operand":
            if let validLocals = getNativeMap(args[1]),
               operandLocalValid(args[0], validLocals) { return .unit }
        case "verify_rvalue":
            if let validLocals = getNativeMap(args[1]),
               rvalueValid(args[0], validLocals) { return .unit }
        case "verify_statement":
            // verify_statement(stmt, valid_locals, ctx, errors)
            if case .structVal(_, let stFields) = args[0],
               case .enumVal(_, let kindIdx, let payload) = stFields["kind"],
               let validLocals = getNativeMap(args[1]) {
                switch kindIdx {
                case 0: // MirAssign(place, rvalue)
                    if case .tuple(let parts) = payload, parts.count >= 2,
                       case .structVal(_, let pf) = parts[0],
                       case .structVal(_, let lf) = pf["local"],
                       let lid = lf["id"]?.asInt,
                       validLocals.contains(.int(lid)),
                       rvalueValid(parts[1], validLocals) { return .unit }
                case 1, 2: // MirStorageLive(local), MirStorageDead(local)
                    if case .structVal(_, let lf) = payload,
                       let lid = lf["id"]?.asInt,
                       validLocals.contains(.int(lid)) { return .unit }
                default: return .unit // MirNop, etc.
                }
            }
        case "verify_terminator":
            // verify_terminator(term, valid_blocks, valid_locals, ctx, errors)
            if case .structVal(_, let termFields) = args[0],
               case .enumVal(_, let kindIdx, let kindPayload) = termFields["kind"],
               let validBlocks = getNativeMap(args[1]),
               let validLocals = getNativeMap(args[2]) {
                switch kindIdx {
                case 0: // MirGoto(BlockId)
                    if case .structVal(_, let bf) = kindPayload,
                       let bid = bf["id"]?.asInt,
                       validBlocks.contains(.int(bid)) { return .unit }
                case 1, 2, 8: return .unit // MirReturn, MirUnreachable, MirAbort
                case 3: // MirSwitchInt { op, targets, default_target }
                    if case .structVal(_, let sf) = kindPayload {
                        if let opVal = sf["op"], !operandLocalValid(opVal, validLocals) { break }
                        if case .array(let targets) = sf["targets"] {
                            for t in targets {
                                if case .structVal(_, let tf) = t,
                                   case .structVal(_, let tbf) = tf["target"],
                                   let bid = tbf["id"]?.asInt,
                                   !validBlocks.contains(.int(bid)) { break }
                            }
                        }
                        if case .structVal(_, let df) = sf["default_target"],
                           let bid = df["id"]?.asInt,
                           validBlocks.contains(.int(bid)) { return .unit }
                    }
                case 4: // MirCall { dest, func, args, success, unwind }
                    if case .structVal(_, let cf) = kindPayload {
                        if let callee = cf["func"], !operandLocalValid(callee, validLocals) { break }
                        if case .array(let callArgs) = cf["args"] {
                            for a in callArgs {
                                if !operandLocalValid(a, validLocals) { break }
                            }
                        }
                        if case .structVal(_, let sf) = cf["success"],
                           let bid = sf["id"]?.asInt, validBlocks.contains(.int(bid)) {
                            if case .enumVal(_, 0, let uwBlock) = cf["unwind"],
                               case .structVal(_, let uwf) = uwBlock,
                               let uwid = uwf["id"]?.asInt {
                                if validBlocks.contains(.int(uwid)) { return .unit }
                            } else if case .enumVal(_, 1, _) = cf["unwind"] { return .unit }
                            else { return .unit }
                        }
                    }
                case 5: // MirDrop { place, target, unwind }
                    if case .structVal(_, let df) = kindPayload,
                       case .structVal(_, let pf) = df["place"],
                       case .structVal(_, let lf) = pf["local"],
                       let lid = lf["id"]?.asInt, validLocals.contains(.int(lid)),
                       case .structVal(_, let tf) = df["target"],
                       let bid = tf["id"]?.asInt, validBlocks.contains(.int(bid)) {
                        if case .enumVal(_, 0, let uwBlock) = df["unwind"],
                           case .structVal(_, let uwf) = uwBlock,
                           let uwid = uwf["id"]?.asInt {
                            if validBlocks.contains(.int(uwid)) { return .unit }
                        } else { return .unit }
                    }
                case 6: // MirAssert { cond, expected, msg, target, unwind }
                    if case .structVal(_, let af) = kindPayload,
                       let cond = af["cond"], operandLocalValid(cond, validLocals),
                       case .structVal(_, let tf) = af["target"],
                       let bid = tf["id"]?.asInt, validBlocks.contains(.int(bid)) {
                        if case .enumVal(_, 0, let uwBlock) = af["unwind"],
                           case .structVal(_, let uwf) = uwBlock,
                           let uwid = uwf["id"]?.asInt {
                            if validBlocks.contains(.int(uwid)) { return .unit }
                        } else { return .unit }
                    }
                case 7: // MirYield — no validation needed
                    return .unit
                default: return .unit
                }
            }
        // ── Register allocator fast-path ──
        case "alloc_reg":
            // alloc_reg(state: &mut RegAllocState) -> Option[PhysReg]
            if case .structVal(let sn, var fields) = args[0],
               case .array(var freeRegs) = fields["free_regs"] {
                if freeRegs.isEmpty {
                    recordMutatedFirstArg(.structVal(sn, fields))
                    return .enumVal("Option", 1, .unit) // None
                }
                let reg = freeRegs.removeLast()
                fields["free_regs"] = .array(freeRegs)
                if let (isA64, inner) = Self.physRegDecompose(reg) {
                    var isCalleeSaved = false
                    var regId = 0
                    if isA64, let idx = Self.enumTag(inner, named: "A64") {
                        regId = min(idx, 31)
                        isCalleeSaved = idx >= 19 && idx <= 28
                    } else if !isA64, let idx = Self.enumTag(inner, named: "X64") {
                        regId = idx
                        isCalleeSaved = idx == 3 || idx == 5 || (idx >= 12 && idx <= 15)
                    }
                    if isCalleeSaved, let usedCallee = getNativeMap(fields["used_callee"] ?? .unit) {
                        usedCallee.insert(.int(regId), .unit)
                    }
                }
                recordMutatedFirstArg(.structVal(sn, fields))
                return .enumVal("Option", 0, reg)
            }
        // ── Codegen emit_mov_rr (inline a64_mov_rr / x64_mov_rr) ──
        case "emit_mov_rr":
            if case .structVal(let ctxName, var ctxFields) = args[0],
               case .structVal(let textName, var textFields) = ctxFields["text"],
               let dIdx = Self.physRegA64Index(args[1]),
               let nIdx = Self.physRegA64Index(args[2]) {
                let bb = getOrUpgradeByteBuffer(&textFields)
                let rd = UInt32(min(dIdx, 31)), rn = UInt32(min(nIdx, 31))
                let w: UInt32 = (dIdx == 31 || nIdx == 31) ? (0x9100_0000 | (rn << 5) | rd) : (0xAA00_03E0 | (rn << 16) | rd)
                bb.data.append(UInt8(truncatingIfNeeded: w)); bb.data.append(UInt8(truncatingIfNeeded: w >> 8))
                bb.data.append(UInt8(truncatingIfNeeded: w >> 16)); bb.data.append(UInt8(truncatingIfNeeded: w >> 24))
                ctxFields["text"] = .structVal(textName, textFields)
                recordMutatedFirstArg(.structVal(ctxName, ctxFields))
                return .unit
            }
        case "load_constant":
            if case .structVal(_, let cstFields) = args[1],
               case .enumVal(_, let kindIdx, let payload) = cstFields["kind"],
               let dIdx = Self.physRegA64Index(args[2]) {
                switch kindIdx {
                case 0, 7:
                    if let r = withCodegenTextBuffer(args[0], { bb in
                        let rd = UInt32(min(dIdx, 31))
                        let w: UInt32 = dIdx == 31
                            ? (0x9100_0000 | (UInt32(31) << 5) | rd)
                            : (0xAA00_03E0 | (UInt32(31) << 16) | rd)
                        appendWord(bb, w)
                    }) {
                        return r
                    }
                case 1:
                    if let bit = Self.scalarBoolValue(payload) {
                        if let r = withCodegenTextBuffer(args[0], { bb in
                            if bit {
                                emitA64MoveImmediate(bb, dstIndex: dIdx, imm: 1)
                            } else {
                                let rd = UInt32(min(dIdx, 31))
                                let w: UInt32 = dIdx == 31
                                    ? (0x9100_0000 | (UInt32(31) << 5) | rd)
                                    : (0xAA00_03E0 | (UInt32(31) << 16) | rd)
                                appendWord(bb, w)
                            }
                        }) {
                            return r
                        }
                    }
                case 2, 4:
                    if let imm = Self.scalarIntValue(payload),
                       let r = withCodegenTextBuffer(args[0], { bb in
                           emitA64MoveImmediate(bb, dstIndex: dIdx, imm: imm)
                       }) {
                        return r
                    }
                default:
                    break
                }
            }
        case "emit_zero_reg":
            if let dIdx = Self.physRegA64Index(args[1]),
               let r = withCodegenTextBuffer(args[0], { bb in
                   let rd = UInt32(min(dIdx, 31))
                   let w: UInt32 = dIdx == 31
                       ? (0x9100_0000 | (UInt32(31) << 5) | rd)
                       : (0xAA00_03E0 | (UInt32(31) << 16) | rd)
                   appendWord(bb, w)
               }) {
                return r
            }
        case "emit_mov_ri":
            if let dIdx = Self.physRegA64Index(args[1]),
               let imm = args[2].asInt,
               let r = withCodegenTextBuffer(args[0], { bb in
                   emitA64MoveImmediate(bb, dstIndex: dIdx, imm: imm)
               }) {
                return r
            }
        case "emit_cmp_rr":
            if let aIdx = Self.physRegA64Index(args[1]),
               let bIdx = Self.physRegA64Index(args[2]),
               let r = withCodegenTextBuffer(args[0], { bb in
                   appendWord(bb, 0xEB00_001F | (UInt32(min(bIdx, 31)) << 16) | (UInt32(min(aIdx, 31)) << 5))
               }) {
                return r
            }
        case "emit_cmp_ri":
            if let rIdx = Self.physRegA64Index(args[1]),
               let imm = args[2].asInt,
               let r = withCodegenTextBuffer(args[0], { bb in
                    let uimm = UInt32(imm & 0xFFFFFFFF)
                    let n = UInt32(min(rIdx, 31))
                    if uimm <= 0xFFF {
                        appendWord(bb, 0xF100_001F | (uimm << 10) | (n << 5))
                    } else if (uimm & 0xFFF) == 0 && (uimm >> 12) <= 0xFFF {
                        appendWord(bb, 0xF140_001F | ((uimm >> 12) << 10) | (n << 5))
                    } else {
                        let scratch = (rIdx == 16) ? 17 : 16
                        emitA64MoveImmediate(bb, dstIndex: scratch, imm: Int(uimm))
                        appendWord(bb, 0xEB00_001F | (UInt32(scratch) << 16) | (n << 5))
                    }
                }) {
                return r
            }
        case "emit_setcc":
            if let cond = Self.a64CondCode(args[1]),
               let dIdx = Self.physRegA64Index(args[2]),
               let r = withCodegenTextBuffer(args[0], { bb in
                   let inv = cond ^ 1
                   appendWord(bb, 0x9A9F_07E0 | (inv << 12) | UInt32(min(dIdx, 31)))
               }) {
                return r
            }
        case "emit_add_ri":
            if let dIdx = Self.physRegA64Index(args[1]),
               let imm = args[2].asInt,
               abs(imm) <= 0xFFF,
               let r = withCodegenTextBuffer(args[0], { bb in
                   let rd = UInt32(min(dIdx, 31))
                   if imm >= 0 {
                       appendWord(bb, 0x9100_0000 | (UInt32(imm) << 10) | (rd << 5) | rd)
                   } else {
                       appendWord(bb, 0xD100_0000 | (UInt32(-imm) << 10) | (rd << 5) | rd)
                   }
               }) {
                return r
            }
        case "emit_sub_ri":
            if let dIdx = Self.physRegA64Index(args[1]),
               let imm = args[2].asInt,
               abs(imm) <= 0xFFF,
               let r = withCodegenTextBuffer(args[0], { bb in
                   let rd = UInt32(min(dIdx, 31))
                   if imm >= 0 {
                       appendWord(bb, 0xD100_0000 | (UInt32(imm) << 10) | (rd << 5) | rd)
                   } else {
                       appendWord(bb, 0x9100_0000 | (UInt32(-imm) << 10) | (rd << 5) | rd)
                   }
               }) {
                return r
            }
        default:
            break  // Fall through to main builtin switch
        }

        switch name {

        // ── Macros ──────────────────────────────────────────────
        case "__macro_println", "println", "io::println", "std::io::println":
            output.append(args.map(\.displayString).joined(separator: " "))
            return .unit
        case "__macro_print", "print", "io::print", "std::io::print":
            output.append(args.map(\.displayString).joined(separator: " "))
            return .unit
        case "eprintln", "io::eprintln", "std::io::eprintln":
            // Write directly to stderr for real-time progress visibility
            let msg = args.map(\.displayString).joined(separator: " ")
            fputs(msg, stderr)
            fputs("\n", stderr)
            fflush(stderr)
            return .unit
        case "eprint", "io::eprint", "std::io::eprint":
            let msg = args.map(\.displayString).joined(separator: " ")
            fputs(msg, stderr)
            fflush(stderr)
            return .unit
        case "__macro_assert":
            if let b = args.first?.asBool, !b { output.append("ASSERTION FAILED") }
            return .unit
        case "__macro_assert_eq":
            if args.count >= 2, args[0] != args[1] {
                output.append("ASSERTION FAILED: \(args[0].displayString) != \(args[1].displayString)")
            }
            return .unit
        case "__macro_vec":
            return makeArray(args)
        case "__macro_format", "format":
            return .string(args.map(\.displayString).joined())
        case "from_cstr", "String::from_cstr", "String__from_cstr", "string_from_cstr":
            return .string(cString(from: args.first ?? .int(0)) ?? "")
        case "libc_write":
            let fd = args.first?.asInt ?? -1
            let count = args.count > 2 ? max(0, args[2].asInt ?? 0) : Int.max
            let bytes = byteSlice(from: args.count > 1 ? args[1] : .unit, limit: count)
            let data = Data(bytes)
            switch fd {
            case 2:
                FileHandle.standardError.write(data)
            case 1:
                FileHandle.standardOutput.write(data)
            default:
                let _ = data.withUnsafeBytes { buf in
                    write(Int32(fd), buf.baseAddress, data.count)
                }
            }
            return .int(bytes.count)
        case "libc_getenv":
            guard let name = cString(from: args.first ?? .int(0)),
                  let value = ProcessInfo.processInfo.environment[name] else {
                return .int(0)
            }
            let bytes = value.utf8.map { MirValue.int(Int($0)) } + [.int(0)]
            return makeArray(bytes)
        case "libc_system":
            guard let cmd = cString(from: args.first ?? .int(0)) else {
                return .int(-1)
            }
            let proc = Process()
            proc.launchPath = "/bin/sh"
            proc.arguments = ["-c", cmd]
            do {
                try proc.run()
                proc.waitUntilExit()
                return .int(Int(proc.terminationStatus))
            } catch {
                return .int(-1)
            }
        case "libc_open_path":
            guard let path = cString(from: args.first ?? .int(0)) else {
                return .int(-1)
            }
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            return .int(Int(fd))
        case "libc_close":
            let fd = args.first?.asInt ?? -1
            return .int(Int(close(Int32(fd))))
        case "libc_chmod":
            guard let path = cString(from: args.first ?? .int(0)) else {
                return .int(-1)
            }
            let mode = args.count > 1 ? args[1].asInt ?? 0 : 0
            return .int(Int(chmod(path, mode_t(mode))))
        case "_tg_write_vec_u8":
            let fd = args.first?.asInt ?? -1
            let count = args.count > 2 ? max(0, args[2].asInt ?? 0) : Int.max
            let bytes = byteSlice(from: args.count > 1 ? args[1] : .unit, limit: count)
            if bytes.isEmpty { return .int(0) }
            let data = Data(bytes)
            var written = 0
            if fd == 1 || fd == 2 {
                // Foundation's FileHandle.write is all-or-nothing (throws on failure).
                let handle: FileHandle = fd == 1 ? .standardOutput : .standardError
                try? handle.write(contentsOf: data)
                written = data.count
            } else {
                // write-all loop: a single write(2) may do a partial write.
                let fds = Int32(fd)
                let n = data.count
                var offset = 0
                while offset < n {
                    let result = data.withUnsafeBytes { buf -> Int in
                        let rc = write(fds, buf.baseAddress!.advanced(by: offset), n - offset)
                        return Int(rc)
                    }
                    if result <= 0 { break }
                    offset += result
                }
                written = offset
            }
            return .int(written)
        case "_tg_normalize_string":
            return args.first ?? .int(0)
        case "clock_gettime_nsec":
            // Return monotonic time in nanoseconds using Mach absolute time.
            // This is only called when --time is passed; during normal bootstrap
            // compilation --time is not set, so this path is typically unreachable.
            var info = mach_timebase_info_data_t(numer: 0, denom: 0)
            mach_timebase_info(&info)
            let now = mach_absolute_time()
            let nanos = now * UInt64(info.numer) / UInt64(info.denom)
            return .int(Int(truncatingIfNeeded: nanos))
        case "get_current_rss_kb":
            // Return current resident set size in kilobytes using getrusage.
            // Only called when --time is passed; bootstrap runs do not use this.
            var usage = rusage()
            let result = withUnsafeMutablePointer(to: &usage) { ptr in
                getrusage(RUSAGE_SELF, ptr)
            }
            if result == 0 {
                // On macOS ru_maxrss is in bytes, convert to KB
                return .int(Int(usage.ru_maxrss) / 1024)
            }
            return .int(0)

        case "_tg_bump_reset":
            // Interpreter uses host memory management; bump reset is a no-op
            // at the interpreted level (only meaningful in native codegen).
            return .unit

        // ── Type constructors ───────────────────────────────────
        case "Vec::new", "Array::new", "Vec::with_capacity", "Array::with_capacity",
             "__intrinsic_array_new", "__intrinsic_array_with_capacity", "array_new", "array_with_capacity":
            return .array([])
        case "Vec::from", "Array::from", "__intrinsic_array_from_list", "array_from_list":
            if case .array = args.first { return args.first! }
            return args.first ?? .array([])
        case "array_get", "collections::array_get", "std::collections::array_get", "__intrinsic_array_get":
            if case .array(let elems) = args.first,
               let idx = args.dropFirst().first?.asInt,
               idx >= 0,
               idx < elems.count {
                return elems[idx]
            }
            return .unit
        case "Vec::filled":
            let n = args.first?.asInt ?? 0
            let val = args.count > 1 ? args[1] : .unit
            return makeArray(Array(repeating: val, count: n))
        case "Map::new", "HashMap::new", "Set::new",
             "Map::with_capacity", "HashMap::with_capacity", "Set::with_capacity",
             "__intrinsic_map_with_capacity":
            return makeNativeMap()

        // ── Map native fast-paths (used by borrow checker and type checker) ──
        // These ensure Map operations work correctly even when the interpreted
        // stdlib implementation would hit unsupported patterns.
        case "map_get", "Map::get", "collections::map_get", "std::collections::map_get":
            // map_get(map: Map[K,V], key: K) -> Option[V]
            if args.count >= 2, let nativeMap = getNativeMap(args[0]) {
                if let result = nativeMap.get(args[1]) {
                    return .enumVal("Option", 0, result)
                }
                return .enumVal("Option", 1, .unit)
            }
            // Fallback: search entries array for non-native maps
            if args.count >= 2,
               case .structVal("Map", let fields) = args[0],
               case .array(let entries) = fields["entries"] {
                for entry in entries {
                    if case .tuple(let kv) = entry, kv.count >= 2, kv[0] == args[1] {
                        return .enumVal("Option", 0, kv[1])
                    }
                }
                return .enumVal("Option", 1, .unit)
            }
            return .enumVal("Option", 1, .unit)
        case "map_insert", "Map::insert", "collections::map_insert", "std::collections::map_insert":
            // map_insert(map: &mut Map[K,V], key: K, value: V) -> Unit
            if args.count >= 3, let nativeMap = getNativeMap(args[0]) {
                nativeMap.insert(args[1], args[2])
                return args[0]
            }
            // Fallback for non-native maps
            if args.count >= 3,
               case .structVal("Map", var fields) = args[0],
               case .array(var entries) = fields["entries"] {
                var found = false
                for i in 0..<entries.count {
                    if case .tuple(let kv) = entries[i], kv.count >= 2, kv[0] == args[1] {
                        entries[i] = .tuple([args[1], args[2]])
                        found = true
                        break
                    }
                }
                if !found {
                    entries.append(.tuple([args[1], args[2]]))
                }
                fields["entries"] = .array(entries)
                return .structVal("Map", fields)
            }
            return args[0]
        case "map_contains", "map_contains_key", "Map::contains_key", "collections::map_contains_key", "std::collections::map_contains_key":
            // map_contains_key(map: &Map[K,V], key: K) -> Bool
            if args.count >= 2, let nativeMap = getNativeMap(args[0]) {
                return .bool(nativeMap.get(args[1]) != nil)
            }
            if args.count >= 2,
               case .structVal("Map", let fields) = args[0],
               case .array(let entries) = fields["entries"] {
                for entry in entries {
                    if case .tuple(let kv) = entry, kv.count >= 2, kv[0] == args[1] {
                        return .bool(true)
                    }
                }
            }
            return .bool(false)
        case "map_remove", "Map::remove", "collections::map_remove", "std::collections::map_remove":
            // map_remove(map: &mut Map[K,V], key: K) -> Option[V]
            if args.count >= 2, let nativeMap = getNativeMap(args[0]) {
                if let result = nativeMap.get(args[1]) {
                    nativeMap.remove(args[1])
                    return .enumVal("Option", 0, result)
                }
                return .enumVal("Option", 1, .unit)
            }
            return .enumVal("Option", 1, .unit)
        case "map_len", "Map::len", "collections::map_len", "std::collections::map_len":
            // map_len(map: &Map[K,V]) -> Int
            if let nativeMap = getNativeMap(args.first ?? .unit) {
                return .int(nativeMap.count)
            }
            if case .structVal("Map", let fields) = args.first,
               case .array(let entries) = fields["entries"] {
                return .int(entries.count)
            }
            return .int(0)
        case "map_clear", "Map::clear", "collections::map_clear", "std::collections::map_clear":
            // map_clear(map: &mut Map[K,V]) -> Unit
            if let nativeMap = getNativeMap(args.first ?? .unit) {
                nativeMap.dict.removeAll()
            }
            return args.first ?? .unit
        case "map_keys", "Map::keys", "collections::map_keys", "std::collections::map_keys":
            // map_keys(map: &Map[K,V]) -> Vec[K]
            if let nativeMap = getNativeMap(args.first ?? .unit) {
                let keys = nativeMap.dict.values.map { $0.key }
                return makeArray(keys)
            }
            return makeArray([MirValue]())
        case "map_values", "Map::values", "collections::map_values", "std::collections::map_values":
            // map_values(map: &Map[K,V]) -> Vec[V]
            if let nativeMap = getNativeMap(args.first ?? .unit) {
                let values = nativeMap.dict.values.map { $0.value }
                return makeArray(values)
            }
            return makeArray([MirValue]())
        case "map_entries", "Map::entries", "collections::map_entries", "std::collections::map_entries":
            // map_entries(map: &Map[K,V]) -> Vec[(K,V)]
            if let nativeMap = getNativeMap(args.first ?? .unit) {
                return makeArray(nativeMap.toEntries())
            }
            if case .structVal("Map", let fields) = args.first,
               case .array(let entries) = fields["entries"] {
                return makeArray(entries)
            }
            return makeArray([MirValue]())

        case "String::new":
            return .string("")
        case "String::from_bytes":
            if case .array(let bytes) = args.first {
                let rawBytes = bytes.compactMap { byte -> UInt8? in
                    byte.asInt.map { UInt8(truncatingIfNeeded: $0) }
                }
                return .string(String(decoding: rawBytes, as: UTF8.self))
            }
            return .string("")
        case "Box::new":
            // Box::new(val): wrap the value in a Box struct so projections work.
            // Box[T] = struct { ptr: Ptr[T] }
            return .structVal("Box", ["ptr": args.first ?? .unit])
        case "Option::Some":
            return .enumVal("Option", 0, args.first ?? .unit)
        case "Option::None":
            return .enumVal("Option", 1, .unit)
        case "Result::Ok":
            return .enumVal("Result", 0, args.first ?? .unit)
        case "Result::Err":
            return .enumVal("Result", 1, args.first ?? .unit)
        case "Int::from_str_radix":
            if let s = args.first?.displayString, let radix = args.dropFirst().first?.asInt,
               let val = Int(s, radix: radix) {
                return .enumVal("Option", 0, .int(val))
            }
            return .enumVal("Option", 1, .unit)
        case "Char::from_u32", "char::from_u32":
            if let i = args.first?.asInt, let u = UnicodeScalar(i) {
                return .enumVal("Option", 0, .char(Character(u)))
            }
            return .enumVal("Option", 1, .unit)
        case "Version::new":
            return .structVal("Version", ["major": args.count > 0 ? args[0] : .int(0), "minor": args.count > 1 ? args[1] : .int(0), "patch": args.count > 2 ? args[2] : .int(0)])
        case "Version::parse", "Requirement::parse":
            return .enumVal("Result", 0, .structVal("Version", ["major": args.count > 0 ? args[0] : .int(0), "minor": args.count > 1 ? args[1] : .int(0), "patch": args.count > 2 ? args[2] : .int(0)]))
        case "Sha256::new":
            return .structVal("Sha256", ["_data": .array([])])

        // ── Vec / Array methods (receiver is args[0]) ───────────
        case ".reserve":
            // .reserve(capacity: Int) — Pre-allocate Vec/Array capacity (no-op in interpreter,
            // but must not fail to resolve)
            if case .array(let elems) = args.first, args.count > 1, let n = args[1].asInt {
                elems.elements.reserveCapacity(n)
                return args.first!
            }
            return args.first ?? .unit
        case ".push":
            if case .array(var elems) = args.first, args.count > 1 {
                if case .unit = args[1] {
                    pushUnitIntoArrayCount += 1
                    if pushUnitIntoArrayCount <= 12 {
                        let chain = callStack.suffix(6).map { program.functions[$0.functionIdx].name }.joined(separator: " -> ")
                        fputs("[PUSH-UNIT] len=\(elems.count) chain=\(chain)\n", stderr)
                    }
                }
                elems.append(args[1])
                return args.first!
            }
            if case .byteBuffer(let bb) = args.first, args.count > 1 {
                if let v = args[1].asInt {
                    bb.data.append(UInt8(truncatingIfNeeded: v))
                }
                return args.first!  // Reference type — already mutated
            }
            return args.first ?? .unit
        case ".pop":
            if case .array(var elems) = args.first, !elems.isEmpty {
                let last = elems.removeLast()
                return .enumVal("Option", 0, last)
            }
            return .enumVal("Option", 1, .unit)
        case ".len":
            if case .array(let elems) = args.first { return .int(elems.count) }
            if case .byteBuffer(let bb) = args.first { return .int(bb.data.count) }
            if case .string(let s) = args.first { return .int(stringLength(s)) }
            if let nm = getNativeMap(args.first ?? .unit) { return .int(nm.count) }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                return .int(arr.count)
            }
            // Range { start, end } → end - start (exclusive)
            if case .structVal("Range", let f) = args.first,
               let s = f["start"]?.asInt, let e = f["end"]?.asInt {
                return .int(max(0, e - s))
            }
            // RangeInclusive { start, end } → end - start + 1
            if case .structVal("RangeInclusive", let f) = args.first,
               let s = f["start"]?.asInt, let e = f["end"]?.asInt {
                return .int(max(0, e - s + 1))
            }
            return .int(0)
        case ".get":
            if case .array(let elems) = args.first, let idx = args.dropFirst().first?.asInt {
                if idx >= 0 && idx < elems.count {
                    return .enumVal("Option", 0, elems[idx])
                }
            }
            // Native Map.get(key)
            if let nm = getNativeMap(args.first ?? .unit) {
                let key = args.count > 1 ? args[1] : .unit
                if let val = nm.get(key) { return .enumVal("Option", 0, val) }
                return .enumVal("Option", 1, .unit)
            }
            // Fallback Map.get(key)
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                let key = args.count > 1 ? args[1] : .unit
                for entry in arr {
                    if case .tuple(let kv) = entry, kv.count >= 2, kv[0] == key {
                        return .enumVal("Option", 0, kv[1])
                    }
                }
            }
            return .enumVal("Option", 1, .unit)
        case ".get_mut":
            return dispatchCallDirect(".get", args: args) // Same as .get for interpreter
        case ".contains":
            if case .array(let elems) = args.first {
                let needle = args.count > 1 ? args[1] : .unit
                return .bool(elems.contains(needle))
            }
            if case .string(let s) = args.first, let sub = args.dropFirst().first?.displayString {
                return .bool(s.contains(sub))
            }
            // Native Set.contains
            if let nm = getNativeMap(args.first ?? .unit) {
                return .bool(nm.contains(args.count > 1 ? args[1] : .unit))
            }
            // Fallback Set.contains
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                let key = args.count > 1 ? args[1] : .unit
                return .bool(arr.contains { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] == key }
                    return entry == key
                })
            }
            return .bool(false)
        case ".is_empty":
            if case .array(let elems) = args.first { return .bool(elems.isEmpty) }
            if case .string(let s) = args.first { return .bool(s.isEmpty) }
            if let nm = getNativeMap(args.first ?? .unit) { return .bool(nm.isEmpty) }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                return .bool(arr.isEmpty)
            }
            return .bool(true)
        case ".first":
            if case .array(let elems) = args.first, let f = elems.first {
                return .enumVal("Option", 0, f)
            }
            return .enumVal("Option", 1, .unit)
        case ".last":
            if case .array(let elems) = args.first, let l = elems.last {
                return .enumVal("Option", 0, l)
            }
            return .enumVal("Option", 1, .unit)
        case ".reverse":
            if case .array(let elems) = args.first {
                elems.elements.reverse()
                return args.first!
            }
            return args.first ?? .unit
        case ".sort":
            if case .array(let elems) = args.first {
                elems.elements.sort { a, b in
                    // Use numeric comparison for ints, then string fallback
                    if let ai = a.asInt, let bi = b.asInt { return ai < bi }
                    if let af = a.asFloat, let bf = b.asFloat { return af < bf }
                    return a.displayString < b.displayString
                }
                return args.first!
            }
            return args.first ?? .unit
        case ".extend":
            let ext = args.dropFirst().first ?? .unit
            switch (args.first, ext) {
            case (.array(var base), .array(let extArr)):
                base.append(contentsOf: extArr)
                return args.first ?? .unit
            case (.array(let base), .byteBuffer(let extBuf)):
                // Upgrade to byteBuffer for fast bulk copy
                let bb = MirByteBuffer(data: base.map { UInt8(truncatingIfNeeded: $0.asInt ?? 0) })
                bb.data.append(contentsOf: extBuf.data)
                return .byteBuffer(bb)
            case (.byteBuffer(let base), .byteBuffer(let extBuf)):
                base.data.append(contentsOf: extBuf.data)
                return .byteBuffer(base)
            case (.byteBuffer(let base), .array(let extArr)):
                for v in extArr { base.data.append(UInt8(v.asInt ?? 0)) }
                return .byteBuffer(base)
            default:
                return args.first ?? .unit
            }
        case ".clear":
            // Canvas.clear(color) — native GUI
            if case .structVal("NativeCanvas", _) = args.first {
                if args.count > 1, case .structVal(_, let c) = args[1] {
                    let r = c["r"]?.asFloat ?? 0
                    let g = c["g"]?.asFloat ?? 0
                    let b = c["b"]?.asFloat ?? 0
                    let a = c["a"]?.asFloat ?? 1
                    TGNativeGUI.shared.clear(r, g, b, a)
                }
                return .unit
            }
            // Map/Set.clear()
            if let nm = getNativeMap(args.first ?? .unit) {
                nm.dict.removeAll(keepingCapacity: true)
                return args.first!
            }
            // Vec.clear() — array operation
            if case .array(var elems) = args.first {
                elems.removeAll(keepingCapacity: true)
                return args.first!
            }
            return .array([])
        case ".truncate":
            if case .array(let elems) = args.first, let n = args.dropFirst().first?.asInt {
                elems.truncate(to: n)
                return args.first!
            }
            return args.first ?? .unit
        case ".join":
            if case .array(let elems) = args.first {
                let sep = args.count > 1 ? args[1].displayString : ""
                return .string(elems.map(\.displayString).joined(separator: sep))
            }
            return .string("")
        case ".to_vec":
            return args.first ?? .array([])
        case ".as_ptr", ".as_mut_ptr":
            return args.first ?? .unit
        case ".as_bytes":
            if case .string(let s) = args.first {
                return makeArray(s.utf8.map { .int(Int($0)) })
            }
            return args.first ?? .array([])
        case ".iter":
            return materializeIterable(args.first ?? .array([]))
        case ".resize":
            if case .array(var elems) = args.first, let n = args.dropFirst().first?.asInt {
                let fill = args.count > 2 ? args[2] : .unit
                if n > elems.count {
                    elems.append(contentsOf: Array(repeating: fill, count: n - elems.count))
                } else {
                    elems.truncate(to: n)
                }
                return args.first!
            }
            return args.first ?? .unit
        case ".set":
            if case .array(var elems) = args.first, let idx = args.dropFirst().first?.asInt, args.count > 2 {
                while elems.count <= idx { elems.append(.unit) }
                elems[idx] = args[2]
                return args.first!
            }
            return args.first ?? .unit

        // ── String methods ──────────────────────────────────────
        case ".clone":
            if let value = args.first {
                return cloneValue(value)
            }
            return .unit
        case "__intrinsic_string_as_bytes", "string_as_bytes", "String__as_bytes":
            if case .string(let s) = args.first {
                return makeArray(s.utf8.map { .int(Int($0)) })
            }
            return args.first ?? .array([])
        case "__intrinsic_string_as_ptr", "string_as_ptr", "String__as_ptr",
             "__intrinsic_array_as_ptr", "__intrinsic_array_as_mut_ptr",
             "array_as_ptr", "array_as_mut_ptr",
             "Vec__as_ptr", "Vec__as_mut_ptr",
             "Array__as_ptr", "Array__as_mut_ptr":
            return args.first ?? .unit
        case ".to_bits":
            if case .float(let f) = args.first {
                return .int(Int(bitPattern: UInt(f.bitPattern)))
            }
            if case .int(let i) = args.first { return .int(i) }
            return .int(0)
        case ".from_bits":
            if let i = args.first?.asInt {
                return .float(Double(bitPattern: UInt64(bitPattern: Int64(i))))
            }
            return .float(0)
        case ".wrapping_add":
            if let a = args.first?.asInt, let b = args.dropFirst().first?.asInt {
                return .int(a &+ b)
            }
            return .int(0)
        case ".wrapping_sub":
            if let a = args.first?.asInt, let b = args.dropFirst().first?.asInt {
                return .int(a &- b)
            }
            return .int(0)
        case ".wrapping_mul":
            if let a = args.first?.asInt, let b = args.dropFirst().first?.asInt {
                return .int(a &* b)
            }
            return .int(0)
        case ".abs":
            if case .int(let i) = args.first { return .int(abs(i)) }
            if case .float(let f) = args.first { return .float(abs(f)) }
            return args.first ?? .int(0)
        case ".is_nan":
            if case .float(let f) = args.first { return .bool(f.isNaN) }
            return .bool(false)
        case ".is_infinite":
            if case .float(let f) = args.first { return .bool(f.isInfinite) }
            return .bool(false)
        case ".floor":
            if case .float(let f) = args.first { return .float(f.rounded(.down)) }
            return args.first ?? .float(0)
        case ".ceil":
            if case .float(let f) = args.first { return .float(f.rounded(.up)) }
            return args.first ?? .float(0)
        case ".sqrt":
            if case .float(let f) = args.first { return .float(f.squareRoot()) }
            return .float(0)
        case ".to_string", ".as_str", ".as_ptr_address":
            return .string(args.first?.displayString ?? "")
        case ".starts_with":
            if case .string(let s) = args.first, let prefix = args.dropFirst().first?.displayString {
                return .bool(s.hasPrefix(prefix))
            }
            return .bool(false)
        case ".ends_with":
            if case .string(let s) = args.first, let suffix = args.dropFirst().first?.displayString {
                return .bool(s.hasSuffix(suffix))
            }
            return .bool(false)
        case ".trim":
            if case .string(let s) = args.first {
                return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return args.first ?? .string("")
        case ".split":
            if case .string(let s) = args.first, let sep = args.dropFirst().first?.displayString {
                return makeArray(s.components(separatedBy: sep).map { .string(String($0)) })
            }
            return .array([])
        case ".lines":
            if case .string(let s) = args.first {
                return makeArray(s.components(separatedBy: "\n").map { .string(String($0)) })
            }
            return .array([])
        case ".replace":
            if case .string(let s) = args.first, args.count >= 3 {
                let old = args[1].displayString
                let new = args[2].displayString
                return .string(s.replacingOccurrences(of: old, with: new))
            }
            return args.first ?? .string("")
        case ".chars":
            if !args.isEmpty, case .string(let s) = args[0] {
                return makeArray(s.map { .char($0) })
            }
            return .array([])
        case ".char_at":
            if args.count >= 2,
               case .string(let s) = args[0],
               let idx = args[1].asInt,
               let ch = stringCharacter(s, at: idx) {
                return .char(ch)
            }
            return .char("\0")
        case ".substring", ".slice":
            if args.count >= 2,
               case .string(let s) = args[0],
               let start = args[1].asInt {
                let end = args.count > 2 ? (args[2].asInt ?? stringLength(s)) : stringLength(s)
                return .string(stringSlice(s, start: start, end: end))
            }
            return args.isEmpty ? .string("") : args[0]
        case ".find", ".index_of":
            if case .string(let s) = args.first, let needle = args.dropFirst().first?.displayString {
                if let index = stringFind(s, needle: needle) {
                    return .enumVal("Option", 0, .int(index))
                }
            }
            return .enumVal("Option", 1, .unit)
        case ".rfind":
            if case .string(let s) = args.first, let needle = args.dropFirst().first?.displayString {
                if let index = stringFind(s, needle: needle, backwards: true) {
                    return .enumVal("Option", 0, .int(index))
                }
            }
            return .enumVal("Option", 1, .unit)
        case ".to_lowercase":
            if case .string(let s) = args.first { return .string(s.lowercased()) }
            return args.first ?? .string("")
        case ".to_uppercase":
            if case .string(let s) = args.first { return .string(s.uppercased()) }
            return args.first ?? .string("")
        case ".capitalize":
            if case .string(let s) = args.first { return .string(s.prefix(1).uppercased() + s.dropFirst()) }
            return args.first ?? .string("")
        case ".parse_int":
            if case .string(let s) = args.first, let i = Int(s) {
                return .enumVal("Option", 0, .int(i))
            }
            return .enumVal("Option", 1, .unit)
        case ".parse_uint":
            if case .string(let s) = args.first, let i = UInt(s) {
                return .enumVal("Option", 0, .int(Int(i)))
            }
            return .enumVal("Option", 1, .unit)
        case ".parse_float":
            if case .string(let s) = args.first, let f = Double(s) {
                return .enumVal("Option", 0, .float(f))
            }
            return .enumVal("Option", 1, .unit)
        case ".into_bytes", ".bytes":
            if case .string(let s) = args.first {
                return makeArray(s.utf8.map { .int(Int($0)) })
            }
            return .array([])

        // ── Map / HashMap methods ───────────────────────────────
        case ".insert":
            // Native Map.insert(key, value)
            if let nm = getNativeMap(args.first ?? .unit), args.count >= 3 {
                nm.insert(args[1], args[2])
                return args.first!
            }
            // Native Set.insert(key)
            if let nm = getNativeMap(args.first ?? .unit), args.count >= 2 {
                nm.insert(args[1], .unit)
                return args.first!
            }
            // Fallback: non-native maps
            if case .structVal("Map", var fields) = args.first, case .array(var arr)? = fields["entries"],
               args.count >= 3 {
                let key = args[1]; let value = args[2]
                arr.removeAll { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] == key }
                    return false
                }
                arr.append(.tuple([key, value]))
                fields["entries"] = .array(arr)
                return .structVal("Map", fields)
            }
            if case .structVal("Map", var fields) = args.first, case .array(var arr)? = fields["entries"],
               args.count >= 2 {
                let key = args[1]
                if !arr.contains(where: { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] == key }
                    return entry == key
                }) {
                    arr.append(.tuple([key, .unit]))
                    fields["entries"] = .array(arr)
                }
                return .structVal("Map", fields)
            }
            return args.first ?? .unit
        case ".contains_key":
            if let nm = getNativeMap(args.first ?? .unit) {
                return .bool(nm.contains(args.count > 1 ? args[1] : .unit))
            }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                let key = args.count > 1 ? args[1] : .unit
                return .bool(arr.contains { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] == key }
                    return false
                })
            }
            return .bool(false)
        case ".remove":
            if let nm = getNativeMap(args.first ?? .unit), args.count >= 2 {
                nm.remove(args[1])
                return args.first!
            }
            if case .structVal("Map", var fields) = args.first, case .array(var arr)? = fields["entries"],
               args.count >= 2 {
                let key = args[1]
                arr.removeAll { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] == key }
                    return false
                }
                fields["entries"] = .array(arr)
                return .structVal("Map", fields)
            }
            return args.first ?? .unit
        case ".keys":
            if let nm = getNativeMap(args.first ?? .unit) { return makeArray(nm.keys) }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                return makeArray(arr.compactMap { entry in
                    if case .tuple(let kv) = entry, kv.count >= 1 { return kv[0] }
                    return nil
                })
            }
            return .array([])
        case ".values":
            if let nm = getNativeMap(args.first ?? .unit) { return makeArray(nm.values) }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                return makeArray(arr.compactMap { entry in
                    if case .tuple(let kv) = entry, kv.count >= 2 { return kv[1] }
                    return nil
                })
            }
            return .array([])
        case ".entries":
            if let nm = getNativeMap(args.first ?? .unit) { return makeArray(nm.toEntries()) }
            if case .structVal("Map", let fields) = args.first, case .array(let arr)? = fields["entries"] {
                return .array(arr)
            }
            return .array([])

        // ── Option methods ──────────────────────────────────────
        case ".is_some":
            if case .enumVal("Option", 0, _) = args.first { return .bool(true) }
            return .bool(false)
        case ".is_none":
            if case .enumVal("Option", 1, _) = args.first { return .bool(true) }
            if case .enumVal("Option", 0, _) = args.first { return .bool(false) }
            return .bool(true)
        case ".unwrap":
            if case .enumVal(_, 0, let inner) = args.first { return inner }
            output.append("PANIC: called unwrap on None/Err")
            halted = true
            return .unit
        case ".unwrap_or":
            if case .enumVal(_, 0, let inner) = args.first { return inner }
            return args.count > 1 ? args[1] : .unit
        case ".expect":
            if case .enumVal(_, 0, let inner) = args.first { return inner }
            let msg = args.count > 1 ? args[1].displayString : "expect failed"
            output.append("PANIC: \(msg)")
            halted = true
            return .unit

        // ── Result methods ──────────────────────────────────────
        case ".is_ok":
            if case .enumVal("Result", 0, _) = args.first { return .bool(true) }
            return .bool(false)
        case ".is_err":
            if case .enumVal("Result", 1, _) = args.first { return .bool(true) }
            return .bool(false)
        case ".map_err":
            return args.first ?? .unit // No-op in interpreter

        // ── Iterator / functional chain ─────────────────────────
        case ".map":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                let result: MirValue = makeArray(elems.map { dispatchCallDirect(cls.name, args: [$0] + cls.captures) })
                lastCallFinalParams = saved
                return result
            }
            return args.first ?? .array([])
        case ".filter":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                let result: MirValue = makeArray(elems.filter { dispatchCallDirect(cls.name, args: [$0] + cls.captures).asBool ?? false })
                lastCallFinalParams = saved
                return result
            }
            return args.first ?? .array([])
        case ".collect":
            return args.first ?? .array([])
        case ".for_each":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                for elem in elems { _ = dispatchCallDirect(cls.name, args: [elem] + cls.captures) }
                lastCallFinalParams = saved
            }
            return .unit
        case ".enumerate":
            if case .array(let elems) = args.first {
                return makeArray(elems.enumerated().map { .tuple([.int($0.offset), $0.element]) })
            }
            return .array([])
        case ".any":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                let result = elems.contains { dispatchCallDirect(cls.name, args: [$0] + cls.captures).asBool ?? false }
                lastCallFinalParams = saved
                return .bool(result)
            }
            return .bool(false)
        case ".all":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                let result = elems.allSatisfy { dispatchCallDirect(cls.name, args: [$0] + cls.captures).asBool ?? false }
                lastCallFinalParams = saved
                return .bool(result)
            }
            return .bool(true)
        case ".position":
            if case .array(let elems) = args.first, let cls = extractClosure(args.dropFirst().first ?? .unit) {
                let saved = lastCallFinalParams
                for (i, e) in elems.enumerated() {
                    if dispatchCallDirect(cls.name, args: [e] + cls.captures).asBool ?? false {
                        lastCallFinalParams = saved
                        return .enumVal("Option", 0, .int(i))
                    }
                }
                lastCallFinalParams = saved
            }
            return .enumVal("Option", 1, .unit)

        // ── Char methods ────────────────────────────────────────
        case ".is_alphanumeric":
            if case .char(let c) = args.first { return .bool(c.isLetter || c.isNumber) }
            return .bool(false)
        case ".is_digit":
            if case .char(let c) = args.first { return .bool(c.isNumber) }
            return .bool(false)
        case ".is_uppercase":
            if case .char(let c) = args.first { return .bool(c.isUppercase) }
            return .bool(false)
        case ".is_lowercase":
            if case .char(let c) = args.first { return .bool(c.isLowercase) }
            return .bool(false)

        // ── Sha256 ───────────────────────────────────────────────
        case ".update":
            if case .structVal("Sha256", var fields) = args.first {
                var accumulated: [MirValue] = []
                if case .array(let existing) = fields["_data"] { accumulated = Array(existing) }
                if args.count > 1 {
                    switch args[1] {
                    case .array(let bytes): accumulated.append(contentsOf: bytes)
                    case .string(let s): accumulated.append(contentsOf: s.utf8.map { .int(Int($0)) })
                    default: break
                    }
                }
                fields["_data"] = makeArray(accumulated)
                return .structVal("Sha256", fields)
            }
            return args.first ?? .unit
        case ".finalize":
            if case .structVal("Sha256", let fields) = args.first,
               case .array(let dataArray) = fields["_data"] {
                let bytes = dataArray.compactMap { v -> UInt8? in if case .int(let i) = v { return UInt8(truncatingIfNeeded: i) } else { return nil } }
                let hash = MIRInterpreter.computeSha256(bytes)
                return makeArray(hash.map { .int(Int($0)) })
            }
            return makeArray((0..<32).map { _ in MirValue.int(0) })
        case ".finalize_hex", ".hexdigest":
            if case .structVal("Sha256", let fields) = args.first,
               case .array(let dataArray) = fields["_data"] {
                let bytes = dataArray.compactMap { v -> UInt8? in if case .int(let i) = v { return UInt8(truncatingIfNeeded: i) } else { return nil } }
                let hash = MIRInterpreter.computeSha256(bytes)
                return .string(hash.map { String(format: "%02x", $0) }.joined())
            }
            return .string("0000000000000000000000000000000000000000000000000000000000000000")

        // ── Stdlib runtime builtins (free functions) ────────────
        case "args":
            return makeArray(runtimeArgs.map { .string($0) })
        case "raw_arg_count", "std::args::raw_arg_count", "std::env::raw_arg_count":
            return .int(runtimeArgs.count)
        case "tg_get_argc":
            return .int(runtimeArgs.count)
        case "tg_get_argv":
            return makeArray(runtimeArgs.map { .string($0) })
        case "_tg_arg":
            if let idx = args.first?.asInt, idx >= 0 && idx < runtimeArgs.count {
                return .string(runtimeArgs[idx])
            }
            return .string("")
        case "_tg_arg_copy", "raw_arg_copy", "std::args::raw_arg_copy", "std::env::raw_arg_copy":
            if let idx = args.first?.asInt, idx >= 0 && idx < runtimeArgs.count {
                return .string(runtimeArgs[idx])
            }
            return .string("")
        case "raw_arg", "std::args::raw_arg", "std::env::raw_arg":
            if let idx = args.first?.asInt, idx >= 0 && idx < runtimeArgs.count {
                return .enumVal("Option", 0, .string(runtimeArgs[idx]))
            }
            return .enumVal("Option", 1, .unit)
        case "raw_arg_unchecked", "std::args::raw_arg_unchecked", "std::env::raw_arg_unchecked":
            if let idx = args.first?.asInt, idx >= 0 && idx < runtimeArgs.count {
                return .string(runtimeArgs[idx])
            }
            return .string("")
        case "read_to_vec", "fs::read_to_vec", "std::fs::read_to_vec":
            if let path = args.first?.displayString {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    return .enumVal("Result", 0, makeArray(data.map { .int(Int($0)) }))
                } catch {
                    return .enumVal("Result", 1, .string("cannot read file: \(path)"))
                }
            }
            return .enumVal("Result", 1, .string("read_to_vec: no path"))
        case "read_file_text_direct", "driver::read_file_text_direct":
            if let path = args.first?.displayString {
                do {
                    let text = try String(contentsOfFile: path, encoding: .utf8)
                    return .string(text)
                } catch {
                    return .string("")
                }
            }
            return .string("")
        case "read_file", "fs::read_to_string", "fs::read_file", "std::fs::read_file", "std::fs::read_to_string":
            if let path = args.first?.displayString {
                do {
                    let contents = try String(contentsOfFile: path, encoding: .utf8)
                    return .enumVal("Result", 0, .string(contents))
                } catch {
                    fputs("[read_file] failed to read '\(path)': \(error.localizedDescription)\n", stderr)
                    return .enumVal("Result", 1, .string("cannot read file: \(path): \(error.localizedDescription)"))
                }
            }
            return .enumVal("Result", 1, .string("read_file: no path"))
        case "write_file", "fs::write_file", "fs::write_string", "fs::write_file_string",
             "std::fs::write_file", "std::fs::write_string", "std::fs::write_file_string":
            if args.count >= 2, let path = args.first?.displayString {
                let contents = args[1].displayString
                do {
                    try contents.write(toFile: path, atomically: true, encoding: .utf8)
                    return .enumVal("Result", 0, .unit)
                } catch {
                    return .enumVal("Result", 1, .string("write error: \(error)"))
                }
            }
            return .enumVal("Result", 1, .string("write_file: bad args"))
           case "write_file_bytes", "fs::write_file_bytes", "std::fs::write_file_bytes",
               "write_file_bytes_owned", "fs::write_file_bytes_owned", "std::fs::write_file_bytes_owned":
            if args.count >= 2, let path = args.first?.displayString {
                let bytesVal = args[1]
                var rawBytes: [UInt8] = []
                if case .array(let elements) = bytesVal {
                    rawBytes.reserveCapacity(elements.count)
                    var coercedCount = 0
                    var coercedKinds: [String: Int] = [:]
                    var coercedSamples: [String] = []
                    var index = 0
                    for elem in elements {
                        if let byte = elem.asInt {
                            rawBytes.append(UInt8(truncatingIfNeeded: byte))
                        } else {
                            rawBytes.append(0)
                            coercedCount += 1
                            let kind = valueKindName(elem)
                            coercedKinds[kind, default: 0] += 1
                            if coercedSamples.count < 8 {
                                coercedSamples.append("\(index):\(kind)=\(String(elem.description.prefix(80)))")
                            }
                        }
                        index += 1
                    }
                    if coercedCount > 0 {
                        let sortedKinds = coercedKinds.sorted { lhs, rhs in
                            if lhs.value == rhs.value { return lhs.key < rhs.key }
                            return lhs.value > rhs.value
                        }
                        let kindSummary = sortedKinds.prefix(5).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                        let sampleSummary = coercedSamples.joined(separator: " | ")
                        fputs("[write_file_bytes] warning: coerced \(coercedCount) non-byte values to zero for \(path); kinds=[\(kindSummary)]; samples=[\(sampleSummary)]\n", stderr)
                    }
                } else if case .byteBuffer(let bb) = bytesVal {
                    rawBytes = bb.data
                }
                let data = Data(rawBytes)
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    // Make executable if it looks like a binary (not .o)
                    if !path.hasSuffix(".o") {
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o755], ofItemAtPath: path)
                    }
                    return .enumVal("Result", 0, .unit)
                } catch {
                    return .enumVal("Result", 1, .string("write error: \(error)"))
                }
            }
            return .enumVal("Result", 1, .string("write_file_bytes: bad args"))
        case "file_exists", "path_exists", "fs::file_exists", "fs::path_exists",
             "std::fs::file_exists", "std::fs::path_exists":
            if let path = args.first?.displayString {
                return .bool(FileManager.default.fileExists(atPath: path))
            }
            return .bool(false)
        case "mkdir_p", "create_dir_all", "fs::create_dir_all", "fs::mkdir_p",
             "std::fs::create_dir_all", "std::fs::mkdir_p":
            if let path = args.first?.displayString {
                do {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                } catch {
                    fputs("[mkdir_p] failed to create directory '\(path)': \(error.localizedDescription)\n", stderr)
                    return .enumVal("Result", 1, .string("mkdir failed: \(error.localizedDescription)"))
                }
            }
            return .enumVal("Result", 0, .unit)
        case "list_directory", "list_dir", "read_dir",
             "fs::list_directory", "fs::list_dir", "fs::read_dir",
             "std::fs::list_directory", "std::fs::list_dir", "std::fs::read_dir":
            if let path = args.first?.displayString {
                let entries: [String]
                do {
                    entries = try FileManager.default.contentsOfDirectory(atPath: path)
                } catch {
                    fputs("[list_directory] failed to list '\(path)': \(error.localizedDescription)\n", stderr)
                    return .enumVal("Result", 1, .string("cannot list directory: \(error.localizedDescription)"))
                }
                let renderedEntries = entries.map { entryName -> MirValue in
                    let entryPath = path.hasSuffix("/") ? path + entryName : path + "/" + entryName
                    var isDirectoryFlag = ObjCBool(false)
                    let exists = FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDirectoryFlag)
                    let isDirectory = exists && isDirectoryFlag.boolValue
                    let attrs: [FileAttributeKey: Any]?
                    do {
                        attrs = try FileManager.default.attributesOfItem(atPath: entryPath)
                    } catch {
                        fputs("[list_directory] warning: could not read attributes for '\(entryPath)': \(error.localizedDescription)\n", stderr)
                        attrs = nil
                    }
                    let attrType = attrs?[.type] as? FileAttributeType
                    let isSymlink = attrType == .typeSymbolicLink
                    let isFile = exists && !isDirectory
                    let sizeValue = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                    let readOnly = exists && !FileManager.default.isWritableFile(atPath: entryPath)
                    let metadata = MirValue.structVal("FileMetadata", [
                        "size": .int(sizeValue),
                        "is_dir": .bool(isDirectory),
                        "is_file": .bool(isFile),
                        "is_symlink": .bool(isSymlink),
                        "read_only": .bool(readOnly),
                        "modified_time": .int(0),
                        "accessed_time": .int(0),
                        "created_time": .int(0),
                    ])
                    return .structVal("DirEntry", [
                        "name": .string(entryName),
                        "path": .string(entryPath),
                        "metadata": metadata,
                        "is_dir": .bool(isDirectory),
                        "is_file": .bool(isFile),
                        "is_symlink": .bool(isSymlink),
                    ])
                }
                return .enumVal("Result", 0, makeArray(renderedEntries))
            }
            return .enumVal("Result", 1, .string("cannot list directory"))
        case "delete_file", "remove_file", "fs::remove_file", "fs::delete_file",
             "std::fs::remove_file", "std::fs::delete_file":
            if let path = args.first?.displayString {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    fputs("[delete_file] failed to remove '\(path)': \(error.localizedDescription)\n", stderr)
                    return .enumVal("Result", 1, .string("delete failed: \(error.localizedDescription)"))
                }
            }
            return .enumVal("Result", 0, .unit)
        case "fs::path_join", "std::fs::path_join":
            return .string(args.map(\.displayString).joined(separator: "/"))
        case "run_command", "process::run_command", "std::process::run_command":
            // run_command(program: String, args: Vec<String>) -> Result<String, String>
            guard args.count >= 2,
                  case .string(let program) = args[0],
                  case .array(let argVals) = args[1] else {
                return .enumVal("Result", 1, .string("run_command: bad arguments"))
            }
            let cmdArgs = argVals.compactMap { val -> String? in
                if case .string(let s) = val { return s }
                return nil
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: program)
            proc.arguments = cmdArgs
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    return .enumVal("Result", 0, .string(outStr))
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    return .enumVal("Result", 1, .string(errStr.isEmpty ? "exit \(proc.terminationStatus)" : errStr))
                }
            } catch {
                return .enumVal("Result", 1, .string(error.localizedDescription))
            }
        case "panic":
            let msg = args.first?.displayString ?? "panic"
            output.append("PANIC: \(msg)")
            halted = true
            return .unit
        case "to_string":
            return .string(args.first?.displayString ?? "")
        case "to_float":
            if let s = args.first?.displayString, let f = Double(s) { return .float(f) }
            return .float(0.0)
        case "std::env::args":
            return makeArray(runtimeArgs.map { .string($0) })
        case "std::env::home_dir":
            return .string(FileManager.default.homeDirectoryForCurrentUser.path)
        case "std::env::var", "std::env::get_env":
            if let name = args.first?.displayString {
                if let val = ProcessInfo.processInfo.environment[name] {
                    return .enumVal("Option", 0, .string(val))
                }
            }
            return .enumVal("Option", 1, .unit)

        // ── Native tokenize delegation ──────────────────────────
        // Runs the Swift Lexer at native speed and converts tokens to TG MirValues
        // matching the tg_compiler TokenKind/Token/LexResult types exactly.
        case "tokenize", "lex":
            guard case .string(let source) = args.first else { return .unit }
            let path: String = {
                if args.count >= 2, case .string(let p) = args[1] { return p }
                return ""
            }()
            return nativeTokenize(source: source, path: path)
        case "tokenize_impl":
            guard case .structVal(let lexerName, var lexerFields) = args.first,
                  case .string(let source)? = lexerFields["source"] else {
                return .unit
            }
            let path: String = {
                if case .string(let p)? = lexerFields["path"] { return p }
                return ""
            }()
            let result = nativeTokenize(source: source, path: path)
            if case .structVal("LexResult", let resultFields) = result {
                lexerFields["tokens"] = resultFields["tokens"] ?? .array([])
                lexerFields["errors"] = resultFields["errors"] ?? .array([])
                lexerFields["pos"] = .int(source.utf8.count)
                recordMutatedFirstArg(.structVal(lexerName, lexerFields))
            }
            return result

        case "diag_has_errors":
            // Check DiagBag.has_errors field
            if case .structVal("DiagBag", let fields) = args.first {
                if case .bool(let b)? = fields["has_errors"] { return .bool(b) }
                if case .array(let diags)? = fields["diagnostics"] { return .bool(!diags.isEmpty) }
            }
            if case .structVal(_, let fields) = args.first {
                if case .bool(let b)? = fields["has_errors"] { return .bool(b) }
            }
            return .bool(false)

        // ── FFI stubs (no-ops in interpreter) ──────────────────
        case "sched_yield":
            return .int(0)
        case "usleep":
            return .int(0)
        case "nanosleep":
            return .int(0)
        case "pthread_create", "pthread_join", "pthread_detach",
             "pthread_mutex_init", "pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_destroy",
             "pthread_rwlock_init", "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "pthread_rwlock_unlock", "pthread_rwlock_destroy",
             "pthread_cond_init", "pthread_cond_wait", "pthread_cond_signal", "pthread_cond_broadcast", "pthread_cond_destroy",
             "pthread_barrier_init", "pthread_barrier_wait", "pthread_barrier_destroy",
             "pthread_self", "pthread_attr_init", "pthread_attr_destroy",
             "pthread_attr_setstacksize", "pthread_attr_setdetachstate":
            return .int(0)

        // ── Native GUI (cross-platform) ──────────────────────
        case ".poll_event":
            // Lazily create the native window from the SoftwareWindow struct
            if case .structVal(_, let fields) = args.first {
                let title = fields["title"]?.displayString ?? "TG App"
                let w = fields["width"]?.asInt ?? 384
                let h = fields["height"]?.asInt ?? 392
                TGNativeGUI.shared.ensureWindow(title: title, width: w, height: h)
            }
            return TGNativeGUI.shared.pollEvent()

        case ".surface", "surface_offscreen":
            let gui = TGNativeGUI.shared
            gui.createSurface()
            let surface = MirValue.structVal("NativeSurface", [
                "width": .int(gui.windowWidth),
                "height": .int(gui.windowHeight)
            ])
            return .enumVal("Result", 0, surface)

        case ".begin_frame":
            let gui = TGNativeGUI.shared
            if !gui.hasActiveCanvas { gui.createSurface() }
            let canvas = MirValue.structVal("NativeCanvas", [
                "width": .int(gui.windowWidth),
                "height": .int(gui.windowHeight)
            ])
            return .enumVal("Result", 0, canvas)

        case ".end_frame":
            return .enumVal("Result", 0, .unit)

        case ".present":
            TGNativeGUI.shared.present()
            return .enumVal("Result", 0, .unit)

        case ".request_redraw":
            TGNativeGUI.shared.requestRedraw()
            return .unit

        case ".fill_rect":
            // args: [self, Rect, &Paint]
            if args.count > 2,
               case .structVal(_, let rect) = args[1] {
                let x = rect["x"]?.asFloat ?? 0
                let y = rect["y"]?.asFloat ?? 0
                let w = rect["w"]?.asFloat ?? rect["width"]?.asFloat ?? 0
                let h = rect["h"]?.asFloat ?? rect["height"]?.asFloat ?? 0
                let (cr, cg, cb, ca) = extractPaintColor(args[2])
                TGNativeGUI.shared.fillRect(x: x, y: y, w: w, h: h, r: cr, g: cg, b: cb, a: ca)
            }
            return .unit

        case ".fill_rrect":
            // args: [self, RRect, &Paint]
            if args.count > 2,
               case .structVal(_, let rr) = args[1] {
                let x = rr["x"]?.asFloat ?? 0
                let y = rr["y"]?.asFloat ?? 0
                let w = rr["width"]?.asFloat ?? 0
                let h = rr["height"]?.asFloat ?? 0
                let radius = rr["radius"]?.asFloat ?? 0
                let (cr, cg, cb, ca) = extractPaintColor(args[2])
                TGNativeGUI.shared.fillRRect(x: x, y: y, w: w, h: h, radius: radius,
                                             r: cr, g: cg, b: cb, a: ca)
            }
            return .unit

        case ".draw_glyph_run":
            // args: [self, &GlyphRun, f32 x, f32 y, &Paint]
            if args.count > 4,
               case .structVal(_, let run) = args[1] {
                let x = args[2].asFloat ?? 0
                let y = args[3].asFloat ?? 0
                let (cr, cg, cb, ca) = extractPaintColor(args[4])
                let opaqueId = run["_opaque"]?.asInt ?? 0
                if let (text, size) = TGNativeGUI.shared.getTextRun(opaqueId) {
                    TGNativeGUI.shared.drawText(text, x: x, y: y, size: size,
                                                r: cr, g: cg, b: cb, a: ca)
                }
            }
            return .unit

        case ".stroke_rect", ".fill_path", ".stroke_path", ".draw_image",
             ".clip_rect", ".clip_path", ".save", ".restore", ".transform":
            return .unit

        case "text::font_db_new", "font_db_new":
            // Return a FontDb with one system font entry so shape() doesn't fail
            let fontEntry = MirValue.structVal("_FontEntry", [
                "id": .structVal("FontId", ["value": .int(0)]),
                "data": .array([]),
                "units_per_em": .int(1000)
            ])
            return .structVal("FontDb", [
                "_fonts": .array([fontEntry]),
                "_next_id": .int(1)
            ])

        case "text::shape", "shape":
            // Use CoreText for real text shaping
            if args.count >= 4 {
                let text = args[1].displayString
                var fontSize = 16.0
                if case .structVal(_, let style) = args[2] {
                    fontSize = style["size"]?.asFloat ?? 16.0
                }
                let (_, glyphRun) = TGNativeGUI.shared.shapeText(text, size: fontSize)
                return .enumVal("Result", 0, glyphRun)
            }
            return .enumVal("Result", 1, .string("shape: invalid args"))

        case "text::default_shaping_opts", "default_shaping_opts":
            return .structVal("ShapingOpts", [
                "direction": .enumVal("Direction", 0, .unit),
                "language": .enumVal("Option", 1, .unit)
            ])

        case "text::layout", "layout":
            // Layout text by shaping and wrapping lines.
            // Args: db, text, style, max_width, opts
            if args.count >= 4 {
                let text = args[1].displayString
                var fontSize = 16.0
                if case .structVal(_, let style) = args[2] { fontSize = style["size"]?.asFloat ?? 16.0 }
                let _ = args.count > 3 ? (args[3].asFloat ?? 10000.0) : 10000.0
                let (_, glyphRun) = TGNativeGUI.shared.shapeText(text, size: fontSize)
                // Extract bounds from the glyph run
                var runWidth = 0.0
                if case .structVal(_, let rf) = glyphRun, case .structVal(_, let bf) = rf["bounds"] {
                    runWidth = bf["w"]?.asFloat ?? Double(text.count) * fontSize * 0.6
                }
                let lineHeight = fontSize * 1.2
                let lineRect = MirValue.structVal("Rect", [
                    "x": .float(0), "y": .float(0), "w": .float(runWidth), "h": .float(lineHeight)])
                let line = MirValue.structVal("TextLine", [
                    "run": glyphRun, "baseline_y": .float(fontSize * 0.8), "rect": lineRect])
                let bounds = MirValue.structVal("Rect", [
                    "x": .float(0), "y": .float(0), "w": .float(runWidth), "h": .float(lineHeight)])
                let layout = MirValue.structVal("TextLayout", [
                    "lines": .array([line]), "bounds": bounds])
                return .enumVal("Result", 0, layout)
            }
            return .enumVal("Result", 1, .string("layout: invalid args"))

        case ".set_title":
            return .unit
        case ".clipboard_set", ".clipboard_get":
            return .unit
        case ".id":
            return .structVal("WindowId", ["value": .int(0)])
        case ".size":
            let gui = TGNativeGUI.shared
            return .tuple([.int(gui.windowWidth), .int(gui.windowHeight)])
        case ".dpi":
            return .structVal("Dpi", ["scale": .float(1.0)])

        default:
            // Check dispatch cache first (avoids repeated name resolution)
            if isMethodName(name), !args.isEmpty, let typeName = receiverTypeName(args[0]) {
                if let cachedIdx = methodDispatchCache[name]?[typeName] {
                    recordCallSiteResolution(name, args: args, fnIdx: cachedIdx, site: siteKey)
                    return deferResolvedUserCall(cachedIdx, args: args)
                }
                for candidate in resolveFunctionCandidates(name: name, args: args) {
                    if let idx = functionIndex[candidate] {
                        var perType = methodDispatchCache[name] ?? [:]
                        perType[typeName] = idx
                        methodDispatchCache[name] = perType
                        recordCallSiteResolution(name, args: args, fnIdx: idx, site: siteKey)
                        return deferResolvedUserCall(idx, args: args)
                    }
                }
            } else if let cachedIdx = dispatchCache[name] {
                recordCallSiteResolution(name, args: args, fnIdx: cachedIdx, site: siteKey)
                return deferResolvedUserCall(cachedIdx, args: args)
            }
            for candidate in resolveFunctionCandidates(name: name, args: args) {
                if let idx = functionIndex[candidate] {
                    dispatchCache[name] = idx
                    recordCallSiteResolution(name, args: args, fnIdx: idx, site: siteKey)
                    return deferResolvedUserCall(idx, args: args)
                }
            }
            // Try enum variant construction: TypeName::VariantName(args)
            if name.contains("::") {
                let parts = name.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let variantName = parts.last!
                    // Try all possible type name prefixes (e.g. "app::PaintKind" → "PaintKind")
                    var typeCandidates = [parts.dropLast().joined(separator: "::")]
                    if parts.count > 2, let bare = parts.dropLast().last {
                        typeCandidates.append(bare)
                    }
                    var tdCandidates: [Int] = []
                    var seenTypeDefs: Set<Int> = []
                    for typeName in typeCandidates {
                        let tdIndices: [Int]
                        if let exact = typeDefIndex[typeName] {
                            tdIndices = exact
                        } else {
                            let scanned = program.typeDefs.enumerated().compactMap { index, td in
                                if td.name == typeName || td.name.hasSuffix("::\(typeName)") {
                                    return index
                                }
                                return nil
                            }
                            // Cache the result so subsequent lookups are O(1)
                            if !scanned.isEmpty {
                                typeDefIndex[typeName] = scanned
                            }
                            tdIndices = scanned
                        }
                        for tdIdx in tdIndices {
                            if seenTypeDefs.insert(tdIdx).inserted {
                                tdCandidates.append(tdIdx)
                            }
                        }
                    }
                    for tdIdx in tdCandidates {
                        if case .enumDef(let variants) = program.typeDefs[tdIdx].kind {
                            // Try exact arity first, then fall back to the variant name alone.
                            let idx: Int? = variants.firstIndex(where: { $0.0 == variantName && $0.1.count == args.count })
                                ?? variants.firstIndex(where: { $0.0 == variantName })
                                ?? variants.firstIndex(where: { $0.0.hasSuffix(variantName) && $0.0 != variantName && $0.1.count == args.count })
                                ?? variants.firstIndex(where: { $0.0.hasSuffix(variantName) && $0.0 != variantName })
                            if let idx = idx {
                                let payload: MirValue
                                if args.isEmpty {
                                    payload = .unit
                                } else if args.count == 1 {
                                    payload = args[0]
                                } else {
                                    payload = .tuple(args)
                                }
                                return .enumVal(program.typeDefs[tdIdx].name, idx, payload)
                            }
                        }
                    }
                }
            }
            let stack = callStack.suffix(12).map { frame in
                program.functions[frame.functionIdx].name
            }.joined(separator: " -> ")
            let msg: String
            if stack.isEmpty {
                msg = "INTERPRETER: unknown function '\(name)' with \(args.count) args"
            } else {
                msg = "INTERPRETER: unknown function '\(name)' with \(args.count) args [stack: \(stack)]"
            }
            output.append(msg)
            runtimeError = msg
            halted = true
            return .unit
        }
    }

    /// Call dispatchCall but if it defers a user function, call it directly.
    /// Used for closure invocations from .map/.filter/.any/.all etc. where
    /// we need the result immediately (not via the trampoline).
    private func dispatchCallDirect(_ name: String, args: [MirValue]) -> MirValue {
        let result = dispatchCall(name, args: args)
        if hasDeferredCall {
            hasDeferredCall = false
            return callFunction(program.functions[deferredFnIdx], args: deferredArgs)
        }
        return result
    }

    // MARK: - Helpers

    /// Create a new native-backed Map/Set and return a structVal with embedded _nid.
    private func makeNativeMap() -> MirValue {
        let id = nextNativeMapId
        nextNativeMapId += 1
        nativeMapStore[id] = MirNativeMap()
        nativeMapRefCount[id] = 1
        return .structVal("Map", ["entries": .array([]), "_nid": .int(id)])
    }

    /// Release native maps referenced by a MirValue, recursing into nested structures.
    /// Uses an iterative worklist to avoid stack overflow on deep values.
    private func releaseNativeMaps(_ value: MirValue) {
        var stack: [MirValue] = [value]
        while let current = stack.popLast() {
            switch current {
            case .structVal("Map", let fields):
                if case .int(let nid)? = fields["_nid"] {
                    let newCount = (nativeMapRefCount[nid] ?? 1) - 1
                    if newCount <= 0 {
                        // Cascade: scan map entries for nested maps before removing
                        if let nm = nativeMapStore[nid] {
                            for entry in nm.dict.values {
                                stack.append(entry.key)
                                stack.append(entry.value)
                            }
                        }
                        nativeMapStore.removeValue(forKey: nid)
                        nativeMapRefCount.removeValue(forKey: nid)
                    } else {
                        nativeMapRefCount[nid] = newCount
                    }
                }
            case .structVal(_, let fields):
                for (_, v) in fields {
                    switch v {
                    case .structVal(_, _), .enumVal(_, _, _), .array(_): stack.append(v)
                    default: break
                    }
                }
            case .enumVal(_, _, let payload):
                switch payload {
                case .structVal(_, _), .enumVal(_, _, _), .tuple(_), .array(_): stack.append(payload)
                default: break
                }
            case .tuple(let elems):
                for e in elems {
                    switch e {
                    case .structVal(_, _), .enumVal(_, _, _): stack.append(e)
                    default: break
                    }
                }
            case .array(let arr):
                // Only scan arrays that could contain maps (check first element type)
                if let first = arr.first {
                    switch first {
                    case .structVal(_, _), .enumVal(_, _, _), .tuple(_):
                        for e in arr { stack.append(e) }
                    default: break
                    }
                }
            default: break
            }
        }
    }

    /// Retain (increment ref count for) native maps referenced by a MirValue.
    private func retainNativeMaps(_ value: MirValue) {
        var stack: [MirValue] = [value]
        while let current = stack.popLast() {
            switch current {
            case .structVal("Map", let fields):
                if case .int(let nid)? = fields["_nid"] {
                    nativeMapRefCount[nid] = (nativeMapRefCount[nid] ?? 0) + 1
                }
            case .structVal(_, let fields):
                for (_, v) in fields {
                    switch v {
                    case .structVal(_, _), .enumVal(_, _, _), .array(_): stack.append(v)
                    default: break
                    }
                }
            case .enumVal(_, _, let payload):
                switch payload {
                case .structVal(_, _), .enumVal(_, _, _), .tuple(_), .array(_): stack.append(payload)
                default: break
                }
            case .tuple(let elems):
                for e in elems {
                    switch e {
                    case .structVal(_, _), .enumVal(_, _, _): stack.append(e)
                    default: break
                    }
                }
            case .array(let arr):
                if let first = arr.first {
                    switch first {
                    case .structVal(_, _), .enumVal(_, _, _), .tuple(_):
                        for e in arr { stack.append(e) }
                    default: break
                    }
                }
            default: break
            }
        }
    }

    /// Periodic garbage collection of unreachable native maps.
    private func gcNativeMaps() {
        guard nativeMapStore.count > 100 else { return }
        var reachable = Set<Int>()
        reachable.reserveCapacity(nativeMapStore.count)
        for i in 0..<localsStackTop {
            collectReachableMapIds(localsStack[i], into: &reachable)
        }
        let allIds = Array(nativeMapStore.keys)
        for id in allIds {
            if !reachable.contains(id) {
                nativeMapStore.removeValue(forKey: id)
                nativeMapRefCount.removeValue(forKey: id)
            }
        }
    }

    private func collectReachableMapIds(_ value: MirValue, into ids: inout Set<Int>) {
        var stack: [MirValue] = [value]
        while let current = stack.popLast() {
            switch current {
            case .structVal("Map", let fields):
                if case .int(let nid)? = fields["_nid"] {
                    if ids.insert(nid).inserted {
                        // Trace through native map entries for nested maps
                        if let nm = nativeMapStore[nid] {
                            for entry in nm.dict.values {
                                stack.append(entry.key)
                                stack.append(entry.value)
                            }
                        }
                    }
                }
            case .structVal(_, let fields):
                for (_, v) in fields {
                    switch v {
                    case .structVal(_, _), .enumVal(_, _, _), .array(_): stack.append(v)
                    default: break
                    }
                }
            case .enumVal(_, _, let payload):
                switch payload {
                case .structVal(_, _), .enumVal(_, _, _), .tuple(_), .array(_): stack.append(payload)
                default: break
                }
            case .tuple(let elems):
                for e in elems {
                    switch e {
                    case .structVal(_, _), .enumVal(_, _, _): stack.append(e)
                    default: break
                    }
                }
            case .array(let arr):
                if let first = arr.first {
                    switch first {
                    case .structVal(_, _), .enumVal(_, _, _), .tuple(_):
                        for e in arr { stack.append(e) }
                    default: break
                    }
                }
            default: break
            }
        }
    }

    /// Get the native map backing a structVal, if any.
    @inline(__always)
    private func getNativeMap(_ val: MirValue) -> MirNativeMap? {
        if case .structVal("Map", let fields) = val,
           case .int(let nid)? = fields["_nid"] {
            return nativeMapStore[nid]
        }
        return nil
    }

    private func materializeIterable(_ value: MirValue) -> MirValue {
        func setLikeKeys<S: Sequence>(from entries: S) -> [MirValue]? where S.Element == MirValue {
            var keys: [MirValue] = []
            for entry in entries {
                guard case .tuple(let kv) = entry, kv.count >= 2, kv[1] == .unit else {
                    return nil
                }
                keys.append(kv[0])
            }
            return keys
        }

        switch value {
        case .array, .byteBuffer, .string:
            return value
        case .structVal("Range", _), .structVal("RangeInclusive", _):
            return value
        default:
            break
        }

        if let nativeMap = getNativeMap(value) {
            let entries = nativeMap.toEntries()
            if let keys = setLikeKeys(from: entries) {
                return makeArray(keys)
            }
            return makeArray(entries)
        }

        if case .structVal("Map", let fields) = value,
           case .array(let entries)? = fields["entries"] {
            if let keys = setLikeKeys(from: entries) {
                return makeArray(keys)
            }
            return .array(entries)
        }

        return value
    }

    /// Write a modified value back to a Map entry (for get_mut tracking)
    private func updateMapEntry(mapPlace: MirPlace, key: MirValue, value: MirValue) {
        // Check for native map first
        let containerBase = getLocal(mapPlace.local)
        var mapVal: MirValue
        if mapPlace.projections.isEmpty {
            mapVal = containerBase
        } else {
            mapVal = containerBase
            for proj in mapPlace.projections {
                mapVal = projectValue(mapVal, proj)
            }
        }
        if let nativeMap = getNativeMap(mapVal) {
            nativeMap.insert(key, value)
            return
        }
        
        // Update the map entry
        if case .structVal("Map", var fields) = mapVal, case .array(var arr) = fields["entries"] {
            var found = false
            for i in 0..<arr.count {
                if case .tuple(let kv) = arr[i], kv.count >= 2, kv[0] == key {
                    arr[i] = .tuple([key, value])
                    found = true
                    break
                }
            }
            if !found {
                arr.append(.tuple([key, value]))
            }
            fields["entries"] = .array(arr)
            mapVal = .structVal("Map", fields)
            
            // Write the updated map back through the projections
            if mapPlace.projections.isEmpty {
                setLocal(mapPlace.local, mapVal)
            } else {
                let newBase = setProjected(containerBase, projections: mapPlace.projections, value: mapVal)
                setLocal(mapPlace.local, newBase)
            }
            
            // Propagate field copy changes up the chain
            propagateFieldCopy(mapPlace.local)
        }
    }
    
    /// After a local is modified, propagate changes through fieldCopyTracker and downcastTracker chains
    private func propagateFieldCopy(_ localId: LocalId, visited: Set<LocalId> = []) {
        guard let frame = callStack.last else { return }
        guard !visited.contains(localId) else { return }  // break cycles
        var visited = visited
        visited.insert(localId)
        
        // Propagate through field copy chain
        if let sourcePath = frame.fieldCopyTracker[localId] {
            let modifiedVal = getLocal(localId)
            var base = getLocal(sourcePath.local)
            base = setProjected(base, projections: sourcePath.projections, value: modifiedVal)
            setLocal(sourcePath.local, base)
            // Recursively propagate up
            propagateFieldCopy(sourcePath.local, visited: visited)
            return
        }
        
        // Propagate through downcast chain (e.g., Option::Some payload modification)
        if let downcast = frame.downcastTracker[localId] {
            let modifiedPayload = getLocal(localId)
            let enumVal = getLocal(downcast.enumLocal)
            // Reconstruct the enum with the modified payload
            if case .enumVal(let name, let idx, _) = enumVal, idx == downcast.variantIdx {
                let newEnum = MirValue.enumVal(name, idx, modifiedPayload)
                setLocal(downcast.enumLocal, newEnum)
                // Recursively propagate up
                propagateFieldCopy(downcast.enumLocal, visited: visited)
            }
        }
    }

    private func normalizedEnumPayload(enumTypeName: String, variantIdx: Int, inner: MirValue) -> MirValue {
        guard let shapes = enumPayloadShapes[enumTypeName],
              variantIdx >= 0, variantIdx < shapes.count else {
            return inner
        }

        switch shapes[variantIdx] {
        case .unit:
            return .unit
        case .namedStruct:
            return inner
        case .unnamed(let fieldCount):
            if fieldCount == 1 {
                return inner
            }
            return inner
        }
    }

    private func findFunction(_ name: String) -> MirFunction? {
        guard let idx = functionIndex[name] else { return nil }
        return program.functions[idx]
    }

    private func resolveFunctionCandidates(name: String, args: [MirValue]) -> [String] {
        // Fast path for simple names (no . prefix, no ::) — try exact match first,
        // then search for qualified variants (module::name) in the function index.
        if !name.hasPrefix(".") && !name.contains("::") {
            if functionIndex[name] != nil {
                return [name]
            }
            // Search for qualified names ending with "::name"
            let suffix = "::\(name)"
            var matches: [String] = []
            for key in functionIndex.keys {
                if key.hasSuffix(suffix) {
                    matches.append(key)
                }
            }
            return [name] + matches
        }

        var candidates: [String] = [name]

        if name.hasPrefix(".") {
            let method = String(name.dropFirst())
            candidates.append(method)

            if let recv = args.first {
                switch recv {
                case .structVal(let typeName, _):
                    candidates.append("\(typeName)::\(method)")
                    if typeName.contains("::") {
                        let parts = typeName.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                        if let last = parts.last {
                            candidates.append("\(last)::\(method)")
                        }
                    }
                case .enumVal(let typeName, _, _):
                    candidates.append("\(typeName)::\(method)")
                default:
                    break
                }
            }
        }

        if name.contains("::") {
            let parts = name.split(separator: ":").map(String.init).filter { !$0.isEmpty }
            if let last = parts.last {
                candidates.append(last)
            }
            if parts.count >= 2 {
                let lastTwo = parts.suffix(2).joined(separator: "::")
                candidates.append(lastTwo)
            }
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for c in candidates where !c.isEmpty {
            if seen.insert(c).inserted {
                deduped.append(c)
            }
        }
        return deduped
    }


    @inline(__always)

    private func getLocal(_ id: LocalId) -> MirValue {
        let idx = currentLocalsBase + id
        if id < currentLocalsCount && idx < localsStack.count {
            return localsStack[idx]
        }
        return .unit
    }

    @inline(__always)
    private func setLocal(_ id: LocalId, _ value: MirValue) {
        let idx = currentLocalsBase + id
        if id < currentLocalsCount {
            localsStack[idx] = value
        } else if idx >= localsStack.count {
            // Grow array dynamically when needed
            localsStack.append(contentsOf: repeatElement(.unit, count: idx - localsStack.count + 1))
            localsStack[idx] = value
        }
    }

    private func addTrace(_ fn: String, _ block: BlockId, _ kind: TraceKind, _ detail: String) {
        guard enableTrace else { return }
        trace.append(TraceEntry(function: fn, block: block, kind: kind, detail: detail))
    }

    /// Extract closure function name and captured values from a MirValue.
    /// Closures with captures are represented as .tuple([.fn(name), capture1, capture2, ...]).
    /// Closures without captures are just .fn(name).
    private func extractClosure(_ val: MirValue) -> (name: String, captures: [MirValue])? {
        if case .fn(let n) = val { return (n, []) }
        if case .tuple(let parts) = val, !parts.isEmpty, case .fn(let n) = parts[0] {
            return (n, Array(parts.dropFirst()))
        }
        return nil
    }

    /// Extract (r, g, b, a) color from a Paint MirValue.
    /// Paint { kind: PaintKind::Solid(Color { r, g, b, a }), ... }
    private func extractPaintColor(_ paint: MirValue) -> (Double, Double, Double, Double) {
        if case .structVal(_, let fields) = paint,
           case .enumVal(_, 0, let colorVal) = fields["kind"],  // PaintKind::Solid
           case .structVal(_, let c) = colorVal {
            let r = c["r"]?.asFloat ?? 0
            let g = c["g"]?.asFloat ?? 0
            let b = c["b"]?.asFloat ?? 0
            let a = c["a"]?.asFloat ?? 1
            return (r, g, b, a)
        }
        return (0, 0, 0, 1) // fallback: black
    }

    // MARK: - Native Tokenize

    /// Run the Swift Lexer at native speed and convert the result to TG MirValues
    /// matching tg_compiler's LexResult { tokens: Vec[Token], errors: Vec[(String,Span)] }.
    private func nativeTokenize(source: String, path: String = "") -> MirValue {
        let diags = DiagnosticBag()
        let lexer = Lexer(source: source, fileID: 0, diagnostics: diags)
        let rawTokens = lexer.lexPreservingTrivia()

        var mirTokens: [MirValue] = []
        var i = 0
        while i < rawTokens.count {
            let tok = rawTokens[i]
            switch tok.kind {
            case .whitespace, .comment:
                i += 1
                continue
            default:
                break
            }
            let (kindVal, consumed) = swiftTokenToTgKind(rawTokens, at: i)
            let lastTok = rawTokens[i + consumed - 1]
            let spanVal = Self.spanValue(file: path, start: tok.span.start, end: lastTok.span.end)
            mirTokens.append(.structVal("Token", [
                "kind": kindVal,
                "span": spanVal
            ]))
            i += consumed
        }
        return .structVal("LexResult", [
            "tokens": makeArray(mirTokens),
            "errors": .array([])
        ])
    }

    /// Map a Swift Token (possibly consuming the next token for multi-char operators) to a TG TokenKind MirValue.
    /// Returns (tokenKindMirValue, numberOfSwiftTokensConsumed).
    private func swiftTokenToTgKind(_ tokens: [Token], at i: Int) -> (MirValue, Int) {
        let tok = tokens[i]

        // Multi-token combinations (must be adjacent — no whitespace gap)
        if i + 1 < tokens.count {
            let next = tokens[i + 1]
            if tok.span.end == next.span.start {
                switch (tok.kind, next.kind) {
                case (.amp, .kwMut):  return (tkEnum(95), 2)   // &mut → AmpMut
                case (.pipe, .gt):    return (tkEnum(97), 2)   // |>   → PipeArrow
                case (.star, .star):  return (tkEnum(107), 2)  // **   → DoubleStar
                case (.amp, .eq):     return (tkEnum(115), 2)  // &=   → AmpEq
                case (.pipe, .eq):    return (tkEnum(116), 2)  // |=   → PipeEq
                case (.shl, .eq):     return (tkEnum(118), 2)  // <<=  → ShlEq
                case (.shr, .eq):     return (tkEnum(119), 2)  // >>=  → ShrEq
                default: break
                }
            }
        }

        switch tok.kind {
        // ── Literals ──
        case .integer(let s):    return (tkEnum(0, .int(MIRLowering.parseInt(s))), 1)
        case .float(let s):      return (tkEnum(1, .float(Double(s.replacingOccurrences(of: "_", with: "")) ?? 0)), 1)
        case .string(let s):     return (tkEnum(2, .string(s)), 1)
        case .char(let c):       return (tkEnum(3, .char(c)), 1)
        // ── Identifier (with TG-extra-keyword post-processing) ──
        case .ident(let s):      return (identToTgKind(s), 1)
        // ── Doc comment ──
        case .docComment(let s): return (tkEnum(5, .string(s)), 1)
        // ── Core keywords ──
        case .kwDef:       return (tkEnum(6), 1)
        case .kwEnd:       return (tkEnum(7), 1)
        case .kwDo:        return (tkEnum(8), 1)
        case .kwIf:        return (tkEnum(9), 1)
        case .kwElsif:     return (tkEnum(10), 1)
        case .kwElse:      return (tkEnum(11), 1)
        case .kwWhile:     return (tkEnum(12), 1)
        case .kwFor:       return (tkEnum(13), 1)
        case .kwIn:        return (tkEnum(14), 1)
        case .kwLoop:      return (tkEnum(15), 1)
        case .kwMatch:     return (tkEnum(16), 1)
        case .kwWhen:      return (tkEnum(17), 1)
        case .kwThen:      return (tkEnum(18), 1)
        case .kwUnless:    return (tkEnum(19), 1)
        case .kwUntil:     return (tkEnum(20), 1)
        case .kwLet:       return (tkEnum(21), 1)
        case .kwMut:       return (tkEnum(22), 1)
        case .kwReturn:    return (tkEnum(23), 1)
        case .kwBreak:     return (tkEnum(24), 1)
        case .kwNext:      return (tkEnum(25), 1)
        case .kwStruct:    return (tkEnum(26), 1)
        case .kwEnum:      return (tkEnum(27), 1)
        case .kwTrait:     return (tkEnum(28), 1)
        case .kwImpl:      return (tkEnum(29), 1)
        case .kwModule, .kwMod: return (tkEnum(30), 1)
        case .kwUse:       return (tkEnum(31), 1)
        case .kwAs:        return (tkEnum(32), 1)
        case .kwPub:       return (tkEnum(33), 1)
        case .kwMacro:     return (tkEnum(35), 1)
        case .kwWhere:     return (tkEnum(36), 1)
        case .kwTrue:      return (tkEnum(37), 1)
        case .kwFalse:     return (tkEnum(38), 1)
        case .kwSelfValue: return (tkEnum(40), 1)   // self → Self_
        case .kwSelfTy:    return (tkEnum(41), 1)   // Self → SelfType
        case .kwPre:       return (tkEnum(48), 1)
        case .kwPost:      return (tkEnum(49), 1)
        case .kwInvariant: return (tkEnum(50), 1)
        case .kwCap:       return (tkEnum(51), 1)
        case .kwUnsafe:    return (tkEnum(52), 1)
        case .kwRationale: return (tkEnum(53), 1)
        case .kwBudget:    return (tkEnum(54), 1)
        case .kwEdition:   return (tkEnum(55), 1)
        case .kwRequires:  return (tkEnum(56), 1)
        case .kwEffect:    return (tkEnum(58), 1)
        case .kwPure:      return (tkEnum(59), 1)
        case .kwAsync:     return (tkEnum(60), 1)
        case .kwAwait:     return (tkEnum(61), 1)
        case .kwYield:     return (tkEnum(62), 1)
        case .kwTry:       return (tkEnum(64), 1)
        case .kwCatch:     return (tkEnum(65), 1)
        case .kwFinally:   return (tkEnum(66), 1)
        case .kwGuard:     return (tkEnum(67), 1)
        case .kwDefer:     return (tkEnum(63), 1)
        case .kwHandle:    return (tkEnum(68), 1)
        case .kwWith:      return (tkEnum(69), 1)
        case .kwImplies:   return (tkEnum(71), 1)
        case .kwComptime:  return (tkEnum(72), 1)
        case .kwConst:     return (tkEnum(73), 1)
        case .kwStatic:    return (tkEnum(74), 1)
        case .kwType:      return (tkEnum(75), 1)
        case .kwTypealias: return (tkEnum(76), 1)
        case .kwExtern:    return (tkEnum(77), 1)
        case .kwInline:    return (tkEnum(78), 1)
        // Swift-only keywords with no TG TokenKind → emit as Ident
        case .kwFn:        return (tkEnum(4, .string("fn")), 1)
        case .kwSuper:     return (tkEnum(4, .string("super")), 1)
        case .kwCrate:     return (tkEnum(4, .string("crate")), 1)
        case .kwTest:      return (tkEnum(4, .string("test")), 1)
        case .kwDyn:       return (tkEnum(4, .string("dyn")), 1)
        // ── Operators ──
        case .plus:        return (tkEnum(79), 1)
        case .minus:       return (tkEnum(80), 1)
        case .star:        return (tkEnum(81), 1)
        case .slash:       return (tkEnum(82), 1)
        case .percent:     return (tkEnum(83), 1)
        case .eq:          return (tkEnum(84), 1)
        case .eqEq:        return (tkEnum(85), 1)
        case .bangEq:      return (tkEnum(86), 1)
        case .lt:          return (tkEnum(87), 1)
        case .gt:          return (tkEnum(88), 1)
        case .ltEq:        return (tkEnum(89), 1)
        case .gtEq:        return (tkEnum(90), 1)
        case .ampAmp:      return (tkEnum(91), 1)   // && → And
        case .pipePipe:    return (tkEnum(92), 1)   // || → Or
        case .bang:        return (tkEnum(93), 1)
        case .amp:         return (tkEnum(94), 1)
        case .pipe:        return (tkEnum(96), 1)
        case .arrow:       return (tkEnum(98), 1)
        case .fatArrow:    return (tkEnum(99), 1)
        case .question:    return (tkEnum(100), 1)
        case .colonColon:  return (tkEnum(101), 1)
        case .dot:         return (tkEnum(102), 1)
        case .dotDot:      return (tkEnum(103), 1)
        case .dotDotDot:   return (tkEnum(104), 1)  // TG has no DotDotDot token; keep legacy fallback
        case .dotDotEq:    return (tkEnum(104), 1)
        case .tilde:       return (tkEnum(105), 1)
        case .caret:       return (tkEnum(106), 1)
        case .shl:         return (tkEnum(108), 1)
        case .shr:         return (tkEnum(109), 1)
        case .plusEq:      return (tkEnum(110), 1)
        case .minusEq:     return (tkEnum(111), 1)
        case .starEq:      return (tkEnum(112), 1)
        case .slashEq:     return (tkEnum(113), 1)
        case .percentEq:   return (tkEnum(114), 1)
        case .caretEq:     return (tkEnum(117), 1)
        // ── Delimiters ──
        case .lParen:      return (tkEnum(120), 1)
        case .rParen:      return (tkEnum(121), 1)
        case .lBracket:    return (tkEnum(122), 1)
        case .rBracket:    return (tkEnum(123), 1)
        case .lBrace:      return (tkEnum(124), 1)
        case .rBrace:      return (tkEnum(125), 1)
        // ── Punctuation ──
        case .colon:       return (tkEnum(126), 1)
        case .semi:        return (tkEnum(127), 1)
        case .comma:       return (tkEnum(128), 1)
        case .at:          return (tkEnum(129), 1)
        // ── Special ──
        case .newline:     return (tkEnum(131), 1)
        case .eof:         return (tkEnum(132), 1)
        case .dollar:      return (tkEnum(4, .string("$")), 1)
        case .whitespace, .comment:
            return (tkEnum(131), 1)  // shouldn't reach here; treat as newline
        }
    }

    /// Identifiers that are TG keywords but not Swift lexer keywords.
    private func identToTgKind(_ s: String) -> MirValue {
        switch s {
        case "def":      return tkEnum(6)
        case "end":      return tkEnum(7)
        case "do":       return tkEnum(8)
        case "if":       return tkEnum(9)
        case "elsif":    return tkEnum(10)
        case "else":     return tkEnum(11)
        case "while":   return tkEnum(12)
        case "for":      return tkEnum(13)
        case "in":       return tkEnum(14)
        case "loop":     return tkEnum(15)
        case "match":   return tkEnum(16)
        case "when":    return tkEnum(17)
        case "then":    return tkEnum(18)
        case "unless":  return tkEnum(19)
        case "until":   return tkEnum(20)
        case "let":     return tkEnum(21)
        case "mut":     return tkEnum(22)
        case "return":  return tkEnum(23)
        case "break":   return tkEnum(24)
        case "next":    return tkEnum(25)
        case "struct":  return tkEnum(26)
        case "enum":    return tkEnum(27)
        case "trait":   return tkEnum(28)
        case "impl":    return tkEnum(29)
        case "module":  return tkEnum(30)
        case "mod":     return tkEnum(30)
        case "use":     return tkEnum(31)
        case "as":      return tkEnum(32)
        case "pub":     return tkEnum(33)
        case "private":  return tkEnum(34)
        case "macro":   return tkEnum(35)
        case "where":   return tkEnum(36)
        case "true":    return tkEnum(37)
        case "false":   return tkEnum(38)
        case "nil":      return tkEnum(39)
        case "self":     return tkEnum(40)  // self value
        case "Self":    return tkEnum(41)  // Self type
        case "move":     return tkEnum(42)
        case "copy":     return tkEnum(43)
        case "drop":     return tkEnum(44)
        case "own":      return tkEnum(45)
        case "ref":      return tkEnum(46)
        case "ref_mut":  return tkEnum(47)
        case "pre":     return tkEnum(48)
        case "post":    return tkEnum(49)
        case "invariant": return tkEnum(50)
        case "cap":     return tkEnum(51)
        case "unsafe":  return tkEnum(52)
        case "rationale": return tkEnum(53)
        case "budget":  return tkEnum(54)
        case "edition": return tkEnum(55)
        case "requires": return tkEnum(56)
        case "ensures":  return tkEnum(57)
        case "effect":  return tkEnum(58)
        case "pure":    return tkEnum(59)
        case "async":   return tkEnum(60)
        case "await":   return tkEnum(61)
        case "yield":   return tkEnum(62)
        case "defer":   return tkEnum(63)
        case "try":     return tkEnum(64)
        case "catch":   return tkEnum(65)
        case "finally": return tkEnum(66)
        case "guard":   return tkEnum(67)
        case "handle":  return tkEnum(68)
        case "with":    return tkEnum(69)
        case "is":       return tkEnum(70)
        case "implies": return tkEnum(71)
        case "comptime": return tkEnum(72)
        case "const":   return tkEnum(73)
        case "static":  return tkEnum(74)
        case "type":    return tkEnum(75)
        case "alias":    return tkEnum(76)
        case "extern":  return tkEnum(77)
        case "inline":  return tkEnum(78)
        default:         return tkEnum(4, .string(s))
        }
    }

    /// Shorthand for creating a TokenKind enum MirValue (unit payload).
    private func tkEnum(_ idx: Int) -> MirValue {
        .enumVal("TokenKind", idx, .unit)
    }
    /// Shorthand for creating a TokenKind enum MirValue with payload.
    private func tkEnum(_ idx: Int, _ payload: MirValue) -> MirValue {
        .enumVal("TokenKind", idx, payload)
    }

    // MARK: - Native is_intrinsic / bare_intrinsic_name

    /// Canonical intrinsic names accepted by codegen.tg's is_intrinsic().
    /// Explicit non-intrinsic exclusions are handled separately in nativeIsIntrinsic.
    private static let intrinsicNames: Set<String> = {
        var s = Set<String>(minimumCapacity: 256)
        // Syscall intrinsics
        for n in ["syscall6","syscall5","syscall4","syscall3","syscall2","syscall1"] { s.insert(n) }
        for n in ["__intrinsic_syscall6","__intrinsic_syscall5","__intrinsic_syscall4","__intrinsic_syscall3","__intrinsic_syscall2","__intrinsic_syscall1"] { s.insert(n) }
        // Resize intrinsic
        for n in ["resize"] { s.insert(n) }
        // String conversion
        for n in ["int_to_string","uint_to_string","float_to_string","bool_to_string","str_to_string",
                  "string_from_bytes","int_to_string_intrinsic","uint_to_string_intrinsic","float_to_string_intrinsic"] { s.insert(n) }
        // Identity/no-op
        for n in ["as_bytes","as_ptr","as_str","as_mut_ptr","len","clone","to_string"] { s.insert(n) }
        // Collection and CString helpers that codegen treats as intrinsics early
        for n in ["array_as_ptr_address","array_as_str","array_replace","set_is_empty","map_push",
                  "as_ptr_address","cstring_new","cstring_as_ptr","bytes"] { s.insert(n) }
        // String intrinsics
        for n in ["str_concat","str_len","str_cmp","str_copy","int_to_str","float_to_str","str_to_int","str_to_float"] { s.insert(n) }
        // String methods
        for n in ["to_lowercase","to_uppercase","trim_matches","trim","split_once","split","lines",
                   "starts_with","ends_with","index_of","last_index_of","rfind","find",
                   "parse_int","parse_float","to_bits","from_bits","to_wide_string",
                   "replace","slice",
                   "string_replace","string_find","string_char_at","string_push",
                   "string_push_str","string_split","string_slice","string_len","string_parse_int"] { s.insert(n) }
        // Array/Vec
         for n in ["array_new","array_push","array_pop","array_get","array_set","array_len",
                   "array_cap","array_remove","array_insert","array_clear","array_contains",
                   "array_last","array_first","array_is_empty","array_reverse","array_sort",
                   "array_extend","array_truncate","array_resize",
                   "array_slice","array_from_list","array_with_capacity","array_capacity"] { s.insert(n) }
        // Map
        for n in ["map_new","map_insert","map_get","map_remove","map_contains","map_len",
                   "map_clear","map_keys","map_values","map_entries","map_contains_key","map_get_mut"] { s.insert(n) }
        // Set
        for n in ["set_new","set_insert","set_contains","set_remove","set_len","set_clear","set_entries"] { s.insert(n) }
        // Memory
        for n in ["mem_alloc","mem_free","mem_copy","mem_set","mem_zero"] { s.insert(n) }
        // Hash
        for n in ["hash_int","hash_str","hash_combine"] { s.insert(n) }
        // Chars
        for n in ["chars","char_at"] { s.insert(n) }
        // Option/Result
        for n in ["is_some","is_none","is_ok","is_err","unwrap","unwrap_or"] { s.insert(n) }
        // Formatter
        for n in ["emit_newline","emit_blank_line","emit","space","would_overflow","indent","dedent"] { s.insert(n) }
        // Bare method names
        for n in ["push","pop","get","set","cap","is_empty","first","last",
                   "map","entries","keys","values","contains_key","get_mut",
                   "join","collect"] { s.insert(n) }
        // Process/Environment
        for n in ["status","output","stdout_string","stderr_string","lint_file"] { s.insert(n) }
        for n in ["cmp","to_int","eval"] { s.insert(n) }
        // File constants
        for n in ["SYS_WRITE","SYS_READ","SYS_OPEN","SYS_CLOSE","SYS_EXIT",
                   "O_WRONLY","O_RDWR","O_APPEND","O_CREAT","O_TRUNC","open_windows"] { s.insert(n) }
        // Additional method names
        for n in ["parse_float","string_parse_float"] { s.insert(n) }
        // Vec/Array clone variants
        for n in ["Vec__clone","Array__clone","Vec__starts_with","Vec__ends_with",
                   "Vec__to_string","Array__to_string","Vec__read","Array__read",
                   "Vec__join","Array__join","Vec__as_ptr","Vec__as_mut_ptr",
                   "Array__as_ptr","Array__as_mut_ptr","array_as_ptr","array_as_mut_ptr"] { s.insert(n) }
        // Map/Set method variants
        for n in ["Map__unwrap","Map__clone","Set__clone","Set__unwrap"] { s.insert(n) }
        // Canonical array_/map_/set_/string_ normalized names
        for n in ["array_clone","array_starts_with","array_ends_with","array_to_string",
                   "array_read","array_join","array_as_ptr","array_as_mut_ptr",
                   "map_unwrap","map_clone","set_clone","set_unwrap"] { s.insert(n) }
        // String__ prefixed
        for n in ["string_clone","string_is_empty","string_chars","string_as_bytes",
                   "string_as_ptr","string_as_str","string_to_wide_string","string_to_string",
                   "string_ends_with","string_starts_with","string_len","string_index_of",
                   "string_last_index_of","string_rfind","string_trim","string_trim_matches",
                   "string_to_lowercase","string_to_uppercase","string_contains","string_replace",
                   "string_slice","string_split","string_lines","string_split_once",
                   "string_unwrap_or","String__unwrap_or"] { s.insert(n) }
        // Type__method variants
        for n in ["PanicInfo__clone","TypeExpr__clone","Span__clone",
                   "LifetimeCtx__to_string","MirProgram__to_string","Type__clone",
                   "Type__collect","Type__unwrap","InlineResult__unwrap_or",
                   "MirStatement__unwrap_or","Place__unwrap_or","MirRvalue__collect",
                   "MirRvalue__unwrap_or","MirTerminator__unwrap_or","PgoProfile__unwrap_or",
                   "LocalId__clone","BlockId__clone","MirFunction__clone",
                   "MirStatement__clone","MirRvalue__clone","AggregateKind__clone",
                   "MirTerminatorKind__clone","AsmTarget__clone","Budget__unwrap_or",
                   "Budget__trim","IfStmt__len"] { s.insert(n) }
        return s
    }()

    private static let nonIntrinsicNames: Set<String> = [
        "open", "close", "read", "write",
        "raw_read", "raw_write", "raw_open", "raw_close",
        "contains",
        "arg", "args", "args_vec"
    ]

    private static func nativeIsIntrinsic(_ name: String) -> Bool {
        if Self.nonIntrinsicNames.contains(name) {
            return false
        }
        if name.hasPrefix("__intrinsic_") {
            return true
        }
        return Self.intrinsicNames.contains(name)
    }

    private static func stripGenericArgs(_ name: String) -> String {
        if let start = name.firstIndex(of: "<") {
            return String(name[..<start])
        }
        return name
    }

    /// Native implementation of bare_intrinsic_name matching codegen.tg's logic.
    private static func nativeBareIntrinsicName(_ name: String) -> String {
        if name.count > 1 && name.hasPrefix(".") {
            return nativeBareIntrinsicName(String(name.dropFirst()))
        }
        // Pattern 1: __intrinsic_ prefix
        if name.count >= 12 && name.hasPrefix("__intrinsic_") {
            return stripGenericArgs(String(name.dropFirst(12)))
        }
        // Pattern 2: Type__method mangled names
        if let range = name.range(of: "__") {
            let pos = name.distance(from: name.startIndex, to: range.lowerBound)
            if pos == 0 { return name }  // starts with __ but not __intrinsic_
            let prefix = String(name[..<range.lowerBound])
            let bare = stripGenericArgs(String(name[name.index(range.lowerBound, offsetBy: 2)...]))
            switch prefix {
            case "Vec", "Array": return "array_" + bare
            case "Map": return "map_" + bare
            case "Set": return "set_" + bare
            case "String": return "string_" + bare
            case "Formatter", "Option", "Result", "Io", "File",
                 "Budget", "PanicInfo", "TypeExpr", "Span", "LocalId", "BlockId",
                 "MirFunction", "MirStatement", "MirRvalue", "MirTerminator",
                 "AggregateKind", "AsmTarget", "InlineResult", "Place", "PgoProfile",
                 "LifetimeCtx", "MirProgram", "Type", "IfStmt", "LocalDef", "FieldDef",
                 "Repl", "ReplContext":
                return bare
            default:
                return name  // Unknown prefix → return full name unchanged
            }
        }
        return name
    }

    /// Native implementation of canonical_fn_ref matching codegen.tg's logic.
    private static func nativeCanonicalFnRef(_ name: String) -> String {
        // Pattern 1: __intrinsic_ prefix
        if name.count >= 12 && name.hasPrefix("__intrinsic_") {
            return String(name.dropFirst(12))
        }
        // Pattern 2: Type__method
        if let range = name.range(of: "__") {
            let pos = name.distance(from: name.startIndex, to: range.lowerBound)
            if pos > 0 {
                let prefix = String(name[..<range.lowerBound])
                let bare = String(name[name.index(range.lowerBound, offsetBy: 2)...])
                switch prefix {
                case "Vec", "Array": return "array_" + bare
                case "Map": return "map_" + bare
                case "Set": return "set_" + bare
                case "String": return "string_" + bare
                case "Formatter": return "fmt_" + bare
                case "Option": return "option_" + bare
                case "Result": return "result_" + bare
                case "Iterator": return "iter_" + bare
                case "File": return "file_" + bare
                case "Io": return "io_" + bare
                default: return bare
                }
            }
        }
        // Pattern 3: qualified name (last segment after ::)
        if let range = name.range(of: "::", options: .backwards) {
            return String(name[name.index(range.upperBound, offsetBy: 0)...])
        }
        return name
    }

    /// Native implementation of bare_name_from_qualified matching codegen.tg's logic.
    private static func nativeBareNameFromQualified(_ name: String) -> String {
        // Handle Type__method mangled names
        if let range = name.range(of: "__") {
            let pos = name.distance(from: name.startIndex, to: range.lowerBound)
            if pos > 0 {
                return String(name[name.index(range.lowerBound, offsetBy: 2)...])
            }
        }
        // Handle :: qualified names (last segment)
        if let range = name.range(of: "::", options: .backwards) {
            return String(name[name.index(range.upperBound, offsetBy: 0)...])
        }
        return name
    }

    // MARK: - SHA-256 (pure Swift)

    private static let sha256K: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func computeSha256(_ input: [UInt8]) -> [UInt8] {
        func rr(_ v: UInt32, _ n: UInt32) -> UInt32 { (v >> n) | (v << (32 &- n)) }

        var h: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
            (0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
             0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19)

        // Padding
        var msg = input
        let bitLen = UInt64(input.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8(truncatingIfNeeded: bitLen >> shift))
        }

        // Process 512-bit blocks
        for blk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = blk + i * 4
                w[i] = UInt32(msg[o]) << 24 | UInt32(msg[o+1]) << 16 | UInt32(msg[o+2]) << 8 | UInt32(msg[o+3])
            }
            for i in 16..<64 {
                let s0 = rr(w[i-15], 7) ^ rr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rr(w[i-2], 17) ^ rr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = h
            for i in 0..<64 {
                let S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ sha256K[i] &+ w[i]
                let S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h.0 &+= a; h.1 &+= b; h.2 &+= c; h.3 &+= d
            h.4 &+= e; h.5 &+= f; h.6 &+= g; h.7 &+= hh
        }

        var result = [UInt8](repeating: 0, count: 32)
        for (i, hv) in [h.0, h.1, h.2, h.3, h.4, h.5, h.6, h.7].enumerated() {
            result[i*4]   = UInt8(truncatingIfNeeded: hv >> 24)
            result[i*4+1] = UInt8(truncatingIfNeeded: hv >> 16)
            result[i*4+2] = UInt8(truncatingIfNeeded: hv >> 8)
            result[i*4+3] = UInt8(truncatingIfNeeded: hv)
        }
        return result
    }
}

// MARK: - MirArrayBuffer (reference-type array storage to avoid COW)

public final class MirArrayBuffer: Equatable, ExpressibleByArrayLiteral, RandomAccessCollection, MutableCollection, RangeReplaceableCollection {
    public typealias Element = MirValue
    public typealias Index = Int
    public typealias ArrayLiteralElement = MirValue

    public var elements: [MirValue]

    public required init() {
        self.elements = []
        self.elements.reserveCapacity(32)
    }

    public init<S: Sequence>(_ elements: S) where S.Element == MirValue {
        self.elements = Array(elements)
    }

    public required convenience init(arrayLiteral elements: MirValue...) {
        self.init(elements)
    }

    public static func == (lhs: MirArrayBuffer, rhs: MirArrayBuffer) -> Bool {
        lhs === rhs || lhs.elements == rhs.elements
    }

    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }

    public func index(after i: Int) -> Int {
        elements.index(after: i)
    }

    public func index(before i: Int) -> Int {
        elements.index(before: i)
    }

    public subscript(position: Int) -> MirValue {
        get { elements[position] }
        set { elements[position] = newValue }
    }

    public func truncate(to count: Int) {
        if count <= 0 {
            elements.removeAll(keepingCapacity: true)
            return
        }
        if count < elements.count {
            elements.removeLast(elements.count - count)
        }
    }

    public func replaceSubrange<C>(_ subrange: Range<Int>, with newElements: C) where C: Collection, MirValue == C.Element {
        elements.replaceSubrange(subrange, with: newElements)
    }
}

// MARK: - MirByteBuffer (reference-type byte storage to avoid COW)

/// A reference-type wrapper for byte arrays, used to store CodeBuffer.bytes
/// efficiently. Since this is a class (reference type), "copying" a MirValue
/// that contains a byteBuffer just copies the reference — O(1) instead of O(n).
/// This is critical for codegen performance where CodeBuffer is passed by &mut
/// through many levels of function calls.
public final class MirByteBuffer: Equatable {
    public var data: [UInt8]
    
    public init() {
        self.data = []
        self.data.reserveCapacity(4096)  // Most code buffers grow large
    }
    public init(data: [UInt8]) { self.data = data }
    
    public static func == (lhs: MirByteBuffer, rhs: MirByteBuffer) -> Bool {
        return lhs === rhs || lhs.data == rhs.data
    }
    
    func toMirValues() -> [MirValue] {
        return data.map { .int(Int($0)) }
    }
}

/// Reference-type hash map for Map/Set with O(1) operations.
/// Uses type-prefixed display string as hash key for any MirValue key type.
public final class MirNativeMap {
    /// Backing store: hashKey → (originalKey, value)
    var dict: [String: (key: MirValue, value: MirValue)]

    init() {
        self.dict = [:]
        self.dict.reserveCapacity(32)
    }

    @inline(__always)
    static func hashKey(_ key: MirValue) -> String {
        switch key {
        case .string(let s): return "s:" + s
        case .int(let i):    return "i:\(i)"
        case .bool(let b):   return "b:\(b)"
        default:             return "x:" + key.displayString
        }
    }

    func get(_ key: MirValue) -> MirValue? {
        dict[Self.hashKey(key)]?.value
    }

    func contains(_ key: MirValue) -> Bool {
        dict[Self.hashKey(key)] != nil
    }

    func insert(_ key: MirValue, _ value: MirValue) {
        dict[Self.hashKey(key)] = (key, value)
    }

    func remove(_ key: MirValue) {
        dict.removeValue(forKey: Self.hashKey(key))
    }

    /// Convert back to array of tuples for TG compatibility
    func toEntries() -> [MirValue] {
        dict.values.map { .tuple([$0.key, $0.value]) }
    }

    var count: Int { dict.count }
    var isEmpty: Bool { dict.isEmpty }
    var keys: [MirValue] { dict.values.map(\.key) }
    var values: [MirValue] { dict.values.map(\.value) }
}

// MARK: - MirValue (runtime value)

public enum MirValue: Equatable, CustomStringConvertible {
    case unit
    case bool(Bool)
    case int(Int)
    case float(Double)
    case char(Character)
    case string(String)
    case fn(String)
    case tuple([MirValue])
    case array(MirArrayBuffer)
    case byteBuffer(MirByteBuffer)
    case structVal(String, [String: MirValue])
    // Only enumVal needs indirect because it directly contains a MirValue.
    // All other cases use reference-counted types (Array, Dictionary, class)
    // which are already boxed, so the enum itself stays inline-allocated.
    indirect case enumVal(String, Int, MirValue)

    public var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .bool(let b): return b ? 1 : 0
        case .char(let c):
            let scalars = c.unicodeScalars
            guard !scalars.isEmpty else { return 0 }
            return Int(scalars[scalars.startIndex].value)
        default: return nil
        }
    }

    public var asFloat: Double? {
        switch self {
        case .float(let f): return f
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var displayString: String {
        switch self {
        case .unit: return "()"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .char(let c): return "\(c)"
        case .string(let s): return s
        case .fn(let n): return "<fn \(n)>"
        case .tuple(let vs): return "(\(vs.map(\.displayString).joined(separator: ", ")))"
        case .array(let vs): return "[\(vs.map(\.displayString).joined(separator: ", "))]"
        case .byteBuffer(let bb): return "[bytes:\(bb.data.count)]"
        case .structVal(let n, let fs): return "\(n) { \(fs.map { "\($0.key): \($0.value.displayString)" }.joined(separator: ", ")) }"
        case .enumVal(let n, let v, let inner): return "\(n)::\(v)(\(inner.displayString))"
        }
    }

    public var description: String { displayString }
}

// MARK: - MIR Pretty-Printer

public struct MIRPrettyPrinter {
    public init() {}

    public func print(_ program: MirProgram) -> String {
        var out = ""
        for fn in program.functions {
            out += printFunction(fn)
            out += "\n"
        }
        return out
    }

    private func printFunction(_ fn: MirFunction) -> String {
        var out = "fn \(fn.name)("
        out += fn.params.map { p in
            "\(p.name ?? "_\(p.id)"): \(printType(p.type))"
        }.joined(separator: ", ")
        out += ") -> \(printType(fn.returnType)) {\n"

        for local in fn.locals where !fn.params.contains(where: { $0.id == local.id }) {
            let mutStr = local.isMutable ? "mut " : ""
            let nameStr = local.name.map { " /* \($0) */" } ?? ""
            out += "    let \(mutStr)_\(local.id)\(nameStr): \(printType(local.type));\n"
        }
        out += "\n"

        for block in fn.blocks {
            out += "    bb\(block.id): {\n"
            for stmt in block.statements {
                out += "        \(printStatement(stmt))\n"
            }
            out += "        \(printTerminator(block.terminator))\n"
            out += "    }\n"
        }

        out += "}\n"
        return out
    }

    private func printStatement(_ stmt: MirStatement) -> String {
        switch stmt {
        case .assign(let place, let rvalue):
            return "\(printPlace(place)) = \(printRvalue(rvalue));"
        case .storageLive(let id):
            return "StorageLive(_\(id));"
        case .storageDead(let id):
            return "StorageDead(_\(id));"
        case .setDiscriminant(let place, let disc):
            return "SetDiscriminant(\(printPlace(place)), \(disc));"
        case .nop:
            return "nop;"
        }
    }

    private func printTerminator(_ term: MirTerminator) -> String {
        switch term {
        case .goto(let bb):
            return "goto -> bb\(bb);"
        case .ret:
            return "return;"
        case .switchInt(let op, let targets, let otherwise):
            let arms = targets.map { "\($0.0): bb\($0.1)" }.joined(separator: ", ")
            return "switchInt(\(printOperand(op))) -> [\(arms), otherwise: bb\(otherwise)];"
        case .call(let dest, let callee, let args, let next, let unwind):
            let argStr = args.map(printOperand).joined(separator: ", ")
            let unwindStr = unwind.map { ", unwind: bb\($0)" } ?? ""
            return "\(printPlace(dest)) = \(printOperand(callee))(\(argStr)) -> [bb\(next)\(unwindStr)];"
        case .drop(let place, let next, _):
            return "drop(\(printPlace(place))) -> bb\(next);"
        case .assert(let cond, let expected, let msg, let target):
            return "assert(\(printOperand(cond)), \(expected), \"\(msg)\") -> bb\(target);"
        case .yield(let val, let resume):
            return "yield(\(printOperand(val))) -> bb\(resume);"
        case .unreachable:
            return "unreachable;"
        case .abort:
            return "abort;"
        }
    }

    private func printRvalue(_ rvalue: MirRvalue) -> String {
        switch rvalue {
        case .use(let op):
            return printOperand(op)
        case .binaryOp(let op, let l, let r):
            return "\(printOperand(l)) \(binOpStr(op)) \(printOperand(r))"
        case .unaryOp(let op, let operand):
            return "\(unOpStr(op))(\(printOperand(operand)))"
        case .aggregate(let kind, let ops):
            let vals = ops.map(printOperand).joined(separator: ", ")
            switch kind {
            case .tuple: return "(\(vals))"
            case .array: return "[\(vals)]"
            case .structCtor(let n, let fieldNames): return "\(n) { \(fieldNames.isEmpty ? vals : zip(fieldNames, ops.map(printOperand)).map { "\($0.0): \($0.1)" }.joined(separator: ", ")) }"
            case .enumCtor(let n, let v): return "\(n)::\(v)(\(vals))"
            case .closure(let n): return "closure(\(n))"
            }
        case .ref(let bk, let place):
            return "&\(bk == .mutable ? "mut " : "")\(printPlace(place))"
        case .discriminant(let place):
            return "discriminant(\(printPlace(place)))"
        case .len(let place):
            return "Len(\(printPlace(place)))"
        case .cast(let op, let ty):
            return "\(printOperand(op)) as \(printType(ty))"
        }
    }

    private func printOperand(_ op: MirOperand) -> String {
        switch op {
        case .copy(let p): return printPlace(p)
        case .move(let p): return "move \(printPlace(p))"
        case .constant(let c): return printConstant(c)
        }
    }

    private func printPlace(_ place: MirPlace) -> String {
        var s = "_\(place.local)"
        for proj in place.projections {
            switch proj {
            case .deref: s = "(*\(s))"
            case .field(let i): s += ".\(i)"
            case .namedField(let n): s += ".\(n)"
            case .index(let id): s += "[_\(id)]"
            case .constantIndex(let i): s += "[\(i)]"
            case .downcast(let v): s += " as variant#\(v)"
            }
        }
        return s
    }

    private func printConstant(_ c: MirConstant) -> String {
        switch c {
        case .unit: return "()"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .char(let c): return "'\(c)'"
        case .str(let s): return "\"\(s)\""
        case .fnItem(let n): return n
        case .zeroSized: return "zst"
        }
    }

    private func printType(_ ty: MirType) -> String {
        switch ty {
        case .unit: return "()"
        case .bool: return "Bool"
        case .int: return "Int"
        case .float: return "Float"
        case .char: return "Char"
        case .string: return "String"
        case .named(let n): return n
        case .ref(let inner, let mutable): return "&\(mutable ? "mut " : "")\(printType(inner))"
        case .rawPtr(let inner): return "*\(printType(inner))"
        case .array(let inner, let size): return size.map { "[\(printType(inner)); \($0)]" } ?? "[\(printType(inner))]"
        case .slice(let inner): return "[\(printType(inner))]"
        case .tuple(let elems): return "(\(elems.map(printType).joined(separator: ", ")))"
        case .fn(let params, let ret): return "fn(\(params.map(printType).joined(separator: ", "))) -> \(printType(ret))"
        case .unknown: return "?"
        }
    }

    private func binOpStr(_ op: MirBinOp) -> String {
        switch op {
        case .add: return "+"; case .sub: return "-"; case .mul: return "*"; case .div: return "/"
        case .rem: return "%"; case .eq: return "=="; case .ne: return "!="; case .lt: return "<"
        case .le: return "<="; case .gt: return ">"; case .ge: return ">="; case .and: return "&&"
        case .or: return "||"; case .bitAnd: return "&"; case .bitOr: return "|"
        case .bitXor: return "^"; case .shl: return "<<"; case .shr: return ">>"
        }
    }

    private func unOpStr(_ op: MirUnOp) -> String {
        switch op { case .neg: return "Neg"; case .not: return "Not" }
    }
}
