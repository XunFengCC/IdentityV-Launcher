import Foundation
import Darwin

/// Owns only samplers launched by this Toolbox and bound to an exact persisted
/// record. A manually started sampler is deliberately detected for
/// display/deduplication, but never adopted or terminated. Recovery after a
/// Toolbox restart is permitted only when PID, UID, target, executable and the
/// unique per-run output path all still match the live command.
struct DenseSamplerRecord: Codable, Equatable {
    let samplerPID: Int32
    let targetPID: Int32
    let userID: uid_t
    let executablePath: String
    /// Per-run output path makes a reused PID distinguishable from the
    /// original sampler command.
    let outputPath: String?
}

struct DenseSamplerProcess: Equatable {
    let pid: Int32
    let uid: uid_t
    let command: String
    let targetPID: Int32
}

/// Result of a stop request for one exact sampler record.  A caller must not
/// treat `stillRunning` or `notOwned` as a completed capture.
enum DenseSamplerStopResult: Equatable {
    case stopped(DenseSamplerRecord)
    case stillRunning(DenseSamplerRecord)
    case notOwned
}

enum DenseSamplerStopPlan {
    static func processMatches(_ record: DenseSamplerRecord, snapshot: String) -> Bool {
        DenseMonitoringProcessMatcher.parseProcesses(snapshot).contains {
            $0.pid == record.samplerPID
                && $0.uid == record.userID
                && $0.targetPID == record.targetPID
                && DenseMonitoringProcessMatcher.executablePath(in: $0.command) == record.executablePath
                && (record.outputPath == nil || $0.command.contains("--output \(record.outputPath!)"))
        }
    }

    static func outcome(
        record: DenseSamplerRecord,
        ownedRecord: DenseSamplerRecord?,
        before: String,
        signalSucceeded: Bool,
        after: [String]
    ) -> DenseSamplerStopResult {
        guard ownedRecord == record, processMatches(record, snapshot: before) else { return .notOwned }
        guard signalSucceeded else { return .stillRunning(record) }
        return after.contains(where: { !processMatches(record, snapshot: $0) })
            ? .stopped(record)
            : .stillRunning(record)
    }
}

private struct DenseSamplerMetadata: Encodable {
    let driver: String
    let target: Int32
    let sampler: String
    let samplerPID: Int32
    let wineserverPID: Int32?
    let explorerPID: Int32?
    let windowServerPID: Int32?
    let startedAt: String
}

private struct DenseSupportingProcesses: Equatable {
    let wineserverPID: Int32?
    let explorerPID: Int32?
    let windowServerPID: Int32?
}

enum DenseMonitoringProcessMatcher {
    /// Finder/launchd need not supply a UTF-8 locale. BSD ps then vis-escapes
    /// Chinese app names (M-g...), falsely reporting our live sampler absent.
    /// Keep display/stop snapshots identical, Unicode-preserving and uncut.
    static func processSnapshot() -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-axo", "pid=,uid=,command="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseProcesses(_ snapshot: String) -> [DenseSamplerProcess] {
        snapshot.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  let pid = Int32(fields[0]), let parsedUID = UInt32(fields[1]),
                  samplerTarget(in: String(fields[2])) != nil else { return nil }
            return DenseSamplerProcess(pid: pid, uid: uid_t(parsedUID), command: String(fields[2]), targetPID: samplerTarget(in: String(fields[2]))!)
        }
    }

    static func matchingSampler(
        in snapshot: String,
        targetPID: Int32,
        userID: uid_t
    ) -> DenseSamplerProcess? {
        parseProcesses(snapshot).first { $0.targetPID == targetPID && $0.uid == userID }
    }

    static func isSamplerCommand(_ command: String) -> Bool {
        let first = executablePath(in: command) ?? ""
        return first == "idv-dense-metrics" || first.hasSuffix("/idv-dense-metrics")
    }

    static func executablePath(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "\"" {
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    fileprivate static func supportingProcesses(in snapshot: String, userID: uid_t) -> DenseSupportingProcesses {
        var wineservers: [Int32] = []
        var explorers: [Int32] = []
        var windowServers: [Int32] = []
        for rawLine in snapshot.split(whereSeparator: \.isNewline) {
            let fields = String(rawLine).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let parsedUID = UInt32(fields[1]) else {
                continue
            }
            let command = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let executable = (executablePath(in: command) ?? "")
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
            if uid_t(parsedUID) == userID,
               command == "wineserver" || command.hasSuffix("/wineserver") {
                wineservers.append(pid)
            }
            if uid_t(parsedUID) == userID,
               executable == "explorer.exe" || executable.hasSuffix("/explorer.exe") {
                explorers.append(pid)
            }
            if executable == "windowserver" || executable.hasSuffix("/windowserver") {
                windowServers.append(pid)
            }
        }
        return DenseSupportingProcesses(
            wineserverPID: wineservers.count == 1 ? wineservers[0] : nil,
            explorerPID: explorers.count == 1 ? explorers[0] : nil,
            windowServerPID: windowServers.count == 1 ? windowServers[0] : nil
        )
    }

    private static func samplerTarget(in command: String) -> Int32? {
        guard isSamplerCommand(command) else { return nil }
        let pattern = "(?:^|[[:space:]])--pid[[:space:]]+([0-9]+)(?:[[:space:]]|$)"
        guard let range = command.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(command[range])
        return matched.split(whereSeparator: { $0.isWhitespace }).last.flatMap { Int32($0) }
    }
}

@MainActor
final class DenseMonitoringController {
    private let samplerURL: URL
    private let root: URL
    private let userID = getuid()
    private var ownedRecord: DenseSamplerRecord?

    init?(samplerURL: URL?, root: URL) {
        guard let samplerURL, FileManager.default.isExecutableFile(atPath: samplerURL.path) else { return nil }
        self.samplerURL = samplerURL
        self.root = root
    }

    func status(gamePID: Int32?, snapshot: String) -> DenseMonitoringState {
        guard let gamePID else { return .idle }
        if let existing = DenseMonitoringProcessMatcher.matchingSampler(
            in: snapshot, targetPID: gamePID, userID: userID
        ) {
            // A record persisted by an earlier Toolbox process is evidence for
            // display only. Never adopt it: PID reuse would make stop unsafe.
            return .recording(targetPID: gamePID, samplerPID: existing.pid, owned: ownedRecord.map { DenseSamplerStopPlan.processMatches($0, snapshot: snapshot) && $0.samplerPID == existing.pid } ?? false)
        }
        // Observation must not discard a pending capture's ownership. Dense
        // can exit before the game (or hit its time limit); stop still needs
        // this in-memory record to finalize that capture without adoption.
        return .ready(targetPID: gamePID)
    }

    func start(gamePID: Int32?, snapshot: String) -> DenseMonitoringState {
        guard let gamePID else { return .idle }
        let currentSnapshot = Self.processDetailsSnapshot()
        let checkedSnapshot = currentSnapshot.isEmpty ? snapshot : currentSnapshot
        let current = status(gamePID: gamePID, snapshot: checkedSnapshot)
        if case .recording = current {
            return current
        }
        if let record = startSampler(targetPID: gamePID, snapshot: checkedSnapshot) {
            return .recording(targetPID: record.targetPID, samplerPID: record.samplerPID, owned: true)
        }
        return .ready(targetPID: gamePID)
    }

    /// Starts a new sampler and returns its complete ownership record.  It
    /// deliberately refuses to adopt an already-running historical sampler.
    func startNewRecord(gamePID: Int32?, snapshot: String) -> DenseSamplerRecord? {
        guard let gamePID, ownedRecord == nil else { return nil }
        let live = Self.processDetailsSnapshot()
        let checkedSnapshot = live.isEmpty ? snapshot : live
        guard case .ready = status(gamePID: gamePID, snapshot: checkedSnapshot) else { return nil }
        return startSampler(targetPID: gamePID, snapshot: checkedSnapshot)
    }

    func stop(snapshot: String) -> DenseSamplerStopResult? {
        guard let ownedRecord else { return nil }
        return stop(record: ownedRecord, snapshot: snapshot)
    }

    /// Signals only the caller's exact current record, then verifies that PID
    /// has exited.  Persisted history is never searched as a fallback: an old
    /// record can name a PID that has since been reused.
    func stop(record: DenseSamplerRecord, snapshot: String) -> DenseSamplerStopResult {
        guard ownedRecord == record else { return .notOwned }
        // The target may have exited and Dense may already have self-stopped.
        // A different command at the reused PID is likewise never signalled.
        guard DenseSamplerStopPlan.processMatches(record, snapshot: snapshot) else {
            ownedRecord = nil
            return .stopped(record)
        }
        guard kill(record.samplerPID, SIGTERM) == 0 else {
            return .stillRunning(record)
        }
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.1)
            if !DenseSamplerStopPlan.processMatches(record, snapshot: Self.processDetailsSnapshot()) {
                ownedRecord = nil
                return .stopped(record)
            }
        }
        return .stillRunning(record)
    }

#if TOOLBOX_PROCESS_SELF_TEST
    /// Exercises the controller's ownership handoff with snapshots only.
    /// `/usr/bin/true` makes construction side-effect free; the synthetic
    /// sampler command still uses the production matcher name so this fixture
    /// covers the same PID/UID/target/executable/output identity checks.
    static func fixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "idv-dense-controller-fixture-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        guard let controller = DenseMonitoringController(
            samplerURL: URL(fileURLWithPath: "/usr/bin/true"), root: root
        ) else { return [false] }

        let userID = getuid()
        let targetPID: Int32 = 75512
        let samplerPID: Int32 = 78205
        let executablePath = "/private/tmp/idv-dense-metrics"
        let outputPath = root.appendingPathComponent("telemetry.jsonl").path
        let reusedOutputPath = root.appendingPathComponent("reused.jsonl").path
        let historicalOutputPath = root.appendingPathComponent("historical.jsonl").path
        let currentRecord = DenseSamplerRecord(
            samplerPID: samplerPID,
            targetPID: targetPID,
            userID: userID,
            executablePath: executablePath,
            outputPath: outputPath
        )
        let historicalRecord = DenseSamplerRecord(
            samplerPID: samplerPID - 1,
            targetPID: targetPID,
            userID: userID,
            executablePath: executablePath,
            outputPath: historicalOutputPath
        )
        func snapshot(outputPath: String) -> String {
            "\(samplerPID) \(userID) \(executablePath) --pid \(targetPID) --output \(outputPath) --hz 20 --seconds 7200"
        }

        let liveSnapshot = snapshot(outputPath: outputPath)
        let reusedSnapshot = snapshot(outputPath: reusedOutputPath)

        // An exact current process remains owned and visible as such. Do not
        // call stop for this snapshot: the fixture must never signal a real
        // process, even if the synthetic PID happens to be reused on-host.
        controller.ownedRecord = currentRecord
        let liveState = controller.status(gamePID: targetPID, snapshot: liveSnapshot)
        let historicalStop = controller.stop(record: historicalRecord, snapshot: liveSnapshot)
        let pendingStartRefused = controller.startNewRecord(
            gamePID: targetPID, snapshot: liveSnapshot
        ) == nil

        // Dense may exit between refresh and stop. status must preserve the
        // pending record so the explicit stop can finalize it as stopped.
        let exitedState = controller.status(gamePID: targetPID, snapshot: "")
        let exitedStop = controller.stop(record: currentRecord, snapshot: "")

        // A reused PID with a different output path is visible, but does not
        // match our record and therefore must be treated as already stopped.
        controller.ownedRecord = currentRecord
        let reusedState = controller.status(gamePID: targetPID, snapshot: reusedSnapshot)
        let reusedStop = controller.stop(record: currentRecord, snapshot: reusedSnapshot)
        let reusedStillVisible = controller.status(gamePID: targetPID, snapshot: reusedSnapshot)

        return [
            liveState == .recording(targetPID: targetPID, samplerPID: samplerPID, owned: true),
            historicalStop == .notOwned,
            pendingStartRefused,
            exitedState == .ready(targetPID: targetPID),
            exitedStop == .stopped(currentRecord),
            reusedState == .recording(targetPID: targetPID, samplerPID: samplerPID, owned: false),
            reusedStop == .stopped(currentRecord),
            reusedStillVisible == .recording(targetPID: targetPID, samplerPID: samplerPID, owned: false),
        ]
    }
#endif

    private func startSampler(targetPID: Int32, snapshot: String) -> DenseSamplerRecord? {
        guard ownedRecord == nil else { return ownedRecord }
        var startedProcess: Process?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let directory = root.appendingPathComponent("\(timestamp)-pid-\(targetPID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let output = directory.appendingPathComponent("telemetry.jsonl")
            let metadata = directory.appendingPathComponent("metadata.json")
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let process = Process()
            let supporting = DenseMonitoringProcessMatcher.supportingProcesses(
                in: snapshot, userID: userID
            )
            process.executableURL = samplerURL
            var arguments = [
                "--pid", String(targetPID),
                "--output", output.path,
                "--hz", "20",
                "--seconds", "0",
                "--parent-pid", String(getpid()),
            ]
            if let pid = supporting.wineserverPID {
                arguments += ["--wineserver-pid", String(pid)]
            }
            if let pid = supporting.explorerPID {
                arguments += ["--explorer-pid", String(pid)]
            }
            if let pid = supporting.windowServerPID {
                arguments += ["--windowserver-pid", String(pid)]
            }
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            startedProcess = process
            let record = DenseSamplerRecord(
                samplerPID: process.processIdentifier,
                targetPID: targetPID,
                userID: userID,
                executablePath: samplerURL.path,
                outputPath: output.path
            )
            try JSONEncoder().encode(DenseSamplerMetadata(
                driver: "IdentityVToolbox",
                target: targetPID,
                sampler: samplerURL.path,
                samplerPID: process.processIdentifier,
                wineserverPID: supporting.wineserverPID,
                explorerPID: supporting.explorerPID,
                windowServerPID: supporting.windowServerPID,
                startedAt: ISO8601DateFormatter().string(from: Date())
            )).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            try JSONEncoder().encode(record).write(
                to: directory.appendingPathComponent("sampler.pid"), options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: directory.appendingPathComponent("sampler.pid").path
            )
            ownedRecord = record
            return record
        } catch {
            // If metadata persistence fails after Process.run(), do not leave
            // an unowned sampler behind.
            if startedProcess?.isRunning == true {
                startedProcess?.terminate()
            }
            // The UI remains armed; a later status refresh can retry.  No game
            // process is ever affected by a diagnostics failure.
            return nil
        }
    }

    private func persistedRecord(matching process: DenseSamplerProcess) -> DenseSamplerRecord? {
        persistedRecords().first { record in
            record.samplerPID == process.pid
                && record.targetPID == process.targetPID
                && record.userID == process.uid
                && DenseMonitoringProcessMatcher.executablePath(in: process.command) == record.executablePath
                && (record.outputPath == nil || process.command.contains("--output \(record.outputPath!)"))
        }
    }

    private func persistedRecords() -> [DenseSamplerRecord] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { directory in
            let file = directory.appendingPathComponent("sampler.pid")
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DenseSamplerRecord.self, from: data),
                  record.userID == userID,
                  record.executablePath == samplerURL.path else { return nil }
            return record
        }
    }

    private static func processDetailsSnapshot() -> String {
        DenseMonitoringProcessMatcher.processSnapshot()
    }
}

#if TOOLBOX_PROCESS_SELF_TEST
enum DenseMonitoringProcessMatcherSelfTest {
    static func checks() -> [Bool] {
        let manual = "78205 501 /Users/fengyin/project/denseMetrics/idv-dense-metrics --pid 75512 --output /tmp/telemetry.jsonl --hz 20 --seconds 7200"
        let wrongTarget = "78206 501 /Users/fengyin/project/denseMetrics/idv-dense-metrics --pid 123 --output /tmp/a"
        let watcher = "78207 501 /bin/zsh -c ps -axo command= | rg idv-dense-metrics --pid 75512"
        let wrongUID = "78208 0 /tmp/idv-dense-metrics --pid 75512 --output /tmp/a"
        let wineserver = "70001 501 /example/identityv-runtime/bin/wineserver"
        let explorer = "70002 501 C:\\windows\\system32\\explorer.exe /desktop"
        let windowServer = "639 88 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon"
        let snapshot = [manual, wrongTarget, watcher, wrongUID, wineserver, explorer, windowServer].joined(separator: "\n")
        let matched = DenseMonitoringProcessMatcher.matchingSampler(in: snapshot, targetPID: 75512, userID: 501)
        let supporting = DenseMonitoringProcessMatcher.supportingProcesses(in: snapshot, userID: 501)
        let currentRecord = DenseSamplerRecord(samplerPID: 78205, targetPID: 75512, userID: 501, executablePath: "/Users/fengyin/project/denseMetrics/idv-dense-metrics", outputPath: "/tmp/telemetry.jsonl")
        let historicalRecord = DenseSamplerRecord(samplerPID: 78206, targetPID: 123, userID: 501, executablePath: "/Users/fengyin/project/denseMetrics/idv-dense-metrics", outputPath: "/tmp/a")
        let reusedPID = "78205 501 /Users/fengyin/project/denseMetrics/idv-dense-metrics --pid 75512 --output /tmp/reused.jsonl --hz 20"
        return [
            matched?.pid == 78205,
            DenseMonitoringProcessMatcher.parseProcesses(snapshot).count == 3,
            DenseMonitoringProcessMatcher.matchingSampler(in: snapshot, targetPID: 123, userID: 501)?.pid == 78206,
            DenseMonitoringProcessMatcher.matchingSampler(in: snapshot, targetPID: 75512, userID: 0)?.pid == 78208,
            !DenseMonitoringProcessMatcher.isSamplerCommand(watcher),
            supporting == DenseSupportingProcesses(
                wineserverPID: 70001, explorerPID: 70002, windowServerPID: 639
            ),
            // A current record names the only PID allowed to receive a signal;
            // an older valid record must not be selected merely because it is
            // first in persisted history.
            DenseSamplerStopPlan.outcome(record: currentRecord, ownedRecord: currentRecord, before: snapshot, signalSucceeded: true, after: [snapshot.replacingOccurrences(of: manual, with: "")]) == .stopped(currentRecord),
            DenseSamplerStopPlan.outcome(record: historicalRecord, ownedRecord: currentRecord, before: snapshot, signalSucceeded: true, after: [snapshot]) == .notOwned,
            DenseSamplerStopPlan.outcome(record: currentRecord, ownedRecord: currentRecord, before: snapshot, signalSucceeded: false, after: []) == .stillRunning(currentRecord),
            DenseSamplerStopPlan.outcome(record: currentRecord, ownedRecord: currentRecord, before: snapshot, signalSucceeded: true, after: [snapshot]) == .stillRunning(currentRecord),
            !DenseSamplerStopPlan.processMatches(currentRecord, snapshot: reusedPID)
        ]
    }
}
#endif

enum DenseMonitoringState: Equatable {
    case idle
    case ready(targetPID: Int32)
    case recording(targetPID: Int32, samplerPID: Int32, owned: Bool)

    var localizedDescription: String {
        switch self {
        case .idle: return "未在记录"
        case .ready(let target): return "已发现游戏 PID \(target)，可开始高密度记录"
        case .recording(let target, let sampler, let owned):
            return "正在记录游戏 PID \(target)（采集器 PID \(sampler)\(owned ? "，工具箱启动" : "，已有采集器")）"
        }
    }
}
