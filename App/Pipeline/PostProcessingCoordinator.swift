import Foundation
import InkfallCore

/// 「转写完了 → 该输出什么文字」这一步的唯一入口。
///
/// 听写与落笔两条路共用它。分开写过一次，结果是降级提示、key 缺失的处理、
/// 日志格式三处各写一遍，然后慢慢长歪 —— 而这一层的每个分支都只在真机上
/// 才看得见，走歪了没人会发现。
@MainActor
final class PostProcessingCoordinator {

    struct Outcome {
        /// 最终要落进文档/笔记的文字。
        var text: String
        /// 实际走了哪条路（日志与自测用）。
        var route: String
        /// 要不要跟用户说一句。降级、没配 key、鉴权失败都算。
        var notice: String?
        /// 这条提示是「有问题」还是只是「顺带一提」。
        var isProblem = false
    }

    private let store: SettingsStore
    private let notes: NoteStore
    private let keys = APIKeyStore.shared

    /// 「没配 key」这句话一次运行只说一次。每说一句话就弹一次，比静默还烦人。
    private var missingKeyAnnounced: Set<String> = []

    init(store: SettingsStore, notes: NoteStore) {
        self.store = store
        self.notes = notes
    }

    /// 启动时预热这份配置真会用到的 key。绝不在「用户刚说完话」的路径上
    /// 现 fork 一个 `security`。
    func preloadKeys() {
        keys.preload(store.settings.activeCloudProviders)
    }

    /// 跑一次加工。**不加工**的分支也从这里走 —— 调用方不需要知道有几种情况。
    ///
    /// - `settings`: 听写传全局设置，落笔传 `noteEffective()`。
    /// - `onRemoteStart`: 真要发出去时才回调（刘海显示「加工中」）。
    /// - `onDelta`: 流式增量，目前只有 Claude Code 那条路会喂。
    func process(_ transcript: String,
                 settings: AppSettings,
                 durationMs: UInt64,
                 speakerLabeled: Bool,
                 onRemoteStart: ((PostProcessingPreset) -> Void)? = nil,
                 // `@MainActor @Sendable`：它要被交给后台的流式读取循环，
                 // 但回调本身必须跳回主 actor 才能碰界面。
                 onDelta: (@MainActor @Sendable (String) -> Void)? = nil) async -> Outcome {

        let decision = PostProcessingPolicy.decide(settings: settings, durationMs: durationMs,
                                                   transcript: transcript,
                                                   speakerLabeled: speakerLabeled)
        switch decision {
        case .raw(let reason):
            return Outcome(text: transcript, route: "raw(\(reason.rawValue))")

        case .local(let reason):
            return Outcome(text: BasicPolisher.polish(transcript),
                           route: "basic(\(reason.rawValue))")

        case .cloud(let preset, let provider, let model):
            guard let instructions = buildInstructions(preset: preset, settings: settings) else {
                return customPromptMissing(transcript)
            }
            guard let key = await keys.resolve(provider) else {
                return notConfigured(transcript, what: "\(provider.label) 的 API key",
                                     id: provider.rawValue)
            }
            onRemoteStart?(preset)
            return await send(.init(instructions: instructions,
                                    input: PostProcessingPrompt.userBody(transcript: transcript),
                                    route: .cloud(provider: provider, model: model, key: key)),
                              transcript: transcript,
                              label: "\(provider.label)/\(model)",
                              settings: settings, onDelta: onDelta)

        case .cli(let agent, let preset, let effort, let model):
            guard let instructions = buildInstructions(preset: preset, settings: settings) else {
                return customPromptMissing(transcript)
            }
            // 这条路**不要 key** —— 用的是那个工具自己的登录态。唯一的前提
            // 就是它装了。
            guard let executable = CLIAgentLocator.path(for: agent) else {
                return notConfigured(transcript,
                                     what: "\(agent.executable) 命令（先装 \(agent.label)）",
                                     id: "cli-\(agent.rawValue)")
            }
            onRemoteStart?(preset)
            return await send(.init(instructions: instructions,
                                    input: PostProcessingPrompt.userBody(transcript: transcript),
                                    route: .cli(agent: agent, effort: effort, model: model,
                                                executablePath: executable)),
                              transcript: transcript,
                              label: "\(agent.executable)/\(effort)"
                                   + (model.isEmpty ? "" : "/\(model)"),
                              settings: settings, onDelta: onDelta)
        }
    }

    // MARK: - 不走预设的那条通道

    /// 直接跑一段自定义的 instructions + input。
    ///
    /// 自动会议笔记（beta）用它 —— 那一路不是「把这段口述整理好」，而是
    /// 「把整场会维护成一份笔记」，既没有预设也不该在失败时回落成 basic 润色
    /// （对一份 diff 做规则润色毫无意义）。所以它绕开 `PostProcessingPolicy`，
    /// 只复用引擎/密钥的解析与日志。
    ///
    /// - Returns: 模型的原始输出；`nil` = 这一轮没跑通（调用方自己决定
    ///   重试还是丢弃，**绝不**在这里替它做主）。
    func transform(instructions: String, input: String, label: String) async -> String? {
        let settings = store.settings
        guard let route = await route(for: settings) else {
            Log.write("\(label): 没有可用的加工引擎")
            return nil
        }
        Log.write("\(label): 送出（\(input.count) 字）")
        let started = CFAbsoluteTimeGetCurrent()
        switch await PostProcessor.run(.init(instructions: instructions, input: input,
                                             route: route)) {
        case .success(let success):
            Log.write(String(format: "%@: %.2fs → %d 字%@", label, success.elapsed,
                             success.text.count,
                             success.costUSD.map { String(format: " $%.4f", $0) } ?? ""))
            return success.text
        case .failure(let failure):
            Log.write(String(format: "%@: 失败（%@）%@ 用时 %.2fs", label, "\(failure.kind)",
                             failure.message, CFAbsoluteTimeGetCurrent() - started))
            return nil
        }
    }

    /// 这份配置该往哪儿发。云端要 key，CLI 要那个命令装了。
    private func route(for settings: AppSettings) async -> PostProcessor.Route? {
        if let agent = settings.postProcessingEngine.cliAgent {
            guard let executable = CLIAgentLocator.path(for: agent) else { return nil }
            return .cli(agent: agent, effort: settings.cliAgentEffort,
                        model: settings.cliAgentModel, executablePath: executable)
        }
        let provider = settings.postProcessingProvider
        guard let key = await keys.resolve(provider) else { return nil }
        return .cloud(provider: provider,
                      model: settings.postProcessingModel(for: settings.postProcessingPreset),
                      key: key)
    }

    // MARK: - 发出去

    private func send(_ request: PostProcessor.Request,
                      transcript: String,
                      label: String,
                      settings: AppSettings,
                      onDelta: (@MainActor @Sendable (String) -> Void)?) async -> Outcome {
        Log.write("process: 送 \(label)（\(transcript.count) 字）")

        // 流式增量是在后台的读取循环里冒出来的，界面只能在主 actor 上碰。
        var sink: (@Sendable (String) -> Void)?
        if let onDelta {
            sink = { @Sendable (delta: String) in
                Task { @MainActor in onDelta(delta) }
            }
        }
        let result = await PostProcessor.run(request, onDelta: sink)

        switch result {
        case .success(let success):
            let cost = success.costUSD.map { String(format: " $%.4f", $0) } ?? ""
            Log.write(String(format: "process: %@ %.2fs → %d 字%@",
                             label, success.elapsed, success.text.count, cost))
            // 模型在中文里经常吐半角的 `,` `?`，而加工的卖点之一就是补标点。
            // 确定性替换，不写进提示词（提示词是 verbatim 区块）。
            return Outcome(text: CJKPunctuation.normalize(success.text), route: label)

        case .failure(let failure):
            Log.write("process: \(label) 失败（\(failure.kind)）\(failure.message)")
            // A15：只有网络中断和服务端故障才算「云端做不了这活儿」。
            // 鉴权/额度问题必须浮出来 —— 静默重试会掩盖用户必须处理的事。
            let eligible = FallbackPolicy.shouldFallbackPostProcessing(
                autoLocalFallbackEnabled: settings.autoLocalFallbackEnabled, kind: failure.kind)
            // ⚠️ 无论哪种失败，**文字都不能丢**（spec/05：非合并路径下加工失败
            // 回落到转写原文并保持 Done）。区别只在提示说什么。
            return Outcome(text: BasicPolisher.polish(transcript),
                           route: "basic(fallback)",
                           notice: eligible ? "加工没跑通，已用本地整理" : failure.message,
                           isProblem: !eligible)
        }
    }

    // MARK: - 提示词与失败

    private func buildInstructions(preset: PostProcessingPreset,
                                   settings: AppSettings) -> String? {
        try? PostProcessingPrompt.instructions(
            preset: preset,
            customPrompt: settings.customPostProcessingPrompt,
            memoryContext: settings.processingMemoryContext,
            recentContext: recentContext(settings))
    }

    /// 最近 6 条笔记的正文，给模型当术语/风格参考（spec/05 §6.7）。
    private func recentContext(_ settings: AppSettings) -> String {
        guard settings.recentContextEnabled else { return "" }
        return PostProcessingPrompt.recentContext(
            from: notes.notes.prefix(PostProcessingPrompt.recentEntryCount).map(\.displayText))
    }

    private func customPromptMissing(_ transcript: String) -> Outcome {
        Outcome(text: BasicPolisher.polish(transcript), route: "basic(no-prompt)",
                notice: "自定义 prompt 是空的", isProblem: true)
    }

    /// 没配 key / 没装那个命令：**静默降级到本地润色**，只在这次运行里提醒一次。
    /// 每一句话都弹一次「你没配 key」，比不提醒还让人想砸键盘。
    private func notConfigured(_ transcript: String, what: String, id: String) -> Outcome {
        let first = missingKeyAnnounced.insert(id).inserted
        Log.write("process: 缺少 \(what)，回落本地整理")
        return Outcome(text: BasicPolisher.polish(transcript),
                       route: "basic(no-key)",
                       notice: first ? "还没配\(what) · 先用本地整理" : nil)
    }
}
