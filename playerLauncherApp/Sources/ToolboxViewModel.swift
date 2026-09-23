import AppKit
import Foundation

/// Matches the executable field reported by `ps -axo command=`.
///
/// `ps` returns a complete command line, so searching the whole text treats a
/// diagnostic command such as `rg 'dwrg.exe'` as the game itself.  These checks
/// deliberately inspect only the leading executable on each line.
enum RuntimeProcessMatcher {
    private static let loginComponentPrefix = "/Library/Application Support/IdentityVOnMac/Components/idv-login/"

    static func containsGameProcess(in snapshot: String) -> Bool {
        snapshot.split(whereSeparator: \.isNewline).contains { line in
            isGameCommand(String(line))
        }
    }

    static func containsLoginProcess(in snapshot: String) -> Bool {
        snapshot.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            return isLoginCommand(command) || isLoginLauncherCommand(command)
        }
    }

    static func isGameCommand(_ commandLine: String) -> Bool {
        guard let executable = leadingExecutable(in: commandLine) else { return false }
        let normalized = executable.replacingOccurrences(of: "\\", with: "/").lowercased()
        return normalized == "dwrg.exe" || normalized.hasSuffix("/dwrg.exe")
    }

    static func isLoginCommand(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        // `ps` renders this executable path without quoting its spaces on this
        // macOS version, so tokenising on the first space would be wrong.  Match
        // the absolute managed-component path at the start of the line instead.
        let pattern = "^\\\"?\(NSRegularExpression.escapedPattern(for: loginComponentPrefix))[^/[:space:]]+/idv-login(?:-v[^[:space:]/]*)?(?:\\\"|[[:space:]]|$)"
        return trimmed.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Keeps the original fallback for the small managed launcher app, while
    /// applying the same executable-boundary rule as the other matches.
    static func isLoginLauncherCommand(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledLauncher = "/Applications/IDV Login.app/Contents/MacOS/IdentityVIDVLoginLauncher"
        if trimmed.hasPrefix(bundledLauncher) {
            let suffix = trimmed.dropFirst(bundledLauncher.count)
            return suffix.isEmpty || suffix.first?.isWhitespace == true
        }
        guard let executable = leadingExecutable(in: trimmed) else { return false }
        return executable.caseInsensitiveCompare("IdentityVIDVLoginLauncher") == .orderedSame
    }

    /// Returns the first argv item as represented by `ps`.  The managed IDV
    /// Login path contains spaces, so quoted executable paths need handling.
    private static func leadingExecutable(in commandLine: String) -> String? {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.first == "\"" {
            let remainder = trimmed.dropFirst()
            guard let closingQuote = remainder.firstIndex(of: "\"") else { return nil }
            return String(remainder[..<closingQuote])
        }

        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return trimmed
        }
        return String(trimmed[..<separator])
    }
}

/// Process-wide single-flight gate for the root-owned status command.
private enum LoginStatusPollGate {
    static let lock = NSLock()
    static var active = false
    static func tryAcquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard !active else { return false }; active = true; return true }
    static func release() { lock.lock(); active = false; lock.unlock() }
}

private struct LoginStartupResult: Equatable {
    let isReady: Bool
    let code: String
    let summary: String

    static let ready = LoginStartupResult(
        isReady: true,
        code: "IDVL-READY",
        summary: "IDV Login 已就绪。"
    )

    static func failed(code: String, summary: String) -> LoginStartupResult {
        LoginStartupResult(isReady: false, code: code, summary: summary)
    }

    static let waitingForAuthorization = LoginStartupResult(
        isReady: false, code: "IDVL-AUTH-WAITING", summary: "等待系统授权；确认后可继续启动。"
    )

    static func fromHelper(status: Int32, output: String) -> LoginStartupResult {
        if status == 0 { return .ready }
        if status == 75 && output.split(separator: "\n").contains("IDV_LOGIN_AUTHORIZATION=waiting") {
            return .waitingForAuthorization
        }
        return .failed(
            code: "IDVL-START-103",
            summary: LaunchFailureClassifier.boundedReason(
                from: output, fallback: "IDV Login 没有进入就绪状态，已取消启动游戏。"
            )
        )
    }
}

/// Coalesces a start/readiness request across every launcher window in this
/// process.  A server switch can be clicked while another server is launching;
/// they must wait for the same root helper invocation rather than each spawn
/// their own one.
private enum LoginStartupGate {
    final class Ticket: @unchecked Sendable {
        let group = DispatchGroup()
        private let resultLock = NSLock()
        private var value = LoginStartupResult.failed(
            code: "IDVL-START-199",
            summary: "IDV Login 启动结果不可用，请稍后重试。"
        )

        init() { group.enter() }

        func finish(result: LoginStartupResult) {
            resultLock.lock()
            value = result
            resultLock.unlock()
            group.leave()
        }

        func resultAfterWaiting() -> LoginStartupResult {
            group.wait()
            resultLock.lock()
            defer { resultLock.unlock() }
            return value
        }
    }

    private static let lock = NSLock()
    private static var activeTicket: Ticket?

    static func acquire() -> (isLeader: Bool, ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        if let activeTicket {
            return (false, activeTicket)
        }
        let ticket = Ticket()
        activeTicket = ticket
        return (true, ticket)
    }

    static func finish(_ ticket: Ticket, result: LoginStartupResult) {
        lock.lock()
        guard activeTicket === ticket else { lock.unlock(); return }
        activeTicket = nil
        lock.unlock()
        ticket.finish(result: result)
    }
}

/// Joins the two safe launch prerequisites: the shared IDV Login proxy becoming
/// ready and the selected product's read-only runner preflight.  The actual
/// Wine/game process is still started only after both sides succeed.
private final class ProductLaunchPreparation: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var loginResult = LoginStartupResult.failed(
        code: "IDVL-START-199",
        summary: "IDV Login 启动结果不可用，请稍后重试。"
    )
    private var preflightStatus: Int32 = 1
    private var preflightOutput = ""

    init() {
        group.enter()
        group.enter()
    }

    func finishLogin(result: LoginStartupResult) {
        lock.lock()
        loginResult = result
        lock.unlock()
        group.leave()
    }

    func finishPreflight(status: Int32, output: String) {
        lock.lock()
        preflightStatus = status
        preflightOutput = output
        lock.unlock()
        group.leave()
    }

    func snapshot() -> (loginResult: LoginStartupResult, preflightStatus: Int32, preflightOutput: String) {
        lock.lock()
        defer { lock.unlock() }
        return (loginResult, preflightStatus, preflightOutput)
    }
}

private struct IdvLoginDownloadProgressEvent: Decodable {
    let schemaVersion: Int
    let phase: String
    let bytesWritten: Int64
    let totalBytesExpected: Int64
}

private final class BoundedLineCollector: @unchecked Sendable {
    private var buffer = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int = 64 * 1_024) { self.maximumBytes = maximumBytes }

    func append(_ data: Data, finish: Bool = false) -> [String] {
        if !data.isEmpty { buffer.append(data) }
        if buffer.count > maximumBytes { buffer.removeFirst(buffer.count - maximumBytes) }
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
            buffer.removeSubrange(...newline)
        }
        if finish, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }
}

@MainActor
final class ToolboxViewModel: ObservableObject {
    @Published private(set) var runtimeStatus = RuntimeStatus()
    @Published private(set) var probePhase: ProbePhase = .idle
    @Published private(set) var probeStatusText = "尚未测量"
    @Published private(set) var probeProgress = 0.0
    @Published private(set) var probeConsole = ""
    @Published private(set) var probeSummary: ProbeSummary?
    @Published private(set) var showsPermissionHelp = false
    @Published private(set) var loginStartIsRunning = false
    @Published private(set) var loginInstallIsRunning = false
    @Published private(set) var loginUninstallIsRunning = false
    @Published private(set) var loginInstallPhase: String?
    @Published private(set) var loginInstallProgress: Double?
    @Published private(set) var loginStopIsRunning = false
    @Published private(set) var idvLoginEnabled = false
    @Published var shouldConfirmLoginCertificateTrust = false
    @Published private(set) var showsSkipLoginConfirmation = false
    @Published private(set) var launcherUpdateIsChecking = false
    @Published private(set) var feedbackIsSending = false
    @Published private(set) var gameRestartIsRunning = false
    @Published private(set) var overlayStopIsRunning = false
    @Published private(set) var diagnosticExportIsRunning = false
    @Published private(set) var operationMessage: String?
    @Published private(set) var operationIsError = false
    @Published private(set) var mouseAccelerationDisabled = false
    @Published private(set) var denseMonitoringState: DenseMonitoringState = .idle
    @Published private(set) var products = GameProductPresentation.makeAll(from: nil)
    /// This is navigation state for the launcher panel, not a global launch
    /// mutex.  A player may inspect/download one server while the other game
    /// process continues to run.
    @Published private(set) var selectedProductID: GameProductID = .mainland
    @Published private(set) var productManagerMessage = "正在检查启动器组件…"
    @Published private(set) var productManagerIsAvailable = false
    @Published private(set) var runtimePrerequisiteCheckIsRunning = false
    @Published private(set) var runtimePrerequisiteIssue: String?
    @Published private(set) var activeProductAction: GameProductAction?
    @Published private(set) var activeProductID: GameProductID?
    @Published private(set) var downloadProgress: ProductDownloadProgress?
    /// This expectation is deliberately independent of progress events: the
    /// installer must be allowed to start at once, while the player still gets
    /// a prominent first-install estimate.
    @Published private(set) var showsInitialInstallDownloadNotice = false
    @Published private(set) var recentlyCompletedProductID: GameProductID?
    @Published private(set) var lastLaunchFailure: LaunchFailurePresentation?
    @Published private(set) var showsLaunchFailureAlert = false
    /// The launcher owns this lightweight health reminder. It is opt-out and
    /// lives independently of the diagnostic toolbox.
    @Published private(set) var hangWarningsEnabled: Bool

    var loginMutationIsBusy: Bool {
        loginInstallIsRunning || loginStartIsRunning || loginStopIsRunning || loginUninstallIsRunning
            || loginInstallationAuthorizationPresentationPending
    }

    private let probeDurationSeconds = 18.0
    private var statusRefreshInFlight = false
    private var probeProcess: Process?
    private var probeStdout = Pipe()
    private var probeStderr = Pipe()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var probeStartedAt: Date?
    private var measurementStartedAt: Date?
    private var progressTimer: Timer?
    private var cancelledProbeIdentifier: Int32?
    private var productStatusRefreshInFlight = false
    private var loadedInitialProductSelection = false
    private var productInstallProcess: Process?
    private var productInstallStdout: Pipe?
    private var productInstallStderr: Pipe?
    private var productInstallStdoutBuffer = Data()
    private var productInstallStderrBuffer = Data()
    private var productInstallOutput = ""
    private var cancelledProductInstallPID: Int32?
    private var productInstallControlURL: URL?
    private var productInstallAttemptLog: InstallAttemptLog?
    private var installCompletionGeneration = UUID()
    private var loginDownloadProcess: Process?
    private var loginDownloadStdout: Pipe?
    private var loginDownloadStderr: Pipe?
    private var loginDownloadErrorOutput = ""
    /// The verified component is ready for an explicit administrator decision,
    /// but another launcher-owned explanatory alert is currently visible.
    /// Keeping this separate avoids attempting to present two SwiftUI alerts
    /// from the same view at once; it never starts installation by itself.
    private var loginInstallationAuthorizationPresentationPending = false
    private var pendingLoginTrustProductAction: (GameProductAction, GameProductID)?
    private var pendingManualLoginStart = false
    private enum LoginTrustDecision { case authorize, skipLogin }
    private var loginTrustDecision: LoginTrustDecision?
    private var diagnosticExportProcess: Process?
    private var feedbackExportProcess: Process?
    private let denseMonitoringController: DenseMonitoringController?
    private var launcherHangMonitor: LauncherHangMonitor?
    private var pendingLauncherHangRestart: LauncherGameSession?
    private var isPresentingLauncherHangPrompt = false
    /// Which incident the visible prompt belongs to. Recovery must never close a
    /// prompt for a different (or superseded) stall.
    private var pendingLauncherHangIncidentID: String?
    /// Remaining seconds of the self-closing recovery notice; 0 when inactive.
    private var hangRecoveryCountdown = 0
    private var hangRecoveryIncidentID: String?
    private var hangRecoveryTimer: Timer?
    private let launcherHangPrompt = LauncherHangPromptClient()

    init() {
        denseMonitoringController = DenseMonitoringController(
            samplerURL: Bundle.main.url(forResource: "idv-dense-metrics", withExtension: nil),
            root: ToolboxPath.denseMetricsRoot
        )
        hangWarningsEnabled = UserDefaults.standard.object(forKey: "identityVLauncherHangWarningsEnabled") as? Bool ?? true
        launcherHangMonitor = nil
        loadLauncherPreferences()
        // This preference means only “start IDV Login when a game starts”.
        // It deliberately uses a new key: older previews wrote `true`
        // automatically during installation, which was not an explicit choice.
        idvLoginEnabled = UserDefaults.standard.bool(forKey: "idvLoginFollowGameLaunchEnabled")
        UserDefaults.standard.removeObject(forKey: "idvLoginEnabled")
        shouldOfferIdvLoginPrompt = UserDefaults.standard.object(forKey: "idvLoginPromptAnswered") == nil
        launcherHangMonitor = LauncherHangMonitor(
            enabled: hangWarningsEnabled,
            onSuspicion: { [weak self] incident in
                DispatchQueue.main.async { [weak self] in
                    self?.presentLauncherHangPrompt(for: incident)
                }
            },
            onRecovery: { [weak self] incident in
                DispatchQueue.main.async { [weak self] in
                    self?.presentLauncherHangRecovery(for: incident)
                }
            }
        )
        refreshRuntimeStatus()
        refreshProductStatus()
        loadLatestProbeResult(allowOlderResult: true)

        // 麦克风授权（原因/条件/做法见 MicrophoneAuthorization.swift）：
        // 2026-09-19 的「进大厅卡死」根因就是它——TCC 从责任 App 取麦克风说明字段，拿不到
        // 就拒绝，游戏内语音引擎开不了采集流，客户端会一直等在进入大厅的加载界面。
        // 这里只做**只读检查 + 明确提示**（不主动申请：责任链异常时主动申请会被 TCC 杀掉进程，
        // 见该文件的安全边界说明），让她知道原因和去哪个设置页打开，而不是让游戏静默卡住。
        if let warning = MicrophoneAuthorization.warningMessage {
            showOperation(warning, isError: true)
        }
    }

    deinit {
        progressTimer?.invalidate()
        probeProcess?.terminate()
        productInstallProcess?.terminate()
        loginDownloadProcess?.terminate()
        diagnosticExportProcess?.terminate()
        feedbackExportProcess?.terminate()
        launcherHangMonitor?.stop()
        hangRecoveryTimer?.invalidate()
    }

    /// The reminder is intentionally a menu preference: it keeps the main
    /// launcher panel focused on choosing, installing, and starting a game.
    /// The monitor itself is independent of the panel/window lifecycle.
    func setHangWarningsEnabled(_ enabled: Bool) {
        hangWarningsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "identityVLauncherHangWarningsEnabled")
        launcherHangMonitor?.setEnabled(enabled)
        if !enabled {
            hangRecoveryTimer?.invalidate()
            hangRecoveryTimer = nil
            hangRecoveryCountdown = 0
            hangRecoveryIncidentID = nil
            pendingLauncherHangIncidentID = nil
            launcherHangPrompt.dismiss()
            isPresentingLauncherHangPrompt = false
        }
    }

    private func clearPendingLauncherHangRestart(for productID: GameProductID) {
        guard pendingLauncherHangRestart?.productID == productID else { return }
        pendingLauncherHangRestart = nil
    }

    /// Show a passive prompt on the game's fullscreen Space. It never
    /// activates the launcher or takes keyboard focus; only the helper's
    /// explicit, incident-bound button reply can request the existing restart.
    private func presentLauncherHangPrompt(for incident: LauncherHangIncident) {
        guard hangWarningsEnabled, !isPresentingLauncherHangPrompt,
              GameProcessIdentity.read(incident.session.identity.pid) == incident.session.identity else {
            launcherHangMonitor?.acknowledge(incident)
            return
        }
        isPresentingLauncherHangPrompt = true
        pendingLauncherHangIncidentID = incident.id
        // A new incident owns the panel; any countdown for an older one is void.
        hangRecoveryTimer?.invalidate()
        hangRecoveryTimer = nil
        hangRecoveryCountdown = 0
        hangRecoveryIncidentID = nil
        let title = incident.session.productID == .mainland ? "游戏可能卡住了" : "国际服可能卡住了"
        let shown = launcherHangPrompt.show(id: incident.id, title: title) { [weak self] action in
            guard let self else { return }
            self.isPresentingLauncherHangPrompt = false
            self.pendingLauncherHangIncidentID = nil
            self.hangRecoveryTimer?.invalidate()
            self.hangRecoveryTimer = nil
            self.hangRecoveryCountdown = 0
            self.hangRecoveryIncidentID = nil
            self.launcherHangMonitor?.acknowledge(incident)
            if action == "restart" { self.revalidateAndRestartAfterHang(incident) }
            else if action == nil { self.showOperation("卡死提醒显示异常，请重新打开启动器。", isError: true) }
        }
        if !shown {
            isPresentingLauncherHangPrompt = false
            pendingLauncherHangIncidentID = nil
            launcherHangMonitor?.acknowledge(incident)
            showOperation("卡死提醒窗口未能启动，请重新打开启动器。", isError: true)
        }
    }

    /// The game started running again while the reminder was on screen. Instead
    /// of waiting for a click over live gameplay, the panel counts 5→1 and closes
    /// itself; the helper holds the deadline, so a dropped tick cannot leave it up.
    private func presentLauncherHangRecovery(for incident: LauncherHangIncident) {
        guard hangWarningsEnabled, isPresentingLauncherHangPrompt,
              pendingLauncherHangIncidentID == incident.id else { return }
        hangRecoveryCountdown = HangPromptRecovery.firstCountdown
        hangRecoveryIncidentID = incident.id
        sendHangRecoveryCountdown(for: incident)
    }

    private func sendHangRecoveryCountdown(for incident: LauncherHangIncident) {
        let step = hangRecoveryCountdown
        guard step >= 1 else { return }
        guard launcherHangPrompt.showRecovery(id: incident.id, remainingSeconds: step) else {
            // The helper is gone; make sure no stale prompt state survives.
            hangRecoveryTimer?.invalidate()
            hangRecoveryTimer = nil
            hangRecoveryCountdown = 0
            hangRecoveryIncidentID = nil
            launcherHangPrompt.dismiss()
            isPresentingLauncherHangPrompt = false
            launcherHangMonitor?.acknowledge(incident)
            return
        }
        // The helper closes itself 1.6 s after the last record, so the launcher
        // only needs to feed the numbers and clear its own presentation state.
        guard let next = HangPromptRecovery.next(after: step) else {
            hangRecoveryTimer?.invalidate()
            hangRecoveryTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.hangRecoveryCountdown == 1 else { return }
                self.hangRecoveryCountdown = 0
                self.hangRecoveryIncidentID = nil
                self.launcherHangPrompt.dismiss()
                self.isPresentingLauncherHangPrompt = false
                self.launcherHangMonitor?.acknowledge(incident)
            }
            return
        }
        hangRecoveryCountdown = next
        hangRecoveryTimer?.invalidate()
        hangRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, self.hangRecoveryIncidentID == incident.id else { return }
            self.sendHangRecoveryCountdown(for: incident)
        }
    }

    private func revalidateAndRestartAfterHang(_ incident: LauncherHangIncident) {
        let captured = incident.session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Both checks are required.  A PID can be reused with the same
            // executable path, and a valid session for the other product must
            // never authorize this restart.
            let identityStillMatches = GameProcessIdentity.read(captured.identity.pid) == captured.identity
            let currentSessions = LauncherGameSessionMatcher.verifiedSessions(
                snapshot: Self.processDetailsSnapshot()
            )
            let confirmed = identityStillMatches && LauncherGameSessionMatcher.canConfirmRestart(
                captured: captured,
                current: currentSessions
            )
            DispatchQueue.main.async {
                guard let self else { return }
                guard confirmed else {
                    self.showOperation("当前游戏会话已变化，已取消重启。请从启动器重新启动。", isError: true)
                    return
                }
                guard !self.runtimePrerequisiteCheckIsRunning, self.activeProductAction == nil else {
                    self.showOperation("启动器正在处理其他操作，已取消本次重启。", isError: true)
                    return
                }
                self.pendingLauncherHangRestart = captured
                self.performProductAction(.restart, for: captured.productID)
            }
        }
    }

    func refreshRuntimeStatus() {
        guard !statusRefreshInFlight else { return }
        statusRefreshInFlight = true

        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let commands = Self.processCommandSnapshot()
            let processDetails = Self.processDetailsSnapshot()
            let componentVersion = Self.loginComponentVersion()
            let processExists = RuntimeProcessMatcher.containsLoginProcess(in: commands)
            let readiness = processExists ? Self.loginReadinessStatus() : "not-running"
            let next = RuntimeStatus(
                // The native trampoline may remain registered with LaunchServices
                // after a failed root handoff.  Only the actual Windows game
                // process is authoritative for the user-facing running state.
                gameIsRunning: RuntimeProcessMatcher.containsGameProcess(in: commands),
                runningProductIDs: Set(LauncherGameSessionMatcher.verifiedSessions(snapshot: processDetails).map(\.productID)),
                // If a legacy helper lacks the explicit status sudoers rule, we
                // still must not promote a visible process to “ready”. Treat
                // the unverifiable state as initializing so it remains
                // stoppable and cannot block normal game/download actions.
                loginProcessStarting: processExists && readiness != "ready" && readiness != "misconfigured" && readiness != "helper-update-required",
                loginProxyReady: processExists && readiness == "ready",
                loginReadinessProblem: processExists && (readiness == "misconfigured" || readiness == "helper-update-required"),
                loginComponentVersion: componentVersion,
                overlayIsRunning: bundleIDs.contains("com.fengyin.identityv.toolbox")
                    || bundleIDs.contains("com.xunfeng.identityv.monitor")
                    || commands.contains("IdentityVMonitor"),
                checkedAt: Date()
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimeStatus = next
                self.refreshDenseMonitoring(with: processDetails)
                self.statusRefreshInFlight = false
                if next.loginProxyReady && self.operationMessage == "正在启动 IDV Login…" {
                    self.loginStartIsRunning = false
                    self.showOperation("IDV Login 已就绪；本机登录代理可用。")
                } else if !next.loginIsActive
                    && !self.loginStartIsRunning
                    && self.operationMessage == "IDV Login 已就绪；本机登录代理可用。" {
                    self.showOperation("IDV Login 已停止。")
                } else if processExists && readiness == "helper-update-required" {
                    self.showOperation("已安装的 IDV Login helper 版本过旧；请重新安装 IDV Login 组件后再启动游戏。", isError: true)
                }
            }
        }
    }

    func refreshProductStatus() {
        guard !productStatusRefreshInFlight else { return }
        guard activeProductAction == nil else { return }
        guard let manager = productManagerURL() else {
            productManagerIsAvailable = false
            products = GameProductPresentation.makeAll(from: nil)
            productManagerMessage = "启动器组件尚未提供；安装、导入、双服切换暂不可用。"
            return
        }
        productStatusRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runProductManager(manager, arguments: ["status", "--json"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.productStatusRefreshInFlight = false
                guard result.status == 0 else {
                    self.productManagerIsAvailable = false
                    self.products = GameProductPresentation.makeAll(from: nil)
                    let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
                    self.productManagerMessage = "无法读取启动器状态：\(detail)"
                    return
                }
                do {
                    let document = try JSONDecoder().decode(
                        ProductManagerStatusDocument.self,
                        from: Data(result.output.utf8)
                    )
                    self.productManagerIsAvailable = true
                    if !self.loadedInitialProductSelection,
                       let savedSelection = document.selectedProductId {
                        self.selectedProductID = savedSelection
                        self.loadedInitialProductSelection = true
                    }
                    self.products = GameProductPresentation.makeAll(
                        from: document,
                        selectedProductID: self.selectedProductID
                    )
                    self.productManagerMessage = "两个版本可独立安装，游戏文件、兼容环境和更新状态不会互相覆盖。"
                } catch {
                    self.productManagerIsAvailable = false
                    self.products = GameProductPresentation.makeAll(from: nil)
                    self.productManagerMessage = "启动器状态格式无效：\(error.localizedDescription)"
                }
            }
        }
    }

    func performProductAction(_ action: GameProductAction, for productID: GameProductID) {
        guard !runtimePrerequisiteCheckIsRunning, activeProductAction == nil else { return }
        let needsRuntime = [GameProductAction.install, .importExisting, .repair, .launch, .restart].contains(action)
        guard needsRuntime, productManagerIsAvailable, let manager = productManagerURL() else {
            performProductActionAfterPrerequisites(action, for: productID)
            return
        }
        runtimePrerequisiteCheckIsRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProductManager(manager, arguments: ["check-runtime-prerequisites"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimePrerequisiteCheckIsRunning = false
                guard result.status == 0 else {
                    self.clearPendingLauncherHangRestart(for: productID)
                    self.runtimePrerequisiteIssue = result.output.isEmpty
                        ? "无法检查游戏运行环境，请重新打开启动器后重试。错误代码：IDV-ENV-199"
                        : result.output
                    return
                }
                self.performProductActionAfterPrerequisites(action, for: productID)
            }
        }
    }

    var runtimePrerequisiteNeedsRosetta: Bool {
        runtimePrerequisiteIssue?.contains("IDV-ENV-101") == true
    }

    func dismissRuntimePrerequisiteIssue() {
        runtimePrerequisiteIssue = nil
    }

    func openRosettaInstaller() {
        dismissRuntimePrerequisiteIssue()
        // Use Apple's own visible installer. The app never supplies an admin
        // password or accepts the Rosetta licence on the player's behalf.
        let candidates = [
            "/System/Library/CoreServices/Rosetta 2 Updater.app",
            "/System/Library/CoreServices/Rosetta2 Updater.app"
        ].map { URL(fileURLWithPath: $0) }
        guard let installer = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            runtimePrerequisiteIssue = "找不到 Apple Rosetta 安装器，请先更新 macOS 后重试。错误代码：IDV-ENV-103"
            return
        }
        NSWorkspace.shared.openApplication(at: installer, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.runtimePrerequisiteIssue = "无法打开 Apple Rosetta 安装器：\(error.localizedDescription)\n错误代码：IDV-ENV-103"
                } else {
                    self.showOperation("完成 Rosetta 安装后，返回启动器再次点击原来的按钮即可继续。")
                }
            }
        }
    }

    private func performProductActionAfterPrerequisites(_ action: GameProductAction, for productID: GameProductID) {
        guard productManagerIsAvailable, let manager = productManagerURL() else {
            clearPendingLauncherHangRestart(for: productID)
            if action == .launch || action == .restart {
                presentLaunchFailure(
                    productID: productID,
                    code: "IDV-LAUNCH-101",
                    summary: "启动器的游戏管理组件缺失或不可用，请重新安装启动器。"
                )
            } else {
                showOperation("双服启动器组件尚未安装，无法执行\(action.localizedTitle)。", isError: true)
            }
            return
        }
        guard activeProductAction == nil else { return }
        clearLaunchFailure()
        clearInstallCompletionPresentation()
        if action == .install {
            let directory = Self.defaultInstallDirectory(for: productID)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            startInstallerDownload(productID: productID, manager: manager, destinationParent: directory)
            return
        }
        if action == .importExisting {
            let panel = NSOpenPanel()
            panel.message = "选择已有的 \(productID.localizedName) 客户端目录"
            panel.prompt = "导入"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let directory = panel.url else {
                showOperation("未选择要导入的客户端目录。")
                return
            }
            runProductAction(action, productID: productID, manager: manager, extraArguments: ["--path", directory.path])
            return
        }
        if (action == .launch || action == .restart), idvLoginEnabled {
            guard loginCertificateTrustNoticeAcknowledged else {
                pendingLoginTrustProductAction = (action, productID)
                shouldConfirmLoginCertificateTrust = true
                return
            }
            if runtimeStatus.loginProxyReady {
                runProductAction(action, productID: productID, manager: manager, extraArguments: [])
            } else {
                prepareLoginAndProductInParallel(
                    action,
                    productID: productID,
                    manager: manager
                )
            }
        } else {
            runProductAction(action, productID: productID, manager: manager, extraArguments: [])
        }
    }

    func defaultInstallPath(for productID: GameProductID) -> String {
        "~/Library/Application Support/第五人格/\(productID == .mainland ? "CN" : "Global")"
    }

    fileprivate static func defaultInstallDirectory(for productID: GameProductID) -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/第五人格", isDirectory: true)
        return root.appendingPathComponent(productID == .mainland ? "CN" : "Global", isDirectory: true)
    }

    func selectProductPanel(_ productID: GameProductID) {
        guard selectedProductID != productID else { return }
        selectedProductID = productID
        // Rebuild presentation immediately instead of waiting for the next
        // status poll.  No product-manager mutation is needed for a view-only
        // server switch, so it stays available during an installer download.
        products = products.map { product in
            GameProductPresentation(
                productId: product.productId,
                state: product.state,
                installedVersion: product.installedVersion,
                detail: product.detail,
                idvLoginVersion: product.idvLoginVersion,
                canRemove: product.canRemove,
                isSelected: product.productId == productID
            )
        }
    }

    private func runProductAction(
        _ action: GameProductAction,
        productID: GameProductID,
        manager: URL,
        extraArguments: [String]
    ) {
        if action == .restart, let captured = pendingLauncherHangRestart,
           captured.productID == productID {
            // Runtime and IDV Login prerequisites may take time after the
            // first confirmation. Recheck immediately before launching the
            // existing manager action so a PID reuse or session replacement
            // cannot turn the user's earlier approval into a broad restart.
            let identityStillMatches = GameProcessIdentity.read(captured.identity.pid) == captured.identity
            let currentSessions = LauncherGameSessionMatcher.verifiedSessions(
                snapshot: Self.processDetailsSnapshot()
            )
            pendingLauncherHangRestart = nil
            guard identityStillMatches,
                  LauncherGameSessionMatcher.canConfirmRestart(
                    captured: captured,
                    current: currentSessions
                  ) else {
                showOperation("当前游戏会话已变化，已取消重启。请从启动器重新启动。", isError: true)
                return
            }
        }
        activeProductAction = action
        activeProductID = productID
        showOperation("正在\(action.localizedTitle)\(productID.localizedName)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProductManager(
                manager,
                arguments: [action.rawValue, "--product", productID.rawValue] + extraArguments
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeProductAction = nil
                self.activeProductID = nil
                if result.status == 0 {
                    self.showOperation(result.output.isEmpty ? "已请求\(action.localizedTitle)\(productID.localizedName)。" : result.output)
                } else {
                    let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
                    if action == .launch || action == .restart {
                        self.presentLaunchFailure(
                            productID: productID,
                            code: LaunchFailureClassifier.gameLaunchCode(for: detail),
                            summary: LaunchFailureClassifier.boundedReason(
                                from: detail,
                                fallback: "游戏没有进入运行状态，请稍后重试。"
                            )
                        )
                    } else {
                        self.showOperation("\(action.localizedTitle)\(productID.localizedName)失败：\(detail)", isError: true)
                    }
                }
                self.refreshProductStatus()
                self.refreshRuntimeStatusAfterDelay()
            }
        }
    }

    private func prepareLoginAndProductInParallel(
        _ action: GameProductAction,
        productID: GameProductID,
        manager: URL
    ) {
        activeProductAction = action
        activeProductID = productID
        showOperation("正在并行准备 IDV Login 与\(productID.localizedName)运行环境…")

        let preparation = ProductLaunchPreparation()
        ensureLoginReady { result in
            preparation.finishLogin(result: result)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runProductManager(
                manager,
                arguments: ["prepare-launch", "--product", productID.rawValue]
            )
            preparation.finishPreflight(status: result.status, output: result.output)
        }
        preparation.group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let result = preparation.snapshot()
            self.activeProductAction = nil
            self.activeProductID = nil
            if self.resumeLoginAuthorizationIfNeeded(result.loginResult, productAction: (action, productID)) { return }
            guard result.loginResult.isReady else {
                self.clearPendingLauncherHangRestart(for: productID)
                self.presentLaunchFailure(
                    productID: productID,
                    code: result.loginResult.code,
                    summary: result.loginResult.summary
                )
                return
            }
            guard result.preflightStatus == 0 else {
                self.clearPendingLauncherHangRestart(for: productID)
                let detail = result.preflightOutput.isEmpty
                    ? "启动前检查退出码 \(result.preflightStatus)"
                    : result.preflightOutput
                self.presentLaunchFailure(
                    productID: productID,
                    code: "IDV-LAUNCH-201",
                    summary: LaunchFailureClassifier.boundedReason(
                        from: detail,
                        fallback: "游戏启动前检查没有通过，请修复游戏后重试。"
                    )
                )
                return
            }
            self.runProductAction(action, productID: productID, manager: manager, extraArguments: [])
        }
    }

    func productActionIsRunning(_ action: GameProductAction, productID: GameProductID) -> Bool {
        activeProductAction == action && activeProductID == productID
    }

    var productActionIsBusy: Bool { activeProductAction != nil || runtimePrerequisiteCheckIsRunning }

    func cancelInstallerDownload() {
        guard activeProductAction == .install,
              let process = productInstallProcess,
              process.isRunning else { return }
        cancelledProductInstallPID = process.processIdentifier
        if downloadProgress?.phase == "runtime" {
            showOperation("正在安全取消共享兼容环境下载并清理临时文件…")
            // The manager forwards termination only to its exact RuntimeBootstrap
            // child and waits for its HTTP/mount cleanup contract.
            process.terminate()
            return
        }
        writeInstallerControl(action: "cancel", success: "正在请求安全取消下载并收束下载进程…")
        // A normal cancel is acknowledged by the supervisor, which owns the
        // Wine/downloadIPC process group.  Only if that contract stalls do we
        // terminate this exact manager PID; never search/kill broad processes.
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.productInstallProcess?.processIdentifier == pid,
                  process.isRunning else { return }
            process.terminate()
        }
    }

    func setInstallerPaused(_ paused: Bool) {
        guard downloadProgress?.phase == "downloading" else {
            showOperation("当前安装阶段不支持暂停；可以安全取消，进入游戏本体下载后再暂停或继续。")
            return
        }
        let globalBoundary = activeProductID == .global && paused
        writeInstallerControl(action: paused ? "pause" : "resume",
                              success: globalBoundary ? "国际服会在当前文件校验完成后暂停；已下载内容会保留。" : (paused ? "下载已请求暂停；保留已下载内容。" : "下载已请求继续。"))
    }

    private func writeInstallerControl(action: String, success: String) {
        guard activeProductAction == .install else { return }
        guard let control = productInstallControlURL else { return }
        let parent = control.deletingLastPathComponent()
        do {
            // The manager alone owns creation of the installation root and its
            // transaction marker.  A premature UI click must never fabricate
            // `work/` before that marker exists.
            guard FileManager.default.fileExists(atPath: parent.path) else {
                showOperation("下载控制将在准备安装目录后可用。")
                return
            }
            let payload: [String: Any] = ["schemaVersion": 1, "sequence": UInt64(Date().timeIntervalSince1970 * 1_000), "action": action]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let temporary = parent.appendingPathComponent(".download-control-\(UUID().uuidString)")
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: control.path) {
                _ = try FileManager.default.replaceItemAt(control, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temporary, to: control)
            }
            showOperation(success)
        } catch {
            showOperation("无法更新下载控制：\(error.localizedDescription)", isError: true)
        }
    }

    private func startInstallerDownload(productID: GameProductID, manager: URL, destinationParent: URL) {
        activeProductAction = .install
        activeProductID = productID
        downloadProgress = ProductDownloadProgress(productID: productID, phase: "resolving")
        productInstallOutput = ""
        productInstallStdoutBuffer.removeAll(keepingCapacity: true)
        productInstallStderrBuffer.removeAll(keepingCapacity: true)
        cancelledProductInstallPID = nil
        // This is already the complete launcher-owned root
        // (…/第五人格/CN or …/第五人格/Global). Keep the transaction marker,
        // work directory and game tree directly beneath it.
        let targetRoot = destinationParent
        do {
            productInstallAttemptLog = try InstallAttemptLog.start(
                root: ToolboxPath.userSupport.appendingPathComponent("Diagnostics/InstallAttempts", isDirectory: true),
                productID: productID,
                targetPath: targetRoot.path
            )
        } catch {
            activeProductAction = nil
            activeProductID = nil
            downloadProgress = nil
            showOperation("无法建立本地安装诊断记录：\(error.localizedDescription)", isError: true)
            return
        }
        productInstallControlURL = destinationParent
            .appendingPathComponent("work/download-control.json")
        showOperation("正在检查安装空间并解析\(productID.localizedName)游戏文件…")

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = manager
        process.arguments = [GameProductAction.install.rawValue, "--product", productID.rawValue,
                             "--destination-parent", destinationParent.path]
        process.standardOutput = stdout
        process.standardError = stderr
        configureInstallerPipe(stdout, isError: false)
        configureInstallerPipe(stderr, isError: true)
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.finishInstallerDownload(processIdentifier: task.processIdentifier, status: task.terminationStatus)
            }
        }
        productInstallProcess = process
        productInstallStdout = stdout
        productInstallStderr = stderr
        do {
            try process.run()
            // Do not wait for this acknowledgement.  In particular, the
            // first manager progress event can take a little while on a cold
            // install, but this is only presented after the process exists.
            showsInitialInstallDownloadNotice = true
        } catch {
            productInstallAttemptLog?.terminal(
                status: 1,
                cancelled: false,
                summary: "无法启动官方安装器下载：\(error.localizedDescription)"
            )
            productInstallAttemptLog = nil
            cleanupInstallerDownloadIO()
            productInstallProcess = nil
            productInstallControlURL = nil
            activeProductAction = nil
            activeProductID = nil
            showOperation("无法启动官方安装器下载：\(error.localizedDescription)", isError: true)
        }
    }

    private func configureInstallerPipe(_ pipe: Pipe, isError: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consumeInstallerData(data, isError: isError)
            }
        }
    }

    private func consumeInstallerData(_ data: Data, isError: Bool) {
        if isError {
            productInstallStderrBuffer.append(data)
            consumeInstallerLines(from: &productInstallStderrBuffer, isError: true)
        } else {
            productInstallStdoutBuffer.append(data)
            consumeInstallerLines(from: &productInstallStdoutBuffer, isError: false)
        }
    }

    private func consumeInstallerLines(from buffer: inout Data, isError: Bool) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            consumeInstallerLine(String(decoding: lineData, as: UTF8.self), isError: isError)
        }
    }

    private func consumeInstallerLine(_ rawLine: String, isError: Bool) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if isError, let event = try? JSONDecoder().decode(ProductDownloadProgressEvent.self, from: Data(line.utf8)) {
            guard event.productId == activeProductID else { return }
            productInstallAttemptLog?.progress(event)
            if event.event == "completed" || event.phase == "completed" {
                downloadProgress = nil
                showOperation("\(event.productId.localizedName)游戏文件已校验，正在完成安装…")
                refreshProductStatus()
                return
            }
            downloadProgress = ProductDownloadProgress(event: event, previous: downloadProgress, now: Date())
            switch event.phase {
            case "resolving": showOperation("正在解析\(event.productId.localizedName)官方游戏清单…")
            case "runtime": showOperation("正在取得并校验两服共享的兼容环境（首次约 327 MB）…")
            case "preparing": showOperation("正在准备独立兼容环境…")
            case "downloading": showOperation("正在下载\(event.productId.localizedName)游戏本体…")
            case "verifying": showOperation("正在校验游戏文件…")
            case "publishing": showOperation("正在写入最终游戏文件…")
            default: break
            }
            return
        }
        productInstallAttemptLog?.output(line, stream: isError ? "stderr" : "stdout")
        productInstallOutput += (isError ? "" : "") + line + "\n"
        if productInstallOutput.count > 16_000 {
            productInstallOutput.removeFirst(productInstallOutput.count - 16_000)
        }
    }

    private func finishInstallerDownload(processIdentifier: Int32, status: Int32) {
        guard productInstallProcess?.processIdentifier == processIdentifier else { return }
        // Drain the final incomplete line after the pipe closes.
        if !productInstallStdoutBuffer.isEmpty {
            consumeInstallerLine(String(decoding: productInstallStdoutBuffer, as: UTF8.self), isError: false)
        }
        if !productInstallStderrBuffer.isEmpty {
            consumeInstallerLine(String(decoding: productInstallStderrBuffer, as: UTF8.self), isError: true)
        }
        let wasCancelled = cancelledProductInstallPID == processIdentifier
        let completedProductID = activeProductID
        let summary = productInstallOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        productInstallAttemptLog?.terminal(status: status, cancelled: wasCancelled, summary: summary)
        productInstallAttemptLog = nil
        cleanupInstallerDownloadIO()
        productInstallProcess = nil
        productInstallControlURL = nil
        activeProductAction = nil
        activeProductID = nil
        cancelledProductInstallPID = nil
        downloadProgress = nil
        if wasCancelled {
            clearInstallCompletionPresentation()
            showOperation("已取消游戏下载；未完成内容保留在受管缓存中，可再次选择同一位置继续。")
        } else if status == 0 {
            if let completedProductID {
                presentInstallCompletion(for: completedProductID)
            }
            showOperation(summary.isEmpty
                ? "游戏本体已安装并通过校验，可以启动游戏了。"
                : summary)
        } else {
            clearInstallCompletionPresentation()
            showOperation("安装游戏失败：\(summary.isEmpty ? "退出码 \(status)" : summary)", isError: true)
        }
        refreshProductStatus()
    }

    private func presentInstallCompletion(for productID: GameProductID) {
        let generation = UUID()
        installCompletionGeneration = generation
        recentlyCompletedProductID = productID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.installCompletionGeneration == generation else { return }
            self.recentlyCompletedProductID = nil
        }
    }

    private func clearInstallCompletionPresentation() {
        installCompletionGeneration = UUID()
        recentlyCompletedProductID = nil
    }

    func dismissInitialInstallDownloadNotice() {
        showsInitialInstallDownloadNotice = false
    }

    func initialInstallDownloadNoticeDidDismiss() {
        // Present another alert only once the compact sheet has finished
        // closing; an in-flight dismissal must not hide the permission notice.
        presentPendingLoginInstallationAuthorizationIfNeeded()
    }

    private func requestLoginInstallationAuthorization() {
        guard !shouldConfirmLoginInstallationAuthorization else { return }
        if showsInitialInstallDownloadNotice {
            loginInstallationAuthorizationPresentationPending = true
        } else {
            shouldConfirmLoginInstallationAuthorization = true
        }
    }

    private func presentPendingLoginInstallationAuthorizationIfNeeded() {
        guard loginInstallationAuthorizationPresentationPending,
              !showsInitialInstallDownloadNotice,
              !shouldConfirmLoginInstallationAuthorization else { return }
        loginInstallationAuthorizationPresentationPending = false
        shouldConfirmLoginInstallationAuthorization = true
    }

    private func cleanupInstallerDownloadIO() {
        productInstallStdout?.fileHandleForReading.readabilityHandler = nil
        productInstallStderr?.fileHandleForReading.readabilityHandler = nil
        productInstallStdout = nil
        productInstallStderr = nil
        productInstallStdoutBuffer.removeAll(keepingCapacity: false)
        productInstallStderrBuffer.removeAll(keepingCapacity: false)
    }

    func openLogin() {
        guard !loginMutationIsBusy else { return }
        guard !runtimeStatus.loginIsActive else {
            showOperation(runtimeStatus.loginProxyReady
                ? "IDV Login 已就绪；请选择服务器后再启动或重启对应游戏。"
                : "IDV Login 已有进程正在初始化或配置异常；请先等待或关闭后再手动启动。")
            return
        }
        guard loginComponentIsInstalled else {
            showOperation("请先安装固定的 IDV Login \(IdvLoginRelease.version) 组件。", isError: true)
            return
        }
        // This ordinary file inspection is deliberately before *every* start
        // path.  An old helper interpreted any argument as a normal launch,
        // so even a well-intentioned readiness/status call could create a
        // launch storm.
        guard Self.loginHelperContainsCurrentStatusContract(at: ToolboxPath.startLoginHelper) else {
            showOperation("已安装的 IDV Login helper 版本过旧；请重新安装 IDV Login 组件后再启动。", isError: true)
            return
        }
        guard loginCertificateTrustNoticeAcknowledged else {
            pendingManualLoginStart = true
            shouldConfirmLoginCertificateTrust = true
            return
        }
        startLoginAfterTrustNotice()
    }

    private var loginCertificateTrustNoticeAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: "idvLoginCertificateTrustNoticeAcknowledged")
    }

    func acceptLoginCertificateTrustNotice() {
        // Starting the helper here could put the system prompt on top of a
        // sheet that is still closing. Only onDismiss may continue the start.
        loginTrustDecision = showsSkipLoginConfirmation ? .skipLogin : .authorize
        shouldConfirmLoginCertificateTrust = false
    }

    func loginCertificateTrustNoticeDidDismiss() {
        let decision = loginTrustDecision
        let productAction = pendingLoginTrustProductAction
        let manualStart = pendingManualLoginStart
        loginTrustDecision = nil
        showsSkipLoginConfirmation = false
        pendingLoginTrustProductAction = nil
        pendingManualLoginStart = false
        guard let decision else {
            // If the modal was dismissed without a decision, do not leave a
            // prior hang approval armed for a later unrelated restart.
            pendingLauncherHangRestart = nil
            return
        }
        switch decision {
        case .authorize:
            UserDefaults.standard.set(true, forKey: "idvLoginCertificateTrustNoticeAcknowledged")
            if let pending = productAction {
                performProductAction(pending.0, for: pending.1)
            } else if manualStart {
                startLoginAfterTrustNotice()
            }
        case .skipLogin:
            // Persist before dispatch so this launch bypasses the IDV helper.
            setIdvLoginFollowGameEnabled(false)
            performProductAction(productAction?.0 ?? .launch,
                                 for: productAction?.1 ?? selectedProductID)
        }
    }

    func declineLoginCertificateTrustNotice() {
        // Cancel asks whether to skip; Return restores the first prompt.
        // Both are presentation-only: they never dispatch a helper or game.
        loginTrustDecision = nil
        showsSkipLoginConfirmation.toggle()
    }

    private func startLoginAfterTrustNotice() {
        loginStartIsRunning = true
        showOperation("正在启动 IDV Login…")
        ensureLoginReady { [weak self] result in
            guard let self else { return }
            self.loginStartIsRunning = false
            if self.resumeLoginAuthorizationIfNeeded(result) { return }
            if result.isReady {
                self.clearLaunchFailure()
                self.showOperation("IDV Login 已就绪；本机登录代理可用。")
            } else {
                self.presentLaunchFailure(productID: nil, code: result.code, summary: result.summary)
            }
        }
    }

    var loginComponentIsInstalled: Bool {
        IdvLoginRelease.isCurrent(
            installedVersion: runtimeStatus.loginComponentVersion,
            helperIsCurrent: FileManager.default.isExecutableFile(atPath: ToolboxPath.startLoginHelper.path)
                && Self.loginHelperContainsCurrentStatusContract(at: ToolboxPath.startLoginHelper))
    }

    var loginComponentNeedsUpdate: Bool {
        runtimeStatus.loginComponentVersion != nil
            && !loginComponentIsInstalled
    }

    @Published var shouldOfferIdvLoginPrompt: Bool = false
    @Published var shouldConfirmLoginInstallationAuthorization: Bool = false

    func acceptIdvLoginPrompt() {
        UserDefaults.standard.set(true, forKey: "idvLoginPromptAnswered")
        shouldOfferIdvLoginPrompt = false
        installLoginComponent()
    }

    func acceptInitialIdvLoginOffer() { acceptIdvLoginPrompt() }

    func declineIdvLoginPrompt() {
        UserDefaults.standard.set(true, forKey: "idvLoginPromptAnswered")
        shouldOfferIdvLoginPrompt = false
        showOperation("已跳过 idv-login；之后可随时在启动器中安装。")
    }

    func declineInitialIdvLoginOffer() { declineIdvLoginPrompt() }

    func setIdvLoginFollowGameEnabled(_ enabled: Bool) {
        if !enabled {
            idvLoginEnabled = false
            UserDefaults.standard.set(false, forKey: "idvLoginFollowGameLaunchEnabled")
            showOperation("已关闭“跟随游戏启动”；仍可在组件可用时手动启动 IDV Login。")
            return
        }
        guard !enabled || loginComponentIsInstalled else {
            idvLoginEnabled = false
            UserDefaults.standard.set(false, forKey: "idvLoginFollowGameLaunchEnabled")
            showOperation("请先安装 IDV Login，再开启“跟随游戏启动”。", isError: true)
            return
        }
        idvLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "idvLoginFollowGameLaunchEnabled")
        showOperation("已开启“跟随游戏启动”；首次使用前会说明本地证书信任授权。")
    }

    func checkForLauncherUpdate() {
        // Alpha 1 deliberately has no trusted update feed/signing key yet.
        // Keep the visible action honest rather than silently contacting an
        // unconfigured endpoint or presenting a fake one-click updater.
        showOperation("当前版本 \(LauncherRelease.displayVersion)。此版本尚未提供自动更新；下载新版安装镜像后，退出启动器并替换应用即可。")
    }

    func prepareFeedback(title: String, description: String,
                          completion: @escaping (FeedbackBundle?, String?) -> Void) {
        guard !feedbackIsSending else { return }
        // Either field alone is a usable report; the ZIP always carries what the
        // user typed, with the title kept as a readable header.
        let packaged = FeedbackMailComposer.packagedDescription(title: title, description: description)
        let normalized = packaged.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard let exporter = Bundle.main.url(forResource: "IdentityVDiagnosticExporter", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: exporter.path) else {
            showOperation("启动器中缺少诊断包导出器，请重新安装启动器。", isError: true)
            completion(nil, "启动器中缺少诊断包导出器，请重新安装启动器。")
            return
        }

        let scratch = ToolboxPath.feedbackScratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let descriptionURL = scratch.appendingPathComponent("description.txt")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = ToolboxPath.diagnosticExports
            .appendingPathComponent("第五人格-Mac-反馈-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).zip")

        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
            try FileManager.default.createDirectory(at: ToolboxPath.diagnosticExports, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ToolboxPath.diagnosticExports.path)
            try Data(packaged.utf8).write(to: descriptionURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptionURL.path)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            showOperation("无法准备反馈包：\(error.localizedDescription)", isError: true)
            completion(nil, "无法准备反馈包：\(error.localizedDescription)")
            return
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = exporter
        process.arguments = ["--output", output.path, "--description-file", descriptionURL.path]
        process.standardOutput = pipe
        process.standardError = pipe
        feedbackIsSending = true
        feedbackExportProcess = process
        showOperation("正在生成脱敏反馈包…")
        process.terminationHandler = { [weak self] task in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async {
                guard let self else { return }
                self.feedbackIsSending = false
                self.feedbackExportProcess = nil
                guard task.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: output.path) else {
                    let detail = text.isEmpty ? "退出码 \(task.terminationStatus)" : text
                    self.showOperation("生成反馈包失败：\(detail)", isError: true)
                    completion(nil, "生成反馈包失败：\(detail)")
                    return
                }
                guard let report = try? JSONDecoder().decode(FeedbackBundle.self, from: Data(text.utf8)),
                      report.archive == output.path else {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                    completion(nil, "反馈包已保存，但预览信息无法读取；已在 Finder 中显示。")
                    return
                }
                // Preparation is local. Channel choice happens only after the
                // user sees their original description and attachment list.
                self.showOperation("反馈包已生成，可以预览并选择反馈方式。")
                completion(report, nil)
            }
        }
        do {
            try process.run()
        } catch {
            feedbackIsSending = false
            feedbackExportProcess = nil
            try? FileManager.default.removeItem(at: scratch)
            showOperation("无法启动反馈包导出器：\(error.localizedDescription)", isError: true)
            completion(nil, "无法启动反馈包导出器：\(error.localizedDescription)")
        }
    }

    func uninstallLoginComponent() {
        guard !loginMutationIsBusy else { return }
        let uninstaller = ToolboxPath.installerPayload.appendingPathComponent("uninstallIdentityVPreview.command")
        guard FileManager.default.isExecutableFile(atPath: uninstaller.path) else {
            showOperation("找不到 IDV Login 组件卸载器，请重新安装启动器。", isError: true)
            return
        }
        loginUninstallIsRunning = true
        showOperation("将卸载 IDV Login；macOS 将显示 osascript 请求管理员授权，游戏与兼容环境会保留。")
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script quoted form of \"\(uninstaller.path)\" & \" --only-idv-login --execute\" with administrator privileges"]
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { [weak self] task in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.loginUninstallIsRunning = false
                if task.terminationStatus == 0 {
                    self?.idvLoginEnabled = false
                    UserDefaults.standard.set(false, forKey: "idvLoginFollowGameLaunchEnabled")
                    self?.resetLoginCertificateTrustNotice()
                    self?.runtimeStatus.loginComponentVersion = nil
                }
                self?.showOperation(task.terminationStatus == 0 ? "IDV Login 已卸载。" : "卸载 IDV Login 失败：\(text)", isError: task.terminationStatus != 0)
                self?.refreshRuntimeStatusAfterDelay()
            }
        }
        do { try process.run() } catch {
            loginUninstallIsRunning = false
            showOperation("无法启动 IDV Login 卸载器：\(error.localizedDescription)", isError: true)
        }
    }

    func installLoginComponent() {
        guard !loginMutationIsBusy else { return }
        guard !loginComponentIsInstalled else {
            showOperation("固定的 IDV Login 组件已安装；可直接启动后台。")
            return
        }
        // Runtime status refresh is asynchronous; immediately reinstalling
        // after uninstall must not inherit a stale installed-version snapshot.
        let freshInstall = !FileManager.default.isExecutableFile(atPath: ToolboxPath.startLoginHelper.path)
        let installer = ToolboxPath.loginInstaller
        let payload = ToolboxPath.installerPayload
        guard FileManager.default.isExecutableFile(atPath: installer.path),
              FileManager.default.fileExists(atPath: payload.path),
              FileManager.default.isExecutableFile(atPath: ToolboxPath.idvLoginDownloader.path),
              FileManager.default.fileExists(atPath: ToolboxPath.idvLoginManifest.path) else {
            showOperation("启动器中缺少 IDV Login 安装组件，请重新安装启动器。", isError: true)
            return
        }

        loginInstallIsRunning = true
        loginInstallPhase = "正在下载 IDV Login…"
        loginInstallProgress = 0
        loginDownloadErrorOutput = ""
        // A version-scoped stable slot is intentionally shared across app
        // restarts. The downloader owns locking, legacy UUID reuse and Range
        // resume; this UI must not create a fresh cache for every click.
        let downloadCache = ToolboxPath.idvLoginDownloadCache
            .appendingPathComponent(IdvLoginRelease.version, isDirectory: true)
        showOperation("正在下载并校验 IDV Login \(IdvLoginRelease.version)…")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stderrCollector = BoundedLineCollector()
        let ioQueue = DispatchQueue(label: "com.fengyin.identityv.idv-login-download-io")
        process.executableURL = ToolboxPath.idvLoginDownloader
        process.arguments = [ToolboxPath.idvLoginManifest.path, downloadCache.path]
        process.standardOutput = stdout
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            ioQueue.async {
                let lines = stderrCollector.append(data)
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async { lines.forEach { self?.consumeLoginDownloadLine($0) } }
            }
        }
        process.terminationHandler = { [weak self] task in
            stderr.fileHandleForReading.readabilityHandler = nil
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrRemainder = stderr.fileHandleForReading.readDataToEndOfFile()
            ioQueue.async {
                let finalLines = stderrCollector.append(stderrRemainder, finish: true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    finalLines.forEach { self.consumeLoginDownloadLine($0) }
                    let componentPath = String(decoding: stdoutData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finishLoginComponentDownload(
                        status: task.terminationStatus,
                        componentPath: componentPath,
                        installer: installer,
                        payload: payload,
                        downloadCache: downloadCache,
                        freshInstall: freshInstall
                    )
                }
            }
        }
        loginDownloadProcess = process
        loginDownloadStdout = stdout
        loginDownloadStderr = stderr
        do {
            try process.run()
        } catch {
            loginInstallIsRunning = false
            loginInstallPhase = nil
            loginInstallProgress = nil
            loginDownloadProcess = nil
            loginDownloadStdout = nil
            loginDownloadStderr = nil
            showOperation("无法启动 IDV Login 安装器：\(error.localizedDescription)", isError: true)
        }
    }

    private func consumeLoginDownloadLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if let event = try? JSONDecoder().decode(IdvLoginDownloadProgressEvent.self, from: Data(line.utf8)),
           event.schemaVersion == 1, event.totalBytesExpected > 0,
           event.bytesWritten >= 0, event.bytesWritten <= event.totalBytesExpected {
            loginInstallProgress = Double(event.bytesWritten) / Double(event.totalBytesExpected)
            switch event.phase {
            case "downloading": loginInstallPhase = "正在下载 IDV Login…"
            case "verifying": loginInstallPhase = "正在验证 IDV Login…"
            default: break
            }
            return
        }
        if !loginDownloadErrorOutput.isEmpty { loginDownloadErrorOutput += "\n" }
        loginDownloadErrorOutput += line
        if loginDownloadErrorOutput.count > 4_096 {
            loginDownloadErrorOutput.removeFirst(loginDownloadErrorOutput.count - 4_096)
        }
    }

    private func finishLoginComponentDownload(
        status: Int32,
        componentPath: String,
        installer: URL,
        payload: URL,
        downloadCache: URL,
        freshInstall: Bool
    ) {
        loginDownloadProcess = nil
        loginDownloadStdout = nil
        loginDownloadStderr = nil
        if status == 0, !componentPath.isEmpty {
            let component = URL(fileURLWithPath: componentPath)
            guard FileManager.default.isReadableFile(atPath: component.path) else {
                loginInstallIsRunning = false
                loginInstallPhase = nil
                loginInstallProgress = nil
                showOperation("安装 IDV Login 失败：下载组件不可读。", isError: true)
                return
            }
            pendingLoginComponent = component
            pendingLoginInstaller = installer
            pendingLoginPayload = payload
            pendingLoginDownloadCache = downloadCache
            pendingLoginInstallationWasFresh = freshInstall
            loginInstallIsRunning = false
            loginInstallPhase = "等待管理员授权…"
            loginInstallProgress = nil
            requestLoginInstallationAuthorization()
        } else {
            loginInstallationAuthorizationPresentationPending = false
            loginInstallIsRunning = false
            loginInstallPhase = nil
            loginInstallProgress = nil
            let detail = loginDownloadErrorOutput.isEmpty ? "退出码 \(status)" : loginDownloadErrorOutput
            showOperation("安装 IDV Login 失败：\(detail)", isError: true)
        }
        refreshRuntimeStatusAfterDelay()
    }

    private var pendingLoginComponent: URL?
    private var pendingLoginInstaller: URL?
    private var pendingLoginPayload: URL?
    private var pendingLoginDownloadCache: URL?
    private var pendingLoginInstallationWasFresh = false

    func acceptLoginInstallationAuthorization() {
        shouldConfirmLoginInstallationAuthorization = false
        loginInstallationAuthorizationPresentationPending = false
        guard let component = pendingLoginComponent,
              let installer = pendingLoginInstaller,
              let payload = pendingLoginPayload,
              let downloadCache = pendingLoginDownloadCache else {
            showOperation("IDV Login 安装准备已失效，请重新安装。", isError: true)
            return
        }
        let freshInstall = pendingLoginInstallationWasFresh
        pendingLoginComponent = nil
        pendingLoginInstaller = nil
        pendingLoginPayload = nil
        pendingLoginDownloadCache = nil
        pendingLoginInstallationWasFresh = false
        loginInstallIsRunning = true
        loginInstallPhase = "正在安装 IDV Login…"
        loginInstallProgress = nil
        installDownloadedLoginComponent(
            component,
            installer: installer,
            payload: payload,
            downloadCache: downloadCache,
            freshInstall: freshInstall
        )
    }

    func declineLoginInstallationAuthorization() {
        shouldConfirmLoginInstallationAuthorization = false
        loginInstallationAuthorizationPresentationPending = false
        let downloadCache = pendingLoginDownloadCache
        let freshInstall = pendingLoginInstallationWasFresh
        pendingLoginComponent = nil
        pendingLoginInstaller = nil
        pendingLoginPayload = nil
        pendingLoginDownloadCache = nil
        pendingLoginInstallationWasFresh = false
        loginInstallIsRunning = false
        loginInstallPhase = nil
        loginInstallProgress = nil
        if freshInstall {
            idvLoginEnabled = false
            UserDefaults.standard.set(false, forKey: "idvLoginFollowGameLaunchEnabled")
        }
        if let downloadCache { clearLoginDownloadAfterAuthorizationDecline(downloadCache) }
        showOperation("已取消 IDV Login 安装；未请求管理员授权，并已清除本轮下载组件。")
    }

    private func installDownloadedLoginComponent(
        _ component: URL,
        installer: URL,
        payload: URL,
        downloadCache: URL,
        freshInstall: Bool
    ) {
        showOperation("已校验 IDV Login；macOS 将显示 osascript 请求管理员授权进行安装。")
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [installer.path, "--payload-root", payload.path, "--component", component.path]
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { [weak self] task in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginInstallIsRunning = false
                self.loginInstallPhase = nil
                self.loginInstallProgress = nil
                guard task.terminationStatus == 0 else { self.showOperation("安装 IDV Login 失败：\(text.isEmpty ? "退出码 \(task.terminationStatus)" : text)", isError: true); return }
                self.refreshRuntimeStatusAfterDelay()
                // Every installation, including repair/update/reinstall, must
                // explain the next component start before system trust UI.
                self.resetLoginCertificateTrustNotice()
                if freshInstall {
                    self.idvLoginEnabled = true
                    UserDefaults.standard.set(true, forKey: "idvLoginFollowGameLaunchEnabled")
                    self.showOperation("IDV Login 已安装；已默认开启“跟随游戏启动”，不会立即启动后台。")
                } else {
                    self.showOperation("IDV Login 组件已更新；已保留现有“跟随游戏启动”设置。")
                }
            }
        }
        do {
            try process.run()
        } catch {
            loginInstallIsRunning = false
            loginInstallPhase = nil
            loginInstallProgress = nil
            showOperation("无法启动 IDV Login 安装器：\(error.localizedDescription)", isError: true)
        }
    }

    /// Authorization was declined before installation. Unlike transport or
    /// installer failures, this is an explicit request to discard the newly
    /// staged component. Successful/failed installs intentionally retain the
    /// verified final file for a later repair or reinstall.
    private func clearLoginDownloadAfterAuthorizationDecline(_ cache: URL) {
        let root = ToolboxPath.idvLoginDownloadCache.standardizedFileURL
        let candidate = cache.standardizedFileURL
        guard candidate.deletingLastPathComponent() == root,
              candidate.lastPathComponent == IdvLoginRelease.version else { return }
        let final = candidate.appendingPathComponent(IdvLoginRelease.assetName)
        let partial = final.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: final)
        try? FileManager.default.removeItem(at: partial)
    }

    private func resetLoginCertificateTrustNotice() {
        UserDefaults.standard.removeObject(forKey: "idvLoginCertificateTrustNoticeAcknowledged")
        shouldConfirmLoginCertificateTrust = false
        pendingLoginTrustProductAction = nil
        pendingManualLoginStart = false
        loginTrustDecision = nil
        showsSkipLoginConfirmation = false
    }

    @discardableResult
    private func resumeLoginAuthorizationIfNeeded(
        _ result: LoginStartupResult,
        productAction: (GameProductAction, GameProductID)? = nil
    ) -> Bool {
        guard result == .waitingForAuthorization else { return false }
        resetLoginCertificateTrustNotice()
        clearLaunchFailure()
        runtimeStatus.loginProcessStarting = false
        runtimeStatus.loginProxyReady = false
        runtimeStatus.loginReadinessProblem = false
        pendingLoginTrustProductAction = productAction
        pendingManualLoginStart = productAction == nil
        showOperation(result.summary)
        shouldConfirmLoginCertificateTrust = true
        return true
    }

    private func ensureLoginReady(completion: @escaping (LoginStartupResult) -> Void) {
        if runtimeStatus.loginProxyReady { completion(.ready); return }
        guard runtimeStatus.loginComponentVersion != nil,
              FileManager.default.isExecutableFile(atPath: ToolboxPath.startLoginHelper.path) else {
            completion(.failed(code: "IDVL-START-101", summary: "IDV Login 组件尚未安装，无法跟随游戏启动。"))
            return
        }
        // Never invoke an unrecognised installed helper.  This is repeated
        // here because launch/restart and post-install flows bypass openLogin.
        guard Self.loginHelperContainsCurrentStatusContract(at: ToolboxPath.startLoginHelper) else {
            completion(.failed(code: "IDVL-START-102", summary: "IDV Login helper 版本过旧，请重新安装 IDV Login 组件。"))
            return
        }
        // Defense at the actual process boundary, including background restart
        // paths that do not pass through openLogin / performProductAction.
        guard loginCertificateTrustNoticeAcknowledged else {
            completion(.failed(code: "IDVL-START-105", summary: "尚未确认 IDV Login 首次授权提示，请从启动器重新启动。"))
            return
        }
        let gate = LoginStartupGate.acquire()
        let isLeader = gate.isLeader
        let ticket = gate.ticket
        DispatchQueue.global(qos: .userInitiated).async {
            if !isLeader {
                let result = ticket.resultAfterWaiting()
                DispatchQueue.main.async { completion(result) }
                return
            }
            let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", ToolboxPath.startLoginHelper.path]; process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                // Drain while the helper is alive.  Its controlled stderr can
                // include a system-tool diagnostic; waiting first can fill the
                // pipe and deadlock before the bounded initialization wait.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                let result = LoginStartupResult.fromHelper(status: process.terminationStatus, output: output)
                LoginStartupGate.finish(ticket, result: result)
                DispatchQueue.main.async {
                    self.refreshRuntimeStatusAfterDelay()
                    completion(result)
                }
            } catch {
                let result = LoginStartupResult.failed(
                    code: "IDVL-START-104",
                    summary: "macOS 无法调用 IDV Login helper：\(error.localizedDescription)"
                )
                LoginStartupGate.finish(ticket, result: result)
                DispatchQueue.main.async { completion(result) }
                return
            }
        }
    }

    func relaunchGame() {
        guard !gameRestartIsRunning else { return }
        guard let restartTool = Bundle.main.url(
            forResource: "restartIdentityVGame",
            withExtension: "command"
        ), FileManager.default.isExecutableFile(atPath: restartTool.path) else {
            showOperation("启动器中缺少快速重启组件，请重新安装启动器。", isError: true)
            return
        }

        let wasRunning = isGameRunningNow()
        gameRestartIsRunning = true
        showOperation(wasRunning ? "正在收束旧游戏会话并立即重启；IDV Login 保持运行…" : "第五人格未运行，正在启动…")

        let process = Process()
        let output = Pipe()
        process.executableURL = restartTool
        process.arguments = ["--stop-for-restart"]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gameRestartIsRunning = false
                guard task.terminationStatus == 0 else {
                    let detail = text.isEmpty ? "退出码 \(task.terminationStatus)" : text
                    self.showOperation("无法重启第五人格：\(detail)", isError: true)
                    self.refreshRuntimeStatusAfterDelay()
                    return
                }
                let success = wasRunning
                    ? "旧游戏会话已结束并重新启动；IDV Login 保持运行。"
                    : "第五人格已启动。"
                self.launchEmbeddedGameRunner(successMessage: success)
            }
        }

        do {
            try process.run()
        } catch {
            gameRestartIsRunning = false
            showOperation("无法运行快速重启组件：\(error.localizedDescription)", isError: true)
        }
    }

    func toggleOverlay() {
        openApplication(at: ToolboxPath.overlayApp, createsNewInstance: false, label: "第五人格工具箱")
    }

    func setMouseAccelerationDisabled(_ disabled: Bool) {
        do {
            try LauncherEnvironmentFile.writeMouseAcceleration(
                disabled: disabled,
                to: ToolboxPath.launcherEnvironment
            )
            mouseAccelerationDisabled = disabled
            showOperation("鼠标加速度实验设置已保存，将在下次启动游戏时生效。")
        } catch {
            loadLauncherPreferences()
            showOperation("无法更新 launcher.env：\(error.localizedDescription)", isError: true)
        }
    }

    func startDenseMonitoring() {
        guard let denseMonitoringController else {
            showOperation("工具箱中缺少高密度采集器，请重新构建。", isError: true)
            return
        }
        let snapshot = Self.processDetailsSnapshot()
        denseMonitoringState = denseMonitoringController.start(
            gamePID: Self.gamePID(in: snapshot), snapshot: snapshot
        )
        showOperation("已请求高密度记录；它只采样当前游戏进程，不会注入或影响游戏。")
    }

    func stopDenseMonitoring() {
        guard let denseMonitoringController else { return }
        switch denseMonitoringController.stop(snapshot: Self.processDetailsSnapshot()) {
        case .some(.stopped):
            denseMonitoringState = .idle
            showOperation("已确认停止工具箱创建且已验证的高密度采集器；手动采集器保持不动。")
        case .some(.stillRunning):
            showOperation("高密度采集器仍在运行，未将其标为已停止；请稍后重试。", isError: true)
        case .some(.notOwned), .none:
            showOperation("未找到可由工具箱安全停止的当前采集器；未改变采集状态。", isError: true)
        }
    }

    func stopLoginBackground() {
        stopLoginBackground(restartAfterStopping: false)
    }

    func restartLoginBackground() {
        guard !loginMutationIsBusy else { return }
        guard loginComponentIsInstalled else {
            showOperation("请先安装固定的 IDV Login \(IdvLoginRelease.version) 组件。", isError: true)
            return
        }
        guard runtimeStatus.loginIsActive else {
            openLogin()
            return
        }
        stopLoginBackground(restartAfterStopping: true)
    }

    private func stopLoginBackground(restartAfterStopping: Bool) {
        guard !loginMutationIsBusy else { return }
        guard FileManager.default.isExecutableFile(atPath: ToolboxPath.stopLoginScript.path) else {
            showOperation("找不到可执行的 stopIdentityVIdvLogin.command。", isError: true)
            return
        }

        loginStopIsRunning = true
        showOperation(restartAfterStopping
            ? "正在结束并重新启动 IDV Login…"
            : "正在关闭 IDV Login；若出现管理员授权窗口，请在系统窗口中确认。")

        let process = Process()
        let output = Pipe()
        process.executableURL = ToolboxPath.stopLoginScript
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginStopIsRunning = false
                if task.terminationStatus == 0 {
                    self.runtimeStatus.loginProcessStarting = false
                    self.runtimeStatus.loginProxyReady = false
                    self.runtimeStatus.loginReadinessProblem = false
                    self.runtimeStatus.checkedAt = Date()
                    if restartAfterStopping {
                        guard self.loginCertificateTrustNoticeAcknowledged else {
                            self.pendingManualLoginStart = true
                            self.shouldConfirmLoginCertificateTrust = true
                            return
                        }
                        self.loginStartIsRunning = true
                        self.showOperation("旧 IDV Login 会话已结束，正在重新启动…")
                        self.ensureLoginReady { [weak self] result in
                            guard let self else { return }
                            self.loginStartIsRunning = false
                            if self.resumeLoginAuthorizationIfNeeded(result) { return }
                            if result.isReady {
                                self.clearLaunchFailure()
                                self.showOperation("IDV Login 已重新启动并就绪。")
                            } else {
                                self.presentLaunchFailure(productID: nil, code: result.code, summary: result.summary)
                            }
                            self.refreshRuntimeStatusAfterDelay()
                        }
                    } else {
                        self.showOperation(text.isEmpty ? "IDV Login 后台已关闭。" : text)
                        self.refreshRuntimeStatusAfterDelay()
                    }
                } else {
                    self.showOperation(
                        text.isEmpty ? "关闭 IDV Login 失败，退出码 \(task.terminationStatus)。" : text,
                        isError: true
                    )
                    self.refreshRuntimeStatusAfterDelay()
                }
            }
        }

        do {
            try process.run()
        } catch {
            loginStopIsRunning = false
            showOperation("无法运行关闭脚本：\(error.localizedDescription)", isError: true)
        }
    }

    func startProbe() {
        guard !probePhase.isActive else { return }
        guard isGameRunningNow() else {
            probePhase = .failed
            probeStatusText = "第五人格未运行"
            showOperation("请先启动并进入第五人格，再开始输入延迟测量。工具箱不会自动启动游戏。", isError: true)
            refreshRuntimeStatus()
            return
        }
        guard let probeURL = Bundle.main.url(forResource: "IdentityVInputLatencyProbe", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: probeURL.path) else {
            probePhase = .failed
            probeStatusText = "嵌入的延迟探针不可用"
            showOperation("工具箱资源中缺少 IdentityVInputLatencyProbe，请重新构建工具箱。", isError: true)
            return
        }

        resetProbeStateForRun()
        probePhase = .waitingForGame
        probeStatusText = "探针已启动，请在 30 秒内切回第五人格"
        probeStartedAt = Date()

        let process = Process()
        probeStdout = Pipe()
        probeStderr = Pipe()
        process.executableURL = probeURL
        process.arguments = ["--duration", "18"]
        process.currentDirectoryURL = ToolboxPath.probeWorkingDirectory
        process.standardOutput = probeStdout
        process.standardError = probeStderr
        configureProbePipe(probeStdout, isError: false)
        configureProbePipe(probeStderr, isError: true)
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.finishProbe(processIdentifier: task.processIdentifier, status: task.terminationStatus)
            }
        }
        probeProcess = process

        do {
            try process.run()
        } catch {
            cleanupProbeIO()
            probeProcess = nil
            probePhase = .failed
            probeStatusText = "探针启动失败"
            showOperation("无法启动输入延迟探针：\(error.localizedDescription)", isError: true)
        }
    }

    func cancelProbe() {
        guard let process = probeProcess, process.isRunning else { return }
        cancelledProbeIdentifier = process.processIdentifier
        process.terminate()
        probeStatusText = "正在停止测量…"
    }

    func exportDiagnosticBundle() {
        guard !diagnosticExportIsRunning else { return }
        guard let exporter = Bundle.main.url(forResource: "IdentityVDiagnosticExporter", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: exporter.path) else {
            showOperation("启动器中缺少原生诊断包导出器，请重新安装启动器。", isError: true)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: ToolboxPath.diagnosticExports,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: ToolboxPath.diagnosticExports.path
            )
        } catch {
            showOperation("无法准备诊断包目录：\(error.localizedDescription)", isError: true)
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = ToolboxPath.diagnosticExports
            .appendingPathComponent("第五人格-Mac-诊断-\(formatter.string(from: Date())).zip")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = exporter
        process.arguments = ["--output", output.path]
        process.standardOutput = pipe
        process.standardError = pipe
        diagnosticExportIsRunning = true
        diagnosticExportProcess = process
        showOperation("正在本地生成脱敏诊断包；不会联网或自动发送…")
        process.terminationHandler = { [weak self] task in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.diagnosticExportIsRunning = false
                self.diagnosticExportProcess = nil
                if task.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                    self.showOperation("脱敏诊断包已在本地生成并显示于 Finder；请预览后再自行决定是否发送。")
                } else {
                    let detail = text.isEmpty ? "退出码 \(task.terminationStatus)" : text
                    self.showOperation("生成诊断包失败：\(detail)", isError: true)
                }
            }
        }
        do {
            try process.run()
        } catch {
            diagnosticExportIsRunning = false
            diagnosticExportProcess = nil
            showOperation("无法启动诊断包导出器：\(error.localizedDescription)", isError: true)
        }
    }

    func openPerformanceReports() {
        openDirectory(ToolboxPath.performanceReports)
    }

    func openPerformanceCaptures() {
        openDirectory(ToolboxPath.performanceCaptures)
    }

    func openRouteReadme() {
        openItem(ToolboxPath.routeReadme)
    }

    func revealProbeResult() {
        if let directory = probeSummary?.resultDirectory {
            let resultFile = directory.appendingPathComponent("result.json")
            NSWorkspace.shared.activateFileViewerSelecting([resultFile])
        } else {
            openDirectory(ToolboxPath.probeResults)
        }
    }

    func openInputMonitoringSettings() {
        openSystemSettings(anchor: "Privacy_ListenEvent")
    }

    func openScreenRecordingSettings() {
        openSystemSettings(anchor: "Privacy_ScreenCapture")
    }

    private func resetProbeStateForRun() {
        progressTimer?.invalidate()
        progressTimer = nil
        probeProgress = 0
        probeConsole = ""
        probeSummary = nil
        showsPermissionHelp = false
        operationMessage = nil
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
        measurementStartedAt = nil
        cancelledProbeIdentifier = nil
    }

    private func loadLauncherPreferences() {
        guard let text = try? String(contentsOf: ToolboxPath.launcherEnvironment, encoding: .utf8) else {
            mouseAccelerationDisabled = false
            return
        }
        mouseAccelerationDisabled = LauncherEnvironmentFile.mouseAccelerationIsDisabled(in: text)
    }

    private func refreshDenseMonitoring(with processDetails: String) {
        guard let denseMonitoringController else {
            denseMonitoringState = .idle
            return
        }
        denseMonitoringState = denseMonitoringController.status(
            gamePID: Self.gamePID(in: processDetails),
            snapshot: processDetails
        )
    }

    private func configureProbePipe(_ pipe: Pipe, isError: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consumeProbeData(data, isError: isError)
            }
        }
    }

    private func consumeProbeData(_ data: Data, isError: Bool) {
        if isError {
            stderrBuffer.append(data)
            consumeCompleteLines(from: &stderrBuffer, isError: true)
        } else {
            stdoutBuffer.append(data)
            consumeCompleteLines(from: &stdoutBuffer, isError: false)
        }
    }

    private func consumeCompleteLines(from buffer: inout Data, isError: Bool) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            consumeProbeLine(line, isError: isError)
        }
    }

    private func consumeProbeLine(_ line: String, isError: Bool) {
        guard !line.isEmpty else { return }
        let prefix = isError ? "[错误] " : ""
        probeConsole += prefix + line + "\n"
        if probeConsole.count > 20_000 {
            probeConsole.removeFirst(probeConsole.count - 20_000)
        }

        if line.contains("等待第五人格切到前台") {
            probePhase = .waitingForGame
            probeStatusText = "请切回第五人格，探针正在等待游戏成为前台窗口"
        } else if line.contains("已锁定主窗口") {
            probePhase = .preparing
            probeStatusText = line
        } else if line.contains("准备完成") {
            probePhase = .preparing
            probeStatusText = "即将开始，请按提示连续左右甩鼠"
        } else if line.contains("开始采样") {
            probePhase = .measuring
            probeStatusText = "正在测量输入到画面的软件延迟"
            beginProgressTimer()
        } else if line.contains("剩余约") {
            probeStatusText = line
        } else if line.contains("采样完成") {
            probePhase = .finishing
            probeProgress = 1
            probeStatusText = "采样完成，正在解析结果…"
        }

        if line.contains("缺少权限")
            || line.localizedCaseInsensitiveContains("screen recording permission")
            || line.contains("屏幕录制权限") {
            showsPermissionHelp = true
        }
    }

    private func beginProgressTimer() {
        measurementStartedAt = Date()
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let startedAt = self.measurementStartedAt else { return }
                self.probeProgress = min(1, Date().timeIntervalSince(startedAt) / self.probeDurationSeconds)
            }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishProbe(processIdentifier: Int32, status: Int32) {
        guard probeProcess?.processIdentifier == processIdentifier else { return }
        flushProbeBuffers()
        cleanupProbeIO()
        progressTimer?.invalidate()
        progressTimer = nil
        probeProcess = nil

        if cancelledProbeIdentifier == processIdentifier {
            probePhase = .cancelled
            probeStatusText = "测量已停止"
            cancelledProbeIdentifier = nil
            return
        }

        if status == 0 {
            probeProgress = 1
            loadLatestProbeResult(allowOlderResult: false)
            if probeSummary != nil {
                probePhase = .completed
                probeStatusText = "测量完成"
            } else {
                probePhase = .failed
                probeStatusText = "探针结束，但没有找到本次 result.json"
            }
        } else {
            probePhase = .failed
            probeStatusText = "测量未完成（退出码 \(status)）"
            if probeConsole.contains("缺少权限") || probeConsole.contains("权限") {
                showsPermissionHelp = true
            }
        }
    }

    private func flushProbeBuffers() {
        if !stdoutBuffer.isEmpty {
            let line = String(decoding: stdoutBuffer, as: UTF8.self)
            stdoutBuffer.removeAll()
            consumeProbeLine(line, isError: false)
        }
        if !stderrBuffer.isEmpty {
            let line = String(decoding: stderrBuffer, as: UTF8.self)
            stderrBuffer.removeAll()
            consumeProbeLine(line, isError: true)
        }
    }

    private func cleanupProbeIO() {
        probeStdout.fileHandleForReading.readabilityHandler = nil
        probeStderr.fileHandleForReading.readabilityHandler = nil
    }

    private func loadLatestProbeResult(allowOlderResult: Bool) {
        guard let latest = Self.latestResultFile() else { return }
        if !allowOlderResult,
           let probeStartedAt,
           let values = try? latest.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate,
           modified < probeStartedAt.addingTimeInterval(-2) {
            return
        }

        do {
            let data = try Data(contentsOf: latest)
            let result = try JSONDecoder().decode(ProbeResultDocument.self, from: data)
            probeSummary = ProbeSummary(
                isValid: result.analysis.valid,
                latencyMilliseconds: result.analysis.softwareLatencyMilliseconds,
                confidenceLevel: result.analysis.confidenceLevel,
                confidenceScore: result.analysis.confidenceScore,
                peakCorrelation: result.analysis.peakCorrelation,
                warnings: result.analysis.warnings,
                resultDirectory: latest.deletingLastPathComponent()
            )
        } catch {
            if !allowOlderResult {
                showOperation("result.json 解析失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func openApplication(
        at url: URL,
        createsNewInstance: Bool,
        label: String,
        successMessage: String? = nil
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showOperation("找不到 \(label)：\(url.path)", isError: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = createsNewInstance
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showOperation("打开 \(label) 失败：\(error.localizedDescription)", isError: true)
                } else {
                    self?.showOperation(successMessage ?? "已打开 \(label)。")
                    self?.refreshRuntimeStatusAfterDelay()
                }
            }
        }
    }

    private func launchEmbeddedGameRunner(successMessage: String) {
        // 启动前必须先解决麦克风授权（原因见 MicrophoneAuthorization.swift）：授权缺失时游戏内
        // 语音引擎开不了采集流，客户端会一直等在「进入大厅」加载界面（2026-09-19 实测卡十几分钟、
        // 看起来像死机）。因此这里不再"提醒后照常启动"，而是先弹授权/引导，再启动。
        guard MicrophoneAuthorization.isAuthorized else {
            resolveMicrophoneAuthorizationThenLaunch(successMessage: successMessage)
            return
        }
        performEmbeddedGameRunnerLaunch(successMessage: successMessage)
    }

    /// 麦克风授权缺失时的处理：尚未决定 → 用独立辅助进程弹系统申请框（责任方是启动器，
    /// 带麦克风说明字段，会正常弹窗；详见 MicrophoneAuthorization.swift 的安全边界）；
    /// 已拒绝/受限 → 打开系统设置的麦克风页并说明原因，**不启动**（避免她等十几分钟才发现卡住）。
    private func resolveMicrophoneAuthorizationThenLaunch(successMessage: String) {
        switch MicrophoneAuthorization.status {
        case .notDetermined:
            showOperation("正在请求麦克风权限（游戏内语音必需），请在系统弹窗上点「允许」。")
            MicrophoneAuthorization.requestViaHelper { [weak self] resolved in
                guard let self else { return }
                switch resolved {
                case .authorized:
                    self.performEmbeddedGameRunnerLaunch(successMessage: successMessage)
                case .denied, .restricted:
                    self.showOperation(MicrophoneAuthorization.deniedGuidanceMessage, isError: true)
                    self.openSystemSettings(anchor: "Privacy_Microphone")
                default:
                    // 辅助进程不可用或她没在弹窗上做选择：状态仍未知。此时**不拦**她——照常启动，
                    // 只把风险讲清楚（游戏自己还会再请求一次），避免"点了启动却什么都没发生"。
                    self.showOperation(MicrophoneAuthorization.warningMessage
                        ?? "麦克风授权状态未知：如果游戏卡在「进入大厅」，请到 系统设置 → 隐私与安全性 → 麦克风 打开「第五人格启动器」。",
                        isError: true)
                    self.performEmbeddedGameRunnerLaunch(successMessage: successMessage)
                }
            }
        case .denied, .restricted:
            showOperation(MicrophoneAuthorization.deniedGuidanceMessage, isError: true)
            openSystemSettings(anchor: "Privacy_Microphone")
        default:
            performEmbeddedGameRunnerLaunch(successMessage: successMessage)
        }
    }

    private func performEmbeddedGameRunnerLaunch(successMessage: String) {
        guard let runner = ToolboxPath.embeddedGameRunner() else {
            showOperation("启动器内嵌的游戏运行器缺失或不可执行，请重新安装第五人格 Mac。", isError: true)
            return
        }
        let executable = runner
            .appendingPathComponent("Contents/MacOS/launchIdentityVRunner")
            .resolvingSymlinksInPath().standardizedFileURL
        guard executable.path.hasPrefix(runner.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            showOperation("启动器内嵌的直接游戏运行器缺失或不可执行，请重新安装第五人格 Mac。", isError: true)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--product", "mainland"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                guard task.terminationStatus == 0 else {
                    self.showOperation("无法分派内嵌游戏运行器（退出码 \(task.terminationStatus)）。", isError: true)
                    return
                }
                self.showOperation(successMessage)
                self.refreshRuntimeStatusAfterDelay()
            }
        }
        do {
            try process.run()
        } catch {
            showOperation("无法调用内嵌游戏运行器：\(error.localizedDescription)", isError: true)
        }
    }

    private func openDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            showOperation("无法打开目录：\(error.localizedDescription)", isError: true)
        }
    }

    private func openItem(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showOperation("文件不存在：\(url.path)", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showOperation(_ message: String, isError: Bool = false) {
        operationMessage = message
        operationIsError = isError
    }

    private func presentLaunchFailure(productID: GameProductID?, code: String, summary: String) {
        let failure = LaunchFailurePresentation(productID: productID, code: code, summary: summary)
        lastLaunchFailure = failure
        showsLaunchFailureAlert = true
        showOperation("\(failure.title)（\(failure.code)）：\(failure.summary)", isError: true)
    }

    private func clearLaunchFailure() {
        lastLaunchFailure = nil
        showsLaunchFailureAlert = false
    }

    func dismissLaunchFailureAlert() {
        showsLaunchFailureAlert = false
    }

    func copyLaunchFailureDetails() {
        guard let failure = lastLaunchFailure else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(failure.title)\n\(failure.alertMessage)", forType: .string)
        showsLaunchFailureAlert = false
        showOperation("已复制启动失败信息；可以把错误代码直接发给风吟。")
    }

    func openLaunchLogs() {
        try? FileManager.default.createDirectory(at: ToolboxPath.userLogs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ToolboxPath.userLogs)
        showsLaunchFailureAlert = false
    }

    private func refreshRuntimeStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshRuntimeStatus()
        }
    }

    private func isGameRunningNow() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.fengyin.identityv.runner"
                || $0.bundleIdentifier == "com.xunfeng.identityv.mac"
        }) {
            return true
        }
        return RuntimeProcessMatcher.containsGameProcess(in: Self.processCommandSnapshot())
    }

    private func productManagerURL() -> URL? {
        guard let url = Bundle.main.url(
            forResource: "identityVProductManager",
            withExtension: "command"
        ), FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url
    }

    nonisolated private static func runProductManager(
        _ executable: URL,
        arguments: [String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return (1, error.localizedDescription)
        }
    }

    nonisolated private static func processCommandSnapshot() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    nonisolated private static func processDetailsSnapshot() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    nonisolated private static func loginReadinessStatus() -> String {
        // Never execute an unrecognised root helper. Older builds interpreted
        // `--status` as a normal start, which turned each poll into a game
        // launch. The marker is inspected as ordinary data before sudo.
        guard loginHelperContainsCurrentStatusContract(at: ToolboxPath.startLoginHelper) else {
            return "helper-update-required"
        }
        guard LoginStatusPollGate.tryAcquire() else { return "starting" }
        defer { LoginStatusPollGate.release() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", ToolboxPath.startLoginHelper.path, "--status"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "unknown" }
            let line = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .last
            guard let line, line.hasPrefix("IDV_LOGIN_READINESS=") else { return "unknown" }
            switch line.dropFirst("IDV_LOGIN_READINESS=".count) {
            case "ready", "starting", "misconfigured", "not-running":
                return String(line.dropFirst("IDV_LOGIN_READINESS=".count))
            default:
                return "unknown"
            }
        } catch {
            return "unknown"
        }
    }

    nonisolated fileprivate static func loginHelperContainsCurrentStatusContract(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 256 * 1_024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("readonly IDV_LOGIN_STATUS_CONTRACT=\"7\"")
    }

    nonisolated private static func gamePID(in snapshot: String) -> Int32? {
        snapshot.split(whereSeparator: \.isNewline).compactMap { rawLine -> Int32? in
            let fields = String(rawLine).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]),
                  RuntimeProcessMatcher.isGameCommand(String(fields[2])) else { return nil }
            return pid
        }.first
    }

    nonisolated private static func latestResultFile() -> URL? {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: ToolboxPath.probeResults,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (URL, Date)? in
            let result = directory.appendingPathComponent("result.json")
            guard FileManager.default.fileExists(atPath: result.path),
                  let values = try? result.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (result, date)
        }
        .max(by: { $0.1 < $1.1 })?.0
    }

    nonisolated private static func loginComponentVersion() -> String? {
        guard let data = try? Data(contentsOf: ToolboxPath.loginComponentMetadata),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              !version.isEmpty else { return nil }
        return version
    }
}

#if TOOLBOX_PROCESS_SELF_TEST
@main
struct ToolboxProcessMatcherSelfTest {
    static func main() throws {
        let helperFixture = FileManager.default.temporaryDirectory.appendingPathComponent("idv-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: helperFixture) }
        try Data("#!/bin/zsh\nreadonly IDV_LOGIN_STATUS_CONTRACT=\"7\"\n".utf8).write(to: helperFixture)
        let compatibleHelper = ToolboxViewModel.loginHelperContainsCurrentStatusContract(at: helperFixture)
        try Data("#!/bin/zsh\nreadonly IDV_LOGIN_STATUS_CONTRACT=\"6\"\n".utf8).write(to: helperFixture)
        let rejectedV3Helper = !ToolboxViewModel.loginHelperContainsCurrentStatusContract(at: helperFixture)
        try Data("#!/bin/zsh\n# legacy helper\n".utf8).write(to: helperFixture)
        let rejectedLegacyHelper = !ToolboxViewModel.loginHelperContainsCurrentStatusContract(at: helperFixture)
        let game = "C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1"
        let quotedLogin = "\"/Library/Application Support/IdentityVOnMac/Components/idv-login/current/idv-login\" --uri idvlogin://start?game_id=h55"
        let unquotedLogin = "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/idv-login --uri idvlogin://start?game_id=h55"
        let fixedLogin = "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/idv-login"
        let launcher = "/Applications/IDV Login.app/Contents/MacOS/IdentityVIDVLoginLauncher"
        let watcher = "/bin/zsh -c ps -axo command= | rg -i 'dwrg.exe|idv-login|IdentityVOnMac/Components'"
        let restartScript = "'/Applications/第五人格启动器.app/Contents/Resources/restartIdentityVGame.command' --stop-for-restart\\n'/Applications/第五人格启动器.app/Contents/Resources/stopIdentityVIdvLogin.command'"
        let snapshot = [game, quotedLogin, watcher, restartScript].joined(separator: "\n")
        let leader = LoginStartupGate.acquire()
        let follower = LoginStartupGate.acquire()
        let sharedFailure = LoginStartupResult.failed(
            code: "IDVL-START-103",
            summary: "证书状态检查未完成。"
        )
        LoginStartupGate.finish(leader.ticket, result: sharedFailure)
        let followerResult = follower.ticket.resultAfterWaiting()
        let boundedReason = LaunchFailureClassifier.boundedReason(
            from: "diagnostic detail\n最终可读原因\n",
            fallback: "fallback"
        )
        let launchFailure = LaunchFailurePresentation(
            productID: .mainland,
            code: "IDV-LAUNCH-203",
            summary: "20 秒内没有检测到游戏进程。"
        )

        let checks = [
            IdvLoginRelease.isCurrent(installedVersion: IdvLoginRelease.version, helperIsCurrent: true),
            !IdvLoginRelease.isCurrent(installedVersion: "6.2.3", helperIsCurrent: true),
            !IdvLoginRelease.isCurrent(installedVersion: IdvLoginRelease.version, helperIsCurrent: false),
            !IdvLoginRelease.isCurrent(installedVersion: nil, helperIsCurrent: true),
            LoginStartupResult.fromHelper(status: 75, output: "IDV_LOGIN_AUTHORIZATION=waiting\n") == .waitingForAuthorization,
            LoginStartupResult.fromHelper(status: 1, output: "IDV_LOGIN_AUTHORIZATION=waiting\n").code == "IDVL-START-103",
            LoginStartupResult.fromHelper(status: 75, output: "unrelated failure").code == "IDVL-START-103",
            LoginStartupResult.fromHelper(status: 0, output: "") == .ready,
            compatibleHelper,
            rejectedV3Helper,
            rejectedLegacyHelper,
            leader.isLeader,
            !follower.isLeader,
            followerResult == sharedFailure,
            boundedReason == "最终可读原因",
            LaunchFailureClassifier.gameLaunchCode(for: "20 秒内没有出现可验证的游戏进程") == "IDV-LAUNCH-203",
            LaunchFailureClassifier.gameLaunchCode(for: "macOS 未能启动内嵌游戏运行器") == "IDV-LAUNCH-202",
            LaunchFailureClassifier.gameLaunchCode(for: "启动前检查失败") == "IDV-LAUNCH-201",
            launchFailure.title == "国服启动失败",
            launchFailure.alertMessage.contains("错误代码：IDV-LAUNCH-203"),
            RuntimeProcessMatcher.isGameCommand(game),
            RuntimeProcessMatcher.isLoginCommand(quotedLogin),
            RuntimeProcessMatcher.isLoginCommand(unquotedLogin),
            RuntimeProcessMatcher.isLoginCommand(fixedLogin),
            RuntimeProcessMatcher.isLoginLauncherCommand(launcher),
            !RuntimeProcessMatcher.isGameCommand(watcher),
            !RuntimeProcessMatcher.isLoginCommand(watcher),
            !RuntimeProcessMatcher.isGameCommand(restartScript),
            !RuntimeProcessMatcher.isLoginCommand(restartScript),
            RuntimeProcessMatcher.containsGameProcess(in: snapshot),
            RuntimeProcessMatcher.containsLoginProcess(in: snapshot),
            !RuntimeProcessMatcher.containsGameProcess(in: watcher),
            !RuntimeProcessMatcher.containsLoginProcess(in: watcher),
            ToolboxViewModel.defaultInstallDirectory(for: .mainland).path
                == URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support/第五人格/CN", isDirectory: true).path,
            ToolboxViewModel.defaultInstallDirectory(for: .global).path
                == URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support/第五人格/Global", isDirectory: true).path
        ] + DenseMonitoringProcessMatcherSelfTest.checks()
        guard checks.allSatisfy({ $0 }) else {
            FileHandle.standardError.write(
                Data("工具箱进程边界匹配自检失败：\(checks)\n".utf8)
            )
            throw SelfTestError.failed
        }
        print("工具箱进程边界匹配自检通过。")
    }

    private enum SelfTestError: Error {
        case failed
    }
}
#endif
