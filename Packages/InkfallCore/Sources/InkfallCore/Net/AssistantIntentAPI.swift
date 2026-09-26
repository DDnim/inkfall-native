import Foundation

/// 「这段话是不是在叫语音助手」的 Jev 判定：请求体、响应解析、三段式裁决。不碰网络。
///
/// 实验分支 `exp/jev-segment-intent` 的试做。提问是 `experiments/jev/run.py` 的
/// `INTENT_Q2`（v2，带 `app_kind`），**逐字复制**，改了就要重跑那边的评测。
/// 减法版没有助手可叫，App 只把裁决写进日志、在刘海上提一句，文字照常粘贴。
public enum AssistantIntentAPI {

    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"

    // verbatim：与 experiments/jev/run.py 的 INTENT_Q2 相同
    public static let question =
        "The user speaks into a dictation app that normally types their words into `app` (`app_kind` says what it is for). They can also talk to a voice "
        + "assistant (Claude Code) that performs tasks on their computer. Is `text` (or its last sentence) addressed to the assistant as a request to do "
        + "something, rather than content the user wants typed out? In chat or email apps, requests like \"帮我看一下…\" are usually written to a colleague, "
        + "not to the assistant, unless the assistant is named. In a terminal, a short description of a change is usually a commit message being dictated."

    /// 三段式（评测 48 条：直接叫 21 条全对、当正文 23 条全对、中间 4 条）。
    public enum Verdict: String, Sendable, Equatable {
        /// ≥ 0.6：交给助手
        case call
        /// 0.4–0.6：在刘海问一句。这里**不看唤醒词**（「给 Claude 的提示词写成…」0.54）
        case ask
        /// < 0.4：当正文，有唤醒词也不叫
        case text

        public static func decide(_ p: Double) -> Verdict {
            p >= 0.6 ? .call : p >= 0.4 ? .ask : .text
        }

        public var label: String {
            switch self {
            case .call: return "像在叫助手"
            case .ask: return "拿不准是不是叫助手"
            case .text: return "正文"
            }
        }
    }

    /// 前台应用的用途。Jev 几乎不看 App 名，要把用途说出来才分得清
    /// 「Slack 里对同事说的帮我看一下」和「对助手说的」。查不到就是 unknown。
    public static func appKind(bundleID: String?) -> String {
        guard let id = bundleID?.lowercased() else { return "unknown" }
        let table: [(String, String)] = [
            ("com.tinyspeck.slackmacgap", "chat with other people"),
            ("com.hnc.discord", "chat with other people"),
            ("com.tencent.xinwechat", "chat with other people"),
            ("jp.naver.line.mac", "chat with other people"),
            ("com.microsoft.teams", "chat with other people"),
            ("com.apple.mobilesms", "chat with other people"),
            ("ru.keepcoder.telegram", "chat with other people"),
            ("com.apple.mail", "email to other people"),
            ("com.microsoft.outlook", "email to other people"),
            ("com.apple.terminal", "developer tool"),
            ("com.googlecode.iterm2", "developer tool"),
            ("dev.warp.warp-stable", "developer tool"),
            ("com.mitchellh.ghostty", "developer tool"),
            ("com.microsoft.vscode", "developer tool"),
            ("com.todesktop.230313mzl4w4u92", "developer tool"),  // Cursor
            ("com.apple.dt.xcode", "developer tool"),
            ("com.apple.notes", "personal notes"),
            ("md.obsidian", "personal notes"),
            ("com.apple.textedit", "personal notes"),
            ("com.apple.safari", "web browser"),
            ("com.google.chrome", "web browser"),
            ("company.thebrowser.browser", "web browser"),
            ("org.mozilla.firefox", "web browser"),
        ]
        return table.first { id == $0.0 || id.hasPrefix($0.0 + ".") }?.1 ?? "unknown"
    }

    public static func headers(key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]
    }

    public static func body(appName: String, bundleID: String?, text: String) -> Data? {
        let payload: [String: Any] = [
            "model": model,
            "state": ["app": appName, "app_kind": appKind(bundleID: bundleID), "text": text],
            "questions": ["assistant": ["type": "noul", "instructions": question]],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// `{"answers": {"assistant": {"noul": 0.83}}}` → 0.83
    public static func parse(_ data: Data) throws -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let answer = answers["assistant"] as? [String: Any],
              let p = (answer["noul"] as? NSNumber)?.doubleValue,
              (0...1).contains(p)
        else { throw TextGenerationAPI.Failure.malformedResponse }
        return p
    }
}
