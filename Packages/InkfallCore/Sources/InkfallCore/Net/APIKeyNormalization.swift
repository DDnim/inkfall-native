import Foundation

/// API key 归一化（spec/05 §5）。
///
/// 用户是从网页上**复制**过来的，粘进来的东西经常带着 `Bearer `、引号、
/// 换行，或者干脆是整段 `export GROQ_API_KEY=...`。与其在界面上教育用户，
/// 不如在这里把 key 捞出来。
public enum APIKeyNormalization {

    public enum Failure: LocalizedError, Equatable {
        case empty(CloudProvider)
        /// 粘贴的内容里找不到 `gsk_` 开头的串。
        case groqFormat

        public var errorDescription: String? {
            switch self {
            case .empty(let provider): return "\(provider.label) 的 key 是空的"
            case .groqFormat: return "不像是 Groq key —— 应该以 gsk_ 开头"
            }
        }
    }

    public static func normalized(_ raw: String, provider: CloudProvider) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty(provider) }

        switch provider {
        case .groq:
            if trimmed.hasPrefix("gsk_") { return trimmed }
            // 整段粘贴（`export GROQ_API_KEY="gsk_…"`、带说明的一行）里把 key 抠出来。
            guard let extracted = firstMatch("gsk_[A-Za-z0-9_-]+", in: trimmed) else {
                throw Failure.groqFormat
            }
            return extracted
        case .openai, .gemini:
            return removingBearerPrefix(trimmed)
        }
    }

    /// key 的环境变量名。解析顺序是**环境变量优先于 Keychain**，
    /// 这样跑自测/CI 不必往用户的钥匙串里写东西。
    public static func environmentVariableName(_ provider: CloudProvider) -> String {
        switch provider {
        case .openai: return "INKFALL_OPENAI_API_KEY"
        case .groq: return "INKFALL_GROQ_API_KEY"
        case .gemini: return "INKFALL_GEMINI_API_KEY"
        }
    }

    /// 界面上显示用的遮罩形式：`gsk_abcd…3f2a`。
    /// 全长绝不显示 —— 设置页会被截图、会被投屏。
    public static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 4)) }
        return key.prefix(8) + "…" + key.suffix(4)
    }

    private static func removingBearerPrefix(_ value: String) -> String {
        guard value.lowercased().hasPrefix("bearer ") else { return value }
        return String(value.dropFirst("bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matched = Range(match.range, in: text) else { return nil }
        return String(text[matched])
    }
}
