import Foundation

/// 边听边插话的「抢话」：不等这句说完，听到说错的事实就插嘴（2026-10-01 境：要的是它打断我，不是等我说完）。
///
/// 原来三道门都让着人：Smart Turn 判没说完就不转写；Jev 判没说完就不核对；纠正好了有人接着说就先听完再定。
/// 抢话把这三道门拆掉，代价是当场改口（「是大阪……啊不对」）也会被插 —— 那时纠正已经念出去了。
public enum BargeIn {

    /// 话没说完时也去核对的门槛：比说完的句子（`InterjectionAPI.claimThreshold` 0.5）高一点 —— 半句话更容易看走眼。
    public static let unfinishedClaim = 0.6

    /// Smart Turn 判没说完的停顿也转写，但要比说完的句子多留这么多次 Whisper 额度（免费档每分钟 20 次）。
    /// 起先留 6 次：模拟里一分钟聊下来额度总在 10 次上下，句中停顿一次也没转写，抢话等于没开（2026-10-01）。
    public static let unfinishedReserve = 2

    /// 这一段没说完，但已经像在说事实：先核对，不等后半句。
    public static func checksUnfinished(_ gate: InterjectionAPI.Gate) -> Bool {
        gate.claim >= unfinishedClaim
    }

    /// 这句说完收下时，前半句已经抢着纠正过了：不再核对一次（Qwen 的措辞每次略有不同，`duplicate` 挡不住）。
    public static func alreadyInterrupted(_ text: String, interrupted: [String]) -> Bool {
        let whole = normalize(text)
        return interrupted.contains { !normalize($0).isEmpty && whole.contains(normalize($0)) }
    }

    /// 抢话时念在纠正前面的那句「等一下」，跟纠正同一种语言。
    public static func interruptPhrase(for correction: String) -> String {
        let scalars = correction.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ちょっと待って、" }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "等一下，" }
        return "Wait, "
    }

    /// 排队念的下一句前面那句「还有」。
    public static func followUpPhrase(for correction: String) -> String {
        switch interruptPhrase(for: correction) {
        case "ちょっと待って、": return "それと、"
        case "等一下，": return "还有，"
        default: return "Also, "
        }
    }

    /// 念出来的整句：纠正 + 理由（2026-10-01 境：「只有否定，没有解释」—— 核对一直有 detail，原来没念）。
    public static func explained(_ correction: String, detail: String) -> String {
        let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return correction }
        let head = correction.trimmingCharacters(in: CharacterSet(charactersIn: "。．.!！，,、 "))
        switch interruptPhrase(for: correction) {
        case "ちょっと待って、": return head + "。" + reason
        case "等一下，": return head + "，" + reason
        default: return head + ". " + reason
        }
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
