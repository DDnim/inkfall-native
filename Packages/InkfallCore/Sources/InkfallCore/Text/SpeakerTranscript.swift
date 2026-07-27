import Foundation

/// 把「谁在说」贴回转写文本。
///
/// 分离模型给的是一串带说话人编号的片段，直接逐段输出会把一句话切成好几行。
/// 这里负责合并、加标签、以及决定**要不要**加标签。
public enum SpeakerTranscript {

    /// 一个片段：说话人编号（`nil` = 没匹配上）+ 文本。
    public struct Segment: Sendable, Equatable {
        public let speaker: Int?
        public let text: String

        public init(speaker: Int?, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Output: Sendable, Equatable {
        public let text: String
        /// 真正区分出来的人数。1 表示独白（不加标签）。
        public let speakerCount: Int
        /// 有没有真的加上标签。
        public let labeled: Bool
    }

    /// 标签写法。编号从 1 开始 —— 模型给的是 0-based，直接透出来会出现
    /// 「说话人 0」，看起来像 bug。
    static func label(_ speaker: Int?) -> String {
        "说话人 \((speaker ?? 0) + 1)"
    }

    public static func compose(_ segments: [Segment]) -> Output {
        let cleaned = segments
            .map { Segment(speaker: $0.speaker,
                           text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
        guard !cleaned.isEmpty else { return Output(text: "", speakerCount: 0, labeled: false) }

        // 连续同一人的片段先合并 —— 分离模型按声学边界切，一句话常被切成
        // 好几段，逐段加标签会得到一屏「说话人 1：」。
        var merged: [Segment] = []
        for segment in cleaned {
            if let last = merged.last, last.speaker == segment.speaker {
                merged[merged.count - 1] = Segment(
                    speaker: last.speaker, text: joined(last.text, segment.text))
            } else {
                merged.append(segment)
            }
        }

        let distinct = Set(cleaned.compactMap(\.speaker))
        // ⚠️ **只有一个说话人时不加标签。** 独白前面挂一排「说话人 1：」只是噪音，
        // 而按住说话的绝大多数场景就是独白。
        guard distinct.count > 1 else {
            return Output(text: merged.map(\.text).reduce("", joined),
                          speakerCount: max(distinct.count, 1), labeled: false)
        }
        let text = merged
            .map { "\(label($0.speaker))：\($0.text)" }
            .joined(separator: "\n")
        return Output(text: text, speakerCount: distinct.count, labeled: true)
    }

    /// 拼接两段文本。中日韩之间不插空格，其余按空格分词的语言要插。
    private static func joined(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left.hasSuffix(" ") || right.hasPrefix(" ") { return left + right }
        return needsSpace(left.last!) && needsSpace(right.first!)
            ? left + " " + right
            : left + right
    }

    /// 这个字符两侧要不要空格。CJK 表意文字与全角标点不要。
    private static func needsSpace(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,      // CJK 标点
             0x3040...0x30FF,      // 假名
             0x4E00...0x9FFF,      // 汉字
             0xFF00...0xFFEF,      // 全角
             0xAC00...0xD7AF:      // 谚文
            return false
        default:
            return true
        }
    }
}
