import Foundation

/// 插话纠错（试做，分支 `exp/interject`）不碰网络的那一半：Jev 的门、核对的提示词、JSON 解析。
///
/// 两步：Jev 一次请求问两件事（说完了吗 / 有没有可核对的事实）→ 过了门才用**加工模型**
/// 另发一次请求核对。核对不能并进加工提示词：那样加工会把「苹果是蔬菜」悄悄改成
/// 「苹果是水果」粘出去。提示词是 verbatim，改了要重跑 `experiments/interject`。
/// 设计：vault `Wiki/inkfall-AI插话纠错设计.md`。
public enum InterjectionAPI {

    // MARK: - Jev 的门

    public static let gateModel = "jev-latest"

    // verbatim：与 experiments/jev/run.py 的 SEG_Q 相同（断句实验 30/30）
    public static let completeQuestion =
        "A dictation app transcribes speech and the speaker just paused for about 1.3 seconds. `segment` is what they said "
        + "since the last cut (`previous` is earlier context). Is `segment` a complete thought, so it is right to cut and send it "
        + "now — rather than the speaker pausing mid-sentence to think and about to continue the same sentence?"

    // verbatim：与 experiments/interject/run.py 的 CLAIM_Q 相同
    public static let claimQuestion =
        "`segment` is what a person just said aloud (`previous` is what they said just before). Does `segment` state, as the "
        + "speaker's own claim, a fact about the world that could be checked against common knowledge — rather than an opinion, "
        + "a plan, a question, an instruction, a joke, or words the speaker attributes to someone else?"

    /// 低于它就是「没说完」，把这段留着拼到下一段前面再问（断句实验：句中停顿 ≤ 0.26）。
    public static let completeThreshold = 0.3
    /// 低于它就不去核对。
    public static let claimThreshold = 0.5

    public struct Gate: Sendable, Equatable {
        public let complete: Double
        public let claim: Double
        public init(complete: Double, claim: Double) {
            self.complete = complete
            self.claim = claim
        }
        public var isComplete: Bool { complete >= completeThreshold }
        public var passes: Bool { isComplete && claim >= claimThreshold }
    }

    public static func gateBody(previous: [String], segment: String) -> Data? {
        let payload: [String: Any] = [
            "model": gateModel,
            "state": ["previous": previous.joined(separator: "\n"), "segment": segment],
            "questions": [
                "complete": ["type": "noul", "instructions": completeQuestion],
                "claim": ["type": "noul", "instructions": claimQuestion],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public static func parseGate(_ data: Data) throws -> Gate {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let complete = ((answers["complete"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue,
              let claim = ((answers["claim"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue,
              (0...1).contains(complete), (0...1).contains(claim)
        else { throw TextGenerationAPI.Failure.malformedResponse }
        return Gate(complete: complete, claim: claim)
    }

    // MARK: - 核对（加工模型）

    // verbatim：与 experiments/interject/run.py 的 CHECK_INSTRUCTIONS 相同
    public static let checkInstructions = """
    You are a quiet fact-checker listening to someone talk. `segment` is what they just said; `previous` is what they said \
    just before (context only). Decide whether `segment` asserts, as the speaker's own claim, something that is clearly and \
    unambiguously false by common knowledge.

    Do NOT flag (use kind "not_claim" or "disputed"):
    - opinions, plans, questions, instructions, hypotheticals, jokes or sarcasm
    - words the speaker attributes to someone else ("他说…", "some people think…")
    - a claim the speaker corrects themselves within the segment
    - claims whose truth depends on definition or context (e.g. whether a tomato is a vegetable, whether Pluto is a planet)
    - recent or time-sensitive facts, niche facts, or anything you are not sure about
    - text that is probably a speech-recognition error rather than what the speaker meant

    Reply with only one JSON object, no code fence, no other text:
    {"wrong": true or false, "kind": "clear_error" | "disputed" | "outdated" | "not_claim" | "correct", "confidence": 0.0 to 1.0, "correction": "...", "detail": "..."}

    - correction: only when wrong — one short sentence stating the correct fact, written in the same language as \
    `segment` (Chinese segment → Chinese), with no preamble. At most 20 characters for Chinese or Japanese, at most 12 \
    words otherwise. Example: 苹果是水果
    - detail: only when wrong — one short sentence of evidence in the speaker's language
    - when not wrong, correction and detail are empty strings
    """

    public static func checkInput(previous: [String], segment: String) -> String {
        let context = previous.isEmpty ? "(none)" : previous.joined(separator: "\n")
        return "previous:\n\(context)\n\nsegment:\n\(segment)"
    }

    public enum Kind: String, Sendable, Equatable {
        case clearError = "clear_error"
        case disputed
        case outdated
        case notClaim = "not_claim"
        case correct
    }

    public struct Check: Sendable, Equatable {
        public let wrong: Bool
        public let kind: Kind
        public let confidence: Double
        public let correction: String
        public let detail: String
        public init(wrong: Bool, kind: Kind, confidence: Double, correction: String, detail: String) {
            self.wrong = wrong
            self.kind = kind
            self.confidence = confidence
            self.correction = correction
            self.detail = detail
        }
    }

    /// 念更正用哪种语音：有假名 → 日语，有汉字 → 中文，否则英语。
    /// 不交给系统猜：AVSpeechUtterance 默认跟系统语言走，「富士山は本州にある」会被念成中文。
    public static func speechLanguage(for text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja-JP" }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh-CN" }
        return "en-US"
    }

    /// 模型的回答 → `Check`。小模型爱包 ```json 围栏、爱在前后多说一句，
    /// 所以取第一个 `{` 到最后一个 `}`。认不出的 kind 当 not_claim（宁可不插）。
    public static func parseCheck(_ text: String) throws -> Check {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw TextGenerationAPI.Failure.malformedResponse }
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0
        return Check(wrong: (object["wrong"] as? Bool) ?? false,
                     kind: (object["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .notClaim,
                     confidence: min(max(confidence, 0), 1),
                     correction: ((object["correction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                     detail: ((object["detail"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
