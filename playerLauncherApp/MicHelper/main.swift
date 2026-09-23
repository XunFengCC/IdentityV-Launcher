import AVFoundation
import Foundation

/// 独立的麦克风授权辅助进程（由启动器 App 作为父进程调用）。
///
/// 为什么必须是独立进程：`AVCaptureDevice.requestAccess` 在"责任链里找不到带
/// `NSMicrophoneUsageDescription` 的 App"时会被 TCC 直接杀掉进程（2026-09-19 实测：
/// 从终端/自动化会话启动启动器时，启动器自己一申请就被 SIGABRT）。把这个调用放在
/// 辅助进程里，责任方是启动器（它带着说明字段），即使被拒也只死这个辅助进程，
/// 启动器本体不受影响。
///
/// 输出契约（stdout，单行）：
///   MICROPHONE_AUTHORIZATION=authorized|denied|restricted|notDetermined
/// 参数：
///   --status   只读查询（默认）
///   --request  未决定时发起一次系统申请，等用户点完弹窗后再打印最终状态
/// 退出码：0=打印了状态；2=参数错误。
///
/// 复现与边界：该工具的判定等同于系统设置里"麦克风"对启动器这一项的授权；
/// 授权记录挂在启动器 App 上，游戏作为它的子进程随之获得麦克风。
/// 2026-09-19 的「进大厅卡死」根因就是这条授权缺失（语音引擎开不了采集流）。

func statusName(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let wantRequest: Bool
switch args.first {
case nil, "--status": wantRequest = false
case "--request": wantRequest = true
default:
    FileHandle.standardError.write(Data("usage: IdentityVMicrophoneAuthorization [--status|--request]\n".utf8))
    exit(2)
}

var status = AVCaptureDevice.authorizationStatus(for: .audio)
if wantRequest && status == .notDetermined {
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
    // 弹窗可能等一会儿才被点；上限 120 秒，超时后按当前状态输出。
    _ = semaphore.wait(timeout: .now() + 120)
    status = AVCaptureDevice.authorizationStatus(for: .audio)
}
print("MICROPHONE_AUTHORIZATION=\(statusName(status))")
