import Cocoa
import Foundation
import Darwin

private struct CommandLineOptions {
    var durationSeconds = 18.0
    var selfTest = false
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                guard index + 1 < arguments.count,
                      let duration = Double(arguments[index + 1]),
                      duration >= 3,
                      duration <= 120 else {
                    throw ProbeFailure.usage("--duration 需要 3–120 之间的秒数；正式测量建议 15–20 秒。")
                }
                options.durationSeconds = duration
                index += 2
            case "--self-test":
                options.selfTest = true
                index += 1
            case "--help", "-h":
                options.showHelp = true
                index += 1
            default:
                throw ProbeFailure.usage("未知参数：\(arguments[index])。使用 --help 查看用法。")
            }
        }
        return options
    }
}

@main
struct IdentityVInputLatencyProbe {
    static func main() async {
        do {
            let options = try CommandLineOptions.parse(CommandLine.arguments)
            if options.showHelp {
                printUsage()
                return
            }
            if options.selfTest {
                try runSelfTest()
                return
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            try await runProbe(durationSeconds: options.durationSeconds)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fputs("\n错误：\(message)\n", stderr)
            exit(1)
        }
    }

    private static func runProbe(durationSeconds: Double) async throws {
        print("第五人格输入到画面延迟探针 1.0")
        print("边界：\(measurementBoundary)")
        print("安全：CGEventTap 为 listenOnly；不注入输入、不改系统设置、不保存画面或音频。\n")

        try PermissionGate.requireCapturePermissions()
        try await TargetWindowFinder.waitUntilTargetIsFrontmost()
        let selectedWindow = try await TargetWindowFinder.selectMainWindow()
        print(
            "已锁定主窗口：id=\(selectedWindow.metadata.windowIdentifier) "
            + "\(Int(selectedWindow.metadata.width))×\(Int(selectedWindow.metadata.height))，"
            + "低分辨率采样 \(selectedWindow.metadata.captureWidth)×\(selectedWindow.metadata.captureHeight)。"
        )

        let store = SampleStore()
        let inputRecorder = InputRecorder(store: store)
        let frameRecorder = FrameRecorder(store: store)
        var captureStarted = false

        do {
            try inputRecorder.start()
            try await frameRecorder.start(selectedWindow: selectedWindow)
            captureStarted = true

            try await Task.sleep(nanoseconds: 750_000_000)
            guard frameRecorder.completeFrameCount >= 2 else {
                throw ProbeFailure.capture(
                    "ScreenCaptureKit 已启动但没有收到完整画面帧。请确认游戏窗口可见并检查屏幕录制权限。"
                )
            }
            guard TargetWindowFinder.targetIsStillFrontmost(
                processIdentifier: selectedWindow.metadata.processIdentifier
            ) else {
                throw ProbeFailure.target("准备采样时第五人格已离开前台，本次没有记录数据。")
            }

            print("准备完成。请对准静态墙面；听到提示音后连续左右甩鼠，直到第二声提示音。")
            for remaining in stride(from: 3, through: 1, by: -1) {
                print("\(remaining)…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard TargetWindowFinder.targetIsStillFrontmost(
                    processIdentifier: selectedWindow.metadata.processIdentifier
                ) else {
                    throw ProbeFailure.target("倒计时期间第五人格离开了前台，本次没有记录数据。")
                }
            }

            NSSound.beep()
            let startTime = hostClockSeconds()
            store.activate(at: startTime)
            print("开始采样 \(posix("%.1f", durationSeconds)) 秒……")

            var runWarnings: [String] = []
            if durationSeconds < 15 {
                runWarnings.append("采样时长短于建议的 15–20 秒，置信度可能下降。")
            }
            let plannedEnd = startTime + durationSeconds
            var nextProgress = startTime + 5
            while hostClockSeconds() < plannedEnd {
                try await Task.sleep(nanoseconds: 100_000_000)
                let now = hostClockSeconds()

                if !TargetWindowFinder.targetIsStillFrontmost(
                    processIdentifier: selectedWindow.metadata.processIdentifier
                ) {
                    runWarnings.append("测量因第五人格离开前台而提前停止；离开前台后没有继续捕获。")
                    break
                }
                if let streamError = frameRecorder.streamError {
                    runWarnings.append("ScreenCaptureKit 流提前停止：\(streamError)")
                    break
                }
                if now >= nextProgress {
                    let remaining = max(0, plannedEnd - now)
                    print("剩余约 \(Int(ceil(remaining))) 秒……")
                    nextProgress += 5
                }
            }

            let endTime = hostClockSeconds()
            store.deactivate(at: endTime)
            NSSound.beep()
            await frameRecorder.stop()
            captureStarted = false
            inputRecorder.stop()

            let snapshot = store.snapshot()
            let eventFallbackCount = snapshot.mouseEvents.filter {
                $0.timestampSource == "callback_host_fallback"
            }.count
            let frameFallbackCount = snapshot.frameSamples.filter {
                $0.timestampSource == "callback_host_fallback"
            }.count
            if eventFallbackCount > 0 {
                runWarnings.append("有 \(eventFallbackCount) 个输入样本无法对齐原始 CGEvent 时钟，改用了回调主机时钟。")
            }
            if frameFallbackCount > 0 {
                runWarnings.append("有 \(frameFallbackCount) 个画面样本缺少可对齐的显示时间，改用了回调主机时钟。")
            }
            if inputRecorder.reenableCount > 0 {
                runWarnings.append("CGEventTap 测量中被系统暂停并自动恢复 \(inputRecorder.reenableCount) 次。")
            }

            let analysis = LatencyAnalyzer.analyze(
                mouseEvents: snapshot.mouseEvents,
                frameSamples: snapshot.frameSamples,
                extraWarnings: runWarnings
            )
            let metadata = SessionMetadata(
                schemaVersion: 1,
                toolVersion: "1.0.0",
                startedAt: ISO8601DateFormatter().string(
                    from: Date(timeIntervalSinceNow: snapshot.startHostTimeSeconds - hostClockSeconds())
                ),
                requestedDurationSeconds: durationSeconds,
                recordedDurationSeconds: max(
                    0,
                    snapshot.endHostTimeSeconds - snapshot.startHostTimeSeconds
                ),
                startHostTimeSeconds: snapshot.startHostTimeSeconds,
                endHostTimeSeconds: snapshot.endHostTimeSeconds,
                target: selectedWindow.metadata,
                eventTapMode: "CGEventTap.cgSessionEventTap.listenOnly.mouseMoved",
                screenCaptureMode: "SCContentFilter.desktopIndependentWindow.exactBundleID.largestWindow",
                capturesCursor: false,
                capturesAudio: false,
                storesFrames: false,
                eventTapReenableCount: inputRecorder.reenableCount,
                measurementBoundary: measurementBoundary
            )
            let outputDirectory = try OutputWriter.write(
                metadata: metadata,
                analysis: analysis,
                mouseEvents: snapshot.mouseEvents,
                frameSamples: snapshot.frameSamples
            )
            printResult(analysis, outputDirectory: outputDirectory)
        } catch {
            store.deactivate(at: hostClockSeconds())
            if captureStarted {
                await frameRecorder.stop()
            }
            inputRecorder.stop()
            throw error
        }
    }

    private static func printResult(_ analysis: LatencyAnalysis, outputDirectory: URL) {
        print("\n采样完成。")
        if analysis.valid, let latency = analysis.softwareLatencyMilliseconds {
            print("估算 software input-to-visible-window latency：\(posix("%.1f", latency)) ms")
            print(
                "置信度：\(analysis.confidenceLevel) "
                + "(\(posix("%.2f", analysis.confidenceScore)))，"
                + "峰值相关 \(posix("%.3f", analysis.peakCorrelation ?? 0))"
            )
        } else {
            print("本次没有形成有效延迟估算，原始样本仍已保存。")
        }
        for warning in analysis.warnings {
            print("提示：\(warning)")
        }
        print("结果目录：\(outputDirectory.path)")
        print("测量边界：不包含显示器扫描输出和像素响应，也不等同于手到光子的物理延迟。")
    }

    private static func printUsage() {
        print(
            """
            用法：
              IdentityVInputLatencyProbe [--duration 秒]
              IdentityVInputLatencyProbe --self-test

            默认测量 18 秒；正式测量建议 15–20 秒。
            工具会等待 bundle id 为 \(targetBundleIdentifier) 的第五人格切到前台，
            严格选择该进程中面积最大的 >=500×300 窗口。
            """
        )
    }

    private static func runSelfTest() throws {
        let trueLagMilliseconds = 73.0
        let baseTime = 10_000.0
        let duration = 18.5
        let eventStep = 0.004
        let frameStep = 1.0 / 60.0
        var events: [MouseSample] = []
        var frames: [FrameSample] = []

        var t = 0.0
        while t <= duration {
            let energyRate = syntheticSignal(t)
            let eventTime = baseTime + t
            events.append(MouseSample(
                sequence: events.count,
                eventTimestampNanoseconds: UInt64(eventTime * 1_000_000_000),
                eventTimestampSeconds: eventTime,
                analysisTimeSeconds: eventTime,
                callbackHostTimeSeconds: eventTime + 0.0002,
                callbackDelayMilliseconds: 0.2,
                deltaX: 1,
                deltaY: 0,
                energy: energyRate * eventStep,
                timestampSource: "synthetic"
            ))
            t += eventStep
        }

        t = 0.30
        while t <= 18.0 {
            let center = t - frameStep / 2 - trueLagMilliseconds / 1_000
            let deterministicNoise = 0.018 * sin(2 * .pi * 7.31 * t)
            let visualRate = max(0, syntheticSignal(center) + deterministicNoise)
            let frameTime = baseTime + t
            frames.append(FrameSample(
                sequence: frames.count,
                analysisTimeSeconds: frameTime,
                presentationTimeSeconds: frameTime,
                displayMachTime: nil,
                displayTimeSeconds: frameTime,
                callbackHostTimeSeconds: frameTime + 0.001,
                callbackDelayMilliseconds: 1,
                frameIntervalSeconds: frameStep,
                meanAbsoluteLumaDifference: visualRate * frameStep,
                rmsLumaDifference: visualRate * frameStep,
                changedPixelFraction: min(1, visualRate * 0.2),
                visualEnergyPerSecond: visualRate,
                timestampSource: "synthetic",
                captureWidth: 320,
                captureHeight: 190,
                sampleGridWidth: 160,
                sampleGridHeight: 90
            ))
            t += frameStep
        }

        let analysis = LatencyAnalyzer.analyze(mouseEvents: events, frameSamples: frames)
        guard let estimate = analysis.softwareLatencyMilliseconds,
              abs(estimate - trueLagMilliseconds) <= 3 else {
            throw ProbeFailure.capture(
                "分析自测失败：预期 \(trueLagMilliseconds) ms，得到 \(analysis.softwareLatencyMilliseconds.map { posix("%.2f", $0) } ?? "nil") ms。"
            )
        }
        print(
            "分析自测通过：注入 \(posix("%.1f", trueLagMilliseconds)) ms，"
            + "估算 \(posix("%.2f", estimate)) ms，"
            + "峰值相关 \(posix("%.3f", analysis.peakCorrelation ?? 0))。"
        )
    }

    private static func syntheticSignal(_ time: Double) -> Double {
        let slow = 0.78 * sin(2 * .pi * 0.41 * time + 0.2)
        let medium = 0.46 * sin(2 * .pi * 1.17 * time + 1.1)
        let fast = 0.28 * sin(2 * .pi * 3.73 * time + 0.7)
        let stepped = sin(2 * .pi * 0.19 * time + 0.4) > 0.45 ? 0.38 : -0.12
        return max(0.05, 1.35 + slow + medium + fast + stepped)
    }
}
