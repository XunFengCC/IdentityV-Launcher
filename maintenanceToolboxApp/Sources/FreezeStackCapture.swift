import Darwin
import Foundation

/// Pure gate for the deliberately narrow automatic stack capture.  A still
/// login screen is not evidence of a stall: there must first have been a
/// perceptible change in the same recent scene.
struct FreezeStackTriggerState {
    private(set) var triggers = 0
    private var lastMotion: Double?
    private var stillSince: Double?
    private var lastTimestamp: Double?
    private var lastTrigger: Double?

    mutating func observe(timestamp: Double, perceptuallyChanged: Bool, captureFPS: Double, streamIsActive: Bool, targetVisible: Bool) -> Bool {
        guard timestamp.isFinite else { return false }
        // A gap in visibility/capture breaks causal continuity.  Do not let a
        // movement before an off-screen period turn into a capture after the
        // window returns; fresh on-screen motion is required.
        guard streamIsActive, targetVisible, captureFPS >= 15 else {
            lastMotion = nil
            stillSince = nil
            lastTimestamp = timestamp
            return false
        }
        defer { lastTimestamp = timestamp }
        if perceptuallyChanged {
            lastMotion = timestamp
            stillSince = nil
            return false
        }
        if stillSince == nil { stillSince = lastTimestamp ?? timestamp }
        guard let motion = lastMotion, let still = stillSince,
              timestamp - motion <= 3, timestamp - still >= 1.0,
              triggers < 5, (lastTrigger.map { timestamp - $0 >= 15 } ?? true) else { return false }
        triggers += 1
        lastTrigger = timestamp
        return true
    }

    static func fixtureChecks() -> [Bool] {
        var movingThenFrozen = FreezeStackTriggerState()
        _ = movingThenFrozen.observe(timestamp: 0, perceptuallyChanged: true, captureFPS: 60, streamIsActive: true, targetVisible: true)
        let fires = movingThenFrozen.observe(timestamp: 1.05, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true)

        var staticStart = FreezeStackTriggerState()
        let staticDoesNotFire = !staticStart.observe(timestamp: 0, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true) && !staticStart.observe(timestamp: 1, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true)

        var unavailable = FreezeStackTriggerState()
        _ = unavailable.observe(timestamp: 0, perceptuallyChanged: true, captureFPS: 60, streamIsActive: true, targetVisible: true)
        let hiddenOrSlowDoesNotFire = !unavailable.observe(timestamp: 0.6, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: false) && !unavailable.observe(timestamp: 1.2, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true) && !unavailable.observe(timestamp: 1.8, perceptuallyChanged: false, captureFPS: 10, streamIsActive: true, targetVisible: true) && !unavailable.observe(timestamp: 2.4, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true)

        var limits = FreezeStackTriggerState()
        var limitResults: [Bool] = []
        for base in stride(from: 0.0, through: 80.0, by: 16.0) {
            _ = limits.observe(timestamp: base, perceptuallyChanged: true, captureFPS: 60, streamIsActive: true, targetVisible: true)
            limitResults.append(limits.observe(timestamp: base + 1.1, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true))
        }
        _ = limits.observe(timestamp: 96, perceptuallyChanged: true, captureFPS: 60, streamIsActive: true, targetVisible: true)
        let capped = !limits.observe(timestamp: 97.1, perceptuallyChanged: false, captureFPS: 60, streamIsActive: true, targetVisible: true)
        return [fires, staticDoesNotFire, hiddenOrSlowDoesNotFire, limitResults.prefix(5).allSatisfy { $0 } && limitResults.last == false, capped]
    }
}

private struct FreezeStackMarker: Codable {
    let schema: Int
    let eventID: String
    let recordedAtEpoch: TimeInterval
    let targetPID: Int32
    let stillDurationMs: Double
    let captureFPS: Double
    let samplingIntervalMs: Int
    let mayBrieflySuspendTarget: Bool
    let status: String
    let sampleExitCode: Int32?
    let timedOut: Bool
}

/// `sample` is only invoked for a current, explicitly owned combined capture.
/// It never asks for authorization, uses no shell, samples no process name,
/// and retains no child after stop/deinit.
final class FreezeStackCaptureController {
    private struct Context: Equatable { let directory: URL; let targetPID: Int32; let token: UUID }
    private let lock = NSLock()
    private var context: Context?
    private var detector = FreezeStackTriggerState()
    private var children: [UUID: Process] = [:]

    deinit { disarm() }

    func arm(captureDirectory: URL, targetPID: Int32) {
        lock.lock(); defer { lock.unlock() }
        context = Context(directory: captureDirectory, targetPID: targetPID, token: UUID())
        detector = FreezeStackTriggerState()
    }

    func disarm() {
        lock.lock()
        context = nil
        detector = FreezeStackTriggerState()
        let running = Array(children.values)
        lock.unlock()
        // Keep ownership entries until each termination handler confirms the
        // child has really exited.  A second stop/deinit can therefore still
        // see and terminate a slow child instead of forgetting it early.
        running.forEach { $0.terminate() }
    }

    func observe(timestamp: Double, perceptuallyChanged: Bool, captureFPS: Double, stillDurationMs: Double, streamIsActive: Bool, targetVisible: Bool) {
        lock.lock()
        let current = context
        let fire = current != nil && detector.observe(timestamp: timestamp, perceptuallyChanged: perceptuallyChanged, captureFPS: captureFPS, streamIsActive: streamIsActive, targetVisible: targetVisible)
        lock.unlock()
        guard fire, let current else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.capture(current, timestamp: timestamp, captureFPS: captureFPS, stillDurationMs: stillDurationMs) }
    }

    private func capture(_ current: Context, timestamp: Double, captureFPS: Double, stillDurationMs: Double) {
        guard isCurrent(current), Self.matchesExactGameProcess(pid: current.targetPID) else { return }
        let eventID = UUID().uuidString
        let destination = current.directory.appendingPathComponent("FreezeStack-\(Int64(timestamp * 1000))-\(eventID)", isDirectory: true)
        guard MonitorSecureFS.lstat(destination) == nil, MonitorSecureFS.isPrivateDirectory(current.directory), MonitorSecureFS.createDirectoryOneLevel(destination) else { return }
        let stack = destination.appendingPathComponent("sample.txt")
        let stderr = destination.appendingPathComponent("sample.stderr.log")
        guard let stackHandle = MonitorSecureFS.createExclusiveFile(stack), let stderrHandle = MonitorSecureFS.createExclusiveFile(stderr) else { return }
        defer { try? stackHandle.close(); try? stderrHandle.close() }
        guard isCurrent(current), Self.matchesExactGameProcess(pid: current.targetPID) else {
            writeMarkerIfCurrent(destination, current, .init(schema: 1, eventID: eventID, recordedAtEpoch: Date().timeIntervalSince1970, targetPID: current.targetPID, stillDurationMs: stillDurationMs, captureFPS: captureFPS, samplingIntervalMs: 100, mayBrieflySuspendTarget: true, status: "target-revalidation-failed", sampleExitCode: nil, timedOut: false))
            return
        }
        let result = runBoundedSample(pid: current.targetPID, stdout: stackHandle, stderr: stderrHandle, current: current)
        writeMarkerIfCurrent(destination, current, .init(schema: 1, eventID: eventID, recordedAtEpoch: Date().timeIntervalSince1970, targetPID: current.targetPID, stillDurationMs: stillDurationMs, captureFPS: captureFPS, samplingIntervalMs: 100, mayBrieflySuspendTarget: true, status: result.timedOut ? "timed-out" : (result.exitCode == 0 ? "captured" : "sample-failed"), sampleExitCode: result.exitCode, timedOut: result.timedOut))
    }

    private func isCurrent(_ candidate: Context) -> Bool { lock.lock(); defer { lock.unlock() }; return context == candidate }

    private func runBoundedSample(pid: Int32, stdout: FileHandle, stderr: FileHandle, current: Context) -> (exitCode: Int32?, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // `sample` otherwise creates its own /tmp copy.  /dev/fd/1 names the
        // already-open O_NOFOLLOW descriptor supplied as standardOutput, so
        // the report remains solely inside this event directory.
        process.arguments = [String(pid), "1", "100", "-mayDie", "-file", "/dev/fd/1"]
        process.standardOutput = stdout
        process.standardError = stderr
        let id = UUID()
        // Keep the revalidation/start/ownership hand-off indivisible with
        // `disarm`: it either prevents this child from starting, or observes
        // it in `children` and terminates it.
        lock.lock()
        guard context == current, Self.matchesExactGameProcess(pid: pid) else { lock.unlock(); return (nil, false) }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            self?.removeChild(id, process)
        }
        do {
            try process.run()
            children[id] = process
            lock.unlock()
        } catch {
            lock.unlock()
            return (nil, false)
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); finished.signal() }
        let timedOut = finished.wait(timeout: .now() + 2.5) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }
        return (process.isRunning ? nil : process.terminationStatus, timedOut)
    }

    private func removeChild(_ id: UUID, _ process: Process) {
        lock.lock(); defer { lock.unlock() }
        guard children[id] === process else { return }
        children.removeValue(forKey: id)
    }

    private func writeMarkerIfCurrent(_ directory: URL, _ current: Context, _ marker: FreezeStackMarker) {
        guard isCurrent(current) else { return }
        let file = directory.appendingPathComponent("event.json")
        guard let handle = MonitorSecureFS.createExclusiveFile(file), let data = try? JSONEncoder().encode(marker) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: data)
    }

    /// PID reuse is rejected by checking both owner and the exact Windows game
    /// executable command immediately before invoking `/usr/bin/sample`.
    private static func matchesExactGameProcess(pid: Int32) -> Bool {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "uid=,command="]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let fields = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let uid = uid_t(fields[0]), uid == getuid() else { return false }
        return MonitorGameProcessMatcher.isGameCommand(String(fields[1]))
    }

    static func fixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-freeze-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        let privateChild = root.appendingPathComponent("capture", isDirectory: true)
        guard MonitorSecureFS.createDirectoryOneLevel(privateChild) else { return [false] }
        let target = root.appendingPathComponent("target", isDirectory: true)
        guard MonitorSecureFS.createDirectoryOneLevel(target) else { return [false] }
        let sentinel = target.appendingPathComponent("sentinel")
        guard let handle = MonitorSecureFS.createExclusiveFile(sentinel) else { return [false] }
        try? handle.write(contentsOf: Data("unchanged".utf8)); try? handle.close()
        let link = root.appendingPathComponent("linked-capture", isDirectory: true)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let privateOK = MonitorSecureFS.isPrivateDirectory(privateChild)
        let linkRejected = !MonitorSecureFS.isPrivateDirectory(link)
        let unchanged = (try? String(contentsOf: sentinel, encoding: .utf8)) == "unchanged"
        return FreezeStackTriggerState.fixtureChecks() + [privateOK, linkRejected, unchanged, boundedLifecycleFixture(), sampleOutputContractFixture()]
    }

    /// Exercises the same bounded-child cleanup shape without invoking
    /// `sample` or attaching to any user process during the build self-test.
    private static func boundedLifecycleFixture() -> Bool {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        guard (try? child.run()) != nil else { return false }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { child.waitUntilExit(); done.signal() }
        guard done.wait(timeout: .now() + 0.05) == .timedOut else { return false }
        child.terminate()
        return done.wait(timeout: .now() + 0.5) == .success && !child.isRunning
    }

    /// Contract test for the one unusual `sample` detail: without `-file`
    /// macOS creates an auxiliary /tmp report.  Routing -file to fd 1 keeps
    /// all bytes in our already-open private file instead.
    private static func sampleOutputContractFixture() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-sample-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return false }
        let output = root.appendingPathComponent("sample.txt"), stderr = root.appendingPathComponent("sample.stderr.log")
        guard let outputHandle = MonitorSecureFS.createExclusiveFile(output), let stderrHandle = MonitorSecureFS.createExclusiveFile(stderr) else { return false }
        defer { try? outputHandle.close(); try? stderrHandle.close() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["3"]
        sleeper.standardOutput = FileHandle.nullDevice; sleeper.standardError = FileHandle.nullDevice
        guard (try? sleeper.run()) != nil else { return false }
        defer { if sleeper.isRunning { sleeper.terminate(); sleeper.waitUntilExit() } }
        let sampleReportNames: () -> Set<String> = {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []).filter {
                $0.hasPrefix("sleep_") && $0.hasSuffix(".sample.txt")
            })
        }
        let before = sampleReportNames()
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(sleeper.processIdentifier), "1", "100", "-mayDie", "-file", "/dev/fd/1"]
        sampler.standardOutput = outputHandle; sampler.standardError = stderrHandle
        guard (try? sampler.run()) != nil else { return false }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { sampler.waitUntilExit(); done.signal() }
        guard done.wait(timeout: .now() + 2.5) == .success, sampler.terminationStatus == 0 else { if sampler.isRunning { sampler.terminate() }; return false }
        let after = sampleReportNames()
        let stackNonempty = ((try? Data(contentsOf: output).count) ?? 0) > 0
        let privateOnly = MonitorSecureFS.isPrivateRegularFile(output) && MonitorSecureFS.isPrivateRegularFile(stderr)
        return stackNonempty && after.subtracting(before).isEmpty && privateOnly && !sampler.isRunning
    }
}
