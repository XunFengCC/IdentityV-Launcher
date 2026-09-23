import AppKit
import Foundation
import SwiftUI

private let hangPromptTitle = "游戏可能卡住了"

/// Keeps stdin framing bounded and recovers after an oversized or malformed
/// record. The launcher owns the pipe, so a prompt helper must never treat a
/// partial write or arbitrary line as permission to display UI.
struct HangPromptInputBuffer {
    static let maximumRecordBytes = 4 * 1024
    private(set) var buffer = Data()
    private(set) var discardingOversizeRecord = false

    mutating func consume(_ data: Data) -> [HangPromptSnapshot] {
        var snapshots: [HangPromptSnapshot] = []
        for byte in data {
            if discardingOversizeRecord {
                if byte == 0x0A {
                    discardingOversizeRecord = false
                }
                continue
            }
            if byte == 0x0A {
                defer { buffer.removeAll(keepingCapacity: true) }
                if let snapshot = try? JSONDecoder().decode(HangPromptSnapshot.self, from: buffer),
                   Self.isDisplayable(snapshot) {
                    snapshots.append(snapshot)
                }
                continue
            }
            guard buffer.count < Self.maximumRecordBytes else {
                buffer.removeAll(keepingCapacity: false)
                discardingOversizeRecord = true
                continue
            }
            buffer.append(byte)
        }
        return snapshots
    }

    private static func isDisplayable(_ snapshot: HangPromptSnapshot) -> Bool {
        if snapshot.kind != nil && snapshot.kind != "hang" && snapshot.kind != "recovered" { return false }
        if let countdown = snapshot.countdown, countdown < 1 || countdown > 60 { return false }
        guard !snapshot.title.isEmpty, snapshot.title.utf8.count <= 80,
              snapshot.title.rangeOfCharacter(from: .controlCharacters) == nil,
              !snapshot.id.isEmpty,
              snapshot.id.utf8.count <= 256,
              snapshot.id.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
              ) == nil else { return false }
        return true
    }

    static func fixtureChecks() -> [Bool] {
        let expected = HangPromptSnapshot(id: "fixture-1", title: hangPromptTitle)
        let encoded = (try? JSONEncoder().encode(expected)) ?? Data()
        var roundTrip = HangPromptInputBuffer()
        let decoded = roundTrip.consume(encoded + Data([0x0A]))

        var malformed = HangPromptInputBuffer()
        let malformedResult = malformed.consume(
            Data("{\"id\":\"fixture-2\",\"title\":\"\"}\n".utf8)
                + encoded
                + Data([0x0A])
        )

        var oversized = HangPromptInputBuffer()
        let recovery = oversized.consume(
            Data(repeating: 0x78, count: Self.maximumRecordBytes + 1)
                + Data([0x0A])
                + encoded
                + Data([0x0A])
        )

        var partial = HangPromptInputBuffer()
        let firstHalf = encoded.prefix(encoded.count / 2)
        let secondHalf = encoded.dropFirst(encoded.count / 2)
        let noPartialDisplay = partial.consume(Data(firstHalf)).isEmpty
        let completed = partial.consume(Data(secondHalf) + Data([0x0A]))

        return [
            decoded == [expected],
            malformedResult == [expected],
            recovery == [expected],
            oversized.buffer.isEmpty && !oversized.discardingOversizeRecord,
            noPartialDisplay,
            completed == [expected]
        ]
    }
}

@MainActor
private final class HangPromptModel: ObservableObject {
    @Published var snapshot: HangPromptSnapshot
    /// Set once a recovery record arrives: the helper must close itself even if
    /// no further record ever comes, so the reminder cannot cover live gameplay.
    @Published var autoCloseAt: Date?
    private let sendAction: (HangPromptAction) -> Void
    private var sent = false

    init(snapshot: HangPromptSnapshot, sendAction: @escaping (HangPromptAction) -> Void) {
        self.snapshot = snapshot
        self.sendAction = sendAction
    }

    func replace(with snapshot: HangPromptSnapshot) {
        guard !sent else { return }
        self.snapshot = snapshot
        if snapshot.isRecovery {
            // Close one second after the last displayed number (1), with a small
            // tolerance so the panel is never torn down mid-frame.
            autoCloseAt = Date().addingTimeInterval(1.6)
        }
    }

    func choose(_ action: String) {
        guard !sent, action == "wait" || action == "restart" else { return }
        sent = true
        sendAction(HangPromptAction(id: snapshot.id, action: action))
    }
}

/// Shown after the game is observed running again. It carries no controls on
/// purpose: the situation resolved itself, so the only correct action is to get
/// out of the way. It keeps the same passive panel contract (never key, never
/// activating, never moving the pointer).
private struct HangPromptRecoveryView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: NSFont.systemFontSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 300)
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .padding(1)
    }
}

private struct HangPromptView: View {
    @ObservedObject var model: HangPromptModel

    var body: some View {
        // Keep the reminder compact and use system button styles. It is
        // intentionally not an NSAlert: its modal response API cannot keep
        // keyboard focus with the game. No icon is needed for this short prompt.
        VStack(spacing: 12) {
            Text(model.snapshot.title)
                .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if #available(macOS 26.0, *) {
                HStack(spacing: 8) {
                    Button(role: .destructive) { model.choose("restart") } label: {
                        Text("重启游戏").frame(maxWidth: .infinity)
                    }.buttonStyle(.glass)
                    Button { model.choose("wait") } label: {
                        Text("继续等").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent)
                }.buttonBorderShape(.capsule).controlSize(.regular)
            } else {
                HStack(spacing: 8) {
                    Button("重启游戏") { model.choose("restart") }
                    Button("继续等") { model.choose("wait") }
                }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 260)
        .background {
            if #available(macOS 26.0, *) {
                // Clear glass changes only the backdrop. Reducing window
                // alpha would also fade the text and hit targets together.
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .padding(1)
    }
}

private final class HangPromptHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HangPromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func contractChecks() -> [Bool] {
        let panel = HangPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 262, height: 176),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        defer { panel.close() }
        return [
            !panel.styleMask.contains(.titled),
            panel.styleMask.contains(.nonactivatingPanel),
            !panel.canBecomeKey,
            !panel.canBecomeMain
        ]
    }
}

@MainActor
private final class HangPromptApplication: NSObject, NSApplicationDelegate {
    private var input = HangPromptInputBuffer()
    private var panel: HangPromptPanel?
    private var model: HangPromptModel?

    private var autoCloseTimer: Timer?

    /// Recovery auto-close: the reminder is only useful while the game is stuck,
    /// so once recovery is observed the panel ticks 5→1 and then removes itself
    /// without any click. The timer is polled (0.25 s) against the model's
    /// deadline instead of counting ticks, so a delayed run loop cannot leave the
    /// panel on screen longer than the deadline.
    func scheduleAutoClose(for model: HangPromptModel) {
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak model] _ in
            guard let self, let model, let deadline = model.autoCloseAt else {
                self?.autoCloseTimer?.invalidate()
                self?.autoCloseTimer = nil
                return
            }
            if Date() >= deadline { self.finish() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let records = self.input.consume(data)
                for record in records {
                    self.show(record)
                }
                if data.isEmpty {
                    self.finish()
                }
            }
        }
    }

    private func show(_ snapshot: HangPromptSnapshot) {
        if let model {
            model.replace(with: snapshot)
            panel?.orderFrontRegardless()
            if snapshot.isRecovery { scheduleAutoClose(for: model) }
            return
        }

        let model = HangPromptModel(snapshot: snapshot) { [weak self] action in
            self?.write(action)
        }
        // Keep readable, enabled button styling without making this panel
        // key or activating the app; this environment value is visual only.
        let hostingView = Self.contentView(model: model)
        let panel = HangPromptPanel(
            contentRect: Self.frameForCurrentScreen(size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        self.model = model
        self.panel = panel
        if snapshot.isRecovery { scheduleAutoClose(for: model) }
        // This is intentionally the only presentation call. A nonactivating
        // panel must not activate the helper or move the player's cursor.
        panel.orderFrontRegardless()
    }

    private func write(_ action: HangPromptAction) {
        guard action.action == "wait" || action.action == "restart" else { return }
        guard let data = try? JSONEncoder().encode(action) else {
            finish()
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        try? FileHandle.standardOutput.synchronize()
        finish()
    }

    private func finish() {
        FileHandle.standardInput.readabilityHandler = nil
        panel?.orderOut(nil)
        NSApp.terminate(nil)
    }

    private static func contentView(model: HangPromptModel) -> HangPromptHostingView {
        // This makes control labels readable without changing focus. It does
        // not force active glass: on macOS 27 a non-key window still has a
        // more opaque material. See the dated validation record before
        // replacing this with a private appearance/focus workaround.
        if model.snapshot.isRecovery {
            // The countdown text itself carries the number, so the helper does
            // not need to re-render per second: the launcher sends 5,4,3,2,1.
            return HangPromptHostingView(rootView: AnyView(
                HangPromptRecoveryView(title: model.snapshot.title).environment(\.appearsActive, true)
            ))
        }
        return HangPromptHostingView(rootView: AnyView(
            HangPromptView(model: model).environment(\.appearsActive, true)
        ))
    }

    #if HANG_PROMPT_RENDER_PREVIEW
    /// Developer-only layout probe: no window ordering or restart actions.
    /// AppKit's bitmap cache omits compositor-backed glass/control layers;
    /// it cannot validate their appearance against a live game background.
    static func renderPreview(to url: URL) throws {
        NSApp.setActivationPolicy(.accessory)
        let model = HangPromptModel(snapshot: .init(id: "layout-preview", title: hangPromptTitle)) { _ in }
        let view = contentView(model: model)
        let size = view.fittingSize
        let panel = HangPromptPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        print("离屏布局预览：\(Int(size.width))×\(Int(size.height))；没有显示窗口或连接游戏操作。")
    }
    #endif

    private static func frameForCurrentScreen(size: NSSize) -> NSRect {
        let cursor = NSEvent.mouseLocation
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSScreen.screens.first(where: { $0.frame.contains(cursor) })?.visibleFrame ?? fallback
        return NSRect(
            x: visible.minX + 40,
            y: visible.maxY - 75 - size.height,
            width: size.width,
            height: size.height
        )
    }
}

@main
struct IdentityVHangPromptMain {
    static func main() {
        #if HANG_PROMPT_RENDER_PREVIEW
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            _ = NSApplication.shared
            do {
                try HangPromptApplication.renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } catch {
                FileHandle.standardError.write(Data("离屏预览失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--self-test") {
            let checks = HangPromptInputBuffer.fixtureChecks() + HangPromptPanel.contractChecks()
                + HangPromptRecovery.fixtureChecks()
            guard checks.allSatisfy({ $0 }) else {
                FileHandle.standardError.write(Data("疑似卡死提示自检失败：\(checks)\n".utf8))
                exit(1)
            }
            print("疑似卡死提示自检通过。")
            return
        }

        let app = NSApplication.shared
        let delegate = HangPromptApplication()
        app.delegate = delegate
        app.run()
    }
}
