import Foundation
import InkfallCore

/// 「这段音频 → 文字」的唯一入口。听写、提问、落笔三条路共用它。
///
/// 按 `settings.transcriptionMode` 走五种模式之一：OpenAI / Groq / 落音云 /
/// Gemini 是云端（`CloudTranscriber`），local 是本机 WhisperKit（`LocalTranscriber`）。
/// 云端**不可达**（网络 / 5xx）时按 A15 降级到本地模型 —— 前提是用户没关掉
/// 自动降级、且选中的本地模型确实下载了。鉴权 / 配额 / 没配 key 这类问题
/// **不静默重试**：那是用户必须处理的事，静默的本地重试会把它藏起来。
///
/// 贾维斯的关键词扫描与全篇转译**不走这里**：前者是「一直听着、不留文字」，
/// 每一块都往云端送既花钱又违背它的隐私承诺；后者要说话人标签，云端出不了。
final class Transcriber: Sendable {

    struct Outcome: Sendable {
        var result: LocalTranscriber.Result
        /// 实际走了哪条路（日志与自测用）：`groq/whisper-large-v3-turbo`、
        /// `local/whisper-turbo`、`local(fallback)/whisper-turbo`。
        var route: String
        /// 要不要跟用户说一句。降级、没配 key 都算。
        var notice: String?
        /// 这条提示是「有问题」还是只是「顺带一提」。
        var isProblem = false
    }

    enum Failure: LocalizedError {
        case missingKey(CloudProvider)
        case proxyNotConfigured
        case cloud(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider): return "还没配 \(provider.label) 的 API key"
            case .proxyNotConfigured: return "落音云地址没配（设置 → 模型）"
            case .cloud(let message): return message
            }
        }
    }

    private let local: LocalTranscriber

    init(local: LocalTranscriber) {
        self.local = local
    }

    /// 刘海上「谁在转写」的名字：`Groq` / `落音云` / `Whisper Large v3 Turbo`。
    static func label(for settings: AppSettings) -> String {
        switch settings.transcriptionMode {
        case .local:
            let id = settings.selectedLocalModelId
            return LocalModels.definition(id: id)?.name ?? id
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .groqProxy: return "落音云"
        case .gemini: return "Gemini"
        }
    }

    /// 选中的本地模型下没下载 —— 这是降级能不能走的前提。
    static func localModelReady(_ settings: AppSettings) -> Bool {
        guard let model = LocalModels.definition(id: settings.selectedLocalModelId) else { return false }
        return LocalTranscriber.isDownloaded(model)
    }

    /// 转写一段。
    ///
    /// - Parameters:
    ///   - audio: 原始音频（云端要它的字节）。
    ///   - request: 本地路径的请求（调用方已经把 wav 落到临时文件、算好了语言与
    ///     分离开关）。云端路径复用它的 `language` 与 `replacements`。
    ///   - settings: 这一段生效的设置（听写传全局，落笔传 `noteEffective()`）。
    ///   - policy: 语言策略；Gemini 没有 language 参数，要把它写进提示词。
    func transcribe(audio: RecordedAudio,
                    local request: LocalTranscriber.Request,
                    settings: AppSettings,
                    policy: TranscriptionLanguagePolicy) async throws -> Outcome {
        let mode = settings.transcriptionMode
        guard mode != .local else {
            let result = try await local.transcribe(request)
            return Outcome(result: result, route: "local/\(request.modelID)")
        }

        // 云端那条路。先把路线凑齐 —— key / 地址缺失是配置问题，不是网络问题：
        // 本地模型在的话先顶上并提醒；不在的话只能报错。
        let route: TranscriptionAPI.Route
        do {
            route = try await resolveRoute(mode: mode, settings: settings)
        } catch {
            guard Self.localModelReady(settings) else { throw error }
            Log.write("transcribe: \(Self.short(error))，回落本地模型")
            let result = try await local.transcribe(request)
            return Outcome(result: result, route: "local(no-key)/\(request.modelID)",
                           notice: "\(Self.short(error)) · 先用本地模型")
        }

        let instruction = TranscriptionAPI.geminiLanguageInstruction(policy: policy,
                                                                     requested: request.language)
        let outcome = await CloudTranscriber.run(route: route, audio: audio,
                                                 language: request.language,
                                                 vocabulary: settings.transcriptionVocabulary,
                                                 languageInstruction: instruction)
        switch outcome {
        case .success(let success):
            // 云端 Whisper 在没有语音的音频上一样会吐字幕组片尾。
            guard !HallucinationFilter.isHallucination(success.text) else {
                throw LocalTranscriber.Failure.noSpeech(success.text)
            }
            let text = VocabularyCorrector(replacements: request.replacements).apply(success.text)
            // verbose_json 没给语言（gpt-4o-*-transcribe / Gemini）时，用请求的那个 ——
            // 固定模式下它就是答案，自动模式下它是 nil，投票会跳过。
            let result = LocalTranscriber.Result(text: text,
                                                 language: success.language ?? request.language,
                                                 elapsed: success.elapsed,
                                                 speakerCount: nil)
            return Outcome(result: result, route: "\(route.provider.rawValue)/\(route.model)")

        case .failure(let failure):
            let eligible = FallbackPolicy.shouldFallbackTranscription(
                autoLocalFallbackEnabled: settings.autoLocalFallbackEnabled,
                kind: failure.kind,
                localModelReady: Self.localModelReady(settings))
            guard eligible else {
                Log.write("transcribe: \(route.label) 失败（\(failure.kind)）\(failure.message)")
                throw Failure.cloud(failure.message)
            }
            Log.write("transcribe: \(route.label) 失败（\(failure.kind)）\(failure.message)，回落本地模型")
            let result = try await local.transcribe(request)
            return Outcome(result: result, route: "local(fallback)/\(request.modelID)",
                           notice: "\(route.label) 没连上，已用本地模型")
        }
    }

    /// 把设置翻成一条路线：模型白名单、key（环境变量 → 钥匙串）、落音云的地址与鉴权。
    private func resolveRoute(mode: TranscriptionMode,
                              settings: AppSettings) async throws -> TranscriptionAPI.Route {
        let model = TranscriptionAPI.model(for: mode, settings: settings)
        switch mode {
        case .openai:
            return .openai(model: model, key: try await key(.openai))
        case .groq:
            return .groq(model: model, key: try await key(.groq))
        case .gemini:
            return .gemini(model: model, key: try await key(.gemini))
        case .groqProxy:
            guard let url = TranscriptionAPI.proxyURL(settings: settings) else {
                throw Failure.proxyNotConfigured
            }
            let session = await APIKeyStore.shared.resolveSessionToken()
            let auth = TranscriptionAPI.CloudAuth.resolve(
                sessionToken: session,
                proxyToken: TranscriptionAPI.proxyToken(settings: settings))
            return .groqProxy(url: url, model: model, auth: auth)
        case .local:
            preconditionFailure("local 不走云端路线")
        }
    }

    private func key(_ provider: CloudProvider) async throws -> String {
        guard let key = await APIKeyStore.shared.resolve(provider) else {
            throw Failure.missingKey(provider)
        }
        return key
    }

    private static func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
