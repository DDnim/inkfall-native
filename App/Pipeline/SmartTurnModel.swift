import CoreML
import Foundation
import InkfallCore

/// 本机判「这句说完了没有」：Smart Turn v3.2 的 CoreML 版（Whisper-Tiny 编码器 + 小头，8M 参数，
/// 17 MB，BSD-2，pipecat 训练、aufklarer 转换）。一次约 3 ms，所以放在主线程上直接跑。
///
/// 权重不进包体（同本地 Whisper）：第一次用时从 Hugging Face 下到 Application Support，钉死 revision。
/// 没下好 / 载不进来的时候 `probability` 回 nil，调用方当作「说完了」照旧转写 —— 只是少了省额度那一步。
@MainActor
final class SmartTurnModel {

    static let shared = SmartTurnModel()

    private static let repo = "aufklarer/Smart-Turn-v3.2-CoreML"
    private static let revision = "75f069717f500947195fa1945c46ddb472559cff"
    private nonisolated static let files = ["analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"]
    nonisolated static let folder = LocalTranscriber.modelRoot
        .appendingPathComponent("smart-turn-v3.2/smart_turn.mlmodelc")

    private var model: MLModel?
    private var loading: Task<Void, Never>?
    private(set) var failure: String?

    var isReady: Bool { model != nil }

    /// 没下过就下，下好了就载入（首次按芯片编译约 0.7 秒）。边听边插话一开始就叫，可以重复叫。
    @discardableResult
    func prepare() -> Task<Void, Never> {
        if let loading { return loading }
        let task = Task { @MainActor in
            do {
                if !Self.isDownloaded { try await Self.download() }
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                model = try await MLModel.load(contentsOf: Self.folder, configuration: config)
                failure = nil
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.write("smart-turn: 载入失败 \(failure ?? "")")
                loading = nil
            }
        }
        loading = task
        return task
    }

    /// 说完了的概率（0…1）。`samples` 是 16 kHz 单声道、最新的在最后（`SmartTurn.window`）。
    func probability(_ samples: [Float]) -> Float? {
        guard let model, !samples.isEmpty,
              let input = try? MLMultiArray(shape: [1, NSNumber(value: SmartTurn.windowSamples)], dataType: .float32)
        else { return nil }
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: SmartTurn.windowSamples)
        let tail = samples.suffix(SmartTurn.windowSamples)
        let offset = SmartTurn.windowSamples - tail.count
        pointer.initialize(repeating: 0, count: offset)       // 不够 8 秒：前面补零
        _ = UnsafeMutableBufferPointer(start: pointer + offset, count: tail.count).initialize(from: tail)
        guard let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input])),
              let value = output.featureValue(for: "probability")?.multiArrayValue
        else { return nil }
        return value[0].floatValue
    }

    // MARK: - 权重

    nonisolated static var isDownloaded: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// 下到临时目录，齐了再挪过去 —— 下一半断了不留半个空壳。
    private static func download() async throws {
        let manager = FileManager.default
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent("smart_turn.mlmodelc.partial-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/smart_turn.mlmodelc/\(file)")!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
            }
            let target = staging.appendingPathComponent(file)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: temporary, to: target)
        }
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: folder)
        Log.write("smart-turn: 权重下好了 \(folder.path)")
    }
}
