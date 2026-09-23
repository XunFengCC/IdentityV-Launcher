import Darwin
import Foundation
import Metal

#if MONITOR_PROCESS_SELF_TEST
@main struct MonitorProcessSelfTest {
    static func main() {
        if CommandLine.arguments.contains("--live-resource-probe") {
            let sampler = MonitorResourceSampler()
            _ = sampler.sample(targetPID: getpid())
            let until = ProcessInfo.processInfo.systemUptime + 0.4
            while ProcessInfo.processInfo.systemUptime < until { _ = sqrt(Double.random(in: 1...100)) }
            let value = sampler.sample(targetPID: getpid())
            print(String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self))
            guard let cpu = value.gameCPUPercent, cpu > 50, cpu < 150, value.systemGPUPercent != nil else { exit(1) }
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let buffer = device.makeBuffer(length: 4 * 1024 * 1024) else { exit(1) }
            func gpuWork() {
                guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return }
                blit.fill(buffer: buffer, range: 0..<buffer.length, value: 17); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            }
            gpuWork(); Thread.sleep(forTimeInterval: 1.1); _ = sampler.sample(targetPID: getpid())
            for _ in 0..<50 { gpuWork() }
            Thread.sleep(forTimeInterval: 1.1)
            let gpu = sampler.sample(targetPID: getpid())
            print(String(decoding: (try? JSONEncoder().encode(gpu)) ?? Data(), as: UTF8.self))
            guard let share = gpu.gameGPUPercent, share > 0, gpu.gameGPULastSubmitted != nil else { exit(1) }
            return
        }
        let game = "75512 501 C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1"
        let watcher = "75513 501 /bin/zsh -c ps -axo command= | rg dwrg.exe"
        let capture = CombinedCaptureRecord(startedAtEpoch: 1_725_000_123.456, targetPID: 75512, captureDirectory: "/private/tmp/identityv-capture", visualOutputPath: "/private/tmp/identityv-capture/visual-fps.jsonl", includesMetal: true)
        let collect = MetalPerfTraceExportPlan.collectArguments(record: capture, endedAtEpoch: 1_725_000_456.789, outputDirectory: URL(fileURLWithPath: "/private/tmp/identityv-capture/Metal-test"))
        let securityChecks = fixtureSecurityChecks()
        let freezeChecks = FreezeStackCaptureController.fixtureChecks()
        let denseChecks = DenseMonitoringController.fixtureChecks()
        let checks = [
            processSnapshotEncodingCheck(),
            MonitorViewModel.refreshReentryChecks().allSatisfy { $0 },
            !MetalPerfTraceExportPlan.overviewHasData(Data(#"{"error": "No session found"}"#.utf8)),
            !MetalPerfTraceExportPlan.overviewHasData(Data("{}".utf8)),
            !MetalPerfTraceExportPlan.overviewHasData(Data("[]".utf8)),
            !MetalPerfTraceExportPlan.overviewHasData(Data("truncated".utf8)),
            MetalPerfTraceExportPlan.overviewHasData(Data(#"{"sessions":[{"pid":75512}]}"#.utf8)),
            MonitorGameProcessMatcher.gamePID(in: [game, watcher].joined(separator: "\n")) == 75512,
            MonitorGameProcessMatcher.gamePID(in: watcher) == nil,
            MonitorGameProcessMatcher.isGameCommand("C:\\Games\\IdentityV\\dwrg.exe --x"),
            !MonitorGameProcessMatcher.isGameCommand(watcher),
            collect == ["collect", "--start", "@1725000123.456", "--end", "@1725000456.789", "--prefix", "identityv-pid-75512", "/private/tmp/identityv-capture/Metal-test"],
            MetalPerfTraceExportPlan.isMatchingTrace(URL(fileURLWithPath: "/private/tmp/identityv-pid-75512.atrc"), targetPID: 75512),
            VisualFrameAnalyzer.fixtureChecks().allSatisfy { $0 },
            VisualCaptureControllerNative.outputFixtureChecks().allSatisfy { $0 },
            freezeChecks.allSatisfy { $0 },
            MonitorResourceSampler.fixtureChecks().allSatisfy { $0 },
            GameHealthGate.fixtureChecks().allSatisfy { $0 },
            GameANRReader.fixtureChecks().allSatisfy { $0 },
            denseChecks.allSatisfy { $0 },
            ScreenRecordingAuthorizationState.resolve(isAuthorized: false, isCapturing: false) == .notAuthorized,
            ScreenRecordingAuthorizationState.resolve(isAuthorized: true, isCapturing: false) == .authorizedIdle,
            ScreenRecordingAuthorizationState.resolve(isAuthorized: true, isCapturing: true) == .capturing,
            ScreenRecordingAuthorizationState.resolve(isAuthorized: false, isCapturing: true) == .notAuthorized,
            OverlayVisibility.fixtureChecks().allSatisfy { $0 },
            securityChecks.allSatisfy { $0 },
            MetalHUDSettings.fixtureChecks().allSatisfy { $0 },
            !String(describing: CombinedCaptureRecord.self).contains("Sidecar"),
        ] + DenseMonitoringProcessMatcherSelfTest.checks()
        guard checks.allSatisfy({ $0 }) else { FileHandle.standardError.write(Data("第五人格工具箱自检失败：\(checks) freeze=\(freezeChecks) dense=\(denseChecks)\n".utf8)); exit(1) }
    }
    /// Exercise a real BSD ps child under the same unset/C locale as a GUI
    /// launch. ASCII-only synthetic snapshots missed the installed Chinese path.
    private static func processSnapshotEncodingCheck() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-进程-\(UUID().uuidString)")
        let executable = root.appendingPathComponent("第五人格工具箱")
        let child = Process()
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
            child.executableURL = executable
            child.arguments = ["5"]
            try child.run()
            let snapshot = DenseMonitoringProcessMatcher.processSnapshot()
            return snapshot.split(whereSeparator: \.isNewline).contains {
                let fields = $0.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
                return fields.count == 3 && Int32(fields[0]) == child.processIdentifier && fields[2].contains(executable.path)
            }
        } catch { return false }
    }
    private static func fixtureSecurityChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-metal-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        let capture = root.appendingPathComponent("capture", isDirectory: true); guard MonitorSecureFS.createDirectoryOneLevel(capture) else { return [false] }
        let accepted = MetalPerfTraceExportPlan.safeCaptureDirectory(capture.path, root: root) != nil
        let outside = FileManager.default.temporaryDirectory
        let rejectedOutside = MetalPerfTraceExportPlan.safeCaptureDirectory(outside.path, root: root) == nil
        let linked = root.appendingPathComponent("linked", isDirectory: true); try? FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: outside.path)
        let rejectedSymlink = MetalPerfTraceExportPlan.safeCaptureDirectory(linked.path, root: root) == nil
        let preexisting = capture.appendingPathComponent("Metal-existing", isDirectory: true); let first = MonitorSecureFS.createDirectoryOneLevel(preexisting); let second = MonitorSecureFS.lstat(preexisting) != nil
        let traceA = preexisting.appendingPathComponent("identityv-pid-7-a.atrc"), traceB = preexisting.appendingPathComponent("identityv-pid-7-b.atrc")
        _ = MonitorSecureFS.createExclusiveFile(traceA); _ = MonitorSecureFS.createExclusiveFile(traceB)
        let multipleMatching = [traceA, traceB].filter { MetalPerfTraceExportPlan.isMatchingTrace($0, targetPID: 7) && MonitorSecureFS.isPrivateRegularFile($0) }.count == 2
        let target = root.appendingPathComponent("race-target", isDirectory: true); guard MonitorSecureFS.createDirectoryOneLevel(target) else { return [false] }
        let sentinel = target.appendingPathComponent("sentinel"); guard let handle = MonitorSecureFS.createExclusiveFile(sentinel) else { return [false] }; try? handle.write(contentsOf: Data("unchanged".utf8)); try? handle.close()
        let sentinelMode = MonitorSecureFS.lstat(sentinel).map { $0.st_mode & 0o777 }
        let raced = root.appendingPathComponent("raced", isDirectory: true)
        let raceRejected = !MonitorSecureFS.createDirectoryOneLevel(raced, raceHook: { try? FileManager.default.createSymbolicLink(atPath: raced.path, withDestinationPath: target.path) })
        let sentinelUnchanged = (try? String(contentsOf: sentinel, encoding: .utf8)) == "unchanged" && MonitorSecureFS.lstat(sentinel).map { $0.st_mode & 0o777 } == sentinelMode
        return [accepted, rejectedOutside, rejectedSymlink, first, second, multipleMatching, raceRejected, sentinelUnchanged]
    }
}
#endif
