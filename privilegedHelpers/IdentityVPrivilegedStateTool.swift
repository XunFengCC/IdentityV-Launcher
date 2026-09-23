import Darwin
import CryptoKit
import Foundation
import Security

private let helperRoot = "/Library/PrivilegedHelperTools/identityv-on-mac"
private let gameBridge = helperRoot + "/launch-game-as-console-user"
// `/etc` is a compatibility symlink to `/private/etc` on macOS.  Atomic writes
// deliberately reject symlinked parent directories, so use the canonical
// system path for the one fixed Hosts target instead of weakening that guard.
private let systemHostsPath = "/private/etc/hosts"
private let managedDomains = [
    "service.mkey.163.com",
    "sdk-os.mpsdk.easebar.com",
    "mgbsdk.matrix.netease.com"
]
private let hostsTag = "identityv-on-mac-compat"
private let longMainlandGameID = "aecfrt3rmaaaaajl-g-h55"
private let maximumStateBytes = 8 * 1_024 * 1_024
private let idvLoginSystemCAStatePath = "/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json"
private let systemKeychainPath = "/Library/Keychains/System.keychain"
private let idvLoginCAPEMRelativePaths = [
    "Library/Application Support/idv-login/root_ca_oversea_0213.pem",
    "Library/Application Support/idv-login/mitmproxy-conf/mitmproxy-ca-cert.pem"
]

private enum StateError: LocalizedError {
    case message(String)
    case authorizationPending
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .authorizationPending: return "IDV_LOGIN_AUTHORIZATION=waiting"
        }
    }
}

private struct FileMetadata {
    let uid: uid_t
    let gid: gid_t
    let mode: mode_t
}

private func lstatMetadata(_ path: String) -> stat? {
    var value = stat()
    return lstat(path, &value) == 0 ? value : nil
}

private func realDirectory(_ path: String) -> Bool {
    guard let value = lstatMetadata(path) else { return false }
    return (value.st_mode & S_IFMT) == S_IFDIR
}

private func readRegular(_ path: String) throws -> (Data, FileMetadata) {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw StateError.message("拒绝读取非普通状态文件。") }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
          (value.st_mode & S_IFMT) == S_IFREG,
          value.st_size >= 0,
          value.st_size <= maximumStateBytes else {
        throw StateError.message("状态文件类型或大小无效。")
    }
    var data = Data(count: Int(value.st_size))
    var offset = 0
    while offset < data.count {
        let remaining = data.count - offset
        let count = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.read(descriptor, base.advanced(by: offset), remaining)
        }
        guard count >= 0 else { throw StateError.message("读取状态文件失败。") }
        if count == 0 { break }
        offset += count
    }
    data.count = offset
    return (data, FileMetadata(uid: value.st_uid, gid: value.st_gid, mode: value.st_mode & 0o777))
}

private func writeAll(_ descriptor: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
        }
        guard count > 0 else { throw StateError.message("写入状态文件失败。") }
        offset += count
    }
}

private func atomicWrite(_ data: Data, to path: String, metadata: FileMetadata) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard realDirectory(parent) else { throw StateError.message("状态目录无效。") }
    let temporary = parent + "/.identityv-state-" + UUID().uuidString
    let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw StateError.message("无法建立原子状态暂存文件。") }
    var keep = false
    defer {
        Darwin.close(descriptor)
        if !keep { Darwin.unlink(temporary) }
    }
    try writeAll(descriptor, data: data)
    guard fchmod(descriptor, metadata.mode) == 0,
          fchown(descriptor, metadata.uid, metadata.gid) == 0,
          fsync(descriptor) == 0 else {
        throw StateError.message("无法保留状态文件权限。")
    }
    guard rename(temporary, path) == 0 else { throw StateError.message("无法原子发布状态文件。") }
    keep = true
}

private func rewrittenValue(_ value: Any, replacements: Set<String>) -> Any {
    if let string = value as? String, replacements.contains(string) { return gameBridge }
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues { rewrittenValue($0, replacements: replacements) }
    }
    if let array = value as? [Any] {
        return array.map { rewrittenValue($0, replacements: replacements) }
    }
    return value
}

/// IDV Login has modern `installation_state_v1` and older `installations`
/// representations, both of which can hold a per-installation
/// `settings.auto_start` flag.
private func disablingInstallationAutoStart(_ value: Any?) -> Any? {
    guard let value else { return nil }
    if var installations = value as? [String: Any] {
        for key in installations.keys {
            guard var installation = installations[key] as? [String: Any] else { continue }
            var settings = installation["settings"] as? [String: Any] ?? [:]
            settings["auto_start"] = false
            installation["settings"] = settings
            installations[key] = installation
        }
        return installations
    }
    if var installations = value as? [Any] {
        for index in installations.indices {
            guard var installation = installations[index] as? [String: Any] else { continue }
            var settings = installation["settings"] as? [String: Any] ?? [:]
            settings["auto_start"] = false
            installation["settings"] = settings
            installations[index] = installation
        }
        return installations
    }
    return value
}

private func disableGameAutoStart(_ game: inout [String: Any]) {
    game["should_auto_start"] = false
    if var installationState = game["installation_state_v1"] as? [String: Any] {
        installationState["installations"] = disablingInstallationAutoStart(installationState["installations"])
        game["installation_state_v1"] = installationState
    }
    game["installations"] = disablingInstallationAutoStart(game["installations"])
}

/// This launcher owns all game starts. Upstream's plain startup otherwise
/// enumerates every game with auto-start, so set only those booleans to false
/// across both caches while preserving all account, channel, path and other
/// installation data verbatim.
private func disableAllGameAutoStart(in object: inout [String: Any]) {
    if var games = object["game_settings"] as? [String: Any] {
        for key in games.keys {
            guard var game = games[key] as? [String: Any] else { continue }
            disableGameAutoStart(&game)
            games[key] = game
        }
        object["game_settings"] = games
    }
    if var states = object["game_installation_settings_v1"] as? [String: Any] {
        for key in states.keys {
            guard var state = states[key] as? [String: Any] else { continue }
            state["installations"] = disablingInstallationAutoStart(state["installations"])
            states[key] = state
        }
        object["game_installation_settings_v1"] = states
    }
}

private func prepareConfig(home: String, staffGID: gid_t, enforceUserRoot: Bool = true) throws {
    let canonicalHome = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
    guard (!enforceUserRoot || canonicalHome.hasPrefix("/Users/")), realDirectory(canonicalHome) else {
        throw StateError.message("桌面用户主目录无效。")
    }
    let stateDirectory = canonicalHome + "/Library/Application Support/idv-login"
    guard realDirectory(stateDirectory) else { throw StateError.message("IDV Login 状态目录无效。") }
    let configPath = stateDirectory + "/config.json"
    let existing = lstatMetadata(configPath)
    var object: [String: Any]
    let metadata: FileMetadata
    if existing != nil {
        let read = try readRegular(configPath)
        guard let parsed = try JSONSerialization.jsonObject(with: read.0) as? [String: Any] else {
            throw StateError.message("IDV Login config 不是 JSON object；未改动。")
        }
        object = parsed
        metadata = read.1
    } else {
        object = [:]
        metadata = FileMetadata(uid: 0, gid: staffGID, mode: 0o600)
    }

    let oldLaunchers: Set<String> = [
        "/Applications/第五人格.app/Contents/MacOS/IdentityVLauncher",
        "/Applications/第五人格 AGTK.app/Contents/MacOS/launchIdentityV",
        "/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV"
    ]
    object = rewrittenValue(object, replacements: oldLaunchers) as! [String: Any]
    object["proxy_mode"] = "compat"

    var games = object["game_settings"] as? [String: Any] ?? [:]
    let key = games.keys.first(where: { $0 == "h55" || $0.hasSuffix("-h55") }) ?? longMainlandGameID
    var game = games[key] as? [String: Any] ?? [:]
    game["game_id"] = key
    if (game["name"] as? String)?.isEmpty != false { game["name"] = "第五人格" }
    game["path"] = gameBridge
    // Keep the project-owned bridge in the mainland record.  Global
    // auto-start normalization below makes the whole IDV Login service-only.
    if game["auto_close_after_login"] == nil { game["auto_close_after_login"] = false }
    if game["login_delay"] == nil { game["login_delay"] = 6 }
    game["last_used_time"] = Int(Date().timeIntervalSince1970)
    game["default_distribution"] = 73
    if game["version"] == nil { game["version"] = "" }
    games[key] = game
    object["game_settings"] = games
    disableAllGameAutoStart(in: &object)

    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    try atomicWrite(data, to: configPath, metadata: metadata)
}

private func canonicalHostLine(_ domain: String) -> String {
    "127.0.0.1 \(domain) # \(hostsTag)"
}

private func hostFields(_ line: String) -> [Substring] {
    let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    return content.split(whereSeparator: { $0 == " " || $0 == "\t" })
}

// IDV Login's own Hosts backend rewrites our tagged line as an otherwise
// identical two-field line without a comment.  Treat only those two exact
// representations as managed; any other IP, alias, duplicate or comment is
// still outside this helper's authority.
private func acceptedManagedHostDomain(_ line: String) -> String? {
    let pieces = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let fields = hostFields(line)
    guard fields.count == 2,
          fields[0] == "127.0.0.1",
          managedDomains.contains(String(fields[1])) else { return nil }
    if pieces.count == 1 { return String(fields[1]) }
    let comment = pieces[1].trimmingCharacters(in: .whitespaces)
    return comment == hostsTag ? String(fields[1]) : nil
}

private func updateHosts(path: String, ensure: Bool) throws {
    let read = try readRegular(path)
    guard let text = String(data: read.0, encoding: .utf8) else {
        throw StateError.message("Hosts 不是 UTF-8 文本；未改动。")
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    if ensure {
        var acceptedCounts: [String: Int] = [:]
        for line in lines {
            let fields = hostFields(line)
            let managedAliases = fields.dropFirst().filter { field in
                managedDomains.contains(String(field))
            }
            guard !managedAliases.isEmpty else { continue }
            guard managedAliases.count == 1,
                  let domain = acceptedManagedHostDomain(line) else {
                throw StateError.message("发现未由本项目标记的 Identity V Hosts 映射；未改动。")
            }
            acceptedCounts[domain, default: 0] += 1
            guard acceptedCounts[domain] == 1 else {
                throw StateError.message("发现重复的 Identity V Hosts 映射；未改动。")
            }
        }
        for domain in managedDomains where acceptedCounts[domain] == nil {
            lines.append(canonicalHostLine(domain))
        }
    } else {
        lines.removeAll { acceptedManagedHostDomain($0) != nil }
    }
    let output = Data((lines.joined(separator: "\n") + "\n").utf8)
    if output != read.0 { try atomicWrite(output, to: path, metadata: read.1) }
}

private func withStateLock<T>(_ operation: () throws -> T) throws -> T {
    let descriptor = Darwin.open("/var/run/identityv-on-mac-state.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw StateError.message("无法打开 helper 状态锁。") }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw StateError.message("无法取得 helper 状态锁。") }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
}

// MARK: - IDV Login System CA ownership
//
// IDV Login itself creates this CA at first run.  The project never identifies
// it by its display name: upstream has generated multiple certificates with
// the same name in the wild.  We record the exact DER and both digests only
// after proving that the fixed, user-scoped PEM is the very same CA currently
// present in System.keychain.  The public DER is retained solely as an
// uninstall verification witness; it contains no private key or login data.

private struct SystemCARecord: Codable, Equatable {
    let sha1: String
    let sha256: String
    let subject: String
    let issuer: String
    let isCertificateAuthority: Bool
    let derBase64: String
}

private struct SystemCAManifest: Codable, Equatable {
    let schemaVersion: Int
    let owner: String
    var records: [SystemCARecord]
}

private struct CertificateInfo: Equatable {
    let der: Data
    let sha1: String
    let sha256: String
    let subject: String
    let issuer: String
    let isCertificateAuthority: Bool
}

private func lowercaseHex<D: Digest>(_ digest: D) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func runCommand(_ executable: String, arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    let stdin: Pipe?
    if input != nil {
        let pipe = Pipe()
        process.standardInput = pipe
        stdin = pipe
    } else {
        stdin = nil
    }
    try process.run()
    // Drain both pipes while the child is alive.  Waiting first can deadlock if
    // a diagnostic emits more than a pipe buffer; this matters even though the
    // certificate commands normally produce only a few KiB.
    let group = DispatchGroup()
    var output = Data()
    var error = Data()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        error = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    if let input, let stdin {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            group.leave()
        }
    }
    process.waitUntilExit()
    group.wait()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if executable == "/usr/bin/security", arguments.first == "add-trusted-cert",
           isWithdrawnAuthorization(detail) {
            throw StateError.authorizationPending
        }
        throw StateError.message(detail.isEmpty ? "系统证书工具执行失败。" : "系统证书工具执行失败：\(detail)")
    }
    return output
}

private func isWithdrawnAuthorization(_ detail: String) -> Bool {
    let localized = SecCopyErrorMessageString(errAuthorizationCanceled, nil) as String?
    return detail.contains(String(errAuthorizationCanceled))
        || (localized.map { !$0.isEmpty && detail.contains($0) } ?? false)
        || detail.localizedCaseInsensitiveContains("authorization was canceled")
        || detail.localizedCaseInsensitiveContains("authorization was cancelled")
}

private func certificateInfo(fromPEM pem: Data) throws -> CertificateInfo {
    guard pem.count > 0, pem.count <= maximumStateBytes else {
        throw StateError.message("证书 PEM 大小无效。")
    }
    let der = try runCommand("/usr/bin/openssl", arguments: ["x509", "-inform", "PEM", "-outform", "DER"], input: pem)
    return try certificateInfo(fromDER: der)
}

private func certificateInfo(fromDER der: Data) throws -> CertificateInfo {
    guard der.count > 0, der.count <= maximumStateBytes else {
        throw StateError.message("证书 DER 大小无效。")
    }
    let descriptionData = try runCommand(
        "/usr/bin/openssl",
        // macOS ships LibreSSL 3.3.6.  Its `x509` command does not implement
        // OpenSSL's newer `-ext basicConstraints` option, but `-text` is stable
        // across both implementations and includes the same CA:TRUE marker.
        arguments: ["x509", "-inform", "DER", "-noout", "-subject", "-issuer", "-text"],
        input: der
    )
    let description = String(decoding: descriptionData, as: UTF8.self)
    guard let subjectLine = description.split(separator: "\n").first(where: { $0.hasPrefix("subject=") }),
          let issuerLine = description.split(separator: "\n").first(where: { $0.hasPrefix("issuer=") }) else {
        throw StateError.message("无法读取证书 subject/issuer。")
    }
    let subject = String(subjectLine.dropFirst("subject=".count)).trimmingCharacters(in: .whitespaces)
    let issuer = String(issuerLine.dropFirst("issuer=".count)).trimmingCharacters(in: .whitespaces)
    return CertificateInfo(
        der: der,
        sha1: lowercaseHex(Insecure.SHA1.hash(data: der)),
        sha256: lowercaseHex(SHA256.hash(data: der)),
        subject: subject,
        issuer: issuer,
        isCertificateAuthority: description.range(of: "CA:TRUE", options: .caseInsensitive) != nil
    )
}

private func isExpectedIDVLoginCA(_ certificate: CertificateInfo) -> Bool {
    certificate.isCertificateAuthority &&
        certificate.subject == certificate.issuer &&
        certificate.subject.contains("Netease Login Helper CA") &&
        certificate.issuer.contains("Netease Login Helper CA")
}

private func readSafeIDVLoginCAPEM(home: String) throws -> Data {
    let canonicalHome = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
    guard canonicalHome.hasPrefix("/Users/"), let homeMetadata = lstatMetadata(canonicalHome),
          (homeMetadata.st_mode & S_IFMT) == S_IFDIR, homeMetadata.st_uid >= 500 else {
        throw StateError.message("桌面用户主目录无效。")
    }
    var selected: (data: Data, info: CertificateInfo)?
    for relativePath in idvLoginCAPEMRelativePaths {
        let candidate = canonicalHome + "/" + relativePath
        guard let metadata = lstatMetadata(candidate) else { continue }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == 0 || metadata.st_uid == homeMetadata.st_uid,
              (metadata.st_mode & 0o022) == 0 else {
            throw StateError.message("IDV Login CA 文件权限或所有者异常；未处理系统信任。")
        }
        let read = try readRegular(candidate)
        guard (read.1.uid == 0 || read.1.uid == homeMetadata.st_uid),
              (read.1.mode & 0o022) == 0 else {
            throw StateError.message("读取期间 IDV Login CA 权限改变；未处理系统信任。")
        }
        let data = read.0
        let info = try certificateInfo(fromPEM: data)
        guard isExpectedIDVLoginCA(info) else {
            throw StateError.message("IDV Login CA 不符合预期的自签名 CA 特征；未处理系统信任。")
        }
        if let selected {
            guard selected.info.der == info.der else {
                throw StateError.message("发现多个不同的 IDV Login CA；未猜测处理对象。")
            }
        } else {
            selected = (data, info)
        }
    }
    guard let selected else { throw StateError.message("尚未发现 IDV Login 生成的 CA；未记录系统信任。") }
    return selected.data
}

private func pemCertificates(in output: Data) -> [Data] {
    let text = String(decoding: output, as: UTF8.self)
    let begin = "-----BEGIN CERTIFICATE-----"
    let end = "-----END CERTIFICATE-----"
    var certificates: [Data] = []
    var remainder = text[...]
    while let beginRange = remainder.range(of: begin), let endRange = remainder.range(of: end, range: beginRange.upperBound..<remainder.endIndex) {
        let certificate = String(remainder[beginRange.lowerBound..<endRange.upperBound]) + "\n"
        certificates.append(Data(certificate.utf8))
        remainder = remainder[endRange.upperBound...]
    }
    return certificates
}

private func systemKeychainCertificates() throws -> [CertificateInfo] {
    // `-c` is merely a bounded retrieval filter.  Exact DER and dual hashes
    // remain the only ownership/deletion selectors below.
    let output = try runCommand("/usr/bin/security", arguments: ["find-certificate", "-a", "-c", "Netease Login Helper CA", "-p", systemKeychainPath])
    return try pemCertificates(in: output).map(certificateInfo(fromPEM:))
}

private func manifestMetadata() -> FileMetadata {
    FileMetadata(uid: 0, gid: 0, mode: 0o600)
}

private func validatedRecord(_ value: SystemCARecord) throws -> SystemCARecord {
    guard value.sha1.count == 40, value.sha256.count == 64,
          let savedDER = Data(base64Encoded: value.derBase64) else {
        throw StateError.message("系统 CA 台账无效；拒绝猜测删除任何证书。")
    }
    let saved = try certificateInfo(fromDER: savedDER)
    guard saved.sha1 == value.sha1, saved.sha256 == value.sha256,
          saved.subject == value.subject, saved.issuer == value.issuer,
          saved.isCertificateAuthority == value.isCertificateAuthority,
          isExpectedIDVLoginCA(saved) else {
        throw StateError.message("系统 CA 台账与保存证书不一致；拒绝猜测删除任何证书。")
    }
    return value
}

private func loadCAManifest() throws -> SystemCAManifest? {
    guard lstatMetadata(idvLoginSystemCAStatePath) != nil else { return nil }
    let read = try readRegular(idvLoginSystemCAStatePath)
    let value = try JSONDecoder().decode(SystemCAManifest.self, from: read.0)
    guard read.1.uid == 0, read.1.gid == 0, read.1.mode == 0o600,
          value.schemaVersion == 1, value.owner == "IdentityVOnMac",
          !value.records.isEmpty, value.records.count <= 8 else {
        throw StateError.message("系统 CA 台账无效；拒绝猜测删除任何证书。")
    }
    _ = try value.records.map(validatedRecord(_:))
    return value
}

private enum CARemovalPlan: Equatable {
    case noRecordedOwnership
    case removeStaleRecord
    case deleteExactSHA1(String)
}

private func removalPlan(record: SystemCARecord?, currentUserPEM: CertificateInfo?, systemCertificates: [CertificateInfo]) throws -> CARemovalPlan {
    guard let record else { return .noRecordedOwnership }
    guard let current = currentUserPEM,
          current.sha1 == record.sha1, current.sha256 == record.sha256,
          current.subject == record.subject, current.issuer == record.issuer,
          current.isCertificateAuthority == record.isCertificateAuthority,
          current.der.base64EncodedString() == record.derBase64,
          isExpectedIDVLoginCA(current) else {
        throw StateError.message("当前 IDV Login CA 与项目台账不一致；拒绝删除系统证书。")
    }
    return systemCertificates.contains { $0.sha1 == record.sha1 && $0.der == current.der }
        ? .deleteExactSHA1(record.sha1)
        : .removeStaleRecord
}

private func recordSystemCA(home: String) throws {
    let pem = try readSafeIDVLoginCAPEM(home: home)
    let certificate = try certificateInfo(fromPEM: pem)
    try recordSystemCA(certificate: certificate)
}

private func recordSystemCA(certificate: CertificateInfo) throws {
    guard isExpectedIDVLoginCA(certificate) else { throw StateError.message("IDV Login CA 特征无效。") }
    let systemMatches = try systemKeychainCertificates().filter { $0.der == certificate.der }
    guard !systemMatches.isEmpty else {
        throw StateError.message("IDV Login CA 尚未存在于 System.keychain；未创建台账。")
    }
    let record = SystemCARecord(
        sha1: certificate.sha1,
        sha256: certificate.sha256,
        subject: certificate.subject,
        issuer: certificate.issuer,
        isCertificateAuthority: certificate.isCertificateAuthority,
        derBase64: certificate.der.base64EncodedString()
    )
    var manifest = try loadCAManifest() ?? SystemCAManifest(schemaVersion: 1, owner: "IdentityVOnMac", records: [])
    if !manifest.records.contains(where: { $0.sha256 == record.sha256 && $0.derBase64 == record.derBase64 }) {
        manifest.records.append(record)
    }
    let data = try JSONEncoder().encode(manifest)
    try atomicWrite(data + Data("\n".utf8), to: idvLoginSystemCAStatePath, metadata: manifestMetadata())
}

private func requiresSystemCAImport(_ certificate: CertificateInfo, existing: [CertificateInfo], isTrusted: Bool = true) throws -> Bool {
    guard isExpectedIDVLoginCA(certificate) else {
        throw StateError.message("保留的 IDV Login CA 特征无效；未请求系统信任。")
    }
    // A same-name certificate is not the same trust anchor.
    return !isTrusted || !existing.contains { $0.der == certificate.der }
}

private func certificateIsTrusted(_ certificate: CertificateInfo) -> Bool {
    guard let value = SecCertificateCreateWithData(nil, certificate.der as CFData) else { return false }
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(value, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
          let trust,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
    return SecTrustEvaluateWithError(trust, nil)
}

private func ensureSystemCA(home: String) throws {
    let pem = try readSafeIDVLoginCAPEM(home: home)
    let certificate = try certificateInfo(fromPEM: pem)
    if try requiresSystemCAImport(certificate, existing: systemKeychainCertificates(), isTrusted: certificateIsTrusted(certificate)) {
        // Uninstall revokes the system CA but preserves account data and the
        // original PEM. Upstream skips import when that PEM is still valid.
        // Re-import this validated public certificate through the same macOS
        // authorization command; never regenerate keys or trust by name.
        // security reads a root-owned snapshot, not a mutable user pathname.
        let temporary = "/private/var/tmp/identityv-ca-" + UUID().uuidString
        guard mkdir(temporary, 0o700) == 0 else {
            throw StateError.message("无法创建证书授权暂存目录。")
        }
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let snapshot = temporary + "/certificate.der"
        try atomicWrite(certificate.der, to: snapshot, metadata: manifestMetadata())
        _ = try runCommand("/usr/bin/security", arguments: [
            "add-trusted-cert", "-d", "-r", "trustRoot", "-k", systemKeychainPath, snapshot
        ])
        // Keep an exact public ownership witness even if the user replaces
        // their PEM while the system dialog is open.
        try recordSystemCA(certificate: certificate)
        // Confirm both system import and that the user-scoped public witness
        // has not changed while the person was considering authorization.
        let current = try certificateInfo(fromPEM: readSafeIDVLoginCAPEM(home: home))
        guard current.der == certificate.der else {
            throw StateError.message("授权期间 IDV Login CA 已改变；请重新启动组件。")
        }
    }
    guard certificateIsTrusted(certificate) else {
        throw StateError.message("macOS 尚未信任 IDV Login 登录证书；请完成系统授权后重试。")
    }
    try recordSystemCA(home: home)
}

private func removeSystemCA(home: String, delete: (String) throws -> Void = { sha1 in
    _ = try runCommand("/usr/bin/security", arguments: ["delete-certificate", "-Z", sha1, systemKeychainPath])
}) throws {
    // Old installations have no ledger.  This is deliberately a no-op: a
    // shared display name is never ownership evidence.
    guard let manifest = try loadCAManifest() else { return }
    // Account data may be deliberately removed before uninstall.  A current
    // PEM is additional tamper evidence when present, not a prerequisite for
    // revoking a root-owned, DER-backed ownership record.
    let current: CertificateInfo?
    if idvLoginCAPEMRelativePaths.contains(where: { lstatMetadata(URL(fileURLWithPath: home).standardizedFileURL.path + "/" + $0) != nil }) {
        current = try certificateInfo(fromPEM: readSafeIDVLoginCAPEM(home: home))
        guard manifest.records.contains(where: { $0.sha256 == current!.sha256 && $0.derBase64 == current!.der.base64EncodedString() }) else {
            throw StateError.message("当前 IDV Login CA 与项目台账不一致；拒绝删除系统证书。")
        }
    } else {
        current = nil
    }
    let before = try systemKeychainCertificates()
    for record in manifest.records {
        let saved = try certificateInfo(fromDER: Data(base64Encoded: record.derBase64)!)
        guard before.contains(where: { $0.sha1 == record.sha1 && $0.sha256 == record.sha256 && $0.der == saved.der }) else { continue }
        try delete(record.sha1)
        let remaining = try systemKeychainCertificates().contains { $0.sha1 == record.sha1 && $0.sha256 == record.sha256 && $0.der == saved.der }
        guard !remaining else { throw StateError.message("系统证书撤销后仍存在；保留台账以便人工审计。") }
    }
    guard Darwin.unlink(idvLoginSystemCAStatePath) == 0 || errno == ENOENT else {
        throw StateError.message("系统 CA 已撤销，但无法清理项目台账。")
    }
}

private func runSelfTest() throws {
    let fileManager = FileManager.default
    // Exercise the real system LibreSSL command line, not merely the pure
    // ownership planner below.  The previous test built CertificateInfo values
    // directly and therefore missed an unsupported `openssl x509 -ext` option
    // that made every clean IDV Login start fail after its proxy became ready.
    let libreSSLCAFixture = """
    -----BEGIN CERTIFICATE-----
    MIIDPDCCAiSgAwIBAgIJAOByj7AUT+QxMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNV
    BAYTAlVTMR0wGwYDVQQKDBRJZGVudGl0eVZPbk1hYyBUZXN0czElMCMGA1UEAwwc
    SWRlbnRpdHlWIFN0YXRlIFRvb2wgVGVzdCBDQTAeFw0yNjA5MDMxNzQ1MTVaFw0z
    NjA4MzExNzQ1MTVaMFMxCzAJBgNVBAYTAlVTMR0wGwYDVQQKDBRJZGVudGl0eVZP
    bk1hYyBUZXN0czElMCMGA1UEAwwcSWRlbnRpdHlWIFN0YXRlIFRvb2wgVGVzdCBD
    QTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANchcuH0/RR8ENRjr8cu
    u17WZhPxJ0UGeVRlRQlrj6jFMb/jlYH/9+LZ7Si0uyXRsD0oo/uOpzI4wzc6/Hxb
    HhZGoSps3anebKSBxLnd2X7MIJK/C3WxLp4ORK1JZh68ToU35Cj/56f+KKH4V54X
    21myn6cGwFp2Fei3M8xm/u95YxzfPxgyDC6hrJ8d752VIImOmmGXesS3NR8SIerU
    FPXI/4WqngAO8dGMSSScfoZ8AO010ucW1VSYD4f5qw+VmRiA4rajZ1/ft2SNC5Y8
    HicGA2iQT008baaHhndO0FVEc6mjcGXnWGqBNLUuA1rUOW9ghL2W/4SiPgvnh/1h
    vfUCAwEAAaMTMBEwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEA
    ncmN5Dp01nEsaZPXF/L/F14KP0OJXQc/e7l+W+xSA9alo478zgwwMuESMgXRZzQ/
    +I2Npr2Gxsl3wUGEdAJVNVGZ+X34E5GNjXZXTWm/Fs5aK40JtYFSKTtdKiJcInrf
    OHGJ5nBwJrtbRZ+t8iVw7FUwvnc5p2U/vabhOVjgAXEajHvdW7cvTRjbURkxaCbS
    IA4uN79K/PsjKCIKiRky0i/0nhkKtzJeJi4C7ksoXNaKzEa3ih5yuyFi8puz9AFq
    IZdPqNfWTVBRzTXRLPvpkIy5SBM9frti+0g98wkqjnvTwjAOG/1W6st2uc+zQzzy
    V8+TavDeuy5Wsmq+qko/sA==
    -----END CERTIFICATE-----
    """ + "\n"
    let parsedLibreSSLFixture = try certificateInfo(fromPEM: Data(libreSSLCAFixture.utf8))
    guard parsedLibreSSLFixture.isCertificateAuthority,
          parsedLibreSSLFixture.subject == parsedLibreSSLFixture.issuer,
          parsedLibreSSLFixture.subject.contains("IdentityV State Tool Test CA") else {
        throw StateError.message("system LibreSSL certificate parsing self-test failed")
    }
    let root = fileManager.temporaryDirectory.appendingPathComponent("identityv-state-tool-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let home = root.appendingPathComponent("Users/tester", isDirectory: true)
    let state = home.appendingPathComponent("Library/Application Support/idv-login", isDirectory: true)
    try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
    let config = state.appendingPathComponent("config.json")
    let secret = "do-not-change"
    let fixture: [String: Any] = [
        "account_records": [["token": secret]],
        "nested": ["launcher": "/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV"],
        "proxy_mode": "global",
        "game_settings": [
            longMainlandGameID: [
                "should_auto_start": true,
                "installation_state_v1": [
                    "installations": [
                        "modern": ["settings": ["auto_start": true, "keep": "modern"]]
                    ]
                ],
                "installations": [
                    "legacy": ["settings": ["auto_start": true, "keep": "legacy"]]
                ]
            ],
            "international": ["should_auto_start": true]
        ],
        "game_installation_settings_v1": [
            longMainlandGameID: [
                "state_keep": "mainland-cache",
                "installations": [
                    "cache-modern": ["settings": ["auto_start": true, "keep": "cache-modern"]]
                ]
            ],
            "international": [
                "state_keep": "international-cache",
                "installations": [
                    ["settings": ["auto_start": true, "keep": "cache-list"]]
                ]
            ]
        ]
    ]
    try JSONSerialization.data(withJSONObject: fixture).write(to: config)
    try prepareConfig(home: home.path, staffGID: getgid(), enforceUserRoot: false)
    let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    let accounts = migrated["account_records"] as! [[String: String]]
    let games = migrated["game_settings"] as! [String: [String: Any]]
    let game = games[longMainlandGameID]!
    guard accounts.first?["token"] == secret,
          (migrated["nested"] as? [String: String])?["launcher"] == gameBridge,
          migrated["proxy_mode"] as? String == "compat",
          game["path"] as? String == gameBridge,
          game["should_auto_start"] as? Bool == false,
          (((game["installation_state_v1"] as? [String: Any])?["installations"] as? [String: [String: Any]])?["modern"]?["settings"] as? [String: Any])?["auto_start"] as? Bool == false,
          ((game["installations"] as? [String: [String: Any]])?["legacy"]?["settings"] as? [String: Any])?["auto_start"] as? Bool == false,
          ((games["international"]?["should_auto_start"] as? Bool) == false) else {
        throw StateError.message("config 保留/迁移自检失败。")
    }
    let cache = migrated["game_installation_settings_v1"] as! [String: Any]
    let cacheMainland = cache[longMainlandGameID] as! [String: Any]
    let cacheInternational = cache["international"] as! [String: Any]
    let cacheInternationalSettings = ((cacheInternational["installations"] as? [[String: Any]])?.first?["settings"] as? [String: Any])
    guard cacheMainland["state_keep"] as? String == "mainland-cache",
          ((cacheMainland["installations"] as? [String: [String: Any]])?["cache-modern"]?["settings"] as? [String: Any])?["auto_start"] as? Bool == false,
          ((cacheMainland["installations"] as? [String: [String: Any]])?["cache-modern"]?["settings"] as? [String: Any])?["keep"] as? String == "cache-modern",
          cacheInternational["state_keep"] as? String == "international-cache",
          cacheInternationalSettings?["auto_start"] as? Bool == false,
          cacheInternationalSettings?["keep"] as? String == "cache-list" else {
        throw StateError.message("跨缓存自动启动收口自检失败。")
    }

    let hosts = root.appendingPathComponent("hosts")
    try Data("127.0.0.1 localhost\n# keep\n".utf8).write(to: hosts)
    try updateHosts(path: hosts.path, ensure: true)
    let installed = try String(contentsOf: hosts, encoding: .utf8)
    guard managedDomains.allSatisfy({ installed.contains(canonicalHostLine($0)) }) else {
        throw StateError.message("Hosts 安装自检失败。")
    }
    try updateHosts(path: hosts.path, ensure: false)
    let removed = try String(contentsOf: hosts, encoding: .utf8)
    guard !removed.contains(hostsTag), removed.contains("# keep") else {
        throw StateError.message("Hosts 撤销自检失败。")
    }
    let upstreamLines = managedDomains.map { "127.0.0.1\t\($0)" }.joined(separator: "\n")
    try Data(("127.0.0.1 localhost\n" + upstreamLines + "\n").utf8).write(to: hosts)
    try updateHosts(path: hosts.path, ensure: true)
    let acceptedUpstream = try String(contentsOf: hosts, encoding: .utf8)
    guard managedDomains.allSatisfy({ domain in
        acceptedUpstream.components(separatedBy: "\n").filter { acceptedManagedHostDomain($0) == domain }.count == 1
    }) else { throw StateError.message("上游精确 Hosts 格式自检失败。") }
    try updateHosts(path: hosts.path, ensure: false)
    let removedUpstream = try String(contentsOf: hosts, encoding: .utf8)
    guard managedDomains.allSatisfy({ !removedUpstream.contains($0) }) else {
        throw StateError.message("上游精确 Hosts 撤销自检失败。")
    }
    var rejected = false
    try Data((canonicalHostLine(managedDomains[0]) + "\n127.0.0.1\t" + managedDomains[0] + "\n").utf8).write(to: hosts)
    do { try updateHosts(path: hosts.path, ensure: true) } catch { rejected = true }
    guard rejected else { throw StateError.message("Hosts 重复映射反例未被拒绝。") }
    try Data("127.0.0.1 localhost\n127.0.0.1 service.mkey.163.com # foreign\n".utf8).write(to: hosts)
    rejected = false
    do { try updateHosts(path: hosts.path, ensure: true) } catch { rejected = true }
    guard rejected else { throw StateError.message("外部标记 Hosts 反例未被拒绝。") }
    try Data("127.0.0.1 localhost sdk-os.mpsdk.easebar.com\n".utf8).write(to: hosts)
    rejected = false
    do { try updateHosts(path: hosts.path, ensure: true) } catch { rejected = true }
    guard rejected else { throw StateError.message("Hosts 多别名反例未被拒绝。") }
    try Data("192.0.2.1 mgbsdk.matrix.netease.com\n".utf8).write(to: hosts)
    rejected = false
    do { try updateHosts(path: hosts.path, ensure: true) } catch { rejected = true }
    guard rejected else { throw StateError.message("Hosts 非本机映射反例未被拒绝。") }

    // Pure certificate ownership fixtures: no System.keychain access, no
    // privileged mutation.  Two certificates intentionally share every human
    // readable Netease label, which proves that neither label nor subject is a
    // deletion selector.
    func fixtureCertificate(_ marker: String) -> CertificateInfo {
        let der = Data("fixture-der-\(marker)".utf8)
        return CertificateInfo(
            der: der,
            sha1: lowercaseHex(Insecure.SHA1.hash(data: der)),
            sha256: lowercaseHex(SHA256.hash(data: der)),
            subject: "C = US, O = Netease Login Helper CA, CN = Netease Login Helper CA",
            issuer: "C = US, O = Netease Login Helper CA, CN = Netease Login Helper CA",
            isCertificateAuthority: true
        )
    }
    let ownedCA = fixtureCertificate("owned")
    guard isWithdrawnAuthorization("SecTrustSettingsSetTrustSettings: The authorization was canceled by the user."),
          isWithdrawnAuthorization("OSStatus -60006"),
          !isWithdrawnAuthorization("Write permissions error"),
          !isWithdrawnAuthorization("certificate malformed") else {
        throw StateError.message("系统授权收回与真实证书失败的分类回归失败。")
    }
    let sameNameForeignCA = fixtureCertificate("foreign-same-label")
    guard try requiresSystemCAImport(ownedCA, existing: []),
          try requiresSystemCAImport(ownedCA, existing: [sameNameForeignCA]),
          try requiresSystemCAImport(ownedCA, existing: [ownedCA], isTrusted: false),
          try !requiresSystemCAImport(ownedCA, existing: [sameNameForeignCA, ownedCA]) else {
        throw StateError.message("重装保留CA重新授权/同名异证书/已安装无需授权回归失败。")
    }
    var rejectedNonIDVCA = false
    do { _ = try requiresSystemCAImport(parsedLibreSSLFixture, existing: []) }
    catch { rejectedNonIDVCA = true }
    guard rejectedNonIDVCA else { throw StateError.message("不得为非IDV证书请求系统信任。") }
    let record = SystemCARecord(
        sha1: ownedCA.sha1,
        sha256: ownedCA.sha256, subject: ownedCA.subject, issuer: ownedCA.issuer,
        isCertificateAuthority: true, derBase64: ownedCA.der.base64EncodedString()
    )
    guard try removalPlan(record: nil, currentUserPEM: sameNameForeignCA, systemCertificates: [sameNameForeignCA]) == .noRecordedOwnership else {
        throw StateError.message("无台账证书撤销反例失败。")
    }
    guard try removalPlan(record: record, currentUserPEM: ownedCA, systemCertificates: [sameNameForeignCA, ownedCA]) == .deleteExactSHA1(ownedCA.sha1) else {
        throw StateError.message("多个同名证书的精确删除计划失败。")
    }
    guard try removalPlan(record: record, currentUserPEM: ownedCA, systemCertificates: [sameNameForeignCA]) == .removeStaleRecord else {
        throw StateError.message("已不存在证书的台账清理计划失败。")
    }
    var impersonatorRejected = false
    do { _ = try removalPlan(record: record, currentUserPEM: sameNameForeignCA, systemCertificates: [sameNameForeignCA, ownedCA]) } catch { impersonatorRejected = true }
    guard impersonatorRejected else {
        throw StateError.message("任意用户 PEM 冒充反例未被拒绝。")
    }
    // `--only-idv-login` and complete uninstall both call the same state tool;
    // this fixture asserts the shared planner is independent of uninstall scope.
    for _ in ["only-idv-login", "complete-uninstall"] {
        guard try removalPlan(record: record, currentUserPEM: ownedCA, systemCertificates: [ownedCA]) == .deleteExactSHA1(ownedCA.sha1) else {
            throw StateError.message("卸载范围 CA 计划不一致。")
        }
    }
    let rotatedCA = fixtureCertificate("rotated")
    let rotatedRecord = SystemCARecord(
        sha1: rotatedCA.sha1, sha256: rotatedCA.sha256,
        subject: rotatedCA.subject, issuer: rotatedCA.issuer,
        isCertificateAuthority: true, derBase64: rotatedCA.der.base64EncodedString()
    )
    let multiRecordManifest = SystemCAManifest(schemaVersion: 1, owner: "IdentityVOnMac", records: [record, rotatedRecord])
    guard multiRecordManifest.records.count == 2,
          try removalPlan(record: record, currentUserPEM: ownedCA, systemCertificates: [ownedCA, rotatedCA]) == .deleteExactSHA1(ownedCA.sha1),
          try removalPlan(record: rotatedRecord, currentUserPEM: rotatedCA, systemCertificates: [ownedCA, rotatedCA]) == .deleteExactSHA1(rotatedCA.sha1) else {
        throw StateError.message("多 CA 台账追加/精确撤销反例失败。")
    }
    print("IDV Login 原生 config/Hosts 状态工具自检通过。")
}

@main
private struct IdentityVPrivilegedStateTool {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] {
                try runSelfTest()
                return
            }
            guard geteuid() == 0 else { throw StateError.message("状态工具必须由已安装的 root helper 调用。") }
            try withStateLock {
                if arguments.count == 3, arguments[0] == "prepare-config",
                   arguments[1] == "--home" {
                    try prepareConfig(home: arguments[2], staffGID: 20)
                } else if arguments == ["ensure-hosts"] {
                    try updateHosts(path: systemHostsPath, ensure: true)
                } else if arguments == ["remove-hosts"] {
                    try updateHosts(path: systemHostsPath, ensure: false)
                } else if arguments.count == 3, arguments[0] == "record-idv-login-ca",
                          arguments[1] == "--home" {
                    try recordSystemCA(home: arguments[2])
                } else if arguments.count == 3, arguments[0] == "ensure-idv-login-ca",
                          arguments[1] == "--home" {
                    try ensureSystemCA(home: arguments[2])
                } else if arguments.count == 3, arguments[0] == "remove-idv-login-ca",
                          arguments[1] == "--home" {
                    try removeSystemCA(home: arguments[2])
                } else {
                    throw StateError.message("参数无效。")
                }
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            if let stateError = error as? StateError, case .authorizationPending = stateError { exit(75) }
            exit(1)
        }
    }
}
