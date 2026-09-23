import Foundation

public struct PostProcessingPresetModelConfig: Codable, Sendable, Equatable {
    public var provider: CloudProvider
    public var openaiModel: String
    public var groqModel: String
    public var geminiModel: String

    public init(provider: CloudProvider, openaiModel: String,
                groqModel: String, geminiModel: String) {
        self.provider = provider
        self.openaiModel = openaiModel
        self.groqModel = groqModel
        self.geminiModel = geminiModel
    }

    public static func `default`(for preset: PostProcessingPreset) -> Self {
        let fast = preset.prefersFastModel
        return .init(
            provider: .openai,
            openaiModel: fast ? "gpt-4o-mini" : "gpt-4.1",
            groqModel: fast ? "openai/gpt-oss-20b" : "qwen/qwen3-32b",
            geminiModel: fast ? "gemini-3.1-flash-lite-preview" : "gemini-3-flash-preview"
        )
    }
}

/// 全部设置。磁盘格式是 `settings.json`（camelCase key），**必须与现有数据兼容**。
///
/// ⚠️ 刻意不用合成的 `Codable`：Swift 默认的解码语义是「任一字段坏掉 → 整体失败」，
/// 而这里要的是「任一字段缺失/类型错 → 只回落**那一个**字段」，
/// 老配置（比如没有 `appLanguage` 的）才能完整加载而不丢用户其他设置。
public struct AppSettings: Codable, Sendable, Equatable {

    // 粘贴与输出
    public var insertNewlineBetweenSegments = true
    public var focusEditorAfterInsert = true
    /// 每次自动粘贴后补一个换行。默认关 —— 行内听写不该凭空多一个换行。
    public var pasteAppendNewline = false
    /// 听写完把文字直接粘回起录时的那个窗口。
    /// 关掉之后只复制到剪贴板（合成按键一个都不发），落笔的自动粘贴另有开关。
    /// 默认开 —— 这是听写的默认预期，关掉是显式选择。
    public var autoPasteEnabled = true

    // 转写
    /// 默认本机 —— 不需要 key、音频不出机器；云端是显式选择。
    public var transcriptionMode: TranscriptionMode = .local
    public var openAiProviderEnabled = false
    public var groqProviderEnabled = false
    public var geminiProviderEnabled = false
    public var selectedOpenAiModel = "gpt-4o-mini-transcribe"
    public var selectedGroqModel = "whisper-large-v3-turbo"
    public var selectedGeminiModel = "gemini-3.1-flash-lite-preview"
    public var selectedLocalModelId = "whisper-tiny"
    public var transcriptionLanguageMode: TranscriptionLanguageMode = .fixed
    public var fixedTranscriptionLanguage: TranscriptionLanguage = .zh
    public var preferredTranscriptionLanguages: [TranscriptionLanguage] = [.zh, .en, .ja]
    public var autoLocalFallbackEnabled = true
    /// 专有名词表。作为 prompt 发给**云端**转写（OpenAI / Groq 都支持）。
    /// ⚠️ 本地路径不用它 —— WhisperKit 带 promptTokens 时第二次转写起一律返回空。
    public var transcriptionVocabulary: [String] = ["落音", "Inkfall"]
    /// 听错的形态 → 正确写法。本地路径靠它纠专有名词（见 `VocabularyCorrector`）。
    public var transcriptionReplacements: [String: String] = [
        "洛因": "落音", "诺音": "落音", "落因": "落音", "inkfull": "Inkfall",
    ]

    // 加工
    /// 默认**开**。没配 key 时云端预设会静默回落到本地 basic 润色
    /// （见 `PostProcessingPolicy`），所以开着不会让任何人踩坑；
    /// 而默认关会让「填了 key 却什么都没变」成为第一个必踩的坑。
    public var postProcessingEnabled = true
    /// 默认 Groq：加工是高频小请求，它的 gpt-oss-20b 又快又便宜。
    /// 走云端转写时这个值会被 `sanitize()` 对齐到转写供应商，
    /// 本地转写时保留独立选择（这也是目前唯一跑得通的组合）。
    public var postProcessingProvider: CloudProvider = .groq
    public var postProcessingPreset: PostProcessingPreset = .light
    public var postProcessingPresetModels: [String: PostProcessingPresetModelConfig] = [:]
    public var selectedOpenAiPostProcessModel = "gpt-4.1-mini"
    public var selectedGroqPostProcessModel = "openai/gpt-oss-20b"
    public var selectedGeminiPostProcessModel = "gemini-3.1-flash-lite-preview"
    public var customPostProcessingPrompt = ""
    public var processingMemoryContext = ""

    public var noteSpeakerDiarizationEnabled = false

    // 其他
    public var appLanguage: AppLanguage = .system
    public var micGainBoostEnabled = true
    public var micGainBoostTargetPercent: UInt8 = 80
    public var hasCompletedOnboarding = false

    public init() {
        postProcessingPresetModels = Dictionary(
            uniqueKeysWithValues: PostProcessingPreset.allCases.map {
                ($0.rawValue, PostProcessingPresetModelConfig.default(for: $0))
            })
    }

    // MARK: - 容错解码

    private enum K: String, CodingKey {
        case insertNewlineBetweenSegments, focusEditorAfterInsert, pasteAppendNewline
        case autoPasteEnabled
        case transcriptionMode, openAiProviderEnabled, groqProviderEnabled, geminiProviderEnabled
        case selectedOpenAiModel, selectedGroqModel, selectedGeminiModel, selectedLocalModelId
        case transcriptionLanguageMode, fixedTranscriptionLanguage, preferredTranscriptionLanguages
        case autoLocalFallbackEnabled, transcriptionVocabulary
        case transcriptionReplacements
        case postProcessingEnabled, postProcessingProvider, postProcessingPreset
        case postProcessingPresetModels, selectedOpenAiPostProcessModel
        case selectedGroqPostProcessModel, selectedGeminiPostProcessModel
        case customPostProcessingPrompt, processingMemoryContext
        case noteSpeakerDiarizationEnabled
        case appLanguage
        case micGainBoostEnabled, micGainBoostTargetPercent
        case hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: K.self) else { return }
        func f<T: Decodable>(_ key: K, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        insertNewlineBetweenSegments = f(.insertNewlineBetweenSegments, insertNewlineBetweenSegments)
        focusEditorAfterInsert = f(.focusEditorAfterInsert, focusEditorAfterInsert)
        pasteAppendNewline = f(.pasteAppendNewline, pasteAppendNewline)
        autoPasteEnabled = f(.autoPasteEnabled, autoPasteEnabled)

        transcriptionMode = f(.transcriptionMode, transcriptionMode)
        openAiProviderEnabled = f(.openAiProviderEnabled, openAiProviderEnabled)
        groqProviderEnabled = f(.groqProviderEnabled, groqProviderEnabled)
        geminiProviderEnabled = f(.geminiProviderEnabled, geminiProviderEnabled)
        selectedOpenAiModel = f(.selectedOpenAiModel, selectedOpenAiModel)
        selectedGroqModel = f(.selectedGroqModel, selectedGroqModel)
        selectedGeminiModel = f(.selectedGeminiModel, selectedGeminiModel)
        selectedLocalModelId = f(.selectedLocalModelId, selectedLocalModelId)
        transcriptionLanguageMode = f(.transcriptionLanguageMode, transcriptionLanguageMode)
        fixedTranscriptionLanguage = f(.fixedTranscriptionLanguage, fixedTranscriptionLanguage)
        preferredTranscriptionLanguages = f(.preferredTranscriptionLanguages,
                                            preferredTranscriptionLanguages)
        autoLocalFallbackEnabled = f(.autoLocalFallbackEnabled, autoLocalFallbackEnabled)
        transcriptionVocabulary = f(.transcriptionVocabulary, transcriptionVocabulary)
        transcriptionReplacements = f(.transcriptionReplacements, transcriptionReplacements)

        postProcessingEnabled = f(.postProcessingEnabled, postProcessingEnabled)
        postProcessingProvider = f(.postProcessingProvider, postProcessingProvider)
        postProcessingPreset = f(.postProcessingPreset, postProcessingPreset)
        postProcessingPresetModels = f(.postProcessingPresetModels, postProcessingPresetModels)
        selectedOpenAiPostProcessModel = f(.selectedOpenAiPostProcessModel,
                                           selectedOpenAiPostProcessModel)
        selectedGroqPostProcessModel = f(.selectedGroqPostProcessModel, selectedGroqPostProcessModel)
        selectedGeminiPostProcessModel = f(.selectedGeminiPostProcessModel,
                                           selectedGeminiPostProcessModel)
        customPostProcessingPrompt = f(.customPostProcessingPrompt, customPostProcessingPrompt)
        processingMemoryContext = f(.processingMemoryContext, processingMemoryContext)

        noteSpeakerDiarizationEnabled = f(.noteSpeakerDiarizationEnabled,
                                          noteSpeakerDiarizationEnabled)

        appLanguage = f(.appLanguage, appLanguage)
        micGainBoostEnabled = f(.micGainBoostEnabled, micGainBoostEnabled)
        micGainBoostTargetPercent = f(.micGainBoostTargetPercent, micGainBoostTargetPercent)

        // ⚠️ 与其他字段相反：**缺失时默认 true**。
        // 现有的 settings.json 没有这个 key 说明是老用户，不该再弹一次引导。
        hasCompletedOnboarding = f(.hasCompletedOnboarding, true)
    }

    // MARK: - Sanitize

    /// 把非法/过期的值收拾回合法状态。load 与 save 两侧都要跑。
    public mutating func sanitize() {
        if !ProviderModels.openAITranscription.contains(selectedOpenAiModel) {
            selectedOpenAiModel = "gpt-4o-mini-transcribe"
        }
        if !ProviderModels.openAIPostProcess.contains(selectedOpenAiPostProcessModel) {
            selectedOpenAiPostProcessModel = "gpt-4.1-mini"
        }
        if !ProviderModels.groqTranscription.contains(selectedGroqModel) {
            selectedGroqModel = "whisper-large-v3-turbo"
        }
        if !ProviderModels.groqPostProcess.contains(selectedGroqPostProcessModel) {
            selectedGroqPostProcessModel = "openai/gpt-oss-20b"
        }
        if !ProviderModels.gemini.contains(selectedGeminiModel) {
            selectedGeminiModel = "gemini-3.1-flash-lite-preview"
        }
        if !ProviderModels.gemini.contains(selectedGeminiPostProcessModel) {
            selectedGeminiPostProcessModel = "gemini-3.1-flash-lite-preview"
        }
        if preferredTranscriptionLanguages.isEmpty {
            preferredTranscriptionLanguages = [.zh, .en, .ja]
        }
        // 迁移而不是清零：原生版换了推理运行时，模型 id 表也跟着变了，
        // 直接回落默认会把用户选过的档位悄悄降级。
        selectedLocalModelId = LocalModels.migrate(id: selectedLocalModelId)
        processingMemoryContext = String(processingMemoryContext.prefix(8000))
        // 提示词会占解码上下文，词表必须有上限；顺带去空去重。
        var seenVocabulary = Set<String>()
        transcriptionVocabulary = transcriptionVocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenVocabulary.insert($0).inserted }
            .prefix(32)
            .map { String($0.prefix(40)) }
        // 空键会把整段文本炸成逐字插入；自反规则纯属浪费。
        transcriptionReplacements = transcriptionReplacements.filter {
            !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.key != $0.value
        }

        for preset in PostProcessingPreset.allCases {
            let d = PostProcessingPresetModelConfig.default(for: preset)
            var cfg = postProcessingPresetModels[preset.rawValue] ?? d
            if !ProviderModels.openAIPostProcess.contains(cfg.openaiModel) { cfg.openaiModel = d.openaiModel }
            if !ProviderModels.groqPostProcess.contains(cfg.groqModel) { cfg.groqModel = d.groqModel }
            if !ProviderModels.gemini.contains(cfg.geminiModel) { cfg.geminiModel = d.geminiModel }
            postProcessingPresetModels[preset.rawValue] = cfg
        }

        // 一个操作者驱动整条流水线：加工供应商跟随转写供应商。
        // local 是例外 —— 它没法加工，所以保留独立选择。
        switch transcriptionMode {
        case .openai: postProcessingProvider = .openai
        case .groq: postProcessingProvider = .groq
        case .gemini: postProcessingProvider = .gemini
        case .local: break
        }
    }

    /// 要不要带说话人标签：开关开着**且**走的是本地管线。
    ///
    /// 分离是独立能力（Pyannote CoreML），不绑死在某一个模型上；
    /// 云端路径出不了标签，所以要求 local。带标签的段会跳过 AI 加工。
    public var noteWantsSpeakerLabels: Bool {
        noteSpeakerDiarizationEnabled && transcriptionMode == .local
    }

    /// 这份配置真正会调用的云供应商 —— 只碰（也只向 Keychain 索要）在用的
    /// 那几个 key，而不是每个供应商都读一遍。
    public var activeCloudProviders: Set<CloudProvider> {
        var providers = Set<CloudProvider>()
        if let t = transcriptionMode.cloudProviderForSelfTest { providers.insert(t) }
        if postProcessingEnabled { providers.insert(postProcessingProvider) }
        return providers
    }
}
