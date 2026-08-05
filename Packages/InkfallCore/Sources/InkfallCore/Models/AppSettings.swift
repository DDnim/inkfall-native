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

    // 账号与云
    public var accountEmail = ""
    public var websiteAuthBaseUrl = ""
    public var accountWebsiteUrl = ""
    public var groqProxyUrl = ""
    public var groqProxyToken = ""

    // 转写
    public var transcriptionMode: TranscriptionMode = .groqProxy
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
    public var recentContextEnabled = true
    /// 谁来跑这次加工：云端 API，还是本机的命令行助手（`claude -p` …）。
    public var postProcessingEngine: PostProcessingEngine = .cloud
    /// CLI 助手的思考力度（`claude --effort`）。加工是低难度高频的活儿，
    /// 默认 `low` —— 让它「想一想」既慢又贵，而清理口语没什么可想的。
    public var cliAgentEffort = "low"
    /// 空 = 用那个工具自己的默认模型。
    public var cliAgentModel = ""

    // 落笔
    public var noteAutoSegment = true
    public var noteAutoPaste = false
    /// 落笔有**独立于全局听写**的 AI 开关与预设。
    public var noteProcessingEnabled = true
    public var noteProcessingPreset: PostProcessingPreset = .notes
    /// 自动会议笔记（**beta**）。与现有的转写/加工完全并行，另存一份笔记。
    /// 默认关：它慢、要联网、还会额外花钱，得由用户显式打开。
    public var meetingNotesEnabled = false
    public var noteRestoreOnLaunch = true
    public var noteSpeakerDiarizationEnabled = false

    // 语音命令与贾维斯
    /// ⚠️ 默认**关**：随口一句以关键词开头的听写就会启动终端，而命令是任意 shell。
    public var voiceCommandsEnabled = false
    public var voiceCommands: [VoiceCommand] = [.defaultClaude]
    /// ⌥, 的关键词待命扫描。与 `voiceCommandsEnabled` 是**两道**门 ——
    /// 前者管「命令能不能跑」，后者管「要不要一直听着」。
    public var jarvisModeEnabled = false
    public var selectionCommandModeEnabled = false
    public var askModeEnabled = true

    // 其他
    public var appLanguage: AppLanguage = .system
    /// 截图要 Screen Recording 这个很宽的权限，所以默认关，
    /// 关着时两个快捷键会**从监听器里摘掉**（按键原样透传给其他 App）。
    /// 截图功能总开关。关掉时 ⌥; / ⌥' 两个槽会被**置空**，原样透传给别的 App。
    public var screenshotFeatureEnabled = true
    /// 一次性迁移标记：原生版之前把这个功能默认关着，而设置页里从来没有
    /// 对应的开关 —— 盘上那个 `false` 是没人选过的默认值，不是用户的决定。
    /// 迁移只做一次；之后用户在设置页里关掉它就一直是关着的。
    public var screenshotDefaultMigrated = false
    public var screenshotQuoteMarkerEnabled = true
    public var micGainBoostEnabled = true
    public var micGainBoostTargetPercent: UInt8 = 80
    /// 本地集成 API：把笔记读写暴露给任何持 token 的本地进程，所以默认关。
    public var integrationApiEnabled = false
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
        case accountEmail, websiteAuthBaseUrl, accountWebsiteUrl, groqProxyUrl, groqProxyToken
        case transcriptionMode, openAiProviderEnabled, groqProviderEnabled, geminiProviderEnabled
        case selectedOpenAiModel, selectedGroqModel, selectedGeminiModel, selectedLocalModelId
        case transcriptionLanguageMode, fixedTranscriptionLanguage, preferredTranscriptionLanguages
        case autoLocalFallbackEnabled, transcriptionVocabulary
        case transcriptionReplacements
        case postProcessingEnabled, postProcessingProvider, postProcessingPreset
        case postProcessingPresetModels, selectedOpenAiPostProcessModel
        case selectedGroqPostProcessModel, selectedGeminiPostProcessModel
        case customPostProcessingPrompt, processingMemoryContext, recentContextEnabled
        case postProcessingEngine, cliAgentEffort, cliAgentModel
        case noteAutoSegment, noteAutoPaste, noteProcessingEnabled, noteProcessingPreset
        case noteRestoreOnLaunch, noteSpeakerDiarizationEnabled, meetingNotesEnabled
        case voiceCommandsEnabled, voiceCommands, jarvisModeEnabled
        case selectionCommandModeEnabled, askModeEnabled
        case appLanguage, screenshotFeatureEnabled, screenshotQuoteMarkerEnabled
        case screenshotDefaultMigrated
        case micGainBoostEnabled, micGainBoostTargetPercent, integrationApiEnabled
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

        accountEmail = f(.accountEmail, accountEmail)
        websiteAuthBaseUrl = f(.websiteAuthBaseUrl, websiteAuthBaseUrl)
        accountWebsiteUrl = f(.accountWebsiteUrl, accountWebsiteUrl)
        groqProxyUrl = f(.groqProxyUrl, groqProxyUrl)
        groqProxyToken = f(.groqProxyToken, groqProxyToken)

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
        recentContextEnabled = f(.recentContextEnabled, recentContextEnabled)
        postProcessingEngine = f(.postProcessingEngine, postProcessingEngine)
        cliAgentEffort = f(.cliAgentEffort, cliAgentEffort)
        cliAgentModel = f(.cliAgentModel, cliAgentModel)

        noteAutoSegment = f(.noteAutoSegment, noteAutoSegment)
        noteAutoPaste = f(.noteAutoPaste, noteAutoPaste)
        noteProcessingEnabled = f(.noteProcessingEnabled, noteProcessingEnabled)
        noteProcessingPreset = f(.noteProcessingPreset, noteProcessingPreset)
        noteRestoreOnLaunch = f(.noteRestoreOnLaunch, noteRestoreOnLaunch)
        meetingNotesEnabled = f(.meetingNotesEnabled, meetingNotesEnabled)
        noteSpeakerDiarizationEnabled = f(.noteSpeakerDiarizationEnabled,
                                          noteSpeakerDiarizationEnabled)

        voiceCommandsEnabled = f(.voiceCommandsEnabled, voiceCommandsEnabled)
        voiceCommands = f(.voiceCommands, voiceCommands)
        jarvisModeEnabled = f(.jarvisModeEnabled, jarvisModeEnabled)
        selectionCommandModeEnabled = f(.selectionCommandModeEnabled,
                                        selectionCommandModeEnabled)
        askModeEnabled = f(.askModeEnabled, askModeEnabled)

        appLanguage = f(.appLanguage, appLanguage)
        screenshotFeatureEnabled = f(.screenshotFeatureEnabled, screenshotFeatureEnabled)
        screenshotDefaultMigrated = f(.screenshotDefaultMigrated, screenshotDefaultMigrated)
        screenshotQuoteMarkerEnabled = f(.screenshotQuoteMarkerEnabled, screenshotQuoteMarkerEnabled)
        micGainBoostEnabled = f(.micGainBoostEnabled, micGainBoostEnabled)
        micGainBoostTargetPercent = f(.micGainBoostTargetPercent, micGainBoostTargetPercent)
        integrationApiEnabled = f(.integrationApiEnabled, integrationApiEnabled)

        // ⚠️ 与其他字段相反：**缺失时默认 true**。
        // 现有的 settings.json 没有这个 key 说明是老用户，不该再弹一次引导。
        hasCompletedOnboarding = f(.hasCompletedOnboarding, true)
    }

    // MARK: - Sanitize

    /// 把非法/过期的值收拾回合法状态。load 与 save 两侧都要跑。
    public mutating func sanitize() {
        // 截图默认值的一次性迁移。老配置里这个键是 `false`，但设置页里
        // 从来没有过对应的开关 —— 那不是用户关的，是个没人碰过的默认值，
        // 而它会把 ⌥; / ⌥' 两个槽置空，表现为「按了没反应」。
        if !screenshotDefaultMigrated {
            screenshotDefaultMigrated = true
            screenshotFeatureEnabled = true
        }
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
        // 不认识的力度会被 claude 直接拒（整轮加工失败），所以收回默认档。
        if let agent = postProcessingEngine.cliAgent,
           !agent.effortLevels.contains(cliAgentEffort) {
            cliAgentEffort = agent.effortLevels.first ?? "low"
        }
        if preferredTranscriptionLanguages.isEmpty {
            preferredTranscriptionLanguages = [.zh, .en, .ja]
        }
        // 迁移而不是清零：原生版换了推理运行时，模型 id 表也跟着变了，
        // 直接回落默认会把用户选过的档位悄悄降级。
        selectedLocalModelId = LocalModels.migrate(id: selectedLocalModelId)
        processingMemoryContext = String(processingMemoryContext.prefix(8000))
        // 「新标签页」必须激活终端才开得出来，所以它和「保持焦点」互斥；
        // Ghostty 没有脚本接口，对它这个开关只能是关的。
        for index in voiceCommands.indices {
            if !voiceCommands[index].terminal.supportsNewTab {
                voiceCommands[index].openInNewTab = false
            }
            if voiceCommands[index].openInNewTab {
                voiceCommands[index].keepFocus = false
            }
        }
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
        case .groq, .groqProxy: postProcessingProvider = .groq
        case .gemini: postProcessingProvider = .gemini
        case .local: break
        }
    }

    /// 落笔用的等效设置：把全局的加工开关/预设换成落笔自己的那一套，
    /// 其余字段原样带过。这样共享的转写路径在 sink 是笔记面板时应用落笔的加工。
    public func noteEffective() -> AppSettings {
        var derived = self
        derived.postProcessingEnabled = noteProcessingEnabled
        derived.postProcessingPreset = noteProcessingPreset
        return derived
    }

    /// 落笔的这一段要不要带说话人标签：开关开着**且**走的是本地管线。
    ///
    /// 原生版把分离拆成了独立能力（Pyannote CoreML），不再绑死在某一个模型上 ——
    /// Tauri 版必须选 MOSS 才有标签，那个模型只有 Python 实现，搬不过来。
    /// 云端路径仍然出不了标签，所以还是要求 local。
    /// 带标签的段会跳过 AI 加工，让标签原样活下来。
    public var noteWantsSpeakerLabels: Bool {
        noteSpeakerDiarizationEnabled && transcriptionMode == .local
    }

    /// 这份配置真正会调用的云供应商 —— 只碰（也只向 Keychain 索要）在用的
    /// 那几个 key，而不是每个供应商都读一遍。
    ///
    /// 走 Claude Code 那条路时加工不需要任何云供应商 key，所以不算进来。
    public var activeCloudProviders: Set<CloudProvider> {
        var providers = Set<CloudProvider>()
        if let t = transcriptionMode.cloudProviderForSelfTest { providers.insert(t) }
        if postProcessingEnabled, postProcessingEngine == .cloud {
            providers.insert(postProcessingProvider)
        }
        return providers
    }
}
