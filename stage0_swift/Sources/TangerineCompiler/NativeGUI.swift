// NativeGUI.swift — Cross-platform GUI backend for the MIR interpreter
// macOS: AppKit + CoreGraphics + CoreText
// Linux: X11 + Cairo + Pango (via dlopen)
// Windows: Win32 + GDI (via WinSDK)
// All other platforms: software framebuffer (headless with event simulation)

import Foundation

// ═══════════════════════════════════════════════════════════════
// MARK: - Platform-agnostic protocol
// ═══════════════════════════════════════════════════════════════

/// Abstract interface for the native GUI backend.
/// Each platform provides a concrete implementation.
protocol TGPlatformGUI: AnyObject {
    var windowWidth: Int { get }
    var windowHeight: Int { get }

    func ensureWindow(title: String, width: Int, height: Int)
    func pollEvent() -> MirValue
    func requestRedraw()
    func createSurface()
    func present()

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double)
    func fillRect(x: Double, y: Double, w: Double, h: Double,
                  r: Double, g: Double, b: Double, a: Double)
    func fillRRect(x: Double, y: Double, w: Double, h: Double, radius: Double,
                   r: Double, g: Double, b: Double, a: Double)
    func drawText(_ text: String, x: Double, y: Double, size: Double,
                  r: Double, g: Double, b: Double, a: Double)

    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue)
    func getTextRun(_ opaqueId: Int) -> (String, Double)?

    /// Whether a canvas is currently active (between begin_frame / end_frame)
    var hasActiveCanvas: Bool { get }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - Singleton accessor
// ═══════════════════════════════════════════════════════════════

/// Platform-selected GUI singleton — always available, never nil.
enum TGNativeGUI {
    static let shared: TGPlatformGUI = {
        #if os(macOS)
        return TGMacOSGUI()
        #elseif os(Linux)
        return TGLinuxGUI()
        #elseif os(Windows)
        return TGWindowsGUI()
        #else
        return TGSoftwareGUI()
        #endif
    }()
}

// ═══════════════════════════════════════════════════════════════
// MARK: - Shared helpers (framebuffer pixel ops, text run table)
// ═══════════════════════════════════════════════════════════════

/// RGBA8888 software framebuffer used by Linux, Windows, and headless backends.
final class TGFramebuffer {
    var width: Int
    var height: Int
    var pixels: [UInt8]   // RGBA, row-major, top-left origin

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        let rb = UInt8(clamping: Int(r * 255))
        let gb = UInt8(clamping: Int(g * 255))
        let bb = UInt8(clamping: Int(b * 255))
        let ab = UInt8(clamping: Int(a * 255))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i]     = rb
            pixels[i + 1] = gb
            pixels[i + 2] = bb
            pixels[i + 3] = ab
        }
    }

    func fillRect(x: Int, y: Int, w: Int, h: Int,
                  r: Double, g: Double, b: Double, a: Double) {
        let rb = UInt8(clamping: Int(r * 255))
        let gb = UInt8(clamping: Int(g * 255))
        let bb = UInt8(clamping: Int(b * 255))
        let ab = UInt8(clamping: Int(a * 255))
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + w)
        let y1 = min(height, y + h)
        for row in y0..<y1 {
            for col in x0..<x1 {
                let idx = (row * width + col) * 4
                pixels[idx]     = rb
                pixels[idx + 1] = gb
                pixels[idx + 2] = bb
                pixels[idx + 3] = ab
            }
        }
    }

    func fillRRect(x: Int, y: Int, w: Int, h: Int, radius: Int,
                   r: Double, g: Double, b: Double, a: Double) {
        let rb = UInt8(clamping: Int(r * 255))
        let gb = UInt8(clamping: Int(g * 255))
        let bb = UInt8(clamping: Int(b * 255))
        let ab = UInt8(clamping: Int(a * 255))
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + w)
        let y1 = min(height, y + h)
        let rad = min(radius, min(w, h) / 2)
        let r2 = rad * rad
        for row in y0..<y1 {
            for col in x0..<x1 {
                let lx = col - x
                let ly = row - y
                var inside = true
                // Check corners
                if lx < rad && ly < rad {
                    let dx = rad - lx; let dy = rad - ly
                    inside = dx * dx + dy * dy <= r2
                } else if lx >= w - rad && ly < rad {
                    let dx = lx - (w - rad - 1); let dy = rad - ly
                    inside = dx * dx + dy * dy <= r2
                } else if lx < rad && ly >= h - rad {
                    let dx = rad - lx; let dy = ly - (h - rad - 1)
                    inside = dx * dx + dy * dy <= r2
                } else if lx >= w - rad && ly >= h - rad {
                    let dx = lx - (w - rad - 1); let dy = ly - (h - rad - 1)
                    inside = dx * dx + dy * dy <= r2
                }
                if inside {
                    let idx = (row * width + col) * 4
                    pixels[idx]     = rb
                    pixels[idx + 1] = gb
                    pixels[idx + 2] = bb
                    pixels[idx + 3] = ab
                }
            }
        }
    }

    /// Simple bitmap text renderer — draws each character as a small glyph from
    /// a built-in 6×10 bitmap font. Sufficient for calculator labels.
    func drawText(_ text: String, x: Int, y: Int, size: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        let rb = UInt8(clamping: Int(r * 255))
        let gb = UInt8(clamping: Int(g * 255))
        let bb = UInt8(clamping: Int(b * 255))
        let ab = UInt8(clamping: Int(a * 255))
        let scale = max(1, Int(size / 10.0))
        var cx = x
        // Adjust baseline: y in the API is the text baseline, shift up by ascent
        let baseY = y - 8 * scale
        for ch in text {
            let glyph = TGBitmapFont.glyph(for: ch)
            for row in 0..<10 {
                let bits = glyph[row]
                for col in 0..<6 {
                    if bits & (1 << (5 - col)) != 0 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let px = cx + col * scale + sx
                                let py = baseY + row * scale + sy
                                if px >= 0 && px < width && py >= 0 && py < height {
                                    let idx = (py * width + px) * 4
                                    pixels[idx]     = rb
                                    pixels[idx + 1] = gb
                                    pixels[idx + 2] = bb
                                    pixels[idx + 3] = ab
                                }
                            }
                        }
                    }
                }
            }
            cx += 6 * scale + scale // char width + spacing
        }
    }
}

/// Minimal 6×10 bitmap font covering ASCII 32–127.
/// Each glyph is 10 rows of UInt8 bitmask (top 6 bits used).
enum TGBitmapFont {
    // Pre-built glyphs for common calculator characters
    static func glyph(for ch: Character) -> [UInt8] {
        switch ch {
        case "0": return [0b011100, 0b100010, 0b100110, 0b101010, 0b110010, 0b100010, 0b011100, 0, 0, 0]
        case "1": return [0b001000, 0b011000, 0b001000, 0b001000, 0b001000, 0b001000, 0b011100, 0, 0, 0]
        case "2": return [0b011100, 0b100010, 0b000010, 0b001100, 0b010000, 0b100000, 0b111110, 0, 0, 0]
        case "3": return [0b011100, 0b100010, 0b000010, 0b001100, 0b000010, 0b100010, 0b011100, 0, 0, 0]
        case "4": return [0b000100, 0b001100, 0b010100, 0b100100, 0b111110, 0b000100, 0b000100, 0, 0, 0]
        case "5": return [0b111110, 0b100000, 0b111100, 0b000010, 0b000010, 0b100010, 0b011100, 0, 0, 0]
        case "6": return [0b011100, 0b100000, 0b111100, 0b100010, 0b100010, 0b100010, 0b011100, 0, 0, 0]
        case "7": return [0b111110, 0b000010, 0b000100, 0b001000, 0b010000, 0b010000, 0b010000, 0, 0, 0]
        case "8": return [0b011100, 0b100010, 0b100010, 0b011100, 0b100010, 0b100010, 0b011100, 0, 0, 0]
        case "9": return [0b011100, 0b100010, 0b100010, 0b011110, 0b000010, 0b000010, 0b011100, 0, 0, 0]
        case "+": return [0, 0, 0b001000, 0b001000, 0b111110, 0b001000, 0b001000, 0, 0, 0]
        case "-": return [0, 0, 0, 0, 0b111110, 0, 0, 0, 0, 0]
        case "*": return [0, 0b100010, 0b010100, 0b001000, 0b010100, 0b100010, 0, 0, 0, 0]
        case "/": return [0b000010, 0b000100, 0b001000, 0b010000, 0b100000, 0, 0, 0, 0, 0]
        case "=": return [0, 0, 0b111110, 0, 0b111110, 0, 0, 0, 0, 0]
        case "C": return [0b011100, 0b100010, 0b100000, 0b100000, 0b100000, 0b100010, 0b011100, 0, 0, 0]
        case "E": return [0b111110, 0b100000, 0b100000, 0b111100, 0b100000, 0b100000, 0b111110, 0, 0, 0]
        case "r": return [0, 0, 0b101100, 0b110010, 0b100000, 0b100000, 0b100000, 0, 0, 0]
        case "o": return [0, 0, 0b011100, 0b100010, 0b100010, 0b100010, 0b011100, 0, 0, 0]
        case ".": return [0, 0, 0, 0, 0, 0, 0b001000, 0, 0, 0]
        case " ": return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        default:
            // Generic block for unknown chars
            return [0b111110, 0b100010, 0b100010, 0b100010, 0b100010, 0b100010, 0b111110, 0, 0, 0]
        }
    }

    /// Estimate advance width for a character at given size
    static func advance(for ch: Character, size: Double) -> Double {
        let scale = max(1.0, size / 10.0)
        return 7.0 * scale // 6 pixels + 1 spacing
    }
}

/// Shared text run side-table for non-CoreText platforms.
final class TGTextRunTable {
    private var textRuns: [Int: (String, Double)] = [:]
    private var nextId: Int = 1

    func store(_ text: String, size: Double) -> Int {
        let id = nextId
        nextId += 1
        textRuns[id] = (text, size)
        return id
    }

    func get(_ id: Int) -> (String, Double)? {
        return textRuns[id]
    }

    /// Build a GlyphRun MirValue from text using bitmap font metrics
    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue) {
        let runId = store(text, size: size)
        let scale = max(1.0, size / 10.0)
        let ascent = 8.0 * scale
        let descent = 2.0 * scale

        var glyphs: [MirValue] = []
        var xs: [MirValue] = []
        var ys: [MirValue] = []
        var xCursor = 0.0

        for ch in text {
            let adv = TGBitmapFont.advance(for: ch, size: size)
            glyphs.append(.structVal("Glyph", [
                "id": .int(Int(ch.asciiValue ?? 0)),
                "x_adv": .float(adv),
                "y_adv": .float(0),
                "x_off": .float(0),
                "y_off": .float(0)
            ]))
            xs.append(.float(xCursor))
            ys.append(.float(0))
            xCursor += adv
        }

        let fontId = MirValue.structVal("FontId", ["value": .int(0)])
        let bounds = MirValue.structVal("Rect", [
            "x": .float(0),
            "y": .float(-ascent),
            "w": .float(xCursor),
            "h": .float(ascent + descent)
        ])

        let glyphRun = MirValue.structVal("GlyphRun", [
            "font": fontId,
            "size": .float(size),
            "glyphs": .array(MirArrayBuffer(glyphs)),
            "xs": .array(MirArrayBuffer(xs)),
            "ys": .array(MirArrayBuffer(ys)),
            "bounds": bounds,
            "_opaque": .int(runId)
        ])
        return (runId, glyphRun)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - macOS backend (AppKit + CoreGraphics + CoreText)
// ═══════════════════════════════════════════════════════════════

#if os(macOS)
import AppKit
import CoreGraphics
import CoreText

final class TGMacOSGUI: TGPlatformGUI {
    private var window: NSWindow?
    private var contentView: TGContentView?
    private var eventQueue: [MirValue] = []
    private var needsRedraw = true
    private var appStarted = false
    private var currentContext: CGContext?
    private(set) var windowWidth: Int = 384
    private(set) var windowHeight: Int = 392
    private var textRuns: [Int: (String, Double)] = [:]
    private var nextTextRunId: Int = 1
    var hasActiveCanvas: Bool { currentContext != nil }

    func ensureWindow(title: String, width: Int, height: Int) {
        guard window == nil else { return }
        windowWidth = width
        windowHeight = height

        if !appStarted {
            appStarted = true
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.finishLaunching()
        }

        let rect = NSRect(x: 200, y: 200, width: width, height: height)
        let w = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = title

        let view = TGContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.gui = self
        w.contentView = view
        w.delegate = view
        window = w
        contentView = view

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        needsRedraw = true
    }

    func pollEvent() -> MirValue {
        let timeout = needsRedraw ? 0.001 : 0.016
        while let event = NSApp.nextEvent(
            matching: .any,
            until: Date(timeIntervalSinceNow: timeout),
            inMode: .default,
            dequeue: true
        ) {
            convertAndQueue(event)
            NSApp.sendEvent(event)
        }

        if needsRedraw {
            needsRedraw = false
            eventQueue.append(.enumVal("Event", 18, .unit))
        }

        if let event = eventQueue.first {
            eventQueue.removeFirst()
            return .enumVal("Option", 0, event)
        }
        return .enumVal("Option", 1, .unit)
    }

    func requestRedraw() { needsRedraw = true }

    func createSurface() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: windowWidth,
            height: windowHeight,
            bitsPerComponent: 8,
            bytesPerRow: windowWidth * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.translateBy(x: 0, y: CGFloat(windowHeight))
        ctx?.scaleBy(x: 1, y: -1)
        currentContext = ctx
    }

    private var frameCount = 0
    func present() {
        guard let ctx = currentContext, let cgImage = ctx.makeImage() else { return }
        contentView?.displayImage = cgImage
        // Force immediate redraw — needsDisplay=true alone defers to the
        // display cycle, which our tight interpreter event loop may starve.
        contentView?.display()
        if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.001), inMode: .default, dequeue: true) {
            convertAndQueue(event)
            NSApp.sendEvent(event)
        }
    }

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        guard let ctx = currentContext else { return }
        ctx.saveGState()
        ctx.resetClip()
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
        ctx.fill(CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        ctx.restoreGState()
    }

    func fillRect(x: Double, y: Double, w: Double, h: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        guard let ctx = currentContext else { return }
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    func fillRRect(x: Double, y: Double, w: Double, h: Double, radius: Double,
                   r: Double, g: Double, b: Double, a: Double) {
        guard let ctx = currentContext else { return }
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
        let path = CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        ctx.addPath(path)
        ctx.fillPath()
    }

    func drawText(_ text: String, x: Double, y: Double, size: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        guard let ctx = currentContext else { return }
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, CGFloat(size), nil)
        let color = CGColor(red: r, green: g, blue: b, alpha: a)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue) {
        let runId = nextTextRunId
        nextTextRunId += 1
        textRuns[runId] = (text, size)

        let font = CTFontCreateWithName("Helvetica Neue" as CFString, CGFloat(size), nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrStr)

        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))

        var glyphs: [MirValue] = []
        var xs: [MirValue] = []
        var ys: [MirValue] = []
        var totalWidth: Double = 0

        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var glyphIDs = [CGGlyph](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphIDs)

            for i in 0..<count {
                glyphs.append(.structVal("Glyph", [
                    "id": .int(Int(glyphIDs[i])),
                    "x_adv": .float(Double(advances[i].width)),
                    "y_adv": .float(0.0),
                    "x_off": .float(0.0),
                    "y_off": .float(0.0)
                ]))
                xs.append(.float(Double(positions[i].x)))
                ys.append(.float(0.0))
            }
            if let last = positions.last, let lastAdv = advances.last {
                totalWidth = Double(last.x) + Double(lastAdv.width)
            }
        }

        let fontId = MirValue.structVal("FontId", ["value": .int(0)])
        let bounds = MirValue.structVal("Rect", [
            "x": .float(0),
            "y": .float(-ascent),
            "w": .float(totalWidth),
            "h": .float(ascent + descent)
        ])
        let glyphRun = MirValue.structVal("GlyphRun", [
            "font": fontId,
            "size": .float(size),
            "glyphs": .array(MirArrayBuffer(glyphs)),
            "xs": .array(MirArrayBuffer(xs)),
            "ys": .array(MirArrayBuffer(ys)),
            "bounds": bounds,
            "_opaque": .int(runId)
        ])
        return (runId, glyphRun)
    }

    func getTextRun(_ opaqueId: Int) -> (String, Double)? {
        return textRuns[opaqueId]
    }

    // MARK: - AppKit event conversion

    func enqueueCloseRequested() {
        eventQueue.append(.enumVal("Event", 17, .unit))
    }

    private func convertAndQueue(_ event: NSEvent) {
        guard let view = contentView else { return }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let loc = view.convert(event.locationInWindow, from: nil)
            eventQueue.append(.enumVal("Event", 6, .tuple([.float(Double(loc.x)), .float(Double(loc.y))])))
        case .leftMouseDown:
            eventQueue.append(.enumVal("Event", 7, .enumVal("MouseButton", 0, .unit)))
        case .leftMouseUp:
            eventQueue.append(.enumVal("Event", 8, .enumVal("MouseButton", 0, .unit)))
        case .rightMouseDown:
            eventQueue.append(.enumVal("Event", 7, .enumVal("MouseButton", 1, .unit)))
        case .rightMouseUp:
            eventQueue.append(.enumVal("Event", 8, .enumVal("MouseButton", 1, .unit)))
        case .keyDown:
            let key = convertKey(event)
            let mods = convertMods(event)
            eventQueue.append(.enumVal("Event", 0, .tuple([key, mods, .bool(event.isARepeat)])))
        case .keyUp:
            let key = convertKey(event)
            let mods = convertMods(event)
            eventQueue.append(.enumVal("Event", 1, .tuple([key, mods])))
        case .scrollWheel:
            eventQueue.append(.enumVal("Event", 9, .tuple([
                .float(Double(event.scrollingDeltaX)),
                .float(Double(event.scrollingDeltaY)),
                .enumVal("ScrollMode", 0, .unit)
            ])))
        default: break
        }
    }

    private func convertKey(_ event: NSEvent) -> MirValue {
        switch event.keyCode {
        case 36: return .enumVal("Key", 0, .unit)
        case 53: return .enumVal("Key", 1, .unit)
        case 51: return .enumVal("Key", 2, .unit)
        case 48: return .enumVal("Key", 3, .unit)
        case 49: return .enumVal("Key", 4, .unit)
        case 126: return .enumVal("Key", 5, .unit)
        case 125: return .enumVal("Key", 6, .unit)
        case 123: return .enumVal("Key", 7, .unit)
        case 124: return .enumVal("Key", 8, .unit)
        case 115: return .enumVal("Key", 9, .unit)
        case 119: return .enumVal("Key", 10, .unit)
        case 116: return .enumVal("Key", 11, .unit)
        case 121: return .enumVal("Key", 12, .unit)
        case 117: return .enumVal("Key", 14, .unit)
        case 122: return .enumVal("Key", 16, .int(1))
        case 120: return .enumVal("Key", 16, .int(2))
        case 99:  return .enumVal("Key", 16, .int(3))
        case 118: return .enumVal("Key", 16, .int(4))
        case 96:  return .enumVal("Key", 16, .int(5))
        case 97:  return .enumVal("Key", 16, .int(6))
        case 98:  return .enumVal("Key", 16, .int(7))
        case 100: return .enumVal("Key", 16, .int(8))
        case 101: return .enumVal("Key", 16, .int(9))
        case 109: return .enumVal("Key", 16, .int(10))
        case 103: return .enumVal("Key", 16, .int(11))
        case 111: return .enumVal("Key", 16, .int(12))
        default: break
        }
        if let chars = event.characters, let c = chars.first {
            switch c {
            case "\r", "\n": return .enumVal("Key", 0, .unit)
            case "\u{1B}":   return .enumVal("Key", 1, .unit)
            case "\u{7F}":   return .enumVal("Key", 2, .unit)
            case "\t":       return .enumVal("Key", 3, .unit)
            case " ":        return .enumVal("Key", 4, .unit)
            default:         return .enumVal("Key", 15, .char(c))
            }
        }
        return .enumVal("Key", 4, .unit)
    }

    private func convertMods(_ event: NSEvent) -> MirValue {
        let flags = event.modifierFlags
        return .structVal("KeyMods", [
            "shift": .bool(flags.contains(.shift)),
            "ctrl": .bool(flags.contains(.control)),
            "alt": .bool(flags.contains(.option)),
            "meta": .bool(flags.contains(.command))
        ])
    }
}

// MARK: - NSView for macOS

final class TGContentView: NSView, NSWindowDelegate {
    weak var gui: TGMacOSGUI?
    var displayImage: CGImage?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgImage = displayImage,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        ))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        gui?.enqueueCloseRequested()
        return false
    }
}

#endif // os(macOS)

// ═══════════════════════════════════════════════════════════════
// MARK: - Linux backend (X11 via dlopen)
// Supports x86_64 and aarch64
// ═══════════════════════════════════════════════════════════════

#if os(Linux)
import Glibc

// X11 constants
private let KeyPressMask:     Int = 1 << 0
private let KeyReleaseMask:   Int = 1 << 1
private let ButtonPressMask:  Int = 1 << 2
private let ButtonReleaseMask: Int = 1 << 3
private let PointerMotionMask: Int = 1 << 6
private let ExposureMask:     Int = 1 << 15
private let StructureNotifyMask: Int = 1 << 17

private let KeyPress:     Int32 = 2
private let KeyRelease:   Int32 = 3
private let ButtonPress:  Int32 = 4
private let ButtonRelease: Int32 = 5
private let MotionNotify: Int32 = 6
private let Expose:       Int32 = 12
private let ClientMessage: Int32 = 33

// X11 function pointer types
private typealias XOpenDisplayFn = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
private typealias XDefaultScreenFn = @convention(c) (OpaquePointer) -> Int32
private typealias XRootWindowFn = @convention(c) (OpaquePointer, Int32) -> UInt
private typealias XCreateSimpleWindowFn = @convention(c) (OpaquePointer, UInt, Int32, Int32, UInt32, UInt32, UInt32, UInt, UInt) -> UInt
private typealias XStoreName_Fn = @convention(c) (OpaquePointer, UInt, UnsafePointer<CChar>) -> Int32
private typealias XSelectInputFn = @convention(c) (OpaquePointer, UInt, Int) -> Int32
private typealias XMapWindowFn = @convention(c) (OpaquePointer, UInt) -> Int32
private typealias XFlushFn = @convention(c) (OpaquePointer) -> Int32
private typealias XPendingFn = @convention(c) (OpaquePointer) -> Int32
private typealias XNextEventFn = @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
private typealias XCreateImageFn = @convention(c) (OpaquePointer, OpaquePointer?, UInt32, Int32, Int32, UnsafeMutablePointer<CChar>, UInt32, UInt32, Int32, Int32) -> OpaquePointer?
private typealias XPutImageFn = @convention(c) (OpaquePointer, UInt, OpaquePointer, OpaquePointer, Int32, Int32, Int32, Int32, UInt32, UInt32) -> Int32
private typealias XCreateGCFn = @convention(c) (OpaquePointer, UInt, UInt, UnsafeRawPointer?) -> OpaquePointer?
private typealias XDefaultVisualFn = @convention(c) (OpaquePointer, Int32) -> OpaquePointer?
private typealias XDefaultDepthFn = @convention(c) (OpaquePointer, Int32) -> Int32
private typealias XInternAtomFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> UInt
private typealias XSetWMProtocolsFn = @convention(c) (OpaquePointer, UInt, UnsafeMutablePointer<UInt>, Int32) -> Int32
private typealias XLookupStringFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>, Int32, UnsafeMutablePointer<UInt>?, UnsafeMutableRawPointer?) -> Int32
private typealias XDestroyImageFn = @convention(c) (OpaquePointer) -> Int32

final class TGLinuxGUI: TGPlatformGUI {
    private(set) var windowWidth: Int = 384
    private(set) var windowHeight: Int = 392
    var hasActiveCanvas: Bool { fb != nil }

    private var fb: TGFramebuffer?
    private var textRunTable = TGTextRunTable()
    private var eventQueue: [MirValue] = []
    private var needsRedraw = true
    private var windowCreated = false

    // X11 state
    private var display: OpaquePointer?
    private var windowId: UInt = 0
    private var gc: OpaquePointer?
    private var screen: Int32 = 0
    private var wmDeleteMessage: UInt = 0

    // dlopen handles
    private var libX11: UnsafeMutableRawPointer?
    private var fn_XOpenDisplay: XOpenDisplayFn?
    private var fn_XDefaultScreen: XDefaultScreenFn?
    private var fn_XRootWindow: XRootWindowFn?
    private var fn_XCreateSimpleWindow: XCreateSimpleWindowFn?
    private var fn_XStoreName: XStoreName_Fn?
    private var fn_XSelectInput: XSelectInputFn?
    private var fn_XMapWindow: XMapWindowFn?
    private var fn_XFlush: XFlushFn?
    private var fn_XPending: XPendingFn?
    private var fn_XNextEvent: XNextEventFn?
    private var fn_XCreateImage: XCreateImageFn?
    private var fn_XPutImage: XPutImageFn?
    private var fn_XCreateGC: XCreateGCFn?
    private var fn_XDefaultVisual: XDefaultVisualFn?
    private var fn_XDefaultDepth: XDefaultDepthFn?
    private var fn_XInternAtom: XInternAtomFn?
    private var fn_XSetWMProtocols: XSetWMProtocolsFn?
    private var fn_XLookupString: XLookupStringFn?
    private var x11Available = false

    init() {
        loadX11()
    }

    private func loadX11() {
        libX11 = dlopen("libX11.so.6", RTLD_LAZY)
        if libX11 == nil { libX11 = dlopen("libX11.so", RTLD_LAZY) }
        guard let lib = libX11 else { return }

        fn_XOpenDisplay = unsafeBitCast(dlsym(lib, "XOpenDisplay"), to: XOpenDisplayFn?.self)
        fn_XDefaultScreen = unsafeBitCast(dlsym(lib, "XDefaultScreen"), to: XDefaultScreenFn?.self)
        fn_XRootWindow = unsafeBitCast(dlsym(lib, "XRootWindow"), to: XRootWindowFn?.self)
        fn_XCreateSimpleWindow = unsafeBitCast(dlsym(lib, "XCreateSimpleWindow"), to: XCreateSimpleWindowFn?.self)
        fn_XStoreName = unsafeBitCast(dlsym(lib, "XStoreName"), to: XStoreName_Fn?.self)
        fn_XSelectInput = unsafeBitCast(dlsym(lib, "XSelectInput"), to: XSelectInputFn?.self)
        fn_XMapWindow = unsafeBitCast(dlsym(lib, "XMapWindow"), to: XMapWindowFn?.self)
        fn_XFlush = unsafeBitCast(dlsym(lib, "XFlush"), to: XFlushFn?.self)
        fn_XPending = unsafeBitCast(dlsym(lib, "XPending"), to: XPendingFn?.self)
        fn_XNextEvent = unsafeBitCast(dlsym(lib, "XNextEvent"), to: XNextEventFn?.self)
        fn_XCreateImage = unsafeBitCast(dlsym(lib, "XCreateImage"), to: XCreateImageFn?.self)
        fn_XPutImage = unsafeBitCast(dlsym(lib, "XPutImage"), to: XPutImageFn?.self)
        fn_XCreateGC = unsafeBitCast(dlsym(lib, "XCreateGC"), to: XCreateGCFn?.self)
        fn_XDefaultVisual = unsafeBitCast(dlsym(lib, "XDefaultVisual"), to: XDefaultVisualFn?.self)
        fn_XDefaultDepth = unsafeBitCast(dlsym(lib, "XDefaultDepth"), to: XDefaultDepthFn?.self)
        fn_XInternAtom = unsafeBitCast(dlsym(lib, "XInternAtom"), to: XInternAtomFn?.self)
        fn_XSetWMProtocols = unsafeBitCast(dlsym(lib, "XSetWMProtocols"), to: XSetWMProtocolsFn?.self)
        fn_XLookupString = unsafeBitCast(dlsym(lib, "XLookupString"), to: XLookupStringFn?.self)

        x11Available = fn_XOpenDisplay != nil && fn_XCreateSimpleWindow != nil
    }

    func ensureWindow(title: String, width: Int, height: Int) {
        guard !windowCreated else { return }
        windowWidth = width
        windowHeight = height
        windowCreated = true

        guard x11Available else { return }

        display = fn_XOpenDisplay!(nil)
        guard let dpy = display else { x11Available = false; return }

        screen = fn_XDefaultScreen!(dpy)
        let root = fn_XRootWindow!(dpy, screen)

        windowId = fn_XCreateSimpleWindow!(dpy, root, 0, 0, UInt32(width), UInt32(height), 1, 0, 0)
        _ = title.withCString { fn_XStoreName!(dpy, windowId, $0) }

        let mask = KeyPressMask | KeyReleaseMask | ButtonPressMask |
                   ButtonReleaseMask | PointerMotionMask | ExposureMask | StructureNotifyMask
        _ = fn_XSelectInput!(dpy, windowId, mask)
        _ = fn_XMapWindow!(dpy, windowId)

        gc = fn_XCreateGC!(dpy, windowId, 0, nil)

        // Register for WM_DELETE_WINDOW
        if let internAtom = fn_XInternAtom, let setProto = fn_XSetWMProtocols {
            wmDeleteMessage = internAtom(dpy, "WM_DELETE_WINDOW", 0)
            var proto = wmDeleteMessage
            _ = setProto(dpy, windowId, &proto, 1)
        }

        _ = fn_XFlush!(dpy)
        needsRedraw = true
    }

    func pollEvent() -> MirValue {
        if x11Available, let dpy = display {
            // Drain pending X11 events
            while fn_XPending!(dpy) > 0 {
                // XEvent is a 192-byte union on both x86_64 and aarch64
                var eventBuf = [UInt8](repeating: 0, count: 192)
                eventBuf.withUnsafeMutableBytes { buf in
                    _ = fn_XNextEvent!(dpy, buf.baseAddress!)
                }
                let eventType = eventBuf.withUnsafeBytes { $0.load(as: Int32.self) }
                convertX11Event(eventType, &eventBuf)
            }
        }

        if needsRedraw {
            needsRedraw = false
            eventQueue.append(.enumVal("Event", 18, .unit))
        }

        if let event = eventQueue.first {
            eventQueue.removeFirst()
            return .enumVal("Option", 0, event)
        }

        // Yield CPU when idle
        usleep(1000)
        return .enumVal("Option", 1, .unit)
    }

    private func convertX11Event(_ type: Int32, _ buf: inout [UInt8]) {
        switch type {
        case MotionNotify:
            // XMotionEvent: x at offset 64, y at offset 68 (both Int32)
            let x = buf.withUnsafeBytes { $0.load(fromByteOffset: 64, as: Int32.self) }
            let y = buf.withUnsafeBytes { $0.load(fromByteOffset: 68, as: Int32.self) }
            eventQueue.append(.enumVal("Event", 6, .tuple([.float(Double(x)), .float(Double(y))])))

        case ButtonPress:
            // XButtonEvent: button at offset 84 (UInt32)
            let button = buf.withUnsafeBytes { $0.load(fromByteOffset: 84, as: UInt32.self) }
            let mb: MirValue
            switch button {
            case 1: mb = .enumVal("MouseButton", 0, .unit)  // Left
            case 2: mb = .enumVal("MouseButton", 2, .unit)  // Middle
            case 3: mb = .enumVal("MouseButton", 1, .unit)  // Right
            default: mb = .enumVal("MouseButton", 3, .int(Int(button)))
            }
            eventQueue.append(.enumVal("Event", 7, mb))

        case ButtonRelease:
            let button = buf.withUnsafeBytes { $0.load(fromByteOffset: 84, as: UInt32.self) }
            let mb: MirValue
            switch button {
            case 1: mb = .enumVal("MouseButton", 0, .unit)
            case 2: mb = .enumVal("MouseButton", 2, .unit)
            case 3: mb = .enumVal("MouseButton", 1, .unit)
            default: mb = .enumVal("MouseButton", 3, .int(Int(button)))
            }
            eventQueue.append(.enumVal("Event", 8, mb))

        case KeyPress:
            let key = convertX11Key(buf)
            let mods = convertX11Mods(buf)
            eventQueue.append(.enumVal("Event", 0, .tuple([key, mods, .bool(false)])))

        case KeyRelease:
            let key = convertX11Key(buf)
            let mods = convertX11Mods(buf)
            eventQueue.append(.enumVal("Event", 1, .tuple([key, mods])))

        case Expose:
            needsRedraw = true

        case ClientMessage:
            // Check for WM_DELETE_WINDOW
            let data = buf.withUnsafeBytes { $0.load(fromByteOffset: 56, as: UInt.self) }
            if data == wmDeleteMessage {
                eventQueue.append(.enumVal("Event", 17, .unit))
            }

        default: break
        }
    }

    private func convertX11Key(_ buf: [UInt8]) -> MirValue {
        // Use XLookupString to get the character
        guard let lookup = fn_XLookupString else {
            return .enumVal("Key", 4, .unit)
        }
        var keysym: UInt = 0
        var charBuf = [CChar](repeating: 0, count: 32)
        var bufCopy = buf
        let len = bufCopy.withUnsafeMutableBytes { rawBuf -> Int32 in
            lookup(rawBuf.baseAddress!, &charBuf, 32, &keysym, nil)
        }

        // Map X11 keysyms
        switch keysym {
        case 0xFF0D: return .enumVal("Key", 0, .unit)  // Return
        case 0xFF1B: return .enumVal("Key", 1, .unit)  // Escape
        case 0xFF08: return .enumVal("Key", 2, .unit)  // BackSpace
        case 0xFF09: return .enumVal("Key", 3, .unit)  // Tab
        case 0x020:  return .enumVal("Key", 4, .unit)  // Space
        case 0xFF52: return .enumVal("Key", 5, .unit)  // Up
        case 0xFF54: return .enumVal("Key", 6, .unit)  // Down
        case 0xFF51: return .enumVal("Key", 7, .unit)  // Left
        case 0xFF53: return .enumVal("Key", 8, .unit)  // Right
        case 0xFF50: return .enumVal("Key", 9, .unit)  // Home
        case 0xFF57: return .enumVal("Key", 10, .unit) // End
        case 0xFF55: return .enumVal("Key", 11, .unit) // PageUp
        case 0xFF56: return .enumVal("Key", 12, .unit) // PageDown
        case 0xFF63: return .enumVal("Key", 13, .unit) // Insert
        case 0xFFFF: return .enumVal("Key", 14, .unit) // Delete
        case 0xFFBE...0xFFC9:                          // F1-F12
            return .enumVal("Key", 16, .int(Int(keysym - 0xFFBE + 1)))
        default: break
        }

        if len > 0, let scalar = Unicode.Scalar(UInt32(charBuf[0] & 0x7F)) {
            return .enumVal("Key", 15, .char(Character(scalar)))
        }
        return .enumVal("Key", 4, .unit)
    }

    private func convertX11Mods(_ buf: [UInt8]) -> MirValue {
        // XKeyEvent: state at offset 80 (UInt32)
        let state = buf.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self) }
        return .structVal("KeyMods", [
            "shift": .bool(state & 1 != 0),      // ShiftMask
            "ctrl":  .bool(state & 4 != 0),       // ControlMask
            "alt":   .bool(state & 8 != 0),       // Mod1Mask
            "meta":  .bool(state & 0x40 != 0)     // Mod4Mask (Super)
        ])
    }

    func requestRedraw() { needsRedraw = true }

    func createSurface() {
        fb = TGFramebuffer(width: windowWidth, height: windowHeight)
    }

    func present() {
        guard let framebuf = fb, x11Available, let dpy = display, let gc = gc else { return }

        // Convert RGBA → BGRA (X11 uses 32-bit BGRA in ZPixmap format)
        let count = framebuf.width * framebuf.height
        var bgraPixels = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            bgraPixels[i * 4 + 0] = framebuf.pixels[i * 4 + 2] // B
            bgraPixels[i * 4 + 1] = framebuf.pixels[i * 4 + 1] // G
            bgraPixels[i * 4 + 2] = framebuf.pixels[i * 4 + 0] // R
            bgraPixels[i * 4 + 3] = framebuf.pixels[i * 4 + 3] // A
        }

        guard let visual = fn_XDefaultVisual?(dpy, screen),
              let createImage = fn_XCreateImage,
              let putImage = fn_XPutImage else { return }

        bgraPixels.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            if let img = createImage(dpy, visual, 24, 2 /* ZPixmap */, 0, ptr,
                                     UInt32(framebuf.width), UInt32(framebuf.height), 32, 0) {
                _ = putImage(dpy, windowId, gc, img, 0, 0, 0, 0,
                            UInt32(framebuf.width), UInt32(framebuf.height))
                // XDestroyImage would free our data pointer, so we detach it
                // Just let the XImage struct leak — it's tiny
            }
        }
        _ = fn_XFlush!(dpy)
    }

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        fb?.clear(r, g, b, a)
    }

    func fillRect(x: Double, y: Double, w: Double, h: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), r: r, g: g, b: b, a: a)
    }

    func fillRRect(x: Double, y: Double, w: Double, h: Double, radius: Double,
                   r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), radius: Int(radius),
                      r: r, g: g, b: b, a: a)
    }

    func drawText(_ text: String, x: Double, y: Double, size: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.drawText(text, x: Int(x), y: Int(y), size: size, r: r, g: g, b: b, a: a)
    }

    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue) {
        return textRunTable.shapeText(text, size: size)
    }

    func getTextRun(_ opaqueId: Int) -> (String, Double)? {
        return textRunTable.get(opaqueId)
    }
}

#endif // os(Linux)

// ═══════════════════════════════════════════════════════════════
// MARK: - Windows backend (Win32 via WinSDK)
// Supports x86_64 and aarch64 (Windows on ARM)
// ═══════════════════════════════════════════════════════════════

#if os(Windows)
import WinSDK

private let WS_OVERLAPPEDWINDOW: UInt32 = 0x00CF0000
private let WS_VISIBLE: UInt32 = 0x10000000
private let CW_USEDEFAULT: Int32 = -2147483648  // 0x80000000

// Messages
private let WM_DESTROY: UInt32 = 0x0002
private let WM_CLOSE: UInt32 = 0x0010
private let WM_PAINT: UInt32 = 0x000F
private let WM_KEYDOWN: UInt32 = 0x0100
private let WM_KEYUP: UInt32 = 0x0101
private let WM_MOUSEMOVE: UInt32 = 0x0200
private let WM_LBUTTONDOWN: UInt32 = 0x0201
private let WM_LBUTTONUP: UInt32 = 0x0202
private let WM_RBUTTONDOWN: UInt32 = 0x0204
private let WM_RBUTTONUP: UInt32 = 0x0205
private let WM_MBUTTONDOWN: UInt32 = 0x0207
private let WM_MBUTTONUP: UInt32 = 0x0208
private let WM_MOUSEWHEEL: UInt32 = 0x020A

// Virtual keys
private let VK_RETURN: Int32 = 0x0D
private let VK_ESCAPE: Int32 = 0x1B
private let VK_BACK: Int32 = 0x08
private let VK_TAB: Int32 = 0x09
private let VK_SPACE: Int32 = 0x20
private let VK_UP: Int32 = 0x26
private let VK_DOWN: Int32 = 0x28
private let VK_LEFT: Int32 = 0x25
private let VK_RIGHT: Int32 = 0x27
private let VK_HOME: Int32 = 0x24
private let VK_END: Int32 = 0x23
private let VK_PRIOR: Int32 = 0x21  // PageUp
private let VK_NEXT: Int32 = 0x22   // PageDown
private let VK_INSERT: Int32 = 0x2D
private let VK_DELETE: Int32 = 0x2E
private let VK_F1: Int32 = 0x70

// Shared event queue for the window proc callback
private var g_windowsEventQueue: [MirValue] = []
private var g_windowsNeedsRedraw = true
private var g_windowsClosed = false

private func tgWindowProc(hwnd: HWND?, message: UInt32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
    switch message {
    case WM_CLOSE:
        g_windowsEventQueue.append(.enumVal("Event", 17, .unit))
        g_windowsClosed = true
        return 0

    case WM_PAINT:
        g_windowsNeedsRedraw = true
        var ps = PAINTSTRUCT()
        let hdc = BeginPaint(hwnd, &ps)
        EndPaint(hwnd, &ps)
        return 0

    case WM_MOUSEMOVE:
        let x = Int16(truncatingIfNeeded: lParam)
        let y = Int16(truncatingIfNeeded: lParam >> 16)
        g_windowsEventQueue.append(.enumVal("Event", 6, .tuple([.float(Double(x)), .float(Double(y))])))
        return 0

    case WM_LBUTTONDOWN:
        g_windowsEventQueue.append(.enumVal("Event", 7, .enumVal("MouseButton", 0, .unit)))
        return 0
    case WM_LBUTTONUP:
        g_windowsEventQueue.append(.enumVal("Event", 8, .enumVal("MouseButton", 0, .unit)))
        return 0
    case WM_RBUTTONDOWN:
        g_windowsEventQueue.append(.enumVal("Event", 7, .enumVal("MouseButton", 1, .unit)))
        return 0
    case WM_RBUTTONUP:
        g_windowsEventQueue.append(.enumVal("Event", 8, .enumVal("MouseButton", 1, .unit)))
        return 0
    case WM_MBUTTONDOWN:
        g_windowsEventQueue.append(.enumVal("Event", 7, .enumVal("MouseButton", 2, .unit)))
        return 0
    case WM_MBUTTONUP:
        g_windowsEventQueue.append(.enumVal("Event", 8, .enumVal("MouseButton", 2, .unit)))
        return 0

    case WM_KEYDOWN:
        let key = convertWin32Key(Int32(wParam))
        let mods = getWin32Mods()
        let isRepeat = MirValue.bool((lParam & 0x40000000) != 0)
        g_windowsEventQueue.append(.enumVal("Event", 0, .tuple([key, mods, isRepeat])))
        return 0

    case WM_KEYUP:
        let key = convertWin32Key(Int32(wParam))
        let mods = getWin32Mods()
        g_windowsEventQueue.append(.enumVal("Event", 1, .tuple([key, mods])))
        return 0

    case WM_MOUSEWHEEL:
        let delta = Double(Int16(truncatingIfNeeded: wParam >> 16)) / 120.0
        g_windowsEventQueue.append(.enumVal("Event", 9, .tuple([.float(0), .float(delta), .enumVal("ScrollMode", 0, .unit)])))
        return 0

    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

private func convertWin32Key(_ vk: Int32) -> MirValue {
    switch vk {
    case VK_RETURN: return .enumVal("Key", 0, .unit)
    case VK_ESCAPE: return .enumVal("Key", 1, .unit)
    case VK_BACK:   return .enumVal("Key", 2, .unit)
    case VK_TAB:    return .enumVal("Key", 3, .unit)
    case VK_SPACE:  return .enumVal("Key", 4, .unit)
    case VK_UP:     return .enumVal("Key", 5, .unit)
    case VK_DOWN:   return .enumVal("Key", 6, .unit)
    case VK_LEFT:   return .enumVal("Key", 7, .unit)
    case VK_RIGHT:  return .enumVal("Key", 8, .unit)
    case VK_HOME:   return .enumVal("Key", 9, .unit)
    case VK_END:    return .enumVal("Key", 10, .unit)
    case VK_PRIOR:  return .enumVal("Key", 11, .unit)
    case VK_NEXT:   return .enumVal("Key", 12, .unit)
    case VK_INSERT: return .enumVal("Key", 13, .unit)
    case VK_DELETE: return .enumVal("Key", 14, .unit)
    default:
        if vk >= VK_F1 && vk <= VK_F1 + 11 {
            return .enumVal("Key", 16, .int(Int(vk - VK_F1 + 1)))
        }
        // Map printable ASCII
        if vk >= 0x30 && vk <= 0x5A {
            let shifted = GetKeyState(0x10) < 0  // VK_SHIFT
            var ch = UInt8(vk)
            if !shifted && ch >= 0x41 && ch <= 0x5A { ch += 32 } // lowercase
            if let scalar = Unicode.Scalar(ch) {
                return .enumVal("Key", 15, .char(Character(scalar)))
            }
        }
        // Map OEM keys for calculator symbols
        let shifted = GetKeyState(0x10) < 0
        switch vk {
        case 0xBB: return .enumVal("Key", 15, .char(shifted ? "+" : "="))  // OEM_PLUS
        case 0xBD: return .enumVal("Key", 15, .char("-"))                 // OEM_MINUS
        case 0xBF: return .enumVal("Key", 15, .char("/"))                 // OEM_2 (/)
        case 0xBA: return .enumVal("Key", 15, .char(shifted ? "*" : ";")) // OEM_1
        default: return .enumVal("Key", 4, .unit)
        }
    }
}

private func getWin32Mods() -> MirValue {
    return .structVal("KeyMods", [
        "shift": .bool(GetKeyState(0x10) < 0),
        "ctrl":  .bool(GetKeyState(0x11) < 0),
        "alt":   .bool(GetKeyState(0x12) < 0),
        "meta":  .bool(GetKeyState(0x5B) < 0 || GetKeyState(0x5C) < 0)
    ])
}

final class TGWindowsGUI: TGPlatformGUI {
    private(set) var windowWidth: Int = 384
    private(set) var windowHeight: Int = 392
    var hasActiveCanvas: Bool { fb != nil }

    private var fb: TGFramebuffer?
    private var textRunTable = TGTextRunTable()
    private var hwnd: HWND?
    private var windowCreated = false

    func ensureWindow(title: String, width: Int, height: Int) {
        guard !windowCreated else { return }
        windowCreated = true
        windowWidth = width
        windowHeight = height

        let className = "TangerineWindow"
        className.withCString(encodedAs: UTF16.self) { classNamePtr in
            var wc = WNDCLASSEXW()
            wc.cbSize = UInt32(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = tgWindowProc
            wc.hInstance = GetModuleHandleW(nil)
            wc.lpszClassName = classNamePtr
            wc.hCursor = LoadCursorW(nil, IDC_ARROW)
            wc.hbrBackground = HBRUSH(bitPattern: 6) // COLOR_WINDOW + 1
            RegisterClassExW(&wc)

            title.withCString(encodedAs: UTF16.self) { titlePtr in
                hwnd = CreateWindowExW(
                    0, classNamePtr, titlePtr,
                    WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                    CW_USEDEFAULT, CW_USEDEFAULT,
                    Int32(width) + 16, Int32(height) + 39, // account for border/title
                    nil, nil, wc.hInstance, nil
                )
            }
        }

        g_windowsNeedsRedraw = true
    }

    func pollEvent() -> MirValue {
        var msg = MSG()
        while PeekMessageW(&msg, nil, 0, 0, 1 /* PM_REMOVE */) {
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }

        if g_windowsNeedsRedraw {
            g_windowsNeedsRedraw = false
            g_windowsEventQueue.append(.enumVal("Event", 18, .unit))
        }

        if let event = g_windowsEventQueue.first {
            g_windowsEventQueue.removeFirst()
            return .enumVal("Option", 0, event)
        }

        Sleep(1) // Yield CPU
        return .enumVal("Option", 1, .unit)
    }

    func requestRedraw() { g_windowsNeedsRedraw = true }

    func createSurface() {
        fb = TGFramebuffer(width: windowWidth, height: windowHeight)
    }

    func present() {
        guard let framebuf = fb, let hwnd = hwnd else { return }
        let hdc = GetDC(hwnd)

        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = UInt32(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(framebuf.width)
        bmi.bmiHeader.biHeight = -Int32(framebuf.height) // top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0 // BI_RGB

        // Convert RGBA → BGRA for Win32 DIB
        let count = framebuf.width * framebuf.height
        var bgraPixels = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            bgraPixels[i * 4 + 0] = framebuf.pixels[i * 4 + 2]
            bgraPixels[i * 4 + 1] = framebuf.pixels[i * 4 + 1]
            bgraPixels[i * 4 + 2] = framebuf.pixels[i * 4 + 0]
            bgraPixels[i * 4 + 3] = framebuf.pixels[i * 4 + 3]
        }

        bgraPixels.withUnsafeBytes { rawBuf in
            SetDIBitsToDevice(hdc, 0, 0,
                              UInt32(framebuf.width), UInt32(framebuf.height),
                              0, 0, 0, UInt32(framebuf.height),
                              rawBuf.baseAddress, &bmi, 0 /* DIB_RGB_COLORS */)
        }
        ReleaseDC(hwnd, hdc)
    }

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        fb?.clear(r, g, b, a)
    }

    func fillRect(x: Double, y: Double, w: Double, h: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), r: r, g: g, b: b, a: a)
    }

    func fillRRect(x: Double, y: Double, w: Double, h: Double, radius: Double,
                   r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), radius: Int(radius),
                      r: r, g: g, b: b, a: a)
    }

    func drawText(_ text: String, x: Double, y: Double, size: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.drawText(text, x: Int(x), y: Int(y), size: size, r: r, g: g, b: b, a: a)
    }

    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue) {
        return textRunTable.shapeText(text, size: size)
    }

    func getTextRun(_ opaqueId: Int) -> (String, Double)? {
        return textRunTable.get(opaqueId)
    }
}

#endif // os(Windows)

// ═══════════════════════════════════════════════════════════════
// MARK: - Software fallback (headless / unknown platform)
// Used when no native window system is available.
// ═══════════════════════════════════════════════════════════════

#if !os(macOS) && !os(Linux) && !os(Windows)

final class TGSoftwareGUI: TGPlatformGUI {
    private(set) var windowWidth: Int = 384
    private(set) var windowHeight: Int = 392
    var hasActiveCanvas: Bool { fb != nil }

    private var fb: TGFramebuffer?
    private var textRunTable = TGTextRunTable()
    private var pollCount = 0

    func ensureWindow(title: String, width: Int, height: Int) {
        windowWidth = width
        windowHeight = height
    }

    func pollEvent() -> MirValue {
        pollCount += 1
        if pollCount == 1 {
            return .enumVal("Option", 0, .enumVal("Event", 18, .unit))
        } else if pollCount == 2 {
            return .enumVal("Option", 0, .enumVal("Event", 17, .unit))
        }
        return .enumVal("Option", 1, .unit)
    }

    func requestRedraw() {}
    func createSurface() { fb = TGFramebuffer(width: windowWidth, height: windowHeight) }
    func present() {}

    func clear(_ r: Double, _ g: Double, _ b: Double, _ a: Double) { fb?.clear(r, g, b, a) }
    func fillRect(x: Double, y: Double, w: Double, h: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), r: r, g: g, b: b, a: a)
    }
    func fillRRect(x: Double, y: Double, w: Double, h: Double, radius: Double,
                   r: Double, g: Double, b: Double, a: Double) {
        fb?.fillRRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h), radius: Int(radius),
                      r: r, g: g, b: b, a: a)
    }
    func drawText(_ text: String, x: Double, y: Double, size: Double,
                  r: Double, g: Double, b: Double, a: Double) {
        fb?.drawText(text, x: Int(x), y: Int(y), size: size, r: r, g: g, b: b, a: a)
    }

    func shapeText(_ text: String, size: Double) -> (id: Int, glyphRun: MirValue) {
        return textRunTable.shapeText(text, size: size)
    }

    func getTextRun(_ opaqueId: Int) -> (String, Double)? {
        return textRunTable.get(opaqueId)
    }
}

#endif
