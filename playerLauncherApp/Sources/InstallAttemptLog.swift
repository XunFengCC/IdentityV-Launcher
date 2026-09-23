import Foundation

/// A bounded, local-only record of a product install attempt.  The product
/// manager deliberately streams useful progress on stderr, but that output
/// used to exist only in memory, making a failed cold install impossible to
/// attribute after the launcher closed.
final class InstallAttemptLog {
    private struct Record: Encodable {
        let schemaVersion = 1
        let timestamp: String
        let attemptID: String
        let productID: String
        let targetPath: String
        let event: String
        let phase: String?
        let stream: String?
        let message: String?
        let bytesWritten: Int64?
        let totalBytesExpected: Int64?
        let exitCode: Int32?
    }

    let attemptID: String
    let url: URL
    private let productID: GameProductID
    private let targetPath: String
    private let encoder = JSONEncoder()
    private let formatter = ISO8601DateFormatter()
    private var terminalWritten = false

    private init(attemptID: String, url: URL, productID: GameProductID, targetPath: String) {
        self.attemptID = attemptID
        self.url = url
        self.productID = productID
        self.targetPath = targetPath
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    static func start(root: URL, productID: GameProductID, targetPath: String) throws -> InstallAttemptLog {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let identifier = UUID().uuidString.lowercased()
        let url = root.appendingPathComponent("install-attempt-\(identifier).jsonl", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let log = InstallAttemptLog(attemptID: identifier, url: url, productID: productID, targetPath: targetPath)
        try log.write(event: "started", phase: "resolving")
        return log
    }

    func progress(_ event: ProductDownloadProgressEvent) {
        try? write(
            event: event.event,
            phase: event.phase,
            bytesWritten: event.bytesWritten,
            totalBytesExpected: event.totalBytesExpected
        )
    }

    func output(_ line: String, stream: String) {
        let sanitized = Self.redact(line)
        guard !sanitized.isEmpty else { return }
        try? write(event: "output", stream: stream, message: sanitized)
    }

    func terminal(status: Int32, cancelled: Bool, summary: String) {
        guard !terminalWritten else { return }
        terminalWritten = true
        let event = cancelled ? "cancelled" : (status == 0 ? "succeeded" : "failed")
        try? write(event: event, message: Self.redact(summary), exitCode: status)
    }

    private func write(
        event: String,
        phase: String? = nil,
        stream: String? = nil,
        message: String? = nil,
        bytesWritten: Int64? = nil,
        totalBytesExpected: Int64? = nil,
        exitCode: Int32? = nil
    ) throws {
        let record = Record(
            timestamp: formatter.string(from: Date()),
            attemptID: attemptID,
            productID: productID.rawValue,
            targetPath: targetPath,
            event: event,
            phase: phase,
            stream: stream,
            message: message,
            bytesWritten: bytesWritten,
            totalBytesExpected: totalBytesExpected,
            exitCode: exitCode
        )
        let data = try encoder.encode(record) + Data([0x0A])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Retain actionable server/path errors while excluding credentials and URL
    /// query strings. A whole sensitive assignment is replaced rather than
    /// attempting to preserve an arbitrary value fragment.
    static func redact(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = text.replacingOccurrences(
            of: #"(https?://[^\s\"'<>?#]+)\?[^\s\"'<>]*"#,
            with: "$1?<redacted-query>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)(token|cookie|authorization|session|secret|password|passphrase|private[ _-]?key|credential|api[ _-]?key|csrf|signature|jwt|access[ _-]?token)\s*[:=]\s*[^\s,;]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        if text.count > 4_096 {
            text = String(text.prefix(4_096)) + "…<truncated>"
        }
        return text
    }
}

#if TOOLBOX_INSTALL_ATTEMPT_LOG_SELF_TEST
@main
struct InstallAttemptLogSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identityv-install-attempt-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try InstallAttemptLog.start(root: root, productID: .mainland, targetPath: "/tmp/第五人格（国服）")
        log.output("url=https://example.test/download?token=secret token=private", stream: "stderr")
        log.progress(ProductDownloadProgressEvent.fixture(product: .mainland, phase: "runtime"))
        log.terminal(status: 1, cancelled: false, summary: "authorization=private failed")
        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              let text = try? String(contentsOf: log.url, encoding: .utf8),
              text.contains("<redacted-query>"), text.contains("token=<redacted>"),
              text.contains("authorization=<redacted>"), !text.contains("secret"),
              text.split(whereSeparator: \.isNewline).count == 4 else {
            throw SelfTestError.failed
        }
        print("安装尝试日志脱敏与权限自检通过。")
    }

    private enum SelfTestError: Error { case failed }
}

private extension ProductDownloadProgressEvent {
    static func fixture(product: GameProductID, phase: String) -> ProductDownloadProgressEvent {
        try! JSONDecoder().decode(
            ProductDownloadProgressEvent.self,
            from: Data("{\"schemaVersion\":1,\"event\":\"progress\",\"productId\":\"\(product.rawValue)\",\"phase\":\"\(phase)\",\"bytesWritten\":1,\"totalBytesExpected\":2}".utf8)
        )
    }
}
#endif
