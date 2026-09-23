import AppKit
import SwiftUI

/// Feedback, in one pass: type what happened, optionally attach the sanitised
/// log bundle, press send. The send button hands everything to the system mail
/// client (recipient, subject, body, attachment already filled in), so the only
/// remaining step for the user is the client's own Send button.
///
/// 2026-09-18 rewrite: the previous version made the user generate a ZIP, copy
/// the address, open their mail client and attach the file by hand. That was
/// four manual steps for something the launcher can prepare itself, and it also
/// meant the attachment was easy to forget. The bundle is still built locally
/// and never uploaded by the launcher; mail composition is the same verified
/// NSSharingService path used before, and the no-client fallback still reveals
/// the generated file in Finder instead of silently failing.
struct FeedbackView: View {
    @EnvironmentObject private var model: ToolboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var attachLogs = true
    @State private var message: String?
    @State private var mailService: NSSharingService?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Title alone is still a usable report, so sending only needs one of them.
    private var canSend: Bool { !trimmedTitle.isEmpty || !trimmedDescription.isEmpty }
    /// Wording kept in one place: the fields are self-labelling, so there are no
    /// captions outside the boxes.
    private let titlePlaceholder = "这里是标题栏，请简要概括你遇到的问题或想提出的建议"
    private let descriptionPlaceholder = "这里是正文栏，尽可能展开详细说说"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("反馈与建议").font(.title2.weight(.semibold))
            TextField(titlePlaceholder, text: $title)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .accessibilityLabel("标题")
                .disabled(model.feedbackIsSending)
            // Placeholder inside the box, matching the title field. A plain
            // TextEditor always paints its own square, scrolled background,
            // which looked wrong next to the rounded title field; here the
            // editor is transparent, gets the same rounded border, and the
            // scroll bar only appears once the text outgrows the frame.
            // SwiftUI has no placeholder for TextEditor, so the hint is drawn
            // underneath and removed on first keystroke.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $description)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .accessibilityLabel("正文")
                    .disabled(model.feedbackIsSending)
                if description.isEmpty {
                    Text(descriptionPlaceholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            HStack(spacing: 12) {
                // Default on: without logs most reports cannot be acted on, and
                // the bundle is already sanitised (account/device/address fields
                // replaced, credentials and query strings removed).
                Toggle("打包并发送日志", isOn: $attachLogs)
                    .toggleStyle(.checkbox)
                    .disabled(model.feedbackIsSending)
                if model.feedbackIsSending { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.feedbackIsSending)
                Button("发送反馈") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend || model.feedbackIsSending)
            }

            Text(attachLogs
                 ? "附件包含版本、系统摘要和最近启动/安装日志（账号、设备、邮箱、IP 等已替换）；你写的内容按原文保留。邮件由你确认后发出。"
                 : "不会附带日志，只发送你写的内容。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(model.feedbackIsSending)
    }

    private func send() {
        message = nil
        guard attachLogs else {
            composeEmail(attachment: nil, reportId: nil)
            return
        }
        model.prepareFeedback(title: trimmedTitle, description: trimmedDescription) { result, error in
            if let result {
                composeEmail(attachment: result.url, reportId: result.reportId)
            } else {
                message = error ?? "未能生成日志包；可以选择不附带日志再发送。"
            }
        }
    }

    /// Opens a pre-filled mail draft: our address, the product and version in the
    /// subject, the user's own text as the body, and the diagnostic ZIP attached.
    private func composeEmail(attachment: URL?, reportId: String?) {
        let items = FeedbackMailComposer.items(description: FeedbackMailComposer.packagedDescription(title: trimmedTitle, description: trimmedDescription),
                                              version: LauncherRelease.displayVersion,
                                              reportId: reportId,
                                              attachment: attachment)
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
            // No usable mail client: keep the work rather than losing it.
            if let attachment {
                NSWorkspace.shared.activateFileViewerSelecting([attachment])
                message = "未找到可用的邮件客户端。日志包已在 Finder 中显示，请用网页邮箱写到 \(FeedbackDestination.email) 并附上该文件；反馈内容已在上方，可复制。"
            } else {
                message = "未找到可用的邮件客户端。请用网页邮箱写到 \(FeedbackDestination.email)。"
            }
            return
        }
        mailService = service
        service.recipients = [FeedbackDestination.email]
        service.subject = FeedbackMailComposer.subject(title: trimmedTitle, version: LauncherRelease.displayVersion)
        service.perform(withItems: items)
        message = "已打开邮件草稿，请检查内容后点“发送”。"
    }
}
