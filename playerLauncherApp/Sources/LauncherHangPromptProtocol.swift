import Foundation

/// The accessory helper can only display this text and return an explicit
/// button choice. Product ownership and all game controls stay in the launcher.
///
/// Two shapes travel over the same pipe, distinguished by `kind`:
/// - `hang`: the original "game may be stuck" prompt with its two buttons.
/// - `recovered`: the same incident was observed running again, so the helper
///   shows a countdown and closes itself.
struct HangPromptSnapshot: Codable, Equatable {
    let id: String
    let title: String
    /// Absent in the original one-record protocol; treated as `hang`.
    var kind: String?
    /// Remaining seconds; only present for `recovered`.
    var countdown: Int?

    init(id: String, title: String, kind: String? = nil, countdown: Int? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.countdown = countdown
    }

    var isRecovery: Bool { kind == "recovered" }
}

struct HangPromptAction: Codable, Equatable {
    let id: String
    let action: String
}

/// Shared wording so the launcher and the helper cannot drift apart, and so the
/// countdown rule (start at 5, tick to 1, then close) is testable without a
/// window.
enum HangPromptRecovery {
    static let firstCountdown = 5

    static func title(countdown: Int) -> String {
        let bounded = max(1, min(firstCountdown, countdown))
        return "检测到游戏恢复运行，窗口将在 \(bounded) 秒后关闭"
    }

    /// Next countdown value, or nil when the window should close.
    static func next(after countdown: Int) -> Int? {
        countdown > 1 ? countdown - 1 : nil
    }

    static func fixtureChecks() -> [Bool] {
        let first = HangPromptSnapshot(id: "recovered-1", title: title(countdown: firstCountdown),
                                       kind: "recovered", countdown: firstCountdown)
        let encoded = (try? JSONEncoder().encode(first)) ?? Data()
        let decoded = try? JSONDecoder().decode(HangPromptSnapshot.self, from: encoded)
        // A record without kind/countdown (older shape) must still decode, so an
        // installed helper and a newer launcher can still talk during an update.
        let legacy = try? JSONDecoder().decode(
            HangPromptSnapshot.self,
            from: Data("{\"id\":\"legacy\",\"title\":\"游戏可能卡住了\"}".utf8)
        )
        return [
            decoded == first,
            decoded?.isRecovery == true,
            legacy?.isRecovery == false,
            legacy?.countdown == nil,
            title(countdown: 5) == "检测到游戏恢复运行，窗口将在 5 秒后关闭",
            title(countdown: 1) == "检测到游戏恢复运行，窗口将在 1 秒后关闭",
            title(countdown: 0) == "检测到游戏恢复运行，窗口将在 1 秒后关闭",
            next(after: 5) == 4,
            next(after: 2) == 1,
            next(after: 1) == nil
        ]
    }
}
