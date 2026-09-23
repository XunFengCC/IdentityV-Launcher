import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Small POSIX-only primitives for diagnostic output.  FileManager's create
/// APIs follow an existing final-path symlink, which is unacceptable for
/// unattended capture output.
enum MonitorSecureFS {
    static func lstat(_ url: URL) -> stat? { var value = stat(); return Darwin.lstat(url.path, &value) == 0 ? value : nil }
    static func isPrivateDirectory(_ url: URL) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid() else { return false }
        return (s.st_mode & 0o077) == 0 && (s.st_mode & 0o700) == 0o700
    }
    static func isPrivateRegularFile(_ url: URL, allowed: mode_t = 0o600) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid() else { return false }
        return (s.st_mode & 0o777) == allowed
    }
    static func isOwnedRegularFile(_ url: URL) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid() else { return false }
        return true
    }
    static func createDirectoryOneLevel(_ url: URL, raceHook: (() -> Void)? = nil) -> Bool {
        let existed = lstat(url) != nil
        raceHook?()
        if !existed {
            let result = mkdir(url.path, 0o700)
            guard result == 0 || errno == EEXIST else { return false }
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR, before.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { return false }
        var after = stat()
        return fstat(fd, &after) == 0 && (after.st_mode & S_IFMT) == S_IFDIR && after.st_uid == getuid() && (after.st_mode & 0o777) == 0o700
    }
    static func createExclusiveFile(_ url: URL, mode: mode_t = 0o600) -> FileHandle? {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return nil }
        guard fchmod(fd, mode) == 0, isPrivateRegularFile(url, allowed: mode) else { Darwin.close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func canonical(_ url: URL) -> URL? {
        guard let result = Darwin.realpath(url.path, nil) else { return nil }; defer { free(result) }
        return URL(fileURLWithPath: String(cString: result), isDirectory: true)
    }
    static func isDirectChild(_ child: URL, of root: URL) -> Bool {
        child.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
    }
}

struct VisualMetrics: Codable, Equatable {
    var timestamp: TimeInterval
    var status: String
    var captureFPS: Double?
    var sampleChangedFPS: Double?
    var perceptualVisualFPS: Double?
    var meanSampleDelta: Double?
    var changedSampleRatio: Double?
    var currentUnchangedRunMs: Double?
    var maxUnchangedRunMs: Double?
    var targetPID: Int32
    var isUsable: Bool { status == "capturing" && perceptualVisualFPS != nil }
    var localizedDescription: String {
        guard isUsable else { return "画面变化率：\(status)" }
        return String(format: "画面 %.0f FPS · capture %.0f · sample %.0f · 静止 %.0fms", perceptualVisualFPS ?? 0, captureFPS ?? 0, sampleChangedFPS ?? 0, currentUnchangedRunMs ?? 0)
    }
}

struct VisualFinishResult { let succeeded: Bool; let message: String }

/// Pure, intentionally low-resolution frame comparison. Exact hashes remain
/// diagnostic only; perceptual cadence ignores ordinary TAA/noise shimmer.
enum VisualFrameAnalyzer {
    static func perceptuallyChanged(previous: [UInt8], current: [UInt8]) -> (changed: Bool, mean: Double, ratio: Double) {
        guard previous.count == current.count, !current.isEmpty else { return (true, 255, 1) }
        let deltas = zip(previous, current).map { abs(Int($0) - Int($1)) }
        let mean = Double(deltas.reduce(0, +)) / Double(deltas.count)
        let ratio = Double(deltas.filter { $0 >= 12 }.count) / Double(deltas.count)
        return (mean >= 4.0 && ratio >= 0.045, mean, ratio)
    }
    static func fixtureChecks() -> [Bool] {
        let still = Array(repeating: UInt8(80), count: 64)
        let noise = still.enumerated().map { UInt8(80 + ($0.offset % 3) - 1) }
        let moving = still.enumerated().map { $0.offset % 2 == 0 ? UInt8(160) : UInt8(20) }
        let same = perceptuallyChanged(previous: still, current: still)
        let tiny = perceptuallyChanged(previous: still, current: noise)
        let motion = perceptuallyChanged(previous: still, current: moving)
        return [!same.changed, !tiny.changed, motion.changed, motion.mean > tiny.mean, motion.ratio > tiny.ratio]
    }
}

private func sceneSamples(_ pixel: CVPixelBuffer) -> (exact: UInt64, grid: [UInt8]) {
    CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { return (0, []) }
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
    let x0 = width * 14 / 100, xs = max(1, width * 68 / 100), y0 = height * 18 / 100, ys = max(1, height * 60 / 100)
    var hash: UInt64 = 1469598103934665603; var grid: [UInt8] = []; grid.reserveCapacity(32 * 18)
    for sy in 0..<18 { let y = min(height - 1, y0 + (sy * ys + ys / 36) / 18); let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for sx in 0..<32 { let x = min(width - 1, x0 + (sx * xs + xs / 64) / 32); let p = x * 4; let b = row[p], g = row[p + 1], r = row[p + 2]; let luma = UInt8((Int(r) * 54 + Int(g) * 183 + Int(b) * 19) >> 8); grid.append(luma); hash ^= UInt64(r) << 16 | UInt64(g) << 8 | UInt64(b); hash &*= 1099511628211 }
    }
    return (hash, grid)
}

/// The ScreenCaptureKit owner stays in the regular toolbox process.  A tiny
/// display-only accessory executable is deliberately separate: AppKit will
/// otherwise remove a regular app's auxiliary window when Wine moves to its
/// own full-screen Space.  The helper reads this value-only stream from stdin;
/// it has no capture framework, entitlement, preferences, or TCC request path.
final class DisplayOverlayHelper {
    private let executableURL: URL
    private var process: Process?
    private var writer: FileHandle?
    init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IdentityVOverlayDisplay")
    }
    var isRunning: Bool { process?.isRunning == true }
    @discardableResult func show() -> Bool {
        if isRunning { return true }
        stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        let pipe = Pipe(), child = Process()
        child.executableURL = executableURL
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self, weak child] _ in
            DispatchQueue.main.async {
                guard self?.process === child else { return }
                self?.writer = nil
                self?.process = nil
            }
        }
        do {
            try child.run()
            process = child
            writer = pipe.fileHandleForWriting
            return true
        } catch {
            try? pipe.fileHandleForWriting.close()
            return false
        }
    }
    func publish(_ snapshot: OverlayDisplaySnapshot) {
        guard isRunning, let writer, let data = try? JSONEncoder().encode(snapshot) else { return }
        do { try writer.write(contentsOf: data); try writer.write(contentsOf: Data([10])) }
        catch { stop() }
    }
    func stop() {
        // Closing stdin is the normal ownership boundary: the display helper
        // exits on EOF. A bounded terminate is only fallback cleanup.
        let oldWriter = writer; writer = nil
        try? oldWriter?.close()
        guard let child = process else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            if child.isRunning { child.terminate() }
        }
        process = nil
    }
    static func fixtureChecks() -> [Bool] {
        let value = OverlayDisplaySnapshot(cpuLine: "CPU 2%", gpuLine: "GPU 50%  70%", targetPID: 1234, hasLiveData: true)
        let roundTrip = (try? JSONDecoder().decode(OverlayDisplaySnapshot.self, from: JSONEncoder().encode(value))) == value
        let unavailable = DisplayOverlayHelper(executableURL: URL(fileURLWithPath: "/private/tmp/IdentityVOverlayDisplay-does-not-exist"))
        return [roundTrip, !unavailable.show(), !unavailable.isRunning]
    }
}

final class VisualCaptureControllerNative: NSObject, SCStreamOutput, SCStreamDelegate {
    var onUpdate: ((VisualMetrics) -> Void)?
    /// Lifecycle and SCStream callbacks share the main queue, avoiding a
    /// capture-callback/start-stop data race. The ROI is only 576 samples.
    private let queue = DispatchQueue.main
    private struct OutputSession {
        let generation: UInt64; let url: URL; let handle: FileHandle
        var writes: Int; var numericWrites: Int; var failed: Bool
        // A start/status row proves the file opened, not that SCK delivered a
        // usable frame. Keep evidence per record, including reused streams.
        var succeeded: Bool { numericWrites > 0 && !failed }
    }
    private var stream: SCStream?; private var activePID: Int32?; private var output: OutputSession?; private var frames: [Double] = []; private var exact: [Double] = []; private var perceptual: [Double] = []; private var lastHash: UInt64?; private var lastGrid: [UInt8]?; private var lastTime: Double?; private var unchangedStart: Double?; private var maxUnchanged: Double = 0; private var lastEmit: Double = 0; private var generation: UInt64 = 0; private var pendingStart: Task<Void, Never>?; private var numericSamples = 0; private var currentMetrics = VisualMetrics(timestamp: 0, status: "未启动", captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: nil, targetPID: 0); private let freezeStacks = FreezeStackCaptureController(); private var targetWindowID: CGWindowID?; private var targetWindowVisible = false; private var lastVisibilityCheck: Double = 0; private var targetVisibilityConfirmedAt: Double?; private var visibilityRefreshInFlight = false
    private let overlay = DisplayOverlayHelper()
    func publishOverlay(_ snapshot: OverlayDisplaySnapshot) { overlay.publish(snapshot) }
    var statusDescription: String { currentMetrics.localizedDescription }
    @discardableResult func showOverlay() -> Bool { overlay.show() }
    func hideOverlay(hasActiveRecord: Bool) { overlay.stop(); guard !hasActiveRecord else { return }; freezeStacks.disarm(); generation &+= 1; pendingStart?.cancel(); pendingStart = nil; let old = stream; stream = nil; activePID = nil; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; Task { if let old { try? await old.stopCapture() }; self.publishStatus("未启动") } }
    func armAutomaticFreezeStackCapture(captureDirectory: URL, targetPID: Int32) { freezeStacks.arm(captureDirectory: captureDirectory, targetPID: targetPID) }
    func disarmAutomaticFreezeStackCapture() { freezeStacks.disarm() }
    func beginStart(targetPID: Int32, outputURL: URL?) {
        generation &+= 1; let token = generation; pendingStart?.cancel()
        pendingStart = Task { [weak self] in await self?.performStart(targetPID: targetPID, outputURL: outputURL, token: token) }
    }
    private func performStart(targetPID: Int32, outputURL: URL?, token: UInt64) async {
        if !CGPreflightScreenCaptureAccess() { emit(status: "screen-recording-denied"); return }
        guard token == generation, !Task.isCancelled else { return }
        if let outputURL, !prepareOutput(outputURL, token: token) { emit(status: "output-failed"); return }
        if activePID == targetPID, stream != nil { return }
        if let stream { try? await stream.stopCapture() }; guard token == generation else { return }; reset(pid: targetPID)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard token == generation, !Task.isCancelled else { return }
            guard let window = content.windows.filter({ $0.owningApplication?.processID == targetPID && $0.frame.width >= 500 && $0.frame.height >= 300 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { emit(status: "target-window-not-found"); return }
            let config = SCStreamConfiguration(); let aspect = max(window.frame.width / max(window.frame.height, 1), 1); config.width = 480; config.height = max(180, Int(480 / aspect)); config.minimumFrameInterval = CMTime(value: 1, timescale: 120); config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false; config.capturesAudio = false
            let new = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self); try new.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue); try await new.startCapture(); guard token == generation, !Task.isCancelled else { try? await new.stopCapture(); return }; stream = new; targetWindowID = window.windowID; targetWindowVisible = window.isOnScreen; targetVisibilityConfirmedAt = nil; lastVisibilityCheck = 0; pendingStart = nil; emit(status: "capturing")
        } catch { emit(status: "capture-start-failed") }
    }
    func finishRecord(outputURL: URL?, stopIfNoOverlay: Bool) async -> VisualFinishResult {
        guard outputURL != nil else { return .init(succeeded: true, message: "画面变化率：本轮未选择") }
        generation &+= 1; pendingStart?.cancel(); pendingStart = nil
        freezeStacks.disarm()
        let old = stream; if stopIfNoOverlay { stream = nil; activePID = nil; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; if let old { try? await old.stopCapture() } }
        let completed = detachOutput(); let m = currentMetrics
        return completed?.succeeded == true ? .init(succeeded: true, message: "画面变化率：已记录") : .init(succeeded: false, message: "画面变化率：未取得有效数值（\(m.status)）")
    }
    func stream(_ outputStream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === outputStream, type == .screen, sample.isValid, let attach = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete, let pixel = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp.seconds; guard time.isFinite else { return }; let sampled = sceneSamples(pixel); frames.append(time); let exactChanged = lastHash != nil && lastHash != sampled.exact; if exactChanged { exact.append(time) }; let compare: (changed: Bool, mean: Double, ratio: Double) = lastGrid.map { VisualFrameAnalyzer.perceptuallyChanged(previous: $0, current: sampled.grid) } ?? (changed: false, mean: 0, ratio: 0); if compare.changed { perceptual.append(time); unchangedStart = nil } else if unchangedStart == nil { unchangedStart = lastTime ?? time }; lastHash = sampled.exact; lastGrid = sampled.grid; lastTime = time
        let cutoff = time - 1; frames.removeAll { $0 < cutoff }; exact.removeAll { $0 < cutoff }; perceptual.removeAll { $0 < cutoff }; let unchanged = (unchangedStart.map { (time - $0) * 1000 }) ?? 0; maxUnchanged = max(maxUnchanged, unchanged)
        if time - lastVisibilityCheck >= 0.25 { lastVisibilityCheck = time; refreshTargetVisibility() }
        let visibilityFresh = targetVisibilityConfirmedAt.map { time - $0 <= 0.5 } == true
        freezeStacks.observe(timestamp: time, perceptuallyChanged: compare.changed, captureFPS: Double(frames.count), stillDurationMs: unchanged, streamIsActive: stream != nil && output != nil, targetVisible: targetWindowVisible && visibilityFresh)
        if time - lastEmit >= 0.25 { lastEmit = time; numericSamples += 1; emit(metrics: .init(timestamp: Date().timeIntervalSince1970, status: "capturing", captureFPS: Double(frames.count), sampleChangedFPS: Double(exact.count), perceptualVisualFPS: Double(perceptual.count), meanSampleDelta: compare.mean, changedSampleRatio: compare.ratio, currentUnchangedRunMs: unchanged, maxUnchangedRunMs: maxUnchanged, targetPID: activePID ?? 0)) }
    }
    func stream(_ stopped: SCStream, didStopWithError error: Error) { guard stopped === stream else { return }; freezeStacks.disarm(); stream = nil; activePID = nil; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; publishStatus("capture-stopped") }
    private func reset(pid: Int32) { activePID = pid; frames = []; exact = []; perceptual = []; lastHash = nil; lastGrid = nil; lastTime = nil; unchangedStart = nil; maxUnchanged = 0; lastEmit = 0; numericSamples = 0; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; lastVisibilityCheck = 0; visibilityRefreshInFlight = false }
    private func emit(status: String) { emit(metrics: .init(timestamp: Date().timeIntervalSince1970, status: status, captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: nil, targetPID: activePID ?? 0)) }
    private func emit(metrics: VisualMetrics) { currentMetrics = metrics; if let data = try? JSONEncoder().encode(metrics) { append(data, isNumeric: metrics.isUsable) }; DispatchQueue.main.async { self.onUpdate?(metrics) } }
    private func publishStatus(_ status: String) { let value = VisualMetrics(timestamp: Date().timeIntervalSince1970, status: status, captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: maxUnchanged, targetPID: activePID ?? 0); currentMetrics = value; DispatchQueue.main.async { self.onUpdate?(value) } }
    private func prepareOutput(_ url: URL, token: UInt64) -> Bool {
        // Showing the overlay may re-enter start during this same capture.
        // Keep the exclusively opened handle and advance its generation;
        // reopening the existing path fails and strands subsequent writes.
        if let current = output {
            guard current.url == url, !current.failed else { return false }
            output = .init(generation: token, url: current.url, handle: current.handle, writes: current.writes, numericWrites: current.numericWrites, failed: false)
            return true
        }
        let d = url.deletingLastPathComponent()
        guard MonitorSecureFS.isPrivateDirectory(d), MonitorSecureFS.lstat(url) == nil, let handle = MonitorSecureFS.createExclusiveFile(url) else { return false }
        output = .init(generation: token, url: url, handle: handle, writes: 0, numericWrites: 0, failed: false); return true
    }
    private func detachOutput() -> OutputSession? { guard let old = output else { return nil }; output = nil; try? old.handle.close(); return old }
    private func append(_ data: Data, isNumeric: Bool = false) {
        guard var session = output, session.generation == generation, !session.failed else { return }
        do { try session.handle.write(contentsOf: data); try session.handle.write(contentsOf: Data([10])); session.writes += 1; if isNumeric { session.numericWrites += 1 }; output = session }
        catch { session.failed = true; output = session; _ = detachOutput(); freezeStacks.disarm(); publishStatus("output-failed") }
    }
    private func stopCurrentStream() async { freezeStacks.disarm(); if let current = stream { try? await current.stopCapture() }; stream = nil; activePID = nil; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; emit(status: "未启动") }
    private func refreshTargetVisibility() {
        guard !visibilityRefreshInFlight, let expectedID = targetWindowID, let expectedPID = activePID else { return }
        visibilityRefreshInFlight = true
        Task { [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let self else { return }
            self.visibilityRefreshInFlight = false
            guard self.targetWindowID == expectedID, self.activePID == expectedPID else { return }
            self.targetWindowVisible = content?.windows.contains { $0.windowID == expectedID && $0.owningApplication?.processID == expectedPID && $0.isOnScreen } == true
            self.targetVisibilityConfirmedAt = self.targetWindowVisible ? self.lastTime : nil
        }
    }
    static func outputFixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-visual-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        let normal = root.appendingPathComponent("normal.jsonl"), victim = root.appendingPathComponent("victim"), link = root.appendingPathComponent("link.jsonl")
        let controller = VisualCaptureControllerNative()
        let normalPrepared = controller.prepareOutput(normal, token: 11)
        controller.generation = 11; controller.emit(status: "capturing")
        let statusOnlyRejected = controller.output?.succeeded == false
        controller.emit(metrics: .init(timestamp: 1, status: "capturing", captureFPS: 60, sampleChangedFPS: 0, perceptualVisualFPS: 0, meanSampleDelta: 0, changedSampleRatio: 0, currentUnchangedRunMs: 1000, maxUnchangedRunMs: 1000, targetPID: 123))
        let sameSessionPrepared = controller.prepareOutput(normal, token: 12)
        controller.generation = 12; controller.append(Data("{}".utf8)); let first = controller.detachOutput()
        let existingRejected = !controller.prepareOutput(normal, token: 12)
        _ = MonitorSecureFS.createExclusiveFile(victim); try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: victim.path)
        let symlinkRejected = !controller.prepareOutput(link, token: 13) && (try? String(contentsOf: victim, encoding: .utf8)) == ""
        let second = root.appendingPathComponent("second.jsonl"); let reusePrepared = controller.prepareOutput(second, token: 14); let reuseZero = controller.output?.writes == 0 && controller.output?.numericWrites == 0 && controller.output?.succeeded == false; _ = controller.detachOutput()
        let full = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/full")); if let full { controller.output = .init(generation: 14, url: second, handle: full, writes: 0, numericWrites: 0, failed: false); controller.generation = 14; controller.append(Data("{}".utf8)) }; let failedDetached = controller.output == nil
        return [normalPrepared, statusOnlyRejected, sameSessionPrepared, first?.writes == 3, first?.numericWrites == 1, first?.succeeded == true, existingRejected, symlinkRejected, reusePrepared, reuseZero, failedDetached] + DisplayOverlayHelper.fixtureChecks()
    }
}

typealias VisualCaptureController = VisualCaptureControllerNative
