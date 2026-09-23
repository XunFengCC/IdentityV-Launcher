import AVFoundation
import Foundation

// 只验证「辅助进程输出 → 授权状态」的解析契约，不发起任何 TCC 调用，
// 因此在任何责任方（终端/自动化会话）下都安全，可进构建自检。
// 目的：这道解析决定了启动器是"继续启动游戏"还是"拦下来引导去设置"，
// 解析错会让她看到与实际不符的提示，所以固定用例钉住行为。

var failures = 0
func expect(_ text: String, _ want: AVAuthorizationStatus?, _ label: String) {
    let got = MicrophoneAuthorization.parseHelperOutput(text)
    if got != want {
        print("FAIL \(label): 输入=\(text.debugDescription) 期望=\(String(describing: want)) 实际=\(String(describing: got))")
        failures += 1
    }
}

expect("MICROPHONE_AUTHORIZATION=authorized\n", .authorized, "已授权")
expect("MICROPHONE_AUTHORIZATION=denied\n", .denied, "已拒绝")
expect("MICROPHONE_AUTHORIZATION=restricted\n", .restricted, "受限")
expect("MICROPHONE_AUTHORIZATION=notDetermined\n", .notDetermined, "未决定")
expect("噪音行\nMICROPHONE_AUTHORIZATION=authorized\n尾巴\n", .authorized, "夹杂其他输出")
expect("MICROPHONE_AUTHORIZATION= authorized \n", .authorized, "带空白")
expect("MICROPHONE_AUTHORIZATION=\n", nil, "空值当未知")
expect("MICROPHONE_AUTHORIZATION=whatever\n", nil, "未知取值当未知")
expect("完全无关的输出\n", nil, "没有契约行")

if failures == 0 {
    print("麦克风授权辅助进程输出解析自检通过。")
} else {
    print("麦克风授权辅助进程输出解析自检失败：\(failures) 项")
    exit(1)
}
