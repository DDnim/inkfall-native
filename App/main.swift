import AppKit
import ApplicationServices
import SwiftUI
import InkfallCore

/// 菜单栏常驻宿主。
///
/// 刻意用 AppKit 做宿主而不是纯 SwiftUI `App`：重写需要精确控制窗口层级、
/// 非激活 NSPanel、click-through、`orderFrontRegardless` —— 这些
/// `WindowGroup` 都表达不了。视图内部全用 SwiftUI。
///
/// 减法版（2026-09-23）只剩两个手势：**按住说话**（按下起录、松开转写插回）
/// 与**切换录音**（按一下开始长录音、再按一下转写插回）。落笔、贾维斯、
/// 问助手、截图、笔记、本地集成都已经砍掉。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private let permissions = PermissionCoordinator()
    private let store = SettingsStore()
    private let recorder = AudioRecorder()
    private let notch = NotchOverlayController()
    private lazy var models = ModelCatalog(store: store, transcriber: transcriber)
    private lazy var hub = HubWindowController(
        store: store, permissions: permissions, models: models)

    private let transcriber = LocalTranscriber()
    /// 转写的唯一入口：按设置走云端或本地，云端不可达时降级到本地。
    private lazy var router = Transcriber(local: transcriber)
    /// 转写完到粘贴之间的那一步：预设、提示词、云端、降级。
    /// 两个手势共用同一个实例，提示与日志才只有一套。
    private lazy var processing = PostProcessingCoordinator(store: store)

    /// 加工那一步要跟用户说的话。攒到粘贴结果那一刻一起说 —— 单独闪一下
    /// 会被紧接着的「粘贴中 / 已粘回 X」在几十毫秒内盖掉。
    private var pendingProcessingNotice: (text: String, isProblem: Bool)?
    /// 转写那一步的提示（云端没连上、没配 key 时的降级）。加工没话说时才轮到它。
    private var pendingTranscriptionNotice: String?
    /// 试做：Jev 判出「像在叫助手」时的那句话。同样攒到粘贴结果那一刻说。
    private var pendingIntentNotice: String?
    /// 试做：每段问一次 Jev「是不是在叫助手」，只记日志 + 提示，不改粘贴。
    private let intent = AssistantIntentProbe()
    /// 试做：Jev 判成 call 的话放进 Obsidian 看板的起票面板，不粘贴。
    private let kanban = KanbanHandoff()
    /// 试做：切换录音的每段旁路核对「说错了没有」，说错就在刘海上纠正一句（不改粘贴）。
    private let interject = InterjectionProbe()
    /// 刘海上的纠正要停留到这一刻。长录音的计时 30 Hz 在重画，不挡住就一闪而过。
    private var notchHoldUntil: CFAbsoluteTime = 0
    /// 试做：纠正同时念出来。念的期间长录音不切段，念完把这段录音扔掉（否则 AI 的声音会被转写粘出去）。
    private let interjectVoice = InterjectionVoice()
    /// 试做：⌥, 切换。助手模式下录的话**不粘贴**，加工后记进历史（`history.json`）。跨重启保留。
    private var assistantMode = UserDefaults.standard.bool(forKey: "inkfall.assistantMode") {
        didSet {
            UserDefaults.standard.set(assistantMode, forKey: "inkfall.assistantMode")
            modeMenuItem?.state = assistantMode ? .on : .off
        }
    }
    private let history = HistoryStore()
    private var modeMenuItem: NSMenuItem?
    private let historyMenu = NSMenu()

    /// 助手模式的长录音：边听边插话（停顿 0.2 秒先转写，Jev 判说完了就纠正；1.5 秒硬收）。
    /// 输入模式的长录音不走这里，照旧按 1.3 秒停顿分段粘贴。
    private lazy var live: LiveInterjector = makeLive()
    /// `--live-sim` 进行中：假录音器、JSONL 输出、念纠正的模拟。
    private var liveSim: (source: FileLiveSource, out: FileHandle?, mute: Bool)?
    /// `--live-sim --mute`：不出声，按字数估念多久；这期间和真的一样不切段，念完扔掉录到的。
    private var simVoiceUntil: CFAbsoluteTime = 0
    /// 收下的句子还在核对 / 回答的个数（模拟等它们归零再退出）。
    private var liveActsPending = 0
    /// 边听边插话收下的句子（最近 12 句）：判插不插时看这句之后本人有没有改口。
    private var liveHeard: [(at: CFAbsoluteTime, text: String)] = []

    /// 切换录音的自动分段：停顿 1.3 秒就切一段送去转写，不等再按一下。
    private var segmenter = SilenceSegmenter()
    private var lastSegmentTick: CFAbsoluteTime = 0
    /// 刘海上的总时长。`takeDurationSeconds` 每切一段就归零，不能拿来显示。
    private var toggleStartedAt: CFAbsoluteTime = 0
    /// 这一场长录音已经送出去几段。> 0 时，最后那截静音不再提示「太短了」。
    private var toggleSegmentsSent = 0
    /// 单段硬上限：说了三分钟没停顿也要切，转写延迟和失败代价随时长线性上涨。
    private static let hardCutSeconds: Double = 180
    /// 切段时给下一段留的尾巴，免得把词头切秃。
    private static let retainTailMs: UInt64 = 300

    /// 一段一段来：前一段走完（粘上 / 交给看板 / 丢弃 / 失败）才放下一段。
    /// 并发跑的话，云端先回来的后一段会先粘出去，顺序就乱了。
    private var takeQueue: [(audio: RecordedAudio, tag: String, target: PasteTarget?, quiet: Bool)] = []
    private var takeInFlight = false

    /// 录音**开始那一刻**的前台窗口。等转写回来再看前台是谁，就粘到别人窗口里了。
    private var pasteTarget: PasteTarget?

    /// 「粘贴要辅助功能授权」这句引导，一次运行只弹一次。
    private var accessibilityPrompted = false

    /// 这一次「按住说话」是不是真的占着录音器。
    ///
    /// ⚠️ 没有这个标记就会丢掉整场长录。⌥Space 里的那个 ⌥ **就是推杆键本身**：
    /// 按下它，matcher 立刻发 `.overlayHoldPressed`，`beginHold()` 已经起录；
    /// 随后 Space 才到，切换录音接管同一个录音器；最后松开 ⌥ 发
    /// `.overlayHoldReleased` —— 无条件的 `endHold()` 就把长录的录音器停了。
    private var holdOwnsRecorder = false
    /// 切换录音进行中（按一下开始、再按一下结束）。
    private var toggleOwnsRecorder = false

    /// 会话内语言锁定：**两段判出同一种语言才锁**（见 `SessionLanguageLock`）。
    /// Whisper 对短句的自动检测经常判错，一句两个字的中文被当成英文，
    /// 输出就是一串音译垃圾 —— 而第一句恰恰最短最急，最不该由它定生死。
    private var languageLock = SessionLanguageLock()
    private var sessionLanguage: TranscriptionLanguage? { languageLock.locked }
    /// 空闲一段时间就把模型还给系统 —— turbo 常驻 1.5 GB。
    private var unloadTimer: Timer?

    private var hotkeys: HotkeyMonitor?
    private var levelTimer: Timer?
    private var hideTimer: Timer?
    private var accessibilityWatch: Timer?

    /// 自测模式：把热键事件同时打到 stderr 并留档，供 `--hotkey-selftest` 断言。
    private var selfTest = false
    private var selfTestEvents: [HotkeyEvent] = []

    /// tap 回调只能拿到静态可达的东西 —— 委托本身不是 Sendable。
    /// 它与 App 同寿，所以这个引用永远有效。
    @MainActor static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏工具：无 Dock 图标（等价于 LSUIElement）。
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.shared = self

        installStatusItem()

        // 预热这份配置真会用到的 API key（后台线程读钥匙串）。
        // 绝不在「用户刚说完话、正等着文字落下来」的路径上现 fork 一个
        // `security` —— 那是最不能被阻塞的几百毫秒。
        processing.preloadKeys()

        let arguments = ProcessInfo.processInfo.arguments

        // 加工自测：把九个预设的提示词打出来，再真跑一次当前配置的加工。
        if let index = arguments.firstIndex(of: "--process-test") {
            let next = arguments[safe: index + 1] ?? ""
            runProcessTest(text: next.hasPrefix("--") ? "" : next)
            return
        }

        // 叫助手判定自测（试做）：`--intent-test "<文字>" [--bundle <bundle ID>]`，真发一次 Jev。
        if let index = arguments.firstIndex(of: "--intent-test") {
            runIntentTest(text: arguments[safe: index + 1] ?? "",
                          bundleID: arguments.firstIndex(of: "--bundle").flatMap { arguments[safe: $0 + 1] })
            return
        }

        // 助手模式自测（试做）：`--interject-test "<文字>"`，真跑 Jev 分流 + 回答 / 核对（不发看板）。
        // 评测：`--interject-eval <cases.json> <out.json> [--provider groq] [--model m] [--no-gate] [--pace 秒]`。
        if let index = arguments.firstIndex(of: "--interject-test") {
            runInterjectTest(text: arguments[safe: index + 1] ?? "", previous: nil)
            return
        }
        if let index = arguments.firstIndex(of: "--interject-eval") {
            runInterjectEval(cases: arguments[safe: index + 1] ?? "", out: arguments[safe: index + 2] ?? "")
            return
        }

        // 边听边插话的模拟：wav 按真实时间「录」进来，转写 / Jev / 核对全是真的，不出声加 `--mute`。
        // `--live-sim <wav> [--out <jsonl>] [--mute] [--tail 秒]`
        if let index = arguments.firstIndex(of: "--live-sim") {
            runLiveSim(wav: arguments[safe: index + 1] ?? "")
            return
        }

        // 云端转写自测：拿一个 wav 走真实的 Transcriber（含降级），不需要麦克风。
        if let index = arguments.firstIndex(of: "--cloud-transcribe-test") {
            let wav = arguments[safe: index + 1] ?? ""
            runCloudTranscribeTest(wav: wav.hasPrefix("--") ? "" : wav)
            return
        }

        // 粘回自家窗口的自测：2026-08-04 那次崩溃的回归守卫。
        if arguments.contains("--self-paste-test") {
            runSelfPasteTest()
            return
        }

        // 录音自测：录 N 秒，落成 WAV，把提交策略的裁决一并打出来。
        if let index = arguments.firstIndex(of: "--record-test") {
            let seconds = Double(arguments[safe: index + 1] ?? "") ?? 3
            runRecordTest(seconds: seconds)
            return
        }

        // 本地转写自测：喂一个 WAV 进去，把模型下载 → 加载 → 转写 → 规则润色整条走完。
        if let index = arguments.firstIndex(of: "--transcribe-test") {
            runTranscribeTest(path: arguments[safe: index + 1] ?? "")
            return
        }

        // 全链路自测：右⌥ 按住 → 外放播一段语音 → 松开 → 转写 → 粘回文本编辑。
        if let index = arguments.firstIndex(of: "--loop-test") {
            runLoopTest(wav: arguments[safe: index + 1] ?? "", file: arguments[safe: index + 2] ?? "")
            return
        }

        // 模型下载自测：走 ModelCatalog 的完整流程。
        if let index = arguments.firstIndex(of: "--model-download-test") {
            runModelDownloadTest(id: arguments[safe: index + 1] ?? "")
            return
        }

        // 菜单自测：把托盘菜单（含模型子菜单）的实际结构打出来。
        if arguments.contains("--menu-dump") {
            selfTest = true
            emit("托盘菜单：")
            for item in statusItem?.menu?.items ?? [] {
                emit("  \(item.isSeparatorItem ? "──────" : item.title)")
                for sub in item.submenu?.items ?? [] {
                    let mark = sub.state == .on ? "●" : (sub.isSeparatorItem ? " " : "○")
                    emit("    \(mark) \(sub.isSeparatorItem ? "──────" : sub.title)"
                         + (sub.isEnabled ? "" : "（不可用）"))
                }
            }
            Log.flush()
            exit(0)
        }

        // 粘贴自测：往当前前台窗口插一段带标记的文字，再用 AX 读回来核对。
        if arguments.contains("--paste-test") {
            runPasteTest()
            return
        }

        // 自动粘贴自测：剪贴板存/还原、目标退出/无目标/开关关闭的降级、焦点归还。
        if arguments.contains("--autopaste-test") {
            runAutoPasteTest()
            return
        }

        // 热键自测：合成一次真实的右 ⌥ 按住并松开，走完整条
        // CGEventPost → HID tap → 匹配器 → 录音 的链路。
        if arguments.contains("--hotkey-selftest") {
            runHotkeySelfTest()
            return
        }

        // 切换录音自测：合成 右⌥+Space 两次，验「按一下起录、再按一下停」，
        // 以及推杆那截副产物录音被丢掉、松开 ⌥ 不会误停长录。
        if arguments.contains("--toggle-selftest") {
            runToggleSelfTest()
            return
        }

        // 首启，**或者**老用户的辅助功能授权被撤销了 —— 两种情况都弹引导。
        if !store.settings.hasCompletedOnboarding || !permissions.isGranted(.accessibility) {
            showOnboarding()
        }

        startHotkeys()

        // 预热本地模型：第一次按住说话不该等几秒的 CoreML 编译。
        // 权重没下过就跳过 —— 静默拉 1.5 GB 是不能接受的。
        let modelID = store.settings.selectedLocalModelId
        if let model = LocalModels.definition(id: modelID),
           LocalTranscriber.isDownloaded(model) {
            Task { [transcriber] in await transcriber.prewarm(modelID: modelID) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    // MARK: - 菜单栏

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 品牌字形（与 Tauri 版同一张 tray-icon）。
            // 必须是 template 才能跟随菜单栏色并自动适配明暗。
            let image = NSImage(named: "StatusIcon")
                ?? NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Inkfall")
            image?.isTemplate = true
            image?.accessibilityDescription = "Inkfall"
            button.image = image
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        let mode = NSMenuItem(title: "助手模式（⌥, 切换）", action: #selector(toggleModeFromMenu), keyEquivalent: "")
        mode.state = assistantMode ? .on : .off
        menu.addItem(mode)
        modeMenuItem = mode
        let historyItem = NSMenuItem(title: "历史记录", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        rebuildHistoryMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "刘海自测", action: #selector(testOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "重新打开引导", action: #selector(reopenOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出落音", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quit)
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func reopenOnboarding() { showOnboarding() }
    @objc private func toggleModeFromMenu() { toggleMode() }

    /// ⌥, / 菜单：输入模式（粘贴）⇄ 助手模式（不粘贴，记进历史）。
    private func toggleMode() {
        assistantMode.toggle()
        Log.write("mode: \(assistantMode ? "助手模式" : "输入模式")")
        flash(.success, assistantMode ? "助手模式 · 不粘贴，记进历史" : "输入模式 · 照常粘贴", seconds: 1.6)
        handOverToggleRecording()
    }

    /// 长录音录到一半切模式：切到助手就转成边听边插话，切回输入就把边听收尾、接着按停顿切段粘贴。
    /// 原来只在起录时看模式，录到一半切到助手走的还是按 1.3 秒切段那条路，边听插话根本没开（2026-10-01 真机）。
    private func handOverToggleRecording() {
        guard toggleOwnsRecorder, recorder.isRecording else { return }
        if assistantMode, !live.isActive {
            // 切之前那截是输入模式下说的（多半只有按 ⌥, 的那一下），不拿去核对
            let dropped = (try? recorder.flushSegment())?.durationMs ?? 0
            segmenter.resetSegment()
            interject.reset()
            Log.write("toggle: 录音中切到助手，转成边听插话（丢掉切之前的 \(dropped)ms）")
            startLive(source: RecorderLiveSource(recorder))
        } else if !assistantMode, live.isActive {
            live.stop(finalAudio: try? recorder.flushSegment())
            segmenter.resetSegment()
            Log.write("toggle: 录音中切回输入，边听插话收尾")
        }
    }

    /// 历史记录的子菜单：最近 20 条，点一下复制。
    private func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        let recent = history.entries.prefix(20)
        if recent.isEmpty {
            historyMenu.addItem(withTitle: "（还没有记录）", action: nil, keyEquivalent: "")
        }
        let time = DateFormatter()
        time.dateFormat = "MM-dd HH:mm"
        for entry in recent {
            let text = entry.displayText.replacingOccurrences(of: "\n", with: " ")
            let label = "\(time.string(from: Date(timeIntervalSince1970: Double(entry.createdAtMs) / 1000)))  "
                + (text.count > 36 ? String(text.prefix(36)) + "…" : text)
            let item = NSMenuItem(title: label, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.representedObject = entry.displayText
            item.toolTip = entry.displayText
            item.target = self
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        let open = NSMenuItem(title: "在 Finder 中显示 history.json", action: #selector(revealHistoryFile), keyEquivalent: "")
        open.target = self
        historyMenu.addItem(open)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(.success, "已复制", seconds: 1.2)
    }

    @objc private func revealHistoryFile() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.url])
    }

    /// 助手模式：这一段不粘贴，记进历史。
    private func recordAssistantTake(source: String, outcome: PostProcessingCoordinator.Outcome) {
        let settings = store.settings
        history.append(HistoryEntry(sourceText: source, finalText: outcome.text,
                                    transcriptionMode: settings.transcriptionMode,
                                    postProcessingEnabled: settings.postProcessingEnabled,
                                    postProcessingPreset: settings.postProcessingPreset))
        rebuildHistoryMenu()
        Log.write("history: 助手模式记下 \(outcome.text.count) 字（共 \(history.entries.count) 条）")
    }
    @objc private func showSettings() { hub.show() }
    /// 刘海自测：把几个状态依次画一遍。录音管线接上之前，
    /// 这是唯一能看到墨锭真实渲染的方式（截图受 TCC 限制）。
    @objc private func testOverlay() {
        let beats: [(OverlayState, String, Double)] = [
            (.recording, "录音 00:03", 0),
            (.transcribing, "正在转写", 1.4),
            (.processing, "正在加工", 2.6),
            (.success, "已粘贴回原窗口", 3.8),
        ]
        for (state, message, delay) in beats {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.notch.show(state: state, message: message)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in
            self?.notch.hide()
        }
    }

    /// 录一段真实音频并把结果打到 stderr。
    private func runRecordTest(seconds: Double) {
        guard recorder.microphoneAuthorized else {
            emit("麦克风未授权 —— 先在引导里授权（或系统设置 → 隐私 → 麦克风）")
            recorder.requestMicrophoneAccess { granted in
                emit("请求结果 granted=\(granted)；授权后重跑本命令")
                exit(granted ? 0 : 1)
            }
            return
        }

        if let device = AudioDevices.builtInInput() {
            emit("绑定设备：\(AudioDevices.name(device))（内置）")
        } else if let device = AudioDevices.defaultInput() {
            emit("⚠️ 没有内置麦克风，回落默认输入：\(AudioDevices.name(device))")
        }
        AudioDevices.boostInputVolume(targetPercent: 80)

        do {
            try recorder.start()
        } catch {
            emit("start 失败：\(error)")
            exit(1)
        }
        emit("录音中 \(seconds)s…（说点什么）")

        // 中途采一次电平，确认回调真的在跑而不是只有一个空的 WAV 头。
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) { [self] in
            emit(String(format: "中途 level=%.4f 段峰值=%.4f 已录=%.2fs",
                        recorder.level, recorder.takePeak, recorder.takeDurationSeconds))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            do {
                let audio = try recorder.stop()
                let path = "/tmp/inkfall-record-test.wav"
                try audio.data.write(to: URL(fileURLWithPath: path))
                let info = WAV.parse(audio.data)
                let verdict = RecordingSubmissionPolicy.default.verdict(for: audio)
                emit("停止：bytes=\(audio.data.count) durationMs=\(audio.durationMs)")
                emit("WAV：rate=\(info?.sampleRate ?? 0) channels=\(info?.channels ?? 0) "
                     + "pcmBytes=\(info?.dataRange.count ?? 0)")
                emit("提交裁决：\(verdict.rawValue)")
                emit("已写入 \(path)")
                exit(0)
            } catch {
                emit("stop 失败：\(error)")
                exit(1)
            }
        }
    }

    /// 全链路自测。
    private func runLoopTest(wav: String, file: String) {
        selfTest = true
        guard AXIsProcessTrusted(), recorder.microphoneAuthorized else {
            emit("缺权限：辅助功能=\(AXIsProcessTrusted()) 麦克风=\(recorder.microphoneAuthorized)")
            Log.flush()
            exit(1)
        }
        startHotkeys()
        guard hotkeys != nil else {
            emit("tap 建立失败")
            Log.flush()
            exit(1)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.TextEdit" }?
                .activate(options: .activateAllWindows)
            Thread.sleep(forTimeInterval: 1.5)

            emit("→ 右⌥ 按下")
            Self.postRightOption(down: true)
            Thread.sleep(forTimeInterval: 0.5)

            // 外放播语音，让内置麦克风真的收一遍 —— 直接喂 WAV 就绕过了
            // AUHAL 采集这一段，等于没测。
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [wav]
            try? player.run()
            player.waitUntilExit()

            Thread.sleep(forTimeInterval: 0.4)
            emit("→ 右⌥ 松开")
            Self.postRightOption(down: false)
            Thread.sleep(forTimeInterval: 1.0)

            // 系统输出接在蓝牙耳机上时，内置麦克风收不到外放，这一遍必然判静音。
            // 那就把同一段已知音频直接送进「转写 → 润色 → 三层插入」，
            // 至少让后半条链路是被真实驱动的。
            // （AUHAL 采集本身另有 `--record-test` 单独验证。）
            // 等转写 + 粘贴走完。分离开着时要多给一档。
            Thread.sleep(forTimeInterval: 20)
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.TextEdit" }?.activate()
            Thread.sleep(forTimeInterval: 0.4)
            MacAutomation.sendKey(1, command: true)   // ⌘S
            Thread.sleep(forTimeInterval: 1.2)

            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            emit("文件内容：\(text)")
            let ok = text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
            emit(ok ? "✅ 录音 → 本地转写 → 粘贴 全链路通" : "❌ 目标窗口里没有转写文字")
            Log.flush()
            exit(ok ? 0 : 1)
        }
    }

    /// 粘贴自测：先测「目标已在前台」的零激活路径，再测跨 App 路径。
    private func runPasteTest() {
        selfTest = true
        guard AXIsProcessTrusted() else {
            emit("未授权辅助功能")
            Log.flush()
            exit(1)
        }
        // 等前台稳定：`open` 拉起本进程时前台可能正在切换。
        // 整段跑在后台队列上 —— 主线程一堵，被测的路径就跟真实调用不一样了。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            // 自己把被测 App 拉到前台，别指望脚本调用时它还在 —— 上一次跑
            // 就因为别的 App 抢了焦点，把标记插进了无关窗口。
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.TextEdit" }?
                .activate(options: .activateAllWindows)
            Thread.sleep(forTimeInterval: 1.5)

            guard let target = PasteTarget.current() else {
                emit("抓不到前台 App")
                Log.flush()
                exit(1)
            }
            emit("目标：\(target.appName) pid=\(target.processID) "
                 + "窗口引用=\(target.window != nil) 前台=\(target.isFrontmost)")
            guard target.bundleID == "com.apple.TextEdit" else {
                emit("前台不是文本编辑，测不了 —— 先把它打开并置前")
                Log.flush()
                exit(1)
            }

            let markerA = "落音甲\(Int.random(in: 1000...9999))"
            let routeA = MacAutomation.insert(markerA, into: target)
            emit("① 目标在前台：route=\(routeA.route?.rawValue ?? "无") "
                 + "outcome=\(routeA.outcome.rawValue)")

            // 切走再插一次，走跨 App 的 B1/B2。
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
            Thread.sleep(forTimeInterval: 0.8)
            let markerB = "落音乙\(Int.random(in: 1000...9999))"
            let routeB = MacAutomation.insert(markerB, into: target)
            emit("② 跨 App：route=\(routeB.route?.rawValue ?? "无") "
                 + "outcome=\(routeB.outcome.rawValue)")

            // 存盘再从磁盘读 —— AX 读回会摸到窗口标题之类的邻近元素，
            // 不是可信的地面真相。
            NSRunningApplication(processIdentifier: target.processID)?.activate()
            Thread.sleep(forTimeInterval: 0.4)
            MacAutomation.sendKey(1, command: true)   // ⌘S
            Thread.sleep(forTimeInterval: 1.2)
            let path = ProcessInfo.processInfo.arguments.last ?? ""
            let readBack = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            emit("文件内容：\(readBack.suffix(80))")
            let okA = readBack.contains(markerA)
            let okB = readBack.contains(markerB)
            emit("标记甲=\(okA) 标记乙=\(okB)")
            emit(okA && okB ? "✅ 粘贴链路通" : "❌ 有标记没落进目标窗口")
            Log.flush()
            exit(okA && okB ? 0 : 1)
        }
    }

    /// 自动粘贴自测：把**能程序化取证**的那几条挨个跑一遍。
    ///
    /// `--paste-test` 证的是「文字落进了目标窗口」。这一条证的是它证不了的部分：
    /// 剪贴板有没有被还原（A20）、目标退出/没有目标/没授权时会不会降级、
    /// 跨 App 粘完焦点有没有还回去。三层路线的**选择**逻辑在 InkfallCore 有单测，
    /// 这里跑的是接上真实系统调用之后的行为。
    private func runAutoPasteTest() {
        selfTest = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            var failures: [String] = []
            func check(_ ok: Bool, _ what: String) {
                emit((ok ? "  ✓ " : "  ✗ ") + what)
                if !ok { failures.append(what) }
            }
            let pasteboard = NSPasteboard.general
            // 这个自测会反复改剪贴板 —— 跑完必须把用户自己的东西放回去，
            // 不然「验证剪贴板卫生」的自测本身成了破坏剪贴板的那个人。
            let userClipboard = pasteboard.string(forType: .string)
            func finish(_ ok: Bool) -> Never {
                if let userClipboard {
                    pasteboard.clearContents()
                    pasteboard.setString(userClipboard, forType: .string)
                }
                Log.flush()
                exit(ok ? 0 : 1)
            }
            let trusted = AXIsProcessTrusted()
            emit("辅助功能授权=\(trusted)")

            // ——— ① 没有目标：文字必须留在剪贴板上，绝不能凭空消失。
            emit("① 没有目标")
            let sentinel = "哨兵\(Int.random(in: 1000...9999))"
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            let noTargetText = "落音无目标\(Int.random(in: 1000...9999))"
            let noTarget = MacAutomation.insert(noTargetText, into: nil)
            check(noTarget.outcome == (trusted ? .noTarget : .accessibilityDenied),
                  "outcome=\(noTarget.outcome.rawValue)")
            check(pasteboard.string(forType: .string) == noTargetText,
                  "文字留在了剪贴板上（这一条**不**还原，那正是它的意义）")
            check(!noTarget.landedInTarget, "没被误标成已粘贴")

            // ——— ② 目标已退出：死进程 activate 是空操作，之后那一下 ⌘V
            // 会打进当时恰好在前台的别人窗口。必须在合成按键之前就拦住。
            emit("② 目标已退出（真实的死 pid）")
            let dying = Process()
            dying.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try? dying.run()
            dying.waitUntilExit()
            let dead = PasteTarget(bundleID: "app.inkfall.gone",
                                   processID: dying.processIdentifier,
                                   appName: "已退出的 App", window: nil)
            check(!dead.isRunning, "pid \(dead.processID) 判定为已退出")
            let deadText = "落音已退出\(Int.random(in: 1000...9999))"
            let deadResult = MacAutomation.insert(deadText, into: dead)
            check(deadResult.outcome == (trusted ? .targetClosed : .accessibilityDenied),
                  "outcome=\(deadResult.outcome.rawValue)")
            check(deadResult.route == .clipboardOnly, "只复制，没有合成任何按键")
            check(pasteboard.string(forType: .string) == deadText, "文字落到了剪贴板")
            emit("  提示语：\(AutoPaste.message(deadResult.outcome, appName: dead.appName))")

            // ——— ③ 开关关掉：同样只复制。
            emit("③ 自动粘贴开关关闭")
            let offText = "落音关闭\(Int.random(in: 1000...9999))"
            let off = MacAutomation.insert(
                offText, into: nil, options: PasteOptions(autoPasteEnabled: false))
            check(off.outcome == .disabled, "outcome=\(off.outcome.rawValue)（未授权也不该盖过它）")
            check(pasteboard.string(forType: .string) == offText, "文字落到了剪贴板")

            // ——— ④ 补换行。
            let newlineText = "落音换行\(Int.random(in: 1000...9999))"
            _ = MacAutomation.insert(newlineText, into: nil,
                                     options: PasteOptions(appendNewline: true))
            check(pasteboard.string(forType: .string) == newlineText + "\n",
                  "pasteAppendNewline 补上了行尾换行")

            guard trusted else {
                emit("⚠️ 未授权辅助功能：真实 ⌘V 的两条路线跑不了，"
                     + "上面验的是降级行为。授权后重跑本自测。")
                emit(failures.isEmpty ? "✅ 降级路径全部符合预期" : "❌ \(failures.count) 项不符")
                finish(failures.isEmpty)
            }

            // ——— ⑤ 目标在前台：零激活粘贴，粘完剪贴板必须还原（A20）。
            emit("⑤ 目标在前台（TextEdit）")
            // ⚠️ 用 `/usr/bin/open -b` 而不是 `NSRunningApplication.activate()`：
            // 自测跑起来时本 App 是后台的，而 macOS 14 起，非激活 App 发出的
            // activate 会被系统直接忽略 —— 于是被测的「前台」根本没换过。
            Self.activateViaLaunchServices("com.apple.TextEdit")
            Thread.sleep(forTimeInterval: 1.5)
            guard let target = PasteTarget.current(),
                  target.bundleID == "com.apple.TextEdit" else {
                emit("❌ 前台是「\(PasteTarget.current()?.appName ?? "?")」不是文本编辑，"
                     + "后两阶段测不了 —— 先把它打开并置前")
                finish(false)
            }
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            let inPlace = MacAutomation.insert("落音甲\(Int.random(in: 1000...9999))",
                                               into: target)
            check(inPlace.outcome == .inserted,
                  "outcome=\(inPlace.outcome.rawValue) route=\(inPlace.route?.rawValue ?? "无")")
            check(pasteboard.string(forType: .string) == sentinel,
                  "剪贴板还原成了哨兵「\(sentinel)」")

            // ——— ⑥ 跨 App：粘完剪贴板要还原，焦点要回到粘之前那个 App。
            emit("⑥ 跨 App（前台切到访达）")
            Self.activateViaLaunchServices("com.apple.finder")
            Thread.sleep(forTimeInterval: 1.2)
            let finderPID = MacAutomation.frontmostPID()
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            let crossApp = MacAutomation.insert("落音乙\(Int.random(in: 1000...9999))",
                                                into: target)
            check(crossApp.landedInTarget,
                  "outcome=\(crossApp.outcome.rawValue) route=\(crossApp.route?.rawValue ?? "无")")
            check(pasteboard.string(forType: .string) == sentinel, "剪贴板还原成了哨兵")
            let back = MacAutomation.frontmostPID()
            check(back == finderPID,
                  "焦点回到了粘之前那个 App（pid \(back.map(String.init) ?? "无") "
                  + "vs \(finderPID.map(String.init) ?? "无")）")

            // ——— ⑦ 逼出 B2（切过去粘再切回来）。访达的焦点元素是文件列表，
            // 不吃 `AXSelectedText` 写入，所以以它为目标就会落到最后那条回落路线 ——
            // 那也是 sleep 最多、最容易把剪贴板还原写错的一条。
            emit("⑦ 回落路线（目标=访达，AX 写入会被拒）")
            Self.activateViaLaunchServices("com.apple.finder")
            Thread.sleep(forTimeInterval: 1.2)
            let finderTarget = PasteTarget.current()
            Self.activateViaLaunchServices("com.apple.TextEdit")
            Thread.sleep(forTimeInterval: 1.2)
            let textEditPID = MacAutomation.frontmostPID()
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            let fallback = MacAutomation.insert("落音丙\(Int.random(in: 1000...9999))",
                                                into: finderTarget)
            emit("  route=\(fallback.route?.rawValue ?? "无") "
                 + "outcome=\(fallback.outcome.rawValue)")
            check(fallback.route == .activateAndPaste,
                  "走到了 activateAndPaste（访达拒绝 AX 写入）")
            check(pasteboard.string(forType: .string) == sentinel, "剪贴板还原成了哨兵")
            check(MacAutomation.frontmostPID() == textEditPID, "焦点还给了粘之前的文本编辑")

            emit(failures.isEmpty ? "✅ 自动粘贴全部符合预期"
                                  : "❌ \(failures.count) 项不符：\(failures.joined(separator: "；"))")
            finish(failures.isEmpty)
        }
    }

    /// 把某个 App 拉到前台。只给自测用。
    private static func activateViaLaunchServices(_ bundleID: String) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundleID]
        try? open.run()
        open.waitUntilExit()
    }

    /// 读回焦点元素的全文，用来核对刚插进去的标记确实到了目标 App。
    private static func readFocusedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// 本地转写自测。
    private func runTranscribeTest(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            emit("找不到音频：\(path)")
            Log.flush()
            exit(1)
        }
        let id = store.settings.selectedLocalModelId
        guard let model = LocalModels.definition(id: id) else {
            emit("未知模型 \(id)")
            Log.flush()
            exit(1)
        }
        emit("模型 \(model.name)（\(model.variant)，\(model.sizeLabel)）"
             + " 已下载=\(LocalTranscriber.isDownloaded(model))")
        emit("权重目录 \(LocalTranscriber.modelRoot.path)")

        Task { [transcriber] in
            let started = Date()
            do {
                let request = LocalTranscriber.Request(
                    wavURL: url, modelID: id,
                    language: TranscriptionLanguagePolicy(settings: store.settings).requested(),
                    replacements: ProcessInfo.processInfo.arguments.contains("--no-vocab")
                        ? [:] : store.settings.transcriptionReplacements)
                // 连跑三遍：第一遍含模型加载，后两遍才是常驻时的真实延迟。
                // 同时也是回归 —— 同一个实例上重复转写必须每次都出同样的文字。
                var texts: [String] = []
                for round in 1...3 {
                    let r = try await transcriber.transcribe(request)
                    texts.append(r.text)
                    emit(String(format: "第 %d 遍 %.2fs lang=%@ → 「%@」",
                                round, round == 1 ? Date().timeIntervalSince(started) : r.elapsed,
                                r.language ?? "?", r.text))
                }
                emit("润色：\(BasicPolisher.polish(texts[0]))")
                let stable = Set(texts).count == 1
                emit(stable ? "✅ 本地转写通（三遍一致）" : "❌ 重复转写结果不一致")
                Log.flush()
                exit(stable ? 0 : 1)
            } catch {
                emit("❌ 失败：\(error)")
                Log.flush()
                exit(1)
            }
        }
    }

    /// 合成一次右 ⌥ 按住 1.5 秒再松开，验证整条热键链路。
    private func runHotkeySelfTest() {
        selfTest = true
        guard AXIsProcessTrusted() else {
            // 顺手把自己登记进辅助功能列表并把面板打开 —— 否则用户在列表里
            // 根本找不到这个 App，只能手动拖二进制进去。
            permissions.request(.accessibility)
            emit("未授权辅助功能 —— 已打开系统设置，勾选「落音 Inkfall」后重跑本命令")
            exit(1)
        }
        startHotkeys()
        guard let monitor = hotkeys else {
            emit("tap 建立失败")
            exit(1)
        }
        emit("tap 已启用 enabled=\(monitor.isEnabled) 绑定=\(store.effectiveShortcuts.overlayHold.displayLabel)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            emit("→ 合成 右⌥ 按下")
            Self.postRightOption(down: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            emit("按住中：录音=\(recorder.isRecording) 刘海可见=\(notch.isVisible) "
                 + String(format: "已录=%.2fs", recorder.takeDurationSeconds))
            emit("  胶囊 紧凑=\(notch.debugIsCompact) 文案=「\(notch.debugMessage)」"
                 + " \(notch.debugCapsule)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [self] in
            emit("→ 合成 右⌥ 松开")
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [self] in
            emit("松开后：录音=\(recorder.isRecording) 刘海可见=\(notch.isVisible) "
                 + "紧凑=\(notch.debugIsCompact) 文案=「\(notch.debugMessage)」")
            emit("收到事件：\(selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            let ok = selfTestEvents.contains(.overlayHoldPressed)
                && selfTestEvents.contains(.overlayHoldReleased)
            emit(ok ? "✅ 热键链路通" : "❌ 事件不完整")
            Log.flush()
            exit(ok ? 0 : 1)
        }
    }

    /// ⌥Space 切换录音的回归自测。
    ///
    /// 盯的是这个：右⌥ 按下时 matcher 必然先发一次 `.overlayHoldPressed`，
    /// `beginHold()` 已经起录；Space 随后才到。松开右⌥ 的 `.overlayHoldReleased`
    /// 不能把切换录音的录音器停掉 —— 所以断言的是**松开 ⌥ 若干秒之后录音器
    /// 还活着、计时还在走**；再按一次之后录音器必须停。
    private func runToggleSelfTest() {
        selfTest = true
        store.readOnly = true
        guard AXIsProcessTrusted() else {
            permissions.request(.accessibility)
            emit("未授权辅助功能 —— 已打开系统设置，勾选「落音 Inkfall」后重跑本命令")
            exit(1)
        }
        startHotkeys()
        guard hotkeys != nil else {
            emit("tap 建立失败")
            exit(1)
        }
        emit("绑定：toggle=\(store.effectiveShortcuts.toggleRecording.displayLabel)")

        func chord(_ label: String) {
            emit("→ 合成 \(label)：右⌥ 按下 · Space 按下/松开 · 右⌥ 松开")
            Self.postRightOption(down: true)
            Thread.sleep(forTimeInterval: 0.08)
            Self.postSpace(down: true)
            Thread.sleep(forTimeInterval: 0.05)
            Self.postSpace(down: false)
            Thread.sleep(forTimeInterval: 0.08)
            Self.postRightOption(down: false)
        }
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            emit((ok ? "  ✓ " : "  ✗ ") + what)
            if !ok { failures.append(what) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { chord("第一次") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            emit("松开 ⌥ 两秒后：录音=\(recorder.isRecording) toggle=\(toggleOwnsRecorder) "
                 + "hold=\(holdOwnsRecorder) "
                 + String(format: "已录=%.2fs", recorder.takeDurationSeconds)
                 + " 刘海=「\(notch.debugMessage)」")
            check(recorder.isRecording, "第一次按下后录音器在跑")
            check(toggleOwnsRecorder && !holdOwnsRecorder, "录音器归切换录音，不归推杆")
            check(recorder.takeDurationSeconds > 1.5, "松开 ⌥ 没有把长录停掉")
            check(notch.debugMessage.hasPrefix("录音"), "刘海显示切换录音的计时")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { chord("第二次") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { [self] in
            emit("第二次之后：录音=\(recorder.isRecording) toggle=\(toggleOwnsRecorder) "
                 + "刘海=「\(notch.debugMessage)」")
            check(!recorder.isRecording, "第二次按下后录音器停了")
            check(!toggleOwnsRecorder, "切换状态已清")
            let toggles = selfTestEvents.filter { $0 == .toggleRecordingPressed }.count
            check(toggles == 2, "收到两次 toggleRecordingPressed（实际 \(toggles)）")
            emit("收到事件：\(selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            emit(failures.isEmpty ? "✅ 切换录音链路通" : "❌ \(failures.count) 项不通过")
            Log.flush()
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private static func postSpace(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: 49, keyDown: down) else { return }
        // 右⌥ 还按着，所以 alternate 位（共享位 + 设备位）必须带上，
        // 否则 matcher 眼里这就是一个裸 Space。
        event.flags = CGEventFlags(rawValue: HotkeyMask.alternate | HotkeyMask.rightOptionDevice)
        event.post(tap: .cghidEventTap)
    }

    /// 合成一个右 ⌥ 的 flagsChanged。修饰键没有 keyDown/keyUp 事件，
    /// 只能造一个键盘事件再改成 flagsChanged。
    private static func postRightOption(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: 61, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down
            ? CGEventFlags(rawValue: HotkeyMask.alternate | HotkeyMask.rightOptionDevice)
            : CGEventFlags(rawValue: 0)
        event.post(tap: .cghidEventTap)
    }

    private func runModelDownloadTest(id: String) {
        selfTest = true
        guard let model = LocalModels.definition(id: id) else {
            emit("未知模型 \(id)")
            Log.flush()
            exit(1)
        }
        // 先删干净，否则测的是「已经下过」而不是下载本身。
        models.delete(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            emit("起始状态：已下载=\(models.entries.first { $0.id == id }?.downloaded ?? true)")
            models.download(id)
            emit("busy=\(models.busy ?? "无")")
            pollDownload(id: id, model: model, ticks: 0)
        }
    }

    private func pollDownload(id: String, model: LocalModelDefinition, ticks: Int) {
        guard ticks < 120 else {
            emit("❌ 超时")
            Log.flush()
            exit(1)
        }
        let entry = models.entries.first { $0.id == id }
        if let progress = entry?.progress {
            if ticks % 4 == 0 { emit(String(format: "进度 %.0f%%", progress * 100)) }
        } else if models.busy == nil, ticks > 0 {
            let done = entry?.downloaded ?? false
            emit("完成：已下载=\(done) 体积=\(entry?.sizeText ?? "?") "
                 + "错误=\(models.lastError ?? "无")")
            emit(done ? "✅ 模型下载流程通" : "❌ 下载后状态没刷新成已下载")
            Log.flush()
            exit(done ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            pollDownload(id: id, model: model, ticks: ticks + 1)
        }
    }

    @objc private func quit() {
        // 隐私规则：录音绝不能活过 App。真正的录音器接上之后，
        // 这里要同步释放麦克风再退出。
        NSApp.terminate(nil)
    }

    // MARK: - 全局热键

    private func startHotkeys() {
        guard hotkeys == nil else { return }

        let monitor = HotkeyMonitor(shortcuts: store.effectiveShortcuts) { events in
            // HotkeyMonitor 保证这个闭包已经 async 回了主队列。
            MainActor.assumeIsolated { AppDelegate.shared?.handle(events) }
        }
        guard monitor.start() else {
            // 用户多半正在系统设置里勾选。授权成功没有任何通知，只能轮询。
            watchForAccessibility()
            return
        }
        hotkeys = monitor
        accessibilityWatch?.invalidate()
        accessibilityWatch = nil
        Log.write("hotkey: 已接管 \(store.effectiveShortcuts.overlayHold.displayLabel)")
    }

    private func watchForAccessibility() {
        guard accessibilityWatch == nil else { return }
        accessibilityWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                guard AXIsProcessTrusted() else { return }
                AppDelegate.shared?.startHotkeys()
            }
        }
    }

    private func handle(_ events: [HotkeyEvent]) {
        if selfTest {
            selfTestEvents += events
            for event in events { emit("   ← \(event)") }
        }
        for event in events { apply(event) }
    }

    private func apply(_ event: HotkeyEvent) {
        switch event {
        case .overlayHoldPressed:
            beginHold()

        case .overlayHoldReleased:
            endHold()

        // ⌥Space：按一下开始长录音，再按一下停止并转写。
        case .toggleRecordingPressed:
            // ⌥ 按下的那一刻已经起了一截「按住说话」，那是组合键的副产物
            // 而不是说话内容。先把它丢掉，再接管录音器。
            abortSpuriousHold()
            if toggleOwnsRecorder {
                endToggle()
            } else {
                beginToggle()
            }

        // ⌥,：输入模式 ⇄ 助手模式。同样先丢掉 ⌥ 按下时起的那截录音。
        case .modeTogglePressed:
            abortSpuriousHold()
            toggleMode()
        }
    }

    /// 右⌥ 组合键被识别出来了：⌥ 按下时起的那截录音是组合键的副产物，不是说话。
    /// 丢掉它，并让随后的 `.overlayHoldReleased` 变成空操作。
    ///
    /// 不这么做的话，每按一次 ⌥Space / ⌥. / ⌥[ 都会附带转写并粘贴一小段噪声 ——
    /// 现在只是因为那截通常短到被 `RecordingSubmissionPolicy` 丢掉才没被发现。
    private func abortSpuriousHold() {
        guard holdOwnsRecorder else { return }
        holdOwnsRecorder = false
        guard recorder.isRecording else { return }
        recorder.cancel()
        stopLevelTicker()
        notch.hide()
        Log.write("hotkey: 右⌥ 组合键 —— 丢弃推杆按下时起的那截录音")
    }

    private func beginHold() {
        guard !recorder.isRecording else { return }
        // 切换录音进行中时，右⌥ 按住不另起一段 —— 一个麦克风不能同时喂两条管线。
        guard !toggleOwnsRecorder else { return }
        guard recorder.microphoneAuthorized else {
            flash(.error, "麦克风未授权", seconds: 2.0)
            return
        }
        if store.settings.micGainBoostEnabled {
            AudioDevices.boostInputVolume(targetPercent: store.settings.micGainBoostTargetPercent)
        }
        do {
            try recorder.start()
        } catch {
            Log.write("hotkey: 起录失败 \(error)")
            flash(.error, "录音启动失败", seconds: 2.0)
            return
        }
        holdOwnsRecorder = true
        // 必须在起录时抓，不能等转写回来 —— 那时用户多半已经切走了。
        pasteTarget = PasteTarget.current()
        Log.write("hotkey: 粘贴目标=\(pasteTarget?.appName ?? "无")")
        hideTimer?.invalidate()
        // 紧凑胶囊：只排一行计时。
        // 不写「正在录音」，也不写「松开结束」—— 手正按着那个键，
        // 用不着别人提醒它松开。
        lastHoldNotchSecond = -1
        notch.show(state: .recording, message: "00:00", compact: true)
        startLevelTicker()
    }

    private func endHold() {
        // 只收自己起的那次录音。切换录音接管之后这里必须是空操作 ——
        // 见 `holdOwnsRecorder` 的说明。
        guard holdOwnsRecorder else { return }
        holdOwnsRecorder = false
        guard recorder.isRecording else { return }
        stopLevelTicker()
        guard let audio = try? recorder.stop() else {
            flash(.error, "录音结束失败", seconds: 2.0)
            return
        }
        enqueue(audio, tag: "hotkey")
    }

    // MARK: - 切换录音

    /// 按一下开始长录音。刘海显示计时；再按一下走 `endToggle()`。
    private func beginToggle() {
        guard !recorder.isRecording else { return }
        guard recorder.microphoneAuthorized else {
            flash(.error, "麦克风未授权", seconds: 2.0)
            return
        }
        if store.settings.micGainBoostEnabled {
            AudioDevices.boostInputVolume(targetPercent: store.settings.micGainBoostTargetPercent)
        }
        do {
            try recorder.start()
        } catch {
            Log.write("toggle: 起录失败 \(error)")
            flash(.error, "录音启动失败", seconds: 2.0)
            return
        }
        toggleOwnsRecorder = true
        segmenter.reset()
        lastSegmentTick = CFAbsoluteTimeGetCurrent()
        toggleStartedAt = lastSegmentTick
        toggleSegmentsSent = 0
        interject.reset()
        if assistantMode { startLive(source: RecorderLiveSource(recorder)) }
        // 必须在起录时抓，不能等转写回来 —— 那时用户多半已经切走了。
        pasteTarget = PasteTarget.current()
        Log.write("toggle: 粘贴目标=\(pasteTarget?.appName ?? "无")")
        hideTimer?.invalidate()
        lastHoldNotchSecond = -1
        notch.show(state: .recording, message: "\(assistantMode ? "助手" : "录音") 00:00", compact: true)
        startLevelTicker()
        Log.write("toggle: 开始长录音")
    }

    /// 再按一下：停止、转写、插回起录时的那个窗口。
    private func endToggle() {
        guard toggleOwnsRecorder else { return }
        toggleOwnsRecorder = false
        guard recorder.isRecording else { return }
        stopLevelTicker()
        guard let audio = try? recorder.stop() else {
            flash(.error, "录音结束失败", seconds: 2.0)
            return
        }
        if live.isActive {
            live.stop(finalAudio: audio)
            flash(.success, "助手 · 结束", seconds: 1.2)
            return
        }
        enqueue(audio, tag: "toggle", quiet: toggleSegmentsSent > 0)
    }

    /// 录音不停，把到这里为止的切成一段排进队列。
    private func cutToggleSegment(reason: String) {
        guard let audio = try? recorder.flushSegment(retainingTailMs: Self.retainTailMs) else { return }
        segmenter.resetSegment()
        guard RecordingSubmissionPolicy.default.verdict(for: audio) == .submit else {
            Log.write("toggle: \(reason)，丢弃过短/静音的一段 \(audio.durationMs)ms")
            return
        }
        Log.write("toggle: \(reason)，切出一段 \(audio.durationMs)ms")
        toggleSegmentsSent += 1
        enqueue(audio, tag: "toggle-seg")
    }

    private func enqueue(_ audio: RecordedAudio, tag: String, quiet: Bool = false) {
        takeQueue.append((audio, tag, pasteTarget, quiet))
        pumpTakes()
    }

    private func pumpTakes() {
        guard !takeInFlight, !takeQueue.isEmpty else { return }
        takeInFlight = true
        let take = takeQueue.removeFirst()
        submit(take.audio, tag: take.tag, target: take.target, quiet: take.quiet)
    }

    /// 管线的每个终点都要调一次（粘完、交给看板、丢弃、失败）。
    private func takeFinished() {
        guard takeInFlight else { return }
        takeInFlight = false
        pumpTakes()
    }

    /// 两个手势共用的尾巴：太短 / 全静音的一段不进管线 —— 但**必须给反馈**。
    /// 早先这里是直接 `notch.hide()`：用户说了一句、刘海一闪就没了，
    /// 分不清是「没录上」还是「转写失败了」，只能干等。
    private func submit(_ audio: RecordedAudio, tag: String, target: PasteTarget?, quiet: Bool) {
        let verdict = RecordingSubmissionPolicy.default.verdict(for: audio)
        guard verdict == .submit else {
            Log.write("\(tag): 丢弃 \(verdict.rawValue) durationMs=\(audio.durationMs)")
            defer { takeFinished() }
            // 分段送过了，最后那截多半是按停之前的静音，不值得一句「太短了」。
            if quiet { return }
            switch verdict {
            case .tooShort: flash(.cancelled, "太短了，没录上", seconds: 1.4)
            case .silent: flash(.cancelled, "没有听到声音", seconds: 1.4)
            case .submit: break
            }
            return
        }
        Log.write("\(tag): 采集完成 \(audio.data.count) 字节 / \(audio.durationMs) ms")
        transcribeAndInsert(audio, target: target, pauseCut: tag == "toggle-seg")
    }

    // MARK: - 转写 → 加工 → 粘贴

    /// 转写（云端或本地，见 `Transcriber`）→ 加工 → 送回起录时的那个窗口。
    /// 加工那一段九个预设都在，见 `PostProcessingCoordinator`。
    private func transcribeAndInsert(_ audio: RecordedAudio, target: PasteTarget?, pauseCut: Bool = false) {
        let durationMs = audio.durationMs
        let settings = store.settings
        let modelID = settings.selectedLocalModelId
        let name = Transcriber.label(for: settings)
        if !notchHeld { notch.show(state: .transcribing, message: "\(name) 转写中") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-take-\(UUID().uuidString).wav")
        do {
            try audio.data.write(to: url)
        } catch {
            flash(.error, "写入临时文件失败", seconds: 2.0)
            takeFinished()
            return
        }

        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let request = LocalTranscriber.Request(
            wavURL: url,
            modelID: modelID,
            language: policy.requested(locked: sessionLanguage),
            replacements: store.settings.transcriptionReplacements)

        Task { [router] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let outcome = try await router.transcribe(audio: audio, local: request,
                                                          settings: settings, policy: policy)
                await MainActor.run {
                    AppDelegate.shared?.lockSessionLanguage(outcome.result.language, policy: policy)
                    AppDelegate.shared?.pendingTranscriptionNotice = outcome.notice
                    AppDelegate.shared?.deliver(outcome.result, into: target, durationMs: durationMs,
                                                route: outcome.route, pauseCut: pauseCut)
                }
            } catch {
                Log.write("transcribe: 失败 \(error)")
                await MainActor.run {
                    AppDelegate.shared?.flash(.error, Self.short(error), seconds: 3.0)
                    AppDelegate.shared?.takeFinished()
                }
            }
        }
    }

    /// 把这一段的检测结果投进会话语言的票箱。两票一致才锁。
    private func lockSessionLanguage(_ detected: String?,
                                     policy: TranscriptionLanguagePolicy) {
        guard languageLock.observe(TranscriptionLanguage.detected(detected),
                                   policy: policy) else { return }
        Log.write("transcribe: 会话语言锁定 \(languageLock.locked?.rawValue ?? "?") "
            + "（\(languageLock.votes.map(\.rawValue).joined(separator: "→"))）")
    }

    private func deliver(_ result: LocalTranscriber.Result, into target: PasteTarget?,
                         durationMs: UInt64, route: String = "local", pauseCut: Bool = false) {
        guard !result.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            takeFinished()
            return
        }
        Log.write(String(format: "transcribe: %@ %.2fs lang=%@ → %d 字",
                         route, result.elapsed, result.language ?? "?", result.text.count))
        scheduleModelUnload()

        // 加工可能要一次网络往返，所以整条尾巴是异步的。
        // 不加工的分支不会真的挂起，行为和以前一样立刻粘出去。
        Task { [processing, store] in
            let outcome = await processing.process(
                result.text,
                settings: store.settings,
                durationMs: durationMs,
                onRemoteStart: { [weak self] preset in
                    guard self?.notchHeld == false else { return }
                    self?.notch.show(state: .processing, message: "\(preset.label) · 加工中")
                })
            // 输入模式：录音 → 转写 → 粘贴，别的都不做。
            guard self.assistantMode else {
                self.insert(outcome, into: target)
                return
            }
            // 助手模式：不粘贴，记进历史，放下一段进来；分流（任务 / 提问 / 纠错）在旁路跑。
            self.recordAssistantTake(source: result.text, outcome: outcome)
            self.pendingProcessingNotice = nil
            self.pendingTranscriptionNotice = nil
            self.flash(.success, "已记进历史", seconds: 1.2)
            self.takeFinished()
            self.startAssistant(result.text, pauseCut: pauseCut)
        }
    }

    /// 助手模式：简单问题 → 语音回答；要查的问题 / 清楚的任务 → 看板后台建卡给 agent；
    /// 大而不清的任务 → 打开起票面板；说错 → 语音纠正。
    private func startAssistant(_ text: String, pauseCut: Bool) {
        guard interject.hasGateKey else {
            Log.write("assistant: 没有 TypeSafe key，只记历史")
            return
        }
        let index = interject.register(text)
        let transcribedAt = CFAbsoluteTimeGetCurrent()
        let settings = store.settings
        Task { [interject, kanban] in
            let outcome = await interject.run(segment: text, settings: settings, checkComplete: pauseCut)
            let gate = outcome.gate.map {
                String(format: "complete=%.2f task=%.2f question=%.2f simple=%.2f complex=%.2f claim=%.2f",
                       $0.complete, $0.task, $0.question, $0.simple, $0.complex, $0.claim)
            } ?? "无"
            let head = "assistant: \(gate) \(outcome.gateMs)ms → \(outcome.route.rawValue)"
            switch outcome.route {
            case .ticket:
                // 大而不清的活：原话放进起票面板，作成先和模型由境选。
                self.notch.show(state: .processing, message: "打开看板起票")
                if await kanban.send(outcome.segment) {
                    Log.write("\(head) · 已打开看板起票")
                    self.flash(.success, "这个比较大，已打开起票面板", seconds: 2.4)
                } else {
                    Log.write("\(head) · 看板没连上")
                    self.flash(.error, "看板没连上，已记进历史", seconds: 2.4)
                }

            case .agent:
                // 要查东西的问题 / 清楚的任务：后台建卡，agent 直接去做。做完要不要念，看卡的 voice_reply。
                if let path = await kanban.createCard(outcome.segment) {
                    Log.write("\(head) · 已在看板后台建卡 \(path)")
                    self.present("交给 agent 了", prefix: "")
                } else {
                    Log.write("\(head) · 建卡失败")
                    self.flash(.error, "看板没连上，已记进历史", seconds: 2.4)
                }

            case .answer:
                guard let answer = outcome.answer else {
                    Log.write("\(head) · \(outcome.stoppedAt ?? "?")")
                    return
                }
                Log.write("\(head) · \(outcome.model) \(outcome.checkMs)ms 答「\(answer)」")
                self.history.append(HistoryEntry(title: "回答", sourceText: outcome.segment, finalText: answer,
                                                 transcriptionMode: settings.transcriptionMode,
                                                 postProcessingEnabled: false, postProcessingPreset: nil))
                self.rebuildHistoryMenu()
                self.present(answer, prefix: "答：")

            case .check:
                guard let check = outcome.check else {
                    Log.write("\(head) · \(outcome.stoppedAt ?? "?")")
                    return
                }
                let delay = CFAbsoluteTimeGetCurrent() - transcribedAt
                let decision = interject.decide(check, segment: outcome.segment, delay: delay,
                                               laterSegments: interject.segments(after: index))
                let verdict: String
                switch decision {
                case .show(let correction): verdict = "shown「\(correction)」"
                case .drop(let reason): verdict = "dropped(\(reason.rawValue))"
                }
                Log.write(String(format: "%@ · %@ %@ wrong=%@ p=%.2f %dms · %.1fs → %@ · %@",
                                 head, outcome.model, check.kind.rawValue, check.wrong ? "y" : "n",
                                 check.confidence, outcome.checkMs, delay, verdict, check.detail))
                if case .show(let correction) = decision { self.present(correction, prefix: "纠正：") }

            case .incomplete, .none:
                Log.write("\(head)\(outcome.stoppedAt.map { " · \($0)" } ?? "")")
            }
        }
    }

    /// 刘海显示并念出来（纠正 / 回答）。刘海停到念完为止，按字数估。
    private func present(_ text: String, prefix: String) {
        if let sim = liveSim {
            live.trace("present", ["text": prefix + text])
            guard sim.mute else { speakInterjection(text); return }
            // 不出声的模拟：和真的一样，念之前收下已经说的，念的期间不切段，念完扔掉录到的
            live.cut(reason: "before-voice")
            simVoiceUntil = CFAbsoluteTimeGetCurrent() + Self.estimatedSpeech(text)
            return
        }
        let seconds = min(15, max(4, Double(text.count) / 5))
        notchHoldUntil = 0
        flash(.error, prefix + text, seconds: seconds)
        notchHoldUntil = CFAbsoluteTimeGetCurrent() + seconds
        speakInterjection(text)
    }

    private func speakInterjection(_ text: String) {
        interjectVoice.speak(text, onStart: { [weak self] in
            // 念之前把已经说的话先切出去（照常转写），念的这段之后整段扔掉。
            guard let self else { return }
            if self.live.isActive { self.live.cut(reason: "before-voice"); return }
            guard self.toggleOwnsRecorder, self.recorder.isRecording else { return }
            self.cutToggleSegment(reason: "插话前")
        }, onFinish: { [weak self] in
            guard let self else { return }
            if self.live.isActive { self.live.discardVoice(); return }
            guard self.toggleOwnsRecorder, self.recorder.isRecording else { return }
            let dropped = (try? self.recorder.flushSegment(retainingTailMs: 0))?.durationMs ?? 0
            self.segmenter.resetSegment()
            Log.write("assistant: 念完，扔掉念的期间录到的 \(dropped)ms")
        })
    }

    /// 念一句中文大约多久（模拟用）：每字 0.2 秒，另加起头的 0.3 秒。
    private static func estimatedSpeech(_ text: String) -> Double { 0.3 + Double(text.count) * 0.2 }

    // MARK: - 边听边插话

    private func makeLive() -> LiveInterjector {
        let live = LiveInterjector(probe: interject) { [weak self] audio in
            guard let self else { throw CancellationError() }
            return try await self.transcribeLive(audio)
        }
        live.trace = { [weak self] event, fields in self?.traceLive(event, fields) }
        live.onFinished = { [weak self] finished in self?.handleLive(finished) }
        return live
    }

    private func startLive(source: LiveAudioSource) {
        let settings = store.settings
        if let provider = settings.transcriptionMode.cloudProviderForSelfTest { CloudTranscriber.prewarm(provider) }
        PostProcessor.prewarm(InterjectionAPI.checkProvider)
        live.start(source: source)
    }

    private func traceLive(_ event: String, _ fields: [String: Any]) {
        let rendered = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Log.write("live: \(event) \(rendered)")
        guard let sim = liveSim else { return }
        var row = fields
        row["t"] = (sim.source.elapsed * 1000).rounded() / 1000
        row["ev"] = event
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            sim.out?.write(data + Data("\n".utf8))
        }
        emit(String(format: "%7.2f %@ %@", sim.source.elapsed, event, rendered))
    }

    /// 边听边插话的一次转写：和两个手势同一个 `Transcriber`（云端 / 降级 / 会话语言锁都一样）。
    private func transcribeLive(_ audio: RecordedAudio) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-live-\(UUID().uuidString).wav")
        try audio.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = store.settings
        let policy = TranscriptionLanguagePolicy(settings: settings)
        let request = LocalTranscriber.Request(
            wavURL: url, modelID: settings.selectedLocalModelId,
            language: policy.requested(locked: sessionLanguage),
            replacements: settings.transcriptionReplacements)
        let outcome = try await router.transcribe(audio: audio, local: request, settings: settings, policy: policy)
        lockSessionLanguage(outcome.result.language, policy: policy)
        return outcome.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收下的一句：记进历史，说错了就纠正。**只纠正**：两个人聊天时的提问、「你帮我看看」是说给对方的，
    /// 模拟对话里 AI 去答「真的假的」「是吗」「明朝以前吃什么辣的」全是多嘴（2026-09-30）。
    /// 按住说话（明确是对助手说的）照旧回答 / 建卡。
    private func handleLive(_ finished: LiveInterjector.Finished) {
        let settings = store.settings
        // 收下的每句都记着：核对回来之前本人可能已经改口了（「……是大阪。」「啊不对，是东京」先收下、核对 2 秒才回来）
        let committedAt = CFAbsoluteTimeGetCurrent()
        liveHeard.append((committedAt, finished.text))
        if liveHeard.count > 12 { liveHeard.removeFirst() }
        if liveSim == nil {
            history.append(HistoryEntry(sourceText: finished.text, finalText: finished.text,
                                        transcriptionMode: settings.transcriptionMode,
                                        postProcessingEnabled: false, postProcessingPreset: nil))
            rebuildHistoryMenu()
        }
        liveActsPending += 1
        Task { [interject] in
            defer { self.liveActsPending -= 1 }
            let outcome = await interject.act(segment: finished.text, gate: finished.gate, settings: settings,
                                              answering: false)
            let since = Int((CFAbsoluteTimeGetCurrent() - finished.spokeUntil) * 1000)
            var fields: [String: Any] = ["text": finished.text, "route": outcome.route.rawValue,
                                         "model": outcome.model, "ms": outcome.checkMs, "since_speech_ms": since,
                                         "claim": finished.gate.claim, "question": finished.gate.question,
                                         "task": finished.gate.task]
            if let stopped = outcome.stoppedAt { fields["stopped"] = stopped }
            switch outcome.route {
            case .check:
                guard let check = outcome.check else { self.live.trace("act", fields); return }
                let delay = CFAbsoluteTimeGetCurrent() - finished.spokeUntil
                let later = self.liveHeard.filter { $0.at > committedAt }.map(\.text)
                let decision = interject.decide(check, segment: finished.text, delay: delay, laterSegments: later)
                fields["kind"] = check.kind.rawValue
                fields["wrong"] = check.wrong
                fields["confidence"] = check.confidence
                fields["correction"] = check.correction
                switch decision {
                case .show: fields["decision"] = "show"
                case .drop(let reason): fields["decision"] = reason.rawValue
                }
                self.live.trace("act", fields)
                guard case .show(let correction) = decision else { return }
                // 停顿后紧接着有人在说（多半是本人没说完）：先把接着说的转写了，是在改口就不插
                guard self.live.isActive, self.live.continuesQuickly(after: finished.spokeUntil) else {
                    self.present(correction, prefix: "纠正：")
                    return
                }
                self.live.trace("hold", ["correction": correction])
                self.live.cut(reason: "hear-continuation") { heard in
                    if let heard, InterjectionPolicy.correctsItself(heard) {
                        self.live.trace("hold-drop", ["heard": heard, "correction": correction])
                    } else {
                        self.present(correction, prefix: "纠正：")
                    }
                }
            case .answer, .agent, .ticket, .none, .incomplete:
                self.live.trace("act", fields)
            }
        }
    }

    /// `--live-sim <wav> [--out <jsonl>] [--mute] [--tail 秒] [--no-smart-turn] [--turn-give-up 秒]`：
    /// 把 wav 当成麦克风按真实时间放进边听边插话，事件打到 stderr 和 JSONL（`t` 是从放音开始的秒数）。
    private func runLiveSim(wav: String) {
        selfTest = true
        store.readOnly = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let data = FileManager.default.contents(atPath: wav), FileLiveSource(wav: data) != nil else {
            emit("用法：--live-sim <16bit 单声道 wav> [--out <jsonl>] [--mute] [--tail 秒] [--no-smart-turn]")
            exit(2)
        }
        guard interject.hasGateKey else { emit("没有 TypeSafe key"); exit(1) }
        let out = arguments.firstIndex(of: "--out").flatMap { arguments[safe: $0 + 1] }.flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        simTail = arguments.firstIndex(of: "--tail").flatMap { arguments[safe: $0 + 1] }.flatMap(Double.init) ?? 4
        live.smartTurnEnabled = !arguments.contains("--no-smart-turn")
        if let giveUp = arguments.firstIndex(of: "--turn-give-up").flatMap({ arguments[safe: $0 + 1] }).flatMap(Double.init) {
            live.turnGiveUp = giveUp
        }
        Task { @MainActor in
            // 模型先载好再开始放（真机上录音一开始就载，头一次停顿前早好了）
            if self.live.smartTurnEnabled {
                await SmartTurnModel.shared.prepare().value
                if let failure = SmartTurnModel.shared.failure { emit("smart-turn 载不进来：\(failure)") }
            }
            guard let source = FileLiveSource(wav: data) else { exit(2) }
            self.liveSim = (source, out, arguments.contains("--mute"))
            self.startLive(source: source)
            emit(String(format: "live-sim: %.1fs 音频，放完再等 %.0fs", source.durationSeconds, self.simTail))
            self.simLast = CFAbsoluteTimeGetCurrent()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                Task { @MainActor in AppDelegate.shared?.simTick() }
            }
        }
    }

    private var simLast: CFAbsoluteTime = 0
    private var simTail: Double = 4
    private var simVoiceActive = false
    private var simStoppedAt: CFAbsoluteTime?

    private func simTick() {
        guard let sim = liveSim else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let delta = now - simLast
        simLast = now
        sim.source.advance()
        if let stopped = simStoppedAt {
            // 放完了：等在路上的转写 / 核对回来（最多 20 秒），再退出
            let idle = live.inFlight == 0 && liveActsPending == 0
            guard (idle && now - stopped > 0.5) || now - stopped > 20 else { return }
            try? sim.out?.close()
            Log.flush()
            exit(0)
        }
        let speaking = sim.mute ? now < simVoiceUntil : interjectVoice.isSpeaking
        if speaking {
            simVoiceActive = true
        } else if simVoiceActive {
            simVoiceActive = false
            live.discardVoice()
        } else {
            live.tick(level: sim.source.level, delta: delta)
        }
        if sim.source.elapsed > sim.source.durationSeconds + simTail, !speaking {
            live.stop(finalAudio: sim.source.takeAll())
            simStoppedAt = now
        }
    }

    private var notchHeld: Bool { CFAbsoluteTimeGetCurrent() < notchHoldUntil }

    /// 加工结果 → 剪贴板/目标窗口。降级提示先说，再粘。
    private func insert(_ outcome: PostProcessingCoordinator.Outcome, into target: PasteTarget?) {
        let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            takeFinished()
            return
        }
        // ⚠️ 提示不能在这里 flash：紧接着的「粘贴中」和粘完的「已粘回 X」
        // 会在几十毫秒内把它盖掉，用户根本来不及看见。攒到粘贴结果那一刻
        // 一起说（见 `reportPaste`）。
        pendingProcessingNotice = outcome.notice.map { ($0, outcome.isProblem) }
            ?? pendingTranscriptionNotice.map { ($0, false) }
        pendingTranscriptionNotice = nil

        let options = PasteOptions(settings: store.settings)
        if !notchHeld { notch.show(state: .processing, message: options.autoPasteEnabled ? "粘贴中" : "复制中") }
        // ⚠️ 插入路径里是一连串 `Thread.sleep`（等剪贴板、等激活、等目标读完）。
        // 放主线程会把刘海动画连同整个 UI 冻住半秒以上，所以丢到后台队列。
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MacAutomation.insert(text, into: target, options: options)
            DispatchQueue.main.async {
                Log.write("paste: route=\(result.route?.rawValue ?? "无") "
                    + "outcome=\(result.outcome.rawValue) target=\(target?.appName ?? "无")")
                AppDelegate.shared?.reportPaste(result, appName: target?.appName)
            }
        }
    }

    func reportPaste(_ result: PasteResult, appName: String?) {
        defer { takeFinished() }
        var message = AutoPaste.message(result.outcome, appName: appName)
        var state: OverlayState = result.outcome.landedInTarget ? .success : .cancelled
        var seconds = result.outcome.landedInTarget ? 1.6 : 2.4
        // 加工那一步的话攒到这里一起说 —— 单独 flash 会被粘贴消息秒盖。
        if let notice = pendingProcessingNotice {
            message += " · \(notice.text)"
            if notice.isProblem {
                state = .error
                seconds = 3.4
            }
            pendingProcessingNotice = nil
        }
        if let notice = pendingIntentNotice {
            message += " · \(notice)"
            seconds = max(seconds, 2.6)
            pendingIntentNotice = nil
        }
        flash(state, message, seconds: seconds)
        guard result.outcome.needsAccessibilityPrompt else { return }
        promptForAccessibilityOnce()
    }

    /// 引导只弹**一次**。每次听写都把系统设置怼到用户脸上比静默失败还烦人；
    /// 关掉之后设置页的权限行仍然一直摆在那儿。
    private func promptForAccessibilityOnce() {
        guard !accessibilityPrompted else { return }
        accessibilityPrompted = true
        Log.write("paste: 未授权辅助功能，已打开系统设置")
        permissions.request(.accessibility)
    }

    /// 5 分钟没再用就把模型卸掉。常驻 1.5 GB 只为省下 7 秒的重新加载，
    /// 对一个菜单栏小工具是不划算的买卖。
    private func scheduleModelUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
            Task { @MainActor in
                guard let self = AppDelegate.shared, !self.recorder.isRecording else { return }
                await self.transcriber.unload()
                Log.write("transcribe: 空闲 5 分钟，已卸载模型")
            }
        }
    }

    private static func short(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return String(text.prefix(60))
    }

    // MARK: - 粘回自家窗口的自测

    /// 目标是**落音自己的窗口**时，插入路径不能把 App 弄崩。
    ///
    /// 这是 2026-08-04 那次真实崩溃的回归守卫：AX 对跨进程目标是消息传递，
    /// 后台线程调没问题；目标在本进程时请求**就地派发**，`kAXRaiseAction`
    /// 变成在后台线程上跑 `makeKeyAndOrderFront:`，AppKit 直接 trap
    /// （`Must only be used from the main thread`）。
    ///
    /// 复现条件必须一模一样：**真实的自家窗口** + **后台队列** + 真实的
    /// `MacAutomation.insert`。少一样都测不出来 —— 修之前跑这条会整个进程
    /// SIGTRAP，连一行断言都来不及打。
    private func runSelfPasteTest() {
        selfTest = true
        store.readOnly = true
        hub.show()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard let target = PasteTarget.current() else {
                emit("❌ 抓不到前台窗口")
                Log.flush()
                exit(1)
            }
            let mine = MacAutomation.targetsThisProcess(target.processID)
            emit("目标：\(target.appName) pid=\(target.processID) "
                 + "自家进程=\(mine ? "是" : "否") 窗口引用=\(target.window == nil ? "无" : "有")")
            guard mine else {
                emit("❌ 前台不是落音自己 —— 这条自测要的就是自家窗口")
                Log.flush()
                exit(1)
            }

            // ⚠️ 必须先把**别人**切到前台。目标仍在前台时插入会走
            // `pasteInPlace`（原地 ⌘V，不抬窗口），根本碰不到出事的那条路 ——
            // 崩溃发生在 `activateAndPaste`，而它只在目标掉出前台时才走。
            // 这正是真实场景：说话时面板在前台，几秒后转写回来时用户已经切走了。
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.finder" }?
                .activate(options: .activateAllWindows)
            Thread.sleep(forTimeInterval: 1.2)
            emit("已把 Finder 切到前台，目标现在不在前台："
                 + "isFrontmost=\(target.isFrontmost)")

            // ⚠️ 必须是后台队列：主线程上跑的话 `onMainIfSelf` 会直接执行，
            // 那正是崩溃**不会**发生的那条路，等于什么都没验。
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MacAutomation.insert(
                    "落音自测：粘回自家窗口", into: target,
                    options: PasteOptions(autoPasteEnabled: true, appendNewline: false))
                DispatchQueue.main.async {
                    emit("插入完成：route=\(result.route?.rawValue ?? "无") "
                         + "outcome=\(result.outcome.rawValue)")
                    emit("✅ 自家窗口没把 App 弄崩（修复前这里是 SIGTRAP，跑不到这一行）")
                    Log.flush()
                    exit(0)
                }
            }
        }
    }

    // MARK: - 加工自测

    /// 加工链路的取证。
    ///
    /// 麦克风、转写、粘贴全绕开 —— 那几段各自有自己的自测。这里验的是中间
    /// 那一段：九个预设的提示词拼得对不对、当前配置会走哪条路、真发一次
    /// 请求能不能回来。
    /// 云端转写自测：真发一次当前配置的转写请求（或按 `--mode` 覆盖）。
    /// 验的是「这条路通不通」：key、地址、multipart、解析、降级。
    private func runCloudTranscribeTest(wav: String) {
        selfTest = true
        store.readOnly = true
        guard !wav.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: wav)) else {
            emit("用法：--cloud-transcribe-test <wav> [--mode openai|groq|gemini|local]")
            exit(2)
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = arguments.firstIndex(of: "--mode").flatMap({ arguments[safe: $0 + 1] }) {
            guard let mode = TranscriptionMode(rawValue: raw) else {
                emit("未知的转写模式：\(raw)")
                exit(2)
            }
            store.settings.transcriptionMode = mode
        }
        // 自测里语言自动 —— 要验的正是 verbose_json 带回来的语言。
        store.settings.transcriptionLanguageMode = .auto
        let settings = store.settings
        // 秒数从 wav 头算；算不出来就按 0（只影响日志）。
        let durationMs: UInt64 = WAV.parse(data).map { info in
            let bytesPerSecond = Int(info.sampleRate) * Int(info.channels) * 2
            return bytesPerSecond > 0 ? UInt64(info.dataRange.count * 1000 / bytesPerSecond) : 0
        } ?? 0
        let audio = RecordedAudio(filename: (wav as NSString).lastPathComponent,
                                  data: data, durationMs: durationMs)
        let policy = TranscriptionLanguagePolicy(settings: settings)
        let request = LocalTranscriber.Request(
            wavURL: URL(fileURLWithPath: wav), modelID: settings.selectedLocalModelId,
            language: policy.requested(), replacements: settings.transcriptionReplacements)

        emit("转写模式=\(settings.transcriptionMode.rawValue) "
             + "模型=\(TranscriptionAPI.model(for: settings.transcriptionMode, settings: settings)) "
             + "本地模型就绪=\(Transcriber.localModelReady(settings) ? "是" : "否") "
             + "自动降级=\(settings.autoLocalFallbackEnabled ? "开" : "关") "
             + "音频=\(data.count) 字节 \(durationMs) ms")

        Task { [router] in
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let outcome = try await router.transcribe(audio: audio, local: request,
                                                          settings: settings, policy: policy)
                emit(String(format: "路线=%@ 耗时=%.2fs lang=%@", outcome.route,
                            CFAbsoluteTimeGetCurrent() - started, outcome.result.language ?? "?"))
                if let notice = outcome.notice { emit("提示：\(notice)") }
                emit("结果：\(outcome.result.text)")
                Log.flush()
                exit(outcome.isProblem ? 1 : 0)
            } catch {
                emit("失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                Log.flush()
                exit(1)
            }
        }
    }

    private func runIntentTest(text: String, bundleID: String?) {
        selfTest = true
        guard intent.isEnabled else {
            emit("没有 TypeSafe key（TYPESAFE_API_KEY 或 ~/.config/typesafe/api_key）")
            Log.flush()
            exit(1)
        }
        let sample = text.isEmpty || text.hasPrefix("--") ? "帮我把刚才那段改得正式一点" : text
        let appName = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }?
            .deletingPathExtension().lastPathComponent ?? "unknown"
        emit("app=\(appName) kind=\(AssistantIntentAPI.appKind(bundleID: bundleID)) text=\(sample)")
        Task { [intent] in
            guard let judgement = await intent.judge(text: sample, appName: appName, bundleID: bundleID) else {
                emit("Jev 没有回答（见日志）")
                Log.flush()
                exit(1)
            }
            emit(String(format: "p=%.2f → %@（%@）%dms", judgement.p, judgement.verdict.rawValue,
                        judgement.verdict.label, judgement.elapsedMs))
            Log.flush()
            exit(0)
        }
    }

    /// 自测 / 评测用的核对路：`--provider` / `--model` 覆盖，只活在内存里。
    private func interjectRouteForSelfTest() async -> PostProcessor.Route? {
        store.readOnly = true
        let arguments = ProcessInfo.processInfo.arguments
        // ⚠️ 不要在这里把预设改成云端的：用户实际的设置（basic）才是要验的那条路。
        var preferQwen = true
        if let raw = arguments.firstIndex(of: "--provider").flatMap({ arguments[safe: $0 + 1] }),
           let provider = CloudProvider(rawValue: raw) {
            store.settings.postProcessingProvider = provider
            preferQwen = false
        }
        guard let route = await interject.checkRoute(settings: store.settings, preferQwen: preferQwen) else { return nil }
        if let model = arguments.firstIndex(of: "--model").flatMap({ arguments[safe: $0 + 1] }),
           case .cloud(let provider, _, let key) = route {
            return .cloud(provider: provider, model: model, key: key)
        }
        return route
    }

    private func runInterjectTest(text: String, previous: String?) {
        selfTest = true
        let sample = text.isEmpty || text.hasPrefix("--") ? "苹果是一种蔬菜，我每天都吃" : text
        Task { [interject, store] in
            // 走真的助手模式分流（按住说话那样：不看「说完了吗」），用户实际的设置。
            store.readOnly = true
            let outcome = await interject.run(segment: sample, settings: store.settings, checkComplete: false)
            emit("segment=\(sample)")
            if let gate = outcome.gate {
                emit(String(format: "Jev complete=%.2f task=%.2f question=%.2f simple=%.2f complex=%.2f claim=%.2f %dms → %@",
                            gate.complete, gate.task, gate.question, gate.simple, gate.complex, gate.claim,
                            outcome.gateMs, outcome.route.rawValue))
            }
            if let answer = outcome.answer {
                emit("\(outcome.model) \(outcome.checkMs)ms 答：\(answer)")
            } else if outcome.route == .agent || outcome.route == .ticket {
                emit("→ \(outcome.route == .agent ? "看板后台建卡给 agent" : "打开起票面板")（自测不发）")
            } else if let check = outcome.check {
                emit(String(format: "%@ %dms kind=%@ wrong=%@ p=%.2f", outcome.model, outcome.checkMs,
                            check.kind.rawValue, check.wrong ? "y" : "n", check.confidence))
                emit("correction=\(check.correction) detail=\(check.detail)")
                let decision = interject.decide(check, segment: sample, delay: 1, laterSegments: [])
                emit("→ \(decision)")
            } else {
                emit("停在 \(outcome.stoppedAt ?? "?")")
            }
            Log.flush()
            exit(0)
        }
    }

    /// 评测：cases.json = [{"id", "previous": [..], "text"}]，逐条跑（4 条并行），结果写 out.json。
    private func runInterjectEval(cases: String, out: String) {
        selfTest = true
        struct Case: Decodable { let id: String; let previous: [String]; let text: String }
        guard let data = FileManager.default.contents(atPath: cases),
              let items = try? JSONDecoder().decode([Case].self, from: data), !out.isEmpty else {
            emit("用法：--interject-eval <cases.json> <out.json>")
            exit(2)
        }
        let skipGate = ProcessInfo.processInfo.arguments.contains("--no-gate")
        Task { [interject] in
            let route = await interjectRouteForSelfTest()
            if !skipGate && !interject.hasGateKey { emit("没有 TypeSafe key"); exit(1) }
            emit("route=\(route.map { "\($0)".components(separatedBy: "key:").first ?? "" } ?? "无") cases=\(items.count) gate=\(!skipGate)")
            var rows: [[String: Any]] = []
            for chunk in stride(from: 0, to: items.count, by: 4).map({ Array(items[$0..<min($0 + 4, items.count)]) }) {
                let tasks = chunk.map { item in
                    Task { @MainActor in
                        await interject.judge(segment: item.text, previous: item.previous,
                                              route: route, skipGate: skipGate)
                    }
                }
                var outcomes: [InterjectionProbe.Outcome] = []
                for task in tasks { outcomes.append(await task.value) }
                // 免费档的加工 key 有每分钟请求数上限（Groq 429），评测按 `--pace <秒>` 一组一组放。
                if let pace = ProcessInfo.processInfo.arguments.firstIndex(of: "--pace")
                    .flatMap({ ProcessInfo.processInfo.arguments[safe: $0 + 1] }).flatMap(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(pace * 1_000_000_000))
                }
                for (item, outcome) in zip(chunk, outcomes) {
                    var row: [String: Any] = ["id": item.id, "text": item.text, "route": outcome.model,
                                              "gate_ms": outcome.gateMs, "check_ms": outcome.checkMs,
                                              "stopped": outcome.stoppedAt ?? ""]
                    if let gate = outcome.gate { row["complete"] = gate.complete; row["claim"] = gate.claim }
                    if let check = outcome.check {
                        row["wrong"] = check.wrong; row["kind"] = check.kind.rawValue
                        row["confidence"] = check.confidence; row["correction"] = check.correction
                        row["detail"] = check.detail
                        var fresh = InterjectionPolicy()  // 评测看单句，不带冷却
                        if case .show = fresh.decide(check, segment: item.text, delay: 1, laterSegments: [], now: Date()) { row["shown"] = true }
                    }
                    rows.append(row)
                    emit("\(item.id) \(outcome.stoppedAt ?? outcome.check.map { "\($0.kind.rawValue) \($0.correction)" } ?? "")")
                }
            }
            let json = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            FileManager.default.createFile(atPath: out, contents: json)
            Log.flush()
            exit(0)
        }
    }

    private func runProcessTest(text: String) {
        selfTest = true
        // ⚠️ 自测期间禁止落盘，否则临时改的开关会写进用户的 settings.json
        // （这条是踩过的坑：一次自测把语音命令替用户打开了）。
        store.readOnly = true
        let sample = text.isEmpty
            ? "嗯 那个 我觉得吧 这个功能 呃 应该可以先做一个最小版本 然后再迭代 你觉得呢"
            : text

        // 覆盖项只活在内存里。自测要能验**这条路通不通**，
        // 而不是只验「用户当前恰好选了什么」。
        let arguments = ProcessInfo.processInfo.arguments
        store.settings.postProcessingEnabled = true
        if let raw = arguments.firstIndex(of: "--preset").flatMap({ arguments[safe: $0 + 1] }),
           let preset = PostProcessingPreset(rawValue: raw) {
            store.settings.postProcessingPreset = preset
        }

        emit("加工设置：开关=\(store.settings.postProcessingEnabled ? "开" : "关") "
             + "预设=\(store.settings.postProcessingPreset.label) "
             + "供应商=\(store.settings.postProcessingProvider.label)")

        emit("")
        emit("九个预设的提示词：")
        for preset in PostProcessingPreset.allCases {
            let built = try? PostProcessingPrompt.instructions(
                preset: preset, customPrompt: store.settings.customPostProcessingPrompt,
                memoryContext: store.settings.processingMemoryContext)
            guard let built else {
                emit("  \(preset.rawValue)：（自定义 prompt 为空 → 报错，符合预期）")
                continue
            }
            emit("  \(preset.rawValue)（\(preset.label)）\(built.count) 字："
                 + String(built.prefix(64)) + "…")
        }

        emit("")
        let decision = PostProcessingPolicy.decide(
            settings: store.settings, durationMs: 9_000, transcript: sample)
        emit("裁决（9 s / \(sample.count) 字）：\(decision)")

        emit("")
        emit("原文：\(sample)")
        emit("本地 basic：\(BasicPolisher.polish(sample))")

        Task { [processing, store] in
            let started = CFAbsoluteTimeGetCurrent()
            let outcome = await processing.process(
                sample, settings: store.settings, durationMs: 9_000,
                onRemoteStart: { preset in emit("→ 送出（\(preset.label)）") })
            emit("")
            emit(String(format: "路线=%@ 耗时=%.2fs", outcome.route,
                        CFAbsoluteTimeGetCurrent() - started))
            if let notice = outcome.notice { emit("提示：\(notice)") }
            emit("结果：\(outcome.text)")
            Log.flush()
            exit(outcome.isProblem ? 1 : 0)
        }
    }

    private func startLevelTicker() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in AppDelegate.shared?.pushLevel() }
        }
    }

    /// 录音期间刘海上的计时。**只在整秒变化时才写** ——
    /// 这个函数是 30 Hz 在跑的。
    private var lastHoldNotchSecond = -1
    private func pushLevel() {
        notch.setLevel(Double(recorder.level))
        guard holdOwnsRecorder || toggleOwnsRecorder, recorder.isRecording else { return }
        if toggleOwnsRecorder {
            let now = CFAbsoluteTimeGetCurrent()
            let delta = now - lastSegmentTick
            lastSegmentTick = now
            if live.isActive {
                if recorder.takeDurationSeconds >= Self.hardCutSeconds {
                    live.cut(reason: "hard-limit")
                } else if !interjectVoice.isSpeaking {
                    live.tick(level: recorder.level, delta: delta)
                }
            } else if recorder.takeDurationSeconds >= Self.hardCutSeconds {
                cutToggleSegment(reason: "到达 \(Int(Self.hardCutSeconds))s 硬上限")
            } else if interjectVoice.isSpeaking {
                // 念纠正的时候不切段：那是 AI 的声音，念完整段扔掉。
            } else if segmenter.feed(level: recorder.level, delta: delta) {
                cutToggleSegment(reason: "停顿切段")
            }
        }
        let whole = toggleOwnsRecorder
            ? Int(CFAbsoluteTimeGetCurrent() - toggleStartedAt)
            : Int(recorder.takeDurationSeconds)
        guard whole != lastHoldNotchSecond else { return }
        guard !notchHeld else { return }
        lastHoldNotchSecond = whole
        // ⚠️ 切换录音的前缀必须在这里也带上。这个函数 30 Hz 在跑，
        // `beginToggle()` 写的那行会在第一拍就被它盖掉。
        let time = String(format: "%02d:%02d", whole / 60, whole % 60)
        notch.show(state: .recording,
                   message: toggleOwnsRecorder ? "\(assistantMode ? "助手" : "录音") \(time)"
                       : assistantMode ? "助手 \(time)" : time,
                   compact: true)
    }

    private func stopLevelTicker() {
        levelTimer?.invalidate()
        levelTimer = nil
        notch.setLevel(0)
    }

    private func flash(_ state: OverlayState, _ message: String, seconds: Double) {
        // 纠正还挂在刘海上：后面那段的「已粘回 X」之类不去盖它。
        guard !notchHeld else { return }
        hideTimer?.invalidate()
        notch.show(state: state, message: message)
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in AppDelegate.shared?.flashEnded() }
        }
    }

    /// 长录音还在录（前面切出的段刚粘完）：别收起刘海，下一拍 `pushLevel` 把计时画回来。
    private func flashEnded() {
        if toggleOwnsRecorder, recorder.isRecording {
            lastHoldNotchSecond = -1
        } else {
            notch.hide()
        }
    }

    // MARK: - 引导窗口

    private func showOnboarding() {
        permissions.refresh()

        if let window = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = OnboardingView(permissions: permissions) { [weak self] in
            self?.finishOnboarding()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "落音 Inkfall"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()

        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        store.settings.hasCompletedOnboarding = true
        store.save()
        onboardingWindow?.orderOut(nil)
        // 引导里刚授权的辅助功能 —— 立刻接管热键，不等下次启动。
        startHotkeys()
    }
}

/// 设置的读写。
///
/// ⚠️ 这一版**读**现有 Tauri 版的 `app.inkfall.desktop/settings.json`（验证容错
/// 解码确实原地兼容），但**写**进自己的 `app.inkfall.native/` —— 骨架阶段绝不
/// 碰在用的数据。两边正式合流要等录音与笔记接上之后。
/// @Observable：面板上的三个开关直接读写 `store.settings`，不是副本。
/// 没有它，翻开关不会触发重绘 —— 值变了，界面还是旧的。
@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings
    /// 快捷键单独一个文件（与现有磁盘布局一致，不塞进 settings.json）。
    var shortcuts: ShortcutsConfig

    private static let legacyBundleID = "app.inkfall.desktop"
    private static let nativeBundleID = "app.inkfall.native"

    init() {
        var loaded = AppSettings()
        if let data = try? Data(contentsOf: Self.source("settings.json")),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        let beforeSanitize = loaded
        loaded.sanitize()
        settings = loaded
        // sanitize 改动了什么就当场写回去。否则迁移只活在内存里，
        // 盘上永远是旧值，每次启动都要重新迁移一遍，两边状态还对不上。
        let needsRewrite = beforeSanitize != loaded

        var keys = ShortcutsConfig()
        if let data = try? Data(contentsOf: Self.source("shortcuts.json")),
           let decoded = try? JSONDecoder().decode(ShortcutsConfig.self, from: data) {
            keys = decoded
        }
        shortcuts = keys
        if needsRewrite { save() }
    }

    /// 交给监听器的配置。
    var effectiveShortcuts: ShortcutsConfig { shortcuts }

    private static func source(_ name: String) -> URL {
        let native = directory(nativeBundleID).appendingPathComponent(name)
        let legacy = directory(legacyBundleID).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: native.path) ? native : legacy
    }

    /// 自测期间**禁止落盘**。
    ///
    /// ⚠️ 血的教训：自测只在内存里改开关（`store.settings.x = true`），本以为
    /// 退出即恢复 —— 但界面上任何一个绑定被 SwiftUI 写一次就会调 `save()`，
    /// 把那些临时值连同整份配置一起写进用户的 settings.json。
    /// 于是「跑了一遍自测」变成了「替用户改了一堆设置」。
    var readOnly = false

    func save() {
        guard !readOnly else { return }
        settings.sanitize()
        let dir = Self.directory(Self.nativeBundleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // 与现有磁盘格式一致：pretty + key 排序。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        // 原子写：临时文件 + 替换。
        let target = dir.appendingPathComponent("settings.json")
        let tmp = dir.appendingPathComponent("settings.json.tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(target, withItemAt: tmp)
    }

    private static func directory(_ bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(bundleID)
    }
}

/// 自测用的 stderr 输出。提到文件级是因为麦克风授权回调是 `@Sendable` 的，
/// 捕获一个主 actor 隔离的局部函数过不了 Swift 6 的并发检查。
private func emit(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
    // 自测经常要通过 `open` 启动（直接 exec 二进制时 TCC 归责到父进程，
    // 辅助功能会判为未授权），那条路上 stderr 收不到 —— 所以一并落日志。
    Log.write("selftest: " + line)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// 显式启动，不用 @NSApplicationMain —— 宿主的每一步都要看得见。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
