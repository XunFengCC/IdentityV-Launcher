import Foundation

/// Main-queue-owned client of an accessory display helper. A separate,
/// nonactivating accessory is needed for Wine's independent fullscreen Space;
/// a regular launcher's auxiliary window can disappear on that Space.
final class LauncherHangPromptClient {
    private var child: Process?
    private var writer: FileHandle?

    deinit {
        try? writer?.close()
        if let child, child.isRunning { child.terminate() }
    }

    @discardableResult
    func show(id: String, title: String, completion: @escaping (String?) -> Void) -> Bool {
        dismiss()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IdentityVHangPrompt")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let data = try? JSONEncoder().encode(HangPromptSnapshot(id: id, title: title)) else { return false }
        do {
            try process.run()
            child = process
            writer = input.fileHandleForWriting
            try writer?.write(contentsOf: data + Data([10]))
        } catch {
            dismiss()
            return false
        }
        // Drain the action before cleanup. A terminationHandler racing the
        // final stdout line could otherwise discard the user's button click.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = output.fileHandleForReading
            var buffer = Data()
            while buffer.count <= 4096,
                  let chunk = try? reader.read(upToCount: 4096), !chunk.isEmpty {
                buffer.append(chunk)
                if buffer.contains(10) { break }
            }
            try? reader.close()
            let action = Self.validAction(buffer, expectedID: id)
            DispatchQueue.main.async {
                guard let self, self.child === process else { return }
                self.dismiss()
                completion(action)
            }
        }
        return true
    }

    /// Turn the visible reminder into the self-closing recovery notice. The
    /// helper owns the auto-close, so no click or further launcher action is
    /// needed and the panel cannot linger over live gameplay.
    @discardableResult
    func showRecovery(id: String, remainingSeconds: Int) -> Bool {
        guard let writer, child?.isRunning == true,
              let data = try? JSONEncoder().encode(
                HangPromptSnapshot(id: id, title: HangPromptRecovery.title(countdown: remainingSeconds),
                                   kind: "recovered", countdown: remainingSeconds)
              ) else { return false }
        do {
            try writer.write(contentsOf: data + Data([10]))
            return true
        } catch {
            return false
        }
    }

    func dismiss() {
        let old = child
        child = nil
        let oldWriter = writer
        writer = nil
        try? oldWriter?.close()
        // EOF normally exits the helper. Retain bounded fallback ownership.
        if let old {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
                if old.isRunning { old.terminate() }
            }
        }
    }

    private static func validAction(_ data: Data, expectedID: String) -> String? {
        guard data.count <= 4096, let newline = data.firstIndex(of: 10),
              let action = try? JSONDecoder().decode(HangPromptAction.self, from: Data(data.prefix(upTo: newline))),
              action.id == expectedID, ["wait", "restart"].contains(action.action) else { return nil }
        return action.action
    }

    static func fixtureChecks() -> [Bool] {
        func line(_ id: String, _ action: String) -> Data {
            ((try? JSONEncoder().encode(HangPromptAction(id: id, action: action))) ?? Data()) + Data([10])
        }
        return [validAction(line("one", "restart"), expectedID: "one") == "restart",
                validAction(line("old", "restart"), expectedID: "one") == nil,
                validAction(line("one", "wait"), expectedID: "one") == "wait",
                validAction(line("one", "anything"), expectedID: "one") == nil,
                validAction(Data(repeating: 65, count: 4097), expectedID: "one") == nil]
    }
}
