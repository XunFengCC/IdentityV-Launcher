import AppKit
import Combine
import Foundation
import SwiftUI

enum MonitorGameProcessMatcher {
    static func gamePID(in snapshot: String) -> Int32? {
        snapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let f = String(line).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard f.count == 3, let pid = Int32(f[0]), let uid = UInt32(f[1]), uid == getuid(), isGameCommand(String(f[2])) else { return nil }; return pid
        }.first
    }
    static func isGameCommand(_ command: String) -> Bool {
        let exe = command.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let normalized = exe.replacingOccurrences(of: "\\", with: "/").lowercased()
        return normalized == "dwrg.exe" || normalized.hasSuffix("/dwrg.exe")
    }
}

struct CombinedCaptureRecord: Codable, Equatable { let startedAtEpoch: TimeInterval; let targetPID: Int32; let captureDirectory: String; var visualOutputPath: String?; var includesMetal: Bool }
extension CombinedCaptureRecord { var visualOutputURL: URL? { visualOutputPath.map(URL.init(fileURLWithPath:)) } }
struct MetalPerfTraceExportResult: Equatable { let succeeded: Bool; let message: String }
enum MetalPerfTraceExportPlan {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/metalperftrace")
    static func collectArguments(record: CombinedCaptureRecord, endedAtEpoch: TimeInterval, outputDirectory: URL) -> [String] { ["collect", "--start", "@\(arg(record.startedAtEpoch))", "--end", "@\(arg(endedAtEpoch))", "--prefix", "identityv-pid-\(record.targetPID)", outputDirectory.path] }
    static func overviewArguments(trace: URL, targetPID: Int32) -> [String] { ["overview", "--json", "--json-include-timeline", "--predicate", "pid == \(targetPID)", trace.path] }
    static func isMatchingTrace(_ url: URL, targetPID: Int32) -> Bool { url.pathExtension == "atrc" && url.lastPathComponent.contains("identityv-pid-\(targetPID)") }
    static func overviewHasData(_ data: Data) -> Bool {
        // metalperftrace can exit 0 while emitting {"error":"No session found"}.
        // A trace container alone is not evidence of a usable game session.
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let dictionary = object as? [String: Any] { return !dictionary.isEmpty && dictionary["error"] == nil }
        if let array = object as? [Any] { return !array.isEmpty }
        return false
    }
    static func safeCaptureDirectory(_ raw: String, root: URL) -> URL? {
        guard let canonicalRoot = MonitorSecureFS.canonical(root), MonitorSecureFS.isPrivateDirectory(canonicalRoot),
              let capture = MonitorSecureFS.canonical(URL(fileURLWithPath: raw, isDirectory: true)),
              MonitorSecureFS.isDirectChild(capture, of: canonicalRoot), MonitorSecureFS.isPrivateDirectory(capture) else { return nil }
        return capture
    }
    private static func arg(_ value: TimeInterval) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
}

enum CombinedCapturePhase: Equatable {
    case idle, recording, recordingWithoutVisual, recordingDenseOnly, exporting, completed, partialFailure
    var title: String { switch self { case .idle: return "未在采集"; case .recording: return "联合采集中（高密度 + Metal + 画面变化率）"; case .recordingWithoutVisual: return "采集中（高密度 + Metal）"; case .recordingDenseOnly: return "采集中（仅高密度）"; case .exporting: return "正在导出 Metal trace"; case .completed: return "联合采集完成"; case .partialFailure: return "完成（部分数据失败）" } }
    var systemImage: String { switch self { case .idle: return "circle"; case .recording, .recordingWithoutVisual, .recordingDenseOnly: return "record.circle.fill"; case .exporting: return "arrow.down.circle.fill"; case .completed: return "checkmark.circle.fill"; case .partialFailure: return "exclamationmark.triangle.fill" } }
}

/// Keep the macOS privacy grant separate from the capture lifecycle.  A
/// granted Screen Recording entry only means that capture *may* start; it
/// must not be presented as if the toolbox were already sampling frames.
enum ScreenRecordingAuthorizationState: Equatable {
    case notAuthorized
    case authorizedIdle
    case capturing

    static func resolve(isAuthorized: Bool, isCapturing: Bool) -> Self {
        guard isAuthorized else { return .notAuthorized }
        return isCapturing ? .capturing : .authorizedIdle
    }

    var localizedDescription: String {
        switch self {
        case .notAuthorized: return "画面采集权限：未授权"
        case .authorizedIdle: return "画面采集权限：已授权（尚未开始采集）"
        case .capturing: return "画面采集权限：已授权（采集中）"
        }
    }
}

enum MetalHUDSettings {
    static let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IdentityVOnMac/Maintenance", isDirectory: true)
    static let file = parent.appendingPathComponent("metal-hud.env")
    static func read() -> Bool {
        guard safeParents(create: false), safeFile(file), let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let rows = text.split(whereSeparator: \.isNewline); guard rows.count == 2 else { return false }
        let expected = ["schema=1", "enabled=0", "enabled=1"]; return rows[0] == expected[0] && (rows[1] == expected[1] || rows[1] == expected[2]) && rows[1] == "enabled=1"
    }
    static func write(enabled: Bool) throws { try write(enabled: enabled, parent: parent, file: file) }
    private static func write(enabled: Bool, parent: URL, file: URL) throws {
        guard safeParents(parent, create: true) else { throw NSError(domain: "MetalHUDSettings", code: 1) }
        if MonitorSecureFS.lstat(file) != nil && !safeFile(file) { throw NSError(domain: "MetalHUDSettings", code: 2) }
        let temp = parent.appendingPathComponent(".metal-hud-\(UUID().uuidString)")
        guard let handle = MonitorSecureFS.createExclusiveFile(temp) else { throw NSError(domain: "MetalHUDSettings", code: 3) }
        do { try handle.write(contentsOf: Data("schema=1\nenabled=\(enabled ? "1" : "0")\n".utf8)); try handle.close() } catch { try? handle.close(); try? FileManager.default.removeItem(at: temp); throw error }
        guard safeFile(temp), Darwin.rename(temp.path, file.path) == 0, safeFile(file) else { try? FileManager.default.removeItem(at: temp); throw NSError(domain: "MetalHUDSettings", code: 4) }
    }
    private static func safeParents(create: Bool) -> Bool { safeParents(parent, create: create) }
    private static func safeParents(_ parent: URL, create: Bool) -> Bool {
        let app = parent.deletingLastPathComponent()
        guard let applicationSupport = MonitorSecureFS.lstat(app.deletingLastPathComponent()), (applicationSupport.st_mode & S_IFMT) == S_IFDIR, applicationSupport.st_uid == getuid() else { return false }
        if MonitorSecureFS.lstat(app) == nil { guard create && MonitorSecureFS.createDirectoryOneLevel(app) else { return false } }
        guard MonitorSecureFS.isPrivateDirectory(app) else { return false }
        if MonitorSecureFS.lstat(parent) == nil { guard create && MonitorSecureFS.createDirectoryOneLevel(parent) else { return false } }
        return MonitorSecureFS.isPrivateDirectory(parent)
    }
    private static func safeFile(_ url: URL) -> Bool { MonitorSecureFS.isPrivateRegularFile(url, allowed: 0o600) || MonitorSecureFS.isPrivateRegularFile(url, allowed: 0o400) }
    static func fixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-hud-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        let target = root.appendingPathComponent("target", isDirectory: true); guard MonitorSecureFS.createDirectoryOneLevel(target) else { return [false] }
        let sentinel = target.appendingPathComponent("sentinel"); guard let h = MonitorSecureFS.createExclusiveFile(sentinel) else { return [false] }; try? h.write(contentsOf: Data("unchanged".utf8)); try? h.close()
        let badApp = root.appendingPathComponent("IdentityVOnMac", isDirectory: true); try? FileManager.default.createSymbolicLink(atPath: badApp.path, withDestinationPath: target.path)
        let badParent = badApp.appendingPathComponent("Maintenance", isDirectory: true); let badFile = badParent.appendingPathComponent("metal-hud.env")
        let denied = (try? write(enabled: true, parent: badParent, file: badFile)) == nil
        let unchanged = (try? String(contentsOf: sentinel, encoding: .utf8)) == "unchanged"
        return [denied, unchanged]
    }
}

@MainActor final class MonitorViewModel: ObservableObject {
    @Published private(set) var gamePID: Int32?; @Published private(set) var monitoringState: DenseMonitoringState = .idle; @Published private(set) var outputDirectory: URL; @Published private(set) var message: String?; @Published private(set) var combinedPhase: CombinedCapturePhase = .idle; @Published private(set) var visualCaptureStatus = "画面变化率：未启动"; @Published private(set) var screenRecordingAuthorization: ScreenRecordingAuthorizationState = .notAuthorized; @Published private(set) var overlayEnabled = false; @Published var includeVisual = true; @Published var includeMetal = true; @Published var metalHUDEnabled = MetalHUDSettings.read()
    private let controller: DenseMonitoringController?; private let visual = VisualCaptureController(); private var record: CombinedCaptureRecord?; private var poller: AnyCancellable?; private var activationObserver: AnyCancellable?; private var visualIsCapturing = false
    @Published private(set) var resourceCaptureStatus = "CPU/GPU 记录：未开始"
    @Published private(set) var captureEndReason: String?
    private var resourceSamples = 0
    private let resourceSampler = MonitorResourceSampler()
    private let resourceQueue = DispatchQueue(label: "identityv.resources", qos: .utility)
    private var resourceInFlight = false
    private var resources: MonitorResourceSnapshot?
    private var watchedIdentity: GameProcessIdentity?
    private var resourceOutput: FileHandle?
    nonisolated private static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IdentityVOnMac/Diagnostics/Dense", isDirectory: true)
    init() { outputDirectory = Self.root; controller = DenseMonitoringController(samplerURL: Bundle.main.url(forResource: "idv-dense-metrics", withExtension: nil), root: Self.root); visual.onUpdate = { [weak self] metrics in Task { @MainActor in self?.visualUpdate(metrics) } }; poller = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }; activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.refresh() }; refresh(); let legacyPath = "/Applications/第五人格性能浮窗" + ".app"; if FileManager.default.fileExists(atPath: legacyPath) || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.xunfeng.identityv.monitor" + "-overlay").isEmpty { message = "检测到已退役的旧性能浮窗；请迁移到本工具箱。它不会被自动启动、停止或删除。" } }
    func refresh() {
        refresh(readSnapshot: Self.snapshot)
    }
    private func refresh(readSnapshot: () -> String) {
        let observedRecord = record
        let snap = readSnapshot()
        // ps.waitUntilExit may dispatch a Start action while this refresh is
        // suspended. Its snapshot predates that new sampler; never use it as
        // evidence that the just-started capture has already exited.
        guard observedRecord == record else { return }
        gamePID = MonitorGameProcessMatcher.gamePID(in: snap)
        if let controller { monitoringState = controller.status(gamePID: gamePID, snapshot: snap) }
        refreshScreenRecordingAuthorization()
        refreshLiveMonitoring()
        if combinedPhase == .idle { visualCaptureStatus = visual.statusDescription }
        // Finalize the current capture promptly when Dense self-stops, even
        // if the game remains alive. Do not leave a stale recording button.
        if record != nil, combinedPhase != .exporting, combinedPhase != .partialFailure, !snap.isEmpty,
           let sampler = Self.sampler(directory: outputDirectory),
           !DenseSamplerStopPlan.processMatches(sampler, snapshot: snap) {
            stop(reason: Self.samplerEndReason(in: outputDirectory))
        }
    }
#if MONITOR_PROCESS_SELF_TEST
    static func refreshReentryChecks() -> [Bool] {
        let model = MonitorViewModel()
        model.poller?.cancel(); model.activationObserver?.cancel()
        model.gamePID = 111
        model.refresh(readSnapshot: {
            model.record = CombinedCaptureRecord(startedAtEpoch: 1, targetPID: 222, captureDirectory: "/unused-refresh-fixture", visualOutputPath: nil, includesMetal: false)
            return "222 \(getuid()) C:\\Games\\IdentityV\\dwrg.exe"
        })
        let preserved = model.gamePID == 111 && model.combinedPhase == .idle
        model.record = nil
        model.refresh(readSnapshot: { "222 \(getuid()) C:\\Games\\IdentityV\\dwrg.exe" })
        return [preserved, model.gamePID == 222]
    }
#endif
    func requestVisualPermission() {
        if CGPreflightScreenCaptureAccess() {
            refreshScreenRecordingAuthorization()
            message = "第五人格工具箱已具有屏幕录制权限；现在可开始画面变化率采集。"
            return
        }
        guard CGRequestScreenCaptureAccess() else {
            refreshScreenRecordingAuthorization()
            message = "未获得屏幕录制权限；画面变化率不会开始。"
            return
        }
        // TCC may apply a just-approved Screen Recording entry one run-loop
        // later. Recheck without issuing a second request; activation and the
        // regular refresh path continue to keep it current afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshScreenRecordingAuthorization()
            self.message = self.screenRecordingAuthorization == .notAuthorized
                ? "系统已接受授权请求，但此进程尚未取得屏幕录制权限；请完全退出后重新打开第五人格工具箱。"
                : "已获得第五人格工具箱的屏幕录制权限；现在可开始画面变化率采集。"
        }
    }
    func toggleOverlay() {
        if overlayEnabled {
            overlayEnabled = false
            visual.hideOverlay(hasActiveRecord: record != nil)
        } else {
            guard gamePID != nil else { message = "未发现正在运行的 dwrg.exe。"; return }
            guard visual.showOverlay() else { message = "性能浮窗辅助进程未能启动；请重新构建第五人格工具箱。"; return }
            overlayEnabled = true
            publishLoadOverlay()
            refreshLiveMonitoring()
        }
    }
    func start() {
        captureEndReason = nil
        guard let controller else { message = "工具箱缺少高密度采集组件，请重新构建。"; return }; let snap = Self.snapshot(); guard let pid = MonitorGameProcessMatcher.gamePID(in: snap) else { message = "未发现正在运行的 dwrg.exe。"; return }; guard let sampler = controller.startNewRecord(gamePID: pid, snapshot: snap), let output = sampler.outputPath else { message = "高密度采集未能启动，或已有采集器正在记录；没有接管历史采集。"; return }
        let directory = URL(fileURLWithPath: output).deletingLastPathComponent(); let new = CombinedCaptureRecord(startedAtEpoch: Date().timeIntervalSince1970, targetPID: pid, captureDirectory: directory.path, visualOutputPath: includeVisual ? directory.appendingPathComponent("visual-fps.jsonl").path : nil, includesMetal: includeMetal)
        guard Self.persist(new, directory) else { record = CombinedCaptureRecord(startedAtEpoch: new.startedAtEpoch, targetPID: new.targetPID, captureDirectory: new.captureDirectory, visualOutputPath: new.visualOutputPath, includesMetal: false); outputDirectory = directory; combinedPhase = .recordingDenseOnly; message = "高密度采集中；无法保存本轮恢复记录，本轮不会导出 Metal trace。"; return }; record = new; outputDirectory = directory
        resourceSamples = 0
        resourceOutput = MonitorSecureFS.createExclusiveFile(directory.appendingPathComponent("resource-metrics.jsonl"))
        resourceCaptureStatus = resourceOutput == nil ? "CPU/GPU 记录：创建失败" : "CPU/GPU 记录：采集中"
        guard includeVisual else { combinedPhase = includeMetal ? .recordingWithoutVisual : .recordingDenseOnly; message = "高密度采集已启动。"; return }; guard CGPreflightScreenCaptureAccess() else { combinedPhase = .recordingWithoutVisual; visualCaptureStatus = "画面变化率：部分失败（未授予工具箱屏幕录制权限）"; message = "高密度与 Metal 正在采集；画面变化率未启动。"; return }; combinedPhase = .recording; message = "联合采集已启动。"; visual.armAutomaticFreezeStackCapture(captureDirectory: directory, targetPID: pid); visual.beginStart(targetPID: pid, outputURL: new.visualOutputURL)
    }
    func stop() {
        stop(reason: "手动停止")
    }
    private func stop(reason: String) {
        guard combinedPhase != .exporting else { return }
        guard let controller, let current = record,
              let sampler = Self.sampler(directory: URL(fileURLWithPath: current.captureDirectory, isDirectory: true)) else {
            combinedPhase = .partialFailure; message = "缺少本窗口采集记录，无法收尾。已有数据保留在输出目录。"; return
        }
        // Process.waitUntilExit can service the main run loop while reading ps
        // or stopping Dense. Lock BEFORE either call: otherwise the refresh
        // timer can reenter stop() and schedule a second export for this record.
        let previousPhase = combinedPhase
        combinedPhase = .exporting
        switch controller.stop(record: sampler, snapshot: Self.snapshot()) {
        case .stopped:
            captureEndReason = reason
            message = "正在结束采集并导出结果…"
            Task { await complete(current) }
        case .stillRunning:
            combinedPhase = previousPhase
            message = "采集器尚未退出，请重试停止。已有数据保留在输出目录。"
        case .notOwned:
            combinedPhase = .partialFailure
            message = "本窗口未持有这次采集，无法自动收尾。已有数据保留在输出目录。"
        }
    }
    private func complete(_ current: CombinedCaptureRecord) async { let visualResult = await visual.finishRecord(outputURL: current.visualOutputURL, stopIfNoOverlay: true); if resourceOutput != nil { resourceCaptureStatus = resourceSamples > 0 ? "CPU/GPU 记录：已记录" : "CPU/GPU 记录：未取得样本" }; try? resourceOutput?.close(); resourceOutput = nil; visualCaptureStatus = visualResult.message; record = nil; monitoringState = .idle; outputDirectory = URL(fileURLWithPath: current.captureDirectory, isDirectory: true); guard current.includesMetal else { combinedPhase = visualResult.succeeded || !includeVisual ? .completed : .partialFailure; message = "高密度采集已停止。\(visualResult.message)"; return }; combinedPhase = .exporting; message = "高密度采集已停止，正在导出 Metal trace…"; let end = Date().timeIntervalSince1970; let result = await Task.detached(priority: .utility) { Self.exportMetal(record: current, ended: end) }.value; combinedPhase = result.succeeded && (!includeVisual || visualResult.succeeded) ? .completed : .partialFailure; message = result.message + " " + visualResult.message }
    // Resource polling is independent of screen callbacks: a frozen game
    // must not freeze its CPU/GPU readout. No screen permission is needed.
    private func refreshLiveMonitoring() {
        guard let pid = gamePID, let identity = GameProcessIdentity.read(pid), overlayEnabled || record != nil else {
            resources = nil; watchedIdentity = nil
            // The user's intent survives a game exit: the helper stays alive and
            // can come back with the next game, but it must not keep presenting
            // a window for a target that just disappeared.
            publishLoadOverlay()
            return
        }
        if watchedIdentity != identity { watchedIdentity = identity; resources = nil; publishLoadOverlay() }
        guard !resourceInFlight else { return }
        resourceInFlight = true
        let sampler = resourceSampler
        resourceQueue.async { [weak self] in
            let sample = sampler.sample(targetPID: pid)
            DispatchQueue.main.async {
                guard let self else { return }; self.resourceInFlight = false
                guard self.watchedIdentity == identity, GameProcessIdentity.read(pid) == identity else { return }
                self.resources = sample
                if self.record?.targetPID == pid, let data = try? JSONEncoder().encode(sample), let output = self.resourceOutput {
                    do { try output.write(contentsOf: data + Data([10])); self.resourceSamples += 1 }
                    catch { try? output.close(); self.resourceOutput = nil; self.resourceCaptureStatus = "CPU/GPU 记录：写入失败"; self.message = "负载日志写入失败；其他采集继续。" }
                }
                self.publishLoadOverlay()
            }
        }
    }
    private func publishLoadOverlay() {
        guard overlayEnabled else { return }
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "--" }
        // Personal HUD contract: game first, system second, with no extra
        // labels. Keep the differing GPU measurement definitions in the toolbox.
        var cpu = "CPU \(percent(resources?.gameCPUPercent))"
        if let container = resources?.containerCPUPercent { cpu += " · 容器 \(percent(container))" }
        let gpu = "GPU \(percent(resources?.gameGPUPercent))  \(percent(resources?.systemGPUPercent))"
        let pid = resources?.targetPID ?? gamePID ?? 0
        // The helper applies the frontmost half of the same gate. An
        // ineligible snapshot (no sample yet, no target, user turned the
        // overlay off while a sample was in flight) is published as PID 0 /
        // no-data rather than as a placeholder window.
        let live = OverlayVisibility.isSnapshotLive(isEnabledByUser: overlayEnabled, hasLiveData: Self.hasLiveOverlayValue(resources), targetPID: pid)
        visual.publishOverlay(.init(cpuLine: cpu, gpuLine: gpu, targetPID: live ? pid : 0, hasLiveData: live))
    }
    /// "First valid data" for the two lines: at least one displayed number
    /// exists. The first sample of a fresh sampler can only fill some of them,
    /// and that must not open an all-`--` window.
    private static func hasLiveOverlayValue(_ resources: MonitorResourceSnapshot?) -> Bool {
        guard let resources else { return false }
        return resources.gameCPUPercent != nil || resources.containerCPUPercent != nil
            || resources.gameGPUPercent != nil || resources.systemGPUPercent != nil
    }
    func revealOutput() { NSWorkspace.shared.activateFileViewerSelecting([outputDirectory]) }
    func setMetalHUD(_ enabled: Bool) { do { try MetalHUDSettings.write(enabled: enabled); metalHUDEnabled = enabled; message = "Metal HUD 已\(enabled ? "开启" : "关闭")；下次启动或重启游戏生效，当前游戏不变。" } catch { metalHUDEnabled = MetalHUDSettings.read(); message = "无法保存 Metal HUD 设置：\(error.localizedDescription)" } }
    private func visualUpdate(_ metrics: VisualMetrics) {
        visualCaptureStatus = metrics.localizedDescription
        visualIsCapturing = metrics.status == "capturing" && (record != nil || overlayEnabled)
        refreshScreenRecordingAuthorization()
        if let record, combinedPhase != .exporting {
            // The first frame (or a static game) need not be "usable motion".
            // Describe the active stream, and upgrade again when it starts.
            combinedPhase = metrics.status == "capturing" ? .recording : (record.includesMetal ? .recordingWithoutVisual : .recordingDenseOnly)
        }
    }
    private func refreshScreenRecordingAuthorization() { screenRecordingAuthorization = .resolve(isAuthorized: CGPreflightScreenCaptureAccess(), isCapturing: visualIsCapturing && (record != nil || overlayEnabled)) }
    private static func persist(_ current: CombinedCaptureRecord, _ directory: URL) -> Bool { let file = directory.appendingPathComponent("combined-capture.json"); do { try JSONEncoder().encode(current).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); return true } catch { return false } }
    private static func sampler(directory: URL) -> DenseSamplerRecord? { guard let data = try? Data(contentsOf: directory.appendingPathComponent("sampler.pid")) else { return nil }; return try? JSONDecoder().decode(DenseSamplerRecord.self, from: data) }
    private static func samplerEndReason(in directory: URL) -> String {
        // Read only the bounded tail; a long session may contain many hours.
        guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("telemetry.jsonl")) else { return "采集器已退出（未记录原因）" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)) != nil,
              let data = try? handle.read(upToCount: 4096),
              let last = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last,
              let event = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any], event["event"] as? String == "stopped" else { return "采集器已退出（未记录原因）" }
        switch event["reason"] as? String {
        case "target-exited": return "游戏已退出"
        case "parent-exited": return "工具箱已退出"
        case "time-limit": return "已达到本次指定时长"
        case "signal": return "采集器收到停止信号"
        case "write-error": return "采集文件写入失败"
        default: return "采集器已退出（未记录原因）"
        }
    }
    private static func snapshot() -> String { DenseMonitoringProcessMatcher.processSnapshot() }
    nonisolated private static func exportMetal(record: CombinedCaptureRecord, ended: TimeInterval) -> MetalPerfTraceExportResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: MetalPerfTraceExportPlan.executableURL.path) else { return .init(succeeded: false, message: "此 Mac 没有 metalperftrace，未导出 Metal trace。") }
        guard let capture = MetalPerfTraceExportPlan.safeCaptureDirectory(record.captureDirectory, root: Self.root) else {
            return .init(succeeded: false, message: "采集目录安全校验失败，未导出 Metal trace。")
        }
        let directory = capture.appendingPathComponent("Metal-\(Int64(ended * 1000))-\(UUID().uuidString)", isDirectory: true)
        do {
            guard MonitorSecureFS.lstat(directory) == nil, MonitorSecureFS.createDirectoryOneLevel(directory) else { return .init(succeeded: false, message: "无法安全创建 Metal 输出目录。") }
            let collectError = directory.appendingPathComponent("collect.stderr.log"); guard let collectHandle = MonitorSecureFS.createExclusiveFile(collectError) else { return .init(succeeded: false, message: "无法安全创建 Metal 导出日志。") }; defer { try? collectHandle.close() }
            let collect = Process(); collect.executableURL = MetalPerfTraceExportPlan.executableURL; collect.arguments = MetalPerfTraceExportPlan.collectArguments(record: record, endedAtEpoch: ended, outputDirectory: directory); collect.standardOutput = FileHandle.nullDevice; collect.standardError = collectHandle; try collect.run(); collect.waitUntilExit()
            guard collect.terminationStatus == 0 else { return .init(succeeded: false, message: "Metal trace 导出失败（详见 collect.stderr.log）。") }
            let traces = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { MetalPerfTraceExportPlan.isMatchingTrace($0, targetPID: record.targetPID) && MonitorSecureFS.isOwnedRegularFile($0) }
            guard traces.count == 1, let trace = traces.first else { return .init(succeeded: false, message: "Metal trace 导出后未找到唯一匹配 PID 的安全文件。") }
            let output = directory.appendingPathComponent("overview-pid-\(record.targetPID).json"), overviewError = directory.appendingPathComponent("overview.stderr.log")
            guard let outputHandle = MonitorSecureFS.createExclusiveFile(output), let overviewHandle = MonitorSecureFS.createExclusiveFile(overviewError) else { return .init(succeeded: false, message: "无法安全创建 Metal overview 输出。") }; defer { try? outputHandle.close(); try? overviewHandle.close() }
            let overview = Process(); overview.executableURL = MetalPerfTraceExportPlan.executableURL; overview.arguments = MetalPerfTraceExportPlan.overviewArguments(trace: trace, targetPID: record.targetPID); overview.standardOutput = outputHandle; overview.standardError = overviewHandle; try overview.run(); overview.waitUntilExit()
            guard overview.terminationStatus == 0, MonitorSecureFS.isPrivateRegularFile(output), MonitorSecureFS.isPrivateRegularFile(overviewError) else { return .init(succeeded: false, message: "Metal trace 已导出，但 overview 失败（详见 overview.stderr.log）。") }
            guard let overviewData = try? Data(contentsOf: output), MetalPerfTraceExportPlan.overviewHasData(overviewData) else {
                return .init(succeeded: false, message: "高密度记录与 Metal trace 已保存，但未取得可用的 Metal 会话摘要（详见 overview JSON）。")
            }
            return .init(succeeded: true, message: "联合采集完成：高密度记录与 Metal trace 已导出。")
        } catch { return .init(succeeded: false, message: "Metal trace 导出失败：\(error.localizedDescription)") }
    }
}

#if !MONITOR_PROCESS_SELF_TEST
@main struct IdentityVMonitorApp: App {
    @StateObject private var model: MonitorViewModel
    init() {
        IdentityVLegacyPreferences.migrateForCurrentApp()
        _model = StateObject(wrappedValue: MonitorViewModel())
    }
    var body: some Scene {
        Window("第五人格工具箱", id: "identityv-toolbox") {
            MonitorView().environmentObject(model).frame(minWidth: 620, minHeight: 500)
        }
        .defaultSize(width: 700, height: 560)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct MonitorView: View {
    @EnvironmentObject private var model: MonitorViewModel
    private var isCapturing: Bool {
        switch model.combinedPhase {
        case .recording, .recordingWithoutVisual, .recordingDenseOnly, .exporting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第五人格工具箱").font(.system(size: 28, weight: .bold, design: .rounded))
            GroupBox("游戏进程") {
                HStack {
                    Label(model.gamePID.map { "已识别 dwrg.exe · PID \($0)" } ?? "未发现 dwrg.exe", systemImage: model.gamePID == nil ? "circle" : "checkmark.circle.fill")
                    Spacer()
                    Button("刷新", action: model.refresh).buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("画面变化率与性能浮窗") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.screenRecordingAuthorization.localizedDescription, systemImage: model.screenRecordingAuthorization == .notAuthorized ? "lock.circle" : "checkmark.shield.fill")
                        .foregroundStyle(model.screenRecordingAuthorization == .notAuthorized ? Color.secondary : Color.green)
                    Text(model.visualCaptureStatus).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(model.screenRecordingAuthorization == .notAuthorized ? "启用画面采集权限" : "检查画面采集权限", action: model.requestVisualPermission).buttonStyle(.bordered)
                        Button(model.overlayEnabled ? "关闭性能浮窗" : "显示性能浮窗", action: model.toggleOverlay).buttonStyle(.bordered)
                        Spacer()
                        Toggle("Metal HUD", isOn: Binding(get: { model.metalHUDEnabled }, set: model.setMetalHUD)).toggleStyle(.switch)
                    }
                    Text("CPU 的 100% 代表一个核心。GPU 依次为游戏时间占比、整机负载，两者不直接相减。浮窗随游戏前台状态自动显隐，无需画面采集权限。Metal HUD 下次启动生效。").font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox("联合采集") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.combinedPhase.title, systemImage: model.combinedPhase.systemImage).font(.title3.weight(.semibold))
                    Text(model.monitoringState.localizedDescription + " · " + model.resourceCaptureStatus).font(.caption).foregroundStyle(.secondary)
                    Text("无时长上限；手动停止或游戏退出时结束。退出工具箱也会结束采集。").font(.caption).foregroundStyle(.secondary)
                    if let reason = model.captureEndReason { Text("结束原因：\(reason)").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Toggle("包含画面变化率", isOn: $model.includeVisual).disabled(isCapturing)
                        Toggle("导出 Metal trace", isOn: $model.includeMetal).disabled(isCapturing)
                        Spacer()
                        if model.combinedPhase == .idle || model.combinedPhase == .completed || model.combinedPhase == .partialFailure {
                            Button("开始联合采集", action: model.start).buttonStyle(.borderedProminent).disabled(model.gamePID == nil)
                        } else if model.combinedPhase == .exporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("停止并导出", action: model.stop).buttonStyle(.bordered)
                        }
                    }
                }
            }
            GroupBox("输出目录") {
                HStack {
                    Text(model.outputDirectory.path).font(.caption).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("在访达中显示结果", action: model.revealOutput).buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(22)
    }
}
#endif
