import AVFoundation
import AppKit
import Foundation

/// 麦克风授权的最小封装。
///
/// 为什么需要它：2026-09-19 排到「进大厅卡死」的根因是 macOS 麦克风隐私授权被拒——
/// TCC 从**责任 App**（也就是启动这个游戏的 App）的 Info.plist 取 `NSMicrophoneUsageDescription`，
/// 拿到就弹授权框、拿不到就直接拒绝；被拒后游戏内语音引擎（ccmini/WebRTC）开不了采集流，
/// 客户端会一直等在「进入大厅」的加载界面，表现为"游戏卡死"。
///
/// **安全边界（务必先读）**：`requestAccess` 会在"责任链里找不到带说明字段的 App"时
/// 被 TCC 直接杀掉进程（实测：从终端/自动化会话 `open` 启动本 App 时，责任方是终端宿主
/// 而不是本 App，一申请就 abort）。因此本文件默认只做**只读状态检查 + 明确提示**：
/// 真正的授权弹窗交给"游戏自己请求"（游戏的责任 App 就是启动器，它带着说明字段，实测
/// 会 `found usage string` → `display_prompt`）。若将来要用主动申请，必须在一个**独立的
/// 辅助进程**里做（它的责任方是启动器，万一被拒也只死辅助进程，不会连带启动器）。
enum MicrophoneAuthorization {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static var isAuthorized: Bool { status == .authorized }

    /// 未决定时申请一次（**危险**：责任链里没有带说明字段的 App 时会被 TCC 杀掉，
    /// 见文件头的安全边界；当前产品路径不调用它，保留仅用于将来在独立辅助进程里使用）。
    /// 回调固定在主线程。
    static func requestIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            if Thread.isMainThread { completion(granted) }
            else { DispatchQueue.main.async { completion(granted) } }
        }
        switch status {
        case .authorized:
            finish(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in finish(granted) }
        case .denied, .restricted:
            finish(false)
        @unknown default:
            finish(false)
        }
    }

    /// 通过**独立辅助进程**发起系统申请（产品路径用的就是这条，安全）。
    ///
    /// 为什么安全：辅助进程是本 App 的子进程，TCC 的责任方因此是本 App（带说明字段→会弹框）；
    /// 万一责任链异常被 TCC 拒绝，被终止的也只是辅助进程，启动器本体不受影响。
    /// 返回申请之后的实际状态；找不到辅助进程或它异常退出时，回退到只读状态（不冒险在 App 内直接申请）。
    /// 回调固定在主线程。
    static func requestViaHelper(timeout: TimeInterval = 180,
                                 _ completion: @escaping (AVAuthorizationStatus) -> Void) {
        let finish: (AVAuthorizationStatus) -> Void = { resolved in
            if Thread.isMainThread { completion(resolved) }
            else { DispatchQueue.main.async { completion(resolved) } }
        }
        guard let helper = helperURL() else {
            finish(status)
            return
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--request"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            // 输出只有一行、远小于管道缓冲，因此子进程退出后再整体读取不会死锁。
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            finish(parseHelperOutput(text) ?? status)
        }
        do {
            try process.run()
        } catch {
            finish(status)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
    }

    /// 辅助进程的路径：随启动器一起安装的 Contents/Helpers/IdentityVMicrophoneAuthorization。
    static func helperURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/IdentityVMicrophoneAuthorization")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 解析辅助进程的输出契约：MICROPHONE_AUTHORIZATION=authorized|denied|restricted|notDetermined。
    static func parseHelperOutput(_ text: String) -> AVAuthorizationStatus? {
        let prefix = "MICROPHONE_AUTHORIZATION="
        guard let line = text.split(separator: "\n").map(String.init)
            .first(where: { $0.hasPrefix(prefix) }) else { return nil }
        switch line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) {
        case "authorized": return .authorized
        case "denied": return .denied
        case "restricted": return .restricted
        case "notDetermined": return .notDetermined
        default: return nil
        }
    }

    /// 拒绝/受限时的引导文案（授权缺失时不能直接启动游戏：会卡在「进入大厅」十几分钟）。
    static var deniedGuidanceMessage: String {
        "麦克风未授权，游戏会卡在「进入大厅」：请在弹出的系统设置里打开「第五人格启动器」的麦克风开关，再回来点启动游戏。"
    }

    /// 拒绝后的提示文案；已授权时返回 nil。
    static var warningMessage: String? {
        switch status {
        case .authorized:
            return nil
        case .denied, .restricted:
            return "麦克风未授权：游戏内语音会失败，并可能卡在「进入大厅」。请到 系统设置 → 隐私与安全性 → 麦克风 打开「第五人格启动器」后重启游戏。"
        case .notDetermined:
            return "麦克风尚未授权：首次启动游戏时请在系统弹窗上点「允许」，否则语音会失败并可能卡在「进入大厅」。"
        @unknown default:
            return nil
        }
    }

    /// 打开 系统设置 → 隐私与安全性 → 麦克风。
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
