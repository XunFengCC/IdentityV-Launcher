import Darwin
import Foundation

private let maximumLogBytes = 1_048_576
private let maximumInstallAttemptBytes = 262_144
private let maximumMetadataBytes = 262_144
private let maximumDescriptionBytes = 16_384

private enum ExportError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct Options {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var metadataRoot = Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    var output: URL?
    var descriptionFile: URL?
    var preview = false
    var selfTest = false
}

private struct OpenedRegularFile {
    let descriptor: Int32
    let size: Int64
    let modifiedAt: Date
}

private final class Redactor {
    private let home: String
    // Mappings live only for this export: repeated identifiers remain useful
    // for diagnosis, without creating a stable cross-report user identifier.
    private var aliases: [String: [String: String]] = [:]
    private(set) var counts: [String: Int] = [:]
    private let userRoot = try! NSRegularExpression(pattern: #"/Users/[^/\r\n]+"#)
    private let volumeRoot = try! NSRegularExpression(pattern: #"/Volumes/[^/\r\n]+"#)

    init(home: URL) {
        self.home = home.standardizedFileURL.path
    }

    private func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private func replace(_ pattern: String, in text: String, transform: (String, NSTextCheckingResult) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(text, match))
        }
        return result
    }

    private func alias(_ category: String, _ value: String) -> String {
        counts[category, default: 0] += 1
        if let existing = aliases[category]?[value] { return existing }
        let result = "<\(category)_\((aliases[category]?.count ?? 0) + 1)>"
        aliases[category, default: [:]][value] = result
        return result
    }

    private func identifiers(_ raw: String) -> String {
        var text = raw
        let value = #"(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}\]]+)"#
        let categories = [
            ("ACCOUNT", #"(?:account(?:[_-]?id)?|user[_-]?id|uid|player[_-]?id|role[_-]?id)"#),
            ("DEVICE", #"(?:device[_-]?id|serial(?:[_-]?number)?|mac[_-]?address)"#),
            ("PHONE", #"(?:phone(?:[_-]?number)?|mobile)"#)
        ]
        for (category, key) in categories {
            text = replace("(\\b\(key)[\\\"']?\\s*[:=]\\s*)(\(value))", in: text) { original, match in
                let source = original as NSString
                return source.substring(with: match.range(at: 1)) + self.alias(category, source.substring(with: match.range(at: 2)))
            }
        }
        text = replace(#"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}"#, in: text) { original, match in
            self.alias("EMAIL", (original as NSString).substring(with: match.range))
        }
        text = replace(#"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])"#, in: text) { original, match in
            let candidate = (original as NSString).substring(with: match.range)
            var address = in_addr()
            guard inet_pton(AF_INET, candidate, &address) == 1 else { return candidate }
            // Four-part software versions use the same syntax as IPv4.
            let prefix = (original as NSString).substring(to: match.range.location)
            if prefix.range(of: #"(?:version|build)\s*[:=]\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return candidate }
            let kind = candidate.hasPrefix("127.") ? "IP_LOOPBACK" : "IPV4"
            return self.alias(kind, candidate)
        }
        text = replace(#"(?<![\w:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*(?:%[a-z0-9]+)?(?![\w:])"#, in: text) { original, match in
            let candidate = (original as NSString).substring(with: match.range)
            let addressPart = String(candidate.split(separator: "%")[0])
            var address = in6_addr()
            guard inet_pton(AF_INET6, addressPart, &address) == 1 else { return candidate }
            return self.alias("IPV6", candidate)
        }
        return text
    }

    func path(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: #"(https?://)[^/\s<>]+@"#, with: "$1<redacted-user>@", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"(https?://[^\s'\"<>?#]+)[?#][^\s'\"<>]*"#, with: "$1?<redacted-query>", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: home, with: "<HOME>")
        value = replacing(userRoot, in: value, with: "<HOME>")
        return identifiers(replacing(volumeRoot, in: value, with: "<VOLUME>"))
    }

    func log(_ text: String) -> (text: String, removed: Int) {
        var lines: [String] = []
        var removed = 0
        let blocks = text.replacingOccurrences(of: #"(?s)-----BEGIN [^-]*(?:PRIVATE KEY|CERTIFICATE)-----.*?(?:-----END [^-]+-----|$)"#, with: "<redacted secret block>", options: .regularExpression)
        for line in blocks.components(separatedBy: .newlines) {
            // Preserve error/phase context around a sensitive value; quoted
            // values and Authorization schemes must be consumed as a whole.
            // HTTP credential headers may contain several cookie values or
            // parameters separated by spaces/semicolons: consume the header
            // tail rather than leaking a second unlabelled credential.
            var safe = line.replacingOccurrences(of: #"(?i)(\b(?:cookie|set-cookie|authorization)\s*:\s*).*$"#, with: "$1<SECRET>", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"(?i)(\b(?:token|cookie|authorization|session(?:[_-]?id)?|secret|password|passphrase|private[_ -]?key|credential|api[_ -]?key|csrf|signature|jwt|access[_ -]?token)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\\r\n])*\"|'(?:\\.|[^'\\\r\n])*'|(?:Bearer|Basic)\s+[^\s,;]+|[^\s,;}\]]+)"#, with: "$1<SECRET>", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"(?i)\bBearer\s+[^\s,;]+|idvlogin://[^\s\"'<>]+|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,})"#, with: "<SECRET>", options: .regularExpression)
            safe = path(safe)
            if safe != line { removed += 1 }
            lines.append(safe)
        }
        return (lines.joined(separator: "\n"), removed)
    }

    func installLog(_ text: String) -> (text: String, removed: Int) {
        let allowed: Set<String> = ["schemaVersion", "timestamp", "attemptID", "productID", "targetPath", "event", "phase", "stream", "message", "bytesWritten", "totalBytesExpected", "exitCode"]
        var records: [String] = []
        var removed = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                // Truncated/unknown records are not copied as arbitrary text.
                removed += 1
                continue
            }
            var safe: [String: Any] = [:]
            for (key, value) in record where allowed.contains(key) {
                if let value = value as? String {
                    let scrubbed = log(value)
                    safe[key] = scrubbed.text
                    removed += scrubbed.removed
                } else if let value = value as? NSNumber { safe[key] = value }
            }
            removed += record.keys.filter { !allowed.contains($0) }.count
            if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes]) {
                records.append(String(decoding: data, as: UTF8.self))
            }
        }
        return (records.joined(separator: "\n") + "\n", removed)
    }
}

private func parseOptions() throws -> Options {
    var options = Options()
    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        switch argument {
        case "--home", "--metadata-root", "--output", "--description-file":
            index += 1
            guard index < CommandLine.arguments.count else {
                throw ExportError.message("\(argument) 缺少路径。")
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[index], isDirectory: argument != "--output")
            if argument == "--home" { options.home = url }
            if argument == "--metadata-root" { options.metadataRoot = url }
            if argument == "--output" { options.output = url }
            if argument == "--description-file" { options.descriptionFile = url }
        case "--preview": options.preview = true
        case "--self-test": options.selfTest = true
        case "--help":
            print("用法：IdentityVDiagnosticExporter [--output bundle.zip] [--description-file private.txt] [--preview]")
            exit(0)
        default: throw ExportError.message("未知参数：\(argument)")
        }
        index += 1
    }
    return options
}

private func openRegularFile(_ url: URL) throws -> OpenedRegularFile {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw ExportError.message("无法安全读取 \(url.lastPathComponent)。")
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG else {
        Darwin.close(descriptor)
        throw ExportError.message("拒绝非普通文件：\(url.lastPathComponent)")
    }
    return OpenedRegularFile(
        descriptor: descriptor,
        size: Int64(metadata.st_size),
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
    )
}

private func read(_ file: OpenedRegularFile, offset: Int64, count: Int) throws -> Data {
    guard count >= 0 else { throw ExportError.message("读取长度无效。") }
    var data = Data(count: count)
    let result = data.withUnsafeMutableBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return pread(file.descriptor, base, count, off_t(offset))
    }
    guard result >= 0 else { throw ExportError.message("读取诊断来源失败。") }
    data.count = result
    return data
}

private func readBounded(_ url: URL, limit: Int, head: Int = 8_192) throws -> (Data, Date, Int64) {
    let file = try openRegularFile(url)
    defer { Darwin.close(file.descriptor) }
    if file.size <= Int64(limit) {
        return (try read(file, offset: 0, count: Int(file.size)), file.modifiedAt, file.size)
    }
    let headBytes = min(head, limit)
    let tailBytes = max(0, limit - headBytes)
    var data = try read(file, offset: 0, count: headBytes)
    data.append(Data("\n<...truncated...>\n".utf8))
    data.append(try read(file, offset: file.size - Int64(tailBytes), count: tailBytes))
    return (data, file.modifiedAt, file.size)
}

private func regularFileMetadata(_ url: URL) -> (modifiedAt: Date, size: Int64)? {
    guard let file = try? openRegularFile(url) else { return nil }
    Darwin.close(file.descriptor)
    return (file.modifiedAt, file.size)
}

private func realDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
}

private func jsonObject(_ url: URL) -> Any? {
    guard let bytes = try? readBounded(url, limit: maximumMetadataBytes).0 else { return nil }
    return try? JSONSerialization.jsonObject(with: bytes)
}

private func componentSummary(_ url: URL, redactor: Redactor) -> [String: Any] {
    guard let object = jsonObject(url) as? [String: Any] else {
        return ["status": "not-present-or-invalid"]
    }
    let allowed = ["component", "version", "releaseTag", "assetName", "sha256", "license", "redistributionStatus"]
    var summary: [String: Any] = [:]
    for key in allowed {
        if let value = object[key] as? String { summary[key] = redactor.log(value).text }
        if let value = object[key] as? NSNumber { summary[key] = value }
    }
    return summary
}

private func installationSummary(_ url: URL, redactor: Redactor) -> [String: Any] {
    guard let object = jsonObject(url) as? [String: Any] else {
        return ["status": "not-present-or-invalid"]
    }
    var summary: [String: Any] = [:]
    if let schema = object["schemaVersion"] as? NSNumber { summary["schemaVersion"] = schema }
    if let selected = object["selectedEngineId"] as? String { summary["selectedEngineId"] = redactor.log(selected).text }
    if let lastKnown = object["lastKnownGoodEngineId"] as? String { summary["lastKnownGoodEngineId"] = redactor.log(lastKnown).text }
    if let engines = object["engines"] as? [String: Any] {
        summary["engineCount"] = engines.count
        summary["engineIds"] = engines.keys.sorted().prefix(20).map { redactor.log($0).text }
    }
    return summary.isEmpty ? ["status": "present-without-public-fields"] : summary
}

private func machineName() -> String {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}

private func isoDate(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func makeBundle(stage: URL, home: URL, metadataRoot: URL, descriptionFile: URL?) throws -> [String: Any] {
    let fileManager = FileManager.default
    let redactor = Redactor(home: home)
    let logsRoot = home.appendingPathComponent("Library/Logs/IdentityVOnMac", isDirectory: true)
    let stateRoot = home.appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
    let installAttemptsRoot = stateRoot.appendingPathComponent("Diagnostics/InstallAttempts", isDirectory: true)
    let logs = (realDirectory(logsRoot)
        ? ((try? fileManager.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil)) ?? [])
        : [])
        // This directory can also contain manual captures and unrelated files.
        // Only the product runner's known log names belong in a public report.
        .filter { $0.lastPathComponent.range(of: #"^identityv-(mac-dxmt|app-dispatch|agtkwine-dxmt)-[0-9]{8}-[0-9]{6}\.log$"#, options: .regularExpression) != nil }
        .compactMap { url -> (URL, Date, Int64)? in
            guard let metadata = regularFileMetadata(url) else { return nil }
            return (url, metadata.modifiedAt, metadata.size)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
    let installAttempts = (realDirectory(installAttemptsRoot)
        ? ((try? fileManager.contentsOfDirectory(at: installAttemptsRoot, includingPropertiesForKeys: nil)) ?? [])
        : [])
        .filter { $0.lastPathComponent.range(of: #"^install-attempt-[a-fA-F0-9-]{36}\.jsonl$"#, options: .regularExpression) != nil }
        .compactMap { url -> (URL, Date, Int64)? in
            guard let metadata = regularFileMetadata(url) else { return nil }
            return (url, metadata.modifiedAt, metadata.size)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)

    let os = ProcessInfo.processInfo.operatingSystemVersion
    let installedLoginMetadata = URL(fileURLWithPath: "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/component.json")
    let bundledLoginMetadata = metadataRoot.appendingPathComponent("idvLoginComponent.json")
    let loginMetadata = regularFileMetadata(installedLoginMetadata) == nil ? bundledLoginMetadata : installedLoginMetadata
    let stateSummary: [String: Any]
    if realDirectory(stateRoot) {
        stateSummary = installationSummary(stateRoot.appendingPathComponent("installation.json"), redactor: redactor)
    } else {
        stateSummary = ["status": "rejected-non-regular-directory"]
    }
    let systemSummary: [String: Any] = [
        "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        "machine": machineName(),
        "cpuCount": ProcessInfo.processInfo.processorCount
    ]
    let componentSummaries: [String: Any] = [
        "idvLogin": componentSummary(loginMetadata, redactor: redactor),
        "neteaseDownloadCore": componentSummary(
            metadataRoot.appendingPathComponent("downloaderCoreComponent.json"),
            redactor: redactor
        )
    ]
    let infoURL = metadataRoot.deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = (try? Data(contentsOf: infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    let report: [String: Any] = [
        "schemaVersion": 2,
        "reportId": UUID().uuidString.lowercased(),
        "createdAt": isoDate(),
        "privacy": ["networkUpload": false, "screenshots": false, "audio": false, "accountConfiguration": false],
        "launcherVersion": redactor.log(info["IdentityVReleaseVersion"] as? String ?? "unknown").text,
        "system": systemSummary,
        "components": componentSummaries,
        "state": stateSummary
    ]
    try writeJSON(report, to: stage.appendingPathComponent("report.json"))

    var publicDescription = ""
    if let descriptionFile {
        let descriptionSource = try readBounded(descriptionFile, limit: maximumDescriptionBytes, head: maximumDescriptionBytes)
        guard descriptionSource.2 <= maximumDescriptionBytes else {
            throw ExportError.message("问题描述过长，请缩短到16 KB以内后重试。")
        }
        // User-authored reproduction details are deliberately preserved. The
        // user reviews them before sharing; automated collection is scrubbed
        // separately so intentional account/context information is not lost.
        let description = String(decoding: descriptionSource.0, as: UTF8.self)
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportError.message("问题描述为空；未生成反馈包。")
        }
        publicDescription = description
        let destination = stage.appendingPathComponent("user-description.txt")
        try Data(description.utf8).write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    let logStage = stage.appendingPathComponent("logs", isDirectory: true)
    try fileManager.createDirectory(at: logStage, withIntermediateDirectories: false)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logStage.path)
    var timeline: [[String: Any]] = []
    var redactions: [String: Int] = [:]
    for (index, source) in logs.enumerated() {
        let bytes = try readBounded(source.0, limit: maximumLogBytes).0
        let scrubbed = redactor.log(String(decoding: bytes, as: UTF8.self))
        let filename = "launch-\(index + 1).log"
        let destination = logStage.appendingPathComponent(filename)
        try Data(scrubbed.text.utf8).write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        redactions[filename] = scrubbed.removed
        timeline.append([
            "kind": "launch",
            "slot": index + 1,
            "modifiedAt": isoDate(source.1),
            "sourceBytes": source.2
        ])
    }
    let installStage = stage.appendingPathComponent("install-attempts", isDirectory: true)
    try fileManager.createDirectory(at: installStage, withIntermediateDirectories: false)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installStage.path)
    for (index, source) in installAttempts.enumerated() {
        let bytes = try readBounded(source.0, limit: maximumInstallAttemptBytes).0
        let scrubbed = redactor.installLog(String(decoding: bytes, as: UTF8.self))
        let filename = "install-attempt-\(index + 1).jsonl"
        let destination = installStage.appendingPathComponent(filename)
        try Data(scrubbed.text.utf8).write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        redactions["install-attempts/\(filename)"] = scrubbed.removed
        timeline.append([
            "kind": "install-attempt",
            "slot": index + 1,
            "modifiedAt": isoDate(source.1),
            "sourceBytes": source.2
        ])
    }
    try writeJSON([
        "schemaVersion": 1,
        "recentEvents": timeline,
        "launchLogCount": logs.count,
        "installAttemptCount": installAttempts.count
    ], to: stage.appendingPathComponent("timeline.json"))
    try writeJSON(["schemaVersion": 2, "ruleVersion": 2, "changedOrDroppedRecords": redactions, "identifierReplacements": redactor.counts], to: stage.appendingPathComponent("redaction.json"))
    return [
        "reportId": report["reportId"]!,
        "description": publicDescription,
        "logs": logs.count,
        "installAttempts": installAttempts.count
    ]
}

private func archive(stage: URL, output: URL) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: output.path) else {
        throw ExportError.message("输出文件已经存在；拒绝覆盖。")
    }
    let parent = output.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", "--noextattr", stage.path, output.path]
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        try? fileManager.removeItem(at: output)
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ExportError.message(detail.isEmpty ? "系统压缩工具未能生成诊断包。" : detail)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}

private func export(options: Options) throws -> [String: Any] {
    let fileManager = FileManager.default
    let home = options.home.resolvingSymlinksInPath().standardizedFileURL
    let metadataRoot = options.metadataRoot.resolvingSymlinksInPath().standardizedFileURL
    guard (try? home.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
          (try? metadataRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw ExportError.message("HOME 或组件元数据目录无效；拒绝扫描。")
    }
    let stage = fileManager.temporaryDirectory.appendingPathComponent("identityv-diagnostic-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
    defer { try? fileManager.removeItem(at: stage) }
    var summary = try makeBundle(
        stage: stage,
        home: home,
        metadataRoot: metadataRoot,
        descriptionFile: options.descriptionFile?.standardizedFileURL
    )
    summary["files"] = ((try? fileManager.subpathsOfDirectory(atPath: stage.path)) ?? []).filter {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: stage.appendingPathComponent($0).path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }.sorted()
    summary["networkUpload"] = false
    if let output = options.output?.standardizedFileURL {
        try archive(stage: stage, output: output)
        summary["archive"] = output.path
        summary["bytes"] = (try fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
    } else {
        summary["archive"] = NSNull()
    }
    return summary
}

private func runSelfTest() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("identityv-diagnostic-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let logs = home.appendingPathComponent("Library/Logs/IdentityVOnMac", isDirectory: true)
    let state = home.appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
    let installAttempts = state.appendingPathComponent("Diagnostics/InstallAttempts", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: installAttempts, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
    let log = """
    version=1.2.3.4 phase=launch error=E5005 status=503 time=13:01:27
    token=do-not-export phase=download error=E42
    authorization: Bearer EXAMPLE-SECRET status=401
    Cookie: first=COOKIE-ONE; second=COOKIE-TWO
    https://example.test/a?sig=private
    path=\(home.path)/secret
    volume=/Volumes/My Game Disk/IdentityV/game
    email=tester@example.invalid peer=203.0.113.42:443 account=EXAMPLE-PLAYER-123
    retry email=tester@example.invalid account=EXAMPLE-PLAYER-123
    ipv6=[2001:db8::42]:443 phone="138 0000 0000" device_id=EXAMPLE-DEVICE
    password="secret with spaces" phase=login
    -----BEGIN PRIVATE KEY-----
    EXAMPLE-PRIVATE-BODY
    -----END PRIVATE KEY-----
    session started; normal error explanation
    """
    try Data(log.utf8).write(to: logs.appendingPathComponent("identityv-mac-dxmt-20000101-000000.log"))
    try Data("UNKNOWN-SOURCE-PRIVATE".utf8).write(to: logs.appendingPathComponent("unknown.log"))
    try Data("{\"event\":\"failed\",\"targetPath\":\"\(home.path)/Library/Application Support/第五人格/CN\",\"message\":\"https://example.test/game?opaque=private account=EXAMPLE-PLAYER-123 email=tester@example.invalid status=503\",\"unknown\":\"not-for-export\"}\nauthorization=private\n".utf8)
        .write(to: installAttempts.appendingPathComponent("install-attempt-00000000-0000-0000-0000-000000000000.jsonl"))
    try fileManager.createSymbolicLink(
        at: logs.appendingPathComponent("identityv-mac-dxmt-20000101-000001.log"),
        withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
    )
    try Data(#"{"schemaVersion":1,"selectedEngineId":"safe-engine","engines":{"safe-engine":{"gameRoot":"private"}},"session":"do-not-export"}"#.utf8)
        .write(to: state.appendingPathComponent("installation.json"))
    try Data(#"{"component":"download-core","version":"1","sha256":"abc"}"#.utf8)
        .write(to: metadata.appendingPathComponent("downloaderCoreComponent.json"))
    let output = root.appendingPathComponent("bundle.zip")
    let description = root.appendingPathComponent("description.txt")
    try Data("窗口切换后出现卡顿，路径：\(home.path)；token=do-not-export\n".utf8).write(to: description)
    let summary = try export(options: Options(home: home, metadataRoot: metadata, output: output, descriptionFile: description, preview: false, selfTest: false))
    guard summary["networkUpload"] as? Bool == false,
          summary["logs"] as? Int == 1,
          summary["installAttempts"] as? Int == 1,
          regularFileMetadata(output) != nil else {
        throw ExportError.message("诊断包自检未生成受限压缩包。")
    }
    let inspect = root.appendingPathComponent("inspect", isDirectory: true)
    try fileManager.createDirectory(at: inspect, withIntermediateDirectories: false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", output.path, inspect.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0,
          let scrubbed = try? String(contentsOf: inspect.appendingPathComponent("logs/launch-1.log"), encoding: .utf8),
          !scrubbed.contains("do-not-export"), !scrubbed.contains(home.path),
          !scrubbed.contains("My Game Disk"), !scrubbed.contains("sig=private"),
          scrubbed.contains("<HOME>"), scrubbed.contains("<VOLUME>") else {
        throw ExportError.message("诊断包脱敏自检失败。")
    }
    let privateValues = ["tester@example.invalid", "203.0.113.42", "2001:db8::42", "EXAMPLE-PLAYER-123", "EXAMPLE-DEVICE", "138 0000 0000", "secret with spaces", "EXAMPLE-SECRET", "EXAMPLE-PRIVATE-BODY", "UNKNOWN-SOURCE-PRIVATE", "COOKIE-ONE", "COOKIE-TWO"]
    guard privateValues.allSatisfy({ !scrubbed.contains($0) }),
          scrubbed.contains("<EMAIL_1>"), scrubbed.contains("<ACCOUNT_1>"),
          scrubbed.components(separatedBy: "<EMAIL_1>").count == 3,
          scrubbed.contains("version=1.2.3.4 phase=launch error=E5005 status=503 time=13:01:27"),
          scrubbed.contains("phase=download error=E42"),
          scrubbed.contains("session started; normal error explanation"),
          scrubbed.contains("example.test/a"), scrubbed.contains(":443") else {
        throw ExportError.message("公开日志的标识脱敏或诊断上下文保留失败。")
    }
    let scrubbedAttempt = try String(
        contentsOf: inspect.appendingPathComponent("install-attempts/install-attempt-1.jsonl"),
        encoding: .utf8
    )
    guard !scrubbedAttempt.contains("opaque=private"),
          !scrubbedAttempt.contains("authorization=private"),
          !scrubbedAttempt.contains(home.path),
          scrubbedAttempt.contains("<HOME>"),
          scrubbedAttempt.contains("<redacted-query>") else {
        throw ExportError.message("安装尝试日志二次脱敏自检失败。")
    }
    guard privateValues.allSatisfy({ !scrubbedAttempt.contains($0) }),
          !scrubbedAttempt.contains("not-for-export"),
          scrubbedAttempt.contains("<ACCOUNT_1>"), scrubbedAttempt.contains("<EMAIL_1>"),
          scrubbedAttempt.contains("status=503"),
          let attempt = try? JSONSerialization.jsonObject(with: Data(scrubbedAttempt.utf8)) as? [String: Any],
          attempt["event"] as? String == "failed", attempt["unknown"] == nil else {
        throw ExportError.message("结构化安装日志必须保留有效JSON与错误上下文，并过滤未知字段。")
    }
    let scrubbedDescription = try String(contentsOf: inspect.appendingPathComponent("user-description.txt"), encoding: .utf8)
    guard scrubbedDescription == "窗口切换后出现卡顿，路径：\(home.path)；token=do-not-export\n" else {
        throw ExportError.message("用户手写描述必须原文保留，不能被日志过滤器改写。")
    }
    print("原生诊断包有界读取、脱敏和压缩自检通过。")
}

@main
private struct IdentityVDiagnosticExporter {
    static func main() {
        do {
            let options = try parseOptions()
            if options.selfTest {
                try runSelfTest()
                return
            }
            let summary = try export(options: options)
            let output = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: output, as: UTF8.self))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
