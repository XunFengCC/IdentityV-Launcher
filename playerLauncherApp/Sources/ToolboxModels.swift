import Foundation

/// Fixed upstream component shipped by reference, never inside the app. Keep
/// the UI/cache contract together; the build checks it against the manifest.
enum IdvLoginRelease {
    static let version = "6.3.0"
    static let assetName = "idv-login-v\(version)-stable-mac"

    static func isCurrent(installedVersion: String?, helperIsCurrent: Bool) -> Bool {
        installedVersion == version && helperIsCurrent
    }
}

enum LauncherRelease {
    static var displayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "IdentityVReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0-rc.1"
    }
}

struct FeedbackBundle: Decodable {
    let archive: String
    let reportId: String
    let description: String
    let files: [String]
    var url: URL { URL(fileURLWithPath: archive) }
}

enum FeedbackDestination {
    static var email: String {
        Bundle.main.object(forInfoDictionaryKey: "IdentityVFeedbackEmail") as? String ?? "fengyin.apps@icloud.com"
    }

    static var configuredIssueURL: URL? {
        validatedIssueURL(Bundle.main.object(forInfoDictionaryKey: "IdentityVFeedbackIssueURL") as? String ?? "")
    }

    // An unpublished project has no issue destination yet. Never send launcher
    // reports to an unrelated upstream repository or infer a repository name.
    static func validatedIssueURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == components.path,
              components.path.range(of: #"^/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*/issues/new$"#, options: .regularExpression) != nil else { return nil }
        return url
    }

    static func issueURL(base: URL, report: FeedbackBundle, version: String) -> URL? {
        guard validatedIssueURL(base.absoluteString) != nil,
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // Keep arbitrary long descriptions out of a URL. The complete original
        // text is in the same ZIP used by email; users attach it on GitHub.
        parts.queryItems = [
            URLQueryItem(name: "title", value: "[反馈与建议] 第五人格启动器 \(version)"),
            URLQueryItem(name: "body", value: "版本：\(version)\n报告：\(report.reportId)\n\n\(String(report.description.prefix(800)))\n\n请在提交前附上诊断包：\(report.url.lastPathComponent)\nGitHub Issue 与附件公开可见。")
        ]
        return parts.url
    }
}

/// Builds the mail a feedback submission produces. Kept as a pure function so
/// the one-pass feedback window's contract (recipient, subject, user text as
/// body, optional attachment) is covered by the existing self-test rather than
/// only by clicking through the UI.
enum FeedbackMailComposer {
    /// The user's one-line summary becomes the subject, because that is what a
    /// mail list shows and what a maintainer triages by; the product name and
    /// version stay in front so reports from different builds stay sortable.
    /// An empty title falls back to the plain product subject.
    static func subject(title: String, version: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[反馈与建议] 第五人格启动器 \(version)" }
        return "[反馈与建议] \(trimmed) · 第五人格启动器 \(version)"
    }

    static func body(description: String, version: String, reportId: String?, attachesLogs: Bool) -> String {
        var text = "第五人格启动器 \(version)\n"
        if let reportId { text += "报告：\(reportId)\n" }
        text += "\n\(description)\n"
        text += attachesLogs ? "\n诊断包见附件。\n" : "\n（未附带日志包）\n"
        return text
    }

    /// Items handed to NSSharingService: body first, attachment second. The
    /// subject travels separately through `subject(title:version:)`.
    static func items(description: String, version: String, reportId: String?, attachment: URL?) -> [Any] {
        var items: [Any] = [body(description: description, version: version, reportId: reportId,
                                attachesLogs: attachment != nil)]
        if let attachment { items.append(attachment) }
        return items
    }

    /// One text file for the ZIP, so the attached bundle is self-describing even
    /// when it is read without the mail it came from.
    static func packagedDescription(title: String, description: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return description }
        return "标题：\(trimmed)\n\n\(description)"
    }
}

enum GameProductID: String, CaseIterable, Codable, Identifiable {
    case mainland
    case global

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .mainland: return "国服"
        case .global: return "国际服"
        }
    }

    var subtitle: String {
        switch self {
        case .mainland: return "第五人格中国大陆 PC 客户端"
        case .global: return "Identity V Global PC 客户端"
        }
    }
}

/// A player-facing launch failure is deliberately small and stable.  Raw
/// helper/runner output stays in the private logs; the UI presents only a
/// bounded reason plus a support code that invited testers can quote verbatim.
struct LaunchFailurePresentation: Identifiable, Equatable {
    let id = UUID()
    let productID: GameProductID?
    let code: String
    let summary: String

    var title: String {
        productID.map { "\($0.localizedName)启动失败" } ?? "启动失败"
    }

    var alertMessage: String {
        "\(summary)\n\n错误代码：\(code)"
    }
}

enum LaunchFailureClassifier {
    static func boundedReason(from output: String, fallback: String) -> String {
        let lastLine = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty }) ?? fallback
        let collapsed = lastLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let safe = collapsed.isEmpty ? fallback : collapsed
        return String(safe.prefix(360))
    }

    static func gameLaunchCode(for output: String) -> String {
        if output.contains("20 秒内没有出现可验证的游戏进程") { return "IDV-LAUNCH-203" }
        if output.contains("内嵌游戏运行器") { return "IDV-LAUNCH-202" }
        if output.contains("启动前检查") { return "IDV-LAUNCH-201" }
        return "IDV-LAUNCH-299"
    }
}

enum GameProductState: Equatable {
    case notInstalled
    case available
    case needsRepair
    case updating
    case error
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "not-installed", "missing", "uninstalled": self = .notInstalled
        case "available", "ready", "installed": self = .available
        case "needs-repair", "repair-needed", "broken": self = .needsRepair
        case "updating", "installing", "importing": self = .updating
        case "error", "failed": self = .error
        default: self = .unknown(rawValue)
        }
    }

    var localizedLabel: String {
        switch self {
        case .notInstalled: return "未安装"
        case .available: return "可用"
        case .needsRepair: return "需要修复"
        case .updating: return "正在更新"
        case .error: return "出现错误"
        case .unknown: return "状态未知"
        }
    }
}

struct ProductManagerStatusDocument: Decodable, Equatable {
    let schemaVersion: Int
    let selectedProductId: GameProductID?
    let products: [ProductManagerProductDocument]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedProductId
        case products
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw ProductManagerDocumentError.unsupportedSchema(schemaVersion)
        }
        selectedProductId = try container.decodeIfPresent(GameProductID.self, forKey: .selectedProductId)
        products = try container.decode([ProductManagerProductDocument].self, forKey: .products)
    }
}

struct ProductManagerProductDocument: Decodable, Equatable {
    let productId: GameProductID
    let state: GameProductState
    let installedVersion: String?
    let detail: String?
    let idvLoginVersion: String?
    /// Optional for compatibility with an older bundled manager.  A missing
    /// field must never invent a destructive action in the UI.
    let canRemove: Bool

    enum CodingKeys: String, CodingKey {
        case productId
        case id
        case state
        case status
        case installedVersion
        case detail
        case message
        case idvLoginVersion
        case canRemove
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productId = try container.decodeIfPresent(GameProductID.self, forKey: .productId)
            ?? container.decode(GameProductID.self, forKey: .id)
        let rawState = try container.decodeIfPresent(String.self, forKey: .state)
            ?? container.decodeIfPresent(String.self, forKey: .status)
            ?? "unknown"
        state = GameProductState(rawValue: rawState)
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
            ?? container.decodeIfPresent(String.self, forKey: .message)
        idvLoginVersion = try container.decodeIfPresent(String.self, forKey: .idvLoginVersion)
        canRemove = try container.decodeIfPresent(Bool.self, forKey: .canRemove) ?? false
    }
}

enum ProductManagerDocumentError: LocalizedError, Equatable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "不支持的启动器状态版本 \(version)"
        }
    }
}

/// JSONL protocol emitted on the product manager's stderr during an installer
/// download.  Keep it separate from status documents because stderr may also
/// contain a final human-readable error.
struct ProductDownloadProgressEvent: Decodable, Equatable {
    let schemaVersion: Int
    let event: String
    let productId: GameProductID
    let phase: String
    let bytesWritten: Int64
    let totalBytesExpected: Int64?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case event
        case productId
        case phase
        case bytesWritten
        case totalBytesExpected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw ProductManagerDocumentError.unsupportedSchema(schemaVersion)
        }
        event = try container.decode(String.self, forKey: .event)
        productId = try container.decode(GameProductID.self, forKey: .productId)
        phase = try container.decode(String.self, forKey: .phase)
        bytesWritten = try container.decode(Int64.self, forKey: .bytesWritten)
        totalBytesExpected = try container.decodeIfPresent(Int64.self, forKey: .totalBytesExpected)
    }
}

struct ProductDownloadProgress: Equatable {
    let productID: GameProductID
    let phase: String
    let bytesWritten: Int64
    let totalBytesExpected: Int64?
    let bytesPerSecond: Double?
    let etaSeconds: TimeInterval?

    init(productID: GameProductID, phase: String) {
        self.productID = productID
        self.phase = phase
        bytesWritten = 0
        totalBytesExpected = nil
        bytesPerSecond = nil
        etaSeconds = nil
        observedAt = Date()
    }

    init(event: ProductDownloadProgressEvent, previous: ProductDownloadProgress?, now: Date) {
        productID = event.productId
        phase = event.phase
        bytesWritten = max(0, event.bytesWritten)
        totalBytesExpected = event.totalBytesExpected.flatMap { $0 >= 0 ? $0 : nil }
        if let previous, previous.productID == event.productId,
           now.timeIntervalSince(previous.observedAt) > 0,
           bytesWritten >= previous.bytesWritten {
            let rate = Double(bytesWritten - previous.bytesWritten) / now.timeIntervalSince(previous.observedAt)
            bytesPerSecond = rate > 0 ? rate : previous.bytesPerSecond
        } else {
            bytesPerSecond = nil
        }
        if let totalBytesExpected, let bytesPerSecond, bytesPerSecond > 0 {
            etaSeconds = max(0, Double(totalBytesExpected - bytesWritten) / bytesPerSecond)
        } else {
            etaSeconds = nil
        }
        observedAt = now
    }

    private let observedAt: Date

    var fractionCompleted: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(totalBytesExpected))
    }

    var byteDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let written = formatter.string(fromByteCount: bytesWritten)
        guard let totalBytesExpected else { return written }
        return "\(written) / \(formatter.string(fromByteCount: totalBytesExpected))"
    }

    var speedDescription: String {
        guard let bytesPerSecond else { return "正在测量速度…" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/秒"
    }

    var etaDescription: String {
        guard let etaSeconds, etaSeconds.isFinite else { return "剩余时间计算中…" }
        if etaSeconds < 60 { return "剩余约 \(max(1, Int(etaSeconds.rounded()))) 秒" }
        return "剩余约 \(Int((etaSeconds / 60).rounded())) 分钟"
    }

    var phaseDescription: String {
        switch phase {
        case "resolving": return "正在解析官方游戏清单"
        case "runtime": return "正在取得并校验共享兼容环境（首次约 327 MB）"
        case "preparing": return "正在建立此服务器的独立兼容环境"
        case "downloading": return "正在下载游戏本体"
        case "verifying": return "正在校验游戏文件"
        case "publishing": return "正在写入最终游戏文件"
        case "completed": return "游戏本体已安装并通过校验"
        default: return "正在准备安装"
        }
    }
}

/// The manager reports byte totals only for the active phase. It provides no
/// stable cross-phase byte budget, so the overall installer bar intentionally
/// remains indeterminate rather than inventing a percentage.
struct ProductInstallProgressPresentation: Equatable {
    struct Stage: Equatable, Identifiable {
        let id: String
        let title: String
    }

    static let stages = [
        Stage(id: "resolving", title: "解析清单"),
        Stage(id: "runtime", title: "兼容环境"),
        Stage(id: "preparing", title: "准备环境"),
        Stage(id: "downloading", title: "下载游戏"),
        Stage(id: "verifying", title: "校验文件"),
        Stage(id: "publishing", title: "写入游戏"),
    ]

    let currentPhase: String
    let currentTitle: String
    let overallFraction: Double?

    init(progress: ProductDownloadProgress) {
        currentPhase = progress.phase
        currentTitle = progress.phaseDescription
        overallFraction = nil
    }

    func stageState(_ stage: Stage) -> StageState {
        if currentPhase == "completed" { return .complete }
        guard let current = Self.stages.firstIndex(where: { $0.id == currentPhase }),
              let candidate = Self.stages.firstIndex(where: { $0.id == stage.id }) else {
            return .pending
        }
        if candidate < current { return .complete }
        return candidate == current ? .current : .pending
    }

    enum StageState { case complete, current, pending }
}

/// View-layer expectation: the model should expose this controlled setter so
/// the switch can persist user intent without bypassing its launch policy.
protocol IdvLoginFollowGameSetting: AnyObject {
    var idvLoginEnabled: Bool { get }
    func setIdvLoginFollowGameEnabled(_ enabled: Bool)
}

struct GameProductPresentation: Equatable, Identifiable {
    let productId: GameProductID
    let state: GameProductState
    let installedVersion: String?
    let detail: String?
    let idvLoginVersion: String?
    let canRemove: Bool
    let isSelected: Bool

    var id: GameProductID { productId }

    static func makeAll(
        from document: ProductManagerStatusDocument?,
        selectedProductID: GameProductID? = nil
    ) -> [GameProductPresentation] {
        GameProductID.allCases.map { productId in
            let record = document?.products.first { $0.productId == productId }
            return GameProductPresentation(
                productId: productId,
                state: record?.state ?? .unknown("unavailable"),
                installedVersion: record?.installedVersion,
                detail: record?.detail,
                idvLoginVersion: record?.idvLoginVersion,
                canRemove: record?.canRemove ?? false,
                isSelected: (selectedProductID ?? document?.selectedProductId) == productId
            )
        }
    }
}

enum GameProductAction: String, CaseIterable, Identifiable {
    case select
    case install
    case importExisting = "import"
    case launch
    case restart
    case stop
    case remove
    case repair

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .select: return "选择此版本"
        case .install: return "安装游戏"
        case .importExisting: return "导入已有客户端"
        case .launch: return "启动游戏"
        case .restart: return "重启游戏"
        case .stop: return "结束游戏"
        case .remove: return "卸载游戏"
        case .repair: return "修复游戏"
        }
    }
}

enum GameProductActionPolicy {
    static func actions(for state: GameProductState, product: GameProductID = .mainland, canRemove: Bool = false) -> [GameProductAction] {
        var actions: [GameProductAction]
        switch state {
        case .notInstalled: actions = [.install]
        case .available: actions = [.launch, .stop, .restart, .repair]
        case .needsRepair: actions = [.repair]
        case .updating: actions = []
        case .error: actions = [.repair]
        case .unknown: actions = []
        }
        if canRemove { actions.append(.remove) }
        return actions
    }
}

struct RuntimeStatus: Equatable {
    var gameIsRunning = false
    // The selected tab is not necessarily the running server. Use verified
    // launcher sessions so opening Global never labels it running for CN.
    var runningProductIDs: Set<GameProductID> = []
    /// The root component process exists but its local login proxy has not yet
    /// passed the ownership/hosts readiness gate.
    var loginProcessStarting = false
    /// A managed component process tree owns 127.0.0.1:443 and all three
    /// compatibility hosts lines are present without aliases.
    var loginProxyReady = false
    var loginReadinessProblem = false
    var loginComponentVersion: String?
    var overlayIsRunning = false
    var checkedAt: Date?

    var loginIsRunning: Bool { loginProxyReady }
    var loginIsActive: Bool { loginProcessStarting || loginProxyReady || loginReadinessProblem }
}

enum ProbePhase: Equatable {
    case idle
    case waitingForGame
    case preparing
    case measuring
    case finishing
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .waitingForGame, .preparing, .measuring, .finishing:
            return true
        default:
            return false
        }
    }
}

struct ProbeSummary: Equatable {
    let isValid: Bool
    let latencyMilliseconds: Double?
    let confidenceLevel: String
    let confidenceScore: Double
    let peakCorrelation: Double?
    let warnings: [String]
    let resultDirectory: URL

    var localizedConfidence: String {
        switch confidenceLevel.lowercased() {
        case "high": return "高"
        case "medium": return "中"
        case "low": return "低"
        default: return confidenceLevel
        }
    }
}

struct ProbeResultDocument: Decodable {
    let analysis: Analysis

    struct Analysis: Decodable {
        let valid: Bool
        let softwareLatencyMilliseconds: Double?
        let confidenceLevel: String
        let confidenceScore: Double
        let peakCorrelation: Double?
        let warnings: [String]
    }
}

enum ToolboxPath {
    static let userSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
    static let userLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/IdentityVOnMac", isDirectory: true)
    static let resources = Bundle.main.resourceURL ?? userSupport
    static let startLoginHelper = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh"
    )
    static let loginComponentMetadata = URL(
        fileURLWithPath: "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/component.json"
    )
    static let installerPayload = resources.appendingPathComponent("InstallerPayload", isDirectory: true)
    static let loginInstaller = installerPayload.appendingPathComponent("installIdentityVPasswordlessHelpers.command")
    static let idvLoginDownloader = resources.appendingPathComponent("IdentityVIdvLoginDownloader")
    static let idvLoginManifest = resources.appendingPathComponent("idvLoginComponent.json")
    static let idvLoginDownloadCache = userSupport.appendingPathComponent("Components/IdvLoginDownload", isDirectory: true)
    static func embeddedGameRunner(in bundleRoot: URL = Bundle.main.bundleURL) -> URL? {
        let root = bundleRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.pathExtension == "app" else { return nil }
        let candidate = root
            .appendingPathComponent("Contents/Helpers/IdentityVGameRunner.app", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        guard candidate.path.hasPrefix(root.appendingPathComponent("Contents/Helpers", isDirectory: true).path + "/"),
              FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path),
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/launchIdentityV").path) else {
            return nil
        }
        return candidate
    }
    static let overlayApp = URL(fileURLWithPath: "/Applications/第五人格工具箱.app")
    static let stopLoginScript = resources.appendingPathComponent("stopIdentityVIdvLogin.command")
    static let stopMonitoringScript = resources.appendingPathComponent("stopIdentityVMonitoring.command")
    static let performanceReports = userLogs.appendingPathComponent("PerformanceReports", isDirectory: true)
    static let performanceCaptures = userLogs.appendingPathComponent("PerformanceCaptures", isDirectory: true)
    static let routeReadme = resources.appendingPathComponent("currentRoute.md")
    static let launcherEnvironment = userSupport.appendingPathComponent("launcher.env")
    static let probeResults = userSupport
        .appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("InputLatency", isDirectory: true)
    static let denseMetricsRoot = userSupport
        .appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("Dense", isDirectory: true)
    static let diagnosticExports = userSupport
        .appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("Exports", isDirectory: true)
    static let feedbackScratch = userSupport
        .appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("PendingFeedback", isDirectory: true)
    static let probeWorkingDirectory = userSupport
}

enum LauncherEnvironmentFile {
    static let mouseAccelerationKey = "IDENTITYV_DISABLE_MOUSE_ACCELERATION"

    static func mouseAccelerationIsDisabled(in text: String) -> Bool {
        value(for: mouseAccelerationKey, in: text) == "1"
    }

    static func updatingMouseAcceleration(in original: String, disabled: Bool) -> String {
        updating(key: mouseAccelerationKey, value: disabled ? "1" : "0", in: original)
    }

    static func writeMouseAcceleration(disabled: Bool, to url: URL) throws {
        try write(updating: { updatingMouseAcceleration(in: $0, disabled: disabled) }, to: url)
    }

    private static func updating(key: String, value: String, in original: String) -> String {
        var lines = original.components(separatedBy: .newlines)
        if original.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }

        var found = false
        for index in lines.indices {
            let normalized = normalizedAssignment(lines[index])
            guard normalized?.hasPrefix("\(key)=") == true else { continue }
            lines[index] = "\(key)=\(value)"
            found = true
        }
        if !found {
            if !lines.isEmpty, lines.last != "" {
                lines.append("")
            }
            lines.append("\(key)=\(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func write(updating transform: (String) -> String, to url: URL) throws {
        let original: String
        if FileManager.default.fileExists(atPath: url.path) {
            original = try String(contentsOf: url, encoding: .utf8)
        } else {
            original = ""
        }
        let updated = transform(original)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func value(for key: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            guard let line = normalizedAssignment(String(rawLine)),
                  line.hasPrefix("\(key)=") else { return nil }
            return String(line.dropFirst(key.count + 1))
        }.last
    }

    private static func normalizedAssignment(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        return line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
    }
}

#if TOOLBOX_ENV_SELF_TEST
@main
struct LauncherEnvironmentSelfTest {
    static func main() throws {
        let original = """
        # keep this comment
        IDENTITYV_FORCE_GAME_MODE=1
        export IDENTITYV_DISABLE_MOUSE_ACCELERATION=0
        IDENTITYV_AUTO_RESTART_ON_UPDATE=0
        """ + "\n"
        let enabled = LauncherEnvironmentFile.updatingMouseAcceleration(
            in: original,
            disabled: true
        )
        guard enabled.contains("# keep this comment"),
              enabled.contains("IDENTITYV_FORCE_GAME_MODE=1"),
              enabled.contains("IDENTITYV_AUTO_RESTART_ON_UPDATE=0"),
              enabled.contains("IDENTITYV_DISABLE_MOUSE_ACCELERATION=1"),
              LauncherEnvironmentFile.mouseAccelerationIsDisabled(in: enabled) else {
            throw SelfTestError.failed
        }
        let disabled = LauncherEnvironmentFile.updatingMouseAcceleration(
            in: enabled,
            disabled: false
        )
        guard !LauncherEnvironmentFile.mouseAccelerationIsDisabled(in: disabled) else {
            throw SelfTestError.failed
        }
        print("launcher.env 保留式更新自检通过。")
    }

    private enum SelfTestError: Error {
        case failed
    }
}
#endif

#if TOOLBOX_PRODUCT_SELF_TEST
@main
struct ProductManagerModelSelfTest {
    static func main() throws {
        let json = """
        {
          "schemaVersion": 1,
          "selectedProductId": "global",
          "products": [
            { "productId": "mainland", "state": "not-installed" },
            { "productId": "global", "status": "available", "installedVersion": "1.0", "canRemove": true }
          ]
        }
        """
        let document = try JSONDecoder().decode(
            ProductManagerStatusDocument.self,
            from: Data(json.utf8)
        )
        let presentations = GameProductPresentation.makeAll(from: document)
        let mainland = presentations.first { $0.productId == .mainland }
        let global = presentations.first { $0.productId == .global }
        let checks = [
            presentations.count == 2,
            mainland?.state == .notInstalled,
            mainland?.canRemove == false,
            global?.state == .available,
            global?.canRemove == true,
            global?.isSelected == true,
            GameProductActionPolicy.actions(for: .notInstalled) == [.install],
            GameProductActionPolicy.actions(for: .available, canRemove: true) == [.launch, .stop, .restart, .repair, .remove],
            GameProductActionPolicy.actions(for: .needsRepair, canRemove: true) == [.repair, .remove],
            GameProductActionPolicy.actions(for: .notInstalled, canRemove: true) == [.install, .remove],
            GameProductActionPolicy.actions(for: .updating).isEmpty,
            GameProductActionPolicy.actions(for: .unknown("future")).isEmpty,
            GameProductPresentation.makeAll(from: document, selectedProductID: .mainland)
                .first(where: { $0.productId == .mainland })?.isSelected == true,
            GameProductPresentation.makeAll(from: document, selectedProductID: .mainland)
                .first(where: { $0.productId == .global })?.isSelected == false
        ]
        guard checks.allSatisfy({ $0 }) else { throw SelfTestError.failed }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("identityv-toolbox-bundle-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let runnerMacOS = testRoot.appendingPathComponent("Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerMacOS, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(
            to: runnerMacOS.deletingLastPathComponent().appendingPathComponent("Info.plist")
        )
        let runnerExecutable = runnerMacOS.appendingPathComponent("launchIdentityV")
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: runnerExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerExecutable.path)
        guard ToolboxPath.embeddedGameRunner(in: testRoot)?.path == runnerMacOS.deletingLastPathComponent().deletingLastPathComponent().path else {
            throw SelfTestError.failed
        }
        try FileManager.default.removeItem(at: runnerExecutable)
        guard ToolboxPath.embeddedGameRunner(in: testRoot) == nil else { throw SelfTestError.failed }

        let progressJSON = """
        {"schemaVersion":1,"event":"progress","productId":"global","phase":"downloading","bytesWritten":2097152,"totalBytesExpected":8388608}
        """
        let event = try JSONDecoder().decode(ProductDownloadProgressEvent.self, from: Data(progressJSON.utf8))
        let start = ProductDownloadProgress(event: event, previous: nil, now: Date(timeIntervalSince1970: 1_000))
        let laterEventJSON = """
        {"schemaVersion":1,"event":"progress","productId":"global","phase":"downloading","bytesWritten":4194304,"totalBytesExpected":8388608}
        """
        let laterEvent = try JSONDecoder().decode(ProductDownloadProgressEvent.self, from: Data(laterEventJSON.utf8))
        let later = ProductDownloadProgress(event: laterEvent, previous: start, now: Date(timeIntervalSince1970: 1_002))
        guard later.fractionCompleted == 0.5,
              later.bytesPerSecond == 1_048_576,
              later.etaSeconds == 4,
              later.byteDescription.contains("/") else { throw SelfTestError.failed }
        let installerPresentation = ProductInstallProgressPresentation(
            progress: ProductDownloadProgress(productID: .mainland, phase: "publishing")
        )
        let completedPresentation = ProductInstallProgressPresentation(
            progress: ProductDownloadProgress(productID: .mainland, phase: "completed")
        )
        guard installerPresentation.overallFraction == nil,
              installerPresentation.currentTitle == "正在写入最终游戏文件",
              installerPresentation.stageState(.init(id: "downloading", title: "下载游戏")) == .complete,
              installerPresentation.stageState(.init(id: "verifying", title: "校验文件")) == .complete,
              installerPresentation.stageState(.init(id: "publishing", title: "写入游戏")) == .current,
              completedPresentation.currentTitle == "游戏本体已安装并通过校验",
              ProductInstallProgressPresentation.stages.allSatisfy({ completedPresentation.stageState($0) == .complete }) else {
            throw SelfTestError.failed
        }
        print("双服启动器模型自检通过。")
    }

    private enum SelfTestError: Error {
        case failed
    }
}
#endif
