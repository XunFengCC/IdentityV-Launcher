import AppKit
import CoreGraphics
import Foundation

private enum ActivationResult: String {
    case activated
    case activationTimedOut = "activation_timeout"
    case windowTimedOut = "window_timeout"
    case invalidTarget = "invalid_target"
    case invalidArguments = "invalid_arguments"
    case selfTestOK = "self_test_ok"
    case selfTestFailed = "self_test_failed"
    case targetVerified = "target_verified"
}

private struct Arguments {
    let pid: pid_t
    let expectedExecutable: String
    let timeout: TimeInterval
}

private func canonicalPath(_ path: String) -> String? {
    var resolved: UnsafeMutablePointer<CChar>? = nil
    path.withCString { value in
        resolved = realpath(value, nil)
    }
    guard let resolved else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func parseArguments(_ values: [String]) -> Arguments? {
    var pid: pid_t?
    var expectedExecutable: String?
    var timeout: TimeInterval?
    var index = 0

    while index < values.count {
        let option = values[index]
        guard index + 1 < values.count else { return nil }
        let value = values[index + 1]
        switch option {
        case "--pid":
            guard let number = Int32(value), number > 0 else { return nil }
            pid = pid_t(number)
        case "--expected-executable":
            guard !value.isEmpty else { return nil }
            expectedExecutable = value
        case "--timeout":
            guard let seconds = TimeInterval(value), seconds > 0, seconds <= 90 else { return nil }
            timeout = seconds
        default:
            return nil
        }
        index += 2
    }

    guard let pid, let expectedExecutable, let timeout else { return nil }
    return Arguments(pid: pid, expectedExecutable: expectedExecutable, timeout: timeout)
}

private func hasUsableWindow(for pid: pid_t) -> Bool {
    // Include hidden windows / other Spaces: being obscured is exactly why
    // the player needs this activation. Ignore Wine's 500x500 utility window.
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    for window in windows {
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID == pid,
              let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"],
              let height = bounds["Height"],
              width >= 640,
              height >= 360 else {
            continue
        }
        return true
    }
    return false
}

private func targetApplication(pid: pid_t, expectedExecutable: String) -> NSRunningApplication? {
    guard let expectedPath = canonicalPath(expectedExecutable),
          let application = NSRunningApplication(processIdentifier: pid),
          let executableURL = application.executableURL,
          let actualPath = canonicalPath(executableURL.path),
          sameLoader(actualPath, expectedPath) else {
        return nil
    }
    return application
}

// CodeWeavers starts an exact copy of its loader in winetemp, named after a
// Windows process. Compare bounded file contents as well as canonical paths;
// never accept a process just because its display name contains "wine".
private func sameLoader(_ actual: String, _ expected: String) -> Bool {
    if actual == expected { return true }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard let a = try? URL(fileURLWithPath: actual).resourceValues(forKeys: keys),
          let e = try? URL(fileURLWithPath: expected).resourceValues(forKeys: keys),
          a.isRegularFile == true, e.isRegularFile == true,
          let size = a.fileSize, size > 0, size <= 16 * 1024 * 1024,
          size == e.fileSize,
          let lhs = try? Data(contentsOf: URL(fileURLWithPath: actual)),
          let rhs = try? Data(contentsOf: URL(fileURLWithPath: expected)) else { return false }
    return lhs == rhs
}

private func runSelfTest() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("wine")
        let copy = directory.appendingPathComponent("dwrg.exe")
        let wrong = directory.appendingPathComponent("wrong")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.copyItem(at: original, to: copy)
        try Data([1, 2, 4]).write(to: wrong)
        guard sameLoader(copy.path, original.path),
              !sameLoader(wrong.path, original.path),
              !sameLoader(directory.path, original.path) else { return false }
    } catch { return false }
    return parseArguments(["--pid", "123", "--expected-executable", "/tmp/wine", "--timeout", "1"]) != nil
        && parseArguments(["--pid", "0", "--expected-executable", "/tmp/wine", "--timeout", "1"]) == nil
        && parseArguments(["--pid", "123", "--expected-executable", "/tmp/wine", "--timeout", "90"]) != nil
        && parseArguments(["--pid", "123", "--expected-executable", "/tmp/wine", "--timeout", "91"]) == nil
        && parseArguments(["--pid", "123", "--expected-executable", "/tmp/wine", "--timeout", "0"]) == nil
}

private func emit(_ result: ActivationResult, startedAt: Date) -> Never {
    let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    print("result=\(result.rawValue) elapsed_ms=\(elapsed)")
    exit(result == .activated || result == .selfTestOK || result == .targetVerified ? EXIT_SUCCESS : EXIT_FAILURE)
}

let startedAt = Date()
var supplied = Array(CommandLine.arguments.dropFirst())
let checkOnly = supplied.first == "--check-target"
if checkOnly { supplied.removeFirst() }

if supplied == ["--self-test"] {
    emit(runSelfTest() ? .selfTestOK : .selfTestFailed, startedAt: startedAt)
}

guard let arguments = parseArguments(supplied) else {
    emit(.invalidArguments, startedAt: startedAt)
}

let deadline = Date().addingTimeInterval(arguments.timeout)
while Date() < deadline {
    guard kill(arguments.pid, 0) == 0 else {
        emit(.invalidTarget, startedAt: startedAt)
    }
    // The runner starts us immediately after fork. Wait for Wine's exec and
    // AppKit registration as well as its first window, under one deadline.
    if let application = targetApplication(pid: arguments.pid, expectedExecutable: arguments.expectedExecutable),
       hasUsableWindow(for: arguments.pid) {
        if checkOnly { emit(.targetVerified, startedAt: startedAt) }
        // A bare command-line process can successfully send an activation
        // request without moving Wine forward. Register this windowless helper
        // with AppKit and use the macOS 14 cooperative activation API. It has
        // no Dock icon, never activates itself, and yields only to the validated
        // game process above. There is exactly one activation request.
        let helper = NSApplication.shared
        helper.setActivationPolicy(.accessory)
        helper.finishLaunching()
        helper.yieldActivation(to: application)
        _ = application.activate(from: .current, options: [.activateAllWindows])
        let activationDeadline = Date().addingTimeInterval(2)
        while Date() < activationDeadline {
            if application.isActive,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == arguments.pid {
                emit(.activated, startedAt: startedAt)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        emit(.activationTimedOut, startedAt: startedAt)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

emit(.windowTimedOut, startedAt: startedAt)
