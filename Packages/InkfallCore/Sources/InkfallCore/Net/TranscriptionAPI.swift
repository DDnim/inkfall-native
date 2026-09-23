import Foundation

/// 云端转写请求的**拼装与解析**，不碰网络（spec/05 §1）。
///
/// 三条云端路：OpenAI / Groq / Gemini。前两条是同一个 `audio/transcriptions`
/// 形状的 multipart；
/// Gemini 没有转写端点，走 `generateContent` 把音频以 inline_data 塞进去。
///
/// 真正发请求的那一层（`CloudTranscriber`）在 App 里；这里的每个字节
/// 都能被单测钉住 —— 这条链上最容易写错、也最该被测住的正是请求体。
public enum TranscriptionAPI {

    /// 音频上限 25 MiB（OpenAI / Groq 的硬限制；spec/01 常数表）。
    public static let maxAudioBytes = 25 * 1024 * 1024
    /// 单请求超时 45 s（spec/01 常数表）。
    public static let requestTimeout: TimeInterval = 45
    /// 转写的温度是 0（spec/05 §6.5）—— Gemini 那条路用。
    public static let geminiTemperature = 0.0

    public static let openAIEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    public enum Failure: LocalizedError, Equatable {
        case noAudio
        case audioTooLarge
        case malformedResponse
        case emptyTranscript(String)

        public var errorDescription: String? {
            switch self {
            case .noAudio: return "没有音频"
            case .audioTooLarge: return "音频超过 25 MB"
            case .malformedResponse: return "响应解析失败"
            case .emptyTranscript(let label): return "\(label) 返回了空转写"
            }
        }
    }

    // MARK: - 路线

    public enum Route: Sendable, Equatable {
        case openai(model: String, key: String)
        case groq(model: String, key: String)
        case gemini(model: String, key: String)

        /// 界面与日志里的名字。
        public var label: String {
            switch self {
            case .openai: return "OpenAI"
            case .groq: return "Groq"
            case .gemini: return "Gemini"
            }
        }

        public var model: String {
            switch self {
            case .openai(let model, _), .groq(let model, _), .gemini(let model, _): return model
            }
        }

        /// 错误提示里用的名字：`Groq whisper-large-v3-turbo`。
        public var errorLabel: String { "\(label) \(model)" }

        /// 这条路对应的客户端供应商（错误分类与提示用）。
        public var provider: CloudProvider {
            switch self {
            case .openai: return .openai
            case .groq: return .groq
            case .gemini: return .gemini
            }
        }
    }

    /// 模型白名单：设置里的值不在表里就回默认（与 Tauri 版一致）。
    public static func model(for mode: TranscriptionMode, settings: AppSettings) -> String {
        switch mode {
        case .openai:
            return ProviderModels.openAITranscription.contains(settings.selectedOpenAiModel)
                ? settings.selectedOpenAiModel : "gpt-4o-mini-transcribe"
        case .groq:
            return ProviderModels.groqTranscription.contains(settings.selectedGroqModel)
                ? settings.selectedGroqModel : "whisper-large-v3-turbo"
        case .gemini:
            return ProviderModels.gemini.contains(settings.selectedGeminiModel)
                ? settings.selectedGeminiModel : "gemini-3.1-flash-lite-preview"
        case .local:
            return settings.selectedLocalModelId
        }
    }

    /// `verbose_json` 才带 `language` 字段回来（会话语言锁定靠它）。
    /// OpenAI 只有 whisper-1 支持；gpt-4o-*-transcribe 传了会 400。Groq 全支持。
    public static func supportsVerboseJSON(provider: CloudProvider, model: String) -> Bool {
        switch provider {
        case .openai: return model == "whisper-1"
        case .groq: return true
        case .gemini: return false
        }
    }

    // MARK: - 拼请求

    public struct Prepared: Sendable, Equatable {
        public var url: URL
        public var headers: [String: String]
        public var body: Data
    }

    /// 拼一次转写请求。
    ///
    /// - Parameters:
    ///   - language: 这一段要请求的 ISO 639-1 码；`nil` = 交给模型检测
    ///     （由 `TranscriptionLanguagePolicy.requested` 决定，这里不重算）。
    ///   - vocabulary: 专有名词表，作为 `prompt` 发给 OpenAI / Groq。
    ///   - languageInstruction: Gemini 用的语言指令（`geminiLanguageInstruction`）。
    ///   - boundary: multipart 边界；测试时传固定值。
    public static func prepare(route: Route,
                               audio: RecordedAudio,
                               language: String?,
                               vocabulary: [String] = [],
                               languageInstruction: String = "",
                               boundary: String = MultipartForm.boundaryPrefix + UUID().uuidString)
        throws -> Prepared {
        guard !audio.data.isEmpty else { throw Failure.noAudio }
        guard audio.data.count <= maxAudioBytes else { throw Failure.audioTooLarge }

        switch route {
        case .openai(let model, let key):
            return multipart(url: openAIEndpoint, auth: ["Authorization": "Bearer \(key)"],
                             model: model, provider: .openai, audio: audio, language: language,
                             vocabulary: vocabulary, boundary: boundary)
        case .groq(let model, let key):
            return multipart(url: groqEndpoint, auth: ["Authorization": "Bearer \(key)"],
                             model: model, provider: .groq, audio: audio, language: language,
                             vocabulary: vocabulary, boundary: boundary)
        case .gemini(let model, let key):
            guard let url = TextGenerationAPI.endpoint(provider: .gemini, model: model),
                  let body = geminiBody(audio: audio, languageInstruction: languageInstruction) else {
                throw Failure.malformedResponse
            }
            return Prepared(url: url,
                            headers: ["x-goog-api-key": key, "Content-Type": "application/json"],
                            body: body)
        }
    }

    private static func multipart(url: URL, auth: [String: String], model: String,
                                  provider: CloudProvider, audio: RecordedAudio,
                                  language: String?, vocabulary: [String],
                                  boundary: String) -> Prepared {
        var form = MultipartForm(boundary: boundary)
        form.addField("model", model)
        if let language { form.addField("language", language) }
        if supportsVerboseJSON(provider: provider, model: model) {
            form.addField("response_format", "verbose_json")
        }
        let prompt = vocabularyPrompt(vocabulary)
        if !prompt.isEmpty { form.addField("prompt", prompt) }
        form.addFile("file", filename: MultipartForm.sanitizeFilename(audio.filename),
                     mimeType: audio.mimeType, data: audio.data)
        var headers = auth
        headers["Content-Type"] = form.contentType
        return Prepared(url: url, headers: headers, body: form.build())
    }

    /// 专有名词表 → Whisper 的 `prompt`。逗号分隔、去空白、去重。
    public static func vocabularyPrompt(_ vocabulary: [String]) -> String {
        var seen = Set<String>()
        return vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    // MARK: - Gemini

    /// Gemini 的转写提示词（**verbatim**，与 Tauri 版一致）。
    public static let geminiPromptBase =
        "You are a speech-to-text engine. Return only the transcript text, without markdown, "
        + "labels, timestamps, explanations, or summaries. Preserve the speaker's meaning and "
        + "natural punctuation."

    /// Gemini 没有 `language` 参数，语言要写进提示词。
    /// 有明确要求的语言（固定模式或会话已锁定）就点名；否则按语言模式给提示。
    public static func geminiLanguageInstruction(policy: TranscriptionLanguagePolicy,
                                                 requested: String?) -> String {
        if let requested, let language = TranscriptionLanguage(rawValue: requested) {
            return "Transcribe in \(language.englishName)."
        }
        switch policy.mode {
        case .fixed:
            return "Transcribe in \(policy.fixed.englishName)."
        case .preferred where !policy.preferred.isEmpty:
            let names = policy.preferred.map(\.englishName).joined(separator: ", ")
            return "Prefer these languages when the audio is ambiguous: \(names)."
        case .auto, .preferred:
            return "Detect the spoken language automatically."
        }
    }

    static func geminiBody(audio: RecordedAudio, languageInstruction: String) -> Data? {
        let instruction = languageInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = instruction.isEmpty ? geminiPromptBase : "\(geminiPromptBase) \(instruction)"
        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": audio.mimeType,
                                     "data": audio.data.base64EncodedString()]],
                ],
            ]],
            "generationConfig": ["temperature": geminiTemperature],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - 解析

    public struct Parsed: Sendable, Equatable {
        public var text: String
        /// 供应商报的语言（原始字符串，`TranscriptionLanguage.detected` 负责归一化）。
        /// 只有 `verbose_json` 才有；Gemini 从不报。
        public var language: String?

        public init(text: String, language: String?) {
            self.text = text
            self.language = language
        }
    }

    public static func parse(route: Route, data: Data) throws -> Parsed {
        switch route {
        case .openai, .groq:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["text"] as? String else {
                throw Failure.malformedResponse
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.emptyTranscript(route.errorLabel) }
            let language = (object["language"] as? String)
                ?? (object["detectedLanguage"] as? String)
            return Parsed(text: text, language: language)
        case .gemini:
            let text: String
            do {
                text = try TextGenerationAPI.parse(provider: .gemini, data: data)
            } catch TextGenerationAPI.Failure.emptyResult {
                throw Failure.emptyTranscript(route.errorLabel)
            } catch {
                throw Failure.malformedResponse
            }
            return Parsed(text: text, language: nil)
        }
    }

}
