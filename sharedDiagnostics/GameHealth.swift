import AppKit
import Foundation
import Darwin

/// CPU load or a still picture alone cannot prove a deadlock. The launcher
/// uses fresh ANR markers and foreground GPU submission progress, independently
/// of video callbacks. A sampling gap resets the weaker GPU timer, but must
/// not discard a fresh ANR already read from the current game's log.
struct GameHealthGate {
    private var lastNow: Double?
    private var warned = false
    private var snoozeUntil = 0.0
    private var lastGPUStamp: UInt64?
    private var lastGPUProgress: Double?
    mutating func observe(now: Double, foreground: Bool, validCapture: Bool,
                          unchangedSeconds: Double?, newANR: Bool, gpuSubmissionStamp: UInt64? = nil,
                          gpuStallSeconds: Double = 30) -> String? {
        defer { lastNow = now }
        guard now.isFinite else { return nil }
        if let lastNow, now < lastNow || now - lastNow > 5 { lastGPUProgress = nil; lastGPUStamp = nil }
        if foreground, let stamp = gpuSubmissionStamp, stamp > 0 {
            switch lastGPUStamp {
            case .some(let previous) where stamp > previous:
                lastGPUProgress = now
                warned = false
            case .some(let previous) where stamp < previous:
                lastGPUProgress = nil
            case .none:
                // First sample of a foreground stretch: it is both the baseline
                // for "submissions are advancing" and the start of the stall
                // window. Without this the stall condition could never fire,
                // because `now - progress` had no progress to subtract from.
                lastGPUProgress = now
            default:
                break
            }
            lastGPUStamp = stamp
        } else { lastGPUProgress = nil; lastGPUStamp = nil }
        if let unchangedSeconds, unchangedSeconds < 2 { warned = false }
        guard !warned, now >= snoozeUntil else { return nil }
        if newANR {
            warned = true
            return "游戏报告了无响应（ANR）。如果画面或加载进度已卡住，可以重启游戏。"
        }
        if foreground, gpuStallSeconds.isFinite, gpuStallSeconds >= 1,
           let progress = lastGPUProgress, now - progress >= gpuStallSeconds {
            warned = true
            return "游戏在前台约 \(Int(gpuStallSeconds)) 秒没有提交新的 GPU 工作，可能卡在页面切换或加载。"
        }
        guard foreground, validCapture, let unchangedSeconds, unchangedSeconds >= 90 else { return nil }
        warned = true
        return "游戏画面已约 90 秒没有更新，可能卡在加载或页面切换。静态页面也可能出现这种情况。"
    }
    mutating func later(now: Double) { snoozeUntil = now + 300; warned = true }

    /// Asks "is the condition that raised the current warning gone?" so the UI
    /// can withdraw itself instead of waiting for a click. Kept here because this
    /// type owns the evidence rules: a warning clears only when the same signal
    /// that justifies believing the game is alive (a fresh in-process ANR marker,
    /// or GPU submissions advancing while foreground) shows progress again.
    /// Callers must invoke it only for the incident they actually reported, so a
    /// prompt for an older stall cannot be closed by an unrelated later recovery.
    mutating func observeRecovery(now: Double, foreground: Bool, newANR: Bool,
                                  gpuSubmissionStamp: UInt64? = nil) -> Bool {
        guard warned else { return false }
        if newANR { warned = false; return true }
        guard foreground else { return false }
        // A stamp change proves rendering resumed even when the previous stamp
        // was lost to a background gap or a monitor restart.
        if let stamp = gpuSubmissionStamp, stamp > 0 {
            if lastGPUStamp != stamp { warned = false; return true }
            if let progress = lastGPUProgress, now - progress < 2 { warned = false; return true }
        }
        return false
    }
    /// Recovery fixtures: a warning must clear only on a real liveness signal,
    /// never merely because the observation loop kept running.
    static func recoveryFixtureChecks() -> [Bool] {
        var gpu = GameHealthGate()
        // Two advancing samples are required before a held stamp can mean a stall:
        // the first sample only establishes the baseline.
        _ = gpu.observe(now: 0, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 1)
        _ = gpu.observe(now: 1, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2)
        var warned = false
        for tick in 2...14 {
            if gpu.observe(now: Double(tick), foreground: true, validCapture: false, unchangedSeconds: nil,
                           newANR: false, gpuSubmissionStamp: 2, gpuStallSeconds: 10) != nil { warned = true }
        }
        let recovering = gpu.observeRecovery(now: 15, foreground: true, newANR: false, gpuSubmissionStamp: 3)
        let cleared = gpu.observeRecovery(now: 16, foreground: true, newANR: false, gpuSubmissionStamp: 4) == false
        let backgroundIsNotRecovery = gpu.observeRecovery(now: 17, foreground: false, newANR: false, gpuSubmissionStamp: 99) == false

        var anr = GameHealthGate()
        _ = anr.observe(now: 0, foreground: false, validCapture: false, unchangedSeconds: nil, newANR: true)
        let anrRecovery = anr.observeRecovery(now: 1, foreground: false, newANR: true)
        let noDouble = anr.observeRecovery(now: 2, foreground: true, newANR: false, gpuSubmissionStamp: 9) == false

        var quiet = GameHealthGate()
        let noWarningNoRecovery = quiet.observeRecovery(now: 0, foreground: true, newANR: true) == false
        return [warned, recovering, cleared, backgroundIsNotRecovery, anrRecovery, noDouble, noWarningNoRecovery]
    }

    static func fixtureChecks() -> [Bool] {
        var gate = GameHealthGate()
        let noBrokenCapture = gate.observe(now: 0, foreground: true, validCapture: false, unchangedSeconds: 100, newANR: false) == nil
        let noBackground = gate.observe(now: 1, foreground: false, validCapture: true, unchangedSeconds: 100, newANR: false) == nil
        let warn = gate.observe(now: 2, foreground: true, validCapture: true, unchangedSeconds: 100, newANR: false) != nil
        let once = gate.observe(now: 3, foreground: true, validCapture: true, unchangedSeconds: 101, newANR: false) == nil
        _ = gate.observe(now: 4, foreground: true, validCapture: true, unchangedSeconds: 0, newANR: false)
        let anr = gate.observe(now: 5, foreground: false, validCapture: false, unchangedSeconds: nil, newANR: true) != nil
        gate.later(now: 5)
        _ = gate.observe(now: 6, foreground: true, validCapture: true, unchangedSeconds: 0, newANR: false)
        let snooze = gate.observe(now: 7, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: true) == nil
        var gpuGate = GameHealthGate()
        _ = gpuGate.observe(now: 0, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 1)
        _ = gpuGate.observe(now: 1, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2)
        var gpuWarns = 0
        for tick in 2...35 {
            if gpuGate.observe(now: Double(tick), foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2) != nil { gpuWarns += 1 }
        }
        let noAfterBackground = gpuGate.observe(now: 36, foreground: false, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2) == nil
        var shortGate = GameHealthGate()
        _ = shortGate.observe(now: 0, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 1, gpuStallSeconds: 10)
        _ = shortGate.observe(now: 1, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2, gpuStallSeconds: 10)
        var firstShortWarning: Int?
        for tick in 2...12 {
            if shortGate.observe(now: Double(tick), foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2, gpuStallSeconds: 10) != nil, firstShortWarning == nil { firstShortWarning = tick }
        }
        var resumedGate = GameHealthGate()
        _ = resumedGate.observe(now: 0, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 1, gpuStallSeconds: 10)
        _ = resumedGate.observe(now: 1, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2, gpuStallSeconds: 10)
        let noStallAcrossSleep = resumedGate.observe(now: 60, foreground: true, validCapture: false, unchangedSeconds: nil, newANR: false, gpuSubmissionStamp: 2, gpuStallSeconds: 10) == nil
        let freshANRAfterGap = resumedGate.observe(now: 120, foreground: false, validCapture: false, unchangedSeconds: nil, newANR: true) != nil
        return [noBrokenCapture, noBackground, warn, once, anr, snooze, gpuWarns == 1, noAfterBackground, firstShortWarning == 11, noStallAcrossSleep, freshANRAfterGap]
    }
}

struct GameProcessIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicros: UInt64
    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid() else { return nil }
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec)
    }
}

/// Follow only the live game's cwd/log.txt, never a historical log's ANR.
/// Start at EOF, retain an incomplete line across reads, bound work per tick,
/// and reset to EOF on rotation/truncation. No raw account/chat log is copied.
// Used exclusively on the owning app's serial resource queue.
final class GameANRReader: @unchecked Sendable {
    private var identity: GameProcessIdentity?
    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private var filePath: String?
    private(set) var available = false
    func reset() { try? handle?.close(); handle = nil; filePath = nil; identity = nil; pending.removeAll(); available = false }
    deinit { reset() }
    func poll(_ current: GameProcessIdentity) -> Bool {
        if identity != current { reset(); identity = current; openAtEnd(pid: current.pid); return false }
        guard let handle else { openAtEnd(pid: current.pid); return false }
        var value = stat()
        var pathStat = stat()
        guard let filePath, Darwin.lstat(filePath, &pathStat) == 0,
              fstat(handle.fileDescriptor, &value) == 0 else { reset(); return false }
        if pathStat.st_ino != value.st_ino || pathStat.st_dev != value.st_dev { reset(); identity = current; openAtEnd(pid: current.pid); return false }
        guard UInt64(value.st_ino) == inode, value.st_size >= Int64(offset), UInt64(value.st_size) - offset <= 1_048_576 else {
            reset(); identity = current; openAtEnd(pid: current.pid); return false
        }
        guard let data = try? handle.read(upToCount: 256 * 1024), !data.isEmpty else { return false }
        offset += UInt64(data.count); pending.append(data)
        guard let last = pending.lastIndex(of: 10) else { if pending.count > 65536 { pending.removeAll() }; return false }
        let complete = pending.prefix(through: last); pending.removeSubrange(...last)
        return String(decoding: complete, as: UTF8.self).contains("OCCUR ANR")
    }
    private func openAtEnd(pid: Int32) {
        var paths = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout.size(ofValue: paths))) == MemoryLayout.size(ofValue: paths) else { return }
        let cwd = withUnsafeBytes(of: &paths.pvi_cdir.vip_path) { bytes -> String in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd + "/dwrg.exe") else { return }
        let fd = Darwin.open(cwd + "/log.txt", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), (value.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); return }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let end = try? file.seekToEnd() else { try? file.close(); return }
        handle = file; filePath = cwd + "/log.txt"; inode = UInt64(value.st_ino); offset = end; available = true
    }
    static func fixtureChecks() -> [Bool] {
        let fm = FileManager.default, old = fm.currentDirectoryPath
        let root = fm.temporaryDirectory.appendingPathComponent("idv-anr-fixture-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: false)) != nil else { return [false] }
        defer { _ = fm.changeCurrentDirectoryPath(old); try? fm.removeItem(at: root) }
        guard fm.changeCurrentDirectoryPath(root.path), let identity = GameProcessIdentity.read(getpid()) else { return [false] }
        let log = root.appendingPathComponent("log.txt")
        try? Data().write(to: root.appendingPathComponent("dwrg.exe"))
        try? Data("OCCUR ANR old\n".utf8).write(to: log)
        let reader = GameANRReader()
        let skipsOld = !reader.poll(identity) && reader.available
        func append(_ text: String) {
            guard let writer = try? FileHandle(forWritingTo: log) else { return }
            _ = try? writer.seekToEnd(); try? writer.write(contentsOf: Data(text.utf8)); try? writer.close()
        }
        append("OCCUR "); let partial = !reader.poll(identity)
        append("ANR new\n"); let new = reader.poll(identity), once = !reader.poll(identity)
        try? Data("OCCUR ANR rotated\n".utf8).write(to: log, options: .atomic)
        let rotationSkipsOld = !reader.poll(identity)
        append("OCCUR ANR after rotation\n"); let afterRotation = reader.poll(identity)
        reader.reset()
        return [skipsOld, partial, new, once, rotationSkipsOld, afterRotation]
    }
}

struct GameHangIncident {
    let id = UUID().uuidString
    let identity: GameProcessIdentity
    let reason: String
}

struct MonitorHealthSample: Codable {
    let resources: MonitorResourceSnapshot
    let foreground: Bool
    let captureFresh: Bool
    let unchangedSeconds: Double?
    let newANR: Bool
    let anrReadable: Bool
}
struct MonitorHangEvidence: Codable {
    let timestamp: TimeInterval
    let targetPID: Int32
    let reason: String
    let samples: [MonitorHealthSample]
}
