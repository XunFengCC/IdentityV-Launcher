import Combine
import SwiftUI

struct ToolboxView: View {
    @EnvironmentObject private var model: ToolboxViewModel
    @State private var showsProbeInstructions = false
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                runtimeSection
                Divider()
                primaryActionsSection
                Divider()
                latencySection
                Divider()
                auxiliarySection
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(statusTimer) { _ in
            model.refreshRuntimeStatus()
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("运行状态", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 26) {
                RuntimeIndicator(title: "第五人格", isRunning: model.runtimeStatus.gameIsRunning)
                RuntimeIndicator(
                    title: "IDV Login",
                    isRunning: model.runtimeStatus.loginProxyReady,
                    detail: model.runtimeStatus.loginComponentVersion.map {
                        "\(model.runtimeStatus.loginProxyReady ? "已就绪" : (model.runtimeStatus.loginProcessStarting ? "初始化中" : (model.runtimeStatus.loginReadinessProblem ? "配置异常" : "未运行"))) · \($0)"
                    }
                )
                RuntimeIndicator(title: "第五人格工具箱", isRunning: model.runtimeStatus.overlayIsRunning)
                Spacer(minLength: 0)
            }
        }
    }

    private var primaryActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("常用操作", systemImage: "play.square.stack")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ActionButton(
                    title: model.loginComponentIsInstalled ? "启动 IDV Login 后台" : "安装 IDV Login（一次管理员授权）",
                    systemImage: model.loginComponentIsInstalled ? "person.crop.circle.badge.checkmark" : "lock.shield",
                    prominent: true,
                    isBusy: model.loginComponentIsInstalled ? model.loginStartIsRunning : model.loginInstallIsRunning,
                    isDisabled: model.loginComponentIsInstalled && model.runtimeStatus.loginIsActive,
                    action: model.loginComponentIsInstalled ? model.openLogin : model.installLoginComponent
                )
                ActionButton(
                    title: "重启游戏",
                    systemImage: "arrow.clockwise.circle.fill",
                    isBusy: model.gameRestartIsRunning,
                    action: model.relaunchGame
                )
                ActionButton(
                    title: "关闭 IDV Login 后台",
                    systemImage: "xmark.circle",
                    isBusy: model.loginStopIsRunning,
                    isDisabled: !model.runtimeStatus.loginIsActive,
                    action: model.stopLoginBackground
                )
                ActionButton(
                    title: model.runtimeStatus.overlayIsRunning ? "切换到第五人格工具箱" : "打开第五人格工具箱",
                    systemImage: "waveform.path.ecg.rectangle",
                    isBusy: false,
                    action: model.toggleOverlay
                )
            }

            if !model.loginComponentIsInstalled {
                Text("固定 \(IdvLoginRelease.version)。安装会以 root 运行完整上游组件，写入 service.mkey.163.com、sdk-os.mpsdk.easebar.com、mgbsdk.matrix.netease.com 三个域名的 loopback Hosts 规则并占用本机 443；可随时通过卸载器撤销。工具箱不会读取账号或扫码数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.operationMessage {
                Label(
                    message,
                    systemImage: model.operationIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(model.operationIsError ? Color.orange : Color.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private var latencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("输入到画面延迟", systemImage: "timer")
                    .font(.headline)
                Spacer()
                if model.probePhase.isActive {
                    Button("停止测量", systemImage: "stop.fill", action: model.cancelProbe)
                        .buttonStyle(.bordered)
                } else {
                    Button("开始 18 秒测量", systemImage: "record.circle") {
                        showsProbeInstructions = true
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
            .confirmationDialog(
                "准备输入延迟测量",
                isPresented: $showsProbeInstructions,
                titleVisibility: .visible
            ) {
                Button("开始测量", action: model.startProbe)
                Button("取消", role: .cancel) { }
            } message: {
                Text("先进入游戏并对准有纹理、无明显动画的静态场景。开始后请在 30 秒内切回游戏；听到提示音后连续左右甩鼠，第二声提示音后结束。探针只读输入与指定游戏窗口，不会注入操作或保存画面。")
            }

            if model.probePhase.isActive || model.probePhase == .completed || model.probePhase == .failed {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(model.probeStatusText)
                            .font(.callout.weight(.medium))
                        Spacer()
                        if model.probePhase == .measuring {
                            Text("\(Int((model.probeProgress * 18).rounded(.down)))/18 秒")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.probePhase == .measuring || model.probePhase == .finishing || model.probePhase == .completed {
                        ProgressView(value: model.probeProgress)
                    } else if model.probePhase.isActive {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if let summary = model.probeSummary {
                ProbeResultView(summary: summary, revealAction: model.revealProbeResult)
            } else if model.probePhase == .failed, !model.probeConsole.isEmpty {
                Label("完整原因保留在下方“探针输出”中。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.showsPermissionHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要在“隐私与安全性”中给工具箱或嵌入探针开启输入监控与屏幕录制，授权后请完全退出工具箱再重试。", systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    HStack {
                        Button("输入监控设置", systemImage: "cursorarrow.motionlines", action: model.openInputMonitoringSettings)
                        Button("屏幕录制设置", systemImage: "rectangle.inset.filled.badge.record", action: model.openScreenRecordingSettings)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !model.probeConsole.isEmpty {
                DisclosureGroup("探针输出") {
                    ScrollView {
                        Text(model.probeConsole)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .frame(height: 110)
                }
            }
        }
    }

    private var auxiliarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("文件与说明", systemImage: "folder")
                .font(.headline)
            HStack(spacing: 8) {
                Button("性能报告", systemImage: "chart.xyaxis.line", action: model.openPerformanceReports)
                Button("采集文件", systemImage: "waveform", action: model.openPerformanceCaptures)
                Button("当前路线", systemImage: "doc.text", action: model.openRouteReadme)
                Button("延迟结果", systemImage: "folder.badge.gearshape", action: model.revealProbeResult)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct RuntimeIndicator: View {
    let title: String
    let isRunning: Bool
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail ?? (isRunning ? "运行中" : "未运行"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActionButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            button
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || isDisabled)
        } else {
            button
                .buttonStyle(.bordered)
                .disabled(isBusy || isDisabled)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ProbeResultView: View {
    let summary: ProbeSummary
    let revealAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if summary.isValid, let latency = summary.latencyMilliseconds {
                    Text(String(format: "%.1f ms", latency))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Text("软件输入到可见窗口延迟")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("本次未形成有效估算", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Button("在 Finder 中显示", systemImage: "magnifyingglass", action: revealAction)
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 18) {
                ResultMetric(title: "置信度", value: "\(summary.localizedConfidence)  \(String(format: "%.2f", summary.confidenceScore))")
                ResultMetric(title: "峰值相关", value: summary.peakCorrelation.map { String(format: "%.3f", $0) } ?? "无")
            }

            if !summary.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ResultMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }
}
