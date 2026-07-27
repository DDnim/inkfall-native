import Foundation

/// 本地、基于规则的转写清理 —— 不联网、不调用任何模型。
///
/// 它撑起 `basic` 加工预设：做用户期望「免费且离线就该有」的那种保守整理 ——
/// 去掉无意义的语气/迟疑词，收拾这些删除留下的空白，合并被删出来的重复标点，
/// 并保证结尾有句末标点。**刻意不改写、不重排、不摘要**，说话人的用词与语气原样保留。
///
/// 同时是云端加工失败时的降级目标：basic 全本地，不需要下载任何模型。
public enum BasicPolisher {

    /// 可以安全单独删掉的中文迟疑/语气词。
    /// 刻意**排除**会出现在真实词里的字（如 `额` 之于余额、`哈` 之于哈密瓜），
    /// 以及承载意义的 `那个` / `这个`。
    private static let cjkFillers = ["嗯", "唔", "呃", "啊", "呀", "哦", "噢", "唉", "诶", "欸", "呐", "嘛"]

    /// 笑声只在**重复**时折叠，单次出现留在真实词里不动。
    private static let cjkLaughter = ["哈", "呵"]

    /// 英文填充词，按整词匹配（大小写不敏感）。
    private static let latinFillers = [
        "um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mhm",
        "you know", "i mean", "kind of", "sort of",
    ]

    /// 已经算作正常结尾的句末标点。
    private static let terminators: Set<Character> = [
        "。", "！", "？", "…", "”", "」", "』", "）", "】", ".", "!", "?", ")", "\"",
    ]

    public static func polish(_ text: String) -> String {
        var result = text

        // 1. 删英文填充词（整词）。
        for filler in latinFillers {
            result = replace(#"(?i)\b\#(NSRegularExpression.escapedPattern(for: filler))\b"#,
                             in: result, with: "")
        }

        // 2. 删中文语气词，连续重复一并删（啊啊啊 → 空）。
        for filler in cjkFillers {
            result = replace("(?:\(NSRegularExpression.escapedPattern(for: filler)))+",
                             in: result, with: "")
        }

        // 3. 笑声只在重复时删。
        for laugh in cjkLaughter {
            result = replace("(?:\(NSRegularExpression.escapedPattern(for: laugh))){2,}",
                             in: result, with: "")
        }

        // 4. 收拾删除留下的空白。
        result = replace(#"[ \t]+"#, in: result, with: " ")
        result = replace(#" *\n *"#, in: result, with: "\n")
        // 填充词没了之后，紧挨汉字/中文标点的空白就是噪声。
        result = replace(#"(?<=[\p{script=Han}，。！？、；：])\s+"#, in: result, with: "")
        result = replace(#"\s+(?=[\p{script=Han}，。！？、；：])"#, in: result, with: "")

        // 5. 合并被删除弄重复的标点。
        result = replace(#"([，。！？、；：,.!?;:])[，、,]+"#, in: result, with: "$1")
        result = replace(#"([，、,])([。！？.!?])"#, in: result, with: "$2")
        // 行首被孤立的标点直接删掉。
        result = replace(#"(^|\n)[，。、；：,.;: ]+"#, in: result, with: "$1")

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        return ensureTerminalPunctuation(result)
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if terminators.contains(last) { return text }

        // 结尾的逗号应该变成句号，而不是再加一个标点。
        if last == "，" { return String(text.dropLast()) + "。" }
        if last == "," { return String(text.dropLast()) + "." }

        let isCJKTail = last.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
        return text + (isCJKTail ? "。" : ".")
    }

    /// 正则替换。模式编不出来就原样返回 —— 清理是尽力而为，绝不能因此丢文本。
    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
