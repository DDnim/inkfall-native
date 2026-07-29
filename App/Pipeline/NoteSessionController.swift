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
        /// 暂停：麦克风真的停了，但会话还开着 —— 同一篇笔记、同一个粘贴目标、
        /// 同一把语言锁，`resume()` 接着往下录。正文仍然只读。
        case paused
        /// 停下来了，正文可编辑，走 markdown 编辑器。
        case editing
    }

    private(set) var segments: [NoteSessionSegment] = []
    private(set) var mode: Mode = .editing
    private(set) var noteID: String?
    /// 可改。改完走防抖落盘，和正文同一条路。
    var title: String = "" {
        didSet { if title != oldValue { schedulePersist() } }
    }
    /// 编辑模式下的正文。录音模式下由 `segments` 合成。
    var draft: String = ""

    /// 麦克风真的在收音。
    var isRecording: Bool { mode == .recording }
    var isPaused: Bool { mode == .paused }
    /// 会话开着（在录，或暂停着）。
    ///
    /// ⚠️ 「只读 / 不许换篇 / 正文由段落合成」这些判据要的都是**这个**，
    /// 不是 `isRecording`。暂停期间让用户去编辑 `draft` 会在继续录音的
    /// 那一刻被 `syncDraft()` 悄悄冲掉。
    var isLive: Bool { mode != .editing }

    /// 正文：会话开着时由段落合成，停下来之后就是用户可编辑的草稿。
    var body: String { isLive ? composed : draft }

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
    /// 正文/标题落盘的防抖计时器。见 `commitDraft()`。
    private var persistTimer: Timer?
    /// 会话内语言锁定：**两段判出同一种语言才锁**（见 `SessionLanguageLock`）。
    /// 第一句往往又短又急，单靠它定生死会把整场押在最不可靠的一次判断上。
    private var languageLock = SessionLanguageLock()
    private var sessionLanguage: TranscriptionLanguage? { languageLock.locked }
    private var nextSegmentID: UInt64 = 0
    /// 已录时长的记账。**暂停期间冻住** —— 见 `SessionClock`。
    private var clock = SessionClock()
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

    /// **会话**起停的通知（不是录音起停）。宿主用它驱动刘海 —— 停止的入口
    /// 有好几个（快捷键、面板停止键、关面板、tick 自愈），在每个入口各写一遍
    /// 迟早会漏掉一个。这里是唯一的出口。
    ///
    /// ⚠️ 暂停**不**发这个通知：暂停时刘海要留在屏幕上显示「已暂停」，
    /// 发 false 会让宿主把刘海整个收走，用户就再也点不到「继续」了。
    var onRecordingChanged: ((Bool) -> Void)?


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
        guard !isLive else { return true }
        guard openMicrophone() else { return false }

        // 起新篇之前，上一篇可能还压着一次防抖没落盘。
        flushPersist()

        // 每次开始都是一篇新笔记 —— 本轮不做合并。
        segments = []
        draft = ""
        lastSyncedDraft = ""
        history.reset(to: "")
        queue = OrderedPasteQueue<NoteSessionSegment>()
        segmenter.reset()
        languageLock.reset()
        nextSegmentID = 0
        pasteTarget = PasteTarget.current()
        noteID = UUID().uuidString.uppercased()
        title = HistoryEntry.defaultTitle(HistoryEntry.nowMs())
        mode = .recording
        lastTick = CFAbsoluteTimeGetCurrent()
        clock.start(at: lastTick)
        elapsedSeconds = 0
        startTicking()
        persist()
        Log.write("note: 会话开始 \(noteID ?? "?")")
        onRecordingChanged?(true)
        return true
    }

    /// 起麦克风。起录与「继续」共用 —— 增益提升那一步两边都要，
    /// 少一边就会出现「暂停之后音量突然变小」。
    private func openMicrophone() -> Bool {
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
        return true
    }

    /// 收掉麦克风，并把在飞的那一段交出去。**不留尾巴，全都要** ——
    /// 留下的尾巴属于一个马上就要被 cancel 掉的录音器，等于扔掉。
    private func drainMicrophone() {
        if let audio = try? recorder.flushSegment(retainingTailMs: 0),
           RecordingSubmissionPolicy.default.verdict(for: audio) == .submit {
            submit(audio)
        }
        recorder.cancel()
    }

    /// 停止。**在飞的段照常转写并落进笔记** —— 绝不因为用户按了停就丢数据。
    func stop() {
        guard isLive else { return }
        stopTicking()
        // 暂停时麦克风已经收过了，这里再 flush 只会拿到空的（try? 吞掉）。
        if isRecording { drainMicrophone() }
        clock.pause(at: CFAbsoluteTimeGetCurrent())
        mode = .editing
        syncDraft()
        // 停下来这一刻必须真的落盘，不能压在防抖里。
        flushPersist()
        history.reset(to: draft)
        Log.write("note: 会话停止，共 \(segments.count) 段")
        onRecordingChanged?(false)
    }

    func toggle() { isLive ? stop() : (start() ? () : ()) }

    // MARK: - 暂停 / 继续

    /// 暂停。Core Audio 没有 pause，这是组合出来的（spec/01 §6.5）：
    /// 先把在飞的音频切出来（**不丢**），再收麦克风，会话本身留着。
    ///
    /// 留着的东西正是「继续」能接上的原因：同一个 `noteID`、同一份 `segments`、
    /// 同一个 `pasteTarget`、同一把 `languageLock`。
    @discardableResult
    func pause() -> Bool {
        guard isRecording else { return false }
        stopTicking()
        drainMicrophone()
        clock.pause(at: CFAbsoluteTimeGetCurrent())
        mode = .paused
        // 暂停可能持续很久（去开个会、接个电话），期间崩了不能丢。
        flushPersist()
        Log.write("note: 已暂停，共 \(segments.count) 段")
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }
        guard openMicrophone() else {
            Log.write("note: 继续失败 —— 麦克风起不来")
            return false
        }
        // 噪声底重新估。暂停期间环境很可能变了（换了房间、开了空调），
        // 拿旧的底继续判静音会一路误切或一路不切。
        segmenter.reset()
        let now = CFAbsoluteTimeGetCurrent()
        clock.resume(at: now)
        lastTick = now
        mode = .recording
        startTicking()
        Log.write("note: 继续录音 \(noteID ?? "?")")
        return true
    }

    /// 暂停 ↔ 继续。hover 条上是同一个按钮。
    @discardableResult
    func togglePause() -> Bool {
        isPaused ? resume() : pause()
    }

    /// 一次切段的结果。手动切段要给用户反馈 —— 切了个空段却毫无提示，
    /// 用户只会以为快捷键坏了。
    enum CutOutcome: Equatable {
        case submitted(ms: UInt64)
        /// 太短或全是静音，没有东西可转写。
        case discarded(ms: UInt64)
        case notRecording
    }

    /// 手动切段（⌥. 或右⌥ 单击）。
    @discardableResult
    func flushNow() -> CutOutcome {
        guard isRecording else { return .notRecording }
        return cut()
    }

    /// 取消：丢掉还没转写的音频，但**已经转好的段照样留着**。
    func cancel() {
        guard isLive else { return }
        stopTicking()
        recorder.cancel()
        clock.pause(at: CFAbsoluteTimeGetCurrent())
        mode = .editing
        syncDraft()
        flushPersist()
        history.reset(to: draft)
        onRecordingChanged?(false)
    }

    func enterEditing() {
        if isLive { stop() } else { mode = .editing }
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

        let whole = Int(clock.elapsed(at: now))
        if whole != elapsedSeconds { elapsedSeconds = whole }

        if recorder.takeDurationSeconds >= Self.hardCutSeconds {
            Log.write("note: 到达 \(Int(Self.hardCutSeconds))s 硬上限，强制切段")
            cut()
            return
        }
        guard store.settings.noteAutoSegment else {
            debugSampleLevel(now: now, level: recorder.level, autoOn: false, delta: delta)
            return
        }
        let level = recorder.level
        debugSampleLevel(now: now, level: level, autoOn: true, delta: delta)
        if segmenter.feed(level: level, delta: delta) {
            Log.write("note: 自动断句触发")
            cut()
        }
    }

    /// 断句诊断埋点：每秒打一行电平摘要。
    /// 「为什么不自动分段」只能靠看真实电平回答，看代码是看不出来的。
    @ObservationIgnored var debugSegmentTrace = false
    @ObservationIgnored private var debugLastSample: CFAbsoluteTime = 0
    @ObservationIgnored private var debugPeak: Float = 0
    @ObservationIgnored private var debugMin: Float = 1
    @ObservationIgnored private var debugFrames = 0
    @ObservationIgnored private var debugTotalDelta: Double = 0

    /// 原始电平序列的落盘路径。设计断句算法必须对着真实数据做，
    /// 不能对着每秒 min/peak 的摘要猜。
    @ObservationIgnored var debugLevelDumpPath: String?
    @ObservationIgnored private var debugDump: [String] = []

    func debugFlushLevelDump() {
        guard let path = debugLevelDumpPath, !debugDump.isEmpty else { return }
        try? ("delta,level\n" + debugDump.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        Log.write("trace: 电平序列已导出 \(debugDump.count) 帧 → \(path)")
    }

    private func debugSampleLevel(now: CFAbsoluteTime, level: Float,
                                  autoOn: Bool, delta: Double) {
        guard debugSegmentTrace else { return }
        if debugLevelDumpPath != nil {
            debugDump.append(String(format: "%.5f,%.6f", delta, level))
        }
        debugPeak = max(debugPeak, level)
        debugMin = min(debugMin, level)
        debugFrames += 1
        debugTotalDelta += delta
        guard now - debugLastSample >= 1.0 else { return }
        Log.write(String(format:
            "trace: 自动断句=%@ 帧=%d 平均间隔=%.1fms 电平 min=%.5f peak=%.5f",
            autoOn ? "开" : "关", debugFrames,
            debugTotalDelta / Double(max(debugFrames, 1)) * 1000,
            debugMin, debugPeak))
        debugLastSample = now
        debugPeak = 0
        debugMin = 1
        debugFrames = 0
        debugTotalDelta = 0
    }

    @discardableResult
    private func cut() -> CutOutcome {
        guard let audio = try? recorder.flushSegment(retainingTailMs: Self.retainTailMs) else {
            return .notRecording
        }
        segmenter.resetSegment()
        guard RecordingSubmissionPolicy.default.verdict(for: audio) == .submit else {
            Log.write("note: 丢弃过短/静音的一段 \(audio.durationMs)ms")
            return .discarded(ms: audio.durationMs)
        }
        submit(audio)
        return .submitted(ms: audio.durationMs)
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
        if languageLock.observe(TranscriptionLanguage.detected(result.language),
                                policy: policy) {
            Log.write("note: 会话语言锁定 \(languageLock.locked?.rawValue ?? "?") "
                + "（\(languageLock.votes.map(\.rawValue).joined(separator: "→"))）")
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
              !segments[index].pasted else { return }
        pasteSegment(id: id, reason: "自动")
    }

    /// 还有没有没粘出去的内容 —— 面板与刘海用它决定要不要提示。
    var hasUnpasted: Bool {
        segments.contains { $0.status == .done && !$0.pasted && !$0.displayText.isEmpty }
    }

    /// 把某一段插进起录时的那个窗口。双击段落走的就是这条。
    ///
    /// - Returns: 真的粘出去了没有。空段与转写中的段不粘。
    @discardableResult
    func pasteSegment(id: UInt64, reason: String = "双击") -> Bool {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].status == .done else { return false }
        let text = segments[index].displayText
        guard !text.isEmpty else { return false }
        insert(text, ids: [id], reason: "\(reason)粘贴 段\(id)")
        return true
    }

    /// 所有**未粘贴**的已完成段，按段序合成**一次**插入（对齐 Tauri 的
    /// `note_paste_all`）。右⌥ 单击走的就是这条。
    ///
    /// 一次插入而不是逐段插入：目标应用里得到的是一段连续的文字，
    /// 而不是 N 次光标跳动；而且中途切走窗口也不会只粘进去一半。
    ///
    /// - Returns: 这次会粘几段。没有待粘内容时返回 0 且**什么都不插**。
    @discardableResult
    func pasteAllUnpasted() -> Int {
        let pending = segments
            .filter { $0.status == .done && !$0.pasted && !$0.displayText.isEmpty }
            .sorted { $0.id < $1.id }
        guard !pending.isEmpty else { return 0 }
        // 单换行连接 —— 与说话人标签同一套排版约定：换行，不是分段。
        let text = pending.map(\.displayText).joined(separator: "\n")
        insert(text, ids: pending.map(\.id), reason: "粘贴所有 \(pending.count) 段")
        return pending.count
    }

    /// 真正的插入。**成功之后才标记 pasted** —— 只落到剪贴板（没有目标窗口）
    /// 不算已粘贴，否则用户再按一次就什么都不出来了。
    private func insert(_ text: String, ids: [UInt64], reason: String) {
        let target = pasteTarget
        // ⚠️ 必须走这条**串行**队列，和自动粘贴共用。插入路径里全是
        // `Thread.sleep`，放主线程会冻住面板；而并发插入会把顺序搅乱。
        pasteQueue.async { [weak self] in
            let route = MacAutomation.insert(text, into: target)
            Log.write("note: \(reason) route=\(route.rawValue) "
                + "→ \(target?.appName ?? "剪贴板") \(text.count) 字")
            guard route != .clipboardOnly else { return }
            Task { @MainActor in self?.markPasted(ids) }
        }
    }

    private func markPasted(_ ids: [UInt64]) {
        for index in segments.indices where ids.contains(segments[index].id) {
            segments[index].pasted = true
        }
        flushPersist()
    }

    // MARK: - 落盘

    private func persist() {
        guard let noteID else { return }
        let final = isLive ? composed : draft
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
        if isEmptyNote, !isLive {
            notes.remove(id: noteID)
        } else {
            notes.upsert(entry)
        }
        // 暂停也要把会话镜像写出去 —— 那正是「继续」重绑得上的依据，
        // 也是暂停中途崩掉之后还能捡回来的唯一线索。
        notes.saveSession(isLive
            ? NoteSession(segments: segments, sessionEntryId: noteID) : nil)
    }

    /// 编辑模式里改了正文。
    ///
    /// ⚠️ 这里**必须防抖**。`persist()` 会把全部 100 条笔记编码成 JSON
    /// 再原子替换整个 `history.json`，而编辑器的绑定是逐字符回调的 ——
    /// 不防抖就等于「每敲一个字重写一次整库」。
    func commitDraft() {
        guard !isLive else { return }
        history.record(draft, at: CFAbsoluteTimeGetCurrent())
        schedulePersist()
    }

    private static let persistDebounceSeconds: TimeInterval = 0.6

    private func schedulePersist() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(
            withTimeInterval: Self.persistDebounceSeconds, repeats: false) { _ in
            Task { @MainActor in self.flushPersist() }
        }
    }

    /// 立刻落盘。停止录音、关面板、换笔记、退出 App 之前都必须调 ——
    /// 防抖的代价就是「有一小段时间盘上是旧的」，这些时刻不能带着旧数据走。
    func flushPersist() {
        persistTimer?.invalidate()
        persistTimer = nil
        persist()
    }

    // MARK: - 撤销

    /// 见 `DraftHistory`：编辑器自带的撤销栈被库的整体替换打散了，
    /// 撤销只能放在文档层。
    private var history = DraftHistory()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        guard !isLive, let text = history.undo() else { return }
        draft = text
        lastSyncedDraft = text
        schedulePersist()
    }

    func redo() {
        guard !isLive, let text = history.redo() else { return }
        draft = text
        lastSyncedDraft = text
        schedulePersist()
    }

    // MARK: - 字数

    /// 中日韩逐字数，拉丁按词数 —— 对一份中英混排的笔记，
    /// 只数字符或只数词都给不出有意义的数字。
    var wordCount: Int {
        var cjk = 0
        var latinRuns = 0
        var inLatinRun = false
        for scalar in body.unicodeScalars {
            let character = Character(scalar)
            guard character.isLetter || character.isNumber else {
                inLatinRun = false
                continue
            }
            let isCJK = (0x3040...0x30FF).contains(scalar.value)   // 假名
                || (0x4E00...0x9FFF).contains(scalar.value)        // 统一表意
                || (0x3400...0x4DBF).contains(scalar.value)        // 扩展 A
            if isCJK {
                cjk += 1
                inLatinRun = false
            } else if !inLatinRun {
                latinRuns += 1
                inLatinRun = true
            }
        }
        return cjk + latinRuns
    }

    // MARK: - 截图

    /// 截一张图并插进正文。
    ///
    /// 录音中也能截 —— 开会边听边截是最常见的用法。录音中正文是段落合成的
    /// 只读预览，所以图片作为一个**已完成的段**插进去，这样它会落在当前进度
    /// 的位置上，而不是被下一次合成冲掉。
    func insertScreenshot(_ mode: ScreenCapture.Mode,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard let noteID else {
            completion(.failure(ScreenCapture.Failure.cancelled))
            return
        }
        let url: URL
        do {
            url = try NoteAttachments.newImageURL(noteID: noteID)
        } catch {
            completion(.failure(error))
            return
        }

        // 框选是同步交互，会一直阻塞到用户拖完 —— 绝不能放主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ScreenCapture.capture(mode, to: url)
                Task { @MainActor in
                    self.appendImage(url)
                    completion(.success(()))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    private func appendImage(_ url: URL) {
        let markdown = NoteAttachments.markdown(for: url)
        if isLive {
            // 占位段直接标 done —— 它没有转写过程。
            let id = nextSegmentID
            nextSegmentID += 1
            segments.append(NoteSessionSegment(id: id, rawText: markdown,
                                               finalText: markdown, status: .done,
                                               createdAtMs: HistoryEntry.nowMs()))
            syncDraft()
        } else {
            let separator = draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n\n"
            draft += separator + markdown + "\n"
            lastSyncedDraft = draft
            history.record(draft, at: CFAbsoluteTimeGetCurrent())
        }
        flushPersist()
        Log.write("note: 插入截图 \(url.lastPathComponent)")
    }

    // MARK: - 删除

    /// 删掉当前这篇，连同它的图片附件。
    func deleteCurrent() {
        guard let id = noteID else { return }
        if isLive { cancel() }
        persistTimer?.invalidate()
        persistTimer = nil
        notes.remove(id: id)
        NoteAttachments.removeAll(noteID: id)
        notes.saveSession(nil)
        noteID = nil
        segments = []
        draft = ""
        lastSyncedDraft = ""
        title = ""
        history.reset(to: "")
        Log.write("note: 已删除 \(id)")
    }

    /// 空笔记不该占列表位置，但**只在真的什么都没录到时**才算空。
    private var isEmptyNote: Bool {
        composed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inFlight == 0
    }

    /// 开一篇空白笔记来编辑（不录音）。
    /// 截图这类「先有内容再有笔记」的动作需要它 —— 让截图因为
    /// 「你还没开笔记」而失败是没道理的。
    func openBlank() {
        guard !isLive else { return }
        flushPersist()
        noteID = UUID().uuidString.uppercased()
        title = HistoryEntry.defaultTitle(HistoryEntry.nowMs())
        draft = ""
        lastSyncedDraft = ""
        history.reset(to: "")
        segments = []
        mode = .editing
    }

    /// 打开一条已有笔记来编辑。
    ///
    /// - Returns: 打开成功与否。录音中拒绝换篇 —— 正在录的内容会无处可去。
    @discardableResult
    func open(_ entry: HistoryEntry) -> Bool {
        guard !isLive else { return false }
        // 上一篇可能还压着一次防抖没落盘，换篇之前必须先写出去。
        flushPersist()
        noteID = entry.id
        title = entry.title
        draft = entry.finalText
        lastSyncedDraft = entry.finalText
        // 换篇必须清撤销栈，否则 ⌘Z 会把上一篇的正文倒进这一篇。
        history.reset(to: entry.finalText)
        segments = []
        mode = .editing
        Log.write("note: 打开 \(entry.id)")
        return true
    }
}
