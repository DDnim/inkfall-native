import Foundation

/// 助手模式（试做，分支 `exp/interject`）不碰网络的那一半：Jev 的门、核对与回答的提示词、JSON 解析。
///
/// 助手模式：Jev 一次请求问六件事（说完了吗 / 布置任务吗 / 提问吗 / 简单问题吗 /
/// 大而不清的活吗 / 有没有可核对的事实）分流成
/// - 简单问题 → 加工模型当场回答（语音）
/// - 要查东西的问题、清楚的任务 → 看板后台建卡，agent 去做（做完可语音回报，看卡片的 `voice_reply`）
/// - 大而不清的任务 → 打开看板起票面板，境自己写
/// - 说错的事实 → 加工模型核对，纠正（语音）核对不能并进加工提示词：那样加工会把「苹果是蔬菜」悄悄改成
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
    // verbatim：2026-09-27 手试 16 句，任务 0.94–0.97 / 提问 ≤ 0.10 / 陈述 ≤ 0.09
    public static let taskQuestion =
        "The user talks to a voice assistant. `segment` is what they just said. Is `segment` asking the assistant to take on a task "
        + "or piece of work to be done later (build, fix, write, send, schedule, remind, file a ticket) — rather than asking a question "
        + "they want answered right now, or just talking?"

    // verbatim：同上，提问 0.93–0.97 / 任务 ≤ 0.10 / 陈述 ≤ 0.28（「他问我日本的首都是哪里」）
    public static let questionQuestion =
        "The user talks to a voice assistant. `segment` is what they just said. Is `segment` a genuine question the speaker wants "
        + "answered right now with information or an explanation — rather than a request to do some work, a rhetorical question, "
        + "or a statement?"

    // verbatim：2026-09-27 手试 18 句，简单问题 0.89–0.98 / 要查的问题 ≤ 0.22 / 任务 ≤ 0.55
    public static let simpleQuestion =
        "The user asked a voice assistant `segment`. Can it be answered well right now from general knowledge in one to three "
        + "sentences — without looking anything up, checking recent information, reading the user's own files, projects or "
        + "accounts, or running tools?"

    // verbatim：同上，大而不清的活 0.85–0.93 / 清楚的任务 ≤ 0.25 / 问题 ≤ 0.21
    public static let complexQuestion =
        "The user asked a voice assistant to do `segment`. Is it a large or unclear piece of work — a multi-step project, a vague "
        + "idea, or something that needs decisions about scope or approach — that the user should write up and plan themselves "
        + "before anyone starts, rather than a clear, contained task an AI coding agent could simply go and do now?"

    /// 低于它就不去核对。
    public static let claimThreshold = 0.5
    /// 简单问题 / 大而不清的活的门槛。
    public static let simpleThreshold = 0.5
    public static let complexThreshold = 0.5
    /// 布置任务 / 提问的门槛。
    public static let taskThreshold = 0.6
    public static let questionThreshold = 0.6

    public struct Gate: Sendable, Equatable {
        public let complete: Double
        public let claim: Double
        public let task: Double
        public let question: Double
        public let simple: Double
        public let complex: Double
        public init(complete: Double, claim: Double, task: Double = 0, question: Double = 0,
                    simple: Double = 0, complex: Double = 0) {
            self.complete = complete
            self.claim = claim
            self.task = task
            self.question = question
            self.simple = simple
            self.complex = complex
        }
        public var isComplete: Bool { complete >= completeThreshold }
        public var passes: Bool { isComplete && claim >= claimThreshold }

        /// 分流。优先级：任务 > 提问 > 纠错。任务和提问两项都高时取高的那个。
        /// - `checkComplete`: 切换录音按停顿切出的段才看「说完了吗」；按住说话松手就是说完了。
        public func route(checkComplete: Bool) -> Route {
            if checkComplete && !isComplete { return .incomplete }
            let isTask = task >= taskThreshold, isQuestion = question >= questionThreshold
            if isTask && (!isQuestion || task >= question) { return complex >= complexThreshold ? .ticket : .agent }
            if isQuestion { return simple >= simpleThreshold ? .answer : .agent }
            if claim >= claimThreshold { return .check }
            return .none
        }
    }

    public enum Route: String, Sendable, Equatable {
        /// 没说完：拼到下一段再问
        case incomplete
        /// 简单问题 → 加工模型当场回答并念出来
        case answer
        /// 要查东西的问题、清楚的任务 → 看板后台建卡，agent 去做
        case agent
        /// 大而不清的任务 → 打开看板起票面板
        case ticket
        /// 有事实断言 → 核对，说错了就纠正
        case check
        /// 什么都不做（只记历史）
        case none
    }

    public static func gateBody(previous: [String], segment: String) -> Data? {
        let payload: [String: Any] = [
            "model": gateModel,
            "state": ["previous": previous.joined(separator: "\n"), "segment": segment],
            "questions": [
                "complete": ["type": "noul", "instructions": completeQuestion],
                "claim": ["type": "noul", "instructions": claimQuestion],
                "task": ["type": "noul", "instructions": taskQuestion],
                "question": ["type": "noul", "instructions": questionQuestion],
                "simple": ["type": "noul", "instructions": simpleQuestion],
                "complex": ["type": "noul", "instructions": complexQuestion],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public static func parseGate(_ data: Data) throws -> Gate {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any]
        else { throw TextGenerationAPI.Failure.malformedResponse }
        func p(_ key: String) throws -> Double {
            guard let value = ((answers[key] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue,
                  (0...1).contains(value) else { throw TextGenerationAPI.Failure.malformedResponse }
            return value
        }
        return Gate(complete: try p("complete"), claim: try p("claim"), task: try p("task"), question: try p("question"),
                    simple: try p("simple"), complex: try p("complex"))
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

    // MARK: - 回答（加工模型）

    public static let answerInstructions = """
    You are a voice assistant. The user just asked `question` aloud (`previous` is what they said just before, context \
    only). Answer it so it can be read aloud: in the same language as the question, one to three short sentences, the \
    answer first, no markdown, no lists, no preamble. If you do not know or it depends on recent events, say so in one sentence.
    """

    public static func answerInput(previous: [String], question: String) -> String {
        let context = previous.isEmpty ? "(none)" : previous.joined(separator: "\n")
        return "previous:\n\(context)\n\nquestion:\n\(question)"
    }

    /// 回答念出来之前的清理：小模型偶尔还是会带 markdown 符号，念出来是「星号星号」。
    public static func cleanAnswer(_ text: String) -> String {
        var s = text
        for mark in ["**", "__", "`", "#"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

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
