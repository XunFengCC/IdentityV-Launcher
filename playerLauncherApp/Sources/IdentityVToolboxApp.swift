import AppKit
import Darwin
import SwiftUI

enum ToolboxLaunchLocationGuard {
    /// Deliberately lexical: this runs before the app touches Bundle.main or
    /// asks the file system to resolve anything inside a mounted disk image.
    static func blocksLaunch(executablePath: String) -> Bool {
        executablePath == "/Volumes" || executablePath.hasPrefix("/Volumes/")
    }
}

#if !TOOLBOX_LAUNCH_LOCATION_SELF_TEST
@main
struct IdentityVToolboxApp: App {
    @NSApplicationDelegateAdaptor(ToolboxAppDelegate.self) private var appDelegate
    @StateObject private var model: ToolboxViewModel

    init() {
        // This executes before ToolboxViewModel can start status, download, or
        // removable-volume work. The guard itself performs no filesystem
        // resolution on the mounted image; macOS may still read that volume in
        // order to execute an App that the user opened directly inside a DMG.
        // LaunchServices supplies an absolute executable path here. Do not
        // inspect Bundle.main first: doing so can itself access a mounted DMG
        // before we have told the user to install the app.
        if ToolboxLaunchLocationGuard.blocksLaunch(executablePath: CommandLine.arguments[0]) {
            let alert = NSAlert()
            alert.messageText = "请先把第五人格启动器拖到应用程序文件夹"
            alert.informativeText = "请从磁盘映像中拖到“应用程序”后，再打开启动器。"
            alert.alertStyle = .warning
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }
        _model = StateObject(wrappedValue: ToolboxViewModel())
    }

    var body: some Scene {
        Window("第五人格启动器", id: "identityv-toolbox-main") {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                ProductLauncherView()
                    .environmentObject(model)
            }
                .frame(minWidth: 680, minHeight: 420)
        }
        .defaultSize(width: 680, height: 420)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("关于") { appDelegate.showAbout() }
            }
            CommandGroup(replacing: .appVisibility) {
                Button("隐藏") { NSApplication.shared.hide(nil) }
                    .keyboardShortcut("h", modifiers: .command)
                Button("隐藏其他") { NSApplication.shared.hideOtherApplications(nil) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Button("显示全部") { NSApplication.shared.unhideAllApplications(nil) }
            }
            CommandMenu("第五人格") {
                Toggle(
                    "疑似卡死时提醒",
                    isOn: Binding(
                        get: { model.hangWarningsEnabled },
                        set: { model.setHangWarningsEnabled($0) }
                    )
                )
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

final class ToolboxAppDelegate: NSObject, NSApplicationDelegate {
    func showAbout() {
        // Use the system layout and typography, as in Apple's own apps.
        // Suppress the internal build suffix; the full release label includes RC.
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "第五人格启动器",
            .applicationVersion: LauncherRelease.displayVersion,
            .version: ""
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: {
                !$0.isSheet && $0.sheetParent == nil &&
                ($0.identifier?.rawValue == "identityv-toolbox-main" || $0.title == "第五人格启动器")
            }) else { return }
            // Starts from the smallest fixed layout that accommodates the
            // header, game card, dual lower cards and footer without scrolling.
            // Subsequent user resizing is still remembered normally.
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = true

            // Alpha 1 uses the smallest complete layout as a fixed baseline.
            // The App may temporarily grow vertically while an installer is
            // showing progress, then returns here when the operation finishes.
            window.setContentSize(NSSize(width: 680, height: 420))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The launcher-owned hang monitor must keep observing a game after
        // the player closes this window. Quit remains explicit from the app
        // menu, so closing the panel does not silently stop protection.
        false
    }
}

#else
@main
struct ToolboxLaunchLocationSelfTest {
    static func main() {
        let checks = [
            ToolboxLaunchLocationGuard.blocksLaunch(executablePath: "/Volumes/IdentityV/第五人格启动器.app/Contents/MacOS/第五人格启动器"),
            !ToolboxLaunchLocationGuard.blocksLaunch(executablePath: "/Applications/第五人格启动器.app/Contents/MacOS/第五人格启动器"),
            !ToolboxLaunchLocationGuard.blocksLaunch(executablePath: "/Users/dev/projects/identityV/playerLauncherApp/build/第五人格启动器.app/Contents/MacOS/第五人格启动器"),
            !ToolboxLaunchLocationGuard.blocksLaunch(executablePath: "./第五人格启动器"),
        ]
        guard checks.allSatisfy({ $0 }) else {
            FileHandle.standardError.write(Data("启动位置守卫自检失败：\(checks)\n".utf8))
            exit(1)
        }
        print("启动位置守卫自检通过。")
    }
}
#endif
