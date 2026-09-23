import Foundation
import InkfallCore
import WhisperKit

/// 本地转写。CoreML 运行时随 App 编译进二进制，**用户不需要单独安装任何东西**
/// （spec/05 §3：Tauri 版要求自建 `~/.venvs/inkfall-mlx`，那是不可接受的门槛）。
///
/// 要下载的只有模型权重，落在 App 容器里 —— 不进包体，否则更新包会被拖垮。
actor LocalTranscriber {

    struct Request: Sendable {
        var wavURL: URL
        var modelID: String
        /// `nil` = 让模型自己检测（第一段），之后跟着会话锁走。
        var language: String?
        /// 专有名词纠错：听错的形态 → 正确写法。解码之后做，不碰提示词。
        var replacements: [String: String] = [:]
    }

    struct Result: Sendable {
        let text: String
        /// Whisper 检测到的语言，用于会话内语言锁定。
        let language: String?
        let elapsed: TimeInterval
    }

    enum Failure: LocalizedError {
        case unknownModel(String)
        case unreadableAudio
        /// 模型有输出，但整段是幻觉或空白 —— 不是错误，是「没听到话」。
        /// 带上被丢弃的原文，否则误杀了根本查不出来。
        case noSpeech(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "未知的本地模型：\(id)"
            case .unreadableAudio: return "音频读不出来"
            case .noSpeech(let raw):
                return raw.isEmpty ? "模型没输出文字（这段可能真的没有人说话）"
                                   : "整段被判为幻觉：\(raw.prefix(40))"
            }
        }
    }

    /// 已加载的实例按模型 id 缓存。加载一次要几秒（CoreML 要按芯片编译），
    /// 每次录音都重来会让本地路径完全没法用。
    private var loaded: [String: WhisperKit] = [:]

    /// 权重目录。放 Application Support 而不是 Caches —— 用户下过的 1.5 GB
    /// 不该被系统在磁盘吃紧时悄悄清掉。
    static let modelRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.inkfall.native/models")

    /// 送进模型前先把长停顿压掉。
    ///
    /// 一举两得：解码窗口变少 → 更快；模型看不到大段静音 → **少一个幻觉来源**
    /// （它在静音上最爱吐字幕组片尾）。首尾各留 300 ms，免得把词头词尾切秃。
    private static let trimmer = SilenceTrimmer.default

    // MARK: - 权重

    /// 这个模型的权重是否已经在本地。
    nonisolated static func isDownloaded(_ model: LocalModelDefinition) -> Bool {
        folderContains(model.variant, under: modelRoot)
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

    /// 磁盘占用，给模型管理界面用。
    nonisolated static func diskBytes(_ model: LocalModelDefinition) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: modelRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        for case let url as URL in walker where url.lastPathComponent == model.variant {
            return directorySize(url)
        }
        return 0
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

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

    /// 删除权重并卸掉内存里的实例。
    func delete(_ model: LocalModelDefinition) throws {
        loaded.removeValue(forKey: model.id)
        guard let walker = FileManager.default.enumerator(
            at: Self.modelRoot, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent == model.variant {
            try FileManager.default.removeItem(at: url)
            return
        }
    }

    /// 释放内存里的模型。turbo 常驻 1.5 GB，用户长时间不说话就该还回去。
    func unload() {
        loaded.removeAll()
    }

    var isLoaded: Bool { !loaded.isEmpty }

    // MARK: - 转写

    func transcribe(_ request: Request) async throws -> Result {
        guard let model = LocalModels.definition(id: request.modelID) else {
            throw Failure.unknownModel(request.modelID)
        }
        let started = Date()
        let kit = try await instance(for: model)

        // 自己解码成 float 数组：裁剪静音与量能量都要拿到采样。
        guard var samples = try? AudioProcessor.loadAudioAsFloatArray(
            fromPath: request.wavURL.path) else {
            throw Failure.unreadableAudio
        }
        // 裁剪**之前**量一次能量：短套话（「Thank you.」）只有在音频本身
        // 很安静时才是幻觉，而裁剪会把安静的部分压掉、把峰值抬上去。
        let peak = AudioLevel.windowedPeak(samples: samples, sampleRate: 16_000)
        samples = Self.trimSilence(samples)

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = request.language
        options.detectLanguage = request.language == nil
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.wordTimestamps = false
        // 超过一个 30 秒窗口就按语音活动切块并发解码 —— 长录的延迟差一个量级。
        options.chunkingStrategy = samples.count > 16_000 * 30 ? .vad : ChunkingStrategy.none
        // ⚠️ **绝不设 `promptTokens`。** 用它做专有名词提示是很自然的想法，
        // 但 WhisperKit + CoreML 上实测：带 prompt 时第一次转写正常，
        // **第二次开始一律返回空**。对常驻听写工具等于用一次就废。
        // 专有名词改在解码之后用 `VocabularyCorrector` 确定性替换。

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)

        let raw = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper 在没有语音的音频上会自信地吐字幕组片尾。整段是套话就丢掉。
        guard !HallucinationFilter.isHallucination(raw, peakLevel: peak) else {
            throw Failure.noSpeech(raw)
        }
        let text = VocabularyCorrector(replacements: request.replacements).apply(raw)
        return Result(text: text, language: results.first?.language,
                      elapsed: Date().timeIntervalSince(started))
    }

    /// 预热：把模型先加载好，让第一次真实录音不必等几秒的 CoreML 编译。
    func prewarm(modelID: String) async {
        guard let model = LocalModels.definition(id: modelID) else { return }
        _ = try? await instance(for: model)
    }

    // MARK: - 内部

    private func instance(for model: LocalModelDefinition) async throws -> WhisperKit {
        if let cached = loaded[model.id] { return cached }
        let config = WhisperKitConfig(
            model: model.variant,
            downloadBase: Self.modelRoot,
            modelRepo: model.repo,
            verbose: false,
            logLevel: .none,
            // 权重不在本地就顺手下 —— 用户点了录音才发现要先去别处下载最难受。
            download: true)
        let kit = try await WhisperKit(config)
        loaded[model.id] = kit
        return kit
    }

    /// 16 kHz 单声道 float → 压掉长停顿。
    ///
    /// `SilenceTrimmer` 吃的是 Int16 PCM（与录音管线同源），这里桥一下，
    /// 免得为同一套阈值维护两份实现。
    private nonisolated static func trimSilence(_ samples: [Float]) -> [Float] {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let result = trimmer.trim(pcm: pcm, sampleRate: 16_000, channelCount: 1)
        guard result.removedMs > 0 else { return samples }

        var out = [Float]()
        out.reserveCapacity(result.pcm.count / 2)
        result.pcm.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                out.append(Float(Int16(littleEndian: value)) / 32767)
            }
        }
        return out
    }
}
