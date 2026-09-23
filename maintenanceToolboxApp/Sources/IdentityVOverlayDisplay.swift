import AppKit
import Foundation

// This executable is intentionally display-only. It is launched by the
// regular Fifth Personality Toolbox and receives metrics through stdin. Never
// add ScreenCaptureKit, CGRequestScreenCaptureAccess, preferences, or a bundle
// identity here: there must be one user-visible toolbox and one TCC requester.
struct OverlayDisplayInputBuffer {
    static let maximumRecordBytes = 16 * 1024
    private(set) var buffer = Data()
    private(set) var discardingOversizeRecord = false
    mutating func consume(_ data: Data) -> [OverlayDisplaySnapshot] {
        var values: [OverlayDisplaySnapshot] = []
        for byte in data {
            if discardingOversizeRecord {
                if byte == 10 { discardingOversizeRecord = false }
                continue
            }
            if byte == 10 {
                defer { buffer.removeAll(keepingCapacity: true) }
                if let value = try? JSONDecoder().decode(OverlayDisplaySnapshot.self, from: buffer) { values.append(value) }
                continue
            }
            if buffer.count >= Self.maximumRecordBytes {
                buffer.removeAll(keepingCapacity: false)
                discardingOversizeRecord = true
                continue
            }
            buffer.append(byte)
        }
        return values
    }
    static func fixtureChecks() -> [Bool] {
        let expected = OverlayDisplaySnapshot(cpuLine: "a", gpuLine: "b", targetPID: 42, hasLiveData: true)
        let line = (try? JSONEncoder().encode(expected)) ?? Data()
        var malformed = OverlayDisplayInputBuffer()
        let malformedResult = malformed.consume(Data("not-json\n".utf8) + line + Data([10]))
        var oversized = OverlayDisplayInputBuffer()
        let tooLong = Data(repeating: 88, count: Self.maximumRecordBytes + 1)
        let oversizedResult = oversized.consume(tooLong + Data([10]) + line + Data([10]))
        return [malformedResult == [expected], oversizedResult == [expected], oversized.buffer.isEmpty, !oversized.discardingOversizeRecord]
    }
}

final class OverlayDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayDisplayView: NSView {
    static let horizontalInset: CGFloat = 12
    static let panelHeight: CGFloat = 64
    /// Both lines and the width measurement must share one font.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    var snapshot = OverlayDisplaySnapshot(cpuLine: "CPU --", gpuLine: "GPU --  --", targetPID: 0, hasLiveData: false)
    private var dragPoint: NSPoint?

    /// Two lines need only their measured text plus the same 12 pt inset used
    /// while drawing. Digit runs are measured as fixed 3-digit placeholders:
    /// the numbers change every sample, and a tight window must not pulse
    /// wider and narrower with them. A rarer 4-digit value widens the window
    /// once instead of being clipped.
    static func measuredWidth(cpuLine: String, gpuLine: String) -> CGFloat {
        func width(_ text: String) -> CGFloat {
            (stabilized(text) as NSString).size(withAttributes: [.font: font]).width
        }
        return ceil(max(width(cpuLine), width(gpuLine)) + 2 * horizontalInset)
    }
    /// Digit-run normalizer used only for measurement, never for drawing.
    static func stabilized(_ text: String) -> String {
        var result = "", digits = 0
        func flush() {
            if digits > 0 { result += String(repeating: "8", count: max(3, digits)); digits = 0 }
        }
        for character in text {
            if character.isNumber { digits += 1 } else { flush(); result.append(character) }
        }
        flush()
        return result
    }
    /// Anti-jitter fixtures: equal widths across digit-count changes, a wider
    /// window only when a value genuinely outgrows the placeholder, and a
    /// window that stays tight around the text.
    static func layoutFixtureChecks() -> [Bool] {
        let short = measuredWidth(cpuLine: "CPU 5%", gpuLine: "总 40%")
        let longerDigits = measuredWidth(cpuLine: "CPU 125%", gpuLine: "总 400%")
        let outgrown = measuredWidth(cpuLine: "CPU 1025%", gpuLine: "总 40%")
        return [short == longerDigits, outgrown > short, short > 4 * horizontalInset]
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.04, alpha: 0.58).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        draw(snapshot.cpuLine, Self.horizontalInset, 35, .white)
        draw(snapshot.gpuLine, Self.horizontalInset, 12, NSColor(calibratedRed: 0.60, green: 0.90, blue: 1, alpha: 0.98))
    }
    private func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ color: NSColor) {
        text.draw(at: NSPoint(x: x, y: y), withAttributes: [.font: Self.font, .foregroundColor: color])
    }
    override func mouseDown(with event: NSEvent) { dragPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragPoint else { return }
        let now = event.locationInWindow; var frame = window.frame
        frame.origin.x += now.x - start.x; frame.origin.y += now.y - start.y
        window.setFrame(frame, display: true)
    }
}

final class OverlayDisplayApplication: NSObject, NSApplicationDelegate {
    private let view = OverlayDisplayView(frame: NSRect(x: 0, y: 0, width: 1, height: OverlayDisplayView.panelHeight))
    private var input = OverlayDisplayInputBuffer()
    private var panel: NSPanel?
    private var activationObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let size = NSSize(width: OverlayDisplayView.measuredWidth(cpuLine: view.snapshot.cpuLine, gpuLine: view.snapshot.gpuLine), height: OverlayDisplayView.panelHeight)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.minX + 64, y: visible.maxY - size.height - 28, width: size.width, height: size.height)
        let window = OverlayDisplayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.76
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
        panel = window
        // Deliberately not ordered front yet: only a live snapshot for the
        // frontmost game presents the window, so startup never flashes an
        // empty placeholder.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPresentation()
        }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
    private func consume(_ data: Data) {
        for snapshot in input.consume(data) {
            view.snapshot = snapshot
            view.needsDisplay = true
            resizePanel(to: snapshot)
            refreshPresentation()
        }
    }
    private func resizePanel(to snapshot: OverlayDisplaySnapshot) {
        guard let panel else { return }
        let width = OverlayDisplayView.measuredWidth(cpuLine: snapshot.cpuLine, gpuLine: snapshot.gpuLine)
        guard abs(panel.frame.width - width) >= 0.5 else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: width, height: panel.frame.height)), display: true)
    }
    /// Application switches are the timely hide/restore trigger; a data update
    /// re-evaluates the same gate and can never re-present the window on its
    /// own while another app is frontmost.
    private func refreshPresentation() {
        guard let panel else { return }
        let visible = OverlayVisibility.shouldPresent(isSnapshotLive: view.snapshot.hasLiveData, targetPID: view.snapshot.targetPID, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

@main struct IdentityVOverlayDisplayMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let value = OverlayDisplaySnapshot(cpuLine: "a", gpuLine: "b", targetPID: 42, hasLiveData: true)
            guard (try? JSONDecoder().decode(OverlayDisplaySnapshot.self, from: JSONEncoder().encode(value))) == value,
                  OverlayDisplayInputBuffer.fixtureChecks().allSatisfy({ $0 }),
                  OverlayVisibility.fixtureChecks().allSatisfy({ $0 }),
                  OverlayDisplayView.layoutFixtureChecks().allSatisfy({ $0 }) else { exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = OverlayDisplayApplication()
        app.delegate = delegate
        app.run()
    }
}
