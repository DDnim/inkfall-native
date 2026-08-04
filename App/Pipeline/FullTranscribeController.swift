import Foundation
import InkfallCore

/// 全篇转译：把一篇笔记留下的所有语音片段拼成一个 WAV，**跑一次**带说话人
/// 分离的转写，结果落成一条新笔记。
///
/// 为什么需要它（spec/01 §6.8）：**说话人标签只在一次推理内稳定**。落笔是
/// 边录边切的，每段各自跑一次分离，于是第 1 段的「说话人 1」和第 3 段的
/// 「说话人 1」很可能不是同一个人 —— 段越多，人物关系错得越离谱。整篇拼起来
/// 跑一次，聚类才是全篇范围的。
///
/// ⚠️ 结果**另存成新笔记**而不是覆盖原文：
/// - 原笔记里已经有每段的转写，追加等于把全文重复一遍
/// - 重跑出来的东西不一定更好（比如中途换了麦克风），原文必须留着
@MainActor
@Observable
final class FullTranscribeController {

    struct Job: Identifiable, Sendable {
        enum Status: String, Sendable {
            case running, done, failed
        }
        let id: UInt64
        let sourceNoteID: String
        let sourceTitle: String
        var status: Status = .running
        var error: String?
        var resultNoteID: String?
        let startedAtMs: UInt64
        /// 拼进去几段、跳过几段。跳过的那些是格式对不上或者文件坏了。
        var usedClips = 0
        var skippedClips = 0
    }

    enum Failure: LocalizedError {
        case needsLocalTranscription
        case needsDiarizationModel
        case noAudio
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .needsLocalTranscription:
                return "全篇转译要用本地模型（设置 → 模型来源选「本地」）"
            case .needsDiarizationModel:
                return "先下载说话人分离模型（设置 → 模型 → 区分人物）"
            case .noAudio:
                return "这篇笔记没有留下语音 —— 只有装了这个版本之后录的才有"
            case .alreadyRunning:
                return "这篇正在转译中"
            }
        }
    }

    private(set) var jobs: [Job] = []
    private var nextTaskID: UInt64 = 1

    private let store: SettingsStore
    private let notes: NoteStore
    private let transcriber: LocalTranscriber

    /// 完成/失败时说一句（刘海）。宿主注入 —— 这一层不该认识刘海。
    var onFinished: ((Job) -> Void)?

    init(store: SettingsStore, notes: NoteStore, transcriber: LocalTranscriber) {
        self.store = store
        self.notes = notes
        self.transcriber = transcriber
    }

    /// 这篇笔记现在能不能转译。界面拿它决定按钮灰不灰、以及灰的原因。
    func blocker(for noteID: String) -> Failure? {
        if jobs.contains(where: { $0.sourceNoteID == noteID && $0.status == .running }) {
            return .alreadyRunning
        }
        // 云端路径出不了说话人标签，所以这条要求和落笔的「区分人物」一致。
        guard store.settings.transcriptionMode == .local else { return .needsLocalTranscription }
        guard LocalTranscriber.isDiarizationDownloaded else { return .needsDiarizationModel }
        guard !clips(for: noteID).isEmpty else { return .noAudio }
        return nil
    }

    var isBusy: Bool { jobs.contains { $0.status == .running } }

    /// 起一次后台转译。整篇可能是几十分钟的音频，所以**不阻塞界面**，
    /// 完成后通知。
    @discardableResult
    func start(noteID: String) throws -> UInt64 {
        if let blocker = blocker(for: noteID) { throw blocker }

        let entry = notes.note(id: noteID)
        let urls = clips(for: noteID)
        let taskID = nextTaskID
        nextTaskID += 1
        jobs.insert(Job(id: taskID, sourceNoteID: noteID,
                          sourceTitle: entry?.title ?? "",
                          startedAtMs: HistoryEntry.nowMs()), at: 0)
        Log.write("full: 起任务 \(taskID) 笔记=\(noteID) 片段=\(urls.count)")

        let modelID = store.settings.selectedLocalModelId
        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let replacements = store.settings.transcriptionReplacements

        Task { [transcriber] in
            // 读盘 + 拼接在后台做：几十分钟的录音拼起来是几百 MB 的搬运。
            let concatenated = await Task.detached(priority: .utility) { () -> NoteAudio.Concatenated? in
                let clips = urls.compactMap { try? Data(contentsOf: $0) }
                return NoteAudio.concatenate(clips)
            }.value

            guard let concatenated else {
                await MainActor.run { self.fail(taskID, "音频读不出来或者格式对不上") }
                return
            }
            await MainActor.run {
                self.update(taskID) {
                    $0.usedClips = concatenated.usedClips
                    $0.skippedClips = concatenated.skippedClips
                }
                Log.write("full: 任务 \(taskID) 拼好 \(concatenated.usedClips) 段"
                    + "（跳过 \(concatenated.skippedClips)）"
                    + " \(concatenated.durationMs / 1000)s")
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("inkfall-full-\(taskID)-\(UUID().uuidString).wav")
            guard (try? concatenated.data.write(to: url)) != nil else {
                await MainActor.run { self.fail(taskID, "写不出临时文件") }
                return
            }
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                // ⚠️ `diarize: true` 是写死的 —— 全篇转译的全部意义就是重跑分离。
                // 落笔面板上那个「区分人物」开关在这里不参与决定。
                let result = try await transcriber.transcribe(.init(
                    wavURL: url, modelID: modelID, language: policy.requested(locked: nil),
                    replacements: replacements, diarize: true))
                await MainActor.run { self.succeed(taskID, result: result) }
            } catch {
                await MainActor.run {
                    self.fail(taskID, (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            }
        }
        return taskID
    }

    // MARK: - 落地

    private func succeed(_ taskID: UInt64, result: LocalTranscriber.Result) {
        guard let task = jobs.first(where: { $0.id == taskID }) else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fail(taskID, "转写结果是空的") }

        // ⚠️ 带说话人标签的文本**不过加工**：加工会把「说话人 1：」的排版
        // 改坏，而那正是这次重跑要的东西（A13 的同一条道理）。
        let entry = HistoryEntry(
            id: UUID().uuidString,
            createdAtMs: HistoryEntry.nowMs(),
            title: NoteAudio.resultTitle(from: task.sourceTitle),
            sourceText: text,
            finalText: text,
            transcriptionMode: store.settings.transcriptionMode,
            postProcessingEnabled: false)
        notes.upsert(entry)

        update(taskID) {
            $0.status = .done
            $0.resultNoteID = entry.id
        }
        Log.write("full: 任务 \(taskID) 完成 → 笔记 \(entry.id)"
            + "（\(text.count) 字，说话人 \(result.speakerCount.map(String.init) ?? "?")）")
        if let finished = jobs.first(where: { $0.id == taskID }) { onFinished?(finished) }
    }

    private func fail(_ taskID: UInt64, _ message: String) {
        update(taskID) {
            $0.status = .failed
            $0.error = message
        }
        Log.write("full: 任务 \(taskID) 失败 —— \(message)")
        if let finished = jobs.first(where: { $0.id == taskID }) { onFinished?(finished) }
    }

    private func update(_ taskID: UInt64, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == taskID }) else { return }
        change(&jobs[index])
    }

    private func clips(for noteID: String) -> [URL] {
        NoteAttachments.voiceClips(noteID: noteID,
                                   body: notes.note(id: noteID)?.displayText ?? "")
    }
}
