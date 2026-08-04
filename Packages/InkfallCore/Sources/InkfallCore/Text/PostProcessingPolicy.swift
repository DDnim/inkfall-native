import Foundation

/// 这一段转写要不要送去加工、送去哪儿。
///
/// 抽成纯函数是因为它有六个分支、两条路径（听写与落笔）共用，而每一条分支
/// 都能在真机上表现成「AI 加工开着却什么都没发生」——那是没法靠肉眼排查的。
public enum PostProcessingPolicy {

    /// 短于这个时长不送云端（spec/01 常数表）。一句「好的」值不回一次往返。
    public static let minimumDurationMs: UInt64 = 3_000
    /// 少于这个字数不送云端。
    public static let minimumCharacters = 10

    public enum LocalReason: String, Sendable, Equatable {
        /// 预设本身就是本地的 basic。
        case presetBasic
        /// 录音太短。
        case tooShort
        /// 字太少。
        case tooFewCharacters
    }

    public enum RawReason: String, Sendable, Equatable {
        /// 用户把加工关了。
        case disabled
        /// 带说话人标签 —— 加工会把 `说话人 1：` 的排版改坏（spec/01 §356）。
        case speakerLabeled
        /// 转写是空的。
        case emptyTranscript
    }

    public enum Decision: Sendable, Equatable {
        /// 原样输出，不做任何加工。
        case raw(RawReason)
        /// 本地规则润色（`BasicPolisher`），不联网、不要 key。
        case local(LocalReason)
        /// 送云端 API。
        case cloud(preset: PostProcessingPreset, provider: CloudProvider, model: String)
        /// 交给本机的命令行助手（`claude -p` …）。
        case cli(agent: CLIAgentKind, preset: PostProcessingPreset,
                 effort: String, model: String)

        /// 这次要走网络/子进程（而不是本地几条正则）。刘海要不要显示
        /// 「加工中」看的是它。
        public var isRemote: Bool {
            switch self {
            case .cloud, .cli: return true
            case .raw, .local: return false
            }
        }

        public var preset: PostProcessingPreset? {
            switch self {
            case .cloud(let preset, _, _), .cli(_, let preset, _, _): return preset
            case .raw, .local: return nil
            }
        }
    }

    /// ⚠️ 与 Tauri 版有一处**刻意的差异**：那边「太短 / 字太少」直接返回 raw，
    /// 这边回落到本地 basic 润色。原生版的听写路径一直是无条件过一遍
    /// `BasicPolisher` 的，短句恰恰是最常见的一类；退回 raw 会让「打开加工」
    /// 反而比以前脏。basic 全本地、零成本，没有不做的理由。
    public static func decide(settings: AppSettings,
                              durationMs: UInt64,
                              transcript: String,
                              speakerLabeled: Bool) -> Decision {
        guard settings.postProcessingEnabled else { return .raw(.disabled) }
        guard !speakerLabeled else { return .raw(.speakerLabeled) }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .raw(.emptyTranscript)
        }

        let preset = settings.postProcessingPreset
        if preset.isLocal { return .local(.presetBasic) }
        if durationMs < minimumDurationMs { return .local(.tooShort) }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumCharacters {
            return .local(.tooFewCharacters)
        }

        guard let agent = settings.postProcessingEngine.cliAgent else {
            return .cloud(preset: preset,
                          provider: settings.postProcessingProvider,
                          model: settings.postProcessingModel(for: preset))
        }
        return .cli(agent: agent, preset: preset,
                    effort: settings.cliAgentEffort, model: settings.cliAgentModel)
    }
}

public extension AppSettings {

    /// 某个预设实际会用的模型。每个预设可以单独配一档（快档用小模型，
    /// 重活儿用大模型），没配过就回落到供应商的全局选择。
    func postProcessingModel(for preset: PostProcessingPreset) -> String {
        let config = postProcessingPresetModels[preset.rawValue]
        switch postProcessingProvider {
        case .openai: return config?.openaiModel ?? selectedOpenAiPostProcessModel
        case .groq: return config?.groqModel ?? selectedGroqPostProcessModel
        case .gemini: return config?.geminiModel ?? selectedGeminiPostProcessModel
        }
    }
}
