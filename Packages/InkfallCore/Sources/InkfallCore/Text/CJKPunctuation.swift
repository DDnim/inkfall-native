import Foundation

/// 把中文句子里的**半角标点**换回全角。
///
/// 为什么需要它：模型在中文文本里经常吐出 ASCII 的 `,` `?` —— 裁掉上下文
/// （不加载 CLAUDE.md / skills）之后尤其明显，本机实测 `claude --effort low`
/// 与 `medium` 都会。而加工这个功能卖点之一就是「补标点」，标点是半角的
/// 等于没做对。
///
/// ⚠️ 刻意**不写进提示词**：spec/05 §6 的提示词是 verbatim 区块，加一句
/// 「用全角标点」会让整套预设漂移，而且模型仍然会漏。确定性替换更可靠 ——
/// 和当年用 `VocabularyCorrector` 替代 Whisper prompt 是同一个道理。
public enum CJKPunctuation {

    /// 只在**两侧都是中文语境**时替换。
    ///
    /// 这条约束是关键：`3.14`、`file.swift`、`Hello, world` 里的半角标点
    /// 一个都不能动。判据是「前一个字符是 CJK」——英文句子、数字、代码路径
    /// 因此全部不受影响。
    private static let map: [Character: Character] = [
        ",": "，", ".": "。", "!": "！", "?": "？", ":": "：", ";": "；",
    ]

    public static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let characters = Array(text)

        for (index, character) in characters.enumerated() {
            guard let full = map[character] else {
                result.append(character)
                continue
            }
            // 前一个非空白字符必须是汉字 —— 这是「这句话是中文」的判据。
            guard let previous = characters[..<index].last(where: { !$0.isWhitespace }),
                  isCJK(previous) else {
                result.append(character)
                continue
            }
            // 后面必须是中文、句末，或者另一个标点。
            // 「后面是 ASCII 字母/数字」说明它其实在一段英文/代码里
            // （`模型 gpt-4.1`、`见 note.swift`），那就别动。
            let next = characters[(index + 1)...].first { !$0.isWhitespace }
            switch next {
            case nil:
                result.append(full)
            case .some(let following) where isCJK(following) || map[following] != nil
                || isFullWidthPunctuation(following):
                result.append(full)
            default:
                result.append(character)
            }
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)      // 常用汉字
            || (0x3400...0x4DBF).contains(scalar.value)      // 扩展 A
            || (0x3040...0x30FF).contains(scalar.value)      // 假名（日语也算中文语境）
    }

    private static func isFullWidthPunctuation(_ character: Character) -> Bool {
        "，。！？：；、）」』】…".contains(character)
    }
}
