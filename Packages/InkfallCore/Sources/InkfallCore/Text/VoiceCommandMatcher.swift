import Foundation

/// 关键词匹配。
///
/// ⚠️ 必须只喂 **raw transcript**（spec/10 A13）：加工会改写填充词和标点，
/// 能把关键词整个毁掉。
public enum VoiceCommandMatcher {

    /// 关键词与口述内容之间容许的分隔符。ASR 断句时爱在这些位置插标点。
    public static let separators: Set<Character> = Set("，,。.、：:；;！!？?~～")

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || separators.contains(character)
    }

    /// 从 `characters[start...]` 开始能不能吃掉整个关键词。
    ///
    /// 归一化：忽略大小写、忽略两侧空白（含 ASR 爱插的全角空格，
    /// 所以「克 劳 德」也匹配得上）。
    /// - Returns: 匹配结束后的下标；匹配不上返回 nil。
    private static func consumeKeyword(_ characters: [Character], from start: Int,
                                       keyword: [Character]) -> Int? {
        var index = start
        for expected in keyword {
            while true {
                guard index < characters.count else { return nil }
                let actual = characters[index]
                index += 1
                if actual.isWhitespace { continue }
                guard String(actual).lowercased() == String(expected).lowercased() else {
                    return nil
                }
                break
            }
        }
        return index
    }

    /// 在 `text` 里找一个位置被 `position` 允许的 `keyword`，返回 `{text}`：
    /// **整句话减去关键词本身**。
    ///
    /// 用户会把唤醒词放在开头、中间或结尾（「今天天气怎么样，小明」/
    /// 「我想听歌，小明，帮我找找七里香」），所以两侧都要保留；两侧都非空时
    /// 用关键词**后面**那个分隔符重新连接（回落到前面那个，再回落到「，」）。
    ///
    /// 从左往右扫，取第一个满足位置约束的出现。
    public static func removeKeyword(from text: String, keyword: String,
                                     position: KeywordPosition) -> String? {
        let characters = Array(text)
        // 关键词自己的空白先去掉 —— 用户在设置里敲的和 ASR 吐出来的都可能带空格。
        let expected = Array(keyword).filter { !$0.isWhitespace }
        guard !expected.isEmpty else { return nil }

        for start in 0...characters.count {
            guard let end = consumeKeyword(characters, from: start, keyword: expected) else {
                continue
            }
            let before = characters[0..<start]
            let after = characters[end...]
            let beforeTrimmed = trim(before)
            let afterTrimmed = trim(after)

            let allowed: Bool
            switch position {
            case .anywhere: allowed = true
            case .start: allowed = beforeTrimmed.isEmpty
            case .end: allowed = afterTrimmed.isEmpty
            case .startOrEnd: allowed = beforeTrimmed.isEmpty || afterTrimmed.isEmpty
            }
            guard allowed else { continue }

            if beforeTrimmed.isEmpty { return afterTrimmed }
            if afterTrimmed.isEmpty { return beforeTrimmed }
            let joiner = after.first.flatMap { separators.contains($0) ? $0 : nil }
                ?? before.last.flatMap { separators.contains($0) ? $0 : nil }
                ?? "，"
            return beforeTrimmed + String(joiner) + afterTrimmed
        }
        return nil
    }

    /// 两侧都去掉空白与分隔符。
    private static func trim(_ slice: ArraySlice<Character>) -> String {
        var start = slice.startIndex
        var end = slice.endIndex
        while start < end, isSeparator(slice[start]) { start += 1 }
        while end > start, isSeparator(slice[end - 1]) { end -= 1 }
        return String(slice[start..<end])
    }
}

extension AppSettings {
    /// 第一条命中的语音命令，以及去掉关键词之后的 `{text}`。
    ///
    /// 总开关关着时永远不命中 —— 随口一句以关键词开头的听写会启动终端，
    /// 而命令是任意 shell，所以这个开关默认就是关的。
    public func matchVoiceCommand(_ transcript: String) -> (command: VoiceCommand,
                                                            spoken: String)? {
        guard voiceCommandsEnabled else { return nil }
        for command in voiceCommands where command.isUsable {
            let keyword = command.keyword.trimmingCharacters(in: .whitespaces)
            if let spoken = VoiceCommandMatcher.removeKeyword(
                from: transcript, keyword: keyword, position: command.keywordPosition) {
                return (command, spoken)
            }
        }
        return nil
    }
}
