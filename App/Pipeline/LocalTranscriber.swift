import Foundation
import InkfallCore
import WhisperKit

/// 本地转写。CoreML 运行时随 App 编译进二进制，**用户不需要单独安装任何东西**
/// （spec/05 §3：Tauri 版要求自建 `~/.venvs/inkfall-mlx`，那是不可接受的门槛）。
///
/// 要下载的只有模型权重，落在 App 容器里 —— 不进包体，否则更新包会被拖垮。
actor LocalTranscriber {

    struct Result {
        let text: String
        /// Whisper 检测到的语言，用于会话内语言锁定。
        let language: String?
        let elapsed: TimeInterval
    }

    enum Failure: LocalizedError {
        case unknownModel(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "未知的本地模型：\(id)"
            case .empty: return "本地模型没有输出文字"
            }
        }
    }

    /// 已加载的实例按模型 id 缓存。加载一次要几秒（CoreML 要按芯片编译），
    /// 每次录音都重来会让本地路径完全没法用。
    private var loaded: [String: WhisperKit] = [:]

    /// 权重目录。放 Application Support 而不是 Caches —— 用户下过的 630 MB
    /// 不该被系统在磁盘吃紧时悄悄清掉。
    static let modelRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.inkfall.native/models")

    /// 这个模型的权重是否已经在本地。
    nonisolated static func isDownloaded(_ model: LocalModelDefinition) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: modelRoot.appendingPathComponent("models").path) else {
            return folderContains(model.variant, under: modelRoot)
        }
        return !entries.isEmpty && folderContains(model.variant, under: modelRoot)
    }

    /// WhisperKit 会在 downloadBase 下按 `models/<repo>/<variant>` 建目录，
    /// 具体层级随版本变过，所以直接递归找变体目录名。
    private nonisolated static func folderContains(_ variant: String, under root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let url as URL in walker where url.lastPathComponent == variant {
            // 只有目录名还不够 —— 下载中断会留下半个空壳。
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if files.contains(where: { $0.hasSuffix(".mlmodelc") }) { return true }
        }
        return false
    }

    // MARK: - 下载

    /// 下载权重。`progress` 在任意线程回调，0…1。
    static func download(_ model: LocalModelDefinition,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(
            at: modelRoot, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(
            variant: model.variant,
            downloadBase: modelRoot,
            from: model.repo,
            progressCallback: { progress($0.fractionCompleted) })
    }

    // MARK: - 转写

    /// - Parameter language: `nil` 走自动检测（结果会用于会话语言锁定）。
    func transcribe(wavURL: URL, modelID: String, language: String?) async throws -> Result {
        guard let model = LocalModels.definition(id: modelID) else {
            throw Failure.unknownModel(modelID)
        }
        let started = Date()
        let kit = try await instance(for: model)

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = language == nil
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        // 短句听写用不上词级时间戳，关掉省一轮解码。
        options.wordTimestamps = false

        let results = try await kit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return Result(text: text,
                      language: results.first?.language,
                      elapsed: Date().timeIntervalSince(started))
    }

    /// 预热：把模型先加载好，让第一次真实录音不必等几秒的 CoreML 编译。
    func prewarm(modelID: String) async {
        guard let model = LocalModels.definition(id: modelID) else { return }
        _ = try? await instance(for: model)
    }

    private func instance(for model: LocalModelDefinition) async throws -> WhisperKit {
        if let cached = loaded[model.id] { return cached }
        let config = WhisperKitConfig(
            model: model.variant,
            downloadBase: Self.modelRoot,
            modelRepo: model.repo,
            // 权重不在本地就顺手下 —— 用户点了录音才发现要先去别处下载最难受。
            download: true)
        let kit = try await WhisperKit(config)
        loaded[model.id] = kit
        return kit
    }
}
