import Combine
import SwiftUI

struct ProductLauncherView: View {
    @EnvironmentObject private var model: ToolboxViewModel
    @State private var removalTarget: GameProductPresentation?
    @State private var showsFeedback = false
    @State private var operationToast: OperationToast?
    @State private var operationToastGeneration = UUID()
    @State private var installExpectationProtectedUntil = Date.distantPast
    @State private var showsLoginUninstallConfirmation = false
    @State private var completesLoginTrustAfterAlertDismissal = false
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                header
                if let product = selectedProduct {
                    productPanel(product)
                } else { ContentUnavailableView("尚未读取到游戏版本", systemImage: "gamecontroller") }
                lowerPanels
                footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("需要准备游戏运行环境", isPresented: Binding(
            get: { model.runtimePrerequisiteIssue != nil },
            set: { if !$0 { model.dismissRuntimePrerequisiteIssue() } }
        )) {
            if model.runtimePrerequisiteNeedsRosetta {
                Button("安装 Rosetta", action: model.openRosettaInstaller)
            }
            Button("好", role: .cancel, action: model.dismissRuntimePrerequisiteIssue)
        } message: {
            Text(model.runtimePrerequisiteIssue ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.showsInitialInstallDownloadNotice },
            set: { if !$0 { model.dismissInitialInstallDownloadNotice() } }
        ), onDismiss: model.initialInstallDownloadNoticeDidDismiss) {
            VStack(spacing: 18) {
                Text("安装可能需要 30-60 分钟")
                    .font(.body)
                    .fixedSize()
                Button("好的", action: model.dismissInitialInstallDownloadNotice)
                    .keyboardShortcut(.defaultAction)
                    .frame(minWidth: 70)
            }
            .padding(22)
            .frame(width: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert("卸载\(removalTarget?.productId.localizedName ?? "此版本")？", isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }), presenting: removalTarget) { product in
            Button("卸载", role: .destructive) { removalTarget = nil; model.performProductAction(.remove, for: product.productId) }
            Button("取消", role: .cancel) { removalTarget = nil }
        } message: { _ in Text("会结束该版本的游戏，并将其游戏文件与独立兼容环境移入废纸篓；不会影响另一服务器或启动器。") }
        .alert("启用 idv-login？", isPresented: $model.shouldOfferIdvLoginPrompt) {
            Button("是", action: model.acceptInitialIdvLoginOffer)
            Button("否", role: .cancel, action: model.declineInitialIdvLoginOffer)
        } message: { Text("保存账号登录状态\n不用重复扫码登录") }
        .alert("idv-login 安装需要输入密码授权", isPresented: $model.shouldConfirmLoginInstallationAuthorization) {
            Button("继续安装", action: model.acceptLoginInstallationAuthorization)
            Button("取消", role: .cancel, action: model.declineLoginInstallationAuthorization)
        }
        .alert("idv-login 首次启动需要验证指纹授权", isPresented: loginTrustAuthorizationAlertBinding) {
            Button("取消", role: .cancel, action: model.declineLoginCertificateTrustNotice)
            Button("确认", action: acceptLoginTrustAfterAlertDismissal)
        }
        .alert("是否要跳过 idv-login 直接启动游戏？", isPresented: loginTrustSkipAlertBinding) {
            Button("返回", role: .cancel, action: model.declineLoginCertificateTrustNotice)
            Button("确认", action: acceptLoginTrustAfterAlertDismissal)
        }
        .alert("idv-login 卸载需要输入密码授权", isPresented: $showsLoginUninstallConfirmation) {
            Button("继续卸载", role: .destructive, action: model.uninstallLoginComponent)
            Button("取消", role: .cancel) { }
        }
        .alert(
            model.lastLaunchFailure?.title ?? "启动失败",
            isPresented: Binding(
                get: { model.showsLaunchFailureAlert },
                set: { if !$0 { model.dismissLaunchFailureAlert() } }
            )
        ) {
            Button("复制错误信息", action: model.copyLaunchFailureDetails)
            Button("打开日志", action: model.openLaunchLogs)
            Button("好", role: .cancel, action: model.dismissLaunchFailureAlert)
        } message: {
            Text(model.lastLaunchFailure?.alertMessage ?? "游戏没有进入运行状态，请稍后重试。")
        }
        .sheet(isPresented: $showsFeedback) { FeedbackView().environmentObject(model) }
        .overlay(alignment: .bottom) {
            if let operationToast {
                Label(operationToast.message, systemImage: operationToast.systemImage)
                    .font(.callout)
                    .foregroundStyle(operationToast.isError ? Color.orange : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // Game/IDV process state changes frequently and stays on a cheap 2 s
        // poll. Product installation state is refreshed at App startup and
        // after every mutating action; re-running the short-lived manager here
        // would make it touch removable game/runtime volumes every six seconds
        // and repeatedly trigger macOS removable-volume authorization.
        .onReceive(statusTimer) { _ in model.refreshRuntimeStatus() }
        .onChange(of: model.downloadProgress != nil) { wasDownloading, isDownloading in
            resizeWindowForCurrentActivity()
            if wasDownloading && !isDownloading {
                installExpectationProtectedUntil = .distantPast
            }
        }
        .onChange(of: model.operationMessage) { _, message in
            guard let message else { return }
            if Date() < installExpectationProtectedUntil && !model.operationIsError { return }
            if model.operationIsError { installExpectationProtectedUntil = .distantPast }
            showOperationToast(message)
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text("第五人格启动器").font(.system(size: 38, weight: .bold, design: .rounded))
            Spacer(minLength: 16)
            serverSelector
        }
    }
    private var lowerPanels: some View {
        HStack(alignment: .top, spacing: 12) {
            loginComponent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            LauncherStatusWindow(
                model: model,
                downloadProgress: model.downloadProgress,
                cancelDownload: model.cancelInstallerDownload,
                setDownloadPaused: model.setInstallerPaused
            )
            .frame(width: 260)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: lowerPanelHeight, maxHeight: lowerPanelHeight)
    }
    private func productPanel(_ product: GameProductPresentation) -> some View {
        ProductPanel(
            product: product,
            isRunning: model.runtimeStatus.runningProductIDs.contains(product.productId),
            defaultInstallPath: model.defaultInstallPath(for: product.productId),
            action: { model.performProductAction($0, for: product.productId) },
            requestRemoval: { removalTarget = product },
            isBusy: { model.productActionIsRunning($0, productID: product.productId) },
            isAnyActionBusy: model.productActionIsBusy
        )
    }
    private func showOperationToast(
        _ message: String,
        isError: Bool? = nil,
        systemImage: String? = nil,
        duration: TimeInterval = 4
    ) {
        let error = isError ?? model.operationIsError
        let toast = OperationToast(
            message: message,
            isError: error,
            systemImage: systemImage ?? (error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        )
        let generation = UUID()
        operationToastGeneration = generation
        withAnimation { operationToast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard generation == operationToastGeneration else { return }
            withAnimation { operationToast = nil }
        }
    }
    @ViewBuilder private var serverSelector: some View {
        if #available(macOS 26.0, *) {
            serverSelectorButtons
                .padding(3)
                .glassEffect(.regular, in: Capsule())
        } else {
            serverSelectorButtons
                .padding(3)
                .background(.thinMaterial, in: Capsule())
                .overlay { Capsule().stroke(.quaternary, lineWidth: 1) }
        }
    }
    private var serverSelectorButtons: some View {
        HStack(spacing: 3) {
            ForEach(model.products) { product in
                Button(product.productId.localizedName) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedProductID.wrappedValue = product.productId
                    }
                }
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(product.productId == selectedProduct?.productId ? Color.white : Color.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(product.productId == selectedProduct?.productId ? Color.accentColor : Color.clear, in: Capsule())
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedProduct?.productId)
        .disabled(!model.productManagerIsAvailable)
    }
    private var selectedProduct: GameProductPresentation? { model.products.first(where: \.isSelected) ?? model.products.first }
    private var selectedProductID: Binding<GameProductID> { Binding(get: { selectedProduct?.productId ?? .mainland }, set: { next in if next != selectedProduct?.productId { model.selectProductPanel(next) } }) }

    private var loginComponent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("idv-login").font(.title3.weight(.semibold))
                    Text("保存账号登录状态\n不用重复扫码登录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                loginStatus
            }
            HStack(spacing: 10) {
                if !model.loginComponentIsInstalled {
                    Button(model.loginComponentNeedsUpdate ? "更新" : "安装", action: model.installLoginComponent)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(model.loginMutationIsBusy)
                } else {
                    Button("启动", action: model.openLogin)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(model.loginMutationIsBusy || model.runtimeStatus.loginIsActive)
                    Button("结束运行", action: model.stopLoginBackground)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(model.loginMutationIsBusy || !model.runtimeStatus.loginIsActive)
                    Button("卸载") { showsLoginUninstallConfirmation = true }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(.red)
                        .disabled(model.loginMutationIsBusy)
                    Spacer(minLength: 8)
                    if let version = model.runtimeStatus.loginComponentVersion {
                        Text("版本 \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            HStack(spacing: 12) {
                Text("跟随游戏启动")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(model.loginComponentIsInstalled ? Color.primary : Color.secondary)
                Spacer(minLength: 12)
                Toggle("跟随游戏启动", isOn: Binding(
                    get: { model.loginComponentNeedsUpdate ? model.idvLoginEnabled : (model.loginComponentIsInstalled ? model.idvLoginEnabled : false) },
                    set: setFollowGameEnabled
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .disabled(model.loginComponentIsInstalled && model.loginMutationIsBusy)
                .help(model.loginComponentIsInstalled
                    ? "启动或重启游戏时先准备 idv-login"
                    : (model.loginComponentNeedsUpdate ? "更新 idv-login 后恢复跟随启动" : "安装 idv-login 后即可启用"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(model.loginComponentIsInstalled ? .quaternary : .tertiary, lineWidth: 1) }
            .opacity(model.loginComponentIsInstalled ? 1 : 0.55)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private var loginStatus: some View {
        let state = loginStatusPresentation
        return Label(state.title, systemImage: state.symbol)
            .font(.headline.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(state.color.opacity(0.13), in: Capsule())
            .overlay { Capsule().stroke(state.color.opacity(0.32), lineWidth: 1) }
    }
    private func setFollowGameEnabled(_ enabled: Bool) {
        guard model.loginComponentIsInstalled else {
            if !enabled {
                model.setIdvLoginFollowGameEnabled(false)
                return
            }
            showOperationToast(
                "你还没有安装这个功能哦",
                isError: false,
                systemImage: "info.circle.fill"
            )
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.setIdvLoginFollowGameEnabled(enabled)
        }
    }
    private var loginStatusPresentation: (title: String, symbol: String, color: Color) {
        if model.loginComponentNeedsUpdate { return ("需要更新", "arrow.triangle.2.circlepath.circle.fill", .orange) }
        if model.runtimeStatus.loginIsActive { return ("运行中", "checkmark.circle.fill", .green) }
        if model.loginComponentIsInstalled { return ("已安装", "checkmark.circle.fill", .blue) }
        return ("未安装", "arrow.down.circle.fill", .secondary)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text("风吟与砚衡联合出品")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: { showsFeedback = true }) {
                Text("反馈与建议").font(.body)
            }
                .buttonBorderShape(.capsule)
            Button(action: model.checkForLauncherUpdate) {
                if model.launcherUpdateIsChecking { ProgressView().controlSize(.small) }
                Text("版本与更新").font(.body)
            }
                .buttonBorderShape(.capsule)
                .disabled(model.launcherUpdateIsChecking)
        }.buttonStyle(.bordered)
    }
    private func resizeWindowForCurrentActivity() {
        DispatchQueue.main.async {
            // A presented sheet can be key. Resize only our main window,
            // otherwise a short notice grows to the full download layout.
            guard let window = NSApplication.shared.windows.first(where: {
                !$0.isSheet && $0.sheetParent == nil &&
                ($0.identifier?.rawValue == "identityv-toolbox-main" || $0.title == "第五人格启动器")
            }) else { return }
            let height: CGFloat
            height = model.downloadProgress != nil ? 530 : 420
            window.setContentSize(NSSize(width: 680, height: height))
        }
    }
    private var lowerPanelHeight: CGFloat {
        if model.downloadProgress != nil { return 238 }
        // The always-visible follow-game switch needs a stable baseline. Both
        // lower cards deliberately fill this same height, including while the
        // right status window reports IDV Login work.
        return 184
    }
    /// These bindings select one native alert for each stage of the trust
    /// decision. Keeping the stages separate makes Cancel/Back dismiss one
    /// alert before SwiftUI presents the next, rather than replacing its
    /// contents while it is still onscreen.
    private var loginTrustAuthorizationAlertBinding: Binding<Bool> {
        Binding(
            get: {
                model.shouldConfirmLoginCertificateTrust
                    && !model.showsSkipLoginConfirmation
            },
            set: { isPresented in
                if !isPresented {
                    completeLoginTrustAfterNativeAlertDismissalIfNeeded()
                }
            }
        )
    }

    private var loginTrustSkipAlertBinding: Binding<Bool> {
        Binding(
            get: {
                model.shouldConfirmLoginCertificateTrust
                    && model.showsSkipLoginConfirmation
            },
            set: { isPresented in
                if !isPresented {
                    completeLoginTrustAfterNativeAlertDismissalIfNeeded()
                }
            }
        )
    }

    private func acceptLoginTrustAfterAlertDismissal() {
        completesLoginTrustAfterAlertDismissal = true
        model.acceptLoginCertificateTrustNotice()
    }

    private func completeLoginTrustAfterNativeAlertDismissalIfNeeded() {
        guard completesLoginTrustAfterAlertDismissal else { return }
        completesLoginTrustAfterAlertDismissal = false

        // An alert action mutates its binding before SwiftUI completes the
        // native dismissal animation. Deferring one main-loop turn preserves
        // the ViewModel's required "after dismissal" continuation ordering.
        DispatchQueue.main.async {
            model.loginCertificateTrustNoticeDidDismiss()
        }
    }
}

private struct ProductPanel: View {
    let product: GameProductPresentation
    let isRunning: Bool
    let defaultInstallPath: String
    let action: (GameProductAction) -> Void
    let requestRemoval: () -> Void
    let isBusy: (GameProductAction) -> Bool
    let isAnyActionBusy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                actionGrid
                Spacer(minLength: 0)
                Label(installationStatusTitle, systemImage: installationStatusSymbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(installationStatusColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(installationStatusColor.opacity(0.13), in: Capsule())
                    .overlay { Capsule().stroke(installationStatusColor.opacity(0.32), lineWidth: 1) }
            }
            Text("默认安装位置：\(defaultInstallPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(installationStatusColor.opacity(0.38), lineWidth: 1.25) }
    }
    @ViewBuilder private var actionGrid: some View {
        let actions = GameProductActionPolicy.actions(
            for: product.state,
            product: product.productId,
            canRemove: product.canRemove
        )
        if actions == [.install] {
            actionButton(.install, prominent: true)
        } else if !actions.isEmpty {
            HStack(spacing: 10) {
                ForEach(actions) { item in
                    if item == .remove {
                        Button(action: requestRemoval) { actionLabel(.remove) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .tint(.red)
                            .disabled(isAnyActionBusy || isBusy(.remove))
                    } else {
                        actionButton(item, prominent: item == .launch)
                    }
                }
            }
        }
    }
    @ViewBuilder private func actionButton(_ item: GameProductAction, prominent: Bool = false) -> some View {
        if prominent {
            Button { action(item) } label: { actionLabel(item) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(isAnyActionBusy || isBusy(item))
        } else {
            Button { action(item) } label: { actionLabel(item) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(isAnyActionBusy || isBusy(item))
        }
    }
    private func actionLabel(_ item: GameProductAction) -> some View {
        HStack(spacing: 6) {
            if isBusy(item) { ProgressView().controlSize(.small) }
            Text(item.localizedTitle)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    private var installationStatusTitle: String { isRunning ? "运行中" : (product.state == .notInstalled ? "未安装" : "已安装") }
    private var installationStatusSymbol: String { product.state == .notInstalled ? "arrow.down.circle.fill" : "checkmark.circle.fill" }
    private var installationStatusColor: Color {
        if isRunning { return .green }
        return product.state == .notInstalled ? .secondary : .blue
    }
}

private struct OperationToast: Equatable {
    let message: String
    let isError: Bool
    let systemImage: String
}

private struct LauncherStatusWindow: View {
    @ObservedObject var model: ToolboxViewModel
    let downloadProgress: ProductDownloadProgress?
    let cancelDownload: () -> Void
    let setDownloadPaused: (Bool) -> Void

    var body: some View {
        Group {
            if let progress = downloadProgress {
                downloadStatus(progress)
            } else if let completedProductID = model.recentlyCompletedProductID {
                installCompletedStatus(completedProductID)
            } else if let loginPhase = model.loginInstallPhase {
                activeTask(title: loginPhase, detail: concurrentProductDetail ?? loginDetail)
            } else if model.productActionIsBusy, let action = model.activeProductAction, let product = model.activeProductID {
                activeTask(title: "正在\(action.localizedTitle)\(product.localizedName)…", detail: model.loginMutationIsBusy ? "同时正在处理 idv-login 后台；请保持启动器开启。" : "请保持启动器开启，完成后会自动刷新状态。")
            } else if model.loginMutationIsBusy {
                activeTask(title: loginMutationTitle, detail: "正在处理 idv-login 组件或后台状态。")
            } else if let failure = model.lastLaunchFailure {
                launchFailureStatus(failure)
            } else {
                idleStatus
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(statusColor.opacity(0.32), lineWidth: 1) }
        .animation(.easeInOut(duration: 0.18), value: statusIdentity)
    }

    private var idleStatus: some View {
        Text("今天也要开心哦 OvO")
            .font(.title3.weight(.semibold))
            .foregroundStyle(statusColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installCompletedStatus(_ productID: GameProductID) -> some View {
        Label("\(productID.localizedName)安装完成", systemImage: "checkmark.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.green)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func launchFailureStatus(_ failure: LaunchFailurePresentation) -> some View {
        VStack(spacing: 8) {
            Text("启动失败")
                .font(.title3.weight(.semibold))
            Text(failure.code)
                .font(.caption.monospaced().weight(.medium))
            Text(failure.summary)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(Color.orange)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activeTask(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).font(.headline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func downloadStatus(_ progress: ProductDownloadProgress) -> some View {
        let presentation = ProductInstallProgressPresentation(progress: progress)
        return VStack(alignment: .leading, spacing: 5) {
            Text(progress.phase == "completed" ? "\(progress.productID.localizedName)安装完成" : "正在安装\(progress.productID.localizedName)")
                .font(.headline.weight(.semibold))
            ForEach(ProductInstallProgressPresentation.stages) { stage in
                let state = presentation.stageState(stage)
                Label(stage.title, systemImage: state == .complete ? "checkmark.circle.fill" : (state == .current ? "circle.inset.filled" : "circle"))
                    .font(.caption)
                    .foregroundStyle(stageColor(for: state))
            }
            Spacer(minLength: 2)
            Text("\(presentation.currentTitle) · \(progress.byteDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let phase = model.loginInstallPhase {
                Text("同时：\(phase)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if progress.phase != "completed" {
                HStack(spacing: 6) {
                    if progress.phase == "downloading" {
                        Button("暂停") { setDownloadPaused(true) }.buttonStyle(.bordered).controlSize(.small)
                        Button("继续") { setDownloadPaused(false) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("取消", action: cancelDownload)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func stageColor(for state: ProductInstallProgressPresentation.StageState) -> Color {
        switch state {
        case .complete: return .green
        case .current: return .primary
        case .pending: return .secondary.opacity(0.65)
        }
    }

    private var loginDetail: String {
        if let progress = model.loginInstallProgress { return "下载进度 \(Int((progress * 100).rounded()))%" }
        return "可能需要等待系统授权或组件验证完成。"
    }
    private var concurrentProductDetail: String? {
        guard model.productActionIsBusy, let action = model.activeProductAction, let product = model.activeProductID else { return nil }
        return "同时正在\(action.localizedTitle)\(product.localizedName)。"
    }
    private var loginMutationTitle: String {
        if model.loginUninstallIsRunning { return "正在卸载 idv-login…" }
        if model.loginStopIsRunning { return "正在结束 idv-login…" }
        if model.loginStartIsRunning { return "正在启动 idv-login…" }
        return "正在处理 idv-login…"
    }
    private var statusColor: Color {
        if model.recentlyCompletedProductID != nil { return .green }
        if downloadProgress != nil || model.loginInstallPhase != nil || model.productActionIsBusy || model.loginMutationIsBusy { return .accentColor }
        if model.lastLaunchFailure != nil { return .orange }
        return .secondary
    }
    private var statusIdentity: String {
        if let progress = downloadProgress { return "download-\(progress.productID.rawValue)-\(progress.phase)" }
        if let productID = model.recentlyCompletedProductID { return "install-completed-\(productID.rawValue)" }
        if let phase = model.loginInstallPhase { return "login-install-\(phase)" }
        if let action = model.activeProductAction { return "product-\(action.rawValue)" }
        if model.loginMutationIsBusy { return "login-mutation-\(loginMutationTitle)" }
        if let failure = model.lastLaunchFailure { return "launch-failure-\(failure.id)" }
        return "idle"
    }
}
