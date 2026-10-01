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

    // verbatim：与 experiments/interject/run.py 的 CLAIM_Q 相同。
    // 最后一句（2026-09-30）：「日本的首都是大阪吧？」这种只是讨个附和的断言，原来的问法 claim 0.18，大阪漏了。
    public static let claimQuestion =
        "`segment` is what a person just said aloud (`previous` is what they said just before). Does `segment` state, as the "
        + "speaker's own claim, a fact about the world that could be checked against common knowledge — rather than an opinion, "
        + "a plan, a question, an instruction, a joke, or words the speaker attributes to someone else? A statement the speaker "
        + "only softens with a tag asking for agreement (「日本的首都是大阪吧？」, 「…だよね？」, \"…, right?\") still states the fact."

    // verbatim：与 experiments/live/jev_complete.py 的 VARIANTS["v2"] 相同。
    // 边听边插话（2026-09-30）：长录音停顿 0.2 秒就把攒下的整段转写一遍问这个。问的是「结尾」——
    // 两个人你一句我一句、停顿都不到 1.5 秒时，攒下来的是好几句（可能两个人的），问「整段是不是一个完整的意思」
    // 永远是否（模拟对话里攒了 40 秒一句没收，9/27 真机日志也是这样）。
    public static let liveCompleteQuestion =
        "A listening assistant transcribes a live conversation between people and the speaker just paused briefly "
        + "(about 0.2 seconds). `segment` is everything said since the last cut — it may hold several sentences, possibly "
        + "from different people (`previous` is earlier context). Does `segment` end with a finished sentence or thought — "
        + "rather than breaking off mid-sentence, with the speaker about to continue that sentence?"

    /// 低于它就是「没说完」，把这段留着拼到下一段前面再问（断句实验：句中停顿 ≤ 0.26）。
    public static let completeThreshold = 0.3
    /// 0.2 秒停顿的门槛（experiments/live/jev_complete.py v2，64 条）：说完的 0.69–0.94（只有「诶，我跟你说个事儿
    /// 什么事」0.27），半句的「日本的首都」0.59、「对了」0.56、「你知道吗」0.38。低了会把导语、半个主语当一句收下，
    /// 后面的正事被拆开单独转写，短片段 Whisper 听错得厉害（「日本的首都」→「这关在首都」）。
    public static let liveCompleteThreshold = 0.6
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

    // verbatim：与 /tmp 手试同一版（2026-10-01 v3，23 句）：问助手的 0.62–0.96（只漏「北极到底有没有企鹅啊？」0.51），
    // 对朋友说的 ≤ 0.46（「这家店几点关门来着」0.56 两可）。叫一声「落音」0.79 / 0.96。
    // 边听边插话原来只纠错（提问和任务当成说给对方的）；境：「问他问题的时候能跟我聊天」「长时间录音也能派任务」
    public static let addressedQuestion =
        "A voice assistant named 落音 (Inkfall) sits on the table while two friends chat. Either of them may turn to it — by "
        + "name or not — with a question they want answered (a fact, an explanation, a curiosity like why the sky is blue) or a "
        + "request to do something (look something up, remind, file a task). Small talk, plans and personal questions are for "
        + "the other friend. `segment` is what one of them just said (`previous` is earlier conversation). Is `segment` meant "
        + "for the assistant to answer or act on — rather than said to the other friend?"

    /// 边听边插话：高于它才当作是在跟助手说（回答 / 建卡），否则只纠错。
    public static let addressedThreshold = 0.6

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
        /// 边听边插话才问：是不是在跟助手说（`addressedQuestion`）
        public let addressed: Double
        public init(complete: Double, claim: Double, task: Double = 0, question: Double = 0,
                    simple: Double = 0, complex: Double = 0, addressed: Double = 0) {
            self.complete = complete
            self.claim = claim
            self.task = task
            self.question = question
            self.simple = simple
            self.complex = complex
            self.addressed = addressed
        }
        public var isComplete: Bool { complete >= completeThreshold }
        public var isCompleteLive: Bool { complete >= liveCompleteThreshold }
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

        /// 边听边插话（两个人聊天）的分流：在跟助手说（`addressed`）的提问 / 任务照助手模式分流（回答 / 建卡）；
        /// 其余的只纠错 —— 两个人之间的问题是问对方的；两个人的话并成一段时里面常带着对方的问句，有断言就核对。
        public var liveRoute: Route {
            if addressed >= addressedThreshold {
                let routed = route(checkComplete: false)
                if routed == .answer || routed == .agent || routed == .ticket { return routed }
                // 在跟助手说、又不是断言，但提问 / 任务都没过线（对话里带着前文，「帮我查一下明天东京的天气」
                // 提问 0.31、任务 0.26，2026-10-01 模拟）：哪个高算哪个
                if claim < claimThreshold {
                    if task > question { return complex >= complexThreshold ? .ticket : .agent }
                    return simple >= simpleThreshold ? .answer : .agent
                }
            }
            return claim >= claimThreshold ? .check : .none
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

    /// - `live`: 边听边插话的 0.2 秒停顿（问 `liveCompleteQuestion`）
    public static func gateBody(previous: [String], segment: String, live: Bool = false) -> Data? {
        let payload: [String: Any] = [
            "model": gateModel,
            "state": ["previous": previous.joined(separator: "\n"), "segment": segment],
            "questions": [
                "complete": ["type": "noul", "instructions": live ? liveCompleteQuestion : completeQuestion],
                "claim": ["type": "noul", "instructions": claimQuestion],
                "task": ["type": "noul", "instructions": taskQuestion],
                "question": ["type": "noul", "instructions": questionQuestion],
                "simple": ["type": "noul", "instructions": simpleQuestion],
                "complex": ["type": "noul", "instructions": complexQuestion],
            ].merging(live ? ["addressed": ["type": "noul", "instructions": addressedQuestion]] : [:]) { a, _ in a },
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
                    simple: try p("simple"), complex: try p("complex"), addressed: (try? p("addressed")) ?? 0)
    }

    /// Whisper 爱在句尾补个逗号（「一年有13个月,」），Jev 看到就当没说完。问之前去掉（句号问号留着）。
    public static func dropTrailingComma(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, "，,、；;：:".contains(last) {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: - 无意义的话

    /// 语气词、应答（「嗯」「对对对」「好的」「えーと」「OK」）。边听边转写时不拿它们问 Jev，
    /// 一句话收下来只有这些就整句扔掉 —— 纠错、回答都用不上，还白占 Groq 的每分钟额度。
    /// 标点和空白不算；只要剩下一个别的字（「好的，明天见」「水」）就是有内容的。
    public static func isMeaningless(_ text: String) -> Bool {
        var rest = String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
        for token in fillers where !rest.isEmpty { rest = rest.replacingOccurrences(of: token, with: "") }
        return rest.isEmpty
    }

    /// 长的在前：先整个去掉「好的」「えーと」，免得被「好」「え」拆散。
    private static let fillers: [String] = [
        "嗯哼", "好的", "是的", "那个", "就是", "然后", "哈哈", "呵呵", "对的", "行吧", "好吧",
        "嗯", "啊", "呃", "哦", "噢", "喔", "额", "唔", "哈", "呵", "嘿", "诶", "欸", "对", "是", "好", "行",
        "そうですね", "なるほど", "えーと", "えっと", "あのー", "えー", "あの", "うん", "はい", "ええ", "そう",
        "okay", "yeah", "hmm", "um", "uh", "mm", "ah", "oh", "ok",
    ].sorted { $0.count > $1.count }

    // MARK: - 核对（加工模型）

    /// 核对和回答用 Groq 的 Qwen（2026-09-30 境「让 groq 的 qwen 迅速作出指正」）。没配 Groq key 才回落加工那家。
    public static let checkProvider = CloudProvider.groq
    public static let checkModel = "qwen/qwen3.8-27b"
    /// Qwen 被限流（免费档每天 20 万 token，2026-10-01 一天的评测加真机就用完了）时改问这个：同一个 Groq key、额度另算
    public static let fallbackCheckModel = "openai/gpt-oss-20b"
    /// 核对的回答是一行 JSON（~70 token）。**必须写上限**：Groq 免费档按预计输出 token 卡每分钟 1000，
    /// 不写就按模型上限估，一次请求就超，直接 429（2026-09-30 实测）。
    public static let checkMaxOutputTokens = 160
    /// 核对用温度 0：Groq Qwen 默认温度下同一句「地球是太阳系里最大的行星」三次里有一次判成「正确」（2026-10-01）。
    /// OpenAI 不设 —— 推理模型（o 系列、gpt-5）不收 temperature，直接 400。
    public static func checkTemperature(for provider: CloudProvider) -> Double? {
        provider == .openai ? nil : 0
    }
    public static let answerMaxOutputTokens = 240

    // verbatim：与 experiments/interject/run.py 的 CHECK_INSTRUCTIONS 相同
    public static let checkInstructions = """
    You are a quiet fact-checker listening to someone talk. `segment` is what they just said; `previous` is what they said \
    just before (context only). Decide whether `segment` asserts, as the speaker's own claim, something that is clearly and \
    unambiguously false by common knowledge.

    Do NOT flag (use kind "not_claim" or "disputed"):
    - opinions, plans, real questions, instructions, hypotheticals, jokes or sarcasm (a statement only softened with a \
    tag asking for agreement, like 「日本的首都是大阪吧？」, is not a real question — check it; neither is insisting on a \
    claim, like 「我还是坚持苹果是蔬菜」 — that is still the speaker's own claim)
    - words the speaker attributes to someone else ("他说…", "some people think…")
    - a claim the speaker corrects themselves within the segment
    - claims whose truth depends on definition or context (e.g. whether a tomato is a vegetable, whether Pluto is a planet); \
    everyday categories with one clear answer are not like that — an apple is a fruit, a whale is a mammal, so \
    「苹果是蔬菜」「鲸鱼是鱼」 are clear errors, even said bluntly or repeated
    - recent or time-sensitive facts, niche facts, or anything you are not sure about
    - text that is probably a speech-recognition error rather than what the speaker meant

    Reply with only one JSON object, no code fence, no other text:
    {"wrong": true or false, "kind": "clear_error" | "disputed" | "outdated" | "not_claim" | "correct", "confidence": 0.0 to 1.0, "correction": "...", "detail": "..."}

    - correction: only when wrong — one short sentence stating the correct fact (what is actually true, not just that the \
    claim is wrong: 木星才是最大的行星, not 地球不是最大的行星), written in the same language as \
    `segment` (Chinese segment → Chinese), with no preamble. At most 20 characters for Chinese or Japanese, at most 12 \
    words otherwise. Example: 苹果是水果
    - detail: only when wrong — WHY the correct fact is true: one piece of everyday knowledge that backs it up, said \
    plainly the way a friend explains in one breath, in the same language as `segment`. It is read aloud right after \
    the correction, so it must add something new: never restate the correction or the claim, never just say the claim \
    is wrong. Write numbers as spoken words, no symbols or unit notation. At most 25 characters for Chinese or Japanese, \
    at most 15 words otherwise. Examples: correction 蜘蛛不是昆虫 → detail 它有八条腿，昆虫只有六条; \
    correction 蝙蝠是哺乳动物 → detail 它是胎生的，用奶喂小蝙蝠
    - when not wrong, correction and detail are empty strings
    """

    // MARK: - 回答（加工模型）

    public static let answerInstructions = """
    You are a voice assistant. The user just asked `question` aloud (`previous` is what they said just before, context \
    only). Answer it so it can be read aloud: in the same language as the question, one to three short sentences, the \
    answer first, no markdown, no lists, no preamble. If you do not know or it depends on recent events, say so in one sentence.
    Talk like a friend chatting — warm and casual, not a textbook. If they call you by name (落音), just answer — \
    do not remark on being called. Write numbers the way they are spoken \
    (三十万公里每秒, not 3×10^8 m/s), no symbols or formulas. Keep it to about 50 characters for Chinese or Japanese, \
    30 words otherwise.
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
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { throw TextGenerationAPI.Failure.malformedResponse }
        let json = text[start...end]
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                ?? looseCheckFields(String(json))
        else { throw TextGenerationAPI.Failure.malformedResponse }
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0
        return Check(wrong: (object["wrong"] as? Bool) ?? false,
                     kind: (object["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .notClaim,
                     confidence: min(max(confidence, 0), 1),
                     correction: ((object["correction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                     detail: ((object["detail"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 不合法的 JSON 按字段捞：Qwen 偶尔漏掉字符串的引号（`"correction": 人一生共有32颗牙齿"`，
    /// 2026-09-30 实测，该纠正的没纠正）。字符串的值到下一个 `, "键":` 或结尾的 `}` 为止，引号可有可无。
    /// 连 `wrong` 都捞不到的照旧算解析失败。
    static func looseCheckFields(_ json: String) -> [String: Any]? {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
                  let range = Range(match.range(at: 1), in: json) else { return nil }
            return String(json[range])
        }
        guard let wrong = capture(#""wrong"\s*:\s*(true|false)"#) else { return nil }
        var object: [String: Any] = ["wrong": wrong == "true"]
        object["kind"] = capture(#""kind"\s*:\s*"([a-z_]+)""#)
        if let confidence = capture(#""confidence"\s*:\s*([0-9.]+)"#).flatMap(Double.init) {
            object["confidence"] = NSNumber(value: confidence)
        }
        for key in ["correction", "detail"] {
            object[key] = capture(#""\#(key)"\s*:\s*"?(.*?)"?\s*(?:,\s*"[a-z_]+"\s*:|\}\s*$)"#)
        }
        return object
    }
}
