import Foundation

/// 专有名词纠错：把转写模型稳定听错的词换回来。
///
/// **为什么不用模型自己的提示词。** Whisper 支持 `prompt`（把上文喂进去引导用词），
/// 但在 WhisperKit + CoreML 上实测有个硬伤：带 `promptTokens` 时**第一次**转写
/// 正常，**第二次开始一律返回空**。对一个常驻的听写工具，那等于用一次就废。
/// 而且实测它对「落音 / 洛因」这类错误根本没纠过来。
/// 所以本地路径不碰提示词，改成解码之后的确定性替换。
///
/// ⚠️ **只做全词替换，不做模糊匹配。** 猜「哪个词听起来像专有名词」必然误伤 ——
/// 用户说的「洛阳」不该变成「落音」。所以规则由用户显式给出：每条是一个
/// 「听错的形态 → 正确写法」的配对。
public struct VocabularyCorrector: Sendable, Equatable {

    /// 听错的形态 → 正确写法。
    public let replacements: [String: String]

    public init(replacements: [String: String]) {
        self.replacements = replacements
    }

    public init(settings: AppSettings) {
        self.init(replacements: settings.transcriptionReplacements)
    }

    public func apply(_ text: String) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }
        var out = text
        // 长的先替换：短规则会把长规则的匹配面咬掉一块
        //（有「落音」和「落音笔记」两条时，先换短的就再也匹配不上长的了）。
        for wrong in replacements.keys.sorted(by: { $0.count > $1.count }) {
            guard let right = replacements[wrong], !wrong.isEmpty, wrong != right else { continue }
            out = out.replacingOccurrences(of: wrong, with: right)
            // 英文词额外补一次大小写不敏感的替换 —— 模型对英文专名的首字母
            // 大小写完全不稳定（inkfall / Inkfall / INKFALL）。中文没有这个问题。
            if wrong.allSatisfy(\.isASCII) {
                out = out.replacingOccurrences(of: wrong, with: right,
                                               options: [.caseInsensitive])
            }
        }
        return out
    }
}
