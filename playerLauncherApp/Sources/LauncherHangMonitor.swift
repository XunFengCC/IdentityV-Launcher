import AppKit
import Darwin
import Foundation

/// A game session is launcher-owned only when the runner's private session
/// record and the live process command agree.  In particular, a bare Wine
/// `dwrg.exe` process is not enough to claim a product or to restart it.
struct LauncherGameSession: Equatable {
    let productID: GameProductID
    let identity: GameProcessIdentity
}

struct LauncherHangIncident: Equatable {
    let id: String
    let session: LauncherGameSession
    let reason: String
    let timestamp: TimeInterval

    init(session: LauncherGameSession, reason: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        id = UUID().uuidString
        self.session = session
        self.reason = reason
        self.timestamp = timestamp
    }
}

/// Product/session matching used by both the live monitor and its offline
/// fixture.  The runner writes one private record per product; the record's
/// PID is still checked against the current process identity before sampling.
enum LauncherGameSessionMatcher {
    private struct ProcessRow {
        let pid: Int32
        let uid: UInt32
        let command: String
    }

    private struct SessionRecord {
        let productID: GameProductID
        let pid: Int32
        let windowsRoot: String
    }

    static func verifiedSessions(
        snapshot: String,
        supportDirectory: URL = ToolboxPath.userSupport,
        identityReader: (Int32) -> GameProcessIdentity? = GameProcessIdentity.read
    ) -> [LauncherGameSession] {
        let rows = processRows(in: snapshot)
        return GameProductID.allCases.compactMap { productID in
            guard let record = readSession(productID: productID, supportDirectory: supportDirectory),
                  let row = rows.first(where: { $0.pid == record.pid && $0.uid == getuid() }),
                  commandMatches(row.command, productID: productID, windowsRoot: record.windowsRoot),
                  let identity = identityReader(record.pid) else { return nil }
            return LauncherGameSession(productID: productID, identity: identity)
        }
    }

    /// Revalidation intentionally accepts another product running at the same
    /// time.  It rejects a PID reuse, product switch, or a missing/replaced
    /// launcher-owned session before the destructive product action is queued.
    static func canConfirmRestart(
        captured: LauncherGameSession,
        current: [LauncherGameSession]
    ) -> Bool {
        current.filter { $0.productID == captured.productID }.count == 1
            && current.contains(captured)
    }

    private static func processRows(in snapshot: String) -> [ProcessRow] {
        snapshot.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = String(rawLine).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  let pid = Int32(fields[0]), pid > 1,
                  let uid = UInt32(fields[1]) else { return nil }
            return ProcessRow(pid: pid, uid: uid, command: String(fields[2]))
        }
    }

    private static func commandMatches(_ command: String, productID: GameProductID, windowsRoot: String) -> Bool {
        let expected = "c:/games/\(windowsRoot)/dwrg.exe".lowercased()
        let normalized = command.replacingOccurrences(of: "\\", with: "/").lowercased()
        let firstToken = command
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .map { $0.replacingOccurrences(of: "\\", with: "/").lowercased() }
        guard firstToken == expected else { return false }

        switch productID {
        case .mainland:
            return windowsRoot == "IdentityV"
                && normalized.contains("--start_from_launcher=1")
                && !normalized.contains("c:/games/identityvglobal/dwrg.exe")
        case .global:
            // The global runner deliberately has no launcher argument; the
            // session file is the ownership proof that disambiguates it from
            // a manually started process in another Wine prefix.
            return windowsRoot == "IdentityVGlobal"
                && !normalized.contains("--start_from_launcher=1")
                && !normalized.contains("c:/games/identityv/dwrg.exe")
        }
    }

    private static func readSession(productID: GameProductID, supportDirectory: URL) -> SessionRecord? {
        let file = supportDirectory.appendingPathComponent(".launcher-session-\(productID.rawValue).env")
        guard privateSessionFile(file) else { return nil }
        guard let data = try? Data(contentsOf: file), data.count > 0, data.count <= 512,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  !pair[0].isEmpty,
                  values[String(pair[0])] == nil,
                  !pair[1].contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { return nil }
            values[String(pair[0])] = String(pair[1])
        }
        guard values["schema"] == "1",
              values["product"] == productID.rawValue,
              let rawPID = values["wine_pid"], let pid = Int32(rawPID), pid > 1,
              let windowsRoot = values["windows_root"],
              windowsRoot == (productID == .mainland ? "IdentityV" : "IdentityVGlobal") else { return nil }
        guard let rawRunnerPID = values["runner_pid"], let runnerPID = Int32(rawRunnerPID), runnerPID > 1 else { return nil }
        return SessionRecord(productID: productID, pid: pid, windowsRoot: windowsRoot)
    }

    private static func privateSessionFile(_ file: URL) -> Bool {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid() else { return false }
        let mode = metadata.st_mode & 0o777
        return mode == 0o600
    }

    static func fixtureChecks() -> [Bool] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("idv-launcher-hang-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: false)) != nil else { return [false] }
        defer { try? fm.removeItem(at: root) }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let mainlandIdentity = GameProcessIdentity(pid: 41001, startSeconds: 10, startMicros: 20)
        let globalIdentity = GameProcessIdentity(pid: 41002, startSeconds: 11, startMicros: 21)
        let mainFile = root.appendingPathComponent(".launcher-session-mainland.env")
        let globalFile = root.appendingPathComponent(".launcher-session-global.env")
        try? Data("schema=1\nproduct=mainland\nrunner_pid=41000\nwine_pid=41001\nwindows_root=IdentityV\n".utf8).write(to: mainFile)
        try? Data("schema=1\nproduct=global\nrunner_pid=41003\nwine_pid=41002\nwindows_root=IdentityVGlobal\n".utf8).write(to: globalFile)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mainFile.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: globalFile.path)

        let snapshot = [
            "41001 \(getuid()) C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1 --is_multi_start",
            "41002 \(getuid()) C:\\Games\\IdentityVGlobal\\dwrg.exe",
            "41004 \(getuid()) /bin/zsh -c C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1",
            "41005 \(getuid()) C:\\Games\\IdentityV\\dwrg.exe"
        ].joined(separator: "\n")
        let sessions = verifiedSessions(snapshot: snapshot, supportDirectory: root) { pid in
            switch pid {
            case mainlandIdentity.pid: return mainlandIdentity
            case globalIdentity.pid: return globalIdentity
            default: return nil
            }
        }
        let rejectedWrongProductPath = verifiedSessions(
            snapshot: "41001 \(getuid()) C:\\Games\\IdentityVGlobal\\dwrg.exe --start_from_launcher=1",
            supportDirectory: root
        ) { _ in mainlandIdentity }.isEmpty
        let rejectedShellWrapper = sessions.allSatisfy { $0.identity.pid != 41004 }
        return [
            sessions.count == 2,
            sessions.contains(LauncherGameSession(productID: .mainland, identity: mainlandIdentity)),
            sessions.contains(LauncherGameSession(productID: .global, identity: globalIdentity)),
            rejectedWrongProductPath,
            rejectedShellWrapper
        ]
    }
}

enum LauncherHangRestartValidation {
    static func fixtureChecks() -> [Bool] {
        let identity = GameProcessIdentity(pid: 100, startSeconds: 2, startMicros: 3)
        let captured = LauncherGameSession(productID: .mainland, identity: identity)
        let reusedPID = LauncherGameSession(
            productID: .mainland,
            identity: GameProcessIdentity(pid: 100, startSeconds: 9, startMicros: 3)
        )
        let changedProduct = LauncherGameSession(productID: .global, identity: identity)
        return [
            LauncherGameSessionMatcher.canConfirmRestart(captured: captured, current: [captured]),
            !LauncherGameSessionMatcher.canConfirmRestart(captured: captured, current: [reusedPID]),
            !LauncherGameSessionMatcher.canConfirmRestart(captured: captured, current: [changedProduct]),
            !LauncherGameSessionMatcher.canConfirmRestart(captured: captured, current: [captured, captured])
        ]
    }
}

private struct LauncherHangEvidence: Codable {
    let schemaVersion: Int
    let timestamp: TimeInterval
    let productID: GameProductID
    let targetPID: Int32
    let targetStartSeconds: UInt64
    let targetStartMicros: UInt64
    let reason: String
    let samples: [MonitorHealthSample]
}

/// Writes only bounded numeric samples to a private, exclusive file.  The
/// launcher does not copy game logs, screenshots, account data, or chat text.
private enum LauncherHangEvidenceStore {
    static func save(_ incident: LauncherHangIncident, samples: [MonitorHealthSample]) {
        let support = ToolboxPath.userSupport.standardizedFileURL
        guard privateDirectory(support) else { return }
        let diagnostics = support.appendingPathComponent("Diagnostics", isDirectory: true)
        let health = diagnostics.appendingPathComponent("Health", isDirectory: true)
        guard makePrivateDirectory(diagnostics), makePrivateDirectory(health) else { return }

        let filename = "suspected-hang-\(incident.id).json"
        let destination = health.appendingPathComponent(filename)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let evidence = LauncherHangEvidence(
            schemaVersion: 1,
            timestamp: incident.timestamp,
            productID: incident.session.productID,
            targetPID: incident.session.identity.pid,
            targetStartSeconds: incident.session.identity.startSeconds,
            targetStartMicros: incident.session.identity.startMicros,
            reason: String(incident.reason.prefix(256)),
            samples: samples
        )
        guard let data = try? JSONEncoder().encode(evidence) else { return }
        do {
            try handle.write(contentsOf: data)
            fsync(fd)
        } catch {
            return
        }
    }

    private static func privateDirectory(_ directory: URL) -> Bool {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid() else { return false }
        return metadata.st_mode & 0o777 == 0o700
    }

    private static func makePrivateDirectory(_ directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: directory.path) {
            return privateDirectory(directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return privateDirectory(directory)
        } catch {
            return false
        }
    }
}

/// Launcher-owned monitor.  It has its own DispatchSourceTimer so monitoring
/// remains active after the main launcher window is closed or minimized.
final class LauncherHangMonitor: @unchecked Sendable {
    typealias SuspicionHandler = (LauncherHangIncident) -> Void
    /// Fired once when the incident this monitor last reported stops matching the
    /// warning condition, so the visible prompt can withdraw itself.
    typealias RecoveryHandler = (LauncherHangIncident) -> Void

    private final class Observation {
        let session: LauncherGameSession
        let sampler = MonitorResourceSampler()
        let anrReader = GameANRReader()
        var healthGate = GameHealthGate()
        var samples: [MonitorHealthSample] = []
        var lastIncidentID: String?
        /// The incident whose prompt is still on screen, if any.
        var openIncident: LauncherHangIncident?

        init(session: LauncherGameSession) { self.session = session }
    }

    private let queue = DispatchQueue(label: "com.xunfeng.identityv.launcher-hang-monitor", qos: .utility)
    private let onSuspicion: SuspicionHandler
    private let onRecovery: RecoveryHandler
    private var timer: DispatchSourceTimer?
    private var enabled: Bool
    private var observations: [String: Observation] = [:]
    private var activity: NSObjectProtocol?

    init(enabled: Bool, onSuspicion: @escaping SuspicionHandler,
         onRecovery: @escaping RecoveryHandler) {
        self.enabled = enabled
        self.onSuspicion = onSuspicion
        self.onRecovery = onRecovery
        start()
    }

    deinit { stop() }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enabled = enabled
            guard !enabled else { return }
            self.resetObservations()
        }
    }

    func acknowledge(_ incident: LauncherHangIncident) {
        queue.async { [weak self] in
            guard let self,
                  let observation = self.observations[incident.session.productID.rawValue],
                  observation.session == incident.session,
                  observation.lastIncidentID == incident.id else { return }
            observation.healthGate.later(now: ProcessInfo.processInfo.systemUptime)
            observation.lastIncidentID = nil
            observation.openIncident = nil
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            resetObservations()
        }
    }

    private func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        guard enabled else { return }
        let sessions = LauncherGameSessionMatcher.verifiedSessions(snapshot: processDetailsSnapshot())
        // Window closure must not allow App Nap to defer the ten-second
        // watchdog. The assertion exists only while a verified game is alive;
        // it deliberately allows normal display/system sleep.
        if !sessions.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "用户启用的游戏无响应提醒")
        } else if sessions.isEmpty { endActivity() }
        let activeProducts = Set(sessions.map { $0.productID.rawValue })
        let staleProducts = observations.keys.filter { !activeProducts.contains($0) }
        for productID in staleProducts {
            observations[productID]?.anrReader.reset()
            observations[productID]?.openIncident = nil
            observations.removeValue(forKey: productID)
        }

        for session in sessions {
            let observation: Observation
            let key = session.productID.rawValue
            if let current = observations[key], current.session == session {
                observation = current
            } else {
                observations[key]?.anrReader.reset()
                observation = Observation(session: session)
                observations[key] = observation
            }

            let resources = observation.sampler.sample(targetPID: session.identity.pid)
            let anr = observation.anrReader.poll(session.identity)
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.identity.pid
            let now = ProcessInfo.processInfo.systemUptime
            // A fresh ANR is strong process evidence even when the game is no
            // longer frontmost.  Foreground verification is still required
            // for the weaker GPU-submission stall path below.
            let row = MonitorHealthSample(
                resources: resources,
                foreground: foreground,
                captureFresh: false,
                unchangedSeconds: nil,
                newANR: anr,
                anrReadable: observation.anrReader.available
            )
            observation.samples.append(row)
            if observation.samples.count > 60 {
                observation.samples.removeFirst(observation.samples.count - 60)
            }

            let reason = observation.healthGate.observe(
                now: now,
                foreground: foreground,
                validCapture: false,
                unchangedSeconds: nil,
                newANR: anr,
                gpuSubmissionStamp: foreground ? resources.gameGPULastSubmitted : nil,
                gpuStallSeconds: 10
            )

            // Recovery is checked against the incident we actually reported, and
            // only for that one: a prompt must not disappear because a different,
            // later stall resolved. It is checked before the new-warning path so a
            // recovered game reports recovery rather than staying silent.
            if reason == nil, let open = observation.openIncident,
               observation.healthGate.observeRecovery(now: now, foreground: foreground, newANR: anr,
                                                      gpuSubmissionStamp: foreground ? resources.gameGPULastSubmitted : nil) {
                observation.openIncident = nil
                observation.lastIncidentID = nil
                onRecovery(open)
            }

            guard let reason else { continue }

            let incident = LauncherHangIncident(
                session: session,
                reason: reason,
                timestamp: Date().timeIntervalSince1970
            )
            observation.lastIncidentID = incident.id
            observation.openIncident = incident
            LauncherHangEvidenceStore.save(incident, samples: observation.samples)
            onSuspicion(incident)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func resetObservations() {
        endActivity()
        for observation in observations.values { observation.anrReader.reset() }
        observations.removeAll()
    }

    private static func processDetailsSnapshot() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private func processDetailsSnapshot() -> String {
        Self.processDetailsSnapshot()
    }
}

#if TOOLBOX_LAUNCHER_HANG_SELF_TEST
@main
struct LauncherHangMonitorSelfTest {
    static func main() throws {
        let groups: [(String, [Bool])] = [
            ("sessionMatcher", LauncherGameSessionMatcher.fixtureChecks()),
            ("restartValidation", LauncherHangRestartValidation.fixtureChecks()),
            ("healthGate", GameHealthGate.fixtureChecks()),
            ("healthRecovery", GameHealthGate.recoveryFixtureChecks()),
            ("anrReader", GameANRReader.fixtureChecks()),
            ("promptClient", LauncherHangPromptClient.fixtureChecks())
        ]
        let checks = groups.flatMap { $0.1 }
        guard checks.allSatisfy({ $0 }) else {
            // Name the failing group and index: an index-only dump cost a full
            // rebuild cycle the first time this gate fired.
            let failures = groups.flatMap { name, values in
                values.enumerated().filter { !$0.element }.map { "\(name)[\($0.offset)]" }
            }
            FileHandle.standardError.write(Data("启动器疑似卡死会话自检失败：\(failures.joined(separator: ", "))\n总检查数 \(checks.count)\n".utf8))
            throw SelfTestError.failed
        }
        print("启动器疑似卡死会话自检通过。")
    }

    private enum SelfTestError: Error { case failed }
}
#endif
