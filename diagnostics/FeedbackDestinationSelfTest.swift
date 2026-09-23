import Foundation

@main
struct FeedbackDestinationSelfTest {
    static func main() throws {
        let base = FeedbackDestination.validatedIssueURL("https://github.com/example/launcher/issues/new")!
        precondition(FeedbackDestination.validatedIssueURL("https://github.com//example/launcher/issues/new") == nil)
        precondition(FeedbackDestination.validatedIssueURL("https://github.com/example%2Fother/launcher/issues/new") == nil)
        for invalid in ["", "http://github.com/example/launcher/issues/new", "https://github.com.evil.test/example/launcher/issues/new", "https://user@github.com/example/launcher/issues/new", "https://github.com:443/example/launcher/issues/new", "https://github.com/example/launcher/issues/new?body=old", "https://github.com/example/launcher/issues/new#x", "https://github.com/example/launcher"] {
            precondition(FeedbackDestination.validatedIssueURL(invalid) == nil)
        }
        let original = "重现账号 account=EXAMPLE-123，联系 tester@example.invalid\n按钮 A+B & C？"
        let report = FeedbackBundle(archive: "/tmp/反馈.zip", reportId: "fixture-id", description: original, files: ["report.json", "user-description.txt"])
        let url = FeedbackDestination.issueURL(base: base, report: report, version: "1.0.0-rc.1")!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let body = query.first { $0.name == "body" }!.value!
        precondition(body.contains(original))
        precondition(body.contains("反馈.zip") && body.contains("fixture-id"))
        precondition(query.first { $0.name == "title" }!.value!.contains("1.0.0-rc.1"))
        // One-pass feedback mail: body carries the user's own words, subject is
        // product-versioned, and the attachment is present only when requested.
        let composed = FeedbackMailComposer.items(description: original, version: "1.0.0-rc.1",
                                                  reportId: "fixture-id", attachment: report.url)
        precondition(composed.count == 2)
        precondition((composed[0] as? String)?.contains(original) == true)
        precondition((composed[0] as? String)?.contains("诊断包见附件") == true)
        precondition((composed[1] as? URL) == report.url)
        let withoutLogs = FeedbackMailComposer.items(description: original, version: "1.0.0-rc.1",
                                                     reportId: nil, attachment: nil)
        precondition(withoutLogs.count == 1)
        precondition((withoutLogs[0] as? String)?.contains("未附带日志包") == true)
        let titled = FeedbackMailComposer.subject(title: "语音里换耳机无效", version: "1.0.0-rc.1")
        precondition(titled.hasPrefix("[反馈与建议] 语音里换耳机无效"))
        precondition(titled.contains("第五人格启动器 1.0.0-rc.1"))
        let untitled = FeedbackMailComposer.subject(title: "   ", version: "1.0.0-rc.1")
        precondition(untitled == "[反馈与建议] 第五人格启动器 1.0.0-rc.1")
        let packaged = FeedbackMailComposer.packagedDescription(title: "标题A", description: "正文B")
        precondition(packaged == "标题：标题A\n\n正文B")
        precondition(FeedbackMailComposer.packagedDescription(title: "", description: "正文B") == "正文B")
        print("反馈目标验证、用户描述原文编码与一次性反馈邮件契约检查通过。")
    }
}
