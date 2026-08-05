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

    /// 阶段与合法转移都在 Core 的 `NotePhase` / `NoteSessionMachine` 里 ——
    /// 提上去是为了让「起录 → 暂停 → 继续 → 停止」这条多步路走得进单测
    /// （控制器本身要活的麦克风，测不了）。
    typealias Mode = NotePhase

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
    var isRecording: Bool { NoteSessionMachine.microphoneLive(mode) }
    var isPaused: Bool { mode == .paused }
    /// 会话开着（在录，或暂停着）。
    ///
    /// ⚠️ 「只读 / 不许换篇 / 正文由段落合成」这些判据要的都是**这个**，
    /// 不是 `isRecording`。暂停期间让用户去编辑 `draft` 会在继续录音的
    /// 那一刻被 `syncDraft()` 悄悄冲掉。
    var isLive: Bool { NoteSessionMachine.isLive(mode) }

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
    /// 加工与听写共用同一套决策与降级 —— 落笔只是把全局开关换成自己的
    /// （`noteEffective()`）。
    private let processing: PostProcessingCoordinator
    /// 自动会议笔记（beta）。**完全并行**的一路：同一批段落，一边照常落进
    /// 正文，一边在旁边维护一份会议笔记。它慢、会失败、是 beta ——
    /// 所以主链路任何一步都不等它。
    let meeting: MeetingNoteController

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

    /// 每次插入的结果。宿主用它统一「说一句 + 必要时引导授权」——
    /// 没有辅助功能授权时合成按键会被系统静默丢弃，落笔面板自己看不出区别，
    /// 只有宿主那一层能把用户引到系统设置去。
    var onPasteResult: ((PasteResult, String?) -> Void)?

    /// 贾维斯的扫描入口。**只喂 raw transcript**（spec/10 A13）：
    /// 加工会改写填充词和标点，能把关键词整个毁掉。
    ///
    /// 返回「这一段是不是一条指令」—— 命中的那一段照样落进正文（不能悄悄
    /// 扣下用户说过的话），但标成 `>> 原文` 并预标已粘贴：命令已经跑了，
    /// 没有东西可粘，所以它不该进「粘贴所有」，也不算未粘贴内容。
    var scanTranscript: ((String) -> Bool)?

    /// 加工那一步最近说的一句话（「会议纪要 加工中」「加工没跑通，已用本地整理」）。
    /// 面板与刘海读它，`nil` 表示没什么可说的。
    private(set) var processingNotice: String?

    /// 关键词扫描 armed。
    ///
    /// ⚠️ armed 时**无视**「自动断句」这个开关（spec/10 A14）：切段是关键词
    /// 可见的前提，段不闭合就永远扫不到命令 —— 而用户完全看不出「关掉自动断句」
    /// 和「贾维斯变聋了」之间有什么关系。
    var scanArmed = false


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
         store: SettingsStore, notes: NoteStore,
         processing: PostProcessingCoordinator,
         meeting: MeetingNoteController) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        self.notes = notes
        self.processing = processing
        self.meeting = meeting
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
        mode = NoteSessionMachine.next(mode, on: .start) ?? .recording
        lastTick = CFAbsoluteTimeGetCurrent()
        clock.start(at: lastTick)
        elapsedSeconds = 0
        startTicking()
        persist()
        prewarmModels()
        meeting.begin(sourceNoteID: noteID ?? "", title: title)
        Log.write("note: 会话开始 \(noteID ?? "?")")
        onRecordingChanged?(true)
        return true
    }

    /// 起录的同时就把模型拉起来，别等到第一段说完才开始加载。
    ///
    /// 冷加载要几秒（CoreML 按芯片编译 + 权重进内存），而落笔是长录 ——
    /// 用户在这几秒里根本不会停下来说话，这段时间是白送的。空闲 5 分钟的
    /// 自动卸载会把模型还回去，所以「刚才用过」不代表现在还在内存里。
    ///
    /// ⚠️ 权重没下过就**跳过**：`prewarm` 里那条路是 `download: true`，
    /// 起个录音就静默拉 1.5 GB 是不能接受的。
    private func prewarmModels() {
        let modelID = store.settings.selectedLocalModelId
        guard let model = LocalModels.definition(id: modelID),
              LocalTranscriber.isDownloaded(model) else { return }
        let wantsLabels = store.settings.noteWantsSpeakerLabels
        Task { [transcriber] in
            let started = CFAbsoluteTimeGetCurrent()
            await transcriber.prewarm(modelID: modelID)
            // 开着「区分人物」时分离也要预热 —— 它是第一段的另一段等待。
            if wantsLabels { await transcriber.prewarmDiarization() }
            // 打出耗时：这条日志是「预热到底省下了多少」的唯一凭据 ——
            // 模型已经在内存里时它接近 0，冷加载时是几秒。
            Log.write(String(format: "note: 预热 %@%@ 用时 %.2fs", modelID,
                             wantsLabels ? " + 分离" : "",
                             CFAbsoluteTimeGetCurrent() - started))
        }
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
        // 把攒着的最后一批交给会议笔记那一路。**不等它** —— 停止录音的
        // 那一刻界面就该回到编辑态，那一批在后台落地。
        meeting.finishSession()
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
        guard let paused = NoteSessionMachine.next(mode, on: .pause) else { return false }
        mode = paused
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
        guard let recording = NoteSessionMachine.next(mode, on: .resume) else { return false }
        mode = recording
        startTicking()
        // 暂停可能持续很久（去开个会），期间空闲卸载已经把模型还回系统了
        // —— 继续录音同样要先把它拉回来。
        prewarmModels()
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
        // A14：扫描 armed 时无视这个开关 —— 关掉它就等于把贾维斯变聋。
        guard store.settings.noteAutoSegment || scanArmed else {
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
        let createdAtMs = HistoryEntry.nowMs()
        segments.append(NoteSessionSegment(id: id, status: .processing,
                                           createdAtMs: createdAtMs))

        // 把这一段留在笔记目录里，「全篇转译」要靠它重跑（spec/01 §6.8）。
        // ⚠️ 存在**转写之前**：转写失败的段照样该留着音频，否则那句话就
        // 彻底没了，而全篇转译本来正是补救它的手段。
        if let noteID {
            if NoteAttachments.saveVoiceClip(audio.data, noteID: noteID, atMs: createdAtMs) == nil {
                Log.write("note: 段 \(id) 的音频没存下来（全篇转译会少这一段）")
            }
        }

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

        let durationMs = audio.durationMs
        // ⚠️ 这一段属于**哪一篇**笔记，必须在提交时就钉死。
        //
        // 转写是异步的，几秒后才回来 —— 那时用户完全可能已经停了这场、
        // 又点开了另一篇笔记。不钉死的话，迟到的段会落进「当前绑着的那篇」，
        // 把它的正文覆盖掉。2026-08-05 实测：一段 26 字的迟到转写把一份
        // 1661 字的会议笔记整个冲掉了。
        let ownerNoteID = noteID
        Task { [transcriber] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await transcriber.transcribe(request)
                await MainActor.run {
                    self.finish(id: id, seq: seq, result: result, policy: policy,
                                durationMs: durationMs, owner: ownerNoteID)
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.write("note: 段 \(id) 转写失败 —— \(reason)")
                await MainActor.run {
                    guard self.noteID == ownerNoteID else { return }
                    self.queue.skip(seq: seq)
                    self.markFailed(id, reason: reason)
                    self.drain()
                }
            }
        }
    }

    private func finish(id: UInt64, seq: UInt64,
                        result: LocalTranscriber.Result,
                        policy: TranscriptionLanguagePolicy,
                        durationMs: UInt64 = 0,
                        owner: String? = nil) {
        if languageLock.observe(TranscriptionLanguage.detected(result.language),
                                policy: policy) {
            Log.write("note: 会话语言锁定 \(languageLock.locked?.rawValue ?? "?") "
                + "（\(languageLock.votes.map(\.rawValue).joined(separator: "→"))）")
        }
        // A13：贾维斯先看一眼 **raw**，而且必须在加工之前 —— 加工会改写
        // 填充词和标点，能把关键词整个毁掉。扫描是 filter、笔记是 sink，
        // 两者正交：命中与否都不影响这一段会不会落进正文。
        let hit = scanArmed ? (scanTranscript?(result.text) ?? false) : false

        // 加工可能要一次往返，所以这一段先留在「转写中」，回来再入队。
        // ⚠️ 顺序仍然由 `queue` 保证：第 3 段先加工完也得等第 2 段。
        Task { [processing, store] in
            let outcome = await processing.process(
                result.text,
                // 落笔有独立的 AI 开关与预设，其余字段原样带过。
                settings: store.settings.noteEffective(),
                durationMs: durationMs,
                speakerLabeled: result.labeled,
                onRemoteStart: { [weak self] preset in
                    self?.markProcessing(id: id, note: "\(preset.label) 加工中")
                })
            self.complete(id: id, seq: seq, raw: result.text, text: outcome.text, hit: hit,
                          owner: owner)
            if let notice = outcome.notice {
                Log.write("note: 段 \(id) \(notice)")
                self.processingNotice = notice
            }
        }
    }

    /// 段落最终落地：写进队列，按序流进正文。
    private func complete(id: UInt64, seq: UInt64, raw: String, text: String, hit: Bool,
                          owner: String? = nil) {
        // 换篇了：这一段属于上一篇，**补写回那一篇**，绝不落进当前这篇。
        // 直接丢掉也不行 —— 用户说过的话不能凭空消失。
        if let owner, owner != noteID {
            appendToForeignNote(owner, text: text)
            queue.skip(seq: seq)
            return
        }
        var segment = segments.first { $0.id == id }
            ?? NoteSessionSegment(id: id, createdAtMs: HistoryEntry.nowMs())
        segment.rawText = raw
        segment.finalText = hit ? SessionMachine.noteBody(transcript: text, wasCommandHit: true)
                                : text
        // 命令已经执行了，没有东西可粘 —— 预标已粘贴，免得它挤进「粘贴所有」。
        segment.pasted = hit
        segment.status = .done
        queue.complete(seq: seq, item: segment)
        drain()
        // 并行的那一路：喂进去就返回，绝不让它拖住正文落地。
        meeting.ingest(segment.displayText)
    }

    /// 迟到的段落属于另一篇笔记：直接补到那一篇的末尾。
    ///
    /// 不走 `segments` / `queue` —— 那两个是**当前会话**的状态，往里塞
    /// 别人的段只会把顺序和正文一起搅乱。
    private func appendToForeignNote(_ id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var entry = notes.note(id: id) else { return }
        entry.sourceText = entry.sourceText.isEmpty ? trimmed
                                                    : entry.sourceText + "\n\n" + trimmed
        entry.finalText = entry.finalText.isEmpty ? trimmed
                                                  : entry.finalText + "\n\n" + trimmed
        notes.upsert(entry)
        Log.write("note: 迟到的一段补回笔记 \(id.prefix(8))（已换篇，不动当前这篇）")
    }

    /// 这一段正在被加工。面板上那个占位块换句话，用户才知道不是卡住了。
    private func markProcessing(id: UInt64, note: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].status = .processing
        processingNotice = note
    }

    /// 自测用：把一段**真实音频**喂进真实的提交路径。
    ///
    /// 走的是和麦克风完全同一个 `submit()` —— 存片段、转写、按序落正文、
    /// 落盘全都照跑，只有「麦克风采到这段声音」那一步是伪造的。
    ///
    /// 存在的理由：靠外放喂麦克风（`--note-test`）依赖扬声器音量、输出设备、
    /// 环境噪声，在没人值守的机器上根本不可靠 —— 而「音频有没有被留下来」
    /// 这件事必须能确定地验证，它是全篇转译的全部前提。
    func debugInjectAudio(_ data: Data, durationMs: UInt64) {
        submit(RecordedAudio(data: data, durationMs: durationMs))
    }

    /// 自测用：把一段**假装转写回来的文字**喂进真实的落地路径。
    ///
    /// 走的是和真转写完全同一个 `finish()` —— 扫描、标记指令、有序落正文、
    /// 落盘全都照跑，只有「声音变成文字」那一步是伪造的。
    /// （共跑那条链上唯一测不动的就是麦克风，其余每一环都在这里被真实驱动。）
    func debugInjectTranscript(_ text: String) {
        let seq = queue.enqueue()
        let id = nextSegmentID
        nextSegmentID += 1
        segments.append(NoteSessionSegment(id: id, status: .processing,
                                           createdAtMs: HistoryEntry.nowMs()))
        finish(id: id, seq: seq,
               result: LocalTranscriber.Result(text: text, language: "zh",
                                               elapsed: 0, speakerCount: nil),
               policy: TranscriptionLanguagePolicy(settings: store.settings))
    }

    private func markFailed(_ id: UInt64, reason: String? = nil) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].status = .failed
        segments[index].failureReason = reason
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
        // 落笔的插入是用户显式要的（双击 / 粘贴所有 / 落笔自动粘贴那个开关），
        // 所以不受听写的 `autoPasteEnabled` 总开关管；末尾补换行的偏好照用。
        let options = PasteOptions(autoPasteEnabled: true,
                                   appendNewline: store.settings.pasteAppendNewline)
        // ⚠️ 必须走这条**串行**队列，和自动粘贴共用。插入路径里全是
        // `Thread.sleep`，放主线程会冻住面板；而并发插入会把顺序搅乱。
        pasteQueue.async { [weak self] in
            let result = MacAutomation.insert(text, into: target, options: options)
            Log.write("note: \(reason) route=\(result.route?.rawValue ?? "无") "
                + "outcome=\(result.outcome.rawValue) "
                + "→ \(target?.appName ?? "剪贴板") \(text.count) 字")
            Task { @MainActor in
                // ⚠️ 只有真进了目标才标 `pasted`。只落到剪贴板也标上的话，
                // 用户再按一次「粘贴所有」就什么都不出来了。
                if result.landedInTarget { self?.markPasted(ids) }
                self?.onPasteResult?(result, target?.appName)
            }
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

    /// 当前这篇在**外部**被删掉了（集成 API 的 DELETE）。
    ///
    /// 必须解绑，否则面板会继续往一个幽灵条目上追加，而下一次防抖落盘
    /// 又把刚删掉的那篇整个复活。录音中的会话不解绑 —— 正在录的内容会无处可去，
    /// 那种情况下删除本身就该被拒绝。
    func detachDeletedNote() {
        guard !isLive else { return }
        persistTimer?.invalidate()
        persistTimer = nil
        noteID = nil
        title = ""
        draft = ""
        lastSyncedDraft = ""
        segments = []
        history.reset(to: "")
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
