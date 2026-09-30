import Foundation

/// 核对结果出来之后，这一句到底插不插。宁可漏掉也不误插 —— 打断比漏掉伤人。
///
/// 纯状态机：冷却、同一句不重复、太晚不弹、本人已改口不弹。时间由调用方传进来，好测。
public struct InterjectionPolicy: Sendable {

    /// 置信度门槛（评测前的起点，见 experiments/interject）。
    public static let minConfidence = 0.8
    /// 两次插话之间至少隔这么久。只防同一口气里连着插两句（同一句纠正另有 `duplicate` 挡）；
    /// 原来的 2 分钟、后来试的 10 秒都会让聊天里接连说错的第二句不纠正
    /// （2026-09-30 边听边插话的模拟：地球 / 月亮两句都被冷却吃掉）。
    public static let cooldown: TimeInterval = 4
    /// 从这一段转写好到核对回来，超过这么久话题已经过去了，只进日志。
    public static let maxDelay: TimeInterval = 5
    /// 后面的话里出现这些就当本人已经改口。
    public static let selfCorrectionMarkers = [
        "不对", "不是", "说错", "我是说", "应该是", "更正",
        "違う", "ちがう", "じゃなくて", "間違", "訂正",
        "no wait", "i mean", "actually", "sorry,",
    ]

    /// 同一段里出现这些就当已经当场改口（「水50度就开，说错了，100度」—— 评测里 gpt-oss-20b 照样纠正了它）。
    /// 比上面那张表窄：「不是」「actually」在一句话里太常见，放进来会把「鲸鱼不是哺乳动物」这种真错也放过。
    public static let inSegmentCorrectionMarkers = [
        "不对", "说错", "我是说", "口误", "啊不是", "哦不是", "呃不是", "じゃなくて", "間違えた", "no wait", "i mean",
    ]

    public enum Decision: Sendable, Equatable {
        case show(correction: String)
        case drop(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case notWrong = "not-wrong"
        case notClearError = "not-clear-error"
        case lowConfidence = "low-confidence"
        case emptyCorrection = "empty-correction"
        case stale
        case selfCorrected = "self-corrected"
        case duplicate
        case cooldown
    }

    private var lastShownAt: Date?
    private var shown: Set<String> = []

    public init() {}

    /// - `delay`: 这一段转写好到现在过了多久
    /// - `laterSegments`: 这一段之后已经转写出来的话（看本人有没有改口）
    /// - `segment`: 被核对的这一段本身（看有没有当场改口）
    public mutating func decide(_ check: InterjectionAPI.Check, segment: String = "", delay: TimeInterval,
                                laterSegments: [String], now: Date) -> Decision {
        guard check.wrong else { return .drop(.notWrong) }
        guard check.kind == .clearError else { return .drop(.notClearError) }
        guard check.confidence >= Self.minConfidence else { return .drop(.lowConfidence) }
        let correction = check.correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else { return .drop(.emptyCorrection) }
        guard delay <= Self.maxDelay else { return .drop(.stale) }
        let later = laterSegments.joined(separator: " ").lowercased()
        guard !Self.selfCorrectionMarkers.contains(where: later.contains),
              !Self.inSegmentCorrectionMarkers.contains(where: segment.lowercased().contains)
        else { return .drop(.selfCorrected) }
        guard !shown.contains(correction) else { return .drop(.duplicate) }
        if let last = lastShownAt, now.timeIntervalSince(last) < Self.cooldown { return .drop(.cooldown) }
        lastShownAt = now
        shown.insert(correction)
        return .show(correction: correction)
    }
}
