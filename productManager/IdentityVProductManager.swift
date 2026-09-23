import Foundation
import CryptoKit
import Darwin

private enum ProductID: String, Codable, CaseIterable { case mainland, global }

private struct Catalog: Codable { let schemaVersion: Int; let products: [CatalogProduct] }
private struct CatalogProduct: Codable {
    let id: ProductID
    let displayName: String
    let officialLandingPage: String
    let resolverURL: String
    let allowedFinalHostSuffixes: [String]
    let expectedInstallerFilename: String
    let directDownload: DirectDownloadDescriptor?
}

private struct DirectDownloadDescriptor: Codable {
    let adapter: String
    let distributionId: Int
    let gameId: String
    let metadataOrigin: String
    let requestChannel: String
}

private struct DirectManifestFile: Codable, Equatable {
    let path: String
    let byteCount: Int64
    let xxh64: String
    let operation: Int?
}

private struct DirectManifestDirectory: Codable, Equatable {
    let path: String
    let operation: Int?
}

private struct DirectManifestDocument: Codable, Equatable {
    let schemaVersion: Int
    let productId: ProductID
    let adapter: String
    let distributionId: Int
    let gameId: String
    let displayName: String
    let startupPath: String
    let startupArguments: String
    let versionCode: String
    let contentId: Int
    let totalByteCount: Int64
    let files: [DirectManifestFile]
    let directories: [DirectManifestDirectory]
    let fetchedAt: String
}

/// The global adapter has its own independently validated protocol.  Keep the
/// wire type here deliberately separate from the mainland LoadingBay shape.
private struct GlobalManifestDocument: Codable, Equatable {
    let schemaVersion: Int; let productId: ProductID; let adapter: String
    let displayName: String; let startupPath: String; let versionCode: String
    let totalByteCount: Int64; let files: [GlobalManifestFile]
}
private struct GlobalManifestFile: Codable, Equatable { let path: String; let byteCount: Int64; let md5: String; let xxh64: String; let url: String; let operation: Int }
private struct GlobalTransactionMarker: Codable, Equatable { let schemaVersion: Int; let product: String; let phase: String; let prefix: String; let version: String }
private enum GlobalPublishRecovery: Equatable { case restoreLink, stateOnly }

/// Pure transaction-evidence gate used by recovery and its deterministic
/// self-test.  Filesystem reads happen outside this function; it only accepts
/// the two exact C: states belonging to this workspace.
private func validateGlobalPublishEvidence(
    marker: GlobalTransactionMarker, workspace: DirectInstallWorkspace,
    version: String, finalExists: Bool, stagingExists: Bool,
    cTarget: String?, managedDriveTarget: String?, zTarget: String?
) throws -> GlobalPublishRecovery {
    guard marker.schemaVersion == 1, marker.product == "global", marker.phase == "publishing",
          marker.prefix == workspace.prefix.path, marker.version == version,
          finalExists, !stagingExists,
          managedDriveTarget == workspace.installRoot.path,
          zTarget == workspace.prefix.appendingPathComponent("host-root").path else {
        throw ManagerError.message("国际服发布事务证据不完整；未覆盖现有目录。")
    }
    if cTarget == workspace.finalRoot.path { return .stateOnly }
    if cTarget == workspace.stagingRoot.path { return .restoreLink }
    throw ManagerError.message("国际服发布事务的 C: 绑定不属于此安装；未覆盖现有目录。")
}

private struct LoadingBayEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let data: Value
}

private struct LoadingBayLauncherData: Decodable {
    let appId: Int
    let gameId: String
    let displayName: String
    let startupPath: String
    let startupParameters: String

    private enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case gameId = "game_id"
        case displayName = "display_name"
        case startupPath = "startup_path"
        case startupParameters = "startup_params"
    }
}

private struct LoadingBayDistributionData: Decodable {
    let mainContent: LoadingBayMainContent
    private enum CodingKeys: String, CodingKey { case mainContent = "main_content" }
}

private struct LoadingBayMainContent: Decodable {
    let versionCode: String
    let appContentId: Int
    let files: [LoadingBayFile]
    let directories: [LoadingBayDirectory]

    private enum CodingKeys: String, CodingKey {
        case versionCode = "version_code"
        case appContentId = "app_content_id"
        case files, directories
    }
}

private struct LoadingBayFile: Decodable {
    let path: String
    let size: Int64
    let xxh: String
    let operation: Int?
    private enum CodingKeys: String, CodingKey { case path, size, xxh; case operation = "op" }
}

private struct LoadingBayDirectory: Decodable {
    let path: String
    let operation: Int?
    private enum CodingKeys: String, CodingKey { case path; case operation = "op" }
}

private struct ManagedLocation: Codable, Equatable {
    let volumeUUID: String
    let relativePath: String
}

private struct Installation: Codable {
    var gameRoot: ManagedLocation?
    var prefix: ManagedLocation?
    var installer: InstallerRecord?
    var installedVersion: String?
}

/// A download is deliberately published only after the planner has verified
/// every file.  Before then the deterministic staging directory is retained
/// beside the requested game directory: the Netease core owns its `.dlstorage`
/// cache there, so selecting the same parent again safely resumes it.
private struct DirectInstallWorkspace {
    /// The only host directory exposed as D: to this installation's Wine
    /// prefix.  It contains the final game, resumable staging tree and the
    /// downloader's work files; user home, other volumes and the launcher
    /// support directory are never mounted here.
    let installRoot: URL
    let finalRoot: URL
    let stagingRoot: URL
    let prefix: URL
    let work: URL
}

private struct DirectInstallTransaction: Codable {
    let schemaVersion: Int
    let product: String
    let phase: String
    let prefix: String
    let version: String
}

private struct InstallerRecord: Codable {
    let filename: String
    let sha256: String
    let etag: String?
    let lastModified: String?
    let byteCount: Int64
    let downloadedAt: String
}

private struct ProductState: Codable {
    var schemaVersion = 1
    var selectedProductId: ProductID = .mainland
    var installations: [ProductID: Installation] = [:]
}

private struct StatusProduct: Codable {
    let productId: ProductID
    let state: String
    let installedVersion: String?
    let detail: String?
    /// Whether this product has any manager-owned record that may be safely
    /// cleaned.  Keep this distinct from `state`: a downloaded setup EXE is
    /// intentionally still `not-installed`, while a disconnected disk is
    /// `needs-repair` but should still offer the player a cleanup path.
    let canRemove: Bool
}
private struct StatusDocument: Codable { let schemaVersion: Int; let selectedProductId: ProductID; let products: [StatusProduct] }
private struct LegacyRuntimeCatalog: Decodable {
    let schemaVersion: Int
    let engines: [String: LegacyRuntimeCatalogEngine]
}
private struct LegacyRuntimeCatalogEngine: Decodable {
    let executablePaths: LegacyRuntimeExecutablePaths
    let launchProfile: String
    let verificationFiles: [String: LegacyRuntimeVerificationFile]
}
/// Runtime acquisition is independent of either game's installation.  This
/// binding is deliberately insufficient to launch a game: the runner still
/// requires a complete game/prefix binding before it starts Wine.
private struct RuntimeBinding: Codable, Equatable {
    let schemaVersion: Int
    let selectedEngineId: String
    let runtime: ManagedLocation
}
private struct LegacyRuntimeExecutablePaths: Decodable { let wine: String; let wineserver: String }
/// Some catalogue entries are descriptive/status-only. They may omit hash
/// fields, but any engine selected for a launch must provide both fields for
/// every listed verification item; validation below fails closed otherwise.
private struct LegacyRuntimeVerificationFile: Decodable { let relativePath: String?; let sha256: String? }
private struct LegacyInstallationDocument: Codable {
    var schemaVersion: Int
    var selectedEngineId: String
    var lastKnownGoodEngineId: String?
    var engines: [String: LegacyInstallationEngine]
}
private struct LegacyInstallationEngine: Codable {
    var gameRoot: ManagedLocation
    var prefix: ManagedLocation
    var runtime: ManagedLocation
}
private struct RepairPlanSummary: Decodable {
    let repairs: Int
    let valid: Bool
}
private enum RepairExecutionDecision: Equatable {
    case noDownload
    case download
    case blockForGameHotUpdate
}
private struct DownloadTask: Encodable {
    let schemaVersion: Int
    let contentId: String
    let distributionId: String
    let coreExecutable: String
    let coreWorkingDirectory: String
    let wineExecutable: String
    let winePrefix: String
    let downloadRootWindows: String
    let repairListWindows: String
    let targetVersion: String
    let originVersion: String
    let controlFile: String
}
private struct InstallerVerificationDocument: Codable {
    let schemaVersion: Int
    let byteCount: Int64
    let sha256: String
    let peStructureValid: Bool
    let authenticodeContainerPresent: Bool
}
private struct ResolvedDownloadDocument: Codable {
    let schemaVersion: Int
    let productId: ProductID
    let finalHost: String
    let filename: String
}

/// One JSON object per stderr line while `install` is running.  Keep this
/// deliberately small and versioned: the native launcher treats it as a
/// machine protocol, while stdout remains the human-facing completion text.
private struct DownloadProgressEvent: Encodable {
    let schemaVersion: Int
    let event: String
    let productId: ProductID
    let phase: String
    let bytesWritten: Int64
    let totalBytesExpected: Int64?
}

private struct SupervisorProgressEvent: Decodable {
    struct Progress: Decodable {
        struct Stage: Decodable { let percent: Double; let bytesPerSecond: Double; let totalBytes: Double }
        let downloadHead: Stage
        let download: Stage
        let build: Stage
        let verifyPercent: Double
    }
    let progress: Progress
}

/// The vendor's main download/build fields have appeared as both fractions
/// (`0.85`) and percentages (`85`).  Prefer those aggregate fields whenever
/// either has started.  `downloadHead` describes only the current item, so it
/// is a last-resort byte counter rather than a whole-manifest percentage.
private func supervisorManifestFraction(
    progress: SupervisorProgressEvent.Progress,
    manifestBytes: Int64
) -> Double {
    func normalizedPercent(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        return min(1, raw <= 1 ? raw : raw / 100)
    }

    let download = normalizedPercent(progress.download.percent)
    let build = normalizedPercent(progress.build.percent)
    if download > 0 || build > 0 { return max(download, build) }

    guard manifestBytes > 0,
          progress.downloadHead.totalBytes.isFinite,
          progress.downloadHead.totalBytes > 0 else { return 0 }
    return min(
        1,
        progress.downloadHead.totalBytes
            * normalizedPercent(progress.downloadHead.percent)
            / Double(manifestBytes)
    )
}

private enum ManagerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private let fileManager = FileManager.default
private let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
private let supportDirectory = home.appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
private let stateURL = supportDirectory.appendingPathComponent("products.json")
private let legacyURL = supportDirectory.appendingPathComponent("installation.json")
private let runtimeBindingURL = supportDirectory.appendingPathComponent("runtime-binding.json")

/// Keep child diagnostics useful without allowing a malformed or very verbose
/// helper to retain arbitrary amounts of manager memory.
private func appendBounded(_ data: Data, to buffer: inout Data, limit: Int) {
    guard limit > 0 else { buffer.removeAll(keepingCapacity: false); return }
    if data.count >= limit {
        buffer = Data(data.suffix(limit))
        return
    }
    buffer.append(data)
    if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
}
/// Wine's macOS mount manager auto-assigns removable volumes from D: upward.
/// Keep the launcher's private download root on a high, explicitly reserved
/// letter so an attached DMG or USB disk can never replace it asynchronously.
private let directInstallDriveLetter = "Y"
private let directInstallDosDevice = "y:"
private let managedDownloaderCoreDirectoryName = "IdentityVDownloaderCore"
private let managedDownloaderCoreFiles = ["downloadIPC.exe", "OrbitSDK.dll", "aria2c.exe"]
private let managedDownloaderRepairListName = "repair-list.txt"
private let managedDownloaderRepairListWindowsPath = "C:\\IdentityVDownloaderCore\\repair-list.txt"

private final class DownloadProgressReporter {
    private let product: ProductID
    private var lastEmission = Date.distantPast
    private var lastBytes: Int64 = -1

    init(product: ProductID) { self.product = product }

    func emit(
        event: String,
        phase: String,
        bytesWritten: Int64,
        totalBytesExpected: Int64?,
        force: Bool = false
    ) {
        let now = Date()
        guard force || bytesWritten != lastBytes && now.timeIntervalSince(lastEmission) >= 0.2 else { return }
        lastEmission = now
        lastBytes = bytesWritten
        let payload = DownloadProgressEvent(
            schemaVersion: 1,
            event: event,
            productId: product,
            phase: phase,
            bytesWritten: bytesWritten,
            totalBytesExpected: totalBytesExpected
        )
        guard let data = try? JSONEncoder().encode(payload),
              let line = String(data: data, encoding: .utf8) else { return }
        fputs(line + "\n", stderr)
        fflush(stderr)
    }
}

private func executableDirectory() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
}

/// The product manager is embedded in the outer launcher Resources directory.
/// It may launch only the sibling, bundled runner; no second /Applications app
/// is part of the release topology.  The override exists solely for the
/// deterministic self-test below and is never a command-line option.
private func launcherBundleRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["IDENTITYV_TEST_BUNDLE_ROOT"],
       override.hasPrefix("/") {
        return URL(fileURLWithPath: override, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
    }
    return executableDirectory()
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // 第五人格 Mac.app
        .resolvingSymlinksInPath().standardizedFileURL
}

private func embeddedGameRunnerApp(bundleRoot: URL = launcherBundleRoot()) throws -> URL {
    let root = bundleRoot.resolvingSymlinksInPath().standardizedFileURL
    guard root.pathExtension == "app" else {
        throw ManagerError.message("启动器包路径无效；已拒绝定位游戏运行器。")
    }
    let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    let candidate = helpers.appendingPathComponent("IdentityVGameRunner.app", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    guard candidate.path.hasPrefix(helpers.path + "/"),
          fileManager.isExecutableFile(atPath: candidate.appendingPathComponent("Contents/MacOS/launchIdentityV").path),
          fileManager.fileExists(atPath: candidate.appendingPathComponent("Contents/Info.plist").path) else {
        throw ManagerError.message("启动器内嵌的游戏运行器缺失或不可执行，请重新安装第五人格 Mac。")
    }
    return candidate
}

private func embeddedGameRunnerExecutable(runner: URL) throws -> URL {
    let executable = runner
        .appendingPathComponent("Contents/MacOS/launchIdentityVRunner")
        .resolvingSymlinksInPath().standardizedFileURL
    guard executable.path.hasPrefix(runner.path + "/Contents/MacOS/"),
          fileManager.isExecutableFile(atPath: executable.path) else {
        throw ManagerError.message("启动器内嵌的游戏运行器预检入口缺失或不可执行。")
    }
    return executable
}

private func embeddedGameRunnerArguments(product: ProductID) -> [String] {
    ["--product", product.rawValue]
}

private func preflightEmbeddedGameRunner(product: ProductID, runner: URL) throws -> String {
    let executable = try embeddedGameRunnerExecutable(runner: runner)
    return try runTool(
        executable,
        arguments: ["--preflight", "--product", product.rawValue]
    )
}

private func catalogURL() -> URL { executableDirectory().appendingPathComponent("products.json") }

private func loadCatalog() throws -> Catalog {
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL()))
    guard catalog.schemaVersion == 1, Set(catalog.products.map(\.id)) == Set(ProductID.allCases) else {
        throw ManagerError.message("产品目录格式无效。")
    }
    return catalog
}

private func loadState() throws -> ProductState {
    guard fileManager.fileExists(atPath: stateURL.path) else { return migrateLegacyState() }
    let state = try JSONDecoder().decode(ProductState.self, from: Data(contentsOf: stateURL))
    guard state.schemaVersion == 1 else { throw ManagerError.message("启动器状态版本不受支持。") }
    return state
}

private func legacyBinding() -> (selectedEngineId: String, gameRoot: ManagedLocation, prefix: ManagedLocation, runtime: ManagedLocation)? {
    guard let data = try? Data(contentsOf: legacyURL),
          let document = try? JSONDecoder().decode(LegacyInstallationDocument.self, from: data),
          document.schemaVersion == 1,
          !document.selectedEngineId.isEmpty,
          let engine = document.engines[document.selectedEngineId] else { return nil }
    return (document.selectedEngineId, engine.gameRoot, engine.prefix, engine.runtime)
}

/// Migration is deliberately read-only: legacy state stays owned by the existing launcher.
private func migrateLegacyState() -> ProductState {
    guard let binding = legacyBinding() else { return ProductState() }
    return ProductState(installations: [.mainland: Installation(
        gameRoot: binding.gameRoot,
        prefix: binding.prefix,
        installer: nil,
        installedVersion: nil
    )])
}

private func ensureSupportDirectory() throws {
    try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
}

private func save(_ state: ProductState) throws {
    try ensureSupportDirectory()
    let data = try JSONEncoder.pretty.encode(state)
    let temporary = supportDirectory.appendingPathComponent(".products-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try atomicallyReplace(temporary, with: stateURL)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
}

private func atomicallyReplace(_ temporary: URL, with destination: URL) throws {
    guard rename(temporary.path, destination.path) == 0 else {
        throw ManagerError.message("无法原子保存启动器状态：\(String(cString: strerror(errno)))")
    }
}

private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
    try ensureSupportDirectory()
    let lockURL = supportDirectory.appendingPathComponent("product-manager.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ManagerError.message("无法建立启动器操作锁。") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw ManagerError.message("另一个安装、导入或切换操作仍在进行，请稍后重试。")
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
}

private func mountedVolumeURL(uuid: String) -> URL? {
    // The default installation lives on the startup volume. Resolve that
    // known local volume without enumerating removable volumes at launch.
    let startup = URL(fileURLWithPath: "/", isDirectory: true)
    if (try? startup.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)?
        .caseInsensitiveCompare(uuid) == .orderedSame {
        return startup
    }
    // Enumeration is reserved for a previously persisted non-startup volume.
    // It is reached only while resolving an explicit managed location.
    for url in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? [] {
        if (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid { return url }
    }
    return nil
}

private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    candidate.path == root.path || candidate.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
}

/// Foundation's URL symlink normalization intentionally preserves a few
/// system aliases such as `/var`.  Managed locations are persistent security
/// boundaries, so use `realpath(3)` when the item already exists.
private func canonicalExistingURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
        throw ManagerError.message("无法解析现有受管路径。")
    }
    // Do not call `standardizedFileURL` here: on macOS it may render the
    // physical `/private/var` path back as the user-facing `/var` alias.
    return URL(fileURLWithPath: String(cString: buffer))
}

private func resolve(_ location: ManagedLocation) -> URL? {
    let components = location.relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !location.relativePath.hasPrefix("/"), !components.isEmpty,
          !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
          let volume = mountedVolumeURL(uuid: location.volumeUUID) else { return nil }
    let canonicalVolume = volume.resolvingSymlinksInPath().standardizedFileURL
    let candidate = canonicalVolume.appendingPathComponent(location.relativePath).resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(candidate, of: canonicalVolume),
          let values = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey]),
          values.volumeUUIDString?.caseInsensitiveCompare(location.volumeUUID) == .orderedSame else { return nil }
    return candidate
}

private func hasMZHeader(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
    return data[0] == 0x4d && data[1] == 0x5a
}

private func gameExecutable(in root: URL, validateHeader: Bool = false) -> URL? {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let candidates = ["dwrg.exe", "DWRG/dwrg.exe", "IdentityV/dwrg.exe"]
    return candidates.lazy.compactMap { relative -> URL? in
        let candidate = canonicalRoot.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(candidate, of: canonicalRoot),
              fileManager.isReadableFile(atPath: candidate.path),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              (!validateHeader || hasMZHeader(candidate)) else { return nil }
        return candidate
    }.first
}

private func status(for product: CatalogProduct, state: ProductState) -> StatusProduct {
    guard let installation = state.installations[product.id] else {
        return StatusProduct(productId: product.id, state: "not-installed", installedVersion: nil, detail: "未安装；可下载官方安装器或导入已有客户端。", canRemove: false)
    }
    // A downloaded installer has no managed game/prefix location yet. Do not
    // inspect runtime volumes merely to render this intermediate status.
    if installation.installer != nil, installation.gameRoot == nil, installation.prefix == nil {
        return StatusProduct(productId: product.id, state: "not-installed", installedVersion: nil, detail: "官方安装器已下载；请在维护窗口完成安装并导入客户端。", canRemove: true)
    }
    let runtimeReady: Bool
    if product.id == .mainland, let legacy = legacyBinding(),
       legacy.gameRoot == installation.gameRoot, legacy.prefix == installation.prefix,
       let runtime = resolve(legacy.runtime) {
        runtimeReady = (try? verifiedCatalogRuntime(engineID: legacy.selectedEngineId, runtime: runtime)) != nil
    } else {
        runtimeReady = runtimeIsAvailable()
    }
    if let root = installation.gameRoot, let prefix = installation.prefix,
       let rootURL = resolve(root), gameExecutable(in: rootURL) != nil, resolve(prefix) != nil,
       runtimeReady {
        return StatusProduct(productId: product.id, state: "ready", installedVersion: installation.installedVersion, detail: "游戏文件与独立兼容环境已就绪。", canRemove: true)
    }
    if installation.installer != nil {
        return StatusProduct(productId: product.id, state: "not-installed", installedVersion: nil, detail: "官方安装器已下载；请在维护窗口完成安装并导入客户端。", canRemove: true)
    }
    return StatusProduct(productId: product.id, state: "needs-repair", installedVersion: installation.installedVersion, detail: "已记录的游戏、prefix 或 Wine 运行时当前不可用；请重新连接原磁盘或修复。", canRemove: true)
}

private func gameIsRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-u", String(getuid()), "-f", #"C:\\Games\\IdentityV\\dwrg[.]exe.*--start_from_launcher=1"#]
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func waitForManagedGameStart(
    product: ProductID,
    timeout: TimeInterval = 20
) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    repeat {
        let running = product == .mainland ? gameIsRunning() : managedGlobalGamePID() != nil
        if running { return true }
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.1)
    } while true
}

/// A global `dwrg.exe` deliberately has no launcher arguments.  A bare path
/// matcher would therefore seize a developer/manual Wine session in the same
/// prefix.  Only the runner-created, 0600-ish session record is authority to
/// stop or report a global game; verify both its structure and the live PID's
/// exact Windows product root before acting.
private func managedGlobalGamePID() -> Int32? {
    let session = supportDirectory.appendingPathComponent(".launcher-session-global.env")
    guard let values = try? session.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= 512,
          let text = try? String(contentsOf: session, encoding: .utf8) else { return nil }
    var fields: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2, !pair[0].isEmpty, fields[String(pair[0])] == nil else { return nil }
        fields[String(pair[0])] = String(pair[1])
    }
    guard fields["schema"] == "1", fields["product"] == "global", fields["windows_root"] == "IdentityVGlobal",
          let rawPID = fields["wine_pid"], let pid = Int32(rawPID), pid > 1 else { return nil }
    let task = Process(); let output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", String(pid), "-o", "command="]; task.standardOutput = output
    guard (try? task.run()) != nil else { return nil }; task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard command.contains(#"C:\Games\IdentityVGlobal\dwrg.exe"#),
          !command.contains(#"C:\Games\IdentityV\dwrg.exe"#) else { return nil }
    return pid
}

private func anyGlobalGameProcessIsRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    // Exact trailing separator after IdentityVGlobal makes this disjoint from
    // mainland IdentityV; this is only a write-block detector, never a kill.
    task.arguments = ["-u", String(getuid()), "-f", #"C:\\Games\\IdentityVGlobal\\dwrg[.]exe"#]
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

/// The presently verified runner is only the legacy mainland runner.  Do not
/// let its one Windows process claim to represent both products: the global
/// runner deliberately remains unavailable until it has its own verified
/// prefix and launch contract.
private func mayControlRunningGame(for product: ProductID, state: ProductState) -> Bool {
    if product == .global,
       let installation = state.installations[.global],
       let rootLocation = installation.gameRoot, let prefixLocation = installation.prefix,
       let root = resolve(rootLocation), let prefix = resolve(prefixLocation),
       gameExecutable(in: root, validateHeader: true) != nil,
       (try? fileManager.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("drive_c/Games/IdentityVGlobal").path)) == root.path {
        return true
    }
    guard product == .mainland,
          let installation = state.installations[.mainland],
          let legacy = legacyBinding() else { return false }
    return installation.gameRoot == legacy.gameRoot && installation.prefix == legacy.prefix
}

private func stopManagedGame(for product: ProductID, state: ProductState) throws -> String {
    if product == .global {
        guard mayControlRunningGame(for: product, state: state),
              let prefixLocation = state.installations[.global]?.prefix,
              let prefix = resolve(prefixLocation) else {
            throw ManagerError.message("国际服记录与独立 prefix 绑定不一致；已拒绝结束。")
        }
        // Product identity is encoded in its private Windows path.  Never use
        // a bare `dwrg.exe` match: mainland may be playing beside it.
        guard let pid = managedGlobalGamePID() else {
            return "国际服当前没有由启动器创建且可验证的游戏会话；未结束任何 Wine 进程。"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-TERM", String(pid)]
        try task.run(); task.waitUntilExit()
        if task.terminationStatus == 0 {
            let runtime = try selectedRuntimeForDirectInstall()
            let wineserver = runtime.runtime.appendingPathComponent("bin/wineserver")
            if fileManager.isExecutableFile(atPath: wineserver.path) {
                var environment = runtime.environment; environment["WINEPREFIX"] = prefix.path
                _ = try? runTool(wineserver, arguments: ["-k"], environment: environment)
                _ = try? runTool(wineserver, arguments: ["-w"], environment: environment)
            }
            return "已结束国际服的已验证游戏会话并收束其独立 Wine prefix；国服与 IDV Login 未受影响。"
        }
        throw ManagerError.message("无法结束国际服的已验证游戏会话。")
    }
    guard mayControlRunningGame(for: product, state: state) else {
        throw ManagerError.message("国服记录与当前启动壳不一致；为避免结束到不属于此产品的进程，已拒绝操作。")
    }
    let helper = executableDirectory().appendingPathComponent("restartIdentityVGame.command")
    guard fileManager.isExecutableFile(atPath: helper.path) else {
        throw ManagerError.message("工具箱缺少结束游戏组件，请重新安装。")
    }
    let task = Process()
    task.executableURL = helper
    task.arguments = ["--stop-for-restart"]
    let output = Pipe()
    task.standardOutput = output
    task.standardError = output
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ManagerError.message(detail.isEmpty ? "结束游戏组件未能收束当前会话。" : detail)
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    isDescendant(lhs, of: rhs) || isDescendant(rhs, of: lhs)
}

/// `resolve(_:)` intentionally resolves symlinks for normal status checks.
/// Removal needs the stricter opposite contract: every path component must be
/// a real directory, so a stale/tampered state file can never turn a game
/// cleanup into a traversal through a symlink.
private func resolveRemovalDirectory(_ location: ManagedLocation) throws -> URL {
    let components = location.relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !location.relativePath.hasPrefix("/"), !components.isEmpty,
          !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
          let volume = mountedVolumeURL(uuid: location.volumeUUID) else {
        throw ManagerError.message("受管游戏目录所在磁盘不可用或路径无效，未执行清除。")
    }
    let canonicalVolume = volume.resolvingSymlinksInPath().standardizedFileURL
    var candidate = canonicalVolume
    for component in components {
        candidate.appendPathComponent(String(component), isDirectory: true)
        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0 else {
            throw ManagerError.message("受管游戏目录已不存在，未猜测删除目标。")
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw ManagerError.message("受管游戏路径包含符号链接，已拒绝清除。")
        }
    }
    let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeUUIDStringKey])
    guard values.isDirectory == true,
          values.isSymbolicLink != true,
          values.volumeUUIDString?.caseInsensitiveCompare(location.volumeUUID) == .orderedSame,
          isDescendant(candidate.standardizedFileURL, of: canonicalVolume) else {
        throw ManagerError.message("受管游戏目录未通过清除范围校验。")
    }
    return candidate.standardizedFileURL
}

private func protectedRemovalRoots() -> [URL] {
    [
        supportDirectory.standardizedFileURL,
        URL(fileURLWithPath: "/Library/Application Support/IdentityVOnMac", isDirectory: true).standardizedFileURL,
        URL(fileURLWithPath: "/Applications/第五人格启动器.app", isDirectory: true).standardizedFileURL
    ]
}

private enum ManagedRemovalKind {
    case gameRoot
    case prefix
    case installer
}

private struct ManagedRemovalItem {
    let kind: ManagedRemovalKind
    let url: URL
}

private func removalItems(for product: ProductID, state: ProductState) throws -> [ManagedRemovalItem] {
    guard let installation = state.installations[product] else {
        throw ManagerError.message("此版本没有受管游戏文件可清除。")
    }
    let candidates = try [
        (ManagedRemovalKind.gameRoot, installation.gameRoot),
        (ManagedRemovalKind.prefix, installation.prefix)
    ].compactMap { entry -> ManagedRemovalItem? in
        guard let location = entry.1 else { return nil }
        return ManagedRemovalItem(kind: entry.0, url: try resolveRemovalDirectory(location))
    }
    for (index, candidate) in candidates.enumerated() {
        guard !protectedRemovalRoots().contains(where: { pathsOverlap(candidate.url, $0) }) else {
            throw ManagerError.message("受管路径与启动器、共享运行时或登录组件重叠，已拒绝清除。")
        }
        for other in candidates[..<index] where pathsOverlap(candidate.url, other.url) {
            throw ManagerError.message("游戏目录与兼容环境重叠，已拒绝清除以免扩大范围。")
        }
        for (otherProduct, otherInstallation) in state.installations where otherProduct != product {
            for otherLocation in [otherInstallation.gameRoot, otherInstallation.prefix].compactMap({ $0 }) {
                if let otherURL = try? resolveRemovalDirectory(otherLocation), pathsOverlap(candidate.url, otherURL) {
                    throw ManagerError.message("受管路径与另一个服务器的文件重叠，已拒绝清除。")
                }
            }
        }
    }
    var items = candidates
    if let installer = try installerRemovalURL(for: product, installation: installation) {
        items.append(ManagedRemovalItem(kind: .installer, url: installer))
    }
    return items
}

private func installerRemovalURL(for product: ProductID, installation: Installation) throws -> URL? {
    guard let installer = installation.installer else { return nil }
    let filename = installer.filename
    guard !filename.isEmpty,
          filename == URL(fileURLWithPath: filename).lastPathComponent,
          !filename.contains("/") else {
        throw ManagerError.message("受管安装器文件名无效，已拒绝清除。")
    }
    let directory = supportDirectory.appendingPathComponent("Downloads/\(product.rawValue)", isDirectory: true)
    let candidate = directory.appendingPathComponent(filename, isDirectory: false)
    guard fileManager.fileExists(atPath: candidate.path) else { return nil }
    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ManagerError.message("受管安装器不是普通文件，已拒绝清除。")
    }
    return candidate
}

private func moveToTrash(_ url: URL) throws {
    var resultingURL: NSURL?
    try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
}

private func removeManagedProductFiles(
    _ product: ProductID,
    state: inout ProductState,
    move: (URL) throws -> Void = moveToTrash,
    persist: (ProductState) throws -> Void = save
) throws -> String {
    guard let original = state.installations[product] else {
        throw ManagerError.message("此版本没有受管游戏文件可清除。")
    }
    let items = try removalItems(for: product, state: state)
    guard !items.isEmpty else {
        throw ManagerError.message("没有可验证的受管游戏文件；未执行清除。")
    }

    // Only ever send exact, pre-validated items to Finder's per-user Trash.
    // We persist each completed move, so an interrupted multi-volume cleanup
    // cannot leave state claiming that an already-trashed directory still
    // exists.  Nothing is recursively removed by this launcher.
    var installation = original
    var moved: [String] = []
    for item in items {
        // `item.kind` is fixed during preflight.  Do not resolve the original
        // location after moving it: that would fail precisely when the move
        // succeeded and leave stale state behind.
        try move(item.url)
        switch item.kind {
        case .gameRoot:
            installation.gameRoot = nil
        case .prefix:
            installation.prefix = nil
        case .installer:
            installation.installer = nil
        }
        state.installations[product] = installation
        try persist(state)
        moved.append(item.url.lastPathComponent)
    }
    if installation.gameRoot == nil, installation.prefix == nil, installation.installer == nil {
        state.installations.removeValue(forKey: product)
        try persist(state)
    }
    return "已将\(product == .mainland ? "国服" : "国际服")受管游戏文件移入废纸篓（\(moved.joined(separator: "、"))）；启动器、共享 Wine 运行时与 IDV Login 未受影响。"
}

private func runTool(_ executable: URL, arguments: [String], environment: [String: String]? = nil) throws -> String {
    guard fileManager.isExecutableFile(atPath: executable.path) else {
        throw ManagerError.message("启动器缺少维护组件 \(executable.lastPathComponent)，请重新安装启动器。")
    }
    let task = Process()
    let output = Pipe()
    task.executableURL = executable
    task.arguments = arguments
    task.standardOutput = output
    task.standardError = output
    if let environment { task.environment = environment }
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard task.terminationStatus == 0 else {
        throw ManagerError.message(text.isEmpty ? "维护组件 \(executable.lastPathComponent) 失败（退出码 \(task.terminationStatus)）。" : text)
    }
    return text
}

private func windowsPath(_ url: URL) throws -> String {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
        throw ManagerError.message("修复工作路径无效。")
    }
    return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
}

private func repairGameWindowsPath(gameRoot: URL, prefix: URL) throws -> String {
    let managedLink = prefix.appendingPathComponent("drive_c/Games/IdentityV")
    if let target = try? fileManager.destinationOfSymbolicLink(atPath: managedLink.path) {
        let resolvedTarget = URL(fileURLWithPath: target, relativeTo: managedLink.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL
        if resolvedTarget == gameRoot.resolvingSymlinksInPath().standardizedFileURL {
            return "C:\\Games\\IdentityV"
        }
    }

    // Imported legacy prefixes may still use Wine's conventional Z:/ -> /
    // mapping. Accept that broad mapping only when it is already present and
    // resolves exactly to the host root; never create it for a managed prefix.
    let zLink = prefix.appendingPathComponent("dosdevices/z:")
    if let target = try? fileManager.destinationOfSymbolicLink(atPath: zLink.path) {
        let resolvedTarget = URL(fileURLWithPath: target, relativeTo: zLink.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL
        if resolvedTarget.path == "/" { return try windowsPath(gameRoot) }
    }
    throw ManagerError.message("当前兼容环境没有与游戏目录一致的受管 Windows 路径；为避免修复到错误位置，已拒绝继续。")
}

private func repairWorkDirectory(for product: ProductID) throws -> URL {
    let root = supportDirectory.appendingPathComponent("repair-work/\(product.rawValue)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}

private func clearStaleDownloadControl(_ url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        if errno == ENOENT { return }
        throw ManagerError.message("无法检查上一次的下载控制状态。")
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else {
        throw ManagerError.message("下载控制状态不是受管普通文件；已拒绝覆盖。")
    }
    try fileManager.removeItem(at: url)
}

private func availableCapacity(at directory: URL) throws -> Int64 {
    let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
        throw ManagerError.message("无法读取所选安装位置的可用空间。")
    }
    return capacity
}

private func directInstallWorkspace(product: ProductID, destinationParent rawParent: String) throws -> DirectInstallWorkspace {
    let parent = URL(fileURLWithPath: rawParent, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw ManagerError.message("所选安装位置不可用。")
    }
    // Never use a selected volume/root itself as gameRoot.  Keep every
    // download-owned item beneath one root so managed Y: can expose precisely that
    // root, rather than a broad parent directory or a developer prefix.
    let title = product == .mainland ? "CN" : "Global"
    let installRoot = parent
    let finalRoot = installRoot.appendingPathComponent("game", isDirectory: true)
    let stagingRoot = installRoot.appendingPathComponent(".staging", isDirectory: true)
    if fileManager.fileExists(atPath: installRoot.path) {
        let marker = installRoot.appendingPathComponent(product == .mainland ? ".identityv-direct-install.json" : ".identityv-global-install.json")
        let safeResume = (try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        let isEmpty = (try? fileManager.contentsOfDirectory(atPath: installRoot.path).isEmpty) == true
        guard isEmpty || (safeResume?.isRegularFile == true && safeResume?.isSymbolicLink != true) else {
            throw ManagerError.message("所选位置已有非启动器创建的“\(title)”目录；请先导入或选择其他位置。")
        }
    }
    let identity = SHA256.hash(data: Data(installRoot.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
    let prefix = supportDirectory.appendingPathComponent("Prefixes/\(product.rawValue)-\(identity)", isDirectory: true)
    let work = installRoot.appendingPathComponent("work", isDirectory: true)
    return DirectInstallWorkspace(installRoot: installRoot, finalRoot: finalRoot, stagingRoot: stagingRoot, prefix: prefix, work: work)
}

private func relativeWindowsPath(_ item: URL, under root: URL) throws -> String {
    let canonicalRoot = root.standardizedFileURL
    let canonicalItem = item.standardizedFileURL
    guard isDescendant(canonicalItem, of: canonicalRoot) else {
        throw ManagerError.message("下载任务试图访问受管安装目录之外的位置。")
    }
    let relative = String(canonicalItem.path.dropFirst(canonicalRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return relative.isEmpty
        ? "\(directInstallDriveLetter):\\"
        : "\(directInstallDriveLetter):\\" + relative.replacingOccurrences(of: "/", with: "\\")
}

private func ensureRealDirectory(_ url: URL, failure: String) throws {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 {
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw ManagerError.message(failure)
        }
        return
    }
    guard errno == ENOENT else { throw ManagerError.message(failure) }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    guard lstat(url.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw ManagerError.message(failure)
    }
}

/// CodeWeavers Wine may create a new bottle with the Windows known folders
/// linked into the macOS home directory.  A downloader prefix must remain
/// private, so normalize only those exact, current-user bridges before the
/// ordinary real-directory gate below accepts the standard folders.
///
/// This deliberately does not recursively clean arbitrary links.  In
/// particular, a top-level link whose resolved destination is not one of the
/// current user's corresponding macOS standard folders is evidence of a
/// foreign bottle and fails closed without changing it.
private func normalizeWineUserDirectoryBridges(
    account: URL,
    macOSHome: URL = FileManager.default.homeDirectoryForCurrentUser
) throws {
    let canonicalHome = macOSHome.resolvingSymlinksInPath().standardizedFileURL
    let standardDirectories: [(wineName: String, macOSName: String)] = [
        ("Desktop", "Desktop"),
        ("Documents", "Documents"),
        ("Downloads", "Downloads"),
        ("Pictures", "Pictures"),
        ("Music", "Music"),
        // Wine names this known folder Videos while macOS calls it Movies.
        ("Videos", "Movies")
    ]

    func linkDestinationIsWithin(_ item: URL, expectedRoot: URL) -> Bool {
        let destination = item.resolvingSymlinksInPath().standardizedFileURL
        let canonicalExpectedRoot = expectedRoot.resolvingSymlinksInPath().standardizedFileURL
        return isDescendant(destination, of: canonicalExpectedRoot)
    }

    for directory in standardDirectories {
        let candidate = account.appendingPathComponent(directory.wineName, isDirectory: true)
        var metadata = stat()
        if lstat(candidate.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ManagerError.message("无法检查兼容环境中的 Windows 标准目录。")
            }
            continue
        }
        guard (metadata.st_mode & S_IFMT) == S_IFLNK else { continue }

        let expectedRoot = canonicalHome.appendingPathComponent(directory.macOSName, isDirectory: true)
        guard linkDestinationIsWithin(candidate, expectedRoot: expectedRoot) else {
            throw ManagerError.message("兼容环境中的 Windows 标准目录指向当前用户目录以外的位置；已拒绝复用。")
        }
        // `removeItem` removes the link itself, never its resolved destination.
        try fileManager.removeItem(at: candidate)
    }

    // CodeWeavers also creates this nested alias on some macOS versions.  It
    // is not a Windows known folder, so remove only a verified bridge and
    // otherwise leave a foreign nested link untouched.
    let desktop = account.appendingPathComponent("Desktop", isDirectory: true)
    let nestedDesktop = desktop.appendingPathComponent("My Mac Desktop", isDirectory: true)
    var nestedMetadata = stat()
    if lstat(nestedDesktop.path, &nestedMetadata) == 0,
       (nestedMetadata.st_mode & S_IFMT) == S_IFLNK,
       linkDestinationIsWithin(nestedDesktop, expectedRoot: canonicalHome.appendingPathComponent("Desktop", isDirectory: true)) {
        try fileManager.removeItem(at: nestedDesktop)
    }
}

private func replaceLink(at url: URL, destination: String) throws {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 {
        guard (metadata.st_mode & S_IFMT) == S_IFLNK else {
            throw ManagerError.message("受管路径中的现有对象不是符号链接；已拒绝覆盖。")
        }
        try fileManager.removeItem(at: url)
    } else if errno != ENOENT {
        throw ManagerError.message("无法检查受管符号链接。")
    }
    try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
}

private func runWine(_ wine: URL, arguments: [String], environment: [String: String]) throws {
    _ = try runTool(wine, arguments: arguments, environment: environment)
}

/// A direct installation must never clone a live/developer bottle.  `wineboot
/// -i` creates the Windows identity from scratch, then the only non-C: mount
/// granted to it is this installation's own root.
private func stopPrefixWineServer(
    runtime: (runtime: URL, wine: URL, environment: [String: String]),
    prefix: URL
) throws {
    guard let rawPath = runtime.environment["WINESERVER"] else {
        throw ManagerError.message("Wine 运行时没有受管 wineserver 路径。")
    }
    let wineserver = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(wineserver, of: runtime.runtime),
          fileManager.isExecutableFile(atPath: wineserver.path) else {
        throw ManagerError.message("Wine 运行时的 wineserver 绑定无效。")
    }
    var environment = runtime.environment
    environment["WINEPREFIX"] = prefix.path
    _ = try? runTool(wineserver, arguments: ["-k"], environment: environment)
    _ = try runTool(wineserver, arguments: ["-w"], environment: environment)
}

/// The prefix is launcher-owned, but mountmgr may still create D:/E:/F: for
/// mounted DMGs and removable disks. Remove only those exact generated
/// symlinks after wineserver has stopped; C:, managed Y: and private Z: remain.
private func removeAutomaticVolumeMappings(from dosdevices: URL) throws {
    let entries = try fileManager.contentsOfDirectory(
        at: dosdevices,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    )
    for entry in entries {
        let name = entry.lastPathComponent.lowercased()
        let isAutoLetter = name.range(of: "^[d-x]:{1,2}$", options: .regularExpression) != nil
            || name == "y::" || name == "z::"
        guard isAutoLetter else { continue }
        let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink == true else {
            throw ManagerError.message("兼容环境包含非链接的自动卷映射；已拒绝覆盖。")
        }
        try fileManager.removeItem(at: entry)
    }
}

private func prepareDirectInstallPrefix(
    _ destination: URL,
    runtime: (runtime: URL, wine: URL, environment: [String: String]),
    installRoot: URL,
    gameRoot: URL,
    product: ProductID,
    allowExistingPrefix: Bool
) throws {
    let windowsProductRoot = product == .mainland ? "IdentityV" : "IdentityVGlobal"
    let prefixExists = fileManager.fileExists(atPath: destination.path)
    if prefixExists {
        var metadata = stat()
        guard lstat(destination.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw ManagerError.message("未完成安装的兼容环境不是受管目录；已拒绝复用。")
        }
        guard allowExistingPrefix else {
            throw ManagerError.message("未完成安装的兼容环境不属于此目录；已拒绝复用。")
        }
    } else {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var environment = runtime.environment
        environment["WINEPREFIX"] = destination.path
        try runWine(runtime.wine, arguments: ["wineboot", "-i"], environment: environment)
    }
    var environment = runtime.environment
    environment["WINEPREFIX"] = destination.path
    let driveC = destination.appendingPathComponent("drive_c", isDirectory: true)
    try ensureRealDirectory(driveC, failure: "兼容环境的 C: 根目录不是受管真实目录；已拒绝复用。")
    let dosdevices = destination.appendingPathComponent("dosdevices", isDirectory: true)
    try ensureRealDirectory(dosdevices, failure: "兼容环境的盘符目录不是受管真实目录；已拒绝复用。")
    // Do not expose the macOS host root through Z:. A fresh private empty
    // directory is enough for Wine's drive bookkeeping; Y: is the only useful
    // host mount granted to this downloader prefix.
    let privateHostRoot = destination.appendingPathComponent("host-root", isDirectory: true)
    try ensureRealDirectory(privateHostRoot, failure: "兼容环境的私有宿主目录不是受管真实目录；已拒绝复用。")
    let games = driveC.appendingPathComponent("Games", isDirectory: true)
    try ensureRealDirectory(games, failure: "兼容环境的游戏映射目录不是受管真实目录；已拒绝复用。")

    let users = driveC.appendingPathComponent("users", isDirectory: true)
    try ensureRealDirectory(users, failure: "兼容环境的用户目录不是受管真实目录；已拒绝复用。")
    let accounts = (try? fileManager.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    var account: URL?
    for candidate in accounts where candidate.lastPathComponent.lowercased() != "public" && candidate.lastPathComponent.lowercased() != "default" {
        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0 else {
            throw ManagerError.message("无法检查兼容环境中的 Windows 用户目录。")
        }
        if (metadata.st_mode & S_IFMT) == S_IFLNK {
            throw ManagerError.message("兼容环境中的 Windows 用户目录是符号链接；已拒绝复用。")
        }
        if (metadata.st_mode & S_IFMT) == S_IFDIR { account = candidate; break }
    }
    if let account {
        try normalizeWineUserDirectoryBridges(account: account)
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"] {
            try ensureRealDirectory(
                account.appendingPathComponent(name, isDirectory: true),
                failure: "兼容环境中的 Windows 标准目录不是受管真实目录；已拒绝复用。"
            )
        }
    }
    // Keep the same input/DPI contract as the verified runner.  All writes
    // are inside this newly-created prefix.
    let driver = "HKCU\\Software\\Wine\\Mac Driver"
    for (key, value) in [
        ("RetinaMode", "Y"), ("LeftOptionIsAlt", "N"), ("RightOptionIsAlt", "N"),
        ("LeftCommandIsCtrl", "N"), ("RightCommandIsCtrl", "N"),
        ("UseConfinementCursorClipping", "Y"), ("CursorClippingLocksWindows", "Y")
    ] {
        try runWine(runtime.wine, arguments: ["reg", "add", driver, "/v", key, "/t", "REG_SZ", "/d", value, "/f"], environment: environment)
    }
    try runWine(runtime.wine, arguments: ["reg", "add", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers", "/v", "C:\\Games\\\(windowsProductRoot)\\dwrg.exe", "/t", "REG_SZ", "/d", "~ HIGHDPIAWARE", "/f"], environment: environment)
    try runWine(runtime.wine, arguments: ["reg", "add", "HKLM\\Software\\Wine\\Drives", "/v", directInstallDosDevice, "/t", "REG_SZ", "/d", "hd", "/f"], environment: environment)
    _ = try runTool(runtime.wine, arguments: ["cmd", "/c", "ver"], environment: environment)

    // Disk Arbitration callbacks are asynchronous. Stop the prefix server
    // before publishing final mappings so a late removable-volume callback
    // cannot replace them after this function returns.
    try stopPrefixWineServer(runtime: runtime, prefix: destination)
    try removeAutomaticVolumeMappings(from: dosdevices)
    try replaceLink(at: dosdevices.appendingPathComponent(directInstallDosDevice), destination: installRoot.path)
    try replaceLink(at: dosdevices.appendingPathComponent("z:"), destination: privateHostRoot.path)
    try replaceLink(at: games.appendingPathComponent(windowsProductRoot), destination: gameRoot.path)
}

/// Wine cannot translate an arbitrary Unix executable path after Z: has been
/// deliberately narrowed to a private empty directory.  Keep the verified
/// vendor core in this prefix's private C: instead: the Windows loader, its
/// sibling DLL and aria2 helper all resolve without exposing the host root or
/// a shared writable component directory to the Windows process.
private func prepareManagedDownloaderCore(
    componentDirectory: URL,
    prefix: URL,
    repairList: URL
) throws -> URL {
    let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
    var driveMetadata = stat()
    guard lstat(driveC.path, &driveMetadata) == 0,
          (driveMetadata.st_mode & S_IFMT) == S_IFDIR else {
        throw ManagerError.message("兼容环境的 C: 目录无效；已拒绝准备下载核心。")
    }

    let target = driveC.appendingPathComponent(managedDownloaderCoreDirectoryName, isDirectory: true)
    var targetMetadata = stat()
    if lstat(target.path, &targetMetadata) == 0 {
        guard (targetMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw ManagerError.message("兼容环境中的下载核心目标不是受管目录；已拒绝覆盖。")
        }
        try fileManager.removeItem(at: target)
    } else if errno != ENOENT {
        throw ManagerError.message("无法检查兼容环境中的下载核心目标。")
    }

    let staging = driveC.appendingPathComponent(".IdentityVDownloaderCore-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
    var committed = false
    defer { if !committed { try? fileManager.removeItem(at: staging) } }

    for name in managedDownloaderCoreFiles {
        let source = componentDirectory.appendingPathComponent(name, isDirectory: false)
        var sourceMetadata = stat()
        guard lstat(source.path, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw ManagerError.message("已验证的下载核心闭包不完整。")
        }
        let copied = staging.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: source, to: copied)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copied.path)
        guard try sha256(of: source) == sha256(of: copied) else {
            throw ManagerError.message("下载核心复制后摘要不一致。")
        }
    }

    var repairMetadata = stat()
    guard lstat(repairList.path, &repairMetadata) == 0,
          (repairMetadata.st_mode & S_IFMT) == S_IFREG else {
        throw ManagerError.message("游戏下载清单不是普通文件。")
    }
    let copiedRepairList = staging.appendingPathComponent(managedDownloaderRepairListName, isDirectory: false)
    try fileManager.copyItem(at: repairList, to: copiedRepairList)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copiedRepairList.path)
    guard try sha256(of: repairList) == sha256(of: copiedRepairList) else {
        throw ManagerError.message("游戏下载清单复制后摘要不一致。")
    }

    try fileManager.moveItem(at: staging, to: target)
    committed = true
    return target
}

private func removeManagedDownloaderCore(from prefix: URL) throws {
    let target = prefix
        .appendingPathComponent("drive_c", isDirectory: true)
        .appendingPathComponent(managedDownloaderCoreDirectoryName, isDirectory: true)
    var metadata = stat()
    guard lstat(target.path, &metadata) == 0 else {
        if errno == ENOENT { return }
        throw ManagerError.message("无法检查兼容环境中的临时下载核心。")
    }
    guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw ManagerError.message("兼容环境中的临时下载核心不是受管目录；已拒绝清理。")
    }
    try fileManager.removeItem(at: target)
}

private func directTransactionURL(_ workspace: DirectInstallWorkspace) -> URL {
    workspace.installRoot.appendingPathComponent(".identityv-direct-install.json")
}

private func writeDirectTransaction(_ workspace: DirectInstallWorkspace, phase: String, version: String) throws {
    let transaction = DirectInstallTransaction(schemaVersion: 1, product: "mainland", phase: phase, prefix: workspace.prefix.path, version: version)
    try JSONEncoder.pretty.encode(transaction).write(to: directTransactionURL(workspace), options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directTransactionURL(workspace).path)
}

private func directInstallFault(_ phase: String) throws {
    if ProcessInfo.processInfo.environment["IDENTITYV_TEST_FAIL_DIRECT_INSTALL_PHASE"] == phase {
        throw ManagerError.message("测试注入：安装在 \(phase) 阶段中断。")
    }
}

private func validateDirectTransaction(_ marker: DirectInstallTransaction, workspace: DirectInstallWorkspace, manifest: DirectManifestDocument) throws {
    guard marker.schemaVersion == 1, marker.product == "mainland",
          marker.prefix == workspace.prefix.path, marker.version == manifest.versionCode,
          marker.phase == "downloading" || marker.phase == "publishing" else {
        throw ManagerError.message("未完成安装的事务标记无效；未改动任何游戏文件。")
    }
}

/// Complete an interrupted publish only when the immutable evidence already
/// proves a valid final tree.  This never moves, deletes or overwrites the
/// final directory: incomplete states remain resumable staging states.
private func reconcileDirectInstall(
    workspace: DirectInstallWorkspace,
    manifest: DirectManifestDocument,
    state: inout ProductState
) throws -> Bool {
    let markerURL = directTransactionURL(workspace)
    guard fileManager.fileExists(atPath: markerURL.path) else { return false }
    guard let marker = try? JSONDecoder().decode(DirectInstallTransaction.self, from: Data(contentsOf: markerURL)) else {
        throw ManagerError.message("未完成安装的事务标记无效；未改动任何游戏文件。")
    }
    try validateDirectTransaction(marker, workspace: workspace, manifest: manifest)
    // A normal cancellation/network failure leaves this exact marker plus
    // `.staging`; it is deliberately resumable and must not enter the
    // publish-only evidence gate.
    if marker.phase == "downloading" { return false }
    guard fileManager.fileExists(atPath: workspace.finalRoot.path),
          !fileManager.fileExists(atPath: workspace.stagingRoot.path) else { return false }
    let gameLink = workspace.prefix.appendingPathComponent("drive_c/Games/IdentityV")
    let managedDriveLink = workspace.prefix.appendingPathComponent("dosdevices/\(directInstallDosDevice)")
    guard (try? fileManager.destinationOfSymbolicLink(atPath: gameLink.path)) == workspace.finalRoot.path,
          (try? fileManager.destinationOfSymbolicLink(atPath: managedDriveLink.path)) == workspace.installRoot.path,
          gameExecutable(in: workspace.finalRoot, validateHeader: true) != nil else {
        throw ManagerError.message("未完成安装的绑定证据不完整；未覆盖已有游戏目录。")
    }
    let manifestURL = workspace.work.appendingPathComponent("official-manifest.json")
    guard fileManager.fileExists(atPath: manifestURL.path),
          let persisted = try? JSONDecoder().decode(DirectManifestDocument.self, from: Data(contentsOf: manifestURL)),
          persisted == manifest else {
        throw ManagerError.message("未完成安装缺少已验证的官方清单；未覆盖已有游戏目录。")
    }
    let planner = executableDirectory().appendingPathComponent("IdentityVManifestPlanner")
    _ = try runTool(planner, arguments: ["verify", "--manifest", manifestURL.path, "--root", workspace.finalRoot.path])
    let installation = Installation(gameRoot: try makeLocation(workspace.finalRoot), prefix: try makeLocation(workspace.prefix), installer: nil, installedVersion: manifest.versionCode)
    try publishMainlandRunnerBinding(gameRoot: installation.gameRoot!, prefix: installation.prefix!)
    try directInstallFault("after-binding")
    state.installations[.mainland] = installation
    try save(state)
    try directInstallFault("after-state")
    try fileManager.removeItem(at: markerURL)
    return true
}

private func runSupervisorStreaming(
    _ executable: URL,
    task: URL,
    environment: [String: String],
    manifestBytes: Int64,
    reporter: DownloadProgressReporter?
) throws {
    let process = Process()
    let stdout = Pipe(); let stderr = Pipe()
    process.executableURL = executable
    process.arguments = ["run", "--task", task.path]
    process.environment = environment
    process.standardOutput = stdout; process.standardError = stderr
    var lineBuffer = Data()
    var diagnostics = Data()
    let lock = NSLock()
    stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        guard let reporter else { return }
        lock.lock(); defer { lock.unlock() }
        lineBuffer.append(data)
        if lineBuffer.count > 2 * 1_024 * 1_024 {
            lineBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = lineBuffer.firstIndex(of: 0x0a) {
            let line = Data(lineBuffer[..<newline]); lineBuffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(SupervisorProgressEvent.self, from: line) else { continue }
            let fraction = supervisorManifestFraction(progress: event.progress, manifestBytes: manifestBytes)
            reporter.emit(event: "progress", phase: "downloading", bytesWritten: Int64(Double(manifestBytes) * fraction), totalBytesExpected: manifestBytes)
        }
    }
    // The supervisor normally reserves stderr for diagnostics.  It must still
    // be drained while stdout progress is being parsed: waiting first can
    // deadlock when a verbose child fills either pipe.
    stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData; guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        appendBounded(data, to: &diagnostics, limit: 256 * 1_024)
    }
    // If the manager itself is asked to stop (for example the UI fallback
    // after a stalled cancel), forward only to this exact supervisor.  The Go
    // supervisor owns a separate process group and its context cleanup then
    // terminates the Wine/downloadIPC subtree before this function returns.
    let interruptLock = NSLock()
    var interrupted = false
    let oldTermHandler = signal(SIGTERM, SIG_IGN)
    let oldIntHandler = signal(SIGINT, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let forwardInterrupt = {
        interruptLock.lock(); interrupted = true; interruptLock.unlock()
        if process.isRunning { process.terminate() }
    }
    termSource.setEventHandler(handler: forwardInterrupt)
    intSource.setEventHandler(handler: forwardInterrupt)
    termSource.resume(); intSource.resume()
    defer {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        termSource.cancel(); intSource.cancel()
        signal(SIGTERM, oldTermHandler)
        signal(SIGINT, oldIntHandler)
    }
    try process.run()
    // A signal can arrive in the small interval before `run`; recheck after
    // spawning so that the exact child is still terminated in that case.
    interruptLock.lock(); let interruptedBeforeWait = interrupted; interruptLock.unlock()
    if interruptedBeforeWait, process.isRunning { process.terminate() }
    process.waitUntilExit()
    stdout.fileHandleForReading.readabilityHandler = nil
    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    stderr.fileHandleForReading.readabilityHandler = nil
    let trailingErrors = stderr.fileHandleForReading.readDataToEndOfFile()
    if !trailingErrors.isEmpty { lock.lock(); appendBounded(trailingErrors, to: &diagnostics, limit: 256 * 1_024); lock.unlock() }
    interruptLock.lock(); let wasInterrupted = interrupted; interruptLock.unlock()
    if wasInterrupted { throw ManagerError.message("游戏下载已取消；已请求收束下载进程。") }
    guard process.terminationStatus == 0 else {
        lock.lock(); let text = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
        throw ManagerError.message(text.isEmpty ? "游戏下载核心未正常完成。" : text)
    }
}

private func installDirectMainland(
    _ item: CatalogProduct,
    state: inout ProductState,
    destinationParent: String,
    reporter: DownloadProgressReporter
) throws {
    guard item.id == .mainland else { throw ManagerError.message("国际服完整下载 adapter 尚未完成验证。") }
    reporter.emit(event: "progress", phase: "resolving", bytesWritten: 0, totalBytesExpected: nil, force: true)
    let manifest = try resolveDirectManifest(for: item)
    let workspace = try directInstallWorkspace(product: .mainland, destinationParent: destinationParent)
    let needed = manifest.totalByteCount + 2 * 1_024 * 1_024 * 1_024
    guard try availableCapacity(at: workspace.finalRoot.deletingLastPathComponent()) >= needed else {
        throw ManagerError.message("所选位置空间不足：游戏本体约需 \(ByteCountFormatter.string(fromByteCount: manifest.totalByteCount, countStyle: .file))，另需保留约 2 GB 更新余量。")
    }
    let runtime = try ensureRuntime(reporter: reporter)
    try ensureSupportDirectory()
    let resumesExistingTransaction = fileManager.fileExists(atPath: directTransactionURL(workspace).path)
    if try reconcileDirectInstall(workspace: workspace, manifest: manifest, state: &state) {
        reporter.emit(event: "completed", phase: "completed", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
        return
    }
    try fileManager.createDirectory(at: workspace.installRoot, withIntermediateDirectories: true)
    try writeDirectTransaction(workspace, phase: "downloading", version: manifest.versionCode)
    try fileManager.createDirectory(at: workspace.work, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.work.path)
    try fileManager.createDirectory(at: workspace.stagingRoot, withIntermediateDirectories: true)
    reporter.emit(event: "progress", phase: "preparing", bytesWritten: 0, totalBytesExpected: manifest.totalByteCount, force: true)
    try prepareDirectInstallPrefix(
        workspace.prefix,
        runtime: runtime,
        installRoot: workspace.installRoot,
        gameRoot: workspace.stagingRoot,
        product: .mainland,
        allowExistingPrefix: resumesExistingTransaction
    )
    let gameLink = workspace.prefix.appendingPathComponent("drive_c/Games/IdentityV")
    let manifestURL = workspace.work.appendingPathComponent("official-manifest.json")
    let listURL = workspace.work.appendingPathComponent("repair-list.txt")
    let taskURL = workspace.work.appendingPathComponent("download-task.json")
    let controlURL = workspace.work.appendingPathComponent("download-control.json")
    try clearStaleDownloadControl(controlURL)
    try JSONEncoder.pretty.encode(manifest).write(to: manifestURL, options: [.atomic])
    try manifest.files.map(\.path).joined(separator: "\n").appending("\n").write(to: listURL, atomically: true, encoding: .utf8)
    let bootstrap = executableDirectory().appendingPathComponent("IdentityVDownloaderCoreBootstrap")
    let componentManifest = executableDirectory().appendingPathComponent("downloaderCoreComponent.json")
    let componentRoot = supportDirectory.appendingPathComponent("Components/netease-download-core", isDirectory: true)
    _ = try runTool(bootstrap, arguments: ["install", "--manifest", componentManifest.path, "--destination-root", componentRoot.path])
    let coreDirectory = componentRoot.appendingPathComponent("current").resolvingSymlinksInPath().standardizedFileURL
    let managedCoreDirectory = try prepareManagedDownloaderCore(
        componentDirectory: coreDirectory,
        prefix: workspace.prefix,
        repairList: listURL
    )
    var removeManagedCoreOnExit = true
    defer {
        if removeManagedCoreOnExit { try? removeManagedDownloaderCore(from: workspace.prefix) }
    }
    let downloadTask = DownloadTask(schemaVersion: 1, contentId: String(manifest.contentId), distributionId: String(manifest.distributionId), coreExecutable: managedCoreDirectory.appendingPathComponent("downloadIPC.exe").path, coreWorkingDirectory: managedCoreDirectory.path, wineExecutable: runtime.wine.path, winePrefix: workspace.prefix.path, downloadRootWindows: try relativeWindowsPath(workspace.stagingRoot, under: workspace.installRoot), repairListWindows: managedDownloaderRepairListWindowsPath, targetVersion: manifest.versionCode, originVersion: "", controlFile: controlURL.path)
    try JSONEncoder.pretty.encode(downloadTask).write(to: taskURL, options: [.atomic])
    let supervisor = executableDirectory().appendingPathComponent("IdentityVDownloadSupervisor")
    do {
        try runSupervisorStreaming(supervisor, task: taskURL, environment: runtime.environment, manifestBytes: manifest.totalByteCount, reporter: reporter)
        try stopPrefixWineServer(runtime: runtime, prefix: workspace.prefix)
    } catch {
        try? stopPrefixWineServer(runtime: runtime, prefix: workspace.prefix)
        throw error
    }
    try removeManagedDownloaderCore(from: workspace.prefix)
    removeManagedCoreOnExit = false
    reporter.emit(event: "progress", phase: "verifying", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
    let planner = executableDirectory().appendingPathComponent("IdentityVManifestPlanner")
    _ = try runTool(planner, arguments: ["verify", "--manifest", manifestURL.path, "--root", workspace.stagingRoot.path])
    reporter.emit(event: "progress", phase: "publishing", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
    try writeDirectTransaction(workspace, phase: "publishing", version: manifest.versionCode)
    try fileManager.moveItem(at: workspace.stagingRoot, to: workspace.finalRoot)
    try replaceLink(at: gameLink, destination: workspace.finalRoot.path)
    try directInstallFault("after-move")
    let installation = Installation(gameRoot: try makeLocation(workspace.finalRoot), prefix: try makeLocation(workspace.prefix), installer: nil, installedVersion: manifest.versionCode)
    try publishMainlandRunnerBinding(gameRoot: installation.gameRoot!, prefix: installation.prefix!)
    try directInstallFault("after-binding")
    state.installations[.mainland] = installation
    try save(state)
    try directInstallFault("after-state")
    try fileManager.removeItem(at: directTransactionURL(workspace))
    reporter.emit(event: "completed", phase: "completed", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
}

/// Resolve and download the global client through the separately bundled Go
/// adapter.  It validates API identity, every CDN URL and every MD5/XXH64
/// before atomically publishing the final tree; this manager never repurposes
/// the mainland downloader protocol for the international service.
private func installDirectGlobal(
    _ item: CatalogProduct,
    state: inout ProductState,
    destinationParent: String,
    reporter: DownloadProgressReporter
) throws {
    guard item.id == .global else { throw ManagerError.message("国际服 adapter 的产品身份不匹配。") }
    reporter.emit(event: "progress", phase: "resolving", bytesWritten: 0, totalBytesExpected: nil, force: true)
    let adapter = executableDirectory().appendingPathComponent("IdentityVGlobalAdapter")
    let raw = try runTool(adapter, arguments: ["resolve-manifest"])
    guard let manifest = try? JSONDecoder().decode(GlobalManifestDocument.self, from: Data(raw.utf8)),
          manifest.schemaVersion == 1, manifest.productId == .global,
          manifest.adapter == "netease-loadingbay-global-v1", manifest.startupPath == "dwrg.exe",
          manifest.totalByteCount > 0, !manifest.files.isEmpty else {
        throw ManagerError.message("国际服官方清单格式或身份未通过校验。")
    }
    let workspace = try directInstallWorkspace(product: .global, destinationParent: destinationParent)
    let needed = manifest.totalByteCount + 2 * 1_024 * 1_024 * 1_024
    guard try availableCapacity(at: workspace.finalRoot.deletingLastPathComponent()) >= needed else {
        throw ManagerError.message("所选位置空间不足：国际服本体约需 \(ByteCountFormatter.string(fromByteCount: manifest.totalByteCount, countStyle: .file))，另需保留约 2 GB 更新余量。")
    }
    try ensureSupportDirectory()
    try fileManager.createDirectory(at: workspace.installRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: workspace.work, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.work.path)
    let marker = workspace.installRoot.appendingPathComponent(".identityv-global-install.json")
    var resumesExistingTransaction = false
    if fileManager.fileExists(atPath: marker.path) {
        guard let raw = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              object["schemaVersion"] as? Int == 1, object["product"] as? String == "global",
              object["prefix"] as? String == workspace.prefix.path,
              object["version"] as? String == manifest.versionCode,
              let phase = object["phase"] as? String, phase == "downloading" || phase == "publishing" else {
            throw ManagerError.message("国际服未完成安装标记与当前官方版本不一致；已保留原目录，不能混合续传。请选择新目录或先在工具箱清除该受管安装。")
        }
        resumesExistingTransaction = true
        if phase == "downloading", fileManager.fileExists(atPath: workspace.finalRoot.path) {
            throw ManagerError.message("国际服下载事务状态矛盾：下载阶段已有正式目录；已拒绝覆盖。")
        }
        if try reconcileGlobalPublish(workspace: workspace, manifest: manifest, marker: marker, state: &state) {
            reporter.emit(event: "completed", phase: "completed", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
            return
        }
    }
    try JSONEncoder.pretty.encode(manifest).write(to: workspace.work.appendingPathComponent("official-global-manifest.json"), options: [.atomic])
    try Data("{\"schemaVersion\":1,\"product\":\"global\",\"phase\":\"downloading\",\"prefix\":\"\(workspace.prefix.path)\",\"version\":\"\(manifest.versionCode)\"}\n".utf8).write(to: marker, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    let runtime = try ensureRuntime(reporter: reporter)
    try prepareDirectInstallPrefix(
        workspace.prefix,
        runtime: runtime,
        installRoot: workspace.installRoot,
        gameRoot: workspace.stagingRoot,
        product: .global,
        allowExistingPrefix: resumesExistingTransaction
    )
    reporter.emit(event: "progress", phase: "downloading", bytesWritten: 0, totalBytesExpected: manifest.totalByteCount, force: true)
    // The adapter deliberately retains a failed/cancelled private stage and
    // never overwrites a final directory.  Its SIGTERM handler cancels its own
    // HTTP work; the manager is the only launched child, so UI cancellation
    // cannot reach either service's running Wine game.
    let control = workspace.work.appendingPathComponent("download-control.json")
    try clearStaleDownloadControl(control)
    try runGlobalAdapterStreaming(adapter, manifest: workspace.work.appendingPathComponent("official-global-manifest.json"), destination: workspace.stagingRoot, control: control, total: manifest.totalByteCount, reporter: reporter)
    guard gameExecutable(in: workspace.stagingRoot, validateHeader: true) != nil else {
        throw ManagerError.message("国际服下载完成后未找到有效 dwrg.exe；未发布游戏目录。")
    }
    reporter.emit(event: "progress", phase: "verifying", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
    try Data("{\"schemaVersion\":1,\"product\":\"global\",\"phase\":\"publishing\",\"prefix\":\"\(workspace.prefix.path)\",\"version\":\"\(manifest.versionCode)\"}\n".utf8).write(to: marker, options: [.atomic])
    try fileManager.moveItem(at: workspace.stagingRoot, to: workspace.finalRoot)
    try directInstallFault("global-after-move")
    try replaceLink(at: workspace.prefix.appendingPathComponent("drive_c/Games/IdentityVGlobal"), destination: workspace.finalRoot.path)
    try directInstallFault("global-after-link")
    let installation = Installation(gameRoot: try makeLocation(workspace.finalRoot), prefix: try makeLocation(workspace.prefix), installer: nil, installedVersion: manifest.versionCode)
    state.installations[.global] = installation
    try save(state)
    try directInstallFault("global-after-state")
    try fileManager.removeItem(at: marker)
    reporter.emit(event: "completed", phase: "completed", bytesWritten: manifest.totalByteCount, totalBytesExpected: manifest.totalByteCount, force: true)
}

private func reconcileGlobalPublish(workspace: DirectInstallWorkspace, manifest: GlobalManifestDocument, marker: URL, state: inout ProductState) throws -> Bool {
    guard let raw = try? Data(contentsOf: marker),
          let transaction = try? JSONDecoder().decode(GlobalTransactionMarker.self, from: raw),
          fileManager.fileExists(atPath: workspace.finalRoot.path), !fileManager.fileExists(atPath: workspace.stagingRoot.path) else { return false }
    let persisted = workspace.work.appendingPathComponent("official-global-manifest.json")
    let gameLink = workspace.prefix.appendingPathComponent("drive_c/Games/IdentityVGlobal")
    let currentTarget = try? fileManager.destinationOfSymbolicLink(atPath: gameLink.path)
    let managedDriveTarget = try? fileManager.destinationOfSymbolicLink(
        atPath: workspace.prefix.appendingPathComponent("dosdevices/\(directInstallDosDevice)").path
    )
    let zTarget = try? fileManager.destinationOfSymbolicLink(atPath: workspace.prefix.appendingPathComponent("dosdevices/z:").path)
    guard let stored = try? Data(contentsOf: persisted), let decoded = try? JSONDecoder().decode(GlobalManifestDocument.self, from: stored), decoded == manifest,
          gameExecutable(in: workspace.finalRoot, validateHeader: true) != nil else {
        throw ManagerError.message("国际服发布事务证据不完整；未覆盖现有目录。")
    }
    let recovery = try validateGlobalPublishEvidence(marker: transaction, workspace: workspace, version: manifest.versionCode, finalExists: true, stagingExists: false, cTarget: currentTarget, managedDriveTarget: managedDriveTarget, zTarget: zTarget)
    let adapter = executableDirectory().appendingPathComponent("IdentityVGlobalAdapter")
    _ = try runTool(adapter, arguments: ["verify-tree", "--manifest", persisted.path, "--destination", workspace.finalRoot.path])
    if recovery == .restoreLink { try replaceLink(at: gameLink, destination: workspace.finalRoot.path) }
    state.installations[.global] = Installation(gameRoot: try makeLocation(workspace.finalRoot), prefix: try makeLocation(workspace.prefix), installer: nil, installedVersion: manifest.versionCode)
    try save(state); try fileManager.removeItem(at: marker)
    return true
}

/// Global downloads are a single manager-owned child.  SIGTERM/SIGINT is
/// forwarded to that exact PID, whose Go signal context cancels outstanding
/// HTTP requests before it exits.  This is intentionally not a broad Wine or
/// `dwrg.exe` kill path.
private func runGlobalAdapterStreaming(_ adapter: URL, manifest: URL, destination: URL, control: URL, total: Int64, reporter: DownloadProgressReporter) throws {
    let process = Process(); let stderr = Pipe(); let stdout = Pipe()
    process.executableURL = adapter
    process.arguments = ["download", "--manifest", manifest.path, "--destination", destination.path, "--control", control.path]
    process.standardError = stderr; process.standardOutput = stdout
    var buffer = Data(); let lock = NSLock()
    stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData; guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }; appendBounded(data, to: &buffer, limit: 256 * 1_024)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let value = object["bytesWritten"] as? NSNumber else { continue }
            reporter.emit(event: "progress", phase: "downloading", bytesWritten: min(total, value.int64Value), totalBytesExpected: total)
        }
    }
    // The adapter currently writes progress to stderr, but stdout is still a
    // child-controlled pipe and has to be drained live as well.
    stdout.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    let interruptLock = NSLock()
    var interrupted = false
    let previousTerm = signal(SIGTERM, SIG_IGN); let previousInt = signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let cancel = {
        interruptLock.lock(); interrupted = true; interruptLock.unlock()
        if process.isRunning { process.terminate() }
    }
    term.setEventHandler(handler: cancel); intr.setEventHandler(handler: cancel); term.resume(); intr.resume()
    defer { stderr.fileHandleForReading.readabilityHandler = nil; stdout.fileHandleForReading.readabilityHandler = nil; term.cancel(); intr.cancel(); signal(SIGTERM, previousTerm); signal(SIGINT, previousInt) }
    try process.run()
    // Do not lose a cancellation delivered immediately before the child was
    // spawned; only this adapter PID is ever targeted.
    interruptLock.lock(); let interruptedBeforeWait = interrupted; interruptLock.unlock()
    if interruptedBeforeWait, process.isRunning { process.terminate() }
    process.waitUntilExit()
    stderr.fileHandleForReading.readabilityHandler = nil
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    stdout.fileHandleForReading.readabilityHandler = nil
    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    interruptLock.lock(); let wasInterrupted = interrupted; interruptLock.unlock()
    guard !wasInterrupted, process.terminationStatus == 0 else { throw ManagerError.message("国际服下载已取消或未完成；未发布游戏目录，可在同一位置继续。") }
}

/// The official LoadingBay manifest describes the base client.  Identity V can
/// legitimately replace a small engine set after the first launch; treating
/// those files as corrupt would downgrade a working client back to that base.
/// This is deliberately a *block*, not an ignore list: any other mismatch
/// still reaches the normal repair path, while an engine-version mismatch with
/// a syntactically valid live marker must be handled by the game's updater.
private func hasValidGameHotUpdateMarker(gameRoot: URL, repairPaths: [String]) -> Bool {
    guard repairPaths.contains("engine_version") else { return false }
    let marker = gameRoot.appendingPathComponent("engine_version").standardizedFileURL
    guard isDescendant(marker, of: gameRoot),
          let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let size = values.fileSize,
          size > 0, size <= 256,
          let data = try? Data(contentsOf: marker),
          let text = String(data: data, encoding: .utf8) else {
        return false
    }
    let pattern = #"^release_[0-9]{4}_[0-9]{4}:[0-9A-Fa-f]{40}\r?\n?$"#
    guard let range = text.range(of: pattern, options: .regularExpression) else { return false }
    return range == text.startIndex..<text.endIndex
}

private func repairExecutionDecision(summary: RepairPlanSummary, repairList: URL, gameRoot: URL) throws -> RepairExecutionDecision {
    if summary.repairs == 0, summary.valid { return .noDownload }
    let text = try String(contentsOf: repairList, encoding: .utf8)
    let paths = text.split(whereSeparator: \.isNewline).map(String.init)
    if hasValidGameHotUpdateMarker(gameRoot: gameRoot, repairPaths: paths) {
        return .blockForGameHotUpdate
    }
    return .download
}

private func runtimeCatalogLocation() -> URL {
    if let override = ProcessInfo.processInfo.environment["IDENTITYV_RUNTIME_CATALOG_PATH"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return executableDirectory().appendingPathComponent("runtime-catalog.json")
}

private let alpha1RuntimeEngineID = "wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1"

private func verifiedCatalogRuntime(engineID: String, runtime: URL) throws -> (wine: URL, environment: [String: String]) {
    guard let catalogData = try? Data(contentsOf: runtimeCatalogLocation()),
          let catalog = try? JSONDecoder().decode(LegacyRuntimeCatalog.self, from: catalogData),
          catalog.schemaVersion == 1,
          let engine = catalog.engines[engineID],
          engine.launchProfile == "codeweavers-wine-release-dxmt",
          !engine.verificationFiles.isEmpty else {
        throw ManagerError.message("当前 Wine 运行时未通过下载核心的实测兼容性验证，已拒绝修复。")
    }
    let wine = runtime.appendingPathComponent(engine.executablePaths.wine).resolvingSymlinksInPath().standardizedFileURL
    let wineserver = runtime.appendingPathComponent(engine.executablePaths.wineserver).resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(wine, of: runtime), isDescendant(wineserver, of: runtime),
          fileManager.isExecutableFile(atPath: wine.path), fileManager.isExecutableFile(atPath: wineserver.path) else {
        throw ManagerError.message("当前 Wine 运行时缺少可执行的 wine/wineserver，已拒绝修复。")
    }
    for file in engine.verificationFiles.values {
        guard let relativePath = file.relativePath, let expectedSHA = file.sha256,
              !relativePath.isEmpty,
              expectedSHA.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else {
            throw ManagerError.message("当前 Wine 运行时验证清单不完整，已拒绝使用。")
        }
        let item = runtime.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(item, of: runtime), fileManager.isReadableFile(atPath: item.path),
              try sha256(of: item).caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw ManagerError.message("当前 Wine 运行时关键文件校验失败，已拒绝建立新安装。")
        }
    }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "\(runtime.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
    environment["CX_ROOT"] = runtime.path; environment["WINELOADER"] = wine.path; environment["WINESERVER"] = wineserver.path
    environment["WINEDLLPATH"] = runtime.appendingPathComponent("lib/wine").path; environment["DYLD_FALLBACK_LIBRARY_PATH"] = runtime.appendingPathComponent("lib64").path
    environment["WINEDEBUG"] = "-all"; environment["WINEDLLOVERRIDES"] = "mscoree,mshtml="; environment["MallocNanoZone"] = "0"; environment["LANG"] = "C.UTF-8"; environment["LC_ALL"] = "C.UTF-8"
    return (wine, environment)
}

/// Resolve only the selected runtime and re-verify every critical catalogue
/// hash.  Direct installs never borrow an old game's runtime/prefix binding.
private func selectedRuntimeForDirectInstall() throws -> (runtime: URL, wine: URL, environment: [String: String]) {
    guard let data = try? Data(contentsOf: runtimeBindingURL),
          let binding = try? JSONDecoder().decode(RuntimeBinding.self, from: data),
          binding.schemaVersion == 1,
          binding.selectedEngineId == alpha1RuntimeEngineID,
          let runtime = resolve(binding.runtime) else {
        throw ManagerError.message("Wine 运行时尚未完成准备或校验失败。")
    }
    let verified = try verifiedCatalogRuntime(engineID: binding.selectedEngineId, runtime: runtime)
    return (runtime, verified.wine, verified.environment)
}

private func runtimeIsAvailable() -> Bool { (try? selectedRuntimeForDirectInstall()) != nil }

private func saveRuntimeBinding(_ binding: RuntimeBinding) throws {
    try ensureSupportDirectory()
    let temporary = supportDirectory.appendingPathComponent(".runtime-binding-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try JSONEncoder.pretty.encode(binding).write(to: temporary, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try atomicallyReplace(temporary, with: runtimeBindingURL)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeBindingURL.path)
}

private func runRuntimeBootstrapStreaming(_ bootstrap: URL, manifest: URL, destination: URL, patches: URL, reporter: DownloadProgressReporter) throws {
    let process = Process(); let stderr = Pipe(); let stdout = Pipe()
    process.executableURL = bootstrap
    process.arguments = ["install", "--manifest", manifest.path, "--destination-root", destination.path, "--patch-root", patches.path]
    process.standardError = stderr; process.standardOutput = stdout
    var output = Data(); var buffer = Data(); let lock = NSLock()
    stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData; guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }; output.append(data); buffer.append(data)
        while let index = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<index], as: UTF8.self); buffer.removeSubrange(...index)
            var fields: [String: String] = [:]
            for field in line.split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard fields["stage"] == "download", let bytes = Int64(fields["bytes"] ?? ""), let total = Int64(fields["total"] ?? "") else { continue }
            reporter.emit(event: "progress", phase: "runtime", bytesWritten: bytes, totalBytesExpected: total)
        }
    }
    // The helper currently writes progress on stderr, but retain a reader on
    // stdout too: a future diagnostic line must not fill an unread pipe and
    // make cancellation appear to hang.
    stdout.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    let interruptLock = NSLock()
    var interrupted = false
    let oldTermHandler = signal(SIGTERM, SIG_IGN)
    let oldIntHandler = signal(SIGINT, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let forwardInterrupt = {
        interruptLock.lock(); interrupted = true; interruptLock.unlock()
        // Deliberately target only the bootstrap child.  Its own signal
        // context closes the HTTP request and unwinds the mounted-DMG stage.
        if process.isRunning { process.terminate() }
    }
    termSource.setEventHandler(handler: forwardInterrupt)
    intSource.setEventHandler(handler: forwardInterrupt)
    termSource.resume(); intSource.resume()
    defer {
        stderr.fileHandleForReading.readabilityHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        termSource.cancel(); intSource.cancel()
        signal(SIGTERM, oldTermHandler)
        signal(SIGINT, oldIntHandler)
    }
    reporter.emit(event: "progress", phase: "runtime", bytesWritten: 0, totalBytesExpected: nil, force: true)
    try process.run()
    interruptLock.lock(); let interruptedBeforeRun = interrupted; interruptLock.unlock()
    if interruptedBeforeRun, process.isRunning { process.terminate() }
    process.waitUntilExit()
    // Drain the tail after process exit; readability handlers are edge based
    // and may otherwise miss the final short diagnostic line.
    stderr.fileHandleForReading.readabilityHandler = nil
    let trailing = stderr.fileHandleForReading.readDataToEndOfFile()
    if !trailing.isEmpty { lock.lock(); output.append(trailing); lock.unlock() }
    stdout.fileHandleForReading.readabilityHandler = nil
    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    interruptLock.lock(); let wasInterrupted = interrupted; interruptLock.unlock()
    if wasInterrupted { throw ManagerError.message("Wine 运行时准备已取消；临时下载与挂载已收束。") }
    guard process.terminationStatus == 0 else {
        lock.lock(); let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
        throw ManagerError.message(text.isEmpty ? "Wine 运行时准备失败。" : text)
    }
}

/// Bootstrap on first use, then bind only the fully verified `current` runtime.
/// This leaves no partial game binding behind if the 327MB upstream download is
/// interrupted or rejected.
private func ensureRuntime(reporter: DownloadProgressReporter) throws -> (runtime: URL, wine: URL, environment: [String: String]) {
    if let existing = try? selectedRuntimeForDirectInstall() { return existing }
    let bootstrap = executableDirectory().appendingPathComponent("IdentityVRuntimeBootstrap")
    let manifest = executableDirectory().appendingPathComponent("runtime-manifest.json")
    let patches = executableDirectory().appendingPathComponent("RuntimePatches")
    guard fileManager.isExecutableFile(atPath: bootstrap.path), fileManager.isReadableFile(atPath: manifest.path),
          (try? patches.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw ManagerError.message("工具箱缺少 Wine runtime bootstrap 组件，请重新安装。")
    }
    let componentRoot = supportDirectory.appendingPathComponent("Components/wine-runtime", isDirectory: true)
    try ensureSupportDirectory()
    try runRuntimeBootstrapStreaming(bootstrap, manifest: manifest, destination: componentRoot, patches: patches, reporter: reporter)
    let current = componentRoot.appendingPathComponent("current").resolvingSymlinksInPath().standardizedFileURL
    let binding = RuntimeBinding(schemaVersion: 1, selectedEngineId: alpha1RuntimeEngineID, runtime: try makeLocation(current))
    try saveRuntimeBinding(binding)
    let verified = try selectedRuntimeForDirectInstall()
    reporter.emit(event: "progress", phase: "runtime", bytesWritten: 1, totalBytesExpected: 1, force: true)
    return verified
}

private func activeLegacyRuntime(for installation: Installation) throws -> (runtime: URL, prefix: URL, wine: URL, environment: [String: String]) {
    guard let binding = legacyBinding(), binding.gameRoot == installation.gameRoot, binding.prefix == installation.prefix,
          let prefix = resolve(binding.prefix), let runtime = resolve(binding.runtime) else {
        throw ManagerError.message("当前产品没有可验证的 Wine prefix 绑定；为避免写入错误目录，已拒绝修复。")
    }
    let verified = try verifiedCatalogRuntime(engineID: binding.selectedEngineId, runtime: runtime)
    return (runtime, prefix, verified.wine, verified.environment)
}

/// The app runner already validates this document against its bundled catalog:
/// volume UUID + relative paths, runtime hashes, executable paths and the
/// prefix/game-root binding are all checked before Wine starts.  The manager
/// therefore only replaces a complete candidate binding after a verified
/// publish, never edits a selected field in place.
private func publishMainlandRunnerBinding(gameRoot: ManagedLocation, prefix: ManagedLocation) throws {
    guard !gameIsRunning() else {
        throw ManagerError.message("游戏仍在运行，不能切换其启动绑定。请结束游戏后重试。")
    }
    guard let data = try? Data(contentsOf: runtimeBindingURL),
          let runtimeBinding = try? JSONDecoder().decode(RuntimeBinding.self, from: data),
          runtimeBinding.schemaVersion == 1,
          runtimeBinding.selectedEngineId == alpha1RuntimeEngineID,
          runtimeIsAvailable() else {
        throw ManagerError.message("当前 Wine runtime 绑定不可用；未发布游戏启动配置。")
    }
    let engine = LegacyInstallationEngine(gameRoot: gameRoot, prefix: prefix, runtime: runtimeBinding.runtime)
    let document = LegacyInstallationDocument(schemaVersion: 1, selectedEngineId: runtimeBinding.selectedEngineId, lastKnownGoodEngineId: runtimeBinding.selectedEngineId, engines: [runtimeBinding.selectedEngineId: engine])
    let candidate = legacyURL.deletingLastPathComponent().appendingPathComponent(".installation-\(UUID().uuidString).candidate")
    defer { try? fileManager.removeItem(at: candidate) }
    try JSONEncoder.pretty.encode(document).write(to: candidate, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
    // Decode the candidate again before the atomic rename. Runtime hash and
    // prefix-game binding remain enforced by launchIdentityVRunner preflight.
    guard let check = try? JSONDecoder().decode(LegacyInstallationDocument.self, from: Data(contentsOf: candidate)),
          check.schemaVersion == 1,
          check.engines[check.selectedEngineId]?.gameRoot == gameRoot,
          check.engines[check.selectedEngineId]?.prefix == prefix else {
        throw ManagerError.message("新的启动绑定格式无效。")
    }
    try atomicallyReplace(candidate, with: legacyURL)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)
}

private func repairManagedProduct(_ item: CatalogProduct, product: ProductID, state: inout ProductState) throws -> String {
    guard let installation = state.installations[product], let gameRootLocation = installation.gameRoot,
          let gameRoot = resolve(gameRootLocation), gameExecutable(in: gameRoot) != nil else {
        throw ManagerError.message("未找到可验证的\(item.displayName)游戏目录；请重新连接原磁盘或导入客户端。")
    }
    if product == .global {
        // A global repair is entirely adapter-owned: it re-resolves LoadingBay
        // metadata, stages every replacement with MD5+XXH64, then atomically
        // publishes.  It never invokes the mainland downloadIPC protocol.
        guard mayControlRunningGame(for: .global, state: state) else {
            throw ManagerError.message("国际服记录与独立 prefix 绑定不一致；为避免写入正在运行或不属于此产品的目录，已拒绝扫描修复。")
        }
        if managedGlobalGamePID() != nil {
            _ = try stopManagedGame(for: .global, state: state)
        } else if anyGlobalGameProcessIsRunning() {
            throw ManagerError.message("检测到未由启动器创建的国际服 Wine 会话；为避免写入运行中的客户端，未扫描修复。请先手动结束该会话后重试。")
        }
        let adapter = executableDirectory().appendingPathComponent("IdentityVGlobalAdapter")
        let raw = try runTool(adapter, arguments: ["resolve-manifest"])
        guard let manifest = try? JSONDecoder().decode(GlobalManifestDocument.self, from: Data(raw.utf8)),
              manifest.schemaVersion == 1, manifest.productId == .global,
              manifest.adapter == "netease-loadingbay-global-v1", manifest.startupPath == "dwrg.exe",
              manifest.totalByteCount > 0, !manifest.files.isEmpty else {
            throw ManagerError.message("国际服官方清单格式或身份未通过校验。")
        }
        let work = try repairWorkDirectory(for: .global)
        let manifestURL = work.appendingPathComponent("official-global-manifest.json")
        try JSONEncoder.pretty.encode(manifest).write(to: manifestURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        let result = try runTool(adapter, arguments: ["repair", "--manifest", manifestURL.path, "--destination", gameRoot.path])
        guard let summaryLine = result.split(whereSeparator: \.isNewline).last,
              let summary = try? JSONDecoder().decode(RepairPlanSummary.self, from: Data(summaryLine.utf8)),
              summary.valid else {
            throw ManagerError.message("国际服完整性修复没有返回可验证的结果。")
        }
        var updated = installation; updated.installedVersion = manifest.versionCode
        state.installations[.global] = updated; try save(state)
        return summary.repairs == 0
            ? "\(item.displayName)完整性扫描完成：\(manifest.files.count) 个文件均通过校验，无需下载。"
            : "\(item.displayName)已修复 \(summary.repairs) 个文件，并已通过完整性复验。"
    }
    if gameIsRunning() {
        guard mayControlRunningGame(for: product, state: state) else {
            throw ManagerError.message("该服游戏仍在运行，但当前记录无法安全确认其进程归属；请先结束游戏后再扫描修复。")
        }
        _ = try stopManagedGame(for: product, state: state)
    }
    let runtime = try activeLegacyRuntime(for: installation)
    let manifest = try resolveDirectManifest(for: item)
    let work = try repairWorkDirectory(for: product)
    let manifestURL = work.appendingPathComponent("official-manifest.json")
    let repairURL = work.appendingPathComponent("repair-list.txt")
    let taskURL = work.appendingPathComponent("download-task.json")
    let controlURL = work.appendingPathComponent("download-control.json")
    try clearStaleDownloadControl(controlURL)
    try JSONEncoder.pretty.encode(manifest).write(to: manifestURL, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    let planner = executableDirectory().appendingPathComponent("IdentityVManifestPlanner")
    let planned = try runTool(planner, arguments: ["plan", "--manifest", manifestURL.path, "--root", gameRoot.path, "--repair-list", repairURL.path])
    // Planner progress is deliberately JSONL on stderr; `runTool` combines
    // streams so the final stdout summary is the last non-empty JSON line.
    guard let summaryLine = planned.split(whereSeparator: \.isNewline).last,
          let summary = try? JSONDecoder().decode(RepairPlanSummary.self, from: Data(summaryLine.utf8)) else {
        throw ManagerError.message("完整性扫描没有返回可验证的结果。")
    }
    switch try repairExecutionDecision(summary: summary, repairList: repairURL, gameRoot: gameRoot) {
    case .noDownload:
        var updated = installation
        updated.installedVersion = manifest.versionCode
        state.installations[product] = updated
        try save(state)
        return "\(item.displayName)完整性扫描完成：\(manifest.files.count) 个文件均通过校验，无需下载。"
    case .blockForGameHotUpdate:
        throw ManagerError.message("检测到第五人格游戏内热更新的有效 engine_version 标记。当前官方基础 manifest 会把这批正常更新误判为缺损；为避免回退客户端，启动器未下载也未写入。请先使用游戏自身的更新/修复流程，或等待后续 patch adapter。")
    case .download:
        break
    }
    let bootstrap = executableDirectory().appendingPathComponent("IdentityVDownloaderCoreBootstrap")
    let componentManifest = executableDirectory().appendingPathComponent("downloaderCoreComponent.json")
    let componentRoot = supportDirectory.appendingPathComponent("Components/netease-download-core", isDirectory: true)
    _ = try runTool(bootstrap, arguments: ["install", "--manifest", componentManifest.path, "--destination-root", componentRoot.path])
    let coreDirectory = componentRoot.appendingPathComponent("current").resolvingSymlinksInPath().standardizedFileURL
    let managedCoreDirectory = try prepareManagedDownloaderCore(
        componentDirectory: coreDirectory,
        prefix: runtime.prefix,
        repairList: repairURL
    )
    var removeManagedCoreOnExit = true
    defer {
        if removeManagedCoreOnExit { try? removeManagedDownloaderCore(from: runtime.prefix) }
    }
    let gameRootWindows = try repairGameWindowsPath(gameRoot: gameRoot, prefix: runtime.prefix)
    let downloadTask = DownloadTask(
        schemaVersion: 1, contentId: String(manifest.contentId), distributionId: String(manifest.distributionId),
        coreExecutable: managedCoreDirectory.appendingPathComponent("downloadIPC.exe").path,
        coreWorkingDirectory: managedCoreDirectory.path,
        wineExecutable: runtime.wine.path, winePrefix: runtime.prefix.path,
        downloadRootWindows: gameRootWindows,
        repairListWindows: managedDownloaderRepairListWindowsPath,
        targetVersion: manifest.versionCode, originVersion: installation.installedVersion ?? "", controlFile: controlURL.path
    )
    try JSONEncoder.pretty.encode(downloadTask).write(to: taskURL, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskURL.path)
    let supervisor = executableDirectory().appendingPathComponent("IdentityVDownloadSupervisor")
    let stopRuntime = (runtime: runtime.runtime, wine: runtime.wine, environment: runtime.environment)
    do {
        try runSupervisorStreaming(
            supervisor,
            task: taskURL,
            environment: runtime.environment,
            manifestBytes: manifest.totalByteCount,
            reporter: nil
        )
        try stopPrefixWineServer(runtime: stopRuntime, prefix: runtime.prefix)
    } catch {
        try? stopPrefixWineServer(runtime: stopRuntime, prefix: runtime.prefix)
        throw error
    }
    try removeManagedDownloaderCore(from: runtime.prefix)
    removeManagedCoreOnExit = false
    _ = try runTool(planner, arguments: ["verify", "--manifest", manifestURL.path, "--root", gameRoot.path])
    var updated = installation
    updated.installedVersion = manifest.versionCode
    state.installations[product] = updated
    try save(state)
    return "\(item.displayName)已修复 \(summary.repairs) 个文件，并已通过完整性复验。"
}

private func validateProductReadyForLaunch(
    _ item: CatalogProduct,
    product: ProductID,
    state: ProductState
) throws {
    let current = status(for: item, state: state)
    guard current.state == "ready" else {
        throw ManagerError.message("\(item.displayName)尚未就绪：\(current.detail ?? "请先安装或修复。")")
    }
    if product == .mainland {
        guard let installation = state.installations[.mainland],
              let legacy = legacyBinding(), installation.gameRoot == legacy.gameRoot,
              installation.prefix == legacy.prefix else {
            throw ManagerError.message("国服记录与当前启动壳的实际绑定不一致；为防止启动到错误目录，已拒绝执行。")
        }
    }
}

private func canExecuteIntelCode() throws -> Bool {
    let process = Process()
    let finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
    process.arguments = ["-x86_64", "/usr/bin/true"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + 5) == .success else {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw ManagerError.message("无法及时确认 Rosetta 的运行状态，请稍后重试。错误代码：IDV-ENV-104")
    }
    return process.terminationStatus == 0
}

private func requireRuntimePrerequisites(
    majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    intelExecutionProbe: () throws -> Bool = canExecuteIntelCode
) throws {
    guard majorVersion >= 15 else {
        throw ManagerError.message("当前游戏运行环境需要 macOS 15 或更新版本，请先更新系统。错误代码：IDV-ENV-102")
    }
    guard try intelExecutionProbe() else {
        throw ManagerError.message("本游戏需要 Apple Rosetta 兼容组件。点击“安装 Rosetta”打开 Apple 的系统安装器，按提示完成后，回到启动器再次点击原来的按钮即可继续。错误代码：IDV-ENV-101")
    }
}

private func run(_ command: String, product: ProductID) throws {
    // Check before acquiring the mutation lock or starting a network request.
    // Both the GUI and direct manager calls use this same prerequisite gate.
    if ["install", "import", "prepare-launch", "launch", "restart", "repair"].contains(command) {
        try requireRuntimePrerequisites()
    }
    try withMutationLock {
        var state = try loadState(); let catalog = try loadCatalog()
        guard let item = catalog.products.first(where: { $0.id == product }) else { throw ManagerError.message("未知产品。") }
        switch command {
    case "select":
        state.selectedProductId = product
        try save(state)
        print("已选择\(item.displayName)。")
    case "install":
        let reporter = DownloadProgressReporter(product: product)
        guard let destinationParent = argument(after: "--destination-parent") else {
            throw ManagerError.message("安装游戏需要 --destination-parent <文件夹>。")
        }
        if product == .mainland {
            try installDirectMainland(item, state: &state, destinationParent: destinationParent, reporter: reporter)
        } else {
            try installDirectGlobal(item, state: &state, destinationParent: destinationParent, reporter: reporter)
        }
        print("\(item.displayName)游戏本体已安装并校验完成。")
    case "import":
        guard let raw = argument(after: "--path") else { throw ManagerError.message("导入需要 --path <客户端目录>。") }
        let root = URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ManagerError.message("所选路径不是可读取的客户端目录。")
        }
        guard gameExecutable(in: root, validateHeader: true) != nil else { throw ManagerError.message("所选目录未找到有效的 dwrg.exe。") }
        let location = try makeLocation(root)
        var installation = state.installations[product] ?? Installation()
        installation.gameRoot = location
        // A product must not borrow another product's prefix.  The wake-time installer creates it.
        installation.prefix = nil
        state.installations[product] = installation; try save(state)
        print("已导入\(item.displayName)游戏文件；尚未创建独立兼容环境，请完成安装后修复。")
    case "prepare-launch":
        try validateProductReadyForLaunch(item, product: product, state: state)
        let app = try embeddedGameRunnerApp()
        let detail = try preflightEmbeddedGameRunner(product: product, runner: app)
        print(detail.isEmpty ? "\(item.displayName)启动前检查已通过。" : detail)
    case "launch", "restart":
        try validateProductReadyForLaunch(item, product: product, state: state)
        let app = try embeddedGameRunnerApp()
        // Run the helper bundle's shell runner directly.  Its ordinary entry
        // point detaches into `--run` before Wine starts, so the game owns its
        // native AppKit foreground/focus lifecycle instead of inheriting an
        // LSUIElement LaunchServices wrapper.
        _ = try preflightEmbeddedGameRunner(product: product, runner: app)
        if command == "restart" {
            _ = try stopManagedGame(for: product, state: state)
        }
        let process = Process()
        process.executableURL = try embeddedGameRunnerExecutable(runner: app)
        process.arguments = embeddedGameRunnerArguments(product: product)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManagerError.message("macOS 未能启动内嵌游戏运行器（退出码 \(process.terminationStatus)）。")
        }
        guard waitForManagedGameStart(product: product) else {
            throw ManagerError.message("游戏运行器已收到请求，但 20 秒内没有出现可验证的游戏进程；未报告为启动成功。")
        }
        print(command == "restart" ? "已重启\(item.displayName)；IDV Login 保持运行。" : "已启动\(item.displayName)。")
    case "stop":
        let result = try stopManagedGame(for: product, state: state)
        print(result.isEmpty ? "已结束\(item.displayName)游戏进程；IDV Login 保持运行。" : result)
    case "remove":
        // An unverified product has no trusted process identity yet.  It may
        // still have downloaded/imported files that the player wants removed;
        // do not turn that cleanup into a false claim over the other product's
        // process.
        if mayControlRunningGame(for: product, state: state) {
            _ = try stopManagedGame(for: product, state: state)
        }
        print(try removeManagedProductFiles(product, state: &state))
    case "repair":
        print(try repairManagedProduct(item, product: product, state: &state))
        default: throw ManagerError.message("不支持的操作：\(command)")
        }
    }
}

private func makeLocation(_ url: URL) throws -> ManagedLocation {
    let canonical = try canonicalExistingURL(url)
    let values = try canonical.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .isDirectoryKey])
    guard values.isDirectory == true, let uuid = values.volumeUUIDString, let rawVolume = values.volume else {
        throw ManagerError.message("无法读取所选目录所在磁盘的 UUID。")
    }
    let volume = rawVolume.resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(canonical, of: volume) else { throw ManagerError.message("客户端目录逃出了所选磁盘。") }
    let relative = canonical.path.dropFirst(volume.path == "/" ? 1 : volume.path.count + 1)
    guard !relative.isEmpty else { throw ManagerError.message("不能将整块磁盘作为游戏目录。") }
    return ManagedLocation(volumeUUID: uuid, relativePath: String(relative))
}

private func argument(after key: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private func isAllowedHost(_ rawHost: String, suffixes: [String]) -> Bool {
    let host = rawHost.lowercased()
    return suffixes.contains { rawSuffix in
        let suffix = rawSuffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == suffix || host.hasSuffix("." + suffix)
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    let allowedHostSuffixes: [String]
    init(allowedHostSuffixes: [String]) { self.allowedHostSuffixes = allowedHostSuffixes }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let requestHost = url.host,
              isAllowedHost(requestHost, suffixes: allowedHostSuffixes) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private final class InstallerDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let allowedHostSuffixes: [String]
    private let reporter: DownloadProgressReporter
    private let maximumSize: Int64
    private let stagingURL: URL
    private let completion: (Result<(URL, HTTPURLResponse), Error>) -> Void
    private var downloadedURL: URL?
    private var validationError: Error?

    init(
        allowedHostSuffixes: [String],
        reporter: DownloadProgressReporter,
        maximumSize: Int64,
        stagingURL: URL,
        completion: @escaping (Result<(URL, HTTPURLResponse), Error>) -> Void
    ) {
        self.allowedHostSuffixes = allowedHostSuffixes
        self.reporter = reporter
        self.maximumSize = maximumSize
        self.stagingURL = stagingURL
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host,
              isAllowedHost(host, suffixes: allowedHostSuffixes) else {
            validationError = ManagerError.message("官方下载重定向不在允许的下载域名内。")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize {
            validationError = ManagerError.message("官方安装器下载超过 1 GiB 安全上限。")
            downloadTask.cancel()
            return
        }
        let expected = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        reporter.emit(event: "progress", phase: "downloading", bytesWritten: totalBytesWritten, totalBytesExpected: expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // URLSession only guarantees `location` for the duration of this
            // callback.  Move it immediately to a private OS-temporary path;
            // it does not enter the managed Downloads directory until every
            // PE, size and hash check has succeeded.
            try FileManager.default.moveItem(at: location, to: stagingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            downloadedURL = stagingURL
        } catch {
            validationError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let validationError {
            completion(.failure(validationError))
            return
        }
        if let error {
            completion(.failure(error))
            return
        }
        guard let downloadedURL,
              let response = task.response as? HTTPURLResponse else {
            completion(.failure(ManagerError.message("下载没有返回文件。")))
            return
        }
        completion(.success((downloadedURL, response)))
    }
}

private func officialDownloadURL(for item: CatalogProduct) throws -> URL {
    guard let resolver = URL(string: item.resolverURL), resolver.scheme?.lowercased() == "https", let resolverHost = resolver.host else {
        throw ManagerError.message("官方解析地址无效。")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let delegate = RedirectDelegate(allowedHostSuffixes: [resolverHost])
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, URLResponse), Error>?
    session.dataTask(with: resolver) { data, response, error in
        defer { semaphore.signal() }
        if let error { result = .failure(error) }
        else if let data, let response { result = .success((data, response)) }
        else { result = .failure(ManagerError.message("官方解析没有返回地址。")) }
    }.resume()
    semaphore.wait()
    session.finishTasksAndInvalidate()
    guard let result else { throw ManagerError.message("官方解析没有完成。") }
    let resolvedResponse = try result.get()
    guard let http = resolvedResponse.1 as? HTTPURLResponse,
          let finalResolverURL = http.url,
          finalResolverURL.scheme?.lowercased() == "https",
          let finalResolverHost = finalResolverURL.host,
          isAllowedHost(finalResolverHost, suffixes: [resolverHost]),
          resolvedResponse.0.count <= 8_192 else {
        throw ManagerError.message("官方解析响应未通过校验。")
    }
    let resolved: URL?
    if (300...399).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") {
        resolved = URL(string: location, relativeTo: finalResolverURL)?.absoluteURL
    } else if (200...299).contains(http.statusCode) {
        let resolvedText = String(decoding: resolvedResponse.0, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        resolved = URL(string: resolvedText)
    } else {
        resolved = nil
    }
    guard let resolved, resolved.scheme?.lowercased() == "https",
          let finalHost = resolved.host,
          isAllowedHost(finalHost, suffixes: item.allowedFinalHostSuffixes) else {
        throw ManagerError.message("官方解析结果不在允许的下载域名内。")
    }
    return resolved
}

private func loadingBayURL(
    origin rawOrigin: String,
    path: String,
    distributionId: Int,
    forceFreshLauncherData: Bool = false
) throws -> (URL, String) {
    guard distributionId > 0,
          let origin = URL(string: rawOrigin),
          origin.scheme?.lowercased() == "https",
          let host = origin.host,
          origin.user == nil,
          origin.password == nil,
          origin.query == nil,
          origin.fragment == nil,
          origin.path.isEmpty || origin.path == "/",
          var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
        throw ManagerError.message("国服官方下载元数据地址无效。")
    }
    components.path = path
    components.queryItems = (
        forceFreshLauncherData ? [URLQueryItem(name: "force", value: "1")] : []
    ) + [URLQueryItem(name: "app_id", value: String(distributionId))]
    guard let url = components.url,
          url.scheme?.lowercased() == "https",
          url.host?.caseInsensitiveCompare(host) == .orderedSame else {
        throw ManagerError.message("无法构造国服官方下载元数据请求。")
    }
    return (url, host)
}

private func fetchLoadingBayJSON<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    expectedHost: String,
    channel: String
) throws -> Value {
    guard channel.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
        throw ManagerError.message("国服官方下载渠道标识无效。")
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.setValue(channel, forHTTPHeaderField: "channel")
    request.setValue("", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = RedirectDelegate(allowedHostSuffixes: [expectedHost])
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, URLResponse), Error>?
    session.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error { result = .failure(error) }
        else if let data, let response { result = .success((data, response)) }
        else { result = .failure(ManagerError.message("国服官方下载元数据没有返回内容。")) }
    }.resume()
    semaphore.wait()
    session.finishTasksAndInvalidate()

    guard let result else { throw ManagerError.message("国服官方下载元数据请求没有完成。") }
    let response = try result.get()
    guard let http = response.1 as? HTTPURLResponse,
          (200...299).contains(http.statusCode),
          let finalURL = http.url,
          finalURL.scheme?.lowercased() == "https",
          let finalHost = finalURL.host,
          finalHost.caseInsensitiveCompare(expectedHost) == .orderedSame,
          !response.0.isEmpty,
          response.0.count <= 16 * 1_024 * 1_024 else {
        throw ManagerError.message("国服官方下载元数据响应未通过校验。")
    }
    do {
        return try JSONDecoder().decode(type, from: response.0)
    } catch {
        let description: String
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            description = "缺少字段 \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let context):
            description = "字段类型不符 \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.valueNotFound(_, let context):
            description = "字段值为空 \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let context):
            description = "内容损坏 \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            description = "无法解码"
        }
        throw ManagerError.message("国服官方下载元数据格式无效：\(description)。")
    }
}

private func isSafeManifestPath(_ rawPath: String) -> Bool {
    guard !rawPath.isEmpty,
          rawPath.utf8.count <= 4_096,
          !rawPath.hasPrefix("/"),
          !rawPath.contains("\\"),
          !rawPath.contains(":"),
          !rawPath.contains("\0") else { return false }
    let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty && !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
}

private func isValidDirectVersion(_ version: String) -> Bool {
    version.range(of: #"^v[0-9]+_[0-9]+_[0-9A-Fa-f]{32}$"#, options: .regularExpression) != nil
}

private func isSupportedManifestOperation(_ operation: Int?) -> Bool {
    operation == nil || operation == 1
}

private func buildDirectManifest(
    product: ProductID,
    descriptor: DirectDownloadDescriptor,
    launcher: LoadingBayLauncherData,
    content: LoadingBayMainContent,
    fetchedAt: String
) throws -> DirectManifestDocument {
    guard descriptor.adapter == "netease-loadingbay-v1",
          descriptor.distributionId > 0,
          descriptor.gameId.range(of: #"^h[0-9]+$"#, options: .regularExpression) != nil,
          launcher.appId == descriptor.distributionId,
          launcher.gameId == descriptor.gameId,
          !launcher.displayName.isEmpty,
          launcher.displayName.utf8.count <= 128,
          isSafeManifestPath(launcher.startupPath),
          launcher.startupPath.lowercased().hasSuffix(".exe"),
          launcher.startupParameters.utf8.count <= 2_048,
          !launcher.startupParameters.contains("\0"),
          isValidDirectVersion(content.versionCode),
          content.appContentId > 0,
          !content.files.isEmpty,
          content.files.count <= 100_000,
          content.directories.count <= 100_000 else {
        throw ManagerError.message("国服官方下载元数据的产品身份或基础字段无效。")
    }

    // Most supported Mac volumes are case-insensitive.  Rejecting conflicts
    // here keeps the on-disk plan deterministic across APFS configurations.
    var seenFiles = Set<String>()
    var totalByteCount: Int64 = 0
    let files = try content.files.map { file -> DirectManifestFile in
        let normalizedHash = file.xxh.lowercased()
        let normalizedPath = file.path.lowercased()
        guard isSafeManifestPath(file.path),
              file.size >= 0,
              isSupportedManifestOperation(file.operation),
              normalizedHash.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil,
              seenFiles.insert(normalizedPath).inserted else {
            throw ManagerError.message("国服官方文件清单包含不安全、重复或无法校验的条目。")
        }
        let addition = totalByteCount.addingReportingOverflow(file.size)
        guard !addition.overflow else { throw ManagerError.message("国服官方文件清单总大小溢出。") }
        totalByteCount = addition.partialValue
        return DirectManifestFile(path: file.path, byteCount: file.size, xxh64: normalizedHash, operation: file.operation)
    }

    var seenDirectories = Set<String>()
    let directories = try content.directories.map { directory -> DirectManifestDirectory in
        let normalizedPath = directory.path.lowercased()
        guard isSafeManifestPath(directory.path),
              isSupportedManifestOperation(directory.operation),
              seenDirectories.insert(normalizedPath).inserted,
              !seenFiles.contains(normalizedPath) else {
            throw ManagerError.message("国服官方目录清单包含不安全、重复或冲突的条目。")
        }
        return DirectManifestDirectory(path: directory.path, operation: directory.operation)
    }

    return DirectManifestDocument(
        schemaVersion: 1,
        productId: product,
        adapter: descriptor.adapter,
        distributionId: descriptor.distributionId,
        gameId: descriptor.gameId,
        displayName: launcher.displayName,
        startupPath: launcher.startupPath,
        startupArguments: launcher.startupParameters,
        versionCode: content.versionCode.lowercased(),
        contentId: content.appContentId,
        totalByteCount: totalByteCount,
        files: files,
        directories: directories,
        fetchedAt: fetchedAt
    )
}

private func resolveDirectManifest(for item: CatalogProduct) throws -> DirectManifestDocument {
    guard let descriptor = item.directDownload else {
        throw ManagerError.message("\(item.displayName)尚未提供可验证的完整游戏直下适配器。")
    }
    guard descriptor.adapter == "netease-loadingbay-v1" else {
        throw ManagerError.message("不支持的完整游戏下载适配器。")
    }
    let launcherRequest = try loadingBayURL(
        origin: descriptor.metadataOrigin,
        path: "/app/v1/game_library/app",
        distributionId: descriptor.distributionId,
        forceFreshLauncherData: true
    )
    let contentRequest = try loadingBayURL(
        origin: descriptor.metadataOrigin,
        path: "/app/v1/file_distribution/download_app",
        distributionId: descriptor.distributionId
    )
    let launcherEnvelope = try fetchLoadingBayJSON(
        LoadingBayEnvelope<LoadingBayLauncherData>.self,
        from: launcherRequest.0,
        expectedHost: launcherRequest.1,
        channel: descriptor.requestChannel
    )
    let distributionEnvelope = try fetchLoadingBayJSON(
        LoadingBayEnvelope<LoadingBayDistributionData>.self,
        from: contentRequest.0,
        expectedHost: contentRequest.1,
        channel: descriptor.requestChannel
    )
    guard launcherEnvelope.code == 200, distributionEnvelope.code == 200 else {
        throw ManagerError.message("国服官方下载元数据服务返回失败。")
    }
    return try buildDirectManifest(
        product: item.id,
        descriptor: descriptor,
        launcher: launcherEnvelope.data,
        content: distributionEnvelope.data.mainContent,
        fetchedAt: ISO8601DateFormatter().string(from: Date())
    )
}

private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

/// Confirms a structurally valid PE file with an embedded Authenticode
/// WIN_CERTIFICATE container.  Publisher-chain verification remains a
/// separate release gate before the installer is ever executed.
private func validateSignedPE(at url: URL, byteCount: Int64) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let header = try handle.read(upToCount: min(Int(byteCount), 1_048_576)) ?? Data()
    guard header.count >= 64, header[0] == 0x4d, header[1] == 0x5a,
          let peOffsetValue = littleEndianUInt32(header, at: 0x3c) else {
        throw ManagerError.message("下载文件不是有效的 Windows PE 安装器。")
    }
    let peOffset = Int(peOffsetValue)
    guard littleEndianUInt32(header, at: peOffset) == 0x0000_4550 else {
        throw ManagerError.message("下载文件缺少有效的 PE 标头。")
    }
    let optionalHeader = peOffset + 24
    guard let magic = littleEndianUInt16(header, at: optionalHeader) else {
        throw ManagerError.message("下载文件的 PE 可选标头不完整。")
    }
    let dataDirectory: Int
    switch magic {
    case 0x010b: dataDirectory = optionalHeader + 96
    case 0x020b: dataDirectory = optionalHeader + 112
    default: throw ManagerError.message("下载文件使用了不支持的 PE 格式。")
    }
    let securityEntry = dataDirectory + 8 * 4
    guard let certificateOffsetValue = littleEndianUInt32(header, at: securityEntry),
          let certificateSizeValue = littleEndianUInt32(header, at: securityEntry + 4) else {
        throw ManagerError.message("下载文件缺少 Authenticode 目录。")
    }
    let certificateOffset = Int64(certificateOffsetValue)
    let certificateSize = Int64(certificateSizeValue)
    guard certificateOffset > 0, certificateSize >= 8,
          certificateOffset <= byteCount,
          certificateSize <= byteCount - certificateOffset else {
        throw ManagerError.message("下载文件的 Authenticode 目录无效。")
    }
    try handle.seek(toOffset: UInt64(certificateOffset))
    let certificateHeader = try handle.read(upToCount: 8) ?? Data()
    guard let containerLength = littleEndianUInt32(certificateHeader, at: 0),
          littleEndianUInt16(certificateHeader, at: 4) == 0x0200,
          littleEndianUInt16(certificateHeader, at: 6) == 0x0002,
          containerLength >= 8,
          Int64(containerLength) <= certificateSize else {
        throw ManagerError.message("下载文件的 Authenticode 容器无效。")
    }
}

private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func writeLittleEndianUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
}

private func writeLittleEndianUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

private func runSelfTest() throws {
    var intelProbeCalls = 0
    do {
        try requireRuntimePrerequisites(majorVersion: 14) { intelProbeCalls += 1; return true }
        throw ManagerError.message("unsupported macOS prerequisite was accepted")
    } catch {
        guard error.localizedDescription.contains("IDV-ENV-102"), intelProbeCalls == 0 else { throw error }
    }
    do {
        try requireRuntimePrerequisites(majorVersion: 15) { false }
        throw ManagerError.message("missing Rosetta prerequisite was accepted")
    } catch {
        guard error.localizedDescription.contains("IDV-ENV-101") else { throw error }
    }
    try requireRuntimePrerequisites(majorVersion: 15) { true }
    let legacyFixture = """
    {"schemaVersion":1,"selectedEngineId":"legacy","engines":{"legacy":{"gameRoot":{"volumeUUID":"A","relativePath":"Games/IDV"},"prefix":{"volumeUUID":"A","relativePath":"Prefixes/IDV"},"runtime":{"volumeUUID":"A","relativePath":"Runtime"}}}}
    """
    let decodedLegacy = try JSONDecoder().decode(LegacyInstallationDocument.self, from: Data(legacyFixture.utf8))
    guard decodedLegacy.selectedEngineId == "legacy", decodedLegacy.engines["legacy"]?.runtime.relativePath == "Runtime" else {
        throw ManagerError.message("legacy installation strict-decoding self-test failed")
    }
    let statusOnlyCatalog = """
    {"schemaVersion":1,"engines":{"status":{"executablePaths":{"wine":"bin/wine","wineserver":"bin/wineserver"},"launchProfile":"codeweavers-wine-release-dxmt","verificationFiles":{"note":{}}}}}
    """
    let decodedCatalog = try JSONDecoder().decode(LegacyRuntimeCatalog.self, from: Data(statusOnlyCatalog.utf8))
    guard decodedCatalog.engines["status"]?.verificationFiles["note"]?.relativePath == nil,
          decodedCatalog.engines["status"]?.verificationFiles["note"]?.sha256 == nil else {
        throw ManagerError.message("status-only runtime catalogue self-test failed")
    }
    let bundleRoot = fileManager.temporaryDirectory
        .appendingPathComponent("identityv-product-manager-\(UUID().uuidString).app", isDirectory: true)
    defer { try? fileManager.removeItem(at: bundleRoot) }
    let runnerMacOS = bundleRoot.appendingPathComponent(
        "Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS", isDirectory: true
    )
    try fileManager.createDirectory(at: runnerMacOS, withIntermediateDirectories: true)
    let runnerInfo = runnerMacOS.deletingLastPathComponent().appendingPathComponent("Info.plist")
    try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: runnerInfo)
    let appExecutable = runnerMacOS.appendingPathComponent("launchIdentityV")
    let runnerExecutable = runnerMacOS.appendingPathComponent("launchIdentityVRunner")
    for executable in [appExecutable, runnerExecutable] {
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let runner = try embeddedGameRunnerApp(bundleRoot: bundleRoot)
    guard runner.path == runnerMacOS.deletingLastPathComponent().deletingLastPathComponent().path,
          try embeddedGameRunnerExecutable(runner: runner) == runnerExecutable,
          embeddedGameRunnerArguments(product: .mainland) == ["--product", "mainland"],
          embeddedGameRunnerArguments(product: .global) == ["--product", "global"] else {
        throw ManagerError.message("embedded runner location/argument self-test failed")
    }
    try fileManager.removeItem(at: appExecutable)
    var missingRunnerRejected = false
    do { _ = try embeddedGameRunnerApp(bundleRoot: bundleRoot) }
    catch { missingRunnerRejected = true }
    guard missingRunnerRejected else {
        throw ManagerError.message("embedded runner missing-file self-test failed")
    }

    guard isAllowedHost("a50.gdl.netease.com", suffixes: ["gdl.netease.com"]),
          isAllowedHost("gdl.netease.com", suffixes: ["gdl.netease.com"]),
          !isAllowedHost("gdl.netease.com.example.org", suffixes: ["gdl.netease.com"]) else {
        throw ManagerError.message("host allowlist self-test failed")
    }

    let progress = DownloadProgressEvent(
        schemaVersion: 1,
        event: "progress",
        productId: .mainland,
        phase: "downloading",
        bytesWritten: 1_024,
        totalBytesExpected: 4_096
    )
    let progressObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any]
    guard progressObject?["schemaVersion"] as? Int == 1,
          progressObject?["event"] as? String == "progress",
          progressObject?["productId"] as? String == "mainland",
          progressObject?["phase"] as? String == "downloading",
          progressObject?["bytesWritten"] as? Int == 1_024,
          progressObject?["totalBytesExpected"] as? Int == 4_096 else {
        throw ManagerError.message("download progress JSON self-test failed")
    }

    let emptySupervisorStage = SupervisorProgressEvent.Progress.Stage(percent: 0, bytesPerSecond: 0, totalBytes: 0)
    func supervisorProgress(
        head: SupervisorProgressEvent.Progress.Stage = emptySupervisorStage,
        download: Double = 0,
        build: Double = 0
    ) -> SupervisorProgressEvent.Progress {
        SupervisorProgressEvent.Progress(
            downloadHead: head,
            download: .init(percent: download, bytesPerSecond: 0, totalBytes: 0),
            build: .init(percent: build, bytesPerSecond: 0, totalBytes: 0),
            verifyPercent: 0
        )
    }
    let supervisorManifestBytes: Int64 = 1_000
    let fractionProgress = supervisorManifestFraction(progress: supervisorProgress(download: 0.85), manifestBytes: supervisorManifestBytes)
    let percentageProgress = supervisorManifestFraction(progress: supervisorProgress(build: 85), manifestBytes: supervisorManifestBytes)
    let headOnlyProgress = supervisorManifestFraction(
        progress: supervisorProgress(head: .init(percent: 1, bytesPerSecond: 0, totalBytes: 250)),
        manifestBytes: supervisorManifestBytes
    )
    let partialHeadProgress = supervisorManifestFraction(
        progress: supervisorProgress(head: .init(percent: 0.5, bytesPerSecond: 0, totalBytes: 250)),
        manifestBytes: supervisorManifestBytes
    )
    guard fractionProgress == 0.85,
          percentageProgress == 0.85,
          headOnlyProgress == 0.25,
          partialHeadProgress == 0.125 else {
        throw ManagerError.message("supervisor progress normalization self-test failed")
    }

    let directDescriptor = DirectDownloadDescriptor(
        adapter: "netease-loadingbay-v1",
        distributionId: 73,
        gameId: "h55",
        metadataOrigin: "https://loadingbaycn.webapp.163.com",
        requestChannel: "mkt-h55"
    )
    let directLauncher = LoadingBayLauncherData(
        appId: 73,
        gameId: "h55",
        displayName: "第五人格",
        startupPath: "dwrg.exe",
        startupParameters: "--start_from_launcher=1"
    )
    let directContent = LoadingBayMainContent(
        versionCode: "v3_4220_229300afaa11f1da1aa4af7379c2a648",
        appContentId: 434,
        files: [
            LoadingBayFile(path: "dwrg.exe", size: 1_024, xxh: "0123456789abcdef", operation: 1),
            LoadingBayFile(path: "res/data.wpk", size: 4_096, xxh: "fedcba9876543210", operation: 1)
        ],
        directories: [LoadingBayDirectory(path: "res", operation: 1)]
    )
    let directManifest = try buildDirectManifest(
        product: .mainland,
        descriptor: directDescriptor,
        launcher: directLauncher,
        content: directContent,
        fetchedAt: "2026-08-28T00:00:00Z"
    )
    guard directManifest.schemaVersion == 1,
          directManifest.contentId == 434,
          directManifest.totalByteCount == 5_120,
          directManifest.files.map(\.path) == ["dwrg.exe", "res/data.wpk"],
          directManifest.files.map(\.xxh64) == ["0123456789abcdef", "fedcba9876543210"] else {
        throw ManagerError.message("direct manifest validation self-test failed")
    }
    let unsafeContent = LoadingBayMainContent(
        versionCode: directContent.versionCode,
        appContentId: directContent.appContentId,
        files: [LoadingBayFile(path: "../escape.exe", size: 1, xxh: "0123456789abcdef", operation: 1)],
        directories: []
    )
    var unsafeManifestRejected = false
    do {
        _ = try buildDirectManifest(
            product: .mainland,
            descriptor: directDescriptor,
            launcher: directLauncher,
            content: unsafeContent,
            fetchedAt: "2026-08-28T00:00:00Z"
        )
    } catch {
        unsafeManifestRejected = true
    }
    guard unsafeManifestRejected else { throw ManagerError.message("unsafe manifest path was accepted") }

    let unsupportedOperation = LoadingBayMainContent(
        versionCode: directContent.versionCode,
        appContentId: directContent.appContentId,
        files: [LoadingBayFile(path: "dwrg.exe", size: 1, xxh: "0123456789abcdef", operation: 2)],
        directories: []
    )
    var unsupportedOperationRejected = false
    do {
        _ = try buildDirectManifest(
            product: .mainland,
            descriptor: directDescriptor,
            launcher: directLauncher,
            content: unsupportedOperation,
            fetchedAt: "2026-08-28T00:00:00Z"
        )
    } catch {
        unsupportedOperationRejected = true
    }
    guard unsupportedOperationRejected else { throw ManagerError.message("unsupported manifest operation was accepted") }

    let caseConflictingPaths = LoadingBayMainContent(
        versionCode: directContent.versionCode,
        appContentId: directContent.appContentId,
        files: [LoadingBayFile(path: "Res/Data.wpk", size: 1, xxh: "0123456789abcdef", operation: 1)],
        directories: [LoadingBayDirectory(path: "res/data.wpk", operation: 1)]
    )
    var caseConflictRejected = false
    do {
        _ = try buildDirectManifest(
            product: .mainland,
            descriptor: directDescriptor,
            launcher: directLauncher,
            content: caseConflictingPaths,
            fetchedAt: "2026-08-28T00:00:00Z"
        )
    } catch {
        caseConflictRejected = true
    }
    guard caseConflictRejected else { throw ManagerError.message("case-insensitive file/directory conflict was accepted") }

    let testRoot = fileManager.temporaryDirectory.appendingPathComponent("identityv-product-manager-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: testRoot) }

    // This fixture writes far beyond the usual pipe capacity on *both* file
    // descriptors before it exits. These calls exercise the real lifecycle
    // functions; an unread pipe would keep this self-test blocked forever.
    let pipeFlood = testRoot.appendingPathComponent("pipe-flood.command")
    try Data("#!/bin/sh\ndd if=/dev/zero bs=65536 count=80 2>/dev/null\ndd if=/dev/zero bs=65536 count=80 1>&2 2>/dev/null\nexit 0\n".utf8).write(to: pipeFlood)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pipeFlood.path)
    try runSupervisorStreaming(
        pipeFlood,
        task: testRoot.appendingPathComponent("unused-task.json"),
        environment: ProcessInfo.processInfo.environment,
        manifestBytes: 1,
        reporter: nil
    )
    try runGlobalAdapterStreaming(
        pipeFlood,
        manifest: testRoot.appendingPathComponent("unused-manifest.json"),
        destination: testRoot.appendingPathComponent("unused-destination"),
        control: testRoot.appendingPathComponent("unused-control.json"),
        total: 1,
        reporter: DownloadProgressReporter(product: .global)
    )

    let realDirectoryFixture = testRoot.appendingPathComponent("real-directory", isDirectory: true)
    try ensureRealDirectory(realDirectoryFixture, failure: "real directory fixture rejected")
    var realMetadata = stat()
    guard lstat(realDirectoryFixture.path, &realMetadata) == 0,
          (realMetadata.st_mode & S_IFMT) == S_IFDIR else {
        throw ManagerError.message("real directory creation self-test failed")
    }
    let linkedDirectoryFixture = testRoot.appendingPathComponent("linked-directory", isDirectory: true)
    try fileManager.createSymbolicLink(at: linkedDirectoryFixture, withDestinationURL: realDirectoryFixture)
    var linkedDirectoryRejected = false
    do {
        try ensureRealDirectory(linkedDirectoryFixture, failure: "linked directory rejected")
    } catch {
        linkedDirectoryRejected = true
    }
    guard linkedDirectoryRejected,
          (try? fileManager.destinationOfSymbolicLink(atPath: linkedDirectoryFixture.path)) != nil else {
        throw ManagerError.message("linked managed directory was not rejected safely")
    }

    // A fresh CodeWeavers bottle may bridge these known folders into the
    // current macOS home.  Verify normalization only changes the approved
    // bridge, removes the nested Desktop alias, and preserves/rejects a
    // foreign top-level bridge.
    let bridgeHome = testRoot.appendingPathComponent("bridge-home", isDirectory: true)
    for name in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"] {
        try fileManager.createDirectory(at: bridgeHome.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
    }
    try fileManager.createDirectory(at: bridgeHome.appendingPathComponent("Movies/subfolder", isDirectory: true), withIntermediateDirectories: true)
    let bridgeAccount = testRoot.appendingPathComponent("bridge-account", isDirectory: true)
    try fileManager.createDirectory(at: bridgeAccount, withIntermediateDirectories: true)
    let documentsBridge = bridgeAccount.appendingPathComponent("Documents", isDirectory: true)
    try fileManager.createSymbolicLink(at: documentsBridge, withDestinationURL: bridgeHome.appendingPathComponent("Documents", isDirectory: true))
    let videosBridge = bridgeAccount.appendingPathComponent("Videos", isDirectory: true)
    try fileManager.createSymbolicLink(at: videosBridge, withDestinationURL: bridgeHome.appendingPathComponent("Movies/subfolder", isDirectory: true))
    let desktop = bridgeAccount.appendingPathComponent("Desktop", isDirectory: true)
    try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
    let nestedDesktopBridge = desktop.appendingPathComponent("My Mac Desktop", isDirectory: true)
    try fileManager.createSymbolicLink(at: nestedDesktopBridge, withDestinationURL: bridgeHome.appendingPathComponent("Desktop", isDirectory: true))
    try normalizeWineUserDirectoryBridges(account: bridgeAccount, macOSHome: bridgeHome)
    var normalizedDocuments = stat()
    var normalizedVideos = stat()
    guard lstat(documentsBridge.path, &normalizedDocuments) != 0, errno == ENOENT,
          lstat(videosBridge.path, &normalizedVideos) != 0, errno == ENOENT,
          !fileManager.fileExists(atPath: nestedDesktopBridge.path),
          fileManager.fileExists(atPath: bridgeHome.appendingPathComponent("Documents").path) else {
        throw ManagerError.message("known-folder bridge normalization self-test failed")
    }
    // The caller's normal gate creates replacement private directories.
    try ensureRealDirectory(documentsBridge, failure: "normalized Documents bridge was not replaceable")
    try ensureRealDirectory(videosBridge, failure: "normalized Videos bridge was not replaceable")

    let foreignBridgeTarget = testRoot.appendingPathComponent("foreign-bridge-target", isDirectory: true)
    try fileManager.createDirectory(at: foreignBridgeTarget, withIntermediateDirectories: true)
    let foreignDownloadsBridge = bridgeAccount.appendingPathComponent("Downloads", isDirectory: true)
    try fileManager.createSymbolicLink(at: foreignDownloadsBridge, withDestinationURL: foreignBridgeTarget)
    var foreignBridgeRejected = false
    do { try normalizeWineUserDirectoryBridges(account: bridgeAccount, macOSHome: bridgeHome) }
    catch { foreignBridgeRejected = true }
    guard foreignBridgeRejected,
          (try? fileManager.destinationOfSymbolicLink(atPath: foreignDownloadsBridge.path)) == foreignBridgeTarget.path else {
        throw ManagerError.message("foreign known-folder bridge was not preserved and rejected")
    }

    let managedLinkFixture = testRoot.appendingPathComponent("managed-link")
    try fileManager.createSymbolicLink(atPath: managedLinkFixture.path, withDestinationPath: "old-target")
    try replaceLink(at: managedLinkFixture, destination: "new-target")
    guard try fileManager.destinationOfSymbolicLink(atPath: managedLinkFixture.path) == "new-target" else {
        throw ManagerError.message("managed symlink replacement self-test failed")
    }
    let foreignDirectoryFixture = testRoot.appendingPathComponent("foreign-directory", isDirectory: true)
    let foreignSentinel = foreignDirectoryFixture.appendingPathComponent("sentinel")
    try fileManager.createDirectory(at: foreignDirectoryFixture, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: foreignSentinel, options: [.atomic])
    var foreignDirectoryReplacementRejected = false
    do { try replaceLink(at: foreignDirectoryFixture, destination: "forbidden-target") }
    catch { foreignDirectoryReplacementRejected = true }
    guard foreignDirectoryReplacementRejected,
          (try Data(contentsOf: foreignSentinel)) == Data("preserve".utf8) else {
        throw ManagerError.message("real directory was not preserved by managed-link replacement")
    }

    guard managedDownloaderRepairListWindowsPath == "C:\\IdentityVDownloaderCore\\repair-list.txt" else {
        throw ManagerError.message("managed downloader repair-list Windows path self-test failed")
    }

    let staleControlFixture = testRoot.appendingPathComponent("stale-download-control.json")
    try Data("{\"schemaVersion\":1,\"sequence\":1,\"action\":\"cancel\"}\n".utf8)
        .write(to: staleControlFixture, options: [.atomic])
    try clearStaleDownloadControl(staleControlFixture)
    guard !fileManager.fileExists(atPath: staleControlFixture.path) else {
        throw ManagerError.message("stale download control cleanup self-test failed")
    }
    let foreignControlTarget = testRoot.appendingPathComponent("foreign-control-target")
    try Data("foreign".utf8).write(to: foreignControlTarget, options: [.atomic])
    try fileManager.createSymbolicLink(at: staleControlFixture, withDestinationURL: foreignControlTarget)
    var foreignControlRejected = false
    do { try clearStaleDownloadControl(staleControlFixture) } catch { foreignControlRejected = true }
    guard foreignControlRejected,
          (try? fileManager.destinationOfSymbolicLink(atPath: staleControlFixture.path)) != nil,
          (try Data(contentsOf: foreignControlTarget)) == Data("foreign".utf8) else {
        throw ManagerError.message("foreign download control link was not rejected safely")
    }

    let requestedParent = testRoot.appendingPathComponent("chosen-parent", isDirectory: true)
    try fileManager.createDirectory(at: requestedParent, withIntermediateDirectories: true)
    let workspace = try directInstallWorkspace(product: .mainland, destinationParent: requestedParent.path)
    guard workspace.installRoot.path == requestedParent.path,
          workspace.finalRoot.deletingLastPathComponent().path == workspace.installRoot.path,
          workspace.stagingRoot.deletingLastPathComponent().path == workspace.installRoot.path else {
        throw ManagerError.message("direct install workspace boundary self-test failed")
    }
    guard try relativeWindowsPath(workspace.stagingRoot, under: workspace.installRoot) == "Y:\\.staging",
          try relativeWindowsPath(workspace.work.appendingPathComponent("repair-list.txt"), under: workspace.installRoot) == "Y:\\work\\repair-list.txt" else {
        throw ManagerError.message("direct install Y: boundary self-test failed")
    }
    do {
        _ = try relativeWindowsPath(testRoot, under: workspace.installRoot)
        throw ManagerError.message("direct install accepted path outside Y: root")
    } catch let error as ManagerError {
        if error.errorDescription == "direct install accepted path outside Y: root" { throw error }
    }
    let mappingFixture = testRoot.appendingPathComponent("dosdevices-fixture", isDirectory: true)
    try fileManager.createDirectory(at: mappingFixture, withIntermediateDirectories: true)
    for (name, target) in [
        ("c:", "../drive_c"), (directInstallDosDevice, workspace.installRoot.path),
        ("z:", workspace.prefix.appendingPathComponent("host-root").path),
        ("d:", "/Volumes/Installer"), ("d::", "/dev/rdisk-test"),
        ("e:", "/Volumes/USB")
    ] {
        try fileManager.createSymbolicLink(
            atPath: mappingFixture.appendingPathComponent(name).path,
            withDestinationPath: target
        )
    }
    try removeAutomaticVolumeMappings(from: mappingFixture)
    guard (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent("c:").path)) != nil,
          (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent(directInstallDosDevice).path)) != nil,
          (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent("z:").path)) != nil,
          (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent("d:").path)) == nil,
          (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent("d::").path)) == nil,
          (try? fileManager.destinationOfSymbolicLink(atPath: mappingFixture.appendingPathComponent("e:").path)) == nil else {
        throw ManagerError.message("automatic removable-volume mapping cleanup self-test failed")
    }
    let foreignMapping = mappingFixture.appendingPathComponent("g:")
    try Data("not-a-link".utf8).write(to: foreignMapping)
    var foreignMappingRejected = false
    do { try removeAutomaticVolumeMappings(from: mappingFixture) } catch { foreignMappingRejected = true }
    guard foreignMappingRejected, fileManager.fileExists(atPath: foreignMapping.path) else {
        throw ManagerError.message("non-link drive mapping was not rejected safely")
    }

    let coreSourceFixture = testRoot.appendingPathComponent("verified-core-fixture", isDirectory: true)
    let corePrefixFixture = testRoot.appendingPathComponent("managed-core-prefix", isDirectory: true)
    let coreDriveCFixture = corePrefixFixture.appendingPathComponent("drive_c", isDirectory: true)
    let repairListFixture = testRoot.appendingPathComponent("repair-list-fixture.txt")
    try fileManager.createDirectory(at: coreSourceFixture, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: coreDriveCFixture, withIntermediateDirectories: true)
    for (index, name) in managedDownloaderCoreFiles.enumerated() {
        try Data("fixture-\(index)-\(name)".utf8).write(
            to: coreSourceFixture.appendingPathComponent(name),
            options: [.atomic]
        )
    }
    try Data("dwrg.exe\nres/data.wpk\n".utf8).write(to: repairListFixture, options: [.atomic])
    let stagedCoreFixture = try prepareManagedDownloaderCore(
        componentDirectory: coreSourceFixture,
        prefix: corePrefixFixture,
        repairList: repairListFixture
    )
    for name in managedDownloaderCoreFiles {
        guard try sha256(of: stagedCoreFixture.appendingPathComponent(name))
                == sha256(of: coreSourceFixture.appendingPathComponent(name)) else {
            throw ManagerError.message("managed downloader core copy self-test failed")
        }
    }
    guard try sha256(of: stagedCoreFixture.appendingPathComponent(managedDownloaderRepairListName))
            == sha256(of: repairListFixture) else {
        throw ManagerError.message("managed downloader repair-list copy self-test failed")
    }
    try removeManagedDownloaderCore(from: corePrefixFixture)
    guard !fileManager.fileExists(atPath: stagedCoreFixture.path) else {
        throw ManagerError.message("managed downloader core cleanup self-test failed")
    }

    let foreignCoreTarget = testRoot.appendingPathComponent("foreign-core-target", isDirectory: true)
    try fileManager.createDirectory(at: foreignCoreTarget, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
        at: coreDriveCFixture.appendingPathComponent(managedDownloaderCoreDirectoryName),
        withDestinationURL: foreignCoreTarget
    )
    var foreignCoreRejected = false
    do {
        _ = try prepareManagedDownloaderCore(
            componentDirectory: coreSourceFixture,
            prefix: corePrefixFixture,
            repairList: repairListFixture
        )
    } catch {
        foreignCoreRejected = true
    }
    guard foreignCoreRejected,
          (try? fileManager.destinationOfSymbolicLink(
            atPath: coreDriveCFixture.appendingPathComponent(managedDownloaderCoreDirectoryName).path
          )) != nil else {
        throw ManagerError.message("managed downloader core symlink target was not rejected safely")
    }
    let globalParent = testRoot.appendingPathComponent("global-parent", isDirectory: true)
    try fileManager.createDirectory(at: globalParent, withIntermediateDirectories: true)
    let globalWorkspace = try directInstallWorkspace(product: .global, destinationParent: globalParent.path)
    let globalMarker = GlobalTransactionMarker(schemaVersion: 1, product: "global", phase: "publishing", prefix: globalWorkspace.prefix.path, version: "v-test")
    let expectedManagedDrive = globalWorkspace.installRoot.path
    let expectedZ = globalWorkspace.prefix.appendingPathComponent("host-root").path
    guard try validateGlobalPublishEvidence(marker: globalMarker, workspace: globalWorkspace, version: "v-test", finalExists: true, stagingExists: false, cTarget: globalWorkspace.stagingRoot.path, managedDriveTarget: expectedManagedDrive, zTarget: expectedZ) == .restoreLink,
          try validateGlobalPublishEvidence(marker: globalMarker, workspace: globalWorkspace, version: "v-test", finalExists: true, stagingExists: false, cTarget: globalWorkspace.finalRoot.path, managedDriveTarget: expectedManagedDrive, zTarget: expectedZ) == .stateOnly else {
        throw ManagerError.message("global after-move/after-link recovery self-test failed")
    }
    for evidence in [
        ("foreign C link", globalWorkspace.installRoot.path, expectedManagedDrive, expectedZ, "v-test"),
        ("Y mismatch", globalWorkspace.stagingRoot.path, testRoot.path, expectedZ, "v-test"),
        ("Z mismatch", globalWorkspace.stagingRoot.path, expectedManagedDrive, testRoot.path, "v-test"),
        ("version mismatch", globalWorkspace.stagingRoot.path, expectedManagedDrive, expectedZ, "v-other")
    ] {
        do {
            _ = try validateGlobalPublishEvidence(marker: globalMarker, workspace: globalWorkspace, version: evidence.4, finalExists: true, stagingExists: false, cTarget: evidence.1, managedDriveTarget: evidence.2, zTarget: evidence.3)
            throw ManagerError.message("global \(evidence.0) was accepted")
        } catch let error as ManagerError {
            if error.errorDescription == "global \(evidence.0) was accepted" { throw error }
        }
    }
    do {
        _ = try validateGlobalPublishEvidence(marker: globalMarker, workspace: globalWorkspace, version: "v-test", finalExists: true, stagingExists: true, cTarget: globalWorkspace.stagingRoot.path, managedDriveTarget: expectedManagedDrive, zTarget: expectedZ)
        throw ManagerError.message("global downloading/final contradiction was accepted")
    } catch let error as ManagerError {
        if error.errorDescription == "global downloading/final contradiction was accepted" { throw error }
    }
    try fileManager.createDirectory(at: workspace.installRoot, withIntermediateDirectories: true)
    try writeDirectTransaction(workspace, phase: "publishing", version: directManifest.versionCode)
    let transaction = try JSONDecoder().decode(DirectInstallTransaction.self, from: Data(contentsOf: directTransactionURL(workspace)))
    guard transaction.phase == "publishing", transaction.prefix == workspace.prefix.path else {
        throw ManagerError.message("direct install transaction self-test failed")
    }
    try validateDirectTransaction(transaction, workspace: workspace, manifest: directManifest)
    let resumable = DirectInstallTransaction(schemaVersion: 1, product: "mainland", phase: "downloading", prefix: workspace.prefix.path, version: directManifest.versionCode)
    try validateDirectTransaction(resumable, workspace: workspace, manifest: directManifest)
    for invalid in [
        DirectInstallTransaction(schemaVersion: 1, product: "mainland", phase: "downloading", prefix: workspace.prefix.path + "-other", version: directManifest.versionCode),
        DirectInstallTransaction(schemaVersion: 1, product: "mainland", phase: "downloading", prefix: workspace.prefix.path, version: directManifest.versionCode + "-other"),
        DirectInstallTransaction(schemaVersion: 1, product: "mainland", phase: "unexpected", prefix: workspace.prefix.path, version: directManifest.versionCode)
    ] {
        var rejected = false
        do { try validateDirectTransaction(invalid, workspace: workspace, manifest: directManifest) } catch { rejected = true }
        guard rejected else { throw ManagerError.message("invalid direct install transaction was accepted") }
    }
    let oldFault = ProcessInfo.processInfo.environment["IDENTITYV_TEST_FAIL_DIRECT_INSTALL_PHASE"]
    setenv("IDENTITYV_TEST_FAIL_DIRECT_INSTALL_PHASE", "after-move", 1)
    defer {
        if let oldFault { setenv("IDENTITYV_TEST_FAIL_DIRECT_INSTALL_PHASE", oldFault, 1) }
        else { unsetenv("IDENTITYV_TEST_FAIL_DIRECT_INSTALL_PHASE") }
    }
    var faultInjected = false
    do { try directInstallFault("after-move") } catch { faultInjected = true }
    guard faultInjected else { throw ManagerError.message("direct install fault injection self-test failed") }

    let cleanRepairList = testRoot.appendingPathComponent("clean-repair-list.txt")
    try Data().write(to: cleanRepairList)
    let cleanSummary = RepairPlanSummary(repairs: 0, valid: true)
    guard try repairExecutionDecision(summary: cleanSummary, repairList: cleanRepairList, gameRoot: testRoot) == .noDownload else {
        throw ManagerError.message("zero-defect repair decision self-test failed")
    }

    let ordinaryRepairList = testRoot.appendingPathComponent("ordinary-repair-list.txt")
    try "neox_engine.dll\n".data(using: .utf8)!.write(to: ordinaryRepairList)
    let damagedSummary = RepairPlanSummary(repairs: 1, valid: false)
    guard try repairExecutionDecision(summary: damagedSummary, repairList: ordinaryRepairList, gameRoot: testRoot) == .download else {
        throw ManagerError.message("ordinary defect must remain repairable")
    }

    let engineMarker = testRoot.appendingPathComponent("engine_version")
    try "release_2026_0828:0123456789abcdef0123456789abcdef01234567\n".data(using: .utf8)!.write(to: engineMarker)
    let hotUpdateRepairList = testRoot.appendingPathComponent("hot-update-repair-list.txt")
    try "neox_engine.dll\nengine_version\n".data(using: .utf8)!.write(to: hotUpdateRepairList)
    guard try repairExecutionDecision(summary: RepairPlanSummary(repairs: 2, valid: false), repairList: hotUpdateRepairList, gameRoot: testRoot) == .blockForGameHotUpdate else {
        throw ManagerError.message("game hot-update marker must block downloader execution")
    }

    var signedPE = Data(repeating: 0, count: 1_024)
    signedPE[0] = 0x4d; signedPE[1] = 0x5a
    writeLittleEndianUInt32(0x80, to: &signedPE, at: 0x3c)
    writeLittleEndianUInt32(0x0000_4550, to: &signedPE, at: 0x80)
    let optionalHeader = 0x80 + 24
    writeLittleEndianUInt16(0x010b, to: &signedPE, at: optionalHeader)
    let securityEntry = optionalHeader + 96 + 8 * 4
    writeLittleEndianUInt32(0x200, to: &signedPE, at: securityEntry)
    writeLittleEndianUInt32(16, to: &signedPE, at: securityEntry + 4)
    writeLittleEndianUInt32(16, to: &signedPE, at: 0x200)
    writeLittleEndianUInt16(0x0200, to: &signedPE, at: 0x204)
    writeLittleEndianUInt16(0x0002, to: &signedPE, at: 0x206)
    let signedURL = testRoot.appendingPathComponent("signed.exe")
    try signedPE.write(to: signedURL)
    try validateSignedPE(at: signedURL, byteCount: Int64(signedPE.count))
    guard try sha256(of: signedURL).count == 64 else { throw ManagerError.message("streaming hash self-test failed") }

    // Cancellation never writes a managed sidecar: URLSession owns its partial
    // file until validation is complete, then the final rename is one step.
    let managedDownload = testRoot.appendingPathComponent("managed-download", isDirectory: true)
    try fileManager.createDirectory(at: managedDownload, withIntermediateDirectories: true)
    let previousInstaller = managedDownload.appendingPathComponent("installer.exe")
    try Data("previous-valid-installer".utf8).write(to: previousInstaller)
    let cancelledSessionFile = testRoot.appendingPathComponent("session-cancelled.download")
    try Data("partial".utf8).write(to: cancelledSessionFile)
    guard String(decoding: try Data(contentsOf: previousInstaller), as: UTF8.self) == "previous-valid-installer",
          try fileManager.contentsOfDirectory(atPath: managedDownload.path).count == 1,
          fileManager.fileExists(atPath: cancelledSessionFile.path) else {
        throw ManagerError.message("download cancellation state-safety self-test failed")
    }

    var unsignedPE = signedPE
    writeLittleEndianUInt32(0, to: &unsignedPE, at: securityEntry)
    writeLittleEndianUInt32(0, to: &unsignedPE, at: securityEntry + 4)
    let unsignedURL = testRoot.appendingPathComponent("unsigned.exe")
    try unsignedPE.write(to: unsignedURL)
    do {
        try validateSignedPE(at: unsignedURL, byteCount: Int64(unsignedPE.count))
        throw ManagerError.message("unsigned PE was accepted")
    } catch let error as ManagerError {
        if error.localizedDescription == "unsigned PE was accepted" { throw error }
    }

    let clientRoot = testRoot.appendingPathComponent("client", isDirectory: true)
    try fileManager.createDirectory(at: clientRoot, withIntermediateDirectories: true)
    let outsideExecutable = testRoot.appendingPathComponent("outside.exe")
    try Data([0x4d, 0x5a]).write(to: outsideExecutable)
    try fileManager.createSymbolicLink(at: clientRoot.appendingPathComponent("dwrg.exe"), withDestinationURL: outsideExecutable)
    guard gameExecutable(in: clientRoot) == nil else { throw ManagerError.message("symlink escape self-test failed") }
    let location = try makeLocation(clientRoot)
    guard resolve(location) == clientRoot.resolvingSymlinksInPath().standardizedFileURL else {
        throw ManagerError.message("managed location self-test failed")
    }

    // Lifecycle boundaries: ordinary managed directories resolve, while a
    // symlink component and cross-product ownership both fail closed before a
    // caller could reach Finder's Trash API.
    guard try resolveRemovalDirectory(location) == clientRoot.standardizedFileURL else {
        throw ManagerError.message("managed removal path self-test failed")
    }
    let linkedClient = testRoot.appendingPathComponent("linked-client", isDirectory: true)
    try fileManager.createSymbolicLink(at: linkedClient, withDestinationURL: clientRoot)
    let rootLocation = try makeLocation(testRoot)
    let symlinkLocation = ManagedLocation(
        volumeUUID: rootLocation.volumeUUID,
        relativePath: "\(rootLocation.relativePath)/linked-client"
    )
    var symlinkRejected = false
    do {
        _ = try resolveRemovalDirectory(symlinkLocation)
    } catch {
        symlinkRejected = true
    }
    guard symlinkRejected else { throw ManagerError.message("symlink removal self-test failed") }

    let overlappingState = ProductState(installations: [
        .mainland: Installation(gameRoot: location, prefix: nil, installer: nil, installedVersion: nil),
        .global: Installation(gameRoot: location, prefix: nil, installer: nil, installedVersion: nil)
    ])
    var overlapRejected = false
    do {
        _ = try removalItems(for: .mainland, state: overlappingState)
    } catch {
        overlapRejected = true
    }
    guard overlapRejected,
          !mayControlRunningGame(for: .global, state: overlappingState),
          pathsOverlap(clientRoot, clientRoot) else {
        throw ManagerError.message("product lifecycle isolation self-test failed")
    }
    var selectionState = ProductState(selectedProductId: .mainland)
    selectionState.selectedProductId = .global
    guard selectionState.selectedProductId == .global else {
        throw ManagerError.message("server panel selection self-test failed")
    }

    let statusProduct = CatalogProduct(
        id: .mainland,
        displayName: "测试国服",
        officialLandingPage: "https://example.invalid",
        resolverURL: "https://example.invalid/installer",
        allowedFinalHostSuffixes: ["example.invalid"],
        expectedInstallerFilename: "setup.exe",
        directDownload: nil
    )
    let downloadedInstaller = InstallerRecord(
        filename: "setup.exe",
        sha256: String(repeating: "0", count: 64),
        etag: nil,
        lastModified: nil,
        byteCount: 1,
        downloadedAt: "2026-08-28T00:00:00Z"
    )
    guard !status(for: statusProduct, state: ProductState()).canRemove,
          status(for: statusProduct, state: ProductState(installations: [
            .mainland: Installation(gameRoot: nil, prefix: nil, installer: downloadedInstaller, installedVersion: nil)
          ])).canRemove,
          status(for: statusProduct, state: ProductState(installations: [
            .mainland: Installation(gameRoot: location, prefix: nil, installer: nil, installedVersion: nil)
          ])).canRemove else {
        throw ManagerError.message("removal availability status self-test failed")
    }

    // Inject a private test mover and persistence sink.  This checks the
    // post-move state transition without ever touching products.json or the
    // real Finder Trash.
    let removableRoot = testRoot.appendingPathComponent("removable-game", isDirectory: true)
    let removablePrefix = testRoot.appendingPathComponent("removable-prefix", isDirectory: true)
    let simulatedTrash = testRoot.appendingPathComponent("simulated-trash", isDirectory: true)
    try fileManager.createDirectory(at: removableRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: removablePrefix, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: simulatedTrash, withIntermediateDirectories: true)
    var cleanupState = ProductState(installations: [
        .mainland: Installation(
            gameRoot: try makeLocation(removableRoot),
            prefix: try makeLocation(removablePrefix),
            installer: nil,
            installedVersion: nil
        )
    ])
    var persistedSnapshots: [ProductState] = []
    _ = try removeManagedProductFiles(
        .mainland,
        state: &cleanupState,
        move: { source in
            try fileManager.moveItem(
                at: source,
                to: simulatedTrash.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            )
        },
        persist: { snapshot in persistedSnapshots.append(snapshot) }
    )
    guard cleanupState.installations[.mainland] == nil,
          persistedSnapshots.last?.installations[.mainland] == nil,
          fileManager.fileExists(atPath: simulatedTrash.appendingPathComponent("removable-game").path),
          fileManager.fileExists(atPath: simulatedTrash.appendingPathComponent("removable-prefix").path) else {
        throw ManagerError.message("injected removal state self-test failed")
    }
}

private func verifyInstaller(at rawPath: String) throws -> InstallerVerificationDocument {
    let url = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        throw ManagerError.message("待验证路径不是普通文件。")
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0, byteCount <= 1_073_741_824 else {
        throw ManagerError.message("待验证文件大小不在允许范围内。")
    }
    try validateSignedPE(at: url, byteCount: byteCount)
    return InstallerVerificationDocument(
        schemaVersion: 1,
        byteCount: byteCount,
        sha256: try sha256(of: url),
        peStructureValid: true,
        authenticodeContainerPresent: true
    )
}

private func downloadInstaller(
    _ item: CatalogProduct,
    state: inout ProductState,
    reporter: DownloadProgressReporter
) throws {
    let resolved = try officialDownloadURL(for: item)
    reporter.emit(event: "progress", phase: "downloading", bytesWritten: 0, totalBytesExpected: nil, force: true)
    try ensureSupportDirectory()
    let destinationDir = supportDirectory.appendingPathComponent("Downloads/\(item.id.rawValue)", isDirectory: true)
    try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationDir.path)
    let destination = destinationDir.appendingPathComponent(item.expectedInstallerFilename)
    let staging = fileManager.temporaryDirectory
        .appendingPathComponent("IdentityVOnMac-\(item.id.rawValue)-\(UUID().uuidString).download")
    defer { try? fileManager.removeItem(at: staging) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 6 * 60 * 60
    let maximumInstallerSize: Int64 = 1_073_741_824
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(URL, HTTPURLResponse), Error>?
    let delegate = InstallerDownloadDelegate(
        allowedHostSuffixes: item.allowedFinalHostSuffixes,
        reporter: reporter,
        maximumSize: maximumInstallerSize,
        stagingURL: staging
    ) { value in
        result = value
        semaphore.signal()
    }
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let task = session.downloadTask(with: resolved)
    task.resume()
    semaphore.wait()
    session.finishTasksAndInvalidate()
    guard let result else { throw ManagerError.message("下载没有完成。") }
    let downloaded = try result.get()
    let http = downloaded.1
    guard let finalURL = http.url,
          finalURL.scheme?.lowercased() == "https", let finalHost = finalURL.host,
          isAllowedHost(finalHost, suffixes: item.allowedFinalHostSuffixes),
          (200...299).contains(http.statusCode) else { throw ManagerError.message("下载响应未通过域名校验。") }
    if http.expectedContentLength > maximumInstallerSize {
        throw ManagerError.message("官方安装器响应超过 1 GiB 安全上限。")
    }
    let attributes = try fileManager.attributesOfItem(atPath: downloaded.0.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 1_000_000, byteCount <= maximumInstallerSize else {
        throw ManagerError.message("安装器大小不在允许范围内，已拒绝保存。")
    }
    reporter.emit(event: "progress", phase: "verifying", bytesWritten: byteCount, totalBytesExpected: http.expectedContentLength >= 0 ? http.expectedContentLength : byteCount, force: true)
    // Verify and hash the URLSession-owned temporary file first.  No managed
    // partial exists while the task is cancellable; the only managed mutation
    // is this final atomic rename, which preserves a previous valid installer.
    try validateSignedPE(at: downloaded.0, byteCount: byteCount)
    let hash = try sha256(of: downloaded.0)
    try atomicallyReplace(downloaded.0, with: destination)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    var installation = state.installations[item.id] ?? Installation()
    installation.installer = InstallerRecord(filename: item.expectedInstallerFilename, sha256: hash, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"), byteCount: byteCount, downloadedAt: ISO8601DateFormatter().string(from: Date()))
    state.installations[item.id] = installation
}

private extension JSONEncoder { static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder } }

private func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw ManagerError.message("用法：status --json | resolve-manifest --json | select|install|import|prepare-launch|launch|restart|repair --product mainland|global") }
    if command == "self-test" {
        try runSelfTest()
        print("产品管理器自检通过。")
        return
    }
    if command == "check-runtime-prerequisites" {
        try requireRuntimePrerequisites()
        print("游戏运行环境已就绪。")
        return
    }
    if command == "verify-installer" {
        guard let path = argument(after: "--path") else { throw ManagerError.message("verify-installer 需要 --path <安装器>。") }
        print(String(decoding: try JSONEncoder.pretty.encode(verifyInstaller(at: path)), as: UTF8.self))
        return
    }
    if command == "resolve-download" {
        guard let rawProduct = argument(after: "--product"), let product = ProductID(rawValue: rawProduct) else {
            throw ManagerError.message("resolve-download 需要 --product mainland|global。")
        }
        let catalog = try loadCatalog()
        guard let item = catalog.products.first(where: { $0.id == product }) else { throw ManagerError.message("未知产品。") }
        let resolved = try officialDownloadURL(for: item)
        guard let finalHost = resolved.host else { throw ManagerError.message("官方下载地址缺少 host。") }
        let document = ResolvedDownloadDocument(
            schemaVersion: 1,
            productId: product,
            finalHost: finalHost,
            filename: resolved.lastPathComponent
        )
        print(String(decoding: try JSONEncoder.pretty.encode(document), as: UTF8.self))
        return
    }
    if command == "resolve-manifest" {
        guard args.contains("--json"),
              let rawProduct = argument(after: "--product"),
              let product = ProductID(rawValue: rawProduct) else {
            throw ManagerError.message("resolve-manifest 需要 --json --product mainland|global。")
        }
        let catalog = try loadCatalog()
        guard let item = catalog.products.first(where: { $0.id == product }) else {
            throw ManagerError.message("未知产品。")
        }
        print(String(decoding: try JSONEncoder.pretty.encode(resolveDirectManifest(for: item)), as: UTF8.self))
        return
    }
    if command == "status" {
        guard args.contains("--json") else { throw ManagerError.message("status 需要 --json。") }
        let catalog = try loadCatalog(); let state = try loadState()
        let document = StatusDocument(schemaVersion: 1, selectedProductId: state.selectedProductId, products: catalog.products.map { status(for: $0, state: state) })
        print(String(decoding: try JSONEncoder.pretty.encode(document), as: UTF8.self)); return
    }
    guard let rawProduct = argument(after: "--product"), let product = ProductID(rawValue: rawProduct) else { throw ManagerError.message("操作需要 --product mainland|global。") }
    try run(command, product: product)
}

do { try main() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
