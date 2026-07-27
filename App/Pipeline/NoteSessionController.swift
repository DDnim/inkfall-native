import AppKit
import Foundation
import InkfallCore

/// 落笔会话：连续录音，说到停顿自动切一段，每段独立转写，按说话顺序落进笔记。
///
/// 与「按住说话」的关键差别是**边录边切**：一次 take 会产出很多段，而转写是
/// 并发的 —— 第 3 段可能先转完。所以落进正文的顺序由 `OrderedPasteQueue` 保证，
/// 而不是谁先回来谁先写。
@MainActor
@Observable
final class NoteSessionController {

    enum Mode: Equatable {
        /// 录音中，正文只读，走 markdown 预览。
        case recording
        /// 停下来了，正文可编辑，走 markdown 编辑器。
        case editing
    }

    private(set) var segments: [NoteSessionSegment] = []
    private(set) var mode: Mode = .editing
    private(set) var noteID: String?
    private(set) var title: String = ""
    /// 编辑模式下的正文。录音模式下由 `segments` 合成。
    var draft: String = ""

    var isRecording: Bool { mode == .recording }

    /// 正文：录音中由段落合成，停下来之后就是用户可编辑的草稿。
    var body: String { isRecording ? composed : draft }

    /// 已完成段落合成的正文。
    private var composed: String {
        segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 把段落合成的正文同步进草稿。
    ///
    /// ⚠️ 必须能在**停止之后**继续同步：停下来时还在飞的段照常转写回来
    /// （「绝不丢数据」那条），它们必须补进正文。只要用户还没动过草稿就覆盖。
    private func syncDraft() {
        guard draft == lastSyncedDraft else { return }
        draft = composed
        lastSyncedDraft = draft
    }

    private let recorder: AudioRecorder
    private let transcriber: LocalTranscriber
    private let store: SettingsStore
    private let notes: NoteStore

    private var segmenter = SilenceSegmenter()
    private var queue = OrderedPasteQueue<NoteSessionSegment>()
    private var lastTick: CFAbsoluteTime = 0
    private var tickTimer: Timer?
    /// 会话内语言锁定：第一段判出来什么，后面就跟着走。
    private var sessionLanguage: TranscriptionLanguage?
    private var nextSegmentID: UInt64 = 0
    private var startedAt: CFAbsoluteTime = 0
    /// 上一次由程序写进 `draft` 的内容。用户改过之后 `draft` 就不再等于它，
    /// 迟到的段落也就不会覆盖用户的编辑。比布尔标志可靠 —— SwiftUI 的
    /// onChange 分不清「程序赋值」和「用户敲键」。
    private var lastSyncedDraft = ""

    /// 起录那一刻的前台窗口，自动粘贴往这里落。
    /// **必须在起录时抓**：等段落转完再看前台是谁，用户多半已经切走了。
    /// 面板是非激活的 NSPanel，所以它自己永远不会变成目标。
    private var pasteTarget: PasteTarget?

    /// 自动粘贴的**串行**队列。插入路径里全是 `Thread.sleep`（等剪贴板、等激活），
    /// 放主线程会把面板冻住；而并发插入会把段落顺序搅乱 —— 顺序正是落笔的全部意义。
    private let pasteQueue = DispatchQueue(label: "app.inkfall.note-paste", qos: .userInitiated)


    /// 已录秒数。**只在整秒变化时才写** —— tick 是 30 Hz，每次都写会让整个
    /// 面板一秒重绘三十次。
    private(set) var elapsedSeconds: Int = 0

    /// 还在转写中的段数，面板用它显示「N 段转写中」。
    var inFlight: Int { segments.filter { $0.status == .processing }.count }

    // MARK: - 三个开关

    // 真值都住在 `AppSettings` 里，这里只是让面板能读能写同一份值 ——
    // 面板和设置页翻的是同一个开关，不是两份会漂移的副本。
    // （`SettingsStore` 现在是 @Observable，所以这些 computed 读出来会被
    // SwiftUI 的观察追踪到，翻完立刻重绘。）

    var autoSegment: Bool {
        get { store.settings.noteAutoSegment }
        set { store.settings.noteAutoSegment = newValue; store.save() }
    }

    var autoPaste: Bool {
        get { store.settings.noteAutoPaste }
        set { store.settings.noteAutoPaste = newValue; store.save() }
    }

    var diarize: Bool {
        get { store.settings.noteSpeakerDiarizationEnabled }
        set { store.settings.noteSpeakerDiarizationEnabled = newValue; store.save() }
    }

    /// 分离模型下载了没有。没下就只能把「区分人物」置灰 —— 让用户翻一个
    /// 翻了也不会生效的开关，比不给这个开关更糟。
    var diarizationReady: Bool { LocalTranscriber.isDiarizationDownloaded }

    /// 单段硬上限。说了三分钟没停顿的人是存在的，不切就会一直攒着，
    /// 转写延迟和失败代价都随时长线性上涨。
    private static let hardCutSeconds: Double = 180
    /// 切段时给下一段留的尾巴，免得把词头切秃。
    private static let retainTailMs: UInt64 = 300

    init(recorder: AudioRecorder, transcriber: LocalTranscriber,
         store: SettingsStore, notes: NoteStore) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        self.notes = notes
    }

    // MARK: - 起停

    /// - Returns: 起录是否成功。
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        guard recorder.microphoneAuthorized else { return false }
        if store.settings.micGainBoostEnabled {
            AudioDevices.boostInputVolume(targetPercent: store.settings.micGainBoostTargetPercent)
        }
        do {
            try recorder.start()
        } catch {
            Log.write("note: 起录失败 \(error)")
            return false
        }

        // 每次开始都是一篇新笔记 —— 本轮不做合并。
        segments = []
        draft = ""
        lastSyncedDraft = ""
        queue = OrderedPasteQueue<NoteSessionSegment>()
        segmenter.reset()
        sessionLanguage = nil
        nextSegmentID = 0
        pasteTarget = PasteTarget.current()
        noteID = UUID().uuidString.uppercased()
        title = HistoryEntry.defaultTitle(HistoryEntry.nowMs())
        mode = .recording
        lastTick = CFAbsoluteTimeGetCurrent()
        startedAt = lastTick
        elapsedSeconds = 0
        startTicking()
        persist()
        Log.write("note: 会话开始 \(noteID ?? "?")")
        return true
    }

    /// 停止。**在飞的段照常转写并落进笔记** —— 绝不因为用户按了停就丢数据。
    func stop() {
        guard isRecording else { return }
        stopTicking()
        // 最后一段：不留尾巴，全都要。
        if let audio = try? recorder.flushSegment(retainingTailMs: 0),
           RecordingSubmissionPolicy.default.verdict(for: audio) == .submit {
            submit(audio)
        }
        recorder.cancel()
        mode = .editing
        syncDraft()
        persist()
        Log.write("note: 会话停止，共 \(segments.count) 段")
    }

    func toggle() { isRecording ? stop() : (start() ? () : ()) }

    /// 手动切段（⌥.）。
    func flushNow() {
        guard isRecording else { return }
        cut()
    }

    /// 取消：丢掉还没转写的音频，但**已经转好的段照样留着**。
    func cancel() {
        guard isRecording else { return }
        stopTicking()
        recorder.cancel()
        mode = .editing
        syncDraft()
        persist()
    }

    func enterEditing() {
        if isRecording { stop() } else { mode = .editing }
    }

    // MARK: - 切段

    private func startTicking() {
        tickTimer?.invalidate()
        // 30 Hz。断句判据只需要电平 + 时间差，放主线程跑就够，
        // 不必去动音频渲染回调（那条路一慢就是丢采样）。
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isRecording else { return }
        // 录音器在会话之外被停掉了。面板绝不能继续显示「录音中」而实际
        // 一个采样都没在收 —— 那正是「录音状态锁不住、录完 0 段」的样子。
        // 早年这条 guard 是静默 `return`，于是计时器停在原地、界面继续骗人。
        guard recorder.isRecording else {
            Log.write("note: 录音器已被外部停止，会话自愈收尾")
            stop()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let delta = now - lastTick
        lastTick = now

        let whole = Int(now - startedAt)
        if whole != elapsedSeconds { elapsedSeconds = whole }

        if recorder.takeDurationSeconds >= Self.hardCutSeconds {
            Log.write("note: 到达 \(Int(Self.hardCutSeconds))s 硬上限，强制切段")
            cut()
            return
        }
        guard store.settings.noteAutoSegment else { return }
        if segmenter.feed(level: recorder.level, delta: delta) { cut() }
    }

    private func cut() {
        guard let audio = try? recorder.flushSegment(retainingTailMs: Self.retainTailMs) else {
            return
        }
        segmenter.resetSegment()
        guard RecordingSubmissionPolicy.default.verdict(for: audio) == .submit else {
            Log.write("note: 丢弃过短/静音的一段 \(audio.durationMs)ms")
            return
        }
        submit(audio)
    }

    // MARK: - 转写

    private func submit(_ audio: RecordedAudio) {
        let seq = queue.enqueue()
        let id = nextSegmentID
        nextSegmentID += 1

        // 先插一个占位段，用户立刻看到「转写中…」，而不是对着空白等。
        segments.append(NoteSessionSegment(id: id, status: .processing,
                                           createdAtMs: HistoryEntry.nowMs()))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-note-\(id)-\(UUID().uuidString).wav")
        guard (try? audio.data.write(to: url)) != nil else {
            queue.skip(seq: seq)
            markFailed(id)
            return
        }

        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let request = LocalTranscriber.Request(
            wavURL: url,
            modelID: store.settings.selectedLocalModelId,
            language: policy.requested(locked: sessionLanguage),
            replacements: store.settings.transcriptionReplacements,
            diarize: store.settings.noteWantsSpeakerLabels
                && LocalTranscriber.isDiarizationDownloaded)

        Task { [transcriber] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await transcriber.transcribe(request)
                await MainActor.run {
                    self.finish(id: id, seq: seq, result: result, policy: policy)
                }
            } catch {
                Log.write("note: 段 \(id) 转写失败 \(error)")
                await MainActor.run {
                    self.queue.skip(seq: seq)
                    self.markFailed(id)
                    self.drain()
                }
            }
        }
    }

    private func finish(id: UInt64, seq: UInt64,
                        result: LocalTranscriber.Result,
                        policy: TranscriptionLanguagePolicy) {
        if let detected = TranscriptionLanguage.detected(result.language),
           policy.shouldLock(detected: detected, locked: sessionLanguage) {
            sessionLanguage = detected
        }
        // 带说话人标签的结果原样放行：标签的排版是结构，不是待清理的噪声。
        let text = result.labeled ? result.text : BasicPolisher.polish(result.text)
        var segment = segments.first { $0.id == id }
            ?? NoteSessionSegment(id: id, createdAtMs: HistoryEntry.nowMs())
        segment.rawText = result.text
        segment.finalText = text
        segment.status = .done
        queue.complete(seq: seq, item: segment)
        drain()
    }

    private func markFailed(_ id: UInt64) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].status = .failed
        syncDraft()
        persist()
    }

    /// 队头完成才往正文里落 —— 第 3 段先转完也得等第 2 段。
    private func drain() {
        for ready in queue.takeReadyPrefix() {
            if let index = segments.firstIndex(where: { $0.id == ready.id }) {
                segments[index] = ready
            } else {
                segments.append(ready)
            }
            autoPasteIfNeeded(id: ready.id)
        }
        syncDraft()
        persist()
    }

    /// 自动粘贴：段落一落进正文就同时插进起录时的那个窗口。
    ///
    /// 在 `drain()` 里做而不是在 `finish()` 里，是为了白拿队列的顺序保证 ——
    /// 第 3 段先转完也不会先粘出去。`pasted` 标记防重复：`drain` 对同一个 id
    /// 只会走一次，但会话恢复之类的路径将来可能再喂一遍。
    private func autoPasteIfNeeded(id: UInt64) {
        guard autoPaste else { return }
        guard let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].status == .done, !segments[index].pasted else { return }
        let text = segments[index].displayText
        guard !text.isEmpty else { return }
        segments[index].pasted = true

        let target = pasteTarget
        pasteQueue.async {
            let route = MacAutomation.insert(text, into: target)
            Log.write("note: 自动粘贴 段\(id) route=\(route.rawValue) "
                + "→ \(target?.appName ?? "剪贴板") \(text.count) 字")
        }
    }

    // MARK: - 落盘

    private func persist() {
        guard let noteID else { return }
        let final = isRecording ? composed : draft
        var entry = notes.note(id: noteID)
            ?? HistoryEntry(id: noteID, createdAtMs: HistoryEntry.nowMs(),
                            title: title, sourceText: "", finalText: "",
                            transcriptionMode: store.settings.transcriptionMode,
                            postProcessingEnabled: store.settings.noteProcessingEnabled)
        entry.sourceText = segments.map(\.rawText).filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        entry.finalText = final
        // 空笔记不占位置 —— 误触一次 ⌥Space 不该在列表里留个空壳。
        // ⚠️ 判据要带上「还有段在飞」：停止那一刻正文常常还是空的，
        // 转写几秒后才回来，早删就把整篇笔记丢了。
        if isEmptyNote, !isRecording {
            notes.remove(id: noteID)
        } else {
            notes.upsert(entry)
        }
        notes.saveSession(isRecording
            ? NoteSession(segments: segments, sessionEntryId: noteID) : nil)
    }

    /// 编辑模式里改了正文，写回同一条笔记。
    func commitDraft() {
        guard !isRecording else { return }
        persist()
    }

    /// 空笔记不该占列表位置，但**只在真的什么都没录到时**才算空。
    private var isEmptyNote: Bool {
        composed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inFlight == 0
    }

    /// 打开一条已有笔记来编辑。
    func open(_ entry: HistoryEntry) {
        guard !isRecording else { return }
        noteID = entry.id
        title = entry.title
        draft = entry.finalText
        lastSyncedDraft = entry.finalText
        segments = []
        mode = .editing
    }
}
