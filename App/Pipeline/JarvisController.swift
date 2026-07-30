import AppKit
import Foundation
import InkfallCore

/// 贾维斯 · 关键词待命（⌥,）。
///
/// **它是一个 filter，不是一个 sink**（spec/01 §1）。所以有两种跑法：
///
/// - **纯待命**：自己占着录音器，每段转写完只用来扫关键词，文本一个字都不留。
/// - **共跑**：落笔会话占着录音器，这里只在每段转写回来时**顺带扫一遍**。
///   命中的那一段照样落进笔记（标成 `>> 原文` 并预标已粘贴）。
///
/// 历史坑：贾维斯以前是一个 sink，于是它和落笔永远不能同时开。重写必须保持
/// 正交性 —— 这个类因此**不碰**笔记会话的任何状态，只提供一个扫描入口。
@MainActor
@Observable
final class JarvisController {

    /// 一条等着执行的命令。
    ///
    /// `payload` 按 runner 变义：终端命令是一行 shell，Claude Code 是一段提示词。
    /// 两者共用同一个倒计时 —— 决策点都在**执行之前**。
    struct Pending: Equatable {
        var id: UInt64
        var command: VoiceCommand
        var payload: String

        var keyword: String { command.keyword }
    }

    private let recorder: AudioRecorder
    private let transcriber: LocalTranscriber
    private let store: SettingsStore
    private let notch: NotchOverlayController
    /// 后台的 Claude Code 助手（tmux + `claude -p`，同一个关键词持续对话）。
    let claude = ClaudeCodeAgent()

    private var runtime = JarvisRuntime()
    private(set) var pending: Pending?
    /// 连续对话的活会话：关键词 → 那条命令开出来的窗口。
    private var conversation: (keyword: String, target: PasteTarget)?

    /// 纯待命时由这里占着录音器；共跑时是 false（录音器是落笔会话的）。
    private(set) var owningRecorder = false
    var scanning: Bool { runtime.scanning }
    var discarded: Int { runtime.discarded }
    private(set) var startedAtMs: UInt64 = 0

    // MARK: - 与宿主的接线（刻意用闭包：这个类不认识 AppDelegate）

    /// 落笔会话是不是开着 —— 决定 ⌥, 走「叠加」还是「新起待命」。
    var noteSessionLive: () -> Bool = { false }
    /// 「按住说话」是不是正占着录音器。⌥, 必然先按下 ⌥，所以总要问一句。
    var holdActive: () -> Bool = { false }
    /// 丢掉那截 hold 录音（组合键的副产物，不是说话内容）。
    var abortHold: () -> Void = {}
    /// 扫描起停：宿主拿它同步落笔会话的 `scanArmed`（A14）与面板上的指示。
    var onScanningChanged: ((Bool) -> Void)?
    /// 倒计时起停：宿主拿它开关热键监听器对 esc / ↩ 的抢占（A12）。
    var onCountdownChanged: ((Bool) -> Void)?
    /// 请宿主在这段时间内别用别的东西覆盖刘海（落笔的 30 Hz tick 会抢）。
    var onHoldNotch: ((Double) -> Void)?

    private var tickTimer: Timer?
    private var countdownTimer: Timer?
    private var restoreTimer: Timer?
    private var segmenter = SilenceSegmenter()
    private var lastTick: CFAbsoluteTime = 0
    /// 最后一次听到「有人在说话」的时刻。带的高度靠它 + 1200ms 迟滞，
    /// 否则每个音节间隙都会闪一下。
    private var lastVoiceAt: CFAbsoluteTime = 0
    /// 正在转写的段数。>0 时刘海借录音 pill 的高度 —— 不然整个往返都像没听见。
    private var inFlight = 0
    /// 卡片占着刘海：待命带的 tick 这段时间不许重绘。
    private var cardOpen = false

    /// 单段硬上限，与落笔同一个数。
    private static let hardCutSeconds: Double = 180
    private static let retainTailMs: UInt64 = 300

    init(recorder: AudioRecorder, transcriber: LocalTranscriber,
         store: SettingsStore, notch: NotchOverlayController) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        self.notch = notch
    }

    // MARK: - ⌥,

    /// 这一刻的会话形状 —— 喂给 spec/01 §1.2 那张动作表。
    private var shape: SessionShape {
        SessionShape(recording: owningRecorder || noteSessionLive() || holdActive(),
                     hold: holdActive() && !owningRecorder && !noteSessionLive(),
                     sink: owningRecorder ? .discard
                         : (noteSessionLive() ? .noteWindow : .paste),
                     scanning: runtime.scanning)
    }

    /// 功能开关：两道门都要开。前者管「命令能不能跑」，后者管「要不要一直听着」。
    var featureEnabled: Bool {
        store.settings.jarvisModeEnabled && store.settings.voiceCommandsEnabled
    }

    /// - Returns: 给用户的一句反馈（nil = 不用说话）。
    @discardableResult
    func toggle() -> String? {
        switch JarvisMachine.toggleAction(shape: shape, featureEnabled: featureEnabled) {
        case .refuse:
            return "贾维斯没开 —— 设置 → 语音命令"
        case .stopRecording:
            stopStandby()
            return "待命已停"
        case .disarmKeepRecording:
            // 别的消费者还要这条流：只撤过滤器，录音继续。
            disarm()
            return "待命已停，录音继续"
        case .convertHold:
            // ⌥, 必然先按下 ⌥，那一截 hold 是组合键的副产物，不是说话内容。
            abortHold()
            return startStandby()
        case .armOverExisting:
            arm()
            return "待命已开 · 每段既留下又扫描"
        case .startStandby:
            return startStandby()
        }
    }

    // MARK: - 起停

    private func arm() {
        runtime.arm()
        startedAtMs = HistoryEntry.nowMs()
        onScanningChanged?(true)
        notch.setArmed(true)
        paintRest()
        Log.write("jarvis: 扫描已 armed（共跑=\(noteSessionLive())）")
    }

    /// 撤掉过滤器，但**不动**录音器 —— 它可能属于落笔会话。
    private func disarm() {
        runtime.disarm()
        cancelTimers()
        pending = nil
        conversation = nil
        onCountdownChanged?(false)
        onScanningChanged?(false)
        notch.setArmed(false)
        cardOpen = false
        if !noteSessionLive() { notch.hide() }
        Log.write("jarvis: 扫描已撤")
    }

    private func startStandby() -> String? {
        guard recorder.microphoneAuthorized else { return "麦克风未授权" }
        if store.settings.micGainBoostEnabled {
            AudioDevices.boostInputVolume(targetPercent: store.settings.micGainBoostTargetPercent)
        }
        do {
            try recorder.start()
        } catch {
            Log.write("jarvis: 起录失败 \(error)")
            return "录音启动失败"
        }
        owningRecorder = true
        segmenter.reset()
        lastTick = CFAbsoluteTimeGetCurrent()
        lastVoiceAt = 0
        arm()
        startTicking()
        return "待命中 · 只扫关键词，不留文字"
    }

    /// 纯待命的收尾：录音器是我们的，要真的停掉。
    func stopStandby() {
        guard owningRecorder else {
            disarm()
            return
        }
        owningRecorder = false
        stopTicking()
        // 待命不留任何文本，所以在飞的这一段直接丢 —— 没有「绝不丢数据」的义务，
        // 反而有「什么都不留」的承诺。
        recorder.cancel()
        disarm()
    }

    // MARK: - 采集（只有纯待命时才跑）

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        notch.setLevel(0)
    }

    private func tick() {
        guard owningRecorder else { return }
        guard recorder.isRecording else {
            Log.write("jarvis: 录音器已被外部停止，待命收尾")
            stopStandby()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let delta = now - lastTick
        lastTick = now

        let level = Double(recorder.level)
        if level > JarvisTiming.voiceLevel { lastVoiceAt = now }
        notch.setLevel(level)

        if recorder.takeDurationSeconds >= Self.hardCutSeconds {
            cut()
        } else if segmenter.feed(level: recorder.level, delta: delta) {
            cut()
        }
        paintRest()
    }

    /// 切一段去扫。
    private func cut() {
        guard let audio = try? recorder.flushSegment(retainingTailMs: Self.retainTailMs) else {
            return
        }
        segmenter.resetSegment()
        guard RecordingSubmissionPolicy.default.verdict(for: audio) == .submit else { return }
        transcribe(audio)
    }

    private func transcribe(_ audio: RecordedAudio) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-jarvis-\(UUID().uuidString).wav")
        guard (try? audio.data.write(to: url)) != nil else { return }

        inFlight += 1
        paintRest()
        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let request = LocalTranscriber.Request(
            wavURL: url,
            modelID: store.settings.selectedLocalModelId,
            language: policy.requested(),
            replacements: store.settings.transcriptionReplacements,
            // 待命只扫关键词，说话人标签没有意义，白等一遍分离。
            diarize: false)

        Task { [transcriber] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await transcriber.transcribe(request)
                await MainActor.run {
                    self.inFlight -= 1
                    self.dispatch(result.text)
                }
            } catch {
                Log.write("jarvis: 转写失败 \(error)")
                await MainActor.run {
                    self.inFlight -= 1
                    self.showCard(.error, title: "转写失败",
                                  message: String("\(error)".prefix(60)),
                                  seconds: JarvisTiming.takeResultHoldMs / 1000)
                }
            }
        }
    }

    // MARK: - 分发

    /// 扫一段 **raw transcript**。
    ///
    /// ⚠️ 必须是 raw（spec/10 A13）：加工会改写填充词和标点，能把关键词整个毁掉。
    /// 落笔共跑时由笔记会话在每段转写回来时调这里。
    ///
    /// - Returns: 这一段是不是命中了关键词。调用方拿它决定要不要把这一段标成指令。
    @discardableResult
    func dispatch(_ transcript: String) -> Bool {
        guard runtime.scanning else { return false }
        guard let match = store.settings.matchVoiceCommand(transcript) else {
            let count = runtime.countDiscarded()
            Log.write("jarvis: 没有关键词，丢弃（累计 \(count)）")
            // 未命中原本是静默丢弃，而那恰恰是最该把原文说出来的一种结果 ——
            // 只有看到它，用户才分得清关键词是**听错了**还是**没听见**。
            showCard(.cancelled, title: "没听到关键词",
                     message: JarvisMachine.takeResultLine(transcript),
                     seconds: JarvisTiming.takeResultHoldMs / 1000)
            return false
        }

        Log.write("jarvis: 命中「\(match.command.keyword)」")
        // 连续对话：这个关键词已经有一个活着的窗口/会话，就把话直接送过去，
        // 不再重新启动模板，也**没有倒计时** —— 载荷是聊天内容，不是新命令。
        //
        // Claude Code 的续接判据是「这个关键词有没有一场会话」，终端的判据是
        // 「那个窗口还在不在」，但用户看到的是同一件事：接着上一句往下说。
        if match.command.continuousConversation {
            if match.command.runner == .claudeCode,
               claude.hasConversation(keyword: match.command.keyword) {
                prepare(match.command, spoken: match.spoken, skipCountdown: true)
                return true
            }
            if match.command.runner == .terminal,
               continueConversation(match.command, spoken: match.spoken) {
                return true
            }
        }
        prepare(match.command, spoken: match.spoken)
        return true
    }

    /// 抓选区 + 读剪贴板 → 组出这条命令，再进倒计时。
    ///
    /// ⚠️ 抓选区（⌘C）里全是 `Thread.sleep`，必须离开主线程；
    /// 而且**要先抓选区再读剪贴板** —— 抓的过程会短暂借用并还原剪贴板。
    private func prepare(_ command: VoiceCommand, spoken: String,
                         skipCountdown: Bool = false) {
        showCard(.processing, title: skipCountdown ? "接着上一句" : "正在组装命令",
                 message: command.keyword, seconds: 3)
        DispatchQueue.global(qos: .userInitiated).async {
            let selection = MacAutomation.captureSelection() ?? ""
            let clipboard = MacAutomation.clipboardText()
            // 两个 runner 的展开规则不同：一个要按 shell 转义，一个是说给模型听的
            // 提示词（引号和分行都是内容）。
            let payload = command.runner == .claudeCode
                ? command.prompt(spoken: spoken, selection: selection, clipboard: clipboard)
                : command.shellCommand(spoken: spoken, selection: selection,
                                       clipboard: clipboard)
            Task { @MainActor in
                // 续接的那几句不再倒计时 —— 这是一场对话，不是一条新命令。
                if skipCountdown {
                    self.askClaude(command, prompt: payload)
                } else {
                    self.schedule(command, payload: payload)
                }
            }
        }
    }

    private func schedule(_ command: VoiceCommand, payload: String) {
        guard let id = runtime.schedule() else { return }
        let entry = Pending(id: id, command: command, payload: payload)
        pending = entry
        let shell = payload
        // esc / ↩ **只在这段窗口里**被抢占（A12）。
        onCountdownChanged?(true)
        let title = command.runner == .claudeCode
            ? "\(Int(JarvisTiming.undoCountdownSeconds)) 秒后问克劳德"
            : "\(Int(JarvisTiming.undoCountdownSeconds)) 秒后执行"
        showCard(.jarvisPending, title: title,
                 message: shell, seconds: JarvisTiming.undoCountdownSeconds + 0.5)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(
            withTimeInterval: JarvisTiming.undoCountdownSeconds, repeats: false) { _ in
            Task { @MainActor in self.fire(id: id) }
        }
        Log.write("jarvis: 待执行 #\(id) \(shell)")
    }

    /// 倒计时到点，或用户按了 ↩「立即执行」。
    func fire(id: UInt64) {
        guard runtime.take(id: id), let entry = pending, entry.id == id else { return }
        pending = nil
        countdownTimer?.invalidate()
        onCountdownChanged?(false)

        switch entry.command.runner {
        case .claudeCode:
            askClaude(entry.command, prompt: entry.payload)
        case .terminal:
            runInTerminal(entry, id: id)
        }
    }

    private func runInTerminal(_ entry: Pending, id: UInt64) {
        let command = entry.command
        do {
            try TerminalLauncher.run(entry.payload, in: command.terminal,
                                     keepFocus: command.keepFocus,
                                     newTab: command.openInNewTab)
            Log.write("jarvis: 已执行 #\(id) 于 \(command.terminal.label)")
            if command.continuousConversation,
               let target = TerminalLauncher.target(bundleID: command.terminal.bundleID) {
                conversation = (command.keyword, target)
            }
            showCard(.jarvisResult, title: "已在\(command.terminal.label)执行",
                     message: entry.payload, seconds: JarvisTiming.resultHoldSeconds)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.write("jarvis: 执行失败 \(message)")
            // 刘海是 click-through 的，没有按钮可点 —— 那条没跑成的命令
            // 只能靠剪贴板交回给用户，卡片也不自动收。
            MacAutomation.copyToClipboard(entry.payload)
            showCard(.jarvisError, title: "执行失败 · 命令已复制",
                     message: String(message.prefix(80)), seconds: 600)
        }
    }

    // MARK: - Claude Code

    /// ask 手势（双击右⌥ 并按住）用的那条「命令」。
    ///
    /// 它不经关键词 —— 手势本身就是唤醒词。连续对话开着，所以追问接得上
    /// 上一问；权限确认保持要求（这是一次提问，不是一次授权）。
    static let askCommand = VoiceCommand(
        keyword: "__ask__", commandTemplate: "{text}\n\n{selection}",
        runner: .claudeCode, continuousConversation: true)

    /// 直接问一句，不走关键词扫描。ask 手势的出口。
    func askDirectly(_ prompt: String) {
        askClaude(Self.askCommand, prompt: prompt)
    }

    /// ask 手势能不能用：功能开关 + claude 在不在。
    ///
    /// 注意它**不看** `voiceCommandsEnabled` —— 那个开关管的是「关键词能不能
    /// 触发任意 shell」，而 ask 只是把一句话交给模型，风险形状不一样。
    var askAvailable: Bool { store.settings.askModeEnabled && claude.hasClaude }

    /// 问克劳德一句。
    ///
    /// 第一句会开一场 `claude -p` 会话（tmux 里一个窗口），之后同一个关键词的
    /// 每一句都 `--resume` 接回去 —— 所以它记得住上下文。回答落在刘海上，
    /// 全文进剪贴板；整段对话在 `tmux attach -t inkfall` 里。
    private func askClaude(_ command: VoiceCommand, prompt: String) {
        // ⚠️ 忙判必须在 `startThinking()` **之前**。
        //
        // 否则这一句会先起一张自己的「在想」卡，随即因为忙被拒、在完成回调里
        // `stopThinking()` —— 而那个计时器是共享的，等于把**上一轮**还在跑的
        // 思考指示器一起掐了：屏幕上什么都没有，而它其实还在想（实测踩过：
        // 一段迟到的转写撞上来，正在飞的那一问就此失去所有反馈）。
        if let busy = claude.busyKeyword {
            Log.write("claude: 「\(busy)」还在想上一句，这句丢掉")
            // 只说一句就走，不碰在飞那一轮的卡片与计时器。
            showCard(.cancelled, title: "还在想上一句", message: ClaudeCode.answerLine(prompt),
                     seconds: JarvisTiming.cancelledHoldSeconds)
            return
        }
        // 关掉「连续对话」就意味着每一句都是新的一场。
        if !command.continuousConversation { claude.reset(keyword: command.keyword) }

        let resuming = claude.hasConversation(keyword: command.keyword)
        startThinking(title: resuming ? "克劳德在想（接着上一句）" : "克劳德在想",
                      message: ClaudeCode.answerLine(prompt))
        claude.ask(prompt, command: command) { [weak self] result in
            guard let self else { return }
            stopThinking()
            switch result {
            case .success(let answer):
                Log.write("claude: 回答 \(answer.text.count) 字")
                // 刘海只有一行，而回答往往是一段 —— 全文放剪贴板，
                // 并且在标题里**说出来**，不做无声的剪贴板改写。
                MacAutomation.copyToClipboard(answer.text)
                var title = answer.resumed ? "克劳德（接着上一句）· 已复制" : "克劳德 · 已复制"
                if let ms = answer.durationMs {
                    title += String(format: " · %.1fs", Double(ms) / 1000)
                }
                showCard(answer.isError ? .jarvisError : .jarvisResult, title: title,
                         message: ClaudeCode.answerLine(answer.text),
                         seconds: Self.answerHoldSeconds)
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.write("claude: 失败 \(message)")
                showCard(.jarvisError, title: "克劳德没答上来",
                         message: String(message.prefix(90)),
                         seconds: JarvisTiming.takeResultHoldMs / 1000)
            }
        }
    }

    /// 回答要读，比一条「已执行」需要更久。
    private static let answerHoldSeconds: Double = 8
    /// 一轮可能要几十秒，而刘海不能被一张卡锁住那么久（共跑时它还压着落笔的
    /// 计时）—— 所以「在想」这张卡是**重画**出来的，每次只占几秒。
    private static let thinkingRepaintSeconds: Double = 4

    private var thinkingTimer: Timer?

    private func startThinking(title: String, message: String) {
        showCard(.processing, title: title, message: message,
                 seconds: Self.thinkingRepaintSeconds)
        thinkingTimer?.invalidate()
        thinkingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.thinkingRepaintSeconds - 0.4, repeats: true) { _ in
            Task { @MainActor in
                self.showCard(.processing, title: title, message: message,
                              seconds: Self.thinkingRepaintSeconds)
            }
        }
    }

    private func stopThinking() {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
    }

    /// esc：撤销倒计时里的那条命令。
    @discardableResult
    func undo() -> Bool {
        guard let entry = pending, runtime.cancel(id: entry.id) else { return false }
        pending = nil
        countdownTimer?.invalidate()
        onCountdownChanged?(false)
        Log.write("jarvis: 已撤销 #\(entry.id)")
        showCard(.cancelled, title: "已撤销", message: entry.payload,
                 seconds: JarvisTiming.cancelledHoldSeconds)
        return true
    }

    /// ↩：跳过剩下的倒计时。
    @discardableResult
    func runNow() -> Bool {
        guard let entry = pending else { return false }
        fire(id: entry.id)
        return true
    }

    /// 连续对话的续接。
    ///
    /// - Returns: 文本是不是已经交给一个活着的会话了（true = 调用方不要再启动命令）。
    ///   没有会话、属于别的关键词、目标 App 已经退了 —— 都返回 false，
    ///   让这一次命中去起一条新的。
    private func continueConversation(_ command: VoiceCommand, spoken: String) -> Bool {
        guard let session = conversation, session.keyword == command.keyword else { return false }
        guard TerminalLauncher.isRunning(bundleID: session.target.bundleID ?? "") else {
            conversation = nil
            return false
        }
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let target = session.target
        DispatchQueue.global(qos: .userInitiated).async {
            let route = MacAutomation.insert(text, into: target)
            guard route != .clipboardOnly else {
                Task { @MainActor in self.conversation = nil }
                return
            }
            // 粘完等一拍再敲回车，让目标先把文本收进输入框。
            Thread.sleep(forTimeInterval: JarvisTiming.conversationReturnDelayMs / 1000)
            MacAutomation.sendKey(MacAutomation.keyReturn, command: false)
        }
        Log.write("jarvis: 连续对话 → \(target.appName)")
        showCard(.jarvisResult, title: "已发给 \(target.appName)", message: text,
                 seconds: JarvisTiming.resultHoldSeconds)
        return true
    }

    // MARK: - 刘海

    /// 卡片：占住刘海一段时间，到点回到待命形态。
    private func showCard(_ state: OverlayState, title: String, message: String,
                          seconds: Double) {
        cardOpen = true
        notch.show(state: state, message: message, title: title)
        // 落笔的 30 Hz tick 会抢刘海 —— 请宿主让开这段时间。
        onHoldNotch?(seconds)
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in
                self.cardOpen = false
                // 这段时间里可能又来了新卡片 / 扫描已经停了 —— paintRest 自己判。
                self.paintRest()
            }
        }
    }

    /// 没有卡片时刘海该长什么样。
    ///
    /// 两根轴是独立的：**宽 = 在扫描**（`armed`），**高 = 在采集**。
    /// 所以待命本身只占刘海带（绝不下坠），听到声音才长成 pill。
    private func paintRest() {
        guard runtime.scanning, !cardOpen else { return }
        // 共跑时刘海归落笔的胶囊 —— 它才是那个必须说清「文本仍然会被留下」的形状。
        guard owningRecorder else { return }
        if inFlight > 0 {
            notch.show(state: .transcribing, message: "正在转译", title: "待命")
            return
        }
        let quiet = (CFAbsoluteTimeGetCurrent() - lastVoiceAt) * 1000
        let speaking = quiet < JarvisTiming.quietCollapseMs
        notch.show(state: speaking ? .jarvisListening : .jarvisStandby,
                   message: speaking ? "在听" : "",
                   title: "待命 · 不留文字")
    }

    private func cancelTimers() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        restoreTimer?.invalidate()
        restoreTimer = nil
        stopThinking()
    }

    // MARK: - 自测取证

    var debugSnapshot: String {
        "scanning=\(runtime.scanning) 占录音器=\(owningRecorder) 丢弃=\(runtime.discarded) "
            + "待执行=\(pending.map { "#\($0.id) \($0.payload)" } ?? "无") "
            + "抢占esc↩=\(runtime.grabsEscapeAndReturn)"
    }

    var debugGrabsEscape: Bool { runtime.grabsEscapeAndReturn }
    var debugPendingShell: String? { pending?.payload }
    /// 干跑：只算「这句话会不会命中、`{text}` 是什么」，**不执行**。
    func debugMatch(_ transcript: String) -> String {
        guard let match = store.settings.matchVoiceCommand(transcript) else {
            return "未命中"
        }
        return "命中「\(match.command.keyword)」→ " + match.command.shellCommand(
            spoken: match.spoken, selection: "", clipboard: "")
    }
}
