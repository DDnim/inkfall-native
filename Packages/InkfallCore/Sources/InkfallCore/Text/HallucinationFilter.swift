import Foundation

/// 剔除 Whisper 在**没有语音**的音频上凭空生成的套话。
///
/// 这是本地 Whisper 最伤体验的一个失效模式：训练数据里塞满了 YouTube 字幕，
/// 所以喂给它静音、呼吸声、键盘声或背景音乐时，它会自信地吐出字幕组片尾 ——
/// 「字幕由 Amara.org 社群提供」「請不吝點贊 訂閱」「Thanks for watching!」。
/// 这些句子解码置信度很高，`logProbThreshold` / `noSpeechThreshold` 拦不住。
///
/// 提交策略（`RecordingSubmissionPolicy`）已经挡掉了全静音的一段，但**不够**：
/// 用户在嘈杂环境里按住说话又什么都没说，音频不静但也没有语音 —— 那一段照样
/// 会被提交，然后粘出一句片尾。
///
/// ⚠️ **只在整段输出就是套话时才丢弃**，绝不做子串删除。用户完全可能真的说
/// 「谢谢观看」，把它从一段正常句子里抠掉比留着幻觉更糟。
public enum HallucinationFilter {

    /// 归一化之后与之完全相等即判为幻觉。
    ///
    /// 名单刻意保守 —— 只收那些真实出现过、且几乎不可能是用户原话的整句。
    /// 中文条目同时收简繁：模型输出的字形不稳定。
    ///
    /// 这里写自然形态，比较前统一过一遍 `normalize` —— 手写归一化形式太容易
    /// 出错（一个漏掉的空格就让整条永不命中）。
    static let exactPhrases: Set<String> = Set(rawPhrases.map(normalize))

    private static let rawPhrases: [String] = [
        // 中文字幕组片尾
        "字幕由 Amara.org 社群提供",
        "由 Amara.org 社群提供",
        "中文字幕由 Amara.org 社群提供",
        "字幕志愿者李宗盛",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目",
        "明镜与点点栏目",
        "小编推荐",
        "谢谢观看",
        "謝謝觀看",
        "谢谢大家收看",
        "下集再见",
        "下期再见",
        "字幕提供",
        "本字幕由字幕组提供",
        "优优独播剧场",
        "优优独播剧场——YoYo Television Series Exclusive",
        // 英文
        "thanks for watching",
        "thank you for watching",
        "thanks for watching!",
        "subscribe to my channel",
        "please subscribe",
        "Subtitles by the Amara.org community",
        "Transcription by CastingWords",
        // 日文
        "ご視聴ありがとうございました",
        "ご清聴ありがとうございました",
        "チャンネル登録お願いします",
    ]

    /// 只由这些字符组成也算无内容输出（模型对静音常吐一串标点或省略号）。
    private static let punctuationOnly = CharacterSet(charactersIn:
        " .。，,、!！?？…·-—~～\"'“”‘’()（）[]【】/\\*#♪♫「」『』:：;；\n\t")

    /// - Returns: 这一整段是不是幻觉，该整条丢弃。
    public static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // 纯标点/纯符号 —— 没有任何可粘贴的内容。
        if trimmed.unicodeScalars.allSatisfy(punctuationOnly.contains) { return true }
        if exactPhrases.contains(normalize(trimmed)) { return true }
        // 同一句短语被重复刷屏是解码陷进循环的典型形态
        //（「好的好的好的好的…」）。真人不会这么说。
        if isDegenerateRepetition(trimmed) { return true }
        return false
    }

    /// 去掉大小写、空白与标点差异 —— 模型在这三件事上完全不稳定。
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars where !punctuationOnly.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// 解码退化：整段被同一个短片段重复铺满。
    ///
    /// 判据是「去重后的内容不足总长的三分之一」，且至少重复了 4 次 ——
    /// 正常的口语重复（「对对对」）达不到这个量级。
    static func isDegenerateRepetition(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard normalized.count >= 24 else { return false }
        let scalars = Array(normalized)
        // 试所有不长于四分之一总长的重复单元。
        for unit in 1...(scalars.count / 4) {
            let pattern = Array(scalars[0..<unit])
            var repeats = 0
            var index = 0
            while index + unit <= scalars.count,
                  Array(scalars[index..<(index + unit)]) == pattern {
                repeats += 1
                index += unit
            }
            // 允许结尾有个不完整的残片。
            let covered = Double(repeats * unit) / Double(scalars.count)
            if repeats >= 4, covered >= 0.9 { return true }
        }
        return false
    }
}
