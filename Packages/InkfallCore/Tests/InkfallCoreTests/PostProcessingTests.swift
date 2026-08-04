import XCTest
@testable import InkfallCore

// 加工链路里不需要活的 App 环境的那一半：提示词拼装、送不送云端的裁决、
// key 归一化、请求体与响应体的形状。
//
// 真正发请求那一层在 App 里（`PostProcessor`），靠 `--process-test` 真机验证。

final class PostProcessingPromptTests: XCTestCase {

    /// 结构是 `{base} {language_rule} {guard}` —— 顺序和空格都算行为，
    /// 提示词的任何漂移用户都感知得到。
    func testBuiltInPresetStructure() throws {
        let text = try PostProcessingPrompt.instructions(preset: .clean)
        XCTAssertEqual(text,
                       PostProcessingPreset.clean.basePrompt + " "
                       + PostProcessingPrompt.languageRule + " "
                       + PostProcessingPrompt.guardRule)
    }

    /// Custom **没有** language rule：用户完全可能就是要翻译。
    /// 但护栏还是要带。
    func testCustomPresetKeepsGuardButDropsLanguageRule() throws {
        let text = try PostProcessingPrompt.instructions(
            preset: .custom, customPrompt: "  Translate to English.  ")
        XCTAssertEqual(text, "Translate to English. " + PostProcessingPrompt.guardRule)
        XCTAssertFalse(text.contains(PostProcessingPrompt.languageRule))
    }

    func testEmptyCustomPromptThrows() {
        XCTAssertThrowsError(
            try PostProcessingPrompt.instructions(preset: .custom, customPrompt: "   ")
        ) { error in
            XCTAssertEqual(error as? PostProcessingPrompt.Failure, .emptyCustomPrompt)
        }
    }

    /// 九个预设都要有 base（custom 的 base 是用户给的，所以它是空的）。
    func testEveryPresetHasABasePrompt() {
        for preset in PostProcessingPreset.allCases where preset != .custom {
            XCTAssertFalse(preset.basePrompt.isEmpty, "\(preset.rawValue) 没有 base 提示词")
            XCTAssertFalse(preset.label.isEmpty, "\(preset.rawValue) 没有界面名字")
        }
        XCTAssertTrue(PostProcessingPreset.custom.basePrompt.isEmpty)
    }

    /// 记忆与近期上下文按固定顺序追加在末尾，空的时候一个字都不加。
    func testContextAppendedInOrder() throws {
        let plain = try PostProcessingPrompt.instructions(preset: .light,
                                                          memoryContext: "  ",
                                                          recentContext: "")
        XCTAssertFalse(plain.contains("Memory context:"))
        XCTAssertFalse(plain.contains("Recent dictations:"))

        let full = try PostProcessingPrompt.instructions(preset: .light,
                                                        memoryContext: "叫我老张",
                                                        recentContext: "上一段")
        let memoryAt = full.range(of: "Memory context:")
        let recentAt = full.range(of: "Recent dictations:")
        XCTAssertNotNil(memoryAt)
        XCTAssertNotNil(recentAt)
        XCTAssertTrue(memoryAt!.lowerBound < recentAt!.lowerBound, "记忆在前，近期在后")
        XCTAssertTrue(full.hasSuffix("上一段"))
    }

    /// 上下文有硬上限：8 000 字，谁也别想把 token 预算撑爆。
    func testContextTruncatedTo8000Characters() throws {
        let huge = String(repeating: "字", count: 12_000)
        let text = try PostProcessingPrompt.instructions(preset: .light, memoryContext: huge)
        let body = text.components(separatedBy: "Memory context:\n").last ?? ""
        XCTAssertEqual(body.count, PostProcessingPrompt.contextCharLimit)
    }

    /// 近期上下文：最近 6 条、每条 400 字、`---` 分隔、空条目丢掉。
    func testRecentContextShape() {
        let entries = (1...10).map { "第\($0)条" }
        let context = PostProcessingPrompt.recentContext(from: entries)
        XCTAssertEqual(context.components(separatedBy: "\n\n---\n\n").count, 6)
        XCTAssertTrue(context.hasPrefix("第1条"), "最新的在最前")
        XCTAssertFalse(context.contains("第7条"))

        let long = String(repeating: "话", count: 500)
        let capped = PostProcessingPrompt.recentContext(from: [long])
        XCTAssertEqual(capped.count, PostProcessingPrompt.recentEntryCharLimit + 1)
        XCTAssertTrue(capped.hasSuffix("…"), "截断要看得出来")

        XCTAssertEqual(PostProcessingPrompt.recentContext(from: ["", "  ", "有内容"]), "有内容")
    }

    func testUserBody() {
        XCTAssertEqual(PostProcessingPrompt.userBody(transcript: "你好"),
                       "Transcript to process:\n你好")
    }
}

// MARK: - 送不送云端

final class PostProcessingPolicyTests: XCTestCase {

    private func settings(enabled: Bool = true,
                          preset: PostProcessingPreset = .light) -> AppSettings {
        var s = AppSettings()
        s.transcriptionMode = .local
        s.postProcessingEnabled = enabled
        s.postProcessingPreset = preset
        s.postProcessingProvider = .groq
        s.sanitize()
        return s
    }

    private let sentence = "这是一段足够长的口述内容，够得上加工的门槛。"

    func testCloudWhenEverythingIsInPlace() {
        let decision = PostProcessingPolicy.decide(
            settings: settings(), durationMs: 5_000,
            transcript: sentence, speakerLabeled: false)
        XCTAssertEqual(decision, .cloud(preset: .light, provider: .groq,
                                        model: "openai/gpt-oss-20b"))
    }

    /// 开关关着就是原样输出 —— 这个开关以前是空的（点了没有任何行为差别），
    /// 现在它必须真的管事。
    func testDisabledMeansRaw() {
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(enabled: false), durationMs: 9_000,
                                        transcript: sentence, speakerLabeled: false),
            .raw(.disabled))
    }

    /// A13 的邻居：带说话人标签的段绝不加工，标签的排版是结构不是噪声。
    func testSpeakerLabeledNeverProcessed() {
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(), durationMs: 9_000,
                                        transcript: "说话人 1：你好", speakerLabeled: true),
            .raw(.speakerLabeled))
    }

    /// basic 是本地预设：不联网、不要 key。
    func testBasicPresetStaysLocal() {
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(preset: .basic), durationMs: 9_000,
                                        transcript: sentence, speakerLabeled: false),
            .local(.presetBasic))
    }

    /// 太短 / 字太少不值一次往返，但仍然过一遍本地润色
    /// （刻意不同于 Tauri 版的 raw —— 见 `PostProcessingPolicy` 的说明）。
    func testShortTakesFallBackToLocalPolish() {
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(), durationMs: 2_999,
                                        transcript: sentence, speakerLabeled: false),
            .local(.tooShort))
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(), durationMs: 9_000,
                                        transcript: "嗯好的", speakerLabeled: false),
            .local(.tooFewCharacters))
    }

    func testEmptyTranscriptIsRaw() {
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: settings(), durationMs: 9_000,
                                        transcript: "  \n ", speakerLabeled: false),
            .raw(.emptyTranscript))
    }

    /// 每个预设可以单独配模型；快档用小模型，重活儿用大模型。
    func testPerPresetModelSelection() {
        var s = settings(preset: .meeting)
        XCTAssertEqual(s.postProcessingModel(for: .meeting), "qwen/qwen3-32b")
        XCTAssertEqual(s.postProcessingModel(for: .light), "openai/gpt-oss-20b")
        s.postProcessingProvider = .openai
        XCTAssertEqual(s.postProcessingModel(for: .light), "gpt-4o-mini")
        XCTAssertEqual(s.postProcessingModel(for: .meeting), "gpt-4.1")
    }

    /// 落笔有独立的开关与预设，走同一套裁决。
    func testNoteEffectiveSettingsDriveTheSameDecision() {
        var s = settings(enabled: false, preset: .light)
        s.noteProcessingEnabled = true
        s.noteProcessingPreset = .notes
        let decision = PostProcessingPolicy.decide(
            settings: s.noteEffective(), durationMs: 9_000,
            transcript: sentence, speakerLabeled: false)
        XCTAssertEqual(decision, .cloud(preset: .notes, provider: .groq,
                                        model: "qwen/qwen3-32b"))
    }
}

// MARK: - 中文标点归一

final class CJKPunctuationTests: XCTestCase {

    /// 模型在中文里吐半角标点是常态（裁掉上下文之后尤其明显），
    /// 而加工的卖点之一就是「补标点」。
    func testHalfWidthPunctuationInChineseBecomesFullWidth() {
        XCTAssertEqual(
            CJKPunctuation.normalize("我觉得这个功能可以先做一个最小版本,然后再迭代,你觉得呢?"),
            "我觉得这个功能可以先做一个最小版本，然后再迭代，你觉得呢？")
        XCTAssertEqual(CJKPunctuation.normalize("好的."), "好的。")
        XCTAssertEqual(CJKPunctuation.normalize("注意:这里有坑;别踩"), "注意：这里有坑；别踩")
    }

    /// ⚠️ 这一条是这个函数存在的**风险面**：英文、小数、文件名、版本号里的
    /// 半角标点一个都不能动。判据是「前一个非空白字符是不是汉字」。
    func testNonChineseContextUntouched() {
        for text in ["Hello, world.", "3.14", "gpt-4.1-mini", "note.swift",
                     "见 note.swift", "用 gpt-4.1, 快", "https://a.com/b?c=1"] {
            XCTAssertEqual(CJKPunctuation.normalize(text), text, text)
        }
    }

    /// 中文后面紧跟英文/数字时也不动 —— 那是「中文里嵌了一段英文」，
    /// 半角标点在那儿是对的。
    func testChineseFollowedByLatinKeepsHalfWidth() {
        XCTAssertEqual(CJKPunctuation.normalize("模型是 gpt-4.1"), "模型是 gpt-4.1")
        XCTAssertEqual(CJKPunctuation.normalize("文件叫 note.swift"), "文件叫 note.swift")
    }

    func testAlreadyFullWidthUnchanged() {
        let text = "我觉得这个可以，然后再迭代。你觉得呢？"
        XCTAssertEqual(CJKPunctuation.normalize(text), text)
    }
}

// MARK: - 命令行助手那条路

final class ClaudeCodeCLITests: XCTestCase {

    /// 裁上下文的那几个开关是这条路的核心 —— 少一条实测就多几千个 token
    /// （裸调 19 982 → 裁完 256）。参数拼错不该等到用户账单上才发现。
    func testLeanStreamingArguments() {
        let arguments = CLIAgentKind.claudeCode.transformArguments(
            instructions: "做这个", input: "这段话", effort: "low")
        XCTAssertEqual(arguments, [
            "-p", "--system-prompt", "做这个", "这段话",
            "--tools", "", "--disable-slash-commands", "--strict-mcp-config",
            "--setting-sources", "",
            "--effort", "low",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        ])
        // `--bare` 会跳过 OAuth（反而要 API key），而裁上下文不用付这个代价。
        XCTAssertFalse(arguments.contains("--bare"))
    }

    /// 逐 token 增量要三个 flag 一起给；关掉流式就退回一次性 json。
    func testNonStreamingDropsThePartialMessageFlags() {
        let arguments = CLIAgentKind.claudeCode.transformArguments(
            instructions: "a", input: "b", effort: "low", streaming: false)
        XCTAssertEqual(arguments.suffix(2), ["--output-format", "json"])
        XCTAssertFalse(arguments.contains("--include-partial-messages"))
        XCTAssertFalse(arguments.contains("stream-json"))
    }

    /// 空模型名/空力度不该变成一个 `--model ""` 或 `--effort ""` 参数。
    func testOptionalFlagsOnlyWhenSet() {
        let bare = CLIAgentKind.claudeCode
            .transformArguments(instructions: "a", input: "b", effort: "  ", model: "  ")
        XCTAssertFalse(bare.contains("--model"))
        XCTAssertFalse(bare.contains("--effort"))
        let picked = CLIAgentKind.claudeCode
            .transformArguments(instructions: "a", input: "b", effort: "high", model: "haiku")
        XCTAssertEqual(picked[picked.firstIndex(of: "--model")! + 1], "haiku")
        XCTAssertEqual(picked[picked.firstIndex(of: "--effort")! + 1], "high")
    }

    func testTextDeltaParsing() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}}"#
        XCTAssertEqual(CLIAgentKind.claudeCode.parse(line: line), .textDelta("你好"))
    }

    /// init / status / message_stop 这些是正常事件，不是错误 —— 忽略即可。
    func testUnrelatedLinesIgnored() {
        for line in [#"{"type":"system","subtype":"init"}"#,
                     #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
                     "", "not json", "[]"] {
            XCTAssertEqual(CLIAgentKind.claudeCode.parse(line: line), .ignored, line)
        }
    }

    func testResultLine() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"清理后的文字","total_cost_usd":0.0021,"duration_ms":2100}"#
        guard case .result(let result) = CLIAgentKind.claudeCode.parse(line: line) else {
            return XCTFail("没解析成 result")
        }
        XCTAssertEqual(result.text, "清理后的文字")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.costUSD, 0.0021)
        XCTAssertEqual(result.durationMs, 2100)
    }

    /// ⚠️ 真实的认证失败那一行 `subtype` 仍然是 `"success"`，只有
    /// `is_error` 是 true。判 subtype 会把「没登录」当成一次成功的加工，
    /// 然后把 "Not logged in · Please run /login" 粘进用户的文档里。
    func testAuthFailureIsDetectedDespiteSuccessSubtype() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","terminal_reason":"api_error","total_cost_usd":0}"#
        guard case .result(let result) = CLIAgentKind.claudeCode.parse(line: line) else {
            return XCTFail("没解析成 result")
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorKind, "api_error")
    }

    /// 每个 CLI 工具都要说清楚：可执行文件叫什么、可能装在哪儿、认哪几档力度。
    /// App 从 Finder 起来时 PATH 是空的，少一条搜索路径就等于
    /// 「本机装了却说没装」。
    func testAgentDescribesItself() {
        for agent in CLIAgentKind.allCases {
            XCTAssertFalse(agent.executable.isEmpty)
            XCTAssertFalse(agent.label.isEmpty)
            XCTAssertGreaterThan(agent.timeoutSeconds, 0)
            XCTAssertFalse(agent.effortLevels.isEmpty, "\(agent.rawValue) 没说有哪几档力度")
        }
        XCTAssertEqual(CLIAgentKind.claudeCode.executable, "claude")
        XCTAssertEqual(CLIAgentKind.claudeCode.effortLevels.first, "low", "加工默认最低档")
        XCTAssertEqual(PostProcessingEngine.claudeCode.cliAgent, .claudeCode)
        XCTAssertNil(PostProcessingEngine.cloud.cliAgent)
    }

    /// 不认识的力度会被 claude 直接拒（整轮加工失败），所以要在 sanitize
    /// 里收回默认档，而不是原样发出去。
    func testUnknownEffortSanitizedBack() {
        var s = AppSettings()
        s.postProcessingEngine = .claudeCode
        s.cliAgentEffort = "ultra"
        s.sanitize()
        XCTAssertEqual(s.cliAgentEffort, "low")

        s.cliAgentEffort = "high"
        s.sanitize()
        XCTAssertEqual(s.cliAgentEffort, "high", "认识的档位不该被改掉")
    }

    /// 引擎切到 CLI 之后，裁决走另一条分支，但门槛（时长、字数、
    /// 说话人标签、开关）一条都不变。
    func testEngineRoutesToTheCLIWithoutChangingTheGates() {
        var s = AppSettings()
        s.transcriptionMode = .local
        s.postProcessingEnabled = true
        s.postProcessingPreset = .clean
        s.postProcessingEngine = .claudeCode
        s.cliAgentEffort = "low"
        s.sanitize()

        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: s, durationMs: 9_000,
                                        transcript: "这是一段足够长的口述内容，够得上门槛。",
                                        speakerLabeled: false),
            .cli(agent: .claudeCode, preset: .clean, effort: "low", model: ""))
        // 短录音仍然走本地，不该为了一句「好的」去 fork 一个 claude。
        XCTAssertEqual(
            PostProcessingPolicy.decide(settings: s, durationMs: 1_000,
                                        transcript: "这是一段足够长的口述内容，够得上门槛。",
                                        speakerLabeled: false),
            .local(.tooShort))
        // 这条路不需要任何云供应商 key。
        XCTAssertTrue(s.activeCloudProviders.isEmpty)
    }
}

// MARK: - key 归一化

final class APIKeyNormalizationTests: XCTestCase {

    func testGroqKeyTakenAsIs() throws {
        XCTAssertEqual(try APIKeyNormalization.normalized("  gsk_abc123  ", provider: .groq),
                       "gsk_abc123")
    }

    /// 用户粘的经常是一整行说明或 `export FOO="gsk_…"` —— 把 key 抠出来，
    /// 而不是让他自己去掐两头。
    func testGroqKeyExtractedFromPastedJunk() throws {
        XCTAssertEqual(
            try APIKeyNormalization.normalized("export GROQ_API_KEY=\"gsk_Ab-9_x\"",
                                               provider: .groq),
            "gsk_Ab-9_x")
    }

    func testGroqKeyWithoutTokenThrows() {
        XCTAssertThrowsError(try APIKeyNormalization.normalized("sk-openai-key", provider: .groq)) {
            XCTAssertEqual($0 as? APIKeyNormalization.Failure, .groqFormat)
        }
    }

    func testBearerPrefixStripped() throws {
        XCTAssertEqual(try APIKeyNormalization.normalized("Bearer sk-123", provider: .openai),
                       "sk-123")
        XCTAssertEqual(try APIKeyNormalization.normalized("bearer  AIza9  ", provider: .gemini),
                       "AIza9")
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try APIKeyNormalization.normalized("  ", provider: .groq)) {
            XCTAssertEqual($0 as? APIKeyNormalization.Failure, .empty(.groq))
        }
    }

    /// 设置页会被截图、会被投屏 —— 全长永远不显示。
    func testMaskingHidesTheMiddle() {
        let masked = APIKeyNormalization.masked("gsk_abcdefghijklmnop")
        XCTAssertEqual(masked, "gsk_abcd…mnop")
        XCTAssertFalse(masked.contains("efghij"))
    }

    func testEnvironmentVariableNames() {
        XCTAssertEqual(APIKeyNormalization.environmentVariableName(.groq), "INKFALL_GROQ_API_KEY")
        XCTAssertEqual(APIKeyNormalization.environmentVariableName(.openai),
                       "INKFALL_OPENAI_API_KEY")
        XCTAssertEqual(APIKeyNormalization.environmentVariableName(.gemini),
                       "INKFALL_GEMINI_API_KEY")
    }
}

// MARK: - 请求与响应的形状

final class TextGenerationAPITests: XCTestCase {

    private func json(_ data: Data?) -> [String: Any] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// OpenAI / Groq 走 Responses API：`instructions` + `input` 两段，
    /// 不是 chat/completions 的 messages 数组。
    func testResponsesAPIBody() {
        let body = json(TextGenerationAPI.body(provider: .openai, model: "gpt-4.1-mini",
                                               instructions: "做这个", input: "这段话"))
        XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
        XCTAssertEqual(body["instructions"] as? String, "做这个")
        XCTAssertEqual(body["input"] as? String, "这段话")
        XCTAssertNil(body["reasoning"], "OpenAI 不带 reasoning")
    }

    /// gpt-oss 默认会在思考上花掉大量 token，而加工是高频小活儿。
    func testGroqGptOssGetsLowReasoningEffort() {
        let oss = json(TextGenerationAPI.body(provider: .groq, model: "openai/gpt-oss-20b",
                                              instructions: "a", input: "b"))
        XCTAssertEqual((oss["reasoning"] as? [String: Any])?["effort"] as? String, "low")

        let qwen = json(TextGenerationAPI.body(provider: .groq, model: "qwen/qwen3-32b",
                                               instructions: "a", input: "b"))
        XCTAssertNil(qwen["reasoning"])
    }

    /// Gemini 没有 instructions 字段，两段拼一起；温度是生成档的 0.2。
    func testGeminiBody() {
        let body = json(TextGenerationAPI.body(provider: .gemini, model: "gemini-3-flash-preview",
                                               instructions: "做这个", input: "这段话"))
        let contents = body["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "做这个\n\n这段话")
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["temperature"] as? Double, 0.2)
    }

    func testEndpointsAndHeaders() {
        XCTAssertEqual(TextGenerationAPI.endpoint(provider: .groq, model: "x")?.absoluteString,
                       "https://api.groq.com/openai/v1/responses")
        XCTAssertEqual(TextGenerationAPI.endpoint(provider: .openai, model: "x")?.absoluteString,
                       "https://api.openai.com/v1/responses")
        // 模型名进路径，`/` 必须转义，否则路径被拆断。
        let gemini = TextGenerationAPI.endpoint(provider: .gemini, model: "a/b")?.absoluteString
        XCTAssertEqual(gemini,
                       "https://generativelanguage.googleapis.com/v1beta/models/a%2Fb:generateContent")

        XCTAssertEqual(TextGenerationAPI.headers(provider: .groq, key: "k")["Authorization"],
                       "Bearer k")
        XCTAssertEqual(TextGenerationAPI.headers(provider: .gemini, key: "k")["x-goog-api-key"], "k")
        XCTAssertNil(TextGenerationAPI.headers(provider: .gemini, key: "k")["Authorization"])
    }

    func testParseResponsesAPI() throws {
        let payload = """
        {"output":[{"type":"reasoning","content":[{"type":"output_text","text":"想"}]},
                   {"type":"message","content":[{"type":"output_text","text":"你好"},
                                                {"type":"output_text","text":"世界"}]}]}
        """
        XCTAssertEqual(try TextGenerationAPI.parse(provider: .groq, data: Data(payload.utf8)),
                       "你好世界")
    }

    /// `type` 缺失的响应体（老格式）当作 message / output_text —— 严格判等
    /// 会把一次完全正常的结果整个丢掉。
    func testParseToleratesMissingTypes() throws {
        let payload = #"{"output":[{"content":[{"text":"好"}]}]}"#
        XCTAssertEqual(try TextGenerationAPI.parse(provider: .openai, data: Data(payload.utf8)),
                       "好")
    }

    func testParseGemini() throws {
        let payload = #"{"candidates":[{"content":{"parts":[{"text":" 你好 "}]}}]}"#
        XCTAssertEqual(try TextGenerationAPI.parse(provider: .gemini, data: Data(payload.utf8)),
                       "你好")
    }

    func testEmptyAndMalformedResponses() {
        XCTAssertThrowsError(
            try TextGenerationAPI.parse(provider: .groq,
                                        data: Data(#"{"output":[]}"#.utf8))
        ) { XCTAssertEqual($0 as? TextGenerationAPI.Failure, .emptyResult(.groq)) }

        XCTAssertThrowsError(
            try TextGenerationAPI.parse(provider: .groq, data: Data("不是 JSON".utf8))
        ) { XCTAssertEqual($0 as? TextGenerationAPI.Failure, .malformedResponse) }
    }

    /// 会员错误要能从响应体里认出来，才好翻成「请升级」而不是一串英文。
    func testErrorCodeExtraction() {
        XCTAssertEqual(TextGenerationAPI.errorCode(in: Data(#"{"error":"quotaExceeded"}"#.utf8)),
                       "quotaExceeded")
        XCTAssertEqual(
            TextGenerationAPI.errorCode(in: Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8)),
            "invalid_api_key")
        XCTAssertEqual(TextGenerationAPI.errorCode(in: Data("{}".utf8)), "")
    }
}
