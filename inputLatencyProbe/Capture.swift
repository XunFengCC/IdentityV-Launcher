import Cocoa
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Darwin

struct SelectedWindow {
    let window: SCWindow
    let metadata: TargetWindowMetadata
}

enum PermissionGate {
    static func requireCapturePermissions() throws {
        let inputAllowed = CGPreflightListenEventAccess()
        let screenAllowed = CGPreflightScreenCaptureAccess()

        if !inputAllowed {
            _ = CGRequestListenEventAccess()
        }
        if !screenAllowed {
            _ = CGRequestScreenCaptureAccess()
        }

        guard inputAllowed && screenAllowed else {
            var missing: [String] = []
            if !inputAllowed {
                missing.append("输入监控（用于只读 mouseMoved）")
            }
            if !screenAllowed {
                missing.append("屏幕与系统音频录制（实际不采音频，只读取目标窗口）")
            }
            throw ProbeFailure.permissions(
                "缺少权限：\(missing.joined(separator: "、"))。\n"
                + "已向 macOS 发起权限请求。请到“系统设置 → 隐私与安全性”授权终端或 IdentityVInputLatencyProbe，然后完全退出并重新运行本工具。\n"
                + "本工具只监听输入、只抓第五人格主窗口，不会注入输入或修改系统设置。"
            )
        }
    }
}

enum TargetWindowFinder {
    static func waitUntilTargetIsFrontmost(timeoutSeconds: Double = 30) async throws {
        print("等待第五人格切到前台（最长 \(Int(timeoutSeconds)) 秒）……")
        let deadline = hostClockSeconds() + timeoutSeconds
        while hostClockSeconds() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleIdentifier {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let actual = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "未知"
        throw ProbeFailure.target(
            "未等到前台应用 \(targetBundleIdentifier)，当前前台 bundle id：\(actual)。请启动第五人格 Mac 后重试。"
        )
    }

    static func selectMainWindow() async throws -> SelectedWindow {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == targetBundleIdentifier else {
            throw ProbeFailure.target("第五人格 Mac 当前不在前台；尚未开始任何窗口捕获。")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ProbeFailure.capture(
                "ScreenCaptureKit 无法枚举窗口：\(error.localizedDescription)。请检查屏幕录制权限后重试。"
            )
        }

        let processIdentifier = frontmost.processIdentifier
        let candidates = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.bundleIdentifier == targetBundleIdentifier
                && owner.processID == processIdentifier
                && window.frame.width >= 500
                && window.frame.height >= 300
        }

        guard let selected = candidates.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else {
            throw ProbeFailure.target(
                "未找到 \(targetBundleIdentifier) 的主游戏窗口（要求至少 500×300）。小窗和其他应用不会被捕获。"
            )
        }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleIdentifier else {
            throw ProbeFailure.target("枚举窗口期间第五人格离开了前台；为避免抓错窗口，本次没有开始捕获。")
        }

        let captureSize = lowResolutionSize(for: selected.frame)
        let ownerPID = selected.owningApplication?.processID ?? processIdentifier
        return SelectedWindow(
            window: selected,
            metadata: TargetWindowMetadata(
                bundleIdentifier: targetBundleIdentifier,
                processIdentifier: ownerPID,
                windowIdentifier: selected.windowID,
                title: selected.title ?? "",
                x: selected.frame.origin.x,
                y: selected.frame.origin.y,
                width: selected.frame.width,
                height: selected.frame.height,
                captureWidth: captureSize.width,
                captureHeight: captureSize.height
            )
        )
    }

    static func targetIsStillFrontmost(processIdentifier: Int32) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.bundleIdentifier == targetBundleIdentifier
            && frontmost.processIdentifier == processIdentifier
    }

    private static func lowResolutionSize(for frame: CGRect) -> (width: Int, height: Int) {
        let width = 320
        let aspect = max(frame.width / max(frame.height, 1), 0.5)
        var height = Int((Double(width) / aspect).rounded())
        height = min(240, max(100, height))
        if height % 2 != 0 { height += 1 }
        return (width, height)
    }
}

struct SampleSnapshot {
    let startHostTimeSeconds: Double
    let endHostTimeSeconds: Double
    let mouseEvents: [MouseSample]
    let frameSamples: [FrameSample]
}

final class SampleStore {
    private let lock = NSLock()
    private var recording = false
    private var startTime = 0.0
    private var endTime = 0.0
    private var mouseEvents: [MouseSample] = []
    private var frameSamples: [FrameSample] = []

    func activate(at hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        mouseEvents.removeAll(keepingCapacity: true)
        frameSamples.removeAll(keepingCapacity: true)
        startTime = hostTime
        endTime = hostTime
        recording = true
    }

    func deactivate(at hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        endTime = hostTime
        recording = false
    }

    func append(mouse sample: MouseSample) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, sample.analysisTimeSeconds >= startTime else { return }
        var stored = sample
        stored.sequence = mouseEvents.count
        mouseEvents.append(stored)
    }

    func append(frame sample: FrameSample) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, sample.analysisTimeSeconds >= startTime else { return }
        var stored = sample
        stored.sequence = frameSamples.count
        frameSamples.append(stored)
    }

    func snapshot() -> SampleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SampleSnapshot(
            startHostTimeSeconds: startTime,
            endHostTimeSeconds: endTime,
            mouseEvents: mouseEvents,
            frameSamples: frameSamples
        )
    }
}

private let inputEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<InputRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class InputRecorder {
    private let store: SampleStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let stateLock = NSLock()
    private var reenableCountStorage = 0

    init(store: SampleStore) {
        self.store = store
    }

    var reenableCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return reenableCountStorage
    }

    func start() throws {
        let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ProbeFailure.permissions(
                "无法创建只读 CGEventTap。请在“系统设置 → 隐私与安全性 → 输入监控”授权后重新运行。"
            )
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ProbeFailure.capture("无法把 CGEventTap 加入主运行循环。")
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                stateLock.lock()
                reenableCountStorage += 1
                stateLock.unlock()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .mouseMoved else { return }

        let callbackTime = hostClockSeconds()
        let rawTimestamp = event.timestamp
        let eventTime = Double(rawTimestamp) / 1_000_000_000
        let timestampIsAligned = eventTime.isFinite && abs(callbackTime - eventTime) < 10
        let analysisTime = timestampIsAligned ? eventTime : callbackTime
        let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        let deltaY = event.getIntegerValueField(.mouseEventDeltaY)

        store.append(mouse: MouseSample(
            sequence: 0,
            eventTimestampNanoseconds: rawTimestamp,
            eventTimestampSeconds: eventTime,
            analysisTimeSeconds: analysisTime,
            callbackHostTimeSeconds: callbackTime,
            callbackDelayMilliseconds: (callbackTime - eventTime) * 1_000,
            deltaX: deltaX,
            deltaY: deltaY,
            energy: hypot(Double(deltaX), Double(deltaY)),
            timestampSource: timestampIsAligned ? "cg_event_timestamp" : "callback_host_fallback"
        ))
    }
}

private let machSecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    guard info.denom != 0 else { return 0 }
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

final class FrameRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let store: SampleStore
    private let sampleQueue = DispatchQueue(
        label: "com.xunfeng.identityv.input-latency-probe.frames",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var previousLuma: [UInt8]?
    private var previousFrameTime: Double?
    private var completeFrameCountStorage = 0
    private var streamErrorStorage: String?

    init(store: SampleStore) {
        self.store = store
    }

    var completeFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completeFrameCountStorage
    }

    var streamError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamErrorStorage
    }

    func start(selectedWindow: SelectedWindow) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = selectedWindow.metadata.captureWidth
        configuration.height = selectedWindow.metadata.captureHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: selectedWindow.window)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            stream = newStream
            try await newStream.startCapture()
        } catch {
            stream = nil
            throw ProbeFailure.capture(
                "ScreenCaptureKit 启动失败：\(error.localizedDescription)。请检查屏幕录制权限和游戏窗口状态。"
            )
        }
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            recordStreamErrorIfEmpty("停止捕获时出错：\(error.localizedDescription)")
        }
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let statusRaw = integer(attachment[.status]),
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let callbackTime = hostClockSeconds()
        let presentationTime = finiteOrNil(sampleBuffer.presentationTimeStamp.seconds)
        let displayMachTime = unsignedInteger(attachment[.displayTime])
        let displayTime = displayMachTime.map { Double($0) * machSecondsPerTick }

        let analysisTime: Double
        let timestampSource: String
        if let displayTime, displayTime.isFinite, abs(callbackTime - displayTime) < 10 {
            analysisTime = displayTime
            timestampSource = "sc_display_time"
        } else if let presentationTime, abs(callbackTime - presentationTime) < 10 {
            analysisTime = presentationTime
            timestampSource = "sample_presentation_time"
        } else {
            analysisTime = callbackTime
            timestampSource = "callback_host_fallback"
        }

        guard let currentLuma = sampledLuma(pixelBuffer) else { return }
        let interval = previousFrameTime.map { analysisTime - $0 }
        let differences = previousLuma.flatMap { differenceMetrics($0, currentLuma) }
        let validInterval = interval.flatMap { value -> Double? in
            value > 0 && value <= 1 ? value : nil
        }
        let visualEnergy = differences.flatMap { metrics in
            validInterval.map { metrics.meanAbsolute / $0 }
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let grid = gridSize(width: width, height: height)
        store.append(frame: FrameSample(
            sequence: 0,
            analysisTimeSeconds: analysisTime,
            presentationTimeSeconds: presentationTime,
            displayMachTime: displayMachTime,
            displayTimeSeconds: finiteOrNil(displayTime),
            callbackHostTimeSeconds: callbackTime,
            callbackDelayMilliseconds: (callbackTime - analysisTime) * 1_000,
            frameIntervalSeconds: validInterval,
            meanAbsoluteLumaDifference: differences?.meanAbsolute,
            rmsLumaDifference: differences?.rms,
            changedPixelFraction: differences?.changedFraction,
            visualEnergyPerSecond: visualEnergy,
            timestampSource: timestampSource,
            captureWidth: width,
            captureHeight: height,
            sampleGridWidth: grid.width,
            sampleGridHeight: grid.height
        ))

        previousLuma = currentLuma
        previousFrameTime = analysisTime
        stateLock.lock()
        completeFrameCountStorage += 1
        stateLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordStreamError(error.localizedDescription)
    }

    private func recordStreamError(_ message: String) {
        stateLock.lock()
        streamErrorStorage = message
        stateLock.unlock()
    }

    private func recordStreamErrorIfEmpty(_ message: String) {
        stateLock.lock()
        if streamErrorStorage == nil {
            streamErrorStorage = message
        }
        stateLock.unlock()
    }

    private func sampledLuma(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let grid = gridSize(width: width, height: height)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: grid.width * grid.height)

        for gridY in 0..<grid.height {
            let sourceY = min(height - 1, (gridY * height + grid.height / 2) / grid.height)
            let row = bytes.advanced(by: sourceY * bytesPerRow)
            for gridX in 0..<grid.width {
                let sourceX = min(width - 1, (gridX * width + grid.width / 2) / grid.width)
                let pixel = row.advanced(by: sourceX * 4)
                let blue = Int(pixel[0])
                let green = Int(pixel[1])
                let red = Int(pixel[2])
                luma[gridY * grid.width + gridX] = UInt8(
                    min(255, (29 * blue + 150 * green + 77 * red) >> 8)
                )
            }
        }
        return luma
    }

    private func gridSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let gridWidth = min(160, max(1, width))
        let proportionalHeight = Int(
            (Double(gridWidth) * Double(height) / Double(max(width, 1))).rounded()
        )
        return (gridWidth, min(90, max(1, proportionalHeight)))
    }

    private func differenceMetrics(
        _ previous: [UInt8],
        _ current: [UInt8]
    ) -> (meanAbsolute: Double, rms: Double, changedFraction: Double)? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var absoluteSum = 0.0
        var squaredSum = 0.0
        var changedCount = 0
        for index in current.indices {
            let difference = abs(Int(current[index]) - Int(previous[index]))
            absoluteSum += Double(difference)
            squaredSum += Double(difference * difference)
            if difference >= 6 { changedCount += 1 }
        }
        let count = Double(current.count)
        return (
            meanAbsolute: absoluteSum / count / 255,
            rms: sqrt(squaredSum / count) / 255,
            changedFraction: Double(changedCount) / count
        )
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func unsignedInteger(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? NSNumber { return value.uint64Value }
        return nil
    }
}
